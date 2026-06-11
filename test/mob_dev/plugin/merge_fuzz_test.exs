defmodule MobDev.Plugin.MergeFuzzTest do
  @moduledoc """
  Property-based fuzzing of the cross-plugin merge layer. Generates random sets
  of plugin manifests (1-5 plugins, each populating a random subset of shared
  fields from a small value pool so collisions actually occur) and asserts two
  invariants hold for EVERY combination:

    1. `cross_validate` reports a collision on a guarded resource **iff** that
       resource genuinely has a value contributed by ≥2 distinct plugins (an
       independent oracle). Catches both under-detection (a real clash slips
       through) and over-detection (e.g. the cross-platform-NIF false positive,
       where one plugin's iOS+Android entry shares a `:module`).
    2. No silent loss: when `cross_validate` finds no plist-key collision,
       `Merge.plist_keys` (a `Map.merge`, the one consumer that silently
       last-write-wins) preserves every key — proving the guard is *sufficient*,
       not just present.

  Deterministic: `:rand` is seeded per iteration so a failure is reproducible
  (the message prints the iteration + manifests).
  """
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Merge, Validator}

  @iterations 400

  # ── value pools (small, so collisions happen) ───────────────────────────────
  @nif_mods [:a_nif, :b_nif, :c_nif]
  @routes ["/x", "/y", "/z"]
  @swift ["Alpha.swift", "Beta.swift", "Gamma.swift"]
  @jni ["thunk.c", "hook.c"]
  @bridges ["io.p.Alpha", "io.p.Beta", "io.p.Gamma"]
  @plist [
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSPhotoLibraryUsageDescription"
  ]
  @workers [W.Alpha, W.Beta, W.Gamma]
  @matches [%{type: "a"}, %{type: "b"}, %{type: "c"}]
  @atoms [:chart, :gauge, :map]
  @namespaces ["a_", "b_", "c_"]

  test "cross_validate flags exactly the cross-plugin collisions (fuzz)" do
    for i <- 1..@iterations do
      manifests = gen_set(i)
      plugins = to_plugins(manifests)
      %{errors: errors} = Validator.cross_validate(plugins)

      for {_gatherer, {:collision, checks}} <- Validator.conflict_surface(),
          {label, extractor} <- checks do
        expected = cross_plugin_dup?(manifests, extractor)
        # Anchored to the exact collision-message shape so one guard's label
        # can't substring-match inside another guard's error text.
        actual = Enum.any?(errors, &(&1 =~ ~r/declare the same #{Regex.escape(label)}: /))

        assert expected == actual,
               "iter #{i}: resource #{inspect(label)} expected collision=#{expected} " <>
                 "but cross_validate reported=#{actual}\nerrors: #{inspect(errors)}\n" <>
                 "manifests: #{inspect(manifests, pretty: true)}"
      end
    end
  end

  test "no silent loss: clean plist merge keeps every key (fuzz)" do
    for i <- 1..@iterations do
      manifests = gen_set(i + 10_000)
      plugins = to_plugins(manifests)
      %{errors: errors} = Validator.cross_validate(plugins)
      plist_collision? = Enum.any?(errors, &(&1 =~ "Info.plist key"))

      merged = Merge.plist_keys(plugins)

      distinct_keys =
        manifests
        |> Enum.flat_map(fn m -> (get_in(m, [:ios, :plist_keys]) || %{}) |> Map.keys() end)
        |> Enum.uniq()

      unless plist_collision? do
        assert map_size(merged) == length(distinct_keys),
               "iter #{i}: plist merge lost a key with NO collision flagged — " <>
                 "merged #{map_size(merged)} vs #{length(distinct_keys)} distinct\n" <>
                 "manifests: #{inspect(manifests, pretty: true)}"
      end
    end
  end

  # ── independent oracle ──────────────────────────────────────────────────────
  # A value is a cross-plugin collision when, after de-duping WITHIN each plugin
  # (so a cross-platform NIF declaring one :module twice counts once), it appears
  # in ≥2 plugins. Re-derived here without cross_validate's collisions/3 helper.
  defp cross_plugin_dup?(manifests, extractor) do
    manifests
    |> Enum.flat_map(fn m -> m |> extractor.() |> Enum.uniq() end)
    |> Enum.frequencies()
    |> Enum.any?(fn {_v, count} -> count > 1 end)
  end

  # ── deterministic generators ────────────────────────────────────────────────
  defp gen_set(seed) do
    :rand.seed(:exsss, {seed, seed * 2 + 1, seed * 3 + 7})
    n = :rand.uniform(5)
    for j <- 1..n, do: gen_manifest(:"p#{j}")
  end

  defp to_plugins(manifests) do
    manifests |> Enum.with_index() |> Enum.map(fn {m, k} -> {"/p#{k}", m} end)
  end

  defp gen_manifest(name) do
    %{name: name, mob_version: "~> 0.6", plugin_spec_version: 2}
    |> maybe(0.6, &put_nifs/1)
    |> maybe(0.4, &put_swift/1)
    |> maybe(0.4, &put_jni/1)
    |> maybe(0.4, &put_bridge/1)
    |> maybe(0.4, &put_plist/1)
    |> maybe(0.4, &put_lifecycle/1)
    |> maybe(0.4, &put_notifications/1)
    |> maybe(0.4, &put_screens/1)
    |> maybe(0.3, &put_ui/1)
    |> maybe(0.3, &put_migrations/1)
  end

  defp maybe(m, p, f), do: if(:rand.uniform() < p, do: f.(m), else: m)
  defp some(pool), do: Enum.take_random(pool, :rand.uniform(2))

  defp put_nifs(m) do
    entries = for mod <- some(@nif_mods), do: %{module: mod, native_dir: "priv/jni"}

    # 30%: inject the legit cross-platform pattern — same :module a second time
    # under a different platform (must NOT be flagged as a collision).
    entries =
      if entries != [] and :rand.uniform() < 0.3 do
        dup = %{module: hd(entries).module, native_dir: "priv/ios", lang: :objc, platform: :ios}
        [dup | entries]
      else
        entries
      end

    Map.put(m, :nifs, entries)
  end

  defp put_swift(m), do: deep_put(m, [:ios, :swift_files], Enum.map(some(@swift), &"priv/#{&1}"))
  defp put_jni(m), do: deep_put(m, [:android, :jni_source], "priv/#{Enum.random(@jni)}")
  defp put_bridge(m), do: deep_put(m, [:android, :bridge_class], Enum.random(@bridges))

  defp put_plist(m) do
    keys = some(@plist) |> Map.new(fn k -> {k, "why #{m.name}"} end)
    deep_put(m, [:ios, :plist_keys], keys)
  end

  defp put_lifecycle(m), do: Map.put(m, :lifecycle, %{supervised: some(@workers)})

  defp put_notifications(m) do
    handlers = for mt <- some(@matches), do: %{match: mt, handler: {H, :h, 1}}
    Map.put(m, :notifications, %{handlers: handlers})
  end

  defp put_screens(m) do
    screens = for r <- some(@routes), do: %{module: Screen, default_route: r}
    Map.put(m, :screens, screens)
  end

  defp put_ui(m) do
    comps = for a <- some(@atoms), do: %{atom: a}
    Map.put(m, :ui_components, comps)
  end

  defp put_migrations(m),
    do:
      Map.put(m, :migrations, %{
        repo_namespace: Enum.random(@namespaces),
        migrations_dir: "priv/m"
      })

  defp deep_put(m, [k1, k2], value) do
    Map.update(m, k1, %{k2 => value}, &Map.put(&1, k2, value))
  end
end

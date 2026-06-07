defmodule Mix.Tasks.Mob.RegenDriverTab do
  use Mix.Task

  alias MobDev.StaticNifs

  @shortdoc "Regenerate priv/generated/driver_tab_*.zig from :static_nifs"

  @moduledoc """
  Regenerates the per-app static-NIF table source files in
  `priv/generated/driver_tab_ios.zig` and `priv/generated/driver_tab_android.zig`.

  These files are linked **before** `libbeam.a` so they override BEAM's empty
  built-in `erts_static_nif_tab[]`. Without them, `load_nif/2` falls back to
  `dlopen`, which is broken on iOS (App Store rejects bundled `.dylibs`) and
  on Android (RTLD_LOCAL hides parent's `enif_*` symbols from children).

      mix mob.regen_driver_tab              # regenerate both platforms (default: Zig)
      mix mob.regen_driver_tab --format c   # emit driver_tab_*.c instead (hand-editable C)
      mix mob.regen_driver_tab --check      # verify on-disk matches manifest, exit non-zero on drift

  ## Format

  Zig is the default as of Phase 6a iter 4 — it uses comptime gates
  instead of `#ifdef` for guarded NIFs (e.g. iOS `sqlite3_nif`
  device-only), and Zig's `export` keyword produces the same C-ABI
  symbols libbeam.a expects. `--format c` is still supported for
  anyone who wants a hand-editable C dispatch table. Both formats
  produce equivalent behavior at link time.

  C NIF authors are unaffected by the default: their `c_src/<name>.c`
  files compile via the usual path, and the Zig dispatch table calls
  their `<name>_nif_init()` function through standard C ABI (`extern
  fn <name>_nif_init() callconv(.c)`).

  ## Where the NIF list comes from

  `MobDev.StaticNifs.default_nifs/0` baked-in defaults are merged with any
  `:static_nifs` set in `mob.exs`:

      config :mob_dev,
        static_nifs: [
          %{module: :my_native, archs: [:all]}
        ]

  See `MobDev.StaticNifs` for the entry schema and arch values.

  ## Why a Mix task and not a build-time generator

  The output is committed to the app's repo so reviewers can see what's in
  the static-link surface. It also lets non-Mob build tools (e.g. xcodebuild
  invoked outside `mix mob.deploy`) pick up the file as plain source. The
  task is fast (deterministic file generation) so re-running it on every
  `mix compile` is cheap.

  ## Drift detection

  `mob.doctor` runs `--check` mode and reports any drift between the
  manifest and the on-disk files. CI can do the same.
  """

  @ios_c_path "priv/generated/driver_tab_ios.c"
  @android_c_path "priv/generated/driver_tab_android.c"
  @ios_zig_path "priv/generated/driver_tab_ios.zig"
  @android_zig_path "priv/generated/driver_tab_android.zig"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean, format: :string])
    format = parse_format(opts[:format])

    # Per-platform: the iOS build has no zig plugin-NIF compile path yet, so a
    # zig plugin NIF (e.g. Android-only mob_bluetooth) must not land in
    # driver_tab_ios or the link fails on an unresolved <module>_nif_init.
    ios_nifs = resolved_nifs(:ios)
    android_nifs = resolved_nifs(:android)

    case validate_all(android_nifs) do
      :ok -> :ok
      {:error, msg} -> Mix.raise(":static_nifs invalid — #{msg}")
    end

    ios_src = StaticNifs.generate(:ios, ios_nifs, format: format) |> IO.iodata_to_binary()

    android_src =
      StaticNifs.generate(:android, android_nifs, format: format) |> IO.iodata_to_binary()

    paths = target_paths(format)

    if opts[:check] do
      check_mode(ios_src, android_src, paths)
    else
      write_mode(ios_src, android_src, paths)
    end
  end

  # Default is :zig as of Phase 6a iter 4 — for projects whose
  # `ios/build.zig` was generated with the addZigObject helper (mob_new
  # post-iter-2). Older projects without that helper fall back to :c
  # because their build.zig's addCObject → addCSourceFile path can't
  # compile a .zig source (Zig 0.17-dev rejects the conflicting
  # -Mroot=./ + positional .zig combination). Pass `--format c`/`--format zig`
  # explicitly to override the auto-detect.
  defp parse_format(nil), do: detect_default_format()
  defp parse_format("zig"), do: :zig
  defp parse_format("c"), do: :c

  defp parse_format(other) do
    Mix.raise("Unknown --format #{inspect(other)}. Supported: zig, c.")
  end

  defp detect_default_format do
    case File.read("ios/build.zig") do
      {:ok, content} ->
        if String.contains?(content, "addZigObject") do
          :zig
        else
          :c
        end

      _ ->
        # No project-side build.zig (rare — e.g. running from a fresh
        # template directory). Default to Zig; if there's no build
        # pipeline yet the file is harmless until one's added.
        :zig
    end
  end

  @doc false
  @spec resolved_nifs() :: [StaticNifs.nif_entry()]
  def resolved_nifs, do: resolved_nifs(:all)

  @doc false
  # `platform` filters the *plugin* NIFs to those the platform's build actually
  # compiles, so the generated table never references a symbol the link can't
  # find. The iOS build compiles only C plugin NIFs (`-Dplugin_c_nifs`); it has
  # no zig plugin-NIF path yet, so zig plugin NIFs (e.g. Android-only
  # mob_bluetooth, whose zig is full of JNI symbols and can't build on iOS) are
  # excluded from driver_tab_ios. Android compiles both, and `:all` (the
  # default, used by mob.doctor / project-NIF classification) keeps everything.
  @spec resolved_nifs(:ios | :android | :all) :: [StaticNifs.nif_entry()]
  def resolved_nifs(platform) do
    # mob.exs isn't auto-imported by Mix.Config — every other task that
    # reads from it goes through Config.Reader.read! directly. Match that
    # pattern here. Application.get_env stays as a secondary source so
    # MIX_CONFIG=... or programmatic Application.put_env still wins for
    # tests that want to bypass the file.
    user =
      MobDev.Config.load_mob_config()
      |> Keyword.get(:static_nifs, Application.get_env(:mob_dev, :static_nifs, []))

    # Activated plugins contribute their NIFs to the static-NIF table. The
    # plugin's native source still has to be compiled into the binary by the
    # build (see android_sources/swift_files); this only adds the table entry.
    plugin_nifs =
      MobDev.Plugin.Merge.nifs(MobDev.Plugin.activated())
      |> reject_uncompiled_plugin_nifs(platform)

    StaticNifs.resolve(user ++ plugin_nifs)
  end

  @doc false
  # Drops plugin NIFs the platform's build won't compile, so the generated table
  # never references an uncompiled <module>_nif_init:
  #   - iOS has no zig plugin-NIF path yet, so `lang: :zig` entries are dropped.
  #   - Android has no Objective-C runtime, so `lang: :objc` entries are dropped
  #     (objc is implicitly Apple-only even without an explicit `platform: :ios`).
  #   - A NIF tagged `platform: :ios | :android` is only compiled on that
  #     platform (a cross-platform plugin ships a separate iOS + Android source
  #     for the same module); the other platform drops it. No `:platform` =
  #     compiled everywhere. `:all` keeps everything.
  # Public for tests.
  @spec reject_uncompiled_plugin_nifs([map()], :ios | :android | :all) :: [map()]
  def reject_uncompiled_plugin_nifs(nifs, :ios) do
    nifs
    |> Enum.reject(&(&1[:lang] == :zig))
    |> Enum.reject(&(&1[:platform] == :android))
  end

  def reject_uncompiled_plugin_nifs(nifs, :android) do
    nifs
    |> Enum.reject(&(&1[:lang] == :objc))
    |> Enum.reject(&(&1[:platform] == :ios))
  end

  def reject_uncompiled_plugin_nifs(nifs, _), do: nifs

  @doc false
  @spec target_paths() :: %{ios: String.t(), android: String.t()}
  def target_paths, do: target_paths(:c)

  @doc false
  @spec target_paths(:c | :zig) :: %{ios: String.t(), android: String.t()}
  def target_paths(:c), do: %{ios: @ios_c_path, android: @android_c_path}
  def target_paths(:zig), do: %{ios: @ios_zig_path, android: @android_zig_path}

  defp validate_all(nifs) do
    Enum.reduce_while(nifs, :ok, fn entry, :ok ->
      case StaticNifs.validate_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "#{inspect(entry)}: #{msg}"}}
      end
    end)
  end

  defp write_mode(ios_src, android_src, %{ios: ios_path, android: android_path}) do
    File.mkdir_p!(Path.dirname(ios_path))
    File.mkdir_p!(Path.dirname(android_path))

    write_if_changed(ios_path, ios_src)
    write_if_changed(android_path, android_src)
  end

  defp write_if_changed(path, new_content) do
    case File.read(path) do
      {:ok, ^new_content} ->
        Mix.shell().info("  ✓ #{path} (unchanged)")

      _ ->
        File.write!(path, new_content)
        Mix.shell().info("  ✓ #{path} (regenerated)")
    end
  end

  defp check_mode(ios_src, android_src, %{ios: ios_path, android: android_path}) do
    drifts =
      [{ios_path, ios_src}, {android_path, android_src}]
      |> Enum.filter(fn {path, expected} ->
        File.read(path) != {:ok, expected}
      end)

    case drifts do
      [] ->
        Mix.shell().info("✓ driver_tab files match :static_nifs")
        :ok

      paths ->
        msg =
          paths
          |> Enum.map(fn {path, _} -> "  - #{path}" end)
          |> Enum.join("\n")

        Mix.raise(
          "driver_tab drift detected — these files don't match :static_nifs:\n#{msg}\n\n" <>
            "Run `mix mob.regen_driver_tab` to fix."
        )
    end
  end
end

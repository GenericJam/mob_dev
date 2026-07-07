defmodule MobDev.Plugin.ConflictSurfaceTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Merge, Validator}

  @base %{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}

  defp two(extra_a, extra_b) do
    [{:a, Map.merge(@base, extra_a)}, {:b, Map.merge(%{@base | name: :b}, extra_b)}]
  end

  defp same(extra), do: two(extra, extra)

  # ── The systematic guarantee ────────────────────────────────────────────────
  describe "completeness — every Merge gatherer is classified" do
    # Every public MobDev.Plugin.Merge function combines N plugins' contributions
    # into one shared space, so each MUST be classified in Validator.conflict_surface/0
    # (as a collision guard, or as namespaced/union/build_time/derived). This test
    # fails the moment a new gatherer is added without classifying its conflict
    # behavior — turning "we hope multiples compose" into "CI proves they do".
    @merge_gatherers Merge.__info__(:functions)
                     |> Enum.map(fn {name, _arity} -> name end)
                     |> Enum.uniq()
                     |> MapSet.new()

    test "no Merge gatherer is missing a conflict-surface classification" do
      classified = Validator.conflict_surface() |> Map.keys() |> MapSet.new()
      missing = MapSet.difference(@merge_gatherers, classified)

      assert MapSet.size(missing) == 0,
             "Merge gatherers with no Validator.conflict_surface/0 entry: " <>
               "#{inspect(MapSet.to_list(missing))}. Classify each — add a {:collision, ...} " <>
               "guard if two plugins can clash on it, else {:namespaced|:union|:build_time|:derived, reason}."
    end

    test "no stale conflict-surface entry without a backing Merge gatherer" do
      classified = Validator.conflict_surface() |> Map.keys() |> MapSet.new()
      stale = MapSet.difference(classified, @merge_gatherers)

      assert MapSet.size(stale) == 0,
             "conflict_surface/0 classifies non-existent Merge gatherers: #{inspect(MapSet.to_list(stale))}"
    end

    test "every :collision entry carries at least one {label, extractor}" do
      for {gatherer, {:collision, checks}} <- Validator.conflict_surface() do
        assert is_list(checks) and checks != [], "#{gatherer} :collision has no checks"

        for {label, extractor} <- checks do
          assert is_binary(label) and byte_size(label) > 0, "#{gatherer} has an empty label"
          assert is_function(extractor, 1)
        end
      end
    end
  end

  # ── Each guard actually catches a clash ─────────────────────────────────────
  describe "collision detection (two plugins, same value → build error)" do
    test "duplicate NIF module across plugins" do
      plugins = same(%{nifs: [%{module: :dup_nif, native_dir: "priv/jni"}]})
      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "NIF module"))
    end

    test "duplicate iOS Swift source basename across plugins" do
      plugins =
        two(
          %{ios: %{swift_files: ["priv/a/Shared.swift"]}},
          %{ios: %{swift_files: ["priv/b/Shared.swift"]}}
        )

      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "Swift source basename"))
    end

    test "duplicate Android JNI source basename across plugins" do
      plugins =
        two(%{android: %{jni_source: "priv/a/thunk.c"}}, %{
          android: %{jni_source: "priv/b/thunk.c"}
        })

      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "JNI source basename"))
    end

    test "duplicate Android bridge class across plugins" do
      plugins = same(%{android: %{bridge_class: "io.mob.x.Bridge"}})
      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "bridge class"))
    end

    test "duplicate Info.plist key across plugins (different values)" do
      plugins =
        two(
          %{ios: %{plist_keys: %{"NSCameraUsageDescription" => "A wants camera"}}},
          %{ios: %{plist_keys: %{"NSCameraUsageDescription" => "B wants camera"}}}
        )

      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "Info.plist key"))
    end

    test "duplicate AndroidManifest component name across plugins" do
      plugins =
        same(%{
          android: %{
            manifest_application_snippets: [
              ~s(<service android:name="io.mob.x.Svc" android:exported="true"/>)
            ]
          }
        })

      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "AndroidManifest component"))
    end

    test "duplicate Android res destination across plugins" do
      plugins =
        two(
          %{android: %{res_files: ["priv/a/res/xml/svc.xml"]}},
          %{android: %{res_files: ["priv/b/res/xml/svc.xml"]}}
        )

      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "Android res destination"))
    end

    test "duplicate supervised worker across plugins" do
      plugins = same(%{lifecycle: %{supervised: [MyApp.Worker]}})
      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "supervised worker"))
    end

    test "duplicate notification match across plugins" do
      handler = {Some.Mod, :handle, 1}

      plugins =
        same(%{notifications: %{handlers: [%{match: %{type: "ping"}, handler: handler}]}})

      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "notification match"))
    end
  end

  describe "no false positives (distinct values compose cleanly)" do
    test "distinct NIF modules, swift basenames, plist keys, workers, matches" do
      plugins =
        two(
          %{
            nifs: [%{module: :a_nif, native_dir: "priv/jni"}],
            ios: %{
              swift_files: ["priv/A.swift"],
              plist_keys: %{"NSCameraUsageDescription" => "a"}
            },
            android: %{jni_source: "priv/a.c", bridge_class: "io.a.B"},
            lifecycle: %{supervised: [A.Worker]},
            notifications: %{handlers: [%{match: %{type: "a"}, handler: {M, :f, 1}}]}
          },
          %{
            nifs: [%{module: :b_nif, native_dir: "priv/jni"}],
            ios: %{
              swift_files: ["priv/B.swift"],
              plist_keys: %{"NSMicrophoneUsageDescription" => "b"}
            },
            android: %{jni_source: "priv/b.c", bridge_class: "io.b.B"},
            lifecycle: %{supervised: [B.Worker]},
            notifications: %{handlers: [%{match: %{type: "b"}, handler: {M, :f, 1}}]}
          }
        )

      assert %{errors: []} = Validator.cross_validate(plugins)
    end

    test "tier-0 (nil) manifests contribute nothing" do
      plugins = [{:a, Map.merge(@base, %{nifs: [%{module: :x_nif}]})}, {:zero, nil}]
      assert %{errors: []} = Validator.cross_validate(plugins)
    end

    test "a cross-platform NIF (one plugin, same :module for iOS + Android) is NOT a collision" do
      # The legit pattern (e.g. mob_location): one plugin ships an iOS objc NIF and
      # an Android zig NIF for the same module. Distinct platform entries, one
      # plugin → must not be flagged as a cross-plugin clash.
      plugins = [
        {:loc,
         Map.merge(@base, %{
           nifs: [
             %{module: :loc_nif, native_dir: "priv/ios", lang: :objc, platform: :ios},
             %{module: :loc_nif, native_dir: "priv/jni", lang: :zig, platform: :android}
           ]
         })}
      ]

      assert %{errors: []} = Validator.cross_validate(plugins)
    end
  end
end

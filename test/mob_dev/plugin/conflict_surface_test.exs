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
          %{ios: %{plist_keys: %{"UIStatusBarStyle" => "UIStatusBarStyleLightContent"}}},
          %{ios: %{plist_keys: %{UIStatusBarStyle: "UIStatusBarStyleDarkContent"}}}
        )

      assert %{errors: [err]} = Validator.cross_validate(plugins)
      assert err =~ ~s[Info.plist key (ios.plist_keys): "UIStatusBarStyle"]
    end

    test "a usage description several plugins declare as strings combines instead of colliding" do
      # MOB-421: mob_bluetooth and mob_midi each need Bluetooth for their own
      # reason; the prompt has to explain both, and neither reason is lost.
      plugins = [
        {"/deps/mob_bluetooth",
         %{@base | name: :mob_bluetooth}
         |> Map.put(:ios, %{
           plist_keys: %{NSBluetoothAlwaysUsageDescription: "Discover nearby devices."}
         })},
        {"/deps/mob_midi",
         %{@base | name: :mob_midi}
         |> Map.put(:ios, %{
           plist_keys: %{"NSBluetoothAlwaysUsageDescription" => " Connect to BLE MIDI devices "}
         })},
        {"/deps/mob_beacon",
         %{@base | name: :mob_beacon}
         |> Map.put(:ios, %{
           plist_keys: %{NSBluetoothAlwaysUsageDescription: "Discover nearby devices."}
         })}
      ]

      assert Validator.cross_validate(plugins) == %{errors: [], warnings: []}

      assert Merge.plist_keys(plugins) == %{
               "NSBluetoothAlwaysUsageDescription" =>
                 "Discover nearby devices. Connect to BLE MIDI devices."
             }

      assert Validator.combined_usage_descriptions(plugins) == [
               {"NSBluetoothAlwaysUsageDescription", ["mob_bluetooth", "mob_midi", "mob_beacon"]}
             ]
    end

    test "the same usage description from every plugin is kept verbatim and not reported as combined" do
      plugins = same(%{ios: %{plist_keys: %{NSCameraUsageDescription: "Scan codes"}}})

      assert Validator.cross_validate(plugins).errors == []
      assert Merge.plist_keys(plugins) == %{"NSCameraUsageDescription" => "Scan codes"}
      assert Validator.combined_usage_descriptions(plugins) == []
    end

    test "a usage description some plugin declares as a non-string still collides" do
      plugins =
        two(
          %{ios: %{plist_keys: %{NSCameraUsageDescription: "Scan codes"}}},
          %{ios: %{plist_keys: %{NSCameraUsageDescription: true}}}
        )

      assert %{errors: [err]} = Validator.cross_validate(plugins)
      assert err =~ "NSCameraUsageDescription"
      assert Validator.combined_usage_descriptions(plugins) == []
    end

    test "a duplicate Info.plist key the host's own Info.plist sets is no conflict" do
      plugins =
        two(
          %{ios: %{plist_keys: %{UIStatusBarStyle: "A", UIRequiresFullScreen: true}}},
          %{ios: %{plist_keys: %{UIStatusBarStyle: "B", UIRequiresFullScreen: false}}}
        )

      assert %{errors: [err]} =
               Validator.cross_validate(plugins, host_plist_keys: ["UIStatusBarStyle"])

      assert err =~ "UIRequiresFullScreen"
    end

    test "a host-set Info.plist key any plugin declares as an array still conflicts" do
      # Plugin arrays are merged into the host's array, and between plugins the
      # later value wins, so the other plugin's array would be silently lost.
      array = %{ios: %{plist_keys: %{"UIBackgroundModes" => ["bluetooth-central"]}}}

      for other <- [["location"], "scalar"], {a, b} <- [{:array, :other}, {:other, :array}] do
        pick = %{array: array, other: %{ios: %{plist_keys: %{"UIBackgroundModes" => other}}}}

        assert %{errors: [err]} =
                 Validator.cross_validate(two(pick[a], pick[b]),
                   host_plist_keys: ["UIBackgroundModes"]
                 )

        assert err =~ "UIBackgroundModes"
      end
    end

    @tag :tmp_dir
    test "host_plist_keys/1 lists the root dictionary's keys only", %{tmp_dir: dir} do
      path = Path.join(dir, "Info.plist")

      File.write!(path, """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0">
      <dict>
          <key>NSCameraUsageDescription</key>
          <string>camera</string>
          <key>UIApplicationSceneManifest</key>
          <dict>
              <key>UISceneConfigurations</key>
              <dict><key>Inner</key><string>x</string></dict>
          </dict>
          <!-- <key>NSMicrophoneUsageDescription</key><string>off</string> -->
          <key>Real</key>
          <string><![CDATA[literal <key>Fake</key> text]]></string>
          <key>NFCReaderUsageDescription</key>
          <string>nfc</string>
      </dict>
      </plist>
      """)

      assert Enum.sort(Validator.host_plist_keys(path)) ==
               ~w(NFCReaderUsageDescription NSCameraUsageDescription Real UIApplicationSceneManifest)

      assert Validator.host_plist_keys(Path.join(dir, "missing.plist")) == []
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

    test "two plugins both declaring default_font is a conflict, even with different fonts" do
      # Deliberately DIFFERENT fonts — the point of the sentinel-based check is
      # that this still collides, because only one plugin's default can win.
      plugins =
        two(
          %{
            assets: %{fonts: ["priv/a.ttf"]},
            default_font: %{family: "A", file: "priv/a.ttf"}
          },
          %{
            assets: %{fonts: ["priv/b.ttf"]},
            default_font: %{family: "B", file: "priv/b.ttf"}
          }
        )

      assert %{errors: errs} = Validator.cross_validate(plugins)
      assert Enum.any?(errs, &(&1 =~ "plugin default_font declaration"))
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

    test "a single plugin declaring default_font is NOT a conflict" do
      plugins = [
        {:a,
         Map.merge(@base, %{
           assets: %{fonts: ["priv/a.ttf"]},
           default_font: %{family: "A", file: "priv/a.ttf"}
         })}
      ]

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

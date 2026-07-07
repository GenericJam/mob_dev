defmodule MobDev.Plugin.MergeTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Merge

  defp base(extra),
    do: Map.merge(%{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}, extra)

  describe "nifs/1" do
    test "resolves native_dir to an absolute path under the plugin dir" do
      plugins = [{"/abs/plug", base(%{nifs: [%{module: P.Nif, native_dir: "priv/native/jni"}]})}]
      assert [%{module: P.Nif, native_dir: "/abs/plug/priv/native/jni"}] = Merge.nifs(plugins)
    end

    test "combines nifs across plugins and ignores tier-0 (nil) manifests" do
      plugins = [
        {"/a", base(%{nifs: [%{module: A, native_dir: "priv/jni"}]})},
        {"/palette", nil},
        {"/b", base(%{nifs: [%{module: B, native_dir: "priv/jni"}]})}
      ]

      assert [%{module: A}, %{module: B}] = Merge.nifs(plugins)
    end

    test "leaves a nif without native_dir untouched" do
      plugins = [{"/a", base(%{nifs: [%{module: A}]})}]
      assert [%{module: A}] = Merge.nifs(plugins)
    end
  end

  describe "android_permissions/1 + gradle_deps/1 + ios_frameworks/1" do
    test "uniquifies across plugins" do
      plugins = [
        {"/a",
         base(%{
           android: %{permissions: ["P.CAMERA"], gradle_deps: ["g:1"]},
           ios: %{frameworks: ["CoreHaptics"]}
         })},
        {"/b",
         base(%{
           android: %{permissions: ["P.CAMERA", "P.MIC"], gradle_deps: ["g:1", "g:2"]},
           ios: %{frameworks: ["CoreHaptics", "AVFoundation"]}
         })}
      ]

      assert Merge.android_permissions(plugins) == ["P.CAMERA", "P.MIC"]
      assert Merge.gradle_deps(plugins) == ["g:1", "g:2"]
      assert Merge.ios_frameworks(plugins) == ["CoreHaptics", "AVFoundation"]
    end

    test "empty when no plugins declare them" do
      assert Merge.android_permissions([{"/a", base(%{})}]) == []
    end
  end

  describe "swift_files/1 + android_sources/1" do
    test "swift_files are absolute, per plugin" do
      plugins = [
        {"/a", base(%{ios: %{swift_files: ["priv/ios/A.swift"]}})},
        {"/b", base(%{ios: %{swift_files: ["priv/ios/B.swift", "priv/ios/C.swift"]}})}
      ]

      assert Merge.swift_files(plugins) ==
               ["/a/priv/ios/A.swift", "/b/priv/ios/B.swift", "/b/priv/ios/C.swift"]
    end

    test "android_sources gathers bridge, jni, and nif dirs, absolute + unique" do
      plugins = [
        {"/a",
         base(%{
           android: %{bridge_kt: "priv/a/Bridge.kt", jni_source: "priv/a/x.c"},
           nifs: [%{module: A, native_dir: "priv/a/jni"}]
         })}
      ]

      sources = Merge.android_sources(plugins)
      assert "/a/priv/a/Bridge.kt" in sources
      assert "/a/priv/a/x.c" in sources
      assert "/a/priv/a/jni" in sources
    end
  end

  describe "nif_sources/1" do
    test "computes <dir>/<native_dir>/<module>.c for each NIF" do
      plugins = [
        {"/a",
         base(%{
           nifs: [
             %{module: :foo_nif, native_dir: "priv/native/jni"},
             %{module: :bar_nif, native_dir: "priv/native/jni"}
           ]
         })}
      ]

      assert Merge.nif_sources(plugins) ==
               ["/a/priv/native/jni/foo_nif.c", "/a/priv/native/jni/bar_nif.c"]
    end

    test "defaults native_dir to priv/native/jni when omitted" do
      plugins = [{"/a", base(%{nifs: [%{module: :foo_nif}]})}]
      assert Merge.nif_sources(plugins) == ["/a/priv/native/jni/foo_nif.c"]
    end

    test "ignores tier-0 (nil) manifests and entries without a :module atom" do
      plugins = [
        {"/a", nil},
        {"/b", base(%{nifs: [%{native_dir: "priv/jni"}]})}
      ]

      assert Merge.nif_sources(plugins) == []
    end

    test "treats lang: :c the same as an absent :lang" do
      plugins = [{"/a", base(%{nifs: [%{module: :foo_nif, lang: :c}]})}]
      assert Merge.nif_sources(plugins) == ["/a/priv/native/jni/foo_nif.c"]
    end

    test "excludes lang: :zig NIFs (they belong to zig_nif_sources/1)" do
      plugins = [{"/a", base(%{nifs: [%{module: :foo_nif, lang: :zig}]})}]
      assert Merge.nif_sources(plugins) == []
    end

    test "excludes lang: :cpp_archive NIFs (they belong to static_archives/2)" do
      plugins = [
        {"/a",
         base(%{nifs: [%{module: :x, lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "x"}]})}
      ]

      assert Merge.nif_sources(plugins) == []
      assert Merge.zig_nif_sources(plugins) == []
    end
  end

  describe "static_archives/2" do
    test "resolves sources to absolute and tags the plugin" do
      plugins = [
        {"/abs/plug",
         base(%{
           nifs: [
             %{
               module: :nx_eigen_nif,
               lang: :cpp_archive,
               sources: ["c_src/nx_eigen_nif.cpp", "c_src/fft.cpp"],
               nm_symbol: "nx_eigen_nif_init"
             }
           ]
         })}
      ]

      assert [spec] = Merge.static_archives(plugins)
      assert spec.module == :nx_eigen_nif
      assert spec.sources == ["/abs/plug/c_src/nx_eigen_nif.cpp", "/abs/plug/c_src/fft.cpp"]
      assert spec.nm_symbol == "nx_eigen_nif_init"
      assert spec.plugin == :p
    end

    test "resolves dep-sourced .cpp (NxEigen's NIF lives in the nx_eigen dep)" do
      plugins = [
        {"/plug",
         base(%{
           nifs: [
             %{
               module: :nx_eigen_nif,
               lang: :cpp_archive,
               sources: [
                 {:dep, :nx_eigen, "c_src/nx_eigen_nif.cpp"},
                 "c_src/nx_eigen_fft_eigen.cpp"
               ],
               nm_symbol: "nx_eigen_nif_init"
             }
           ]
         })}
      ]

      assert [spec] = Merge.static_archives(plugins)
      # dep token passes through; plugin-relative source resolves to absolute.
      assert spec.sources == [
               {:dep, :nx_eigen, "c_src/nx_eigen_nif.cpp"},
               "/plug/c_src/nx_eigen_fft_eigen.cpp"
             ]
    end

    test "resolves plugin-relative includes to absolute, passes :dep tokens through" do
      plugins = [
        {"/plug",
         base(%{
           nifs: [
             %{
               module: :x,
               lang: :cpp_archive,
               sources: ["a.cpp"],
               includes: ["c_src", {:dep, :nx_eigen, "eigen-3.4.0"}, {:dep, :fine, "c_include"}],
               nm_symbol: "x_init"
             }
           ]
         })}
      ]

      assert [spec] = Merge.static_archives(plugins)

      assert spec.includes == [
               "/plug/c_src",
               {:dep, :nx_eigen, "eigen-3.4.0"},
               {:dep, :fine, "c_include"}
             ]
    end

    test "ignores non-cpp_archive NIFs and tier-0 manifests" do
      plugins = [
        {"/a", base(%{nifs: [%{module: :c_nif}, %{module: :z, lang: :zig}]})},
        {"/b", nil}
      ]

      assert Merge.static_archives(plugins) == []
    end

    test "filters by platform (entry tagged :ios excluded from android build)" do
      plugins = [
        {"/a",
         base(%{
           nifs: [
             %{
               module: :ios_only,
               lang: :cpp_archive,
               sources: ["a.cpp"],
               nm_symbol: "a",
               platform: :ios
             },
             %{module: :both, lang: :cpp_archive, sources: ["b.cpp"], nm_symbol: "b"}
           ]
         })}
      ]

      assert Enum.map(Merge.static_archives(plugins, :android), & &1.module) == [:both]
      assert Enum.map(Merge.static_archives(plugins, :ios), & &1.module) == [:ios_only, :both]
      assert length(Merge.static_archives(plugins, :all)) == 2
    end

    test "carries base + per-platform cxxflags through" do
      plugins = [
        {"/a",
         base(%{
           nifs: [
             %{
               module: :x,
               lang: :cpp_archive,
               sources: ["a.cpp"],
               nm_symbol: "x",
               cxxflags: ["-std=c++17"],
               cxxflags_android: ["-mbranch-protection=standard"],
               cxxflags_ios: []
             }
           ]
         })}
      ]

      assert [spec] = Merge.static_archives(plugins)
      assert spec.cxxflags == ["-std=c++17"]
      assert spec.cxxflags_android == ["-mbranch-protection=standard"]
      assert spec.cxxflags_ios == []
    end
  end

  describe "zig_nif_sources/1" do
    test "computes <dir>/<native_dir>/<module>.zig for lang: :zig NIFs" do
      plugins = [
        {"/a",
         base(%{
           nifs: [%{module: :mob_bluetooth_nif, native_dir: "priv/native/jni", lang: :zig}]
         })}
      ]

      assert Merge.zig_nif_sources(plugins) == ["/a/priv/native/jni/mob_bluetooth_nif.zig"]
    end

    test "defaults native_dir to priv/native/jni when omitted" do
      plugins = [{"/a", base(%{nifs: [%{module: :foo_nif, lang: :zig}]})}]
      assert Merge.zig_nif_sources(plugins) == ["/a/priv/native/jni/foo_nif.zig"]
    end

    test "excludes C NIFs (absent :lang or lang: :c)" do
      plugins = [
        {"/a", base(%{nifs: [%{module: :c_default_nif}, %{module: :c_explicit_nif, lang: :c}]})}
      ]

      assert Merge.zig_nif_sources(plugins) == []
    end

    test "a mixed manifest splits cleanly between the C and zig source lists" do
      plugins = [
        {"/a",
         base(%{
           nifs: [
             %{module: :c_nif},
             %{module: :z_nif, lang: :zig}
           ]
         })}
      ]

      assert Merge.nif_sources(plugins) == ["/a/priv/native/jni/c_nif.c"]
      assert Merge.zig_nif_sources(plugins) == ["/a/priv/native/jni/z_nif.zig"]
    end
  end

  describe "per-platform NIF source filtering" do
    # A cross-platform plugin ships a separate iOS + Android source for the same
    # module; each platform compiles only its own (the other may reference
    # platform-only symbols). No :platform = compiled everywhere.
    setup do
      plugins = [
        {"/loc",
         base(%{
           nifs: [
             %{module: :mob_location_nif, native_dir: "priv/native/ios", platform: :ios},
             %{
               module: :mob_location_nif,
               native_dir: "priv/native/jni",
               lang: :zig,
               platform: :android
             },
             %{module: :shared_nif}
           ]
         })}
      ]

      %{plugins: plugins}
    end

    test "iOS C sources include ios-tagged + untagged, exclude android-tagged", %{plugins: p} do
      assert Merge.nif_sources(p, :ios) == [
               "/loc/priv/native/ios/mob_location_nif.c",
               "/loc/priv/native/jni/shared_nif.c"
             ]
    end

    test "Android C sources exclude ios-tagged (the android one is zig)", %{plugins: p} do
      assert Merge.nif_sources(p, :android) == ["/loc/priv/native/jni/shared_nif.c"]
    end

    test "Android zig sources include android-tagged zig only", %{plugins: p} do
      assert Merge.zig_nif_sources(p, :android) == ["/loc/priv/native/jni/mob_location_nif.zig"]
    end

    test "iOS zig sources exclude android-tagged", %{plugins: p} do
      assert Merge.zig_nif_sources(p, :ios) == []
    end

    test ":all (arity-1) keeps every entry", %{plugins: p} do
      assert length(Merge.nif_sources(p)) == 2
      assert length(Merge.zig_nif_sources(p)) == 1
    end

    test "lang: :objc routes through the C path with a .m extension" do
      plugins = [
        {"/loc",
         base(%{
           nifs: [
             %{
               module: :mob_location_nif,
               native_dir: "priv/native/ios",
               lang: :objc,
               platform: :ios
             }
           ]
         })}
      ]

      assert Merge.nif_sources(plugins, :ios) == ["/loc/priv/native/ios/mob_location_nif.m"]
      # objc is C-family, not a zig source.
      assert Merge.zig_nif_sources(plugins, :ios) == []
    end

    test "lang: :objc WITHOUT an explicit platform is still excluded from the Android build" do
      # objc is implicitly Apple-only — it must never reach the Android build args
      # even when the author omits `platform: :ios`.
      plugins = [
        {"/p", base(%{nifs: [%{module: :perm_nif, native_dir: "priv/ios", lang: :objc}]})}
      ]

      assert Merge.nif_sources(plugins, :android) == []
      assert Merge.nif_sources(plugins, :ios) == ["/p/priv/ios/perm_nif.m"]
      # :all (listing, not building) keeps it.
      assert Merge.nif_sources(plugins) == ["/p/priv/ios/perm_nif.m"]
    end
  end

  describe "jni_sources/1 + bridge_kt_sources/1 + bridge_classes/1" do
    test "jni_sources resolves android.jni_source to absolute paths" do
      plugins = [
        {"/a", base(%{android: %{jni_source: "priv/native/jni/mob_bluetooth_jni.c"}})},
        {"/b", base(%{android: %{}})}
      ]

      assert Merge.jni_sources(plugins) == ["/a/priv/native/jni/mob_bluetooth_jni.c"]
    end

    test "bridge_kt_sources resolves android.bridge_kt to absolute paths" do
      plugins = [
        {"/a", base(%{android: %{bridge_kt: "priv/native/android/MobBluetoothBridge.kt"}})}
      ]

      assert Merge.bridge_kt_sources(plugins) ==
               ["/a/priv/native/android/MobBluetoothBridge.kt"]
    end

    test "bridge_classes collects the FQNs to register at startup" do
      plugins = [
        {"/a", base(%{android: %{bridge_class: "io.mob.bluetooth.MobBluetoothBridge"}})},
        {"/b", base(%{android: %{}})},
        {"/c", nil}
      ]

      assert Merge.bridge_classes(plugins) == ["io.mob.bluetooth.MobBluetoothBridge"]
    end

    test "all three ignore tier-0 (nil) manifests and absent android maps" do
      plugins = [{"/a", nil}, {"/b", base(%{})}]
      assert Merge.jni_sources(plugins) == []
      assert Merge.bridge_kt_sources(plugins) == []
      assert Merge.bridge_classes(plugins) == []
    end
  end

  describe "plist_keys/1 + ui_components/1" do
    test "plist_keys merge across plugins" do
      plugins = [
        {"/a", base(%{ios: %{plist_keys: %{"K1" => "a"}}})},
        {"/b", base(%{ios: %{plist_keys: %{"K2" => "b"}}})}
      ]

      assert Merge.plist_keys(plugins) == %{"K1" => "a", "K2" => "b"}
    end

    test "ui_components combine across plugins" do
      plugins = [
        {"/a", base(%{ui_components: [%{atom: :chart}]})},
        {"/b", base(%{ui_components: [%{atom: :gauge}]})}
      ]

      assert [%{atom: :chart}, %{atom: :gauge}] = Merge.ui_components(plugins)
    end
  end

  describe "tier-3/4 runtime-manifest gatherers" do
    test "screens/1 tags each entry with its plugin name" do
      plugins = [
        {"/a", base(%{name: :a, screens: [%{module: A.List, default_route: "/a"}]})},
        {"/pal", nil},
        {"/b", base(%{name: :b, screens: [%{module: B.List, default_route: "/b"}]})}
      ]

      assert [
               %{module: A.List, default_route: "/a", plugin: :a},
               %{module: B.List, default_route: "/b", plugin: :b}
             ] = Merge.screens(plugins)
    end

    test "migrations/1 resolves migrations_dir to absolute + carries namespace" do
      plugins = [
        {"/abs/p",
         base(%{
           name: :p,
           migrations: %{repo_namespace: "p_", migrations_dir: "priv/repo/migrations"}
         })}
      ]

      assert [%{plugin: :p, repo_namespace: "p_", migrations_dir: "/abs/p/priv/repo/migrations"}] =
               Merge.migrations(plugins)
    end

    test "assets/1 resolves font/image paths to absolute, defaulting missing lists to []" do
      plugins = [
        {"/abs/p", base(%{name: :p, assets: %{fonts: ["priv/a.ttf"]}})}
      ]

      assert [%{plugin: :p, fonts: ["/abs/p/priv/a.ttf"], images: []}] = Merge.assets(plugins)
    end

    test "migrations/1 skips a :migrations map missing a string :migrations_dir (no crash)" do
      # `activated/0` feeds Merge unvalidated manifests; a malformed :migrations
      # (no :migrations_dir) must not crash with an opaque Path.join error.
      plugins = [{"/abs/p", base(%{name: :p, migrations: %{repo_namespace: "p_"}})}]
      assert Merge.migrations(plugins) == []

      plugins = [
        {"/abs/p", base(%{name: :p, migrations: %{repo_namespace: "p_", migrations_dir: 123}})}
      ]

      assert Merge.migrations(plugins) == []
    end

    test "assets/1 treats a non-list :fonts/:images as empty (no crash)" do
      plugins = [{"/abs/p", base(%{name: :p, assets: %{fonts: "single.ttf", images: 0}})}]
      assert [%{plugin: :p, fonts: [], images: []}] = Merge.assets(plugins)
    end

    test "lifecycle/1 and settings/1 tag with plugin name" do
      lc = %{on_start: {P, :start, []}, supervised: [P.Worker]}
      settings = %{schema: [%{key: :x, type: :boolean, default: true}], editor_screen: P.Edit}
      plugins = [{"/p", base(%{name: :p, lifecycle: lc, settings: settings})}]

      assert [%{plugin: :p, on_start: {P, :start, []}}] = Merge.lifecycle(plugins)

      assert [%{plugin: :p, schema: [%{key: :x}], editor_screen: P.Edit}] =
               Merge.settings(plugins)
    end

    test "notification_handlers/1 flattens in plugin-then-declaration order" do
      plugins = [
        {"/a",
         base(%{
           name: :a,
           notifications: %{
             handlers: [
               %{match: %{type: "x"}, handler: {A, :hx, 1}},
               %{match: %{type: "y"}, handler: {A, :hy, 1}}
             ]
           }
         })},
        {"/b",
         base(%{
           name: :b,
           notifications: %{handlers: [%{match: %{type: "z"}, handler: {B, :hz, 1}}]}
         })}
      ]

      assert [
               %{plugin: :a, handler: {A, :hx, 1}},
               %{plugin: :a, handler: {A, :hy, 1}},
               %{plugin: :b, handler: {B, :hz, 1}}
             ] = Merge.notification_handlers(plugins)
    end

    test "host_requirements/1 tags each obligation with its plugin, skipping malformed" do
      plugins = [
        {"/a", base(%{name: :a, host_requirements: ["add the <service> fragment", :oops]})},
        {"/b", base(%{name: :b})},
        {"/c", base(%{name: :c, host_requirements: ["declare a FileProvider"]})}
      ]

      assert [
               %{plugin: :a, requirement: "add the <service> fragment"},
               %{plugin: :c, requirement: "declare a FileProvider"}
             ] = Merge.host_requirements(plugins)
    end
  end

  describe "android_manifest_snippets/1" do
    test "collects <application> snippets across plugins, tagged with the plugin" do
      plugins = [
        {"/a", base(%{name: :a, android: %{manifest_application_snippets: ["<service a/>"]}})},
        {"/z", nil},
        {"/b",
         base(%{
           name: :b,
           android: %{manifest_application_snippets: ["<receiver b/>", "<provider b/>"]}
         })}
      ]

      assert [
               %{plugin: :a, snippet: "<service a/>"},
               %{plugin: :b, snippet: "<receiver b/>"},
               %{plugin: :b, snippet: "<provider b/>"}
             ] = Merge.android_manifest_snippets(plugins)
    end

    test "absent / malformed snippets contribute nothing" do
      plugins = [
        {"/a", base(%{name: :a})},
        {"/b", base(%{name: :b, android: %{manifest_application_snippets: [:oops]}})}
      ]

      assert Merge.android_manifest_snippets(plugins) == []
    end
  end

  describe "android_res_files/1" do
    test "resolves src absolutely and derives the res/<type>/<file> dest" do
      plugins = [
        {"/plug",
         base(%{
           name: :plug,
           android: %{res_files: ["priv/native/android/res/xml/foo_apduservice.xml"]}
         })}
      ]

      assert [
               %{
                 plugin: :plug,
                 src: "/plug/priv/native/android/res/xml/foo_apduservice.xml",
                 dest: "res/xml/foo_apduservice.xml"
               }
             ] = Merge.android_res_files(plugins)
    end

    test "uses the LAST res segment when the path has more than one" do
      plugins = [{"/p", base(%{android: %{res_files: ["res/drawable/res/icon.xml"]}})}]
      assert [%{dest: "res/icon.xml"}] = Merge.android_res_files(plugins)
    end

    test "combines across plugins and ignores tier-0 manifests" do
      plugins = [
        {"/a", base(%{name: :a, android: %{res_files: ["x/res/values/strings.xml"]}})},
        {"/z", nil},
        {"/b", base(%{name: :b, android: %{res_files: ["y/res/xml/svc.xml"]}})}
      ]

      assert [
               %{plugin: :a, dest: "res/values/strings.xml"},
               %{plugin: :b, dest: "res/xml/svc.xml"}
             ] = Merge.android_res_files(plugins)
    end
  end
end

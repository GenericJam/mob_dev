defmodule MobDev.Plugin.ValidatorTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Validator

  @base %{name: :mob_demo, mob_version: "~> 0.6", plugin_spec_version: 1}

  describe "referenced_paths/1" do
    test "nil manifest has no paths" do
      assert Validator.referenced_paths(nil) == []
    end

    test "collects nif dirs, android bridge/jni, and ios swift files" do
      m =
        Map.merge(@base, %{
          nifs: [%{module: X, native_dir: "priv/native/jni"}],
          android: %{bridge_kt: "priv/a/B.kt", jni_source: "priv/a/c.c"},
          ios: %{swift_files: ["priv/i/D.swift", "priv/i/E.swift"]}
        })

      paths = Validator.referenced_paths(m)
      assert "priv/native/jni" in paths
      assert "priv/a/B.kt" in paths
      assert "priv/a/c.c" in paths
      assert "priv/i/D.swift" in paths
      assert "priv/i/E.swift" in paths
    end
  end

  describe "validate_plugin/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_validator_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "a minimal valid manifest with no paths passes", %{dir: dir} do
      assert %{errors: [], warnings: []} = Validator.validate_plugin(@base, dir, "0.6.20")
    end

    test "errors when a declared path is missing", %{dir: dir} do
      m = Map.put(@base, :android, %{jni_source: "priv/native/missing.c"})
      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "does not exist"))
    end

    test "passes when the declared path exists", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native"))
      File.write!(Path.join(dir, "priv/native/x.c"), "// stub")
      m = Map.put(@base, :android, %{jni_source: "priv/native/x.c"})
      assert %{errors: []} = Validator.validate_plugin(m, dir, "0.6.20")
    end

    test "errors when installed mob does not satisfy mob_version", %{dir: dir} do
      m = %{@base | mob_version: "~> 0.7"}
      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "does not satisfy"))
    end

    test "skips the mob_version check when installed version is unknown", %{dir: dir} do
      m = %{@base | mob_version: "~> 0.7"}
      assert %{errors: []} = Validator.validate_plugin(m, dir, nil)
    end

    test "propagates structural errors", %{dir: dir} do
      assert %{errors: errs} = Validator.validate_plugin(Map.delete(@base, :name), dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ ":name"))
    end

    test "warns on a single-platform component", %{dir: dir} do
      m =
        Map.put(@base, :ui_components, [%{tag: "Chart", atom: :chart, ios: %{view_module: "X"}}])

      assert %{warnings: warns} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(warns, &(&1 =~ "only one platform"))
    end

    test "does not warn when a component declares both platforms", %{dir: dir} do
      m =
        Map.put(@base, :ui_components, [
          %{tag: "Chart", atom: :chart, ios: %{view_module: "X"}, android: %{composable: "Y"}}
        ])

      assert %{warnings: []} = Validator.validate_plugin(m, dir, "0.6.20")
    end

    test "warns when permissions are declared", %{dir: dir} do
      m = Map.put(@base, :android, %{permissions: ["android.permission.CAMERA"]})
      assert %{warnings: warns} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(warns, &(&1 =~ "permissions"))
    end

    test "warns when plist_keys are declared", %{dir: dir} do
      m = Map.put(@base, :ios, %{plist_keys: %{"NSCameraUsageDescription" => "why"}})
      assert %{warnings: warns} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(warns, &(&1 =~ "plist_keys"))
    end

    test "accepts a C-token nif :module atom", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))

      m =
        Map.put(@base, :nifs, [
          %{module: :mob_bluetooth_nif, native_dir: "priv/native/jni"}
        ])

      assert %{errors: []} = Validator.validate_plugin(m, dir, "0.6.20")
    end

    test "rejects an Elixir module as nif :module", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))

      m =
        Map.put(@base, :nifs, [
          %{module: MyApp.Foo, native_dir: "priv/native/jni"}
        ])

      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "C-token"))
      assert Enum.any?(errs, &(&1 =~ "MyApp.Foo"))
      assert Enum.any?(errs, &(&1 =~ "ERL_NIF_INIT"))
    end

    test "rejects an uppercase-only atom as nif :module", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))

      m =
        Map.put(@base, :nifs, [
          %{module: :ALLCAPS, native_dir: "priv/native/jni"}
        ])

      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "C-token"))
      assert Enum.any?(errs, &(&1 =~ "ALLCAPS"))
    end

    test "rejects an atom starting with a digit as nif :module", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))

      m =
        Map.put(@base, :nifs, [
          %{module: :"1bad_nif", native_dir: "priv/native/jni"}
        ])

      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "C-token"))
    end

    test "rejects an atom containing a hyphen as nif :module", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))

      m =
        Map.put(@base, :nifs, [
          %{module: :"bad-nif", native_dir: "priv/native/jni"}
        ])

      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "C-token"))
    end

    test "rejects a nif :module that collides with a core/runtime NIF", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))

      for core <- [:crypto, :mob_nif, :prim_file, :zlib] do
        m =
          Map.put(@base, :nifs, [
            %{module: core, native_dir: "priv/native/jni"}
          ])

        assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")

        assert Enum.any?(errs, &(&1 =~ "collides with a core/runtime NIF")),
               "expected #{inspect(core)} to be rejected as a reserved NIF module"

        assert Enum.any?(errs, &(&1 =~ to_string(core)))
      end
    end

    test "still accepts a plugin-specific nif :module that is not reserved", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))

      m =
        Map.put(@base, :nifs, [
          %{module: :mob_bluetooth_nif, native_dir: "priv/native/jni"}
        ])

      assert %{errors: []} = Validator.validate_plugin(m, dir, "0.6.20")
    end

    test "accepts a Swift-identifier ios.swift_struct", %{dir: dir} do
      m =
        Map.put(@base, :ui_components, [
          %{
            tag: "Sig",
            atom: :sig,
            ios: %{view_module: "Demo_SigPad_View", swift_struct: "MobSignaturePadView"},
            android: %{composable: "Demo_SigPad_View"}
          }
        ])

      assert %{errors: []} = Validator.validate_plugin(m, dir, "0.6.20")
    end

    test "rejects a non-binary ios.swift_struct", %{dir: dir} do
      m =
        Map.put(@base, :ui_components, [
          %{
            tag: "Sig",
            atom: :sig,
            ios: %{view_module: "Demo_SigPad_View", swift_struct: MobSignaturePadView},
            android: %{composable: "Demo_SigPad_View"}
          }
        ])

      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "swift_struct"))
      assert Enum.any?(errs, &(&1 =~ "Swift identifier"))
    end

    test "rejects a swift_struct containing a hyphen", %{dir: dir} do
      m =
        Map.put(@base, :ui_components, [
          %{
            tag: "Sig",
            atom: :sig,
            ios: %{view_module: "Demo_SigPad_View", swift_struct: "Mob-Bad-View"},
            android: %{composable: "Demo_SigPad_View"}
          }
        ])

      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "swift_struct"))
    end

    test "does not complain when ios.swift_struct is absent (optional field)", %{dir: dir} do
      m =
        Map.put(@base, :ui_components, [
          %{
            tag: "Sig",
            atom: :sig,
            ios: %{view_module: "Demo_SigPad_View"},
            android: %{composable: "Demo_SigPad_View"}
          }
        ])

      assert %{errors: []} = Validator.validate_plugin(m, dir, "0.6.20")
    end
  end

  describe "validate_swift_imports/2" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "mob_validator_swift_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "no swift_files means no errors", %{dir: dir} do
      assert Validator.validate_swift_imports(@base, dir) == []
    end

    test "nil manifest yields no errors", %{dir: _dir} do
      assert Validator.validate_swift_imports(nil, "/nonexistent") == []
    end

    test "imports of base frameworks (SwiftUI, Foundation, UIKit) require no declaration",
         %{dir: dir} do
      swift_file = Path.join(dir, "priv/native/ios/Pad.swift")
      File.mkdir_p!(Path.dirname(swift_file))

      File.write!(swift_file, """
      import SwiftUI
      import Foundation
      import UIKit
      struct Pad: View { var body: some View { Text("hi") } }
      """)

      m = Map.put(@base, :ios, %{swift_files: ["priv/native/ios/Pad.swift"]})
      assert Validator.validate_swift_imports(m, dir) == []
    end

    test "an undeclared non-base import is flagged", %{dir: dir} do
      swift_file = Path.join(dir, "priv/native/ios/Loc.swift")
      File.mkdir_p!(Path.dirname(swift_file))

      File.write!(swift_file, """
      import SwiftUI
      import CoreLocation
      struct Loc {}
      """)

      m = Map.put(@base, :ios, %{swift_files: ["priv/native/ios/Loc.swift"]})
      errors = Validator.validate_swift_imports(m, dir)
      assert Enum.any?(errors, &(&1 =~ "CoreLocation"))
      assert Enum.any?(errors, &(&1 =~ "priv/native/ios/Loc.swift"))
      assert Enum.any?(errors, &(&1 =~ "manifest.ios.frameworks"))
    end

    test "a declared framework satisfies the check", %{dir: dir} do
      swift_file = Path.join(dir, "priv/native/ios/Haptics.swift")
      File.mkdir_p!(Path.dirname(swift_file))

      File.write!(swift_file, """
      import CoreHaptics
      import Foundation
      class HapticEngine {}
      """)

      m =
        Map.put(@base, :ios, %{
          swift_files: ["priv/native/ios/Haptics.swift"],
          frameworks: ["CoreHaptics"]
        })

      assert Validator.validate_swift_imports(m, dir) == []
    end

    test "@testable import is treated as an ordinary import", %{dir: dir} do
      swift_file = Path.join(dir, "priv/native/ios/T.swift")
      File.mkdir_p!(Path.dirname(swift_file))

      File.write!(swift_file, """
      @testable import CoreBluetooth
      """)

      m = Map.put(@base, :ios, %{swift_files: ["priv/native/ios/T.swift"]})
      errors = Validator.validate_swift_imports(m, dir)
      assert Enum.any?(errors, &(&1 =~ "CoreBluetooth"))
    end

    test "skips files declared but missing on disk (path check owns that error)",
         %{dir: dir} do
      m = Map.put(@base, :ios, %{swift_files: ["priv/native/ios/Missing.swift"]})
      assert Validator.validate_swift_imports(m, dir) == []
    end

    test "mob_demo_signature_pad's swift source passes with no declared frameworks",
         %{dir: dir} do
      # The real demo plugin imports SwiftUI + Foundation — both base — so it
      # should pass with no extra ios.frameworks declared. Copy the file shape
      # rather than depending on the live plugin's filesystem location.
      swift_file = Path.join(dir, "priv/native/ios/MobSignaturePadView.swift")
      File.mkdir_p!(Path.dirname(swift_file))

      File.write!(swift_file, """
      import SwiftUI
      import Foundation

      struct MobSignaturePadView: View {
          let props: [String: Any]
          var body: some View { Text("sig") }
      }
      """)

      m =
        Map.put(@base, :ios, %{
          swift_files: ["priv/native/ios/MobSignaturePadView.swift"]
        })

      assert Validator.validate_swift_imports(m, dir) == []
    end

    test "wired into validate_plugin/3 — undeclared import bubbles up as an error",
         %{dir: dir} do
      swift_file = Path.join(dir, "priv/native/ios/X.swift")
      File.mkdir_p!(Path.dirname(swift_file))
      File.write!(swift_file, "import CoreLocation\n")

      m = Map.put(@base, :ios, %{swift_files: ["priv/native/ios/X.swift"]})
      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "CoreLocation"))
    end
  end

  describe "validate_android_permissions/2" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "mob_validator_android_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "no AndroidManifest fragment means no errors", %{dir: dir} do
      assert Validator.validate_android_permissions(@base, dir) == []
    end

    test "nil manifest yields no errors" do
      assert Validator.validate_android_permissions(nil, "/nonexistent") == []
    end

    test "a declared permission satisfies the check", %{dir: dir} do
      manifest_xml = Path.join(dir, "priv/native/android/AndroidManifest.xml")
      File.mkdir_p!(Path.dirname(manifest_xml))

      File.write!(manifest_xml, """
      <manifest xmlns:android="http://schemas.android.com/apk/res/android">
        <uses-permission android:name="android.permission.CAMERA"/>
      </manifest>
      """)

      m = Map.put(@base, :android, %{permissions: ["android.permission.CAMERA"]})
      assert Validator.validate_android_permissions(m, dir) == []
    end

    test "an undeclared permission is flagged", %{dir: dir} do
      manifest_xml = Path.join(dir, "priv/native/android/AndroidManifest.xml")
      File.mkdir_p!(Path.dirname(manifest_xml))

      File.write!(manifest_xml, """
      <manifest xmlns:android="http://schemas.android.com/apk/res/android">
        <uses-permission android:name="android.permission.RECORD_AUDIO"/>
      </manifest>
      """)

      m = Map.put(@base, :android, %{permissions: []})
      errors = Validator.validate_android_permissions(m, dir)
      assert Enum.any?(errors, &(&1 =~ "android.permission.RECORD_AUDIO"))
      assert Enum.any?(errors, &(&1 =~ "AndroidManifest.xml"))
      assert Enum.any?(errors, &(&1 =~ "manifest.android.permissions"))
    end

    test "tolerates extra attributes and whitespace in the element", %{dir: dir} do
      manifest_xml = Path.join(dir, "priv/native/android/AndroidManifest.xml")
      File.mkdir_p!(Path.dirname(manifest_xml))

      File.write!(manifest_xml, """
      <manifest xmlns:android="http://schemas.android.com/apk/res/android">
        <uses-permission
            android:name="android.permission.BLUETOOTH_CONNECT"
            android:maxSdkVersion="32"/>
      </manifest>
      """)

      m = Map.put(@base, :android, %{permissions: []})
      errors = Validator.validate_android_permissions(m, dir)
      assert Enum.any?(errors, &(&1 =~ "BLUETOOTH_CONNECT"))
    end

    test "scans nested xml files under priv/native/android/", %{dir: dir} do
      manifest_xml = Path.join(dir, "priv/native/android/manifest/MyManifest.xml")
      File.mkdir_p!(Path.dirname(manifest_xml))

      File.write!(manifest_xml, """
      <manifest xmlns:android="http://schemas.android.com/apk/res/android">
        <uses-permission android:name="android.permission.INTERNET"/>
      </manifest>
      """)

      m = Map.put(@base, :android, %{permissions: []})
      errors = Validator.validate_android_permissions(m, dir)
      assert Enum.any?(errors, &(&1 =~ "INTERNET"))
    end

    test "wired into validate_plugin/3 — undeclared permission bubbles up as an error",
         %{dir: dir} do
      manifest_xml = Path.join(dir, "priv/native/android/AndroidManifest.xml")
      File.mkdir_p!(Path.dirname(manifest_xml))

      File.write!(manifest_xml, """
      <uses-permission android:name="android.permission.CAMERA"/>
      """)

      m = Map.put(@base, :android, %{permissions: []})
      assert %{errors: errs} = Validator.validate_plugin(m, dir, "0.6.20")
      assert Enum.any?(errs, &(&1 =~ "CAMERA"))
    end
  end

  describe "activated_capability_errors/1" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "mob_validator_act_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "empty list when no plugins are activated", %{root: _root} do
      assert Validator.activated_capability_errors([]) == []
    end

    test "ignores tier-0 (nil) manifests", %{root: root} do
      assert Validator.activated_capability_errors([{root, nil}]) == []
    end

    test "flags drift across multiple plugins, prefixed by plugin name", %{root: root} do
      plugin_a = Path.join(root, "plugin_a")
      File.mkdir_p!(Path.join(plugin_a, "priv/native/ios"))
      File.write!(Path.join(plugin_a, "priv/native/ios/A.swift"), "import CoreLocation\n")

      manifest_a =
        Map.merge(@base, %{
          name: :plugin_a,
          ios: %{swift_files: ["priv/native/ios/A.swift"]}
        })

      plugin_b = Path.join(root, "plugin_b")
      File.mkdir_p!(Path.join(plugin_b, "priv/native/android"))

      File.write!(Path.join(plugin_b, "priv/native/android/AndroidManifest.xml"), """
      <uses-permission android:name="android.permission.CAMERA"/>
      """)

      manifest_b =
        Map.merge(@base, %{
          name: :plugin_b,
          android: %{permissions: []}
        })

      errors =
        Validator.activated_capability_errors([
          {plugin_a, manifest_a},
          {plugin_b, manifest_b}
        ])

      assert Enum.any?(errors, &(&1 =~ "[plugin_a]" and &1 =~ "CoreLocation"))
      assert Enum.any?(errors, &(&1 =~ "[plugin_b]" and &1 =~ "CAMERA"))
    end
  end

  describe "raise_on_capability_drift!/1" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "mob_validator_raise_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "no-op when no drift is found", %{root: root} do
      assert Validator.raise_on_capability_drift!([{root, nil}]) == :ok
      assert Validator.raise_on_capability_drift!([]) == :ok
    end

    test "raises with a Mix-formatted bullet list when drift is found", %{root: root} do
      File.mkdir_p!(Path.join(root, "priv/native/ios"))
      File.write!(Path.join(root, "priv/native/ios/X.swift"), "import CoreBluetooth\n")

      manifest =
        Map.merge(@base, %{name: :driftling, ios: %{swift_files: ["priv/native/ios/X.swift"]}})

      # raise_on_capability_drift!/1 now runs the signature gate first.
      # Acknowledge the unsigned plugin so the test can exercise the
      # capability check it actually targets.
      previous = Application.get_env(:mob, :acknowledge_unsafe_plugins, [])
      Application.put_env(:mob, :acknowledge_unsafe_plugins, [:driftling])
      on_exit(fn -> Application.put_env(:mob, :acknowledge_unsafe_plugins, previous) end)

      assert_raise Mix.Error, ~r/plugin capability check failed.*CoreBluetooth/s, fn ->
        Validator.raise_on_capability_drift!([{root, manifest}])
      end
    end
  end

  describe "cross_validate/1" do
    test "no collisions across distinct plugins" do
      a = Map.put(@base, :ui_components, [%{atom: :chart}])
      b = Map.put(@base, :ui_components, [%{atom: :gauge}])
      assert %{errors: []} = Validator.cross_validate([{:a, a}, {:b, b}])
    end

    test "detects a duplicate component atom across plugins" do
      a = Map.put(@base, :ui_components, [%{atom: :chart}])
      b = Map.put(@base, :ui_components, [%{atom: :chart}])
      assert %{errors: errs} = Validator.cross_validate([{:a, a}, {:b, b}])
      assert Enum.any?(errs, &(&1 =~ "component atom"))
    end

    test "detects a duplicate screen route across plugins" do
      a = Map.put(@base, :screens, [%{module: A, default_route: "/x"}])
      b = Map.put(@base, :screens, [%{module: B, default_route: "/x"}])
      assert %{errors: errs} = Validator.cross_validate([{:a, a}, {:b, b}])
      assert Enum.any?(errs, &(&1 =~ "screen route"))
    end

    test "detects a duplicate migration repo_namespace" do
      a = Map.put(@base, :migrations, %{repo_namespace: Foo, migrations_dir: "x"})
      b = Map.put(@base, :migrations, %{repo_namespace: Foo, migrations_dir: "y"})
      assert %{errors: errs} = Validator.cross_validate([{:a, a}, {:b, b}])
      assert Enum.any?(errs, &(&1 =~ "repo_namespace"))
    end

    test "ignores tier-0 (nil) manifests" do
      a = Map.put(@base, :ui_components, [%{atom: :chart}])
      assert %{errors: []} = Validator.cross_validate([{:a, a}, {:palette, nil}])
    end

    test "detects a duplicate iOS view_module across plugins with distinct atoms" do
      a = Map.put(@base, :ui_components, [%{atom: :chart, ios: %{view_module: "Shared_View"}}])
      b = Map.put(@base, :ui_components, [%{atom: :gauge, ios: %{view_module: "Shared_View"}}])
      assert %{errors: errs} = Validator.cross_validate([{:a, a}, {:b, b}])
      assert Enum.any?(errs, &(&1 =~ "view_module"))
    end

    test "detects a duplicate Android composable across plugins with distinct atoms" do
      a = Map.put(@base, :ui_components, [%{atom: :chart, android: %{composable: "Shared_View"}}])
      b = Map.put(@base, :ui_components, [%{atom: :gauge, android: %{composable: "Shared_View"}}])
      assert %{errors: errs} = Validator.cross_validate([{:a, a}, {:b, b}])
      assert Enum.any?(errs, &(&1 =~ "composable"))
    end

    test "distinct native view keys across plugins do not collide" do
      a = Map.put(@base, :ui_components, [%{atom: :chart, ios: %{view_module: "Chart_View"}}])
      b = Map.put(@base, :ui_components, [%{atom: :gauge, ios: %{view_module: "Gauge_View"}}])
      assert %{errors: []} = Validator.cross_validate([{:a, a}, {:b, b}])
    end

    test "detects a duplicate cpp_archive nm_symbol across plugins (distinct modules)" do
      a =
        Map.put(@base, :nifs, [
          %{module: :a_nif, lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "shared_init"}
        ])

      b =
        Map.put(@base, :nifs, [
          %{module: :b_nif, lang: :cpp_archive, sources: ["b.cpp"], nm_symbol: "shared_init"}
        ])

      assert %{errors: errs} = Validator.cross_validate([{:a, a}, {:b, b}])
      assert Enum.any?(errs, &(&1 =~ "cpp_archive init symbol"))
    end

    test "distinct cpp_archive nm_symbols across plugins do not collide" do
      a =
        Map.put(@base, :nifs, [
          %{module: :a_nif, lang: :cpp_archive, sources: ["a.cpp"], nm_symbol: "a_init"}
        ])

      b =
        Map.put(@base, :nifs, [
          %{module: :b_nif, lang: :cpp_archive, sources: ["b.cpp"], nm_symbol: "b_init"}
        ])

      assert %{errors: []} = Validator.cross_validate([{:a, a}, {:b, b}])
    end
  end
end

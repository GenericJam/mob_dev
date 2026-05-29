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

    test "accepts a Swift-identifier ios.swift_struct", %{dir: dir} do
      m =
        Map.put(@base, :ui_components, [
          %{
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
            atom: :sig,
            ios: %{view_module: "Demo_SigPad_View"},
            android: %{composable: "Demo_SigPad_View"}
          }
        ])

      assert %{errors: []} = Validator.validate_plugin(m, dir, "0.6.20")
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
  end
end

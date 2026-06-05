defmodule MobDev.Plugin.ManifestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Manifest

  @valid %{name: :mob_demo, mob_version: "~> 0.6", plugin_spec_version: 1}

  describe "load/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "mob_manifest_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "priv"))
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns nil when no manifest file exists (tier-0 plugin)", %{dir: dir} do
      assert {:ok, nil} = Manifest.load(dir)
    end

    test "reads and returns a manifest map", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(@valid))
      assert {:ok, %{name: :mob_demo}} = Manifest.load(dir)
    end

    test "errors when the file does not evaluate to a map", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), ":not_a_map")
      assert {:error, msg} = Manifest.load(dir)
      assert msg =~ "must evaluate to a map"
    end

    test "errors (does not raise) on a malformed manifest file", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), "%{name: :x,,,}")
      assert {:error, msg} = Manifest.load(dir)
      assert msg =~ "failed to evaluate"
    end
  end

  describe "validate/1" do
    test "nil (no manifest) is valid" do
      assert {:ok, nil} = Manifest.validate(nil)
    end

    test "accepts a manifest with the three required fields" do
      assert {:ok, @valid} = Manifest.validate(@valid)
    end

    test "rejects a missing/invalid name" do
      assert {:error, errs} = Manifest.validate(Map.delete(@valid, :name))
      assert Enum.any?(errs, &(&1 =~ ":name"))
    end

    test "rejects an invalid mob_version requirement" do
      assert {:error, errs} = Manifest.validate(%{@valid | mob_version: "not a req"})
      assert Enum.any?(errs, &(&1 =~ ":mob_version"))
    end

    test "rejects an unsupported plugin_spec_version" do
      assert {:error, errs} = Manifest.validate(%{@valid | plugin_spec_version: 99})
      assert Enum.any?(errs, &(&1 =~ "plugin_spec_version"))
    end

    test "accepts spec version 2 (code-generated plugins)" do
      assert {:ok, _} = Manifest.validate(%{@valid | plugin_spec_version: 2})
    end

    test "reports every problem at once, not just the first" do
      assert {:error, errs} = Manifest.validate(%{plugin_spec_version: "nope"})
      assert length(errs) == 3
    end

    test "rejects a non-map manifest" do
      assert {:error, _} = Manifest.validate("nope")
    end

    test "accepts a permissions list with capability + optional ios handler" do
      m =
        Map.put(@valid, :permissions, [
          %{capability: :location, ios: %{handler: "mob_location_request_permission"}},
          %{capability: :sensors}
        ])

      assert {:ok, _} = Manifest.validate(m)
    end

    test "rejects permissions that isn't a list" do
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :permissions, %{capability: :x}))
      assert Enum.any?(errs, &(&1 =~ "permissions must be a list"))
    end

    test "rejects a permissions entry without a :capability atom" do
      assert {:error, errs} = Manifest.validate(Map.put(@valid, :permissions, [%{ios: %{}}]))
      assert Enum.any?(errs, &(&1 =~ ":capability"))
    end

    test "rejects a permissions entry whose :ios lacks a :handler string" do
      m = Map.put(@valid, :permissions, [%{capability: :location, ios: %{}}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ ":handler"))
    end

    test "accepts nif entries with a valid :platform (cross-platform plugin)" do
      m =
        Map.put(@valid, :nifs, [
          %{module: :mob_location_nif, native_dir: "priv/native/ios", platform: :ios},
          %{
            module: :mob_location_nif,
            native_dir: "priv/native/jni",
            lang: :zig,
            platform: :android
          },
          %{module: :shared_nif}
        ])

      assert {:ok, _} = Manifest.validate(m)
    end

    test "rejects a nif entry with an invalid :platform" do
      m = Map.put(@valid, :nifs, [%{module: :x, platform: :windows}])
      assert {:error, errs} = Manifest.validate(m)
      assert Enum.any?(errs, &(&1 =~ ":platform must be :ios or :android"))
    end
  end

  describe "tier/1" do
    test "no manifest is tier 0" do
      assert Manifest.tier(nil) == 0
    end

    test "minimal manifest (no capability sections) is the tier-1 floor" do
      assert Manifest.tier(@valid) == 1
    end

    test "NIFs are tier 1" do
      assert Manifest.tier(Map.put(@valid, :nifs, [])) == 1
    end

    test "ui_components are tier 2" do
      assert Manifest.tier(Map.put(@valid, :ui_components, [])) == 2
    end

    test "permissions are tier 1 (native capability)" do
      assert Manifest.tier(Map.put(@valid, :permissions, [%{capability: :location}])) == 1
    end

    test "screens are tier 3" do
      assert Manifest.tier(Map.put(@valid, :screens, [])) == 3
    end

    test "screens_generator (spec 2) is tier 3" do
      assert Manifest.tier(Map.put(@valid, :screens_generator, {M, :f, []})) == 3
    end

    test "lifecycle is tier 4" do
      assert Manifest.tier(Map.put(@valid, :lifecycle, %{})) == 4
    end

    test "highest matching section wins" do
      m = @valid |> Map.put(:nifs, []) |> Map.put(:ui_components, []) |> Map.put(:lifecycle, %{})
      assert Manifest.tier(m) == 4
    end
  end

  describe "hot_pushable/1" do
    test "no manifest (pure Elixir tier 0) is hot-pushable" do
      assert Manifest.hot_pushable(nil) == true
    end

    test "minimal manifest with no native sections is hot-pushable" do
      assert Manifest.hot_pushable(@valid) == true
    end

    test "NIF plugin is not hot-pushable" do
      assert Manifest.hot_pushable(Map.put(@valid, :nifs, [])) == false
    end

    test "visual plugin is not hot-pushable" do
      assert Manifest.hot_pushable(Map.put(@valid, :ui_components, [])) == false
    end

    test "native + Elixir screens is partial" do
      m = @valid |> Map.put(:nifs, []) |> Map.put(:screens, [])
      assert Manifest.hot_pushable(m) == :partial
    end

    test "pure-Elixir screens (no native) is hot-pushable" do
      assert Manifest.hot_pushable(Map.put(@valid, :screens, [])) == true
    end
  end
end

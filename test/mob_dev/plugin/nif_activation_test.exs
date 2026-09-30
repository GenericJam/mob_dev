defmodule MobDev.Plugin.NifActivationTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.NifActivation

  @scanner %{
    name: :mob_scanner,
    nifs: [
      %{module: :mob_scanner_nif, native_dir: "priv/native/ios", platform: :ios},
      %{module: :mob_scanner_nif, native_dir: "priv/native/jni", platform: :android}
    ]
  }
  @ios_only %{name: :mob_touch, nifs: [%{module: :mob_touch_nif, platform: :ios}]}
  @both %{name: :mob_midi, nifs: [%{module: :mob_midi_nif}]}
  @no_nifs %{name: :mob_haptic, android: %{permissions: ["android.permission.VIBRATE"]}}
  @empty_nifs %{name: :mob_style, nifs: []}
  @objc_untagged %{name: :mob_legacy, nifs: [%{module: :mob_legacy_nif, lang: :objc}]}

  # Every dep in these tests ships to the device unless a test says otherwise.
  @runtime MapSet.new(~w(jason mob_haptic mob_style mob_scanner mob_touch mob_midi odd))

  describe "inactive_nif_plugins/3" do
    test "flags a dep whose manifest declares NIFs but isn't activated" do
      assert NifActivation.inactive_nif_plugins([{:mob_scanner, @scanner}], [], @runtime) ==
               [:mob_scanner]
    end

    test "doesn't flag an activated NIF plugin" do
      assert NifActivation.inactive_nif_plugins(
               [{:mob_scanner, @scanner}],
               [:mob_scanner],
               @runtime
             ) == []
    end

    test "doesn't flag tier-0 deps, manifests without nifs, or empty nifs" do
      deps = [{:jason, nil}, {:mob_haptic, @no_nifs}, {:mob_style, @empty_nifs}]
      assert NifActivation.inactive_nif_plugins(deps, [], @runtime) == []
    end

    test "only the inactive ones, sorted" do
      deps = [{:mob_scanner, @scanner}, {:mob_touch, @ios_only}, {:mob_midi, @both}]

      assert NifActivation.inactive_nif_plugins(deps, [:mob_touch], @runtime) ==
               [:mob_midi, :mob_scanner]
    end

    test "a malformed nifs value is not a NIF declaration" do
      assert NifActivation.inactive_nif_plugins([{:odd, %{nifs: :oops}}], [], @runtime) == []
    end

    test "a dep that doesn't ship to the device (only: :dev / runtime: false) isn't flagged" do
      deps = [{:mob_scanner, @scanner}, {:host_tool, @both}]

      assert NifActivation.inactive_nif_plugins(deps, [], @runtime) == [:mob_scanner]
    end
  end

  describe "inactive_warning/2" do
    test "nil when nothing is inactive" do
      assert NifActivation.inactive_warning([], [:mob_camera]) == nil
    end

    test "names the plugin and gives the full config line to set" do
      msg = NifActivation.inactive_warning([:mob_scanner], [:mob_camera])

      assert msg =~ "mob_scanner is in your deps and ships a NIF, but is not activated"
      assert msg =~ "config :mob, :plugins, [:mob_camera, :mob_scanner]"
      assert msg =~ "mix mob.deploy --native"
    end
  end

  describe "nif_plugins_by_platform/2" do
    test "only activated plugins, split by each NIF's platform" do
      deps = [
        {:mob_scanner, @scanner},
        {:mob_touch, @ios_only},
        {:mob_midi, @both},
        {:mob_haptic, @no_nifs},
        {:inactive, @both}
      ]

      activated = [:mob_scanner, :mob_touch, :mob_midi, :mob_haptic]

      assert NifActivation.nif_plugins_by_platform(deps, activated) == %{
               android: ["mob_midi", "mob_scanner"],
               ios: ["mob_midi", "mob_scanner", "mob_touch"]
             }
    end

    test "every platform is a key even with no NIF plugins" do
      assert NifActivation.nif_plugins_by_platform([], []) == %{android: [], ios: []}
    end

    test "an Objective-C NIF without :platform is iOS-only, as the native build treats it" do
      assert NifActivation.nif_plugins_by_platform([{:mob_legacy, @objc_untagged}], [:mob_legacy]) ==
               %{android: [], ios: ["mob_legacy"]}
    end
  end

  describe "drift/3" do
    test "a plugin activated after the recorded build is :not_built" do
      current = %{android: ["mob_scanner"], ios: ["mob_scanner"]}
      recorded = %{android: [], ios: ["mob_scanner"]}

      assert NifActivation.drift(current, recorded, [:android, :ios]) == [
               {:mob_scanner, :android, :not_built}
             ]
    end

    test "no drift when the recorded build has every activated NIF plugin" do
      current = %{android: ["mob_scanner"], ios: []}
      recorded = %{android: ["mob_camera", "mob_scanner"], ios: []}

      assert NifActivation.drift(current, recorded, [:android, :ios]) == []
    end

    test "a platform never recorded is :no_record for each activated NIF plugin" do
      current = %{android: ["mob_scanner"], ios: ["mob_scanner"]}

      assert NifActivation.drift(current, %{android: ["mob_scanner"]}, [:android, :ios]) == [
               {:mob_scanner, :ios, :no_record}
             ]
    end

    test "no warning without activated NIF plugins, even with no record" do
      assert NifActivation.drift(%{android: [], ios: []}, %{}, [:android, :ios]) == []
    end

    test "only the platforms being deployed to are checked" do
      current = %{android: ["mob_scanner"], ios: ["mob_scanner"]}
      recorded = %{android: ["mob_scanner"], ios: []}

      assert NifActivation.drift(current, recorded, [:android]) == []
    end
  end

  describe "drift_warning/1" do
    test "nil when there is no drift" do
      assert NifActivation.drift_warning([]) == nil
    end

    test "a known-stale build says the app was built without the plugin" do
      msg = NifActivation.drift_warning([{:mob_scanner, :android, :not_built}])

      assert msg =~
               "mob_scanner is activated but the installed android app was built without it " <>
                 "— run `mix mob.deploy --native`"
    end

    test "a missing record doesn't claim the build is stale" do
      msg = NifActivation.drift_warning([{:mob_scanner, :ios, :no_record}])

      assert msg =~ "no native ios build has been recorded"
      refute msg =~ "was built without it"
    end
  end

  describe "record round-trip" do
    test "put_record replaces one platform and keeps the others" do
      record = NifActivation.put_record(%{ios: ["mob_touch"]}, :android, ["b", "a"])
      assert record == %{ios: ["mob_touch"], android: ["a", "b"]}
    end

    test "render_record/parse_record round-trips, including an empty platform" do
      record = %{android: [], ios: ["mob_midi", "mob_scanner"]}
      assert record |> NifActivation.render_record() |> NifActivation.parse_record() == record
    end

    test "an unrecorded platform stays absent (not an empty build)" do
      parsed =
        %{android: ["mob_scanner"]}
        |> NifActivation.render_record()
        |> NifActivation.parse_record()

      refute Map.has_key?(parsed, :ios)
    end

    test "parse_record ignores unknown platforms and malformed lines" do
      assert NifActivation.parse_record("# c\nwindows x\n\nios mob_touch\n") == %{
               ios: ["mob_touch"]
             }
    end

    @tag :tmp_dir
    test "read_record of a missing file is an empty record", %{tmp_dir: dir} do
      assert NifActivation.read_record(Path.join(dir, "absent.txt")) == %{}
    end

    @tag :tmp_dir
    test "record_native_build/3 merges the built platforms and keeps the rest", %{tmp_dir: dir} do
      path = Path.join([dir, "nested", "record.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, NifActivation.render_record(%{ios: ["mob_touch"], android: ["old"]}))

      assert :ok =
               NifActivation.record_native_build(
                 [:android],
                 %{android: ["mob_scanner"], ios: []},
                 path
               )

      assert NifActivation.read_record(path) == %{android: ["mob_scanner"], ios: ["mob_touch"]}
    end

    @tag :tmp_dir
    test "record_native_build/3 warns instead of raising when the record can't be written",
         %{tmp_dir: dir} do
      # The parent "directory" is a regular file, so neither mkdir nor write can succeed.
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   NifActivation.record_native_build(
                     [:android],
                     %{android: ["mob_scanner"]},
                     Path.join(blocker, "record.txt")
                   )
        end)

      assert output =~ "could not record the native build's plugins"
    end
  end

  describe "node_platforms/2" do
    test "reads platforms from Device.node_name/1 shapes" do
      nodes = [
        :"my_app_android_emulator_5554@127.0.0.1",
        :"my_app_ios_78354490@127.0.0.1"
      ]

      assert NifActivation.node_platforms(nodes, :my_app) == [:android, :ios]
    end

    test "bare platform suffixes and a single platform" do
      assert NifActivation.node_platforms([:"my_app_ios@10.0.0.120"], :my_app) == [:ios]
      assert NifActivation.node_platforms([:"my_app_android@127.0.0.1"], :my_app) == [:android]
    end

    test "a platform word inside the app name isn't read as the platform" do
      assert NifActivation.node_platforms(
               [:"my_ios_app_android_zy22k6bsjm@127.0.0.1"],
               :my_ios_app
             ) ==
               [:android]

      assert NifActivation.node_platforms([:"android_tool_ios_78354490@127.0.0.1"], :android_tool) ==
               [:ios]
    end

    test "nodes of another app are ignored" do
      assert NifActivation.node_platforms([:"other_android_emulator_5554@127.0.0.1"], :my_app) ==
               []
    end

    test "no nodes, no platforms" do
      assert NifActivation.node_platforms([], :my_app) == []
    end
  end
end

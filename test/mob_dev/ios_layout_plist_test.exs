defmodule MobDev.IosLayoutPlistTest do
  use ExUnit.Case, async: true

  alias MobDev.IosLayoutPlist

  @all ~w(UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown
          UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight)

  # Builds an XML Info.plist with only the given layout keys (plus a non-ASCII
  # display name, which the reader must survive).
  defp plist(keys) do
    body =
      Enum.map_join(keys, "\n", fn
        {key, :true} -> "<key>#{key}</key><true/>"
        {key, :false} -> "<key>#{key}</key><false/>"
        {key, ints} when is_integer(hd(ints)) -> array(key, "integer", ints)
        {key, strings} -> array(key, "string", strings)
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleName</key>
        <string>Café</string>
        <!-- a comment between entries -->
        #{body}
        <key>UIApplicationSceneManifest</key>
        <dict><key>UIDeviceFamily</key><array><integer>9</integer></array></dict>
    </dict>
    </plist>
    """
  end

  defp array(key, type, values),
    do: "<key>#{key}</key><array>#{Enum.map_join(values, &"<#{type}>#{&1}</#{type}>")}</array>"

  # The template mob_new generated before MOB-206: all four iPhone
  # orientations, no UIDeviceFamily, no ~ipad key, no UIRequiresFullScreen.
  @old [{"UISupportedInterfaceOrientations", @all}]

  # The template mob_new generates from MOB-206 on.
  @new [
    {"UIDeviceFamily", [1, 2]},
    {"UIRequiresFullScreen", false},
    {"UISupportedInterfaceOrientations", @all},
    {"UISupportedInterfaceOrientations~ipad", @all}
  ]

  defp levels(rows), do: Enum.map(rows, fn {level, label, _, _} -> {level, label} end)

  describe "read/1" do
    test "reads the top-level layout keys, not nested dicts" do
      assert {:ok,
              %{
                device_family: [1, 2],
                orientations: @all,
                ipad_orientations: @all,
                requires_full_screen: false
              }} = IosLayoutPlist.read(plist(@new))
    end

    test "reports an absent key as nil" do
      assert {:ok, %{device_family: nil, ipad_orientations: nil, requires_full_screen: nil}} =
               IosLayoutPlist.read(plist(@old))
    end

    test "refuses a binary plist" do
      assert {:error, _} = IosLayoutPlist.read("bplist00\x01\x02")
    end
  end

  describe "plist_commands/1" do
    test "unset keys leave the project plist as written" do
      assert IosLayoutPlist.plist_commands([]) == []
    end

    test "ios_target_devices replaces UIDeviceFamily" do
      assert IosLayoutPlist.plist_commands(ios_target_devices: [:iphone]) == [
               "Delete :UIDeviceFamily",
               "Add :UIDeviceFamily array",
               "Add :UIDeviceFamily:0 integer 1"
             ]

      assert IosLayoutPlist.plist_commands(ios_target_devices: [:ipad, :iphone, :ipad]) == [
               "Delete :UIDeviceFamily",
               "Add :UIDeviceFamily array",
               "Add :UIDeviceFamily:0 integer 1",
               "Add :UIDeviceFamily:1 integer 2"
             ]
    end

    test "ios_orientations locks iPhone; iPad keeps all four" do
      commands = IosLayoutPlist.plist_commands(ios_orientations: :portrait)

      assert "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationPortrait" in commands

      assert "Add :UISupportedInterfaceOrientations:1 string UIInterfaceOrientationPortraitUpsideDown" in commands

      refute "Add :UISupportedInterfaceOrientations:2 string UIInterfaceOrientationLandscapeLeft" in commands

      for {orientation, i} <- Enum.with_index(@all) do
        assert "Add :UISupportedInterfaceOrientations~ipad:#{i} string #{orientation}" in commands
      end
    end

    test "rejects an invalid value instead of building something else" do
      assert_raise Mix.Error, ~r/ios_target_devices must be/, fn ->
        IosLayoutPlist.plist_commands(ios_target_devices: [:watch])
      end

      assert_raise Mix.Error, ~r/ios_target_devices must be/, fn ->
        IosLayoutPlist.plist_commands(ios_target_devices: [])
      end

      assert_raise Mix.Error, ~r/ios_orientations must be/, fn ->
        IosLayoutPlist.plist_commands(ios_orientations: [:portrait])
      end
    end
  end

  describe "audit/2" do
    test "the new template passes" do
      assert [{:ok, _, "iPhone + iPad, all orientations, resizable", nil}] =
               IosLayoutPlist.audit(plist(@new), [])
    end

    test "the old template warns that iPad is missing, with the exact fix" do
      assert [{:warn, "iOS iPad support", detail, fix}] = IosLayoutPlist.audit(plist(@old), [])
      assert detail =~ "no UIDeviceFamily key"
      assert detail =~ "letterboxed"
      assert fix =~ "ios_target_devices: [:iphone, :ipad]"
      assert fix =~ "<integer>1</integer><integer>2</integer>"
      assert fix =~ "ios_target_devices: [:iphone]"
    end

    test "an iPhone-only family warns even when declared explicitly" do
      xml = plist([{"UIDeviceFamily", [1]} | @old])
      assert [{:warn, "iOS iPad support", detail, _}] = IosLayoutPlist.audit(xml, [])
      assert detail =~ "UIDeviceFamily is [1]"
    end

    test "mob.exs choosing iPhone-only silences the iPad warning" do
      assert [{:ok, _, "iPhone only (ios_target_devices)" <> _, nil}] =
               IosLayoutPlist.audit(plist(@old), ios_target_devices: [:iphone])
    end

    test "mob.exs overrides fix an old plist without editing it" do
      assert [{:ok, _, _, nil}] =
               IosLayoutPlist.audit(plist(@old),
                 ios_target_devices: [:iphone, :ipad],
                 ios_orientations: :all
               )
    end

    test "portrait-only orientations warn unless mob.exs chose them" do
      xml =
        plist([
          {"UIDeviceFamily", [1, 2]},
          {"UISupportedInterfaceOrientations", ["UIInterfaceOrientationPortrait"]},
          {"UISupportedInterfaceOrientations~ipad", @all}
        ])

      assert [{:warn, "iOS orientations", detail, fix}] = IosLayoutPlist.audit(xml, [])
      assert detail =~ "only portrait"
      assert fix =~ "ios_orientations: :all"
      assert fix =~ "ios_orientations: :portrait"

      assert [{:ok, _, _, _}] = IosLayoutPlist.audit(xml, ios_orientations: :portrait)
    end

    test "restricted iPad orientations warn; the iPhone key stands in when ~ipad is absent" do
      xml =
        plist([
          {"UIDeviceFamily", [1, 2]},
          {"UISupportedInterfaceOrientations", ["UIInterfaceOrientationPortrait"]}
        ])

      assert [{:warn, "iOS orientations", _, _}, {:warn, "iOS iPad orientations", _, fix}] =
               IosLayoutPlist.audit(xml, [])

      assert fix =~ "UISupportedInterfaceOrientations~ipad"

      # ios_orientations always declares all four on iPad.
      assert [{:ok, _, _, _}] = IosLayoutPlist.audit(xml, ios_orientations: :portrait)
    end

    test "UIRequiresFullScreen true warns, and no mob.exs key silences it" do
      xml = plist(List.keyreplace(@new, "UIRequiresFullScreen", 0, {"UIRequiresFullScreen", true}))

      assert levels(IosLayoutPlist.audit(xml, ios_target_devices: [:iphone])) == [
               {:warn, "iOS UIRequiresFullScreen"}
             ]
    end

    test "an iPhone-only portrait-locked full-screen plist reports every problem" do
      xml =
        plist([
          {"UIRequiresFullScreen", true},
          {"UISupportedInterfaceOrientations", ["UIInterfaceOrientationPortrait"]}
        ])

      assert levels(IosLayoutPlist.audit(xml, [])) == [
               {:warn, "iOS iPad support"},
               {:warn, "iOS orientations"},
               {:warn, "iOS UIRequiresFullScreen"}
             ]
    end

    test "an invalid mob.exs value fails" do
      assert [{:fail, _, detail, _}] = IosLayoutPlist.audit(plist(@new), ios_orientations: :up)
      assert detail =~ "ios_orientations"
    end

    test "an unreadable plist warns instead of crashing" do
      assert [{:warn, _, "couldn't check ios/Info.plist" <> _, nil}] =
               IosLayoutPlist.audit("bplist00", [])
    end
  end
end

defmodule MobDev.ReleaseTest do
  use ExUnit.Case, async: true

  alias MobDev.Release

  # Pure-function coverage. The end-to-end build path requires Xcode + a paid
  # Apple Developer Program account and is exercised by `mix mob.release` on a
  # configured machine; tests here cover the parsing + signing-resolution
  # logic that runs before any xcodebuild call.

  describe "parse_mobileprovision/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "rel_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "parses an App Store distribution profile (no provisioned devices)", %{tmp: tmp} do
      path = Path.join(tmp, "appstore.mobileprovision")
      File.write!(path, app_store_profile_xml("AAA111BBBB.com.example.app"))

      assert [profile] = Release.parse_mobileprovision(path)
      assert profile.uuid == "12345678-1234-1234-1234-123456789ABC"
      assert profile.app_id == "AAA111BBBB.com.example.app"
      assert profile.team_id == "AAA111BBBB"
      refute profile.provisioned_devices?
      refute profile.provisions_all_devices?
    end

    test "parses a development profile (has ProvisionedDevices)", %{tmp: tmp} do
      path = Path.join(tmp, "dev.mobileprovision")
      File.write!(path, development_profile_xml())

      assert [profile] = Release.parse_mobileprovision(path)
      assert profile.uuid == "DEV12345-1234-1234-1234-123456789ABC"
      assert profile.provisioned_devices?
      refute profile.provisions_all_devices?
    end

    test "parses an Enterprise profile (ProvisionsAllDevices)", %{tmp: tmp} do
      path = Path.join(tmp, "ent.mobileprovision")
      File.write!(path, enterprise_profile_xml())

      assert [profile] = Release.parse_mobileprovision(path)
      assert profile.provisions_all_devices?
      refute profile.provisioned_devices?
    end

    test "returns [] for a file with no plist payload", %{tmp: tmp} do
      path = Path.join(tmp, "garbage.mobileprovision")
      File.write!(path, "not a real provisioning profile")
      assert Release.parse_mobileprovision(path) == []
    end

    test "returns [] for a missing file" do
      assert Release.parse_mobileprovision("/nonexistent/path.mobileprovision") == []
    end

    test "wildcard application-identifier is captured verbatim", %{tmp: tmp} do
      path = Path.join(tmp, "wild.mobileprovision")
      File.write!(path, app_store_profile_xml("AAA111BBBB.*"))

      assert [profile] = Release.parse_mobileprovision(path)
      assert profile.app_id == "AAA111BBBB.*"
    end
  end

  describe "resolve_distribution_signing/1 (config validation)" do
    test "passes through pre-set signing identity + profile UUID + team" do
      cfg = [
        bundle_id: "com.example.app",
        ios_team_id: "AAA111BBBB",
        ios_dist_sign_identity: "Apple Distribution: Test (AAA111BBBB)",
        ios_dist_profile_uuid: "12345678-1234-1234-1234-123456789ABC"
      ]

      assert {:ok, resolved} = Release.resolve_distribution_signing(cfg)
      assert resolved[:ios_dist_sign_identity] == "Apple Distribution: Test (AAA111BBBB)"
      assert resolved[:ios_dist_profile_uuid] == "12345678-1234-1234-1234-123456789ABC"
      assert resolved[:ios_team_id] == "AAA111BBBB"
    end
  end

  # The App Store profile selection kernel, extracted from resolve_dist_profile/3
  # so the pick logic (which is easy to get wrong: dev vs App Store, exact vs
  # wildcard, uuid narrowing) is testable without a keychain full of profiles.
  describe "select_dist_profile/3" do
    @bundle "com.example.app"

    test "excludes development profiles even when the bundle id matches" do
      # A dev profile has ProvisionedDevices — it must never be picked for App Store.
      profiles = [profile(provisioned_devices?: true, app_id: "TEAMID.#{@bundle}")]
      assert Release.select_dist_profile(profiles, nil, @bundle) == :none
    end

    test "excludes Enterprise profiles (ProvisionsAllDevices)" do
      profiles = [profile(provisions_all_devices?: true, app_id: "TEAMID.#{@bundle}")]
      assert Release.select_dist_profile(profiles, nil, @bundle) == :none
    end

    test "picks the App Store profile whose app id exactly matches the bundle id" do
      p = profile(uuid: "EXACT", app_id: "TEAMID.#{@bundle}")
      assert {:ok, ^p} = Release.select_dist_profile([p], nil, @bundle)
    end

    test "falls back to a wildcard (.*) profile when there is no exact match" do
      wild = profile(uuid: "WILD", app_id: "TEAMID.*")
      assert {:ok, ^wild} = Release.select_dist_profile([wild], nil, @bundle)
    end

    test "prefers an exact-bundle profile over a wildcard when both match" do
      exact = profile(uuid: "EXACT", app_id: "TEAMID.#{@bundle}")
      wild = profile(uuid: "WILD", app_id: "TEAMID.*")
      assert {:ok, ^exact} = Release.select_dist_profile([wild, exact], nil, @bundle)
    end

    test "with an explicit uuid, narrows to that profile and ignores the rest" do
      a = profile(uuid: "AAA", app_id: "TEAMID.#{@bundle}")
      b = profile(uuid: "BBB", app_id: "TEAMID.#{@bundle}")
      assert {:ok, ^b} = Release.select_dist_profile([a, b], "BBB", @bundle)
    end

    test "returns :none when the given uuid matches nothing" do
      p = profile(uuid: "AAA", app_id: "TEAMID.#{@bundle}")
      assert Release.select_dist_profile([p], "NOPE", @bundle) == :none
    end

    test "returns :none when no profile matches the bundle id" do
      p = profile(app_id: "TEAMID.com.other.app")
      assert Release.select_dist_profile([p], nil, @bundle) == :none
    end

    test "returns {:multiple, _} when two profiles exactly match and no uuid is set" do
      a = profile(uuid: "AAA", app_id: "TEAMID.#{@bundle}")
      b = profile(uuid: "BBB", app_id: "TEAMID.#{@bundle}")
      assert {:multiple, both} = Release.select_dist_profile([a, b], nil, @bundle)
      assert Enum.sort_by(both, & &1.uuid) == [a, b]
    end
  end

  describe "screenshot_build_env/1" do
    # Drives -DMOB_ENABLE_SCREENSHOT on the release mob_nif.m compile. Opt-in: the
    # public-API screenshot NIF ships in release only when the host asks for it.
    test "opts in when ios_release_screenshot: true" do
      assert Release.screenshot_build_env(ios_release_screenshot: true) ==
               {"MOB_ENABLE_SCREENSHOT", "1"}
    end

    test "off (empty) when the key is false" do
      assert Release.screenshot_build_env(ios_release_screenshot: false) ==
               {"MOB_ENABLE_SCREENSHOT", ""}
    end

    test "off (empty) by default when the key is absent" do
      assert Release.screenshot_build_env([]) == {"MOB_ENABLE_SCREENSHOT", ""}
    end
  end

  describe "plugin_ios_build_env/1" do
    # The two env vars feed release_device.sh's plugin NIF compile + link loop.
    # Pure over the activated-plugin list, so the matrix runs without a deps tree.

    test "no activated plugins → empty source + framework strings" do
      assert Release.plugin_ios_build_env([]) == [
               {"MOB_PLUGIN_IOS_NIF_SOURCES", ""},
               {"MOB_PLUGIN_IOS_FRAMEWORKS", ""}
             ]
    end

    test "one ObjC plugin → its .m source (absolute) + declared frameworks" do
      activated = [
        {"/deps/mob_camera",
         %{
           nifs: [
             %{
               module: :mob_camera_nif,
               native_dir: "priv/native/ios",
               lang: :objc,
               platform: :ios
             }
           ],
           ios: %{frameworks: ["AVFoundation", "Photos"]}
         }}
      ]

      assert [
               {"MOB_PLUGIN_IOS_NIF_SOURCES", srcs},
               {"MOB_PLUGIN_IOS_FRAMEWORKS", fws}
             ] = Release.plugin_ios_build_env(activated)

      assert srcs == "/deps/mob_camera/priv/native/ios/mob_camera_nif.m"
      assert fws == "AVFoundation Photos"
    end

    test "multiple plugins → space-joined sources; frameworks de-duped across the union" do
      activated = [
        {"/deps/a",
         %{
           nifs: [%{module: :a_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}],
           ios: %{frameworks: ["CoreBluetooth", "Foundation"]}
         }},
        {"/deps/b",
         %{
           nifs: [%{module: :b_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}],
           ios: %{frameworks: ["Foundation", "AVFoundation"]}
         }}
      ]

      assert [
               {"MOB_PLUGIN_IOS_NIF_SOURCES", srcs},
               {"MOB_PLUGIN_IOS_FRAMEWORKS", fws}
             ] = Release.plugin_ios_build_env(activated)

      assert srcs == "/deps/a/priv/native/ios/a_nif.m /deps/b/priv/native/ios/b_nif.m"
      # collect_uniq preserves first-seen order across plugins.
      assert fws == "CoreBluetooth Foundation AVFoundation"
    end

    test "an Android-only NIF entry on the same plugin is excluded from iOS sources" do
      activated = [
        {"/deps/x",
         %{
           nifs: [
             %{module: :x_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
             %{module: :x_nif, native_dir: "priv/native/jni", lang: :c, platform: :android}
           ],
           ios: %{frameworks: []}
         }}
      ]

      assert [{"MOB_PLUGIN_IOS_NIF_SOURCES", srcs}, {"MOB_PLUGIN_IOS_FRAMEWORKS", ""}] =
               Release.plugin_ios_build_env(activated)

      assert srcs == "/deps/x/priv/native/ios/x_nif.m"
    end
  end

  # A parsed-profile map in the shape parse_mobileprovision/1 returns; App Store by
  # default (no provisioned devices, not provisions-all).
  defp profile(overrides) do
    Map.merge(
      %{
        uuid: "UUID",
        team_id: "TEAMID",
        app_id: "TEAMID.com.example.app",
        provisioned_devices?: false,
        provisions_all_devices?: false
      },
      Map.new(overrides)
    )
  end

  # ── Profile XML fixtures ────────────────────────────────────────────────
  # Real .mobileprovision files are CMS-signed binaries with a plist payload
  # wrapped in DER. parse_mobileprovision/1 extracts the plist by string
  # matching `<?xml` ... `</plist>`, so a bare XML document with the same
  # structure is a sufficient input for the parser tests.

  defp app_store_profile_xml(app_id) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>UUID</key>
        <string>12345678-1234-1234-1234-123456789ABC</string>
        <key>application-identifier</key>
        <string>#{app_id}</string>
        <key>TeamIdentifier</key>
        <array>
            <string>AAA111BBBB</string>
        </array>
        <key>Name</key>
        <string>App Store Distribution</string>
    </dict>
    </plist>
    """
  end

  defp development_profile_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>UUID</key>
        <string>DEV12345-1234-1234-1234-123456789ABC</string>
        <key>application-identifier</key>
        <string>AAA111BBBB.com.example.app</string>
        <key>TeamIdentifier</key>
        <array>
            <string>AAA111BBBB</string>
        </array>
        <key>ProvisionedDevices</key>
        <array>
            <string>00008110-001E1C3A34F8401E</string>
        </array>
    </dict>
    </plist>
    """
  end

  defp enterprise_profile_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>UUID</key>
        <string>ENT12345-1234-1234-1234-123456789ABC</string>
        <key>application-identifier</key>
        <string>ENTRP00000.com.example.app</string>
        <key>TeamIdentifier</key>
        <array>
            <string>ENTRP00000</string>
        </array>
        <key>ProvisionsAllDevices</key>
        <true/>
    </dict>
    </plist>
    """
  end
end

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

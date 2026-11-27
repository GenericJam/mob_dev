defmodule MobDev.ReleasePluginPlistTest do
  # Changes the working directory: the release reads the project's ios/Info.plist from it.
  use ExUnit.Case, async: false

  # `mix mob.release --ios` copied ios/Info.plist into the bundle without the
  # keys activated plugins declare (`ios.plist_keys`), which the sim and device
  # builds merge (`NativeBuild.write_bundle_info_plist!/3`). An App Store build
  # then lost a plugin's privacy strings and Bonjour service types, and iOS
  # refused what the plugin needed.

  alias MobDev.Release

  @project_plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>CFBundleIdentifier</key>
      <string>placeholder</string>
  </dict>
  </plist>
  """

  setup do
    cwd = File.cwd!()

    dir =
      Path.join(System.tmp_dir!(), "release_plugin_plist_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "ios"))
    File.mkdir_p!(Path.join(dir, "inputs"))
    File.cd!(dir)

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp plugin(plist_keys),
    do: {"/deps/demo_plugin", %{name: :demo_plugin, ios: %{plist_keys: plist_keys}}}

  defp extract(plist, key) do
    {json, 0} = System.cmd("plutil", ["-extract", key, "json", "-o", "-", plist])
    :json.decode(json)
  end

  # plutil's json format takes containers only; a string comes out as raw text.
  defp extract_string(plist, key) do
    {text, 0} = System.cmd("plutil", ["-extract", key, "raw", "-o", "-", plist])
    String.trim_trailing(text, "\n")
  end

  # release_device.sh's url_schemes loop, run on a copy of `plist` as on the bundle's.
  defp run_url_types_block(plist, commands) do
    [block] =
      Regex.run(
        ~r/^ *if \[ -n "\$MOB_IOS_URL_TYPES_PLIST_COMMANDS" \]; then\n.*?^ *fi\n/ms,
        Release.release_device_sh()
      )

    File.cp!(plist, "Info.plist")

    System.cmd("bash", ["-e", "-c", block],
      env: [{"MOB_IOS_URL_TYPES_PLIST_COMMANDS", commands}, {"APP", File.cwd!()}],
      stderr_to_stdout: true
    )
  end

  @tag :macos_only
  test "the release Info.plist carries the plugins' keys, and the project's file is left as written" do
    File.write!("ios/Info.plist", @project_plist)

    activated = [
      plugin(%{
        NSBluetoothAlwaysUsageDescription: "Find devices nearby",
        NSBonjourServices: ["_http._tcp"]
      })
    ]

    plist = Release.write_release_info_plist!(activated, "inputs")

    assert extract_string(plist, "NSBluetoothAlwaysUsageDescription") == "Find devices nearby"
    assert extract(plist, "NSBonjourServices") == ["_http._tcp"]
    assert extract_string(plist, "CFBundleIdentifier") == "placeholder"
    assert File.read!("ios/Info.plist") == @project_plist
  end

  @tag :macos_only
  test "a key the project's Info.plist sets wins over the plugin's, the others are added" do
    File.write!(
      "ios/Info.plist",
      String.replace(@project_plist, "</dict>", """
          <key>NSBluetoothAlwaysUsageDescription</key>
          <string>The app's own words</string>
      </dict>
      """)
    )

    activated = [
      plugin(%{
        NSBluetoothAlwaysUsageDescription: "Find devices nearby",
        NSLocalNetworkUsageDescription: "Talk to devices on the network"
      })
    ]

    plist = Release.write_release_info_plist!(activated, "inputs")

    assert extract_string(plist, "NSBluetoothAlwaysUsageDescription") == "The app's own words"

    assert extract_string(plist, "NSLocalNetworkUsageDescription") ==
             "Talk to devices on the network"
  end

  test "release_env/5 hands the script the Info.plist it is given" do
    cfg = [mob_dir: "/mob", elixir_lib: "/elixir/lib", ios_bundle_id: "com.example.app"]
    env = Release.release_env(cfg, "/otp", "/app/release_Info.plist", [], [])

    assert {"MOB_IOS_INFO_PLIST", "/app/release_Info.plist"} in env
  end

  # The dev build computes the URL types from the bundle's merged file. Computed
  # from ios/Info.plist, the commands would add a CFBundleURLTypes array the
  # plugin already created, and the script would stop on PlistBuddy's
  # "Entry Already Exists".
  @tag :macos_only
  test "the URL types are computed from the merged Info.plist, so a plugin's CFBundleURLTypes doesn't stop the release" do
    File.write!("ios/Info.plist", @project_plist)

    activated = [plugin(%{CFBundleURLTypes: [%{"CFBundleURLSchemes" => ["plugin"]}]})]
    plist = Release.write_release_info_plist!(activated, "inputs")

    cfg = [
      mob_dir: "/mob",
      elixir_lib: "/elixir/lib",
      ios_bundle_id: "com.example.app",
      url_schemes: ["myapp"]
    ]

    env = Release.release_env(cfg, "/otp", plist, [], []) |> Map.new()
    {output, status} = run_url_types_block(plist, env["MOB_IOS_URL_TYPES_PLIST_COMMANDS"])

    assert status == 0, output
    assert [%{"CFBundleURLSchemes" => ["myapp"]}] = extract("Info.plist", "CFBundleURLTypes")
  end

  test "the release script bundles that Info.plist, not the project's own file" do
    sh = Release.release_device_sh()

    assert sh =~ ~s|cp "${MOB_IOS_INFO_PLIST:?|
    refute sh =~ "cp ios/Info.plist"
  end
end

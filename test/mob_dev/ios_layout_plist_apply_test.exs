defmodule MobDev.IosLayoutPlistApplyTest do
  use ExUnit.Case, async: true

  # Runs the mob.exs layout overrides through the real /usr/libexec/PlistBuddy,
  # both as the dev build applies them (IosLayoutPlist.apply!/2) and as
  # release_device.sh does (its MOB_IOS_LAYOUT_PLIST_COMMANDS loop). macOS
  # only; CI on Linux excludes :macos_only.
  @moduletag :macos_only

  alias MobDev.IosLayoutPlist

  @all ~w(UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown
          UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight)

  # An app generated before MOB-206: no UIDeviceFamily, iPhone orientations
  # only, plus a hand-added ~iphone lock the orientation override must remove.
  @old_plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>CFBundleName</key>
      <string>Café</string>
      <key>UISupportedInterfaceOrientations</key>
      <array>
          <string>UIInterfaceOrientationPortrait</string>
          <string>UIInterfaceOrientationLandscapeLeft</string>
      </array>
      <key>UISupportedInterfaceOrientations~iphone</key>
      <array>
          <string>UIInterfaceOrientationLandscapeLeft</string>
      </array>
  </dict>
  </plist>
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "layout_plist_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "Info.plist")
    File.write!(path, @old_plist)
    {:ok, path: path}
  end

  defp keys!(path) do
    {xml, 0} = System.cmd("plutil", ["-convert", "xml1", "-o", "-", path])
    {:ok, keys} = IosLayoutPlist.read(xml)
    keys
  end

  @cfg [ios_target_devices: [:iphone, :ipad], ios_orientations: :portrait]

  test "apply!/2 stamps the overrides over the project's values", %{path: path} do
    assert IosLayoutPlist.apply!(path, @cfg) == :ok

    assert %{
             device_family: [1, 2],
             orientations: [
               "UIInterfaceOrientationPortrait",
               "UIInterfaceOrientationPortraitUpsideDown"
             ],
             iphone_orientations: nil,
             ipad_orientations: @all
           } = keys!(path)

    {name, 0} = System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleName", path])
    assert String.trim(name) == "Café"
  end

  test "apply!/2 is idempotent and switches back to iPhone-only", %{path: path} do
    IosLayoutPlist.apply!(path, @cfg)
    IosLayoutPlist.apply!(path, ios_target_devices: [:iphone])
    assert %{device_family: [1]} = keys!(path)
  end

  test "apply!/2 without mob.exs keys leaves the file untouched", %{path: path} do
    IosLayoutPlist.apply!(path, [])
    assert File.read!(path) == @old_plist
  end

  defp release_block! do
    [block] =
      Regex.run(
        ~r/^ *if \[ -n "\$MOB_IOS_LAYOUT_PLIST_COMMANDS" \]; then\n.*?^ *fi\n/ms,
        MobDev.Release.release_device_sh()
      )

    block
  end

  defp run_release_block(path, commands) do
    System.cmd("bash", ["-e", "-c", release_block!()],
      env: [{"MOB_IOS_LAYOUT_PLIST_COMMANDS", commands}, {"APP", Path.dirname(path)}],
      stderr_to_stdout: true
    )
  end

  test "release_device.sh's loop stamps the same values", %{path: path} do
    {"MOB_IOS_LAYOUT_PLIST_COMMANDS", commands} = MobDev.Release.layout_plist_env(@cfg)
    {output, status} = run_release_block(path, commands)

    assert status == 0, output

    assert %{
             device_family: [1, 2],
             orientations: [
               "UIInterfaceOrientationPortrait",
               "UIInterfaceOrientationPortraitUpsideDown"
             ],
             iphone_orientations: nil,
             ipad_orientations: @all
           } = keys!(path)
  end

  test "release_device.sh's loop stops on a failing Add but not a failing Delete", %{path: path} do
    assert {_, 0} = run_release_block(path, "Delete :NoSuchKey\nAdd :Fresh string ok")

    # PlistBuddy refuses to Add a key that exists.
    assert {_, status} = run_release_block(path, "Add :Fresh string again\nAdd :After string x")

    assert status != 0
    {_, absent} = System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :After", path])
    assert absent != 0
  end

  # The scene manifest mob_new generates (MOB-245 stamps into it).
  @scene_plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>UIApplicationSceneManifest</key>
      <dict>
          <key>UIApplicationSupportsMultipleScenes</key>
          <false/>
          <key>UISceneConfigurations</key>
          <dict>
              <key>UIWindowSceneSessionRoleApplication</key>
              <array>
                  <dict>
                      <key>UISceneDelegateClassName</key>
                      <string>SceneDelegate</string>
                  </dict>
              </array>
          </dict>
      </dict>
  </dict>
  </plist>
  """

  defp print(path, key),
    do:
      System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print #{key}", path], stderr_to_stdout: true)

  @multiple ":UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes"
  @delegate ":UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName"

  test "multi_window: true turns on multiple scenes and keeps the SceneDelegate; false turns it off",
       %{path: path} do
    File.write!(path, @scene_plist)

    IosLayoutPlist.apply!(path, multi_window: true)
    assert {"true\n", 0} = print(path, @multiple)
    assert {"SceneDelegate\n", 0} = print(path, @delegate)

    IosLayoutPlist.apply!(path, multi_window: false)
    assert {_, status} = print(path, @multiple)
    assert status != 0
    assert {"SceneDelegate\n", 0} = print(path, @delegate)
  end

  test "multi_window: true refuses a plist without a scene manifest instead of adding one",
       %{path: path} do
    assert_raise Mix.Error, ~r/multi_window: true needs .*UISceneConfigurations/, fn ->
      IosLayoutPlist.apply!(path, multi_window: true)
    end

    assert File.read!(path) == @old_plist

    # false on the same plist adds no manifest either.
    IosLayoutPlist.apply!(path, multi_window: false)
    assert {_, absent} = print(path, ":UIApplicationSceneManifest")
    assert absent != 0
  end

  test "release_device.sh's loop stamps multi_window and refuses a manifest-less plist",
       %{path: path} do
    {"MOB_IOS_LAYOUT_PLIST_COMMANDS", commands} =
      MobDev.Release.layout_plist_env(multi_window: true)

    {output, status} = run_release_block(path, commands)
    assert status != 0
    assert output =~ "multi_window: true needs UIApplicationSceneManifest"
    assert {_, absent} = print(path, ":UIApplicationSceneManifest")
    assert absent != 0

    File.write!(path, @scene_plist)
    {output, status} = run_release_block(path, commands)
    assert status == 0, output
    assert {"true\n", 0} = print(path, @multiple)
  end
end

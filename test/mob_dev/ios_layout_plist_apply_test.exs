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
  # only, plus a nested key the overrides must not touch.
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

  test "release_device.sh's loop stamps the same values", %{path: path} do
    sh = MobDev.Release.release_device_sh()

    [block] =
      Regex.run(~r/^ *if \[ -n "\$MOB_IOS_LAYOUT_PLIST_COMMANDS" \]; then\n.*?^ *fi\n/ms, sh)

    {var, commands} = MobDev.Release.layout_plist_env(@cfg)
    app = Path.dirname(path)
    File.rename!(path, Path.join(app, "Info.plist"))

    {output, status} =
      System.cmd("bash", ["-e", "-c", block],
        env: [{var, commands}, {"APP", app}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert %{
             device_family: [1, 2],
             orientations: [
               "UIInterfaceOrientationPortrait",
               "UIInterfaceOrientationPortraitUpsideDown"
             ],
             ipad_orientations: @all
           } = keys!(path)
  end
end

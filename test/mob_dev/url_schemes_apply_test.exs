defmodule MobDev.UrlSchemesApplyTest do
  use ExUnit.Case, async: true

  # Runs mob.exs url_schemes through the real plutil and /usr/libexec/PlistBuddy,
  # both as the dev build applies them (UrlSchemes.apply_plist!/3) and as
  # release_device.sh does (its MOB_IOS_URL_TYPES_PLIST_COMMANDS loop). macOS
  # only; CI on Linux excludes :macos_only.
  @moduletag :macos_only

  alias MobDev.UrlSchemes

  # An app that already registers a scheme of its own (an OAuth redirect) plus
  # one mob.exs also lists, in another case.
  @oauth_plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>CFBundleName</key>
      <string>Café</string>
      <key>CFBundleURLTypes</key>
      <array>
          <dict>
              <key>CFBundleURLName</key>
              <string>google</string>
              <key>CFBundleURLSchemes</key>
              <array>
                  <string>com.googleusercontent.apps.123</string>
                  <string>Legacy</string>
              </array>
          </dict>
      </array>
  </dict>
  </plist>
  """

  @bare_plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>CFBundleName</key>
      <string>Café</string>
  </dict>
  </plist>
  """

  @cfg [url_schemes: ["operator", "legacy"]]

  setup do
    dir = Path.join(System.tmp_dir!(), "url_schemes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "Info.plist")}
  end

  defp url_types!(path) do
    case System.cmd("plutil", ["-extract", "CFBundleURLTypes", "json", "-o", "-", path],
           stderr_to_stdout: true
         ) do
      {json, 0} -> :json.decode(json)
      {_, _} -> nil
    end
  end

  @google %{
    "CFBundleURLName" => "google",
    "CFBundleURLSchemes" => ["com.googleusercontent.apps.123", "Legacy"]
  }
  @ours %{
    "CFBundleURLName" => "com.example.app",
    "CFBundleTypeRole" => "Viewer",
    "CFBundleURLSchemes" => ["operator"]
  }

  test "apply_plist!/3 appends an entry after the app's and skips its schemes", %{path: path} do
    File.write!(path, @oauth_plist)

    assert UrlSchemes.apply_plist!(path, @cfg, "com.example.app") == :ok
    assert url_types!(path) == [@google, @ours]

    {name, 0} = System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleName", path])
    assert String.trim(name) == "Café"
  end

  test "apply_plist!/3 creates CFBundleURLTypes as an array", %{path: path} do
    File.write!(path, @bare_plist)

    UrlSchemes.apply_plist!(path, [url_schemes: ["operator", "myapp"]], "com.example.app")

    assert url_types!(path) == [
             %{
               "CFBundleURLName" => "com.example.app",
               "CFBundleTypeRole" => "Viewer",
               "CFBundleURLSchemes" => ["operator", "myapp"]
             }
           ]
  end

  test "apply_plist!/3 adds nothing the second time", %{path: path} do
    File.write!(path, @oauth_plist)
    UrlSchemes.apply_plist!(path, @cfg, "com.example.app")
    UrlSchemes.apply_plist!(path, @cfg, "com.example.app")

    assert url_types!(path) == [@google, @ours]
  end

  test "apply_plist!/3 reads a binary plist", %{path: path} do
    File.write!(path, @oauth_plist)
    {_, 0} = System.cmd("plutil", ["-convert", "binary1", path])

    UrlSchemes.apply_plist!(path, @cfg, "com.example.app")
    assert url_types!(path) == [@google, @ours]
  end

  test "apply_plist!/3 without the key, or with only declared schemes, leaves the file untouched",
       %{path: path} do
    File.write!(path, @oauth_plist)

    UrlSchemes.apply_plist!(path, [], "com.example.app")
    UrlSchemes.apply_plist!(path, [url_schemes: []], "com.example.app")
    UrlSchemes.apply_plist!(path, [url_schemes: ["legacy"]], "com.example.app")

    assert File.read!(path) == @oauth_plist
  end

  defp release_block! do
    [block] =
      Regex.run(
        ~r/^ *if \[ -n "\$MOB_IOS_URL_TYPES_PLIST_COMMANDS" \]; then\n.*?^ *fi\n/ms,
        MobDev.Release.release_device_sh()
      )

    block
  end

  defp run_release_block(path, commands) do
    System.cmd("bash", ["-e", "-c", release_block!()],
      env: [{"MOB_IOS_URL_TYPES_PLIST_COMMANDS", commands}, {"APP", Path.dirname(path)}],
      stderr_to_stdout: true
    )
  end

  test "release_device.sh's loop stamps what the dev build does", %{path: path} do
    File.write!(path, @oauth_plist)

    {"MOB_IOS_URL_TYPES_PLIST_COMMANDS", commands} =
      MobDev.Release.url_types_plist_env(@cfg ++ [ios_bundle_id: "com.example.app"], path)

    {output, status} = run_release_block(path, commands)

    assert status == 0, output
    assert url_types!(path) == [@google, @ours]
  end

  test "url_types_plist_env/2 names the entry after the iOS bundle id", %{path: path} do
    File.write!(path, @bare_plist)

    {_, commands} =
      MobDev.Release.url_types_plist_env(
        [
          url_schemes: ["operator"],
          bundle_id: "com.example.android_id",
          ios_bundle_id: "com.ex.ios"
        ],
        path
      )

    {_, 0} = run_release_block(path, commands)
    assert [%{"CFBundleURLName" => "com.ex.ios"}] = url_types!(path)
  end

  test "release_device.sh's loop stops on the first failing command", %{path: path} do
    File.write!(path, @bare_plist)

    # PlistBuddy refuses to Add a key that exists.
    assert {_, status} =
             run_release_block(
               path,
               "Add :Fresh string ok\nAdd :Fresh string again\nAdd :After string x"
             )

    assert status != 0
    assert {_, 0} = System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :Fresh", path])
    assert {_, absent} = System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :After", path])
    assert absent != 0
  end
end

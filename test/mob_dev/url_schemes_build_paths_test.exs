defmodule MobDev.UrlSchemesBuildPathsTest do
  # Changes the working directory: the build steps read the project from it.
  use ExUnit.Case, async: false

  # The functions the build paths call, run against a project directory, so a
  # path that stops passing mob.exs url_schemes through fails here. The dev
  # Android build and mix mob.release --android share
  # NativeBuild.apply_android_url_schemes!/1, the iOS sim and device bundles
  # share NativeBuild.write_bundle_info_plist!/3; the iOS release is covered in
  # url_schemes_apply_test.exs.

  @manifest """
  <manifest xmlns:android="http://schemas.android.com/apk/res/android">
      <application>
          <activity android:name=".MainActivity" android:exported="true"
              android:launchMode="singleTask">
              <intent-filter>
                  <action android:name="android.intent.action.MAIN"/>
                  <category android:name="android.intent.category.LAUNCHER"/>
              </intent-filter>
          </activity>
      </application>
  </manifest>
  """

  @manifest_path "android/app/src/main/AndroidManifest.xml"

  setup do
    cwd = File.cwd!()
    dir = Path.join(System.tmp_dir!(), "url_schemes_paths_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.dirname(Path.join(dir, @manifest_path)))
    File.cd!(dir)

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mob_exs!(url_schemes),
    do:
      File.write!(
        "mob.exs",
        "import Config\nconfig :mob_dev, url_schemes: #{inspect(url_schemes)}\n"
      )

  test "the Android build step stamps the project's manifest and strips it when unset" do
    File.write!(@manifest_path, @manifest)

    assert MobDev.NativeBuild.apply_android_url_schemes!(url_schemes: ["myapp"]) == :ok
    assert File.read!(@manifest_path) =~ ~s(<data android:scheme="myapp" />)

    MobDev.NativeBuild.apply_android_url_schemes!([])
    assert File.read!(@manifest_path) == @manifest
  end

  test "mix mob.release --android applies mob.exs url_schemes before building" do
    mob_exs!(["myapp"])
    File.write!("android/gradlew", "")
    no_launcher = String.replace(@manifest, "category.LAUNCHER", "category.DEFAULT")
    File.write!(@manifest_path, no_launcher)

    assert_raise Mix.Error, ~r/url_schemes is set, but AndroidManifest.xml has no launcher/, fn ->
      MobDev.ReleaseAndroid.build_aab()
    end
  end

  test "mix mob.doctor fails an invalid url_schemes" do
    mob_exs!(["https"])

    assert {:fail, "deep-link URL schemes", message, _fix} =
             List.keyfind(Mix.Tasks.Mob.Doctor.__project_checks__(), "deep-link URL schemes", 1)

    assert message =~ ~s(can't claim "https")
  end

  @tag :macos_only
  test "the iOS bundle Info.plist carries the URL type, named after the bundle id" do
    File.mkdir_p!("ios")
    File.mkdir_p!("Demo.app")

    File.write!("ios/Info.plist", """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>placeholder</string>
    </dict>
    </plist>
    """)

    plist =
      MobDev.NativeBuild.write_bundle_info_plist!(
        "Demo.app",
        [url_schemes: ["myapp"]],
        "com.example.ios"
      )

    {json, 0} = System.cmd("plutil", ["-extract", "CFBundleURLTypes", "json", "-o", "-", plist])

    assert :json.decode(json) == [
             %{
               "CFBundleURLName" => "com.example.ios",
               "CFBundleTypeRole" => "Viewer",
               "CFBundleURLSchemes" => ["myapp"]
             }
           ]

    refute File.read!("ios/Info.plist") =~ "CFBundleURLTypes"
  end
end

defmodule MobDev.UrlSchemesTest do
  use ExUnit.Case, async: true

  alias MobDev.UrlSchemes

  describe "schemes/1" do
    test "unset, nil and [] turn deep links off" do
      assert UrlSchemes.schemes([]) == {:ok, []}
      assert UrlSchemes.schemes(url_schemes: nil) == {:ok, []}
      assert UrlSchemes.schemes(url_schemes: []) == {:ok, []}
    end

    test "accepts RFC 3986 schemes and drops duplicates, keeping order" do
      assert UrlSchemes.schemes(url_schemes: ["operator", "my-app+v2.beta", "operator"]) ==
               {:ok, ["operator", "my-app+v2.beta"]}
    end

    test "refuses uppercase, naming the lowercase spelling" do
      assert {:error, message} = UrlSchemes.schemes(url_schemes: ["Operator"])
      assert message =~ ~s|"Operator" must be lowercase ("operator")|
    end

    test "refuses what isn't a scheme" do
      for bad <- ["operator://", "1app", "my app", "", "my_app"] do
        assert {:error, message} = UrlSchemes.schemes(url_schemes: [bad])
        assert message =~ "isn't a URL scheme", bad
      end
    end

    test "refuses http and https, pointing at verified links" do
      for web <- ["http", "https"] do
        assert {:error, message} = UrlSchemes.schemes(url_schemes: ["operator", web])
        assert message =~ ~s(can't claim "#{web}")
        assert message =~ "domain verification"
      end
    end

    test "refuses a value that isn't a list of strings" do
      assert {:error, message} = UrlSchemes.schemes(url_schemes: "operator")
      assert message =~ ~s(must be a list of URL scheme strings such as ["myapp"], got "operator")

      assert {:error, message} = UrlSchemes.schemes(url_schemes: [:operator])
      assert message =~ "entries must be strings"
    end
  end

  # mob_new's manifest shape, opted in to deep links (singleTask), with a
  # second activity ahead of the launcher one and a commented-out launcher
  # filter in it.
  @manifest """
  <?xml version="1.0" encoding="utf-8"?>
  <manifest xmlns:android="http://schemas.android.com/apk/res/android">
      <queries>
          <intent>
              <action android:name="android.intent.action.VIEW" />
              <data android:scheme="https" />
          </intent>
      </queries>
      <application android:label="Demo">
          <activity android:name=".SettingsActivity"
              android:exported="false">
              <!--
              <intent-filter>
                  <action android:name="android.intent.action.MAIN"/>
                  <category android:name="android.intent.category.LAUNCHER"/>
              </intent-filter>
              -->
          </activity>
          <activity android:name=".Splash" android:exported="false" />
          <activity android:name=".MainActivity"
              android:exported="true"
              android:launchMode="singleTask">
              <intent-filter>
                  <action android:name="android.intent.action.MAIN"/>
                  <category android:name="android.intent.category.LAUNCHER"/>
              </intent-filter>
          </activity>
      </application>
  </manifest>
  """

  defp main_activity(manifest) do
    [_, main] = String.split(manifest, ~s(android:name=".MainActivity"))
    [body, _] = String.split(main, "</activity>", parts: 2)
    body
  end

  describe "audit/2" do
    test "no row when unset, ok listing the schemes, fail on an invalid value" do
      assert UrlSchemes.audit([], nil) == []
      assert UrlSchemes.audit([], single_top()) == []

      assert [{:ok, "deep-link URL schemes", "operator://, myapp://", nil}] =
               UrlSchemes.audit([url_schemes: ["operator", "myapp"]], nil)

      assert [{:ok, _, _, nil}] = UrlSchemes.audit([url_schemes: ["operator"]], @manifest)

      assert [{:fail, "deep-link URL schemes", message, fix}] =
               UrlSchemes.audit([url_schemes: ["https"]], nil)

      assert message =~ "can't claim"
      assert fix =~ "mob.exs"
    end

    test "fails a launcher activity the build refuses" do
      assert [{:fail, "deep-link URL schemes", message, fix}] =
               UrlSchemes.audit([url_schemes: ["operator"]], single_top())

      assert message =~ ~s(needs android:launchMode="singleTask")
      assert fix =~ "android/app/src/main/AndroidManifest.xml"
    end
  end

  describe "launch_mode_error/2" do
    test "accepts singleTask and singleInstance" do
      assert UrlSchemes.launch_mode_error(@manifest, "M.xml") == nil

      assert UrlSchemes.launch_mode_error(
               launch_mode(~s(android:launchMode="singleInstance")),
               "M.xml"
             ) == nil
    end

    test "refuses singleTop and a missing launchMode, naming the activity and file" do
      message = UrlSchemes.launch_mode_error(single_top(), "android/x/AndroidManifest.xml")

      assert message =~
               ~s|needs android:launchMode="singleTask" on <activity android:name=".MainActivity"> in android/x/AndroidManifest.xml (it is "singleTop")|

      assert message =~ "start a second MainActivity there"

      assert UrlSchemes.launch_mode_error(launch_mode(""), "M.xml") =~
               ~s(it has none, so it is "standard")
    end

    test "only the launcher activity's own launchMode counts" do
      commented =
        launch_mode(~s(android:launchMode="singleTop"))
        |> String.replace(
          ~s(<activity android:name=".Splash" android:exported="false" />),
          ~s(<activity android:name=".Splash" android:launchMode="singleTask" />\n        <!-- android:launchMode="singleTask" -->)
        )

      assert UrlSchemes.launch_mode_error(commented, "M.xml") =~ ~s(it is "singleTop")
    end

    test "an activity-alias launcher is checked through its targetActivity" do
      alias_manifest = fn target_mode, target ->
        """
        <manifest xmlns:android="http://schemas.android.com/apk/res/android">
            <application>
                <activity android:name=".MainActivity" #{target_mode} android:exported="true" />
                <activity-alias android:name=".Launcher" android:targetActivity="#{target}">
                    <intent-filter>
                        <action android:name="android.intent.action.MAIN"/>
                        <category android:name="android.intent.category.LAUNCHER"/>
                    </intent-filter>
                </activity-alias>
            </application>
        </manifest>
        """
      end

      single_task = ~s(android:launchMode="singleTask")

      assert UrlSchemes.launch_mode_error(alias_manifest.(single_task, ".MainActivity"), "M.xml") ==
               nil

      assert UrlSchemes.launch_mode_error(alias_manifest.("", ".MainActivity"), "M.xml") =~
               ~s(on <activity android:name=".MainActivity">)

      assert UrlSchemes.launch_mode_error(alias_manifest.(single_task, ".Gone"), "M.xml") =~
               ~s(targets ".Gone", but no <activity> there has that android:name)
    end

    test "a manifest without a launcher activity is refused" do
      no_launcher = String.replace(@manifest, "category.LAUNCHER", "category.DEFAULT")
      assert UrlSchemes.launch_mode_error(no_launcher, "M.xml") =~ "has no launcher activity"
    end
  end

  defp launch_mode(attribute),
    do: String.replace(@manifest, ~s(android:launchMode="singleTask"), attribute)

  defp single_top, do: launch_mode(~s(android:launchMode="singleTop"))

  defp block(merged) do
    case Regex.run(Regex.compile!("mob:url-schemes BEGIN.*mob:url-schemes END", "s"), merged) do
      [block] -> block
      nil -> ""
    end
  end

  defp view_filter(data) do
    """
                <intent-filter>
                    <action android:name="android.intent.action.VIEW"/>
                    <category android:name="android.intent.category.DEFAULT"/>
                    <category android:name="android.intent.category.BROWSABLE"/>
                    #{data}
                </intent-filter>
    """
  end

  # After the launcher's MAIN/LAUNCHER filter, before its </activity>.
  defp in_launcher(manifest, xml) do
    String.replace(
      manifest,
      "            </intent-filter>\n        </activity>\n    </application>",
      "            </intent-filter>\n" <> xml <> "        </activity>\n    </application>"
    )
  end

  defp in_settings(manifest, xml) do
    String.replace(
      manifest,
      "            -->\n        </activity>",
      "            -->\n" <> xml <> "        </activity>"
    )
  end

  describe "merge_manifest/2" do
    test "puts the VIEW filter inside the launcher activity, before </activity>" do
      merged = UrlSchemes.merge_manifest(@manifest, ["operator", "myapp"])

      assert merged =~ """
                         </intent-filter>
                         <!-- mob:url-schemes BEGIN (managed — regenerated each build; do not edit) -->
                         <intent-filter>
                             <action android:name="android.intent.action.VIEW" />
                             <category android:name="android.intent.category.DEFAULT" />
                             <category android:name="android.intent.category.BROWSABLE" />
                             <data android:scheme="operator" />
                             <data android:scheme="myapp" />
                         </intent-filter>
                         <!-- mob:url-schemes END -->
                     </activity>
                 </application>
             """

      assert main_activity(merged) =~ "mob:url-schemes BEGIN"

      [settings, _] = String.split(merged, ~s(android:name=".MainActivity"))
      refute settings =~ "mob:url-schemes"
    end

    test "is idempotent" do
      once = UrlSchemes.merge_manifest(@manifest, ["operator"])
      assert UrlSchemes.merge_manifest(once, ["operator"]) == once
    end

    test "a changed setting replaces the block; an empty one restores the manifest" do
      once = UrlSchemes.merge_manifest(@manifest, ["operator"])
      changed = UrlSchemes.merge_manifest(once, ["myapp"])

      assert changed =~ ~s(android:scheme="myapp")
      refute changed =~ ~s(android:scheme="operator")
      assert changed == UrlSchemes.merge_manifest(@manifest, ["myapp"])

      assert UrlSchemes.merge_manifest(changed, []) == @manifest
    end

    test "leaves a manifest without the setting alone" do
      assert UrlSchemes.merge_manifest(@manifest, []) == @manifest
    end

    test "skips a scheme the launcher activity already routes in full" do
      host = in_launcher(@manifest, view_filter(~s(<data android:scheme="operator"/>)))

      assert block(UrlSchemes.merge_manifest(host, ["operator", "myapp"])) =~
               ~s(<data android:scheme="myapp" />)

      refute block(UrlSchemes.merge_manifest(host, ["operator", "myapp"])) =~ "operator"
      assert UrlSchemes.merge_manifest(host, ["operator"]) == host
    end

    test "a launcher filter narrowed by host, path, port or MIME type doesn't cover the scheme" do
      for data <- [
            ~s(<data android:scheme="operator" android:host="auth" />),
            ~s(<data android:scheme='operator' android:pathPrefix='/x' />),
            # <data> elements of one filter merge: the host narrows "operator".
            ~s(<data android:scheme="operator" />\n<data android:host="auth" />),
            ~s(<data android:scheme="operator" android:port="8080" />),
            ~s(<data android:scheme="operator" android:mimeType="text/plain" />)
          ] do
        host = in_launcher(@manifest, view_filter(data))
        assert block(UrlSchemes.merge_manifest(host, ["operator"])) =~ "operator", data
      end
    end

    test "a launcher filter missing DEFAULT or BROWSABLE doesn't cover the scheme" do
      for category <- ["DEFAULT", "BROWSABLE"] do
        filter =
          String.replace(
            view_filter(~s(<data android:scheme="operator"/>)),
            ~s(<category android:name="android.intent.category.#{category}"/>),
            ""
          )

        host = in_launcher(@manifest, filter)
        assert block(UrlSchemes.merge_manifest(host, ["operator"])) =~ "operator", category
      end
    end

    test "a filter on another activity doesn't cover the scheme, and is reported" do
      host = in_settings(@manifest, view_filter(~s(<data android:scheme="operator"/>)))
      merged = UrlSchemes.merge_manifest(host, ["operator", "myapp"])

      assert main_activity(merged) =~ ~s(<data android:scheme="operator" />)
      assert UrlSchemes.declared_elsewhere(host, ["operator", "myapp"]) == ["operator"]

      # Nothing to report about a scheme the launcher covers itself.
      both = in_launcher(host, view_filter(~s(<data android:scheme="operator"/>)))
      assert UrlSchemes.declared_elsewhere(both, ["operator"]) == []
      assert UrlSchemes.declared_elsewhere(@manifest, ["operator"]) == []
    end

    test "a scheme in <queries> or in a commented-out filter isn't a declaration" do
      commented =
        @manifest
        |> String.replace(
          ~s(<data android:scheme="https" />),
          ~s(<data android:scheme="operator" />)
        )
        |> in_launcher("<!-- " <> view_filter(~s(<data android:scheme="myapp"/>)) <> " -->\n")

      merged = UrlSchemes.merge_manifest(commented, ["operator", "myapp"])

      assert block(merged) =~ ~s(<data android:scheme="operator" />)
      assert block(merged) =~ ~s(<data android:scheme="myapp" />)
    end

    test "finds a launcher whose closing tag has whitespace before >" do
      spaced =
        String.replace(
          @manifest,
          "            </intent-filter>\n        </activity>",
          "            </intent-filter>\n        </activity >"
        )

      assert UrlSchemes.merge_manifest(spaced, ["operator"]) =~
               "<!-- mob:url-schemes END -->\n        </activity >"
    end

    test "places the filter in an activity-alias that is the launcher" do
      alias_manifest = """
      <manifest xmlns:android="http://schemas.android.com/apk/res/android">
          <application>
              <activity android:name=".MainActivity" android:exported="true" />
              <activity-alias android:name=".Launcher" android:targetActivity=".MainActivity">
                  <intent-filter>
                      <action android:name="android.intent.action.MAIN"/>
                      <category android:name="android.intent.category.LAUNCHER"/>
                  </intent-filter>
              </activity-alias>
          </application>
      </manifest>
      """

      merged = UrlSchemes.merge_manifest(alias_manifest, ["operator"])
      assert merged =~ "<!-- mob:url-schemes END -->\n        </activity-alias>"
    end

    test "raises when there is no launcher activity" do
      no_launcher = String.replace(@manifest, "category.LAUNCHER", "category.DEFAULT")

      assert_raise Mix.Error,
                   ~r/url_schemes is set, but AndroidManifest.xml has no launcher/,
                   fn ->
                     UrlSchemes.merge_manifest(no_launcher, ["operator"])
                   end

      assert UrlSchemes.merge_manifest(no_launcher, []) == no_launcher
    end

    test "raises rather than split a line when </activity> shares it" do
      inline =
        String.replace(
          @manifest,
          "            </intent-filter>\n        </activity>",
          "            </intent-filter></activity>"
        )

      assert_raise Mix.Error, ~r/Put <\/activity> on a line of its own/, fn ->
        UrlSchemes.merge_manifest(inline, ["operator"])
      end
    end
  end

  describe "apply_android_manifest!/2" do
    @describetag :tmp_dir

    test "writes the block, rewrites only on change, and strips it when the key goes",
         %{tmp_dir: dir} do
      path = Path.join(dir, "AndroidManifest.xml")
      File.write!(path, @manifest)

      assert UrlSchemes.apply_android_manifest!(path, url_schemes: ["operator"]) == :ok
      assert main_activity(File.read!(path)) =~ ~s(android:scheme="operator")

      File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
      UrlSchemes.apply_android_manifest!(path, url_schemes: ["operator"])
      assert File.stat!(path).mtime == {{2000, 1, 1}, {0, 0, 0}}

      UrlSchemes.apply_android_manifest!(path, [])
      assert File.read!(path) == @manifest
    end

    test "warns about a scheme another activity also declares", %{tmp_dir: dir} do
      path = Path.join(dir, "AndroidManifest.xml")

      File.write!(
        path,
        in_settings(@manifest, view_filter(~s(<data android:scheme="operator"/>)))
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          UrlSchemes.apply_android_manifest!(path, url_schemes: ["operator", "myapp"])
        end)

      assert output =~ "warning: url_schemes operator:// is also in a VIEW intent filter"
      refute output =~ "myapp"
      assert main_activity(File.read!(path)) =~ ~s(android:scheme="operator")
    end

    test "refuses a launcher without singleTask when schemes are set, and only then",
         %{tmp_dir: dir} do
      path = Path.join(dir, "AndroidManifest.xml")

      for manifest <- [single_top(), launch_mode("")] do
        File.write!(path, manifest)

        assert_raise Mix.Error, ~r/needs android:launchMode="singleTask"/, fn ->
          UrlSchemes.apply_android_manifest!(path, url_schemes: ["operator"])
        end

        assert File.read!(path) == manifest
        assert UrlSchemes.apply_android_manifest!(path, []) == :ok
        assert File.read!(path) == manifest
      end

      # Dropping url_schemes and going back to singleTop still strips the block.
      File.write!(path, UrlSchemes.merge_manifest(single_top(), ["operator"]))
      UrlSchemes.apply_android_manifest!(path, [])
      assert File.read!(path) == single_top()

      File.write!(path, launch_mode(~s(android:launchMode="singleInstance")))
      assert UrlSchemes.apply_android_manifest!(path, url_schemes: ["operator"]) == :ok
      assert block(File.read!(path)) =~ ~s(android:scheme="operator")
    end

    test "raises on an invalid setting without touching the file", %{tmp_dir: dir} do
      path = Path.join(dir, "AndroidManifest.xml")
      File.write!(path, @manifest)

      assert_raise Mix.Error, ~r/must be lowercase/, fn ->
        UrlSchemes.apply_android_manifest!(path, url_schemes: ["OPERATOR"])
      end

      assert File.read!(path) == @manifest
    end

    test "a missing manifest is fine unset and an error when schemes are set", %{tmp_dir: dir} do
      path = Path.join(dir, "AndroidManifest.xml")
      assert UrlSchemes.apply_android_manifest!(path, []) == :ok

      assert_raise Mix.Error,
                   ~r/url_schemes is set but .*AndroidManifest.xml can't be read/,
                   fn ->
                     UrlSchemes.apply_android_manifest!(path, url_schemes: ["operator"])
                   end
    end
  end

  defp plist(entries) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleName</key>
        <string>Demo</string>
    #{entries}
    </dict>
    </plist>
    """
  end

  @oauth """
      <key>CFBundleURLTypes</key>
      <array>
          <dict>
              <key>CFBundleURLName</key>
              <string>google</string>
              <key>CFBundleURLSchemes</key>
              <array>
                  <string>com.googleusercontent.apps.123</string>
                  <string>Operator</string>
              </array>
          </dict>
          <dict>
              <key>CFBundleURLName</key>
              <string>no-schemes</string>
          </dict>
      </array>
  """

  describe "plist_commands/3" do
    test "creates CFBundleURLTypes when the plist has none" do
      assert UrlSchemes.plist_commands(["operator", "myapp"], plist(""), "com.example.app") == [
               "Add :CFBundleURLTypes array",
               "Add :CFBundleURLTypes:0 dict",
               "Add :CFBundleURLTypes:0:CFBundleURLName string com.example.app",
               "Add :CFBundleURLTypes:0:CFBundleTypeRole string Viewer",
               "Add :CFBundleURLTypes:0:CFBundleURLSchemes array",
               "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string operator",
               "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string myapp"
             ]
    end

    test "appends after the app's entries and skips schemes it declares, any case" do
      assert UrlSchemes.plist_commands(["operator", "myapp"], plist(@oauth), "com.example.app") ==
               [
                 "Add :CFBundleURLTypes:2 dict",
                 "Add :CFBundleURLTypes:2:CFBundleURLName string com.example.app",
                 "Add :CFBundleURLTypes:2:CFBundleTypeRole string Viewer",
                 "Add :CFBundleURLTypes:2:CFBundleURLSchemes array",
                 "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string myapp"
               ]
    end

    test "nothing to do when every scheme is declared or none is set" do
      assert UrlSchemes.plist_commands(["operator"], plist(@oauth), "com.example.app") == []
      assert UrlSchemes.plist_commands([], plist(""), "com.example.app") == []
    end

    test "refuses a CFBundleURLTypes that isn't an array, and a non-XML plist" do
      bad = plist("    <key>CFBundleURLTypes</key>\n    <dict/>")

      assert_raise Mix.Error, ~r/CFBundleURLTypes isn't an array/, fn ->
        UrlSchemes.plist_commands(["operator"], bad, "com.example.app")
      end

      assert_raise Mix.Error, ~r/not an XML property list/, fn ->
        UrlSchemes.plist_commands(["operator"], "bplist00\x01\x02", "com.example.app")
      end
    end
  end

  describe "bundle_plist_commands!/3" do
    test "reads nothing when the key is unset" do
      assert UrlSchemes.bundle_plist_commands!("/nonexistent/Info.plist", [], "com.example.app") ==
               []
    end

    test "validates before reading" do
      assert_raise Mix.Error, ~r/can't claim "https"/, fn ->
        UrlSchemes.bundle_plist_commands!(
          "/nonexistent/Info.plist",
          [url_schemes: ["https"]],
          "x"
        )
      end
    end
  end
end

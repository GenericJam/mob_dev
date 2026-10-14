defmodule MobDev.ReleaseFontsTest do
  use ExUnit.Case, async: true

  # Runs release_device.sh's font block through the real bash and
  # /usr/libexec/PlistBuddy with the env MobDev.Release.ios_fonts_release_env/2
  # computes, and checks the bundle against what the dev build produces
  # (MOB-480: the release used to ship no custom fonts at all). macOS only; CI
  # on Linux excludes :macos_only.
  @moduletag :macos_only

  alias MobDev.Plugin.Assets
  alias MobDev.Release

  @plist_with_fonts """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>CFBundleName</key>
      <string>App</string>
      <key>UIAppFonts</key>
      <array>
          <string>Inter-Regular.ttf</string>
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
      <string>App</string>
  </dict>
  </plist>
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "release_fonts_#{System.unique_integer([:positive])}")
    app = Path.join(dir, "App.app")
    File.mkdir_p!(app)
    File.mkdir_p!(Path.join(dir, "style/priv/fonts"))
    File.mkdir_p!(Path.join(dir, "my fonts"))
    on_exit(fn -> File.rm_rf!(dir) end)

    fonts =
      for rel <- [
            "style/priv/fonts/EBGaramond-Medium.ttf",
            "my fonts/Inter-Regular.ttf",
            "my fonts/My Icons.otf"
          ] do
        path = Path.join(dir, rel)
        File.write!(path, "font:" <> rel)
        path
      end

    {:ok, dir: dir, app: app, fonts: fonts}
  end

  defp run_block(app, env) do
    # Up to the block's own `fi`, at the `if`'s indentation (it nests an `if`).
    [block] =
      Regex.run(
        ~r/^( *)if \[ -n "\$MOB_IOS_FONT_FILES" \]; then\n.*?^\1fi\n/ms,
        Release.release_device_sh(),
        capture: :first
      )

    System.cmd("bash", ["-e", "-c", block], env: [{"APP", app} | env], stderr_to_stdout: true)
  end

  defp ui_app_fonts(app) do
    {json, 0} =
      System.cmd("plutil", [
        "-extract",
        "UIAppFonts",
        "json",
        "-o",
        "-",
        Path.join(app, "Info.plist")
      ])

    :json.decode(json)
  end

  for {label, plist} <- [
        {"an existing UIAppFonts list", @plist_with_fonts},
        {"no UIAppFonts key", @bare_plist}
      ] do
    test "copies every font and lists it in UIAppFonts as the dev build does, with #{label}",
         %{dir: dir, app: app, fonts: fonts} do
      source_plist = Path.join(dir, "Info.plist")
      File.write!(source_plist, unquote(plist))
      File.cp!(source_plist, Path.join(app, "Info.plist"))

      {output, status} = run_block(app, Release.ios_fonts_release_env(source_plist, fonts))
      assert status == 0, output

      for font <- fonts do
        assert File.read!(Path.join(app, Path.basename(font))) == File.read!(font)
      end

      dev = unquote(plist) |> Assets.merge_ui_app_fonts(Enum.map(fonts, &Path.basename/1))
      assert ui_app_fonts(app) == Assets.parse_ui_app_fonts(dev)
    end
  end

  test "no fonts: nothing is bundled and the plist is left alone", %{dir: dir, app: app} do
    source_plist = Path.join(dir, "Info.plist")
    File.write!(source_plist, @bare_plist)
    File.cp!(source_plist, Path.join(app, "Info.plist"))

    env = Release.ios_fonts_release_env(Path.join(dir, "missing.plist"), [])
    assert {_, 0} = run_block(app, env)

    assert File.read!(Path.join(app, "Info.plist")) == @bare_plist
    assert File.ls!(app) == ["Info.plist"]
  end

  test "two fonts with one bundle name fail the release before any build", %{
    dir: dir,
    fonts: fonts
  } do
    File.write!(Path.join(dir, "Info.plist"), @bare_plist)
    clash = Path.join(dir, "style/priv/fonts/Inter-Regular.ttf")
    File.write!(clash, "other")

    assert_raise Mix.Error, ~r/Inter-Regular\.ttf/, fn ->
      Release.ios_fonts_release_env(Path.join(dir, "Info.plist"), [clash | fonts])
    end
  end
end

defmodule MobDev.BundleResourcesTest do
  # Changes the working directory: the build reads the project from it.
  use ExUnit.Case, async: false

  alias MobDev.NativeBuild

  setup do
    cwd = File.cwd!()
    dir = Path.join(System.tmp_dir!(), "bundle_resources_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "ios"))
    File.cd!(dir)

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(dir)
    end)

    {:ok, app: Path.join(dir, "Build/App.app")}
  end

  test "copies each ios/<lang>.lproj and the privacy manifest to the bundle's root", %{app: app} do
    File.mkdir_p!(app)
    File.mkdir_p!("ios/fr.lproj")
    File.write!("ios/fr.lproj/InfoPlist.strings", ~s("NSCameraUsageDescription" = "Photo";\n))
    File.mkdir_p!("ios/en.lproj")
    File.write!("ios/en.lproj/InfoPlist.strings", ~s("NSCameraUsageDescription" = "Photo";\n))
    File.write!("ios/PrivacyInfo.xcprivacy", "<plist/>")
    # Not a localization: left out.
    File.write!("ios/notes.lproj", "a file, not a directory")

    assert NativeBuild.copy_bundle_resources!(app) == :ok

    assert File.read!(Path.join(app, "fr.lproj/InfoPlist.strings")) =~ "NSCameraUsageDescription"
    assert File.exists?(Path.join(app, "en.lproj/InfoPlist.strings"))
    assert File.read!(Path.join(app, "PrivacyInfo.xcprivacy")) == "<plist/>"
    refute File.exists?(Path.join(app, "notes.lproj"))
  end

  test "an app with neither copies nothing", %{app: app} do
    File.mkdir_p!(app)
    assert NativeBuild.copy_bundle_resources!(app) == :ok
    assert File.ls!(app) == []
  end
end

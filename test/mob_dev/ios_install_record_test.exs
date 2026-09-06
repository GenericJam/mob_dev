defmodule MobDev.IOSInstallRecordTest do
  @moduledoc """
  Pins the invariant the MOB-70 kill scope rests on.

  The registry translates between a bundle id (how we address an app) and a
  `.app` name (all a running process exposes). If those two helpers ever
  disagree with how the app is actually built, the registry records a name that
  never matches a running process — the kill scope silently becomes empty, and
  every second Mob app on a device fails to boot with no diagnostic. Nothing
  crashes; it just stops working.
  """
  use ExUnit.Case, async: false

  alias MobDev.NativeBuild

  test "the recorded app name is the .app bundle basename" do
    # The build copies the binary to `<name>.app/<name>` and sets
    # CFBundleExecutable to the same, so bundle dir basename == executable
    # name == what shows up in `devicectl device info processes`.
    assert NativeBuild.app_name_for("/tmp/build/Demo.app") == "Demo"
    assert NativeBuild.app_name_for("Demo.app") == "Demo"
    assert NativeBuild.app_name_for("/a/b/My App.app") == "My App"
  end

  test "the recorded bundle id is the iOS one, where it differs from the Android one" do
    # Must be ios_bundle_id/0, not bundle_id/0. Apple forbids underscores and a
    # com.example.* id is often already claimed by another team, so the two
    # legitimately differ — and recording the Android id would make the entry
    # unmatchable when the launcher later looks the app up by its iOS id.
    #
    # Asserted against a config where they actually differ, because in a
    # project where they happen to coincide this test cannot fail and would be
    # evidence of nothing.
    dir = Path.join(System.tmp_dir!(), "mob70_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "mob.exs"), """
    import Config
    config :mob_dev, bundle_id: "com.example.android_id", ios_bundle_id: "com.example.iosid"
    """)

    original = File.cwd!()

    try do
      File.cd!(dir)
      assert MobDev.Config.bundle_id() == "com.example.android_id"
      assert MobDev.Config.ios_bundle_id() == "com.example.iosid"
      assert NativeBuild.bundle_id_for("/tmp/build/Demo.app") == "com.example.iosid"
    after
      File.cd!(original)
      File.rm_rf(dir)
    end
  end

  test "an app name round-trips through the registry into a kill decision" do
    # The whole chain in one assertion: what install records is what the
    # process listing is matched against.
    app_path = "/tmp/build/Demo.app"
    name = NativeBuild.app_name_for(app_path)

    processes = """
       7911   /private/var/containers/Bundle/Application/AAAA/#{name}.app/#{name}
    """

    assert MobDev.Discovery.IOS.mob_pids_to_kill(processes, [name], nil) == [7911]
  end
end

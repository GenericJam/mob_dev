defmodule Mix.Tasks.Mob.RegenDriverTabTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Mob.RegenDriverTab

  setup do
    cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "mob_regen_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(tmp)
      Application.delete_env(:mob_dev, :static_nifs)
    end)

    %{tmp: tmp}
  end

  describe "default run with new template (Phase 6a iter 4 — Zig)" do
    setup %{tmp: tmp} do
      # Simulate a project whose build.zig has the addZigObject helper.
      File.mkdir_p!(Path.join(tmp, "ios"))
      File.write!(Path.join(tmp, "ios/build.zig"), "fn addZigObject(opts: anytype) void {}\n")
      :ok
    end

    test "auto-detects and writes .zig when build.zig has addZigObject" do
      capture_run([])

      paths = RegenDriverTab.target_paths(:zig)
      assert File.exists?(paths.ios)
      assert File.exists?(paths.android)
      c_paths = RegenDriverTab.target_paths(:c)
      refute File.exists?(c_paths.ios)
      refute File.exists?(c_paths.android)
    end

    test "iOS Zig output uses comptime sqlite_static (no #ifdef)" do
      capture_run([])
      ios_src = File.read!(RegenDriverTab.target_paths(:zig).ios)

      refute ios_src =~ "#ifdef MOB_STATIC_SQLITE_NIF"
      assert ios_src =~ "sqlite_static"
      assert ios_src =~ "sqlite3_nif_nif_init"
    end

    test "Android Zig output omits sqlite3_nif" do
      capture_run([])
      android_src = File.read!(RegenDriverTab.target_paths(:zig).android)

      refute android_src =~ "sqlite3_nif"
      refute android_src =~ "sqlite_static"
    end
  end

  describe "default run with legacy template (no addZigObject → fall back to C)" do
    setup %{tmp: tmp} do
      # Simulate a project whose build.zig predates Phase 6a iter 2.
      # The auto-detect path falls back to :c so the legacy addCObject →
      # addCSourceFile chain keeps working.
      File.mkdir_p!(Path.join(tmp, "ios"))
      File.write!(Path.join(tmp, "ios/build.zig"), "fn addCObject(opts: anytype) void {}\n")
      :ok
    end

    test "auto-detects and writes .c when build.zig lacks addZigObject" do
      capture_run([])

      paths = RegenDriverTab.target_paths(:c)
      assert File.exists?(paths.ios)
      assert File.exists?(paths.android)
      zig_paths = RegenDriverTab.target_paths(:zig)
      refute File.exists?(zig_paths.ios)
      refute File.exists?(zig_paths.android)
    end

    test "iOS C output gates sqlite3_nif under MOB_STATIC_SQLITE_NIF" do
      capture_run([])
      ios_src = File.read!(RegenDriverTab.target_paths(:c).ios)

      assert ios_src =~ "#ifdef MOB_STATIC_SQLITE_NIF"
      assert ios_src =~ "sqlite3_nif_nif_init"
    end
  end

  describe "--format c (opt-out for hand-editable C)" do
    test "writes .c paths instead of .zig when requested" do
      capture_run(["--format", "c"])
      c = RegenDriverTab.target_paths(:c)
      zig = RegenDriverTab.target_paths(:zig)
      assert File.exists?(c.ios)
      assert File.exists?(c.android)
      refute File.exists?(zig.ios)
      refute File.exists?(zig.android)
    end

    test "C output uses #ifdef MOB_STATIC_SQLITE_NIF (legacy behavior)" do
      capture_run(["--format", "c"])
      ios_src = File.read!(RegenDriverTab.target_paths(:c).ios)
      assert ios_src =~ "#ifdef MOB_STATIC_SQLITE_NIF"
    end
  end

  describe ":static_nifs from app config" do
    test "user-declared NIFs appear in the generated tables" do
      Application.put_env(:mob_dev, :static_nifs, [%{module: :foo_native}])

      capture_run([])
      paths = RegenDriverTab.target_paths(:zig)

      assert File.read!(paths.ios) =~ "foo_native_nif_init"
      assert File.read!(paths.android) =~ "foo_native_nif_init"
    end

    test "invalid entry raises Mix.Error with a useful message" do
      Application.put_env(:mob_dev, :static_nifs, [%{module: :broken, archs: [:windows]}])

      assert_raise Mix.Error, ~r/unknown archs/, fn ->
        RegenDriverTab.run([])
      end
    end
  end

  describe "--check mode" do
    test "passes silently when files match" do
      capture_run([])
      # Re-run in --check mode against fresh files — no drift, so
      # no Mix.raise; the success path prints "files match :static_nifs".
      out = capture_run(["--check"])
      assert out =~ "files match"
      refute out =~ "drift"
    end

    test "raises with a list of drifted paths" do
      capture_run([])
      paths = RegenDriverTab.target_paths(:zig)
      File.write!(paths.ios, "// tampered\n")

      assert_raise Mix.Error, ~r/driver_tab drift detected/, fn ->
        RegenDriverTab.run(["--check"])
      end
    end
  end

  describe "deterministic output" do
    test "two regen runs against the same manifest produce identical bytes" do
      capture_run([])
      paths = RegenDriverTab.target_paths(:zig)
      first_ios = File.read!(paths.ios)
      first_android = File.read!(paths.android)

      capture_run([])
      assert File.read!(paths.ios) == first_ios
      assert File.read!(paths.android) == first_android
    end

    test "second run reports 'unchanged' rather than rewriting" do
      capture_run([])
      out = capture_run([])

      assert out =~ "(unchanged)"
    end
  end

  defp capture_run(args) do
    ExUnit.CaptureIO.capture_io(fn -> RegenDriverTab.run(args) end)
  end

  describe "reject_uncompiled_plugin_nifs/2" do
    @c_nif %{module: :mob_location_nif, native_dir: "/x", lang: :c}
    # a plugin NIF with no :lang defaults to C
    @default_nif %{module: :mob_photos_nif, native_dir: "/y"}
    @zig_nif %{module: :mob_bluetooth_nif, native_dir: "/z", lang: :zig}

    test ":ios drops zig plugin NIFs (no iOS zig compile path) but keeps C ones" do
      nifs = [@c_nif, @default_nif, @zig_nif]
      kept = RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :ios)
      assert @c_nif in kept
      assert @default_nif in kept
      refute @zig_nif in kept
    end

    test ":android and :all keep C and zig plugin NIFs (both langs compile there)" do
      nifs = [@c_nif, @default_nif, @zig_nif]
      assert RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :android) == nifs
      assert RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :all) == nifs
    end

    @objc_nif %{module: :perm_nif, native_dir: "/o", lang: :objc}

    test ":android drops objc plugin NIFs (no Android Obj-C runtime), iOS/:all keep them" do
      nifs = [@c_nif, @objc_nif, @zig_nif]
      refute @objc_nif in RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :android)
      assert @objc_nif in RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :ios)
      assert @objc_nif in RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :all)
    end

    @ios_only %{module: :mob_location_nif, native_dir: "/i", lang: :c, platform: :ios}
    @android_only %{module: :mob_location_nif, native_dir: "/a", lang: :zig, platform: :android}

    test "platform-tagged NIFs only survive on their own platform" do
      nifs = [@ios_only, @android_only, @default_nif]

      ios = RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :ios)
      assert @ios_only in ios
      assert @default_nif in ios
      refute @android_only in ios

      android = RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :android)
      assert @android_only in android
      assert @default_nif in android
      refute @ios_only in android

      assert RegenDriverTab.reject_uncompiled_plugin_nifs(nifs, :all) == nifs
    end
  end
end

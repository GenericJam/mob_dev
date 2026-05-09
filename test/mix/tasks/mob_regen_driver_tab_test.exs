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

  describe "default run" do
    test "generates both driver_tab files" do
      capture_run([])

      paths = RegenDriverTab.target_paths()
      assert File.exists?(paths.ios)
      assert File.exists?(paths.android)
    end

    test "generated files contain mob_nif_init for both platforms" do
      capture_run([])
      paths = RegenDriverTab.target_paths()

      assert File.read!(paths.ios) =~ "mob_nif_nif_init"
      assert File.read!(paths.android) =~ "mob_nif_nif_init"
    end

    test "iOS output gates sqlite3_nif under MOB_STATIC_SQLITE_NIF" do
      capture_run([])
      ios_src = File.read!(RegenDriverTab.target_paths().ios)

      assert ios_src =~ "#ifdef MOB_STATIC_SQLITE_NIF"
      assert ios_src =~ "sqlite3_nif_nif_init"
    end

    test "Android output omits sqlite3_nif" do
      capture_run([])
      android_src = File.read!(RegenDriverTab.target_paths().android)

      refute android_src =~ "sqlite3_nif"
      refute android_src =~ "MOB_STATIC_SQLITE_NIF"
    end
  end

  describe ":static_nifs from app config" do
    test "user-declared NIFs appear in the generated tables" do
      Application.put_env(:mob_dev, :static_nifs, [%{module: :foo_native}])

      capture_run([])
      paths = RegenDriverTab.target_paths()

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
      # Re-run in --check mode against fresh files
      capture_run(["--check"])
    end

    test "raises with a list of drifted paths" do
      capture_run([])
      paths = RegenDriverTab.target_paths()
      File.write!(paths.ios, "// tampered\n")

      assert_raise Mix.Error, ~r/driver_tab drift detected/, fn ->
        RegenDriverTab.run(["--check"])
      end
    end
  end

  describe "deterministic output" do
    test "two regen runs against the same manifest produce identical bytes" do
      capture_run([])
      paths = RegenDriverTab.target_paths()
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
end

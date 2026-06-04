defmodule MobDev.PythonAppleSupportTest do
  # async: false — these tests mutate the global MOB_CACHE_DIR env var, which
  # races other modules that read/write it (python_android_support, the *_downloader
  # tests). Matches the async: false convention of every other MOB_CACHE_DIR test.
  use ExUnit.Case, async: false

  alias MobDev.PythonAppleSupport

  # ── extracted_dir/0, cache_dir/0 ────────────────────────────────────────────

  describe "extracted_dir/0" do
    test "honors MOB_CACHE_DIR env var" do
      System.put_env("MOB_CACHE_DIR", "/tmp/mob_test_cache")

      try do
        path = PythonAppleSupport.extracted_dir()
        assert String.starts_with?(path, "/tmp/mob_test_cache/")
        assert String.ends_with?(path, "/extracted")
      after
        System.delete_env("MOB_CACHE_DIR")
      end
    end

    test "defaults to ~/.mob/cache when MOB_CACHE_DIR unset" do
      System.delete_env("MOB_CACHE_DIR")
      home = System.get_env("HOME")
      path = PythonAppleSupport.extracted_dir()
      assert String.starts_with?(path, "#{home}/.mob/cache/")
    end
  end

  # ── valid_dir?/1 ────────────────────────────────────────────────────────────

  describe "valid_dir?/1" do
    @tag :tmp_dir
    test "returns false when dir doesn't exist", %{tmp_dir: tmp} do
      refute PythonAppleSupport.valid_dir?(Path.join(tmp, "nonexistent"))
    end

    @tag :tmp_dir
    test "returns false when xcframework missing", %{tmp_dir: tmp} do
      refute PythonAppleSupport.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns false when only sim slice present", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "Python.xcframework", "ios-arm64_x86_64-simulator"]))
      refute PythonAppleSupport.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns false when device + sim present but stdlib missing", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "Python.xcframework", "ios-arm64"]))
      File.mkdir_p!(Path.join([tmp, "Python.xcframework", "ios-arm64_x86_64-simulator"]))
      refute PythonAppleSupport.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns true when full bundle present", %{tmp_dir: tmp} do
      stub_full_bundle(tmp)
      assert PythonAppleSupport.valid_dir?(tmp)
    end
  end

  # ── framework_path/1 ────────────────────────────────────────────────────────

  describe "framework_path/1" do
    test "ios_device slice uses ios-arm64" do
      assert PythonAppleSupport.framework_path("/tmp/x", :ios_device) ==
               "/tmp/x/Python.xcframework/ios-arm64/Python.framework"
    end

    test "ios_simulator slice uses ios-arm64_x86_64-simulator" do
      assert PythonAppleSupport.framework_path("/tmp/x", :ios_simulator) ==
               "/tmp/x/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework"
    end
  end

  # ── stdlib_path/1 ───────────────────────────────────────────────────────────

  describe "stdlib_path/1" do
    test "returns shared stdlib at lib/python<version>" do
      assert PythonAppleSupport.stdlib_path("/tmp/x") ==
               "/tmp/x/Python.xcframework/lib/python3.13"
    end
  end

  # ── lib_dynload_path/2 ──────────────────────────────────────────────────────

  describe "lib_dynload_path/2" do
    test "ios_device slice uses lib-arm64 under ios-arm64/" do
      assert PythonAppleSupport.lib_dynload_path("/tmp/x", :ios_device) ==
               "/tmp/x/Python.xcframework/ios-arm64/lib-arm64/python3.13/lib-dynload"
    end

    test "ios_simulator slice uses lib-arm64 under ios-arm64_x86_64-simulator/" do
      assert PythonAppleSupport.lib_dynload_path("/tmp/x", :ios_simulator) ==
               "/tmp/x/Python.xcframework/ios-arm64_x86_64-simulator/lib-arm64/python3.13/lib-dynload"
    end
  end

  # ── download_url/0, tarball_name/0 ──────────────────────────────────────────

  describe "download_url/0" do
    test "points at BeeWare's GitHub release for the pinned tag" do
      url = PythonAppleSupport.download_url()

      assert String.starts_with?(
               url,
               "https://github.com/beeware/Python-Apple-support/releases/download/"
             )

      assert String.ends_with?(url, ".tar.gz")
    end
  end

  describe "tarball_name/0" do
    test "matches BeeWare's naming convention Python-X.Y-iOS-support.bN.tar.gz" do
      assert Regex.match?(
               ~r/^Python-3\.13-iOS-support\.b\d+\.tar\.gz$/,
               PythonAppleSupport.tarball_name()
             )
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp stub_full_bundle(tmp) do
    base = Path.join(tmp, "Python.xcframework")
    File.mkdir_p!(Path.join([base, "ios-arm64", "Python.framework"]))
    File.mkdir_p!(Path.join([base, "ios-arm64", "lib-arm64", "python3.13", "lib-dynload"]))
    File.mkdir_p!(Path.join([base, "ios-arm64_x86_64-simulator", "Python.framework"]))

    File.mkdir_p!(
      Path.join([base, "ios-arm64_x86_64-simulator", "lib-arm64", "python3.13", "lib-dynload"])
    )

    File.mkdir_p!(Path.join([base, "lib", "python3.13"]))
    # Stub a few stdlib files so the dir isn't empty.
    File.write!(Path.join([base, "lib", "python3.13", "os.py"]), "")
  end
end

defmodule MobDev.PythonAndroidSupportTest do
  # async: false — these tests mutate the global MOB_CACHE_DIR env var, which
  # races other modules that read/write it (python_apple_support, the *_downloader
  # tests). Matches the async: false convention of every other MOB_CACHE_DIR test.
  use ExUnit.Case, async: false

  alias MobDev.PythonAndroidSupport

  # ── extracted_dir/0 ─────────────────────────────────────────────────────────

  describe "extracted_dir/0" do
    test "honors MOB_CACHE_DIR env var" do
      System.put_env("MOB_CACHE_DIR", "/tmp/mob_test_cache_android")

      try do
        path = PythonAndroidSupport.extracted_dir()
        assert String.starts_with?(path, "/tmp/mob_test_cache_android/")
        assert String.ends_with?(path, "/extracted")
      after
        System.delete_env("MOB_CACHE_DIR")
      end
    end

    test "defaults to ~/.mob/cache when MOB_CACHE_DIR unset" do
      System.delete_env("MOB_CACHE_DIR")
      home = System.get_env("HOME")
      path = PythonAndroidSupport.extracted_dir()
      assert String.starts_with?(path, "#{home}/.mob/cache/")
    end
  end

  # ── valid_dir?/1 ────────────────────────────────────────────────────────────

  describe "valid_dir?/1" do
    @tag :tmp_dir
    test "returns false when dir doesn't exist", %{tmp_dir: tmp} do
      refute PythonAndroidSupport.valid_dir?(Path.join(tmp, "nonexistent"))
    end

    @tag :tmp_dir
    test "returns false when only stdlib present (missing arm64 libs)", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "stdlib"))
      refute PythonAndroidSupport.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns false when arm64-v8a libs missing libpython.so", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "arm64-v8a", "jniLibs", "arm64-v8a"]))
      File.mkdir_p!(Path.join(tmp, "stdlib"))
      refute PythonAndroidSupport.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns true when full bundle present", %{tmp_dir: tmp} do
      stub_full_bundle(tmp)
      assert PythonAndroidSupport.valid_dir?(tmp)
    end
  end

  # ── libpython_path/2 ───────────────────────────────────────────────────────

  describe "libpython_path/2" do
    test "arm64-v8a uses jniLibs/arm64-v8a/libpython3.13.so" do
      assert PythonAndroidSupport.libpython_path("/tmp/x", "arm64-v8a") ==
               "/tmp/x/arm64-v8a/jniLibs/arm64-v8a/libpython3.13.so"
    end

    test "x86_64 uses jniLibs/x86_64" do
      assert PythonAndroidSupport.libpython_path("/tmp/x", "x86_64") ==
               "/tmp/x/x86_64/jniLibs/x86_64/libpython3.13.so"
    end
  end

  # ── jni_libs_dir/2 ──────────────────────────────────────────────────────────

  describe "jni_libs_dir/2" do
    test "arm64-v8a points at the per-abi jniLibs subtree" do
      assert PythonAndroidSupport.jni_libs_dir("/tmp/x", "arm64-v8a") ==
               "/tmp/x/arm64-v8a/jniLibs/arm64-v8a"
    end
  end

  # ── lib_dynload_dir/2 ───────────────────────────────────────────────────────

  describe "lib_dynload_dir/2" do
    test "arm64-v8a points at the per-abi lib-dynload subtree" do
      assert PythonAndroidSupport.lib_dynload_dir("/tmp/x", "arm64-v8a") ==
               "/tmp/x/arm64-v8a/lib-dynload/arm64-v8a"
    end
  end

  # ── stdlib_dir/1 ────────────────────────────────────────────────────────────

  describe "stdlib_dir/1" do
    test "shared across abis (no per-arch suffix)" do
      assert PythonAndroidSupport.stdlib_dir("/tmp/x") == "/tmp/x/stdlib"
    end
  end

  # ── headers_dir/2 ───────────────────────────────────────────────────────────

  describe "headers_dir/2" do
    test "arm64-v8a points at include/python3.13" do
      assert PythonAndroidSupport.headers_dir("/tmp/x", "arm64-v8a") ==
               "/tmp/x/arm64-v8a/include/python3.13"
    end
  end

  # ── download_url/1 + per-abi tarball naming ────────────────────────────────

  describe "download_url/1" do
    test "arm64-v8a points at chaquopy's Maven release" do
      url = PythonAndroidSupport.download_url("arm64-v8a")

      assert String.starts_with?(
               url,
               "https://repo1.maven.org/maven2/com/chaquo/python/target/"
             )

      assert String.ends_with?(url, "-arm64-v8a.zip")
    end

    test "stdlib uses the stdlib variant" do
      assert PythonAndroidSupport.download_url("stdlib") =~ "-stdlib.zip"
    end

    test "x86_64 emulator slice has its own URL" do
      assert PythonAndroidSupport.download_url("x86_64") =~ "-x86_64.zip"
    end
  end

  describe "tarball_name/1" do
    test "arm64-v8a follows chaquopy's pattern" do
      assert Regex.match?(
               ~r/^target-3\.13\.\d+-\d+-arm64-v8a\.zip$/,
               PythonAndroidSupport.tarball_name("arm64-v8a")
             )
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp stub_full_bundle(tmp) do
    for abi <- ["arm64-v8a", "x86_64"] do
      base = Path.join(tmp, abi)
      File.mkdir_p!(Path.join([base, "jniLibs", abi]))
      File.write!(Path.join([base, "jniLibs", abi, "libpython3.13.so"]), <<>>)
      File.mkdir_p!(Path.join([base, "lib-dynload", abi]))
      File.mkdir_p!(Path.join([base, "include", "python3.13"]))
    end

    stdlib = Path.join(tmp, "stdlib")
    File.mkdir_p!(stdlib)
    File.write!(Path.join(stdlib, "os.py"), <<>>)
  end
end

defmodule MobDev.NativeBuildTfliteTest do
  use ExUnit.Case, async: true

  alias MobDev.NativeBuild

  # ── tflite_zig_args_android/1 ──────────────────────────────────────────────

  describe "tflite_zig_args_android/1" do
    test "nil → []" do
      assert NativeBuild.tflite_zig_args_android(nil) == []
    end

    test "build map → -Dtflite_static + -Dtflite_lib" do
      args =
        NativeBuild.tflite_zig_args_android(%{
          archive: "/build/tflite/android_arm64/libtflite_nif.a",
          tflite_dir: "/cache/tflite-2.16.1-android_arm64"
        })

      assert "-Dtflite_static=true" in args
      assert "-Dtflite_lib=/build/tflite/android_arm64/libtflite_nif.a" in args
    end

    test "android passes the archive path directly (not dirname)" do
      # The Android build.zig uses the .a path verbatim — different
      # convention from iOS which uses the dir. Lock that in.
      args =
        NativeBuild.tflite_zig_args_android(%{
          archive: "/x/libtflite_nif.a",
          tflite_dir: "/y"
        })

      refute "-Dtflite_lib=/x" in args
      assert "-Dtflite_lib=/x/libtflite_nif.a" in args
    end
  end

  # ── tflite_zig_args_ios/1 ──────────────────────────────────────────────────

  describe "tflite_zig_args_ios/1" do
    test "nil → []" do
      assert NativeBuild.tflite_zig_args_ios(nil) == []
    end

    test "build map → -Dtflite_static + -Dtflite_dir + -Dtflite_framework_dir" do
      args =
        NativeBuild.tflite_zig_args_ios(%{
          archive: "/build/tflite/ios_device/libtflite_nif.a",
          tflite_dir: "/cache/tflite-2.17.0-ios_device"
        })

      assert "-Dtflite_static=true" in args
      assert "-Dtflite_dir=/build/tflite/ios_device" in args
      assert "-Dtflite_framework_dir=/cache/tflite-2.17.0-ios_device/Frameworks" in args
    end

    test "iOS uses the dirname of the archive path (not the path itself)" do
      args =
        NativeBuild.tflite_zig_args_ios(%{
          archive: "/x/libtflite_nif.a",
          tflite_dir: "/y"
        })

      assert "-Dtflite_dir=/x" in args
      refute "-Dtflite_dir=/x/libtflite_nif.a" in args
    end

    test "iOS framework dir is rooted at tflite_dir/Frameworks" do
      args =
        NativeBuild.tflite_zig_args_ios(%{
          archive: "/build/libtflite_nif.a",
          tflite_dir: "/cache/somewhere"
        })

      assert "-Dtflite_framework_dir=/cache/somewhere/Frameworks" in args
    end
  end

  # ── copy_tflite_runtime_lib_android/2 ──────────────────────────────────────

  describe "copy_tflite_runtime_lib_android/3" do
    # Each test gets its own project_root under /tmp so we don't have to
    # cd around (which races other tests' compilation when run in
    # parallel — see helpers_test.exs's async:false comment).
    setup do
      project_root =
        Path.join([
          System.tmp_dir!(),
          "mob_test_tflite_runtime_#{System.unique_integer([:positive])}"
        ])

      File.rm_rf!(project_root)
      File.mkdir_p!(project_root)
      on_exit(fn -> File.rm_rf!(project_root) end)
      {:ok, project_root: project_root}
    end

    test "nil tflite_build → :ok, no copy", %{project_root: root} do
      assert NativeBuild.copy_tflite_runtime_lib_android(nil, "arm64-v8a", root) == :ok

      refute File.exists?(
               Path.join(root, "android/app/src/main/jniLibs/arm64-v8a/libtensorflowlite_jni.so")
             )
    end

    test "copies .so to jniLibs/<abi>/", %{project_root: root} do
      tflite_dir = Path.join(root, "fake_tflite_cache")
      src_so = Path.join([tflite_dir, "jni", "arm64-v8a", "libtensorflowlite_jni.so"])
      File.mkdir_p!(Path.dirname(src_so))
      File.write!(src_so, "fake .so content")

      assert NativeBuild.copy_tflite_runtime_lib_android(
               %{tflite_dir: tflite_dir},
               "arm64-v8a",
               root
             ) == :ok

      dst = Path.join(root, "android/app/src/main/jniLibs/arm64-v8a/libtensorflowlite_jni.so")
      assert File.exists?(dst)
      assert File.read!(dst) == "fake .so content"
    end

    test "raises when the source .so is missing", %{project_root: root} do
      tflite_dir = Path.join(root, "empty_cache")
      File.mkdir_p!(tflite_dir)

      assert_raise RuntimeError, ~r/TFLite runtime lib missing/, fn ->
        NativeBuild.copy_tflite_runtime_lib_android(
          %{tflite_dir: tflite_dir},
          "arm64-v8a",
          root
        )
      end
    end

    test "uses the abi parameter (not hardcoded arm64-v8a)", %{project_root: root} do
      tflite_dir = Path.join(root, "armv7_cache")
      src_so = Path.join([tflite_dir, "jni", "armeabi-v7a", "libtensorflowlite_jni.so"])
      File.mkdir_p!(Path.dirname(src_so))
      File.write!(src_so, "armv7 .so")

      assert NativeBuild.copy_tflite_runtime_lib_android(
               %{tflite_dir: tflite_dir},
               "armeabi-v7a",
               root
             ) == :ok

      assert File.exists?(
               Path.join(
                 root,
                 "android/app/src/main/jniLibs/armeabi-v7a/libtensorflowlite_jni.so"
               )
             )
    end
  end

  # ── copy_tflite_frameworks_ios/3 ───────────────────────────────────────────

  describe "copy_tflite_frameworks_ios/3" do
    test "nil tflite_build → :ok (no-op)" do
      assert NativeBuild.copy_tflite_frameworks_ios(nil, "ios-arm64", "/anywhere") == :ok
    end

    test "build map → :ok (currently a no-op stub since framework binaries are MH_OBJECT)" do
      # The function is kept as a hook for a future TFLite release that
      # ships MH_DYLIB frameworks (which would actually need embedding).
      # For now MH_OBJECT binaries get linked statically into the app at
      # build time, so embedding is unnecessary AND harmful (codesign
      # rejects MH_OBJECT signatures on iOS 17+).
      assert NativeBuild.copy_tflite_frameworks_ios(
               %{tflite_dir: "/whatever"},
               "ios-arm64",
               "/whatever/.app/Frameworks"
             ) == :ok
    end
  end
end

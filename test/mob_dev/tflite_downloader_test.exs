defmodule MobDev.TfliteDownloaderTest do
  # async: false — these tests set/unset MOB_CACHE_DIR /
  # MOB_TFLITE_LOCAL_TARBALL_DIR which are process-global. Mirrors the
  # MLXDownloaderTest contract.
  use ExUnit.Case, async: false

  alias MobDev.TfliteDownloader

  # ── dir/1 + cache_dir/0 ─────────────────────────────────────────────────────

  describe "dir/1" do
    setup do
      System.put_env("MOB_CACHE_DIR", "/tmp/mob_test_cache_tflite")
      on_exit(fn -> System.delete_env("MOB_CACHE_DIR") end)
      :ok
    end

    test "android_arm64 lands in versioned cache slot" do
      assert TfliteDownloader.dir(:android_arm64) ==
               "/tmp/mob_test_cache_tflite/tflite-#{TfliteDownloader.android_version()}-android_arm64"
    end

    test "android_arm32 distinct from arm64" do
      refute TfliteDownloader.dir(:android_arm32) == TfliteDownloader.dir(:android_arm64)
    end

    test "ios_device distinct from ios_sim" do
      refute TfliteDownloader.dir(:ios_device) == TfliteDownloader.dir(:ios_sim)
    end

    test "ios paths use ios_version, android paths use android_version" do
      assert TfliteDownloader.dir(:android_arm64) =~ TfliteDownloader.android_version()
      assert TfliteDownloader.dir(:ios_device) =~ TfliteDownloader.ios_version()
    end
  end

  describe "cache_dir/0" do
    test "honours MOB_CACHE_DIR" do
      System.put_env("MOB_CACHE_DIR", "/tmp/explicit_cache_path")

      try do
        assert TfliteDownloader.cache_dir() == "/tmp/explicit_cache_path"
      after
        System.delete_env("MOB_CACHE_DIR")
      end
    end

    test "falls back to ~/.mob/cache when env unset" do
      System.delete_env("MOB_CACHE_DIR")
      home = System.user_home!()
      assert TfliteDownloader.cache_dir() == Path.join([home, ".mob", "cache"])
    end

    test "treats empty MOB_CACHE_DIR as unset" do
      System.put_env("MOB_CACHE_DIR", "")

      try do
        home = System.user_home!()
        assert TfliteDownloader.cache_dir() == Path.join([home, ".mob", "cache"])
      after
        System.delete_env("MOB_CACHE_DIR")
      end
    end
  end

  # ── valid_dir?/2 ───────────────────────────────────────────────────────────

  describe "valid_dir?/2" do
    test "android_arm64 requires .so + headers" do
      dir = "/tmp/tflite_valid_test_android"
      File.rm_rf!(dir)

      refute TfliteDownloader.valid_dir?(:android_arm64, dir)

      File.mkdir_p!(Path.join([dir, "jni", "arm64-v8a"]))
      File.touch!(Path.join([dir, "jni", "arm64-v8a", "libtensorflowlite_jni.so"]))
      refute TfliteDownloader.valid_dir?(:android_arm64, dir)

      File.mkdir_p!(Path.join([dir, "headers", "tensorflow", "lite", "c"]))
      File.touch!(Path.join([dir, "headers", "tensorflow", "lite", "c", "c_api.h"]))
      assert TfliteDownloader.valid_dir?(:android_arm64, dir)

      File.rm_rf!(dir)
    end

    test "ios_device requires framework binary + headers" do
      dir = "/tmp/tflite_valid_test_ios"
      File.rm_rf!(dir)

      refute TfliteDownloader.valid_dir?(:ios_device, dir)

      fw_root =
        Path.join([
          dir,
          "Frameworks",
          "TensorFlowLiteC.xcframework",
          "ios-arm64",
          "TensorFlowLiteC.framework"
        ])

      File.mkdir_p!(Path.join(fw_root, "Headers"))
      File.touch!(Path.join(fw_root, "TensorFlowLiteC"))
      File.touch!(Path.join([fw_root, "Headers", "c_api.h"]))
      assert TfliteDownloader.valid_dir?(:ios_device, dir)

      File.rm_rf!(dir)
    end

    test "ios_sim uses the simulator slice subdir" do
      dir = "/tmp/tflite_valid_test_ios_sim"
      File.rm_rf!(dir)

      # Putting only the device slice does NOT satisfy ios_sim's check.
      device_fw =
        Path.join([
          dir,
          "Frameworks",
          "TensorFlowLiteC.xcframework",
          "ios-arm64",
          "TensorFlowLiteC.framework"
        ])

      File.mkdir_p!(Path.join(device_fw, "Headers"))
      File.touch!(Path.join(device_fw, "TensorFlowLiteC"))
      File.touch!(Path.join([device_fw, "Headers", "c_api.h"]))
      refute TfliteDownloader.valid_dir?(:ios_sim, dir)

      sim_fw =
        Path.join([
          dir,
          "Frameworks",
          "TensorFlowLiteC.xcframework",
          "ios-arm64_x86_64-simulator",
          "TensorFlowLiteC.framework"
        ])

      File.mkdir_p!(Path.join(sim_fw, "Headers"))
      File.touch!(Path.join(sim_fw, "TensorFlowLiteC"))
      File.touch!(Path.join([sim_fw, "Headers", "c_api.h"]))
      assert TfliteDownloader.valid_dir?(:ios_sim, dir)

      File.rm_rf!(dir)
    end
  end

  # ── version pins ───────────────────────────────────────────────────────────

  describe "version pins" do
    test "android version is the last AAR-shipping release (2.16.1)" do
      # The pin matters: 2.17.0+ Maven artifacts dropped the .aar packaging
      # in favour of .jar-only (Java wrapper, no native libs). Bumping
      # past this needs a new upstream native-lib distribution story.
      assert TfliteDownloader.android_version() == "2.16.1"
    end

    test "ios version is a real CocoaPods release" do
      # Sanity check — must be `MAJOR.MINOR.PATCH`, three numerics. If
      # this drifts to a nightly tag the dl.google.com URL pattern will
      # also need updating.
      assert Regex.match?(~r/^\d+\.\d+\.\d+$/, TfliteDownloader.ios_version())
    end
  end
end

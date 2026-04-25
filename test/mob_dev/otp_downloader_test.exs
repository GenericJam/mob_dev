defmodule MobDev.OtpDownloaderTest do
  use ExUnit.Case, async: true

  alias MobDev.OtpDownloader

  describe "android_otp_dir/1" do
    test "default (no arg) returns arm64 path" do
      assert OtpDownloader.android_otp_dir() == OtpDownloader.android_otp_dir("arm64-v8a")
    end

    test "arm64-v8a returns a path containing the arm64 artifact name" do
      path = OtpDownloader.android_otp_dir("arm64-v8a")
      assert path =~ "otp-android-"
      refute path =~ "arm32"
    end

    test "armeabi-v7a returns a path containing the arm32 artifact name" do
      path = OtpDownloader.android_otp_dir("armeabi-v7a")
      assert path =~ "otp-android-arm32-"
    end

    test "unknown ABI falls back to arm64 path" do
      assert OtpDownloader.android_otp_dir("x86") == OtpDownloader.android_otp_dir("arm64-v8a")
    end

    test "arm64 and arm32 paths are distinct" do
      refute OtpDownloader.android_otp_dir("arm64-v8a") ==
               OtpDownloader.android_otp_dir("armeabi-v7a")
    end

    test "arm32 path ends inside the standard cache directory" do
      cache = Path.join([System.get_env("HOME"), ".mob", "cache"])
      assert String.starts_with?(OtpDownloader.android_otp_dir("armeabi-v7a"), cache)
    end
  end
end

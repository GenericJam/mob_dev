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

  # ── valid_otp_dir?/2 ────────────────────────────────────────────────────────
  #
  # The Android and iOS-sim tarballs only need an `erts-*/` to be considered
  # valid. The iOS-device tarball additionally must ship EPMD source files —
  # `mix mob.deploy --native` static-links EPMD into the iOS app and there's
  # nowhere else to source those .c files from. The (c) tarball-schema bump
  # adds them under `erts/epmd/src/`; older caches without the source files
  # are treated as invalid so they auto-redownload.

  describe "valid_otp_dir?/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "otp_validity_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "Android tarball: erts-* alone is enough", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "erts-16.1"))
      assert OtpDownloader.valid_otp_dir?(tmp, "otp-android-73ba6e0f")
      assert OtpDownloader.valid_otp_dir?(tmp, "otp-android-arm32-73ba6e0f")
    end

    test "iOS sim tarball: erts-* alone is enough", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "erts-16.1"))
      assert OtpDownloader.valid_otp_dir?(tmp, "otp-ios-sim-73ba6e0f")
    end

    test "iOS device tarball: needs erts-* AND EPMD .c sources AND .h headers",
         %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "erts-16.1"))
      File.mkdir_p!(Path.join(tmp, "erts/epmd/src"))

      # No EPMD source yet — fails.
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-73ba6e0f")

      # All three .c files present, but no headers — still fails. This is the
      # regression we're guarding against: a tarball with sources but no
      # headers extracts cleanly but breaks at clang time with `'epmd.h' file
      # not found`. Validation must catch it.
      for rel <- ~w[epmd.c epmd_srv.c epmd_cli.c] do
        File.write!(Path.join(tmp, "erts/epmd/src/#{rel}"), "")
      end

      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-73ba6e0f")

      # Add headers — now passes.
      for rel <- ~w[epmd.h epmd_int.h] do
        File.write!(Path.join(tmp, "erts/epmd/src/#{rel}"), "")
      end

      assert OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-73ba6e0f")
    end

    test "iOS device tarball: missing any one required file invalidates", %{tmp: tmp} do
      required = ~w[epmd.c epmd_srv.c epmd_cli.c epmd.h epmd_int.h]

      for missing <- required do
        File.rm_rf!(tmp)
        File.mkdir_p!(Path.join(tmp, "erts-16.1"))
        File.mkdir_p!(Path.join(tmp, "erts/epmd/src"))

        for rel <- required, rel != missing do
          File.write!(Path.join(tmp, "erts/epmd/src/#{rel}"), "")
        end

        refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-73ba6e0f"),
               "expected invalid when #{missing} is missing"
      end
    end

    test "no erts-* dir → invalid regardless of name", %{tmp: tmp} do
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-android-73ba6e0f")
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-73ba6e0f")
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-sim-73ba6e0f")
    end

    test "non-existent dir → invalid" do
      refute OtpDownloader.valid_otp_dir?("/nonexistent/path", "otp-ios-device-73ba6e0f")
    end
  end
end

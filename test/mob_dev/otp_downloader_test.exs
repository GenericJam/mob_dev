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

    test "x86_64 returns a path containing the x86_64 artifact name" do
      path = OtpDownloader.android_otp_dir("x86_64")
      assert path =~ "otp-android-x86_64-"
    end

    test "unknown ABI falls back to arm64 path" do
      assert OtpDownloader.android_otp_dir("x86") == OtpDownloader.android_otp_dir("arm64-v8a")
    end

    test "arm64, arm32, and x86_64 paths are distinct" do
      refute OtpDownloader.android_otp_dir("arm64-v8a") ==
               OtpDownloader.android_otp_dir("armeabi-v7a")

      refute OtpDownloader.android_otp_dir("arm64-v8a") ==
               OtpDownloader.android_otp_dir("x86_64")
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

    # All tarballs (post-2026-05-06) ship crypto.a + libcrypto.a. Helper
    # to populate them in test fixtures.
    defp add_crypto(tmp) do
      File.mkdir_p!(Path.join(tmp, "erts-16.1/lib"))
      File.write!(Path.join(tmp, "erts-16.1/lib/crypto.a"), "")
      File.write!(Path.join(tmp, "erts-16.1/lib/libcrypto.a"), "")
    end

    test "Android tarball: erts-* + crypto archives is enough", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "erts-16.1"))
      add_crypto(tmp)
      assert OtpDownloader.valid_otp_dir?(tmp, "otp-android-7721ab74")
      assert OtpDownloader.valid_otp_dir?(tmp, "otp-android-arm32-7721ab74")
      assert OtpDownloader.valid_otp_dir?(tmp, "otp-android-x86_64-7721ab74")
    end

    test "Android tarball: missing crypto.a → invalid", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "erts-16.1"))
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-android-7721ab74")
    end

    test "iOS sim tarball: erts-* + crypto archives is enough", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "erts-16.1"))
      add_crypto(tmp)
      assert OtpDownloader.valid_otp_dir?(tmp, "otp-ios-sim-7721ab74")
    end

    test "iOS device tarball: needs erts-* AND EPMD .c sources AND .h headers",
         %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "erts-16.1"))
      add_crypto(tmp)
      File.mkdir_p!(Path.join(tmp, "erts/epmd/src"))

      # No EPMD source yet — fails.
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-7721ab74")

      # All three .c files present, but no headers — still fails. This is the
      # regression we're guarding against: a tarball with sources but no
      # headers extracts cleanly but breaks at clang time with `'epmd.h' file
      # not found`. Validation must catch it.
      for rel <- ~w[epmd.c epmd_srv.c epmd_cli.c] do
        File.write!(Path.join(tmp, "erts/epmd/src/#{rel}"), "")
      end

      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-7721ab74")

      # Add headers — now passes.
      for rel <- ~w[epmd.h epmd_int.h] do
        File.write!(Path.join(tmp, "erts/epmd/src/#{rel}"), "")
      end

      assert OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-7721ab74")
    end

    test "iOS device tarball: missing any one required file invalidates", %{tmp: tmp} do
      required = ~w[epmd.c epmd_srv.c epmd_cli.c epmd.h epmd_int.h]

      for missing <- required do
        File.rm_rf!(tmp)
        File.mkdir_p!(Path.join(tmp, "erts-16.1"))
        add_crypto(tmp)
        File.mkdir_p!(Path.join(tmp, "erts/epmd/src"))

        for rel <- required, rel != missing do
          File.write!(Path.join(tmp, "erts/epmd/src/#{rel}"), "")
        end

        refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-7721ab74"),
               "expected invalid when #{missing} is missing"
      end
    end

    test "no erts-* dir → invalid regardless of name", %{tmp: tmp} do
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-android-7721ab74")
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-device-7721ab74")
      refute OtpDownloader.valid_otp_dir?(tmp, "otp-ios-sim-7721ab74")
    end

    test "non-existent dir → invalid" do
      refute OtpDownloader.valid_otp_dir?("/nonexistent/path", "otp-ios-device-7721ab74")
    end
  end

  # ── Elixir build/runtime version skew ───────────────────────────────────────
  #
  # Build Elixir ≠ device-runtime Elixir at the minor level is the Enum.__in__/2
  # class of breakage (black screen at boot). We compare major.minor: rc/patch
  # differences within a minor are beam-compatible and must NOT warn.

  describe "elixir_skew/2" do
    test "different minor is a skew" do
      assert OtpDownloader.elixir_skew("1.20.0-rc.5", "1.19.5") ==
               {:skew, "1.20.0-rc.5", "1.19.5"}
    end

    test "identical version is ok" do
      assert OtpDownloader.elixir_skew("1.19.5", "1.19.5") == :ok
    end

    test "same minor, different patch is ok" do
      assert OtpDownloader.elixir_skew("1.19.5", "1.19.6") == :ok
    end

    test "same minor, rc vs final is ok" do
      assert OtpDownloader.elixir_skew("1.20.0-rc.5", "1.20.0") == :ok
    end

    test "nil bundled version (unreadable) does not warn" do
      assert OtpDownloader.elixir_skew("1.20.0", nil) == :ok
    end
  end

  describe "bundled_elixir_version/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "otp_elixir_vsn_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "lib/elixir/ebin"))
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "reads the vsn from lib/elixir/ebin/elixir.app", %{tmp: tmp} do
      File.write!(
        Path.join(tmp, "lib/elixir/ebin/elixir.app"),
        ~s|{application,elixir,[{description,"elixir"},{vsn,"1.19.5"},{modules,[]}]}.|
      )

      assert OtpDownloader.bundled_elixir_version(tmp) == "1.19.5"
    end

    test "missing elixir.app returns nil", %{tmp: tmp} do
      assert OtpDownloader.bundled_elixir_version(tmp) == nil
    end
  end
end

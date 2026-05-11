defmodule Mix.Tasks.Mob.Release.OtpTest do
  use ExUnit.Case, async: false

  import Mox

  alias Mix.Tasks.Mob.Release.Otp, as: OTPTask

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    otp_src = mk_tmp_otp_fixture()

    on_exit(fn ->
      Application.delete_env(:mob_dev, :release_shell)
      File.rm_rf!(otp_src)
    end)

    %{otp_src: otp_src}
  end

  describe "argument parsing" do
    test "missing target raises a usage message" do
      assert_raise Mix.Error, ~r/missing target argument/, fn ->
        OTPTask.run([])
      end
    end

    test "unknown target raises with the valid list" do
      assert_raise Mix.Error, ~r/unknown target: bogus.*valid:/s, fn ->
        OTPTask.run(["bogus"])
      end
    end

    test "too many positional args raises" do
      assert_raise Mix.Error, ~r/too many arguments/, fn ->
        OTPTask.run(["android_arm64", "ios_sim"])
      end
    end
  end

  describe "happy paths" do
    test "android_arm64 runs the full OTP build pipeline with the right ssl flags",
         %{otp_src: otp_src} do
      stub_predicates_true()

      configure_argv = :atomics.new(1, signed: false)
      _ = configure_argv

      pid = self()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        if "configure" in argv do
          send(pid, {:configure, argv})
        end

        cond do
          hd(argv) == "ls" -> {:ok, "crypto-5.6\npublic_key-1.18\nssl-11.4\n"}
          true -> {:ok, ""}
        end
      end)

      OTPTask.run([
        "android_arm64",
        "--otp-src",
        otp_src,
        "--openssl-prefix",
        "/openssl/prefix",
        "--release-root",
        "/fake/release",
        "--ndk-root",
        "/fake/ndk"
      ])

      assert_received {:configure, argv}
      assert "--with-ssl=/openssl/prefix" in argv
      assert "--disable-dynamic-ssl-lib" in argv
    end

    test "ios_sim runs without --openssl-prefix and uses --without-ssl",
         %{otp_src: otp_src} do
      stub_predicates_true()
      pid = self()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        if "configure" in argv do
          send(pid, {:configure, argv})
        end

        {:ok, ""}
      end)

      OTPTask.run([
        "ios_sim",
        "--otp-src",
        otp_src,
        "--release-root",
        "/fake/release"
      ])

      assert_received {:configure, argv}
      assert "--without-ssl" in argv
      refute Enum.any?(argv, &String.starts_with?(&1, "--with-ssl"))
    end
  end

  describe "error paths" do
    test "OTP_SRC missing raises with the clone hint" do
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> false end)

      assert_raise Mix.Error, ~r/OTP_SRC missing/, fn ->
        OTPTask.run([
          "android_arm64",
          "--otp-src",
          "/nonexistent",
          "--openssl-prefix",
          "/openssl/prefix",
          "--ndk-root",
          "/fake/ndk"
        ])
      end
    end

    test "android target without openssl_prefix raises with OpenSSL hint",
         %{otp_src: otp_src} do
      stub_predicates_true()

      assert_raise Mix.Error, ~r/openssl_prefix required/, fn ->
        OTPTask.run([
          "android_arm64",
          "--otp-src",
          otp_src,
          "--ndk-root",
          "/fake/ndk"
        ])
      end
    end

    test "Android verify catches missing crypto apps with --with-ssl hint",
         %{otp_src: otp_src} do
      stub_predicates_true()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        if hd(argv) == "ls" do
          # missing crypto/public_key/ssl — silent shipping bug we
          # want to fail loudly.
          {:ok, "kernel-9.0\nstdlib-6.0\n"}
        else
          {:ok, ""}
        end
      end)

      assert_raise Mix.Error, ~r/crypto.*--with-ssl/s, fn ->
        OTPTask.run([
          "android_arm64",
          "--otp-src",
          otp_src,
          "--openssl-prefix",
          "/openssl/prefix",
          "--release-root",
          "/fake/release",
          "--ndk-root",
          "/fake/ndk"
        ])
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp stub_predicates_true do
    stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
    stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
  end

  defp mk_tmp_otp_fixture do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "mob_dev_otp_task_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp, "erts"))
    File.write!(Path.join([tmp, "erts", "vsn.mk"]), "VSN = 17.0\n")
    File.touch!(Path.join(tmp, "otp_build"))
    tmp
  end
end

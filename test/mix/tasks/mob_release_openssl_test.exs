defmodule Mix.Tasks.Mob.Release.OpensslTest do
  use ExUnit.Case, async: false

  import Mox

  alias Mix.Tasks.Mob.Release.Openssl, as: OpenSSLTask

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  describe "argument parsing" do
    test "missing target argument raises a usage message" do
      assert_raise Mix.Error, ~r/missing target argument/, fn ->
        OpenSSLTask.run([])
      end
    end

    test "unknown target raises with the valid list" do
      assert_raise Mix.Error, ~r/unknown target: nonsense.*valid:/s, fn ->
        OpenSSLTask.run(["nonsense"])
      end
    end

    test "too many positional args raises" do
      assert_raise Mix.Error, ~r/too many arguments/, fn ->
        OpenSSLTask.run(["android_arm64", "ios_sim"])
      end
    end
  end

  describe "one target — happy path" do
    test "android_arm64 invokes OpenSSL build then CryptoNif build in sequence" do
      stub_dir_checks_true()

      # Phase 1: OpenSSL build (1 distclean + 1 Configure + 1 make + 1 install_sw)
      stub_openssl_build_calls()

      # Phase 2: crypto NIF build (mkdir × 2, 31 compile, 1 rm_f, 1 ar, 1 ranlib, 1 nm)
      stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)
      stub(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)

      # Reuse the OpenSSL Mox; the second wave of cmd calls are the
      # crypto NIF phase. We let everything through and assert on the
      # nm output that ships back.
      Mox.expect(MobDev.Release.ShellMock, :cmd, 31, fn argv, _opts ->
        # Compile phase — verify some marker
        assert "-DSTATIC_ERLANG_NIF" in argv
        {:ok, ""}
      end)

      # ar + ranlib + nm
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert "rcs" in argv
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert hd(argv) =~ "llvm-ranlib"
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert hd(argv) =~ "llvm-nm"
        {:ok, "0000000000000000 T crypto_nif_init\n"}
      end)

      # No raise expected — task completes silently.
      OpenSSLTask.run([
        "android_arm64",
        "--openssl-src",
        "/fake/openssl",
        "--otp-src",
        "/fake/otp",
        "--prefix",
        "/fake/prefix",
        "--ndk-root",
        "/fake/ndk"
      ])
    end
  end

  describe "error paths" do
    test "OpenSSL build failure raises with the formatted error" do
      # Make OPENSSL_SRC missing — precondition_failed before any cmd.
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> false end)

      assert_raise Mix.Error, ~r/OPENSSL_SRC missing/, fn ->
        OpenSSLTask.run([
          "android_arm64",
          "--openssl-src",
          "/nonexistent",
          "--otp-src",
          "/fake/otp"
        ])
      end
    end

    test "crypto_nif_init missing in nm output raises" do
      stub_dir_checks_true()
      stub_openssl_build_calls()
      stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)
      stub(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)

      # 31 compile + ar + ranlib succeed; nm returns "undefined" — the
      # exact regression we want to fail loudly.
      Mox.expect(MobDev.Release.ShellMock, :cmd, 31, fn _, _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert hd(argv) =~ "llvm-nm"
        {:ok, "                 U crypto_nif_init\n"}
      end)

      assert_raise Mix.Error, ~r/crypto_nif_init/, fn ->
        OpenSSLTask.run([
          "android_arm64",
          "--openssl-src",
          "/fake/openssl",
          "--otp-src",
          "/fake/otp",
          "--ndk-root",
          "/fake/ndk"
        ])
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp stub_dir_checks_true do
    stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
  end

  defp stub_openssl_build_calls do
    # OpenSSL build: distclean + Configure + make + install_sw = 4 cmd calls.
    # We stub them all with success.
    Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _ -> {:ok, ""} end)
    Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["./Configure" | _], _ -> {:ok, ""} end)
    Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "-j8"], _ -> {:ok, ""} end)
    Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "install_sw"], _ -> {:ok, ""} end)
  end
end

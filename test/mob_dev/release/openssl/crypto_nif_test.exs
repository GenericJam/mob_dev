defmodule MobDev.Release.OpenSSL.CryptoNifTest do
  use ExUnit.Case, async: false

  import Mox

  alias MobDev.Release.{Errors, OpenSSL}
  alias OpenSSL.CryptoNif

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  # ── Source list — surface lock ───────────────────────────────────────
  # Adding or removing a source from `@sources` is a deliberate decision
  # that must show up in a code review.

  describe "sources/0" do
    test "includes the 31 crypto NIF C files we ship" do
      srcs = CryptoNif.sources()
      assert length(srcs) == 31

      # Spot-check representative entries from each crypto family.
      assert "aes.c" in srcs
      assert "rsa.c" in srcs
      assert "ec.c" in srcs
      assert "hmac.c" in srcs
      assert "evp.c" in srcs

      # otp_test_engine.c is intentionally excluded (test fixture, not
      # for shipping).
      refute "otp_test_engine.c" in srcs
    end

    test "all entries are .c files" do
      assert Enum.all?(CryptoNif.sources(), &String.ends_with?(&1, ".c"))
    end
  end

  # ── target_spec/1 — pinned surface per target ────────────────────────

  describe "target_spec/1" do
    test "android_arm64 — aarch64 arch dir, Android hardening, ELF symbol" do
      spec = CryptoNif.target_spec(:android_arm64)

      assert spec.arch_dir == "aarch64-unknown-linux-android"
      assert spec.nm_symbol == "crypto_nif_init"
      assert "-mbranch-protection=standard" in spec.extra_cflags
      assert "-fstack-clash-protection" in spec.extra_cflags
      assert "-D_GNU_SOURCE" in spec.extra_cflags

      # arm32-specific ABI flags should NOT be in arm64
      refute "-march=armv7-a" in spec.extra_cflags
    end

    test "android_arm32 — ABI flags AND Android hardening" do
      spec = CryptoNif.target_spec(:android_arm32)

      assert spec.arch_dir == "arm-unknown-linux-androideabi"
      assert spec.nm_symbol == "crypto_nif_init"

      # arm32-specific ABI flags
      assert "-march=armv7-a" in spec.extra_cflags
      assert "-mfloat-abi=softfp" in spec.extra_cflags
      assert "-mthumb" in spec.extra_cflags

      # Android hardening still applies
      assert "-mbranch-protection=standard" in spec.extra_cflags
      assert "-D_GNU_SOURCE" in spec.extra_cflags
    end

    test "ios_sim — Mach-O symbol with leading underscore, no Android flags" do
      spec = CryptoNif.target_spec(:ios_sim)

      assert spec.arch_dir == "aarch64-apple-iossimulator"
      assert spec.nm_symbol == "_crypto_nif_init"
      # iOS does NOT get Android hardening flags
      assert spec.extra_cflags == []
    end

    test "ios_device — distinct from sim (different arch_dir)" do
      sim = CryptoNif.target_spec(:ios_sim)
      device = CryptoNif.target_spec(:ios_device)

      assert sim.arch_dir != device.arch_dir
      assert device.arch_dir == "aarch64-apple-ios"
      assert device.nm_symbol == "_crypto_nif_init"
    end

    test "targets/0 enumerates all four" do
      assert CryptoNif.targets() == [:android_arm64, :android_arm32, :ios_sim, :ios_device]
    end
  end

  # ── cflags/3 — pure assembly ────────────────────────────────────────

  describe "cflags/3" do
    test "every target starts with the same base CFLAGS" do
      base = CryptoNif.base_cflags()

      for target_id <- CryptoNif.targets() do
        spec = CryptoNif.target_spec(target_id)
        flags = CryptoNif.cflags(spec, "/openssl/prefix", "/otp/src")

        # Base flags appear before extras (order-sensitive).
        for base_flag <- base do
          assert base_flag in flags, "target #{target_id} missing base flag #{base_flag}"
        end
      end
    end

    test "android targets include the Android hardening flags" do
      for target_id <- [:android_arm64, :android_arm32] do
        spec = CryptoNif.target_spec(target_id)
        flags = CryptoNif.cflags(spec, "/openssl/prefix", "/otp/src")

        assert "-mbranch-protection=standard" in flags, "#{target_id} missing branch-protection"
        assert "-D_GNU_SOURCE" in flags, "#{target_id} missing _GNU_SOURCE"
      end
    end

    test "iOS targets do NOT include Android hardening flags" do
      for target_id <- [:ios_sim, :ios_device] do
        spec = CryptoNif.target_spec(target_id)
        flags = CryptoNif.cflags(spec, "/openssl/prefix", "/otp/src")

        refute "-mbranch-protection=standard" in flags
        refute "-D_GNU_SOURCE" in flags
        refute "-fstack-clash-protection" in flags
      end
    end

    test "STATIC_ERLANG_NIF is defined on every target" do
      # This define is what makes `ERL_NIF_INIT(crypto, ...)` emit
      # `crypto_nif_init` as a static symbol instead of `nif_init`.
      # Dropping it would break the entire static-link approach.
      for target_id <- CryptoNif.targets() do
        spec = CryptoNif.target_spec(target_id)
        flags = CryptoNif.cflags(spec, "/openssl/prefix", "/otp/src")
        assert "-DSTATIC_ERLANG_NIF" in flags
      end
    end

    test "include paths reference the target's arch_dir" do
      spec = CryptoNif.target_spec(:android_arm64)
      flags = CryptoNif.cflags(spec, "/openssl/prefix", "/otp/src")

      assert "-I/otp/src/erts/include/aarch64-unknown-linux-android" in flags
      assert "-I/otp/src/erts/include/internal/aarch64-unknown-linux-android" in flags
    end

    test "includes OpenSSL prefix" do
      spec = CryptoNif.target_spec(:ios_sim)
      flags = CryptoNif.cflags(spec, "/custom/openssl", "/otp/src")
      assert "-I/custom/openssl/include" in flags
    end

    test "arm32 emits -march=armv7-a BEFORE Android hardening flags" do
      spec = CryptoNif.target_spec(:android_arm32)
      flags = CryptoNif.cflags(spec, "/openssl/prefix", "/otp/src")

      assert march_idx = Enum.find_index(flags, &(&1 == "-march=armv7-a"))
      assert branch_idx = Enum.find_index(flags, &(&1 == "-mbranch-protection=standard"))
      assert march_idx < branch_idx
    end
  end

  # ── check_symbol_present/3 — pure nm output parser ───────────────────

  describe "check_symbol_present/3" do
    test "accepts ELF nm output with the symbol" do
      output = """
      0000000000000000 T crypto_nif_init
      0000000000000018 T some_other_symbol
      """

      assert :ok = CryptoNif.check_symbol_present(output, "crypto_nif_init", "/path/crypto.a")
    end

    test "accepts Mach-O nm output (leading underscore)" do
      output = "0000000000000000 T _crypto_nif_init\n"

      assert :ok = CryptoNif.check_symbol_present(output, "_crypto_nif_init", "/path/crypto.a")
    end

    test "rejects when symbol is undefined (U flag, not T)" do
      output = "                 U crypto_nif_init\n"

      assert {:error, {:precondition_failed, msg}} =
               CryptoNif.check_symbol_present(output, "crypto_nif_init", "/p/crypto.a")

      assert msg =~ "T crypto_nif_init"
      assert msg =~ "STATIC_ERLANG_NIF"
    end

    test "rejects when symbol is missing entirely" do
      output = """
      0000000000000000 T some_other_init
      """

      assert {:error, {:precondition_failed, _}} =
               CryptoNif.check_symbol_present(output, "crypto_nif_init", "/p/crypto.a")
    end

    test "doesn't false-match a prefix (crypto_nif_init_v2 should fail for crypto_nif_init)" do
      # The whole point of pinning the regex anchor is to avoid this
      # class of silent pass.
      output = """
      0000000000000000 T crypto_nif_init_v2
      0000000000000020 T some_other_symbol
      """

      assert {:error, {:precondition_failed, _}} =
               CryptoNif.check_symbol_present(output, "crypto_nif_init", "/p/crypto.a")
    end

    test "doesn't false-match a leading-substring suffix" do
      # The C-level symbol `_crypto_nif_init` should NOT match a
      # search for `crypto_nif_init` (with `_` as a literal prefix).
      output = "0000000000000000 T _crypto_nif_init\n"

      assert {:error, {:precondition_failed, _}} =
               CryptoNif.check_symbol_present(output, "crypto_nif_init", "/p/crypto.a")
    end
  end

  # ── build/2 against the Mox ──────────────────────────────────────────
  # 30 compile calls + 1 ar + 1 ranlib + 1 nm — heavy ceremony, so we
  # only test a few representative targets exhaustively.

  describe "build/2 — android_arm64 full sequence" do
    test "compiles each source with NDK clang, archives, verifies symbol" do
      stub_all_dir_checks_true()

      # 31 compile calls — one per source file.
      Mox.expect(MobDev.Release.ShellMock, :mkdir_p, 2, fn _ -> :ok end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, 31, fn argv, _opts ->
        # CC is the NDK toolchain clang. The exact path is interpolated
        # off the NDK root override we pass below.
        assert hd(argv) =~ "aarch64-linux-android24-clang"
        assert "-c" in argv
        assert "-DSTATIC_ERLANG_NIF" in argv
        assert "-mbranch-protection=standard" in argv
        {:ok, ""}
      end)

      # rm_f the archive before re-archiving (idempotent rebuild).
      Mox.expect(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)

      # ar rcs <archive> <objs...>
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert hd(argv) =~ "llvm-ar"
        assert "rcs" in argv
        # All 31 object paths are in the argv after "rcs <archive>"
        assert length(argv) >= 31
        {:ok, ""}
      end)

      # ranlib
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert hd(argv) =~ "llvm-ranlib"
        {:ok, ""}
      end)

      # nm verification — return a fake output that contains the symbol.
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert hd(argv) =~ "llvm-nm"
        {:ok, "0000000000000000 T crypto_nif_init\n"}
      end)

      assert {:ok, info} =
               CryptoNif.build(:android_arm64,
                 otp_src: "/fake/otp",
                 openssl_prefix: "/fake/openssl",
                 ndk_root: "/fake/ndk"
               )

      assert info.target == :android_arm64
      assert info.archive =~ "aarch64-unknown-linux-android/crypto.a"
      assert length(info.objects) == 31
    end
  end

  describe "build/2 — ios_sim full sequence" do
    test "uses xcrun -sdk iphonesimulator for cc/ar/ranlib/nm" do
      stub_all_dir_checks_true()
      Mox.expect(MobDev.Release.ShellMock, :mkdir_p, 2, fn _ -> :ok end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, 31, fn argv, _opts ->
        # iOS cc argv: ["xcrun", "-sdk", "iphonesimulator", "clang",
        #               "-arch", "arm64", "-mios-simulator-version-min=17.0", ...flags, "-c", "-o", obj, src]
        assert Enum.take(argv, 7) == [
                 "xcrun",
                 "-sdk",
                 "iphonesimulator",
                 "clang",
                 "-arch",
                 "arm64",
                 "-mios-simulator-version-min=17.0"
               ]

        # No Android hardening on iOS
        refute "-mbranch-protection=standard" in argv
        refute "-D_GNU_SOURCE" in argv
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)

      # ar
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert Enum.take(argv, 4) == ["xcrun", "-sdk", "iphonesimulator", "ar"]
        {:ok, ""}
      end)

      # ranlib
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert Enum.take(argv, 4) == ["xcrun", "-sdk", "iphonesimulator", "ranlib"]
        {:ok, ""}
      end)

      # nm with leading-underscore symbol
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert Enum.take(argv, 4) == ["xcrun", "-sdk", "iphonesimulator", "nm"]
        {:ok, "0000000000000000 T _crypto_nif_init\n"}
      end)

      assert {:ok, info} =
               CryptoNif.build(:ios_sim,
                 otp_src: "/fake/otp",
                 openssl_prefix: "/fake/openssl"
               )

      assert info.archive =~ "aarch64-apple-iossimulator/crypto.a"
    end

    test "ios_device uses iphoneos SDK + -miphoneos-version-min" do
      stub_all_dir_checks_true()
      Mox.expect(MobDev.Release.ShellMock, :mkdir_p, 2, fn _ -> :ok end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, 31, fn argv, _opts ->
        assert "iphoneos" in argv
        assert "-miphoneos-version-min=17.0" in argv
        refute "-mios-simulator-version-min=17.0" in argv
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _, _ ->
        {:ok, "0000000000000000 T _crypto_nif_init\n"}
      end)

      assert {:ok, info} =
               CryptoNif.build(:ios_device,
                 otp_src: "/fake/otp",
                 openssl_prefix: "/fake/openssl"
               )

      assert info.archive =~ "aarch64-apple-ios/crypto.a"
    end
  end

  # ── build/2 failure modes ────────────────────────────────────────────

  describe "build/2 failure paths" do
    test "missing OTP_SRC → precondition_failed with clone hint" do
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> false end)

      assert {:error, {:precondition_failed, msg}} =
               CryptoNif.build(:android_arm64,
                 otp_src: "/nonexistent",
                 openssl_prefix: "/fake/openssl"
               )

      assert msg =~ "OTP_SRC missing"
      assert msg =~ "github.com/erlang/otp"
    end

    test "missing OPENSSL_PREFIX → precondition_failed pointing at MobDev.Release.OpenSSL" do
      # OTP_SRC dir: yes; OPENSSL_PREFIX dir: no
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> false end)

      assert {:error, {:precondition_failed, msg}} =
               CryptoNif.build(:android_arm64,
                 otp_src: "/fake/otp",
                 openssl_prefix: "/nonexistent",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "OPENSSL_PREFIX missing"
      assert msg =~ "MobDev.Release.OpenSSL.build"
    end

    test "compile failure propagates as cmd_failed, halts the loop" do
      stub_all_dir_checks_true()
      Mox.stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)

      # Fail on the first compile call. The remaining 30 should never
      # run (Mox verify_on_exit will fail this test if they do).
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _argv, _opts ->
        Errors.cmd_failed(["aarch64-linux-android24-clang"], 1, "error: header not found\n")
      end)

      assert {:error, {:cmd_failed, %{exit: 1}}} =
               CryptoNif.build(:android_arm64,
                 otp_src: "/fake/otp",
                 openssl_prefix: "/fake/openssl",
                 ndk_root: "/fake/ndk"
               )
    end

    test "missing crypto_nif_init symbol → precondition_failed (the silent-shipping bug we fix)" do
      stub_all_dir_checks_true()
      Mox.stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)
      Mox.stub(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)

      # 31 compile + ar + ranlib + nm = 34 cmd calls. ar/ranlib succeed
      # but nm output lacks the symbol.
      Mox.expect(MobDev.Release.ShellMock, :cmd, 31, fn _, _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _ ->
        assert hd(argv) =~ "llvm-nm"
        # Symbol got built as U (undefined) — exactly the regression
        # the shell version would have silently shipped.
        {:ok, "                 U crypto_nif_init\n"}
      end)

      assert {:error, {:precondition_failed, msg}} =
               CryptoNif.build(:android_arm64,
                 otp_src: "/fake/otp",
                 openssl_prefix: "/fake/openssl",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "crypto_nif_init"
      assert msg =~ "STATIC_ERLANG_NIF"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp stub_all_dir_checks_true do
    stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
  end
end

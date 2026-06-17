defmodule MobDev.Release.OpenSSLTest do
  use ExUnit.Case, async: false
  # async: false because we mutate Application env (release_shell impl).
  # Parallel tests sharing app env race.

  import Mox

  alias MobDev.Release.{OpenSSL, Errors}

  # The Mox built in test/support/release/shell_mock.ex is automatically
  # verified per test — any expected call that wasn't made fails the test.
  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  # ── Target spec — pure data ─────────────────────────────────────────────
  # These tests lock down the surface so a future "improvement" can't
  # silently drop e.g. arm32's `no-asm` flag (the exact regression the
  # shell version's comment block warned about).

  describe "target_spec/1" do
    test "android_arm64 — no `no-asm`; -D__ANDROID_API__=24" do
      spec = OpenSSL.target_spec(:android_arm64)

      assert spec.configure_target == "android-arm64"
      assert spec.default_prefix == "/tmp/openssl-android-arm64"
      assert "-D__ANDROID_API__=24" in spec.extra_configure_args
      refute "no-asm" in spec.extra_configure_args
    end

    test "android_x86_64 — no `no-asm`; -D__ANDROID_API__=24" do
      spec = OpenSSL.target_spec(:android_x86_64)

      assert spec.configure_target == "android-x86_64"
      assert spec.default_prefix == "/tmp/openssl-android-x86_64"
      assert "-D__ANDROID_API__=24" in spec.extra_configure_args
      refute "no-asm" in spec.extra_configure_args
    end

    test "android_arm32 — `no-asm` IS present (ld.lld rejects non-PIC reloc)" do
      spec = OpenSSL.target_spec(:android_arm32)

      assert spec.configure_target == "android-arm"
      assert spec.default_prefix == "/tmp/openssl-android-arm32"
      assert "-D__ANDROID_API__=24" in spec.extra_configure_args
      assert "no-asm" in spec.extra_configure_args
    end

    test "ios_sim — iossimulator-xcrun Configure target" do
      spec = OpenSSL.target_spec(:ios_sim)
      assert spec.configure_target == "iossimulator-xcrun"
      assert spec.default_prefix == "/tmp/openssl-ios-sim"
      # iOS targets don't pass -D__ANDROID_API__ etc.
      assert spec.extra_configure_args == []
    end

    test "ios_device — ios64-xcrun Configure target" do
      spec = OpenSSL.target_spec(:ios_device)
      assert spec.configure_target == "ios64-xcrun"
      assert spec.default_prefix == "/tmp/openssl-ios-device"
      assert spec.extra_configure_args == []
    end

    test "targets/0 enumerates all five in canonical order" do
      assert OpenSSL.targets() == [
               :android_arm64,
               :android_arm32,
               :android_x86_64,
               :ios_sim,
               :ios_device
             ]
    end
  end

  # ── Configure args — pure assembly ─────────────────────────────────────
  # The assembled argv is what the shell scripts hand-rolled. Pin its
  # contents + ordering so any tweak that breaks the OpenSSL build
  # surfaces in test rather than in release-time.

  describe "configure_args/2" do
    test "first arg is the Configure target" do
      args = OpenSSL.configure_args(OpenSSL.target_spec(:android_arm64), "/tmp/out")
      assert hd(args) == "android-arm64"
    end

    test "includes all size flags" do
      args = OpenSSL.configure_args(OpenSSL.target_spec(:ios_sim), "/tmp/out")

      for flag <- ["-Os", "-ffunction-sections", "-fdata-sections", "-fPIC"] do
        assert flag in args, "expected size flag #{flag} in #{inspect(args)}"
      end
    end

    test "android_arm32 places `no-asm` BEFORE the disabled-algorithm list" do
      # Position matters less than presence for OpenSSL, but pinning the
      # position catches accidental list-merge regressions.
      args = OpenSSL.configure_args(OpenSSL.target_spec(:android_arm32), "/tmp/out")

      assert no_asm_idx = Enum.find_index(args, &(&1 == "no-asm"))
      assert no_md2_idx = Enum.find_index(args, &(&1 == "no-md2"))
      assert no_asm_idx < no_md2_idx, "no-asm should come before the no-X disable list"
    end

    test "includes --prefix and --openssldir" do
      args = OpenSSL.configure_args(OpenSSL.target_spec(:ios_device), "/custom/prefix")
      assert "--prefix=/custom/prefix" in args
      assert "--openssldir=/custom/prefix/ssl" in args
    end

    test "includes the full disabled-algorithm list" do
      args = OpenSSL.configure_args(OpenSSL.target_spec(:android_arm64), "/tmp/out")

      # Spot-check a few representative entries. The full list is tested
      # in disabled_algorithms/0 directly.
      for disabled <- ["no-shared", "no-md2", "no-rc4", "no-ssl3", "no-tls1_1", "no-srp"] do
        assert disabled in args
      end
    end

    test "argv is non-empty and entirely strings" do
      args = OpenSSL.configure_args(OpenSSL.target_spec(:ios_sim), "/tmp/out")
      assert length(args) > 0
      assert Enum.all?(args, &is_binary/1)
    end
  end

  # ── disabled_algorithms/0 — pin the surface ─────────────────────────────
  # Adding or removing an entry here is a deliberate decision that
  # should show up in code review, not a silent edit-and-forget.

  describe "disabled_algorithms/0" do
    test "includes every legacy hash + cipher + protocol we don't ship" do
      disabled = OpenSSL.disabled_algorithms()

      expected = ~w(
        no-shared no-tests no-apps no-engine
        no-md2 no-md4 no-mdc2 no-whirlpool no-rmd160
        no-rc2 no-rc4 no-idea no-cast no-bf no-blake2
        no-seed no-aria no-camellia no-gost
        no-weak-ssl-ciphers no-ssl3 no-tls1 no-tls1_1
        no-srp no-psk no-nextprotoneg
      )

      assert disabled == expected
    end
  end

  # ── build/2 — the orchestration, against a Mox ─────────────────────────
  # These tests prove "given these inputs, the Shell behaviour is invoked
  # with exactly these argv + cwd + env." The actual clang/Configure/make
  # never runs.

  describe "build/2 against the Mox" do
    test "android_arm64 invokes Configure with the right argv" do
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      # NDK root + toolchain checks
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      # distclean (tolerant)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _opts ->
        {:ok, ""}
      end)

      # Configure
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        assert hd(argv) == "./Configure"
        assert "android-arm64" in argv
        assert "-D__ANDROID_API__=24" in argv
        assert "no-asm" not in argv

        env = Keyword.fetch!(opts, :env)
        assert {"ANDROID_NDK_ROOT", _} = List.keyfind(env, "ANDROID_NDK_ROOT", 0)
        {:ok, ""}
      end)

      # make -j8
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "-j8"], _opts ->
        {:ok, ""}
      end)

      # make install_sw
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "install_sw"], _opts ->
        {:ok, ""}
      end)

      assert {:ok, info} =
               OpenSSL.build(:android_arm64,
                 openssl_src: "/fake/openssl",
                 prefix: "/fake/prefix"
               )

      assert info.target == :android_arm64
      assert info.prefix == "/fake/prefix"
      assert info.libcrypto == "/fake/prefix/lib/libcrypto.a"
      assert info.libssl == "/fake/prefix/lib/libssl.a"
      assert info.include == "/fake/prefix/include"
    end

    test "android_arm32 passes `no-asm` to Configure" do
      stub_all_dir_checks_true()

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert "android-arm" in argv
        assert "no-asm" in argv
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "-j8"], _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "install_sw"], _ -> {:ok, ""} end)

      assert {:ok, _} =
               OpenSSL.build(:android_arm32,
                 openssl_src: "/fake/openssl",
                 prefix: "/fake/prefix"
               )
    end

    test "ios_sim sets CC/CXX/AR/RANLIB via xcrun in env" do
      stub_all_dir_checks_true()

      # iOS precheck calls `xcrun --sdk iphonesimulator --show-sdk-path`
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert argv == ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]
        {:ok, "/some/sdk/path\n"}
      end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        assert "iossimulator-xcrun" in argv

        env = Keyword.fetch!(opts, :env)
        cc = env |> List.keyfind("CC", 0) |> elem(1)
        ar = env |> List.keyfind("AR", 0) |> elem(1)

        assert cc =~ "xcrun -sdk iphonesimulator clang -arch arm64"
        assert cc =~ "-mios-simulator-version-min=17.0"
        assert ar == "xcrun -sdk iphonesimulator ar"
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "-j8"], _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "install_sw"], _ -> {:ok, ""} end)

      assert {:ok, info} =
               OpenSSL.build(:ios_sim,
                 openssl_src: "/fake/openssl",
                 prefix: "/fake/prefix"
               )

      assert info.target == :ios_sim
    end

    test "ios_device uses -miphoneos-version-min (not -mios-simulator-version-min)" do
      stub_all_dir_checks_true()

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert argv == ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]
        {:ok, "/some/sdk/path\n"}
      end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        assert "ios64-xcrun" in argv

        env = Keyword.fetch!(opts, :env)
        cc = env |> List.keyfind("CC", 0) |> elem(1)

        assert cc =~ "-miphoneos-version-min=17.0"
        refute cc =~ "ios-simulator"
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "-j8"], _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "install_sw"], _ -> {:ok, ""} end)

      assert {:ok, _} =
               OpenSSL.build(:ios_device,
                 openssl_src: "/fake/openssl",
                 prefix: "/fake/prefix"
               )
    end

    test "distclean failure is tolerated (first-time builds have nothing to clean)" do
      stub_all_dir_checks_true()

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _ ->
        Errors.cmd_failed(["make", "distclean"], 2, "nothing to clean\n")
      end)

      # The build continues to Configure despite distclean failing.
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["./Configure" | _], _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "-j8"], _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "install_sw"], _ -> {:ok, ""} end)

      assert {:ok, _} =
               OpenSSL.build(:android_arm64,
                 openssl_src: "/fake/openssl",
                 prefix: "/fake/prefix"
               )
    end

    test "Configure failure propagates as cmd_failed (NOT tolerated)" do
      stub_all_dir_checks_true()

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["./Configure" | _], _ ->
        Errors.cmd_failed(["./Configure"], 1, "unknown target\n")
      end)

      # Subsequent steps should NOT be invoked — Mox verify_on_exit
      # will fail this test if they are.

      assert {:error, {:cmd_failed, %{exit: 1}}} =
               OpenSSL.build(:android_arm64,
                 openssl_src: "/fake/openssl",
                 prefix: "/fake/prefix"
               )
    end

    test "make failure propagates" do
      stub_all_dir_checks_true()
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "distclean"], _ -> {:ok, ""} end)
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["./Configure" | _], _ -> {:ok, ""} end)

      Mox.expect(MobDev.Release.ShellMock, :cmd, fn ["make", "-j8"], _ ->
        Errors.cmd_failed(["make", "-j8"], 2, "error: ...\n")
      end)

      assert {:error, {:cmd_failed, _}} =
               OpenSSL.build(:android_arm64,
                 openssl_src: "/fake/openssl",
                 prefix: "/fake/prefix"
               )
    end
  end

  # ── Preconditions — actionable hints, not blob errors ───────────────────

  describe "build/2 preconditions" do
    test "missing OPENSSL_SRC → precondition_failed with clone hint" do
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> false end)

      assert {:error, {:precondition_failed, msg}} =
               OpenSSL.build(:android_arm64, openssl_src: "/nonexistent")

      assert msg =~ "OPENSSL_SRC missing"
      assert msg =~ "github.com/openssl/openssl"
    end

    test "missing NDK root → precondition_failed with install hint" do
      # OPENSSL_SRC dir: yes; NDK dir: no
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> false end)

      assert {:error, {:precondition_failed, msg}} =
               OpenSSL.build(:android_arm64,
                 openssl_src: "/fake/openssl",
                 ndk_root: "/nonexistent/ndk"
               )

      assert msg =~ "Android NDK"
      assert msg =~ "install"
    end

    test "missing iOS SDK → precondition_failed with xcode-select hint" do
      # OPENSSL_SRC dir: yes
      Mox.expect(MobDev.Release.ShellMock, :dir?, fn _ -> true end)

      # xcrun fails
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert argv == ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]
        Errors.cmd_failed(argv, 64, "xcrun: error: SDK \"iphonesimulator\" cannot be located\n")
      end)

      assert {:error, {:precondition_failed, msg}} =
               OpenSSL.build(:ios_sim, openssl_src: "/fake/openssl")

      assert msg =~ "iphonesimulator"
      assert msg =~ "xcode-select"
    end
  end

  # ── build_all/1 — sequence, doesn't short-circuit ───────────────────────

  describe "build_all/1" do
    test "returns one result per target in canonical order" do
      # Stub everything to a quick success on dir? + cmd
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)

      results = OpenSSL.build_all(openssl_src: "/fake/openssl")

      assert Keyword.keys(results) == [
               :android_arm64,
               :android_arm32,
               :android_x86_64,
               :ios_sim,
               :ios_device
             ]

      assert Enum.all?(results, fn {_id, r} -> match?({:ok, _}, r) end)
    end

    test "doesn't short-circuit when one target fails" do
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)

      # Fail android_arm64's Configure, pass everything else.
      stub(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        cd = Keyword.get(opts, :cd, "")

        cond do
          hd(argv) == "./Configure" and "android-arm64" in argv ->
            Errors.cmd_failed(argv, 1, "oops")

          hd(argv) == "xcrun" ->
            {:ok, "/sdk\n"}

          true ->
            _ = cd
            {:ok, ""}
        end
      end)

      results = OpenSSL.build_all(openssl_src: "/fake/openssl")
      android_arm64 = Keyword.fetch!(results, :android_arm64)
      android_arm32 = Keyword.fetch!(results, :android_arm32)

      assert {:error, {:cmd_failed, _}} = android_arm64
      assert {:ok, _} = android_arm32
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp stub_all_dir_checks_true do
    stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
  end
end

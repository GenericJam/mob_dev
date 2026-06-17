defmodule MobDev.Release.OTPTest do
  use ExUnit.Case, async: false

  import Mox

  alias MobDev.Release.OTP

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

  # ── target_spec/1 — pinned surface ───────────────────────────────────

  describe "target_spec/1" do
    test "android_arm64 — arm64-android conf, with_openssl, otp_build_release" do
      spec = OTP.target_spec(:android_arm64)
      assert spec.arch_dir == "aarch64-unknown-linux-android"
      assert spec.xcomp_conf == "xcomp/erl-xcomp-arm64-android.conf"
      assert spec.default_release_root == "/tmp/otp-android"
      assert spec.ssl_strategy == :with_openssl
      assert spec.install_method == :otp_build_release
    end

    test "android_x86_64 — x86_64-android conf (arch_dir is x86_64-PC-linux-android)" do
      spec = OTP.target_spec(:android_x86_64)
      # config.sub canonicalizes x86_64-linux-android to the `pc` vendor, NOT
      # `unknown` like aarch64 — getting this wrong silently breaks the tarball.
      assert spec.arch_dir == "x86_64-pc-linux-android"
      assert spec.xcomp_conf == "xcomp/erl-xcomp-x86_64-android.conf"
      assert spec.default_release_root == "/tmp/otp-android-x86_64"
      assert spec.ssl_strategy == :with_openssl
      assert spec.install_method == :otp_build_release
    end

    test "android_arm32 — arm-android conf (NOT arm32-android — historical)" do
      spec = OTP.target_spec(:android_arm32)
      assert spec.arch_dir == "arm-unknown-linux-androideabi"
      # OTP's naming dropped the `32`: erl-xcomp-arm-android.conf, not
      # erl-xcomp-arm32-android.conf. If this drifts the build fails.
      assert spec.xcomp_conf == "xcomp/erl-xcomp-arm-android.conf"
      assert spec.default_release_root == "/tmp/otp-android-arm32"
    end

    test "ios_sim — iossimulator conf, WITHOUT ssl, make_release" do
      spec = OTP.target_spec(:ios_sim)
      assert spec.arch_dir == "aarch64-apple-iossimulator"
      assert spec.xcomp_conf == "xcomp/erl-xcomp-arm64-iossimulator.conf"
      assert spec.default_release_root == "/tmp/otp-ios-sim"
      # Load-bearing: iOS uses --without-ssl because
      # --enable-static-nifs + --with-ssl don't play nice.
      assert spec.ssl_strategy == :without_ssl
      assert spec.install_method == :make_release
    end

    test "ios_device — ios conf (not iossimulator), same flags as sim" do
      sim = OTP.target_spec(:ios_sim)
      device = OTP.target_spec(:ios_device)

      assert sim.xcomp_conf != device.xcomp_conf
      assert device.xcomp_conf == "xcomp/erl-xcomp-arm64-ios.conf"
      assert device.arch_dir == "aarch64-apple-ios"
      assert device.ssl_strategy == :without_ssl
      assert device.install_method == :make_release
    end

    test "targets/0 enumerates all five in canonical order" do
      assert OTP.targets() == [
               :android_arm64,
               :android_arm32,
               :android_x86_64,
               :ios_sim,
               :ios_device
             ]
    end
  end

  # ── configure_args/2 — pure assembly ─────────────────────────────────

  describe "configure_args/2" do
    test "android passes --with-ssl + --disable-dynamic-ssl-lib" do
      args = OTP.configure_args(OTP.target_spec(:android_arm64), "/openssl/prefix")

      assert "--xcomp-conf=./xcomp/erl-xcomp-arm64-android.conf" in args
      assert "--with-ssl=/openssl/prefix" in args
      assert "--disable-dynamic-ssl-lib" in args
      refute "--without-ssl" in args
    end

    test "iOS passes --without-ssl (regardless of openssl_prefix arg)" do
      # Even if a caller mistakenly hands an openssl_prefix to an iOS
      # build, the spec says --without-ssl. Mixing --with-ssl with iOS's
      # --enable-static-nifs breaks the link with undefined RAND_seed /
      # OSSL_PROVIDER_load — load-bearing.
      args = OTP.configure_args(OTP.target_spec(:ios_sim), "/this/is/ignored")

      assert "--without-ssl" in args
      refute Enum.any?(args, &String.starts_with?(&1, "--with-ssl"))
    end

    test "android raises ArgumentError when openssl_prefix is nil" do
      assert_raise ArgumentError, ~r/openssl_prefix is required/, fn ->
        OTP.configure_args(OTP.target_spec(:android_arm64), nil)
      end
    end

    test "xcomp-conf path uses the ./ prefix that otp_build expects" do
      for target_id <- OTP.targets() do
        args = OTP.configure_args(OTP.target_spec(target_id), "/openssl/prefix")

        assert Enum.any?(args, fn arg ->
                 String.starts_with?(arg, "--xcomp-conf=./xcomp/erl-xcomp-")
               end),
               "target #{target_id} missing properly-prefixed xcomp-conf in #{inspect(args)}"
      end
    end
  end

  # ── install_args/2 — pure assembly ───────────────────────────────────

  describe "install_args/2" do
    test "Android uses ./otp_build release -a" do
      args = OTP.install_args(OTP.target_spec(:android_arm64), "/tmp/otp-android")
      assert args == ["./otp_build", "release", "-a", "/tmp/otp-android"]
    end

    test "iOS uses make release with RELEASE_ROOT= env-arg" do
      args = OTP.install_args(OTP.target_spec(:ios_device), "/tmp/otp-ios-device")
      assert args == ["make", "release", "RELEASE_ROOT=/tmp/otp-ios-device"]
    end

    test "RELEASE_ROOT= prefix is literal — must not split on whitespace" do
      args = OTP.install_args(OTP.target_spec(:ios_sim), "/path")
      [last] = Enum.take(args, -1)
      assert last == "RELEASE_ROOT=/path"
      refute "RELEASE_ROOT" in args
    end
  end

  # ── build/2 against the Mox — full sequence ──────────────────────────

  describe "build/2 — android_arm64 happy path" do
    test "fires distclean + configure + boot + rm + otp_build release + verify",
         %{otp_src: otp_src} do
      stub_predicates_true()

      # The `cmd` stub branches on the argv shape. We capture each call
      # via an ETS table so the test can assert on the canonical sequence
      # after build/2 returns.
      cmd_log = :ets.new(:cmd_log, [:public, :ordered_set])

      stub(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        :ets.insert(cmd_log, {System.monotonic_time(), argv, opts})

        cond do
          hd(argv) == "ls" ->
            # verify_outputs's ls of release_root/lib — return Android
            # crypto apps so the with-ssl check passes.
            {:ok, "crypto-5.6\npublic_key-1.18\nssl-11.4\n"}

          true ->
            {:ok, ""}
        end
      end)

      assert {:ok, info} =
               OTP.build(:android_arm64,
                 otp_src: otp_src,
                 openssl_prefix: "/openssl/prefix",
                 release_root: "/fake/release",
                 ndk_root: "/fake/ndk"
               )

      # Inspect the call sequence.
      calls = :ets.tab2list(cmd_log) |> Enum.map(fn {_, argv, _opts} -> argv end)

      # The first 6 calls are the build pipeline.
      assert Enum.at(calls, 0) == ["make", "distclean"]
      assert hd(Enum.at(calls, 1)) == "./otp_build"
      assert "configure" in Enum.at(calls, 1)
      assert Enum.at(calls, 2) == ["./otp_build", "boot"]
      assert Enum.at(calls, 3) == ["rm", "-rf", "/fake/release"]
      assert Enum.at(calls, 4) == ["./otp_build", "release", "-a", "/fake/release"]
      # Then ls for verify.
      assert hd(Enum.at(calls, 5)) == "ls"

      # Verify the configure invocation had the right env.
      configure_call = Enum.at(calls, 1)
      assert "--xcomp-conf=./xcomp/erl-xcomp-arm64-android.conf" in configure_call
      assert "--with-ssl=/openssl/prefix" in configure_call
      assert "--disable-dynamic-ssl-lib" in configure_call

      assert info.target == :android_arm64
      assert info.release_root == "/fake/release"
      assert info.erts_vsn == "17.0"
    end
  end

  describe "build/2 — ios_sim happy path" do
    test "uses --without-ssl, make release RELEASE_ROOT=, verifies arch config.h",
         %{otp_src: otp_src} do
      stub_predicates_true()

      cmd_log = :ets.new(:cmd_log_ios, [:public, :ordered_set])

      stub(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        :ets.insert(cmd_log, {System.monotonic_time(), argv, opts})
        {:ok, ""}
      end)

      assert {:ok, info} =
               OTP.build(:ios_sim,
                 otp_src: otp_src,
                 release_root: "/fake/release"
               )

      calls = :ets.tab2list(cmd_log) |> Enum.map(fn {_, argv, _opts} -> argv end)

      # Configure: --without-ssl, NOT --with-ssl
      assert configure_call = Enum.find(calls, fn argv -> "configure" in argv end)
      assert "--xcomp-conf=./xcomp/erl-xcomp-arm64-iossimulator.conf" in configure_call
      assert "--without-ssl" in configure_call
      refute Enum.any?(configure_call, &String.starts_with?(&1, "--with-ssl"))

      # Install: make release RELEASE_ROOT= (NOT otp_build release)
      install_call = Enum.find(calls, fn argv -> hd(argv) == "make" and "release" in argv end)
      assert install_call == ["make", "release", "RELEASE_ROOT=/fake/release"]

      assert info.target == :ios_sim
    end
  end

  describe "build/2 — ios env doesn't leak NDK keys" do
    test "iOS configure invocation has RELEASE_LIBBEAM but no NDK_ROOT/NDK_ABI_PLAT",
         %{otp_src: otp_src} do
      stub_predicates_true()

      captured_env = :atomics.new(1, signed: false)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        if "configure" in argv do
          send(self(), {:configure_env, Keyword.fetch!(opts, :env)})
        end

        :atomics.add(captured_env, 1, 1)
        {:ok, ""}
      end)

      assert {:ok, _} =
               OTP.build(:ios_device,
                 otp_src: otp_src,
                 release_root: "/fake/release"
               )

      assert_received {:configure_env, env}
      assert {"RELEASE_LIBBEAM", "yes"} = List.keyfind(env, "RELEASE_LIBBEAM", 0)
      refute List.keyfind(env, "NDK_ROOT", 0)
      refute List.keyfind(env, "NDK_ABI_PLAT", 0)
    end
  end

  # ── Precondition failures ────────────────────────────────────────────

  describe "build/2 preconditions" do
    test "missing OTP_SRC → precondition_failed with clone hint" do
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> false end)

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:android_arm64,
                 otp_src: "/nonexistent",
                 openssl_prefix: "/openssl/prefix",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "OTP_SRC missing"
      assert msg =~ "github.com/erlang/otp"
    end

    test "OTP_SRC without otp_build script → precondition_failed", %{otp_src: otp_src} do
      # otp_src exists. file? returns false for the otp_build file.
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> false end)

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:android_arm64,
                 otp_src: otp_src,
                 openssl_prefix: "/openssl/prefix",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "otp_build script not found"
    end

    test "android target without openssl_prefix → precondition_failed pointing at OpenSSL",
         %{otp_src: otp_src} do
      stub_predicates_true()

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:android_arm64,
                 otp_src: otp_src,
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "openssl_prefix required"
      assert msg =~ "MobDev.Release.OpenSSL.build"
    end

    test "android target with missing openssl_prefix dir → precondition_failed",
         %{otp_src: otp_src} do
      # otp_src dir: true; otp_build file: true; openssl_prefix dir: false
      stub(MobDev.Release.ShellMock, :dir?, fn path ->
        not String.starts_with?(path, "/nonexistent")
      end)

      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:android_arm64,
                 otp_src: otp_src,
                 openssl_prefix: "/nonexistent",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "OPENSSL_PREFIX missing"
    end

    test "android target with missing NDK root → precondition_failed",
         %{otp_src: otp_src} do
      # Everything exists EXCEPT the NDK root.
      stub(MobDev.Release.ShellMock, :dir?, fn path ->
        not String.starts_with?(path, "/no/ndk")
      end)

      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:android_arm64,
                 otp_src: otp_src,
                 openssl_prefix: "/openssl/prefix",
                 ndk_root: "/no/ndk"
               )

      assert msg =~ "Android NDK"
    end
  end

  # ── Verification failures ────────────────────────────────────────────

  describe "build/2 verification failures" do
    test "missing erts-<vsn> dir after install → precondition_failed", %{otp_src: otp_src} do
      # All preconditions pass. After the build, erts-<vsn> dir check
      # returns false.
      stub(MobDev.Release.ShellMock, :dir?, fn path ->
        not String.ends_with?(path, "/erts-17.0")
      end)

      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:android_arm64,
                 otp_src: otp_src,
                 openssl_prefix: "/openssl/prefix",
                 release_root: "/fake/release",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "missing"
      assert msg =~ "erts-17.0"
    end

    test "Android verify catches missing crypto/public_key/ssl apps (the --with-ssl wiring check)",
         %{otp_src: otp_src} do
      stub_predicates_true()

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          hd(argv) == "ls" ->
            # Missing crypto/public_key/ssl — exactly the silent shipping
            # bug we want to fail loudly.
            {:ok, "kernel-9.0\nstdlib-6.0\n"}

          true ->
            {:ok, ""}
        end
      end)

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:android_arm64,
                 otp_src: otp_src,
                 openssl_prefix: "/openssl/prefix",
                 release_root: "/fake/release",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "crypto"
      assert msg =~ "--with-ssl"
    end

    test "iOS verify catches missing arch-specific config.h", %{otp_src: otp_src} do
      # All dir? true. file? returns false for the config.h check,
      # true for the otp_build file check.
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)

      stub(MobDev.Release.ShellMock, :file?, fn path ->
        not String.ends_with?(path, "config.h")
      end)

      stub(MobDev.Release.ShellMock, :cmd, fn _, _ -> {:ok, ""} end)

      assert {:error, {:precondition_failed, msg}} =
               OTP.build(:ios_device,
                 otp_src: otp_src,
                 release_root: "/fake/release"
               )

      assert msg =~ "config.h"
      assert msg =~ "arch-specific"
    end
  end

  # ── build_all/1 ──────────────────────────────────────────────────────

  describe "build_all/1" do
    test "passes per-target openssl_prefix defaults to Android targets", %{otp_src: otp_src} do
      stub_predicates_true()

      configure_calls = :ets.new(:configure_calls, [:public, :duplicate_bag])

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          "configure" in argv ->
            :ets.insert(configure_calls, {:configure, argv})
            {:ok, ""}

          hd(argv) == "ls" ->
            # Pass Android verify by reporting crypto apps.
            {:ok, "crypto-5.6\npublic_key-1.18\nssl-11.4\n"}

          true ->
            {:ok, ""}
        end
      end)

      OTP.build_all(otp_src: otp_src, ndk_root: "/fake/ndk")

      calls = :ets.tab2list(configure_calls)
      assert length(calls) == 5

      flat = List.flatten(for {:configure, argv} <- calls, do: argv)
      assert Enum.any?(flat, &(&1 == "--with-ssl=/tmp/openssl-android-arm64"))
      assert Enum.any?(flat, &(&1 == "--with-ssl=/tmp/openssl-android-arm32"))
      assert Enum.any?(flat, &(&1 == "--with-ssl=/tmp/openssl-android-x86_64"))
      assert Enum.count(flat, &(&1 == "--without-ssl")) == 2
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp stub_predicates_true do
    stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
    stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
  end

  defp mk_tmp_otp_fixture do
    tmp =
      Path.join(System.tmp_dir!(), "mob_dev_otp_release_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "erts"))
    File.write!(Path.join([tmp, "erts", "vsn.mk"]), "VSN = 17.0\n")
    File.touch!(Path.join(tmp, "otp_build"))
    tmp
  end
end

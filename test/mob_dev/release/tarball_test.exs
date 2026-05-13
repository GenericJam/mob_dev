defmodule MobDev.Release.TarballTest do
  use ExUnit.Case, async: false

  import Mox

  alias MobDev.Release.Tarball

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  # ── target_spec/1 — pinned surface ───────────────────────────────────

  describe "target_spec/1" do
    test "android_arm64 tarball basename is `otp-android` (NOT otp-android-arm64)" do
      spec = Tarball.target_spec(:android_arm64)

      # Load-bearing asymmetry — MobDev.OtpDownloader's @otp_hash
      # cache convention depends on this. Changing to otp-android-arm64
      # would break every existing cache entry.
      assert spec.tarball_basename == "otp-android"
      assert spec.arch_dir == "aarch64-unknown-linux-android"
      assert spec.include_exqlite
      refute spec.include_epmd_source
      assert spec.borrow_crypto_apps == nil
    end

    test "android_arm32 basename includes the arm32 suffix" do
      spec = Tarball.target_spec(:android_arm32)
      assert spec.tarball_basename == "otp-android-arm32"
      assert spec.arch_dir == "arm-unknown-linux-androideabi"
      assert spec.include_exqlite
      refute spec.include_epmd_source
    end

    test "ios_sim borrows from Android install, no exqlite, excludes test apps" do
      spec = Tarball.target_spec(:ios_sim)
      assert spec.tarball_basename == "otp-ios-sim"
      refute spec.include_exqlite
      refute spec.include_epmd_source
      assert spec.borrow_crypto_apps == "/tmp/otp-android"
      # Spurious build dirs from the iOS-sim cross-compile.
      assert "beamhello" in spec.tar_excludes
      assert "test_app" in spec.tar_excludes
    end

    test "ios_device borrows from Android AND ships EPMD source" do
      spec = Tarball.target_spec(:ios_device)
      assert spec.tarball_basename == "otp-ios-device"
      refute spec.include_exqlite
      assert spec.include_epmd_source
      assert spec.borrow_crypto_apps == "/tmp/otp-android"
    end

    test "android_arm64 verifies crypto.so + public_key/ssl beams; arm32 doesn't" do
      arm64 = Tarball.target_spec(:android_arm64)
      arm32 = Tarball.target_spec(:android_arm32)

      assert "lib/crypto-.*/priv/lib/crypto.so" in arm64.additional_verifies
      assert "lib/public_key-.*/ebin/public_key.beam" in arm64.additional_verifies
      assert "lib/ssl-.*/ebin/ssl.beam" in arm64.additional_verifies

      # arm32 historical: shell version didn't verify these, so we don't
      # either. Reason: the arm32 OTP install layout differs (no static-
      # link symbol search via nm in the shell). Keeping parity.
      assert arm32.additional_verifies == []
    end

    test "ios_device verifies EPMD source files + arch-specific config.h" do
      spec = Tarball.target_spec(:ios_device)

      assert "erts/epmd/src/epmd.c" in spec.additional_verifies
      assert "erts/epmd/src/epmd_srv.c" in spec.additional_verifies
      assert "erts/epmd/src/epmd_cli.c" in spec.additional_verifies
      assert "erts/aarch64-apple-ios/config.h" in spec.additional_verifies
    end

    test "targets/0 enumerates all four in canonical order" do
      assert Tarball.targets() == [:android_arm64, :android_arm32, :ios_sim, :ios_device]
    end
  end

  # ── tarball_path/3 — pure assembly ───────────────────────────────────

  describe "tarball_path/3" do
    test "android_arm64 is `<out>/otp-android-<hash>.tar.gz`" do
      target = Tarball.target_spec(:android_arm64)

      assert Tarball.tarball_path(target, "/tmp", "abc12345") ==
               "/tmp/otp-android-abc12345.tar.gz"
    end

    test "ios_device interpolates the basename + hash" do
      target = Tarball.target_spec(:ios_device)

      assert Tarball.tarball_path(target, "/out", "feedface") ==
               "/out/otp-ios-device-feedface.tar.gz"
    end
  end

  # ── exqlite version parsers (pure) ───────────────────────────────────

  describe "parse_exqlite_version_from_lock/1" do
    test "extracts version from a canonical mix.lock entry" do
      content = """
      %{
        "exqlite": {:hex, :exqlite, "0.39.0", "abc123", [:make, :mix], [...], "hexpm", "..."},
        "jason": {:hex, :jason, "1.4.4", "..."}
      }
      """

      assert Tarball.parse_exqlite_version_from_lock(content) == {:ok, "0.39.0"}
    end

    test "handles entries on a single long line" do
      content =
        ~S({"exqlite": {:hex, :exqlite, "0.42.1", "hash", [:make, :mix], [], "hexpm", "outer-hash"},})

      assert Tarball.parse_exqlite_version_from_lock(content) == {:ok, "0.42.1"}
    end

    test "tolerates extra whitespace inside the tuple" do
      content = ~S("exqlite":  {:hex,  :exqlite,   "1.0.0",)
      assert Tarball.parse_exqlite_version_from_lock(content) == {:ok, "1.0.0"}
    end

    test "rejects when exqlite isn't present" do
      content = ~S("jason": {:hex, :jason, "1.4.4", "..."})
      assert {:error, {:parse_failed, _}} = Tarball.parse_exqlite_version_from_lock(content)
    end

    test "doesn't false-match a similarly-named package" do
      # `exqlite_extra` is hypothetical, but the regex anchor must
      # require the exact "exqlite" key.
      content = ~S("exqlite_extra": {:hex, :exqlite_extra, "9.9.9", "..."})
      assert {:error, {:parse_failed, _}} = Tarball.parse_exqlite_version_from_lock(content)
    end
  end

  describe "parse_exqlite_version_from_app_file/1" do
    test "extracts vsn from a real exqlite.app shape" do
      content = """
      {application, exqlite,
       [{description, "An Elixir SQLite3 library"},
        {modules, [...]},
        {vsn, "0.39.0"},
        {applications, [kernel, stdlib, elixir]}
       ]}.
      """

      assert Tarball.parse_exqlite_version_from_app_file(content) == {:ok, "0.39.0"}
    end

    test "rejects when vsn key is absent" do
      content = "{application, exqlite, [{description, \"...\"}]}."
      assert {:error, {:parse_failed, _}} = Tarball.parse_exqlite_version_from_app_file(content)
    end
  end

  # ── check_entries/3 — the verify_tarball heart ───────────────────────

  describe "check_entries/3" do
    test "returns :ok when every expected entry matches at least one line" do
      listing = """
      mob_dev_stage_123/
      mob_dev_stage_123/erts-17.0/
      mob_dev_stage_123/erts-17.0/lib/crypto.a
      mob_dev_stage_123/erts-17.0/lib/libcrypto.a
      mob_dev_stage_123/lib/elixir/ebin/elixir.app
      """

      assert :ok =
               Tarball.check_entries(
                 listing,
                 [
                   "erts-17.0",
                   "lib/elixir/ebin/elixir.app",
                   "erts-17.0/lib/crypto.a"
                 ],
                 "/tmp/x.tar.gz"
               )
    end

    test "regex wildcards match expected entries" do
      listing = """
      stage/lib/crypto-5.6/priv/lib/crypto.so
      stage/lib/public_key-1.18/ebin/public_key.beam
      stage/lib/ssl-11.4/ebin/ssl.beam
      """

      assert :ok =
               Tarball.check_entries(
                 listing,
                 [
                   "lib/crypto-.*/priv/lib/crypto.so",
                   "lib/public_key-.*/ebin/public_key.beam",
                   "lib/ssl-.*/ebin/ssl.beam"
                 ],
                 "/tmp/x.tar.gz"
               )
    end

    test "fails with the missing entry named when one is absent" do
      listing = "stage/erts-17.0/\nstage/erts-17.0/lib/crypto.a\n"

      assert {:error, {:precondition_failed, msg}} =
               Tarball.check_entries(
                 listing,
                 ["erts-17.0", "lib/elixir/ebin/elixir.app"],
                 "/tmp/x.tar.gz"
               )

      assert msg =~ "lib/elixir/ebin/elixir.app"
      assert msg =~ "/tmp/x.tar.gz"
    end

    test "iOS device verify catches missing EPMD source (load-bearing for static-link)" do
      # If the EPMD source isn't in the tarball, downstream
      # build_device builds will fail when trying to static-link
      # EPMD into the iOS app — but only at the END of the build
      # pipeline, hours of error report time. Here it fails before
      # the tarball ships.
      listing = """
      stage/erts-17.0/
      stage/erts-17.0/lib/crypto.a
      stage/erts-17.0/lib/libcrypto.a
      stage/lib/elixir/ebin/elixir.app
      """

      ios_device = Tarball.target_spec(:ios_device)

      assert {:error, {:precondition_failed, msg}} =
               Tarball.check_entries(
                 listing,
                 Tarball.required_entries(ios_device, %{erts_vsn: "17.0"}),
                 "/tmp/otp-ios-device.tar.gz"
               )

      assert msg =~ "epmd"
    end
  end

  # ── required_entries/2 — pinned per-target verify lists ─────────────

  describe "required_entries/2" do
    test "interpolates erts_vsn into the universal entries" do
      target = Tarball.target_spec(:android_arm64)
      entries = Tarball.required_entries(target, %{erts_vsn: "17.0"})

      assert "erts-17.0" in entries
      assert "erts-17.0/lib/crypto.a" in entries
      assert "erts-17.0/lib/libcrypto.a" in entries
      assert "lib/elixir/ebin/elixir.app" in entries
    end

    test "android_arm64 appends the crypto.so / public_key / ssl entries" do
      target = Tarball.target_spec(:android_arm64)
      entries = Tarball.required_entries(target, %{erts_vsn: "17.0"})

      assert "lib/crypto-.*/priv/lib/crypto.so" in entries
      assert "lib/public_key-.*/ebin/public_key.beam" in entries
      assert "lib/ssl-.*/ebin/ssl.beam" in entries
    end

    test "ios_device appends EPMD source + arch config.h entries" do
      target = Tarball.target_spec(:ios_device)
      entries = Tarball.required_entries(target, %{erts_vsn: "17.0"})

      assert "erts/epmd/src/epmd.c" in entries
      assert "erts/aarch64-apple-ios/config.h" in entries
    end
  end

  # ── build/2 against the Mox — Android arm64 happy path ──────────────
  # The full pipeline is long; this test asserts the call order is right
  # and the tarball gets named correctly.

  describe "build/2 — android_arm64" do
    test "stages otp_release, copies static libs, bundles exqlite, tars + verifies" do
      {otp_src, exqlite_build} = mk_tmp_project()

      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)
      stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)

      cmd_log = :ets.new(:cmds, [:public, :ordered_set])

      stub(MobDev.Release.ShellMock, :cmd, fn argv, opts ->
        :ets.insert(cmd_log, {System.monotonic_time(), argv, opts})

        cond do
          hd(argv) == "mktemp" ->
            {:ok, "/tmp/fake-stage\n"}

          hd(argv) == "tar" and "tzf" in argv ->
            # Return a listing that satisfies the verify step.
            {:ok,
             """
             fake-stage/erts-17.0/
             fake-stage/erts-17.0/lib/crypto.a
             fake-stage/erts-17.0/lib/libcrypto.a
             fake-stage/lib/elixir/ebin/elixir.app
             fake-stage/lib/crypto-5.6/priv/lib/crypto.so
             fake-stage/lib/public_key-1.18/ebin/public_key.beam
             fake-stage/lib/ssl-11.4/ebin/ssl.beam
             """}

          true ->
            {:ok, ""}
        end
      end)

      assert {:ok, info} =
               Tarball.build(:android_arm64,
                 otp_src: otp_src,
                 hash: "abc12345",
                 out_dir: "/out",
                 otp_release: "/tmp/otp-android",
                 openssl_prefix: "/tmp/openssl-android-arm64",
                 exqlite_build: exqlite_build
               )

      assert info.tarball == "/out/otp-android-abc12345.tar.gz"
      assert info.hash == "abc12345"
      assert info.erts_vsn == "17.0"

      # Inspect the sequence
      calls = :ets.tab2list(cmd_log) |> Enum.map(fn {_, argv, _} -> argv end)

      # mktemp -d came first
      assert hd(hd(calls)) == "mktemp"

      # cp -r OTP_RELEASE/. STAGE — there's a copy with trailing "/."
      assert Enum.any?(calls, fn argv ->
               hd(argv) == "cp" and Enum.any?(argv, &String.ends_with?(&1, "/tmp/otp-android/."))
             end)

      # tar czf <tarball> — exists, with the right output path
      assert tar_call =
               Enum.find(calls, fn argv ->
                 hd(argv) == "tar" and "czf" in argv
               end)

      assert "/out/otp-android-abc12345.tar.gz" in tar_call

      # tar tzf for verify
      assert Enum.any?(calls, fn argv -> hd(argv) == "tar" and "tzf" in argv end)

      # Cleanup the temp project root we made
      File.rm_rf!(otp_src)
    end
  end

  describe "build/2 — ios_sim" do
    test "borrows from Android install, uses iossimulator arch, excludes test-app dirs" do
      {otp_src, _exqlite_build} = mk_tmp_project()

      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)
      stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)

      cmd_log = :ets.new(:ios_cmds, [:public, :ordered_set])

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        :ets.insert(cmd_log, {System.monotonic_time(), argv})

        cond do
          hd(argv) == "mktemp" ->
            {:ok, "/tmp/fake-stage-ios\n"}

          # Glob for crypto-*/ etc. via bash -c "ls -d ... | head -1"
          hd(argv) == "bash" and Enum.any?(argv, &String.contains?(&1, "ls -d")) ->
            # Just return a fake match.
            {:ok, "/tmp/otp-android/lib/crypto-5.6/"}

          hd(argv) == "tar" and "tzf" in argv ->
            {:ok,
             """
             stage/erts-17.0/
             stage/erts-17.0/lib/crypto.a
             stage/erts-17.0/lib/libcrypto.a
             stage/lib/elixir/ebin/elixir.app
             """}

          true ->
            {:ok, ""}
        end
      end)

      assert {:ok, info} =
               Tarball.build(:ios_sim,
                 otp_src: otp_src,
                 hash: "feed1234",
                 out_dir: "/out",
                 otp_release: "/tmp/otp-ios-sim",
                 openssl_prefix: "/tmp/openssl-ios-sim"
                 # no :exqlite_build — iOS doesn't ship exqlite
               )

      assert info.tarball == "/out/otp-ios-sim-feed1234.tar.gz"

      calls = :ets.tab2list(cmd_log) |> Enum.map(fn {_, argv} -> argv end)

      # tar invocation should include --exclude= flags for the test-app dirs
      assert tar_call = Enum.find(calls, fn argv -> hd(argv) == "tar" and "czf" in argv end)
      assert Enum.any?(tar_call, &String.ends_with?(&1, "/beamhello"))
      assert Enum.any?(tar_call, &String.ends_with?(&1, "/test_app"))

      File.rm_rf!(otp_src)
    end
  end

  # ── Preconditions ────────────────────────────────────────────────────

  describe "build/2 preconditions" do
    test "missing OTP_SRC → precondition_failed" do
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> false end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)

      assert {:error, {:precondition_failed, msg}} =
               Tarball.build(:android_arm64,
                 otp_src: "/nope",
                 hash: "abc12345",
                 erts_vsn: "17.0",
                 exqlite_build: "/x"
               )

      assert msg =~ "OTP_SRC"
    end

    test "missing OTP_RELEASE → precondition_failed pointing at MobDev.Release.OTP" do
      {otp_src, exqlite_build} = mk_tmp_project()

      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)

      # Path-based stubbing: everything exists EXCEPT the otp_release
      # path. Clearer than counter-based ordering.
      stub(MobDev.Release.ShellMock, :dir?, fn path ->
        not String.starts_with?(path, "/nonexistent")
      end)

      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)

      assert {:error, {:precondition_failed, msg}} =
               Tarball.build(:android_arm64,
                 otp_src: otp_src,
                 hash: "abc12345",
                 erts_vsn: "17.0",
                 otp_release: "/nonexistent",
                 openssl_prefix: "/openssl",
                 exqlite_build: exqlite_build
               )

      assert msg =~ "otp_release missing"
      assert msg =~ "MobDev.Release.OTP.build"

      File.rm_rf!(otp_src)
    end

    test "android target without exqlite_build → precondition_failed", %{} do
      {otp_src, _exqlite_build} = mk_tmp_project()
      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)

      assert {:error, {:precondition_failed, msg}} =
               Tarball.build(:android_arm64,
                 otp_src: otp_src,
                 hash: "abc12345"
                 # no :exqlite_build
               )

      assert msg =~ "exqlite_build required"

      File.rm_rf!(otp_src)
    end
  end

  # ── verify failure surfaces as precondition_failed ───────────────────

  describe "verify_tarball — failure surfaces" do
    test "missing crypto.so in the listing fails the build" do
      {otp_src, exqlite_build} = mk_tmp_project()

      stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      stub(MobDev.Release.ShellMock, :fetch_env, fn _ -> :error end)
      stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)

      stub(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        cond do
          hd(argv) == "mktemp" ->
            {:ok, "/tmp/fake\n"}

          hd(argv) == "tar" and "tzf" in argv ->
            # Listing missing the crypto.so entry — exactly the silent
            # shipping bug we want to catch.
            {:ok,
             """
             stage/erts-17.0/
             stage/erts-17.0/lib/crypto.a
             stage/erts-17.0/lib/libcrypto.a
             stage/lib/elixir/ebin/elixir.app
             stage/lib/public_key-1.18/ebin/public_key.beam
             stage/lib/ssl-11.4/ebin/ssl.beam
             """}

          true ->
            {:ok, ""}
        end
      end)

      assert {:error, {:precondition_failed, msg}} =
               Tarball.build(:android_arm64,
                 otp_src: otp_src,
                 hash: "abc12345",
                 out_dir: "/out",
                 exqlite_build: exqlite_build
               )

      assert msg =~ "verify failed"
      assert msg =~ "crypto-.*/priv/lib/crypto.so"

      File.rm_rf!(otp_src)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # mk_tmp_project returns `{otp_src_path, exqlite_build_path}` where
  # both directories exist and contain enough fixture files for the
  # tarball build to read:
  #   * `otp_src/erts/vsn.mk` — read by Helpers.erts_version
  #   * `otp_src/otp_build` — checked by precheck (file exists)
  #   * `exqlite_build/ebin/exqlite.app` — fallback exqlite version source
  #   * `<project_root>/mix.lock` — primary exqlite version source
  #     (sits 4 levels above exqlite_build, project-root convention)
  defp mk_tmp_project do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "mob_dev_tarball_#{uniq}")

    otp_src = Path.join(base, "otp_src")
    File.mkdir_p!(Path.join(otp_src, "erts"))
    File.write!(Path.join([otp_src, "erts", "vsn.mk"]), "VSN = 17.0\n")
    File.touch!(Path.join(otp_src, "otp_build"))

    # Build a fake project layout: project_root/_build/dev/lib/exqlite/ebin/
    project_root = Path.join(base, "user_project")
    exqlite_build = Path.join([project_root, "_build/dev/lib/exqlite"])
    File.mkdir_p!(Path.join(exqlite_build, "ebin"))

    # The .app file with a vsn entry (fallback parse source)
    File.write!(Path.join([exqlite_build, "ebin", "exqlite.app"]), """
    {application, exqlite, [{vsn, "0.39.0"}]}.
    """)

    # mix.lock at the project root (preferred parse source)
    File.write!(Path.join(project_root, "mix.lock"), """
    %{"exqlite": {:hex, :exqlite, "0.39.0", "abc", [:make, :mix], [], "hexpm", "outer"}}
    """)

    {otp_src, exqlite_build}
  end
end

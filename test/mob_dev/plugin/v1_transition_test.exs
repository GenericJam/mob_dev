defmodule MobDev.Plugin.V1TransitionTest do
  # async: false — the notice test swaps the global Mix shell.
  use ExUnit.Case, async: false

  alias MobDev.Plugin.{SignatureGate, Verify}

  # `priv/` of mob_scanner 0.1.3 exactly as published on Hex
  # (`mix hex.package fetch mob_scanner 0.1.3 --unpack`): a real v1 envelope
  # signed in plugin CI with the shared first-party key.
  @fixture Path.expand("../../fixtures/plugins/mob_scanner_v1", __DIR__)
  @trusted_fp "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
  @hexpm_entry {:hex, :mob_scanner, "0.1.3",
                "20e740fadc1d521c04fdb41052f521ed53cfc17b5bc3cfaa8f8948b28ba96626", [:mix],
                [{:mob, "~> 0.7", [hex: :mob, repo: "hexpm", optional: false]}], "hexpm",
                "86b366d59efc042765378a9bc4c42c4b60ebd917a146a9edb89a857996c85d34"}

  setup do
    root = Path.join(System.tmp_dir!(), "mob_v1_transition_#{System.unique_integer([:positive])}")
    deps_path = Path.join(root, "deps")
    dir = Path.join(deps_path, "mob_scanner")
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(@fixture, "priv"), Path.join(dir, "priv"))
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [
      scms: %{mob_scanner: Hex.SCM},
      lock: %{mob_scanner: @hexpm_entry},
      deps_path: deps_path,
      trust_map: %{mob_scanner: @trusted_fp}
    ]

    {:ok, root: root, dir: dir, opts: opts}
  end

  # Prepends a side effect to the published manifest. The manifest still
  # evaluates to the signed map, so a v1 check would pass once it ran — the
  # sentinel proves whether evaluation happened at all.
  defp arm_sentinel(dir) do
    sentinel = Path.join(Path.dirname(dir), "EVALUATED")
    manifest = Path.join(dir, "priv/mob_plugin.exs")
    File.write!(manifest, "File.write!(#{inspect(sentinel)}, \"x\")\n" <> File.read!(manifest))
    sentinel
  end

  describe "accepted: hexpm lock entry + trusted fingerprint + valid v1 signature" do
    test "load_verified evaluates and returns the published manifest", %{dir: dir, opts: opts} do
      assert {:ok, %{name: :mob_scanner, nifs: [_ | _]}} = Verify.load_verified(dir, opts)
    end

    test "the build gate passes it", %{dir: dir, opts: opts} do
      {:ok, manifest} = Verify.load_verified(dir, opts)
      {trust_map, v1_opts} = Keyword.pop(opts, :trust_map)

      assert :ok = SignatureGate.check_activated([{dir, manifest}], trust_map, [], v1_opts)
    end

    test "prints the one-line transition notice with the locked version",
         %{dir: dir, opts: opts} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      {:ok, manifest} = Verify.load_verified(dir, opts)
      assert :ok = SignatureGate.maybe_print_v1_transition_notice([{dir, manifest}], opts)

      assert_received {:mix_shell, :info, [notice]}

      assert notice =~
               "mob_scanner 0.1.3 uses a legacy v1 signature, accepted during the v2 " <>
                 "transition (MOB-287); it will be refused once re-signed releases ship"

      refute_received {:mix_shell, :info, _}
    end
  end

  describe "refused without evaluating the manifest" do
    test "a path dependency (no lock entry, directory outside deps/)",
         %{root: root, dir: dir, opts: opts} do
      path_dir = Path.join([root, "vendor", "mob_scanner"])
      File.mkdir_p!(Path.dirname(path_dir))
      File.rename!(dir, path_dir)
      sentinel = arm_sentinel(path_dir)
      opts = Keyword.merge(opts, scms: %{mob_scanner: Mix.SCM.Path}, lock: %{})

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(path_dir, opts)
      refute File.exists?(sentinel)
    end

    # `{:mob_scanner, path: "deps/mob_scanner", override: true}` resolves to
    # exactly the Hex checkout directory and Mix keeps the stale hexpm lock
    # line, so only the active SCM tells it apart from the Hex dependency.
    test "a path override pointing into deps/ with a stale hexpm lock entry",
         %{dir: dir, opts: opts} do
      sentinel = arm_sentinel(dir)
      opts = Keyword.put(opts, :scms, %{mob_scanner: Mix.SCM.Path})

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
      refute File.exists?(sentinel)
    end

    test "a directory other than the deps/ checkout, even with Hex SCM and a hexpm lock",
         %{root: root, dir: dir, opts: opts} do
      path_dir = Path.join([root, "vendor", "mob_scanner"])
      File.mkdir_p!(Path.dirname(path_dir))
      File.rename!(dir, path_dir)
      sentinel = arm_sentinel(path_dir)

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(path_dir, opts)
      refute File.exists?(sentinel)
    end

    test "a git dependency", %{dir: dir, opts: opts} do
      sentinel = arm_sentinel(dir)

      git = {:git, "https://github.com/GenericJam/mob_scanner.git", "0123abcd", []}
      opts = Keyword.merge(opts, scms: %{mob_scanner: Mix.SCM.Git}, lock: %{mob_scanner: git})

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
      refute File.exists?(sentinel)
    end

    test "a Hex package from a repo other than public hexpm", %{dir: dir, opts: opts} do
      sentinel = arm_sentinel(dir)
      opts = Keyword.put(opts, :lock, %{mob_scanner: put_elem(@hexpm_entry, 6, "hexpm:acme")})

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
      refute File.exists?(sentinel)
    end

    test "a missing lock entry", %{dir: dir, opts: opts} do
      sentinel = arm_sentinel(dir)
      opts = Keyword.put(opts, :lock, %{mob_camera: put_elem(@hexpm_entry, 1, :mob_camera)})

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
      refute File.exists?(sentinel)
    end

    test "a fingerprint not in :trusted_plugins", %{dir: dir, opts: opts} do
      sentinel = arm_sentinel(dir)
      opts = Keyword.put(opts, :trust_map, %{mob_camera: @trusted_fp})

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
      refute File.exists?(sentinel)
    end

    test "a fingerprint different from the trusted one", %{dir: dir, opts: opts} do
      sentinel = arm_sentinel(dir)
      other_fp = "ed25519:" <> Base.encode64(:crypto.hash(:sha256, "another key"))
      opts = Keyword.put(opts, :trust_map, %{mob_scanner: other_fp})

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
      refute File.exists?(sentinel)
    end
  end

  describe "refused after provenance passes" do
    test "a tampered manifest", %{dir: dir, opts: opts} do
      manifest = Path.join(dir, "priv/mob_plugin.exs")

      File.write!(
        manifest,
        String.replace(
          File.read!(manifest),
          "android.permission.CAMERA",
          "android.permission.READ_SMS"
        )
      )

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
    end

    test "a tampered signed source file", %{dir: dir, opts: opts} do
      File.write!(Path.join(dir, "priv/native/jni/mob_scanner_nif.zig"), "// evil\n", [:append])

      assert {:error, :envelope_v1_unsupported} = Verify.load_verified(dir, opts)
    end
  end

  describe "SignatureGate" do
    test "refuses a v1 plugin whose manifest load_verified refused", %{dir: dir, opts: opts} do
      {trust_map, v1_opts} = Keyword.pop(opts, :trust_map)

      assert {:error, [{:envelope_v1_unsupported, :mob_scanner}]} =
               SignatureGate.check_activated([{dir, nil}], trust_map, [], v1_opts)
    end

    test "refuses an untrusted v1 plugin even when handed its manifest",
         %{dir: dir, opts: opts} do
      {:ok, manifest} = Verify.load_verified(dir, opts)
      v1_opts = Keyword.delete(opts, :trust_map)

      assert {:error, [{:envelope_v1_unsupported, :mob_scanner}]} =
               SignatureGate.check_activated([{dir, manifest}], %{}, [], v1_opts)
    end

    test "refuses a v1 plugin handed a manifest other than the signed one",
         %{dir: dir, opts: opts} do
      {:ok, manifest} = Verify.load_verified(dir, opts)
      {trust_map, v1_opts} = Keyword.pop(opts, :trust_map)
      forged = Map.put(manifest, :description, "forged")

      assert {:error, [{:envelope_v1_unsupported, :mob_scanner}]} =
               SignatureGate.check_activated([{dir, forged}], trust_map, [], v1_opts)
    end

    test "prints no transition notice for a v1 plugin that does not qualify",
         %{dir: dir, opts: opts} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      {:ok, manifest} = Verify.load_verified(dir, opts)
      untrusted = Keyword.put(opts, :trust_map, %{})

      assert :ok = SignatureGate.maybe_print_v1_transition_notice([{dir, manifest}], untrusted)
      refute_received {:mix_shell, :info, _}
    end
  end
end

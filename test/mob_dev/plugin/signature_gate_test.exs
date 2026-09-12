defmodule MobDev.Plugin.SignatureGateTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Crypto, Sign, SignatureGate}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mob_sig_gate_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "priv"))
    on_exit(fn -> File.rm_rf!(dir) end)

    manifest = %{name: :mob_demo, mob_version: "~> 0.6", plugin_spec_version: 1}
    File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(manifest, limit: :infinity))

    {priv, pub} = Crypto.generate_keypair()
    File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")
    :ok = Sign.sign_plugin(dir, priv)

    {:ok, dir: dir, manifest: manifest, pub: pub}
  end

  describe "check_plugin/4" do
    test "passes when signature verifies and fingerprint is trusted", %{
      dir: dir,
      manifest: manifest,
      pub: pub
    } do
      trust = %{mob_demo: Crypto.fingerprint(pub)}
      assert SignatureGate.check_plugin(dir, manifest, trust, []) == :ok
    end

    test "untrusted when fingerprint not in trust map", %{
      dir: dir,
      manifest: manifest,
      pub: pub
    } do
      result = SignatureGate.check_plugin(dir, manifest, %{}, [])
      assert {:untrusted, :mob_demo, fp, nil} = result
      assert fp == Crypto.fingerprint(pub)
    end

    test "untrusted reports key rotation when a different fingerprint is stored", %{
      dir: dir,
      manifest: manifest,
      pub: pub
    } do
      {_p2, pub2} = Crypto.generate_keypair()
      trust = %{mob_demo: Crypto.fingerprint(pub2)}

      result = SignatureGate.check_plugin(dir, manifest, trust, [])
      assert {:untrusted, :mob_demo, signed_fp, trusted_fp} = result
      assert signed_fp == Crypto.fingerprint(pub)
      assert trusted_fp == Crypto.fingerprint(pub2)
    end

    test "missing_signature when sig file is absent", %{dir: dir, manifest: manifest} do
      File.rm!(Sign.signature_path(dir))
      assert {:missing_signature, :mob_demo} = SignatureGate.check_plugin(dir, manifest, %{}, [])
    end

    test "missing_signature is suppressed by acknowledge list", %{dir: dir, manifest: manifest} do
      File.rm!(Sign.signature_path(dir))
      assert :ok = SignatureGate.check_plugin(dir, manifest, %{}, [:mob_demo])
    end

    test "invalid_signature when sources are tampered", %{
      dir: dir,
      manifest: _manifest,
      pub: pub
    } do
      File.write!(
        Path.join(dir, "priv/mob_plugin.exs"),
        inspect(%{name: :mob_evil, mob_version: "~> 0.6", plugin_spec_version: 1})
      )

      trust = %{mob_evil: Crypto.fingerprint(pub)}

      result =
        SignatureGate.check_plugin(
          dir,
          %{name: :mob_evil, mob_version: "~> 0.6", plugin_spec_version: 1},
          trust,
          []
        )

      assert {:invalid_signature, :mob_evil} = result
    end
  end

  describe "check_activated/3" do
    test "returns :ok when every plugin verifies + is trusted", %{
      dir: dir,
      manifest: manifest,
      pub: pub
    } do
      trust = %{mob_demo: Crypto.fingerprint(pub)}
      assert SignatureGate.check_activated([{dir, manifest}], trust, []) == :ok
    end

    test "reports errors per failing plugin", %{dir: dir, manifest: manifest} do
      assert {:error, [{:untrusted, :mob_demo, _, nil}]} =
               SignatureGate.check_activated([{dir, manifest}], %{}, [])
    end

    test "skips tier-0 plugins — no priv/mob_plugin.exs on disk means no signature required" do
      # A tier-0 plugin is one that never publishes a manifest file. After
      # MOB-74 the gate distinguishes tier-0 (nothing to verify) from a
      # tier-1 plugin whose sig failed (manifest present but eval refused)
      # by testing the presence of priv/mob_plugin.exs — not by
      # nil-manifest, which now also happens for failed-verification
      # plugins whose manifest bytes the gate must NOT skip.
      tier0_dir =
        Path.join(
          System.tmp_dir!(),
          "mob_sig_gate_tier0_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tier0_dir)
      on_exit(fn -> File.rm_rf!(tier0_dir) end)

      assert SignatureGate.check_activated([{tier0_dir, nil}], %{}, []) == :ok
    end

    test "surfaces a friendly error for a tier-1 plugin whose signature failed to verify",
         %{dir: dir} do
      # Regression guard for the MOB-74 tightening: after `activated/0` moved
      # to `Verify.load_verified/1`, a plugin that fails verification comes
      # back as `{dir, nil}`. If the gate were still using the old
      # `is_map(manifest)` filter, it would silently skip the plugin and
      # the build would proceed as if it were tier-0. Instead the gate
      # must detect that priv/mob_plugin.exs is on disk and produce a
      # named error.
      #
      # We simulate the failed-verification case by breaking the signature
      # file (any tamper works; we just need `Verify.verify_plugin/1` to
      # refuse).
      File.write!(Sign.signature_path(dir), "garbage")

      # With a nil manifest the gate can't read `manifest[:name]`, so it falls
      # back to the deps-directory basename — which matches the Hex package
      # name in real deployments (`deps/mob_demo`) but is the temp-dir
      # basename here. Assert the shape and reason; the name atom must exist
      # (i.e. it was derived from the dir, not left as nil).
      assert {:error, [{:invalid_signature, name}]} =
               SignatureGate.check_activated([{dir, nil}], %{}, [])

      assert is_atom(name) and not is_nil(name)
    end
  end
end

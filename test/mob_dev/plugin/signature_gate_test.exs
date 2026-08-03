defmodule MobDev.Plugin.SignatureGateTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Crypto, Sign, SignatureGate, Verify}

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

    {:ok, dir: dir, manifest: manifest, priv: priv, pub: pub}
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

    test "keeps trusted v1 plugins valid for checksum-pinned official plugin compatibility", %{
      dir: dir,
      manifest: manifest,
      priv: priv,
      pub: pub
    } do
      file_hashes = Sign.compute_file_hashes(dir, manifest, 1)
      payload = Sign.build_payload(manifest, file_hashes, 1)
      signature = Crypto.sign(payload, priv)

      File.write!(
        Sign.signature_path(dir),
        Crypto.canonical_encode(%{signature: signature, envelope_version: 1})
      )

      trust = %{mob_demo: Crypto.fingerprint(pub)}
      assert {:ok, 1} = Verify.verify_plugin_with_version(dir, manifest)
      assert SignatureGate.check_plugin(dir, manifest, trust, []) == :ok
      assert SignatureGate.check_activated([{dir, manifest}], trust, []) == :ok
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

    test "skips tier-0 (nil-manifest) plugins", %{dir: dir} do
      assert SignatureGate.check_activated([{dir, nil}], %{}, []) == :ok
    end
  end
end

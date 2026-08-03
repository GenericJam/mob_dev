defmodule MobDev.Plugin.VerifyTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Crypto, Manifest, Sign, Verify}

  # Frozen with the v1 signer at 06762494 (before Objective-C entered the hash
  # policy). This is deliberately not built through Sign helpers: successful
  # verification pins the exact historical ETF payload and legacy extension
  # policy independently of current code.
  @legacy_v1_pub Base.decode64!("A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
  @legacy_v1_envelope Base.decode64!(
                        "g3QAAAACdxBlbnZlbG9wZV92ZXJzaW9uYQF3CXNpZ25hdHVyZW0AAABAoje4i24j7SClsYsQ25r/DuzSv+GRxFWaiPZJANA1ajoV/JREZ9TpXeeSqq1oXTETl+19wWPvIy9N96/61k7cDg=="
                      )
  @legacy_v1_manifest %{
    name: :mob_legacy_fixture,
    mob_version: "~> 0.6",
    plugin_spec_version: 1,
    nifs: [
      %{module: :mob_legacy_fixture_nif, native_dir: "priv/native/ios", lang: :objc}
    ]
  }

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mob_verify_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "priv"))
    on_exit(fn -> File.rm_rf!(dir) end)

    manifest = %{
      name: :mob_demo,
      mob_version: "~> 0.6",
      plugin_spec_version: 1,
      ios: %{swift_files: ["ios/Demo.swift"]}
    }

    File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(manifest, limit: :infinity))

    swift_path = Path.join(dir, "ios/Demo.swift")
    File.mkdir_p!(Path.dirname(swift_path))
    File.write!(swift_path, "import Foundation\n")

    {priv, pub} = Crypto.generate_keypair()
    File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")
    :ok = Sign.sign_plugin(dir, priv)

    {:ok, dir: dir, manifest: manifest, pub: pub, priv: priv}
  end

  describe "load_signature/1" do
    test "keeps returning the raw 64-byte signature for callers that do not need the version", %{
      dir: dir
    } do
      assert {:ok, sig} = Verify.load_signature(dir)
      assert byte_size(sig) == 64
    end

    test "returns :missing when the sig file is absent", %{dir: dir} do
      File.rm!(Sign.signature_path(dir))
      assert {:error, :missing} = Verify.load_signature(dir)
    end

    test "returns :corrupt when the sig file has garbage", %{dir: dir} do
      File.write!(Sign.signature_path(dir), "garbage")
      assert {:error, :corrupt} = Verify.load_signature(dir)
    end

    # Regression: the envelope is decoded with binary_to_term(_, [:safe]), which
    # will not *create* atoms. The envelope contains :envelope_version, an atom
    # Verify must intern at load time (via @envelope_atoms) — otherwise, in any
    # BEAM where Sign (the only other interner) hadn't loaded yet, the :safe
    # decode raised and a *valid* signature was misreported as :corrupt. That
    # load-order dependence made the build signature gate intermittently reject
    # good plugins. The true cold-VM repro is cross-process (atoms can't be
    # un-interned in a live VM); these guard the fix's mechanism in-process.
    # See decisions/2026-05-31-verify-safe-atom-intern.md.
    test "interns the envelope atoms at module load (safe-decode guard)" do
      assert :signature in Verify.envelope_atoms()
      assert :envelope_version in Verify.envelope_atoms()
    end

    test "decodes an envelope whose term includes the :envelope_version key",
         %{dir: dir} do
      raw = File.read!(Sign.signature_path(dir))
      assert %{signature: _, envelope_version: 2} = :erlang.binary_to_term(raw, [:safe])
      assert {:ok, sig} = Verify.load_signature(dir)
      assert byte_size(sig) == 64
    end
  end

  describe "load_signature_with_version/1" do
    test "returns the bounded version alongside the raw signature", %{dir: dir} do
      assert {:ok, {2, sig}} = Verify.load_signature_with_version(dir)
      assert byte_size(sig) == 64
    end

    test "rejects an envelope with the version stripped", %{dir: dir, manifest: manifest} do
      %{signature: signature} = read_envelope!(dir)
      write_envelope!(dir, %{signature: signature})

      assert {:error, :corrupt} = Verify.load_signature_with_version(dir)
      assert {:error, :invalid_signature} = Verify.verify_plugin_with_version(dir, manifest)
    end

    test "rejects unknown and non-integer versions", %{dir: dir, manifest: manifest} do
      %{signature: signature} = read_envelope!(dir)

      for version <- [0, 3, -1, "2", 2.0, nil] do
        write_envelope!(dir, %{signature: signature, envelope_version: version})
        assert {:error, :corrupt} = Verify.load_signature_with_version(dir)

        assert {:error, :invalid_signature} =
                 Verify.verify_plugin_with_version(dir, manifest)
      end
    end

    test "rejects envelopes with extra keys", %{dir: dir, manifest: manifest} do
      envelope = Map.put(read_envelope!(dir), :manifest, %{})
      write_envelope!(dir, envelope)

      assert {:error, :corrupt} = Verify.load_signature_with_version(dir)
      assert {:error, :invalid_signature} = Verify.verify_plugin_with_version(dir, manifest)
    end

    test "rejects a bare 64-byte signature file", %{dir: dir, manifest: manifest} do
      %{signature: signature} = read_envelope!(dir)
      File.write!(Sign.signature_path(dir), signature)

      assert {:error, :corrupt} = Verify.load_signature_with_version(dir)
      assert {:error, :invalid_signature} = Verify.verify_plugin_with_version(dir, manifest)
    end

    test "rejects a compressed ETF encoding of an otherwise exact envelope", %{
      dir: dir,
      manifest: manifest
    } do
      envelope = %{read_envelope!(dir) | signature: :binary.copy(<<0>>, 64)}
      compressed = :erlang.term_to_binary(envelope, [:deterministic, compressed: 9])
      assert <<131, 80, _::binary>> = compressed
      File.write!(Sign.signature_path(dir), compressed)

      assert {:error, :corrupt} = Verify.load_signature_with_version(dir)
      assert {:error, :invalid_signature} = Verify.verify_plugin_with_version(dir, manifest)
    end

    test "rejects an oversized envelope after reading only the fixed bound plus one byte", %{
      dir: dir,
      manifest: manifest
    } do
      oversized = File.read!(Sign.signature_path(dir)) <> :binary.copy(<<0>>, 300)
      assert byte_size(oversized) > 256
      File.write!(Sign.signature_path(dir), oversized)

      assert {:error, :corrupt} = Verify.load_signature_with_version(dir)
      assert {:error, :invalid_signature} = Verify.verify_plugin_with_version(dir, manifest)
    end

    test "rejects malformed bounded envelopes without crashing", %{
      dir: dir,
      manifest: manifest
    } do
      raw = File.read!(Sign.signature_path(dir))
      %{signature: signature} = read_envelope!(dir)

      malformed_envelopes = [
        binary_part(raw, 0, byte_size(raw) - 1),
        raw <> "trailing bytes",
        Crypto.canonical_encode(%{signature: binary_part(signature, 0, 63), envelope_version: 2}),
        Crypto.canonical_encode(%{signature: signature <> <<0>>, envelope_version: 2})
      ]

      for malformed <- malformed_envelopes do
        File.write!(Sign.signature_path(dir), malformed)
        assert {:error, :corrupt} = Verify.load_signature_with_version(dir)

        assert {:error, :invalid_signature} =
                 Verify.verify_plugin_with_version(dir, manifest)
      end
    end
  end

  describe "load_pubkey/1" do
    test "loads the raw 32-byte public key", %{dir: dir} do
      assert {:ok, pub} = Verify.load_pubkey(dir)
      assert byte_size(pub) == 32
    end

    test "returns :missing when the pubkey file is absent", %{dir: dir} do
      File.rm!(Path.join(dir, "priv/mob_plugin.pub"))
      assert {:error, :missing} = Verify.load_pubkey(dir)
    end

    test "returns :malformed for non-base64 contents", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), "not base64!@#$\n")
      assert {:error, :malformed} = Verify.load_pubkey(dir)
    end

    test "returns :malformed when the decoded key is the wrong size", %{dir: dir} do
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(<<1, 2, 3>>) <> "\n")
      assert {:error, :malformed} = Verify.load_pubkey(dir)
    end
  end

  describe "verify_plugin/2" do
    test "accepts a freshly-signed plugin", %{dir: dir, manifest: manifest} do
      assert :ok = Verify.verify_plugin(dir, manifest)
      assert {:ok, 2} = Verify.verify_plugin_with_version(dir, manifest)
    end

    test "accepts a frozen shipped v1 envelope against only the exact legacy payload", %{
      dir: dir
    } do
      c_source = Path.join(dir, "priv/native/ios/demo.c")
      objc_source = Path.join(dir, "priv/native/ios/demo.m")
      File.mkdir_p!(Path.dirname(c_source))
      File.write!(c_source, "legacy signed c source\n")
      File.write!(objc_source, "legacy unsigned objective-c source\n")
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(@legacy_v1_pub) <> "\n")
      File.write!(Sign.signature_path(dir), @legacy_v1_envelope)

      assert {:ok, 1} = Verify.verify_plugin_with_version(dir, @legacy_v1_manifest)
      assert :ok = Verify.verify_plugin(dir, @legacy_v1_manifest)

      File.write!(objc_source, "changed objective-c source outside the frozen v1 payload")
      assert {:ok, 1} = Verify.verify_plugin_with_version(dir, @legacy_v1_manifest)

      File.write!(c_source, "tampered legacy signed c source")

      assert {:error, :invalid_signature} =
               Verify.verify_plugin_with_version(dir, @legacy_v1_manifest)
    end

    test "rejects changing a valid v2 envelope to v1 without resigning", %{
      dir: dir,
      manifest: manifest
    } do
      envelope = %{read_envelope!(dir) | envelope_version: 1}
      write_envelope!(dir, envelope)

      assert {:error, :invalid_signature} = Verify.verify_plugin_with_version(dir, manifest)
      assert {:error, :invalid_signature} = Verify.verify_plugin(dir, manifest)
    end

    test "rejects changing a valid v1 envelope to v2 without resigning", %{
      dir: dir,
      manifest: manifest,
      priv: priv
    } do
      write_v1_signature!(dir, manifest, priv)
      assert {:ok, 1} = Verify.verify_plugin_with_version(dir, manifest)

      envelope = %{read_envelope!(dir) | envelope_version: 2}
      write_envelope!(dir, envelope)

      assert {:error, :invalid_signature} = Verify.verify_plugin_with_version(dir, manifest)
    end

    test "rejects when a referenced source file is tampered", %{dir: dir, manifest: manifest} do
      File.write!(Path.join(dir, "ios/Demo.swift"), "import SwiftUI // EVIL\n")
      assert {:error, :invalid_signature} = Verify.verify_plugin(dir, manifest)
    end

    test "rejects when the manifest is altered after signing", %{dir: dir, manifest: manifest} do
      tampered = put_in(manifest, [:ios, :swift_files], ["ios/Other.swift"])
      assert {:error, :invalid_signature} = Verify.verify_plugin(dir, tampered)
    end

    test "rejects when the signature is missing", %{dir: dir, manifest: manifest} do
      File.rm!(Sign.signature_path(dir))
      assert {:error, :missing_signature} = Verify.verify_plugin(dir, manifest)
    end

    test "rejects when the pubkey is missing", %{dir: dir, manifest: manifest} do
      File.rm!(Path.join(dir, "priv/mob_plugin.pub"))
      assert {:error, :missing_pubkey} = Verify.verify_plugin(dir, manifest)
    end

    test "rejects when the pubkey doesn't match the signing key", %{dir: dir, manifest: manifest} do
      {_other_priv, other_pub} = Crypto.generate_keypair()
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(other_pub) <> "\n")
      assert {:error, :invalid_signature} = Verify.verify_plugin(dir, manifest)
    end

    test "round-trips against the manifest loaded back from disk", %{dir: dir} do
      {:ok, loaded} = Manifest.load(dir)
      assert :ok = Verify.verify_plugin(dir, loaded)
    end
  end

  defp write_v1_signature!(dir, manifest, priv) do
    file_hashes = Sign.compute_file_hashes(dir, manifest, 1)
    payload = Sign.build_payload(manifest, file_hashes, 1)
    signature = Crypto.sign(payload, priv)
    write_envelope!(dir, %{signature: signature, envelope_version: 1})
  end

  defp read_envelope!(dir) do
    dir
    |> Sign.signature_path()
    |> File.read!()
    |> :erlang.binary_to_term([:safe])
  end

  defp write_envelope!(dir, envelope) do
    File.write!(Sign.signature_path(dir), Crypto.canonical_encode(envelope))
  end
end

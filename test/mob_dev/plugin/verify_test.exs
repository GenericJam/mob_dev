defmodule MobDev.Plugin.VerifyTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Crypto, Manifest, Sign, Verify}

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

  describe "load_envelope/1" do
    test "loads the full v2 envelope with signature + file_hashes", %{dir: dir} do
      assert {:ok, envelope} = Verify.load_envelope(dir)
      assert byte_size(envelope.signature) == 64
      assert envelope.envelope_version == 2

      paths = Enum.map(envelope.file_hashes, &elem(&1, 0))
      assert "priv/mob_plugin.exs" in paths
      assert "ios/Demo.swift" in paths
    end

    test "returns :missing when the sig file is absent", %{dir: dir} do
      File.rm!(Sign.signature_path(dir))
      assert {:error, :missing} = Verify.load_envelope(dir)
    end

    test "returns :corrupt when the sig file has garbage", %{dir: dir} do
      File.write!(Sign.signature_path(dir), "garbage")
      assert {:error, :corrupt} = Verify.load_envelope(dir)
    end

    test "refuses a v1 envelope with :envelope_v1_unsupported so the caller can print a re-sign hint",
         %{dir: dir} do
      # A v1 envelope on disk carried only {signature, envelope_version: 1}.
      # v1 verification required the eval'd manifest to rebuild the payload,
      # which is the MOB-74 bug. Accepting v1 would silently reopen it.
      # Revert-verify: change the guard to also accept envelope_version: 1
      # and this fails.
      v1_bytes =
        Crypto.canonical_encode(%{
          signature: :binary.copy(<<0>>, 64),
          envelope_version: 1
        })

      File.write!(Sign.signature_path(dir), v1_bytes)
      assert {:error, :envelope_v1_unsupported} = Verify.load_envelope(dir)
    end

    # Regression: the envelope is decoded with binary_to_term(_, [:safe]), which
    # will not *create* atoms. The envelope contains :envelope_version and
    # :file_hashes, atoms Verify must intern at load time (via @envelope_atoms)
    # — otherwise, in any BEAM where Sign (the only other interner) hadn't
    # loaded yet, the :safe decode raised and a *valid* signature was
    # misreported as :corrupt. That load-order dependence made the build
    # signature gate intermittently reject good plugins. See
    # decisions/2026-05-31-verify-safe-atom-intern.md.
    test "interns the envelope atoms at module load (safe-decode guard)" do
      assert :signature in Verify.envelope_atoms()
      assert :envelope_version in Verify.envelope_atoms()
      assert :file_hashes in Verify.envelope_atoms()
    end
  end

  describe "load_signature/1 (back-compat shim)" do
    test "still returns the 64-byte signature from a v2 envelope", %{dir: dir} do
      assert {:ok, sig} = Verify.load_signature(dir)
      assert byte_size(sig) == 64
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

  describe "verify_plugin/1" do
    test "accepts a freshly-signed plugin without needing the eval'd manifest", %{dir: dir} do
      assert :ok = Verify.verify_plugin(dir)
    end

    test "rejects when a referenced source file is tampered", %{dir: dir} do
      File.write!(Path.join(dir, "ios/Demo.swift"), "import SwiftUI // EVIL\n")
      assert {:error, :invalid_signature} = Verify.verify_plugin(dir)
    end

    test "rejects when the manifest BYTES are tampered — the MOB-74 CVE class", %{dir: dir} do
      # Before MOB-74: the signature covered the eval'd manifest map, so a
      # tampered priv/mob_plugin.exs that eval'd to the same map (e.g. added
      # a side-effecting expression before the returning map literal) would
      # verify clean. Now the file bytes are in file_hashes; any change to
      # the .exs bytes shifts the hash and fails verification.
      #
      # Revert-verify: remove the @manifest_file prefix from
      # `Sign.referenced_files/2` and this fails (verification would pass
      # because the tampered map, if it eval'd to the same shape, wouldn't
      # be caught).
      original = File.read!(Path.join(dir, "priv/mob_plugin.exs"))
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), original <> "\n# tampered\n")
      assert {:error, :invalid_signature} = Verify.verify_plugin(dir)
    end

    test "rejects when the signature is missing", %{dir: dir} do
      File.rm!(Sign.signature_path(dir))
      assert {:error, :missing_signature} = Verify.verify_plugin(dir)
    end

    test "rejects when the pubkey is missing", %{dir: dir} do
      File.rm!(Path.join(dir, "priv/mob_plugin.pub"))
      assert {:error, :missing_pubkey} = Verify.verify_plugin(dir)
    end

    test "rejects when the pubkey doesn't match the signing key", %{dir: dir} do
      {_other_priv, other_pub} = Crypto.generate_keypair()
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(other_pub) <> "\n")
      assert {:error, :invalid_signature} = Verify.verify_plugin(dir)
    end

    test "rejects a v1 envelope with a distinguished error", %{dir: dir} do
      v1_bytes =
        Crypto.canonical_encode(%{
          signature: :binary.copy(<<0>>, 64),
          envelope_version: 1
        })

      File.write!(Sign.signature_path(dir), v1_bytes)
      assert {:error, :envelope_v1_unsupported} = Verify.verify_plugin(dir)
    end
  end

  describe "load_verified/1 — the safe consumer path (MOB-74)" do
    test "verifies the plugin first, then evals the manifest", %{dir: dir, manifest: manifest} do
      assert {:ok, loaded} = Verify.load_verified(dir)
      assert loaded[:name] == manifest.name
    end

    test "returns {:ok, nil} for a tier-0 plugin (no priv/mob_plugin.exs, no signature)" do
      dir = Path.join(System.tmp_dir!(), "mob_verify_tier0_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, nil} = Verify.load_verified(dir)
    end

    test "REFUSES to eval when verification fails — this is the MOB-74 fix", %{dir: dir} do
      # If a malicious plugin tampers with priv/mob_plugin.exs, load_verified
      # must refuse before Code.eval_file runs. Revert-verify: swap the
      # `verify_plugin/1` call in Verify.load_verified/1 for a bare
      # `Manifest.load/1` and this test still passes because the eval'd
      # manifest map returns fine — but the malicious side effects would
      # have already run. So we can't test "side effects didn't happen"
      # without a marker; the assertion here is the negative pre-condition
      # (error return, not {:ok, manifest}).
      original = File.read!(Path.join(dir, "priv/mob_plugin.exs"))
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), original <> "\n# tampered\n")

      assert {:error, :invalid_signature} = Verify.load_verified(dir)
    end

    test "refuses to eval a tampered manifest even if the side effect would run first",
         %{dir: dir} do
      # Stronger version: put a side-effect BEFORE the returning map. If
      # load_verified accidentally eval'd, the marker file would appear.
      # This directly guards the CVE class MOB-74 closes.
      marker = Path.join(dir, "SIDE_EFFECT_RAN")

      original_manifest = %{
        name: :mob_demo,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        ios: %{swift_files: ["ios/Demo.swift"]}
      }

      # The tampered manifest still evaluates to a valid-looking map, so if
      # verification had been re-ordered wrong (post-eval) or omitted, the
      # side effect would land.
      tampered = """
      File.write!(#{inspect(marker)}, "pwned")
      #{inspect(original_manifest, limit: :infinity)}
      """

      File.write!(Path.join(dir, "priv/mob_plugin.exs"), tampered)

      assert {:error, :invalid_signature} = Verify.load_verified(dir)
      refute File.exists?(marker), "Code.eval_file/1 ran despite invalid signature — MOB-74 open"
    end

    test "round-trips against the manifest loaded back from disk", %{dir: dir} do
      {:ok, loaded_direct} = Manifest.load(dir)
      {:ok, loaded_verified} = Verify.load_verified(dir)
      assert loaded_direct == loaded_verified
    end
  end
end

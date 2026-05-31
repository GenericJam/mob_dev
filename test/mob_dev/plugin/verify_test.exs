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

  describe "load_signature/1" do
    test "loads the raw 64-byte signature", %{dir: dir} do
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
      assert %{signature: _, envelope_version: 1} = :erlang.binary_to_term(raw, [:safe])
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

  describe "verify_plugin/2" do
    test "accepts a freshly-signed plugin", %{dir: dir, manifest: manifest} do
      assert :ok = Verify.verify_plugin(dir, manifest)
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
end

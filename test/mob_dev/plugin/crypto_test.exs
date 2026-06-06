defmodule MobDev.Plugin.CryptoTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Crypto

  describe "generate_keypair/0" do
    test "produces a 32-byte private key and 32-byte public key" do
      {priv, pub} = Crypto.generate_keypair()
      assert is_binary(priv) and byte_size(priv) == 32
      assert is_binary(pub) and byte_size(pub) == 32
    end

    test "produces distinct keypairs across calls" do
      {priv1, pub1} = Crypto.generate_keypair()
      {priv2, pub2} = Crypto.generate_keypair()
      assert priv1 != priv2
      assert pub1 != pub2
    end
  end

  describe "sign/2 + verify/3 round-trip" do
    test "verifies a signature against the original payload" do
      {priv, pub} = Crypto.generate_keypair()
      payload = %{manifest: %{name: :mob_demo}, file_hashes: [], envelope_version: 1}

      sig = Crypto.sign(payload, priv)
      assert byte_size(sig) == 64
      assert :ok = Crypto.verify(payload, sig, pub)
    end

    test "verifies regardless of map key insertion order" do
      {priv, pub} = Crypto.generate_keypair()
      a = %{manifest: %{a: 1, b: 2, c: 3}, file_hashes: [], envelope_version: 1}
      b = %{envelope_version: 1, file_hashes: [], manifest: %{c: 3, b: 2, a: 1}}

      sig = Crypto.sign(a, priv)
      assert :ok = Crypto.verify(b, sig, pub)
    end

    test "rejects a tampered payload" do
      {priv, pub} = Crypto.generate_keypair()
      payload = %{manifest: %{name: :mob_demo}, file_hashes: [], envelope_version: 1}
      tampered = %{manifest: %{name: :mob_evil}, file_hashes: [], envelope_version: 1}

      sig = Crypto.sign(payload, priv)
      assert {:error, :invalid_signature} = Crypto.verify(tampered, sig, pub)
    end

    test "rejects a signature signed by a different key" do
      {priv1, _pub1} = Crypto.generate_keypair()
      {_priv2, pub2} = Crypto.generate_keypair()
      payload = %{manifest: %{name: :x}, file_hashes: [], envelope_version: 1}

      sig = Crypto.sign(payload, priv1)
      assert {:error, :invalid_signature} = Crypto.verify(payload, sig, pub2)
    end

    test "returns :invalid_signature (not a crash) for wrong-size key/sig" do
      # :crypto.verify/5 raises :badarg from OpenSSL on an ill-sized key.
      # These bytes come from attacker-controlled plugin files, so the
      # documented contract must hold: return the error tuple, never raise.
      {_priv, pub} = Crypto.generate_keypair()
      payload = %{manifest: %{name: :x}, file_hashes: [], envelope_version: 1}
      good_sig = :binary.copy(<<0>>, 64)

      assert {:error, :invalid_signature} = Crypto.verify(payload, good_sig, "")

      assert {:error, :invalid_signature} =
               Crypto.verify(payload, good_sig, :binary.copy(<<0>>, 10))

      assert {:error, :invalid_signature} = Crypto.verify(payload, "", pub)

      assert {:error, :invalid_signature} =
               Crypto.verify(payload, :binary.copy(<<0>>, 10), pub)
    end
  end

  describe "fingerprint/1" do
    test "is deterministic for a given public key" do
      {_priv, pub} = Crypto.generate_keypair()
      assert Crypto.fingerprint(pub) == Crypto.fingerprint(pub)
    end

    test "differs for distinct keys" do
      {_p1, pub1} = Crypto.generate_keypair()
      {_p2, pub2} = Crypto.generate_keypair()
      assert Crypto.fingerprint(pub1) != Crypto.fingerprint(pub2)
    end

    test "is shaped as `ed25519:<base64>`" do
      {_priv, pub} = Crypto.generate_keypair()
      assert "ed25519:" <> base64 = Crypto.fingerprint(pub)
      assert {:ok, digest} = Base.decode64(base64)
      assert byte_size(digest) == 32
    end
  end

  describe "canonical_encode/1" do
    test "produces the same bytes for equal terms with different map orders" do
      a = %{a: 1, b: 2, c: 3}
      b = %{c: 3, b: 2, a: 1}
      assert Crypto.canonical_encode(a) == Crypto.canonical_encode(b)
    end
  end
end

defmodule MobDev.Plugin.Crypto do
  @moduledoc """
  Ed25519 sign/verify primitives + canonical-term encoding for plugin signing.

  The signing scheme (see `MOB_PLUGIN_SECURITY.md`, Phase 2):

  - Plugin authors generate a per-plugin Ed25519 keypair; the public key
    ships in `priv/mob_plugin.pub` and the manifest+sources are signed
    with the private key into `priv/mob_plugin.sig`.
  - Hosts verify the signature against the public key at activation time
    and refuse to build untrusted/unsigned plugins.

  This module is the single place the Ed25519 + canonical-encoding
  decisions are encoded. Keep it crypto-only — workflow (sign/verify
  orchestration, fingerprint storage) lives in `Sign`, `Verify`, and
  `TrustStore`.
  """

  @typedoc "Raw 32-byte Ed25519 private key."
  @type priv_key :: <<_::256>>

  @typedoc "Raw 32-byte Ed25519 public key."
  @type pub_key :: <<_::256>>

  @typedoc "Raw 64-byte Ed25519 signature."
  @type signature :: <<_::512>>

  @typedoc "Host-visible trust identifier; base64-encoded SHA-256 of the public key."
  @type fingerprint :: String.t()

  @doc """
  Generates a fresh Ed25519 keypair.

  Returns `{priv_bin, pub_bin}` as raw 32-byte binaries. The format
  matches what `:crypto.sign/4` and `:crypto.verify/5` accept directly
  with the `:eddsa`/`:ed25519` options.
  """
  @spec generate_keypair() :: {priv_key(), pub_key()}
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {priv, pub}
  end

  @doc """
  Signs `payload_term` with `priv_bin`.

  The term is canonically encoded via `canonical_encode/1` before signing,
  so the signature is over the deterministic binary form — the same map
  with the same contents produces the same signature regardless of map
  insertion order.
  """
  @spec sign(term(), priv_key()) :: signature()
  def sign(payload_term, priv_bin) when is_binary(priv_bin) do
    payload = canonical_encode(payload_term)
    :crypto.sign(:eddsa, :sha512, payload, [priv_bin, :ed25519])
  end

  @doc """
  Verifies `signature_bin` against `payload_term` and `pub_bin`.

  Returns `:ok` on valid signature, `{:error, :invalid_signature}`
  otherwise. Mirrors `sign/2` — the same canonical encoding is applied
  before verifying.

  A wrong-*size* signature or public key (not a 64-byte sig / 32-byte
  Ed25519 key) is treated as an invalid signature rather than crashing:
  `:crypto.verify/5` raises `:badarg` from OpenSSL when handed an
  ill-sized key, and these bytes originate from attacker-controlled
  plugin files (`priv/mob_plugin.sig` / `priv/mob_plugin.pub`). The
  documented contract (`:ok | {:error, :invalid_signature}`) must hold
  for every binary input, so the raise is caught here.
  """
  @spec verify(term(), signature(), pub_key()) :: :ok | {:error, :invalid_signature}
  def verify(payload_term, signature_bin, pub_bin)
      when is_binary(signature_bin) and is_binary(pub_bin) do
    payload = canonical_encode(payload_term)

    if :crypto.verify(:eddsa, :sha512, payload, signature_bin, [pub_bin, :ed25519]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  rescue
    ArgumentError -> {:error, :invalid_signature}
    ErlangError -> {:error, :invalid_signature}
  end

  @doc """
  Computes the host-visible trust identifier for a public key.

  Format: `"ed25519:<base64>"` where `<base64>` is the standard base64
  encoding (with `=` padding) of the SHA-256 digest of the raw 32-byte
  public key. Suitable for storing in `mob.exs` under
  `:trusted_plugins` and for comparing two keys for equality without
  printing the key itself.
  """
  @spec fingerprint(pub_key()) :: fingerprint()
  def fingerprint(pub_bin) when is_binary(pub_bin) do
    digest = :crypto.hash(:sha256, pub_bin)
    "ed25519:" <> Base.encode64(digest)
  end

  @doc """
  Canonical encoding of an arbitrary Erlang term to a binary.

  Uses `:erlang.term_to_binary/2` with `:deterministic` so the same logical
  value produces the same bytes regardless of map iteration order.
  Centralised here so the determinism flag is in one place: `sign/2`,
  `verify/3`, and any future hash-of-payload helper all agree.
  """
  @spec canonical_encode(term()) :: binary()
  def canonical_encode(term) do
    :erlang.term_to_binary(term, [:deterministic, minor_version: 2])
  end
end

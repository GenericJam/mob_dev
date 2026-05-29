defmodule MobDev.Plugin.Verify do
  @moduledoc """
  Host-side signature verification for activated mob plugins.

  Given a plugin directory + its loaded manifest, this module:

  1. Loads `priv/mob_plugin.sig` (the signed envelope).
  2. Loads `priv/mob_plugin.pub` (the plugin author's public key).
  3. Recomputes the file-hash list via `Sign.compute_file_hashes/2`.
  4. Reconstructs the canonical payload and runs `Crypto.verify/3`.

  Failure modes are distinguished:

  - `:missing_signature` — no `priv/mob_plugin.sig`.
  - `:missing_pubkey` — no `priv/mob_plugin.pub`.
  - `:invalid_signature` — sig file present but the signature doesn't
    verify against the canonical payload reconstructed from disk. This
    is the failure mode for both manifest tampering and source-file
    tampering: the recomputed `file_hashes` no longer match what was
    signed, so the payload differs and the signature check fails.

  Trust (mapping a verified public key to "the host operator approved
  it") lives in `TrustStore` and is layered on top of this module.
  """

  alias MobDev.Plugin.{Crypto, Sign}

  @signature_file "priv/mob_plugin.sig"
  @pubkey_file "priv/mob_plugin.pub"

  @typedoc "Errors `load_signature/1` can return."
  @type sig_error :: :missing | :corrupt

  @typedoc "Errors `load_pubkey/1` can return."
  @type pubkey_error :: :missing | :malformed

  @typedoc "Errors `verify_plugin/2` can return."
  @type verify_error :: :missing_signature | :missing_pubkey | :invalid_signature

  @doc """
  Loads the raw 64-byte signature from `priv/mob_plugin.sig`.

  The file is the `Crypto.canonical_encode/1` of an envelope map
  (`%{signature: <64-byte sig>, envelope_version: 1}`); this function
  decodes the envelope and returns the inner signature binary.
  """
  @spec load_signature(Path.t()) :: {:ok, Crypto.signature()} | {:error, sig_error()}
  def load_signature(plugin_dir) do
    path = Path.join(plugin_dir, @signature_file)

    case File.read(path) do
      {:ok, bytes} -> decode_signature_envelope(bytes)
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :corrupt}
    end
  end

  defp decode_signature_envelope(bytes) do
    {:ok, decode_envelope_term!(bytes)}
  rescue
    _ -> {:error, :corrupt}
  end

  defp decode_envelope_term!(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      %{signature: sig} when is_binary(sig) and byte_size(sig) == 64 -> sig
      _ -> raise "corrupt"
    end
  end

  @doc """
  Loads the raw 32-byte public key from `priv/mob_plugin.pub`.

  Format: a single line of base64 (with `=` padding) of the raw 32-byte
  Ed25519 public key, optionally followed by a trailing newline. Plain
  text so plugin authors can `cat` it or paste it into a release note.
  """
  @spec load_pubkey(Path.t()) :: {:ok, Crypto.pub_key()} | {:error, pubkey_error()}
  def load_pubkey(plugin_dir) do
    path = Path.join(plugin_dir, @pubkey_file)

    case File.read(path) do
      {:ok, contents} -> decode_pubkey(contents)
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp decode_pubkey(contents) do
    trimmed = String.trim(contents)

    case Base.decode64(trimmed) do
      {:ok, pub} when byte_size(pub) == 32 -> {:ok, pub}
      _ -> {:error, :malformed}
    end
  end

  @doc """
  Verifies that the plugin in `plugin_dir` has a valid signature for the
  given `manifest` + the current file contents on disk.

  Returns `:ok` on success or one of the distinguished error reasons
  (see `t:verify_error/0`). The caller is responsible for any trust
  decision; this function only proves that the bytes on disk match
  what the plugin author signed.
  """
  @spec verify_plugin(Path.t(), map() | nil) :: :ok | {:error, verify_error()}
  def verify_plugin(plugin_dir, manifest) do
    with {:ok, signature} <- need(load_signature(plugin_dir), :missing_signature),
         {:ok, pub} <- need(load_pubkey(plugin_dir), :missing_pubkey),
         file_hashes = Sign.compute_file_hashes(plugin_dir, manifest),
         payload = Sign.build_payload(manifest, file_hashes),
         :ok <- normalise_verify(Crypto.verify(payload, signature, pub)) do
      :ok
    end
  end

  # Both load_signature and load_pubkey return :missing for a missing file;
  # other errors (:corrupt, :malformed) collapse into :invalid_signature
  # because they all mean "the bytes that should certify this plugin are
  # not usable".
  defp need({:ok, value}, _missing_reason), do: {:ok, value}
  defp need({:error, :missing}, missing_reason), do: {:error, missing_reason}
  defp need({:error, _}, _missing_reason), do: {:error, :invalid_signature}

  defp normalise_verify(:ok), do: :ok
  defp normalise_verify({:error, :invalid_signature}), do: {:error, :invalid_signature}
end

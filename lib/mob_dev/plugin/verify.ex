defmodule MobDev.Plugin.Verify do
  @moduledoc """
  Host-side signature verification for activated mob plugins.

  Given a plugin directory + its loaded manifest, this module:

  1. Loads `priv/mob_plugin.sig` and validates its exact versioned envelope.
  2. Loads `priv/mob_plugin.pub` (the plugin author's public key).
  3. Recomputes the file-hash list using the policy bound to that version.
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
  @supported_signature_versions [1, 2]
  @max_signature_envelope_bytes 256

  # Atom keys that appear in the signed envelope term (see `Sign.sign_plugin/2`).
  # `load_signature/1` decodes the envelope with `binary_to_term(_, [:safe])`,
  # which refuses to *create* atoms — every atom in the encoded term must
  # already exist in the runtime atom table or the decode raises `badarg` and a
  # valid signature is misreported as `:corrupt`. Naming the atoms in this
  # module-level literal interns them at `Verify`-load (guaranteed before any
  # decode), making the decode deterministic while keeping `:safe` (sig files
  # are attacker-controlled). See
  # decisions/2026-05-31-verify-safe-atom-intern.md.
  @envelope_atoms [:signature, :envelope_version]

  @typedoc "Errors `load_signature/1` can return."
  @type sig_error :: :missing | :corrupt

  @typedoc "A supported signature version; only the verify API authenticates it."
  @type signature_version :: 1 | 2

  @typedoc "The decoded version and raw Ed25519 signature."
  @type versioned_signature :: {signature_version(), Crypto.signature()}

  @typedoc "Errors `load_pubkey/1` can return."
  @type pubkey_error :: :missing | :malformed

  @typedoc "Errors `verify_plugin/2` can return."
  @type verify_error :: :missing_signature | :missing_pubkey | :invalid_signature

  @doc """
  Loads the raw 64-byte signature from `priv/mob_plugin.sig`.

  This compatibility API validates the exact versioned envelope and then
  discards the version. Call `load_signature_with_version/1` when the caller
  needs the decoded version, or `verify_plugin_with_version/2` when it needs a
  version that has also passed cryptographic verification.
  """
  @spec load_signature(Path.t()) :: {:ok, Crypto.signature()} | {:error, sig_error()}
  def load_signature(plugin_dir) do
    case load_signature_with_version(plugin_dir) do
      {:ok, {_version, signature}} -> {:ok, signature}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads and validates the exact two-key signature envelope.

  Returns `{version, raw_signature}` only for supported integer versions 1 and
  2 in the canonical uncompressed ETF map encoding. Missing, unknown,
  non-integer, stripped, extra-key, compressed, oversized, and bare signature
  forms fail closed as `:corrupt`.
  """
  @spec load_signature_with_version(Path.t()) ::
          {:ok, versioned_signature()} | {:error, sig_error()}
  def load_signature_with_version(plugin_dir) do
    path = Path.join(plugin_dir, @signature_file)

    case read_signature_envelope(path) do
      {:ok, bytes} -> decode_signature_envelope(bytes)
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :corrupt}
    end
  end

  defp read_signature_envelope(path) do
    case File.open(path, [:read, :binary], fn io ->
           IO.binread(io, @max_signature_envelope_bytes + 1)
         end) do
      {:ok, bytes}
      when is_binary(bytes) and byte_size(bytes) <= @max_signature_envelope_bytes ->
        {:ok, bytes}

      {:ok, _oversized_or_unreadable} ->
        {:error, :corrupt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_signature_envelope(<<131, 116, _::binary>> = bytes)
       when byte_size(bytes) <= @max_signature_envelope_bytes do
    # Touch the literal so the envelope atoms are guaranteed interned before the
    # :safe decode runs (see @envelope_atoms above).
    _ = @envelope_atoms

    case :erlang.binary_to_term(bytes, [:safe, :used]) do
      {%{signature: signature, envelope_version: version} = envelope, bytes_used}
      when bytes_used == byte_size(bytes) and map_size(envelope) == 2 and
             is_binary(signature) and byte_size(signature) == 64 and
             version in @supported_signature_versions ->
        {:ok, {version, signature}}

      _ ->
        {:error, :corrupt}
    end
  rescue
    ArgumentError -> {:error, :corrupt}
    ErlangError -> {:error, :corrupt}
  end

  defp decode_signature_envelope(_bytes), do: {:error, :corrupt}

  @doc false
  # Atoms the signed envelope can contain; exposed so the interning guarantee is
  # regression-testable (see verify_test.exs).
  @spec envelope_atoms() :: [atom()]
  def envelope_atoms, do: @envelope_atoms

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
    case verify_plugin_with_version(plugin_dir, manifest) do
      {:ok, _version} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies a plugin and returns the signature version only after the signature
  succeeds against that version's single payload and file-hash policy.

  Version 1 reconstructs the frozen legacy payload, which excludes Objective-C
  `.m` and `.mm` files from `native_dir`. Version 2 includes them. Verification
  never falls back between policies, so changing an envelope version without
  resigning fails cryptographically.
  """
  @spec verify_plugin_with_version(Path.t(), map() | nil) ::
          {:ok, signature_version()} | {:error, verify_error()}
  def verify_plugin_with_version(plugin_dir, manifest) do
    with {:ok, {version, signature}} <-
           need(load_signature_with_version(plugin_dir), :missing_signature),
         {:ok, pub} <- need(load_pubkey(plugin_dir), :missing_pubkey),
         file_hashes = Sign.compute_file_hashes(plugin_dir, manifest, version),
         payload = Sign.build_payload(manifest, file_hashes, version),
         :ok <- normalise_verify(Crypto.verify(payload, signature, pub)) do
      {:ok, version}
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

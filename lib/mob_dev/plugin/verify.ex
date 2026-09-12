defmodule MobDev.Plugin.Verify do
  @moduledoc """
  Host-side signature verification for activated mob plugins.

  Given a plugin directory, this module:

  1. Loads `priv/mob_plugin.sig` (the signed envelope).
  2. Loads `priv/mob_plugin.pub` (the plugin author's public key).
  3. Rebuilds the canonical payload from the envelope's embedded
     `file_hashes` list and runs `Crypto.verify/3` — proving the
     envelope on disk came from the author.
  4. Re-hashes each file the envelope declares and compares against the
     signed hash — proving the on-disk state has not been tampered with
     since the author signed it.

  Because the envelope carries `file_hashes` on disk (v2, see
  `Sign` moduledoc for the version history), verification does not
  require the eval'd manifest map — so the safe order is
  **verify → then eval**. This closes the MOB-74 class of bug where a
  malicious `priv/mob_plugin.exs` could execute arbitrary code during
  plugin activation because the eval ran before the signature check.

  Failure modes are distinguished:

  - `:missing_signature` — no `priv/mob_plugin.sig`.
  - `:missing_pubkey` — no `priv/mob_plugin.pub`.
  - `:invalid_signature` — sig present but doesn't verify, or on-disk
    files no longer match the signed hashes (tamper detected), or the
    envelope is malformed.
  - `:envelope_v1_unsupported` — a legacy v1 envelope was found. v1
    verification required the eval'd manifest to rebuild the payload,
    which is the very bug we are closing. Author must re-sign with
    `mix mob.plugin.sign` on mob_dev 0.7.2 or later.

  Trust (mapping a verified public key to "the host operator approved
  it") lives in `TrustStore` and is layered on top of this module.
  """

  alias MobDev.Plugin.{Crypto, Manifest, Sign}

  @signature_file "priv/mob_plugin.sig"
  @pubkey_file "priv/mob_plugin.pub"

  # Atom keys that appear in the v2 signed envelope term (see
  # `Sign.sign_plugin/2`). `load_envelope/1` decodes the envelope with
  # `binary_to_term(_, [:safe])`, which refuses to *create* atoms — every atom
  # in the encoded term must already exist in the runtime atom table or the
  # decode raises `badarg` and a valid signature is misreported as `:corrupt`.
  # Naming the atoms in this module-level literal interns them at `Verify`-load
  # (guaranteed before any decode), making the decode deterministic while
  # keeping `:safe` (sig files are attacker-controlled). See
  # decisions/2026-05-31-verify-safe-atom-intern.md.
  @envelope_atoms [:signature, :envelope_version, :file_hashes]

  @typedoc "Errors `load_envelope/1` can return."
  @type envelope_error :: :missing | :corrupt | :envelope_v1_unsupported

  @typedoc "Errors `load_pubkey/1` can return."
  @type pubkey_error :: :missing | :malformed

  @typedoc "Errors `verify_plugin/1` can return."
  @type verify_error ::
          :missing_signature
          | :missing_pubkey
          | :invalid_signature
          | :envelope_v1_unsupported

  @typedoc "A decoded v2 envelope."
  @type envelope :: %{
          signature: Crypto.signature(),
          file_hashes: Sign.file_hashes(),
          envelope_version: 2
        }

  @doc """
  Loads and decodes the signature envelope from `priv/mob_plugin.sig`.

  Returns the full envelope map (v2 shape) on success, or a distinguished
  error. A v1 envelope on disk is reported as `:envelope_v1_unsupported` so
  the caller can print a re-sign hint — v1 required the eval'd manifest to
  verify, which is the bug MOB-74 closes.
  """
  @spec load_envelope(Path.t()) :: {:ok, envelope()} | {:error, envelope_error()}
  def load_envelope(plugin_dir) do
    path = Path.join(plugin_dir, @signature_file)

    case File.read(path) do
      {:ok, bytes} -> decode_envelope(bytes)
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :corrupt}
    end
  end

  defp decode_envelope(bytes) do
    # Touch the literal so the envelope atoms are guaranteed interned before the
    # :safe decode runs (see @envelope_atoms above).
    _ = @envelope_atoms

    case :erlang.binary_to_term(bytes, [:safe]) do
      %{signature: sig, file_hashes: fh, envelope_version: 2}
      when is_binary(sig) and byte_size(sig) == 64 and is_list(fh) ->
        {:ok, %{signature: sig, file_hashes: fh, envelope_version: 2}}

      %{signature: sig, envelope_version: 1} when is_binary(sig) and byte_size(sig) == 64 ->
        {:error, :envelope_v1_unsupported}

      _ ->
        {:error, :corrupt}
    end
  rescue
    _ -> {:error, :corrupt}
  end

  @doc """
  Back-compat shim for `mob 0.8.x` and the `SignatureGate.maybe_print_unsafe_banner/1`
  path, both of which used the v1 helper that returned just the raw
  signature. Now returns the same 64-byte signature but extracted from a v2
  envelope. Callers that need the full envelope should use `load_envelope/1`.
  """
  @spec load_signature(Path.t()) :: {:ok, Crypto.signature()} | {:error, envelope_error()}
  def load_signature(plugin_dir) do
    case load_envelope(plugin_dir) do
      {:ok, %{signature: sig}} -> {:ok, sig}
      {:error, r} -> {:error, r}
    end
  end

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
  Verifies that the plugin in `plugin_dir` has a valid v2 signature and
  that the on-disk files match what the author signed.

  The check runs entirely off the envelope's embedded `file_hashes` list
  — the manifest is one of those files, and rehashing its bytes on disk
  detects tampering without any `Code.eval_file` call. That is the
  MOB-74 fix: verification is now safe to run *before* eval, closing the
  RCE window where a malicious `priv/mob_plugin.exs` could execute
  arbitrary code during plugin activation.

  Returns `:ok` on success or one of the distinguished error reasons
  (see `t:verify_error/0`). The caller is responsible for any trust
  decision; this function only proves that the bytes on disk match
  what the plugin author signed.
  """
  @spec verify_plugin(Path.t()) :: :ok | {:error, verify_error()}
  def verify_plugin(plugin_dir) do
    with {:ok, envelope} <- normalise_envelope_error(load_envelope(plugin_dir)),
         {:ok, pub} <- normalise_pubkey_error(load_pubkey(plugin_dir)),
         :ok <- check_files_match(plugin_dir, envelope.file_hashes),
         payload = Sign.build_payload(envelope.file_hashes),
         :ok <- normalise_verify(Crypto.verify(payload, envelope.signature, pub)) do
      :ok
    end
  end

  @doc """
  Verifies the plugin, then loads and evaluates the manifest.

  This is the safe consumer-side path: if `verify_plugin/1` refuses,
  `Manifest.load/1` is never called and `Code.eval_file/1` on the
  potentially-malicious `priv/mob_plugin.exs` never runs.

  For plugins with no `priv/mob_plugin.exs` at all (tier-0 plugins),
  returns `{:ok, nil}` without requiring a signature.
  """
  @spec load_verified(Path.t()) :: {:ok, map() | nil} | {:error, verify_error() | String.t()}
  def load_verified(plugin_dir) do
    case Manifest.manifest_present?(plugin_dir) do
      false ->
        {:ok, nil}

      true ->
        case verify_plugin(plugin_dir) do
          :ok -> Manifest.load(plugin_dir)
          {:error, _} = err -> err
        end
    end
  end

  # Rehash each declared file on disk and compare against the signed hash.
  # A single mismatch (or missing file) collapses to :invalid_signature —
  # the tamper check and the signature check share the same error surface
  # because either failure means "the bytes that should certify this plugin
  # are not what's on disk right now".
  defp check_files_match(plugin_dir, expected_hashes) do
    mismatch =
      Enum.find(expected_hashes, fn {rel, expected} ->
        actual = Sign.sha256!(Path.join(plugin_dir, rel))
        actual != expected
      end)

    if mismatch, do: {:error, :invalid_signature}, else: :ok
  end

  # Envelope errors that mean "no sig file at all" map to :missing_signature.
  # A v1 envelope propagates as its own distinct error so the caller can print
  # an actionable re-sign message. Everything else (corrupt, malformed)
  # collapses to :invalid_signature.
  defp normalise_envelope_error({:ok, envelope}), do: {:ok, envelope}
  defp normalise_envelope_error({:error, :missing}), do: {:error, :missing_signature}

  defp normalise_envelope_error({:error, :envelope_v1_unsupported}),
    do: {:error, :envelope_v1_unsupported}

  defp normalise_envelope_error({:error, _}), do: {:error, :invalid_signature}

  # Pubkey errors: :missing bubbles as :missing_pubkey; malformed → invalid_signature
  # because a garbage .pub file is functionally as bad as a bad signature.
  defp normalise_pubkey_error({:ok, pub}), do: {:ok, pub}
  defp normalise_pubkey_error({:error, :missing}), do: {:error, :missing_pubkey}
  defp normalise_pubkey_error({:error, _}), do: {:error, :invalid_signature}

  defp normalise_verify(:ok), do: :ok
  defp normalise_verify({:error, :invalid_signature}), do: {:error, :invalid_signature}
end

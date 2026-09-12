defmodule MobDev.Plugin.Sign do
  @moduledoc """
  Author-side signing workflow for mob plugins.

  Produces `priv/mob_plugin.sig` for a plugin directory by:

  1. Loading the manifest (`priv/mob_plugin.exs`).
  2. Computing SHA-256 hashes for every file the manifest references
     (Swift sources, Android bridge/JNI sources, NIF native_dir contents,
     **and the manifest bytes themselves**).
  3. Building the canonical payload (sorted file hashes + envelope
     version).
  4. Signing the canonical encoding of the payload via `Crypto.sign/2`.
  5. Writing a binary `priv/mob_plugin.sig` containing the signature
     **and the signed file_hashes list**, so verifiers can check
     integrity without needing to `Code.eval_file` the manifest first
     (see MOB-74).

  Pure helpers are exposed for tests: `compute_file_hashes/2` and
  `build_payload/1` are deterministic given their inputs.

  ## Envelope versions

  - **v1** (deprecated, MOB-74) — payload was `%{manifest: <map>,
    file_hashes: [...]}` and the envelope on disk carried only the
    signature. Verifiers needed the eval'd manifest map to rebuild the
    payload, so the eval had to run *before* verification could —
    letting a malicious `priv/mob_plugin.exs` execute arbitrary code
    at build time. Refused by `MobDev.Plugin.Verify` since mob_dev
    0.7.2.
  - **v2** (current) — payload is `%{file_hashes: [...],
    envelope_version: 2}`; `file_hashes` includes
    `priv/mob_plugin.exs`; envelope on disk embeds `file_hashes`
    alongside the signature. Verifiers can check every on-disk file
    against the signed hashes without touching the manifest map, so
    verification is safe to run before eval.
  """

  alias MobDev.Plugin.{Crypto, Manifest}

  @envelope_version 2

  @signature_file "priv/mob_plugin.sig"
  @manifest_file "priv/mob_plugin.exs"

  # File extensions to include when a manifest entry points at a
  # `:native_dir` (NIF C/C++/Zig sources + headers). The set is fixed
  # because the build pipeline only ever compiles these extensions.
  @nif_extensions [".c", ".h", ".cpp", ".zig"]

  @typedoc "Relative path inside the plugin directory."
  @type rel_path :: String.t()

  @typedoc "SHA-256 digest of a single file (raw 32-byte binary)."
  @type file_hash :: binary()

  @typedoc "Sorted list of `{relative_path, sha256}` tuples."
  @type file_hashes :: [{rel_path(), file_hash()}]

  @doc """
  Returns the relative-path-sorted list of `{relative_path, sha256}`
  tuples for every file the manifest references.

  Pure given the plugin dir + manifest. The set covers:

  - `manifest.ios.swift_files` — single files (list of paths).
  - `manifest.android.bridge_kt` and `manifest.android.jni_source` —
    single paths each.
  - `manifest.android.res_files` — the resource files copied verbatim
    into the app `res/` tree (list of paths).
  - `manifest.nifs[].native_dir` — recursive over `.c`, `.h`, `.cpp`,
    `.zig` files inside. This is the only case where a directory is
    expanded.

  Other manifest fields are either name-only (component atoms,
  `swift_struct`) or pure data (plist keys, permission strings,
  framework names) and are covered by the manifest term itself being
  part of the signed payload.

  Missing files are skipped silently — `Validator.validate_plugin/3`
  is responsible for refusing to publish a plugin with missing
  declared paths, so the signing surface assumes paths that exist.
  """
  @spec compute_file_hashes(Path.t(), map() | nil) :: file_hashes()
  def compute_file_hashes(_plugin_dir, nil), do: []

  def compute_file_hashes(plugin_dir, manifest) when is_map(manifest) do
    manifest
    |> referenced_files(plugin_dir)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn rel -> {rel, sha256!(Path.join(plugin_dir, rel))} end)
  end

  @doc """
  Builds the canonical payload term that gets signed.

  Shape:

      %{
        file_hashes: [{rel_path, sha256}, ...],
        envelope_version: 2
      }

  Authoritative for what's inside the signature — any new field added
  here needs both author and host updates.

  Note that the payload no longer includes the manifest term itself
  (see MOB-74). The manifest is one of the files hashed in
  `file_hashes`, so its bytes are covered — and dropping the map from
  the payload lets `Verify` recompute the payload without eval'ing
  the manifest first.
  """
  @spec build_payload(file_hashes()) :: map()
  def build_payload(file_hashes) do
    %{
      file_hashes: file_hashes,
      envelope_version: @envelope_version
    }
  end

  # CAVEAT — atom keys in the signed terms (this payload + the sig envelope in
  # `sign_plugin/2`) must also appear in `MobDev.Plugin.Verify`'s
  # `@envelope_atoms`. Verify decodes the .sig with binary_to_term(_, [:safe]),
  # which won't *create* atoms — any atom key it hasn't interned at load time
  # makes a valid signature decode as :corrupt, intermittently (depends on what
  # else loaded first). Adding a key here without updating @envelope_atoms
  # reintroduces that bug. See decisions/2026-05-31-verify-safe-atom-intern.md.

  @doc """
  Signs `plugin_dir` and writes `priv/mob_plugin.sig`.

  Orchestrates the full author workflow: loads the manifest (to know
  which files it references), computes file hashes (including the
  manifest bytes themselves), builds the v2 payload, signs it, wraps
  the signature **and the file_hashes list** in the envelope binary,
  and writes the file. Returns `:ok` on success or `{:error, reason}`
  if the manifest is missing/invalid.

  The envelope carries `file_hashes` on disk so `Verify.verify_plugin/1`
  can check tampering without needing to `Code.eval_file` the manifest
  first — see MOB-74.
  """
  @spec sign_plugin(Path.t(), Crypto.priv_key()) :: :ok | {:error, term()}
  def sign_plugin(plugin_dir, priv_key) when is_binary(priv_key) do
    with {:ok, manifest} <- Manifest.load(plugin_dir),
         :ok <- refuse_if_no_manifest(manifest, plugin_dir) do
      file_hashes = compute_file_hashes(plugin_dir, manifest)
      payload = build_payload(file_hashes)
      signature = Crypto.sign(payload, priv_key)

      envelope = %{
        signature: signature,
        file_hashes: file_hashes,
        envelope_version: @envelope_version
      }

      sig_path = Path.join(plugin_dir, @signature_file)
      File.mkdir_p!(Path.dirname(sig_path))
      File.write!(sig_path, Crypto.canonical_encode(envelope))
      :ok
    end
  end

  @doc "Relative path inside a plugin dir where the signature lives."
  @spec signature_path(Path.t()) :: Path.t()
  def signature_path(plugin_dir), do: Path.join(plugin_dir, @signature_file)

  @doc "Relative path inside a plugin dir where the manifest lives."
  @spec manifest_path(Path.t()) :: Path.t()
  def manifest_path(plugin_dir), do: Path.join(plugin_dir, @manifest_file)

  @doc "Current signing envelope version."
  @spec envelope_version() :: integer()
  def envelope_version, do: @envelope_version

  defp refuse_if_no_manifest(nil, plugin_dir),
    do: {:error, "no priv/mob_plugin.exs in #{plugin_dir}"}

  defp refuse_if_no_manifest(_manifest, _plugin_dir), do: :ok

  # ── referenced-file collection ────────────────────────────────────────────

  defp referenced_files(manifest, plugin_dir) do
    swift = list_of_strings(get_in(manifest, [:ios, :swift_files]))

    android =
      [
        get_in(manifest, [:android, :bridge_kt]),
        get_in(manifest, [:android, :jni_source])
      ]
      |> Enum.filter(&is_binary/1)

    # res_files are copied verbatim into the app res/ tree, so their bytes must
    # be tamper-evident too (same as bridge_kt / jni_source).
    res = list_of_strings(get_in(manifest, [:android, :res_files]))

    nifs = nif_files(manifest, plugin_dir)

    # The manifest itself MUST be signed — otherwise `Verify` has no way to
    # detect a tampered `priv/mob_plugin.exs` without eval'ing it first,
    # which is the whole class of bug MOB-74 closes. Always included, always
    # at a stable relative path so `Verify` can look it up by name.
    [@manifest_file | swift ++ android ++ res ++ nifs]
  end

  defp nif_files(manifest, plugin_dir) do
    for nif <- Map.get(manifest, :nifs, []) || [],
        is_map(nif),
        rel = nif[:native_dir],
        is_binary(rel),
        path <- expand_native_dir(plugin_dir, rel) do
      path
    end
  end

  defp expand_native_dir(plugin_dir, rel_dir) do
    abs_dir = Path.join(plugin_dir, rel_dir)

    if File.dir?(abs_dir) do
      abs_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(fn p -> Path.extname(p) in @nif_extensions end)
      |> Enum.map(&Path.relative_to(&1, plugin_dir))
    else
      []
    end
  end

  defp list_of_strings(value) do
    for s <- List.wrap(value), is_binary(s), do: s
  end

  @doc false
  # Exposed so `Verify` can re-hash files on disk without duplicating the
  # missing-file convention (missing file hashes as the SHA-256 of empty
  # bytes so a tamper-check comparing declared vs actual notices the
  # difference).
  @spec sha256!(Path.t()) :: file_hash()
  def sha256!(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _} -> :crypto.hash(:sha256, <<>>)
    end
  end
end

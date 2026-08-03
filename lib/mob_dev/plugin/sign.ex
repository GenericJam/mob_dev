defmodule MobDev.Plugin.Sign do
  @moduledoc """
  Author-side signing workflow for mob plugins.

  Produces `priv/mob_plugin.sig` for a plugin directory by:

  1. Loading the manifest (`priv/mob_plugin.exs`).
  2. Computing SHA-256 hashes for every file the manifest references
     (Swift sources, Android bridge/JNI sources, NIF native_dir contents).
  3. Building the canonical payload (manifest + sorted file hashes).
  4. Signing the canonical encoding of the payload via `Crypto.sign/2`.
  5. Writing a versioned binary envelope to `priv/mob_plugin.sig`.

  Pure helpers are exposed for tests: `compute_file_hashes/2` and
  `build_payload/2` are deterministic given their inputs.
  """

  alias MobDev.Plugin.{Crypto, Manifest}

  @legacy_envelope_version 1
  @envelope_version 2
  @supported_envelope_versions [@legacy_envelope_version, @envelope_version]

  @signature_file "priv/mob_plugin.sig"
  @manifest_file "priv/mob_plugin.exs"

  # File extensions to include when a manifest entry points at a
  # `:native_dir` (NIF C/C++/Objective-C/Objective-C++/Zig sources + headers).
  # The set is fixed because the build pipeline only compiles these extensions.
  @legacy_nif_extensions [".c", ".h", ".cpp", ".zig"]
  @nif_extensions [".c", ".h", ".cpp", ".m", ".mm", ".zig"]

  @typedoc "A supported plugin-signature envelope and payload version."
  @type signature_version :: 1 | 2

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
  - `manifest.nifs[].native_dir` — recursive over `.c`, `.h`, `.cpp`, `.m`,
    `.mm`, and `.zig` files inside. This is the only case where a directory
    is expanded.

  Other manifest fields are either name-only (component atoms,
  `swift_struct`) or pure data (plist keys, permission strings,
  framework names) and are covered by the manifest term itself being
  part of the signed payload.

  Missing files are skipped silently — `Validator.validate_plugin/3`
  is responsible for refusing to publish a plugin with missing
  declared paths, so the signing surface assumes paths that exist.
  """
  @spec compute_file_hashes(Path.t(), map() | nil) :: file_hashes()
  def compute_file_hashes(plugin_dir, manifest) do
    compute_file_hashes(plugin_dir, manifest, @envelope_version)
  end

  @doc false
  @spec compute_file_hashes(Path.t(), map() | nil, signature_version()) :: file_hashes()
  def compute_file_hashes(_plugin_dir, nil, version)
      when version in @supported_envelope_versions,
      do: []

  def compute_file_hashes(plugin_dir, manifest, version)
      when is_map(manifest) and version in @supported_envelope_versions do
    manifest
    |> referenced_files(plugin_dir, version)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn rel -> {rel, sha256!(Path.join(plugin_dir, rel))} end)
  end

  @doc """
  Builds the canonical payload term that gets signed.

  Shape:

      %{
        manifest: <the loaded mob_plugin manifest>,
        file_hashes: [{rel_path, sha256}, ...],
        envelope_version: 2
      }

  The two-argument form always builds the current v2 payload. Verification
  uses the versioned form to reconstruct the exact frozen v1 payload for
  already-shipped signatures. The version is part of the signed payload, so
  changing the envelope version without resigning fails cryptographically.
  """
  @spec build_payload(map() | nil, file_hashes()) :: map()
  def build_payload(manifest, file_hashes) do
    build_payload(manifest, file_hashes, @envelope_version)
  end

  @doc false
  @spec build_payload(map() | nil, file_hashes(), signature_version()) :: map()
  def build_payload(manifest, file_hashes, version)
      when version in @supported_envelope_versions do
    %{
      manifest: manifest,
      file_hashes: file_hashes,
      envelope_version: version
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

  Orchestrates the full author workflow: loads the manifest, computes
  file hashes, builds the payload, signs it, wraps the signature in the
  envelope binary, and writes the file. Returns `:ok` on success or
  `{:error, reason}` if the manifest is missing/invalid.
  """
  @spec sign_plugin(Path.t(), Crypto.priv_key()) :: :ok | {:error, term()}
  def sign_plugin(plugin_dir, priv_key) when is_binary(priv_key) do
    with {:ok, manifest} <- Manifest.load(plugin_dir),
         :ok <- refuse_if_no_manifest(manifest, plugin_dir) do
      file_hashes = compute_file_hashes(plugin_dir, manifest)
      payload = build_payload(manifest, file_hashes)
      signature = Crypto.sign(payload, priv_key)

      envelope = %{signature: signature, envelope_version: @envelope_version}
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

  defp referenced_files(manifest, plugin_dir, version) do
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

    nifs = nif_files(manifest, plugin_dir, version)

    swift ++ android ++ res ++ nifs
  end

  defp nif_files(manifest, plugin_dir, version) do
    for nif <- Map.get(manifest, :nifs, []) || [],
        is_map(nif),
        rel = nif[:native_dir],
        is_binary(rel),
        path <- expand_native_dir(plugin_dir, rel, version) do
      path
    end
  end

  defp expand_native_dir(plugin_dir, rel_dir, version) do
    abs_dir = Path.join(plugin_dir, rel_dir)
    extensions = nif_extensions(version)

    if File.dir?(abs_dir) do
      abs_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(fn p -> Path.extname(p) in extensions end)
      |> Enum.map(&Path.relative_to(&1, plugin_dir))
    else
      []
    end
  end

  defp nif_extensions(@legacy_envelope_version), do: @legacy_nif_extensions
  defp nif_extensions(@envelope_version), do: @nif_extensions

  defp list_of_strings(value) do
    for s <- List.wrap(value), is_binary(s), do: s
  end

  defp sha256!(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _} -> :crypto.hash(:sha256, <<>>)
    end
  end
end

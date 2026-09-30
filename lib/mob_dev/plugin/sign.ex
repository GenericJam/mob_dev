defmodule MobDev.Plugin.Sign do
  @moduledoc """
  Author-side signing workflow for mob plugins.

  Produces `priv/mob_plugin.sig` for a plugin directory by:

  1. Loading the manifest (`priv/mob_plugin.exs`).
  2. Computing SHA-256 hashes for every file the native build reads from
     the plugin (`build_inputs/2`), **including the manifest bytes
     themselves**, plus the build-input coverage marker (see below).
  3. Building the canonical payload (sorted file hashes + envelope
     version).
  4. Signing the canonical encoding of the payload via `Crypto.sign/2`.
  5. Writing a binary `priv/mob_plugin.sig` containing the signature
     **and the signed file_hashes list**, so verifiers can check
     integrity without needing to `Code.eval_file` the manifest first
     (see MOB-74).

  `build_inputs/2`, `compute_file_hashes/2` and `build_payload/1` are
  exposed for tests and for `Verify`; they are deterministic given their
  inputs and the plugin directory's contents.

  ## Envelope versions

  - **v1** (deprecated, MOB-74) — payload was `%{manifest: <map>,
    file_hashes: [...]}` and the envelope on disk carried only the
    signature. Verifiers needed the eval'd manifest map to rebuild the
    payload, so the eval had to run *before* verification could —
    letting a malicious `priv/mob_plugin.exs` execute arbitrary code
    at build time. Refused by `MobDev.Plugin.Verify` since mob_dev
    0.7.2, except for Hex plugins accepted under the MOB-287 transition
    rule (`MobDev.Plugin.V1Transition`). Never produced any more.
  - **v2** (current) — payload is `%{file_hashes: [...],
    envelope_version: 2}`; `file_hashes` includes
    `priv/mob_plugin.exs`; envelope on disk embeds `file_hashes`
    alongside the signature. Verifiers can check every on-disk file
    against the signed hashes without touching the manifest map, so
    verification is safe to run before eval.

  ## Build-input coverage (MOB-297)

  Signatures made before MOB-297 listed only some of the files the build
  reads (a `native_dir` was filtered to `.c`/`.h`/`.cpp`/`.zig`, so every
  iOS `.m` NIF was unsigned, and `cpp_archive` sources were skipped), and
  the verifier checked only listed files. A signature now lists every
  `build_inputs/2` file **and** a coverage marker entry — a `file_hashes`
  entry for a path that never exists, hashed as empty bytes. Because the
  marker is inside the signed list it cannot be stripped, and a verifier
  that sees it also requires every build input to be listed. mob_dev 0.7.2
  rehashes the marker path, finds nothing, gets the empty-bytes hash and
  accepts it, so hosts that have not upgraded still verify new signatures.
  See decisions/2026-09-30-plugin-signature-coverage.md.
  """

  alias MobDev.Plugin.{Crypto, Manifest, Merge}

  @envelope_version 2

  @signature_file "priv/mob_plugin.sig"
  @manifest_file "priv/mob_plugin.exs"

  # Build-input coverage marker (see the moduledoc). A path no plugin ships,
  # hashed as empty bytes: exactly what `sha256!/1` yields for a missing file,
  # which is how mob_dev 0.7.2 passes it without knowing what it means. The
  # `-2` is the coverage rule's version; a verifier must recompute the set with
  # the rule the signer used, so a future change to `build_inputs/2` that
  # would reject existing signatures ships as a new marker.
  @coverage_marker "priv/mob_plugin.coverage-2"
  @empty_sha256 :crypto.hash(:sha256, <<>>)

  @typedoc "Relative path inside the plugin directory."
  @type rel_path :: String.t()

  @typedoc "SHA-256 digest of a single file (raw 32-byte binary)."
  @type file_hash :: binary()

  @typedoc "Sorted list of `{relative_path, sha256}` tuples."
  @type file_hashes :: [{rel_path(), file_hash()}]

  @doc """
  Returns the relative-path-sorted `{relative_path, sha256}` list a new
  signature carries: every `build_inputs/2` file plus the coverage marker.

  Missing files hash as empty bytes (see `sha256!/1`) —
  `Validator.validate_plugin/3` refuses to publish a plugin with missing
  declared paths, and a missing file that later appears no longer matches.
  """
  @spec compute_file_hashes(Path.t(), map() | nil) :: file_hashes()
  def compute_file_hashes(_plugin_dir, nil), do: []

  def compute_file_hashes(plugin_dir, manifest) when is_map(manifest) do
    hashes =
      for rel <- build_inputs(plugin_dir, manifest),
          do: {rel, sha256!(Path.join(plugin_dir, rel))}

    Enum.sort([{@coverage_marker, @empty_sha256} | hashes])
  end

  @doc """
  Plugin-relative paths of every file the native build reads from the
  plugin, sorted. The signer lists all of them; a verifier seeing the
  coverage marker refuses a signature that omits any.

  Derived from the same `MobDev.Plugin.Merge` gatherers the build uses,
  called with an empty plugin dir so they return the declared relative
  paths:

  - `priv/mob_plugin.exs` itself (evaluated by every consumer).
  - `ios.swift_files`, `android.bridge_kt`, `android.res_files`.
  - Every compiled C-family source: each C / ObjC / Zig NIF's primary
    source (`<native_dir>/<module>.<ext>`, default `native_dir` applied),
    `android.jni_source`, and `lang: :cpp_archive` `sources:` — **and every
    file under each one's directory**, whatever its extension, because a
    quoted `#include`/`@import` resolves there first.
  - `migrations.migrations_dir/*.exs` (copied into the host and run on
    device), `assets.fonts`, `assets.images`, `default_font.file`.

  Not covered: `{:dep, app, path}` entries (another package's files) and
  `cpp_archive` `includes:` roots. An include root can be provisioned on
  the host at build time rather than shipped — mob_nx_eigen's
  `eigen-3.4.0` is downloaded into the plugin's own tree by its Mix
  compiler — so its contents cannot be signed, and requiring them listed
  would refuse the plugin on every host that has compiled it. Headers a
  plugin ships belong beside its sources, where they are covered.

  Directory expansion skips dotfiles: they are editor/OS litter
  (`.DS_Store` appears on hosts that browse `deps/` in Finder), and
  requiring them listed would fail verification for a harmless file.
  A symlink is listed as an entry and never followed. `priv/mob_plugin.sig`
  is never an input.
  """
  @spec build_inputs(Path.t(), map() | nil) :: [rel_path()]
  def build_inputs(_plugin_dir, nil), do: []

  def build_inputs(plugin_dir, manifest) when is_map(manifest) do
    # Plugin dir "" makes each gatherer's Path.join/2 return the declared
    # relative path unchanged.
    plugins = [{"", manifest}]
    archive_sources = Enum.flat_map(Merge.static_archives(plugins), &own_paths(&1.sources))

    compiled =
      Merge.nif_sources(plugins) ++
        Merge.zig_nif_sources(plugins) ++
        Merge.jni_sources(plugins) ++
        archive_sources

    files =
      Merge.swift_files(plugins) ++
        Merge.bridge_kt_sources(plugins) ++
        Enum.map(Merge.android_res_files(plugins), & &1.src) ++
        compiled ++
        Enum.flat_map(Merge.assets(plugins), &(&1.fonts ++ &1.images)) ++
        Enum.map(Merge.default_font(plugins), & &1.file)

    expanded =
      Enum.flat_map(compiled, &files_under(plugin_dir, Path.dirname(&1))) ++
        Enum.flat_map(Merge.migrations(plugins), &migration_files(plugin_dir, &1.migrations_dir))

    sig = Path.expand(@signature_file, plugin_dir)

    [@manifest_file | files ++ expanded]
    |> Enum.reject(&(Path.expand(&1, plugin_dir) == sig))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  True when a signed `file_hashes` list carries the build-input coverage
  marker, i.e. the signer listed every `build_inputs/2` file.
  """
  @spec declares_build_input_coverage?(file_hashes()) :: boolean()
  def declares_build_input_coverage?(file_hashes),
    do: List.keymember?(file_hashes, @coverage_marker, 0)

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

  # ── build-input collection ────────────────────────────────────────────────

  # cpp_archive entries: plugin-relative strings are ours; `{:dep, …}` tokens
  # point into another package.
  defp own_paths(entries), do: Enum.filter(entries, &is_binary/1)

  # Every non-dot entry under `rel` that is not itself a directory, recursing
  # into real directories only (a symlink is listed, never followed, so a link
  # loop can't hang verification). Built on `rel` so the paths match what the
  # manifest declares. Lists with File.ls rather than Path.wildcard: a `[` or
  # `{` in the plugin's absolute path would be read as glob syntax and silently
  # list nothing, making signer and verifier disagree.
  defp files_under(plugin_dir, rel), do: list_tree(Path.join(plugin_dir, rel), rel)

  defp list_tree(abs, rel) do
    for name <- visible_entries(abs), reduce: [] do
      acc ->
        path = Path.join(abs, name)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> list_tree(path, Path.join(rel, name)) ++ acc
          {:ok, _} -> [Path.join(rel, name) | acc]
          {:error, _} -> acc
        end
    end
  end

  # The `*.exs` files `NativeBuild.apply_plugin_migrations!/0` copies.
  defp migration_files(plugin_dir, rel_dir) do
    abs = Path.join(plugin_dir, rel_dir)

    for name <- visible_entries(abs),
        Path.extname(name) == ".exs",
        File.regular?(Path.join(abs, name)),
        do: Path.join(rel_dir, name)
  end

  defp visible_entries(abs) do
    case File.ls(abs) do
      {:ok, names} -> Enum.reject(names, &String.starts_with?(&1, "."))
      {:error, _} -> []
    end
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

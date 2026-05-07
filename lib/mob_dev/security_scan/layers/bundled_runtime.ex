defmodule MobDev.SecurityScan.Layers.BundledRuntime do
  @moduledoc """
  Audits the OpenSSL, ERTS, Elixir, exqlite, and SQLite versions
  baked into Mob's pre-built OTP tarballs and into the project's
  `deps/exqlite/c_src/sqlite3.c`.

  ## Why this layer exists

  Generic dependency scanners (`mix_audit`, `osv-scanner`,
  Aqua/Snyk/Trivy) all assume *dynamic* linking — they look at lockfiles
  and don't see versions baked into static archives. Mob ships
  `libcrypto.a` (OpenSSL), `libbeam.a` (ERTS), the entire SQLite
  amalgamation, and a frozen Elixir stdlib *inside* the OTP tarball
  that gets copied into every app binary. Nothing in your `mix.lock`
  reveals these versions.

  This layer looks inside.

  ## What it does

  1. **Fingerprint** — locate cached tarballs at `~/.mob/cache/otp-*-{hash}/`,
     extract real versions of OpenSSL, ERTS, Elixir, and the bundled
     exqlite BEAMs.

  2. **Drift detection** — compare fingerprints against the
     `BundledVersions` manifest. Any mismatch is a `:high` finding —
     it means the manifest is lying about what shipped, which is the
     exact failure mode the manifest exists to prevent.

  3. **SQLite fingerprint** — read `deps/exqlite/c_src/sqlite3.c` from
     the scanned project and extract `SQLITE_VERSION`. SQLite isn't
     in the OTP tarball; it's compiled per-app via exqlite.

  4. **Version transparency** — emit informational notes documenting
     every detected version with a pointer to its upstream advisory
     page. We don't pretend to do live CVE lookups for OpenSSL/SQLite
     — there's no reliable machine-readable feed at this writing
     (OpenSSL retired its JSON feed; OSV.dev doesn't cover native libs).
     The notes give the user everything they need to verify manually.

  Hex-ecosystem CVEs (including exqlite the BEAM package) are handled
  by `hex_deps`, not duplicated here.
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{BundledVersions, Finding, LayerResult}
  alias MobDev.SecurityScan.BundledRuntime.Fingerprint

  @impl true
  def name, do: :bundled_runtime

  @impl true
  def run(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    cache_dir_opts = if dir = Keyword.get(opts, :cache_dir), do: [cache_dir: dir], else: []

    tarballs = Fingerprint.locate_cached_tarballs(cache_dir_opts)
    manifest = safe_load_manifest()

    {drift_findings, version_notes, status, error} =
      analyze(tarballs, manifest, project_root)

    %LayerResult{
      name: :bundled_runtime,
      status: status,
      findings: drift_findings,
      tools_used: ["BundledVersions manifest", "fingerprint"],
      notes: version_notes,
      error: error
    }
  end

  defp safe_load_manifest do
    {:ok, BundledVersions.load()}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp analyze([], _manifest, project_root) do
    sqlite_notes = sqlite_notes(project_root)

    notes =
      [
        "no cached OTP tarballs found at ~/.mob/cache/",
        "run `mix mob.deploy --native` from a Mob app to populate the cache"
      ] ++ sqlite_notes

    {[], notes, :not_applicable, nil}
  end

  defp analyze(_tarballs, {:error, reason}, _project_root) do
    {[], [], :error, "bundled-versions manifest failed to load: #{reason}"}
  end

  defp analyze(tarballs, {:ok, manifest}, project_root) do
    {drift_findings, per_tarball_notes} = check_tarballs(tarballs, manifest)
    sqlite_notes = sqlite_notes(project_root)
    upstream_notes = upstream_pointer_notes(manifest)

    notes =
      ["scanned #{length(tarballs)} cached OTP tarball(s)"] ++
        per_tarball_notes ++ upstream_notes ++ sqlite_notes

    {drift_findings, notes, :ok, nil}
  end

  defp check_tarballs(tarballs, manifest) do
    Enum.reduce(tarballs, {[], []}, fn tb, {findings_acc, notes_acc} ->
      versions = Fingerprint.fingerprint_tarball(tb.path)
      {findings, note} = compare_to_manifest(tb, versions, manifest)
      {findings_acc ++ findings, notes_acc ++ [note]}
    end)
  end

  defp compare_to_manifest(tb, versions, manifest) do
    case Map.fetch(manifest.bundles, tb.hash) do
      {:ok, bundle} ->
        check_bundle(tb, versions, bundle)

      :error ->
        # Tarball on disk has an unknown hash — could be from an
        # older Mob release. Inform but don't error.
        {[],
         "  · #{tb.platform} (#{tb.hash}): hash not in manifest — older or unpublished tarball"}
    end
  end

  defp expected_for(bundle, platform, key) do
    overrides = bundle |> Map.get(:per_platform, %{}) |> Map.get(platform, %{})

    if Map.has_key?(overrides, key) do
      Map.fetch!(overrides, key)
    else
      Map.get(bundle, key)
    end
  end

  defp check_bundle(tb, versions, bundle) do
    fields = [
      {:erts, "ERTS"},
      {:elixir, "Elixir"},
      {:openssl, "OpenSSL"},
      {:exqlite_beam, "exqlite (BEAM)"}
    ]

    drifts =
      Enum.flat_map(fields, fn {key, label} ->
        actual = Map.get(versions, key)
        expected = expected_for(bundle, tb.platform, key)
        compare_field(tb, label, key, expected, actual)
      end)

    summary =
      "  · #{tb.platform} (#{tb.hash}): " <>
        "ERTS #{versions.erts || "?"}, " <>
        "Elixir #{versions.elixir || "?"}, " <>
        "OpenSSL #{versions.openssl || "?"}, " <>
        "exqlite #{versions.exqlite_beam || "n/a"}" <>
        if drifts == [], do: "  ✓", else: "  ✗ DRIFT (#{length(drifts)})"

    {drifts, summary}
  end

  # Both expected and actual nil → manifest declares "this platform
  # doesn't ship this artifact" and the binary agrees. Not drift.
  defp compare_field(_tb, _label, _key, nil, nil), do: []
  defp compare_field(_tb, _label, _key, expected, actual) when expected == actual, do: []

  defp compare_field(tb, label, key, expected, nil) do
    [
      %Finding{
        id: "MOB-DRIFT-#{tb.platform}-#{key}",
        severity: :high,
        package: "mob/otp-tarball",
        version: "#{tb.platform}@#{tb.hash}",
        title: "Manifest lists #{label} #{expected} but binary has no detectable version",
        description:
          "Fingerprinting the tarball at #{tb.path} could not extract a #{label} version. " <>
            "Either the binary was built without the expected metadata, or fingerprinting needs to be updated.",
        url: "https://github.com/genericjam/mob_dev/blob/main/priv/security/bundled_versions.exs",
        source: :bundled_runtime,
        layer: :bundled_runtime
      }
    ]
  end

  defp compare_field(tb, label, key, expected, actual) do
    [
      %Finding{
        id: "MOB-DRIFT-#{tb.platform}-#{key}",
        severity: :high,
        package: "mob/otp-tarball",
        version: "#{tb.platform}@#{tb.hash}",
        fixed_in: nil,
        title: "Bundled-versions drift: #{label} manifest=#{expected} binary=#{actual}",
        description:
          "Manifest at priv/security/bundled_versions.exs claims #{label} #{expected} " <>
            "but the actual binary contains #{actual}. " <>
            "Update the manifest to match the binary, or rebuild the tarball.",
        url: "https://github.com/genericjam/mob_dev/blob/main/priv/security/bundled_versions.exs",
        source: :bundled_runtime,
        layer: :bundled_runtime
      }
    ]
  end

  defp upstream_pointer_notes(manifest) do
    bundle = Map.get(manifest.bundles, manifest.active_hash, %{})

    [
      "── version pointers (verify advisories upstream) ──",
      "  OpenSSL #{bundle[:openssl] || "?"} (#{bundle[:openssl_release_date] || "?"}) — https://openssl-library.org/news/vulnerabilities/",
      "  Erlang/OTP #{bundle[:otp_release] || "?"} (ERTS #{bundle[:erts] || "?"}) — https://github.com/erlef/security-wg/tree/main/advisories",
      "  Elixir #{bundle[:elixir] || "?"} — https://github.com/elixir-lang/elixir/security/advisories",
      "  exqlite (BEAM) #{bundle[:exqlite_beam] || "?"} — covered by :hex_deps layer"
    ]
  end

  defp sqlite_notes(project_root) do
    case Fingerprint.fingerprint_sqlite(project_root) do
      {:ok, version} ->
        [
          "  SQLite #{version} (from #{Path.relative_to_cwd(Path.join([project_root, "deps/exqlite/c_src/sqlite3.c"]))}) — https://www.sqlite.org/cves.html"
        ]

      {:error, :not_found} ->
        [
          "  SQLite: no deps/exqlite/c_src/sqlite3.c — exqlite not in this project's deps tree"
        ]

      {:error, :unparseable} ->
        [
          "  SQLite: deps/exqlite/c_src/sqlite3.c present but version macro could not be parsed"
        ]
    end
  end
end

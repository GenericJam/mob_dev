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

  3. **SQLite** — read `deps/exqlite/c_src/sqlite3.c` from the scanned
     project, extract `SQLITE_VERSION`, and report every CVE on
     `www.sqlite.org/cves.html` whose fixing release is newer (severity
     from the page, `:medium` when it gives none; rows SQLite marks
     "not a bug" are skipped). SQLite isn't in the OTP tarball; it's
     compiled per-app via exqlite, so this runs with or without cached
     tarballs.

  4. **Upstream advisories** — for the tarballs of the active runtime
     (the manifest's `active_hash`, i.e. what this mob_dev deploys),
     match the fingerprinted versions against the Erlang/OTP GitHub
     security advisories, OpenSSL's per-branch vulnerability page, and
     endoflife.date's OpenSSL branch EOL dates. Each affected advisory
     is a finding with the upstream severity; an OpenSSL branch past EOL
     is `:high`. See `MobDev.SecurityScan.BundledRuntime.Advisories` for
     the matching rules and `MobDev.SecurityScan.BundledRuntime.AdvisoryFeed`
     for caching. Offline, a cached copy is used (flagged when stale);
     with no copy at all the layer warns and lists the advisory pages to
     check by hand. Elixir remains a manual-check note.

  Stale tarballs of other hashes are fingerprinted for drift but not
  matched against advisories: they are not what ships.

  Hex-ecosystem CVEs (including exqlite the BEAM package) are handled
  by `hex_deps`, not duplicated here.
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{BundledVersions, Finding, LayerResult}
  alias MobDev.SecurityScan.BundledRuntime.{Advisories, AdvisoryFeed, Fingerprint}
  alias MobDev.Release.Tarball

  @openssl_index "https://openssl-library.org/news/vulnerabilities/"
  @openssl_eol_page "https://endoflife.date/openssl"

  @impl true
  def name, do: :bundled_runtime

  @impl true
  def run(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    cache_dir_opts = if dir = Keyword.get(opts, :cache_dir), do: [cache_dir: dir], else: []

    tarballs = Fingerprint.locate_cached_tarballs(cache_dir_opts)
    manifest = safe_load_manifest()

    {findings, notes, status, error, feed_tools} =
      analyze(tarballs, manifest, project_root, opts)

    %LayerResult{
      name: :bundled_runtime,
      status: status,
      findings: findings,
      tools_used: ["BundledVersions manifest", "fingerprint"] ++ feed_tools,
      notes: notes,
      error: error
    }
  end

  defp safe_load_manifest do
    {:ok, BundledVersions.load()}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp analyze([], _manifest, project_root, opts) do
    {sqlite_status, sqlite_findings, sqlite_notes, sqlite_tools} =
      sqlite_check(project_root, opts)

    notes =
      [
        "no cached OTP tarballs found at ~/.mob/cache/",
        "run `mix mob.deploy --native` from a Mob app to populate the cache"
      ] ++ sqlite_notes

    # SQLite is compiled from the project's deps, not the tarball, so it
    # is checked even with an empty cache.
    {sqlite_findings, notes, sqlite_status, nil, sqlite_tools}
  end

  defp analyze(_tarballs, {:error, reason}, _project_root, _opts) do
    {[], [], :error, "bundled-versions manifest failed to load: #{reason}", []}
  end

  defp analyze(tarballs, {:ok, manifest}, project_root, opts) do
    project_exqlite = project_exqlite_version(project_root)
    fingerprinted = Enum.map(tarballs, &{&1, Fingerprint.fingerprint_tarball(&1.path)})

    {drift_findings, per_tarball_notes} =
      check_tarballs(fingerprinted, manifest, project_exqlite)

    active = Enum.filter(fingerprinted, fn {tb, _versions} -> tb.hash == manifest.active_hash end)
    {advisory_findings, advisory_notes, feed_tools} = advisory_check(active, manifest, opts)
    {_status, sqlite_findings, sqlite_notes, sqlite_tools} = sqlite_check(project_root, opts)

    notes =
      ["scanned #{length(tarballs)} cached OTP tarball(s)"] ++
        per_tarball_notes ++ advisory_notes ++ sqlite_notes

    {drift_findings ++ advisory_findings ++ sqlite_findings, notes, :ok, nil,
     feed_tools ++ sqlite_tools}
  end

  defp project_exqlite_version(project_root) do
    with {:ok, lock} <- File.read(Path.join(project_root, "mix.lock")),
         {:ok, vsn} <- Tarball.parse_exqlite_version_from_lock(lock) do
      vsn
    else
      _ -> nil
    end
  end

  defp check_tarballs(fingerprinted, manifest, project_exqlite) do
    Enum.reduce(fingerprinted, {[], []}, fn {tb, versions}, {findings_acc, notes_acc} ->
      {findings, note} = compare_to_manifest(tb, versions, manifest, project_exqlite)
      {findings_acc ++ findings, notes_acc ++ [note]}
    end)
  end

  defp compare_to_manifest(tb, versions, manifest, project_exqlite) do
    case Map.fetch(manifest.bundles, tb.hash) do
      {:ok, bundle} ->
        check_bundle(tb, versions, bundle, project_exqlite)

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

  @doc """
  Whether an exqlite found in a cached OTP dir is the deploy-installed
  copy of the scanned project's own exqlite.

  iOS tarballs don't ship exqlite (manifest `nil` for that platform); the
  iOS native build installs the project's exqlite into the cached OTP dir,
  and the :hex_deps layer audits that version through `mix.lock`. So the
  copy is exempt from drift only when the manifest expects none AND its
  version equals the project's locked exqlite. Anything else in the cache
  (a project without exqlite, or another project's version) is not covered
  by :hex_deps, still gets packaged, and stays a drift finding.
  """
  @spec deploy_installed_exqlite?(String.t() | nil, String.t() | nil, String.t() | nil) ::
          boolean()
  def deploy_installed_exqlite?(nil, actual, project_exqlite)
      when is_binary(actual) and actual == project_exqlite,
      do: true

  def deploy_installed_exqlite?(_expected, _actual, _project_exqlite), do: false

  defp check_bundle(tb, versions, bundle, project_exqlite) do
    fields = [
      {:erts, "ERTS"},
      {:elixir, "Elixir"},
      {:openssl, "OpenSSL"},
      {:exqlite_beam, "exqlite (BEAM)"}
    ]

    exqlite_expected = expected_for(bundle, tb.platform, :exqlite_beam)

    deploy_installed? =
      deploy_installed_exqlite?(exqlite_expected, versions.exqlite_beam, project_exqlite)

    drifts =
      Enum.flat_map(fields, fn
        {:exqlite_beam, _label} when deploy_installed? ->
          []

        {:exqlite_beam, label} when is_nil(exqlite_expected) ->
          stray_exqlite(tb, label, versions.exqlite_beam, project_exqlite)

        {key, label} ->
          compare_field(tb, label, key, expected_for(bundle, tb.platform, key), versions[key])
      end)

    exqlite_note =
      cond do
        is_nil(versions.exqlite_beam) -> "exqlite n/a"
        deploy_installed? -> "exqlite #{versions.exqlite_beam} (deploy-installed, not tracked)"
        true -> "exqlite #{versions.exqlite_beam}"
      end

    summary =
      "  · #{tb.platform} (#{tb.hash}): " <>
        "ERTS #{versions.erts || "?"}, " <>
        "Elixir #{versions.elixir || "?"}, " <>
        "OpenSSL #{versions.openssl || "?"}, " <>
        exqlite_note <>
        if drifts == [], do: "  ✓", else: "  ✗ DRIFT (#{length(drifts)})"

    {drifts, summary}
  end

  defp stray_exqlite(_tb, _label, nil, _project_exqlite), do: []

  defp stray_exqlite(tb, label, actual, project_exqlite) do
    project = if project_exqlite, do: "locks #{project_exqlite}", else: "has no exqlite"

    [
      %Finding{
        id: "MOB-DRIFT-#{tb.platform}-exqlite_beam",
        severity: :high,
        package: "mob/otp-tarball",
        version: "#{tb.platform}@#{tb.hash}",
        title: "Cached #{label} #{actual} is not this project's exqlite (project #{project})",
        description:
          "The #{tb.platform} tarball doesn't ship exqlite, but #{tb.path} contains " <>
            "exqlite #{actual}. It isn't the version in this project's mix.lock, so the " <>
            ":hex_deps layer doesn't audit it, yet the native build packages the whole cached " <>
            "lib dir. Rerun `mix mob.deploy --native` from this project, or remove the stale " <>
            "lib/exqlite-#{actual} from the cache.",
        url: "https://github.com/genericjam/mob_dev/blob/main/priv/security/bundled_versions.exs",
        source: :bundled_runtime,
        layer: :bundled_runtime
      }
    ]
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

  defp advisory_check([], manifest, _opts) do
    bundle = Map.get(manifest.bundles, manifest.active_hash, %{})

    notes =
      [
        "── upstream advisories ──",
        "  ⚠ active runtime #{manifest.active_hash} is not in the cache, so OTP/OpenSSL " <>
          "advisories were not checked; run `mix mob.deploy --native` to fetch it",
        "  OpenSSL #{bundle[:openssl] || "?"} — #{@openssl_index}",
        "  Erlang/OTP #{bundle[:otp_release] || "?"} (ERTS #{bundle[:erts] || "?"}) — " <>
          Advisories.otp_advisories_url()
      ] ++ manual_check_notes(bundle)

    {[], notes, []}
  end

  defp advisory_check(active, manifest, opts) do
    bundle = Map.fetch!(manifest.bundles, manifest.active_hash)
    {otp_findings, otp_notes, otp_tools} = otp_advisories(active, opts)
    {ssl_findings, ssl_notes, ssl_tools} = openssl_advisories(active, opts)

    notes =
      ["── upstream advisories (active runtime #{manifest.active_hash}) ──"] ++
        otp_notes ++ ssl_notes ++ manual_check_notes(bundle)

    {otp_findings ++ ssl_findings, notes, otp_tools ++ ssl_tools}
  end

  defp manual_check_notes(bundle) do
    [
      "  Elixir #{bundle[:elixir] || "?"} — not checked automatically; " <>
        "https://github.com/elixir-lang/elixir/security/advisories",
      "  exqlite (BEAM) #{bundle[:exqlite_beam] || "?"} — covered by :hex_deps layer"
    ]
  end

  defp otp_advisories(active, opts) do
    label = "Erlang/OTP " <> joined(active, &(&1.otp || "?"))

    # Application entries decide every current advisory, so a tarball whose
    # OTP apps weren't found would read as clean. lib/ also holds versioned
    # non-OTP dirs (exqlite, deploy-installed project apps), so key on the
    # OTP core apps every runtime ships.
    {checkable, blind} =
      Enum.split_with(active, fn {_tb, versions} ->
        Enum.any?(versions.apps, fn {app, _vsn} -> app in ["kernel", "stdlib"] end)
      end)

    blind_notes =
      for {tb, _versions} <- blind do
        "  ⚠ #{tb.platform} (#{tb.hash}): no OTP application versions found under " <>
          "#{Path.join(tb.path, "lib")} — OTP advisories not checked for it"
      end

    if checkable == [] do
      {[], blind_notes, []}
    else
      {findings, notes, tools} = match_otp_advisories(checkable, label, opts)
      {findings, blind_notes ++ notes, tools}
    end
  end

  defp match_otp_advisories(active, label, opts) do
    case AdvisoryFeed.load(:otp, opts) do
      {:ok, advisories, provenance} ->
        findings =
          active
          |> Enum.flat_map(fn {tb, versions} ->
            advisories
            |> Advisories.otp_findings(%{otp: versions.otp, apps: versions.apps})
            |> Enum.map(&{&1, tb})
          end)
          |> merge_platforms()

        applying = findings |> Enum.uniq_by(& &1.id) |> length()

        note =
          feed_note(
            "#{label}: #{applying} of #{length(advisories)} erlang/otp security advisories apply",
            provenance
          )

        {findings, [note], ["GitHub erlang/otp security advisories"]}

      {:error, reason} ->
        {[], [unavailable_note(label, reason, Advisories.otp_advisories_url())], []}
    end
  end

  defp openssl_advisories(active, opts) do
    by_version =
      active
      |> Enum.group_by(fn {_tb, versions} -> versions.openssl end)
      |> Map.delete(nil)

    if map_size(by_version) == 0 do
      {[],
       [
         "  ⚠ OpenSSL: no version fingerprinted from libcrypto.a — not checked; #{@openssl_index}"
       ], []}
    else
      eol_feed = AdvisoryFeed.load(:openssl_eol, opts)
      today = Keyword.get(opts, :today, Date.utc_today())

      {pairs, notes, tools} =
        Enum.reduce(by_version, {[], [], []}, fn {version, tarballs}, {pairs, notes, tools} ->
          {p, n, t} = openssl_version_check(version, tarballs, eol_feed, today, opts)
          {pairs ++ p, notes ++ n, tools ++ t}
        end)

      {merge_platforms(pairs), notes, Enum.uniq(tools)}
    end
  end

  defp openssl_version_check(version, tarballs, eol_feed, today, opts) do
    case Advisories.openssl_branch(version) do
      {:ok, branch} ->
        {vuln_pairs, vuln_notes, vuln_tools} = openssl_vulns(version, branch, tarballs, opts)

        {eol_pairs, eol_notes, eol_tools} =
          openssl_eol(version, branch, tarballs, eol_feed, today)

        {vuln_pairs ++ eol_pairs, vuln_notes ++ eol_notes, vuln_tools ++ eol_tools}

      :error ->
        {[], ["  ⚠ OpenSSL #{version}: unrecognised version — not checked; #{@openssl_index}"],
         []}
    end
  end

  defp openssl_vulns(version, branch, tarballs, opts) do
    label = "OpenSSL #{version}"

    case AdvisoryFeed.load({:openssl, branch}, opts) do
      {:ok, entries, provenance} ->
        findings = Advisories.openssl_findings(entries, version, branch)
        pairs = for {tb, _versions} <- tarballs, finding <- findings, do: {finding, tb}

        note =
          feed_note(
            "#{label}: #{length(findings)} of #{length(entries)} CVEs on the #{branch} " <>
              "vulnerability page apply",
            provenance
          )

        {pairs, [note], ["openssl-library.org vulnerabilities"]}

      {:error, reason} ->
        {[], [unavailable_note(label, reason, Advisories.openssl_page_url(branch))], []}
    end
  end

  defp openssl_eol(version, branch, tarballs, eol_feed, today) do
    case eol_feed do
      {:ok, cycles, provenance} ->
        {pairs, text} =
          case Advisories.openssl_eol(cycles, version, today) do
            {:eol, %Date{} = eol, finding} ->
              {for({tb, _versions} <- tarballs, do: {finding, tb}),
               "OpenSSL #{branch}: END OF LIFE since #{Date.to_iso8601(eol)}"}

            {:eol, nil, finding} ->
              {for({tb, _versions} <- tarballs, do: {finding, tb}),
               "OpenSSL #{branch}: END OF LIFE"}

            {:supported, %Date{} = eol} ->
              {[], "OpenSSL #{branch}: supported until #{Date.to_iso8601(eol)}"}

            {:supported, nil} ->
              {[], "OpenSSL #{branch}: supported, no end-of-life date announced"}

            :unknown_branch ->
              {[], "OpenSSL #{branch}: branch not listed by endoflife.date"}
          end

        {pairs, [feed_note(text, provenance)], ["endoflife.date"]}

      {:error, reason} ->
        {[], [unavailable_note("OpenSSL #{branch} end-of-life", reason, @openssl_eol_page)], []}
    end
  end

  # The same advisory hits every platform tarball of the runtime; report
  # it once per (id, package, version) and name the platforms.
  defp merge_platforms(pairs) do
    pairs
    |> Enum.group_by(fn {finding, _tb} -> Finding.dedupe_key(finding) end)
    |> Enum.map(fn {_key, [{finding, tb} | _] = group} ->
      platforms =
        group
        |> Enum.map(fn {_finding, t} -> Atom.to_string(t.platform) end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.join(", ")

      %{finding | description: "#{finding.description} Ships in #{tb.hash} for: #{platforms}."}
    end)
    |> Enum.sort_by(&Finding.sort_key/1)
  end

  defp joined(active, fun) do
    active |> Enum.map(fn {_tb, versions} -> fun.(versions) end) |> Enum.uniq() |> Enum.join("/")
  end

  defp feed_note(text, {:fetched, _at}), do: "  #{text} (fetched just now)"

  defp feed_note(text, {:fetched, _at, {:cache_write_failed, reason}}),
    do: "  ⚠ #{text} (fetched just now, but not cached for offline use: #{reason})"

  defp feed_note(text, {:cached, at}), do: "  #{text} (cached #{timestamp(at)})"

  defp feed_note(text, {:stale, at, reason}),
    do: "  ⚠ #{text} (STALE copy from #{timestamp(at)}; refresh failed: #{reason})"

  defp unavailable_note(label, reason, url) do
    "  ⚠ #{label}: advisory data unavailable (#{reason}; no cached copy) — not checked; " <>
      "verify at #{url}"
  end

  defp timestamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp sqlite_check(project_root, opts) do
    case Fingerprint.fingerprint_sqlite(project_root) do
      {:ok, version} ->
        sqlite_cves(version, opts)

      {:error, :not_found} ->
        {:not_applicable, [],
         ["  SQLite: no deps/exqlite/c_src/sqlite3.c — exqlite not in this project's deps tree"],
         []}

      {:error, :unparseable} ->
        {:ok, [],
         [
           "  ⚠ SQLite: deps/exqlite/c_src/sqlite3.c present but version macro could not be " <>
             "parsed — not checked; #{Advisories.sqlite_cves_url()}"
         ], []}
    end
  end

  defp sqlite_cves(version, opts) do
    label = "SQLite #{version} (deps/exqlite/c_src/sqlite3.c)"

    with true <- Advisories.sqlite_version?(version),
         {:ok, entries, provenance} <- AdvisoryFeed.load(:sqlite, opts) do
      findings =
        entries |> Advisories.sqlite_findings(version) |> Enum.sort_by(&Finding.sort_key/1)

      fixed =
        for %{fixed_in: fix, cves: cves} when is_binary(fix) <- entries, cve <- cves, do: cve

      note =
        feed_note(
          "#{label}: #{length(findings)} of #{length(fixed)} fixed CVEs on " <>
            "#{Advisories.sqlite_cves_url()} apply",
          provenance
        )

      {:ok, findings, [note], ["sqlite.org CVE table"]}
    else
      false ->
        {:ok, [],
         ["  ⚠ #{label}: unrecognised version — not checked; #{Advisories.sqlite_cves_url()}"],
         []}

      {:error, reason} ->
        {:ok, [], [unavailable_note(label, reason, Advisories.sqlite_cves_url())], []}
    end
  end
end

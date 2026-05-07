defmodule MobDev.SecurityScan.Layers.HexDeps do
  @moduledoc """
  Audits Hex dependencies in `mix.lock` against two complementary
  advisory sources:

    1. [`mix_audit`](https://hexdocs.pm/mix_audit/) — Mirego's curated
       `elixir-security-advisories` repo, cloned into `~/.local/share/`.
       Hex-ecosystem-only, hand-reviewed entries.

    2. [`osv-scanner`](https://google.github.io/osv-scanner/) — Google's
       OSV.dev aggregator, which pulls the Erlef CNA feed alongside many
       other ecosystems. Tends to surface CVE-numbered advisories that
       Mirego hasn't ingested yet.

  Running both is deliberate. They miss different things, and the
  delta between them is what catches advisories the curated database
  hasn't picked up. Findings dedupe on `(advisory_id, package, version)`
  with osv-scanner winning on ties (CVSS-derived severity is the more
  standard signal).

  If `osv-scanner` isn't installed the layer still runs successfully
  on `mix_audit` alone — the note records that the second source was
  unavailable so the report is honest about coverage.
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{Finding, LayerResult, OsvScanner}

  @impl true
  def name, do: :hex_deps

  @impl true
  def run(opts) do
    path = Keyword.get(opts, :project_root, File.cwd!())
    lockfile = Path.join(path, "mix.lock")

    if File.exists?(lockfile) do
      run_audit(path, lockfile, opts)
    else
      %LayerResult{
        name: :hex_deps,
        status: :not_applicable,
        notes: ["no mix.lock at #{lockfile}"]
      }
    end
  end

  defp run_audit(path, lockfile, opts) do
    deps = MixAudit.Project.dependencies(path)
    {audit_findings, audit_notes, audit_status} = run_mix_audit(deps, opts)
    {osv_findings, osv_notes, osv_tools} = run_osv(lockfile, opts)

    findings = dedupe(osv_findings ++ audit_findings)
    base_note = "audited #{length(deps)} hex deps from #{lockfile}"

    %LayerResult{
      name: :hex_deps,
      status: audit_status,
      findings: findings,
      tools_used: ["mix_audit"] ++ osv_tools,
      notes: [base_note] ++ audit_notes ++ osv_notes
    }
  end

  defp run_mix_audit(deps, opts) do
    advisories_fn = Keyword.get(opts, :advisories_fn, &MixAudit.Repo.advisories/0)

    case fetch_advisories(advisories_fn) do
      {:ok, advisories} ->
        grouped = Enum.group_by(advisories, & &1.package)
        report = MixAudit.Audit.report(deps, grouped)
        findings = Enum.map(report.vulnerabilities, &to_finding/1)
        {findings, ["mix_audit: #{length(findings)} finding(s)"], :ok}

      {:error, reason} ->
        {[],
         [
           "mix_audit advisory db unavailable: #{reason}",
           "first run clones github.com/mirego/elixir-security-advisories"
         ], :tool_missing}
    end
  end

  defp run_osv(lockfile, opts) do
    osv_scan = Keyword.get(opts, :osv_scan_fn, &OsvScanner.scan/3)

    case osv_scan.({:lockfile, lockfile}, :hex_deps, []) do
      {:ok, findings} ->
        {findings, ["osv-scanner: #{length(findings)} finding(s)"], ["osv-scanner"]}

      {:error, :not_installed} ->
        {[], ["osv-scanner not installed (skipped); install: brew install osv-scanner"], []}

      {:error, {:not_found, _}} ->
        # mix.lock missing was already screened above; if osv says not_found,
        # treat as transient and skip without panic.
        {[], ["osv-scanner: target unavailable"], []}

      {:error, {:scan_failed, reason}} ->
        {[], ["osv-scanner failed: #{reason}"], ["osv-scanner"]}
    end
  end

  defp dedupe(findings) do
    Enum.uniq_by(findings, &Finding.dedupe_key/1)
  end

  defp fetch_advisories(advisories_fn) do
    {:ok, advisories_fn.()}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp to_finding(%MixAudit.Vulnerability{advisory: advisory, dependency: dep}) do
    %Finding{
      id: advisory.id,
      severity: normalize_severity(advisory.severity),
      package: dep.package,
      version: dep.version,
      fixed_in: first_patched(advisory.first_patched_versions),
      title: advisory.title,
      description: advisory.description,
      url: advisory.url,
      source: :mix_audit,
      layer: :hex_deps
    }
  end

  defp first_patched(nil), do: nil
  defp first_patched([]), do: nil
  defp first_patched([first | _]) when is_binary(first), do: first
  defp first_patched(other) when is_binary(other), do: other
  defp first_patched(_), do: nil

  # Mirego advisory severities are free-form strings ("critical", "high",
  # "moderate", etc.) and many entries simply omit the field. Normalize
  # to our atom scale.
  defp normalize_severity(nil), do: :unknown
  defp normalize_severity(""), do: :unknown

  defp normalize_severity(severity) when is_binary(severity) do
    case severity |> String.trim() |> String.downcase() do
      "critical" -> :critical
      "high" -> :high
      "important" -> :high
      "medium" -> :medium
      "moderate" -> :medium
      "low" -> :low
      _ -> :unknown
    end
  end

  defp normalize_severity(_), do: :unknown
end

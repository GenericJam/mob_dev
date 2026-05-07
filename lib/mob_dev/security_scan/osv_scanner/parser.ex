defmodule MobDev.SecurityScan.OsvScanner.Parser do
  @moduledoc """
  Pure parser: `osv-scanner` JSON → `[Finding.t()]`.

  The osv-scanner output schema (as of 2.x):

      {
        "results": [
          {
            "source": {"path": "...", "type": "lockfile"},
            "packages": [
              {
                "package": {"name": "...", "version": "...", "ecosystem": "..."},
                "groups": [{"ids": [...], "max_severity": "8.2"}],
                "vulnerabilities": [
                  {
                    "id": "GHSA-XXX",
                    "summary": "...",
                    "details": "...",
                    "aliases": ["CVE-...", "GHSA-..."],
                    "affected": [{"ranges": [{"events": [{"fixed": "1.11.0"}]}]}],
                    "references": [{"url": "..."}]
                  }
                ]
              }
            ]
          }
        ]
      }

  Severity comes from the package's `groups[].max_severity` field,
  which is a CVSS 3.x base score as a string. We normalize using
  the standard CVSS severity bands (NVD qualitative ratings).
  """

  alias MobDev.SecurityScan.Finding

  @doc "Walk an osv-scanner JSON map and return findings tagged with `layer`."
  @spec findings(map(), atom()) :: [Finding.t()]
  def findings(%{} = json, layer) do
    json
    |> Map.get("results", [])
    |> Enum.flat_map(&package_findings(&1, layer))
  end

  defp package_findings(%{"packages" => packages}, layer) when is_list(packages) do
    Enum.flat_map(packages, &one_package(&1, layer))
  end

  defp package_findings(_, _), do: []

  defp one_package(%{"package" => pkg, "vulnerabilities" => vulns} = entry, layer)
       when is_list(vulns) do
    severity_map = build_severity_map(entry)

    Enum.map(vulns, &one_vulnerability(&1, pkg, severity_map, layer))
  end

  defp one_package(_, _), do: []

  defp build_severity_map(%{"groups" => groups}) when is_list(groups) do
    # groups[].ids gives the alias set; max_severity applies to all of them.
    # Build a per-id lookup so each vulnerability can look up its severity
    # without scanning all groups.
    Enum.reduce(groups, %{}, fn group, acc ->
      score = parse_cvss(group["max_severity"])

      group
      |> Map.get("ids", [])
      |> Enum.reduce(acc, &Map.put(&2, &1, score))
    end)
  end

  defp build_severity_map(_), do: %{}

  defp one_vulnerability(vuln, pkg, severity_map, layer) do
    id = vuln["id"]
    severity = lookup_severity(vuln, severity_map)

    %Finding{
      id: id,
      severity: severity,
      package: pkg["name"],
      version: pkg["version"],
      fixed_in: first_fixed_version(vuln),
      title: vuln["summary"] || vuln["details"],
      description: vuln["details"] || vuln["summary"],
      url: primary_url(vuln),
      source: :osv_scanner,
      layer: layer
    }
  end

  defp lookup_severity(vuln, severity_map) do
    aliases = (vuln["aliases"] || []) ++ [vuln["id"]]

    aliases
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(:unknown, &Map.get(severity_map, &1))
  end

  defp first_fixed_version(vuln) do
    vuln
    |> Map.get("affected", [])
    |> Enum.flat_map(fn affected -> Map.get(affected, "ranges", []) end)
    |> Enum.flat_map(fn range -> Map.get(range, "events", []) end)
    |> Enum.find_value(fn
      %{"fixed" => v} when is_binary(v) -> v
      _ -> nil
    end)
  end

  defp primary_url(vuln) do
    vuln
    |> Map.get("references", [])
    |> Enum.find_value(fn
      %{"url" => url} when is_binary(url) -> url
      _ -> nil
    end)
  end

  # CVSS 3.x base score → NVD qualitative severity bands.
  # Spec: https://www.first.org/cvss/specification-document
  defp parse_cvss(nil), do: :unknown
  defp parse_cvss(""), do: :unknown

  defp parse_cvss(score) when is_binary(score) do
    case Float.parse(score) do
      {n, _} -> cvss_band(n)
      :error -> :unknown
    end
  end

  defp parse_cvss(score) when is_number(score), do: cvss_band(score * 1.0)
  defp parse_cvss(_), do: :unknown

  defp cvss_band(n) when n >= 9.0, do: :critical
  defp cvss_band(n) when n >= 7.0, do: :high
  defp cvss_band(n) when n >= 4.0, do: :medium
  defp cvss_band(n) when n > 0.0, do: :low
  defp cvss_band(_), do: :unknown
end

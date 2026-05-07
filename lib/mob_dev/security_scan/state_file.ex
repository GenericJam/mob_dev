defmodule MobDev.SecurityScan.StateFile do
  @moduledoc """
  Read/write the state sidecar for `mix mob.security_scan.log`.

  The state file is a small JSON document that records the
  last-known set of findings and when each was first seen. Diff
  computation between runs depends on it.

  Default location: `.security_scan/state.json` at the project root.
  Should be **checked into git** so a fresh CI run knows what the
  prior baseline was — without it, every scheduled run reports every
  finding as 'new' and the changelog becomes useless.

  ## Schema

      {
        "version": 1,
        "last_run_at": "2026-05-07T05:30:00Z",
        "findings": [
          {
            "key": "EEF-CVE-2026-32689|phoenix|1.8.5",
            "id": "EEF-CVE-2026-32689",
            "severity": "high",
            "package": "phoenix",
            "version": "1.8.5",
            "fixed_in": "1.7.22",
            "title": "...",
            "url": "...",
            "source": "osv_scanner",
            "layer": "hex_deps",
            "first_seen_at": "2026-05-07T05:30:00Z"
          }
        ]
      }
  """

  alias MobDev.SecurityScan.{Diff, Finding, Report}

  @schema_version 1

  @typedoc "Finding-as-stored: same fields as Finding plus key + first_seen_at."
  @type entry :: %{
          required(:key) => key(),
          required(:id) => String.t() | nil,
          required(:severity) => atom(),
          required(:package) => String.t() | nil,
          required(:version) => String.t() | nil,
          required(:fixed_in) => String.t() | nil,
          required(:title) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:source) => atom() | nil,
          required(:layer) => atom() | nil,
          required(:first_seen_at) => DateTime.t() | String.t()
        }

  @typedoc "Dedup key derived from id|package|version."
  @type key :: String.t()

  @typedoc "Loaded state map."
  @type state :: %{
          required(:version) => integer(),
          required(:last_run_at) => DateTime.t() | nil,
          required(:findings) => [entry()]
        }

  @doc "Empty initial state for first-time scans."
  @spec empty() :: state()
  def empty do
    %{version: @schema_version, last_run_at: nil, findings: []}
  end

  @doc "Load state from a JSON file. Returns `empty/0` if the file is missing."
  @spec load(Path.t()) :: state()
  def load(path) do
    case File.read(path) do
      {:ok, body} -> decode(body)
      {:error, _} -> empty()
    end
  end

  @doc "Encode + write the given state to disk. Creates parent dirs as needed."
  @spec save(Path.t(), state()) :: :ok
  def save(path, %{} = state) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(serialize(state), pretty: true) <> "\n")
    :ok
  end

  @doc """
  Build the next state from the current report and a `Diff` (which
  carries `first_seen_at` for findings that already existed).
  """
  @spec from_report(Report.t(), Diff.t(), DateTime.t()) :: state()
  def from_report(%Report{} = report, %Diff{} = diff, %DateTime{} = now) do
    findings =
      report
      |> Report.all_findings()
      |> Enum.map(&finding_to_entry(&1, diff.first_seen, now))

    %{version: @schema_version, last_run_at: now, findings: findings}
  end

  ## ── encoding ──────────────────────────────────────────────────────────────

  defp serialize(state) do
    %{
      "version" => state.version,
      "last_run_at" => format_dt(state.last_run_at),
      "findings" =>
        state.findings
        |> Enum.sort_by(& &1.key)
        |> Enum.map(&serialize_entry/1)
    }
  end

  defp serialize_entry(entry) do
    %{
      "key" => entry.key,
      "id" => entry.id,
      "severity" => to_string(entry.severity),
      "package" => entry.package,
      "version" => entry.version,
      "fixed_in" => entry.fixed_in,
      "title" => entry.title,
      "url" => entry.url,
      "source" => entry.source && to_string(entry.source),
      "layer" => entry.layer && to_string(entry.layer),
      "first_seen_at" => format_dt(entry.first_seen_at)
    }
  end

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(s) when is_binary(s), do: s

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"findings" => findings} = map} ->
        %{
          version: map["version"] || @schema_version,
          last_run_at: parse_dt(map["last_run_at"]),
          findings: Enum.map(findings, &decode_entry/1)
        }

      _ ->
        empty()
    end
  end

  defp decode_entry(map) do
    %{
      key: map["key"],
      id: map["id"],
      severity: parse_atom(map["severity"]),
      package: map["package"],
      version: map["version"],
      fixed_in: map["fixed_in"],
      title: map["title"],
      url: map["url"],
      source: parse_atom(map["source"]),
      layer: parse_atom(map["layer"]),
      first_seen_at: parse_dt(map["first_seen_at"])
    }
  end

  defp parse_atom(nil), do: nil
  defp parse_atom(""), do: nil

  defp parse_atom(s) when is_binary(s) do
    String.to_atom(s)
  rescue
    _ -> nil
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(%DateTime{} = dt), do: dt

  defp finding_to_entry(%Finding{} = f, first_seen, now) do
    key = Finding.dedupe_key(f) |> key_to_string()
    first = Map.get(first_seen, Finding.dedupe_key(f), now)

    %{
      key: key,
      id: f.id,
      severity: f.severity,
      package: f.package,
      version: f.version,
      fixed_in: f.fixed_in,
      title: f.title,
      url: f.url,
      source: f.source,
      layer: f.layer,
      first_seen_at: first
    }
  end

  defp key_to_string({id, package, version}) do
    "#{id || ""}|#{package || ""}|#{version || ""}"
  end
end

defmodule MobDev.SecurityScan.Diff do
  @moduledoc """
  Computes the delta between the previous scan state and the
  current report:

    * `new` — findings present now that were absent last run
    * `resolved` — findings present last run that are absent now
    * `still_present` — findings in both, with their `first_seen_at`
      preserved from the prior state for patch-lag display

  The dedup key is `Finding.dedupe_key/1` (id, package, version).
  Two findings reported by different sources for the same advisory
  on the same package@version are considered the same finding —
  resolution is based on the underlying vulnerability, not the
  scanner that surfaced it.
  """

  alias MobDev.SecurityScan.{Finding, Report}
  alias MobDev.SecurityScan.StateFile

  @type t :: %__MODULE__{
          new: [Finding.t()],
          resolved: [StateFile.entry()],
          still_present: [Finding.t()],
          first_seen: %{StateFile.key() => DateTime.t()}
        }

  defstruct new: [], resolved: [], still_present: [], first_seen: %{}

  @doc """
  Compute the diff between a previous state map (typically loaded
  from the state file) and the current report.

  Both sides are keyed by the string form of `Finding.dedupe_key/1`
  (`"id|package|version"`) so we can compare across the JSON state
  file boundary.

  `now` is injectable so tests can pin timestamps.
  """
  @spec compute(StateFile.state(), Report.t(), DateTime.t()) :: t()
  def compute(%{} = prev_state, %Report{} = report, %DateTime{} = now) do
    prev_findings = Map.get(prev_state, :findings, [])
    prev_by_key = Map.new(prev_findings, &{&1.key, &1})
    prev_keys = MapSet.new(Map.keys(prev_by_key))

    current_findings = Report.all_findings(report)
    current_by_key = Map.new(current_findings, &{string_key(&1), &1})
    current_keys = MapSet.new(Map.keys(current_by_key))

    new_keys = MapSet.difference(current_keys, prev_keys)
    resolved_keys = MapSet.difference(prev_keys, current_keys)
    still_keys = MapSet.intersection(current_keys, prev_keys)

    first_seen = build_first_seen(current_by_key, prev_by_key, now)

    # Map back to tuple-keyed first_seen for downstream consumers
    # (HistoryFormatter calls `Finding.dedupe_key/1` directly).
    first_seen_tuple_keyed =
      Map.new(first_seen, fn {string_key, ts} ->
        {string_to_tuple(string_key), ts}
      end)

    %__MODULE__{
      new: Enum.map(new_keys, &Map.fetch!(current_by_key, &1)),
      resolved: Enum.map(resolved_keys, &Map.fetch!(prev_by_key, &1)),
      still_present: Enum.map(still_keys, &Map.fetch!(current_by_key, &1)),
      first_seen: first_seen_tuple_keyed
    }
  end

  @doc "String form of `Finding.dedupe_key/1` — matches StateFile entry keys."
  @spec string_key(Finding.t()) :: String.t()
  def string_key(%Finding{} = f) do
    {id, package, version} = Finding.dedupe_key(f)
    "#{id || ""}|#{package || ""}|#{version || ""}"
  end

  defp string_to_tuple(string) do
    [id, package, version] = String.split(string, "|", parts: 3)
    {nil_if_empty(id), nil_if_empty(package), nil_if_empty(version)}
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  defp build_first_seen(current_by_key, prev_by_key, now) do
    Map.new(current_by_key, fn {key, _finding} ->
      first =
        case Map.get(prev_by_key, key) do
          %{first_seen_at: %DateTime{} = ts} -> ts
          %{first_seen_at: ts} when is_binary(ts) -> parse_or_now(ts, now)
          _ -> now
        end

      {key, first}
    end)
  end

  defp parse_or_now(string, fallback) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _} -> dt
      _ -> fallback
    end
  end
end

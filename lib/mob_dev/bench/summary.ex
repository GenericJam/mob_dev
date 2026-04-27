defmodule MobDev.Bench.Summary do
  @moduledoc """
  Post-run analysis of a bench CSV log.

  Reads a `MobDev.Bench.Logger` CSV and produces a summary map with
  metrics that tell you whether the bench measurement is trustworthy:

  - `total_samples` — how many polls completed
  - `successful_samples` — those that produced a battery reading
  - `success_rate` — fraction (0.0..1.0)
  - `reconnect_count` — number of times we transitioned :unreachable / :alive_*_only → :alive_rpc
  - `longest_gap_sec` — longest interval between successful battery reads
  - `state_durations` — total time (sec) spent in each reachability state
  - `screen_off_duration_sec` — time the screen was off
  - `screen_on_duration_sec` — time the screen was on
  - `start_battery`, `end_battery`, `drain_pct` — first and last successful reads
  - `effective_rate_pct_per_hour` — drain extrapolated to per-hour
  """

  alias MobDev.Bench.Logger

  @type metrics :: %{
          total_samples: non_neg_integer(),
          successful_samples: non_neg_integer(),
          success_rate: float(),
          reconnect_count: non_neg_integer(),
          longest_gap_sec: float(),
          state_durations: %{atom() => float()},
          screen_off_duration_sec: float(),
          screen_on_duration_sec: float(),
          start_battery: integer() | nil,
          end_battery: integer() | nil,
          drain_pct: integer() | nil,
          effective_rate_pct_per_hour: float() | nil,
          taint_warnings: [String.t()]
        }

  @doc """
  Compute summary metrics for a bench CSV.
  """
  @spec from_csv(Path.t()) :: metrics()
  def from_csv(path) do
    rows = Logger.read(path)
    from_rows(rows)
  end

  @doc """
  Compute summary metrics from already-parsed rows. Useful for tests.
  """
  @spec from_rows([map()]) :: metrics()
  def from_rows([]), do: empty_metrics()

  def from_rows(rows) when is_list(rows) do
    successful = Enum.filter(rows, &is_integer(&1.battery_pct))

    %{
      total_samples: length(rows),
      successful_samples: length(successful),
      success_rate: length(successful) / length(rows),
      reconnect_count: count_reconnects(rows),
      longest_gap_sec: longest_gap_sec(successful),
      state_durations: state_durations(rows),
      screen_off_duration_sec: screen_duration(rows, :off),
      screen_on_duration_sec: screen_duration(rows, :on),
      start_battery: start_battery(successful),
      end_battery: end_battery(successful),
      drain_pct: drain(successful),
      effective_rate_pct_per_hour: effective_rate(successful),
      taint_warnings: taint_warnings(rows)
    }
  end

  defp empty_metrics do
    %{
      total_samples: 0,
      successful_samples: 0,
      success_rate: 0.0,
      reconnect_count: 0,
      longest_gap_sec: 0.0,
      state_durations: %{},
      screen_off_duration_sec: 0.0,
      screen_on_duration_sec: 0.0,
      start_battery: nil,
      end_battery: nil,
      drain_pct: nil,
      effective_rate_pct_per_hour: nil,
      taint_warnings: []
    }
  end

  # ── Reconnect counting ───────────────────────────────────────────────────

  defp count_reconnects(rows) do
    rows
    |> Enum.map(& &1.reachability)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn
      [prev, :alive_rpc] when prev != :alive_rpc -> true
      _ -> false
    end)
  end

  # ── Gap analysis ─────────────────────────────────────────────────────────

  defp longest_gap_sec([]), do: 0.0
  defp longest_gap_sec([_]), do: 0.0

  defp longest_gap_sec(rows) do
    rows
    |> Enum.map(& &1.elapsed_sec)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.max(fn -> 0.0 end)
  end

  # ── State duration breakdown ─────────────────────────────────────────────

  defp state_durations([]), do: %{}

  defp state_durations(rows) do
    # For each row, the duration is the gap until the next row (or 0 for the
    # last row). We attribute that duration to the row's reachability state.
    rows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{}, fn [a, b], acc ->
      duration = b.elapsed_sec - a.elapsed_sec
      Map.update(acc, a.reachability, duration, &(&1 + duration))
    end)
    |> Map.new(fn {k, v} -> {k, Float.round(v, 2)} end)
  end

  defp screen_duration([], _state), do: 0.0

  defp screen_duration(rows, target_state) do
    rows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc ->
      if a.screen == target_state do
        acc + (b.elapsed_sec - a.elapsed_sec)
      else
        acc
      end
    end)
    |> Float.round(2)
  end

  # ── Battery extraction ───────────────────────────────────────────────────

  defp start_battery([first | _]), do: first.battery_pct
  defp start_battery([]), do: nil

  defp end_battery([]), do: nil
  defp end_battery(rows), do: List.last(rows).battery_pct

  defp drain([]), do: nil

  defp drain([_]), do: 0

  defp drain(rows) do
    s = start_battery(rows)
    e = end_battery(rows)
    if s && e, do: s - e, else: nil
  end

  defp effective_rate([]), do: nil
  defp effective_rate([_]), do: nil

  defp effective_rate(rows) do
    case {drain(rows), List.last(rows).elapsed_sec - List.first(rows).elapsed_sec} do
      {drain, elapsed} when is_integer(drain) and is_float(elapsed) and elapsed > 0 ->
        Float.round(drain * 3600.0 / elapsed, 2)

      _ ->
        nil
    end
  end

  # ── Taint detection ──────────────────────────────────────────────────────
  #
  # Surface things that would make a measurement inconclusive: screen came
  # back on mid-run, app died, reconnect-storms, etc.

  defp taint_warnings(rows) do
    []
    |> add_warning(screen_on_during_off_run?(rows), "screen turned ON during off-screen run")
    |> add_warning(app_died?(rows), "app process reported as dead at some point")
    |> add_warning(unreachable_majority?(rows), "majority of polls were :unreachable")
    |> add_warning(many_reconnects?(rows), "many reconnects (>=10) — flapping connection")
  end

  defp add_warning(list, true, msg), do: list ++ [msg]
  defp add_warning(list, false, _), do: list

  defp screen_on_during_off_run?(rows) do
    states = rows |> Enum.map(& &1.screen) |> MapSet.new()
    MapSet.member?(states, :off) and MapSet.member?(states, :on)
  end

  defp app_died?(rows), do: Enum.any?(rows, &(&1.app_process == :app_dead))

  defp unreachable_majority?([]), do: false

  defp unreachable_majority?(rows) do
    unreachable = Enum.count(rows, &(&1.reachability == :unreachable))
    unreachable * 2 > length(rows)
  end

  defp many_reconnects?(rows), do: count_reconnects(rows) >= 10

  # ── Pretty-print ─────────────────────────────────────────────────────────

  @doc """
  Render a summary as a human-readable multi-line string.
  """
  @spec pretty(metrics()) :: String.t()
  def pretty(%{} = m) do
    [
      "Total samples:      #{m.total_samples}",
      "Successful samples: #{m.successful_samples} (#{percent(m.success_rate)})",
      "Reconnects:         #{m.reconnect_count}",
      "Longest gap:        #{m.longest_gap_sec} sec",
      "Time by state:",
      m.state_durations
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.map(fn {state, dur} -> "  #{state}: #{dur} sec" end)
      |> Enum.join("\n"),
      "Screen off:         #{m.screen_off_duration_sec} sec",
      "Screen on:          #{m.screen_on_duration_sec} sec",
      battery_line(m),
      taint_lines(m.taint_warnings)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp percent(rate) when is_float(rate), do: "#{Float.round(rate * 100, 1)}%"

  defp battery_line(%{start_battery: nil}), do: "Battery: no successful reads"

  defp battery_line(m) do
    rate =
      case m.effective_rate_pct_per_hour do
        nil -> ""
        r -> " (≈ #{r} %/hr)"
      end

    "Battery: #{m.start_battery}% → #{m.end_battery}% (drain #{m.drain_pct}%)#{rate}"
  end

  defp taint_lines([]), do: ""

  defp taint_lines(warnings) do
    "WARNINGS (run may be inconclusive):\n" <>
      Enum.map_join(warnings, "\n", &("  - " <> &1))
  end
end

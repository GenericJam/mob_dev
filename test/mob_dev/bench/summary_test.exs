defmodule MobDev.Bench.SummaryTest do
  use ExUnit.Case, async: true

  alias MobDev.Bench.Summary

  defp row(opts) do
    %{
      ts_ms: Keyword.get(opts, :ts_ms, 0),
      elapsed_sec: Keyword.get(opts, :elapsed_sec, 0.0),
      reachability: Keyword.get(opts, :reachability, :alive_rpc),
      app_process: Keyword.get(opts, :app_process, :app_running),
      usb: Keyword.get(opts, :usb, :usb_ok),
      screen: Keyword.get(opts, :screen, :off),
      battery_pct: Keyword.get(opts, :battery_pct, 100),
      reason: Keyword.get(opts, :reason)
    }
  end

  describe "from_rows/1 — empty" do
    test "empty list returns zero metrics" do
      m = Summary.from_rows([])
      assert m.total_samples == 0
      assert m.successful_samples == 0
      assert m.success_rate == 0.0
      assert m.start_battery == nil
      assert m.end_battery == nil
      assert m.drain_pct == nil
      assert m.taint_warnings == []
    end
  end

  describe "from_rows/1 — happy path" do
    test "all healthy 30-min run" do
      rows = [
        row(elapsed_sec: 0.0, battery_pct: 100),
        row(elapsed_sec: 600.0, battery_pct: 99),
        row(elapsed_sec: 1200.0, battery_pct: 98),
        row(elapsed_sec: 1800.0, battery_pct: 97)
      ]

      m = Summary.from_rows(rows)
      assert m.total_samples == 4
      assert m.successful_samples == 4
      assert m.success_rate == 1.0
      assert m.reconnect_count == 0
      assert m.start_battery == 100
      assert m.end_battery == 97
      assert m.drain_pct == 3
      assert m.effective_rate_pct_per_hour == 6.0
    end

    test "screen-off duration matches" do
      rows = [
        row(elapsed_sec: 0.0, screen: :off),
        row(elapsed_sec: 600.0, screen: :off),
        row(elapsed_sec: 1200.0, screen: :off),
        row(elapsed_sec: 1800.0, screen: :off)
      ]

      m = Summary.from_rows(rows)
      assert m.screen_off_duration_sec == 1800.0
      assert m.screen_on_duration_sec == 0.0
    end
  end

  describe "from_rows/1 — reconnect counting" do
    test "single drop and reconnect counts as 1 reconnect" do
      rows = [
        row(elapsed_sec: 0.0, reachability: :alive_rpc),
        row(elapsed_sec: 10.0, reachability: :alive_dist_only),
        row(elapsed_sec: 20.0, reachability: :alive_rpc)
      ]

      assert Summary.from_rows(rows).reconnect_count == 1
    end

    test "multiple drops and reconnects" do
      rows = [
        row(elapsed_sec: 0.0, reachability: :alive_rpc),
        row(elapsed_sec: 10.0, reachability: :alive_epmd_only),
        row(elapsed_sec: 20.0, reachability: :alive_rpc),
        row(elapsed_sec: 30.0, reachability: :unreachable),
        row(elapsed_sec: 40.0, reachability: :alive_rpc),
        row(elapsed_sec: 50.0, reachability: :alive_dist_only),
        row(elapsed_sec: 60.0, reachability: :alive_rpc)
      ]

      assert Summary.from_rows(rows).reconnect_count == 3
    end

    test "no reconnects in stable run" do
      rows = [
        row(elapsed_sec: 0.0, reachability: :alive_rpc),
        row(elapsed_sec: 10.0, reachability: :alive_rpc)
      ]

      assert Summary.from_rows(rows).reconnect_count == 0
    end
  end

  describe "from_rows/1 — gap analysis" do
    test "longest_gap_sec finds max interval between successful reads" do
      rows = [
        row(elapsed_sec: 0.0, battery_pct: 100),
        row(elapsed_sec: 5.0, battery_pct: 100),
        row(elapsed_sec: 30.0, battery_pct: 99),
        row(elapsed_sec: 31.0, battery_pct: 99)
      ]

      assert Summary.from_rows(rows).longest_gap_sec == 25.0
    end
  end

  describe "from_rows/1 — state duration breakdown" do
    test "tracks time spent in each reachability state" do
      rows = [
        row(elapsed_sec: 0.0, reachability: :alive_rpc),
        row(elapsed_sec: 10.0, reachability: :alive_rpc),
        row(elapsed_sec: 20.0, reachability: :alive_dist_only),
        row(elapsed_sec: 30.0, reachability: :alive_dist_only),
        row(elapsed_sec: 40.0, reachability: :alive_rpc)
      ]

      m = Summary.from_rows(rows)
      # State at row[i] applies to the gap (row[i].t .. row[i+1].t).
      # alive_rpc: 0→10 + 10→20 = 20s
      # alive_dist_only: 20→30 + 30→40 = 20s
      assert m.state_durations[:alive_rpc] == 20.0
      assert m.state_durations[:alive_dist_only] == 20.0
    end
  end

  describe "from_rows/1 — taint warnings" do
    test "warns when screen turns ON during off-screen run" do
      rows = [
        row(elapsed_sec: 0.0, screen: :off),
        row(elapsed_sec: 100.0, screen: :on)
      ]

      assert "screen turned ON during off-screen run" in Summary.from_rows(rows).taint_warnings
    end

    test "warns when app process reported dead" do
      rows = [
        row(elapsed_sec: 0.0, app_process: :app_running),
        row(elapsed_sec: 10.0, app_process: :app_dead)
      ]

      assert "app process reported as dead at some point" in Summary.from_rows(rows).taint_warnings
    end

    test "warns when majority unreachable" do
      rows = [
        row(elapsed_sec: 0.0, reachability: :unreachable),
        row(elapsed_sec: 10.0, reachability: :unreachable),
        row(elapsed_sec: 20.0, reachability: :alive_rpc)
      ]

      assert "majority of polls were :unreachable" in Summary.from_rows(rows).taint_warnings
    end

    test "warns when reconnects exceed threshold" do
      rows =
        for i <- 0..30 do
          state = if rem(i, 2) == 0, do: :alive_rpc, else: :alive_dist_only
          row(elapsed_sec: i * 1.0, reachability: state)
        end

      assert "many reconnects (>=10) — flapping connection" in Summary.from_rows(rows).taint_warnings
    end

    test "no warnings on a clean run" do
      rows = [
        row(elapsed_sec: 0.0, screen: :off, battery_pct: 100),
        row(elapsed_sec: 10.0, screen: :off, battery_pct: 99)
      ]

      assert Summary.from_rows(rows).taint_warnings == []
    end
  end

  describe "from_csv/1 — round-trip with Logger" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "summary_test_#{System.unique_integer([:positive])}.csv")

      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "reads back what Logger wrote", %{path: path} do
      log = MobDev.Bench.Logger.open(path, start_ts_ms: 0)

      log =
        log
        |> MobDev.Bench.Logger.append(%MobDev.Bench.Probe{
          ts_ms: 0,
          reachability: :alive_rpc,
          app_process: :app_running,
          usb: :usb_ok,
          screen: :off,
          battery_pct: 100,
          reason: nil
        })
        |> MobDev.Bench.Logger.append(%MobDev.Bench.Probe{
          ts_ms: 600_000,
          reachability: :alive_rpc,
          app_process: :app_running,
          usb: :usb_ok,
          screen: :off,
          battery_pct: 99,
          reason: nil
        })
        |> MobDev.Bench.Logger.append(%MobDev.Bench.Probe{
          ts_ms: 1_800_000,
          reachability: :alive_rpc,
          app_process: :app_running,
          usb: :usb_ok,
          screen: :off,
          battery_pct: 97,
          reason: nil
        })

      MobDev.Bench.Logger.close(log)

      m = Summary.from_csv(path)
      assert m.total_samples == 3
      assert m.start_battery == 100
      assert m.end_battery == 97
      assert m.drain_pct == 3
      assert m.effective_rate_pct_per_hour == 6.0
    end
  end

  describe "pretty/1" do
    test "renders the basics" do
      rows = [
        row(elapsed_sec: 0.0, battery_pct: 100),
        row(elapsed_sec: 1800.0, battery_pct: 97)
      ]

      output = Summary.pretty(Summary.from_rows(rows))
      assert output =~ "Total samples:"
      assert output =~ "Battery:"
      assert output =~ "100%"
      assert output =~ "97%"
      refute output =~ "WARNINGS"
    end

    test "includes warnings section when tainted" do
      rows = [
        row(elapsed_sec: 0.0, screen: :off),
        row(elapsed_sec: 100.0, screen: :on)
      ]

      output = Summary.pretty(Summary.from_rows(rows))
      assert output =~ "WARNINGS"
      assert output =~ "screen turned ON"
    end
  end
end

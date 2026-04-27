defmodule MobDev.Bench.LoggerTest do
  use ExUnit.Case, async: true

  alias MobDev.Bench.{Logger, Probe}

  setup do
    path = Path.join(System.tmp_dir!(), "bench_logger_#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp probe(opts \\ []) do
    %Probe{
      ts_ms: Keyword.get(opts, :ts_ms, System.monotonic_time(:millisecond)),
      reachability: Keyword.get(opts, :reachability, :alive_rpc),
      app_process: Keyword.get(opts, :app_process, :app_running),
      usb: Keyword.get(opts, :usb, :usb_ok),
      screen: Keyword.get(opts, :screen, :off),
      battery_pct: Keyword.get(opts, :battery_pct, 87),
      reason: Keyword.get(opts, :reason)
    }
  end

  describe "open/2 and close/1" do
    test "creates parent dirs and writes header", %{path: path} do
      log = Logger.open(path)
      log = Logger.close(log)

      content = File.read!(path)
      assert content =~ "ts_ms,elapsed_sec,reachability"
      assert log.file == nil
    end

    test "close is idempotent", %{path: path} do
      log = Logger.open(path)
      log = Logger.close(log)
      assert Logger.close(log).file == nil
    end

    test "creates parent dirs when missing", %{path: path} do
      nested = Path.join([Path.dirname(path), "nested", "subdir", Path.basename(path)])
      on_exit(fn -> File.rm_rf(Path.dirname(nested)) end)

      log = Logger.open(nested)
      Logger.close(log)
      assert File.exists?(nested)
    end
  end

  describe "append/2 and read/1 — round-trip" do
    test "single row round-trips", %{path: path} do
      log = Logger.open(path, start_ts_ms: 1000)

      log =
        Logger.append(
          log,
          probe(
            ts_ms: 1500,
            reachability: :alive_rpc,
            app_process: :app_running,
            usb: :usb_ok,
            screen: :off,
            battery_pct: 87
          )
        )

      Logger.close(log)
      assert log.rows == 1

      [row] = Logger.read(path)
      assert row.ts_ms == 1500
      assert row.elapsed_sec == 0.5
      assert row.reachability == :alive_rpc
      assert row.app_process == :app_running
      assert row.usb == :usb_ok
      assert row.screen == :off
      assert row.battery_pct == 87
      assert row.reason == nil
    end

    test "multiple rows preserve order and elapsed_sec", %{path: path} do
      log = Logger.open(path, start_ts_ms: 0)

      log =
        log
        |> Logger.append(probe(ts_ms: 0, battery_pct: 100))
        |> Logger.append(probe(ts_ms: 1_000, battery_pct: 99))
        |> Logger.append(probe(ts_ms: 5_000, battery_pct: 95))

      Logger.close(log)

      rows = Logger.read(path)
      assert length(rows) == 3
      assert Enum.map(rows, & &1.ts_ms) == [0, 1_000, 5_000]
      assert Enum.map(rows, & &1.elapsed_sec) == [0.0, 1.0, 5.0]
      assert Enum.map(rows, & &1.battery_pct) == [100, 99, 95]
    end

    test "battery_pct: nil renders as empty cell and parses back to nil", %{path: path} do
      log = Logger.open(path)
      log = Logger.append(log, probe(battery_pct: nil))
      Logger.close(log)

      [row] = Logger.read(path)
      assert row.battery_pct == nil

      raw = File.read!(path)
      [_header, line | _] = String.split(raw, "\n")
      assert String.contains?(line, ",,")
    end

    test "reason with comma is CSV-escaped", %{path: path} do
      log = Logger.open(path)
      log = Logger.append(log, probe(reason: "rpc, badrpc, nodedown"))
      Logger.close(log)

      [row] = Logger.read(path)
      assert row.reason == "rpc, badrpc, nodedown"
    end

    test "reason with embedded quotes is escaped", %{path: path} do
      log = Logger.open(path)
      log = Logger.append(log, probe(reason: ~S|rpc: "timeout"|))
      Logger.close(log)

      [row] = Logger.read(path)
      assert row.reason == ~S|rpc: "timeout"|
    end

    test "reason with newline is escaped", %{path: path} do
      log = Logger.open(path)
      log = Logger.append(log, probe(reason: "line1\nline2"))
      Logger.close(log)

      [row] = Logger.read(path)
      assert row.reason == "line1\nline2"
    end
  end

  describe "real-world simulation" do
    test "captures a transition from connected to disconnected to reconnected",
         %{path: path} do
      log = Logger.open(path, start_ts_ms: 0)

      events = [
        probe(ts_ms: 0, reachability: :alive_rpc, battery_pct: 100),
        probe(ts_ms: 10_000, reachability: :alive_rpc, battery_pct: 100),
        probe(ts_ms: 20_000, reachability: :alive_dist_only, battery_pct: nil,
              reason: "rpc battery: badrpc :timeout"),
        probe(ts_ms: 30_000, reachability: :alive_epmd_only, battery_pct: nil,
              reason: "dist disconnected"),
        probe(ts_ms: 40_000, reachability: :alive_rpc, battery_pct: 100,
              reason: "reconnected")
      ]

      log = Enum.reduce(events, log, &Logger.append(&2, &1))
      Logger.close(log)

      rows = Logger.read(path)
      assert length(rows) == 5
      assert Enum.map(rows, & &1.reachability) == [
               :alive_rpc, :alive_rpc, :alive_dist_only, :alive_epmd_only, :alive_rpc
             ]
      assert Enum.at(rows, 2).reason == "rpc battery: badrpc :timeout"
    end
  end
end

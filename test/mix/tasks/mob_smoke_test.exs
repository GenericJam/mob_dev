defmodule Mix.Tasks.Mob.SmokeTest do
  @moduledoc """
  `mix mob.smoke` driven end to end with a fake agent-device, discovery and
  RPC: the verdict has to come from what those return, not from the exit code.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mob.Smoke, as: SmokeTask
  alias MobDev.Device

  @moduletag :tmp_dir

  @emulator %Device{
    platform: :android,
    serial: "emulator-5554",
    name: "Pixel 8",
    type: :emulator,
    node: :"app_android_emulator_5554@127.0.0.1"
  }

  @no_claims ~S({"success": true, "data": {"claims": [], "hiddenStaleClaims": 0}})

  @claimed ~S"""
  {"success": true, "data": {"claims": [{
    "deviceKey": "local:android:none:emulator-5554", "classification": "live",
    "device": {"id": "emulator-5554", "platform": "android"},
    "owner": {"session": "rec", "workspace": "/Users/k/code/app", "stateDir": "/s", "pid": 1}}]}}
  """

  @passing ~S"""
  {"success": true, "data": {"total": 1, "executed": 1, "passed": 1, "failed": 0, "skipped": 0,
   "notRun": 0, "durationMs": 9000, "failures": [], "tests": [], "artifactsDir": "/a"}}
  """

  @failing ~S"""
  {"success": true, "data": {"total": 1, "executed": 1, "passed": 0, "failed": 1, "skipped": 0,
   "notRun": 0, "durationMs": 9000, "artifactsDir": "/a", "tests": [],
   "failures": [{"file": "/p/smoke/login.ad", "status": "failed", "attempts": 1,
     "artifactsDir": "/a/login",
     "error": {"code": "COMMAND_FAILED", "message": "Element not found", "hint": "Re-record"}}]}}
  """

  setup %{tmp_dir: dir} do
    flows = Path.join(dir, "smoke")
    File.mkdir_p!(flows)
    File.write!(Path.join(flows, "a_home.ad"), ~s(open "com.example.app" --relaunch\n))
    File.write!(Path.join(flows, "b_login.ad"), ~s(open "com.example.app" --relaunch\n))
    %{flows: flows, args: ["--flows", flows, "--artifacts-dir", Path.join(dir, "artifacts")]}
  end

  defp health(lost, recorded) do
    %{
      heir: :pid,
      subscribers: %{process: :pid, topics: 1, parked: 0},
      listener: %{process: :pid, undeliverable: 0},
      stores: %{
        Mob.Store.Notes => %{owner: :pid, lost: lost, resets: 0, owner_starts: 1},
        Mob.Agent.Receipts => %{lost: 0, resets: 0, store: %{recorded: recorded, evicted: 0}}
      }
    }
  end

  # `snapshots` is the {health, os pid} the app answers with before the first
  # flow and after each one, in order. `reports` maps a flow's file name to the
  # report its `agent-device test` run prints.
  defp deps(status_json, reports, snapshots) do
    test = self()
    {:ok, queue} = Agent.start_link(fn -> snapshots end)

    %{
      find_executable: fn "agent-device" -> "/opt/homebrew/bin/agent-device" end,
      discover: fn _platforms -> [@emulator] end,
      connect: fn devices, _cookie -> Map.new(devices, &{&1.serial, &1.node}) end,
      await_node: fn _device, node, _cookie -> node end,
      cmd: fn _exe, argv ->
        send(test, {:cmd, argv})

        case argv do
          ["device", "status", "--json"] ->
            {status_json, 0}

          ["test", script | _] ->
            report = Map.get(reports, Path.basename(script), @passing)
            {report, if(report == @passing, do: 0, else: 1)}
        end
      end,
      rpc: fn
        _node, Mob.Diag, :health, [] ->
          Agent.get(queue, fn [{health, _} | _] -> health end)

        _node, :os, :getpid, [] ->
          Agent.get_and_update(queue, fn [{_, pid} | rest] -> {pid, rest} end)
      end
    }
  end

  defp clean, do: [{health(0, 5), ~c"1"}, {health(0, 7), ~c"1"}, {health(0, 9), ~c"1"}]

  defp run_task(args, deps),
    do: capture_io(fn -> send(self(), {:result, SmokeTask.run(args, deps)}) end)

  defp test_runs do
    Stream.repeatedly(fn ->
      receive do
        {:cmd, ["test" | _] = argv} -> argv
        {:cmd, _other} -> :status
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.reject(&(&1 == :status))
  end

  test "clean flows with clean health pass, one agent-device run per flow", %{
    args: args,
    flows: flows
  } do
    output = run_task(args, deps(@no_claims, %{}, clean()))

    assert_received {:result, :ok}

    assert [
             ["test", first, "--serial", "emulator-5554", "--json", "--artifacts-dir", dir | _],
             ["test", second | _]
           ] = test_runs()

    assert {first, second} == {Path.join(flows, "a_home.ad"), Path.join(flows, "b_login.ad")}
    assert String.ends_with?(dir, "artifacts/emulator-5554/a_home")
    assert output =~ "b_login.ad: receipts +2"
  end

  test "a claimed device is skipped, never tested, and fails the run", %{args: args} do
    assert_raise Mix.Error,
                 ~r/blocked, in use by session rec \(workspace \/Users\/k\/code\/app\)/,
                 fn -> run_task(args, deps(@claimed, %{}, clean())) end

    assert test_runs() == []
  end

  test "a failing report fails the run and prints the failure", %{args: args} do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/1 flow\(s\) failed/, fn ->
          SmokeTask.run(args, deps(@no_claims, %{"b_login.ad" => @failing}, clean()))
        end
      end)

    assert output =~ "/p/smoke/login.ad [COMMAND_FAILED] Element not found"
    assert output =~ "artifacts: /a/login"
  end

  test "--fail-fast stops at the first failing flow and counts the rest as not run", %{
    args: args
  } do
    assert_raise Mix.Error, ~r/1 flow\(s\) failed\n  emulator-5554: 1 flow\(s\) not run/, fn ->
      run_task(["--fail-fast" | args], deps(@no_claims, %{"a_home.ad" => @failing}, clean()))
    end

    assert [["test", _ | _]] = test_runs()
  end

  test "--fail-fast halts on a health failure even when the replay passed", %{args: args} do
    snapshots = [{health(0, 5), ~c"1"}, {health(1, 7), ~c"1"}, {health(1, 9), ~c"1"}]

    assert_raise Mix.Error, ~r/a_home.ad: Mob.Store.Notes: lost 0 → 1/, fn ->
      run_task(["--fail-fast" | args], deps(@no_claims, %{}, snapshots))
    end

    assert [["test", first | _]] = test_runs()
    assert Path.basename(first) == "a_home.ad"
  end

  test "a store loss during a flow fails the run, naming the flow", %{args: args} do
    snapshots = [{health(0, 5), ~c"1"}, {health(1, 7), ~c"1"}, {health(1, 9), ~c"1"}]

    assert_raise Mix.Error, ~r/a_home.ad: Mob.Store.Notes: lost 0 → 1/, fn ->
      run_task(args, deps(@no_claims, %{}, snapshots))
    end
  end

  test "a loss in a relaunched BEAM is caught even though its count is below the old one", %{
    args: args
  } do
    # Old BEAM had lost 3; each flow relaunches. The second BEAM loses 1.
    snapshots = [{health(3, 5), ~c"1"}, {health(0, 2), ~c"2"}, {health(1, 4), ~c"3"}]

    assert_raise Mix.Error, ~r/b_login.ad: Mob.Store.Notes: lost 0 → 1/, fn ->
      run_task(args, deps(@no_claims, %{}, snapshots))
    end
  end

  test "a node that does not come back after a flow is a warning naming the flow", %{
    args: args
  } do
    deps = %{deps(@no_claims, %{}, [{health(0, 5), ~c"1"}]) | await_node: fn _, _, _ -> nil end}

    output = run_task(args, deps)

    assert_received {:result, :ok}
    assert output =~ "warning: a_home.ad: health unavailable after the flow: node not reachable"
  end

  test "old mob without Mob.Diag passes with a note", %{args: args} do
    undef = {:badrpc, {:EXIT, {:undef, [{Mob.Diag, :health, [], []}]}}}
    output = run_task(args, deps(@no_claims, %{}, List.duplicate({undef, ~c"1"}, 3)))

    assert_received {:result, :ok}
    assert output =~ "health check skipped: Mob.Diag.health/0 is not on the device"
  end

  test "--no-health runs the flows as one suite and never touches dist", %{
    args: args,
    flows: flows
  } do
    no_dist = %{
      deps(@no_claims, %{}, [])
      | connect: fn _, _ -> flunk("connected") end,
        rpc: fn _, _, _, _ -> flunk("called rpc") end
    }

    run_task(["--no-health", "--fail-fast" | args], no_dist)

    assert_received {:result, :ok}
    assert [["test", glob | rest]] = test_runs()
    assert glob == Path.join(flows, "*.ad")
    assert List.last(rest) == "--fail-fast"
  end

  test "no flows raises with the recording recipe", %{tmp_dir: dir} do
    assert_raise Mix.Error, ~r/--save-script "\$PWD\/empty\/<name>.ad"/, fn ->
      File.cd!(dir, fn ->
        File.mkdir_p!("empty")
        SmokeTask.run(["--flows", "empty"], deps(@no_claims, %{}, []))
      end)
    end
  end

  test "a missing agent-device raises with the install hint", %{args: args} do
    missing = %{deps(@no_claims, %{}, []) | find_executable: fn _ -> nil end}

    assert_raise Mix.Error, ~r/npm i -g agent-device/, fn -> SmokeTask.run(args, missing) end
  end
end

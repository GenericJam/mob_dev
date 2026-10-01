defmodule MobDev.SmokeTest do
  use ExUnit.Case, async: true

  alias MobDev.{Device, Smoke}

  @android %Device{platform: :android, serial: "emulator-5554", type: :emulator}
  @iphone %Device{platform: :ios, serial: "00008110-001A2C3E0E8B801E", type: :physical}
  @simulator %Device{
    platform: :ios,
    serial: "1F8955AE-2BD3-440D-9831-2025E1402FD2",
    type: :simulator
  }

  # The shape agent-device 0.21.1 prints when a script fails: top-level
  # "success" is still true.
  @failing_report ~S"""
  {
    "success": true,
    "data": {
      "total": 3, "executed": 3, "passed": 2, "failed": 1, "skipped": 0, "notRun": 0,
      "durationMs": 41250,
      "failures": [
        {
          "file": "/p/smoke/login.ad",
          "status": "failed",
          "attempts": 2,
          "artifactsDir": "/p/_build/mob_smoke/emulator-5554/login",
          "error": {
            "code": "COMMAND_FAILED",
            "message": "Android snapshot helper output could not be parsed",
            "hint": "Retry the snapshot."
          }
        }
      ],
      "tests": [
        {"file": "/p/smoke/home.ad", "status": "passed", "durationMs": 9000, "attempts": 1,
         "artifactsDir": "/p/_build/mob_smoke/emulator-5554/home", "replayed": true, "healed": false}
      ],
      "artifactsDir": "/p/_build/mob_smoke/emulator-5554"
    }
  }
  """

  @cli_error ~S"""
  {
    "success": false,
    "error": {
      "code": "INVALID_ARGS",
      "message": "No replay tests matched.",
      "hint": "Check command arguments and run --help for usage examples.",
      "diagnosticId": "muozkxur-5e37262a"
    }
  }
  """

  # agent-device 0.21.1 replaying a flow recorded on an iOS simulator: the
  # selector still matches, the recorded identity (ancestry) does not.
  @identity_report ~S"""
  {
    "success": true,
    "data": {
      "total": 1, "executed": 1, "passed": 0, "failed": 1, "skipped": 0, "notRun": 0,
      "durationMs": 3381,
      "failures": [
        {
          "file": "/p/smoke/dice.ad",
          "status": "failed",
          "attempts": 1,
          "artifactsDir": "/p/_build/mob_smoke/sim/dice",
          "error": {
            "code": "REPLAY_DIVERGENCE",
            "message": "Replay failed at step 3 (press \"id=\\\"open_dice\\\" || label=\\\"Roll Dice\\\"\"): The recorded selector/ref still matches, but nothing in the current tree carries the recorded identity.",
            "details": {
              "step": 3,
              "action": "press",
              "divergence": {
                "version": 1,
                "kind": "identity-mismatch",
                "cause": {
                  "code": "IDENTITY_MISMATCH",
                  "message": "The recorded selector/ref still matches, but nothing in the current tree carries the recorded identity."
                },
                "targetBinding": {
                  "classification": "identity-mismatch",
                  "mismatches": ["ancestry[0]: recorded=scrollview observed=other/☀️"]
                }
              }
            }
          }
        }
      ]
    }
  }
  """

  @claims ~S"""
  {
    "success": true,
    "data": {
      "claims": [
        {
          "deviceKey": "local:android:none:emulator-5556",
          "classification": "live",
          "device": {"id": "emulator-5556", "platform": "android"},
          "owner": {"session": "rec", "workspace": "/Users/k/code/app", "stateDir": "/tmp/s", "pid": 4242}
        },
        {
          "deviceKey": "local:apple:ios:00008110-001A2C3E0E8B801E",
          "classification": "live",
          "device": {"id": "00008110-001A2C3E0E8B801E", "platform": "ios"},
          "owner": {"session": "default", "workspace": "/Users/k/other", "stateDir": "/tmp/t", "pid": 7}
        }
      ],
      "hiddenStaleClaims": 0
    }
  }
  """

  defp ran(report_overrides, status \\ 0) do
    {:ran,
     Map.merge(
       Smoke.merge_reports([]),
       Map.merge(%{total: 1, executed: 1, passed: 1}, report_overrides)
     ), status}
  end

  defp result(outcome, findings \\ []),
    do: %{device: "emulator-5554", outcome: outcome, findings: findings, receipts_delta: nil}

  describe "parse_report/1" do
    test "a report with failures is a report, not a success" do
      assert {:ok, report} = Smoke.parse_report(@failing_report)

      assert %{total: 3, executed: 3, passed: 2, failed: 1, not_run: 0, duration_ms: 41_250} =
               report

      assert [
               %{
                 file: "/p/smoke/login.ad",
                 attempts: 2,
                 code: "COMMAND_FAILED",
                 artifacts_dir: "/p/_build/mob_smoke/emulator-5554/login",
                 hint: "Retry the snapshot."
               }
             ] = report.failures

      assert Smoke.verdict([result({:ran, report, 1})]) ==
               {:error, ["emulator-5554: 1 flow(s) failed"]}
    end

    test "a CLI error is returned as one" do
      assert Smoke.parse_report(@cli_error) ==
               {:error,
                %{
                  code: "INVALID_ARGS",
                  message: "No replay tests matched.",
                  hint: "Check command arguments and run --help for usage examples."
                }}
    end

    test "output that is not JSON is an error naming what was printed" do
      assert {:error, %{message: message}} = Smoke.parse_report("npm WARN something")
      assert message =~ "npm WARN something"
    end
  end

  describe "reports across per-flow runs" do
    test "a refused run counts as a flow not run and names the refusal" do
      {:error, error} = Smoke.parse_report(@cli_error)
      report = Smoke.refused_report("/p/smoke/a.ad", error)

      assert Smoke.verdict([result({:ran, report, 1})]) ==
               {:error,
                [
                  "emulator-5554: agent-device refused: No replay tests matched.",
                  "emulator-5554: 1 flow(s) not run",
                  "emulator-5554: no flows executed"
                ]}
    end

    test "merging sums the counts and keeps every failure" do
      {:ok, failing} = Smoke.parse_report(@failing_report)
      {:ran, passing, 0} = ran(%{duration_ms: 50})

      merged = Smoke.merge_reports([failing, passing, Smoke.not_run_report(2)])

      assert %{total: 6, executed: 4, passed: 3, failed: 1, not_run: 2, duration_ms: 41_300} =
               merged

      assert [%{file: "/p/smoke/login.ad"}] = merged.failures
    end
  end

  describe "verdict/1" do
    test "a clean run passes" do
      assert Smoke.verdict([result(ran(%{}))]) == :ok
    end

    test "flows that did not run fail even with zero failures" do
      assert Smoke.verdict([result(ran(%{executed: 1, not_run: 2}))]) ==
               {:error, ["emulator-5554: 2 flow(s) not run"]}

      assert Smoke.verdict([result(ran(%{executed: 0, passed: 0}))]) ==
               {:error, ["emulator-5554: no flows executed"]}
    end

    test "a non-zero exit with a clean report still fails" do
      assert Smoke.verdict([result(ran(%{}, 2))]) ==
               {:error, ["emulator-5554: agent-device exited 2"]}
    end

    test "blocked devices and failure findings fail; warnings and notes do not" do
      assert Smoke.verdict([result({:blocked, "in use by session rec (workspace /w)"})]) ==
               {:error, ["emulator-5554: blocked, in use by session rec (workspace /w)"]}

      assert Smoke.verdict([result(ran(%{}), [{:failure, "store lost"}])]) ==
               {:error, ["emulator-5554: store lost"]}

      assert Smoke.verdict([result(ran(%{}), [{:warning, "w"}, {:note, "n"}])]) == :ok
    end

    test "no devices is not a pass" do
      assert Smoke.verdict([]) == {:error, ["no device was smoke-tested"]}
    end
  end

  describe "find_claim/2" do
    test "names the session and workspace holding the device" do
      assert {:ok, claim} = Smoke.find_claim(@claims, "emulator-5556")
      assert claim.session == "rec"
      assert Smoke.claim_message(claim) == "in use by session rec (workspace /Users/k/code/app)"
    end

    test "matches iOS UDIDs regardless of case" do
      assert {:ok, %{session: "default"}} =
               Smoke.find_claim(@claims, "00008110-001a2c3e0e8b801e")
    end

    test "an unclaimed device, and a prefix of a claimed id, are free" do
      assert Smoke.find_claim(@claims, "emulator-5554") == {:ok, nil}
      assert Smoke.find_claim(@claims, "emulator-555") == {:ok, nil}
    end

    test "an unreadable status is an error, not a free device" do
      assert {:error, "agent-device device status did not print a claims report"} =
               Smoke.find_claim("", "emulator-5554")

      assert {:error, "No replay tests matched."} = Smoke.find_claim(@cli_error, "emulator-5554")
    end
  end

  describe "test_argv/3 and run_paths/4" do
    test "a suite run addresses the device and gets its own artifacts directory" do
      paths = Smoke.run_paths("/p/_build/mob_smoke", nil, "emulator-5554", nil)

      assert Smoke.test_argv("/p/smoke/*.ad", ["--serial", "emulator-5554"],
               artifacts_dir: paths.artifacts_dir,
               junit: paths.junit
             ) ==
               ~w(test /p/smoke/*.ad --serial emulator-5554 --json --artifacts-dir /p/_build/mob_smoke/emulator-5554 --retries 0)
    end

    test "a per-flow run gets a directory and JUnit file of its own" do
      paths = Smoke.run_paths("/a", "/p/out/smoke.xml", "emulator-5554", "/p/smoke/login.ad")

      assert paths == %{
               artifacts_dir: "/a/emulator-5554/login",
               junit: "/p/out/smoke-emulator-5554-login.xml"
             }

      assert Smoke.run_paths("/a", "/p/out/smoke", "emulator-5554", nil).junit ==
               "/p/out/smoke-emulator-5554"
    end

    test "names that need rewriting cannot collide with ones that did not" do
      spaced = Smoke.run_paths("/a", "/j.xml", "10.0.0.17:5555", "/p/smoke/log in.ad")
      plain = Smoke.run_paths("/a", "/j.xml", "10.0.0.17:5555", "/p/smoke/log_in.ad")

      assert spaced.artifacts_dir =~ ~r"^/a/10\.0\.0\.17_5555-[0-9A-F]+/log_in-[0-9A-F]+$"
      assert plain.artifacts_dir =~ ~r"/log_in$"
      refute spaced.junit == plain.junit
    end

    test "passes retries, junit and fail-fast" do
      argv =
        Smoke.test_argv("/p/smoke/a.ad", ["--udid", "U"],
          artifacts_dir: "/a",
          junit: "/j.xml",
          retries: 2,
          fail_fast: true
        )

      assert Enum.drop(argv, 7) == ~w(--retries 2 --reporter junit:/j.xml --fail-fast)
    end

    test "zero retries is passed, so a script's own `context retries=` cannot win" do
      assert Enum.drop(Smoke.test_argv("/s", [], artifacts_dir: "/a", retries: 0), 5) ==
               ~w(--retries 0)

      assert Enum.drop(Smoke.test_argv("/s", [], artifacts_dir: "/a"), 5) == ~w(--retries 0)
    end
  end

  describe "device_target/1" do
    test "Android by serial, iOS by UDID" do
      assert Smoke.device_target(@android) == {:ok, ["--serial", "emulator-5554"]}
      assert Smoke.device_target(@iphone) == {:ok, ["--udid", "00008110-001A2C3E0E8B801E"]}
    end

    test "an iPhone known only by IP cannot be addressed" do
      assert {:error, message} =
               Smoke.device_target(%Device{platform: :ios, serial: "10.0.0.120", type: :physical})

      assert message =~ "UDID"
    end
  end

  describe "failure_hints/2" do
    test "the UiAutomation conflict names the command that stops mobile-mcp" do
      {:ok, %{failures: [failure]}} = Smoke.parse_report(@failing_report)

      assert Smoke.failure_hints(failure, @android) == [
               "Retry the snapshot.",
               "another UiAutomation client (mobile-mcp's DeviceServer) holds the device; " <>
                 "stop it with: adb -s emulator-5554 shell pkill -f mobilecli.DeviceServer"
             ]
    end

    test "other failures, and iOS, keep only agent-device's hint" do
      failure = %{message: "Element not found", cause: nil, hint: nil}
      assert Smoke.failure_hints(failure, @android) == []

      conflict = %{
        message: "Android snapshot helper output could not be parsed",
        cause: nil,
        hint: "h"
      }

      assert Smoke.failure_hints(conflict, @iphone) == ["h"]
    end

    test "a simulator identity mismatch names the identity lines to delete in that flow" do
      {:ok, %{failures: [failure]}} = Smoke.parse_report(@identity_report)
      assert failure.cause == "IDENTITY_MISMATCH"

      assert [hint] = Smoke.failure_hints(failure, @simulator)
      assert hint =~ "SwiftUI scroll views"

      assert String.ends_with?(
               hint,
               "sed -i '' '/^# agent-device:target-v1 /d' '/p/smoke/dice.ad'"
             )
    end

    test "the identity hint's path survives a shell whatever it contains" do
      {:ok, %{failures: [failure]}} = Smoke.parse_report(@identity_report)
      failure = %{failure | file: "/p/my app/it's $(x).ad"}

      assert [hint] = Smoke.failure_hints(failure, @simulator)
      assert String.ends_with?(hint, ~S"/d' '/p/my app/it'\''s $(x).ad'")
    end

    test "the identity hint is for simulators only, and only for an identity mismatch" do
      {:ok, %{failures: [failure]}} = Smoke.parse_report(@identity_report)

      # agent-device reads a physical iPhone through XCTest only (its README).
      assert Smoke.failure_hints(failure, @iphone) == []
      assert Smoke.failure_hints(failure, @android) == []
      assert Smoke.failure_hints(%{failure | cause: "SELECTOR_MISS"}, @simulator) == []
    end
  end

  describe "classify_reply/1" do
    test "sorts RPC replies" do
      assert Smoke.classify_reply(%{heir: :x}) == {:ok, %{heir: :x}}
      assert Smoke.classify_reply({:badrpc, :nodedown}) == {:unreachable, "node not reachable"}

      assert Smoke.classify_reply({:badrpc, {:EXIT, {:undef, [{Mob.Diag, :health, [], []}]}}}) ==
               {:unsupported, "Mob.Diag.health/0 is not on the device"}

      assert {:error, ":timeout"} = Smoke.classify_reply({:badrpc, :timeout})
    end
  end

  @store Mob.Store.Notes

  # The shape `Mob.Diag.health/0` returns (mob 0.9.7), trimmed to what is read.
  defp health(lost, resets, undeliverable, recorded \\ 0) do
    %{
      heir: :pid,
      subscribers: %{process: :pid, topics: 3, parked: 0},
      listener: %{process: :pid, undeliverable: undeliverable},
      stores: %{
        @store => %{owner: :pid, lost: lost, resets: resets, owner_starts: 1, tables: []},
        Mob.Agent.Receipts => %{
          owner: :pid,
          lost: 0,
          resets: 0,
          owner_starts: 1,
          tables: [],
          store: %{recorded: recorded, evicted: max(recorded - 256, 0)}
        }
      }
    }
  end

  defp snap(health, beam \\ ~c"4242"), do: %{health: {:ok, health}, beam: {:ok, beam}}

  @unreachable %{
    health: {:unreachable, "node not reachable"},
    beam: {:unreachable, "node not reachable"}
  }

  describe "health_findings/2" do
    test "unchanged counters find nothing" do
      assert Smoke.health_findings(snap(health(1, 2, 3)), snap(health(1, 2, 3))) == []
    end

    test "a rise in lost, resets or undeliverable is a failure" do
      assert Smoke.health_findings(snap(health(0, 0, 0)), snap(health(2, 1, 4))) == [
               {:failure, "Mob.Store.Notes: lost 0 → 2"},
               {:failure, "Mob.Store.Notes: resets 0 → 1"},
               {:failure, "listener: undeliverable 0 → 4"}
             ]
    end

    test "after a relaunch the new BEAM's counters are compared from zero" do
      # The old BEAM had lost 2; the relaunched one lost 1 during the flow.
      # Compared against the old baseline that loss would be invisible.
      assert Smoke.health_findings(snap(health(2, 0, 0)), snap(health(1, 0, 0), ~c"5151")) == [
               {:note, "the app restarted during a flow; its counters are compared from zero"},
               {:failure, "Mob.Store.Notes: lost 0 → 1"}
             ]
    end

    test "a store first seen after the flow counts from zero" do
      before = %{health(0, 0, 0) | stores: %{}}

      assert [{:failure, "Mob.Store.Notes: lost 0 → 1"}] =
               Smoke.health_findings(snap(before), snap(health(1, 0, 0)))
    end

    test "mob without the listener section (< 0.9.7) is a note" do
      old = Map.delete(health(0, 0, 0), :listener)

      assert Smoke.health_findings(snap(old), snap(old)) == [
               {:note,
                "listener not reported (needs mob >= 0.9.7); undeliverable events not checked"}
             ]
    end

    test "no baseline skips the check with a note" do
      assert [{:note, "health check skipped: node not reachable"}] =
               Smoke.health_findings(@unreachable, snap(health(9, 9, 9)))

      undef = Smoke.classify_reply({:badrpc, {:EXIT, {:undef, [{Mob.Diag, :health, [], []}]}}})

      assert [{:note, "health check skipped: Mob.Diag.health/0 is not on the device" <> _}] =
               Smoke.health_findings(%{health: undef, beam: {:ok, ~c"1"}}, snap(health(9, 9, 9)))
    end

    test "health unavailable after a flow is a warning, not a pass" do
      assert Smoke.health_findings(snap(health(0, 0, 0)), @unreachable) ==
               [{:warning, "health unavailable after the flow: node not reachable"}]
    end
  end

  describe "receipts" do
    test "the delta comes from the cumulative recorded counter" do
      # count/0 would read 256 both times here: the table is full.
      assert Smoke.receipts_delta(snap(health(0, 0, 0, 900)), snap(health(0, 0, 0, 912))) == 12

      assert Smoke.receipt_findings(snap(health(0, 0, 0, 900)), snap(health(0, 0, 0, 912)), 1) ==
               []
    end

    test "a relaunched BEAM's recorded count is the delta" do
      assert Smoke.receipts_delta(snap(health(0, 0, 0, 900)), snap(health(0, 0, 0, 7), ~c"9")) ==
               7
    end

    test "no new receipts while the flow executed is a warning" do
      assert Smoke.receipt_findings(snap(health(0, 0, 0, 10)), snap(health(0, 0, 0, 10)), 1) ==
               [{:warning, "the flow did not reach the app (no new receipts)"}]

      assert Smoke.receipt_findings(snap(health(0, 0, 0, 10)), snap(health(0, 0, 0, 10)), 0) == []
    end

    test "a fresh app's receipt store with no state yet counts as zero recorded" do
      # Seen on a Moto G 2024: before its first write the store's entry has
      # owner/lost/resets/tables but no `store` key.
      fresh =
        update_in(health(0, 0, 0).stores[Mob.Agent.Receipts], &Map.delete(&1, :store))

      assert Smoke.receipts_delta(snap(fresh), snap(health(0, 0, 0, 3))) == 3
      assert Smoke.receipt_findings(snap(fresh), snap(health(0, 0, 0, 3)), 1) == []

      assert Smoke.receipt_findings(snap(fresh), snap(fresh), 1) ==
               [{:warning, "the flow did not reach the app (no new receipts)"}]
    end

    test "before mob 0.9.7 (no listener section) no new receipts is a note, not a warning" do
      # Native taps were not receipted until mob 0.9.7, so a working flow on an
      # older app also leaves none (release review, codex).
      old = Map.delete(health(0, 0, 0, 10), :listener)

      assert Smoke.receipt_findings(snap(old), snap(old), 1) ==
               [{:note, "reach not checked: mob < 0.9.7 records no receipts for native taps"}]
    end

    test "health without the receipt store's entry (older mob) is a note" do
      old = update_in(health(0, 0, 0).stores, &Map.delete(&1, Mob.Agent.Receipts))

      assert Smoke.receipts_delta(snap(old), snap(health(0, 0, 0, 3))) == nil

      assert Smoke.receipt_findings(snap(old), snap(old), 1) ==
               [
                 {:note,
                  "receipts not counted: Mob.Diag.health/0 reports no Mob.Agent.Receipts recorded"}
               ]
    end

    test "an unreadable receipt store is not counted as zero" do
      stale = put_in(health(0, 0, 0).stores[Mob.Agent.Receipts][:store], :stale)
      assert Smoke.receipts_delta(snap(stale), snap(health(0, 0, 0, 3))) == nil
    end
  end

  test "summary shows counts, health and status per device" do
    lines =
      Smoke.summary_lines([
        result(ran(%{passed: 2, failed: 1, total: 3, executed: 3})),
        %{result({:blocked, "in use"}) | device: "emulator-5556"}
      ])

    assert lines == [
             "device         passed  failed  not run  health                      status",
             "emulator-5554  2       1       0        0 failure(s), 0 warning(s)  FAILED",
             "emulator-5556  -       -       -        0 failure(s), 0 warning(s)  BLOCKED"
           ]
  end

  describe "unchecked health" do
    defp checked(flows, unchecked),
      do:
        Map.put(result(ran(%{passed: flows, total: flows, executed: flows})), :health, %{
          flows: flows,
          unchecked: unchecked
        })

    test "a device whose flows were never checked says so and claims nothing" do
      results = [checked(2, ["node not reachable", "node not reachable"])]

      assert Smoke.verdict(results) == :ok

      assert Smoke.summary_lines(results) == [
               "device         passed  failed  not run  health                            status",
               "emulator-5554  2       0       0        not checked (node not reachable)  ok"
             ]

      assert Smoke.passed_line(results) ==
               "All flows passed; app health not checked on:\n  emulator-5554: node not reachable"
    end

    test "partly checked devices count what was checked and name the rest" do
      results = [
        checked(3, ["node not reachable"]),
        %{checked(2, []) | device: "emulator-5556"}
      ]

      assert [_, partial, full] = Smoke.summary_lines(results)

      assert partial =~
               "0 failure(s), 0 warning(s); 1 of 3 flow(s) not checked (node not reachable)  ok"

      assert full =~ ~r/^emulator-5556 .* 0 failure\(s\), 0 warning\(s\) +ok$/

      assert Smoke.passed_line(results) ==
               "All flows passed; app health not checked on:\n" <>
                 "  emulator-5554: 1 of 3 flow(s) not checked (node not reachable)"
    end

    test "every flow checked, or health off, is the plain pass" do
      assert Smoke.passed_line([checked(2, [])]) == "All flows passed and the app held up."
      assert Smoke.passed_line([result(ran(%{}))]) == "All flows passed and the app held up."
    end

    test "a flow is unchecked when either snapshot around it did not read" do
      ok = snap(health(0, 0, 0))
      assert Smoke.unchecked_reason(@unreachable, ok) == "node not reachable"
      assert Smoke.unchecked_reason(ok, @unreachable) == "node not reachable"
      assert Smoke.unchecked_reason(ok, ok) == nil
    end
  end

  test "the no-flows message carries the recording recipe with an absolute path" do
    message = Smoke.no_flows_message("smoke")
    assert message =~ "No smoke flows (*.ad) in smoke/."
    assert message =~ ~S(--save-script "$PWD/smoke/<name>.ad")
    assert message =~ "--relaunch"
  end
end

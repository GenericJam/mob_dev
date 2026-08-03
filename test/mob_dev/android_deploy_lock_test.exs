defmodule MobDev.AndroidDeployLockTest do
  use ExUnit.Case, async: true

  alias MobDev.AndroidDeployLock

  @bundle "com.example.casein"
  @owner "ownerproof000001"

  test "preflights the exact sorted set before acquiring any target" do
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn args ->
      Agent.update(commands, &[args | &1])
      {"", 0}
    end

    assert {:ok, lease} =
             AndroidDeployLock.acquire(@bundle, ["serial-b", "serial-a"], runner, owner: @owner)

    assert lease == held_lease(["serial-a", "serial-b"])
    assert AndroidDeployLock.valid?(lease)
    assert AndroidDeployLock.valid?(lease, :acquired)
    refute AndroidDeployLock.valid?(lease, :native_ready)

    history = Agent.get(commands, &Enum.reverse/1)
    assert Enum.map(Enum.take(history, 2), &Enum.at(&1, 1)) == ["serial-a", "serial-b"]
    assert Enum.all?(Enum.take(history, 2), &(List.last(&1) =~ "sh -c 'set -e; test ! -e"))
    refute Enum.any?(Enum.take(history, 2), &mutation?/1)
    assert Enum.map(Enum.drop(history, 2), &Enum.at(&1, 1)) == ["serial-a", "serial-b"]
    assert Enum.all?(Enum.drop(history, 2), &mutation?/1)

    record = expected_record(lease)

    assert Enum.all?(Enum.drop(history, 2), fn args ->
             List.last(args) =~ ~s(printf %s "#{record}")
           end)
  end

  test "a known block on the later target causes zero mutation on every target" do
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn ["-s", serial, "shell", _command] = args ->
      Agent.update(commands, &[args | &1])
      if serial == "serial-b", do: {"blocked", 1}, else: {"", 0}
    end

    assert {:error,
            %{
              phase: :preflight,
              reason: :lease_present_or_ambiguous,
              serial: "serial-b",
              lease: %{state: :not_acquired}
            }} =
             AndroidDeployLock.acquire(@bundle, ["serial-b", "serial-a"], runner, owner: @owner)

    refute Agent.get(commands, & &1) |> Enum.any?(&mutation?/1)
  end

  test "an exception after a later acquire mutation retains the full identity and halts" do
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn ["-s", serial, "shell", command] = args ->
      Agent.update(commands, &[args | &1])

      if serial == "serial-b" and String.contains?(command, "mkdir ") do
        raise "transport lost after write"
      else
        {"", 0}
      end
    end

    assert {:error,
            %{
              phase: :acquire,
              reason: :acquire_ambiguous,
              serial: "serial-b",
              affected_serials: ["serial-a", "serial-b"],
              lease: %{state: :retained_ambiguous} = retained
            }} =
             AndroidDeployLock.acquire(@bundle, ["serial-b", "serial-a"], runner, owner: @owner)

    assert retained.serials == ["serial-a", "serial-b"]
    assert retained.target_digest == target_digest(retained.serials)
    refute AndroidDeployLock.valid?(retained)
    refute Agent.get(commands, & &1) |> Enum.any?(&cleanup?/1)
  end

  test "owner proof binds owner, exact target digest, and phase" do
    one_target = held_lease(["serial-a"])
    two_targets = held_lease(["serial-a", "serial-b"])

    assert :ok =
             AndroidDeployLock.verify_owner(one_target, "serial-a", fn
               ["-s", "serial-a", "shell", command] ->
                 assert command =~ "wc -c"
                 assert command =~ ".mob_native_deploy_releasing_*"
                 {expected_record(one_target), 0}
             end)

    assert {:error, %{reason: :record_mismatch}} =
             AndroidDeployLock.verify_owner(two_targets, "serial-a", fn _args ->
               {expected_record(one_target), 0}
             end)

    assert {:error, %{reason: :record_mismatch}} =
             AndroidDeployLock.verify_owner(one_target, "serial-a", fn _args ->
               {expected_record(one_target, :native_ready), 0}
             end)

    assert {:error, %{reason: :record_mismatch}} =
             AndroidDeployLock.verify_owner(one_target, "serial-a", fn _args ->
               {expected_record(one_target) <> "\n", 0}
             end)
  end

  test "transition preflights the full set and writes the next exact phase" do
    lease = held_lease(["serial-a", "serial-b"])
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn args ->
      Agent.update(commands, &[args | &1])
      command = List.last(args)

      if fixed_record_proof?(command), do: {expected_record(lease), 0}, else: {"", 0}
    end

    assert {:ok, transitioned} =
             AndroidDeployLock.transition(lease, :acquired, :native_ready, runner)

    assert transitioned.phase == :native_ready
    assert transitioned.state == :held_success
    assert AndroidDeployLock.valid?(transitioned, :native_ready)

    history = Agent.get(commands, &Enum.reverse/1)
    assert Enum.all?(Enum.take(history, 2), &fixed_record_proof?(List.last(&1)))

    transition_commands = Enum.drop(history, 2)
    assert Enum.map(transition_commands, &Enum.at(&1, 1)) == ["serial-a", "serial-b"]

    assert Enum.all?(transition_commands, fn args ->
             command = List.last(args)

             command =~ ~s(test "$value" = "#{expected_record(lease)}") and
               command =~ ~s(printf %s "#{expected_record(lease, :native_ready)}")
           end)
  end

  test "a later transition exception retains current and prior target metadata" do
    lease = held_lease(["serial-a", "serial-b"])

    runner = fn ["-s", serial, "shell", command] ->
      cond do
        fixed_record_proof?(command) ->
          {expected_record(lease), 0}

        serial == "serial-b" and String.contains?(command, "record_next_") ->
          throw(:transport_lost_after_transition)

        true ->
          {"", 0}
      end
    end

    assert {:error,
            %{
              phase: :transition,
              affected_serials: ["serial-a", "serial-b"],
              transitioned_serials: ["serial-a"],
              transition: {:acquired, :native_ready},
              lease: %{state: :retained_ambiguous, phase: :acquired}
            }} = AndroidDeployLock.transition(lease, :acquired, :native_ready, runner)
  end

  test "transition authority mismatch is retained ambiguity, not a held lease" do
    lease = held_lease(["serial-a"])

    assert {:error,
            %{
              reason: :record_mismatch,
              lease: %{state: :retained_ambiguous}
            }} =
             AndroidDeployLock.transition(lease, :acquired, :native_ready, fn _args ->
               {"malformed", 0}
             end)
  end

  test "release is committed-only and performs set-wide rename and proof before deletion" do
    uncommitted = held_lease(["serial-a", "serial-b"])
    {:ok, untouched} = Agent.start_link(fn -> [] end)

    assert {:error, %{reason: :lease_not_releasable}} =
             AndroidDeployLock.release(uncommitted, fn args ->
               Agent.update(untouched, &[args | &1])
               {"", 0}
             end)

    assert Agent.get(untouched, & &1) == []

    lease = %{uncommitted | phase: :final_committed}
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn args ->
      Agent.update(commands, &[args | &1])
      command = List.last(args)

      if fixed_record_proof?(command) or tombstone_record_proof?(command),
        do: {expected_record(lease), 0},
        else: {"", 0}
    end

    assert :ok = AndroidDeployLock.release(lease, runner)

    history = Agent.get(commands, &Enum.reverse/1)
    assert Enum.count(history, &fixed_record_proof?(List.last(&1))) == 2
    assert Enum.count(history, &rename?(&1)) == 2
    assert Enum.count(history, &tombstone_record_proof?(List.last(&1))) == 2
    assert Enum.count(history, &cleanup?/1) == 2

    Enum.each(Enum.filter(history, &cleanup?/1), fn args ->
      command = List.last(args)
      assert command =~ "/record; rmdir "
      refute command =~ "rm -rf"
    end)

    last_rename = history |> indexes(&rename?/1) |> Enum.max()
    first_tombstone_proof = history |> indexes(&tombstone_proof_args?/1) |> Enum.min()
    last_tombstone_proof = history |> indexes(&tombstone_proof_args?/1) |> Enum.max()
    first_delete = history |> indexes(&cleanup?/1) |> Enum.min()
    assert last_rename < first_tombstone_proof
    assert last_tombstone_proof < first_delete
  end

  test "release rename ambiguity leaves all prior tombstones and performs no deletion" do
    lease = %{held_lease(["serial-a", "serial-b"]) | phase: :fast_committed}
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn ["-s", serial, "shell", command] = args ->
      Agent.update(commands, &[args | &1])

      cond do
        fixed_record_proof?(command) -> {expected_record(lease), 0}
        serial == "serial-a" and String.contains?(command, "mv ") -> raise "lost reply"
        true -> {"", 0}
      end
    end

    assert {:error,
            %{
              phase: :release_rename,
              affected_serials: ["serial-a", "serial-b"],
              renamed_serials: ["serial-b"],
              released_serials: nil,
              lease: %{state: :retained_ambiguous}
            }} = normalize_release_failure(AndroidDeployLock.release(lease, runner))

    refute Agent.get(commands, & &1) |> Enum.any?(&cleanup?/1)
  end

  test "release delete exception halts later cleanup and reports already clear targets" do
    lease = %{held_lease(["serial-a", "serial-b"]) | phase: :final_committed}
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn ["-s", serial, "shell", command] = args ->
      Agent.update(commands, &[args | &1])

      cond do
        fixed_record_proof?(command) or tombstone_record_proof?(command) ->
          {expected_record(lease), 0}

        serial == "serial-a" and tombstone_delete_command?(command) ->
          exit(:transport_lost_after_delete)

        true ->
          {"", 0}
      end
    end

    assert {:error,
            %{
              phase: :release_delete,
              serial: "serial-a",
              released_serials: ["serial-b"],
              lease: %{state: :retained_ambiguous}
            }} = AndroidDeployLock.release(lease, runner)

    delete_targets =
      Agent.get(commands, &Enum.reverse/1)
      |> Enum.filter(&cleanup?/1)
      |> Enum.map(&Enum.at(&1, 1))

    assert delete_targets == ["serial-b", "serial-a"]
  end

  test "release never recursively deletes content added after tombstone proof" do
    lease = %{held_lease(["serial-a"]) | phase: :final_committed}
    topology = start_supervised!({Agent, fn -> %{record?: true, late_content?: true} end})

    runner = fn args ->
      command = List.last(args)

      cond do
        fixed_record_proof?(command) or tombstone_record_proof?(command) ->
          {expected_record(lease), 0}

        String.contains?(command, "mv ") ->
          {"", 0}

        String.contains?(command, "rm -rf") ->
          Agent.update(topology, fn _state -> %{record?: false, late_content?: false} end)
          {"", 0}

        tombstone_delete_command?(command) ->
          Agent.update(topology, &%{&1 | record?: false})
          {"directory not empty", 1}
      end
    end

    assert {:error,
            %{
              phase: :release_delete,
              reason: :delete_ambiguous,
              lease: %{state: :retained_ambiguous}
            }} = AndroidDeployLock.release(lease, runner)

    assert Agent.get(topology, & &1) == %{record?: false, late_content?: true}
  end

  test "an extra tombstone observed after rename blocks every expected tombstone delete" do
    lease = %{held_lease(["serial-a"]) | phase: :final_committed}
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn args ->
      Agent.update(commands, &[args | &1])
      command = List.last(args)

      cond do
        fixed_record_proof?(command) -> {expected_record(lease), 0}
        String.contains?(command, "mv ") -> {"", 0}
        tombstone_record_proof?(command) -> {"extra tombstone", 1}
        true -> {"", 1}
      end
    end

    assert {:error,
            %{
              phase: :release_verify,
              lease: %{state: :retained_ambiguous},
              renamed_serials: ["serial-a"]
            }} = AndroidDeployLock.release(lease, runner)

    history = Agent.get(commands, &Enum.reverse/1)
    proof = Enum.find(history, &tombstone_record_proof?(List.last(&1))) |> List.last()
    assert proof =~ ~s(test "$#" -eq 1)
    assert proof =~ ~s(test "$1" = ")
    assert proof =~ ~s(test "$entries" -eq 1)
    refute Enum.any?(history, &cleanup?/1)
  end

  test "structural validation rejects forged subsets, malformed digest, phase, and ordering" do
    lease = held_lease(["serial-a", "serial-b"])

    refute AndroidDeployLock.valid?(%{lease | serials: ["serial-a"]})
    refute AndroidDeployLock.valid?(%{lease | target_digest: String.duplicate("0", 64)})
    refute AndroidDeployLock.valid?(%{lease | serials: Enum.reverse(lease.serials)})
    refute AndroidDeployLock.valid?(%{lease | phase: :unknown})
    refute AndroidDeployLock.valid?(%{lease | state: :not_acquired})
    refute AndroidDeployLock.valid?(Map.delete(lease, :owner))
  end

  test "case-fold-colliding target identities are rejected before runner I/O" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    assert {:error, %{reason: :ambiguous_target, lease: %{state: :not_acquired}}} =
             AndroidDeployLock.acquire(
               @bundle,
               ["ABC", "abc"],
               fn _args ->
                 Agent.update(calls, &(&1 + 1))
                 {"", 0}
               end,
               owner: @owner
             )

    assert Agent.get(calls, & &1) == 0

    forged = held_lease(["ABC", "abc"])
    refute AndroidDeployLock.valid?(forged)
    refute AndroidDeployLock.valid?(forged, :acquired)
  end

  test "status exposes bounded categories only" do
    for {output, expected} <- [
          {"clear", :clear},
          {"held", :held},
          {"released_tombstone", :released_tombstone},
          {"ambiguous", :ambiguous}
        ] do
      assert {:ok, ^expected} =
               AndroidDeployLock.status(@bundle, "serial-a", fn
                 ["-s", "serial-a", "shell", command] ->
                   assert command =~ "tombstones=$((tombstones + 1))"
                   {output, 0}
               end)
    end

    assert {:error, :status_ambiguous} =
             AndroidDeployLock.status(@bundle, "serial-a", fn _args ->
               {"held\nowner", 0}
             end)

    assert {:error, :status_ambiguous} =
             AndroidDeployLock.status(@bundle, "serial-a", fn _args ->
               raise "transport unavailable"
             end)
  end

  test "recovery cleanup removes only one exact committed tombstone" do
    lease = %{held_lease(["serial-a"]) | phase: :final_committed}
    basename = ".mob_native_deploy_releasing_#{lease.owner}"
    probe = basename <> "\n" <> expected_record(lease)
    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn args ->
      Agent.update(commands, &[args | &1])
      command = List.last(args)

      if tombstone_delete_command?(command), do: {"", 0}, else: {probe, 0}
    end

    assert :ok =
             AndroidDeployLock.cleanup_committed_tombstone(@bundle, "serial-a", runner)

    [probe_command, cleanup_command] = Agent.get(commands, &Enum.reverse/1)
    assert List.last(probe_command) =~ "test ! -e"
    assert List.last(probe_command) =~ ~s(test "$#" -eq 1)
    assert List.last(probe_command) =~ ~s(test "$entries" -eq 1)
    assert List.last(cleanup_command) =~ ~s(test "$1" = ")
    assert List.last(cleanup_command) =~ ~s(test "$entries" -eq 1)
    assert List.last(cleanup_command) =~ ~s(test "$value" = "#{expected_record(lease)}")
    assert List.last(cleanup_command) =~ "/record; rmdir "
    refute List.last(cleanup_command) =~ "rm -rf"
  end

  test "recovery cleanup leaves late-added tombstone content and fails ambiguous" do
    lease = %{held_lease(["serial-a"]) | phase: :final_committed}
    basename = ".mob_native_deploy_releasing_#{lease.owner}"
    probe = basename <> "\n" <> expected_record(lease)
    topology = start_supervised!({Agent, fn -> %{record?: true, late_content?: true} end})

    runner = fn args ->
      command = List.last(args)

      cond do
        recovery_probe?(command) ->
          {probe, 0}

        String.contains?(command, "rm -rf") ->
          Agent.update(topology, fn _state -> %{record?: false, late_content?: false} end)
          {"", 0}

        tombstone_delete_command?(command) ->
          Agent.update(topology, &%{&1 | record?: false})
          {"directory not empty", 1}
      end
    end

    assert {:error, :cleanup_ambiguous} =
             AndroidDeployLock.cleanup_committed_tombstone(@bundle, "serial-a", runner)

    assert Agent.get(topology, & &1) == %{record?: false, late_content?: true}
  end

  test "concurrent recovery cleanup allows only one attempt to report success" do
    lease = %{held_lease(["serial-a"]) | phase: :fast_committed}
    basename = ".mob_native_deploy_releasing_#{lease.owner}"
    probe = basename <> "\n" <> expected_record(lease)
    parent = self()
    record_present? = start_supervised!({Agent, fn -> true end})
    task_supervisor = start_supervised!(Task.Supervisor)

    runner = fn args ->
      command = List.last(args)

      cond do
        recovery_probe?(command) ->
          send(parent, {:cleanup_probe_waiting, self()})

          receive do
            :continue_cleanup_probe -> {probe, 0}
          end

        tombstone_delete_command?(command) or String.contains?(command, "rm -rf") ->
          send(parent, {:cleanup_delete_waiting, self(), command})

          receive do
            :continue_cleanup_delete ->
              if String.contains?(command, "rm -rf") do
                {"", 0}
              else
                Agent.get_and_update(record_present?, fn
                  true -> {{"", 0}, false}
                  false -> {{"record disappeared", 1}, false}
                end)
              end
          end
      end
    end

    cleanup = fn ->
      AndroidDeployLock.cleanup_committed_tombstone(@bundle, "serial-a", runner)
    end

    first = Task.Supervisor.async_nolink(task_supervisor, cleanup)
    second = Task.Supervisor.async_nolink(task_supervisor, cleanup)

    probe_pids =
      for _index <- 1..2 do
        assert_receive {:cleanup_probe_waiting, pid}
        pid
      end

    Enum.each(probe_pids, &send(&1, :continue_cleanup_probe))

    delete_waiters =
      for _index <- 1..2 do
        assert_receive {:cleanup_delete_waiting, pid, command}
        refute command =~ "rm -rf"
        assert command =~ "/record; rmdir "
        pid
      end

    Enum.each(delete_waiters, &send(&1, :continue_cleanup_delete))

    results = [Task.await(first), Task.await(second)]
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :cleanup_ambiguous})) == 1
  end

  test "recovery cleanup rejects native-ready, basename mismatch, and delete ambiguity" do
    lease = %{held_lease(["serial-a"]) | phase: :native_ready}
    basename = ".mob_native_deploy_releasing_#{lease.owner}"
    probe = basename <> "\n" <> expected_record(lease)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    assert {:error, :tombstone_not_committed} =
             AndroidDeployLock.cleanup_committed_tombstone(@bundle, "serial-a", fn args ->
               Agent.update(calls, &[args | &1])
               {probe, 0}
             end)

    refute Agent.get(calls, & &1) |> Enum.any?(&cleanup?/1)

    committed = %{lease | phase: :fast_committed}

    assert {:error, :tombstone_not_committed} =
             AndroidDeployLock.cleanup_committed_tombstone(@bundle, "serial-a", fn _args ->
               {".mob_native_deploy_releasing_otherproof00001\n" <>
                  expected_record(committed), 0}
             end)

    good_probe = basename <> "\n" <> expected_record(committed)
    attempt_key = {__MODULE__, make_ref()}

    assert {:error, :cleanup_ambiguous} =
             AndroidDeployLock.cleanup_committed_tombstone(@bundle, "serial-a", fn _args ->
               case Process.get(attempt_key, 0) do
                 0 ->
                   Process.put(attempt_key, 1)
                   {good_probe, 0}

                 count ->
                   raise "transport lost after delete #{count}"
               end
             end)

    assert Process.get(attempt_key) == 1
  end

  test "recovery cleanup observes unknown tombstone contents before any deletion" do
    {:ok, commands} = Agent.start_link(fn -> [] end)

    assert {:error, :tombstone_ambiguous} =
             AndroidDeployLock.cleanup_committed_tombstone(@bundle, "serial-a", fn args ->
               Agent.update(commands, &[args | &1])
               {"extra entry", 1}
             end)

    [probe] = Agent.get(commands, & &1)
    assert List.last(probe) =~ ~s(test "$entries" -eq 1)
    refute cleanup?(probe)
  end

  defp held_lease(serials) do
    ordered = Enum.sort(serials)

    %{
      bundle_id: @bundle,
      owner: @owner,
      serials: ordered,
      target_digest: target_digest(ordered),
      phase: :acquired,
      state: :held_success
    }
  end

  defp expected_record(lease, phase \\ nil) do
    phase = phase || lease.phase
    "1|#{lease.owner}|#{lease.target_digest}|#{phase}"
  end

  defp target_digest(serials) do
    serials
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fixed_record_proof?(command) do
    String.ends_with?(command, ".mob_native_deploy_lock/record'") and
      not String.contains?(command, "value=$(cat")
  end

  defp tombstone_record_proof?(command) do
    String.contains?(command, ".mob_native_deploy_releasing_#{@owner}/record") and
      String.ends_with?(command, "/record'") and
      not String.contains?(command, "value=$(cat")
  end

  defp mutation?(args), do: List.last(args) |> String.contains?("mkdir ")
  defp cleanup?(args), do: args |> List.last() |> tombstone_delete_command?()

  defp tombstone_delete_command?(command) do
    String.contains?(command, "/record; rmdir ") and not String.contains?(command, "rm -rf")
  end

  defp recovery_probe?(command), do: String.contains?(command, "base=${1##*/}")

  defp rename?(args) do
    command = List.last(args)

    String.contains?(command, "mv ") and
      String.contains?(command, ".mob_native_deploy_releasing_")
  end

  defp tombstone_proof_args?(args), do: tombstone_record_proof?(List.last(args))

  defp indexes(items, predicate) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> if predicate.(item), do: [index], else: [] end)
  end

  defp normalize_release_failure({:error, failure}) do
    {:error, Map.put_new(failure, :released_serials, nil)}
  end
end

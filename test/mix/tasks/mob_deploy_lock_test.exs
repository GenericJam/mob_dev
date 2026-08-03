defmodule Mix.Tasks.Mob.DeployLockTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mob.DeployLock

  @bundle "com.example.casein"
  @serial "serial-a"
  @owner "ownerproof000001"
  @digest String.duplicate("a", 64)

  test "status is read-only and returns only the bounded lock category" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn args ->
      Agent.update(calls, &[args | &1])
      {"clear", 0}
    end

    assert {:ok, :clear} = DeployLock.inspect_or_cleanup(@bundle, @serial, false, runner)

    assert [["-s", @serial, "shell", command]] = Agent.get(calls, &Enum.reverse/1)
    assert command =~ "printf clear"
    refute command =~ "rm -rf"
    refute command =~ "mv "
    refute command =~ "mkdir "
  end

  test "cleanup refuses clear, active, and ambiguous topology without a mutation" do
    for state <- [:clear, :held, :ambiguous] do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      runner = fn args ->
        Agent.update(calls, &[args | &1])
        {Atom.to_string(state), 0}
      end

      assert {:error, {:cleanup_refused, ^state}} =
               DeployLock.inspect_or_cleanup(@bundle, @serial, true, runner)

      history = Agent.get(calls, &Enum.reverse/1)
      assert length(history) == 1
      refute Enum.any?(history, &(List.last(&1) =~ "rm -rf"))
    end
  end

  test "cleanup removes one exact committed tombstone and proves the final clear state" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    {:ok, step} = Agent.start_link(fn -> 0 end)
    basename = ".mob_native_deploy_releasing_#{@owner}"
    record = "1|#{@owner}|#{@digest}|final_committed"

    runner = fn args ->
      Agent.update(calls, &[args | &1])

      case Agent.get_and_update(step, &{&1, &1 + 1}) do
        0 -> {"released_tombstone", 0}
        1 -> {basename <> "\n" <> record, 0}
        2 -> {"", 0}
        3 -> {"clear", 0}
      end
    end

    assert {:ok, :cleaned} =
             DeployLock.inspect_or_cleanup(@bundle, @serial, true, runner)

    history = Agent.get(calls, &Enum.reverse/1)
    assert length(history) == 4
    assert Enum.all?(history, &(Enum.take(&1, 2) == ["-s", @serial]))

    cleanup = Enum.at(history, 2) |> List.last()
    tombstone = "/data/data/#{@bundle}/files/.mob_native_deploy_releasing_#{@owner}"
    assert cleanup =~ tombstone
    assert cleanup =~ ~s(test "$value" = "#{record}")
    assert cleanup =~ "rm #{tombstone}/record; rmdir #{tombstone}"
    refute cleanup =~ "rm -rf"
  end

  test "a lost cleanup reply remains ambiguous and is never retried" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    basename = ".mob_native_deploy_releasing_#{@owner}"
    record = "1|#{@owner}|#{@digest}|fast_committed"

    runner = fn _args ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {"released_tombstone", 0}
        1 -> {basename <> "\n" <> record, 0}
        2 -> raise "transport lost after delete"
      end
    end

    assert {:error, :cleanup_ambiguous} =
             DeployLock.inspect_or_cleanup(@bundle, @serial, true, runner)

    assert Agent.get(calls, & &1) == 3
  end

  test "a non-clear post-cleanup proof is reported as ambiguity, not refusal" do
    {:ok, step} = Agent.start_link(fn -> 0 end)
    basename = ".mob_native_deploy_releasing_#{@owner}"
    record = "1|#{@owner}|#{@digest}|fast_committed"

    runner = fn _args ->
      case Agent.get_and_update(step, &{&1, &1 + 1}) do
        0 -> {"released_tombstone", 0}
        1 -> {basename <> "\n" <> record, 0}
        2 -> {"", 0}
        3 -> {"held", 0}
      end
    end

    assert {:error, :post_cleanup_ambiguous} =
             DeployLock.inspect_or_cleanup(@bundle, @serial, true, runner)

    assert Agent.get(step, & &1) == 4
  end

  test "malformed requests fail before invoking the runner" do
    runner = fn _args -> flunk("runner must not be called") end

    assert {:error, :invalid_request} =
             DeployLock.inspect_or_cleanup(@bundle, @serial, :yes, runner)

    assert {:error, :invalid_request} =
             DeployLock.inspect_or_cleanup(@bundle, @serial, false, :not_a_runner)
  end

  test "duplicate device switches fail before any status or cleanup command" do
    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          DeployLock.run([
            "--device",
            "serial-a",
            "--device",
            "serial-b",
            "--cleanup-committed"
          ])
        end)
      end

    assert error.message ==
             "Exactly one Android device serial is required; pass --device once"
  end
end

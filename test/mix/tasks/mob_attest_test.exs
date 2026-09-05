defmodule Mix.Tasks.Mob.AttestTest do
  @moduledoc """
  The reporting half of `mix mob.attest`.

  Per this repo's convention the task stays a thin unstubbed I/O wrapper and
  the decisions live in `MobDev.Attest`; what is testable here is the shape of
  what it hands back.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Attest, as: AttestTask
  alias MobDev.Attest

  defp finding(verdict), do: %{module: Foo, verdict: verdict, expected: nil, actual: nil}

  describe "the tally that drives the summary line" do
    test "a device running this build reports only matches" do
      findings = List.duplicate(finding(:match), 55)

      assert Attest.tally(findings) == %{match: 55, stale: 0, missing: 0, unreadable: 0}
      assert Attest.verdict(findings) == :ok
    end

    test "the shape a real stale device produced" do
      # 55 match / 12 stale, from the run that found MOB-161: a deploy that
      # printed a tick while twelve modules on the device differed from the
      # build. The numbers are the point — a check that only fires when
      # everything is wrong would not have caught it.
      findings = List.duplicate(finding(:match), 55) ++ List.duplicate(finding(:stale), 12)

      assert Attest.tally(findings) == %{match: 55, stale: 12, missing: 0, unreadable: 0}
      assert {:error, message} = Attest.verdict(findings)
      assert message =~ "12 module(s)"
    end

    test "modules the device cannot find fail the run" do
      # An earlier version treated these as routine on the theory that
      # interactive BEAM loads lazily. Measured on a device, the probe itself
      # triggers the load — so :undef means the module is on no code path, and
      # for something mob.deploy pushed that is a real failure.
      findings = [finding(:match)] ++ List.duplicate(finding(:missing), 400)

      assert {:error, message} = Attest.verdict(findings)
      assert message =~ "on no code path"
      assert Attest.tally(findings).missing == 400
    end
  end

  describe "finding/2 — the wiring that had no tests" do
    @beam :code.which(MobDev.Attest) |> List.to_string()

    test "compares the local digest against what the fetcher returns" do
      # Replacing the fetcher with the expected value would report 100% match
      # on every run; nothing exercised this path before.
      {_, digest} = MobDev.Attest.local_digest(@beam)

      assert %{verdict: :match} = AttestTask.finding(@beam, fn _ -> digest end)
      assert %{verdict: :stale} = AttestTask.finding(@beam, fn _ -> "other" end)
    end

    test "a device that cannot answer is unreadable, not a match" do
      assert %{verdict: :unreadable} =
               AttestTask.finding(@beam, fn _ -> {:badrpc, :nodedown} end)
    end

    test "an undigestable local file never calls the fetcher" do
      path = Path.join(System.tmp_dir!(), "x_#{System.unique_integer([:positive])}.beam")
      File.write!(path, "not a beam")
      on_exit(fn -> File.rm(path) end)

      assert %{verdict: :unreadable} =
               AttestTask.finding(path, fn _ -> raise "must not be asked" end)
    end

    test "the module name comes from the file name" do
      assert AttestTask.module_from_path("a/b/Elixir.Mob.Renderer.beam") == Mob.Renderer
    end
  end

  describe "outcome/2" do
    test "clean run" do
      assert AttestTask.outcome([], []) == "ok"
    end

    test "an unreachable device is never ok" do
      # Two devices, one wedged: checking the healthy one and reporting "ok"
      # is the same shape as a deploy that skips a target and exits 0.
      assert AttestTask.outcome([], [:a@b]) == "unreachable"
    end

    test "a mismatch outranks an unreachable device" do
      assert AttestTask.outcome([%{}], [:a@b]) == "mismatch"
    end
  end
end

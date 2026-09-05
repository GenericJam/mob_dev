defmodule Mix.Tasks.Mob.AttestTest do
  @moduledoc """
  The reporting half of `mix mob.attest`.

  Per this repo's convention the task stays a thin unstubbed I/O wrapper and
  the decisions live in `MobDev.Attest`; what is testable here is the shape of
  what it hands back.
  """
  use ExUnit.Case, async: true

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

    test "a mostly-unloaded bundle is still a pass" do
      # Interactive BEAM loads a module when something first calls it, so this
      # is the ordinary state of a freshly booted app, not a problem.
      findings = [finding(:match)] ++ List.duplicate(finding(:missing), 400)

      assert Attest.verdict(findings) == :ok
      assert Attest.tally(findings).missing == 400
    end
  end
end

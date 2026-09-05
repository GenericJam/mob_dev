defmodule MobDev.AttestTest do
  @moduledoc """
  The comparison behind `mix mob.attest`.

  Written against a real failure: two bundle ids diverged, the BEAM push
  addressed one app's container while another app was running, and the deploy
  printed a tick. Both containers existed, so every step was honest about
  itself and the run as a whole was a lie. Nothing in the toolchain could
  contradict it.
  """
  use ExUnit.Case, async: true

  alias MobDev.Attest

  @digest_a :crypto.hash(:md5, "a")
  @digest_b :crypto.hash(:md5, "b")

  describe "compare/3" do
    test "the same digest is a match" do
      assert %{verdict: :match} = Attest.compare(Foo, @digest_a, @digest_a)
    end

    test "a different digest is stale — this is the case the task exists for" do
      finding = Attest.compare(Foo, @digest_a, @digest_b)

      assert finding.verdict == :stale
      assert finding.expected == @digest_a
      assert finding.actual == @digest_b
    end

    test "a module the device never loaded is missing, not stale" do
      # `module_info(:md5)` raises :undef for an unloaded module, which arrives
      # as a badrpc EXIT. Interactive BEAM loads a module when something first
      # calls it, so most of a bundle is legitimately unloaded — calling that
      # stale would make the check cry wolf and get it turned off.
      for remote <- [
            {:badrpc, {:EXIT, {:undef, []}}},
            {:badrpc, :nodedown},
            nil,
            :undefined
          ] do
        assert %{verdict: :missing} = Attest.compare(Foo, @digest_a, remote)
      end
    end

    test "an undigestable local beam is unreadable, never a match" do
      # Nothing can be concluded, and "cannot tell" must not read as agreement.
      assert %{verdict: :unreadable} = Attest.compare(Foo, nil, @digest_a)
      assert %{verdict: :unreadable} = Attest.compare(Foo, nil, nil)
    end
  end

  describe "verdict/1" do
    defp finding(verdict), do: %{module: Foo, verdict: verdict, expected: nil, actual: nil}

    test "all matched is ok" do
      assert Attest.verdict([finding(:match), finding(:match)]) == :ok
    end

    test "unloaded modules alone do not fail the check" do
      assert Attest.verdict([finding(:match), finding(:missing), finding(:missing)]) == :ok
    end

    test "one stale module fails, however many matched" do
      findings = List.duplicate(finding(:match), 500) ++ [finding(:stale)]

      assert {:error, message} = Attest.verdict(findings)
      assert message =~ "do not match this build"
      assert message =~ "running code you did not just push"
    end

    test "a check that could not run does not pass" do
      # Same rule as a deploy that exits 0 having shipped nothing: not being
      # able to measure is not a success.
      assert {:error, message} = Attest.verdict([finding(:match), finding(:unreadable)])
      assert message =~ "could not be digested"
    end

    test "stale outranks unreadable in the message" do
      assert {:error, message} = Attest.verdict([finding(:stale), finding(:unreadable)])
      assert message =~ "do not match this build"
    end

    test "the named modules are sorted, so two runs diff cleanly" do
      # Found by `mix mob.mutate`: deleting the sort left every test green.
      # Report order that follows map iteration makes two runs of the same
      # check look different, which is exactly when someone stops reading it.
      findings =
        for name <- [:Zeta, :Alpha, :Mid], do: %{finding(:stale) | module: name}

      assert {:error, message} = Attest.verdict(findings)
      assert message =~ ":Alpha, :Mid, :Zeta"
    end

    test "the message names modules but does not run away" do
      findings = for n <- 1..50, do: %{finding(:stale) | module: :"Mod#{n}"}

      assert {:error, message} = Attest.verdict(findings)
      assert message =~ "50 module(s)"
      assert length(String.split(message, ", ")) <= 6
    end
  end

  describe "tally/1" do
    test "counts each verdict" do
      findings = [finding(:match), finding(:match), finding(:stale), finding(:missing)]

      assert Attest.tally(findings) == %{match: 2, stale: 1, missing: 1, unreadable: 0}
    end

    test "every key is present even when nothing was found" do
      # A consumer reading `.stale` must not get nil on a clean run.
      assert Attest.tally([]) == %{match: 0, stale: 0, missing: 0, unreadable: 0}
    end
  end

  describe "local_digest/1" do
    test "digests a real beam, and agrees with module_info(:md5)" do
      # The whole comparison rests on these two being the same number. If OTP
      # ever changes that, this fails rather than every attestation silently
      # reporting stale.
      path = :code.which(MobDev.Attest) |> List.to_string()

      assert {MobDev.Attest, digest} = Attest.local_digest(path)
      assert digest == MobDev.Attest.module_info(:md5)
    end

    test "a file that is not a beam yields nil" do
      path = Path.join(System.tmp_dir!(), "not_a_beam_#{System.unique_integer([:positive])}")
      File.write!(path, "definitely not a beam")
      on_exit(fn -> File.rm(path) end)

      assert Attest.local_digest(path) == nil
    end

    test "a missing file yields nil" do
      assert Attest.local_digest("/nope/missing.beam") == nil
    end
  end
end

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

    test "an :undef answer is missing — the device has it on no code path" do
      # Measured on a device: the code server is interactive, so asking for
      # module_info(:md5) LOADS an unloaded module and returns a digest.
      # :undef therefore does not mean "not resident yet", it means the module
      # is not findable at all.
      assert %{verdict: :missing} =
               Attest.compare(Foo, @digest_a, {:badrpc, {:EXIT, {:undef, []}}})
    end

    test "a transport failure is unreadable, NOT missing" do
      # The bug this replaces, and the one a previous version of this test
      # actively pinned: every badrpc collapsed to :missing, :missing was
      # non-fatal, and a node that went away mid-run produced hundreds of
      # missing modules and a cheerful :ok. Zero evidence, tick printed.
      for remote <- [{:badrpc, :nodedown}, {:badrpc, :timeout}, nil, :undefined] do
        assert %{verdict: :unreadable} = Attest.compare(Foo, @digest_a, remote),
               "#{inspect(remote)} means the check could not run, not that the module is absent"
      end
    end

    test "a node that went away does not attest green" do
      dead = for _ <- 1..400, do: Attest.compare(Foo, @digest_a, {:badrpc, :nodedown})

      assert {:error, message} = Attest.verdict(dead)
      assert message =~ "could not"
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

    test "a module the device cannot find is a failure" do
      # These were pushed. If the device answers :undef for one, on an
      # interactive code server it is not on any code path — which is the
      # thing a deploy was supposed to have put there.
      assert {:error, message} = Attest.verdict([finding(:match), finding(:missing)])
      assert message =~ "on no code path"
    end

    test "nothing compared is not a pass" do
      # A typo'd --app used to glob no files, produce no findings, and report
      # success. A green attestation over an empty set is the switched-off
      # check that still reports.
      assert {:error, message} = Attest.verdict([])
      assert message =~ "nothing was verified"
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

      # Count the names, not the commas. `String.split(message, ", ")` returned
      # exactly 6 parts whether the cap was 5 or 6, because the last name is
      # glued to the trailing sentence — so the cap test did not test the cap,
      # which a review demonstrated by mutating take(5) to take(6).
      assert length(Regex.scan(~r/:Mod\d+/, message)) == 5
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

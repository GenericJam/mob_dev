# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
#
# These assert on source text rather than calling application code, which is
# what the check is designed to catch. It is the right shape here: the paths
# guarded need a keychain, a provisioning profile or a physical device to run,
# and every one of these fixes was silently revertible before they existed.
defmodule MobDev.WiringTest do
  @moduledoc """
  Assertions that a decision is actually WIRED to the code path it governs.

  Every finding that put a test in here had the same shape: a well-covered
  pure function, and a call site nothing checked — so deleting the call left
  the suite green and fully restored the bug. That has now happened four
  times (the two bundle-id resolvers, the `Mix.raise` on a failed deploy, and
  the `requested:` flag on the native build).

  ## iOS bundle ids

  Every iOS path must resolve its bundle id through the `:ios_bundle_id ||
  :bundle_id` rule.

  Reaching for the generic `bundle_id/0` on an iOS path is the defect this was
  written to eliminate: the app installs under one id and everything afterwards
  addresses another. It was found twice in the deploy path, and a review then
  found three more sites the original audit missed.

  These are source assertions because the paths need a keychain, a provisioning
  profile or a physical device to execute. The behavioural seams are tested in
  `MobDev.ConfigTest`; these cover what cannot be reached from a unit test.
  """
  use ExUnit.Case, async: true

  @native_build File.read!(Path.expand("../../lib/mob_dev/native_build.ex", __DIR__))
  @release File.read!(Path.expand("../../lib/mob_dev/release.ex", __DIR__))
  @deployer File.read!(Path.expand("../../lib/mob_dev/deployer.ex", __DIR__))
  @deploy_task File.read!(Path.expand("../../lib/mix/tasks/mob.deploy.ex", __DIR__))
  @native_build_src File.read!(Path.expand("../../lib/mob_dev/native_build.ex", __DIR__))

  defp index_of(hay, needle) do
    case :binary.match(hay, needle) do
      {i, _} -> i
      :nomatch -> flunk("expected to find #{inspect(needle)}")
    end
  end

  defp region(source, from, to) do
    unless String.contains?(source, from), do: flunk("marker not found: #{inspect(from)}")
    [_, rest] = String.split(source, from, parts: 2)
    unless String.contains?(rest, to), do: flunk("end marker not found: #{inspect(to)}")
    [body | _] = String.split(rest, to, parts: 2)
    body
  end

  describe "the device build signs against a profile for the id it stamps" do
    test "check_device_signing_config/1 looks the profile up by the iOS id" do
      # Without this the build searches for a profile minted for the Android
      # applicationId. `mix mob.provision` creates it for `ios_bundle_id`, so
      # the two disagree and the build falls back to a wildcard or fails
      # naming an id Apple would reject outright.
      body = region(@native_build, "defp check_device_signing_config(cfg) do", "\n  end")

      assert body =~ "bundle_id = ios_bundle_id(cfg)"
      refute body =~ "bundle_id = cfg[:bundle_id]"
    end
  end

  describe "the release/IPA path" do
    test "resolves the distribution profile by the iOS id" do
      body = region(@release, "def resolve_distribution_signing(cfg) do", "\n  end")

      assert body =~ "MobDev.NativeBuild.ios_bundle_id(cfg)"
      refute body =~ "bundle_id = cfg[:bundle_id]"
    end

    test "MOB_IOS_BUNDLE_ID carries the iOS id" do
      # The env var is named for iOS and fed the App Store build's
      # CFBundleIdentifier. Reading `:bundle_id` here stamps a submitted IPA
      # with the Android applicationId — which, for the id that motivated this
      # work, App Store Connect rejects for containing an underscore.
      assert @release =~ ~s|{"MOB_IOS_BUNDLE_ID", MobDev.NativeBuild.ios_bundle_id(cfg)}|
      refute @release =~ ~s|{"MOB_IOS_BUNDLE_ID", cfg[:bundle_id]}|
    end
  end

  describe "a device without the app is skipped, not failed" do
    test "the iOS not-installed branch throws :skipped" do
      # Android already reports this as `{:skipped, ...}` — it means "this
      # device is not a target", not "the deploy failed". Once mob.deploy
      # started returning a non-zero exit code, tagging the iOS case as an
      # error made a plain `mix mob.deploy` fail on any Mac with an unrelated
      # iPhone attached.
      body = region(@deployer, "ContainerLookupErrorDomain", "devicectl copy failed")

      assert body =~ "throw(\n              {:skipped,"
      refute body =~ "throw({:error, reason})"
    end

    test "the catch clause returns it as skipped without override annotation" do
      # The copy never began, so nothing on the device was replaced and there
      # is no partial-override warning to attach.
      body = region(@deployer, "    catch\n      # Not annotated", "\n    after")

      assert body =~ "{:skipped, reason} ->"
      refute body =~ "{:skipped, reason} ->\n        {:error,"
    end
  end

  describe "the exit code is actually wired to the decision" do
    test "failure_message/3 drives a Mix.raise, after the summary" do
      # `failure_message/3` is well tested as a pure function, but deleting the
      # block that CALLS it left the whole suite green — the deploy would go
      # back to exiting 0 on failure, the original bug, with the function that
      # decides it still perfectly covered.
      body = region(@deploy_task, "Enum.each(format_summary(", "\n  end")

      assert body =~ "failure_message("
      assert body =~ "missing_device_message(device_id, deployed, failed, skipped)"
      assert body =~ "message -> Mix.raise(message)"

      # Order matters: raising before the summary loses the per-device detail
      # for every device in the run, which is what an operator reads. Measured
      # against the whole file — anchoring the region ON the summary made this
      # `assert 0 < raise_at`, which cannot fail.
      assert index_of(@deploy_task, "Enum.each(format_summary(") <
               index_of(@deploy_task, "Mix.raise(message)")
    end
  end

  describe "the native build's honest-exit wiring (MOB-150)" do
    # `build_outcome/2` is well covered as a pure function, but nothing in the
    # suite calls `build_all/1` — so deleting either half of the wiring left
    # 2244 tests green and fully restored the bug: `mix mob.deploy --android
    # --native` with no sdk.dir builds nothing and exits 0. Same shape as the
    # `Mix.raise` gap above: the decision was covered, the call was not.
    test "the task tells the build which platforms were asked for" do
      body = region(@deploy_task, "MobDev.NativeBuild.build_all(", "\n        )")

      assert body =~ "requested: requested_platforms(opts)"
    end

    test "the build reads that back and runs it through build_outcome/2" do
      body = region(@native_build_src, "requested =", "\n  end")

      assert body =~ "Keyword.get(opts, :requested, [])"
      assert body =~ "case build_outcome(results, requested) do"
    end

    test "an unserved request is intersected with the narrowed platform list" do
      # An auto-detected iPhone narrows Android out of the build. Counting that
      # as an unserved `--android` fails a run that did what was asked.
      body = region(@native_build_src, "requested =", "case build_outcome")

      assert body =~ "Enum.filter(Keyword.get(opts, :requested, []), &(&1 in platforms))"
    end
  end

  describe "--json is declared and pipeable" do
    # Deleting `json: :boolean` from @switches makes OptionParser drop the flag
    # into `invalid`, `opts[:json]` becomes nil, and no document is emitted —
    # with every json_result/4 test still green, because none of them went
    # through the switch.
    test "the switch exists" do
      assert @deploy_task =~ "json: :boolean"
    end

    test "progress is redirected so stdout carries one document" do
      # The comment used to claim progress went to stderr. It did not: every
      # line in this task, the deployer and the native build is a plain
      # IO.puts/1 to :stdio, so `--json | jq` got ANSI prose and died.
      assert @deploy_task =~ "Process.group_leader(self(), Process.whereis(:standard_error))"
      assert @deploy_task =~ "Process.put(:mob_deploy_stdout, Process.group_leader())"
      assert @deploy_task =~ "IO.puts(Process.get(:mob_deploy_stdout, :standard_io), json)"
    end

    test "a native-build failure still emits a document" do
      # The one path where a caller most needs the result was the one that
      # produced none, because the emit sat after the early raise.
      assert @deploy_task =~
               ~r/emit_json\(opts, \[\], \[\], \[\], "Native build failed"\)\s*Mix\.raise/
    end
  end
end

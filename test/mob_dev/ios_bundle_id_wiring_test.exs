# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
#
# These assert on source text rather than calling application code, which is
# what the check is designed to catch. It is the right shape here: the paths
# guarded need a keychain, a provisioning profile or a physical device to run,
# and every one of these fixes was silently revertible before they existed.
defmodule MobDev.IosBundleIdWiringTest do
  @moduledoc """
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

      assert body =~ "case failure_message(deployed, failed, skipped) do"
      assert body =~ "message -> Mix.raise(message)"

      # Order matters: raising before the summary loses the per-device detail
      # for every device in the run, which is what an operator reads.
      summary_at = 0
      raise_at = :binary.match(body, "Mix.raise(message)") |> elem(0)
      assert summary_at < raise_at
    end
  end
end

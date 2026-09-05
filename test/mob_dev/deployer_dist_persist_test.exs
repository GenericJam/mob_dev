defmodule MobDev.DeployerDistPersistTest do
  @moduledoc """
  What a dist deploy does after the hot load (MOB-118).

  The dist and filesystem paths used to be mutually exclusive, so a dist
  deploy loaded modules into the running VM and left the on-disk copies stale.
  The app reverted on its next restart — and `mix mob.connect` restarts it, so
  connecting to look at your change undid it.

  The first version of the fix was tested with source-text assertions, and a
  review showed a one-line mutation that **restores the original bug** passes
  all of them: pass `[]` for `beam_dirs` at the call site and nothing is
  written, while every body those tests read stays identical. These assert the
  decisions instead.
  """
  use ExUnit.Case, async: true

  alias MobDev.{Deployer, Device}

  defp device(attrs \\ []),
    do: struct(%Device{name: "d", serial: "s", platform: :android}, attrs)

  describe "persistable?/1" do
    test "an Android device is written to disk" do
      assert Deployer.persistable?(device())
      assert Deployer.persistable?(device(type: :emulator))
    end

    test "an iOS simulator is written to disk" do
      assert Deployer.persistable?(device(platform: :ios, type: :simulator))
    end

    test "a physical iPhone is not" do
      # Two independent reasons, either sufficient. It is discovered by probing
      # EPMD across the LAN, and a LAN-only device has no `devicectl` route at
      # all — the first version of this fix turned that documented fallback
      # into a hard exit 1 on a deploy that previously succeeded. And even over
      # USB the write is a `--remove-existing-content` replace with no undo, so
      # a cable knock mid-copy leaves the app unbootable. A hot load could
      # never damage a device; making it able to, silently, is not a fix.
      refute Deployer.persistable?(device(platform: :ios, type: :physical))
    end
  end

  describe "dist_outcome/2" do
    test "a written device is deployed" do
      d = device()
      assert Deployer.dist_outcome(d, {:ok, d}) == {:ok, d}
    end

    test "a failed write is an error, even though the app is running the new code" do
      # It will silently revert on restart, which is worse than a clean
      # failure — that is the whole bug.
      assert {:error, message} = Deployer.dist_outcome(device(), {:error, "disk full"})
      assert message =~ "hot load succeeded but the on-disk BEAMs were not updated"
      assert message =~ "disk full"
    end

    test "a skipped write does not fail a device that was reached" do
      # `:skipped` means "app not installed for that platform" — but it just
      # answered over dist, so it plainly is. Failing here would report a
      # device as unreached when it was reached and updated.
      d = device()
      assert Deployer.dist_outcome(d, {:skipped, "not installed"}) == {:ok, d}
    end
  end
end

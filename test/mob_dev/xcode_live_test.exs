defmodule MobDev.XcodeLiveTest do
  # MOB-201: runs `mix mob.doctor` against the real Xcode the environment
  # selects (DEVELOPER_DIR) and checks the Xcode, iOS SDK and iPhone Duo rows it
  # prints, so the task is checked on actual `xcodebuild` / `xcrun` output,
  # including Xcode 27.1's, which the dev Mac doesn't have. Excluded by default
  # (test_helper.exs); the `xcode` lane in .github/workflows/test.yml runs it
  # with the expectations set:
  #
  #   MOB_EXPECT_XCODE=27.1 MOB_EXPECT_IOS_SDK=27.1 MOB_EXPECT_DUO=ok \
  #     mix test --only xcode_live
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # The whole task runs, including `xcrun simctl` and `adb` device probes,
  # which can take minutes on a busy Mac.
  @moduletag :xcode_live
  @moduletag timeout: :timer.minutes(10)

  test "mix mob.doctor reports the selected Xcode, its iOS SDK and Duo support" do
    xcode = System.fetch_env!("MOB_EXPECT_XCODE")
    sdk = System.fetch_env!("MOB_EXPECT_IOS_SDK")

    duo =
      case System.fetch_env!("MOB_EXPECT_DUO") do
        "ok" -> "✓ iPhone Duo — supported (Xcode #{xcode}, iOS SDK #{sdk})"
        "warn" -> "⚠ iPhone Duo — unsupported (needs Xcode 27.1+) — selected: Xcode #{xcode}"
      end

    # Outside a mob project other sections fail and the task raises; the
    # Tools section is printed before that.
    output =
      capture_io(fn ->
        try do
          Mix.Tasks.Mob.Doctor.run([])
        rescue
          Mix.Error -> :ok
        end
      end)

    lines = output |> String.replace(Regex.compile!("\e\\[[0-9;]*m"), "") |> String.split("\n")

    assert Enum.any?(lines, &String.starts_with?(&1, "  ✓ Xcode — #{xcode} (")), output
    assert "  ✓ iOS SDK — #{sdk}" in lines, output
    assert Enum.any?(lines, &String.starts_with?(&1, "  " <> duo)), output
  end
end

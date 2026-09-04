defmodule Mix.Tasks.Mob.DeployBeamFlagsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Deploy

  # ── combine_beam_flags/2 ──────────────────────────────────────────────────────

  describe "combine_beam_flags/2" do
    test "nil/nil returns nil (read cached value from mob.exs)" do
      assert Deploy.combine_beam_flags(nil, nil) == nil
    end

    test "schedulers only" do
      assert Deploy.combine_beam_flags(2, nil) == "-S 2:2"
    end

    test "schedulers 0 means BEAM auto-detect (one per core)" do
      assert Deploy.combine_beam_flags(0, nil) == "-S 0:0"
    end

    test "schedulers 1 pins to single scheduler" do
      assert Deploy.combine_beam_flags(1, nil) == "-S 1:1"
    end

    test "flags string only" do
      assert Deploy.combine_beam_flags(nil, "-sbwt none") == "-sbwt none"
    end

    test "trims whitespace from flags string" do
      assert Deploy.combine_beam_flags(nil, "  -sbwt none  ") == "-sbwt none"
    end

    test "schedulers + flags combined" do
      assert Deploy.combine_beam_flags(4, "-A 4") == "-S 4:4 -A 4"
    end

    test "schedulers + flags trims the flags string" do
      assert Deploy.combine_beam_flags(2, "  -A 2  ") == "-S 2:2 -A 2"
    end
  end

  # ── update_beam_flags_in_config/2 ────────────────────────────────────────────

  describe "update_beam_flags_in_config/2" do
    test "appends beam_flags line when key is absent" do
      content = """
      import Config

      config :mob_dev,
        mob_dir: "/path/to/mob"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 2:2")
      assert updated =~ ~s(config :mob_dev, beam_flags: "-S 2:2")
      assert updated =~ ~r/mob_dir:/
    end

    test "replaces existing beam_flags value" do
      content = """
      import Config

      config :mob_dev,
        mob_dir: "/path/to/mob",
        beam_flags: "-S 1:1"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 4:4")
      assert updated =~ ~s(beam_flags: "-S 4:4")
      refute updated =~ "-S 1:1"
    end

    test "replace preserves other keys on surrounding lines" do
      content = """
      import Config

      config :mob_dev,
        mob_dir: "/path/to/mob",
        beam_flags: "-S 1:1",
        elixir_lib: "/path/to/elixir"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 0:0")
      assert updated =~ ~r/mob_dir:/
      assert updated =~ ~r/elixir_lib:/
      assert updated =~ ~s(beam_flags: "-S 0:0")
      refute updated =~ "-S 1:1"
    end

    test "does not create a duplicate beam_flags key on repeated calls" do
      content = """
      import Config

      config :mob_dev,
        beam_flags: "-S 1:1"
      """

      updated = Deploy.update_beam_flags_in_config(content, "-S 2:2")
      count = updated |> String.split("beam_flags:") |> length() |> Kernel.-(1)
      assert count == 1
    end

    test "flags value is properly quoted with inspect/1" do
      updated = Deploy.update_beam_flags_in_config("config :mob_dev,\n  x: 1\n", "-S 2:2 -A 4")
      assert updated =~ ~s(beam_flags: "-S 2:2 -A 4")
    end
  end

  # ── format_summary/4 — deploy report rendering ────────────────────────────────
  #
  # Pin the report shape against regressions. Original bug: devices
  # without the app installed were tallied as "Failed on N device(s)"
  # in red. The fix introduced a separate "Skipped on N device(s)"
  # bucket; these tests assert that the three categories render
  # distinctly, that skipped never bleeds into failed (or vice-versa),
  # and that the empty-everything case still emits the right hint.

  describe "format_summary/4" do
    defp device(name, error \\ nil),
      do: %MobDev.Device{name: name, serial: name, platform: :android, error: error}

    defp strip_ansi(line), do: String.replace(line, ~r/\e\[[0-9;]*m/, "")

    test "all three buckets empty → 'No devices found' hint" do
      lines = Deploy.format_summary([], [], [])

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "No devices found."
      assert joined =~ "mix mob.devices"
      refute joined =~ "Deployed"
      refute joined =~ "Skipped"
      refute joined =~ "Failed"
    end

    test "only deployed → green deployed header + restart hint when :restart true" do
      lines = Deploy.format_summary([device("iPhone")], [], [], restart: true)

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "Deployed to 1 device(s)"
      assert joined =~ "Apps restarted"
      assert joined =~ "mix mob.connect"
      refute joined =~ "Skipped"
      refute joined =~ "Failed"
    end

    test "only deployed with :restart false → nl(MyModule) hint" do
      lines = Deploy.format_summary([device("iPhone")], [], [], restart: false)
      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert joined =~ "BEAMs pushed"
      assert joined =~ "nl(MyModule)"
      refute joined =~ "Apps restarted"
    end

    test "only skipped → yellow informational, NOT counted as failed" do
      # Regression: this case used to print "Failed on 1 device(s)" in red.
      skip = device("emulator-5554", "com.example not installed on emulator-5554")
      lines = Deploy.format_summary([], [], [skip])

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "Skipped on 1 device(s)"
      assert joined =~ "app not installed"
      assert joined =~ "build for that platform with --android / --ios"
      refute joined =~ "Failed on", "skipped must NOT trigger the Failed header"
    end

    test "only failed → red Failed header with x markers per device" do
      lines = Deploy.format_summary([], [device("buggy", "push timed out")], [])

      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")
      assert joined =~ "Failed on 1 device(s)"
      assert joined =~ "✗ buggy: push timed out"
      refute joined =~ "Skipped"
    end

    test "mixed: deployed + skipped + failed all render in distinct blocks" do
      ok = device("iPhone")
      skip = device("emulator-5554", "not installed")
      fail = device("emulator-5556", "adb push failed: broken pipe")

      lines = Deploy.format_summary([ok], [fail], [skip])
      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert joined =~ "Deployed to 1 device(s)"
      assert joined =~ "Skipped on 1 device(s)"
      assert joined =~ "Failed on 1 device(s)"
      assert joined =~ "✗ emulator-5556"
      # Skipped row uses the — marker, not ✗ — pin that distinction.
      assert joined =~ "— emulator-5554: not installed"
    end

    test "5-androids-skipped scenario from the original bug report" do
      # The flow that surfaced this: `mix mob.deploy --native` auto-
      # detected iPhone, built iOS only, swept BEAM push to all
      # connected devices. Five Androids didn't have the app and
      # showed up as failures.
      iphone = device("iPhone")
      androids = for i <- 1..5, do: device("emulator-#{i}", "not installed (ABI mismatch)")

      lines = Deploy.format_summary([iphone], [], androids)
      joined = lines |> Enum.map(&strip_ansi/1) |> Enum.join("\n")

      assert joined =~ "Deployed to 1 device(s)"
      assert joined =~ "Skipped on 5 device(s)"
      refute joined =~ "Failed", "Bug fix: 5 not-installed devices must NOT count as failed"
    end
  end

  # ── failure_message/3 — deploy exit status ────────────────────────────────────
  #
  # Original bug: a run that printed "Failed on 1 device(s)" still exited 0,
  # so CI treated a failed deploy as a success. `failure_message/3` is the
  # decision behind the `Mix.raise` — it must agree with `format_summary/4`
  # about which bucket means failure.

  describe "failure_message/3" do
    test "nothing attempted → no failure" do
      assert Deploy.failure_message([], [], []) == nil
    end

    test "all deployed → no failure" do
      assert Deploy.failure_message([device("iPhone")], [], []) == nil
    end

    test "skipped-because-not-installed is not a failure" do
      skip = device("emulator-5554", "com.example not installed on emulator-5554")
      assert Deploy.failure_message([], [], [skip]) == nil
    end

    test "a skipped device does not absorb a failed one" do
      # The combination the real bug produces — an iPhone that failed and an
      # Android emulator without the app, on one default run — and the only
      # combination no test covered. Two mutations passed the whole describe
      # block without it: an added `failure_message(_, _, [_ | _]), do: nil`
      # clause ("any skip makes the run non-fatal"), and counting
      # `length(failed) + length(skipped)`.
      failed = device("iPhone", "push timed out")
      skipped = device("emulator-5554", "com.example not installed on emulator-5554")

      message = Deploy.failure_message([], [failed], [skipped])

      assert message =~ "Deploy failed on 1 device(s)",
             "the skipped device must neither suppress the failure nor inflate the count"
    end

    test "a failed device produces a message naming the count" do
      message = Deploy.failure_message([], [device("buggy", "push timed out")], [])
      assert message =~ "Deploy failed on 1 device(s)"
    end

    test "partial success still fails — one bad device out of three" do
      deployed = [device("iPhone"), device("emulator-5554")]
      fail = device("emulator-5556", "adb push failed: broken pipe")

      assert Deploy.failure_message(deployed, [fail], []) =~ "Deploy failed on 1 device(s)"
    end

    test "the iPhone bundle-id scenario from the bug report" do
      # `mix mob.deploy --native --device <udid>` installed the app, then the
      # BEAM push hit the wrong bundle id. Summary said "Failed on 1", exit
      # status said 0.
      fail = device("Kevin's iPhone", "App 'com.example.mishka_mob' is not installed")

      assert Deploy.failure_message([], [fail], []) =~ "Deploy failed on 1 device(s)"
    end

    test "counts every failed device, not just the first" do
      failed = for i <- 1..3, do: device("emulator-#{i}", "adb push failed")
      assert Deploy.failure_message([], failed, []) =~ "Deploy failed on 3 device(s)"
    end
  end
end

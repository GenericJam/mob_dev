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
end

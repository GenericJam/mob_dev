defmodule Mix.Tasks.Mob.DeployParsingTest do
  @moduledoc """
  Every invocation this repo prints at a user must actually parse.

  Switching `mix mob.deploy` to strict parsing turned a silent drop into a hard
  failure, which was the point — but it also broke
  `--beam-flags "-S 4:4 -A 4"`, the spelling documented in seven places
  including the README and both battery-bench workflows. The four tests that
  shipped with that change were all source-text assertions and none of them
  ran the parser, so none could have caught it.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Deploy

  defp parse(argv) do
    argv
    |> Deploy.join_dashed_values()
    |> OptionParser.parse(strict: Deploy.switches(), aliases: [d: :device])
  end

  describe "the documented invocations" do
    # Lifted from the moduledoc, README and the two battery-bench tasks. If a
    # switch is renamed or dropped, this fails rather than the docs going stale
    # in silence.
    @documented [
      ~w(--native),
      ~w(--no-restart),
      ~w(--slim),
      ~w(--android),
      ~w(--ios),
      ~w(--native --android),
      ~w(--device ABC123),
      ~w(-d ABC123),
      ~w(--dist-port 9200),
      ~w(--node-suffix sim1),
      ~w(--schedulers 4),
      ~w(--json),
      ["--beam-flags", ""],
      ["--beam-flags", "-S 4:4 -A 4"],
      ["--beam-flags", "+S 4:4"],
      ["--beam-flags=-S 4:4 -A 4"],
      ["--beam-flags", "-S 4:4 -A 8", "--android"]
    ]

    for argv <- @documented do
      test "parses #{inspect(argv)}" do
        assert {_opts, [], []} = parse(unquote(argv))
      end
    end

    test "a dash-prefixed BEAM flag keeps its value intact" do
      # The regression: OptionParser will not consume a dash-prefixed argument
      # as a :string value, so this parsed as two unknown options and aborted a
      # run the README tells you to make.
      assert {[beam_flags: "-S 4:4 -A 4"], [], []} = parse(["--beam-flags", "-S 4:4 -A 4"])
    end

    test "joining only applies to switches whose value is free text" do
      # Doing it for every switch would swallow the flag after a boolean.
      assert {[android: true, ios: true], [], []} = parse(~w(--android --ios))
      assert {[native: true, device: "X"], [], []} = parse(~w(--native --device X))
    end

    test "a `--` separator still ends option parsing" do
      # OptionParser consumes the separator itself and returns the rest as
      # positional. The task rejects positionals, so this is a loud failure
      # rather than a silent deploy-to-everything — which is the point.
      assert {[native: true], ["-S"], []} = parse(~w(--native -- -S))
    end
  end

  describe "what it still refuses" do
    test "an unrecognised flag" do
      assert {_, _, [{"--devcie", _}]} = parse(~w(--devcie X))
    end

    test "a recognised flag with an unparseable value is named with its value" do
      # Reporting `--schedulers abc` as merely "unknown" sends the user to a
      # help page that lists --schedulers, with the bad value discarded.
      assert {_, _, invalid} = parse(~w(--schedulers abc))

      message = Deploy.invalid_options_message(invalid)
      assert message =~ "--schedulers abc"
      assert message =~ "Unrecognized or invalid"
    end

    test "the message does not claim the equals form is required" do
      # It was, before `join_dashed_values/1` landed in the same commit that
      # wrote this advice. Telling someone their working spelling is wrong is
      # its own small version of a tool that lies.
      message = Deploy.invalid_options_message([{"--beam-flags", nil}])

      refute message =~ "equals form"
      assert message =~ "mix help mob.deploy"
    end
  end

  describe "--help" do
    test "the helper recognises both spellings" do
      assert MobDev.TaskHelp.help_requested?(["--help"])
      assert MobDev.TaskHelp.help_requested?(["-h"])
      refute MobDev.TaskHelp.help_requested?(["--device", "x"])
    end
  end
end

defmodule Mix.Tasks.Mob.MutateTest do
  @moduledoc """
  The task half of `mix mob.mutate` — the part that touches the disk and sets
  the exit code.

  A review pointed out that this module shipped with no tests at all, against a
  repo convention of about twenty-five `mob_*_test.exs` files, and that
  everything untested was the file-rewriting and reporting logic. It was also
  invisible to the tool itself at the time, because the heredoc scanner had run
  away on this file's own `\"\"\")` and classified 185 of its 226 lines as prose.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Mutate, as: MutateTask

  describe "source_file?/1" do
    test "accepts the languages a compiler reads" do
      assert MutateTask.source_file?("lib/a.ex")
      assert MutateTask.source_file?("src/b.erl")
      assert MutateTask.source_file?("android/jni/c.zig")
      assert MutateTask.source_file?("ios/d.m")
      assert MutateTask.source_file?("ios/e.swift")
      assert MutateTask.source_file?("app/f.kt")
      assert MutateTask.source_file?("g.h")
    end

    test "rejects everything else" do
      # Without this the branch that added this task mutated CHANGELOG.md and
      # mix.lock line by line: every mutant a guaranteed survivor, the run
      # failing, and mix.lock rewritten while the suite ran against it.
      refute MutateTask.source_file?("CHANGELOG.md")
      refute MutateTask.source_file?("mix.lock")
      refute MutateTask.source_file?("config.json")
      refute MutateTask.source_file?(".github/ci.yml")
      refute MutateTask.source_file?("notes.txt")
    end

    test "a .exs file is not mutated" do
      # Scripts and config are not compiled into the app under test, so a
      # mutant there can never be killed.
      refute MutateTask.source_file?("config/runtime.exs")
    end
  end

  describe "summary/4" do
    defp result(outcome),
      do: %{file: "lib/a.ex", line: 1, operator: :delete_line, label: "x", outcome: outcome}

    test "counts every bucket" do
      results = [
        result(:killed),
        result(:killed),
        result(:survived),
        result(:build_error),
        result(:unmeasured)
      ]

      summary =
        MutateTask.summary(results, "Result: 5 passed", [result(:survived)], [result(:unmeasured)])

      assert summary["killed"] == 2
      assert summary["survived"] == 1
      assert summary["build_errors"] == 1
      assert summary["unmeasured"] == 1
      assert summary["baseline"] == "Result: 5 passed"
      assert summary["outcome"] == "survivors"
    end

    test "a clean run reports ok" do
      summary = MutateTask.summary([result(:killed)], "Result: 1 passed", [], [])
      assert summary["outcome"] == "ok"
    end

    test "the shape is the same when nothing ran" do
      # A consumer reading `.survived` used to get nil on exactly the runs that
      # measured nothing, which are the runs worth noticing.
      empty = MutateTask.summary([], nil, [], [])

      assert Enum.sort(Map.keys(empty)) ==
               Enum.sort(~w(outcome baseline killed survived build_errors unmeasured mutations))

      assert empty["survived"] == 0
      assert empty["mutations"] == []
    end

    test "unmeasured mutants do not count as killed" do
      # The whole point of the bucket: a mutant nobody could measure is not a
      # win, and counting it as one inflates the score in the same way the
      # hardcoded baseline did.
      summary = MutateTask.summary([result(:unmeasured)], "b", [], [result(:unmeasured)])

      assert summary["killed"] == 0
      assert summary["unmeasured"] == 1
    end

    test "each mutation is reported with its outcome" do
      summary = MutateTask.summary([result(:survived)], "b", [result(:survived)], [])

      assert [%{"file" => "lib/a.ex", "line" => 1, "outcome" => "survived"}] =
               summary["mutations"]
    end
  end

  describe "dirty_message/2" do
    # The only thing between an interrupted run and someone's uncommitted work.
    test "a clean tree is allowed" do
      assert MutateTask.dirty_message("", 0) == nil
      assert MutateTask.dirty_message("   \n", 0) == nil
    end

    test "uncommitted changes are refused, and named" do
      message = MutateTask.dirty_message(" M lib/a.ex\n?? lib/b.ex\n", 0)

      assert message =~ "Refusing to mutate"
      assert message =~ "lib/a.ex"
      assert message =~ "git checkout"
    end

    test "a git that will not answer is as disqualifying as a dirty tree" do
      # If we cannot tell whether recovery is possible, proceeding as though it
      # is would be the same optimism that made the docs claim a snapshot that
      # did not exist.
      assert MutateTask.dirty_message("", 128) =~ "clean recovery cannot be guaranteed"
      assert MutateTask.dirty_message("not a git repository", 128) =~ "Refusing"
    end
  end
end

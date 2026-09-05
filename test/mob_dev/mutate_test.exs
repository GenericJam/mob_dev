defmodule MobDev.MutateTest do
  @moduledoc """
  The decision kernel of `mix mob.mutate`.

  This exists because the hand-rolled version of this loop got the baseline
  comparison wrong once, and reported a surviving mutation — a real gap — as
  caught. Everything here is about not repeating that.
  """
  use ExUnit.Case, async: true

  alias MobDev.Mutate

  describe "classify/3" do
    test "an identical result means nothing noticed" do
      assert Mutate.classify("Result: 10 passed", "…", "Result: 10 passed") == :survived
    end

    test "a different result means the suite caught it" do
      assert Mutate.classify("Result: 10 passed", "…", "Result: 9/10 passed") == :killed
    end

    test "off-by-one in the baseline is the whole hazard" do
      # The mistake that motivated this task: comparing a mutant's output
      # against a remembered count rather than a captured one. With a baseline
      # of 11 the surviving mutant below reports as killed, and a real gap
      # ships. Nothing here can prevent a wrong baseline — only capturing it by
      # running can — but the comparison itself must be exact, never fuzzy.
      assert Mutate.classify("Result: 10 passed", "…", "Result: 10 passed") == :survived
      assert Mutate.classify("Result: 11 passed", "…", "Result: 10 passed") == :killed
    end

    test "a build failure is reported apart from a real kill" do
      # It died, but not because a test noticed — that says nothing about test
      # quality, and counting it as a win inflates the score.
      for output <- [
            "** (CompileError) lib/x.ex:3",
            "** (SyntaxError) unexpected end",
            "** (TokenMissingError) missing terminator",
            "Compilation failed due to warnings"
          ] do
        assert Mutate.classify("Result: 10 passed", output, "") == :build_error
      end
    end

    test "a run that could not be measured is not a kill" do
      # `build_error?/1` matches four banners and Mix has more than four ways
      # to fail. Everything else printed no Result: line and was called killed
      # — the same score inflation the :build_error bucket exists to prevent,
      # in a quieter form. The first string below is the one this file already
      # uses as the canonical example of a run that never reported.
      for output <- [
            "** (Mix) Could not compile\n",
            "** (Mix) Could not start application foo\n",
            "** (RuntimeError) test_helper blew up\n"
          ] do
        assert Mutate.classify("Result: 10 passed", output, nil) == :unmeasured
      end

      assert Mutate.classify("Result: 10 passed", "noise", "") == :unmeasured
    end

    test "a build failure outranks a matching result line" do
      assert Mutate.classify("Result: 10 passed", "** (CompileError) x", "Result: 10 passed") ==
               :build_error
    end
  end

  describe "result_line/1" do
    test "finds the ExUnit summary" do
      output = "....\nFinished in 0.2s\nResult: 42 passed (2 doctests), 3 excluded\n"
      assert Mutate.result_line(output) == "Result: 42 passed (2 doctests), 3 excluded"
    end

    test "finds it whatever the indentation or trailing space" do
      # Both the trim_leading and the trim were unguarded: the fixture had the
      # summary at column 0 with no trailing whitespace, so deleting either
      # left the suite green.
      assert Mutate.result_line("   Result: 1 passed") == "Result: 1 passed"
      assert Mutate.result_line("Result: 1 passed   \n") == "Result: 1 passed"
    end

    test "is nil when the run never reported" do
      # The caller must treat this as a failure to measure, not as a pass:
      # a baseline of nil compared against a mutant of nil would call every
      # mutation survived.
      assert Mutate.result_line("** (Mix) Could not compile\n") == nil
    end
  end

  describe "mutable?/1" do
    test "skips blanks and comments" do
      refute Mutate.mutable?("")
      refute Mutate.mutable?("   ")
      refute Mutate.mutable?("  # a comment")
      refute Mutate.mutable?("  // a comment")
      refute Mutate.mutable?("   * doc continuation")
    end

    test "skips bare closing delimiters" do
      # Deleting an `end` is a guaranteed syntax error: reported killed,
      # entirely uninformative, and enough of them bury the survivors.
      for line <- ["end", "  end", "}", "  };", "  )", "  end)", "  }),", "  ]"] do
        refute Mutate.mutable?(line), "#{inspect(line)} should be skipped"
      end
    end

    test "skips a C-style block comment opener" do
      refute Mutate.mutable?("  /* a block comment")
    end

    test "keeps real code, including lines that merely end with a delimiter" do
      assert Mutate.mutable?("  x = compute()")
      assert Mutate.mutable?("  if ready? do")
      assert Mutate.mutable?("    boolAtom(env, Bridge.tap_xy != null),")
    end
  end

  describe "mutations/3" do
    test "deletion is offered for every mutable line" do
      source = "a()\n\nb()\n"
      mutations = Mutate.mutations("x.ex", source)

      deletions = Enum.filter(mutations, &(&1.operator == :delete_line))
      assert Enum.map(deletions, & &1.line) == [1, 3]
      assert Enum.all?(deletions, &(&1.mutated == ""))
    end

    test "booleans and comparisons are flipped" do
      mutations = Mutate.mutations("x.ex", "  assert ready == true\n")
      ops = mutations |> Enum.map(& &1.operator) |> Enum.sort()

      assert ops == [:delete_line, :flip_boolean, :flip_comparison]

      flip = Enum.find(mutations, &(&1.operator == :flip_boolean))
      assert flip.mutated == "  assert ready == false"

      cmp = Enum.find(mutations, &(&1.operator == :flip_comparison))
      assert cmp.mutated == "  assert ready != true"
    end

    test "ordering comparisons flip too" do
      # Found by running the tool on this module: nothing exercised the >= or
      # <= branches, so either could be deleted with the suite green.
      [m] =
        Mutate.mutations("x.ex", "  if a >= b, do: x\n")
        |> Enum.filter(&(&1.operator == :flip_comparison))

      assert m.mutated == "  if a < b, do: x"

      [m] =
        Mutate.mutations("x.ex", "  if a <= b, do: x\n")
        |> Enum.filter(&(&1.operator == :flip_comparison))

      assert m.mutated == "  if a > b, do: x"
    end

    test "false flips to true, and != flips to ==" do
      [m] =
        Mutate.mutations("x.ex", "  assert done == false\n")
        |> Enum.filter(&(&1.operator == :flip_boolean))

      assert m.mutated == "  assert done == true"

      [m] =
        Mutate.mutations("x.ex", "  if a != b, do: x\n")
        |> Enum.filter(&(&1.operator == :flip_comparison))

      assert m.mutated == "  if a == b, do: x"
    end

    test "only the FIRST occurrence on a line is replaced" do
      # `global: false` in the operators. Flipping it changes every occurrence
      # at once, which produces a mutant testing several things and makes a
      # survivor impossible to attribute. The tool found this one on itself:
      # every test until now used a line with a single occurrence.
      [m] =
        Mutate.mutations("x.ex", "  a = true and b == true\n")
        |> Enum.filter(&(&1.operator == :flip_boolean))

      assert m.mutated == "  a = false and b == true",
             "the second `true` must be left alone"

      [m] =
        Mutate.mutations("x.ex", "  a == b and c == d\n")
        |> Enum.filter(&(&1.operator == :flip_comparison))

      assert m.mutated == "  a != b and c == d"
    end

    test "a line with no boolean or comparison offers deletion only" do
      ops = Mutate.mutations("x.ex", "  do_thing()\n") |> Enum.map(& &1.operator)
      assert ops == [:delete_line]
    end

    test "only the requested lines are considered" do
      source = "a()\nb()\nc()\n"
      mutations = Mutate.mutations("x.ex", source, MapSet.new([2]))

      assert Enum.map(mutations, & &1.line) == [2]
    end

    test "the mutation carries the file it belongs to" do
      [m | _] = Mutate.mutations("lib/deep/path.ex", "  go()\n")
      assert m.file == "lib/deep/path.ex"
    end

    test "the label is trimmed of leading indentation" do
      [m | _] = Mutate.mutations("x.ex", "                    go()\n")
      assert m.label == "delete: go()"
    end

    test "the label describes the change, not the position" do
      # The report is read to decide whether a survivor matters, so it has to
      # say what was done.
      [m | _] = Mutate.mutations("x.ex", "  send_the_thing()\n")
      assert m.label =~ "delete"
      assert m.label =~ "send_the_thing()"
    end

    test "a long line is truncated in the label but not in the mutation" do
      long = "  " <> String.duplicate("x", 200)
      [m | _] = Mutate.mutations("x.ex", long <> "\n")

      assert String.length(m.label) < 80
      assert m.original == long
    end

    test "the truncation boundary is exactly 60 characters" do
      # Asserting `length < 80` against a 200-char input left the boundary and
      # the slice width both free to move.
      [at60 | _] = Mutate.mutations("x.ex", String.duplicate("x", 60) <> "\n")
      [at61 | _] = Mutate.mutations("x.ex", String.duplicate("x", 61) <> "\n")

      refute String.ends_with?(at60.label, "..."), "60 characters fits"
      assert at61.label == "delete: " <> String.duplicate("x", 57) <> "..."
    end
  end

  describe "prose and type attributes are not code" do
    # Both of these came from running the tool on itself. Without the first,
    # every line of a @moduledoc is offered as a deletion and every one
    # survives; without the second, every @spec does. Ten survivors, no signal.
    test "heredoc contents are skipped, delimiters included" do
      source = """
      defmodule X do
        @moduledoc \"\"\"
        Prose that no test asserts on.
        \"\"\"
        def go, do: :ok
      end
      """

      lines = Mutate.mutations("x.ex", source) |> Enum.map(& &1.line) |> Enum.uniq()

      refute 2 in lines, "the opening delimiter unbalances the block if deleted"
      refute 3 in lines, "prose is not code"
      refute 4 in lines, "the closing delimiter unbalances the block if deleted"
      assert 5 in lines, "real code after the heredoc must still be mutated"
    end

    test "a type attribute and its continuation lines are skipped" do
      source = """
      defmodule X do
        @spec go(
                integer(),
                atom()
              ) :: :ok
        def go(_a, _b), do: :ok
      end
      """

      lines = Mutate.mutations("x.ex", source) |> Enum.map(& &1.line) |> Enum.uniq()

      for n <- 2..5, do: refute(n in lines, "line #{n} is part of the @spec")
      assert 6 in lines
    end

    test "a single-line spec does not swallow the function below it" do
      source = """
      defmodule X do
        @spec go() :: :ok
        def go, do: :ok
      end
      """

      lines = Mutate.mutations("x.ex", source) |> Enum.map(& &1.line) |> Enum.uniq()

      refute 2 in lines
      assert 3 in lines, "the bracket balance closes on the @spec's own line"
    end

    test "a heredoc closes however the line continues" do
      # The runaway that made this whole scanner untrustworthy: a close was
      # required to END the line, so `\"\"\")` never closed and everything to
      # EOF was treated as prose — 185 of 226 lines of the task module, none of
      # which were ever mutated and none of which appeared in any report.
      delim = String.duplicate("\"", 3)

      for close <- [delim <> ")", delim <> ",", delim <> " <> x"] do
        lines = ["@doc " <> delim, "prose", close, "real_code()"]

        refute MapSet.member?(Mutate.prose_lines(lines), 4),
               "code after a #{inspect(close)} close must still be mutated"
      end
    end

    test "an unbalanced bracket in a doc string cannot eat the module" do
      # `@doc "see foo("` used to put the scanner in :attribute until the
      # brackets happened to balance, which for a real module means never.
      lines = ["@doc \"see foo(\"" | Enum.map(1..60, &"line#{&1}()")]

      skipped = Mutate.prose_lines(lines)

      assert MapSet.size(skipped) < 50, "a stray bracket must cost a bounded number of lines"
      refute MapSet.member?(skipped, 61), "the tail of the module must stay mutable"
    end

    test "prose_lines/1 reports the skipped set directly" do
      lines = ["code()", "@moduledoc \"\"\"", "prose", "\"\"\"", "more_code()"]

      assert Mutate.prose_lines(lines) == MapSet.new([2, 3, 4])
    end

    test "code between two heredocs is still code" do
      lines = ["\"\"\"", "a", "\"\"\"", "real()", "\"\"\"", "b", "\"\"\""]

      refute MapSet.member?(Mutate.prose_lines(lines), 4)
    end
  end

  describe "changed_lines/1" do
    test "reads added lines from a unified diff" do
      diff = """
      diff --git a/lib/a.ex b/lib/a.ex
      --- a/lib/a.ex
      +++ b/lib/a.ex
      @@ -10,0 +11,2 @@
      +added one
      +added two
      """

      assert Mutate.changed_lines(diff) == %{"lib/a.ex" => MapSet.new([11, 12])}
    end

    test "a deleted line contributes nothing — there is no line to mutate" do
      diff = """
      +++ b/lib/a.ex
      @@ -10,2 +11,1 @@
      -gone
      +kept
      """

      assert Mutate.changed_lines(diff) == %{"lib/a.ex" => MapSet.new([11])}
    end

    test "context lines advance the counter without being marked" do
      diff = """
      +++ b/lib/a.ex
      @@ -1,3 +1,3 @@
       context
       context
      +changed
      """

      assert Mutate.changed_lines(diff) == %{"lib/a.ex" => MapSet.new([3])}
    end

    test "several files are kept apart" do
      diff = """
      +++ b/lib/a.ex
      @@ -0,0 +1 @@
      +one
      +++ b/lib/b.ex
      @@ -0,0 +5 @@
      +five
      """

      assert Mutate.changed_lines(diff) == %{
               "lib/a.ex" => MapSet.new([1]),
               "lib/b.ex" => MapSet.new([5])
             }
    end

    test "an empty diff yields nothing" do
      assert Mutate.changed_lines("") == %{}
    end

    test "/dev/null and other non-b/ targets are ignored" do
      # A deleted file's `+++ /dev/null` must not leave the previous file
      # selected, or its additions get attributed to the wrong path.
      diff = """
      +++ b/lib/a.ex
      @@ -0,0 +1 @@
      +kept
      +++ /dev/null
      @@ -0,0 +9 @@
      +orphan
      """

      assert Mutate.changed_lines(diff) == %{"lib/a.ex" => MapSet.new([1])}
    end

    test "a malformed hunk header does not crash or misattribute" do
      diff = """
      +++ b/lib/a.ex
      @@ garbage @@
      +line
      """

      # Counter resets to 0, so the addition lands at line 0 rather than being
      # silently attributed to whatever the previous hunk was counting.
      assert Mutate.changed_lines(diff) == %{"lib/a.ex" => MapSet.new([0])}
    end

    test "a path containing a space keeps its name" do
      # Git appends a tab to the +++ line when the path has a space in it.
      # Left on, File.exists? is false and the file is dropped in silence.
      diff = "+++ b/lib/with space.ex\t\n@@ -0,0 +1 @@\n+one\n"

      assert Mutate.changed_lines(diff) == %{"lib/with space.ex" => MapSet.new([1])}
    end

    test "the no-newline marker is not counted as a line" do
      diff = """
      +++ b/lib/a.ex
      @@ -0,0 +1 @@
      +one
      \\ No newline at end of file
      +two
      """

      assert Mutate.changed_lines(diff) == %{"lib/a.ex" => MapSet.new([1, 2])}
    end
  end
end

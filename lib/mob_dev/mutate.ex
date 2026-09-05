defmodule MobDev.Mutate do
  @moduledoc """
  Mutation testing: change the production code, and see whether the suite
  notices.

  A passing suite says the tests ran. It does not say they *guard* anything.
  The only cheap way to tell the difference is to break the code on purpose and
  check that something goes red — and every place that has been done by hand in
  this project has found real gaps: a `record(...)` that could be deleted from a
  frame tracker with 1500 tests still green, an `-export` line whose removal
  crashes every app at boot and which no assertion noticed, a `requested:`
  option whose deletion silently restored the bug it was added to fix.

  Mob's native assertions make this sharper than usual. They match source text
  with `=~`, which is unusually easy to write vacuously — an assertion satisfied
  by the comment describing the code, or one pinning a rename rather than a
  behaviour. Mutation is what separates those from the real ones.

  ## Known limits

  Deleting a line is blunt on Elixir: removing a `def` head or a middle segment
  of a pipeline is a syntax error, not a test failure. Those are reported as
  `did not build` and counted apart from real kills, because a mutant that
  cannot compile says nothing about the tests. Expect roughly a third of the
  mutants on idiomatic Elixir to land there.

  Mutating a module that itself manipulates source text — this one — produces
  self-referential noise, since its operator table contains the very tokens it
  searches for. That is a curiosity here rather than a problem in general.

  Nothing understands strings: a `" == "` inside a literal is mutated like any
  other. Skipping heredocs and type attributes removes the bulk of that, and
  the rest is cheap enough to read past.

  ## Why this is a task and not a shell loop

  It has been a shell loop, six or seven times, and one of those runs compared
  the mutant's output against a hardcoded expected pass-count that was off by
  one. Every surviving mutation in that run was reported as caught, including a
  real gap. Capturing the baseline by *running* it is the whole difference, and
  it is not something to re-derive under time pressure at the end of a task.
  """

  @typedoc """
  One change to try.

  `line` is 1-indexed into the original file. `label` is what appears in the
  report, so it must describe the change rather than the location.
  """
  @type mutation :: %{
          file: String.t(),
          line: pos_integer(),
          operator: atom(),
          label: String.t(),
          original: String.t(),
          mutated: String.t()
        }

  @doc """
  The mutations worth trying for `source`, restricted to `lines` when given.

  `lines` is the set of 1-indexed line numbers to consider — normally the lines
  a branch changed, so a run reports on the work in hand rather than the whole
  repository.
  """
  @spec mutations(String.t(), String.t(), MapSet.t(pos_integer()) | :all) :: [mutation()]
  def mutations(file, source, lines \\ :all) do
    split = String.split(source, "\n")
    prose = prose_lines(split)

    split
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, n} -> lines == :all or MapSet.member?(lines, n) end)
    |> Enum.reject(fn {_line, n} -> MapSet.member?(prose, n) end)
    |> Enum.flat_map(fn {line, n} -> line_mutations(file, n, line) end)
  end

  @doc """
  Line numbers inside a `\"\"\"` block, which are prose or data rather than code.

  Found by running this tool on itself: without it, every line of a `@moduledoc`
  is offered as a deletion, every one survives — nothing asserts on prose — and
  a report of ten survivors contains ten pieces of noise and no signal. The
  delimiter lines go too, since deleting one unbalances the block and only ever
  produces a syntax error.

  A heredoc is the common case in Elixir; Swift's multi-line literals use the
  same delimiter, so the same scan covers both.
  """
  # A doc string mentioning an unbalanced bracket — `@doc "see foo("` — would
  # otherwise swallow the rest of the module the way the heredoc bug did. Give
  # the attribute state a small budget and fall back to code rather than eating
  # everything after it.
  @attribute_line_budget 40

  @spec prose_lines([String.t()]) :: MapSet.t(pos_integer())
  def prose_lines(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce({:code, 0, MapSet.new()}, &scan_prose/2)
    |> elem(2)
  end

  # Two states beyond code: inside a heredoc, and inside a type/spec attribute
  # that may wrap over several lines. Both are skipped for the same reason —
  # `mix test` cannot notice their absence, so every deletion survives and the
  # report fills with findings that mean nothing. A `@spec` IS checked, by
  # Dialyzer, which is a different tool answering a different question.
  defp scan_prose({line, n}, {:heredoc, _depth, acc}) do
    if closes_heredoc?(String.trim(line)),
      do: {:code, 0, MapSet.put(acc, n)},
      else: {:heredoc, 0, MapSet.put(acc, n)}
  end

  defp scan_prose({line, n}, {:attribute, budget, acc}) do
    cond do
      budget <= 0 -> {:code, 0, acc}
      bracket_delta(line) + budget_depth(budget) <= 0 -> {:code, 0, MapSet.put(acc, n)}
      true -> {:attribute, budget - 1, MapSet.put(acc, n)}
    end
  end

  defp scan_prose({line, n}, {:code, _depth, acc}) do
    trimmed = String.trim(line)

    cond do
      opens_heredoc?(trimmed) and not closes_heredoc?(trimmed) ->
        {:heredoc, 0, MapSet.put(acc, n)}

      type_attribute?(trimmed) ->
        if bracket_delta(line) <= 0,
          do: {:code, 0, MapSet.put(acc, n)},
          else: {:attribute, @attribute_line_budget, MapSet.put(acc, n)}

      true ->
        {:code, 0, acc}
    end
  end

  # The budget counts down rather than tracking exact depth, so a stray bracket
  # costs at most @attribute_line_budget lines instead of a whole module.
  defp budget_depth(_budget), do: 1

  # Opening and closing are NOT the same test, and treating them as one is how
  # this scanner ran away twice.
  #
  # An opening delimiter ends the line: `@doc """`. A closing one begins the
  # line's content, and may be followed by anything — `""")`, `""",`,
  # `""" <> x`. Requiring the close to also end the line meant `""")` never
  # closed, and the scanner stayed inside the heredoc to end of file: 185 of
  # this task module's 226 lines were classified as prose and silently never
  # mutated. That is the dangerous direction, because a region that is skipped
  # produces no mutants, no report line, and a clean bill of health.
  #
  # Counting occurrences was the first attempt and was worse: `~s(\"\"\")` here
  # mentions the delimiter without being one.
  defp opens_heredoc?(trimmed), do: String.ends_with?(trimmed, heredoc_delimiter())
  defp closes_heredoc?(trimmed), do: String.starts_with?(trimmed, heredoc_delimiter())

  defp heredoc_delimiter, do: <<34, 34, 34>>

  @type_attributes ~w(@spec @type @typep @opaque @typedoc @doc @moduledoc @callback @macrocallback)

  defp type_attribute?(trimmed),
    do: Enum.any?(@type_attributes, &String.starts_with?(trimmed, &1 <> " "))

  defp bracket_delta(line) do
    counts = fn char -> line |> String.graphemes() |> Enum.count(&(&1 == char)) end
    counts.("(") - counts.(")") + counts.("{") - counts.("}") + counts.("[") - counts.("]")
  end

  defp line_mutations(file, n, line) do
    if mutable?(line) do
      operators()
      |> Enum.flat_map(fn {operator, fun} ->
        case fun.(line) do
          nil -> []
          mutated -> [build(file, n, operator, line, mutated)]
        end
      end)
    else
      []
    end
  end

  defp build(file, n, operator, original, mutated) do
    %{
      file: file,
      line: n,
      operator: operator,
      label: label_for(operator, original),
      original: original,
      mutated: mutated
    }
  end

  defp label_for(:delete_line, original), do: "delete: #{trim(original)}"
  defp label_for(:flip_boolean, original), do: "flip boolean: #{trim(original)}"
  defp label_for(:flip_comparison, original), do: "flip comparison: #{trim(original)}"

  defp trim(line) do
    line = String.trim(line)
    if String.length(line) > 60, do: String.slice(line, 0, 57) <> "...", else: line
  end

  # Deleting a line is the highest-signal operator by a distance: it asks "does
  # anything at all notice that this line exists?", which is the question a
  # vacuous test fails. The others catch narrower defects that a deletion would
  # also catch but which are easier to read in a report.
  defp operators do
    [
      {:delete_line, fn _line -> "" end},
      {:flip_boolean, &flip_boolean/1},
      {:flip_comparison, &flip_comparison/1}
    ]
  end

  defp flip_boolean(line) do
    cond do
      String.contains?(line, " true") -> String.replace(line, " true", " false", global: false)
      String.contains?(line, " false") -> String.replace(line, " false", " true", global: false)
      true -> nil
    end
  end

  defp flip_comparison(line) do
    cond do
      String.contains?(line, " == ") -> String.replace(line, " == ", " != ", global: false)
      String.contains?(line, " != ") -> String.replace(line, " != ", " == ", global: false)
      String.contains?(line, " >= ") -> String.replace(line, " >= ", " < ", global: false)
      String.contains?(line, " <= ") -> String.replace(line, " <= ", " > ", global: false)
      true -> nil
    end
  end

  @doc """
  Whether a line is worth mutating.

  Blank lines, comments and bare closing delimiters are skipped. Deleting an
  `end` or a `}` is a guaranteed syntax error, which the runner would report as
  killed — technically true and completely uninformative, and enough of them
  drown the survivors that matter.
  """
  @spec mutable?(String.t()) :: boolean()
  def mutable?(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> false
      comment?(trimmed) -> false
      closing_delimiter?(trimmed) -> false
      true -> true
    end
  end

  defp comment?(line) do
    String.starts_with?(line, "#") or String.starts_with?(line, "//") or
      String.starts_with?(line, "*") or String.starts_with?(line, "/*")
  end

  # `end`, `}`, `)`, `};`, `end)`, `}),` and friends — a line that is only
  # structure.
  defp closing_delimiter?(line), do: Regex.match?(~r/^(end|[\}\)\]][\,\;\)]*)+$/, line)

  @doc """
  Classify one mutant's outcome by comparing against the captured baseline.

  `baseline` must be the output of actually running the suite on unmutated
  code. Comparing against a remembered or hardcoded value is the mistake this
  module exists to stop making: a baseline that is wrong by one test reports
  every survivor as killed.

  * `:survived` — identical result, so nothing noticed the change.
  * `:killed` — the suite went red, which is what should happen.
  * `:build_error` — it did not compile. The mutant died, but that says nothing
    about test quality, so it is reported separately rather than counted as a
    win.
  * `:unmeasured` — the run printed no result and named no build error we
    recognise. Counting that as a kill is the same score inflation in a
    quieter form: the safe answer to "I could not measure this" is to say so.
    `build_error?/1` matches four banners, and Mix has more than four ways to
    fail.
  """
  @spec classify(String.t(), String.t(), String.t() | nil) ::
          :survived | :killed | :build_error | :unmeasured
  def classify(baseline, output, result_line) do
    cond do
      build_error?(output) -> :build_error
      result_line in [nil, ""] -> :unmeasured
      result_line == baseline -> :survived
      true -> :killed
    end
  end

  defp build_error?(output) do
    String.contains?(output, "** (CompileError)") or
      String.contains?(output, "** (SyntaxError)") or
      String.contains?(output, "** (TokenMissingError)") or
      String.contains?(output, "Compilation failed")
  end

  @doc """
  The `Result:` line ExUnit prints, or `nil` when it printed none.

  `nil` means the run did not get as far as reporting, which the caller must
  treat as a failure to measure rather than as a passing baseline.
  """
  @spec result_line(String.t()) :: String.t() | nil
  def result_line(output) do
    output
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(String.trim_leading(&1), "Result:"))
    |> case do
      nil -> nil
      line -> String.trim(line)
    end
  end

  @doc """
  Line numbers `diff` adds or changes, per file.

  Reads a unified diff and follows the `@@` hunk headers, counting only the
  lines present in the new file — a deleted line has no line to mutate.
  """
  @spec changed_lines(String.t()) :: %{String.t() => MapSet.t(pos_integer())}
  def changed_lines(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({nil, 0, %{}}, &scan_diff_line/2)
    |> elem(2)
  end

  # Git appends a tab when the path contains a space. Left on, `File.exists?`
  # is false and the file is dropped without a word — a silently skipped file
  # is the same harm as a silently skipped region.
  defp scan_diff_line("+++ b/" <> path, {_file, _n, acc}),
    do: {String.trim_trailing(path, "\t"), 0, acc}

  defp scan_diff_line("+++ " <> _, {_file, _n, acc}), do: {nil, 0, acc}

  defp scan_diff_line("@@" <> _ = header, {file, _n, acc}) do
    case Regex.run(~r/^@@ -\d+(?:,\d+)? \+(\d+)/, header) do
      [_, start] -> {file, String.to_integer(start), acc}
      _ -> {file, 0, acc}
    end
  end

  defp scan_diff_line("+" <> _, {nil, n, acc}), do: {nil, n, acc}

  defp scan_diff_line("+" <> _, {file, n, acc}),
    do: {file, n + 1, Map.update(acc, file, MapSet.new([n]), &MapSet.put(&1, n))}

  defp scan_diff_line("-" <> _, {file, n, acc}), do: {file, n, acc}
  defp scan_diff_line("\\" <> _, {file, n, acc}), do: {file, n, acc}
  defp scan_diff_line(_context, {file, n, acc}), do: {file, n + 1, acc}
end

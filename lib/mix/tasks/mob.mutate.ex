defmodule Mix.Tasks.Mob.Mutate do
  @shortdoc "Break the code on purpose and check the tests notice"

  @moduledoc """
  Mutation-test the lines this branch changed.

      mix mob.mutate                      # lines changed vs origin/master
      mix mob.mutate --file lib/foo.ex    # every mutable line in one file
      mix mob.mutate --base HEAD~3        # against a different base
      mix mob.mutate --json

  A green suite says the tests ran, not that they guard anything. This changes
  the production code one line at a time and reports the changes nothing
  noticed.

  ## Options

    * `--file PATH`     — mutate this file instead of the branch diff; repeatable
    * `--base REF`      — diff base (default: `origin/master`)
    * `--test-command`  — how to run the suite (default: `mix test`). Narrow it
                          when the full suite is slow: every mutant runs it once.
    * `--max N`         — stop after N mutants
    * `--json`          — machine-readable result on stdout, progress on stderr

  ## Running it on this task

  It reports most of `run/1` as surviving, and that is accurate rather than a
  bug in either. This repo's convention is that a Mix task stays a thin
  unstubbed I/O wrapper and the decisions get extracted and tested — so the
  parts with a testable kernel (`source_file?/1`, `summary/4`,
  `dirty_message/2`, and everything in `MobDev.Mutate`) are guarded, and the
  orchestration that only sequences them is not. The tool measures what the
  suite guards; it does not know what you decided not to guard.

  ## Exit status

  Non-zero when any mutation survived, so this can gate a change the way a
  failing test does.

  ## What it does to your working tree

  It rewrites real source files in place and restores them from memory after
  each mutant. **An interrupted run leaves the last mutant on disk** — Ctrl-C,
  a closed terminal and an OOM kill all skip the restore, and no amount of
  in-process care changes that.

  So the run refuses to start unless the files it would touch are clean in git.
  That way `git checkout -- <file>` is always a complete recovery, which is the
  only guarantee that survives being killed outright. An earlier version of
  this text claimed a snapshot restored the tree "even if the run is
  interrupted"; there was no snapshot, the claim was false, and it talked the
  reader out of the one habit that would have saved them.
  """

  use Mix.Task

  alias MobDev.Mutate

  @switches [file: :keep, base: :string, test_command: :string, max: :integer, json: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    unless invalid == [] do
      Mix.raise("Unknown option(s): #{invalid |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
    end

    if opts[:json], do: Process.put(:mutate_stdout, Process.group_leader())
    if opts[:json], do: Process.group_leader(self(), Process.whereis(:standard_error))

    test_command = opts[:test_command] || "mix test"
    mutations = collect(opts)
    refuse_if_dirty!(mutations)

    if mutations == [] do
      say("Nothing to mutate — no changed production lines found.")
      emit(opts, summary([], nil, [], []))
    else
      run_all(mutations, test_command, opts)
    end
  end

  defp run_all(mutations, test_command, opts) do
    say("Capturing the baseline (#{test_command})...")

    # Run it. A remembered or hardcoded baseline is exactly how a surviving
    # mutation gets reported as caught, which has happened.
    {output, _code} = shell(test_command)

    case Mutate.result_line(output) do
      nil ->
        # Emit before raising: --json producing nothing at all on the failure
        # this design cares most about leaves a caller parsing prose.
        emit(opts, Map.put(summary([], nil, [], []), "outcome", "no_baseline"))

        Mix.raise("""
        The baseline run printed no `Result:` line, so there is nothing to
        compare mutants against. Fix the suite first — a mutation run against a
        broken baseline reports every mutant as killed.

        Command: #{test_command}
        """)

      baseline ->
        say("Baseline: #{baseline}\n")
        results = Enum.map(mutations, &evaluate(&1, baseline, test_command))
        report(results, baseline, opts)
    end
  end

  defp evaluate(mutation, baseline, test_command) do
    original = File.read!(mutation.file)

    outcome =
      try do
        apply_mutation!(mutation, original)
        {output, _code} = shell(test_command)
        Mutate.classify(baseline, output, Mutate.result_line(output))
      after
        restore!(mutation.file, original)
      end

    say(" #{pad(outcome)} #{mutation.file}:#{mutation.line}  #{mutation.label}")
    Map.put(mutation, :outcome, outcome)
  end

  defp apply_mutation!(mutation, original) do
    lines = String.split(original, "\n")

    unless Enum.at(lines, mutation.line - 1) == mutation.original do
      raise "#{mutation.file}:#{mutation.line} changed under us — refusing to mutate"
    end

    lines
    |> List.replace_at(mutation.line - 1, mutation.mutated)
    |> Enum.join("\n")
    |> then(&File.write!(mutation.file, &1))
  end

  # Restoration is the one step that must not fail quietly: a half-restored
  # tree looks like your own edit and is found much later, in a diff.
  defp restore!(file, original) do
    File.write!(file, original)

    if File.read!(file) != original do
      Mix.raise("FAILED TO RESTORE #{file} — check `git diff` before doing anything else")
    end
  end

  # The only recovery that survives a kill -9 is `git checkout`, and that only
  # works if the file had nothing uncommitted in it to begin with. Refusing up
  # front is cheaper than any amount of in-process restore logic, and it also
  # closes the case where an editor autosaves mid-mutant: `restore!` would
  # happily overwrite that edit with the pre-run copy and verify successfully,
  # since it compares against its own snapshot.
  defp refuse_if_dirty!([]), do: :ok

  defp refuse_if_dirty!(mutations) do
    files = mutations |> Enum.map(& &1.file) |> Enum.uniq()

    {out, status} =
      System.cmd("git", ["status", "--porcelain", "--"] ++ files, stderr_to_stdout: true)

    case dirty_message(out, status) do
      nil -> :ok
      message -> Mix.raise(message)
    end
  end

  @doc """
  The refusal for a tree that is not safe to mutate, or `nil`.

  Pure, and tested, because it is the only thing standing between an
  interrupted run and someone's uncommitted work. A `git status` that fails is
  as disqualifying as one that reports changes: if we cannot tell whether
  recovery is possible, we must not proceed as though it is.
  """
  @spec dirty_message(String.t(), non_neg_integer()) :: String.t() | nil
  def dirty_message(_output, status) when status != 0,
    do: "`git status` failed, so a clean recovery cannot be guaranteed. Refusing to mutate."

  def dirty_message(output, _status) do
    case String.trim(output) do
      "" ->
        nil

      changes ->
        """
        Refusing to mutate files with uncommitted changes.

        #{changes}

        An interrupted run leaves the last mutant on disk — Ctrl-C, a closed
        terminal and an OOM kill all skip the restore. The only recovery that
        survives being killed outright is `git checkout -- <file>`, and that
        would take your uncommitted work with it. Commit or stash first.
        """
    end
  end

  defp collect(opts) do
    case Keyword.get_values(opts, :file) do
      [] -> from_diff(opts)
      files -> Enum.flat_map(files, &Mutate.mutations(&1, File.read!(&1), :all))
    end
    |> limit(opts[:max])
  end

  defp limit(mutations, nil), do: mutations

  defp limit(mutations, max) do
    dropped = length(mutations) - max

    if dropped > 0 do
      # Say what was left out. A capped run that reads as a clean sweep is the
      # same lie as a deploy that exits 0 having shipped nothing.
      say("Capped at #{max} mutants — #{dropped} not run.\n")
    end

    Enum.take(mutations, max)
  end

  defp from_diff(opts) do
    base = opts[:base] || "origin/master"

    # One diff, one coordinate system. Concatenating `base...HEAD` with a
    # working-tree diff mixed HEAD-relative and index-relative line numbers, so
    # any uncommitted insertion silently shifted the branch-diff lines onto the
    # wrong code — and the drift guard in `apply_mutation!/2` cannot catch it,
    # because it reads the current file too.
    #
    # `HEAD` rather than a bare `git diff` also picks up staged work, which is
    # otherwise invisible: on a fully staged branch the default mode found
    # nothing to mutate and called it success.
    diff =
      git!(["diff", "--unified=0", base, "--"]) <> "\n" <> git!(["diff", "--unified=0", "HEAD"])

    diff
    |> Mutate.changed_lines()
    |> Enum.reject(fn {file, _} ->
      test_file?(file) or not source_file?(file) or not File.exists?(file)
    end)
    |> Enum.flat_map(fn {file, lines} -> Mutate.mutations(file, File.read!(file), lines) end)
  end

  # Mutating a test proves nothing about the tests.
  defp test_file?(path),
    do: String.starts_with?(path, "test/") or String.ends_with?(path, "_test.exs")

  # A whitelist, not a blacklist: anything a compiler does not read produces a
  # mutant no test can possibly kill. Without this, a branch that touches
  # CHANGELOG.md or mix.lock — as the branch adding this task does — reports a
  # wall of guaranteed survivors, fails, and rewrites mix.lock line by line
  # while running the suite against it.
  @source_extensions ~w(.ex .erl .zig .m .mm .swift .kt .java .h .c .cc .cpp)

  @doc false
  @spec source_file?(String.t()) :: boolean()
  def source_file?(path), do: Path.extname(path) in @source_extensions

  # A git failure that gets parsed as an empty diff reports a clean sweep and
  # exits 0 — a typo'd --base, a missing origin/master on a fresh clone, or a
  # shallow CI checkout all measure nothing and call it "ok". That is the exact
  # defect this repo fixed in `mix mob.deploy` one release ago.
  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> Mix.raise("`git #{Enum.join(args, " ")}` failed (#{status}):\n\n#{out}")
    end
  end

  defp report(results, baseline, opts) do
    by = fn outcome -> Enum.filter(results, &(&1.outcome == outcome)) end
    survived = by.(:survived)
    unmeasured = by.(:unmeasured)

    say("")

    say(
      "#{length(by.(:killed))} killed, #{length(survived)} survived, " <>
        "#{length(by.(:build_error))} did not build, #{length(unmeasured)} unmeasured"
    )

    list("Nothing noticed these changes:", survived)
    list("Could not be measured — the run reported no result:", unmeasured)

    emit(opts, summary(results, baseline, survived, unmeasured))

    unless survived == [] do
      Mix.raise("#{length(survived)} mutation(s) survived — see the list above")
    end
  end

  defp list(_heading, []), do: :ok

  defp list(heading, mutations) do
    say("\n#{heading}\n")
    Enum.each(mutations, &say("  #{&1.file}:#{&1.line}  #{&1.label}"))
  end

  @doc false
  # One shape for every exit, so a consumer reading `.survived` never gets nil
  # on the runs that measured nothing — which are exactly the runs worth
  # noticing.
  @spec summary([map()], String.t() | nil, [map()], [map()]) :: map()
  def summary(results, baseline, survived, unmeasured) do
    count = fn outcome -> Enum.count(results, &(&1.outcome == outcome)) end

    %{
      "outcome" => if(survived == [], do: "ok", else: "survivors"),
      "baseline" => baseline,
      "killed" => count.(:killed),
      "survived" => length(survived),
      "build_errors" => count.(:build_error),
      "unmeasured" => length(unmeasured),
      "mutations" => Enum.map(results, &json_mutation/1)
    }
  end

  defp json_mutation(m) do
    %{
      "file" => m.file,
      "line" => m.line,
      "operator" => to_string(m.operator),
      "label" => m.label,
      "outcome" => to_string(m.outcome)
    }
  end

  defp emit(opts, payload) do
    if opts[:json] do
      IO.puts(Process.get(:mutate_stdout, :standard_io), Jason.encode!(payload, pretty: true))
    end
  end

  defp pad(:survived), do: "SURVIVED"
  defp pad(:killed), do: "killed  "
  defp pad(:build_error), do: "no build"
  defp pad(:unmeasured), do: "no result"

  defp say(message), do: IO.puts(message)

  defp shell(command) do
    System.cmd("sh", ["-c", command], stderr_to_stdout: true)
  end
end

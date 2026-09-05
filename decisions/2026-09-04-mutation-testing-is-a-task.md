# Mutation testing ships as a Mix task

- Date: 2026-09-04
- Status: accepted

## Context

Mutation testing has been done by hand in these repos maybe seven times, always
as an ad-hoc shell loop written fresh: capture a baseline, edit a line, run the
suite, compare, restore. It has found real defects every time — a `record(...)`
that could be deleted from a frame tracker with 1500 tests green, an `-export`
line whose removal fails `load_nif` and crash-loops every app at boot, a
`requested:` option whose deletion silently restored the bug it was added to
fix. None of those were caught by review; all were caught by mutation.

It has also been got wrong. One run compared each mutant's output against a
hardcoded expected pass-count that was off by one, so every mutant that
*survived* was reported as caught — including a genuine gap. The loop is short
enough to feel safe to rewrite and just subtle enough to get wrong under time
pressure at the end of a task, which is exactly when it gets written.

Mob's native assertions raise the stakes. They match source text with `=~`,
which is unusually easy to write vacuously: an assertion satisfied by the
comment describing the code, or one pinning a rename rather than a behaviour.
Mutation is the only cheap way to tell those from the real ones.

## Decision

Ship it as `mix mob.mutate`, with the decision kernel in `MobDev.Mutate` and
the I/O in the task.

The baseline is always captured by running the suite, never supplied. A run
whose baseline produced no `Result:` line refuses to continue rather than
treating "no output" as a passing baseline — that comparison is the whole
failure mode this exists to prevent.

Three outcomes, not two. `killed` and `survived` are the answer; `did not
build` is reported separately because a mutant that fails to compile died
without any test noticing, and counting it as a win inflates the score. On
idiomatic Elixir roughly a third of line-deletions land there.

Heredocs and type attributes are skipped. Both were found by running the tool
on itself: without them every line of a `@moduledoc` and every `@spec` is
offered as a deletion, every one survives — nothing asserts on prose, and
`mix test` does not check specs — and the report becomes noise with the real
findings buried in it. A `@spec` *is* checked, by Dialyzer, which is a
different tool answering a different question.

Default scope is the branch diff rather than the whole repo, so a run reports
on the work in hand. `--file` overrides it.

## Consequences

Every mutant runs the suite once, so the cost is `mutations × suite`. That is
why `--test-command` exists: narrow it, and the loop is usable interactively.
`--max` bounds a run and says how many were dropped, because a capped run that
reads as a clean sweep is the same lie as a deploy that exits 0 having shipped
nothing.

It rewrites real files. Contents are held in memory and restored after each
mutant, and a failed restore raises loudly rather than leaving a half-restored
tree to be found later in a diff.

Nothing here understands strings, so a `" == "` inside a literal is mutated
like any other. Skipping heredocs removes most of that; the rest is cheap to
read past.

Building it found four defects in itself — prose mutation, spec mutation, a
heredoc scanner desynchronised by its own source mentioning the delimiter, and
six untested branches in its own diff parser.

That sentence originally ended the record, as a validation of the tool. A
review then showed it was worth much less than it read as: the same heredoc
scanner never closed on `\"\"\")`, which is the form this task's own
`Mix.raise("""…""")` uses, so it stayed inside the heredoc to end of file and
classified 185 of the task module's 226 lines as prose. Two thirds of the
riskiest code in the change — the file rewriting and the restore — was
invisible to the tool while "we ran it on itself" was being written down.

The direction of that failure is the lesson. A scanner desync SKIPS code, so
the mutants are never generated, never run, and never reported: the output is
indistinguishable from a clean bill of health. Mutating prose is noisy and
obvious; skipping code is silent and reassuring. Where the two trade off, this
tool should prefer the noise, and the closing test is now deliberately lax
(`starts_with?`) while the opening one stays strict.

Two further findings from the same review were the module's own thesis turned
back on it. `classify/3` defaulted a mutant it could not measure to `killed` —
score inflation of exactly the kind the hardcoded baseline produced — and now
reports `:unmeasured`. And `from_diff/1` swallowed git's exit status, so a
typo'd `--base` or a missing `origin/master` measured nothing and reported
`"outcome": "ok"`, which is the defect this repo fixed in `mix mob.deploy` one
release earlier.

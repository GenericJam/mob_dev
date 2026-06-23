# Scaffolded plugins derive their mob version requirement

- Date: 2026-06-22
- Status: accepted

## Context

`mix mob.new_plugin` (via `MobDev.Plugin.Scaffold`) hard-coded the mob
dependency requirement in two places: `{:mob, "~> 0.6"}` in the generated
`mix.exs` and `mob_version: "~> 0.6"` in each tier's `priv/mob_plugin.exs`
manifest. Published mob is 0.7.x, so a freshly scaffolded plugin failed
activation with `installed :mob 0.7.x does not satisfy mob_version "~> 0.6"`,
and `mix deps.get` resolved a stale mob. Reported as issue #21, surfaced by the
mob_ci harness which dogfoods `mob.new_plugin --tier 0..4` and had to hand-bump
the generated fixtures.

The literal also lived in five separate template strings, so the two pins could
drift apart and nothing caught a stale value before a user hit it.

## Decision

Derive the requirement instead of hard-coding it.

- `Scaffold.mob_requirement/1` (pure) maps a concrete version to `"~> MAJOR.MINOR"`,
  or returns the compiled `@fallback_mob_requirement` on `nil`.
- `Scaffold.detect_mob_requirement/0` (impure) prefers the version of `:mob`
  actually resolved in the current project (`Application.spec(:mob, :vsn)` after
  `Application.load/1`), falling back to the constant when mob isn't loadable
  (scaffolding standalone, outside a host app). The `mix mob.new_plugin` task
  calls this and threads the result into `Scaffold.files_for/3`; the templates
  stay pure and unit-testable.
- A single `@fallback_mob_requirement "~> 0.7"` is the only literal; `mix.exs`
  and all manifests interpolate the threaded value, so they can't disagree.
- A `Scaffold` test pins the default to a parseable `~> X.Y`, asserts every
  tier's `mix.exs` and manifest agree, asserts it is not the abandoned `~> 0.6`,
  and validates a generated manifest against a version that satisfies the default
  (derived from the requirement, so the test tracks future bumps).

## Consequences

- A plugin scaffolded inside a mob 0.7.x app pins `"~> 0.7"`; one scaffolded with
  no mob present gets the constant. Both activate against current mob.
- When mob's major.minor moves again, bump `@fallback_mob_requirement` — the
  test guards against silently shipping the old floor, but the constant still
  needs a human bump (mob_dev does not depend on mob, so CI here can't compare
  against the latest published mob automatically).
- `files_for/2` callers keep working via the defaulted third argument.

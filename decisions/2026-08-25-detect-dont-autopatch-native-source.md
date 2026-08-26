# Already-generated apps get a `mix mob.doctor` warning, not an auto-patch

- Date: 2026-08-25
- Status: accepted

## Context

MOB-98's Android JNI owner mismatch (`nativeDeliverComponentEvent`
declared on the wrong Kotlin object) was fixed in `mob_new`'s
`MobBridge.kt.eex` template, but that fix only reaches projects
generated *after* the fix lands — `mix mob.new` renders the template
once at generation time; nothing re-syncs an already-generated app's
`MobBridge.kt` when the template changes later. Every prior template
fix in this repo has hit the same shape (see `enable.ex`'s
`detect_stale_pythonx_templates/2`, which predates this decision by
inheriting the pattern without writing it down).

The tempting fix is a blind overwrite: detect the stale pattern, patch
it, done. That's wrong here specifically because `MobBridge.kt` (and
the other native template outputs) are **hand-editable** — a real app
routinely customizes them after generation. A blind overwrite risks
silently destroying those edits, which is a far worse failure mode
than "the fix requires a manual step."

## Decision

Detect known template drift and **warn with fix instructions**; never
auto-patch native source a user may have hand-edited. This repo now
has two instances of the pattern:

- `MobDev.Enable.detect_stale_pythonx_templates/2`, wired into `mix
  mob.enable`'s python check — reports missing blocks, tells the user
  to regenerate or copy the block from the template.
- `Mix.Tasks.Mob.Doctor.check_component_event_jni/0` (this file) —
  reports the pre-fix JNI declaration shape, tells the user to port
  the fix from a fresh `mix mob.new` app or `mob_new`'s
  `MobBridge.kt.eex` directly.

Any future "template fixed, existing apps still broken" situation
should follow this same shape: a pure detection function + a `mix
mob.doctor` (or equivalent) warning with the concrete fix, not an
auto-patch.

## Consequences

- A user must take a manual step (hand-port, or regenerate and
  re-apply their own customizations) to receive a template fix in an
  existing project. This is real friction, accepted deliberately in
  exchange for never risking a silent overwrite of hand-edited native
  code.
- Detection logic (e.g.
  `Mix.Tasks.Mob.Doctor.__component_event_jni_mismatched__/1`) must
  stay tolerant of reasonable hand-applied variations of the fix (e.g.
  an annotation on its own line vs. the same line as the declaration)
  — a false positive here tells a user "still broken" forever, since
  `mix mob.doctor` only warns and never re-checks itself against a fix
  it can't see was actually applied.
- If template drift becomes common enough that manual porting is a
  recurring burden, the next step is a real diff/merge mechanism
  (unlike `on_exists: :skip`, which `mix mob.adopt`'s installers use
  today only for filling in *missing* files, not re-syncing changed
  ones) — not attempted here; out of scope for this decision.

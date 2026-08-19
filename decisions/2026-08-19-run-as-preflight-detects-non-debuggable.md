# ERTS preflight detects `run-as` failure, not just missing ERTS

- Date: 2026-08-19
- Status: accepted

## Context

Debugging a slow cold-boot in a downstream app (mishka_mob), an
incremental `mix mob.deploy` reported `✓` on every push, but a fresh
timing-instrumentation edit never showed up in device logs. The
installed APK turned out to be non-debuggable (built by an earlier,
unrelated native build), so every `run-as`-based push step failed —
but silently.

`ensure_erts_on_device/2` already ran a `run-as #{pkg} sh -c 'ls
.../erl_child_setup'` preflight and inspected its output, but only for
`"No such file"` / `"not found"` (a missing-ERTS signature). A
`run-as: package not debuggable: <pkg>` response matched neither
branch, so the preflight returned `:ok` and `deploy_android` proceeded
into the real push steps. Those shell out to `run-as #{pkg} tar xf ...
2>/dev/null; true` — the trailing `; true` exists to swallow Toybox
tar's benign chown-to-macOS-UID exit code, but it swallows a genuine
`run-as` failure just as well. Net effect: `mix mob.deploy` claimed
success while nothing reached the device, for as long as the installed
build stayed non-debuggable.

## Decision

Extend `ensure_erts_on_device/2`'s output check to also detect any
`run-as:`-prefixed response and return a distinct, actionable
`{:error, _}` (rebuild via `mix mob.deploy --native` to get a
debuggable install) — before any push is attempted. Left the `; true`
tar-chown workaround untouched; the fix is a preflight check ahead of
it, not a change to the push mechanism itself.

## Consequences

- A non-debuggable install now fails loudly and immediately, with a
  fix in the error message, instead of silently no-op'ing every push
  until someone notices code changes aren't taking effect.
- Doesn't address *why* a `mix mob.deploy --native` build can end up
  non-debuggable in the first place (Gradle's `debug` build type
  defaults `debuggable=true`; the affected app's installed APK
  predated this investigation and its provenance wasn't established).
  If this recurs, that's the next thread to pull.

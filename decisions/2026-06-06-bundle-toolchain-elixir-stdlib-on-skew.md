# Bundle the toolchain's Elixir stdlib, not a stale mob.exs pin, on version skew

- Date: 2026-06-06
- Status: accepted

## Context

`native_build.ex` `resolve_elixir_lib/1` decided which Elixir stdlib to bundle
into the device app from mob.exs `elixir_lib`, honoring the configured path as
long as it *existed on disk* — it never checked the lib's Elixir version.

The app's `.beam` files are compiled by the toolchain that runs `mix`
(`System.version()`). Macros baked into those BEAMs (Ecto.Migration, regex
literals, …) emit calls into compiler internals that move between versions. A
stale or mispinned `elixir_lib` bundles a stdlib whose internals don't match the
compiled BEAMs. The skew is invisible until the app compiles an `.exs` at runtime
on-device (an Ecto migration) and dies with `undef`.

Real instance: mob_plugin_demo's mob.exs pinned `1.20.0-rc.5` while the active
mise toolchain resolved to `1.20.0` final. `:elixir_quote.validate_quote/1` was
added between rc.5 and final, so the rc.5-compiled compiler on-device couldn't
expand the final-compiled `Ecto.Migration` macro — tier-3 plugin migrations
failed on iOS. Android never hit it: `sync_elixir_stdlib_android` auto-detects
the lib from the running BEAM (`:code.lib_dir`), so it always ships whatever
compiled the app.

## Decision

`resolve_elixir_lib/1` now reads the configured lib's version from
`<lib>/elixir/ebin/elixir.app` and compares it to `System.version()`:

- match (or unreadable version) → honor the configured path
- version skew → warn loudly and fall back to `detect_elixir_lib()` (the
  running-BEAM lib, which matches the compiler by definition)
- missing path → detect (unchanged)

The decision is a pure kernel `__elixir_lib_decision__/3` with a pure message
builder `__elixir_lib_skew_warning__/4`, both `@doc false` and unit-tested across
the matrix (the skew case pins the exact rc.5-vs-final bug). The I/O wrapper stays
thin.

## Consequences

- A correct build is preferred over an honored-but-stale config; a mispinned
  `elixir_lib` self-corrects with a warning instead of shipping a broken app.
- The warning tells the user to fix mob.exs, so the skew is surfaced at build
  time rather than as an opaque on-device `undef`.
- The iOS bundle path now matches the Android sync's auto-detect behavior in
  spirit (always ship the compiler's stdlib).
- Verified on a physical iPhone: tier-3 plugin `.exs` migrations compile and run.

# iOS exqlite-beam manifest drift: record reality over rebuilding the tarball

- Date: 2026-06-24
- Status: accepted

## Context

`mix mob.security_scan` flagged two `:high` `MOB-DRIFT` findings for the
active `5c9c69fc` bundle: the bundled-versions manifest declared
`ios_sim`/`ios_device` as `exqlite_beam: nil` ("this platform deliberately
does not ship the exqlite beam; the host `_build/dev/lib/exqlite` is bundled
at deploy time"), but fingerprinting the actual `otp-ios-{sim,device}-5c9c69fc`
tarballs found exqlite **0.36.0** in them. The Phase-B (Elixir 1.20.1)
iOS tarball build bundled exqlite even though the manifest said it wouldn't.

The same drift surfaced downstream in livebook_mob / Io's scan, which is what
prompted this. exqlite 0.36.0 is the current, non-vulnerable version (it is
also what the `android` tarballs ship, and matches the hex-deps layer), so the
finding is a manifest-vs-binary bookkeeping mismatch, not a security exposure.

`bundled_versions.exs` itself documents the choice point: "If it doesn't
[match], fix the manifest, the tarball, or both."

## Decision

Fix the **manifest** to record reality. Removed the `per_platform` override
for the `5c9c69fc` bundle so all four platforms inherit the global
`exqlite_beam: "0.36.0"`. Chosen over rebuilding + republishing the iOS OTP
tarballs without exqlite (the `build_release.md` path) because:

- exqlite 0.36.0 in the tarball is harmless (current version; the `_build`
  copy that also ships is just redundant, not wrong), so the heavyweight
  tarball rebuild is disproportionate.
- The manifest's job is to state what actually ships; it was simply stale.

The inactive `7d46fdd4` bundle (Elixir 1.20.0-rc.5) is left with its
`ios_*: nil` overrides untouched — it is not the active hash, its tarballs
were not re-fingerprinted here, and the scan only checks the active bundle.

To keep the `per_platform` suppression mechanism under test after removing the
only live override that exercised it, `BundledRuntime.run/1` gained an optional
`:manifest` opt (defaults to the loaded `bundled_versions.exs`). The
"per-platform override suppresses missing-artifact drift" test now injects a
synthetic manifest carrying an `ios_sim: %{exqlite_beam: nil}` override, so the
mechanism is verified independently of the live manifest data.

## Consequences

- `mix mob.security_scan` is drift-clean for `5c9c69fc` (all four platforms ✓).
  Reaches downstream apps (Io) once mob_dev is released and they repeg.
- If a future iOS OTP tarball genuinely ships **without** exqlite (restoring
  the original intent), re-add the `per_platform` `exqlite_beam: nil` override
  for that bundle — the mechanism and its test still support it.
- `BundledRuntime.run/1`'s `:manifest` opt is test-facing but harmless in
  production (defaults to the real manifest when absent).

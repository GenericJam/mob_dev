# Decision: Extract `lean_release` once API stabilizes

## Context

`MobDev.OtpAudit` and `Mix.Tasks.Mob.AuditOtp` (added 2026-05-02) do
something genuinely novel: lib-level reachability analysis of a Mix
release tree, with cache-cruft + duplicate-version detection. The audit
tool already paid for itself — caught ~10 MB of cruft shipping in every
Mob iOS release that nobody had noticed before.

The same tool is useful to **anyone** shipping an Elixir release —
Burrito, Bakeware, Nerves, plain `mix release` — not just Mob. The
existing prior art in the ecosystem is `strip_beams: true` (debug-info
stripping, ~30% wins) and hard-coded strip lists in Nerves; nobody
publishes a tool that does empirical reachability + cache hygiene.

## Decision

**Build the next phases (empirical trace harness, `mix mob.release
--slim`) in mob_dev. Extract to its own repo + Hex package once the
public API stabilizes.** Working name: `lean_release`.

## Why not extract today

The API will reshape as the trace-harness work lands:

- `OtpAudit.report` will gain a `:trace_data` field
- `OtpAudit.audit/2` will gain a `:trace_input` opt
- `report.strippable_libs` will get a confidence tier (static-only vs
  static+trace vs hardcoded baseline)
- The Mix task will likely split into `audit_otp` (read-only),
  `trace_otp` (instrument + capture), `slim_release` (strip + verify)

Anyone consuming a published v0.1 today would hit constant breaking
changes. Without external contributors yet, the public commitment buys
us nothing and costs friction.

## Why extract eventually

- Mob is a niche framework; the audit tool is general-purpose
- Burrito + Bakeware ship full OTP unmodified; they'd benefit
- Nerves uses hardcoded strip lists; an audit-driven approach is better
- `lean_release` shows up on Hex, gets discovered by anyone hitting
  release-size pain
- A clean public artifact attracts collaborators on the harder
  empirical-trace work

## When to extract

Trigger conditions (any one of these):

1. The API hasn't changed in 2 consecutive Mob releases
2. Someone external asks "is this published?"
3. The empirical-trace harness lands and produces actionable results
4. We have at least one non-Mob app using the audit (e.g. ran it
   manually against another Elixir release)

## Naming

`lean_release` — descriptive, available on Hex, reads well in
`mix lean_release.audit` / `mix lean_release.slim`.

Considered + rejected: `beam_diet` (cute but unprofessional), `unship`
(too clever), `release_inspector` (boring), `otp_audit` (we're already
calling our internal module that, fine for internal but generic on Hex).

## Pre-extraction checklist (when the trigger fires)

- [ ] Move `MobDev.OtpAudit` → `LeanRelease.Audit` (or just `LeanRelease`)
- [ ] Move `Mix.Tasks.Mob.AuditOtp` → `Mix.Tasks.LeanRelease.Audit`
- [ ] Add `Mix.Tasks.LeanRelease.Slim` (strip command)
- [ ] Generic path discovery: look for `_build/prod/rel/<app>/lib`
  (standard Mix release output) instead of mob-specific dirs
- [ ] Mob keeps a thin `Mix.Tasks.Mob.AuditOtp` shim that adds mob's
  release-tree path to LeanRelease's search list
- [ ] mob_dev gains `{:lean_release, "~> 0.1"}` dep
- [ ] README + guide on hexdocs
- [ ] Initial Hex release as 0.1.0

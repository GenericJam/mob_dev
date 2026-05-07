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

## Prior art and references

### `mix_unused` (Hauleth)

`https://hexdocs.pm/mix_unused/Mix.Tasks.Compile.Unused.html` —
community pointer when this work was discussed. Static AST analysis of
**project source**, flags public functions never called.

- Different layer than `OtpAudit`. We do app/module reachability across
  the whole release; `mix_unused` does dead-public-function detection
  inside one project. They stack, they don't compete.
- Blind to dynamic dispatch (`apply/2`, `apply/3`, runtime module
  lookup). Mob and its apps use a fair bit of this — render-tree
  dispatch, NIF stub lookup, component registry — so expect false
  positives needing an `ignore` list.
- Trial plan when work resumes: install in `mob_dev` first (least
  dynamic, highest signal), then `square_triangle`, then `mob` itself.
  Decide whether the ignore-list maintenance pays for itself before
  wiring it into `mix mob.doctor`.

### Peer Stritzinger / GRiSP — closest prior art for shrinking

Stritzinger has been doing the same thing we're doing, at one-tenth our
scale. Headline result (mid-2025, Code BEAM Stockholm): **BEAM boots in
16 MB on GRiSP Nano.** Reaches an Erlang shell, runs OTP, TCP/IP, USB.

References:

- `https://github.com/grisp/rebar3_grisp` — their build plugin. Most
  useful artifact: shows how they decide which OTP modules to include
  and how they assemble a stripped ERTS. This is the rebar3 analog of
  what `mix lean_release.slim` should do. Read the source when starting
  the slim-release implementation, not before — it'll inform the design
  but isn't load-bearing for the audit work.
- `https://www.grisp.org/resources` — current talk index. The 2025
  Stockholm talk ("Squeezing the BEAM into 16MB" or similar) is the
  current technical reference; the 2017-era YouTube video is older and
  superseded.
- Open question whether `lean_release` should reuse any GRiSP code or
  just the techniques. They're rebar3-native; we're Mix-native. Likely
  a re-implementation, not a port.

### Outreach

When `lean_release` is closer to extraction (per the trigger
conditions above), reach out to Stritzinger directly. He's an active
community member; the GRiSP work is the closest prior art in
Erlang-land. Trading notes is likely valuable both ways — our trace
harness (empirical reachability from a running app) is something
embedded developers don't need but Phoenix/LiveView shops would use.

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

## When work resumes — quick start

Before doing anything else:

1. Read this whole file, including the prior art section above.
2. Re-run `mix mob.audit_otp` against a current Mob iOS release to
   establish the baseline (saved cruft total, current strip list).
3. Decide whether the next phase is: (a) `mix_unused` evaluation,
   (b) empirical-trace harness, or (c) `mix mob.release --slim`.
   Pick one; don't fan out.

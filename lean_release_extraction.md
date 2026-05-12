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

## Progress log

### 2026-05-11 — Slim pass extracted from `MobDev.NativeBuild`

`MobDev.OtpAudit.Slim` now owns the in-place strip pass that
`mix mob.deploy --slim` runs. The hardcoded prefix list is its source
of truth (`Slim.hardcoded_prefixes/0`); per-app `mob.exs` overrides
(`:slim` sub-keyword with `:keep_libs` / `:drop_libs`) let users
expand or restrict the strip set without code changes. 22 unit tests
against fixture trees pin every phase.

**Deliberately deferred:** audit-driven auto-expansion of the strip
set. A baseline `mix mob.audit_otp` run against `~/code/pigeon` showed
audit.strippable_libs catches `exqlite` (1.3 MB) as unreachable — a
true false positive, since exqlite loads via `:erlang.load_nif` which
the static call graph can't see. Auto-union is blocked on either
(a) tighter foreign-app detection (cross-reference `_build/dev/lib/`
to distinguish leftover cache from real runtime deps) or (b) trace
data from `MobDev.OtpTrace` providing the empirical reachability
signal. Both are higher-leverage next steps than `mix_unused`.

**Same baseline run also surfaced:** the audit's `looks_like_user_app?`
heuristic missed obvious foreign apps (`pigeon`, `push_notify`,
`phase2q_lv`, `phase2q_smoke`, `pythonx_ios_spike`) because the
prefix list is hardcoded too narrowly (`test_`, `toy_`, `mob_test`).
Tightening that is its own task — should land before the audit-driven
slim union since it removes false positives there too.

**Headline numbers from the baseline run (against `~/code/pigeon`'s
cached iOS device tree):**

| Slice                              | KB        |
|------------------------------------|-----------|
| Total shipped                      | 103.0 MB  |
| Reachable (kernel/stdlib/etc seed) | 25.5 MB   |
| Strippable (audit, 0 reachable)    | 17.3 MB   |
| Duplicate versions                 | 8.0 MB    |
| Hardcoded baseline only catches    | ~28 MB extra (megaco, snmp, compiler, …) |
| Unreachable modules INSIDE partly-used libs | ~52 MB (megaco 64/65 dead, snmp 83/90 dead, …) |

That last row is the prize per-module stripping would unlock, but
it's also the riskiest: it requires confident "this module is never
called" answers that only trace data provides.

### 2026-05-11 (cont'd) — Audit improvements: foreign-app allow-list + trace input

Two related improvements landed in close succession after the Slim
extraction.

**Foreign-app allow-list (`:project_deps`):** `OtpAudit.audit/2`
now accepts a list of atoms naming the project's runtime deps. Any
lib in the bundle that isn't OTP-shipped, isn't Elixir-shipped,
isn't the app under test, and isn't in `:project_deps` is classified
as foreign and lands in `report.foreign_apps` (out of
`report.strippable_libs`). `mix mob.audit_otp` auto-derives
`:project_deps` from `_build/dev/lib/` — Mix's view of what's
installed. The legacy name-pattern heuristic
(`test_/toy_/mob_test/scratch_`) is preserved when `:project_deps`
is omitted, for backwards compat. This catches the pigeon /
push_notify / phase2q_lv / etc. false-negative cluster the baseline
audit surfaced.

**Trace input (`:trace_input`):** `OtpAudit.audit/2` accepts a
runtime-traced module set (MapSet, list, OtpTrace.result, or
remote-trace shape — normalizer handles all four) and exposes
`report.trace_strippable_libs` — libs whose modules are entirely
absent from the trace. Each lib_report grows `:modules_traced` and
`:untraced_modules`. The intersection `strippable_libs ∩
trace_strippable_libs` is the high-confidence strip set; the
trace-only difference is the "static graph reaches it but trace
says never called" set that unlocks megaco / snmp / diameter /
compiler / etc.

`mix mob.audit_otp --trace-json path/to/trace.json` reads a JSON
file written by `mix mob.trace_otp --json` and feeds it through.
The CLI report now shows a "Trace-strippable" section split into
"both static + trace" (high confidence) and "trace-only" (unlocked
by trace), with statically-reachable module counts on the
trace-only entries so the user can see how aggressive each strip
would be.

**Mob_new wheel-filter cherry-pick (parallel work):** between the
two audit steps, a `.so`-filter for iOS wheels was cherry-picked
from a parallel pigeon-side branch into `NativeBuild`:
`copy_ios_safe_project_python_wheels/2` skips wheels containing
any `.so` (cffi, cryptography ship Android-only binaries). 10
tests pinning the filter behaviour came along. Unrelated to the
audit work but landed in the same session.

### What's next

With audit + trace wired, the remaining lean_release work is:

1. ~~**Make `MobDev.OtpAudit.Slim` consume the trace-augmented strip
   set.**~~ Done 2026-05-11. `Slim.compute_strip_set/1` accepts
   `:audit_input`; `mob.exs` `slim: [audit: true, trace_json: "..."]`
   opts the build into auditing during slim. Pre-req remains: a real
   device-side trace JSON to actually unlock the megaco/snmp/etc.
   expansion. Until a trace is captured, the audit expansion only adds
   the (allow-list-validated) foreign_app_names.

2. **Per-module stripping inside partly-used libs.** Now genuinely
   blocked on (a) a representative device trace and (b) `.app` file
   rewriting (`{application, _, [{modules, ...}]}` has to lose the
   stripped modules or the application controller will try to load
   them at boot). Higher risk than full-lib stripping. Right next
   step after a trace is captured.

3. **`mix_unused` evaluation** — still orthogonal, still anytime.

4. **Capture a baseline device trace.** Concrete user action that
   unlocks the rest:

       cd ~/code/<mob_app>
       mix mob.connect --no-iex          # in one terminal
       mix mob.trace_otp --remote <node>@127.0.0.1 \
         --duration 60000 \
         --json /tmp/mob_trace.json      # in another, drive the app meanwhile

   Then add to `mob.exs`:

       config :mob_dev,
         slim: [audit: true, trace_json: "/tmp/mob_trace.json"]

   And `mix mob.deploy --native --slim` will print the audit-driven
   expansion in the build log.

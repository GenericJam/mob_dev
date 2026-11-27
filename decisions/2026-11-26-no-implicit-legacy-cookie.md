# mob_dev never presents the legacy cookie on its own

- Date: 2026-11-26
- Status: accepted
- Issue: MOB-552. Supersedes the "Legacy fallback" and "Migration restarts"
  parts of `2026-09-30-private-dist-cookie-for-every-platform.md` (MOB-49).

## Context

MOB-49 moved development distribution to a private cookie per app but kept a
fallback: without `--cookie`, mob_dev tried the private cookie and then the
public `mob_secret`, so apps built against an older mob stayed reachable
until redeployed. mob's runtime has since stopped accepting `mob_secret`
(`mob/lib/mob/dist.ex`, `ios/mob_dist_cookie.h`), so the fallback only ever
helped apps built against that older mob, and it presented a public
credential to whatever node answered under the expected name.

## Decision

- `MobDev.DistCookie.candidates/2` returns only the private cookie when no
  `--cookie` is given, and only the explicit cookie otherwise, except
  `mob_secret` (below). Every caller
  (`mob.connect`, `mob.push`, `mob.watch`, `mob.attest`, `mob.smoke`,
  `mob.selftest`, `mob.trace_otp`, `mob.deploy`, the battery benches)
  inherits that; the iOS battery bench no longer appends `mob_secret` itself
  (`BatteryBenchIos.dist_connect/2`).
- A legacy app is still reachable with an explicit `--cookie mob_secret`.
  That one explicit value yields `[private, mob_secret]`, not `[mob_secret]`:
  callers use the first candidate as the Mac node's default cookie and as
  the cookie handed to restarted apps. Making the public cookie the default
  would admit any peer presenting it under any name, and handing it to an
  up-to-date app (which rejects it) would leave that app on a random cookie.
  So `mob_secret` is only ever a per-node cookie, set for a node that refused
  the private one; up-to-date apps in the same session still connect on
  theirs. `DistCookie.connect/2` warns whenever a node accepts `mob_secret`,
  telling the developer to redeploy.
- When nothing answers on the private cookie, `mob.connect`, `mob.push`,
  `mob.watch` and `mob.attest` print `DistCookie.connect_failure_hint/1`: how
  to redeploy a legacy app, or reach it with `--cookie mob_secret`. With an
  explicit cookie they print nothing extra. `mob.deploy`, which has no
  `--cookie`, says in its WiFi-only iPhone error that a legacy app never
  answers and needs `--native` over USB.
- `mob.deploy` never reaches a legacy app over dist, so it always takes the
  filesystem path: it writes the BEAMs and, unless `--no-restart` is given,
  restarts the app. `Deployer.hot_load_nodes/1`, which routed legacy nodes to
  that path, is gone.
- `mix mob.adopt` templates call `Mob.Dist.ensure_started/1` without a
  `cookie:`, so adopted apps use the private cookie mob_dev hands them.

## Consequences

- An app built against a pre-MOB-49 mob is unreachable over dist until it is
  redeployed (`--native` on iOS, where the launcher sets the cookie), unless
  the developer opts in with `--cookie mob_secret`.
- A legacy physical iPhone reachable only over the LAN can no longer be
  hot-loaded by `mob.deploy`; it needs a `--native` deploy over USB.
- `mob.trace_otp` and the battery benches take no `--cookie`, so they cannot
  reach a legacy app at all.

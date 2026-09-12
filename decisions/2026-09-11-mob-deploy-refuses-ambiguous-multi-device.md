# mob.deploy refuses an ambiguous multi-device fan-out

- Date: 2026-09-11
- Status: accepted
- Linear: MOB-182
- GitHub: mob_dev#53

## Context

`mix mob.deploy` without `--device` used to target every reachable device.
When only one device was around, this was ergonomic: `mix mob.deploy`
deployed to it. When more than one was around — a laptop's own simulator
plus a teammate's paired phone, a spare emulator left running by another
worktree, a Bluetooth-linked device the author forgot about — the same
command silently fanned out to all of them. The behavior was documented
but the failure mode was invisible: the author saw their expected device
succeed and had no reason to check whether *others* also received a build.

mob_dev already fixed the adjacent case in this class — `mix mob.deploy -d
X` where `-d` was never aliased silently deployed to every device, and
`mix mob.deploy --native ABC123` (positional-arg fumble of `--device`)
did the same. That's the same discipline as MOB-150 (deploy exits
honestly): the failure mode a caller can't see is worse than an error at
the tin. Refusing the ambiguous case moves this class of bug from
"invisible until the teammate notices" to "loud at run start."

## Decision

`mix mob.deploy` refuses to proceed when **two or more** devices are
reachable (after `--android` / `--ios` platform narrowing) unless the run
narrows explicitly:

- `--device <id>` or `--ios-device <id>` — target a specific device.
  Either flag disables the gate.
- `--all` — new flag. Explicit opt-in to fan out to every reachable
  device. Preserves the prior default behavior for callers who wanted it.

Single-device runs proceed exactly as before. The gate lives in a pure
predicate (`MobDev.Deployer.check_fanout_gate/2`) so the matrix is unit-
testable without adb/simctl. The mix task does one lightweight discovery
pass ahead of compile / native-build so an ambiguous run is refused before
those costs.

## Consequences

- Multi-device CI configurations must add `--all` (or `--device X` if they
  really wanted one target). Documented in the `mix mob.deploy` help.
- Single-device dev flow (one Android emulator OR one iOS sim) is
  unchanged.
- Mixed dev flow (one Android emulator AND one iOS sim, the common
  parallel-platform case) now requires `--all`. This is a real ergonomic
  cost — kept small by the flag being a single character (`-a` is left
  free; not aliased in this change to keep the surface obvious). If daily
  friction is high we can revisit an "authenticated devices" concept
  (mob.exs pins the two devices you always deploy to; anything else is a
  guest and requires --all).
- `mob.push` still fans out silently; the issue thread (mob_dev#53) called
  it "the first fan-out hazard." That's a separate follow-up; MOB-182 is
  scoped to `mob.deploy` because that's the flow that also builds and
  installs, which is the more expensive mistake.
- The gate does not fire when `deploy_all` runs headlessly (some scripts
  do that); those callers pass `all: true` to `deploy_all`'s underlying
  discovery, which the check consults through the task's option-parsing
  layer.

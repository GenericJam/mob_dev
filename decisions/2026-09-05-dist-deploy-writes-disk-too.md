# A dist deploy hot-loads and writes; it is not a choice between them

- Date: 2026-09-05
- Status: accepted

## Context

`Deployer.deploy_all/1` picked one of two transports per device: Erlang
distribution when the device answered, filesystem copy otherwise. The dist
branch called `HotPush.push_all/1`, which loads modules into the running VM
over RPC and never touches disk.

So a dist deploy updated the running app, printed `✓ (dist, no restart)`, and
left the on-disk BEAMs stale. The app reverted to the last filesystem deploy on
its next restart. `mix mob.connect` restarts the app, so the ordinary act of
connecting to inspect a change was enough to undo it — which is why this
presented as intermittent "the deploy did nothing" rather than as a clear bug.
`--native` was unaffected because it passes `force_fs: true` and skips dist.

Every step reported success. There was no error to notice.

## Decision

After a successful hot load, write the filesystem too, by calling the existing
platform deploy with `restart: false`. The hot load is the latency win; the
file write is what makes it survive. They were never genuinely alternatives —
treating them as alternatives is what produced a deploy that was real until the
next restart.

`restart: false` because the modules are already live; restarting would discard
exactly the state the hot load exists to preserve.

A failed write is an error, even though the running app is correct at that
moment. Reporting success for an app that will silently revert is the failure
mode this fixes, not a smaller version of it.

## Consequences

A dist deploy now costs an rsync it did not before. That is measured in
milliseconds against a hot load that already crossed the network, and it buys
the property the command implies.

`mix mob.attest` gives this an acceptance test that did not previously exist:
deploy, restart, attest, expect zero stale. Verified on the iOS simulator —
67 modules, 0 stale, after `mix mob.connect` restarted the app. Before the fix
the same sequence reported 12 stale.

MOB-161 was filed as a separate bug from the same symptom and is a duplicate of
this. Worth recording that the tracker already held the diagnosis, and the
second report cost more than searching would have.

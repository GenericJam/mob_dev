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

## Scope: not every device

A physical iPhone is deliberately excluded. It gets the hot load and a warning
that the change will not survive a restart.

Two independent reasons, either sufficient. `Discovery.IOS` finds physical
devices by probing EPMD across the LAN, and its own comment says LAN-only
devices "will fall back to dist-only in the deployer" — so a WiFi-discovered
iPhone has no `devicectl` route, and the first version of this change turned
that documented fallback into a hard exit 1 on a deploy that had previously
succeeded. And even over USB the write is an
`xcrun devicectl ... --remove-existing-content` replace with no undo: a cable
knock mid-copy leaves the app unbootable, with no way back but another
successful deploy. A hot load could never damage a device. Making it able to,
silently, on the most-used command in the repo, is not a fix.

The documented physical-iOS dist workflow is USB *unplugged* anyway, which is
precisely the state in which the write cannot run.

## Consequences

The cost is not uniform, and the first draft of this record got it wrong by
saying "an rsync… measured in milliseconds". That is true only of the iOS
simulator, which is the one platform that was measured. On Android the persist
runs `pm list packages`, an `adb push` of every beam dir, an Elixir stdlib
sync and an exqlite setup — several MB of transfer plus around 1.8 s of
hardcoded sleeps. Making that incremental (`HotPush.snapshot_beams/0` and
`push_changed/2` already exist) is the obvious follow-up.

Relatedly, the Android persist calls `adb root`, which on a non-root adbd
restarts adbd and drops every `adb forward` — including the dist tunnels an
open `mix mob.connect` session is using. Harmless while this ran only on the
fallback path; now that a dist deploy persists too, it would kill the user's
IEx session from another terminal. It now checks `adb shell id -u` first,
which is read-only.

`mix mob.attest` gives this an acceptance test that did not previously exist:
deploy, restart, attest, expect zero stale. Verified on the iOS simulator —
67 modules, 0 stale, after `mix mob.connect` restarted the app; the same
sequence reported 12 stale before. Android and physical iOS are **not**
device-verified here, and physical iOS is excluded by design.

MOB-161 is a duplicate of this, filed from the same symptom.

# Dist ports keyed by device serial, not run index

- Date: 2026-06-18
- Status: accepted

## Context

`mix mob.connect` was effectively unreliable for its core promise ("run one
command, you're in IEx on the phone"). Root cause, found by inspecting live
state: the Mac runs ONE EPMD (port 4369) that every device — across every
project and every connect run — registers into, but dist ports were assigned by
per-run index (`9100 + index`). So `nxe_test`'s device-0 and `sloppy_joe`'s
device-0 both registered at 9100; `adb forward tcp:9100` can only point at one
device, so the other resolved to the wrong phone or nothing → a black-box
"timed out waiting for node". Stale forwards/registrations also accumulated and
were never cleaned. With no diagnostics, the failure was undebuggable, so the
workflow got abandoned in favour of agent-driven device control.

## Decision

1. **Serial-derived ports.** `Tunnel.serial_base_port/1` = `9100 + crc32(serial)
   mod 800`. A given phone always maps to the same unique port regardless of
   project/run, so deploy-time and connect-time ports agree and two projects on
   two phones can't collide on 9100. `Tunnel.assign_dist_port/2` bumps past any
   port a live node/forward already holds (cross-project or crc32 collision).
   Both are pure + tested; the I/O (`ports_in_use/1`) is gathered by the caller.
2. **Cleanup.** `Tunnel.setup` removes the device's own stale forwards first,
   scoped to that serial (never touches other devices').
3. **Diagnostics.** On a failed wait, `Connector.connect_diagnosis/1` inspects
   EPMD / forwards / app state and reports the actual cause.

`Tunnel.setup/2` collapses to `setup/1` (callers: connector, hot_push, deployer)
since the port no longer comes from a run index.

## Consequences

- Verified on hardware: two phones got 9633 / 9721 (stable, collision-free) and
  clean 1:1 forwards, with the old 9100/9101 dupes removed.
- crc32 into an 800-wide window: hash collisions between two simultaneously
  connected phones are rare and handled by `assign_dist_port`'s bump.
- Does NOT remove the shared-EPMD-over-adb model itself. The deeper "never think
  about ports" version is EPMD-less distribution (fixed port + custom `erl_epmd`
  resolver) — a larger change, deferred.
- The `setup/2`→`setup/1` signature change is internal (no public Mix-task API
  change). `Tunnel.dist_port/1` (index-based) is gone; use `serial_base_port/1`.

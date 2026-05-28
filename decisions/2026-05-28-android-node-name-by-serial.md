# Derive Android dist node name via `device_node_suffix/1`, not raw `ro.serialno`

- Date: 2026-05-28
- Status: accepted

## Context
`mix mob.connect` printed Android node atoms nobody could connect to. The Mac
side (`Discovery.Android.enrich/1`) computed `node` directly from
`getprop ro.serialno` — which on AOSP emulators returns the placeholder
`EMULATOR36X5X10X0`, yielding `your_app_android_emulator36x5x10x0@127.0.0.1`.
The device side (`Mob.Dist`) receives `MOB_NODE_SUFFIX` from
`restart_app/4`, which already routes through `device_node_suffix/1` and
short-circuits emulator adb ids to the unique `emulator_5554` form. So the
device registered as `your_app_android_emulator_5554@127.0.0.1` and the
connection target was a different name — silent timeout, users had to read
`adb logcat` to find the real name.

## Decision
`Discovery.Android.enrich/1` now calls `device_node_suffix/1` (the same
function `restart_app/4` uses to set `MOB_NODE_SUFFIX`) to derive the node
suffix. Both sides of the EPMD lookup now agree by construction. The
function already does the right thing for all three cases: emulator adb id
(short-circuits to `emulator_NNNN`), physical-USB serial (uses stable
`ro.serialno`), and physical WiFi-adb (uses `ro.serialno` so USB and WiFi
collapse to the same atom).

## Consequences
- `mix mob.connect` against an Android emulator now connects on first try
  without manual `adb logcat` archaeology.
- Two simultaneous emulators get distinct node atoms — no EPMD
  `eaddrinuse` collision.
- Physical-Android behavior unchanged (both paths derive from
  `ro.serialno`).
- iOS path unchanged — `enrich/1` is Android-only.
- One source of truth for Android node-suffix derivation; the old inline
  fallback to `Device.node_name/1` on getprop failure is also folded into
  `device_node_suffix/1` (which sanitizes the adb id directly when getprop
  fails).

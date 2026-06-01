# bt extraction: full three-layer move (zig + JNI thunks + Kotlin)

- Date: 2026-05-28
- Status: accepted

## Context

Phase 3 Wave 1 Session B (`mob_bluetooth` → tier-1) was scoped in the epic as
"move the bt zig NIF into the plugin." Investigation showed bt is a three-layer
native capability, all currently in mob core + the generated app / mob_new
templates:

1. **zig** — `nif_bt_*` (16) + `mob_deliver_bt_*` (~33) in `mob_nif.zig`
2. **C** — 25 `Java_<app-pkg>_MobBridge_nativeDeliverBt*` thunks in `beam_jni.c`
3. **Kotlin** — 16 implemented `bt_*` methods (~450 lines of real
   `BluetoothAdapter`/socket/HFP/SCO code) + 32 `external fun nativeDeliverBt*`
   in `MobBridge.kt`

The layers cross-reference at link time (C thunks call the zig exports; the NIF
calls the Kotlin statics on a cached jclass), and the JNI thunk names encode the
app package — so they can't simply be shipped from a plugin against the app's
`MobBridge`.

## Decision

Do the **full three-layer extraction**: move all of bt (zig + JNI thunks +
Kotlin) into `mob_bluetooth`, with the Kotlin re-homed to a plugin-owned class
`io.mob.bluetooth.MobBluetoothBridge` (its own package, so the thunk names
`Java_io_mob_bluetooth_*` are package-stable and shippable). Strip bt entirely
from mob core, `beam_jni.c`, `MobBridge.kt`, and the mob_new templates.

This depends on two new capabilities, each with its own ADR:
- zig plugin NIFs — `2026-05-28-zig-plugin-nifs.md`
- Android plugin bridge classes — `2026-05-28-android-plugin-bridge-classes.md`

### Alternatives considered
- **Hybrid (zig NIF in plugin, JVM stays in core).** Move only the zig layer;
  the plugin caches bt method IDs on core's exported `Bridge.cls`, and
  `beam_jni.c` keeps the bt thunks. *Rejected:* core/templates retain all bt
  Kotlin + thunks, so it isn't a real extraction — every app still ships bt and
  core still knows about it. Defeats the point of the plugin epic.
- **Defer; keep bt tier-0.** *Rejected by the user:* the zig-NIF capability was
  already built + live-verified, and bt is the canonical tier-1 example the spec
  points at; doing it properly drives the missing plugin-system capabilities
  (zig NIFs, Android bridge classes) that every future native plugin needs
  (`mob_local_llm`, sqlite-vec, etc.).

## Consequences

- Net-new plugin-system surface (zig NIF compile path + Android bridge-class
  registration + plugin JNI/Kotlin compilation) ships before the bt move — a
  larger effort than a code relocation, but it generalizes beyond bt.
- mob core's shared zig helpers (`binToCString`, `pidToJlong`,
  `callBridgePidStr*`, `get_jenv`, …) stay in core; the plugin duplicates the
  small pure helpers it needs and extern-links the exported `get_jenv` + `g_jvm`.
  **Correction (2026-05-30, found during extraction):** `pidToJlong` /
  `pidFromLong` / `callBridgePidStr*` are NOT bt-only — core keeps using them
  for location/camera/audio/vendor_usb (`pidFromLong` 17×, `callBridgePidStr`
  24× post-strip). They are DUPLICATED into the plugin, not moved. The plugin's
  bt method-id cache is its own `g_bt` struct + `g_bt_cls`, not core's exported
  `Bridge`. The 32 (not 25) JNI delivery thunks ship as a verbatim-copied
  `jni_source` C file with only the symbol prefix renamed to
  `Java_io_mob_bluetooth_MobBluetoothBridge_*`.
- bt is Android-only (Apple MFi gates it; mob returns `:unsupported` on iOS), so
  the iOS plugin-bridge path is out of scope for this wave.
- Discipline: prove each capability with a trivial prototype on device (the
  trivial zig NIF already passed; a trivial bridge-class plugin is next) before
  moving the ~1700 lines of real bt code.

# iOS plugin C-NIF compile path + per-platform driver-table filtering

- Date: 2026-06-04
- Status: accepted

## Context

Wave 1 (mob_bluetooth) built the Android plugin-NIF path (`-Dplugin_c_nifs` /
`-Dplugin_zig_nifs` + Android `build.zig` compile blocks). The iOS counterpart
was deferred because bt was Android-only (iOS returned `:unsupported`). Wave 2
(camera, location, notify, photos, biometric) is different: every one is
cross-platform with a real iOS NIF (ObjC/C — CoreLocation, AVFoundation, …). So
the iOS plugin-NIF compile path is now a hard prerequisite for Wave 2.

The driver table was already platform-correct: `RegenDriverTab.resolved_nifs/0`
merges activated plugins' NIFs and `StaticNifs.generate(:ios, …)` emits them.
The only gap was the iOS *build* not compiling the plugin NIF source, so
`driver_tab_ios` referenced a `<module>_nif_init` the link couldn't find.

Verifying surfaced a second issue: the iOS table included *every* activated
plugin's NIF, including the **zig** ones (mob_bluetooth, the zig_extras demo).
The iOS build has no zig plugin-NIF compile path, and bt's zig can't compile on
iOS anyway (it's full of Android JNI symbols). So the link failed on
`_mob_bluetooth_nif_nif_init` / `_mob_zig_extras_nif_nif_init`.

## Decision

Two changes:

1. **iOS plugin C-NIF compile path.** `native_build.ex` emits `-Dplugin_c_nifs`
   for both iOS builds (sim `build.zig`, device `build_device.zig`), gated to
   non-empty like the Android path. `ios/build.zig` + `build_device.zig` (demo +
   mob_new templates) gain a `plugin_c_nifs` compile block that mirrors the
   existing `project_c_nifs` one: each absolute source path is compiled with
   `-DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=<basename>` and linked.
   Scoped to **C** NIFs — Wave 2 is all ObjC/C; no plugin needs a zig NIF on
   iOS, so the zig-on-iOS path is deliberately deferred (and documented in the
   code) until one does.

2. **Per-platform driver-table filtering.** `RegenDriverTab.resolved_nifs/1`
   takes a platform and drops plugin NIFs the platform's build can't compile.
   For `:ios` that means excluding `lang: :zig` plugin NIFs (the invariant: the
   table only references symbols the build links). `:android` / `:all` keep
   everything. The iOS and Android tables are now generated from different NIF
   lists.

## Consequences

- A tier-1 C/ObjC plugin NIF compiles, links, and loads on iOS. Verified
  end-to-end on a physical iPhone (SE 3rd gen, iOS 26.5): re-enabled the
  pure-C `mob_demo_haptic_extras` (disabled solely because this path was
  missing — this resolves that standing TODO), and `haptic_extras_nif.buzz/0`
  returned `:ok` over RPC on `aarch64-apple-ios`.
- Android-only plugins (zig NIFs) no longer break the iOS link — they're absent
  from `driver_tab_ios`, matching their `:unsupported`-on-iOS Elixir contract.
- `resolved_nifs/0` is preserved (delegates to `:all`) so mob.doctor and the
  project-NIF classifier are unchanged.
- Follow-up if ever needed: a zig plugin-NIF compile path on iOS (add
  `-Dplugin_zig_nifs` + an `addZigObject` block to `ios/build*.zig`, and relax
  the `:ios` filter). No current plugin needs it.

# Zig plugin NIFs: named-module imports for mob-core bindings

- Date: 2026-05-28
- Status: accepted

## Context

Phase 3 Wave 1 Session B (promote `mob_bluetooth` to a tier-1 NIF) was
documented as a small "move the bt_* zig exports into the plugin, declare
`nifs:`, smoke" task. Investigation showed that premise was wrong:

1. The bt NIF is ~1000 lines of **zig** (16 `nif_bt_*` wrappers, ~33
   `mob_deliver_bt_*` callbacks, atom cache, paired-list state machine,
   term builders) living inside `mob/android/jni/mob_nif.zig`, not a
   standalone file.
2. The tier-1 plugin NIF compile path is **C-only**: `MobDev.Plugin.Merge.nif_sources/1`
   globs `<plugin>/<native_dir>/<module>.c`, `native_build.ex` emits
   `-Dplugin_c_nifs`, and `build.zig` compiles those via `addCObject`
   (`addCSourceFile`). The only thing it has ever compiled is the haptic
   prototype, a trivial standalone C file.
3. `mob_nif.zig` resolves its bindings with **relative** imports —
   `@import("mob_erts.zig")`, `@import("mob_zig.zig")` — to sibling files
   in `mob/android/jni/`. A plugin `.zig` in a different directory cannot
   use those relative paths.

The driver-table registration side is already plugin-aware:
`Mix.Tasks.Mob.RegenDriverTab.resolved_nifs/0` merges
`MobDev.Plugin.Merge.nifs(activated())` into `erts_static_nif_tab`, and the
generated table calls each `<module>_nif_init()` over plain C ABI — which a
zig `export fn ... callconv(.c)` produces identically. So registration is
not the gap; **compilation + binding-import wiring** is.

User decision (2026-05-28): extend the plugin infra to support zig NIFs
rather than hand-port the bt NIF to C. Rationale: faithful to mob's
zig-native native stack, and unblocks every future zig NIF plugin
(`mob_local_llm` via llama.cpp, sqlite-vec embeddings, etc.), not just bt.

## Decision

Add a parallel **zig** plugin-NIF path alongside the existing C one:

1. **Manifest**: a plugin NIF entry may carry `lang: :zig` (default `:c`
   preserves existing behavior). Source resolves to
   `<plugin>/<native_dir>/<module>.zig`.
2. **`MobDev.Plugin.Merge`**: add `zig_nif_sources/1` mirroring
   `nif_sources/1`; `nif_sources/1` stays C-only so the haptic prototype
   path is unchanged.
3. **`native_build.ex`**: emit `-Dplugin_zig_nifs=<abs,paths>` alongside
   `-Dplugin_c_nifs`.
4. **`build.zig`** (mob_plugin_demo, then the mob_new `build.zig.eex`
   templates): a `plugin_zig_nifs` block compiles each source via
   `addZigObject`, deriving the NIF libname from the basename. Unlike C,
   zig needs no `-DSTATIC_ERLANG_NIF_LIBNAME`: the plugin source names its
   own `export fn <module>_nif_init()` directly.
5. **Binding imports** (the crux): `addZigObject` wires **named module
   imports** so a plugin `.zig` reaches mob-core bindings via
   `@import("erts")` / `@import("jni")`, pointing at
   `$MOB_DIR/android/jni/mob_erts.zig` and `mob_zig.zig`. Those modules'
   own relative imports still resolve against their mob-core location, so
   they keep working.
6. **Shared NIF helpers** (for entangled NIFs like bt that need
   `binToCString`, `pidToJlong`, `callBridgePidStr*`, `get_jenv`, the
   `Bridge`/MobBridge method-id cache — all currently private inside
   `mob_nif.zig`): extract into an importable `mob_nif_shared.zig` exposed
   as `@import("mob_nif")` to plugins. Done as a separate step after a
   trivial zig NIF proves the compile + named-import path end-to-end.

## Consequences

- Distinct module instances: mob_nif.zig imports `erts` relatively while a
  plugin imports it by name, so the two get separate Zig *type* identities
  for `ErlNifEnv` etc. Safe here because the boundary is C-ABI only
  (extern structs + extern `enif_*`); no Zig-level data structures cross.
- Sequencing: prove the pipeline with a trivial standalone zig NIF
  (haptic's role for the C path) before tackling bt's shared-helper
  extraction. A failure then localizes to compile-vs-entanglement.
- iOS counterpart (`build_device.zig` / iOS templates) deferred until the
  Android path is verified on device; bt is Android-only (Apple MFi gates
  it; mob returns `:unsupported` on iOS) so bt doesn't need the iOS path.
- `lang: :zig` is a new manifest field — `MobDev.Plugin.Validator` should
  learn to accept it; follow-up.

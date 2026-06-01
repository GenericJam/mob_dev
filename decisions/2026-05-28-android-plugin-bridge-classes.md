# Android plugin bridge classes: compile plugin JNI/Kotlin + register the bridge jclass

- Date: 2026-05-28
- Status: accepted

## Context

Phase 3 Wave 1 Session B's full bt extraction needs a plugin to own a JVM
*bridge class* — a Kotlin class whose static methods the plugin's NIF invokes
via `CallStaticVoidMethod`, and whose `nativeDeliver*` externals resolve to the
plugin's own JNI thunks. mob has nothing for this today:

- `MobDev.Plugin.Merge.android_sources/1` *gathers* `bridge_kt` + `jni_source`
  paths, but `native_build.ex` never consumes them — the Android build does not
  compile plugin-shipped JNI-thunk C or bridge Kotlin. The "Android native
  merge" only wired permissions, gradle_deps, and `plugin_c_nifs` (NIF inits).
- The app's bridge jclass is cached by a single `JNI_OnLoad` in the project's
  `beam_jni.c` that hardcodes `BRIDGE_CLASS = "com/example/<app>/MobBridge"`.
  `JNI_OnLoad` is one-per-`.so` and core-owned; a plugin-owned Kotlin class in
  its own package has no path to get its jclass cached.
- Existing plugins don't exercise this: `signature_pad` registers a render-time
  Composable via `MobNativeViewRegistry`; the iOS `mob_register_plugins`
  bootstrap is for `ui_components`. Neither is a startup static-bridge cache.

## Decision

Add an Android plugin **native-source + bridge-registration** pipeline, the
Kotlin analog of the iOS `mob_register_plugins` bootstrap.

### Manifest (new `android` fields)
```elixir
android: %{
  jni_source: "priv/native/jni/mob_bluetooth_jni.c",   # JNI thunks (Java_<pkg>_<Class>_*)
  bridge_kt:  "priv/native/android/MobBluetoothBridge.kt", # Kotlin impl + externs
  bridge_class: "io.mob.bluetooth.MobBluetoothBridge"   # FQN to register at startup
}
```

### Compilation
- `Merge.jni_sources/1` returns plugin `jni_source` absolute paths.
  `native_build` emits `-Dplugin_jni_sources=<abs,paths>`; `build.zig` compiles
  each as a plain C object (no `STATIC_ERLANG_NIF_LIBNAME` — these are JNI
  thunks, not NIF inits) and links into the app `.so`. Same shape as
  `plugin_c_nifs` minus the libname flag.
- Bridge Kotlin: `native_build` copies each plugin `bridge_kt` into the app
  source tree at the package-derived path (`android/app/src/main/java/io/mob/
  bluetooth/MobBluetoothBridge.kt`) before `gradle assembleDebug`, so the app's
  existing Kotlin sourceSet compiles it. (Copy-into-tree mirrors how the merge
  already patches AndroidManifest.xml / build.gradle in place at build time.)

### Bridge-class registration (the jclass cache)
- The plugin's Kotlin object exposes `@JvmStatic external fun nativeRegister()`
  and a `@JvmStatic fun register() { nativeRegister() }`.
- The plugin's JNI thunk `Java_io_mob_bluetooth_MobBluetoothBridge_nativeRegister(
  JNIEnv* env, jclass cls)` receives **its own class as `cls`** (JNI passes the
  declaring class to static-method thunks) — so it caches `NewGlobalRef(cls)` +
  looks up the bt_* method IDs with **no `FindClass` and no classloader
  problem**. This sidesteps the `JNI_OnLoad`-singularity issue entirely.
- `Merge.bridge_classes/1` gathers `bridge_class` FQNs. `native_build`
  generates `android/app/src/main/java/.../MobPluginBootstrap.kt`:
  `object MobPluginBootstrap { fun registerAll() { io.mob.bluetooth.MobBluetoothBridge.register(); … } }`
  and the mob_new `MainActivity` template calls `MobPluginBootstrap.registerAll()`
  early in `onCreate` (analog of AppDelegate calling `mob_register_plugins()`).

## Consequences

- The plugin NIF keeps its bt method-id cache + jclass in its own zig globals
  (not core's exported `Bridge`), fed by `nativeRegister`. The NIF's outbound
  `CallStaticVoidMethod` uses that cache; inbound `mob_deliver_bt_*` are reached
  by the plugin's own `Java_io_mob_bluetooth_*` thunks. Fully self-contained.
- New manifest fields → `Validator` should learn `bridge_class`/`jni_source`
  shape (follow-up). Capability/permission enforcement already covers
  AndroidManifest fragments.
- Prove with a trivial bridge plugin (mirror the zig-NIF prototype discipline)
  before moving bt's ~450-line Kotlin.
- iOS: out of scope (bt is Android-only; Apple MFi gates it).
- Copy-into-tree for `bridge_kt` means an `mob.eject`/clean step should remove
  generated plugin Kotlin + `MobPluginBootstrap.kt`; track as follow-up.

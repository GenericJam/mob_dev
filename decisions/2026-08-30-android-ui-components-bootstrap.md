# Android ui_components registration rides the generated MobPluginBootstrap

- Date: 2026-08-30
- Status: accepted

## Context

The plugin manifest's `ui_components.android.composable` was data nobody
consumed. iOS has a working story: `MobDev.Plugin.IOSBootstrap` code-generates
`mob_register_plugins()` from `ui_components.ios`, and the host AppDelegate
calls it before `mob_init_ui()`. Android had no analog — every host
hand-registered each plugin composable in `MainActivity.onCreate`, and a host
that forgot rendered the component as *nothing*: `MobNativeViewRegistry.render`
returns silently on an unknown key (mob_scene3d-q03; chopaat carries the
workaround under that bead id). The plugin bridge's own `register()` could not
do it because `MobNativeViewRegistry` lives in the *app* package (MobBridge.kt)
and a plugin's `io.mob.*` code can't name that package at authoring time.

## Decision

Registration is generated into the existing `io.mob.plugin.MobPluginBootstrap`
(`MobDev.Plugin.AndroidBootstrap` + `NativeBuild.__bootstrap_kotlin__/2`),
whose `registerAll(this)` every generated/adopted MainActivity already calls
before `setContent` — no template or host edit needed, and the app-package
problem dissolves because codegen *discovers* the app package (the package of
the file defining `object MobNativeViewRegistry`) and emits fully-qualified
references.

Non-obvious calls:

- **Registry key = `android.view_module`, falling back to `ios.view_module`.**
  The key is platform-independent (the Elixir module name, dots →
  underscores), and existing manifests only carry it on the iOS side. The
  android-side override exists so an Android-only plugin needs no `:ios` map.
- **A bare `composable` is qualified with the `bridge_class` package** — the
  composable ships in the plugin's `bridge_kt`, which declares that package
  (mob_scene3d: `io.mob.scene3d.MobScene3dViewport`). A fully-qualified
  `composable` is used as-is.
- **Failure is loud at the earliest layer that can see it.** Malformed
  declaration (no key / no composable) → `Mix.raise` at build, next to the
  manifest. Typo'd composable → Gradle Kotlin compile error (the generated
  call references the symbol). Declared-but-unresolvable (bare composable, no
  bridge — the hand-copied tier-2 workflow) → a generated placeholder factory
  that renders a red "Missing native component" tile and `Log.e`s; the host's
  own registration *after* `registerAll` overwrites it, so the documented
  tier-2 flow keeps working while a forgotten registration can no longer be
  silent.
- **Hosts without the registry (LiveView wrappers, pre-registry templates)
  skip UI codegen with a printed warning** — they have no native-view render
  path at all, so generated references would only break their compile.

## Consequences

- The chopaat MainActivity workaround (and the s3d_spike hand registration)
  become removable: activating a ui_components-bearing plugin is enough.
- The generated bootstrap now contains Compose lambdas when (and only when)
  ui components exist, so plugin-less builds stay byte-identical; UI-only
  bootstraps omit the bridge handOff/permission helpers to avoid unused
  private functions.
- The tier-2 scaffold still declares a bare composable with no bridge; its
  hosts now see the loud placeholder until they register by hand. Follow-up:
  scaffold could ship the composable in a bridge_kt so tier-2 gets
  auto-registration too.

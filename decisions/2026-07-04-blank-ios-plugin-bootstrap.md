# Blank iOS apps must still emit the plugin bootstrap

- Date: 2026-07-04
- Status: accepted
- Issue: MOB-7

## Context

`mix mob.new foo --blank --ios` + `mix mob.deploy --native --ios` failed to link:

```
Undefined symbols for architecture arm64:
  "_mob_register_plugins", referenced from:
      -[AppDelegate application:didFinishLaunchingWithOptions:] in AppDelegate.o
```

The generated `AppDelegate.m` (mob_new template) *always* declares and calls
`mob_register_plugins()`. That symbol is *defined* by the generated Swift
bootstrap (`MobDev.Plugin.IOSBootstrap.swift_source/1`, emitted via
`generate_ios_plugin_bootstrap/1`). But `native_build.ex` only generated the
bootstrap when `activated_plugins != []` — both the sim and device paths short-
circuited to `{"", ""}` for a plugin-less app. So a `--blank` app has a call with
no definition. Non-blank apps happened to work only because an activated plugin
triggered bootstrap generation (its empty body still defines the symbol).

The original guard existed for a real reason: an app scaffolded *before* the
plugin system has no `plugin_swift_files` option in its `ios/build.zig`, so
passing `-Dplugin_swift_files` would be an unknown-option error. Its assumption —
"a plugin-less app never calls the bootstrap" — went stale when the AppDelegate
template was changed to always call it.

## Decision

Gate bootstrap generation on the **app's build file capability**, not on whether
plugins are activated. `build_file_supports_plugins?/1` (pure, tested) checks the
`ios/build.zig` / `ios/build_device.zig` for the `plugin_swift_files` token:

- **Plugins activated** → plugins' Swift + bootstrap (unchanged).
- **No plugins, but build file supports `plugin_swift_files`** (current template,
  whose AppDelegate always calls the symbol) → emit the empty bootstrap so
  `mob_register_plugins` is defined.
- **No plugins, legacy build file** (no option, AppDelegate never calls it) →
  empty flags, omitted — legacy apps keep building.

The presence of the `plugin_swift_files` option and the AppDelegate's call to
`mob_register_plugins` are generated together, so the token is a sound proxy for
"this app expects the bootstrap symbol." Both iOS paths share one helper,
`ios_plugin_swift_and_frameworks/3`.

## Consequences

- `--blank --ios` apps link again; verified end-to-end on a physical iPhone SE
  (build + install succeeded, no undefined symbol).
- A zero-plugin app now compiles one extra ~10-line Swift file (empty
  `mob_register_plugins`) — negligible.
- Legacy pre-plugin scaffolds are unaffected (fall through to empty flags).
- Follow-up: the mob_new `AppDelegate.m.eex` could guard the call in a `#if`
  instead, but keying off the build file keeps the fix entirely in mob_dev and
  matches how the flags are already conditionally emitted.

# Android MobPermissionProvider interface + bootstrap codegen

- Date: 2026-06-04
- Status: accepted

## Context

The extensible permission registry (see `mob/decisions/2026-06-04-plugin-permission-registry.md`)
needs mob_dev to generate the Android-side glue so a plugin bridge can supply
the cap→Android-permission-string mapping for a capability core no longer knows
about. iOS needs no codegen (runtime self-registration via an exported core
symbol); Android's flow is generic except for that mapping, so the codegen is
minimal.

## Decision

Mirror the existing `MobActivityAware` pattern exactly:

- `MobDev.NativeBuild.__permission_provider_kotlin__/0` emits the marker
  interface `io.mob.plugin.MobPermissionProvider { fun permissionsFor(cap: String): Array<String>? }`,
  written next to `MobActivityAware` / `MobPluginBootstrap` by
  `apply_plugin_android_kotlin!`.
- `__bootstrap_kotlin__/1` is extended: `registerAll(activity)` additionally
  collects every bridge that `is MobPermissionProvider` into a list, and the
  generated `MobPluginBootstrap` exposes
  `permissionsFor(cap): Array<String>?` that walks the list, returning the
  first non-null mapping. A plugin opts in purely by having its (already
  registered) `bridge_class` implement the interface — no new manifest field.

Core `MobBridge.request_permission` (mob_new template + demo copy) falls through
its `when(cap)` `else` branch to `io.mob.plugin.MobPluginBootstrap.permissionsFor(cap)`;
the generic checkSelfPermission / requestPermissions / onPermissionResult flow
is unchanged.

The manifest's `permissions:` field is validated by `MobDev.Plugin.Manifest`
(tier-1, native) for documentation + tier classification, but Android codegen
does not read it — provider discovery is by interface at runtime.

## Consequences

- `MobPluginBootstrap` is always generated (even with no plugins, an empty
  `permissionsFor` returning null), so core `MobBridge` can reference it
  unconditionally — same guarantee `registerAll` already relied on.
- Symmetric with `MobActivityAware`: one emitter + one collection pass in the
  bootstrap. +tests on the emitters; the generated Kotlin is ktlint-checked via
  the mob_new generate-then-lint suite.

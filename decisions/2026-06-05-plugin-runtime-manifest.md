# Runtime plugin manifest + audited host_config for tiers 3/4

- Date: 2026-06-05
- Status: accepted

## Context

Tiers 3 (multi-screen) and 4 (embedded sub-app) plugins are pure-Elixir and
**runtime-wired**: their screens, lifecycle hooks, settings schemas, and
notification handlers are ordinary Elixir compiled into the host release. But the
host has no on-device awareness of which plugins are active or what they declare —
`MobDev.Plugin.activated/0` reads `mob.exs` + deps at *compile time* only. Tiers
1/2 don't need this because their contributions are native symbols merged at
link time; tiers 3/4 need the data available to running Elixir on device.

Spec-v2 also adds `:screens_generator` (compile-time codegen reading host config
via `host_config/3`, which was a stub).

## Decision

Mirror the existing `driver_tab` / `MobPluginBootstrap` build-time codegen, but
emit **serializable Elixir data** instead of native symbols.

- `MobDev.Plugin.RuntimeManifest.build/1` gathers the tier-3/4 sections (via new
  `Merge` gatherers, each tagged with the owning plugin) and runs spec-v2
  `:screens_generator`s, producing `%{screens, lifecycle, settings,
  notification_handlers}`.
- `render/1` emits a self-describing `.exs` that evaluates back to the map;
  `mix mob.regen_plugin_manifest` writes it to `priv/generated/mob_plugins.exs`
  (with `--check` for drift, like `regen_driver_tab`). Core's `Mob.Plugins`
  reads it at boot.
- **Only behavioral data lives in the manifest.** Migration files and font/image
  assets are physically copied into the host at build time (native_build), not
  carried here — their build-machine paths are meaningless on device.
- **No closures anywhere in tier-3/4 sections.** The manifest serializes to a
  terms file, so notification `match` is a map or a `{Module, :function, arity}`
  predicate reference, never an anonymous `fn`. The validator enforces this.
- `host_config/3` becomes audited: `with_host_config_audit/3` scopes a read set
  to a plugin's declared `:host_config_keys`; a read of an undeclared key raises
  and fails the build. Reads are recorded for `mix mob.audit_plugins`.

## Consequences

- A new generated artifact `priv/generated/mob_plugins.exs`, regenerated when
  `config :mob, :plugins` changes (same deploy/regen gotcha as `driver_tab` —
  run `mix mob.regen_plugin_manifest` after activating a tier-3/4 plugin).
- Notification matching can't use arbitrary closures; named predicate MFAs cover
  the same need and stay serializable + auditable.
- `host_config/3`'s audit is opt-in via the scope — direct calls (tests, non-
  generator code) stay a plain `Application.get_env/3`, so nothing else breaks.
- Migrations/assets file-bundling is deferred to the Phase 1 native_build work;
  this commit is the pure-data foundation (validation + gatherers + manifest
  builder + host_config audit), fully unit-tested, no native or device changes.

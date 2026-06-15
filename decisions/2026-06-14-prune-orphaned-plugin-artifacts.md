# Prune orphaned plugin artifacts on removal

- Date: 2026-06-14
- Status: accepted

## Context

A plugin's tier-3 merges COPY files into the host tree: bridge Kotlin into the
Kotlin sourceSet (`android/app/src/main/java/<package>/`), migrations into
`priv/repo/migrations`, images into `priv/generated/plugin_assets`. The runtime
manifest (`mob_plugins.exs`) and the static-NIF `driver_tab` are recomputed from
the activated set on every `build_all`, so the NIF link surface is always clean
after a plugin is removed. The copied files were not — they lingered. An
orphaned bridge `.kt` is the worst case: Gradle compiles everything under
`src/main/java`, so a stale bridge referencing now-removed symbols can break the
build. This blocked telling users "add and remove plugins freely."

## Decision

Added `NativeBuild.__prune_plugin_artifacts__/2`: a per-concern ledger of the
relative paths each merge wrote, kept under
`priv/generated/.mob_plugin_artifacts/<scope>`. On each run a merge passes the
files it just produced; the helper deletes `(previous − current)` and persists
`current`. Wired into `apply_plugin_android_kotlin!` (`:android_kotlin`),
`apply_plugin_migrations!` (`:migrations`), and `apply_plugin_images!`
(`:images`). Each is restructured so the prune runs even when the current set is
empty (the all-removed case).

Scoped per concern, and only invoked when that concern's merge runs, so an
iOS-only build never prunes Android artifacts. Generated glue at fixed paths
(bootstrap, activity-aware, permission-provider, notify-hub) is overwritten each
build and stays out of the ledger — only the orphan-prone per-plugin copies are
tracked.

## Consequences

- Add/remove of a plugin is now clean in both directions; the lean default
  generated app can document removal as a normal workflow.
- Pruning a migration file does not roll back an already-applied migration
  (schema_migrations keeps the record); it stops re-runs and keeps the dir
  honest. A `mix ecto.rollback` of a removed plugin's migration would have no
  file — acceptable, since you don't roll back a plugin you've dropped.
- Android `res/font/` orphans are deliberately NOT pruned here: that dir mixes
  app fonts (`priv/fonts`) with plugin fonts, and orphan fonts are benign unused
  resources, not a build break. Revisit if it becomes a real problem.
- The ledger lives in `priv/generated/` alongside the other derived build state.

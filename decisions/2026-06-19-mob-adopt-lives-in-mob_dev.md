# `mix mob.adopt` lives in mob_dev, not mob_new

- Date: 2026-06-19
- Status: accepted

## Context

`mix mob.adopt` installs Mob into an *existing* Phoenix project — the
install-into-existing counterpart to `mix mob.new` (which generates a project
from scratch). It was contributed against mob_new as
[mob_new#8](https://github.com/GenericJam/mob_new/pull/8) by @ken-kost, since
mob_new owns the project-generation surface.

But adopt is an **Igniter** task: it mutates a user's existing mix.exs,
`app.js`, `root.html.heex`, and config in place, exactly like mob_dev's
existing `mix mob.add_nif` and `mix mob.enable`. mob_new ships as a
self-contained Mix **archive** (`mix archive.install hex mob_new`), and
archives bundle only their own beams — no runtime deps. `ArchiveSelfContainedTest`
pins that invariant. Igniter is a runtime dep, so it cannot live inside the
archive: adopt running from mob_new would have to either vendor Igniter or
crash on `UndefinedFunctionError` for every installed user (the same class of
bug that bit the original Sourceror-based dep injector — see mob_new issues.md
#1). mob_dev, by contrast, is a normal Hex dependency of the user's project, so
Igniter is already on the path.

## Decision

Relocate the whole adopt task tree into mob_dev, where `mob.add_nif` /
`mob.enable` already live:

- `lib/mix/tasks/mob/adopt.ex` + `adopt/{deps,bridge,screen,mob_app,mob_exs,native,finalize}.ex`
  (+ `native/{android,ios}.ex`). Task **names** are unchanged (`mix mob.adopt`,
  `mix mob.adopt.deps`, …) — task names are global; only the home repo moved.
- `MobNew.AdoptGuard` → `MobDev.AdoptGuard`.
- The shared patcher/generator helpers adopt calls (`inject_deps`,
  `inject_mob_hook`, `inject_mob_bridge_element`, `inject_ecto_sqlite3`, the
  `mob_screen.ex` / `mob_app.ex` / `mob.exs` / `.erl` content generators;
  `resolve_deps`, `assigns`, `templates_root`, `static_root`, `expand_path`,
  the secret-key helpers, `apply_python_patches`) are **duplicated** from
  mob_new's `LiveViewPatcher` / `ProjectGenerator` into
  `MobDev.Adopt.Patcher` / `MobDev.Adopt.Generator`. Only the transitive
  closure adopt actually exercises was copied.

mob_new is **untouched** — `mix mob.new` still uses its own copies. This is a
duplication, not a move.

The native Android/iOS trees render from mob_new's `priv/templates/mob.new/`
(the templates belong to the generator, not the build toolkit). Rather than
duplicate the template files, `mix mob.adopt --android/--ios` **requires the
mob_new archive installed** (`mix archive.install hex mob_new`) alongside
mob_dev as a project dep. Mix puts an installed archive on the code path, so
`Generator.templates_root/1` resolves them via `:code.priv_dir(:mob_new)` at
runtime — the same mechanism `mix mob.new` uses to load its own templates —
falling back to `$MOB_NEW_DIR` / `~/code/mob_new` for local development and
raising a clear "install the mob_new archive" message if none is reachable.

## Consequences

- Two copies of the patcher/generator helpers exist (mob_new + mob_dev) until
  **Phase 5 of `build_system_migration.md`** reunifies them behind a single
  Igniter-based path. Both copies preserve the runtime `Regex.compile!/1`
  form (rule #9 — `~r//` literals call `:re.import/1`, removed in OTP 28.0);
  no `~r//` literals were reintroduced. The mirror has the same drift risk as
  `MobNew.NdkVersion` ↔ `MobDev.NdkVersion`; adopt's `Generator` calls
  `MobDev.NdkVersion.recommended/0` directly rather than carrying yet another
  mirror.
- adopt requires mob_new's templates at runtime for the native path. This is
  an **accepted, documented contract** — the dual requirement (mob_new archive
  installed + mob_dev as a dep) keeps mob_new the single source of native
  templates and avoids duplicating/drifting them across repos. The Elixir-side
  adoption (deps, LV bridge, `mob.exs`, MobScreen) is fully self-contained in
  mob_dev and needs no archive. Phase 5 of `build_system_migration.md` may
  revisit how templates are shared, but the cross-repo template source is
  intentional, not a stopgap.
- The acceptance test (`test/acceptance/mob_adopt_acceptance_test.exs`,
  `@tag :acceptance`) wires the generated project to mob_dev via a `path:` dep
  (the checkout under test) + `:igniter`, then runs `mix mob.adopt`. It needs
  `phx_new`, network for `deps.get`, and a mob_new checkout via `MOB_NEW_DIR`;
  it skips cleanly when those are absent.
- adopt remains pre-1.0 detect-and-refuse: `AdoptGuard` adds Igniter issues
  (no file changes) on umbrella / non-Phoenix / customised `app.js` or root
  layout / non-SQLite LV hosts. Widen the guard, never the silent-proceed path.

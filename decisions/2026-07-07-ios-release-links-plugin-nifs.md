# iOS release build compiles + links activated-plugin NIFs

- Date: 2026-07-07
- Status: accepted

## Context

`mix mob.release --ios` produced a binary that failed to link for any app with
NIF plugins:

```
Undefined symbols for architecture arm64:
  "_mob_camera_nif_nif_init", referenced from:
      _erts_static_nif_tab in driver_tab_ios.o
  ... (one per activated plugin)
```

iOS statically links every NIF into the single app binary (no `dlopen` under the
App Store sandbox), so `priv/generated/driver_tab_ios.c` references each activated
plugin's `<module>_nif_init`. The **dev** path (`native_build.ex` →
`build.zig -Dplugin_c_nifs`, fed by `MobDev.Plugin.Merge.nif_sources/2`) compiles
those sources in, which is why all plugins work on-device in dev. But the
**release** path (`release.ex` → `release_device.sh`) is a separate hand-rolled
clang/swiftc script that predates plugin support: it compiled a fixed object list
(MobNode, mob_nif, mob_beam, driver_tab, …) and never touched plugins. Result: the
driver table declared the symbols, nothing defined them, link failed.

Surfaced shipping Sloppy Joe (activates all 10 capability plugins) to the App
Store. Android was unaffected — it loads NIFs from per-ABI `.so`s, not a single
static binary.

## Decision

Bring the release path to parity with the dev path. `release_env/2` now emits two
env vars from `MobDev.Plugin.activated()`, via the pure, unit-tested
`Release.plugin_ios_build_env/1`:

- `MOB_PLUGIN_IOS_NIF_SOURCES` — absolute paths of each activated plugin's iOS
  C/ObjC NIF source (`Merge.nif_sources(activated, :ios)`).
- `MOB_PLUGIN_IOS_FRAMEWORKS` — the union of frameworks the plugins declare
  (`Merge.ios_frameworks/1`).

`release_device.sh` loops over the sources, compiling each with
`-DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=<basename>` (so `ERL_NIF_INIT`
emits `<basename>_nif_init`, matching the driver table) and `-fmodules` (Clang
autolinks every framework the source `@import`s — a plugin often imports beyond its
manifest's declared set, e.g. Accelerate). The compiled objects join the swiftc
link line, and each declared framework is also passed explicitly.

## Consequences

- Any multi-plugin mob app can now produce a store-ready iOS binary. Verified:
  Sloppy Joe's 10 ObjC NIF plugins compile + link, and the IPA code-signs +
  validates against its App Store profile.
- Scope: this covers `nif_sources` (`lang: :c | :objc`) + `ios_frameworks`, which
  is what every current plugin uses. The dev path also handles plugin
  `swift_files` and `static_archives` (`:cpp_archive`, e.g. mob_nx_eigen); the
  release path does **not** yet. No shipped plugin needs those on iOS today, so
  they're a documented follow-up rather than untested code. A plugin that adds an
  iOS Swift source or cpp-archive NIF would relink-fail the same way until then.
- Tests: `plugin_ios_build_env/1` gets a pure matrix (none / one / many /
  platform-filtered) in `release_test.exs`; `release_script_test.exs` asserts the
  script shape (compile loop, libname derivation, `$PLUGIN_OBJS` on the link,
  framework flags) so a regression is caught at `mix test`, not in a TestFlight
  round trip.

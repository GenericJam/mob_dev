# A guarded project NIF selects itself by target arch, not by a build option

- Date: 2026-10-03
- Status: accepted
- Issue: MOB-376

## Context

`MobDev.StaticNifs` documents `:guard` for a `mob.exs` `:static_nifs` entry
whose `:archs` narrows a platform (e.g. `[:ios_device]`): "a preprocessor macro
that the build defines only on those archs". Nothing in a dev build defined it:

- `NativeBuild.project_nif_zig_args/1` passed `-D<module>_static=true` to
  `zig build`. mob_new's iOS sim, iOS device and Android build files declare
  only the built-in `sqlite_static` / `mlx_static` / `nxeigen_static` /
  `tflite_static` options, so zig stopped with
  `error: invalid option: -D<module>_static` (reproduced on mob_dev 0.7.11
  with a fresh `mix mob.new --blank --ios` app and one guarded C NIF).
- The generated Zig driver table read `build_options.<guard_flag_name(guard)>`,
  a field the same build files don't add, so the table would not have
  compiled either. The flag name came from the guard while the `-D` flag came
  from the module, so they only matched by naming convention.
- A C driver table wraps the entry in `#ifdef <guard>`, which a dev build never
  defines: the NIF was silently dropped.

`mix mob.release --ios` (MOB-373) defines `-D<guard>` on its own C table
compile, so releases worked.

## Decision

The generated tables decide a project guard themselves, from the entry's
`:archs` and the target they are compiled for:

- Zig: each guarded project entry gets its own flag, `<module>_on` (the module
  is already a C identifier, `<module>_nif_init`): `builtin.target.abi !=
  .simulator` for `[:ios_device]`, `== .simulator` for `[:ios_sim]`,
  `builtin.target.cpu.arch == .aarch64` for `[:android_arm64]`, `.arm`/`.thumb`
  for `[:android_arm32]`, `true` when the entry covers the whole platform. A
  flag per entry, not per guard, keeps two entries that share a guard on their
  own archs, and lets any C macro serve as a guard.
- C: `#if defined(<guard>) || <test>` with `TARGET_OS_SIMULATOR` (via
  `<TargetConditionals.h>`, emitted only when needed), `__aarch64__`,
  `__arm__` or `1`. Keeping `defined(<guard>)` means a build that defines the
  guard, like the release, still keeps the entry.
- `project_nif_zig_args/1` no longer emits `-D<module>_static=true`.

The four built-in guards (`default_nifs/0`) are feature switches, not arch
narrowing, and keep their template options (`build_options.<flag>` /
`#ifdef`). Tables with no project guard are byte-identical to before.

We rejected adding a generic guard option to mob_new's templates: mob_dev never
rewrites an app's `ios/build*.zig` or Android `build.zig` (`mix mob.adopt`
skips existing files), so only newly generated apps would have been fixed, as
happened with `tflite_static`, which several apps had to declare by hand. The
native build already regenerates `priv/generated/driver_tab_*` on every run
(`NativeBuild.regen_driver_tab!/0`), so a generator fix reaches existing apps
on their next `mix mob.deploy --native`.

## Consequences

- A guarded project NIF builds on every platform its `:archs` cover, in dev
  builds (Zig or C table) and releases, with any app's build files. Verified:
  the 0.7.11 repro app builds and boots on the simulator; compiled tables
  reference the NIF only on the targets its `:archs` name (zig for
  aarch64-ios / aarch64-ios-simulator / aarch64-linux-android /
  arm-linux-androideabi, Apple clang for both iOS SDKs). A `:requires_zig`
  test compiles the tables on a laptop; CI excludes it (no zig there), and
  text tests of each generated condition run in CI.
- `:guard` on a project entry no longer acts as an off switch: an entry whose
  `:archs` cover the platform is always registered (`|| 1`), even if nothing
  defines the macro. Nothing local relied on the old behaviour, and in a dev
  build it either failed (Zig) or always dropped the entry (C).
- An unguarded entry that narrows a platform still references its init symbol
  on every arch of the platform, as before; the guide says to add a `:guard`.
- Two project entries may share a guard name: the C table tests each entry's
  archs, and the Zig table gives each its own flag.

# Native builds refuse a `mob_dir` that isn't the `:mob` dependency

- Date: 2026-10-01
- Status: accepted

## Context

MOB-351: a native build compiles mob's C/ObjC/Swift (`-Dmob_dir=…`,
`ios/mob_beam.m`, `android/jni/*`, the release script's `$MOB_DIR`) from
`mob.exs` `mob_dir`. Mix compiles mob's Elixir side from the resolved `:mob`
dependency, `Mix.Project.deps_paths()[:mob]`. Nothing compared the two, so an
app could ship native code from one mob commit and BEAMs from another, build,
boot, and misbehave with no error. It happened twice on 2026-10-01: a clone
with `{:mob, path: "/tmp/mob_master"}` kept `mob_dir: "~/code/mob"` and made a
working MOB-348 fix look broken, and a stale `~/code/mob` reached through
`mob_dir` produced a MOB-226-shaped libc build error.

Every setup mob_dev and mob_new generate already makes the two agree:

- Hex (or git) `:mob`: `mob.exs` sets
  `mob_dir: Path.join(File.cwd!(), "deps/mob")`, which is where Mix puts the
  dependency.
- `--local`: `mix.exs` gets `{:mob, path: MOB_DIR, override: true}` and
  `mob.local.exs` gets `mob_dir: MOB_DIR`, the same path.

## Decision

- `MobDev.MobDirCheck` compares `mob_dir` with the `:mob` dependency path.
  Two existing directories match when they are the same directory (device and
  inode), so symlinked or differently-cased paths to one checkout pass. Paths
  that don't exist yet (a Hex dep before `mix deps.get`) are compared with
  every existing symlink resolved.
- On a mismatch, `MobDev.NativeBuild.build_all/1` (`mix mob.deploy --native`)
  and `MobDev.Release.build_ipa/1` (`mix mob.release`, iOS) raise before
  generating or compiling anything. The error names both paths and both
  fixes: point `mob_dir` at the dependency, or point the dependency at
  `mob_dir` with `{:mob, path: …, override: true}`. `mix mob.doctor` reports
  the same as a failed check.
- It fails rather than warns. A warning scrolls past in a multi-minute build
  whose result looks fine, which is how both incidents went unnoticed. No
  supported setup needs the two to differ: anyone who wants native code from a
  local mob checkout can make that checkout the dependency too, and the BEAMs
  then come from the same commit. So there is no opt-out.
- Nothing to compare means no check: `mob_dir` unset, or no `:mob` dependency
  in the project.

## Consequences

- A project whose `mob_dir` points at a checkout other than its dependency
  stops building until one of the two is changed. That is the intended break;
  the build it replaces was silently wrong.
- `mob_dir` is still required. Defaulting an unset `mob_dir` to the
  dependency path (suggested in MOB-351) would make the key optional, which
  also touches `mix mob.install`, `mix mob.doctor`'s required-key check and the
  Android path that expands it unguarded; left for its own change.
- Not covered: Android's Gradle/CMake fallback, which compiles
  `${MOB_DIR}/android/jni/*` with `MOB_DIR` taken from `mob.mob_dir` in
  `android/local.properties`. It runs only when no zig-built objects exist
  (an Android Studio sync, a bare `./gradlew`). `mix mob.deploy --native`
  rewrites `local.properties` only while it still has a placeholder or no
  `sdk.dir`, so that value can go stale independently of `mob.exs`.
  `mix mob.release --android` (`MobDev.ReleaseAndroid.build_aab/1`) compiles
  no mob native code itself: Gradle packages the objects the last
  `mix mob.deploy --native` built, which this check covered, or falls back to
  the CMake path above.

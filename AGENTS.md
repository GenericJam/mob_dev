# AGENTS.md — mob_dev

You're in **mob_dev**, the build/deploy/devices toolkit. Read
[`~/code/mob/AGENTS.md`](../mob/AGENTS.md) first for the system view, the
three-repo topology, the cross-cutting pre-empt-failure rules, and the
**"Don't write this slop"** list (AI-generated patterns to avoid at write
time, not after credo flags them). The notes below are mob_dev-specific.

## What this repo is

Mix tasks (`mob.deploy`, `mob.connect`, `mob.devices`, `mob.emulators`,
`mob.provision`, `mob.doctor`, `mob.battery_bench_*`) plus their backing
modules (`MobDev.Discovery.{Android,IOS}`, `MobDev.NativeBuild`,
`MobDev.OtpDownloader`, `MobDev.Deployer`, `MobDev.Emulators`).

The **release tooling** lives at `scripts/release/` — shell scripts for
cross-compiling OTP for Android arm64/arm32, iOS sim, and iOS device, then
staging the tarballs and uploading to GitHub Releases. Patches we apply to
OTP source for iOS-device compatibility live at
`scripts/release/patches/` (`forker_start` skip, EPMD `NO_DAEMON` guard).
See `build_release.md` for the full release walkthrough.

## TDD is the practice here

Write tests before or alongside new code. Every new function should have
corresponding tests before the task is considered done. The test suite must
stay green at all times.

```bash
mix test                       # all tests
mix test --exclude integration # skip the device-dependent ones
```

## Things that bite specifically in mob_dev

- **Compile-time regex literals are unsafe** on Elixir 1.19 / OTP 28.0. Use
  `Regex.compile!("...", "flags")` for runtime compilation. Already swept in
  0.3.17 — don't reintroduce.
- **`mix mob.deploy --device <id>`** resolves the id via discovery before
  deciding which platform to build. The narrowing logic is in
  `narrow_platforms_for_device/2` and is the single source of truth for both
  build and deploy. Bypass it and you'll get either spurious "No device
  matched" warnings (deploy) or builds for the wrong platform (build).
- **`xcodebuild` errors get rewritten** to actionable hints by
  `diagnose_xcodebuild_failure/1` in `mob.provision`. Apple's verbatim text is
  preserved alongside our hint so the snippet stays google-able. Add new
  pattern matches there when you encounter a new Apple error string.
- **APNs push token never arrives on iOS device** if the binary's codesigning
  entitlements omit `aps-environment`. `NativeBuild.codesign_ios_device_app/3`
  auto-mirrors the value from the embedded provisioning profile into the
  fallback entitlements. If the profile was provisioned without push, no
  mirroring happens — either re-provision with push enabled or create
  `ios/<AppName>.entitlements` with `aps-environment: development`. Test the
  plist text via `NativeBuild.fallback_entitlements_plist/3`.
- **OTP tarball schema changes need bumping `valid_otp_dir?/2`** in
  `otp_downloader.ex` so existing caches auto-redownload. Don't bump the OTP
  hash — the schema check is the right knob.
- **The release scripts assume `~/code/otp` exists** with the right cross-compile
  output. The patches in `scripts/release/patches/` are applied automatically
  by `xcompile_ios_device.sh`, idempotently — re-running is safe.
- **`mob.add_nif` is the entry point for new NIFs.** Don't add `:static_nifs`
  entries by hand to `mob.exs` — the task already does the AST-aware append,
  generates the Elixir stub via Igniter, and re-runs `mob.regen_driver_tab`
  so `priv/generated/driver_tab_*.zig` stays in sync. `--type` of `c`,
  `zigler`, `rustler` also drops the right native skeleton; `elixir-only`
  (default) leaves the C/Zig/Rust to you. The stubs for zigler/rustler
  carry an explicit static-link warning — those backends produce dlopen'd
  `.so` by default, which is wrong for Mob's iOS App Store /
  Android-RTLD_LOCAL constraints. The host-dev path works; on-device
  shipping needs the user to wire the archive into ios/build.zig +
  android/jni/ themselves. Reach for `--type c` if static linking matters
  more than the source language.
- **`mob.regen_driver_tab` reads `:static_nifs` from `mob.exs`** via
  `Config.Reader`, NOT from `Application.get_env`. mob.exs is not
  auto-imported into Mix application env (this matches every other
  mob_dev task that consumes mob.exs values). If you add a new task that
  reads `:static_nifs`, use `MobDev.Config.load_mob_config()` to stay
  consistent — using `Application.get_env(:mob_dev, :static_nifs, [])`
  silently misses the user's entries.
- **`mob.enable` is now Igniter-driven (Phase 4).** Per-feature
  handlers live in `MobDev.Enable.Igniter` and return
  `igniter -> igniter`. When adding a new feature: add a clause to
  the `@valid_features` list in `mob.enable.ex`, a `dispatch/3`
  clause, and an `enable_<name>/2` function in
  `MobDev.Enable.Igniter`. Use `Igniter.update_file` for text-level
  patches (plist, AndroidManifest, JS, HEEX) and AST-aware helpers
  (`Igniter.Project.Module.create_module`, `Project.Deps.add_dep`,
  `Project.Config.modify_config_code`) for Elixir source. Always
  emit `Igniter.add_notice` when a platform dir is missing — silent
  skips were a recurring user-confusion source in the legacy task.
- **File discovery in `Enable.Igniter` is Igniter-aware.** Helpers
  like `find_ios_plist/1` and `find_android_manifest/1` check disk
  first then fall back to `Rewrite.paths(igniter.rewrite)` /
  `Igniter.exists?/2`, so `Igniter.test_project(files: %{...})` in
  tests works without writing to disk. Don't bypass this with raw
  `File.exists?/1` — `mix mob.enable` tests will pass on disk but
  break Igniter test virtualization.
- **`mix mob.enable` reads app name via `Igniter.Project.Application.app_name/1`**,
  NOT `File.cwd!() <> "/mix.exs"`. Under `test_project`, disk reads
  see mob_dev's own mix.exs (wrong app). Falls back to the legacy
  on-disk read only when Igniter has no mix.exs source.
- **`mix mob.adopt` is the install-into-existing-Phoenix task** (Igniter,
  like `mob.enable`). The orchestrator (`Mix.Tasks.Mob.Adopt`) gates on
  `MobDev.AdoptGuard.check/2` then composes the sub-installers
  `mob.adopt.{deps,bridge,screen,mob_app,mob_exs,native,finalize}` — each a
  task module under `lib/mix/tasks/mob/adopt/`. Pre-1.0 it *refuses* (adds
  Igniter issues, no file changes) on unblessed shapes; widen the guard, not
  the silent-proceed path. Shared Elixir-source content + LV-bridge patches
  live in `MobDev.Adopt.Patcher`; assigns / dep-resolution / Pythonx wiring
  in `MobDev.Adopt.Generator`. **The native Android/iOS trees come from
  mob_new's `priv/templates/mob.new/`** — `Generator.templates_root/1`
  resolves a `:mob_new` dep, then `$MOB_NEW_DIR`, then `~/code/mob_new`. Both
  `Adopt.{Patcher,Generator}` are duplicated from mob_new's
  `LiveViewPatcher` / `ProjectGenerator` (mob_new is a self-contained
  archive, can't depend on mob_dev); Phase 5 of `build_system_migration.md`
  reunifies them. See `decisions/2026-06-19-mob-adopt-lives-in-mob_dev.md`.
  `MobDev.AdoptGuard.check/2` / `mode_from/1` and the `Adopt.Patcher` /
  `Adopt.Generator` helpers are public for testing — don't privatise.

## Public-but-undocumented seams

A few helpers are public specifically to enable testing (the parsing and
narrowing functions). Don't make them private:

- `Discovery.Android.parse_devices_output/1`
- `Discovery.IOS.parse_simctl_json/1`, `parse_simctl_text/1`, `parse_runtime_version/1`
- `OtpDownloader.valid_otp_dir?/2`, `ios_device_extras_present?/1`
- `PythonAppleSupport.valid_dir?/1`
- `NativeBuild.narrow_platforms_for_device/2`, `ios_toolchain_available?/0`, `read_sdk_dir/1`, `fallback_entitlements_plist/3`
- `NativeBuild.pythonx_in_project?/1`, `python_apple_support_env/2`
- `NativeBuild.build_all_with_outcome/1`, `build_outcome/1`,
  `resolve_android_update_targets/2`,
  `install_android_updates/3`, and `install_and_deliver_android/4` (update-only
  Android deploy safety seams; injected command/delivery functions are for
  hermetic command-history tests)
- `AndroidDeployLock.valid?/2`, `acquire/4`, `verify_owner/3`, `transition/4`,
  `release/2`, `status/3`, and `cleanup_committed_tombstone/3` (the shared,
  exact-target Android mutation lease and its bounded recovery surface)
- `HotPush.prepare/1`, `push_prepared/2`, `push_prepared/3`,
  `validate_prepared_snapshot/1`, and `push_prepared_fenced/3` (immutable BEAM
  snapshot and lease-fenced RPC seams; raw Android pushes intentionally reject)
- `Mix.Tasks.Mob.DeployLock.inspect_or_cleanup/4` (hermetic task decision seam;
  production still requires an explicit exact `--device`)
- `Deployer.select_canonical_android_devices/2` (native final-pass exact-target
  selection; ordinary `--device` matching remains user-friendly)
- `NativeBuild.__prune_plugin_artifacts__/2` (the plugin-removal prune; ledger-tracked per merge concern)
- `Enable.inject_pythonx_dep/1`, `inject_pythonx_uv_init_gate/2`, `python_paths_module_template/1`
- `Emulators.parse_simctl_json/1`, `find_emulator_binary/1`
- `Provision.diagnose_xcodebuild_failure/1`

If you make any of these private, every downstream test breaks loudly — but
you'll lose the ability to evolve the parsers safely.

## Destructive-task conventions

Apply consistently to every Mix task that mutates device state
(`mix mob.uninstall` today; `mix mob.deploy --all-devices`,
`mix mob.connect`, future ones).

**Emulator vs physical safety pattern (from `mix mob.uninstall`):**

- `--all-devices` sweeps **emulators and simulators only**. NEVER
  physical devices. Phones are someone's personal property and have
  real-data blast radius; emulators are throwaway dev fixtures.
- `--all-physical` is the opt-in for sweeping physical devices.
  Composes with `--all-devices` for "literally everything."
- `--device <id>` is the explicit-id escape hatch — the user typed
  the id, that's consent; bypasses the type filter regardless of
  whether the device is emulator or physical.
- **Auto-detect** (no flags, exactly one device connected) only
  fires for a non-physical device. A solo phone connected with no
  flags → error with a hint pointing at `--all-physical` or
  `--device`.

The predicate to route on is `MobDev.Device.physical?/1`. The
selection logic lives in `MobDev.Uninstaller.select_devices/3`
(public for testing); same shape should appear in any new task
needing the same fan-out behavior. Pin the headline guarantee in
each task's tests — "personal iPhone + dev emulators + `--all-devices`
must leave the iPhone alone."

Android **native** deploys resolve a non-empty connected serial set (narrowed
by `--device <id>` when supplied) and run only the data-preserving
`adb -s <serial> install -r <apk>` update path. They never force-stop first,
uninstall, or fall back to a clean install. A failed update must prevent the
final `MobDev.Deployer` pass, though successful devices in a multi-target plan
may receive their matching OTP payload first. OTP delivery is attempted and
aggregated per successful serial, and a fully successful native build carries
that exact canonical Android serial allowlist into the final BEAM deploy so a
later discovery snapshot cannot widen the set.

Never recover by clearing app data, uninstalling, deleting an active lock, or
blindly retrying. `mix mob.deploy_lock --device <exact-serial>` is read-only;
`--cleanup-committed` may remove only one exact record-only tombstone already
in a committed phase and must prove the final clear state.

**TODO:** apply the full physical-device selection pattern to the fast
`mix mob.deploy` BEAM fan-out (today's broad deploy can push BEAMs to a personal
phone). When that fan-out exists
or grows, factor `select_devices/3` plus the flag plumbing into a
shared `MobDev.TaskTargets` (or similar) module so the rules don't
drift between tasks.

## Naming gotcha: `mix mob.install` vs `mix mob.uninstall`

These look like inverses but aren't. Future agents touching either
should know:

- **`mix mob.install`** — first-run **project setup**. Downloads the
  OTP runtime, generates icons, writes `mob.exs`. Per-project, runs
  once. Doesn't touch any device.
- **`mix mob.uninstall`** — per-**device** app removal. Sweeps
  connected devices and removes installed `.app` / `.apk` bundles.
  Doesn't undo `mix mob.install`'s project setup.

A user reading the task list will plausibly type `mix mob.uninstall`
expecting it to undo `mix mob.install`. If we ever want true
symmetry, the device-cleanup task wants a clearer name (e.g.
`mob.app.uninstall` or `mob.devices.clear`) and `mob.uninstall`
could become the project-cleanup inverse of `mob.install`. Until we
make that call, the help text in both task @moduledoc blocks
should call out the scope difference explicitly. Don't quietly
rename — users have muscle memory by now.

## Keep this file up to date

When you change repo conventions, add a public seam, or hit a new gotcha —
update this file in the same commit. Stale guidance is worse than none.

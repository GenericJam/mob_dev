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

## Verification fidelity ladder

This repo builds and deploys other people's apps, so its failures are mostly
failures to notice that nothing happened. Run every applicable lower rung, plus
the highest rung the change actually reaches, and say which rung you stopped at.

1. **Static.** `mix format --check-formatted`, `mix credo --strict` (ex_slop
   included), `mix compile --warnings-as-errors`.
2. **Host unit.** `mix test`. Proves the task's logic against fixtures. Proves
   nothing about a real toolchain.
3. **Task run against a real project.** Actually invoke the task on a generated
   app and read the output. A task that unit-tests green can still skip its real
   work — a missing toolchain or a mismatched device id once produced a clean
   exit-0 from a deploy that never built anything, and cost several hours of
   debugging failures that had not happened.
4. **Deployed, and the app answers.** `mix mob.deploy` to a simulator or
   emulator, then attach and confirm the BEAM is up and a screen renders.
   Deploy success is the tool's opinion; a reachable node is evidence.
5. **Physical device, and the release variant.** Release changes linkage and
   packaging: iOS release links plugin NIFs by a separate path
   (`decisions/2026-07-07-ios-release-links-plugin-nifs.md`), and release
   `otp.zip` handling is variant-scoped
   (`decisions/2026-07-24-release-otp-zip-variant-scoped-assets.md`). A release
   also leaves an `assets/otp.zip` that crash-loops the next debug deploy.
6. **From the packed Hex tarball, not the working tree.** Hex omits
   repository-root dotfiles, so code under `lib/` that reads one compiles here
   and fails for everyone else. Two releases shipped broken this way. Build the
   package and compile from it before publishing.

Every rung above exists because something got through the one below it.

Two rules that outrank the list:

- **Never substitute a lower rung because a higher one is slow, broken, or
  inconvenient.** Fix the harness, open an issue, or state plainly that the rung
  was unavailable and why. An unavailable rung is a fine answer. A silently
  skipped one is not.
- **Verify effects, not exit codes.** This repo is where that rule was learned
  and it is the repo most able to break it: every task here should prove its
  effect happened rather than reporting that it returned.

## Things that bite specifically in mob_dev

- **Compile-time regex literals are unsafe** on Elixir 1.19 / OTP 28.0. Use
  `Regex.compile!("...", "flags")` for runtime compilation. Already swept in
  0.3.17 — don't reintroduce.
- **Hex packages omit repository-root dotfiles by default.** Code under `lib/`
  must not compile-time read `.tool-versions` or another root-only file. Keep a
  packaged authority in source, enforce exact lockstep with the root file in a
  source test, and compile the unpacked Hex artifact in the regression suite.
- **`mix mob.deploy --device <id>`** resolves the id via discovery before
  deciding which platform to build. The narrowing logic is in
  `narrow_platforms_for_device/2` and is the single source of truth for both
  build and deploy. Bypass it and you'll get either spurious "No device
  matched" warnings (deploy) or builds for the wrong platform (build).
- **Deployment BEAM discovery follows Mix's active paths.** Use
  `Mix.Project.build_path/0` for dependency output and
  `Mix.Project.compile_path/0` for every application BEAM, including modules
  compiled from `erlc_paths`. Hard-coding `_build/dev` can push a stale,
  incomplete override that shadows the complete application bundle.
- **Physical iOS BEAM overrides must be exact and self-verifying.** The app
  prefers `Documents/otp/<app>` over its complete signed bundle. Replace that
  directory rather than incrementally merging it, require `<app>.beam` before
  transfer, and verify the received bootstrap bytes before restarting.
- **iOS bundle ids resolve through one function per side, never `bundle_id/0`.**
  Consumers (deploy, connect, provision, battery bench) use
  `MobDev.Config.ios_bundle_id/0`; the build (sim bundle, device bundle,
  codesign) uses `NativeBuild.ios_bundle_id/1` over the loaded cfg. Both are
  `:ios_bundle_id || :bundle_id`. Reaching for plain `bundle_id/0` on an
  iOS path is the bug that installed an app under one id and pushed BEAMs at
  another ("App '…' is not installed on this device" right after a
  successful install). Android keeps `bundle_id/0` — the two ids often
  cannot be the same string (Apple forbids `_`). See
  `decisions/2026-08-08-ios-bundle-id-single-source-and-deploy-exit-code.md`.
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
- **The application-build Zig version is exact.** `MobDev.Toolchain` embeds the
  root `.tool-versions` pin and both native build preflight and `mob.doctor`
  reject any other version. `mob.adopt` deliberately does not rewrite an
  existing Phoenix project's toolchain file: it installs `build.zig`-bearing
  native trees, then the preflight reports a missing or conflicting pin with
  the exact mise command. Changing an adopted app's existing language/runtime
  pins without its owner's consent would be destructive.
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
- `NativeBuild.__prune_plugin_artifacts__/2` (the plugin-removal prune; ledger-tracked per merge concern)
- `Mix.Tasks.Mob.Doctor.__zig_install_fix__/0`
- `Mix.Tasks.Mob.Doctor.__zig_check_result__/1`
- `Enable.inject_pythonx_dep/1`, `inject_pythonx_uv_init_gate/2`, `python_paths_module_template/1`
- `NativeBuild.ios_bundle_id/1` (the `:ios_bundle_id || :bundle_id` rule for the build side)
- `Deployer.ios_bundle_id/0`, `Connector.ios_bundle_id/0` (the same rule on the
  consumer side — public so the WIRING is testable, not just the resolver;
  reverting either to `bundle_id/0` was the original defect and the suite
  did not notice)
- `Emulators.parse_simctl_json/1`, `find_emulator_binary/1`
- `Provision.diagnose_xcodebuild_failure/1`
- `Mix.Tasks.Mob.Deploy.failure_message/3` (which bucket makes a deploy exit non-zero)
- `Uninstaller.resolve_apps_for_device/3` (which id gets uninstalled, per platform)

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

**TODO:** apply this pattern to `mix mob.deploy` (today's `--all-devices`
deploy can push BEAMs to a personal phone). When that fan-out exists
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

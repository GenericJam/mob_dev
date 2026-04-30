# AGENTS.md — mob_dev

You're in **mob_dev**, the build/deploy/devices toolkit. Read
[`~/code/mob/AGENTS.md`](../mob/AGENTS.md) first for the system view, the
three-repo topology, and the cross-cutting pre-empt-failure rules. The notes
below are mob_dev-specific.

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
- **OTP tarball schema changes need bumping `valid_otp_dir?/2`** in
  `otp_downloader.ex` so existing caches auto-redownload. Don't bump the OTP
  hash — the schema check is the right knob.
- **The release scripts assume `~/code/otp` exists** with the right cross-compile
  output. The patches in `scripts/release/patches/` are applied automatically
  by `xcompile_ios_device.sh`, idempotently — re-running is safe.

## Public-but-undocumented seams

A few helpers are public specifically to enable testing (the parsing and
narrowing functions). Don't make them private:

- `Discovery.Android.parse_devices_output/1`
- `Discovery.IOS.parse_simctl_json/1`, `parse_simctl_text/1`, `parse_runtime_version/1`
- `OtpDownloader.valid_otp_dir?/2`, `ios_device_extras_present?/1`
- `NativeBuild.narrow_platforms_for_device/2`, `ios_toolchain_available?/0`, `read_sdk_dir/1`
- `Emulators.parse_simctl_json/1`, `find_emulator_binary/1`
- `Provision.diagnose_xcodebuild_failure/1`

If you make any of these private, every downstream test breaks loudly — but
you'll lose the ability to evolve the parsers safely.

## Keep this file up to date

When you change repo conventions, add a public seam, or hit a new gotcha —
update this file in the same commit. Stale guidance is worse than none.

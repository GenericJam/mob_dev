# Release otp.zip moves to the release-variant asset source set

- Date: 2026-07-24
- Status: accepted

## Context

`mix mob.deploy --native` on Sloppy Joe reported success and every
intermediate step verified correct (fresh BEAM staged, `tar cf` built the
right archive, `adb push` succeeded, `run-as tar xf` returned exit 0 with no
stderr) — yet the on-device `Elixir.SloppyJoe.DefaultScreens.beam` stayed at
its old size and content after every deploy.

Root-caused by direct device inspection: the debug APK's `assets/otp.zip`
(bundled by `MobDev.ReleaseAndroid.build_zip/2`, normally a release-only
artifact) contained a stale snapshot of that exact BEAM file. `mix
mob.release --android` had written it to `android/app/src/main/assets/otp.zip`
— the **shared `main`** Gradle asset source set, which every build variant
merges, debug included. `MobBridge.kt`'s `extractOtpIfNeeded()` re-extracts
`otp.zip` whenever `PackageInfo.lastUpdateTime` changes (i.e. on every
reinstall, debug or release), wiping `<filesDir>/otp/` and restoring
whatever was bundled at the time of the *last release build* — silently
overwriting BEAMs the debug deploy had just pushed fresh via `adb`.

The comment on `extractOtpIfNeeded()` already assumed debug builds carry no
`otp.zip` at all ("no asset zip exists and this method becomes a no-op") —
that assumption only holds if nothing else leaves one behind in `main`.

## Decision

`MobDev.ReleaseAndroid` now writes the release OTP bundle to
`android/app/src/release/assets/otp.zip` — a **build-variant-scoped** Gradle
source set. Gradle only merges `src/<variant>/assets/` into matching-variant
builds, so a release build can never again leave an asset that a debug build
picks up, regardless of whether anyone remembers to clean up afterward.

Defense in depth for checkouts that already carry the old, dangerous file:
`MobDev.NativeBuild.remove_stale_release_otp_zip/1` runs at the start of
every debug `gradle_assemble/0`, deleting
`android/app/src/main/assets/otp.zip` if present. New release builds won't
recreate it there, but this heals any project that shipped a release before
this fix without requiring a manual `rm`.

## Consequences

- `mix mob.release --android` output path changes from
  `src/main/assets/otp.zip` to `src/release/assets/otp.zip`. No other code
  read the old path directly (confirmed via repo-wide grep); `bundleRelease`
  picks up the new location automatically via Gradle's standard variant
  source-set merging.
- Verified end-to-end on a physical device (Moto G Power, non-rooted,
  `run-as` fallback push path): with the stale `src/main/assets/otp.zip`
  removed, `mix mob.deploy --native` correctly left fresh BEAM content
  on-device; restoring the stale file reproduced the staleness bug exactly,
  confirming this was the sole cause (the beam push/tar/extraction mechanism
  itself was never at fault).
- This was previously worked around ad hoc ("rm src/main/assets/otp.zip
  before debug deploys") after an earlier session traced the same leftover
  file to a *different* symptom (a debug crash-loop). That workaround is now
  obsolete — the fix is structural, not a manual step to remember.

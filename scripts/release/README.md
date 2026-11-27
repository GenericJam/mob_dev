# scripts/release

Runnable companions to [`build_release.md`](../../build_release.md). Each
script implements one stage of the release build; the markdown carries the
narrative, the scripts carry the imperative.

## Files

| Script | Mirrors `build_release.md` step | What it does |
|---|---|---|
| `_lib.sh` | — | Sourced helpers: env defaults, ERTS version detection, Elixir-stdlib bundler. |
| `xcompile_ios_device.sh` | Step 3b.0 | One-time: cross-compile OTP for iOS arm64 (populates `erts/aarch64-apple-ios/` and `/tmp/otp-ios-device`). |
| `tarball_ios_device.sh` | Step 3b | Stage + tar `otp-ios-device-<hash>.tar.gz` (includes EPMD source for static-link). |
| `tarball_ios_sim.sh` | Step 3 | Stage + tar `otp-ios-sim-<hash>.tar.gz`. |
| `tarball_android_arm64.sh` | Step 2 (arm64) | Stage + tar `otp-android-<hash>.tar.gz`. |
| `tarball_android_arm32.sh` | Step 2 (arm32) | Stage + tar `otp-android-arm32-<hash>.tar.gz`. |
| `publish.sh` | Step 4 | Upload new assets to the GitHub release (never replaces one) and print their `MobDev.Download.Pins` entries. |

## Common environment

All scripts source `_lib.sh` and respect these env vars:

| Var | Default | Purpose |
|---|---|---|
| `OTP_SRC` | `~/code/otp` | OTP source checkout (used to read `erts/vsn.mk` and copy headers/libs). |
| `HASH` | auto from `git -C $OTP_SRC rev-parse --short HEAD` | Release tag hash, e.g. `73ba6e0f`. |
| `ERTS_VSN` | auto from `$OTP_SRC/erts/vsn.mk` | e.g. `16.3`. |
| `OUT_DIR` | `/tmp` | Where finished tarballs land. |
| `ELIXIR_LIB` | from `:code.lib_dir(:elixir)` | Host Elixir lib dir for stdlib bundling. |

Per-script overrides (e.g. `OTP_RELEASE`, `EXQLITE_BUILD`, `ASN1RT_NIF_ARM32`)
are documented in each script's header.

## Typical full-release flow

```bash
cd ~/code/mob_dev/scripts/release

# (one time per OTP hash, ~10 min)
./xcompile_ios_device.sh

# (assumes Android arm64/arm32 + iOS sim install dirs already exist —
#  see build_release.md prerequisites for those cross-compiles)
EXQLITE_BUILD=~/code/toy_lv_app/_build/dev/lib/exqlite ./tarball_android_arm64.sh
EXQLITE_BUILD=~/code/toy_lv_app/_build/dev/lib/exqlite ./tarball_android_arm32.sh
./tarball_ios_sim.sh
./tarball_ios_device.sh

./publish.sh   # uploads whatever is in /tmp matching the hash, prints the pins
```

Then paste the printed pin lines into `lib/mob_dev/download/pins.ex` in the
same PR that bumps `@otp_hash` (build_release.md, Step 5). `mix test` fails
until every asset the downloaders can request has a pin.

## Rebuilding a published tarball

Published assets are never replaced: every released mob_dev pins the sha256
of the asset behind each URL, so new bytes at an old URL break all of them
(and `publish.sh` refuses to try). When a tarball's contents change without
an OTP version change (e.g. iOS device gained EPMD source), publish it under a
**new hash** derived from the content, as the Elixir 1.20.1 rebuild did
(`decisions/2026-06-17-otp-hash-elixir-1.20.1.md`), and publish all five
tarballs under it (the downloader names every runtime by the one
`@otp_hash`; unchanged ones can be copied to the new name). See
`decisions/2026-11-26-pinned-runtime-downloads.md`.

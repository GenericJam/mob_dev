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
| `publish.sh` | Step 4 | Upload (or replace) assets on the GitHub release. |

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

./publish.sh   # uploads whatever is in /tmp matching the hash
```

## Schema-bump-only re-upload

When you only need to refresh one tarball (e.g. iOS device gained EPMD source
without an OTP version change), just run that one script + `publish.sh`. The
publish script auto-detects which tarballs are present and only uploads those.

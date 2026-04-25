# Building and Publishing OTP Release Tarballs

`MobDev.OtpDownloader` pulls pre-built OTP runtimes from a GitHub release on
`GenericJam/mob`. This file documents how to build and publish those tarballs
when upgrading OTP.

---

## What's in each tarball

Both tarballs must extract (via `--strip-components=1`) into a flat directory
that looks like an OTP release root:

```
erts-<vsn>/
  bin/          # ERTS executables (erl_child_setup, inet_gethost, epmd, ...)
  include/      # Headers (iOS only — see below)
  lib/          # Static libs + ERTS internal libs
    libbeam.a
    libzstd.a       (iOS only)
    libepcre.a      (iOS only)
    libryu.a        (iOS only)
    asn1rt_nif.a    (iOS only)
    internal/
      liberts_internal_r.a
      libethread.a
lib/            # OTP stdlib (kernel, stdlib, elixir, logger, ...)
releases/
  29/
    start_clean.boot
    start_sasl.boot
```

### Android arm64 (`otp-android-<hash>.tar.gz`)

Built from a full cross-compiled OTP release for `aarch64-unknown-linux-android`.
Needs the same extra static libs and headers as iOS (see Step 2).

The ERTS helper binaries (`erl_child_setup`, `inet_gethost`, `epmd`) must be
in `erts-<vsn>/bin/`; `mob_dev` copies them into the APK as `lib*.so` (required
for SELinux `execve` permission on Android).

### Android arm32 (`otp-android-arm32-<hash>.tar.gz`)

Built from a full cross-compiled OTP release for `arm-unknown-linux-androideabi`
(armeabi-v7a). Same structure as arm64. Required for 32-bit-only devices (e.g.
Motorola E 2020).

`asn1rt_nif.a` must be compiled separately — it is not emitted by the OTP build
system for arm32. Build it with:

```bash
NDK=~/Library/Android/sdk/ndk/27.2.12479018/toolchains/llvm/prebuilt/darwin-x86_64/bin
OTP_SRC=~/code/otp

$NDK/armv7a-linux-androideabi21-clang \
  -march=armv7-a -mfloat-abi=softfp -mthumb \
  -fvisibility=hidden -fno-common -fno-strict-aliasing \
  -fstack-protector-strong -O2 \
  -I "$OTP_SRC/erts/arm-unknown-linux-androideabi" \
  -I "$OTP_SRC/erts/include/arm-unknown-linux-androideabi" \
  -I "$OTP_SRC/erts/emulator/beam" \
  -I "$OTP_SRC/erts/include" \
  -DHAVE_CONFIG_H \
  -DSTATIC_ERLANG_NIF_LIBNAME=asn1rt_nif \
  -c "$OTP_SRC/lib/asn1/c_src/asn1_erl_nif.c" \
  -o /tmp/asn1rt_nif_arm32.o

$NDK/llvm-ar rc /tmp/asn1rt_nif_arm32.a /tmp/asn1rt_nif_arm32.o
$NDK/llvm-ranlib /tmp/asn1rt_nif_arm32.a
```

Then include it in the tarball at `erts-<vsn>/lib/asn1rt_nif.a` (see Step 2b).

### iOS simulator (`otp-ios-sim-<hash>.tar.gz`)

Built from a cross-compiled OTP for `aarch64-apple-iossimulator`. Needs:

1. **Headers** at `erts-<vsn>/include/` (same set for both platforms, arch-specific file differs):
   - `erl_nif.h` — from `erts/emulator/beam/erl_nif.h`
   - `erl_nif_api_funcs.h` — from `erts/emulator/beam/erl_nif_api_funcs.h`
   - `erl_drv_nif.h` — from `erts/emulator/beam/erl_drv_nif.h`
   - `erl_int_sizes_config.h` — iOS: `erts/include/aarch64-apple-iossimulator/erl_int_sizes_config.h` / Android: `erts/include/aarch64-unknown-linux-android/erl_int_sizes_config.h`
   - `erl_fixed_size_int_types.h` — from `erts/include/erl_fixed_size_int_types.h`

2. **Extra static libs** at `erts-<vsn>/lib/`:
   - `libzstd.a` — `erts/emulator/zstd/obj/aarch64-apple-iossimulator/opt/libzstd.a`
   - `libepcre.a` — `erts/emulator/pcre/obj/aarch64-apple-iossimulator/opt/libepcre.a`
   - `libryu.a` — `erts/emulator/ryu/obj/aarch64-apple-iossimulator/opt/libryu.a`
   - `asn1rt_nif.a` — `lib/asn1/priv/lib/aarch64-apple-iossimulator/asn1rt_nif.a`

---

## Prerequisites

- A cross-compiled OTP build. The OTP source tree at `~/code/otp` (commit `73ba6e0f`)
  has iOS simulator and Android targets already compiled.
- `gh` CLI authenticated to the `GenericJam` GitHub account.

---

## Step 1 — Locate the OTP commit hash

```bash
cd ~/code/otp
git rev-parse --short HEAD   # e.g. 73ba6e0f
```

Use this hash everywhere below as `<hash>`.

---

## Step 2 — Build the Android tarball

The Android OTP release lives at `bin/aarch64-unknown-linux-android/` and
the release dir (wherever `make install` put it — check the previous release
for the path, typically `/tmp/otp-android` or similar).

```bash
OTP_SRC=~/code/otp
OTP_RELEASE=/tmp/otp-android   # adjust if different
HASH=<hash>
STAGE=$(mktemp -d)

cp -r "$OTP_RELEASE/." "$STAGE"

# Add extra static libs
ERTS_LIB="$STAGE/erts-16.3/lib"   # update version as needed
cp "$OTP_SRC/erts/emulator/zstd/obj/aarch64-unknown-linux-android/opt/libzstd.a" "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/pcre/obj/aarch64-unknown-linux-android/opt/libepcre.a" "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/ryu/obj/aarch64-unknown-linux-android/opt/libryu.a"   "$ERTS_LIB/"
cp "$OTP_SRC/lib/asn1/priv/lib/aarch64-unknown-linux-android/asn1rt_nif.a"       "$ERTS_LIB/"

# Add required headers
ERTS_INC="$STAGE/erts-16.3/include"
mkdir -p "$ERTS_INC"
cp "$OTP_SRC/erts/emulator/beam/erl_nif.h"                                        "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_nif_api_funcs.h"                              "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_drv_nif.h"                                    "$ERTS_INC/"
cp "$OTP_SRC/erts/include/aarch64-unknown-linux-android/erl_int_sizes_config.h"   "$ERTS_INC/"
cp "$OTP_SRC/erts/include/erl_fixed_size_int_types.h"                             "$ERTS_INC/"

BASE=$(basename $STAGE)
tar czf "/tmp/otp-android-$HASH.tar.gz" -C "$(dirname $STAGE)" "$BASE"

# Verify
tar tzf "/tmp/otp-android-$HASH.tar.gz" | grep "\.a$\|\.h$"
```

---

## Step 3 — Build the iOS simulator tarball

The iOS OTP runtime typically lives at `/tmp/otp-ios-sim`. App-specific BEAM
directories (created by `ios/build.sh` runs) must be excluded.

```bash
OTP_SRC=~/code/otp
OTP_ROOT=/tmp/otp-ios-sim
HASH=<hash>
STAGE=$(mktemp -d)

# Copy the OTP runtime
cp -r "$OTP_ROOT/." "$STAGE"

# Add extra static libs
ERTS_LIB="$STAGE/erts-16.3/lib"   # update version as needed
cp "$OTP_SRC/erts/emulator/zstd/obj/aarch64-apple-iossimulator/opt/libzstd.a" "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/pcre/obj/aarch64-apple-iossimulator/opt/libepcre.a" "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/ryu/obj/aarch64-apple-iossimulator/opt/libryu.a"   "$ERTS_LIB/"
cp "$OTP_SRC/lib/asn1/priv/lib/aarch64-apple-iossimulator/asn1rt_nif.a"       "$ERTS_LIB/"

# Add required headers
ERTS_INC="$STAGE/erts-16.3/include"
cp "$OTP_SRC/erts/emulator/beam/erl_nif.h"                                     "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_nif_api_funcs.h"                           "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_drv_nif.h"                                 "$ERTS_INC/"
cp "$OTP_SRC/erts/include/aarch64-apple-iossimulator/erl_int_sizes_config.h"   "$ERTS_INC/"
cp "$OTP_SRC/erts/include/erl_fixed_size_int_types.h"                          "$ERTS_INC/"

# List any app-specific BEAM dirs to exclude (ls $OTP_ROOT | grep -vE "^(erts|lib|releases|misc|usr)$")
BASE=$(basename $STAGE)
tar czf "/tmp/otp-ios-sim-$HASH.tar.gz" \
    --exclude="$BASE/beamhello" \
    --exclude="$BASE/test_app" \
    --exclude="$BASE/test_app0" \
    -C "$(dirname $STAGE)" "$BASE"

# Verify
tar tzf "/tmp/otp-ios-sim-$HASH.tar.gz" | grep "\.a$"
tar tzf "/tmp/otp-ios-sim-$HASH.tar.gz" | grep "\.h$"
```

---

## Step 4 — Publish the GitHub release

Tag format: `otp-<hash>` (e.g. `otp-73ba6e0f`).

```bash
HASH=<hash>

# Create the release (or use an existing one)
gh release create "otp-$HASH" \
    --repo GenericJam/mob \
    --title "OTP pre-built runtime $HASH" \
    --notes "Pre-built OTP for Android (aarch64-linux-android) and iOS simulator (aarch64-apple-iossimulator). OTP source commit: $HASH."

# Upload tarballs
gh release upload "otp-$HASH" \
    "/tmp/otp-android-$HASH.tar.gz" \
    "/tmp/otp-ios-sim-$HASH.tar.gz" \
    --repo GenericJam/mob

# Verify
gh release view "otp-$HASH" --repo GenericJam/mob --json assets \
    -q '.assets[] | "\(.name) \(.size)"'
```

To replace a bad asset:
```bash
gh release delete-asset "otp-$HASH" otp-ios-sim-$HASH.tar.gz --repo GenericJam/mob --yes
gh release upload "otp-$HASH" /tmp/otp-ios-sim-$HASH.tar.gz --repo GenericJam/mob
```

---

## Step 5 — Update OtpDownloader

Edit `lib/mob_dev/otp_downloader.ex` — update the hash and ERTS version:

```elixir
@otp_hash    "73ba6e0f"    # ← new hash
```

If the ERTS version changed (e.g. from 16.3 to 16.4), update `build_release.md`
to match.

---

## Troubleshooting

**"No erts-* directory found in $OTP_ROOT"** — tarball extracted incorrectly.
Check that `--strip-components=1` produces `erts-<vsn>/` at the top level:
```bash
tar tzf otp-ios-sim-<hash>.tar.gz | head -5
tar tzf otp-ios-sim-<hash>.tar.gz | sed 's|[^/]*/||' | head -5   # after strip
```

**iOS build fails with missing header** — confirm `erl_nif.h` is in the tarball:
```bash
tar tzf otp-ios-sim-<hash>.tar.gz | grep "\.h$"
```

**Android BEAM crash `{undef, app:start}`** — OTP runtime not on device. Check
that `ensure_android/0` succeeded and `push_otp_release_android` ran.

**Wrong tarball uploaded** — the iOS tarball once accidentally contained a compiled
`.app` bundle instead of OTP. Always verify with:
```bash
tar tzf otp-ios-sim-<hash>.tar.gz | grep "erts-"
```

#!/usr/bin/env bash
# scripts/release/xcompile_ios_device.sh
# Cross-compile OTP for iOS arm64 device. Mirrors Step 3b.0 of build_release.md.
#
# Inputs (env or default):
#   OTP_SRC      — OTP source checkout (default: ~/code/otp)
#   RELEASE_ROOT — install dir to populate (default: /tmp/otp-ios-device)
#
# Output:
#   $RELEASE_ROOT/{bin,erts-<vsn>,lib,releases,...}
#   $OTP_SRC/erts/aarch64-apple-ios/config.h (and other configure output)
#   $OTP_SRC/erts/emulator/{zstd,pcre,ryu}/obj/aarch64-apple-ios/opt/lib*.a
#   $OTP_SRC/lib/asn1/priv/lib/aarch64-apple-ios/asn1rt_nif.a
#
# Source of truth: ~/code/otp/HOWTO/INSTALL-IOS.md (OTP's own iOS recipe).

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${RELEASE_ROOT:=/tmp/otp-ios-device}"

log "OTP_SRC=$OTP_SRC"
log "RELEASE_ROOT=$RELEASE_ROOT"

# Sanity: iPhoneOS SDK must be installed.
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    fail "iPhoneOS SDK not found — install Xcode + run 'xcode-select --install'"
fi

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)/patches"

cd "$OTP_SRC"

# Apply iOS-device patches (idempotent — each checks first).
# Without these, the BEAM/EPMD pull in fork() symbols which iOS device
# sandbox blocks; the app dies during boot. See each patch file for context.
apply_patch() {
    local patch_file="$1" marker="$2" target="$3"
    if [ ! -f "$patch_file" ]; then
        log "WARNING: $patch_file not found — assuming OTP source is already patched"
        return 0
    fi
    if grep -q "$marker" "$target" 2>/dev/null; then
        log "$(basename "$patch_file") already applied"
    else
        log "applying $(basename "$patch_file")..."
        patch -p1 < "$patch_file" || fail "patch application failed — inspect $patch_file manually"
    fi
}

apply_patch "$PATCHES_DIR/0001-ios-device-skip-forker-fork.patch" \
            "mob_dev iOS device patch" \
            erts/emulator/sys/unix/sys_drivers.c

apply_patch "$PATCHES_DIR/0002-ios-device-epmd-no-daemon.patch" \
            "ifndef NO_DAEMON" \
            erts/epmd/src/epmd.c

# iOS doesn't allow shared libraries; emit static libbeam.a instead of .so.
export RELEASE_LIBBEAM=yes

# Configure for the iOS arm64 device target. --without-ssl skips OpenSSL
# (Mob ships an Elixir-side crypto shim for HTTP-only Phoenix on-device).
log "configuring for arm64-apple-ios..."
./otp_build configure \
    --xcomp-conf=./xcomp/erl-xcomp-arm64-ios.conf \
    --without-ssl

# Build everything for the target.
log "building (this takes ~5–10 min)..."
./otp_build boot

# Assemble install tree.
log "installing to $RELEASE_ROOT..."
rm -rf "$RELEASE_ROOT"
make release RELEASE_ROOT="$RELEASE_ROOT"

# Verify the artifacts we'll need downstream actually exist.
log "verifying outputs..."
[ -f "$OTP_SRC/erts/aarch64-apple-ios/config.h" ] \
    || fail "missing $OTP_SRC/erts/aarch64-apple-ios/config.h"
[ -d "$RELEASE_ROOT/erts-$ERTS_VSN" ] \
    || fail "missing $RELEASE_ROOT/erts-$ERTS_VSN — 'make release' didn't produce expected layout"
[ -f "$OTP_SRC/erts/emulator/zstd/obj/aarch64-apple-ios/opt/libzstd.a" ] \
    || fail "missing libzstd.a — boot build incomplete"

log "done. Next: scripts/release/tarball_ios_device.sh"

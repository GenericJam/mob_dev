#!/usr/bin/env bash
# scripts/release/xcompile_ios_device.sh
# Cross-compile OTP for iOS arm64 device. Mirrors Step 3b.0 of build_release.md.
#
# Inputs (env or default):
#   OTP_SRC         — OTP source checkout (default: ~/code/otp)
#   OPENSSL_PREFIX  — pre-built OpenSSL install (default: /tmp/openssl-ios-device)
#   RELEASE_ROOT    — install dir to populate (default: /tmp/otp-ios-device)
#
# Output:
#   $RELEASE_ROOT/{bin,erts-<vsn>,lib,releases,...}
#   $OTP_SRC/erts/aarch64-apple-ios/config.h (and other configure output)
#   $OTP_SRC/erts/emulator/{zstd,pcre,ryu}/obj/aarch64-apple-ios/opt/lib*.a
#   $OTP_SRC/lib/asn1/priv/lib/aarch64-apple-ios/asn1rt_nif.a
#
# Source of truth: ~/code/otp/HOWTO/INSTALL-IOS.md (OTP's own iOS recipe).

set -euo pipefail

# Resolve our own dir before cd'ing — `dirname "$0"` returns a relative path
# and the subshell trick on line 37 would fail after we're already cd'd here.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${OPENSSL_PREFIX:=/tmp/openssl-ios-device}"
: "${RELEASE_ROOT:=/tmp/otp-ios-device}"

log "OTP_SRC=$OTP_SRC"
log "OPENSSL_PREFIX=$OPENSSL_PREFIX"
log "RELEASE_ROOT=$RELEASE_ROOT"

# Sanity: iPhoneOS SDK must be installed.
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    fail "iPhoneOS SDK not found — install Xcode + run 'xcode-select --install'"
fi

[ -d "$OPENSSL_PREFIX" ] || fail "OPENSSL_PREFIX missing at $OPENSSL_PREFIX — run scripts/release/openssl/ios_device.sh first (used later by build_crypto_static_ios_device.sh, not the OTP cross-compile itself)"

PATCHES_DIR="$SCRIPT_DIR/patches"

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

# The marker is the patch's own comment: upstream epmd.c already contains
# `#ifndef NO_DAEMON` (around run_daemon's definition), so checking for
# that skipped the patch and left the call site unguarded.
apply_patch "$PATCHES_DIR/0002-ios-device-epmd-no-daemon.patch" \
            "NO_DAEMON strips run_daemon" \
            erts/epmd/src/epmd.c

# __IOS__-guarded, so it is also applied by xcompile_ios_sim.sh.
apply_patch "$PATCHES_DIR/0003-ios-spawn-linked-in-driver.patch" \
            "mob_dev iOS spawn patch" \
            erts/emulator/beam/io.c

# iOS doesn't allow shared libraries; emit static libbeam.a instead of .so.
export RELEASE_LIBBEAM=yes

# mob's device xcomp conf (DED_LD through the cc driver) over upstream's.
VENDORED_CONF="$SCRIPT_DIR/xcomp/erl-xcomp-arm64-ios.conf"
[ -f "$VENDORED_CONF" ] || fail "missing $VENDORED_CONF"
cp "$VENDORED_CONF" xcomp/erl-xcomp-arm64-ios.conf

# Clean prior arch's config so configure doesn't get confused.
make distclean >/dev/null 2>&1 || true

# `--without-ssl` is intentional: iOS xcomp configs set --enable-static-nifs,
# which static-links the crypto NIF into beam.emu at OTP build time. With
# --with-ssl, beam.emu's link line needs OpenSSL but OTP's build system
# doesn't propagate the --with-ssl prefix to that link, so the build fails
# with undefined references to RAND_seed / OSSL_PROVIDER_load / etc.
#
# Android's pattern works around this by building static crypto.a in a
# separate step (build_crypto_static_android_*.sh) — we do the same on iOS
# via build_crypto_static_ios_device.sh, run after this cross-compile. The
# tarball script then ships crypto.a + libcrypto.a, and the user's app
# links them at app-build time.
log "configuring for arm64-apple-ios..."
./otp_build configure \
    --xcomp-conf=./xcomp/erl-xcomp-arm64-ios.conf \
    --without-ssl

# Build everything for the target.
log "building (this takes ~5–10 min)..."
./otp_build boot

# Same xmerl deps fix as xcompile_ios_sim.sh (bare `yeccpre.hrl` breaks
# `make release`); regenerated here it carries the right include path.
rm -f lib/xmerl/src/deps/deps.mk lib/xmerl/src/xmerl_xsd_re_parse.erl

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

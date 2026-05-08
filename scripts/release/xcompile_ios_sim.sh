#!/usr/bin/env bash
# scripts/release/xcompile_ios_sim.sh
# Cross-compile OTP for iOS arm64 simulator.
#
# Inputs (env or default):
#   OTP_SRC         — OTP source checkout (default: ~/code/otp)
#   OPENSSL_PREFIX  — pre-built OpenSSL install (default: /tmp/openssl-ios-sim)
#   RELEASE_ROOT    — install dir to populate (default: /tmp/otp-ios-sim)
#
# Output:
#   $RELEASE_ROOT/{bin,erts-<vsn>,lib,releases,...}
#   $OTP_SRC/erts/aarch64-apple-iossimulator/config.h (configure output)
#   $OTP_SRC/erts/emulator/{zstd,pcre,ryu}/obj/aarch64-apple-iossimulator/opt/lib*.a
#   $OTP_SRC/lib/asn1/priv/lib/aarch64-apple-iossimulator/asn1rt_nif.a
#
# The simulator is a separate target from the device because it runs on the
# Mac's network stack (so EPMD daemon mode works), allows fork(), and doesn't
# need the iOS-device-specific patches. We still emit static libbeam.a for
# linking parity with the device build.

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${OPENSSL_PREFIX:=/tmp/openssl-ios-sim}"
: "${RELEASE_ROOT:=/tmp/otp-ios-sim}"

log "OTP_SRC=$OTP_SRC"
log "OPENSSL_PREFIX=$OPENSSL_PREFIX"
log "RELEASE_ROOT=$RELEASE_ROOT"

# Sanity: iPhoneSimulator SDK must be installed.
if ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
    fail "iPhoneSimulator SDK not found — install Xcode + run 'xcode-select --install'"
fi

[ -d "$OPENSSL_PREFIX" ] || fail "OPENSSL_PREFIX missing at $OPENSSL_PREFIX — run scripts/release/openssl/ios_sim.sh first (used later by build_crypto_static_ios_sim.sh, not the OTP cross-compile itself)"

cd "$OTP_SRC"

# Match the device build: emit static libbeam.a so the simulator app can link
# the same way (target_link_libraries against an .a, not an .so).
export RELEASE_LIBBEAM=yes

# Clean any prior arch's config so configure doesn't pick up Android/iOS-device leftovers.
make distclean >/dev/null 2>&1 || true

# `--without-ssl` is intentional: iOS xcomp configs set --enable-static-nifs,
# which static-links the crypto NIF into beam.emu at OTP build time. With
# --with-ssl, beam.emu's link line needs OpenSSL but OTP's build system
# doesn't propagate the --with-ssl prefix to that link, so the build fails
# with undefined references to RAND_seed / OSSL_PROVIDER_load / etc.
#
# The Android pattern works around this by building static crypto.a in a
# separate step (build_crypto_static_android_*.sh) — we do the same on iOS
# via build_crypto_static_ios_sim.sh, run after this cross-compile. The
# tarball script then ships crypto.a + libcrypto.a, and the user's app
# links them at app-build time.
log "configuring for arm64-apple-iossimulator..."
./otp_build configure \
    --xcomp-conf=./xcomp/erl-xcomp-arm64-iossimulator.conf \
    --without-ssl

log "building (this takes ~5–10 min)..."
./otp_build boot

log "installing to $RELEASE_ROOT..."
rm -rf "$RELEASE_ROOT"
make release RELEASE_ROOT="$RELEASE_ROOT"

log "verifying outputs..."
[ -f "$OTP_SRC/erts/aarch64-apple-iossimulator/config.h" ] \
    || fail "missing $OTP_SRC/erts/aarch64-apple-iossimulator/config.h"
[ -d "$RELEASE_ROOT/erts-$ERTS_VSN" ] \
    || fail "missing $RELEASE_ROOT/erts-$ERTS_VSN — 'make release' didn't produce expected layout"
[ -f "$OTP_SRC/erts/emulator/zstd/obj/aarch64-apple-iossimulator/opt/libzstd.a" ] \
    || fail "missing libzstd.a — boot build incomplete"

log "done. Next: scripts/release/openssl/build_crypto_static_ios_sim.sh, then scripts/release/tarball_ios_sim.sh"

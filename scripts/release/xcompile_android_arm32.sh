#!/usr/bin/env bash
# scripts/release/xcompile_android_arm32.sh
# Cross-compile OTP for Android arm32 (armv7a-linux-androideabi, API 24+).
#
# Inputs (env or default):
#   OTP_SRC         — OTP source checkout (default: ~/code/otp)
#   OPENSSL_PREFIX  — pre-built OpenSSL install (default: /tmp/openssl-android-arm32)
#   RELEASE_ROOT    — install dir to populate (default: /tmp/otp-android-arm32)
#   NDK_VERSION     — NDK version (sourced from openssl/_lib.sh)
#   ANDROID_NDK_ROOT — NDK root (sourced from openssl/_lib.sh)
#   NDK_ABI_PLAT    — Android API-level prefix (default: android24)
#
# Output:
#   $RELEASE_ROOT/{bin,erts-<vsn>,lib,releases,...}
#   $OTP_SRC/erts/arm-unknown-linux-androideabi/{config.h,...}
#   $OTP_SRC/erts/emulator/{zstd,pcre,ryu}/obj/arm-unknown-linux-androideabi/opt/lib*.a
#
# Mirror of the arm64 sibling under openssl/_build_otp_android_arm64.sh.
# Targets armeabi-v7a for older 32-bit-only devices (e.g. Motorola E 2020).

set -euo pipefail

# Resolve our own dir to an absolute path before cd'ing — `dirname "$0"` is
# relative and would break the openssl/_lib.sh source line below.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

# NDK_VERSION + ANDROID_NDK_ROOT come from this shared file (single source of truth).
. "$SCRIPT_DIR/openssl/_lib.sh"

: "${OPENSSL_PREFIX:=/tmp/openssl-android-arm32}"
: "${RELEASE_ROOT:=/tmp/otp-android-arm32}"
# NDK_ABI_PLAT is interpolated into the xcomp conf's CC line as
# "armv7a-linux-${NDK_ABI_PLAT}-clang". The actual NDK clang for arm32 is
# named "armv7a-linux-androideabi24-clang" — the "eabi" suffix is required.
# arm64 differs (just "aarch64-linux-android24-clang"), which is why the
# arm64 sibling sets NDK_ABI_PLAT=android24.
: "${NDK_ABI_PLAT:=androideabi24}"

log "OTP_SRC=$OTP_SRC"
log "OPENSSL_PREFIX=$OPENSSL_PREFIX"
log "RELEASE_ROOT=$RELEASE_ROOT"
log "ANDROID_NDK_ROOT=$ANDROID_NDK_ROOT"

[ -d "$OPENSSL_PREFIX" ] || fail "OPENSSL_PREFIX missing at $OPENSSL_PREFIX — run scripts/release/openssl/android_arm32.sh first"
[ -d "$ANDROID_NDK_ROOT" ] || fail "ANDROID_NDK_ROOT missing at $ANDROID_NDK_ROOT"

export NDK_ROOT="$ANDROID_NDK_ROOT"
export PATH="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin:$PATH"
export NDK_ABI_PLAT
export RELEASE_LIBBEAM=yes

cd "$OTP_SRC"

# Clean any stale config from a prior arch (iOS, arm64, etc.).
make distclean >/dev/null 2>&1 || true

log "configuring for arm-unknown-linux-androideabi..."
./otp_build configure \
    --xcomp-conf=./xcomp/erl-xcomp-arm-android.conf \
    --with-ssl="$OPENSSL_PREFIX" \
    --disable-dynamic-ssl-lib

# Android xcomp configs do NOT set --enable-static-nifs, so beam.emu's link
# is fine without OpenSSL on the link line — crypto.so loads at runtime
# instead. We still build a separate static crypto.a via
# build_crypto_static_android_arm32.sh after this, since Android loads
# native libs RTLD_LOCAL and dlopen-ing crypto.so from a child .so doesn't
# see the parent's enif_* symbols.

log "building (this takes ~5–10 min)..."
./otp_build boot

log "installing to $RELEASE_ROOT..."
rm -rf "$RELEASE_ROOT"
./otp_build release -a "$RELEASE_ROOT"

log "verifying outputs..."
[ -d "$RELEASE_ROOT/erts-$ERTS_VSN" ] \
    || fail "missing $RELEASE_ROOT/erts-$ERTS_VSN"

ls "$RELEASE_ROOT/lib/" | grep -E '^(crypto|public_key|ssl)-' >/dev/null \
    || fail "crypto/ssl/public_key apps NOT in install tree — --with-ssl wired wrong?"

log "done. Next: scripts/release/openssl/build_crypto_static_android_arm32.sh, then scripts/release/tarball_android_arm32.sh"

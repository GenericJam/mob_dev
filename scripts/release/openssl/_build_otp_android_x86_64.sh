#!/usr/bin/env bash
# Cross-compile OTP for android-x86_64 with --with-ssl pointing at our own
# OpenSSL build. Produces /tmp/otp-android-x86_64 (an OTP install tree).
# Mirrors _build_otp_android_arm64.sh — only the xcomp conf, OpenSSL prefix,
# and release dir differ.
set -euo pipefail

. "$(dirname "$0")/_lib.sh"

: "${OPENSSL_PREFIX:=/tmp/openssl-android-x86_64}"
: "${OTP_SRC:=$HOME/code/otp}"
: "${OTP_RELEASE:=/tmp/otp-android-x86_64}"
: "${NDK_ABI_PLAT:=android24}"

[ -d "$OPENSSL_PREFIX" ] || { echo "missing $OPENSSL_PREFIX" >&2; exit 1; }
[ -d "$ANDROID_NDK_ROOT" ] || { echo "missing $ANDROID_NDK_ROOT" >&2; exit 1; }

export NDK_ROOT="$ANDROID_NDK_ROOT"
export PATH="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin:$PATH"
export NDK_ABI_PLAT
export RELEASE_LIBBEAM=yes

cd "$OTP_SRC"

# Clean any stale config from a prior arch (arm64, iOS, etc.).
make distclean >/dev/null 2>&1 || true

./otp_build configure \
    --xcomp-conf=./xcomp/erl-xcomp-x86_64-android.conf \
    --with-ssl="$OPENSSL_PREFIX" \
    --disable-dynamic-ssl-lib

./otp_build boot

rm -rf "$OTP_RELEASE"
./otp_build release -a "$OTP_RELEASE"

echo
echo "=== OTP Android x86_64 with crypto installed at $OTP_RELEASE ==="
ls "$OTP_RELEASE/lib/" | grep -E '^(crypto|public_key|ssl)-' | head -5 || echo "WARN: crypto/ssl/public_key apps NOT in install tree"

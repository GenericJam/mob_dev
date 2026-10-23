#!/usr/bin/env bash
# Cross-compile OTP for android-arm64 with --with-ssl pointing at our
# own OpenSSL build. Produces /tmp/otp-android (an OTP install tree) plus
# the per-arch static-lib and config.h artifacts under $OTP_SRC.
set -euo pipefail

. "$(dirname "$0")/_lib.sh"

: "${OPENSSL_PREFIX:=/tmp/openssl-android-arm64}"
: "${OTP_SRC:=$HOME/code/otp}"
: "${OTP_RELEASE:=/tmp/otp-android}"
: "${NDK_ABI_PLAT:=android24}"

[ -d "$OPENSSL_PREFIX" ] || { echo "missing $OPENSSL_PREFIX" >&2; exit 1; }
[ -d "$ANDROID_NDK_ROOT" ] || { echo "missing $ANDROID_NDK_ROOT" >&2; exit 1; }

export NDK_ROOT="$ANDROID_NDK_ROOT"
export PATH="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin:$PATH"
export NDK_ABI_PLAT
export RELEASE_LIBBEAM=yes

# Resolved before the cd below: $0 may be relative.
VENDORED_CONF="$(cd "$(dirname "$0")/../xcomp" && pwd)/erl-xcomp-arm64-android.conf"

cd "$OTP_SRC"

# Install mob's arm64 xcomp conf over upstream's stub (llvm-ar, 16 KB pages,
# -Os/gc-sections, trimmed apps) — see the header of
# scripts/release/xcomp/erl-xcomp-arm64-android.conf. Same pattern as the
# x86_64 sibling.
[ -f "$VENDORED_CONF" ] || { echo "missing $VENDORED_CONF" >&2; exit 1; }
cp "$VENDORED_CONF" "$OTP_SRC/xcomp/erl-xcomp-arm64-android.conf"

# Clean any stale config from a prior arch (iOS, etc.).
make distclean >/dev/null 2>&1 || true

./otp_build configure \
    --xcomp-conf=./xcomp/erl-xcomp-arm64-android.conf \
    --with-ssl="$OPENSSL_PREFIX" \
    --disable-dynamic-ssl-lib

./otp_build boot

# Static asn1 NIF for the tarball's erts-*/lib/asn1rt_nif.a (linked into the
# app like crypto.a). `boot` only builds it with --enable-static-nifs, which
# Android doesn't use, so build OTP's own static_lib target directly.
ERL_TOP="$OTP_SRC" make -C lib/asn1/c_src TARGET=aarch64-unknown-linux-android static_lib

# Stage the install tree at /tmp/otp-android.
rm -rf "$OTP_RELEASE"
./otp_build release -a "$OTP_RELEASE"

echo
echo "=== OTP Android arm64 with crypto installed at $OTP_RELEASE ==="
ls "$OTP_RELEASE/lib/" | grep -E '^(crypto|public_key|ssl)-' | head -5 || echo "WARN: crypto/ssl/public_key apps NOT in install tree"
find "$OTP_RELEASE/lib/" -name 'crypto.so' 2>/dev/null | head -3 || echo "WARN: crypto.so NIF not found"

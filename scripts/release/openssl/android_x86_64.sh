#!/usr/bin/env bash
# scripts/release/openssl/android_x86_64.sh
# Cross-compile OpenSSL 3.x for Android x86_64 (x86_64-linux-android, API 24+).
# x86_64 ABI = Android emulators on x86_64 hosts (Intel Macs, most CI runners).
# Output: $PREFIX/lib/libcrypto.a, $PREFIX/lib/libssl.a, $PREFIX/include/openssl/*.h
#
# Mirrors android_arm64.sh — only the Configure target and PREFIX differ.
set -euo pipefail

. "$(dirname "$0")/_lib.sh"

: "${OPENSSL_SRC:=$HOME/code/openssl}"
: "${PREFIX:=/tmp/openssl-android-x86_64}"
: "${ANDROID_API:=24}"

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "ERROR: NDK toolchain not at $TOOLCHAIN" >&2; exit 1; }
[ -d "$OPENSSL_SRC" ] || { echo "ERROR: OPENSSL_SRC not at $OPENSSL_SRC" >&2; exit 1; }

export ANDROID_NDK_ROOT
export PATH="$TOOLCHAIN/bin:$PATH"

cd "$OPENSSL_SRC"
make distclean >/dev/null 2>&1 || true

# Same algorithm-disable list as android_arm64.sh — see that script's comment
# for the per-entry justification.
./Configure android-x86_64 \
    -D__ANDROID_API__="$ANDROID_API" \
    -Os -ffunction-sections -fdata-sections \
    -fPIC \
    --prefix="$PREFIX" \
    --openssldir="$PREFIX/ssl" \
    no-shared no-tests no-apps no-engine \
    no-md2 no-md4 no-mdc2 no-whirlpool no-rmd160 \
    no-rc2 no-rc4 no-idea no-cast no-bf no-blake2 \
    no-seed no-aria no-camellia no-gost \
    no-weak-ssl-ciphers no-ssl3 no-tls1 no-tls1_1 \
    no-srp no-psk no-nextprotoneg

make -j8
make install_sw

echo
echo "OpenSSL Android x86_64 installed at: $PREFIX"
echo "  $(ls -la "$PREFIX/lib/libcrypto.a")"
echo "  arch check: $(file "$PREFIX/lib/libcrypto.a" | head -1)"

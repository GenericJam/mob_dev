#!/usr/bin/env bash
# scripts/release/openssl/android_arm32.sh
# Cross-compile OpenSSL 3.x for Android arm32 (armv7a-linux-androideabi, API 24+).
# Output: $PREFIX/lib/libcrypto.a, $PREFIX/lib/libssl.a, $PREFIX/include/openssl/*.h
#
# Inputs (env):
#   OPENSSL_SRC      — OpenSSL source checkout (default: ~/code/openssl)
#   NDK_VERSION      — NDK version (sourced from _lib.sh; matches MobDev.NdkVersion)
#   ANDROID_NDK_ROOT — NDK root (default: ~/Library/Android/sdk/ndk/$NDK_VERSION)
#   PREFIX           — install dir (default: /tmp/openssl-android-arm32)
#   ANDROID_API      — minimum Android API (default: 24)
set -euo pipefail

. "$(dirname "$0")/_lib.sh"

: "${OPENSSL_SRC:=$HOME/code/openssl}"
: "${PREFIX:=/tmp/openssl-android-arm32}"
: "${ANDROID_API:=24}"

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "ERROR: NDK toolchain not at $TOOLCHAIN" >&2; exit 1; }
[ -d "$OPENSSL_SRC" ] || { echo "ERROR: OPENSSL_SRC not at $OPENSSL_SRC" >&2; exit 1; }

export ANDROID_NDK_ROOT
export PATH="$TOOLCHAIN/bin:$PATH"

cd "$OPENSSL_SRC"
make distclean >/dev/null 2>&1 || true

## See android_arm64.sh for size-flag rationale. arm32 also needs
## no-asm because OpenSSL's hand-written ARM assembly emits non-PIC
## absolute relocations against OPENSSL_armcap_P (ld.lld rejects
## these when libcrypto.a is linked into a .so).
## See android_arm64.sh for the no-X rationale per algorithm.
## arm32 needs no-asm too — non-PIC absolute relocations against
## OPENSSL_armcap_P in the hand-written ARM assembly.
./Configure android-arm \
    -D__ANDROID_API__="$ANDROID_API" \
    -Os -ffunction-sections -fdata-sections \
    -fPIC \
    --prefix="$PREFIX" \
    --openssldir="$PREFIX/ssl" \
    no-shared no-tests no-apps no-engine no-asm \
    no-md2 no-md4 no-mdc2 no-whirlpool no-rmd160 \
    no-rc2 no-rc4 no-idea no-cast no-bf no-blake2 \
    no-seed no-aria no-camellia no-gost \
    no-weak-ssl-ciphers no-ssl3 no-tls1 no-tls1_1 \
    no-srp no-psk no-nextprotoneg

make -j8
make install_sw

echo
echo "OpenSSL Android arm32 installed at: $PREFIX"
echo "  $(ls -la "$PREFIX/lib/libcrypto.a")"
echo "  arch check: $(file "$PREFIX/lib/libcrypto.a" | head -1)"

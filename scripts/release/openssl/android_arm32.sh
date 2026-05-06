#!/usr/bin/env bash
# scripts/release/openssl/android_arm32.sh
# Cross-compile OpenSSL 3.x for Android arm32 (armv7a-linux-androideabi, API 24+).
# Output: $PREFIX/lib/libcrypto.a, $PREFIX/lib/libssl.a, $PREFIX/include/openssl/*.h
#
# Inputs (env):
#   OPENSSL_SRC  — OpenSSL source checkout (default: ~/code/openssl)
#   ANDROID_NDK_ROOT — NDK root (default: ~/Library/Android/sdk/ndk/27.2.12479018)
#   PREFIX       — install dir (default: /tmp/openssl-android-arm32)
#   ANDROID_API  — minimum Android API (default: 24)
set -euo pipefail

: "${OPENSSL_SRC:=$HOME/code/openssl}"
: "${ANDROID_NDK_ROOT:=$HOME/Library/Android/sdk/ndk/27.2.12479018}"
: "${PREFIX:=/tmp/openssl-android-arm32}"
: "${ANDROID_API:=24}"

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "ERROR: NDK toolchain not at $TOOLCHAIN" >&2; exit 1; }
[ -d "$OPENSSL_SRC" ] || { echo "ERROR: OPENSSL_SRC not at $OPENSSL_SRC" >&2; exit 1; }

export ANDROID_NDK_ROOT
export PATH="$TOOLCHAIN/bin:$PATH"

cd "$OPENSSL_SRC"
make distclean >/dev/null 2>&1 || true

./Configure android-arm \
    -D__ANDROID_API__="$ANDROID_API" \
    -fPIC \
    --prefix="$PREFIX" \
    --openssldir="$PREFIX/ssl" \
    no-shared \
    no-tests \
    no-apps \
    no-engine \
    no-asm     # OpenSSL's hand-written ARM assembly uses non-PIC
                # absolute relocations against OPENSSL_armcap_P that
                # ld.lld rejects when the .a is linked into a .so.
                # Slower than the asm path but correct. C fallback
                # implementations are still hardware-AES-aware.

make -j8
make install_sw

echo
echo "OpenSSL Android arm32 installed at: $PREFIX"
echo "  $(ls -la "$PREFIX/lib/libcrypto.a")"
echo "  arch check: $(file "$PREFIX/lib/libcrypto.a" | head -1)"

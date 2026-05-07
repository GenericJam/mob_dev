#!/usr/bin/env bash
# scripts/release/openssl/android_arm64.sh
# Cross-compile OpenSSL 3.x for Android arm64 (aarch64-linux-android, API 24+).
# Output: $PREFIX/lib/libcrypto.a, $PREFIX/lib/libssl.a, $PREFIX/include/openssl/*.h
#
# Inputs (env):
#   OPENSSL_SRC  — OpenSSL source checkout (default: ~/code/openssl)
#   ANDROID_NDK_ROOT — NDK root (default: ~/Library/Android/sdk/ndk/27.2.12479018)
#   PREFIX       — install dir (default: /tmp/openssl-android-arm64)
#   ANDROID_API  — minimum Android API (default: 24)
set -euo pipefail

: "${OPENSSL_SRC:=$HOME/code/openssl}"
: "${ANDROID_NDK_ROOT:=$HOME/Library/Android/sdk/ndk/27.2.12479018}"
: "${PREFIX:=/tmp/openssl-android-arm64}"
: "${ANDROID_API:=24}"

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "ERROR: NDK toolchain not at $TOOLCHAIN" >&2; exit 1; }
[ -d "$OPENSSL_SRC" ] || { echo "ERROR: OPENSSL_SRC not at $OPENSSL_SRC" >&2; exit 1; }

export ANDROID_NDK_ROOT
export PATH="$TOOLCHAIN/bin:$PATH"

cd "$OPENSSL_SRC"

# Clean any previous arch's config so Configure doesn't get confused.
make distclean >/dev/null 2>&1 || true

## Size flags: -Os over default -O3, plus per-function/data sections so
## the linker can dead-strip unused crypto code from the final libpigeon.so
## via -Wl,--gc-sections (set on the consuming link, not here). Per
## GRiSP nano (2025-06-11): single biggest C-side shrink technique.
## -fPIC explicit (NDK toolchain default but belt-and-suspenders).
./Configure android-arm64 \
    -D__ANDROID_API__="$ANDROID_API" \
    -Os -ffunction-sections -fdata-sections \
    -fPIC \
    --prefix="$PREFIX" \
    --openssldir="$PREFIX/ssl" \
    no-shared \
    no-tests \
    no-apps \
    no-engine

make -j8
make install_sw

echo
echo "OpenSSL Android arm64 installed at: $PREFIX"
echo "  $(ls -la "$PREFIX/lib/libcrypto.a")"
echo "  $(ls -la "$PREFIX/lib/libssl.a")"
echo "  arch check: $(file "$PREFIX/lib/libcrypto.a" | head -1)"

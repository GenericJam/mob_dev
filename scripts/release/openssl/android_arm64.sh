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
##
## Pass 4 (2026-05-06): disable the legacy / rarely-used algorithms
## that no Mob app should exercise. This is an additive list — every
## entry has a justification. If an app actually needs one, drop it
## from the list and rebuild.
##
##   md2/md4/mdc2/whirlpool/ripemd160 — superseded by SHA-2 / BLAKE2.
##                                     No modern code uses them.
##   rc2/rc4/idea/cast/bf/blake2/seed/aria/camellia — legacy ciphers.
##                                     AES-GCM and ChaCha20-Poly1305
##                                     cover real cryptography.
##   gost — Russian-only standards.
##   weak-ssl-ciphers — RC4, single-DES, NULL, EXPORT.
##   ssl3, tls1, tls1_1 — pre-TLS-1.2. Refused by every modern server.
##   srp — pre-shared password protocol. Niche.
##   psk — pre-shared key TLS variant. Niche.
##   nextprotoneg — superseded by ALPN.
./Configure android-arm64 \
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
echo "OpenSSL Android arm64 installed at: $PREFIX"
echo "  $(ls -la "$PREFIX/lib/libcrypto.a")"
echo "  $(ls -la "$PREFIX/lib/libssl.a")"
echo "  arch check: $(file "$PREFIX/lib/libcrypto.a" | head -1)"

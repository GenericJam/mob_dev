#!/usr/bin/env bash
# scripts/release/openssl/build_crypto_static_ios_sim.sh
#
# iOS arm64 simulator counterpart to build_crypto_static_android_*.sh.
# Recompile OTP's crypto NIF C sources with -DSTATIC_ERLANG_NIF and archive
# them as crypto.a. The user's app's build.sh links this .a + libcrypto.a
# (real OpenSSL) into the app's main native binary so the static
# `crypto_nif_init` symbol resolves without dlopen.
#
# iOS reasoning differs from Android:
#   - Android needs static linking because RTLD_LOCAL hides parent symbols
#     from dlopen'd children, breaking dynamic crypto.so on-device.
#   - iOS needs static linking because the platform forbids loading
#     unsigned dylib/dlopen — every NIF must be present in the final
#     signed binary.
# Both ship the same artifact: erts-<vsn>/lib/crypto.a in the OTP tarball.
#
# Inputs (env):
#   OTP_SRC          — OTP source checkout (default: ~/code/otp)
#   OPENSSL_PREFIX   — pre-built OpenSSL install (default: /tmp/openssl-ios-sim)
#
# Output:
#   $OTP_SRC/lib/crypto/priv/lib/aarch64-apple-iossimulator/crypto.a
#
# tarball_ios_sim.sh picks this up and places it at
# erts-<vsn>/lib/crypto.a in the published tarball.
set -euo pipefail

: "${OTP_SRC:=$HOME/code/otp}"
: "${OPENSSL_PREFIX:=/tmp/openssl-ios-sim}"

[ -d "$OTP_SRC" ]        || { echo "ERROR: OTP_SRC not at $OTP_SRC" >&2; exit 1; }
[ -d "$OPENSSL_PREFIX" ] || { echo "ERROR: $OPENSSL_PREFIX missing — run scripts/release/openssl/ios_sim.sh first" >&2; exit 1; }

CC="xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0"
AR="xcrun -sdk iphonesimulator ar"
RANLIB="xcrun -sdk iphonesimulator ranlib"

CRYPTO_SRC="$OTP_SRC/lib/crypto/c_src"
ARCH=aarch64-apple-iossimulator
OBJ_DIR="$OTP_SRC/lib/crypto/priv/obj/${ARCH}_static_nif"
LIB_DIR="$OTP_SRC/lib/crypto/priv/lib/$ARCH"
mkdir -p "$OBJ_DIR" "$LIB_DIR"

# Mirror the size + safety flags from the Android script. -fPIC is required
# even for static archives that get linked into a position-independent
# executable (every iOS app binary is PIE).
CFLAGS=(
    -fno-strict-aliasing -fno-delete-null-pointer-checks
    -fno-strict-overflow -fexceptions
    -fstack-protector-strong
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3
    -fno-common -g -Os -ffunction-sections -fdata-sections -fPIC
    -DHAVE_OPENSSL_CRYPTO_MEMCMP
    -DSTATIC_ERLANG_NIF
    -DDISABLE_EVP_DH=0 -DDISABLE_EVP_HMAC=0
    -I"$OPENSSL_PREFIX/include"
    -I"$OTP_SRC/erts/emulator/beam"
    -I"$OTP_SRC/erts/include"
    -I"$OTP_SRC/erts/include/$ARCH"
    -I"$OTP_SRC/erts/include/internal"
    -I"$OTP_SRC/erts/include/internal/$ARCH"
    -I"$OTP_SRC/erts/emulator/sys/unix"
    -I"$OTP_SRC/erts/emulator/sys/common"
    -Wno-deprecated-declarations
)

SOURCES=(
    aead.c aes.c algorithms.c api_ng.c atoms.c bn.c cipher.c cmac.c
    common.c crypto.c crypto_callback.c dh.c digest.c dss.c ec.c ecdh.c
    eddsa.c engine.c evp.c fips.c hash.c hash_equals.c hmac.c info.c
    mac.c math.c pbkdf2_hmac.c pkey.c rand.c rsa.c srp.c
)

echo "=== Compiling crypto NIF sources for iOS sim arm64 with -DSTATIC_ERLANG_NIF ==="
OBJECTS=()
for src in "${SOURCES[@]}"; do
    obj="$OBJ_DIR/${src%.c}.o"
    OBJECTS+=("$obj")
    $CC "${CFLAGS[@]}" -c -o "$obj" "$CRYPTO_SRC/$src"
done

echo "=== Archiving crypto.a ==="
rm -f "$LIB_DIR/crypto.a"
$AR rcs "$LIB_DIR/crypto.a" "${OBJECTS[@]}"
$RANLIB "$LIB_DIR/crypto.a"

echo
echo "Done: $LIB_DIR/crypto.a"
ls -la "$LIB_DIR/crypto.a"
echo
echo "Verify static init symbol:"
xcrun -sdk iphonesimulator nm "$LIB_DIR/crypto.a" 2>/dev/null | grep -E ' T _crypto_nif_init$' | head -3

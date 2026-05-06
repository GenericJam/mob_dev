#!/usr/bin/env bash
# scripts/release/openssl/build_crypto_static_android_arm32.sh
#
# arm32 version of build_crypto_static_android_arm64.sh.
# See header of that file for the why.
set -euo pipefail

: "${OTP_SRC:=$HOME/code/otp}"
: "${OPENSSL_PREFIX:=/tmp/openssl-android-arm32}"
: "${ANDROID_NDK_ROOT:=$HOME/Library/Android/sdk/ndk/27.2.12479018}"
: "${ANDROID_API:=24}"

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
CC="$TOOLCHAIN/bin/armv7a-linux-androideabi${ANDROID_API}-clang"
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"

[ -x "$CC" ]     || { echo "ERROR: $CC not found" >&2; exit 1; }
[ -d "$OPENSSL_PREFIX" ] || { echo "ERROR: $OPENSSL_PREFIX missing" >&2; exit 1; }

CRYPTO_SRC="$OTP_SRC/lib/crypto/c_src"
ARCH=arm-unknown-linux-androideabi
OBJ_DIR="$OTP_SRC/lib/crypto/priv/obj/${ARCH}_static_nif"
LIB_DIR="$OTP_SRC/lib/crypto/priv/lib/$ARCH"
mkdir -p "$OBJ_DIR" "$LIB_DIR"

CFLAGS=(
    -march=armv7-a -mfloat-abi=softfp -mthumb
    -fstrict-flex-arrays=3 -fno-strict-aliasing -fno-delete-null-pointer-checks
    -fno-strict-overflow -fexceptions
    -fstack-protector-strong -fstack-clash-protection
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3
    -fno-common -g -O2 -D_GNU_SOURCE -fPIC
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

echo "=== Compiling crypto NIF sources for arm32 with -DSTATIC_ERLANG_NIF -fPIC ==="
OBJECTS=()
for src in "${SOURCES[@]}"; do
    obj="$OBJ_DIR/${src%.c}.o"
    OBJECTS+=("$obj")
    "$CC" "${CFLAGS[@]}" -c -o "$obj" "$CRYPTO_SRC/$src"
done

echo "=== Archiving crypto.a ==="
rm -f "$LIB_DIR/crypto.a"
"$AR" rcs "$LIB_DIR/crypto.a" "${OBJECTS[@]}"
"$RANLIB" "$LIB_DIR/crypto.a"

echo
echo "Done: $LIB_DIR/crypto.a"
ls -la "$LIB_DIR/crypto.a"
"$TOOLCHAIN/bin/llvm-nm" "$LIB_DIR/crypto.a" | grep -E ' T crypto_nif_init$' | head -3

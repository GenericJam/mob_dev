#!/usr/bin/env bash
# scripts/release/openssl/build_crypto_static_android_x86_64.sh
#
# Recompile OTP's crypto NIF C sources with -DSTATIC_ERLANG_NIF for
# Android arm64 and archive them as crypto.a. This .a (plus the
# real libcrypto.a from OpenSSL) is what gets static-linked into the
# app's libpigeon.so. The crypto module's `erlang:load_nif("crypto", ...)`
# then resolves the static `crypto_nif_init` symbol instead of dlopen'ing
# crypto.so — required because Android loads native libs RTLD_LOCAL by
# default, hiding the parent's enif_* symbols from dlopen'd children.
#
# Inputs (env):
#   OTP_SRC          — OTP source checkout (default: ~/code/otp)
#   OPENSSL_PREFIX   — pre-built OpenSSL install (default: /tmp/openssl-android-x86_64)
#   NDK_VERSION      — NDK version (sourced from _lib.sh; matches MobDev.NdkVersion)
#   ANDROID_NDK_ROOT — NDK root (default: ~/Library/Android/sdk/ndk/$NDK_VERSION)
#   ANDROID_API      — minimum Android API (default: 24)
#
# Output:
#   $OTP_SRC/lib/crypto/priv/lib/x86_64-pc-linux-android/crypto.a
#
# The release tarball script (tarball_android_x86_64.sh) picks this up and
# places it next to libbeam.a etc. so the user's CMakeLists can
# target_link_libraries it via ${OTP_DIR}/${ERTS_VSN}/lib/crypto.a.
set -euo pipefail

. "$(dirname "$0")/_lib.sh"

: "${OTP_SRC:=$HOME/code/otp}"
: "${OPENSSL_PREFIX:=/tmp/openssl-android-x86_64}"
: "${ANDROID_API:=24}"

TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
CC="$TOOLCHAIN/bin/x86_64-linux-android${ANDROID_API}-clang"
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"

[ -x "$CC" ]     || { echo "ERROR: $CC not found" >&2; exit 1; }
[ -d "$OPENSSL_PREFIX" ] || { echo "ERROR: $OPENSSL_PREFIX missing" >&2; exit 1; }

CRYPTO_SRC="$OTP_SRC/lib/crypto/c_src"
ARCH=x86_64-pc-linux-android
OBJ_DIR="$OTP_SRC/lib/crypto/priv/obj/${ARCH}_static_nif"
LIB_DIR="$OTP_SRC/lib/crypto/priv/lib/$ARCH"
mkdir -p "$OBJ_DIR" "$LIB_DIR"

# Match the regular crypto build's CFLAGS, but add -DSTATIC_ERLANG_NIF so
# ERL_NIF_INIT(crypto,...) emits `crypto_nif_init` (the static symbol the
# BEAM dlsym(RTLD_DEFAULT)s when load_nif is called for module crypto).
CFLAGS=(
    -fstrict-flex-arrays=3 -fno-strict-aliasing -fno-delete-null-pointer-checks
    -fno-strict-overflow -fexceptions
    -fstack-protector-strong -fstack-clash-protection
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3
    -fno-common -g -Os -ffunction-sections -fdata-sections -D_GNU_SOURCE -fPIC
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

# All crypto NIF sources EXCEPT otp_test_engine.c (test fixture, not
# wanted in production).
SOURCES=(
    aead.c aes.c algorithms.c api_ng.c atoms.c bn.c cipher.c cmac.c
    common.c crypto.c crypto_callback.c dh.c digest.c dss.c ec.c ecdh.c
    eddsa.c engine.c evp.c fips.c hash.c hash_equals.c hmac.c info.c
    mac.c math.c pbkdf2_hmac.c pkey.c rand.c rsa.c srp.c
)

echo "=== Compiling crypto NIF sources with -DSTATIC_ERLANG_NIF ==="
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
echo
echo "Verify static init symbol:"
"$TOOLCHAIN/bin/llvm-nm" "$LIB_DIR/crypto.a" | grep -E ' T crypto_nif_init$' | head -3

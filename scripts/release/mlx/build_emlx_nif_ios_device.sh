#!/usr/bin/env bash
# scripts/release/mlx/build_emlx_nif_ios_device.sh
#
# Cross-compile EMLX's NIF (deps/emlx/c_src/emlx_nif.cpp) for iOS arm64
# device and archive into libemlx.a. Mirrors the
# openssl/build_crypto_static_ios_device.sh pattern.
#
# The output libemlx.a holds a single object with a public
# `emlx_nif_nif_init` symbol — matches what MobDev.StaticNifs registers
# when :emlx_nif is in the static_nifs list, so `:erlang.load_nif/2` at
# app boot finds the init function via erts_static_nif_tab.
#
# Inputs (env):
#   MLX_PREFIX   — output dir from ios_device.sh (default: /tmp/mlx-ios-device-<ver>)
#   EMLX_SRC     — EMLX checkout with c_src/ and deps (default: ~/code/test_emlx/deps/emlx)
#   OTP_IOS_DIR  — cached iOS-device OTP runtime (default: first match of ~/.mob/cache/otp-ios-device-*)
#
# Output:
#   $MLX_PREFIX/lib/libemlx.a

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${MLX_PREFIX:=/tmp/mlx-ios-device-${MLX_VERSION}}"
: "${IOS_DEPLOYMENT_TARGET:=17.0}"

[ -f "$MLX_PREFIX/lib/libmlx.a" ] || fail "libmlx.a not found at $MLX_PREFIX/lib/ — run ios_device.sh first"

require_emlx_src

if [ -z "${OTP_IOS_DIR:-}" ]; then
    OTP_IOS_DIR=$(otp_ios_device_dir)
fi
[ -d "$OTP_IOS_DIR" ] || fail "OTP iOS device dir not found at $OTP_IOS_DIR"

ERTS_VSN=$(basename "$(ls -d "$OTP_IOS_DIR"/erts-* | head -1)")
log "MLX_PREFIX=$MLX_PREFIX"
log "EMLX_SRC=$EMLX_SRC"
log "OTP_IOS_DIR=$OTP_IOS_DIR ($ERTS_VSN)"

OUT_OBJ_DIR=$(mktemp -d -t emlx-nif-ios-device-XXXXXX)
trap 'rm -rf "$OUT_OBJ_DIR"' EXIT

CC="xcrun -sdk iphoneos clang++ -arch arm64 -miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
AR="xcrun -sdk iphoneos ar"
RANLIB="xcrun -sdk iphoneos ranlib"

CFLAGS=(
    -std=c++17 -O3 -fPIC
    -fno-strict-aliasing
    # STATIC_ERLANG_NIF makes ERL_NIF_INIT define a get_init_func() that
    # the static driver_tab can call instead of relying on dlopen.
    -DSTATIC_ERLANG_NIF
    -DSTATIC_ERLANG_NIF_LIBNAME=emlx_nif
    -I "$OTP_IOS_DIR/$ERTS_VSN/include"
    -I "$MLX_PREFIX/include"
    -Wno-macro-redefined  # erl_nif.h re-defines STATIC_ERLANG_NIF, benign
)

# nlohmann/json headers came in via FetchContent at MLX configure time and are
# staged under $MLX_PREFIX/include/_deps/json/. EMLX transitively #includes
# them via "mlx/backend/common/utils.h".
if [ -d "$MLX_PREFIX/include/_deps/json" ]; then
    CFLAGS+=( -I "$MLX_PREFIX/include/_deps/json" )
fi

log "compiling emlx_nif.cpp for iOS arm64..."
$CC "${CFLAGS[@]}" -c "$EMLX_SRC/c_src/emlx_nif.cpp" -o "$OUT_OBJ_DIR/emlx_nif.o"

log "archiving libemlx.a..."
rm -f "$MLX_PREFIX/lib/libemlx.a"
$AR rcs "$MLX_PREFIX/lib/libemlx.a" "$OUT_OBJ_DIR/emlx_nif.o"
$RANLIB "$MLX_PREFIX/lib/libemlx.a"

# Sanity check: confirm iOS-platform tag (2) and presence of the init symbol.
OTOOL_OUT=$(otool -l "$MLX_PREFIX/lib/libemlx.a" 2>/dev/null || true)
if [[ "$OTOOL_OUT" =~ platform[[:space:]]+([0-9]+) ]]; then
    PLATFORM="${BASH_REMATCH[1]}"
else
    PLATFORM="unknown"
fi
[ "$PLATFORM" = "2" ] || fail "libemlx.a tagged platform=$PLATFORM, expected 2 (iOS device)"

NM_OUT=$(xcrun -sdk iphoneos nm "$MLX_PREFIX/lib/libemlx.a" 2>/dev/null || true)
[[ "$NM_OUT" == *" T _emlx_nif_nif_init"* ]] || \
    fail "libemlx.a missing emlx_nif_nif_init symbol — STATIC_ERLANG_NIF not applied?"

log "done — libemlx.a installed at $MLX_PREFIX/lib/libemlx.a"
ls -lh "$MLX_PREFIX/lib/libemlx.a"

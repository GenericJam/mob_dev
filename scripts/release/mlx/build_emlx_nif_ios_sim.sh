#!/usr/bin/env bash
# scripts/release/mlx/build_emlx_nif_ios_sim.sh
#
# iOS Simulator (arm64) counterpart to build_emlx_nif_ios_device.sh.
# See that file's header for rationale; this differs only in SDK and the
# OS-version-min flag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${MLX_PREFIX:=/tmp/mlx-ios-sim-${MLX_VERSION}}"
: "${IOS_DEPLOYMENT_TARGET:=17.0}"

[ -f "$MLX_PREFIX/lib/libmlx.a" ] || fail "libmlx.a not found at $MLX_PREFIX/lib/ — run ios_sim.sh first"

require_emlx_src

if [ -z "${OTP_IOS_DIR:-}" ]; then
    OTP_IOS_DIR=$(otp_ios_sim_dir)
fi
[ -d "$OTP_IOS_DIR" ] || fail "OTP iOS sim dir not found at $OTP_IOS_DIR"

ERTS_VSN=$(basename "$(ls -d "$OTP_IOS_DIR"/erts-* | head -1)")
log "MLX_PREFIX=$MLX_PREFIX"
log "EMLX_SRC=$EMLX_SRC"
log "OTP_IOS_DIR=$OTP_IOS_DIR ($ERTS_VSN)"

OUT_OBJ_DIR=$(mktemp -d -t emlx-nif-ios-sim-XXXXXX)
trap 'rm -rf "$OUT_OBJ_DIR"' EXIT

CC="xcrun -sdk iphonesimulator clang++ -arch arm64 -mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
AR="xcrun -sdk iphonesimulator ar"
RANLIB="xcrun -sdk iphonesimulator ranlib"

CFLAGS=(
    -std=c++17 -O3 -fPIC
    -fno-strict-aliasing
    -DSTATIC_ERLANG_NIF
    -DSTATIC_ERLANG_NIF_LIBNAME=emlx_nif
    -I "$OTP_IOS_DIR/$ERTS_VSN/include"
    -I "$MLX_PREFIX/include"
    -Wno-macro-redefined
)

if [ -d "$MLX_PREFIX/include/_deps/json" ]; then
    CFLAGS+=( -I "$MLX_PREFIX/include/_deps/json" )
fi

log "compiling emlx_nif.cpp for iOS-simulator arm64..."
$CC "${CFLAGS[@]}" -c "$EMLX_SRC/c_src/emlx_nif.cpp" -o "$OUT_OBJ_DIR/emlx_nif.o"

log "archiving libemlx.a..."
rm -f "$MLX_PREFIX/lib/libemlx.a"
$AR rcs "$MLX_PREFIX/lib/libemlx.a" "$OUT_OBJ_DIR/emlx_nif.o"
$RANLIB "$MLX_PREFIX/lib/libemlx.a"

# Sanity check: confirm iOS-Simulator platform tag (7) and the init symbol.
OTOOL_OUT=$(otool -l "$MLX_PREFIX/lib/libemlx.a" 2>/dev/null || true)
if [[ "$OTOOL_OUT" =~ platform[[:space:]]+([0-9]+) ]]; then
    PLATFORM="${BASH_REMATCH[1]}"
else
    PLATFORM="unknown"
fi
[ "$PLATFORM" = "7" ] || fail "libemlx.a tagged platform=$PLATFORM, expected 7 (iOS Simulator)"

NM_OUT=$(xcrun -sdk iphonesimulator nm "$MLX_PREFIX/lib/libemlx.a" 2>/dev/null || true)
[[ "$NM_OUT" == *" T _emlx_nif_nif_init"* ]] || \
    fail "libemlx.a missing emlx_nif_nif_init symbol — STATIC_ERLANG_NIF not applied?"

log "done — libemlx.a installed at $MLX_PREFIX/lib/libemlx.a"
ls -lh "$MLX_PREFIX/lib/libemlx.a"

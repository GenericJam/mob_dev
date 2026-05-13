#!/usr/bin/env bash
# scripts/release/mlx/ios_sim.sh
#
# Cross-compile MLX for iOS Simulator arm64 (Apple Silicon Macs).
# Mirrors ios_device.sh — differs only in SDK and the deployment-target
# flag the iOS sim toolchain expects.
#
# CPU-only for v1; see ios_device.sh for the Metal rationale.
#
# Inputs (env):
#   MLX_VERSION             — MLX tag to fetch (default: 0.25.1)
#   MLX_SRC                 — MLX source checkout (default: shared with ios_device.sh)
#   IOS_DEPLOYMENT_TARGET   — iOS min version (default: 17.0)
#   PREFIX                  — install root (default: /tmp/mlx-ios-sim-<ver>)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${PREFIX:=/tmp/mlx-ios-sim-${MLX_VERSION}}"

xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || \
    fail "iPhoneSimulator SDK not found — install Xcode"

ensure_mlx_src

BUILD_DIR="$MLX_SRC/build-ios-sim-${MLX_VERSION}"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ -f "$BUILD_DIR/libmlx.a" ] && [ -z "${MLX_FORCE_REBUILD:-}" ]; then
    log "libmlx.a already built at $BUILD_DIR — skipping configure+make (set MLX_FORCE_REBUILD=1 to force)"
else

log "configuring MLX for arm64-apple-ios-simulator..."
# Differences from device:
#   * sysroot = iphonesimulator (Mach-O platform tag = 7, iOSSimulator)
#   * deployment target uses -mios-simulator-version-min when CMake threads it
#     through; CMake-iOS handles that internally when sysroot is set
cmake -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DMLX_BUILD_METAL=OFF \
    -DMLX_BUILD_TESTS=OFF \
    -DMLX_BUILD_BENCHMARKS=OFF \
    -DMLX_BUILD_EXAMPLES=OFF \
    -DMLX_BUILD_PYTHON_BINDINGS=OFF \
    "$MLX_SRC"

log "building libmlx.a (this takes ~3-5 min)..."
make mlx -j"$(sysctl -n hw.ncpu)"

fi  # end of MLX_FORCE_REBUILD guard

# Sanity check: confirm iOS-Simulator platform tag (7), not macOS (1).
# See ios_device.sh for the bash-regex-not-pipeline rationale.
OTOOL_OUT=$(otool -l "$BUILD_DIR/libmlx.a" 2>/dev/null || true)
if [[ "$OTOOL_OUT" =~ platform[[:space:]]+([0-9]+) ]]; then
    PLATFORM="${BASH_REMATCH[1]}"
else
    PLATFORM="unknown"
fi
[ "$PLATFORM" = "7" ] || fail "libmlx.a tagged platform=$PLATFORM, expected 7 (iOS Simulator)"

log "installing to $PREFIX..."
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$PREFIX/include"

cp "$BUILD_DIR/libmlx.a" "$PREFIX/lib/"

mkdir -p "$PREFIX/include/mlx"
rsync -a --include='*.h' --include='*/' --exclude='*' \
    "$MLX_SRC/mlx/" "$PREFIX/include/mlx/"

if [ -d "$BUILD_DIR/_deps/json-src/include" ]; then
    mkdir -p "$PREFIX/include/_deps/json"
    rsync -a "$BUILD_DIR/_deps/json-src/include/" "$PREFIX/include/_deps/json/"
fi

cat > "$PREFIX/VERSION" <<EOF
mlx_version=${MLX_VERSION}
variant=ios-sim-cpu
ios_deployment_target=${IOS_DEPLOYMENT_TARGET}
metal_enabled=false
EOF

log "done — libmlx.a installed at $PREFIX/lib/libmlx.a"
ls -lh "$PREFIX/lib/libmlx.a"
file "$PREFIX/lib/libmlx.a" | head -1

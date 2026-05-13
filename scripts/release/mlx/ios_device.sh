#!/usr/bin/env bash
# scripts/release/mlx/ios_device.sh
#
# Cross-compile MLX (Apple's ML compute library) as a static archive for
# iOS arm64 device. CPU-only — Metal is a follow-up that requires the
# optional Xcode "Metal Toolchain" component plus the CMakeLists.txt
# patches in patches/ (not applied here).
#
# Mirrors scripts/release/openssl/ios_device.sh (the closest analogue —
# third-party native lib cross-compiled to a `.a` for static linking into
# a Mob iOS app).
#
# Inputs (env):
#   MLX_VERSION             — MLX tag to fetch (default: 0.25.1, matches EMLX 0.2.0)
#   MLX_SRC                 — MLX source checkout (default: ~/.cache/mob-mlx-build/mlx-<ver>)
#   IOS_DEPLOYMENT_TARGET   — iOS min version (default: 17.0)
#   PREFIX                  — install root (default: /tmp/mlx-ios-device-<ver>)
#
# Output:
#   $PREFIX/lib/libmlx.a            (static archive, ~25 MB)
#   $PREFIX/include/mlx/*.h         (public headers for downstream NIF compiles)
#   $PREFIX/include/_deps/json/...  (mlx pulls these in via FetchContent;
#                                    bundled so the NIF compile can resolve
#                                    them without re-running cmake)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${PREFIX:=/tmp/mlx-ios-device-${MLX_VERSION}}"

# Sanity: iPhoneOS SDK must be installed.
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || \
    fail "iPhoneOS SDK not found — install Xcode + run 'xcode-select --install'"

ensure_mlx_src

BUILD_DIR="$MLX_SRC/build-ios-device-${MLX_VERSION}"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ -f "$BUILD_DIR/libmlx.a" ] && [ -z "${MLX_FORCE_REBUILD:-}" ]; then
    log "libmlx.a already built at $BUILD_DIR — skipping configure+make (set MLX_FORCE_REBUILD=1 to force)"
else

log "configuring MLX for arm64-apple-ios..."
# MLX_BUILD_METAL=OFF is the conservative choice for v1. With METAL on iOS:
# - upstream CMakeLists has hardcoded macosx SDK assumptions that need the
#   patches in patches/0001-ios-metal-platform.patch
# - Xcode 16's "Metal Toolchain" is a separate ~1GB download
# Build CPU-only first; revisit Metal as a v2 once those gates are cleared.
cmake -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
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

# Sanity check: confirm we got an iOS-platform archive, not macOS.
# Use bash regex against a buffered otool output instead of a pipe — `otool |
# awk '... exit'` triggers SIGPIPE on otool because libmlx.a contains many
# object files (350KB of -l output) and awk closes the pipe after the first
# match. set -o pipefail then aborts the script.
OTOOL_OUT=$(otool -l "$BUILD_DIR/libmlx.a" 2>/dev/null || true)
if [[ "$OTOOL_OUT" =~ platform[[:space:]]+([0-9]+) ]]; then
    PLATFORM="${BASH_REMATCH[1]}"
else
    PLATFORM="unknown"
fi
[ "$PLATFORM" = "2" ] || fail "libmlx.a tagged platform=$PLATFORM, expected 2 (iOS device)"

log "installing to $PREFIX..."
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$PREFIX/include"

cp "$BUILD_DIR/libmlx.a" "$PREFIX/lib/"

# MLX public headers — used by downstream NIFs (EMLX) that #include "mlx/mlx.h".
mkdir -p "$PREFIX/include/mlx"
rsync -a --include='*.h' --include='*/' --exclude='*' \
    "$MLX_SRC/mlx/" "$PREFIX/include/mlx/"

# nlohmann/json is FetchContent'd by MLX at configure time. The EMLX NIF
# transitively #includes it via "mlx/backend/common/utils.h" → MLX internals.
# Stage the unpacked json headers so the NIF compile doesn't need a working
# CMake / network at build time.
if [ -d "$BUILD_DIR/_deps/json-src/include" ]; then
    mkdir -p "$PREFIX/include/_deps/json"
    rsync -a "$BUILD_DIR/_deps/json-src/include/" "$PREFIX/include/_deps/json/"
fi

# Write a small VERSION file for the tarball script to pick up and for
# MobDev.MLXDownloader to validate against.
cat > "$PREFIX/VERSION" <<EOF
mlx_version=${MLX_VERSION}
variant=ios-device-cpu
ios_deployment_target=${IOS_DEPLOYMENT_TARGET}
metal_enabled=false
EOF

log "done — libmlx.a installed at $PREFIX/lib/libmlx.a"
ls -lh "$PREFIX/lib/libmlx.a"
file "$PREFIX/lib/libmlx.a" | head -1

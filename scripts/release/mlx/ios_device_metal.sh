#!/usr/bin/env bash
# scripts/release/mlx/ios_device_metal.sh
#
# Cross-compile MLX with Metal GPU support enabled for iOS arm64 device.
# Sibling to ios_device.sh (which builds the CPU-only variant). The CPU
# build remains the conservative default; this script produces the
# Metal-enabled tarball variant that ships GPU compute.
#
# Two things make this distinct from the CPU build:
#
#   1. Source patches — MLX 0.25.1's CMakeLists.txt only enables Metal
#      when CMAKE_SYSTEM_NAME=Darwin and hardcodes `xcrun -sdk macosx`
#      throughout. The patches in patches/0001-ios-metal-build.patch
#      switch SDK selection on CMAKE_SYSTEM_NAME so iOS gets iphoneos +
#      `-mios-version-min` instead. Applied idempotently — re-running
#      the script after a successful build is a no-op.
#
#   2. Xcode Metal Toolchain — required to compile the .metal kernels
#      into a .metallib. Optional ~700MB Xcode component:
#        xcodebuild -downloadComponent MetalToolchain
#      The script checks for `metal` on PATH and fails early with a
#      pointer to that command if missing.
#
# Outputs (per the standard MLX prefix layout):
#
#   $PREFIX/lib/libmlx.a       — static archive, includes Metal symbols (~27 MB)
#   $PREFIX/lib/mlx.metallib   — precompiled Metal kernels (~84 MB)
#   $PREFIX/include/mlx/*.h    — public headers
#   $PREFIX/include/_deps/json — nlohmann/json headers (FetchContent'd by MLX)
#   $PREFIX/VERSION            — variant=ios-device-metal, metal_enabled=true

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${PREFIX:=/tmp/mlx-ios-device-${MLX_VERSION}-metal}"

# Sanity: iPhoneOS SDK must be installed.
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || \
    fail "iPhoneOS SDK not found — install Xcode + run 'xcode-select --install'"

# Sanity: Metal compiler must be installed. The Metal Toolchain is an
# optional Xcode component (different from the base macOS Metal tools
# that ship with Xcode by default).
if ! xcrun -f metal >/dev/null 2>&1; then
    fail "Metal compiler not on PATH — install via: xcodebuild -downloadComponent MetalToolchain"
fi

# Best-effort check: actually try to run metal --version. If the
# toolchain was downloaded but never registered (the asset is on disk
# but Xcode hasn't picked it up), `xcrun -f` finds the binary path but
# the binary itself fails. Surface that early with a clear error.
if ! xcrun metal --version >/dev/null 2>&1; then
    fail "Metal compiler is on PATH but won't run — re-run: xcodebuild -downloadComponent MetalToolchain"
fi

ensure_mlx_src
apply_ios_metal_patch

BUILD_DIR="$MLX_SRC/build-ios-device-metal-${MLX_VERSION}"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ -f "$BUILD_DIR/libmlx.a" ] && [ -f "$BUILD_DIR/mlx/backend/metal/kernels/mlx.metallib" ] && [ -z "${MLX_FORCE_REBUILD:-}" ]; then
    log "libmlx.a + mlx.metallib already built at $BUILD_DIR — skipping configure+make (set MLX_FORCE_REBUILD=1 to force)"
else

log "configuring MLX for arm64-apple-ios with Metal..."
cmake -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DMLX_BUILD_METAL=ON \
    -DMLX_BUILD_TESTS=OFF \
    -DMLX_BUILD_BENCHMARKS=OFF \
    -DMLX_BUILD_EXAMPLES=OFF \
    -DMLX_BUILD_PYTHON_BINDINGS=OFF \
    "$MLX_SRC"

log "building libmlx.a + mlx.metallib (this takes ~5 min, mostly Metal kernel compile)..."
make mlx -j"$(sysctl -n hw.ncpu)"

fi  # end of MLX_FORCE_REBUILD guard

# Sanity check: confirm we got an iOS-platform archive, not macOS.
# Use bash regex against a buffered otool output instead of a pipe — `otool |
# awk '... exit'` triggers SIGPIPE on otool because libmlx.a contains many
# object files and awk closes the pipe after the first match. set -o pipefail
# then aborts the script.
OTOOL_OUT=$(otool -l "$BUILD_DIR/libmlx.a" 2>/dev/null || true)
if [[ "$OTOOL_OUT" =~ platform[[:space:]]+([0-9]+) ]]; then
    PLATFORM="${BASH_REMATCH[1]}"
else
    PLATFORM="unknown"
fi
[ "$PLATFORM" = "2" ] || fail "libmlx.a tagged platform=$PLATFORM, expected 2 (iOS device)"

# Sanity: metallib was actually produced. Metal kernel compile failures
# are loud at build time so this is mostly belt-and-braces.
METALLIB_SRC="$BUILD_DIR/mlx/backend/metal/kernels/mlx.metallib"
[ -f "$METALLIB_SRC" ] || fail "mlx.metallib not produced — Metal kernel build failed silently?"

log "installing to $PREFIX..."
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$PREFIX/include"

cp "$BUILD_DIR/libmlx.a" "$PREFIX/lib/"
cp "$METALLIB_SRC" "$PREFIX/lib/"

# Public headers (same set the CPU build ships).
mkdir -p "$PREFIX/include/mlx"
rsync -a --include='*.h' --include='*/' --exclude='*' \
    "$MLX_SRC/mlx/" "$PREFIX/include/mlx/"

if [ -d "$BUILD_DIR/_deps/json-src/include" ]; then
    mkdir -p "$PREFIX/include/_deps/json"
    rsync -a "$BUILD_DIR/_deps/json-src/include/" "$PREFIX/include/_deps/json/"
fi

cat > "$PREFIX/VERSION" <<EOF
mlx_version=${MLX_VERSION}
variant=ios-device-metal
ios_deployment_target=${IOS_DEPLOYMENT_TARGET}
metal_enabled=true
EOF

log "done — Metal-enabled MLX installed at $PREFIX"
ls -lh "$PREFIX/lib/libmlx.a" "$PREFIX/lib/mlx.metallib"
file "$PREFIX/lib/libmlx.a" | head -1

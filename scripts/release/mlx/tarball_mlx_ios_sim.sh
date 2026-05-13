#!/usr/bin/env bash
# scripts/release/mlx/tarball_mlx_ios_sim.sh
# iOS Simulator counterpart to tarball_mlx_ios_device.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${MLX_PREFIX:=/tmp/mlx-ios-sim-${MLX_VERSION}}"

[ -f "$MLX_PREFIX/lib/libmlx.a" ]  || fail "no libmlx.a at $MLX_PREFIX/lib/ — run ios_sim.sh first"
[ -f "$MLX_PREFIX/lib/libemlx.a" ] || fail "no libemlx.a at $MLX_PREFIX/lib/ — run build_emlx_nif_ios_sim.sh first"

STAGE=$(mktemp -d -t mlx-tarball-XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

NAME="libmlx-${MLX_VERSION}-ios-sim"
STAGE_DIR="$STAGE/$NAME"
mkdir -p "$STAGE_DIR"
rsync -a "$MLX_PREFIX/" "$STAGE_DIR/"

OUT="$OUT_DIR/${NAME}.tar.gz"
log "writing $OUT..."
tar -czf "$OUT" -C "$STAGE" "$NAME"

log "done"
ls -lh "$OUT"
shasum -a 256 "$OUT" | awk '{print "sha256: " $1}'

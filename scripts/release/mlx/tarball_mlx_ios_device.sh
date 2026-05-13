#!/usr/bin/env bash
# scripts/release/mlx/tarball_mlx_ios_device.sh
# Pack the cross-compiled MLX artifacts into a release tarball.
#
# Output: $OUT_DIR/libmlx-<ver>-ios-device.tar.gz
#
# This tarball is what MobDev.MLXDownloader.ensure_ios_device/0 fetches at
# `mix mob.deploy --native` time when a project has :emlx in deps.
#
# Inputs (env):
#   MLX_PREFIX   — install dir from ios_device.sh + build_emlx_nif_ios_device.sh
#                  (default: /tmp/mlx-ios-device-<ver>)
#   OUT_DIR      — output dir (default: /tmp)
#   MLX_VERSION  — pinned MLX version (default: 0.25.1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${MLX_PREFIX:=/tmp/mlx-ios-device-${MLX_VERSION}}"

[ -f "$MLX_PREFIX/lib/libmlx.a" ]  || fail "no libmlx.a at $MLX_PREFIX/lib/ — run ios_device.sh first"
[ -f "$MLX_PREFIX/lib/libemlx.a" ] || fail "no libemlx.a at $MLX_PREFIX/lib/ — run build_emlx_nif_ios_device.sh first"

STAGE=$(mktemp -d -t mlx-tarball-XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

NAME="libmlx-${MLX_VERSION}-ios-device"
STAGE_DIR="$STAGE/$NAME"
mkdir -p "$STAGE_DIR"
rsync -a "$MLX_PREFIX/" "$STAGE_DIR/"

OUT="$OUT_DIR/${NAME}.tar.gz"
log "writing $OUT..."
tar -czf "$OUT" -C "$STAGE" "$NAME"

log "done"
ls -lh "$OUT"
shasum -a 256 "$OUT" | awk '{print "sha256: " $1}'

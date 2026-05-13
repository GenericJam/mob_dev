#!/usr/bin/env bash
# scripts/release/mlx/all_ios.sh
# One-shot orchestrator: build libmlx.a + libemlx.a + tarball for both
# iOS device and iOS simulator.
#
# Run this from a clean machine + Xcode + a working Mob app's ~/.mob/cache
# (so the OTP iOS-{device,sim} runtimes are present).
#
#   ~/code/mob_dev/scripts/release/mlx/all_ios.sh
#
# Produces /tmp/libmlx-<ver>-ios-{device,sim}.tar.gz ready for upload to
# the GitHub release matching `MobDev.MLXDownloader.@release_tag`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/ios_device.sh"
"$SCRIPT_DIR/build_emlx_nif_ios_device.sh"
"$SCRIPT_DIR/tarball_mlx_ios_device.sh"

"$SCRIPT_DIR/ios_sim.sh"
"$SCRIPT_DIR/build_emlx_nif_ios_sim.sh"
"$SCRIPT_DIR/tarball_mlx_ios_sim.sh"

echo
echo "=== MLX iOS release artifacts ready ==="
ls -lh /tmp/libmlx-*-ios-*.tar.gz

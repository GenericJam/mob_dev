#!/usr/bin/env bash
# scripts/release/mlx/_lib.sh — shared helpers for the MLX release scripts.
# Sourced by sibling scripts; not meant to be run directly.

set -euo pipefail

# ── Defaults (override via env or CLI before sourcing) ──────────────────────
# Pin MLX to the version EMLX 0.2.0 expects. Bump together with EMLX.
: "${MLX_VERSION:=0.25.1}"
: "${MLX_SRC:=$HOME/.cache/mob-mlx-build/mlx-${MLX_VERSION}}"
: "${OUT_DIR:=/tmp}"

# iOS deployment-target floor. Matches the rest of the mob_dev scripts.
: "${IOS_DEPLOYMENT_TARGET:=17.0}"

log()  { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

# Fetch and unpack the pinned MLX source archive if not already present.
# Idempotent — leaves an existing checkout alone.
ensure_mlx_src() {
    if [ -f "$MLX_SRC/CMakeLists.txt" ]; then
        log "MLX source already at $MLX_SRC"
        return 0
    fi

    log "downloading MLX $MLX_VERSION..."
    mkdir -p "$(dirname "$MLX_SRC")"
    local tarball="$(dirname "$MLX_SRC")/mlx-${MLX_VERSION}.tar.gz"

    if [ ! -f "$tarball" ]; then
        curl -fSL \
            "https://github.com/ml-explore/mlx/archive/refs/tags/v${MLX_VERSION}.tar.gz" \
            -o "$tarball"
    fi

    tar -xzf "$tarball" -C "$(dirname "$MLX_SRC")"
    log "MLX source ready at $MLX_SRC"
}

# Resolve the EMLX source directory. Defaults to the user's test_emlx project
# checkout — overridable via $EMLX_SRC. For a publish-grade build the caller
# should pass a known-good EMLX checkout.
require_emlx_src() {
    if [ -z "${EMLX_SRC:-}" ]; then
        if [ -d "$HOME/code/test_emlx/deps/emlx/c_src" ]; then
            EMLX_SRC="$HOME/code/test_emlx/deps/emlx"
        else
            fail "EMLX_SRC not set and no fallback at ~/code/test_emlx/deps/emlx — pass EMLX_SRC=/path/to/emlx"
        fi
    fi
    [ -f "$EMLX_SRC/c_src/emlx_nif.cpp" ] || fail "no emlx_nif.cpp at $EMLX_SRC/c_src/"
    export EMLX_SRC
}

# OTP cache (the iOS-{device,sim} OTP tarball Mob already downloads). Used to
# find erl_nif.h when compiling emlx_nif.cpp.
otp_ios_device_dir() {
    local pattern="$HOME/.mob/cache/otp-ios-device-*"
    local first
    first=$(ls -d $pattern 2>/dev/null | head -1)
    [ -n "$first" ] || fail "no iOS-device OTP cache at ~/.mob/cache/otp-ios-device-*. Run `mix mob.install` from a Mob project first."
    echo "$first"
}

otp_ios_sim_dir() {
    local pattern="$HOME/.mob/cache/otp-ios-sim-*"
    local first
    first=$(ls -d $pattern 2>/dev/null | head -1)
    [ -n "$first" ] || fail "no iOS-sim OTP cache at ~/.mob/cache/otp-ios-sim-*. Run `mix mob.install` from a Mob project first."
    echo "$first"
}

export MLX_VERSION MLX_SRC OUT_DIR IOS_DEPLOYMENT_TARGET

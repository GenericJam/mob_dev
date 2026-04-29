#!/usr/bin/env bash
# scripts/release/_lib.sh — shared helpers for the release scripts.
# Sourced by sibling scripts; not meant to be run directly.

set -euo pipefail

# ── Defaults (override via env or CLI before sourcing) ──────────────────────
: "${OTP_SRC:=$HOME/code/otp}"
: "${OUT_DIR:=/tmp}"
: "${HASH:=}"

# Auto-detect HASH from the OTP source tree if not set. Force 8 chars so the
# tag (`otp-<hash>`), tarball filename (`otp-...-<hash>.tar.gz`), and the
# `@otp_hash` constant in `otp_downloader.ex` all stay in lockstep. Git's
# default `--short` length grows over time (collision avoidance) so without
# pinning we'd silently produce 10-char tarball names that don't match.
if [ -z "$HASH" ] && [ -d "$OTP_SRC/.git" ]; then
    HASH=$(git -C "$OTP_SRC" rev-parse --short=8 HEAD)
fi

if [ -z "$HASH" ]; then
    echo "ERROR: HASH not set and OTP_SRC ($OTP_SRC) is not a git checkout." >&2
    echo "       Pass HASH=<hash> as an env var or CLI arg." >&2
    exit 1
fi

# Auto-detect ERTS version from $OTP_SRC/erts/vsn.mk (`VSN = 16.3` etc.)
# Fallback to scanning a release dir if a path is provided.
if [ -z "${ERTS_VSN:-}" ]; then
    if [ -f "$OTP_SRC/erts/vsn.mk" ]; then
        ERTS_VSN=$(awk '/^VSN[ \t]*=/ {print $3; exit}' "$OTP_SRC/erts/vsn.mk")
    fi
fi

if [ -z "${ERTS_VSN:-}" ]; then
    echo "ERROR: could not auto-detect ERTS version from $OTP_SRC/erts/vsn.mk" >&2
    echo "       Set ERTS_VSN=<vsn> explicitly (e.g. ERTS_VSN=16.3)." >&2
    exit 1
fi

# Resolve host Elixir lib dir for the bundled stdlib (elixir, logger, eex).
if [ -z "${ELIXIR_LIB:-}" ]; then
    ELIXIR_LIB=$(elixir -e "IO.puts(:code.lib_dir(:elixir))" | xargs dirname)
fi

log()  { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

# Copy bundled Elixir stdlib (elixir, logger, eex) into a staged tarball root.
# Same recipe is used by every tarball — bytecode is arch-independent.
bundle_elixir_stdlib() {
    local stage="$1"
    for app in elixir logger eex; do
        mkdir -p "$stage/lib/$app/ebin"
        cp "$ELIXIR_LIB/$app/ebin/"* "$stage/lib/$app/ebin/"
    done
    log "bundled Elixir $(elixir --version | grep Elixir | awk '{print $2}')"
}

export OTP_SRC OUT_DIR HASH ERTS_VSN ELIXIR_LIB

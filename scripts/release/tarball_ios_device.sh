#!/usr/bin/env bash
# scripts/release/tarball_ios_device.sh
# Stage and tar the iOS device OTP runtime + EPMD source. Mirrors Step 3b
# of build_release.md.
#
# Inputs (env or default):
#   OTP_SRC      — OTP source checkout (default: ~/code/otp)
#   OTP_RELEASE  — install dir produced by xcompile_ios_device.sh
#                  (default: /tmp/otp-ios-device)
#   HASH         — release tag hash (default: auto-detected from $OTP_SRC git)
#   OUT_DIR      — output directory (default: /tmp)
#
# Output:
#   $OUT_DIR/otp-ios-device-$HASH.tar.gz

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${OTP_RELEASE:=/tmp/otp-ios-device}"

[ -d "$OTP_RELEASE" ] || fail "missing $OTP_RELEASE — run xcompile_ios_device.sh first"
[ -f "$OTP_SRC/erts/aarch64-apple-ios/config.h" ] \
    || fail "missing $OTP_SRC/erts/aarch64-apple-ios/config.h — run xcompile_ios_device.sh first"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

log "OTP_SRC=$OTP_SRC"
log "OTP_RELEASE=$OTP_RELEASE"
log "ERTS_VSN=$ERTS_VSN, HASH=$HASH"
log "staging at $STAGE"

# Copy the OTP runtime install tree.
cp -r "$OTP_RELEASE/." "$STAGE"

# Add extra static libs (same set as the sim tarball, but iOS-device arch).
ERTS_LIB="$STAGE/erts-$ERTS_VSN/lib"
cp "$OTP_SRC/erts/emulator/zstd/obj/aarch64-apple-ios/opt/libzstd.a"   "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/pcre/obj/aarch64-apple-ios/opt/libepcre.a"  "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/ryu/obj/aarch64-apple-ios/opt/libryu.a"     "$ERTS_LIB/"
cp "$OTP_SRC/lib/asn1/priv/lib/aarch64-apple-ios/asn1rt_nif.a"         "$ERTS_LIB/"

# Add required headers.
ERTS_INC="$STAGE/erts-$ERTS_VSN/include"
mkdir -p "$ERTS_INC"
cp "$OTP_SRC/erts/emulator/beam/erl_nif.h"                              "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_nif_api_funcs.h"                    "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_drv_nif.h"                          "$ERTS_INC/"
cp "$OTP_SRC/erts/include/aarch64-apple-ios/erl_int_sizes_config.h"     "$ERTS_INC/"
cp "$OTP_SRC/erts/include/erl_fixed_size_int_types.h"                   "$ERTS_INC/"

# Bundle Elixir stdlib (elixir, logger, eex) — bytecode is arch-independent.
bundle_elixir_stdlib "$STAGE"

# ── EPMD source + iOS-arm64 configure output ────────────────────────────────
# build_device.sh static-links EPMD into the iOS app. The .c sources and the
# arch-specific config.h must be present alongside the install tree.
# `MobDev.OtpDownloader.valid_otp_dir?/2` validates these are present and
# re-downloads if absent.
log "bundling EPMD source + iOS-arm64 configure output..."
mkdir -p "$STAGE/erts/epmd/src"
cp "$OTP_SRC/erts/epmd/src/epmd.c"     "$STAGE/erts/epmd/src/"
cp "$OTP_SRC/erts/epmd/src/epmd_srv.c" "$STAGE/erts/epmd/src/"
cp "$OTP_SRC/erts/epmd/src/epmd_cli.c" "$STAGE/erts/epmd/src/"
# epmd.c → epmd.h, epmd_int.h, both in erts/epmd/src/. Bundle every .h in
# src/ for safety — they're tiny and including all of them costs nothing.
cp "$OTP_SRC/erts/epmd/src/"*.h "$STAGE/erts/epmd/src/"

mkdir -p "$STAGE/erts/aarch64-apple-ios"
cp -r "$OTP_SRC/erts/aarch64-apple-ios/"* "$STAGE/erts/aarch64-apple-ios/"

mkdir -p "$STAGE/erts/include" "$STAGE/erts/include/internal"
cp -r "$OTP_SRC/erts/include/"*          "$STAGE/erts/include/"
cp -r "$OTP_SRC/erts/include/internal/"* "$STAGE/erts/include/internal/"

# Tar it up.
TARBALL="$OUT_DIR/otp-ios-device-$HASH.tar.gz"
BASE=$(basename "$STAGE")
log "creating $TARBALL..."
tar czf "$TARBALL" -C "$(dirname "$STAGE")" "$BASE"

# Verify the schema requirements: erts-*/ install, EPMD source files,
# iOS-arm64 config.h, Elixir stdlib.
log "verifying $TARBALL contents..."
verify_present() {
    tar tzf "$TARBALL" | grep -q "$1" \
        || fail "verify failed — tarball missing $1"
}
verify_present "erts-$ERTS_VSN"
verify_present "erts/epmd/src/epmd.c"
verify_present "erts/epmd/src/epmd_srv.c"
verify_present "erts/epmd/src/epmd_cli.c"
verify_present "erts/epmd/src/epmd.h"
verify_present "erts/epmd/src/epmd_int.h"
verify_present "erts/aarch64-apple-ios/config.h"
verify_present "lib/elixir/ebin/elixir.app"

log "done: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
log "next: scripts/release/publish.sh"

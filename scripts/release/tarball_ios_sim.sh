#!/usr/bin/env bash
# scripts/release/tarball_ios_sim.sh
# Stage and tar the iOS simulator OTP runtime. Mirrors Step 3 of build_release.md.
#
# Inputs (env or default):
#   OTP_SRC      — OTP source checkout (default: ~/code/otp)
#   OTP_RELEASE  — install dir for aarch64-apple-iossimulator
#                  (default: /tmp/otp-ios-sim)
#   HASH         — release tag hash (auto-detected from $OTP_SRC git)
#   OUT_DIR      — output directory (default: /tmp)
#
# Output:
#   $OUT_DIR/otp-ios-sim-$HASH.tar.gz

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${OTP_RELEASE:=/tmp/otp-ios-sim}"

[ -d "$OTP_RELEASE" ] || fail "missing $OTP_RELEASE — cross-compile iOS sim first"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

log "OTP_SRC=$OTP_SRC, OTP_RELEASE=$OTP_RELEASE, ERTS_VSN=$ERTS_VSN, HASH=$HASH"

# Copy the OTP runtime.
cp -r "$OTP_RELEASE/." "$STAGE"

# Add extra static libs.
ERTS_LIB="$STAGE/erts-$ERTS_VSN/lib"
cp "$OTP_SRC/erts/emulator/zstd/obj/aarch64-apple-iossimulator/opt/libzstd.a"  "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/pcre/obj/aarch64-apple-iossimulator/opt/libepcre.a" "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/ryu/obj/aarch64-apple-iossimulator/opt/libryu.a"    "$ERTS_LIB/"
cp "$OTP_SRC/lib/asn1/priv/lib/aarch64-apple-iossimulator/asn1rt_nif.a"        "$ERTS_LIB/"

# Add required headers.
ERTS_INC="$STAGE/erts-$ERTS_VSN/include"
mkdir -p "$ERTS_INC"
cp "$OTP_SRC/erts/emulator/beam/erl_nif.h"                                       "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_nif_api_funcs.h"                             "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_drv_nif.h"                                   "$ERTS_INC/"
cp "$OTP_SRC/erts/include/aarch64-apple-iossimulator/erl_int_sizes_config.h"     "$ERTS_INC/"
cp "$OTP_SRC/erts/include/erl_fixed_size_int_types.h"                            "$ERTS_INC/"

# Bundle Elixir stdlib.
bundle_elixir_stdlib "$STAGE"

# Tar it up — exclude any stray app build dirs left in OTP_RELEASE.
TARBALL="$OUT_DIR/otp-ios-sim-$HASH.tar.gz"
BASE=$(basename "$STAGE")
log "creating $TARBALL..."
tar czf "$TARBALL" \
    --exclude="$BASE/beamhello" \
    --exclude="$BASE/test_app" \
    --exclude="$BASE/test_app0" \
    -C "$(dirname "$STAGE")" "$BASE"

log "verifying contents..."
verify_present() {
    tar tzf "$TARBALL" | grep -q "$1" || fail "missing $1"
}
verify_present "erts-$ERTS_VSN"
verify_present "lib/elixir/ebin/elixir.app"

log "done: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

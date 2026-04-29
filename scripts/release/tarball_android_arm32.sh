#!/usr/bin/env bash
# scripts/release/tarball_android_arm32.sh
# Stage and tar the Android arm32 (armeabi-v7a) OTP runtime + exqlite BEAMs.
# Mirrors Step 2 (arm32) of build_release.md.
#
# Prerequisite: a separately-built arm32 asn1rt_nif.a at
# $ASN1RT_NIF_ARM32 (default /tmp/asn1rt_nif_arm32.a — see build_release.md
# Step 2 arm32 prerequisites for the exact NDK-clang invocation).
#
# Inputs (env or default):
#   OTP_SRC          — OTP source checkout (default: ~/code/otp)
#   OTP_RELEASE      — Android arm32 install dir (default: /tmp/otp-android-arm32)
#   ASN1RT_NIF_ARM32 — pre-built arm32 asn1rt_nif.a (default: /tmp/asn1rt_nif_arm32.a)
#   EXQLITE_BUILD, HASH, OUT_DIR — see _lib.sh / arm64 script
#
# Output:
#   $OUT_DIR/otp-android-arm32-$HASH.tar.gz

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${OTP_RELEASE:=/tmp/otp-android-arm32}"
: "${ASN1RT_NIF_ARM32:=/tmp/asn1rt_nif_arm32.a}"
: "${EXQLITE_BUILD:=}"

[ -d "$OTP_RELEASE" ] || fail "missing $OTP_RELEASE — cross-compile Android arm32 first"
[ -f "$ASN1RT_NIF_ARM32" ] || fail "missing $ASN1RT_NIF_ARM32 — build it per build_release.md Step 2 arm32 prerequisites"
[ -n "$EXQLITE_BUILD" ] || fail "EXQLITE_BUILD not set"
[ -d "$EXQLITE_BUILD/ebin" ] || fail "EXQLITE_BUILD ($EXQLITE_BUILD) has no ebin/"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

log "OTP_SRC=$OTP_SRC, OTP_RELEASE=$OTP_RELEASE, ERTS_VSN=$ERTS_VSN, HASH=$HASH"

cp -r "$OTP_RELEASE/." "$STAGE"

ERTS_LIB="$STAGE/erts-$ERTS_VSN/lib"
cp "$OTP_SRC/erts/emulator/zstd/obj/arm-unknown-linux-androideabi/opt/libzstd.a"   "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/pcre/obj/arm-unknown-linux-androideabi/opt/libepcre.a"  "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/ryu/obj/arm-unknown-linux-androideabi/opt/libryu.a"     "$ERTS_LIB/"
cp "$ASN1RT_NIF_ARM32"                                                              "$ERTS_LIB/asn1rt_nif.a"

ERTS_INC="$STAGE/erts-$ERTS_VSN/include"
mkdir -p "$ERTS_INC"
cp "$OTP_SRC/erts/emulator/beam/erl_nif.h"                                          "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_nif_api_funcs.h"                                "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_drv_nif.h"                                      "$ERTS_INC/"
cp "$OTP_SRC/erts/include/arm-unknown-linux-androideabi/erl_int_sizes_config.h"     "$ERTS_INC/"
cp "$OTP_SRC/erts/include/erl_fixed_size_int_types.h"                               "$ERTS_INC/"

bundle_elixir_stdlib "$STAGE"

EXQLITE_VSN=$(grep '"exqlite"' "$EXQLITE_BUILD/../../../mix.lock" \
    | grep -o '"[0-9][^"]*"' | head -1 | tr -d '"')
[ -n "$EXQLITE_VSN" ] || fail "could not detect exqlite version"
EXQLITE_LIB="$STAGE/lib/exqlite-$EXQLITE_VSN"
mkdir -p "$EXQLITE_LIB/ebin" "$EXQLITE_LIB/priv"
cp "$EXQLITE_BUILD/ebin/"* "$EXQLITE_LIB/ebin/"
log "bundled exqlite $EXQLITE_VSN"

TARBALL="$OUT_DIR/otp-android-arm32-$HASH.tar.gz"
BASE=$(basename "$STAGE")
log "creating $TARBALL..."
tar czf "$TARBALL" -C "$(dirname "$STAGE")" "$BASE"

log "verifying contents..."
verify_present() {
    tar tzf "$TARBALL" | grep -q "$1" || fail "missing $1"
}
verify_present "erts-$ERTS_VSN"
verify_present "lib/elixir/ebin/elixir.app"
verify_present "lib/exqlite-$EXQLITE_VSN"

log "done: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

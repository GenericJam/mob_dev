#!/usr/bin/env bash
# scripts/release/tarball_android_x86_64.sh
# Stage and tar the Android x86_64 OTP runtime + exqlite BEAMs. Mirrors
# tarball_android_arm64.sh — only the target triple, OpenSSL prefix, OTP
# release dir, and tarball name differ. (x86_64 = Android emulators on
# x86_64 hosts / CI.)
#
# Inputs (env or default):
#   OTP_SRC        — OTP source checkout (default: ~/code/otp)
#   OTP_RELEASE    — Android x86_64 install dir (default: /tmp/otp-android-x86_64)
#   EXQLITE_BUILD  — path to a project's _build/dev/lib/exqlite (must exist)
#   HASH, OUT_DIR — see _lib.sh
#
# Output:
#   $OUT_DIR/otp-android-x86_64-$HASH.tar.gz

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${OTP_RELEASE:=/tmp/otp-android-x86_64}"
: "${EXQLITE_BUILD:=}"
TRIPLE="x86_64-pc-linux-android"

[ -d "$OTP_RELEASE" ] || fail "missing $OTP_RELEASE — cross-compile Android x86_64 first"
[ -n "$EXQLITE_BUILD" ] || fail "EXQLITE_BUILD not set — point at any project's _build/dev/lib/exqlite"
[ -d "$EXQLITE_BUILD/ebin" ] || fail "EXQLITE_BUILD ($EXQLITE_BUILD) has no ebin/ — did you run mix compile?"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

log "OTP_SRC=$OTP_SRC, OTP_RELEASE=$OTP_RELEASE, ERTS_VSN=$ERTS_VSN, HASH=$HASH, TRIPLE=$TRIPLE"

cp -r "$OTP_RELEASE/." "$STAGE"

# Extra static libs (same set as arm64, from the x86_64 target dirs).
ERTS_LIB="$STAGE/erts-$ERTS_VSN/lib"
cp "$OTP_SRC/erts/emulator/zstd/obj/$TRIPLE/opt/libzstd.a"  "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/pcre/obj/$TRIPLE/opt/libepcre.a" "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/ryu/obj/$TRIPLE/opt/libryu.a"    "$ERTS_LIB/"
cp "$OTP_SRC/lib/asn1/priv/lib/$TRIPLE/asn1rt_nif.a"        "$ERTS_LIB/"

# Crypto: OTP's crypto NIF + OpenSSL, both static (see arm64 script's comment).
cp "$OTP_SRC/lib/crypto/priv/lib/$TRIPLE/crypto.a"          "$ERTS_LIB/"
: "${OPENSSL_PREFIX_X86_64:=/tmp/openssl-android-x86_64}"
cp "$OPENSSL_PREFIX_X86_64/lib/libcrypto.a"                 "$ERTS_LIB/"

# Required headers.
ERTS_INC="$STAGE/erts-$ERTS_VSN/include"
mkdir -p "$ERTS_INC"
cp "$OTP_SRC/erts/emulator/beam/erl_nif.h"                  "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_nif_api_funcs.h"        "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_drv_nif.h"              "$ERTS_INC/"
cp "$OTP_SRC/erts/include/$TRIPLE/erl_int_sizes_config.h"   "$ERTS_INC/"
cp "$OTP_SRC/erts/include/erl_fixed_size_int_types.h"       "$ERTS_INC/"

bundle_elixir_stdlib "$STAGE"

EXQLITE_VSN=$(grep '"exqlite"' "$EXQLITE_BUILD/../../../../mix.lock" \
    | grep -o '"[0-9][^"]*"' | head -1 | tr -d '"')
if [ -z "$EXQLITE_VSN" ]; then
    EXQLITE_VSN=$(grep -o '{vsn,"[^"]*"}' "$EXQLITE_BUILD/ebin/exqlite.app" \
        | grep -o '"[^"]*"' | tr -d '"')
fi
[ -n "$EXQLITE_VSN" ] || fail "could not detect exqlite version from $EXQLITE_BUILD"
EXQLITE_LIB="$STAGE/lib/exqlite-$EXQLITE_VSN"
mkdir -p "$EXQLITE_LIB/ebin" "$EXQLITE_LIB/priv"
cp "$EXQLITE_BUILD/ebin/"* "$EXQLITE_LIB/ebin/"
log "bundled exqlite $EXQLITE_VSN"

TARBALL="$OUT_DIR/otp-android-x86_64-$HASH.tar.gz"
BASE=$(basename "$STAGE")
log "creating $TARBALL..."
tar czf "$TARBALL" -C "$(dirname "$STAGE")" "$BASE"

log "verifying contents..."
verify_present() { tar tzf "$TARBALL" | grep -q "$1" || fail "missing $1"; }
verify_present "erts-$ERTS_VSN"
verify_present "lib/elixir/ebin/elixir.app"
verify_present "lib/exqlite-$EXQLITE_VSN"
verify_present "lib/crypto-.*/priv/lib/crypto.so"
verify_present "lib/ssl-.*/ebin/ssl.beam"
verify_present "erts-$ERTS_VSN/lib/crypto.a"
verify_present "erts-$ERTS_VSN/lib/libcrypto.a"

log "done: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

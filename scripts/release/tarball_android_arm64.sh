#!/usr/bin/env bash
# scripts/release/tarball_android_arm64.sh
# Stage and tar the Android arm64 OTP runtime + exqlite BEAMs. Mirrors
# Step 2 (arm64) of build_release.md.
#
# Inputs (env or default):
#   OTP_SRC        — OTP source checkout (default: ~/code/otp)
#   OTP_RELEASE    — Android arm64 install dir (default: /tmp/otp-android)
#   EXQLITE_BUILD  — path to a project's _build/dev/lib/exqlite (must exist)
#   HASH, OUT_DIR — see _lib.sh
#
# Output:
#   $OUT_DIR/otp-android-$HASH.tar.gz

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${OTP_RELEASE:=/tmp/otp-android}"
: "${EXQLITE_BUILD:=}"

[ -d "$OTP_RELEASE" ] || fail "missing $OTP_RELEASE — cross-compile Android arm64 first"

if [ -z "$EXQLITE_BUILD" ]; then
    fail "EXQLITE_BUILD not set — point at any project's _build/dev/lib/exqlite (run mix deps.get && mix compile in a project that uses ecto_sqlite3)"
fi

[ -d "$EXQLITE_BUILD/ebin" ] || fail "EXQLITE_BUILD ($EXQLITE_BUILD) has no ebin/ — did you run mix compile?"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

log "OTP_SRC=$OTP_SRC, OTP_RELEASE=$OTP_RELEASE, ERTS_VSN=$ERTS_VSN, HASH=$HASH"

cp -r "$OTP_RELEASE/." "$STAGE"

# Extra static libs.
ERTS_LIB="$STAGE/erts-$ERTS_VSN/lib"
cp "$OTP_SRC/erts/emulator/zstd/obj/aarch64-unknown-linux-android/opt/libzstd.a"  "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/pcre/obj/aarch64-unknown-linux-android/opt/libepcre.a" "$ERTS_LIB/"
cp "$OTP_SRC/erts/emulator/ryu/obj/aarch64-unknown-linux-android/opt/libryu.a"    "$ERTS_LIB/"
cp "$OTP_SRC/lib/asn1/priv/lib/aarch64-unknown-linux-android/asn1rt_nif.a"        "$ERTS_LIB/"

# Crypto: real OpenSSL static-linked into the app's libpigeon.so.
# Both archives are needed:
#   - crypto.a: OTP's crypto NIF C wrapper, built with -DSTATIC_ERLANG_NIF
#     (auto-emitted at OTP-build time when ./otp_build configure was
#     passed --enable-static-nifs). ERL_NIF_INIT(crypto, ...) emits the
#     crypto_nif_init symbol the BEAM resolves at load_nif time via
#     dlsym(RTLD_DEFAULT) — no dlopen of crypto.so.
#   - libcrypto.a: OpenSSL itself (provides EVP_*, ECDH, AEAD, etc.).
# Android loads native libs RTLD_LOCAL by default, so dlopen'ing a
# separate crypto.so doesn't see the BEAM's enif_* symbols. Static
# linking sidesteps that entirely; the same .a is also App-Store-friendly
# (no separate shared library shipped in the bundle).
cp "$OTP_SRC/lib/crypto/priv/lib/aarch64-unknown-linux-android/crypto.a"           "$ERTS_LIB/"
: "${OPENSSL_PREFIX_ARM64:=/tmp/openssl-android-arm64}"
cp "$OPENSSL_PREFIX_ARM64/lib/libcrypto.a"                                         "$ERTS_LIB/"

# Required headers.
ERTS_INC="$STAGE/erts-$ERTS_VSN/include"
mkdir -p "$ERTS_INC"
cp "$OTP_SRC/erts/emulator/beam/erl_nif.h"                                          "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_nif_api_funcs.h"                                "$ERTS_INC/"
cp "$OTP_SRC/erts/emulator/beam/erl_drv_nif.h"                                      "$ERTS_INC/"
cp "$OTP_SRC/erts/include/aarch64-unknown-linux-android/erl_int_sizes_config.h"     "$ERTS_INC/"
cp "$OTP_SRC/erts/include/erl_fixed_size_int_types.h"                               "$ERTS_INC/"

bundle_elixir_stdlib "$STAGE"

# exqlite BEAMs (.so NIF lives in the APK; only ebin/ goes here).
# mix.lock is 4 levels up from .../_build/dev/lib/exqlite (project root).
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

TARBALL="$OUT_DIR/otp-android-$HASH.tar.gz"
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
verify_present "lib/crypto-.*/priv/lib/crypto.so"
verify_present "lib/public_key-.*/ebin/public_key.beam"
verify_present "lib/ssl-.*/ebin/ssl.beam"
verify_present "erts-$ERTS_VSN/lib/crypto.a"
verify_present "erts-$ERTS_VSN/lib/libcrypto.a"

log "done: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

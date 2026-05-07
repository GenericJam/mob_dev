#!/usr/bin/env bash
# scripts/release/openssl/ios_sim.sh
# Cross-compile OpenSSL 3.x for iOS simulator (arm64).
# Output: $PREFIX/lib/libcrypto.a, $PREFIX/lib/libssl.a, $PREFIX/include/openssl/*.h
#
# Inputs (env):
#   OPENSSL_SRC — OpenSSL source checkout (default: ~/code/openssl)
#   PREFIX      — install dir (default: /tmp/openssl-ios-sim)
set -euo pipefail

: "${OPENSSL_SRC:=$HOME/code/openssl}"
: "${PREFIX:=/tmp/openssl-ios-sim}"

[ -d "$OPENSSL_SRC" ] || { echo "ERROR: OPENSSL_SRC not at $OPENSSL_SRC" >&2; exit 1; }
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || \
    { echo "ERROR: iphonesimulator SDK not found" >&2; exit 1; }

# Make sure iossimulator-xcrun targets uses the right SDK; OpenSSL Configure
# auto-detects via xcrun internally. Force arm64 sim target.
export CC="xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0"
export CXX="xcrun -sdk iphonesimulator clang++ -arch arm64 -mios-simulator-version-min=17.0"
export AR="xcrun -sdk iphonesimulator ar"
export RANLIB="xcrun -sdk iphonesimulator ranlib"

cd "$OPENSSL_SRC"
make distclean >/dev/null 2>&1 || true

## See android_arm64.sh for size-flag rationale.
## See android_arm64.sh for the no-X rationale per algorithm.
./Configure iossimulator-xcrun \
    -Os -ffunction-sections -fdata-sections \
    --prefix="$PREFIX" \
    --openssldir="$PREFIX/ssl" \
    no-shared no-tests no-apps no-engine \
    no-md2 no-md4 no-mdc2 no-whirlpool no-rmd160 \
    no-rc2 no-rc4 no-idea no-cast no-bf no-blake2 \
    no-seed no-aria no-camellia no-gost \
    no-weak-ssl-ciphers no-ssl3 no-tls1 no-tls1_1 \
    no-srp no-psk no-nextprotoneg

make -j8
make install_sw

echo
echo "OpenSSL iOS simulator (arm64) installed at: $PREFIX"
echo "  $(ls -la "$PREFIX/lib/libcrypto.a")"
echo "  arch check: $(file "$PREFIX/lib/libcrypto.a" | head -1)"

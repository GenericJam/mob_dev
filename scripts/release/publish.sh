#!/usr/bin/env bash
# scripts/release/publish.sh
# Create or replace assets on the GitHub release for this OTP hash. Mirrors
# Step 4 of build_release.md.
#
# Inputs (env or default):
#   HASH    — release tag hash (auto-detected from $OTP_SRC git)
#   OUT_DIR — where the tarballs were written (default: /tmp)
#   REPO    — GitHub repo (default: GenericJam/mob)
#   ASSETS  — space-separated list of tarball basenames to upload. Defaults
#             to all four if all exist; otherwise only the ones present.
#
# Behaviour:
#   - Creates the release `otp-$HASH` if it doesn't exist.
#   - For each asset that's already on the release, deletes it first
#     (`gh release upload` won't replace by default).
#   - Uploads everything in one `gh release upload` call.

set -euo pipefail

cd "$(dirname "$0")"
source ./_lib.sh

: "${REPO:=GenericJam/mob}"
TAG="otp-$HASH"

# Build default ASSETS list from whatever's in OUT_DIR for this hash.
if [ -z "${ASSETS:-}" ]; then
    candidates=(
        "otp-android-$HASH.tar.gz"
        "otp-android-arm32-$HASH.tar.gz"
        "otp-ios-sim-$HASH.tar.gz"
        "otp-ios-device-$HASH.tar.gz"
    )
    ASSETS=""
    for a in "${candidates[@]}"; do
        if [ -f "$OUT_DIR/$a" ]; then
            ASSETS="$ASSETS $a"
        fi
    done
    ASSETS=$(echo "$ASSETS" | xargs)  # trim
fi

[ -n "$ASSETS" ] || fail "no tarballs found in $OUT_DIR matching $HASH"

log "REPO=$REPO, TAG=$TAG, OUT_DIR=$OUT_DIR"
log "uploading: $ASSETS"

# Create the release if missing.
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "creating release $TAG..."
    gh release create "$TAG" --repo "$REPO" \
        --title "OTP pre-built runtime $HASH" \
        --notes "Pre-built OTP for Android (aarch64 + arm32), iOS simulator (aarch64-apple-iossimulator), and iOS device (aarch64-apple-ios). OTP source commit: $HASH."
else
    log "release $TAG already exists; will replace existing assets..."
fi

# Delete any of the named assets that are already on the release.
existing=$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name' || true)
for a in $ASSETS; do
    if echo "$existing" | grep -qx "$a"; then
        log "deleting existing asset $a..."
        gh release delete-asset "$TAG" "$a" --repo "$REPO" --yes
    fi
done

# Upload all the asset paths.
upload_paths=""
for a in $ASSETS; do
    upload_paths="$upload_paths $OUT_DIR/$a"
done
log "uploading $upload_paths..."
gh release upload "$TAG" $upload_paths --repo "$REPO"

log "done. Verifying..."
gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[] | "\(.name) \(.size)"'

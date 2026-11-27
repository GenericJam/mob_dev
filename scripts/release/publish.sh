#!/usr/bin/env bash
# scripts/release/publish.sh
# Upload new assets to the GitHub release for this OTP hash. Mirrors
# Step 4 of build_release.md.
#
# Inputs (env or default):
#   HASH    — release tag hash (auto-detected from $OTP_SRC git)
#   OUT_DIR — where the tarballs were written (default: /tmp)
#   REPO    — GitHub repo (default: GenericJam/mob)
#   ASSETS  — space-separated list of tarball basenames to upload. Defaults
#             to all five if all exist; otherwise only the ones present.
#
# Behaviour:
#   - Creates the release `otp-$HASH` if it doesn't exist.
#   - Refuses (uploads nothing) if any asset is already on the release:
#     released mob_dev versions pin each asset's sha256, so an asset is never
#     replaced. A rebuilt runtime gets a new HASH (build_release.md, Step 1;
#     decisions/2026-11-26-pinned-runtime-downloads.md).
#   - Uploads everything in one `gh release upload` call.
#   - Prints the MobDev.Download.Pins entries to paste into
#     lib/mob_dev/download/pins.ex.

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
        "otp-android-x86_64-$HASH.tar.gz"
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
        --notes "Pre-built OTP for Android (aarch64, arm32, x86_64), iOS simulator (aarch64-apple-iossimulator), and iOS device (aarch64-apple-ios). OTP source commit: $HASH."
else
    log "release $TAG already exists; adding assets..."
fi

# Published assets are immutable: refuse if any is already there.
existing=$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name')
for a in $ASSETS; do
    if echo "$existing" | grep -qx "$a"; then
        fail "$a is already on $TAG. Published assets are never replaced (released mob_dev versions pin their sha256); publish the rebuild under a new HASH."
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

log "pin in lib/mob_dev/download/pins.ex:"
for a in $ASSETS; do
    sha=$(shasum -a 256 "$OUT_DIR/$a" | awk '{print $1}')
    printf '    "https://github.com/%s/releases/download/%s/%s" =>\n      "%s",\n' "$REPO" "$TAG" "$a" "$sha"
done

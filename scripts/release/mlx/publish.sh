#!/usr/bin/env bash
# scripts/release/mlx/publish.sh
# Upload the cross-compiled MLX tarballs to a GitHub release so
# MobDev.MLXDownloader can fetch them at `mix mob.deploy --native` time.
#
# Requires:
#   * `gh` CLI installed and authenticated against the GenericJam/mob repo
#     (`gh auth status`).
#   * Tarballs already built by all_ios.sh (or the per-target scripts).
#
# Inputs (env):
#   MLX_VERSION   — defaults to the value in _lib.sh (0.25.1)
#   OUT_DIR       — where the tarballs live (default: /tmp)
#   GH_REPO       — repo to publish into (default: GenericJam/mob)
#   DRY_RUN       — non-empty to print what would happen without uploading
#
# Tarballs uploaded (must match MobDev.MLXDownloader.@release_tag /
# @base_url):
#   - libmlx-<ver>-ios-device.tar.gz
#   - libmlx-<ver>-ios-sim.tar.gz
#
# After uploading, bump MobDev.MLXDownloader.@mlx_version (and
# scripts/release/mlx/_lib.sh) in lockstep if this is a new MLX version.
# Existing apps' `mix mob.deploy --native` will re-download into
# ~/.mob/cache/libmlx-<new-ver>-ios-<slice>/ automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source ./_lib.sh

: "${GH_REPO:=GenericJam/mob}"
: "${DRY_RUN:=}"

TAG="mlx-${MLX_VERSION}"
TITLE="MLX ${MLX_VERSION} for Mob iOS"
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT

# Sanity: gh CLI present + authenticated.
command -v gh >/dev/null 2>&1 || fail "gh CLI not found — install via 'brew install gh' and run 'gh auth login'."
gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated — run 'gh auth login' first."

ASSETS=(
    "$OUT_DIR/libmlx-${MLX_VERSION}-ios-device.tar.gz"
    "$OUT_DIR/libmlx-${MLX_VERSION}-ios-sim.tar.gz"
)

# Verify all assets exist before we touch the release.
for asset in "${ASSETS[@]}"; do
    [ -f "$asset" ] || fail "missing $asset — run all_ios.sh (or the per-target ios_{device,sim}.sh + tarball_mlx_*.sh) first"
done

# Build release notes from the VERSION files inside the tarballs. Captures
# variant + MLX upstream version + iOS deployment target in one place.
cat > "$NOTES_FILE" <<EOF
Pre-built MLX + EMLX static archives for Mob iOS.

Consumed by MobDev.MLXDownloader at \`mix mob.deploy --native\` time when a
project depends on \`:emlx\`. The downloader extracts the tarball to
\`~/.mob/cache/libmlx-${MLX_VERSION}-ios-<slice>/\`; the iOS build script
then links \`libmlx.a\` + \`libemlx.a\` statically into the app binary.

## Artifacts

| Slice | File | Platform tag | Variant |
|---|---|---|---|
| iOS device | libmlx-${MLX_VERSION}-ios-device.tar.gz | platform=2 (iOS arm64) | CPU + Accelerate |
| iOS simulator | libmlx-${MLX_VERSION}-ios-sim.tar.gz | platform=7 (iOSSimulator arm64) | CPU + Accelerate |

## Build provenance

- MLX upstream: https://github.com/ml-explore/mlx tag v${MLX_VERSION}
- EMLX upstream: ~/code/test_emlx/deps/emlx (Hex 0.2.x)
- Mob iOS deployment target: ${IOS_DEPLOYMENT_TARGET:-17.0}
- Built with: scripts/release/mlx/all_ios.sh

## Checksums

\`\`\`
$(for asset in "${ASSETS[@]}"; do
    hash=$(shasum -a 256 "$asset" | awk '{print $1}')
    name=$(basename "$asset")
    echo "$hash  $name"
done)
\`\`\`
EOF

log "tag: $TAG"
log "repo: $GH_REPO"
log "title: $TITLE"
log "assets:"
for asset in "${ASSETS[@]}"; do log "  - $asset ($(du -h "$asset" | awk '{print $1}'))"; done

if [ -n "$DRY_RUN" ]; then
    log "DRY_RUN set — would create release + upload assets; exiting."
    log "Release notes preview:"
    cat "$NOTES_FILE"
    exit 0
fi

# Create the release if it doesn't exist, otherwise just upload assets.
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    log "release $TAG already exists — uploading (clobbering existing assets)"
    gh release upload "$TAG" "${ASSETS[@]}" --repo "$GH_REPO" --clobber
else
    log "creating release $TAG"
    gh release create "$TAG" "${ASSETS[@]}" \
        --repo "$GH_REPO" \
        --title "$TITLE" \
        --notes-file "$NOTES_FILE"
fi

log "release URL: $(gh release view "$TAG" --repo "$GH_REPO" --json url --jq .url)"
log "MobDev.MLXDownloader will now fetch from this release on next 'mix mob.deploy --native'."

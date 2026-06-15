#!/usr/bin/env bash
# Rebuild ONE devcontainer image variant from upstream source and push it to GHCR.
#
# Why from source: pulling/copying the published image from MCR 429s on GitHub's
# shared runner IPs. Instead we build the exact upstream recipe ourselves so we
# never touch MCR. The result is *functionally identical* to MCR's image — same
# upstream Dockerfile, same devcontainer features at the same locked digests,
# same Docker Hub `node` base — but not byte/digest identical (apt patches and
# build timestamps differ, as they would in any rebuild, including upstream's).
#
# The only edits to the upstream Dockerfile (your "update the Dockerfiles" step):
#   * pin the VARIANT build arg to the one we're building, and
#   * retarget the base FROM away from MCR (see FROM_KIND below).
#
# Usage: scripts/build-image.sh <src-dir> <variant> <ghcr-name> <from-kind>
#   e.g. scripts/build-image.sh javascript-node 24-trixie devcontainer-javascript-node dockerhub-node
#
# Required env: OWNER (GHCR org/owner). Optional: PLATFORMS (default amd64+arm64).
set -euo pipefail

SRC="${1:?src dir}"          # upstream src/<dir>, e.g. javascript-node
VARIANT="${2:?variant}"      # e.g. 24-trixie
NAME="${3:?ghcr name}"       # e.g. devcontainer-javascript-node
FROM_KIND="${4:?from kind}"  # dockerhub-node | javascript-node

OWNER="${OWNER:?set OWNER to the GHCR owner/org}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

CFG="chain.json"
BASE_MIRROR="$(jq -r .baseMirror "$CFG")"
UP_REPO="$(jq -r .upstream.repo "$CFG")"
UP_SHA="$(jq -r .upstream.sha "$CFG")"
DEST="ghcr.io/${OWNER}/${NAME}"
# Build-date suffix for a pinnable/rollbackable tag. Passed in by CI for
# reproducibility across a run; falls back to today if unset.
DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Fetch just the pinned upstream commit (no full history).
git -C "$work" init -q
git -C "$work" remote add origin "https://github.com/${UP_REPO}.git"
git -C "$work" -c protocol.version=2 fetch -q --depth 1 origin "$UP_SHA"
git -C "$work" checkout -q FETCH_HEAD

ctx="$work/src/$SRC/.devcontainer"
df="$ctx/Dockerfile"
[ -f "$df" ] || { echo "::error::no Dockerfile at $df"; exit 1; }

# (1) Pin the variant: replace the ARG VARIANT default.
sed -i -E "s|^ARG VARIANT=.*|ARG VARIANT=${VARIANT}|" "$df"

# (2) Retarget the base FROM so the build never reaches MCR.
case "$FROM_KIND" in
  dockerhub-node)
    # FROM node:<variant>  ->  FROM mirror.gcr.io/library/node:<variant>
    # (pull-through cache of Docker Hub: identical digests, no rate limit)
    sed -i -E "s|^FROM[[:space:]]+node:|FROM ${BASE_MIRROR}/node:|" "$df"
    ;;
  javascript-node)
    # FROM mcr.microsoft.com/devcontainers/javascript-node:4-${VARIANT}
    #   ->  FROM ghcr.io/<owner>/devcontainer-javascript-node:${VARIANT}  (our build)
    sed -i -E "s|^FROM[[:space:]]+mcr\.microsoft\.com/devcontainers/javascript-node:4-\\\$\{VARIANT\}|FROM ghcr.io/${OWNER}/devcontainer-javascript-node:\${VARIANT}|" "$df"
    ;;
  *)
    echo "::error::unknown FROM_KIND '$FROM_KIND'"; exit 2 ;;
esac

# Fail loudly if any MCR reference slipped through the patch.
if grep -qi "mcr.microsoft.com" "$df"; then
  echo "::error::Dockerfile still references MCR after patching:"; grep -n "mcr.microsoft.com" "$df"; exit 3
fi

echo "::group::Patched $SRC Dockerfile for $VARIANT"; cat "$df"; echo "::endgroup::"

# Build with the devcontainer CLI so the locked features (common-utils, node,
# git) are applied exactly as upstream does, then push the multi-arch image.
npx -y @devcontainers/cli@latest build \
  --workspace-folder "$work/src/$SRC" \
  --platform "$PLATFORMS" \
  --push \
  --image-name "${DEST}:${VARIANT}"

# Add the dated tag and any floating aliases as GHCR->GHCR manifest copies
# (no upstream pulls, preserves multi-arch).
add_tag() { docker buildx imagetools create --tag "${DEST}:$1" "${DEST}:${VARIANT}"; }

echo "tagging ${DEST}:${VARIANT}-${DATE}"
add_tag "${VARIANT}-${DATE}"

for key in $(jq -r --arg v "$VARIANT" '.aliases | to_entries[] | select(.value==$v) | .key' "$CFG"); do
  echo "alias ${DEST}:${key} -> ${VARIANT}"
  add_tag "$key"
done

echo "done: ${DEST}:${VARIANT} (+date, +aliases)"

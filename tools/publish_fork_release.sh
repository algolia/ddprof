#!/bin/bash

# Publish a release on the algolia/ddprof fork.
# Run after build_release.sh has produced artifacts for one or both arches.
#
# Usage: ./tools/publish_fork_release.sh [BUILD_REV] [--draft]
#
# BUILD_REV must match what was passed to build_release.sh (default: algolia.1).
# Uploads all artifacts found in deliverables/ that match the version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DELIVERABLES="$REPO_DIR/deliverables"
FORK_REPO="algolia/ddprof"

BUILD_REV="algolia.1"
DRAFT_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT_FLAG="--draft" ;;
    *)       BUILD_REV="$arg" ;;
  esac
done

# Extract base version and build full version string
BASE_VERSION=$(grep -oP 'VERSION \K[0-9]+\.[0-9]+\.[0-9]+' "$REPO_DIR/CMakeLists.txt" | head -1)
VERSION="${BASE_VERSION}-${BUILD_REV}"
TAG="v${VERSION}"

# Collect all artifacts matching this version
ARTIFACTS=()
for arch in amd64 arm64; do
  tarball="$DELIVERABLES/ddprof-${VERSION}-${arch}-linux.tar.xz"
  binary="$DELIVERABLES/ddprof-${arch}"
  [ -f "$tarball" ] && ARTIFACTS+=("$tarball")
  [ -f "$binary" ] && ARTIFACTS+=("$binary")
done

checksums="$DELIVERABLES/sha256sum.txt"
[ -f "$checksums" ] && ARTIFACTS+=("$checksums")

if [ ${#ARTIFACTS[@]} -eq 0 ]; then
  echo "ERROR: no artifacts found in $DELIVERABLES for version $VERSION"
  echo "Run build_release.sh ${BUILD_REV} first"
  exit 1
fi

echo "Publishing ${TAG} to ${FORK_REPO} with ${#ARTIFACTS[@]} artifacts..."
printf "  %s\n" "${ARTIFACTS[@]}"

COMMIT=$(git rev-parse --short HEAD)

NOTES="$(cat <<EOF
Fork release based on upstream main at commit ${COMMIT}.

Upstream base version: v${BASE_VERSION}

Includes all upstream fixes up to $(git log --oneline upstream/main -1).

Artifacts built from Alpine (musl, static). Binaries run on both glibc and musl hosts.
EOF
)"

gh release create "$TAG" \
  --repo "$FORK_REPO" \
  --title "ddprof ${TAG} (algolia)" \
  --notes "$NOTES" \
  $DRAFT_FLAG \
  "${ARTIFACTS[@]}"

echo ""
echo "Release published: https://github.com/${FORK_REPO}/releases/tag/${TAG}"

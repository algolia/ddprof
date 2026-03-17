#!/bin/bash

# Build and optionally publish a full release (amd64 + arm64).
#
# Usage:
#   ./tools/make_release.sh                    # build both arches
#   ./tools/make_release.sh --publish          # build + publish draft
#   ./tools/make_release.sh --publish --final  # build + publish (not draft)
#   ./tools/make_release.sh algolia.2          # custom BUILD_REV
#
# Requires:
#   - Docker with buildx multi-platform support (for arm64 cross-build)
#   - gh CLI (for --publish)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_REV="algolia.1"
PUBLISH=false
DRAFT="--draft"

for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=true ;;
    --final)   DRAFT="" ;;
    --help|-h)
      sed -n '3,12s/^# //p' "$0"
      exit 0
      ;;
    *)         BUILD_REV="$arg" ;;
  esac
done

echo "=== Building amd64 ==="
"$SCRIPT_DIR/build_release.sh" "$BUILD_REV" amd64

echo ""
echo "=== Building arm64 (cross-compile via QEMU, this will be slow) ==="
"$SCRIPT_DIR/build_release.sh" "$BUILD_REV" arm64

if $PUBLISH; then
  echo ""
  echo "=== Publishing release ==="
  "$SCRIPT_DIR/publish_fork_release.sh" "$BUILD_REV" $DRAFT
fi

echo ""
echo "Done."

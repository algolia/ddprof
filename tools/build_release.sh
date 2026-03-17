#!/bin/bash

# Build a release tarball from the Alpine Docker environment.
#
# Usage:
#   ./tools/build_release.sh [BUILD_REV] [ARCH]
#
# BUILD_REV  defaults to "algolia.1". Baked into version.txt as 0.23.0+algolia.1.
# ARCH       defaults to host arch. Pass "arm64" or "amd64" to cross-compile
#            (requires docker buildx with multi-platform support).
#
# Cross-compiled builds skip jemalloc and use the standard allocator because
# GCC segfaults under QEMU aarch64 user-mode emulation (QEMU #1913).
# They also retry make on segfaults (incremental).
#
# Produces:
#   deliverables/ddprof-<version>-<arch>-linux.tar.xz
#   deliverables/ddprof-<arch>    (bare static binary)
#   deliverables/sha256sum.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$REPO_DIR/app/release-env-alpine/Dockerfile"
DOCKER_IMAGE="ddprof-alpine-release"
DELIVERABLES="$REPO_DIR/deliverables"

BUILD_REV="${1:-algolia.1}"
TARGET_ARCH="${2:-}"

# Resolve architecture and detect cross-compilation
HOST_ARCH=$(uname -m)
if [ -z "$TARGET_ARCH" ]; then
  case "$HOST_ARCH" in
    x86_64)  TARGET_ARCH="amd64" ;;
    aarch64) TARGET_ARCH="arm64" ;;
    *)       echo "ERROR: unsupported architecture $HOST_ARCH"; exit 1 ;;
  esac
fi

case "$TARGET_ARCH" in
  amd64) DOCKER_PLATFORM="linux/amd64"; HOST_MATCH="x86_64" ;;
  arm64) DOCKER_PLATFORM="linux/arm64"; HOST_MATCH="aarch64" ;;
  *)     echo "ERROR: unsupported target arch $TARGET_ARCH (use amd64 or arm64)"; exit 1 ;;
esac

CROSS_COMPILING=false
if [ "$HOST_ARCH" != "$HOST_MATCH" ]; then
  CROSS_COMPILING=true
fi

# Extract base version from CMakeLists.txt
BASE_VERSION=$(grep -oP 'VERSION \K[0-9]+\.[0-9]+\.[0-9]+' "$REPO_DIR/CMakeLists.txt" | head -1)
if [ -z "$BASE_VERSION" ]; then
  echo "ERROR: could not extract version from CMakeLists.txt"
  exit 1
fi
VERSION="${BASE_VERSION}-${BUILD_REV}"

ALLOCATOR_OPT=""
BUILD_JEMALLOC="true"
if $CROSS_COMPILING; then
  echo "Cross-compiling for ${TARGET_ARCH} (host: ${HOST_ARCH})"
  echo "  Skipping jemalloc (GCC crashes under QEMU)"
  echo "  Using retry loop for make (QEMU segfaults are transient)"
  ALLOCATOR_OPT="-DDDPROF_ALLOCATOR=STANDARD"
  BUILD_JEMALLOC="false"
fi
echo "Building ddprof v${VERSION} for ${TARGET_ARCH}"

# Build the Docker image
IMAGE_TAG="${DOCKER_IMAGE}:${TARGET_ARCH}"
echo "Building Alpine Docker image for ${DOCKER_PLATFORM}..."
docker buildx build \
  --platform "$DOCKER_PLATFORM" \
  --build-arg BUILD_JEMALLOC="$BUILD_JEMALLOC" \
  --load \
  -t "$IMAGE_TAG" \
  -f "$DOCKERFILE" \
  "$REPO_DIR"

# Determine vendor extension for cross builds
if $CROSS_COMPILING; then
  VENDOR_EXT="_gcc_alpine-linux-${TARGET_ARCH}_Release"
else
  VENDOR_EXT=""
fi

# Clean previous deliverables for this arch
rm -rf "$DELIVERABLES/ddprof"

echo "Running release build inside container (${DOCKER_PLATFORM})..."
docker run --rm \
  --platform "$DOCKER_PLATFORM" \
  -v "$REPO_DIR:/app" \
  -w /app \
  -u "$(id -u):$(id -g)" \
  -e BUILD_REV="$BUILD_REV" \
  -e ALLOCATOR_OPT="$ALLOCATOR_OPT" \
  -e VENDOR_EXT="$VENDOR_EXT" \
  -e CROSS_COMPILING="$CROSS_COMPILING" \
  "$IMAGE_TAG" \
  bash -c '
    set -euo pipefail
    MAX_RETRIES=200

    retry_make() {
      local target="$1"
      local attempt=0
      while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        echo "--- $target attempt $attempt ---"
        if make -j1 "$target" 2>&1; then
          echo "$target succeeded on attempt $attempt"
          return 0
        fi
        if [ "$CROSS_COMPILING" != "true" ]; then
          echo "ERROR: $target failed (not cross-compiling, no retry)"
          return 1
        fi
        echo "  (QEMU segfault, retrying...)"
      done
      echo "ERROR: $target failed after $MAX_RETRIES attempts"
      return 1
    }

    #
    # Phase 1: elfutils (cross-compile needs retry due to QEMU segfaults)
    #
    if [ "$CROSS_COMPILING" = "true" ] && [ -n "$VENDOR_EXT" ]; then
      ELFDIR="/app/vendor${VENDOR_EXT}/elfutils-0.194"
      if [ -f "$ELFDIR/lib/libdw.a" ] && [ -f "$ELFDIR/lib/libelf.a" ]; then
        echo "elfutils already built, skipping"
      else
        echo "=== Building elfutils (cross-compile with retry) ==="
        mkdir -p "$ELFDIR"
        cd "$ELFDIR"

        TAR_ELF="elfutils-0.194.tar.bz2"
        [ -f "$TAR_ELF" ] || curl -fsSL -o "$TAR_ELF" \
          "https://sourceware.org/elfutils/ftp/0.194/$TAR_ELF"

        if [ ! -f "src/configure" ]; then
          rm -rf src
          mkdir src
          cd src
          tar --no-same-owner --strip-components 1 -xf "../$TAR_ELF"
          patch -p1 < /app/tools/elfutils.patch
          MUSL_LIBC=$(ldd /bin/ls 2>&1 | grep musl || true)
          if [ -n "$MUSL_LIBC" ]; then
            mkdir -p "$ELFDIR/lib"
            cp /patch/libintl.h "$ELFDIR/lib/"
            for p in /patch/*.patch; do
              [ -f "$p" ] && patch -N -p1 < "$p" || true
            done
          fi
          cd "$ELFDIR"
        fi

        cd "$ELFDIR/src"
        if [ ! -f Makefile ]; then
          CFLAGS="-g -O2 -Wno-error=builtin-macro-redefined" \
            ./configure CC=gcc \
            --with-zlib --with-bzlib --with-lzma --with-zstd \
            --disable-debuginfod --disable-libdebuginfod \
            --disable-symbol-versioning \
            --prefix "$ELFDIR"
        fi

        retry_make install

        if [ ! -f "$ELFDIR/lib/libdw.a" ]; then
          echo "ERROR: elfutils build failed"
          exit 1
        fi
        echo "elfutils OK"
      fi
    fi

    #
    # Phase 2: ddprof
    #
    echo "=== Building ddprof ==="
    cd /app
    source setup_env.sh
    MkBuildDir AlpRel-'"$TARGET_ARCH"'

    VENDOR_CMAKE_OPT=""
    [ -n "$VENDOR_EXT" ] && VENDOR_CMAKE_OPT="-DVENDOR_EXTENSION=$VENDOR_EXT"

    if [ ! -f Makefile ]; then
      RelCMake \
        -DBUILD_DDPROF_TESTING=OFF \
        -DBUILD_REV="$BUILD_REV" \
        $VENDOR_CMAKE_OPT \
        $ALLOCATOR_OPT \
        ../
    fi

    if [ "$CROSS_COMPILING" = "true" ]; then
      retry_make ddprof
    else
      make -j$(nproc) ddprof
    fi

    retry_make install
    echo "=== Build complete ==="
  '

# Package
mkdir -p "$DELIVERABLES"
TARBALL="ddprof-${VERSION}-${TARGET_ARCH}-linux.tar.xz"

echo "Packaging $TARBALL..."
cd "$DELIVERABLES"

if [ ! -d ddprof ]; then
  echo "ERROR: install directory 'deliverables/ddprof/' not found"
  exit 1
fi

tar cJf "$TARBALL" ddprof/
cp ddprof/bin/ddprof "ddprof-${TARGET_ARCH}"

sha256sum "$TARBALL" "ddprof-${TARGET_ARCH}" >> sha256sum.txt
sort -u -o sha256sum.txt sha256sum.txt

echo ""
echo "Release artifacts in $DELIVERABLES:"
ls -lh "$TARBALL" "ddprof-${TARGET_ARCH}"
echo ""
cat sha256sum.txt

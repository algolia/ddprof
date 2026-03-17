FROM alpine:3.22
ENV CC=gcc
ENV CXX=g++

# Stripped-down Alpine build environment for release builds only.
# Skips test/benchmark dependencies not needed for the ddprof binary.

ENV TAR_OPTIONS="--no-same-owner"

RUN apk update \
  && apk add --no-cache \
    argp-standalone \
    autoconf \
    automake \
    bash \
    binutils-dev \
    bison \
    bzip2-dev \
    bzip2-static \
    ca-certificates \
    cmake \
    cppcheck \
    coreutils \
    curl \
    flex \
    g++ \
    gcc \
    git \
    grep \
    libcap-dev \
    libcap-static \
    libunwind-dev \
    m4 \
    make \
    musl-fts-dev \
    musl-legacy-error \
    musl-libintl \
    musl-obstack-dev \
    patch \
    py3-pkgconfig \
    samurai \
    unzip \
    wget \
    xz-dev \
    xz-static \
    zlib-dev \
    zlib-static \
    zstd-dev \
    zstd-static

SHELL ["/bin/bash", "-c"]

# Patch to fix compilation of elfutils
RUN mkdir /patch
ADD ./app/base-env-alpine/*.patch /patch/
ADD ./app/base-env-alpine/error.h /patch/
ADD ./app/base-env-alpine/libintl.h /patch/
RUN chmod 644 /patch/*

# jemalloc — optional. Skipped for cross-compiled (QEMU) builds because
# GCC segfaults under QEMU aarch64 user-mode emulation regardless of
# optimization level or parallelism (QEMU #1913 and related regressions).
# The build script passes DDPROF_ALLOCATOR=STANDARD when cross-compiling.
ARG BUILD_JEMALLOC=true
RUN if [ "$BUILD_JEMALLOC" = "true" ]; then \
      VERSION="5.3.0" \
      && TAR_NAME="jemalloc-${VERSION}.tar.bz2" \
      && curl -fsSLO "https://github.com/jemalloc/jemalloc/releases/download/${VERSION}/jemalloc-${VERSION}.tar.bz2" \
      && SHA256="2db82d1e7119df3e71b7640219b6dfe84789bc0537983c3b7ac4f7189aecfeaa" \
      && (printf "${SHA256} ${TAR_NAME}" | sha256sum -c) \
      && tar xf "${TAR_NAME}" \
      && pushd "jemalloc-${VERSION}" \
      && ./configure --enable-experimental-smallocx --disable-doc \
      && make -j$(nproc) \
      && make install \
      && popd \
      && rm -rf "jemalloc-${VERSION}" "${TAR_NAME}" ; \
    else \
      echo "Skipping jemalloc (cross-compile mode)" ; \
    fi

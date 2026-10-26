# syntax=docker/dockerfile:1
# Builds Wine's httpapi.dll and http.sys (x86_64) with the patches from patches/.
# The result is an artifact image (FROM scratch) containing:
#   /httpapi.dll  /http.sys  /SHA256SUMS
# Usage and background: wine-httpapi/README.md

# The Wine version must match the Wine version in the server image exactly
# (httpapi.dll and http.sys talk to each other via internal IOCTLs).
ARG WINE_VERSION=11.0
ARG WINE_SOURCE_URL=https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz
ARG WINE_SHA256=c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701

FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS build
ARG WINE_VERSION
ARG WINE_SOURCE_URL
ARG WINE_SHA256
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bison ca-certificates curl flex gcc gcc-mingw-w64-x86-64 libc6-dev make patch xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSL -o wine.tar.xz "${WINE_SOURCE_URL}" \
 && echo "${WINE_SHA256}  wine.tar.xz" | sha256sum -c - \
 && tar -xJf wine.tar.xz \
 && rm wine.tar.xz

COPY patches/ /patches/
RUN for p in /patches/*.patch; do patch -d "wine-${WINE_VERSION}" -p1 < "$p"; done

# Build only the build tools and the two targets, not all of Wine
WORKDIR /build
RUN "/src/wine-${WINE_VERSION}/configure" -q --enable-win64 --enable-archs=x86_64 \
      --without-x --without-freetype --without-gnutls --without-unwind --disable-tests \
 && make -j"$(nproc)" dlls/httpapi/all dlls/http.sys/all

WORKDIR /out
RUN cp /build/dlls/httpapi/x86_64-windows/httpapi.dll /build/dlls/http.sys/x86_64-windows/http.sys . \
 && sha256sum httpapi.dll http.sys > SHA256SUMS

FROM scratch AS artifacts
COPY --from=build /out/ /

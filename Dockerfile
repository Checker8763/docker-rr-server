# syntax=docker/dockerfile:1
# RaceRoom Dedicated Server under Wine – how it works: docs/ARCHITECTURE.md
#
# Requires the build context "httpapi" with the patched Wine DLLs (wine-httpapi/).
# docker-compose.build.yml provides it automatically; for plain "docker build"
# see docs/BUILD.md.
#
# Targets (docs/BUILD.md#image-variants):
#   full    (default) Wine prefix with .NET Framework 4.8 baked in – for local builds
#   public  without .NET (must not be redistributed for non-Windows platforms); the
#           entrypoint installs it into the /data/wine volume on the first start

FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS base
# "base" is not a build target of its own (the scripts are only added in public/full)

# Wine from the official WineHQ packages. When changing the version, update
# wine-httpapi/ (WINE_VERSION) and, if needed, the patches as well.
ARG WINE_BRANCH=stable
# renovate: datasource=deb depName=winehq-stable registryUrl=https://dl.winehq.org/wine-builds/debian?suite=trixie&components=main&binaryArch=amd64
ARG WINE_PKG_VERSION=11.0.0.0~trixie-1
ARG WINEHQ_KEY_SHA256=d965d646defe94b3dfba6d5b4406900ac6c81065428bf9d9303ad7a72ee8d1b8
# renovate: datasource=github-tags depName=Winetricks/winetricks
ARG WINETRICKS_VERSION=20260125
ARG WINETRICKS_SHA256=431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b
# Optional checksum of the SteamCMD tarball (see the SteamCMD step)
ARG STEAMCMD_SHA256=
ARG UID=1000
ARG GID=1000
ARG WINE_ROOT=/opt/wine-${WINE_BRANCH}

LABEL org.opencontainers.image.title="docker-rr-server" \
      org.opencontainers.image.description="RaceRoom Dedicated Server (Steam app 354060) under Wine" \
      org.opencontainers.image.licenses="MIT AND LGPL-2.1-or-later" \
      org.opencontainers.image.base.name="debian:trixie-slim"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Runtime tools: tini (PID 1), Xvfb (display for the game instance), cabextract/unzip
# (winetricks dotnet48), python3 (webui_init.py, backup_settings.py), curl (health check, downloads),
# procps/iproute2 (diagnostics), lib32gcc-s1/lib32stdc++6 (SteamCMD is 32-bit),
# locales (en_US.UTF-8)
# The cache mounts need the apt cache kept, so Debian's docker-clean is removed
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tini xvfb cabextract unzip python3 procps iproute2 \
      lib32gcc-s1 lib32stdc++6 locales \
 && sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen
# SteamCMD expects en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Wine from WineHQ (pinned version, key verified by checksum). No recommends; only the
# libraries a headless server needs: gnutls (TLS to the RaceRoom backend),
# freetype/fontconfig (fonts), X11 extensions (game instance under Xvfb).
# hadolint ignore=DL3008
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    dpkg --add-architecture i386 \
 && install -d /etc/apt/keyrings \
 && curl -fsSL -o /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && echo "${WINEHQ_KEY_SHA256}  /etc/apt/keyrings/winehq-archive.key" | sha256sum -c - \
 && printf '%s\n' \
      'Types: deb' \
      'URIs: https://dl.winehq.org/wine-builds/debian' \
      'Suites: trixie' \
      'Components: main' \
      'Architectures: amd64 i386' \
      'Signed-By: /etc/apt/keyrings/winehq-archive.key' \
      > /etc/apt/sources.list.d/winehq-trixie.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "winehq-${WINE_BRANCH}=${WINE_PKG_VERSION}" \
      "wine-${WINE_BRANCH}=${WINE_PKG_VERSION}" \
      "wine-${WINE_BRANCH}-amd64=${WINE_PKG_VERSION}" \
      "wine-${WINE_BRANCH}-i386:i386=${WINE_PKG_VERSION}" \
      libgnutls30 libfreetype6 libfontconfig1 fonts-liberation \
      libxcomposite1 libxcursor1 libxfixes3 libxi6 libxinerama1 libxrandr2 libxrender1

# winetricks, pinned by release tag and checksum
RUN curl -fsSL -o /usr/local/bin/winetricks \
      "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_VERSION}/src/winetricks" \
 && echo "${WINETRICKS_SHA256}  /usr/local/bin/winetricks" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/winetricks

# Patched Wine builtins (see wine-httpapi/README.md); verify the artifact's checksums
WORKDIR /tmp/httpapi
# "httpapi" is a named build context (additional_contexts), not a stage of this file
# hadolint ignore=DL3022
COPY --from=httpapi /httpapi.dll /http.sys /SHA256SUMS ./
RUN sha256sum -c SHA256SUMS \
 && install -m 0644 httpapi.dll http.sys "${WINE_ROOT}/lib/wine/x86_64-windows/" \
 && rm -rf /tmp/httpapi
WORKDIR /

# Unprivileged server user; /tmp/.X11-unix so that Xvfb can run as non-root
RUN groupadd -g "${GID}" rr \
 && useradd -l -m -u "${UID}" -g "${GID}" -d /home/rr -s /bin/bash rr \
 && mkdir -p /opt/steamcmd /data/raceroom /data/appdata /data/userdata /data/wine \
 && install -d -m 1777 /tmp/.X11-unix \
 && chown -R rr:rr /opt/steamcmd /data

USER rr
ENV HOME=/home/rr \
    USER=rr \
    WINEPREFIX=/home/rr/.wine \
    WINEDLLOVERRIDES="mshtml=;winedbg.exe=d" \
    WINEDEBUG=-all \
    DISPLAY=:0 \
    SERVER_DIR=/data/raceroom \
    APPDATA_DIR=/data/appdata \
    USERDATA_DIR=/data/userdata \
    STEAMCMD_DIR=/opt/steamcmd

# SteamCMD, including its self-update at build time so the first start is faster.
# Deliberately not verified by default: Valve replaces the tarball without versioning,
# so a pinned checksum would break the build without notice. Set STEAMCMD_SHA256 to check it.
RUN curl -fsSL -o /tmp/steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
 && if [ -n "${STEAMCMD_SHA256}" ]; then echo "${STEAMCMD_SHA256}  /tmp/steamcmd.tar.gz" | sha256sum -c -; fi \
 && tar -xzf /tmp/steamcmd.tar.gz -C "${STEAMCMD_DIR}" \
 && rm /tmp/steamcmd.tar.gz \
 && "${STEAMCMD_DIR}/steamcmd.sh" +quit \
 && rm -rf "${HOME}/Steam/logs" "${HOME}/.steam/logs"

COPY --chown=rr:rr --chmod=0755 scripts/install-prefix.sh /opt/rr/
# Not under /data: Docker would create a missing WORKDIR in the volume as root
WORKDIR /home/rr

# --start-interval needs Docker Engine 25 or newer (older engines ignore it)
HEALTHCHECK --interval=30s --timeout=10s --start-period=30m --start-interval=5s --retries=3 \
    CMD ["/opt/rr/healthcheck.sh"]

# Web UI (TCP) and game ports of up to 5 instances, 3 per instance (UDP + TCP);
# publishing them is up to docker-compose.yml
EXPOSE 8088/tcp 60000-60014/tcp 60000-60014/udp

# tini without -g: signals only go to the entrypoint, which stops the manager gracefully
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/rr/entrypoint.sh"]


# --- public: no .NET in the image; prefix is created in the /data/wine volume -------
FROM base AS public
ENV WINEPREFIX=/data/wine/prefix
# The whole folder, so new scripts cannot be forgotten; tests and tools stay out (.dockerignore)
COPY --chown=rr:rr --chmod=0755 scripts/ /opt/rr/
# Last, so that changing them does not invalidate the layers above
ARG VERSION=dev
ARG REVISION=unknown
ARG SOURCE=unknown
LABEL org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"


# --- full: Wine prefix with .NET Framework 4.8 in a single layer ---------------------
FROM base AS full
ARG UID=1000
ARG GID=1000
# Created by rr: BuildKit would create the cache mount's parent folder as root
RUN mkdir -p "${HOME}/.cache"
# The winetricks downloads stay in a build cache; install-prefix.sh must not delete them
RUN --mount=type=cache,target=/home/rr/.cache/winetricks,uid=${UID},gid=${GID} \
    KEEP_WINETRICKS_CACHE=1 /opt/rr/install-prefix.sh \
 && find "${HOME}/.cache" -mindepth 1 -maxdepth 1 ! -name winetricks -exec rm -rf {} + \
 && rm -rf /tmp/.wine-*
# The whole folder, so new scripts cannot be forgotten; tests and tools stay out (.dockerignore)
COPY --chown=rr:rr --chmod=0755 scripts/ /opt/rr/
# Last, so that changing them does not invalidate the layers above
ARG VERSION=dev
ARG REVISION=unknown
ARG SOURCE=unknown
LABEL org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

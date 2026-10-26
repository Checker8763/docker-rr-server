# Build

## Overview
```
wine-httpapi/Dockerfile ──► docker-rr-server-httpapi:local  (httpapi.dll, http.sys, SHA256SUMS)
                                   │  build context "httpapi"
Dockerfile ────────────────────────┴──► docker-rr-server:local  (RR_IMAGE)
```
Build and runtime are separate:
- **`docker-compose.build.yml`** builds the named images in the right order (`additional_contexts: httpapi: service:wine-httpapi`) and starts nothing.
- **`docker-compose.yml`** and **`docker-compose.traefik.yml`** only contain `image:` and no build. That way they can be used unchanged in Docker managers such as Komodo or Portainer, on hosts that do not build themselves.

## Image variants
The Microsoft .NET Framework 4.8 may not be redistributed for platforms other than Windows (see [Licenses](../README.md#licenses)). The [Dockerfile](../Dockerfile) therefore has two targets:

| Target | .NET Framework 4.8 | Size | Use |
|---|---|---|---|
| `full` (default) | baked into the image (Wine prefix in `/home/rr/.wine`) | ~7.4 GB | Build it yourself: starts immediately |
| `public` | not included; installed into the `data/wine` volume on the first start after `ACCEPT_MICROSOFT_DOTNET_LICENSE=yes` (about 5–20 min, ~2.6 GB) | ~3.6 GB | Intended for a published image |

Both use the same entrypoint and the same installation script (`scripts/install-prefix.sh`). Don't publish images of the `full` target.

## Server image
```bash
docker compose -f docker-compose.build.yml build            # both images
docker compose -f docker-compose.build.yml build raceroom   # server image (builds the artifact if needed)
RR_IMAGE=registry.example.com/raceroom:1 docker compose -f docker-compose.build.yml build   # different name
RR_TARGET=public RR_IMAGE=docker-rr-server:public docker compose -f docker-compose.build.yml build raceroom   # variant without .NET
```
Without Compose:
```bash
docker build -t docker-rr-server-httpapi:local --target artifacts wine-httpapi
docker build -t docker-rr-server:local \
  --build-context httpapi=docker-image://docker-rr-server-httpapi:local .
```

Build arguments: `UID`/`GID` (from `PUID`/`PGID`), `WINE_BRANCH` (`stable`), `WINE_PKG_VERSION`, `WINEHQ_KEY_SHA256`, `WINETRICKS_VERSION`, `WINETRICKS_SHA256`, `STEAMCMD_SHA256` (optional; the SteamCMD tarball is unversioned and unchecked by default), `VERSION`/`REVISION`/`SOURCE` (OCI labels; Compose reads `RR_VERSION`, `RR_REVISION`, `RR_SOURCE`).

The build needs BuildKit (default in current Docker): apt packages and the winetricks downloads are kept in cache mounts, so rebuilds after a changed pin do not download everything again. The stage `base` is not a build target of its own (the scripts are only added in `public` and `full`). The `HEALTHCHECK` uses `--start-interval=5s`, which needs Docker Engine 25 or newer (older engines ignore it).

Steps in the [Dockerfile](../Dockerfile):
1. Base `debian:trixie-slim` (pinned by digest) + runtime tools (tini, Xvfb, cabextract, python3, locales, 32-bit libraries for SteamCMD)
2. Wine from the WineHQ packages (`WINE_PKG_VERSION`, key verified by SHA-256), without recommends; winetricks pinned by release tag and SHA-256
3. Patched `httpapi.dll`/`http.sys` from the artifact (checksums verified), copied over the Wine builtins
4. User `rr` (UID/GID), `/tmp/.X11-unix` so that Xvfb can run as non-root
5. SteamCMD in `/opt/steamcmd` (including its self-update)
6. Target `full`: Wine prefix with .NET Framework 4.8 (`scripts/install-prefix.sh`: `winetricks dotnet48`, 64-bit NGen queue compiled, NGen services disabled) **in a single layer**, caches removed; target `public` skips this
7. Scripts in `/opt/rr/`

## Building the patched Wine DLLs separately
See [wine-httpapi/README.md](../wine-httpapi/README.md). In short:
```bash
docker build --target artifacts --output type=local,dest=wine-httpapi/dist wine-httpapi
```
Using a pre-built artifact:
```bash
# from a directory
docker build --build-context httpapi=wine-httpapi/dist -t docker-rr-server:local .
# or from a registry
docker build --build-context httpapi=docker-image://registry.example.com/rr-wine-httpapi:11.0-p4 -t docker-rr-server:local .
```

## Exporting the image
```bash
scripts/export-image.sh [image]   # -> dist/<image>.tar.zst + .sha256
```
Loading: see [Deployment](DEPLOY.md#provide-the-image).

## Lint and tests
```bash
scripts/lint.sh   # hadolint (both Dockerfiles), shellcheck, ruff, the tests below, compose files valid + docker-compose.yml/docker-compose.traefik.yml in sync
```
Everything runs in containers. The tests need no Steam download and no RaceRoom server:

| Test | Checks |
|---|---|
| `scripts/test_backup_settings.py` | Backups are written with mode 600; nothing is written without servers or when only the time changed; only the newest `BACKUP_KEEP` files stay; a damaged file does not stop backups |
| `scripts/test_webui_init.py` | Against a fake manager: registers once with `REGISTER_PHRASE`, `AUTOSTART` starts only stopped servers, gives up without a phrase or without an answer |
| `scripts/test-preflight.sh` | The configuration checks: numbers, fixed choices, `WEBUI_USERS` format, writable volumes (runs as a normal user, because root may write everywhere) |
| `scripts/test-entrypoint.sh [image]` | The entrypoint in the built image, with a fake manager instead of Wine: start, `access` file with mode 600 and one line per login, no password in the log, `docker stop` sends Ctrl+C and ends with exit code 0, the watchdog ends a container with a hanging web UI with exit code 1, a wrong setting and missing server files stop the start with a clear message. Not part of `lint.sh` (needs a built image, takes about 2½ minutes) |

Run only the tests: `python3 -m unittest discover -s scripts -p 'test_*.py'` (Python 3.11+) and `docker run --rm --user 1000 -v "$PWD:/mnt:ro" -w /mnt bash:5.2 bash scripts/test-preflight.sh`; after a build `scripts/test-entrypoint.sh` (default image `docker-rr-server:local`). Tests and tools are not copied into the image (`.dockerignore`).

## Updating versions
[Renovate](https://docs.renovatebot.com/) (`renovate.json`) proposes updates for the base digest, `WINE_PKG_VERSION` and `WINETRICKS_VERSION` (the latter two via `# renovate:` comments in the Dockerfile; the config is untested until a Renovate instance runs). Its pull requests are not complete on their own: `WINETRICKS_SHA256` and `wine-httpapi/` (`WINE_VERSION`, patches) must be updated by hand, see below.

| What | Where | Note |
|---|---|---|
| Debian base | `FROM debian:trixie-slim@sha256:…` in the `Dockerfile` | `docker pull debian:trixie-slim` and enter the new digest |
| Wine | `WINE_PKG_VERSION` in the `Dockerfile` (Renovate: `renovate.json`, pins marked `# renovate:`) | Available versions: `apt-cache madison winehq-stable` (in a container with the WineHQ source). If the **Wine version** changes, `wine-httpapi` (`WINE_VERSION`, `WINE_SOURCE_URL`, `WINE_SHA256`) and possibly the patches must follow. |
| winetricks | `WINETRICKS_VERSION`, `WINETRICKS_SHA256` | Tags: `git ls-remote --tags https://github.com/Winetricks/winetricks`; checksum: `curl -fsSL <raw-url> \| sha256sum` |
| Wine source | `wine-httpapi/Dockerfile` (ARGs) | Check the patches with `patch --dry-run`, regenerate if needed (see wine-httpapi/README.md) |
| Build base of the DLLs | `FROM debian:trixie-slim@sha256:…` in `wine-httpapi/Dockerfile` | uncritical |
| .NET | `winetricks dotnet48` | Installer version comes from winetricks |
| Server (RaceRoom) | – | SteamCMD downloads it on every start (`UPDATE_ON_START`) |

Image size (`full`): about 7.4 GB – roughly 2.1 GB Wine (including ~0.7 GB of mandatory dependencies of the WineHQ packages such as LLVM, Mesa, ffmpeg) and ~2.9 GB Wine prefix with .NET (64- and 32-bit DLLs, ~0.5 GB of 64-bit native images from NGen). Dropping the 32-bit parts (~1.5 GB) would be a significant compatibility risk (the .NET installer is 32-bit).

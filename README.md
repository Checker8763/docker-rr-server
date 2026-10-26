# RaceRoom Dedicated Server in Docker

Runs the Windows-only [RaceRoom Racing Experience](https://store.steampowered.com/app/211500/) dedicated server (Steam app 354060) on Linux: Wine + .NET Framework 4.8 in a Docker container, bridge networking, unprivileged user. SteamCMD downloads the server files on start.

> **Status:** working – the server appears in the multiplayer list and players can join; sessions (practice → race) run and results are written with all drivers; graceful shutdown on stop. Tested on a public server with two players. Not affiliated with KW Studios / RaceRoom, use at your own risk.

## Requirements
- Linux x86_64 with Docker Engine and Docker Compose ≥ 2.24
- **A public IPv4** with inbound UDP 60000, TCP 60001, UDP 60002 – no CGNAT/DS-Lite (see [Deployment](docs/DEPLOY.md#network))
- A RaceRoom account (entered in the web UI)

## Quick start
```bash
git clone <repo-url> docker-rr-server && cd docker-rr-server
cp .env.example .env                              # set at least WEBUI_USERS
docker compose -f docker-compose.build.yml build  # build the images, first build takes about 10–15 min
                                                  #
docker compose up -d                              # start (no build)
docker compose logs -f                            # wait for "Starting frontend on http://*:8088/"
```
Then open the web UI at `http://<host>:8088/`, log in, enter your RaceRoom login, register with a phrase, create a server and start it. For unattended operation set `REGISTER_PHRASE` and `AUTOSTART=true` in `.env`.

## Documentation
| Topic | Content |
|---|---|
| [Configuration](docs/CONFIGURATION.md) | Environment variables, ports, volumes, multiple instances |
| [Deployment](docs/DEPLOY.md) | Target host, image as a tarball via rsync, Traefik, Komodo/Portainer, network/CGNAT |
| [Build](docs/BUILD.md) | Building the image, patched Wine DLLs, lint, updating versions |
| [Web UI API](docs/API.md) | HTTP API of the manager, all server settings and their values, backup format |
| [Architecture](docs/ARCHITECTURE.md) | How the manager, game instance, Wine and the patches fit together |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Known problems and solutions |
| [wine-httpapi](wine-httpapi/README.md) | The Wine patches for the .NET `HttpListener` |

## Project layout
```
Dockerfile                  server image (Wine, .NET 4.8, SteamCMD)
docker-compose.build.yml    build step: builds the named images
docker-compose.yml          runtime (image only, no build)
docker-compose.traefik.yml  runtime behind Traefik, self-contained (e.g. for Komodo)
.env.example                all variables with placeholders
scripts/                    entrypoint.sh, preflight.sh, install-prefix.sh, healthcheck.sh, webui_init.py, backup_settings.py,
                            export-image.sh, check-public-image.sh, lint.sh
wine-httpapi/               patches + Dockerfile for the patched Wine DLLs
data/                       volumes (not in git)
docs/                       documentation
```

## Licenses
- This project is licensed under the [MIT License](LICENSE).
- The Wine patches in [`wine-httpapi/patches/`](wine-httpapi/patches/) modify Wine source code and are licensed under the [GNU LGPL v2.1 or later](wine-httpapi/patches/LICENSE), like Wine.
- The repository contains no third-party binaries. Images contain third-party software under its own terms:
  - **Published image** (target `public`): Wine (LGPL-2.1-or-later, WineHQ packages for Debian; version in the [Dockerfile](Dockerfile)), the patched Wine DLLs (source in [`wine-httpapi/`](wine-httpapi/)), winetricks (LGPL), SteamCMD (Valve, [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/)) and Debian packages.
  - **Not included, downloaded by you on the first start:** the Microsoft **.NET Framework 4.8** (installed by winetricks from Microsoft; you accept Microsoft's license terms for it with `ACCEPT_MICROSOFT_DOTNET_LICENSE=yes`) and the RaceRoom Dedicated Server (KW Studios, via SteamCMD).
  - A self-built image of the default target `full` contains the .NET Framework. Microsoft's terms do not allow redistributing it for non-Windows platforms, so don't publish such images. See [image variants](docs/BUILD.md#image-variants).

## Disclaimer
This is an unofficial community project. It is not affiliated with, endorsed by or supported by KW Studios, RaceRoom, Valve or Microsoft. "RaceRoom" and related names are trademarks of their respective owners. Use at your own risk.

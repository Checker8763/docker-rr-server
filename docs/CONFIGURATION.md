# Configuration

All settings come from `.env` (template: [`.env.example`](../.env.example)). `.env` is not committed.

## Environment variables
| Variable | Default | Meaning |
|---|---|---|
| `WEBUI_USERS` | – | Web UI logins (HTTP basic auth), `user:pass[,user2:pass2]`. The entrypoint writes them to the `access` file next to the server executable (mode 600). **Without an entry the web UI only listens on `localhost` inside the container.** Left empty, an existing `access` file is kept. |
| `REGISTER_PHRASE` | – | Phrase from the web UI's registration dialog ("unique phrase to differentiate yourself…"). If set, the container registers with the RaceRoom backend on every start, because the manager forgets its registration on every restart. |
| `WEBUI_WATCHDOG_MINUTES` | `5` | Restart the container when the web UI answered once and then stays silent for this many minutes (the manager hangs; seen once under load). The container exits with code 1 and the restart policy starts it again; running races end. `0` = off. |
| `BACKUP_HOURS` | `24` | Save the manager's backup (all servers with settings, welcome messages, ballast, …) to `data/backups/servers-<date>.json` every this many hours, first one shortly after the manager is registered. A file is only written when something changed and the manager reports at least one server, so after an IP change the good backups are not replaced by empty ones. Restore with the import in the web UI. `0` = off. |
| `BACKUP_KEEP` | `14` | Number of backup files kept; older ones are deleted. |
| `AUTOSTART` | `false` | `true`: start all configured servers after the container starts. Requires a registration (`REGISTER_PHRASE` or manual). |
| `UPDATE_ON_START` | `true` | Check/update the server files with SteamCMD on every start. |
| `STEAMCMD_RETRIES` | `5` | Attempts for the SteamCMD update. Success = `Success!`, a complete installation in `steamapps/appmanifest_354060.acf` (`"StateFlags" "4"`) **and** the executable exists. If all attempts fail, the server starts with the existing installation; without one, the start is aborted (Docker restarts the container). |
| `STEAMCMD_RETRY_DELAY` | `10` | Pause between attempts (seconds). |
| `STEAM_USER` / `STEAM_PASS` | – | Only needed if the anonymous download fails. |
| `ACCEPT_MICROSOFT_DOTNET_LICENSE` | – | **Published image only:** `yes` accepts the license terms of the Microsoft .NET Framework 4.8, which the first start downloads from Microsoft and installs into `data/wine` (see [image variants](BUILD.md#image-variants)). Without it that image aborts at start. Not needed for a self-built image (target `full`). |
| `RR_IMAGE` | `docker-rr-server:local` | Image name created by the build step and started by the compose files (also for a tarball or registry image, e.g. `ghcr.io/<owner>/<repo>:latest`). |
| `RR_PULL_POLICY` | `missing` | `pull_policy` of the service. `missing` only pulls if the image is not present locally, so it works with locally built or loaded images. Use `always` for a registry image with updates. |
| `RR_DATA_DIR` | `./data` | Data directory, mounted on `/data`; the subdirectories are created on start. Use an **absolute** path with Docker managers (Komodo, Portainer). |
| `PUID` / `PGID` | `1000` | Build step only: UID/GID of the server user in the image. Must own `RR_DATA_DIR`. |
| `RR_TARGET` | `full` | Build step only: `full` (.NET baked in) or `public` (without .NET, as published). See [image variants](BUILD.md#image-variants). |
| `RR_HTTPAPI_IMAGE` | `docker-rr-server-httpapi:local` | Build step only: name of the DLL artifact image. |
| `TRAEFIK_*` | see [Deployment](DEPLOY.md#behind-traefik) | Only for `docker-compose.traefik.yml`. |

Internals (normally left alone): in the image `WINEPREFIX=/home/rr/.wine` (`public`: `/data/wine/prefix`), `APPDATA_DIR=/data/appdata`, `USERDATA_DIR=/data/userdata`, `WINEDEBUG=-all`, `WINEDLLOVERRIDES=mshtml=;winedbg.exe=d`, `SERVER_DIR=/data/raceroom`, `STEAMCMD_DIR=/opt/steamcmd`; in the entrypoint `STOP_TIMEOUT=20` (seconds before a hard kill); in `webui_init.py` `WEBUI_INIT_TIMEOUT=300`.

All values are validated at start (see [Troubleshooting](TROUBLESHOOTING.md)).

## Ports
Always map host and container ports **identically**: the manager reports its ports to the RaceRoom backend.

| Port | Protocol | Purpose |
|---|---|---|
| 60000 | UDP | Game instance 1: connection |
| 60001 | TCP | Game instance 1: data |
| 60002 | UDP | Game instance 1: ping/time sync |
| 8088 | TCP | Web UI (manager) |

The ports cannot be configured: the manager picks them itself, starting at 60000.

### Multiple instances
Each additional instance uses the next block of three (60003–60005, 60006–60008, …). The registration reports the quota per IP (`allowed 5 dedicated instance`): at most 5 servers can **run** at the same time (any number can be configured; a sixth start is refused). The compose files therefore map the blocks for all five instances, 60000–60014, for both TCP **and** UDP. Unused ports are harmless; forward only the blocks you use on the router/firewall.

| Instance | UDP | TCP | UDP |
|---|---|---|---|
| 1 | 60000 | 60001 | 60002 |
| 2 | 60003 | 60004 | 60005 |
| 3 | 60006 | 60007 | 60008 |
| 4 | 60009 | 60010 | 60011 |
| 5 | 60012 | 60013 | 60014 |

**Resources:** measured on a target server (`cpus: 1.0`, `docker stats`, manager included), one running instance:

| Players | CPU (share of one core) | RAM |
|---|---|---|
| 4 | about 30 % | 333 MB |
| 16 | 30–40 % | 350 MB |

Memory hardly depends on the number of players, CPU only a little. How much each additional running instance adds is not measured yet; as a rough guess, give the container about one core per two to three busy servers and some 300 MB per server, e.g. `cpus: 2.0` and `mem_limit: 2g` for up to 5 servers.

Each instance is a server configured in the web UI. All server settings (track rotation, sessions, rules, driving aids) are listed in [Web UI API › Settings reference](API.md#settings-reference); they can also be scripted through the API.

## Volumes
One bind mount: `RR_DATA_DIR` (default `./data`) on `/data`. The entrypoint creates the subdirectories on start:

| Host | Container | Content |
|---|---|---|
| `./data/raceroom` | `/data/raceroom` | Server installation (SteamCMD), `access` file |
| `./data/appdata` | `/data/appdata` (= `%LOCALAPPDATA%\Sector3_Studios_AB`) | `settings.bin`/`iv.bin` (RaceRoom login, encrypted), `data.db` (server configuration), `logs/output.log` (manager log), `bin/` (game instance, unpacked on every start) |
| `./data/userdata` | `/data/userdata` (= `Documents\My Games\SimBin\RaceRoom Dedicated`) | **Results** `UserData/Log_Dedicated/Results/Port_<port>_<date>_<session>.txt` (JSON content), game instance logs (encrypted), `ReplayData/`, `sentry-errors/` |
| `./data/backups` | `/data/backups` | Settings backups `servers-<date>-<time>.json` (time in UTC; see `BACKUP_HOURS`), mode 600 because they contain the join passwords |
| `./data/wine` | `/data/wine` | Published image only: Wine prefix with .NET 4.8 (~2.6 GB), created on the first start. Empty with a self-built image. Delete `data/wine/prefix` to reinstall. |

Upgrading from an older compose file with one mount per subdirectory: replace the compose file; the host layout stays the same. Very old compose files mounted `appdata`/`userdata` directly into the Wine prefix; they still work, but the log warns about it.

`RR_DATA_DIR` must belong to UID/GID `PUID`/`PGID` (default 1000). In the repository `data/` already belongs to the user who cloned it. With a different `RR_DATA_DIR`, create it beforehand; otherwise Docker creates it as root and the preflight check aborts with a hint:
```bash
sudo install -d -o 1000 -g 1000 /path/to/data
# take over an existing directory:
sudo chown -R 1000:1000 /path/to/data
```

### Results format
One file per session (`Practice`, `Qualify`, `Race1`, …), named `Port_<port>_<event start>_<session>.txt`; all sessions of an event share the event start timestamp. The content is JSON (example from a race, names and IDs replaced):
```json
{
  "header": {"game": "RaceRoom Dedicated", "version": "0.9.8.16", "time": "2026/10/07 16:42:16"},
  "event": {"trackId": 262, "layoutId": 263, "trackLengthCm": 379725},
  "drivers": [
    {
      "name": "Driver One", "userId": 1234567, "countryId": 84,
      "carId": 13394, "liveryId": 13479, "teamId": 13438, "penaltyKg": 0,
      "totalLaps": 1, "lapDistanceTravelledCm": 364,
      "laps": [{"number": 0, "startEtMs": 0, "lapTimeMs": 114971}],
      "qualTimeMs": -1, "bestLapTimeMs": 114971, "raceTimeMs": 114971,
      "place": 1
    },
    {
      "name": "Driver Two", "userId": 7654321, "countryId": 23,
      "carId": 13394, "liveryId": 13466, "teamId": 13434, "penaltyKg": 0,
      "totalLaps": 0, "lapDistanceTravelledCm": 4946, "laps": [],
      "qualTimeMs": -1, "bestLapTimeMs": -1, "raceTimeMs": -1,
      "place": 2
    }
  ]
}
```
Times are in milliseconds, distances in centimetres; `-1` means "no value" (e.g. no completed lap). `drivers` is sorted by `place`. Pretty-print a file with `python3 -m json.tool <file>`.

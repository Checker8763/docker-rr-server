# Architecture

## Components
```
┌──────────────────────────── container (user rr) ────────────────────────────┐
│ tini ─► entrypoint.sh                                                         │
│          ├─ preflight checks                                                  │
│          ├─ Wine prefix: in the image (full) or installed into /data/wine     │
│          │   on the first start (public)                                       │
│          ├─ SteamCMD update  ─► /data/raceroom/RRRE_Dedicated.exe              │
│          ├─ access file from WEBUI_USERS                                      │
│          ├─ Xvfb :0                                                           │
│          ├─ script ─► wine RRRE_Dedicated.exe (manager, .NET 4.8)             │
│          │    ├─ web UI  HttpListener ─► Wine http.sys (patched) :8088        │
│          │    ├─ HTTPS ─► RaceRoom backend (login, registration, listing)     │
│          │    └─ starts DedicatedServer.exe (game instance, x64, StarForce)   │
│          │         └─ UDP 60000 / TCP 60001 / UDP 60002                        │
│          └─ webui_init.py (optional): register + autostart through the API    │
└───────────────────────────────────────────────────────────────────────────────┘
```

### Manager `RRRE_Dedicated.exe`
- .NET console application (AnyCPU, runs as a 64-bit process), **obfuscated**. Under Mono it fails with `InvalidProgramException`, hence the real .NET Framework 4.8.
- Calls `Console.ReadKey()` in `Main` and therefore needs a console. The entrypoint starts it with `setsid script …`: its own pseudo terminal and session, with input from a FIFO the entrypoint keeps open. The container itself needs no TTY.
- Shuts down gracefully on **Ctrl+C** in its console (Wine → `CTRL_C_EVENT`). Other keys do nothing; SIGINT or SIGTERM sent to the Wine process only kill it hard.
- Web UI (ServiceStack on `HttpListener`, HTTP basic auth against the `access` file). Without an `access` file it binds to `http://localhost:8088/`, with one to `http://*:8088/`.
- Unpacks the game instance to `%LOCALAPPDATA%\Sector3_Studios_AB\bin\…` on start and deletes it on exit.
- Forgets its registration on every restart (the login is kept in `settings.bin`).

### Game instance `DedicatedServer.exe`
- Native x64 GUI application with StarForce protection (`protect.exe`/`.dll`), started with `-port 60000 -timePort 60002 … -nowindow`. Needs a display, hence Xvfb.
- Writes results and logs to `%USERPROFILE%\Documents\My Games\SimBin\RaceRoom Dedicated\`.

## Wine adjustments
| Problem | Solution |
|---|---|
| Mono cannot run the obfuscated manager | `winetricks dotnet48` |
| .NET's `HttpListener` uses `http.sys`, whose Wine implementation is incomplete | 4 patches in [wine-httpapi/](../wine-httpapi/README.md) |
| The game instance needs a display | Xvfb, `/tmp/.X11-unix` (1777) in the image |
| Crashes hang in the debugger instead of exiting | `WINEDLLOVERRIDES=winedbg.exe=d` |
| .NET's background NGen services (`mscorsvw.exe`) recompile native images in every new container and keep a CPU core busy for 10+ minutes | `install-prefix.sh` runs the 64-bit NGen queue once (build for `full`, first start for `public`) and disables both `clr_optimization_v4.0.30319_*` services |
| The manager needs a console and only stops gracefully on Ctrl+C | `setsid script` with an input FIFO (see above) |

The patches in detail:
1. **No IOCP packets for synchronous calls:** otherwise .NET receives a stack pointer as `NativeOverlapped*` → `AccessViolationException`.
2. **`HttpCancelHttpRequest` implemented:** it was a stub that aborted the process whenever the web UI stopped.
3. **Find pending requests on all connections:** with several keep-alive connections (browsers), requests were never handed out.
4. **Match wildcard URLs against the local port:** behind a reverse proxy (or with a `Host` header without a port), requests hung.

## Start and stop
1. `tini` (PID 1) → `entrypoint.sh`
2. Preflight checks (`preflight.sh`): volumes writable, Wine prefix (or `ACCEPT_MICROSOFT_DOTNET_LICENSE=yes` to create it), SteamCMD, `script`, valid values; on errors abort with instructions
3. Image `public` only, first start: create the Wine prefix with .NET 4.8 in `/data/wine/prefix` (`install-prefix.sh`, the same script the `full` build uses; built as `prefix.partial` and renamed when complete)
4. Link the data directories in the prefix to the volumes (`/data/appdata`, `/data/userdata`)
5. SteamCMD: warm-up run (self-update), then `app_update 354060` for the Windows platform with retries; success = `Success!`, app manifest `StateFlags` 4 and the executable exists (`UPDATE_ON_START`)
6. Write the `access` file (umask 077, the content is never logged)
7. Start Xvfb (the game instance `DedicatedServer.exe` is a GUI program and does not start without an X server) and wait for its socket
8. `setsid script … wine RRRE_Dedicated.exe` in the background (console via a FIFO, output filtered for readable logs)
9. Optionally `webui_init.py`: waits for the web UI, registers (`POST /dedi/register`), starts servers (`POST /dedi/start`)
10. SIGTERM → `tini` (without `-g`) → the entrypoint writes Ctrl+C into the manager's console → graceful stop of web UI, workers and game instances (about 6 s); `wineserver -k` after `STOP_TIMEOUT`

Health check: `GET http://localhost:8088/` must answer.

## Web UI API (used by `webui_init.py`)
| Method | Path | Purpose |
|---|---|---|
| GET | `/dedi` | Server list with `GameSetting` and `ProcessState.Running`; 403 `Not registered!` without registration |
| POST | `/dedi/register` | `{"Secret": phrase}` → `{"Ip", "Quota"}` |
| POST | `/dedi/start`, `/dedi/stop` | `{"ProcessId": GameSetting.Id}` |
| GET | `/content/meta` | Option lists for the settings |
| GET | `/dedi?attachment=true` | Export of the server settings |

## Data paths
The manager and the game instance use fixed Windows paths. In the prefix these are symlinks to the volumes, so the prefix itself can live in the image (`full`) or in a volume (`public`):

| Windows path | Container | Volume | Content |
|---|---|---|---|
| `Z:\data\raceroom\` | `/data/raceroom` | `data/raceroom` | Installation, `access` |
| `%LOCALAPPDATA%\Sector3_Studios_AB\` | symlink → `/data/appdata` | `data/appdata` | `settings.bin`, `iv.bin`, `data.db`, `logs\output.log`, `bin\` |
| `%USERPROFILE%\Documents\My Games\SimBin\RaceRoom Dedicated\` | symlink → `/data/userdata` | `data/userdata` | Results, game instance logs, replays, crash reports |
| – (Wine prefix, `public` only) | `/data/wine/prefix` | `data/wine` | Wine prefix with .NET 4.8 (~2.6 GB) |

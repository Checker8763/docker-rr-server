# Troubleshooting

Logs: `docker compose logs -f raceroom` (manager and entrypoint), `data/appdata/logs/output.log` (manager). The game instance logs in `data/userdata/UserData/Log_Dedicated/` are encrypted.

At start, `scripts/preflight.sh` checks the most common sources of errors and aborts with concrete instructions (`[entrypoint] ERROR: …`, followed by `Preflight: N error(s) – aborting`): writable volumes, Wine prefix, SteamCMD and `script` present, valid values for switches and numbers, and the `WEBUI_USERS` format. Warnings (`WARNING: …`) do not abort.

| Symptom | Cause / solution |
|---|---|
| `ERROR: … is not writable for UID 1000 … chown -R 1000:1000` | The data directory on the host belongs to root (created by Docker) or another UID. On the host: `chown -R 1000:1000 <RR_DATA_DIR>`. Without this check SteamCMD would report "Success" without writing any files. |
| Web UI not reachable from outside | Is `WEBUI_USERS` set? The log must show `Starting frontend on http://*:8088/` (not `localhost`). |
| `Fatal server error: Server is already active for display 0` after a restart | Fixed since 2026-10-16: images before that left Xvfb's lock file behind on `docker restart` (also after the watchdog), so no X server ran and game instances could not start. Update the image, or recreate the container: `docker compose up -d --force-recreate`. |
| `ERROR AnnounceServer` / `ERROR DediService.Get.ListServersRequest` every 10 s | The manager cannot reach the RaceRoom backend (server list). Usually a short outage on RaceRoom's side; check the host's internet connection if it lasts. |
| `WARN DedicatedServerProcess.Process.Start pipe still connecting`, then `ERROR DedicatedServerProcess.Process.Start` | The game instance did not start. Check that the log shows `Xvfb started on :0` – without an X server `DedicatedServer.exe` does not come up. |
| `This image does not contain the .NET Framework 4.8 … Set ACCEPT_MICROSOFT_DOTNET_LICENSE=yes` | The published image installs .NET on the first start, after you accept Microsoft's license terms: set `ACCEPT_MICROSOFT_DOTNET_LICENSE=yes`. The installation takes 5–20 min; the health status stays `starting` meanwhile. |
| First start of the published image hangs or fails during the .NET installation | Needs internet access to Microsoft's download servers and ~2.5 GB free in `data/wine`. An interrupted installation (`data/wine/prefix.partial`) is repeated on the next start. |
| `WARNING: … is a directory, not a link to /data/appdata – old compose file?` | The compose file still mounts the volumes into the Wine prefix. Use the current compose file ([Volumes](CONFIGURATION.md#volumes)); the host directories stay the same. |
| High CPU while idle, `mscorsvw.exe` processes | .NET's background NGen compiler. Images from before 2026-10-10 recompile in every new container (10+ min, one core). Rebuild or pull a current image; for the published image delete `data/wine/prefix` once so it is reinstalled with NGen precompiled. |
| Server appears twice in the in-game server list | A stale entry in the RaceRoom backend from a server that was killed without deregistering (e.g. container removed or killed hard). It disappears by itself after a while. Check that only one game instance runs: `docker exec raceroom pgrep -fa "DedicatedServer.exe -port"`. |
| Web UI: "Not registered!", empty page after a restart | The manager forgets its registration on every restart. Register again in the web UI or set `REGISTER_PHRASE` (log: `[webui-init] registered for IP …`). |
| Server does not start after a restart | Set `AUTOSTART=true` (requires a registration). |
| Client: "No response from server" | Are ports 60000–60002 reachable from outside (firewall, port forwarding, no CGNAT)? From the same network: the router lacks NAT loopback. See [Deployment › Network](DEPLOY.md#network). |
| Web UI hangs / loads forever | Should not happen with the Wine patches. Check that the image contains the patched DLLs (build log: `httpapi.dll: OK`). Search the log for `unimplemented function httpapi.dll` or `AccessViolationException`. |
| `ERROR! Failed to install app '354060' (Missing configuration)` | **Transient SteamCMD issue** right after its self-update (affects many game servers) – not an app ID or licence problem. The entrypoint does a warm-up run first and then retries (`STEAMCMD_RETRIES`, `STEAMCMD_RETRY_DELAY`). |
| `Success! App '354060' fully installed`, but `RRRE_Dedicated.exe is missing` | After a self-update SteamCMD sometimes reports success without downloading. The entrypoint treats that as a failure and retries with `validate`. |
| `SteamCMD reports success, but the app manifest says StateFlags=…` | The download was incomplete or aborted (`steamapps/appmanifest_354060.acf` is written with `"StateFlags" "4"` only after a complete installation). The entrypoint retries; check free disk space if it persists. |
| `WARNING: the installation may be incomplete` | All update attempts failed (or `UPDATE_ON_START=false`) and the manifest does not report a complete installation. The server starts anyway; restart the container to retry the update. |
| `pull access denied for docker-rr-server` | The image is not present locally: build it (`docker compose -f docker-compose.build.yml build`) or load it; `RR_PULL_POLICY` must be `missing` or `never`. |
| `curl` against the web UI inside the container | `curl -u user:pass http://localhost:8088/dedi` |
| Stopping takes long / `Server still running after …s, killing it` | The manager did not react to Ctrl+C; increase `STOP_TIMEOUT` and `stop_grace_period` (Compose, 30 s) if needed. A graceful stop takes about 6 s. |
| Container is `unhealthy` | The web UI does not answer: check the log; `docker compose restart raceroom`. Behind Traefik all routers answer 404 while the container is unhealthy. If the manager hangs (port 8088 has waiting connections in `ss -tln`, the manager uses ~0 % CPU), the watchdog restarts the container after `WEBUI_WATCHDOG_MINUTES`. |
| Log: `web UI has not answered for … min` | The watchdog restarted the container because the manager hung. Happens rarely; if it repeats, raise `cpus` and report the log. |
| The game instance crashes | `data/userdata/sentry-errors/` contains crash reports. |

Harmless messages in the log: `XDG_RUNTIME_DIR is invalid`, `Unknown heap type: #GUlD`/`#Blop`, winetricks warnings about the 64-bit prefix, `Timed out waiting for update to start` from SteamCMD when the installation is already up to date.

# Web UI API

The manager's web UI (port 8088) is a single-page app on top of a JSON HTTP API. The same API can be scripted, e.g. for automation or a custom front end; [scripts/webui_init.py](../scripts/webui_init.py) uses it for registration and `AUTOSTART`.

There is no official documentation. This page was derived from the web UI's code (`/ui.min.js`) and checked against a running server (manager from Steam app 354060, October 2026). Every endpoint is marked:

- **tested**: called against a running server, status and response as shown
- **UI code**: taken from the web UI's code, not called (e.g. because it affects players or overwrites everything)

Updates of the manager may change any of this.

## Access
- Base URL: `http://<host>:8088` (or the Traefik host, see [Deployment](DEPLOY.md)).
- Authentication: HTTP Basic with a user from the `access` file (`WEBUI_USERS`, see [Configuration](CONFIGURATION.md)). Without credentials: `401`.
- Request and response bodies are JSON (`Content-Type: application/json`).
- Errors usually come as `{"Message": "..."}`.

```bash
curl -u 'admin:secret' http://localhost:8088/dedi
```

### Access model
The manager knows exactly **one role**: every user in the `access` file can see and change every server, register the manager, import a backup (overwrites everything) and delete servers. Some functions are global, not per server:

| Global | Per server (by id) |
|---|---|
| Registration, import/export, creating servers | Settings, start/stop, session commands |
| Ban list (`/ban`, `/user/ban`) | Chat, MOTD, kick, penalty |
| Content catalog | Weights, power restrictions, grid positions, spectator whitelist, results, upload rules |

Separate permissions per server would need a proxy in front of the API that maps its own users to server ids and blocks the global endpoints.

## Concepts
- **Server = process.** Each configured server has a `GameSetting.Id`. The same number is called `ProcessId` in request bodies and `{id}` in paths.
- **Registration.** Until the manager is registered with the RaceRoom backend, `/dedi` answers `403 {"Message":"Not registered!"}` and other server endpoints fail as well (`/dedi/default`: `500`); `/content/*` works. The manager forgets the registration on every restart (hence `REGISTER_PHRASE`). The backend allows **5 running servers** per public IP; any number can be configured.
- **Instances and ports.** A started server gets the next free block of three ports from 60000 (`ProcessState.Port`/`TimePort`), see [Configuration › Ports](CONFIGURATION.md#multiple-instances).
- **Saving** sends the complete `GameSettings` object; there is no partial update.

## Endpoints

### Registration
| Method | Path | Body | Response | |
|---|---|---|---|---|
| POST | `/dedi/register` | `{"Secret": "<phrase>"}` | `{"Ip": "...", "Quota": 5, ...}` or `{"Message": ...}` | tested |

### Servers
| Method | Path | Body | Response | |
|---|---|---|---|---|
| GET | `/dedi` | – | `[{"ProcessState": {...}, "GameSetting": {...}}, ...]` | tested |
| GET | `/dedi/{id}` | – | `{"ProcessState": {...}, "GameSetting": {...}}`; unknown id: `404 {"Message":"No settings found!"}` | tested |
| GET | `/dedi/default` | – | `{"GameSetting": {...}}` template with `Id: 0` and all [settings](#settings-reference) at their defaults | tested |
| POST | `/dedi/` | `{"GameSettings": {...}}` | `{"ProcessId": <id>}`. `Id: 0` creates a server, an existing `Id` overwrites its settings. A duplicate name is rejected with a `Message` (UI code). | tested |
| DELETE | `/dedi/{id}` | – | `{"IsDeleted": true}` | tested |
| POST | `/dedi/start` | `{"ProcessId": <id>}` | `{"IsStarted": true}`; with 5 servers already running: `303 {"Message":"Quota exceeded!"}` | tested |
| POST | `/dedi/stop` | `{"ProcessId": <id>}` | `{"IsStopped": true}` | tested |
| GET | `/dedi?attachment=true` | – | Backup of all servers, see [backup format](#backup-format) | tested |
| POST | `/dedi` | backup JSON | Imports a backup and **overwrites all servers** | UI code |

`ProcessState` (from `GET /dedi/{id}` on a running server):

```json
{"Running": true, "Port": 60000, "TimePort": 60002, "PlayersOnServer": 0,
 "TimeLeft": 581996, "SessionTime": 18003, "SessionTimeLeft": 0,
 "CurrentSession": 0, "Players": []}
```
`CurrentSession` (table from the web UI code): 0 Practice, 256 Qualify, 513/514/515 Warmup before race 1/2/3, 768 or 769 Race 1, 770 Race 2, 771 Race 3. Tested on an empty server: Practice 0 and Qualify 256; after "next session" the old session first counts down about 20 s (`TimeLeft`), and without players the server goes from Qualify back to Practice instead of on to the race.

Times are in milliseconds. During a race by laps, `TimeLeft` reports about 24 h (1440 min) instead of a remaining time. A stopped server reports `Running: false`, ports `0` and `Players: null`.

**Players** are only listed by `GET /dedi/{id}`; the list `GET /dedi` reports `PlayersOnServer` but `Players: null` (tested with one driver on the server). One entry:

```json
{"UserId": 1234567, "X": 276.9, "Z": 112.1, "CarLiveryId": 8714, "LatestPingMilliSec": 25.7,
 "Incidents": [{"Type": 6, "Points": 1, "OtherUserId": 0}, {"Type": 1, "Points": 2, "OtherUserId": 0}]}
```

`Incidents[].Type` is the position in this list (from the web UI): 0 car to car collision, 1 collision with a track object, 2 going the wrong way, 3 going off track, 4 staying stationary on the track, 5 losing control of the vehicle, 6 invalid lap, 7 not serving a penalty, 8 disconnecting / giving up before the end of a race, 9 missing the race start. Observed: invalid lap 1 point, track object and loss of control 2 points.

**Pictures** of tracks, car classes and cars, as in the web UI: `https://game.raceroom.com/store/image_redirect?id=<track, class or car id>&size=small|thumb` (redirects to the store image; not every class has one).

There is no player name: the web UI looks it up in the browser at `https://game.raceroom.com/utils/user-info/<UserId>` (field `name`).

**Live events:** `GET /event-stream?channel={id}` is a server-sent event stream (ServiceStack). Lines look like `data: {id}@session {"Session":256,"SessionTime":303067,"TimeLeft":356932}` (every 3 s); the web UI also handles `{id}@players` (`joined`/`left`) and `{id}@incidents`. Tested: connect and `session` events.

### Session and players
| Method | Path | Body | Response | |
|---|---|---|---|---|
| POST | `/session/{id}` | `{"Command": 1}` restart session, `{"Command": 2}` next session | `201 {}` | tested (accepted; effect not checked with players) |
| POST | `/user/kick` | `{"UserId": u, "ProcessId": id}` | – | UI code |
| POST | `/user/penalty` | `{"UserId", "ProcessId", "PenaltyType", "Duration"}`; `PenaltyType` 0 slowdown, 1 drive-through, 2 stop-and-go, 3 disqualify; `Duration` 0–30 s (slowdown only) | – | UI code |
| POST | `/user/ban` | `{"UserId", "ProcessId"}` – adds to the **global** ban list | – | UI code |

### Chat and message of the day
| Method | Path | Body | Response | |
|---|---|---|---|---|
| GET | `/chat/{id}` | – | `{"messages": [{"Id", "ProcessId", "UserId", "UserName", "Message", "CreatedAt"}]}` (`CreatedAt` Unix seconds, admin messages have `UserId: -1`). Server not running: `404 {"Message":"Process not found!"}` | tested |
| POST | `/chat/{id}/admin` | `{"Message": "..."}` | `201 {}` | tested |
| GET | `/motd/{id}` | – | `{"Message": "..." \| null}` | tested |
| POST | `/motd/` | `{"ProcessId": id, "Message": "..."}` | `201 {}` | tested |

### Bans, weights, restrictions, grid
| Method | Path | Body | Response | |
|---|---|---|---|---|
| GET | `/ban` | – | list of banned `UserId`s (global) | tested |
| DELETE | `/ban` | `{"UserId": u}` | – | UI code |
| GET | `/weight/{id}` | – | list of ballast entries | tested (`[]`) |
| POST | `/weight/user` or `/weight/car` | `{"ProcessId", "UserId" \| "CarId", "WeightPenalty"}` (kg) | – | UI code |
| DELETE | `/weight` | `{"Id": entryId}` | – | UI code |
| GET | `/power-restriction/{id}` | – | list of entries | tested (`[]`) |
| POST | `/power-restriction/` | entry with `RestrictionPercent` | – | UI code |
| DELETE | `/power-restriction` | `{"Id": entryId}` | – | UI code |
| GET | `/positions/{id}` | – | `{"Users": [...]}`, empty: `204` | tested (`204`) |
| POST | `/positions` | `{"ProcessId": id, "Users": [...]}` – fixed grid order | – | UI code |
| GET | `/spectator-whitelist/{id}` | – | `{"Users": [...]}`, empty: `204` | tested (`204`) |
| POST | `/spectator-whitelist` | `{"ProcessId": id, "Users": [...]}` | – | UI code |

### Results
| Method | Path | Body | Response | |
|---|---|---|---|---|
| GET | `/result/{id}` | – | list of result reports of this server | tested (`[]`) |
| GET | `/result/rule/{id}` | – | upload targets for results; none: body `404` | tested |
| POST | `/result/rule/{id}` | `{"ProcessId": id, "UploadTarget": {...}}` – HTTP upload of results to your own endpoint | – | UI code |
| DELETE | `/result/rule/{id}` | `{"ProcessId": id, "Protocol": ...}` | – | UI code |

The result files themselves are written to `userdata/` ([Configuration › Results format](CONFIGURATION.md#results-format)).

### Content catalog
Available without registration.

| Method | Path | Response | |
|---|---|---|---|
| GET | `/content/all` | `Tracks` (with `Layouts`: `Id`, `Name`, `MaxVehicles`), `Liveries` (per car: `Car {Id, Name, Class}` + liveries), `CarClasses`, `Difficulties`, `Experiences`, `EventPacks` | tested |
| GET | `/content/meta` | allowed values and labels for the settings, see below | tested |
| GET | `/content/driveassist/` | driving aid values of the presets 1–3 | tested |

## Settings reference
Fields of `GameSetting` as returned by `GET /dedi/default`, with the allowed values from `GET /content/meta`. Default values in **bold**.

### General
| Field | Values |
|---|---|
| `Id` | server id; `0` in the template |
| `Name` | up to 255 characters, unique |
| `Password` | join password, up to 16 characters, empty = public |
| `Thumbnail` | server image as base64, or `null` |
| `Experience` | content set from `/content/all` › `Experiences`, **2481** RaceRoom Experience |
| `Cars` | car ids from `/content/all` › `Liveries[].Car.Id` |
| `Liveries` | allowed livery ids of those cars |
| `MaxNumOfPlayers` | 1–100, **24**; the track layout's `MaxVehicles` is the real limit |
| `MaxPing` | **0** = 500 ms, otherwise 25–450 ms |
| `MinRating` / `MaxRating` | **0** = anyone, otherwise 50–2100 in steps of 50 |
| `MinReputation` / `MaxReputation` | **0** = anyone, otherwise 1–100 |
| `RankedServer` | **0**; not exposed in the web UI |
| `AdPack` | **null**; not exposed in the web UI |

### Driving aids
`DriveAssistPreset`: **0** custom, 1 novice, 2 amateur, 3 get real. A preset sets the fields below (`/content/driveassist/`); `-1` means **free choice** for the player.

| Field | Forced values |
|---|---|
| `DriveAssistTransmission` | 0 manual, 1 manual with auto clutch, 2 automatic |
| `DriveAssistEsp` | 0 off, 1 low, 2 medium, 3 high |
| `DriveAssistSteer` | 0 off, 1 on |
| `DriveAssistBrake` | 0 off, 1 ABS, 2 factory ABS, 3 assisted |
| `DriveAssistTractionControl` | 0 off, 1 on, 2 factory default |
| `DriveAssistRaceline` | 0 off, 1 downloaded or own, 2 ideal line |
| `DriveAssistAutopit` | 0 off, 1 on |

### Race rules
| Field | Values |
|---|---|
| `FuelUsage` / `TireWear` | **0** off, 1 normal, 2–4 = 2×–4× |
| `TireTemperature` | **0** dynamic, 1 optimal |
| `Damage` | **0** off, 1 limited, 2 full |
| `FlagRules` | **0** none, 1 black only, 2 visual only, 3 complete |
| `CutRules` | **0** off, 1 slow-down, 2 stop-and-go, 3 drive-through |
| `MandatoryPitstop` | **0** off, 1 at least two tires, 2 at least four tires |
| `MaxIncidentPoints` | **0** off, otherwise 10–1000 in steps of 10 |
| `ReverseStartOrderPlaces` | **0**/1 off, 2–100 reverse grid for the top N |
| `RaceFinishDuration` | 30, 45, 60, 100, 120, 240, 360, 480, 600 (seconds), **30** |
| `CheckeredAfterTime` | **0** off, 30, 60, 120, 240, 600 |
| `PreventFalseStart` | **0** no, 1 yes |
| `WreckerPrevention` | **0** off, 1 on |
| `FixedSetup` | **0** off, 1 on |
| `StartingGridFromLeaderboards` | **0** no, 1 yes |
| `AllowPlayersJoinInQualifying` | **0** off, 1 on |
| `StayInPracticeSessionIfEmpty` | **0** off, 1 on |
| `NonReadyPitlaneStartDelay` | **0** off, 1–120 |
| `KickNonReadyClientsTime` | **0** off (wait forever) |
| `LiveUpdate` | **0** off, 1–60 |
| `StateReportInterval` | **3000** (ms) |
| `CompressionLevel` | **3**; not exposed in the web UI |

### Tracks and sessions
`TrackLayouts` is the rotation: a list of layouts, each with its own sessions.

```json
{"LayoutId": 263, "EventPackId": 0, "TimeOfDayMultiplier": 0,
 "Sessions": {
   "WarmupDuration": 0,
   "Practice": {"Duration": 10, "Laps": 0, "TimeOfDay": 2, "SessionType": 1, "Clouds": null},
   "Qualify":  {"...": "same fields"},
   "Race1":    {"...": "same fields"},
   "Race2":    {"...": "same fields"},
   "Race3":    {"...": "same fields"}}}
```

| Field | Values |
|---|---|
| `LayoutId` | layout id from `/content/all` › `Tracks[].Layouts[].Id` |
| `EventPackId` | **0**, or an id from `/content/all` › `EventPacks` |
| `TimeOfDayMultiplier` | time acceleration 0–25 |
| `WarmupDuration` | warm-up length in minutes |
| `Duration` / `Laps` | either duration in minutes or number of laps; the other one is `0`. Both `0` = session off. Rules checked by the manager on save (tested): `Race1` must not be off; `Race2` may only be off when `Race3` is off too (otherwise `500 {"Message":"Race2 duration/laps is not valid!"}`); `Practice`/`Qualify` may be off. The web UI allows up to 360; the manager accepted 361. |
| `TimeOfDay` | 0 dawn, 1 morning, **2** noon, 3 afternoon, 4 sunset |
| `SessionType` | race sessions: 0 rolling start, **1** standing start |
| `Clouds` | `null` or a list of 0 clear, 1 few clouds, 2 scattered, 3 overcast |

### Schedule
| Field | Values |
|---|---|
| `ScheduleStart` / `ScheduleEnd` | Unix seconds, or `null` = no schedule |
| `ScheduleRepeat` | **0** never, 1 every half hour, 2 hourly, 3 daily, 4 weekly, 5–7 every 2nd–4th week, 8 permanent |
| `ScheduleZone` | IANA time zone; the web UI sets the browser's zone on every save |
| `ScheduleOffset` | **0** |
| `RestartRequested` | **null**; set by the manager |

## Backup format
`GET /dedi?attachment=true` (the web UI's export) returns all servers and the per-server lists. Settings at their defaults are left out.

```json
{
  "BackupTime": 1791307168,
  "GameSettings": [
    {"Id": 500000, "Name": "My server", "Password": "", "Experience": 2481,
     "DriveAssistTransmission": -1, "...": "...",
     "TrackLayouts": [{"LayoutId": 263, "EventPackId": 0, "Sessions": {"...": "..."}}],
     "Cars": [13394], "Liveries": [13396, 13456],
     "MaxNumOfPlayers": 12, "RaceFinishDuration": 30,
     "StateReportInterval": 3000, "CompressionLevel": 3,
     "ScheduleZone": "Europe/Berlin", "ScheduleOffset": 0}
  ],
  "Motds": [], "Bans": [], "Weights": [],
  "Positions": [{"ProcessId": 500000, "Users": []}],
  "PowerRestrictions": [],
  "SpectatorWhitelist": [{"ProcessId": 500000, "Users": []}]
}
```

`GameSettings` and `Motds` name the server `Id`, the other lists `ProcessId`; filter by both to cut one server out of a backup.

## Examples
```bash
API=http://localhost:8088; AUTH='admin:secret'

# Servers with id, name and state
curl -s -u "$AUTH" $API/dedi | python3 -c 'import json,sys
for s in json.load(sys.stdin): print(s["GameSetting"]["Id"], s["GameSetting"]["Name"], s["ProcessState"]["Running"])'

# Start a server, then skip to the next session
curl -s -u "$AUTH" -H 'Content-Type: application/json' -d '{"ProcessId": 500000}' $API/dedi/start
curl -s -u "$AUTH" -H 'Content-Type: application/json' -d '{"Command": 2}' $API/session/500000

# Change one setting: read, modify, save the complete object
curl -s -u "$AUTH" $API/dedi/500000 \
  | python3 -c 'import json,sys; g=json.load(sys.stdin)["GameSetting"]; g["Damage"]=2; print(json.dumps({"GameSettings": g}))' \
  | curl -s -u "$AUTH" -H 'Content-Type: application/json' -d @- $API/dedi/
```

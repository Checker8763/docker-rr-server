# Deployment

## Prepare the host
- Linux x86_64, Docker Engine, Docker Compose ≥ 2.24, `zstd` (for the tarball)
- A user with UID/GID = `PUID`/`PGID` (default 1000) who owns the repository directory
- Network: see [below](#network)

```bash
git clone <repo-url> docker-rr-server && cd docker-rr-server
cp .env.example .env    # set WEBUI_USERS; REGISTER_PHRASE/AUTOSTART only after the initial setup
```

## Provide the image
Three options:
- **Pull a published image** (once one is available): in `.env` set `RR_IMAGE=<registry>/<name>:<tag>`, `RR_PULL_POLICY=always` and `ACCEPT_MICROSOFT_DOTNET_LICENSE=yes`; `docker compose up -d` pulls it. It does not contain the .NET Framework: the **first start** installs it into `data/wine` (about 5–20 min, ~2.6 GB, needs internet access to Microsoft's servers). See [image variants](BUILD.md#image-variants).
- **Build on the host**: `docker compose -f docker-compose.build.yml build`, about 10–15 min, ~8 GB free space during the build.
- **Transfer the image from a build machine:**

```bash
# build machine
docker compose -f docker-compose.build.yml build
scripts/export-image.sh        # -> dist/docker-rr-server_local.tar.zst (+ .sha256), about 1.7 GB
rsync -avhP --mkpath dist/docker-rr-server_local.tar.zst dist/docker-rr-server_local.tar.zst.sha256 \
  user@server:docker-rr-server/dist/          # add --bwlimit=5M to limit the upload rate

# target host
cd docker-rr-server
(cd dist && sha256sum -c docker-rr-server_local.tar.zst.sha256)
zstd -dc dist/docker-rr-server_local.tar.zst | docker load
```
`dist/` is git-ignored. The image contains the UID/GID from the build (`PUID`/`PGID`); on the target, `data/` must belong to that UID.

## Start and set up
A graceful stop takes about 6 s, Docker's default of 10 s is too tight for Wine/.NET. The Compose files set `stop_grace_period: 30s`; with plain `docker run` use `--stop-timeout 30`.

```bash
docker compose up -d
docker compose logs -f              # until "Starting frontend on http://*:8088/"
```
In the web UI:
1. Log in with a login from `WEBUI_USERS`.
2. Enter the RaceRoom login.
3. **Register** (enter a phrase). The registration is bound to the public IP; one made on another machine does not apply here.
4. Create a server, or take one over with **Import** from an export, and start it.

For unattended operation set `REGISTER_PHRASE=<phrase>` and `AUTOSTART=true` in `.env` afterwards and run `docker compose up -d`.

**Check:** `docker compose exec raceroom ss -tulnp` shows UDP 60000/60002 and TCP 60001; the server appears in the client's multiplayer list.

Do **not** copy from another machine: `data/appdata/` (login and configuration of the old IP), `data/raceroom/` (SteamCMD downloads it), `data/wine/` (created on the first start), `.env`.

## Behind Traefik
`docker-compose.traefik.yml` is a self-contained, complete variant for an **already running** Traefik. It matches `docker-compose.yml` (`scripts/lint.sh` checks that they stay in sync) but does not publish port 8088. The web UI is then only reachable through Traefik via HTTPS. The game ports are still published directly; they do not go through Traefik.

`.env`:
```
TRAEFIK_HOST=raceroom.example.com
TRAEFIK_NETWORK=traefik          # external Docker network Traefik is attached to
TRAEFIK_ENTRYPOINT=websecure
TRAEFIK_CERTRESOLVER=letsencrypt
```
```bash
docker compose -f docker-compose.traefik.yml up -d
```
The web UI additionally uses HTTP basic auth (`WEBUI_USERS`). More Traefik middlewares (e.g. an IP allowlist) can be added with extra labels.

Note: behind a reverse proxy the web UI only works thanks to patch [0004](../wine-httpapi/patches/0004-http.sys-Match-wildcard-URLs-against-the-local-port.patch); without it, requests with a foreign `Host` header hang.

## With Komodo (or Portainer)
The compose files contain no build section and can be used directly as a stack.
1. Provide the image on the host: build it there (clone the repository, `docker compose -f docker-compose.build.yml build`), load it from a [tarball](#provide-the-image), or pull it from a registry (`RR_IMAGE`, `RR_PULL_POLICY=always`).
2. Create the data directory with the UID/GID from the image (default 1000); the container creates the subdirectories. **Important** – otherwise Docker creates it as root and the container aborts in the preflight check:
   ```bash
   sudo install -d -o 1000 -g 1000 /docker/raceroom/data
   # take over existing directories:
   sudo chown -R 1000:1000 /docker/raceroom/data
   ```
3. Create a stack in Komodo (UI-defined) and paste the content of [`docker-compose.traefik.yml`](../docker-compose.traefik.yml) (or [`docker-compose.yml`](../docker-compose.yml) without Traefik).
4. Set at least these in the stack's environment:
   ```
   RR_DATA_DIR=/docker/raceroom/data
   WEBUI_USERS=admin:<password>
   TRAEFIK_HOST=raceroom.example.com
   ```
   Optionally `TRAEFIK_NETWORK`, `TRAEFIK_ENTRYPOINT`, `TRAEFIK_CERTRESOLVER`, and later `REGISTER_PHRASE` and `AUTOSTART=true` (all variables: [Configuration](CONFIGURATION.md)).
5. Deploy. `pull_policy: missing` (default) prevents the manager from trying to pull a locally built or loaded image from a registry.

`RR_DATA_DIR` must be absolute; a relative path would end up in the Docker manager's stack directory.

## Network
- Required inbound: **UDP 60000, TCP 60001, UDP 60002** (each additional instance uses the next block of three, up to 60012–60014 for instance 5; see [Configuration › Ports](CONFIGURATION.md#multiple-instances)). Host and container ports identical, no port translation.
- Do not expose port 8088 to the internet: use Traefik with TLS, a firewall rule for your own IP, a VPN or an SSH tunnel (`ssh -L 8088:localhost:8088 server`).
- The RaceRoom backend detects the public IP itself, also behind Docker's bridge network. There is no setting for it.
- **CGNAT / DS-Lite / a shared IPv4 with a restricted port range** does not work, because the ports cannot be configured. Options: ask your provider for a dedicated public IPv4, use a VPS with a public IPv4 as a tunnel endpoint (WireGuard + DNAT of the ports 1:1, outbound traffic through the tunnel as well), or run the server directly on a VPS/root server.
- Joining from the same network often fails due to missing NAT loopback ("No response from server"). That is not a container problem.

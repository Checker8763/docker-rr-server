# wine-httpapi – patched `httpapi.dll` and `http.sys` for Wine 11.0

The RaceRoom Dedicated Server manager serves its web UI with the .NET Framework `HttpListener`. On Windows that uses the kernel driver `http.sys`; under Wine it uses Wine's reimplementation in `dlls/httpapi` and `dlls/http.sys`. That reimplementation has four bugs that lead to crashes and hangs. This directory builds both components from the Wine source with four fixes.

## Patches
| Patch | Problem | Fix |
|---|---|---|
| [0001](patches/0001-httpapi-Do-not-queue-IOCP-completions-for-internal-s.patch) | Synchronous calls post a completion packet with a stack `OVERLAPPED` to .NET's IOCP → `AccessViolationException` | Internal event with bit 0 set (no IOCP notification, as on Windows) |
| [0002](patches/0002-httpapi-Implement-HttpCancelHttpRequest.patch) | `HttpCancelHttpRequest` is a stub → the process aborts when the web UI stops | New IOCTL closes the request's connection |
| [0003](patches/0003-http.sys-Hand-out-pending-requests-from-any-connecti.patch) | Requests on a second keep-alive connection are never handed out | Search all connections for pending requests |
| [0004](patches/0004-http.sys-Match-wildcard-URLs-against-the-local-port.patch) | `http://*:port/` compares the port in the `Host` header; behind proxies requests hang, without a port it is a NULL access | Compare the connection's local port |

Each patch carries a description in `git format-patch` format and is written so that it could be submitted to Wine upstream.

## Building
The [Dockerfile](Dockerfile) downloads the Wine source (SHA-256 verified), applies `patches/*.patch` and builds only the Wine tools and the two targets for x86_64 (about 5 min). The result is an artifact image `FROM scratch` with `/httpapi.dll`, `/http.sys` and `/SHA256SUMS`.

```bash
# as an image (this is how docker-compose.build.yml uses it)
docker build --target artifacts -t docker-rr-server-httpapi:local wine-httpapi

# as files, e.g. for a CI or to pass them on
docker build --target artifacts --output type=local,dest=wine-httpapi/dist wine-httpapi
ls wine-httpapi/dist   # httpapi.dll  http.sys  SHA256SUMS
```

Providing them to the server build (`--build-context httpapi=…`): see [docs/BUILD.md](../docs/BUILD.md#building-the-patched-wine-dlls-separately). The server image verifies the `SHA256SUMS` during the build and copies the files to `/opt/wine-stable/lib/wine/x86_64-windows/`, replacing the Wine builtins. x86_64 only, since .NET runs as a 64-bit process.

## Changing the Wine version
The DLL and the driver talk to each other via Wine-internal IOCTLs and must match the Wine version in the server image **exactly**.
1. Determine the version in the server image: `docker run --rm --entrypoint wine <image> --version`.
2. Adjust `WINE_VERSION`, `WINE_SOURCE_URL` and `WINE_SHA256` in the [Dockerfile](Dockerfile) (`curl -fsSL <url> | sha256sum`).
3. Build. If a patch no longer applies, regenerate it in the Wine source tree:
   ```bash
   tar -xJf wine-<ver>.tar.xz && cd wine-<ver> && git init -q && git add -A && git commit -qm base
   for p in ../patches/*.patch; do git am -3 "$p" || break; done   # resolve conflicts, git am --continue
   git format-patch -o ../patches-new base..HEAD
   ```
   Keep the `SPDX-License-Identifier: LGPL-2.1-or-later` line in each commit message.
4. Check whether Wine upstream has fixed the bugs in the meantime (`dlls/httpapi/httpapi.spec`: is `HttpCancelHttpRequest` no longer a `stub`?). Individual patches can then be dropped.

## Testing
After building the server image: stop/start the web UI without crashes, parallel keep-alive requests (GET/POST) without hangs, `Host` headers `example.com`, `example.com:443` and `localhost` → 200.

## License
The patches modify Wine source code and are licensed under the **GNU Lesser General Public License v2.1 or later** like Wine itself – see [patches/LICENSE](patches/LICENSE). The other files in this directory are covered by the project's [MIT license](../LICENSE).

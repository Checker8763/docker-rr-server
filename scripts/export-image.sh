#!/usr/bin/env bash
# Exports the server image as a compressed tarball to dist/ (e.g. to rsync it to a
# host that does not build itself). Loading on the target: see docs/DEPLOY.md.
#   scripts/export-image.sh [image]      (default: $RR_IMAGE or docker-rr-server:local)
set -euo pipefail
cd "$(dirname "$0")/.."

image="${1:-${RR_IMAGE:-docker-rr-server:local}}"
command -v zstd >/dev/null || { echo "zstd is missing (e.g. apt install zstd)" >&2; exit 1; }
docker image inspect "$image" >/dev/null

mkdir -p dist
out="dist/$(tr '/:' '__' <<<"$image").tar.zst"
echo "Exporting $image -> $out"
docker save "$image" | zstd -T0 -10 -q -f -o "$out"
(cd dist && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
ls -lh "$out"

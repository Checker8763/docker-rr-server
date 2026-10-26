#!/usr/bin/env bash
# Lints the Dockerfiles (hadolint), shell scripts (shellcheck), Python (ruff) and
# runs the tests, all as containers, and checks that the compose files
# are valid and in sync.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in Dockerfile wine-httpapi/Dockerfile; do
    docker run --rm -i hadolint/hadolint:v2.14.0 < "$f"
done
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt ghcr.io/astral-sh/ruff:0.6.9 check --no-cache scripts/

# Tests: Python scripts against a fake manager, configuration checks as a normal user
docker run --rm -v "$PWD:/mnt:ro" -w /mnt -e PYTHONDONTWRITEBYTECODE=1 python:3.13-alpine \
    python3 -m unittest discover -q -s scripts -p 'test_*.py'
docker run --rm --user 1000 -v "$PWD:/mnt:ro" -w /mnt bash:5.2 bash scripts/test-preflight.sh

# Compose files valid?
export TRAEFIK_HOST=lint.example.com
for f in docker-compose.yml docker-compose.traefik.yml docker-compose.build.yml; do
    docker compose -f "$f" config -q
done

# docker-compose.traefik.yml is intentionally a complete copy (to paste into
# Komodo/Portainer). It may only differ in ports, networks and labels.
service_without_routing() {
    docker compose -f "$1" config --format json | python3 -c '
import json, sys
svc = json.load(sys.stdin)["services"]["raceroom"]
for key in ("ports", "networks", "labels"):
    svc.pop(key, None)
print(json.dumps(svc, sort_keys=True, indent=1))'
}
if ! diff <(service_without_routing docker-compose.yml) <(service_without_routing docker-compose.traefik.yml); then
    echo "docker-compose.yml and docker-compose.traefik.yml have drifted apart" >&2
    exit 1
fi
echo "Lint OK"

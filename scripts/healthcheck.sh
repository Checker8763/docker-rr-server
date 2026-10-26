#!/usr/bin/env bash
# Does the web UI answer? Uses the URL host "localhost": without an access file the
# HttpListener only accepts "localhost:8088".
set -euo pipefail
curl -fsS -o /dev/null --max-time 5 "http://localhost:8088/"

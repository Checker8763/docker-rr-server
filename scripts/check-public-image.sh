#!/usr/bin/env bash
# Checks that an image built from the target "public" contains no .NET Framework
# (no baked Wine prefix, no framework assemblies). Used by CI before publishing.
#   scripts/check-public-image.sh <image>
set -euo pipefail
image="${1:?usage: $0 <image>}"

docker run --rm --entrypoint bash "$image" -c '
    found="$(find / -xdev \( -iname mscorlib.dll -o -iname Framework64 -o -name system.reg \) -print -quit 2>/dev/null)"
    if [[ -n "$found" ]]; then
        echo "Image contains .NET Framework or a Wine prefix: $found" >&2
        exit 1
    fi
'
echo "OK: $image contains no .NET Framework"

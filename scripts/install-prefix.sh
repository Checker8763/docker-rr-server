#!/usr/bin/env bash
# Creates the Wine prefix with .NET Framework 4.8 in $WINEPREFIX.
# Used at build time (image target "full") and on the first start of the image
# target "public", which must not contain .NET (see docs/BUILD.md#image-variants).
set -euo pipefail
: "${WINEPREFIX:?}"

# mscoree= during wineboot skips the wine-mono install, which dotnet48 would replace anyway
WINEDLLOVERRIDES="mscoree=;mshtml=" wineboot --init
wineserver -w
winetricks -q --unattended dotnet48
wineserver -w

# .NET compiles native images (NGen) in the background through two auto-start
# services (mscorsvw.exe). In a container that work is lost with every new container
# and costs a full CPU core for 10+ minutes. So: compile the 64-bit queue now (the
# manager runs as a 64-bit process; the 32-bit queue would only add size and fails
# under Wine anyway), then disable both services.
wine 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\ngen.exe' executeQueuedItems
for arch in 32 64; do
    wine reg add "HKLM\\System\\CurrentControlSet\\Services\\clr_optimization_v4.0.30319_$arch" \
        /v Start /t REG_DWORD /d 4 /f
done
wineserver -w

# Installer caches and temporary files (several hundred MB); the image build keeps
# the winetricks cache in a cache mount (KEEP_WINETRICKS_CACHE), which cannot be removed
[ -n "${KEEP_WINETRICKS_CACHE:-}" ] || rm -rf "$HOME/.cache/winetricks"
rm -rf "$WINEPREFIX/drive_c/users/$USER/AppData/Local/Temp/"* \
       "$WINEPREFIX/drive_c/windows/temp/"*

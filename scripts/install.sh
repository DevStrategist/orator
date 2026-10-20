#!/bin/bash
# Builds Orator from source and installs it to ~/Applications. The app sets up its speech engine on first launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/Orator.app"
bash "$ROOT/scripts/build.sh"
mkdir -p "$HOME/Applications"
if [ -e "$DEST" ]; then
    if pgrep -f "$DEST/Contents/MacOS/Orator" >/dev/null; then
        printf '%s\n' 'Quit Orator before updating. Pending recovery audio is preserved.'
        exit 1
    fi
    mv "$DEST" "$DEST.previous-$(date +%Y%m%d-%H%M%S)"
fi
ditto "$ROOT/dist/Orator.app" "$DEST"
printf 'Installed %s\n' "$DEST"
if [ "${ORATOR_NO_LAUNCH:-0}" != "1" ]; then
    open "$DEST"
fi

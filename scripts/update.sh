#!/usr/bin/env zsh
# One command to ship a change: build, replace /Applications/Burrow.app,
# relaunch it if it was open, and remove the build from the repository.
# The stable signing identity keeps Full Disk Access and other grants.
set -euo pipefail
cd "${0:A:h:h}"
APP_ID="com.burrow.macos"
RUNNING_BINARY="/Applications/Burrow.app/Contents/MacOS/Burrow"

zsh scripts/setup_signing.sh >/dev/null
zsh ./build_app.sh

was_running=0
if pgrep -f "${RUNNING_BINARY}" >/dev/null; then
    was_running=1
    echo "Zamykanie działającego Burrow…"
    osascript -e "tell application id \"${APP_ID}\" to quit" >/dev/null 2>&1 || true
    for _ in {1..30}; do
        pgrep -f "${RUNNING_BINARY}" >/dev/null || break
        sleep 0.5
    done
    if pgrep -f "${RUNNING_BINARY}" >/dev/null; then
        echo "Burrow nadal działa (może czeka na potwierdzenie). Zamknij go i uruchom ponownie scripts/update.sh." >&2
        rm -rf -- Burrow.app
        exit 1
    fi
fi

zsh scripts/install.sh
rm -rf -- Burrow.app
if (( was_running )); then open -b "${APP_ID}"; fi
echo "Zaktualizowano Burrow."

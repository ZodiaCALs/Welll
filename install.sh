#!/bin/bash
# Builds Welll from source and installs it on this Mac: Welll.app in /Applications,
# plus the background helper, which the app's own installer puts in place.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/Welll.app"
CLI="/usr/local/bin/welllctl"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Welll only runs on macOS." >&2
    exit 1
fi
if [[ $EUID -eq 0 ]]; then
    echo "Run this as yourself, without sudo. It asks for your password when it needs it." >&2
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Swift isn't installed. Install Apple's command line tools first:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

# Files from a downloaded zip carry a quarantine flag that copies would inherit.
xattr -dr com.apple.quarantine . 2>/dev/null || true

# Two charge limiters fight each other.
others="$(ls /Library/LaunchDaemons /Library/PrivilegedHelperTools 2>/dev/null \
    | grep -iE 'aldente|apphousekitchen|batt|charge' | grep -v "local.welll" | sort -u || true)"
if [[ -n "$others" ]]; then
    echo "Another charge limiter looks installed:"
    echo "$others" | sed 's/^/    /'
    echo "Uninstall it first; two tools controlling charging fight each other."
fi

bash Scripts/build-app.sh

# Welll used to be called Plateau; its helper is removed by install-helper.sh below.
if [[ -d /Applications/Plateau.app ]]; then
    say "Removing the old Plateau app…"
    pkill -x Plateau 2>/dev/null || true
    rm -rf /Applications/Plateau.app 2>/dev/null || sudo rm -rf /Applications/Plateau.app
fi

say "Installing Welll.app…"
pkill -x Welll 2>/dev/null || true
if ! { rm -rf "$APP" && cp -R build/Welll.app "$APP"; } 2>/dev/null; then
    sudo rm -rf "$APP"
    sudo cp -R build/Welll.app "$APP"
fi

say "Installing the background helper (asks for your password)…"
sudo "$APP/Contents/Resources/install-helper.sh" || true
open "$APP"

say "Checking the helper…"
helper_ok=0
for _ in 1 2 3; do
    sleep 2
    if "$CLI" status >/dev/null 2>&1; then
        helper_ok=1
        break
    fi
done
if [[ $helper_ok -eq 1 ]]; then
    "$CLI" status
    echo
    echo "Welll is in your menu bar. If macOS shows \"Background Items Added\", leave it allowed."
else
    echo "The helper isn't answering. Here's what welllctl doctor found:"
    echo
    "$CLI" doctor || true
fi

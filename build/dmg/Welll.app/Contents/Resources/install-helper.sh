#!/bin/bash
# Installs Welll's background helper from this app bundle. Runs as root: the app's
# "Install helper" button runs it with your password, and install.sh runs it with sudo.
set -euo pipefail

LABEL="local.welll.daemon"
RESOURCES="$(cd "$(dirname "$0")" && pwd)"
CONTENTS="$(dirname "$RESOURCES")"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOADER="/Library/PrivilegedHelperTools/local.welll.loader"
CLI="/usr/local/bin/welllctl"

if [[ $EUID -ne 0 ]]; then
    echo "Run this as root." >&2
    exit 2
fi
for file in "$CONTENTS/Helpers/$LABEL" "$CONTENTS/Helpers/welllctl" \
            "$RESOURCES/$LABEL.plist" "$RESOURCES/load-helper.sh"; do
    if [[ ! -e "$file" ]]; then
        echo "The app bundle is missing $file." >&2
        exit 3
    fi
done

# Welll used to be called Plateau. Stop and remove that helper so two never run at once,
# and keep its settings and the saved macOS charge limit.
OLD_LABEL="local.plateau.daemon"
if [[ -e "/Library/LaunchDaemons/$OLD_LABEL.plist" ]] || launchctl print "system/$OLD_LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$OLD_LABEL" 2>/dev/null || true
    rm -f "/Library/LaunchDaemons/$OLD_LABEL.plist" "/Library/PrivilegedHelperTools/$OLD_LABEL" \
          /Library/PrivilegedHelperTools/local.plateau.loader /usr/local/bin/plateauctl
fi
if [[ -d "/Library/Application Support/Plateau" && ! -d "/Library/Application Support/Welll" ]]; then
    mv "/Library/Application Support/Plateau" "/Library/Application Support/Welll"
fi

# Stop the current helper first; it hands charging back to macOS on the way out.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    sleep 1
fi

mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons /usr/local/bin
# Fresh files, so macOS never sees a rewritten binary under an old signature.
rm -f "$HELPER" "$LOADER" "$CLI"
install -m 755 -o root -g wheel "$CONTENTS/Helpers/$LABEL" "$HELPER"
install -m 755 -o root -g wheel "$CONTENTS/Helpers/welllctl" "$CLI"
install -m 644 -o root -g wheel "$RESOURCES/$LABEL.plist" "$PLIST"
install -m 755 -o root -g wheel "$RESOURCES/load-helper.sh" "$LOADER"
xattr -c "$HELPER" "$CLI" "$PLIST" "$LOADER" 2>/dev/null || true

# Loads it, falling back to the older loader macOS 26 sometimes needs, and explains a refusal.
exec "$LOADER"

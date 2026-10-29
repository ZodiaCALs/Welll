#!/bin/bash
# Removes Welll and hands charging back to macOS.
set -uo pipefail

LABEL="local.welll.daemon"
CLI="/usr/local/bin/welllctl"

echo "Removing Welll. Your Mac will charge the way macOS normally does."
if [[ -x "$CLI" ]]; then
    # Also puts macOS's own Charge Limit back to what you had before Welll.
    "$CLI" restore >/dev/null 2>&1 || true
fi
pkill -x Welll 2>/dev/null || true
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" "$CLI" /Library/PrivilegedHelperTools/local.welll.loader
sudo rm -rf "/Library/Application Support/Welll"
# Leftovers from when Welll was called Plateau.
sudo launchctl bootout system/local.plateau.daemon 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/local.plateau.daemon.plist /Library/PrivilegedHelperTools/local.plateau.daemon \
           /Library/PrivilegedHelperTools/local.plateau.loader /usr/local/bin/plateauctl
sudo rm -rf "/Library/Application Support/Plateau" /Applications/Plateau.app
rm -rf /Applications/Welll.app 2>/dev/null || sudo rm -rf /Applications/Welll.app
echo "Done. If Welll is still listed in System Settings › General › Login Items, remove it there."

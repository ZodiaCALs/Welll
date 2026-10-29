#!/bin/bash
# Loads Welll's background helper into launchd. install.sh puts this at
# /Library/PrivilegedHelperTools/local.welll.loader, and the app's Restart helper
# button runs it with your password. Run it by hand with:
#   sudo /Library/PrivilegedHelperTools/local.welll.loader
# When macOS refuses, it prints the reason instead of failing silently.
set -u

LABEL="local.welll.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
HELPER="/Library/PrivilegedHelperTools/$LABEL"

if [[ $EUID -ne 0 ]]; then
    echo "Run this with sudo." >&2
    exit 2
fi
for file in "$PLIST" "$HELPER"; do
    if [[ ! -e "$file" ]]; then
        echo "$file is missing. Run install.sh again." >&2
        exit 3
    fi
done

# launchd skips plists that aren't owned by root or are writable by others, and the
# "downloaded from the internet" flag can block the files too.
chown root:wheel "$PLIST" "$HELPER"
chmod 644 "$PLIST"
chmod 755 "$HELPER"
xattr -c "$PLIST" "$HELPER" 2>/dev/null

if ! lint=$(plutil -lint "$PLIST" 2>&1); then
    echo "The launch daemon file is damaged: $lint" >&2
    exit 4
fi

loaded() { launchctl print "system/$LABEL" >/dev/null 2>&1; }

if loaded; then
    launchctl bootout "system/$LABEL" 2>/dev/null
    for _ in 1 2 3 4 5; do loaded || break; sleep 1; done
fi

# Clears a "disabled" override left by an earlier unload.
launchctl enable "system/$LABEL" 2>/dev/null

problems=""
if ! output=$(launchctl bootstrap system "$PLIST" 2>&1); then
    problems+="  launchctl bootstrap: ${output}"$'\n'
    # On macOS 26, bootstrap can fail with error 5 even when nothing is loaded, while
    # the older loader still works.
    output=$(launchctl load -w "$PLIST" 2>&1)
    if [[ -n "$output" ]]; then
        problems+="  launchctl load -w: ${output}"$'\n'
    fi
fi

for _ in 1 2 3; do loaded && break; sleep 1; done
if loaded; then
    launchctl kickstart "system/$LABEL" >/dev/null 2>&1
    echo "The helper is loaded."
    exit 0
fi

echo "macOS wouldn't load the helper." >&2
printf '%s' "$problems" >&2

# Login Items & Extensions (Background Task Management) decides what may run in the background.
record=$(sfltool dumpbtm 2>/dev/null | grep -B 8 -A 2 "$PLIST" | grep -E "^ *(Name|Disposition):" | head -4)
if [[ -n "$record" ]]; then
    echo "Login Items & Extensions record:" >&2
    echo "$record" | sed 's/^ */  /' >&2
    if grep -qi "disabled" <<<"$record"; then
        echo "It's switched off. Turn on local.welll.daemon in System Settings › General › Login Items & Extensions, then press Restart helper." >&2
    fi
fi

reasons=$(log show --last 3m --style compact --predicate "eventMessage CONTAINS \"$LABEL\"" 2>/dev/null \
    | grep -v "^Timestamp" | tail -6 | cut -c1-240)
if [[ -n "$reasons" ]]; then
    echo "What macOS logged:" >&2
    echo "$reasons" | sed 's/^/  /' >&2
fi
exit 1

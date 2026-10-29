#!/bin/bash
# Builds build/Welll.app with everything it needs to install its own helper:
#   Contents/MacOS/Welll                      the menu bar app
#   Contents/Helpers/local.welll.daemon       the background helper
#   Contents/Helpers/welllctl                 the command-line tool
#   Contents/Resources/                         icon, launch daemon file and installers
#
# SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" signs for other Macs, with the
# hardened runtime. Without it the build is signed ad hoc, which is fine on your own Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Welll.app"

echo "Building Welll (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Welll" "$APP/Contents/MacOS/Welll"
cp "$BIN/wellld" "$APP/Contents/Helpers/local.welll.daemon"
cp "$BIN/welllctl" "$APP/Contents/Helpers/welllctl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/local.welll.daemon.plist Resources/load-helper.sh Resources/install-helper.sh \
   "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/load-helper.sh" "$APP/Contents/Resources/install-helper.sh"
# Files from a downloaded zip carry a quarantine flag; none of it belongs in the app.
xattr -cr "$APP"

sign() {
    if [[ "$IDENTITY" == "-" ]]; then
        codesign --force --sign - "$@"
    else
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
    fi
}
# Inner code first, then the bundle that seals it.
sign --identifier local.welll.daemon "$APP/Contents/Helpers/local.welll.daemon"
sign --identifier local.welll.ctl "$APP/Contents/Helpers/welllctl"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

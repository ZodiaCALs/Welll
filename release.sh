#!/bin/bash
# Builds Welll and packages it as a disk image: build/Welll-<version>.dmg.
# Open the disk image, drag Welll to Applications, open it, and press Install helper.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   sign for other Macs
#   NOTARY_PROFILE="profile"   also notarise, using a profile saved with
#                              xcrun notarytool store-credentials
# Without them the disk image is signed ad hoc: it opens on your own Mac, but other Macs
# will say it can't be checked for malicious software.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Disk images can only be made on a Mac." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
xattr -dr com.apple.quarantine . 2>/dev/null || true
bash Scripts/build-app.sh

STAGE="build/dmg"
DMG="build/Welll-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Welll.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "Making $DMG…"
hdiutil create -volname "Welll $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "Notarising (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo
echo "Created $DMG"

#!/bin/bash
# Produces a signed, notarized and stapled dist/Orator-<version>.dmg.
# Requires a Developer ID Application certificate and stored notarytool credentials:
#   xcrun notarytool store-credentials orator --apple-id <email> --team-id <team>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${NOTARY_PROFILE:-orator}"
RELEASE=1 bash "$ROOT/scripts/build.sh"
APP="$ROOT/dist/Orator.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
IDENTITY="$(python3 "$ROOT/scripts/signing_identity.py")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Notarize and staple the app itself, so it opens cleanly even after it leaves the disk image.
ditto -c -k --keepParent "$APP" "$WORK/Orator.zip"
xcrun notarytool submit "$WORK/Orator.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

DMG="$ROOT/dist/Orator-$VERSION.dmg"
mkdir "$WORK/stage"
ditto "$APP" "$WORK/stage/Orator.app"
ln -s /Applications "$WORK/stage/Applications"
rm -f "$DMG"
hdiutil create -volname "Orator" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG"

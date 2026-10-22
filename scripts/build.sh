#!/bin/bash
# Builds and signs dist/Orator.app. RELEASE=1 adds secure timestamps for notarization.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.1.2"
BUILD="8"
IDENTITY="$(python3 "$ROOT/scripts/signing_identity.py")"
UV="$(command -v uv)" || { printf '%s\n' 'uv is required to build: https://docs.astral.sh/uv/'; exit 1; }
if [ "$IDENTITY" = "-" ]; then
    printf '%s\n' 'Warning: temporary ad-hoc signing; Accessibility and Input Monitoring grants may not survive updates.'
fi
TIMESTAMP="--timestamp=none"
[ "${RELEASE:-0}" = "1" ] && TIMESTAMP="--timestamp"

swift build --package-path "$ROOT" -c release --jobs 2
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
rm -rf "$ROOT/dist/Orator.app"
ROOT="$ROOT" BIN="$BIN" IDENTITY="$IDENTITY" VERSION="$VERSION" BUILD="$BUILD" UV="$UV" python3 - <<'PY'
import os, pathlib, plistlib, shutil
root = pathlib.Path(os.environ["ROOT"])
binary = pathlib.Path(os.environ["BIN"])
app = root / "dist/Orator.app"
helper = app / "Contents/Helpers/OratorCapture.app"
for bundle, executable, identifier, title in [
    (app, "Orator", "com.devstrategist.orator", "Orator"),
    (helper, "OratorCapture", "com.devstrategist.orator.capture", "Orator Capture")
]:
    (bundle / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (bundle / "Contents/Resources").mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary / executable, bundle / "Contents/MacOS" / executable)
    info = {
        "CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
        "CFBundleName": title, "CFBundleDisplayName": title,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": os.environ["VERSION"],
        "CFBundleVersion": os.environ["BUILD"], "LSMinimumSystemVersion": "14.0",
        "LSApplicationCategoryType": "public.app-category.productivity",
        "OratorStableSigning": os.environ["IDENTITY"] != "-",
        "LSUIElement": True, "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Copyright © 2026 DevStrategist. MIT License.",
        "NSMicrophoneUsageDescription": "Orator records your microphone only while you dictate. Speech recognition runs on this Mac.",
        "NSPrincipalClass": "NSApplication", "CFBundleIconFile": "Orator",
        "NSAppleEventsUsageDescription": "Orator pauses Spotify or Music while you dictate, if you turn that on, and resumes them afterwards.",
    }
    with (bundle / "Contents/Info.plist").open("wb") as f:
        plistlib.dump(info, f)
resources = app / "Contents/Resources"
shutil.copy2(root / "runtime/worker.py", resources / "worker.py")
(resources / "runtime").mkdir(exist_ok=True)
for name in ["pyproject.toml", "uv.lock"]:
    shutil.copy2(root / "runtime" / name, resources / "runtime" / name)
shutil.copy2(root / "Resources/ThirdPartyNotices.txt", resources / "ThirdPartyNotices.txt")
shutil.copy2(root / "LICENSE", resources / "LICENSE.txt")
shutil.copy2(root / "Resources/Brand/Orator.icns", resources / "Orator.icns")
shutil.copy2(root / "Resources/Brand/orator-mark.svg", resources / "orator-mark.svg")
shutil.copytree(root / "Resources/Sounds", resources / "Sounds", dirs_exist_ok=True)
# The bundled uv installs the speech engine on first launch.
shutil.copy2(os.environ["UV"], app / "Contents/Helpers/uv")
print("Packaged:", app)
PY
APP="$ROOT/dist/Orator.app"
codesign --force $TIMESTAMP --options runtime --sign "$IDENTITY" --identifier com.devstrategist.orator.uv "$APP/Contents/Helpers/uv"
codesign --force $TIMESTAMP --options runtime --sign "$IDENTITY" --identifier com.devstrategist.orator.capture \
    --entitlements "$ROOT/Resources/Entitlements/OratorCapture.entitlements" "$APP/Contents/Helpers/OratorCapture.app"
codesign --force $TIMESTAMP --options runtime --sign "$IDENTITY" --identifier com.devstrategist.orator \
    --entitlements "$ROOT/Resources/Entitlements/Orator.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

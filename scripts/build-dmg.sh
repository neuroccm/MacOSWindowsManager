#!/bin/bash
# Build, sign with the stable Apple Development identity (so the macOS
# Accessibility grant survives rebuilds), and package the Desktop DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
# Sign with a stable Apple Development identity so the macOS Accessibility
# grant survives rebuilds. Defaults to the first such identity in the
# keychain; override with SIGN_IDENTITY="Apple Development: … (TEAMID)".
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Apple Development:' | sed -E 's/.*"([^"]+)".*/\1/')}"
if [ -z "$IDENTITY" ]; then echo "No Apple Development signing identity found" >&2; exit 1; fi

xcodegen generate
xcodebuild -scheme MacOSWindowsManager -configuration Release -derivedDataPath ./build/DerivedData build
APP="build/DerivedData/Build/Products/Release/MacOSWindowsManager.app"
codesign -f -s "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

rm -rf /tmp/dmg-stage && mkdir -p /tmp/dmg-stage
cp -R "$APP" /tmp/dmg-stage/
ln -s /Applications /tmp/dmg-stage/Applications
cp README.md /tmp/dmg-stage/README.txt
hdiutil create -volname "MacOSWindowsManager" -srcfolder /tmp/dmg-stage -ov -format UDZO ./MacOSWindowsManager.dmg
cp ./MacOSWindowsManager.dmg "$HOME/Desktop/MacOSWindowsManager.dmg"
hdiutil verify "$HOME/Desktop/MacOSWindowsManager.dmg"
echo "Done: $HOME/Desktop/MacOSWindowsManager.dmg"

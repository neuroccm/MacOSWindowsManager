#!/bin/bash
# Build, sign with the stable Apple Development identity (so the macOS
# Accessibility grant survives rebuilds), and package the Desktop DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="Apple Development: Houman Khosravani (L68Z3UFCT7)"

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

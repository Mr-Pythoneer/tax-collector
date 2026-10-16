#!/bin/bash
# Builds a disk image to share: the app, a shortcut to Applications, and how-to-install notes.
# The app sets itself up from its welcome screen, so no Terminal is needed on the other Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "build/Tax Collector.app/Contents/Info.plist")
STAGE="build/dmg"
DMG="build/TaxCollector-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/Tax Collector.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/How to Install.txt" "$STAGE/"

hdiutil create -volname "Tax Collector $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"

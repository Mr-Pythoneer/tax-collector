#!/bin/bash
# Builds "build.noindex/Tax Collector.app" (arm64 only) and ad-hoc signs it.
# The ".noindex" keeps Spotlight from listing this copy next to the installed one.
set -euo pipefail
cd "$(dirname "$0")/.."

# From the macOS 27 SDK on, SwiftUI's @State is a macro whose plugin comes only with Xcode. With just the
# Command Line Tools, build against the newest macOS 26 SDK instead (the app targets macOS 14 anyway).
CLT=/Library/Developer/CommandLineTools
if [ -z "${SDKROOT:-}" ] && [ "$(xcode-select -p)" = "$CLT" ] && [ ! -e "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
    SDK26="$(ls -d "$CLT"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
    [ -n "$SDK26" ] && export SDKROOT="$SDK26"
fi

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TaxCollector"
APP="build.noindex/Tax Collector.app"
VERSION="0.8.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TaxCollector"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.mrpythoneer.taxcollector</string>
    <key>CFBundleName</key><string>Tax Collector</string>
    <key>CFBundleDisplayName</key><string>Tax Collector</string>
    <key>CFBundleExecutable</key><string>TaxCollector</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>10</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

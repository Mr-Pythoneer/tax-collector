#!/bin/bash
# Builds, installs to ~/Applications and starts Tax Collector at login via a LaunchAgent.
#
# For testing a throwaway copy, set TAXCOLLECTOR_LABEL and TAXCOLLECTOR_DEST. Any other TAXCOLLECTOR_*
# variables (like TAXCOLLECTOR_DATA_DIR) are passed on to the app.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="${TAXCOLLECTOR_LABEL:-io.github.mrpythoneer.taxcollector}"
DEST="${TAXCOLLECTOR_DEST:-$HOME/Applications/Tax Collector.app}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

./scripts/build-app.sh

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
mkdir -p "$(dirname "$DEST")" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$DEST"
cp -R "build.noindex/Tax Collector.app" "$DEST"

ENV_ENTRIES=""
while IFS='=' read -r name value; do
    case "$name" in
        TAXCOLLECTOR_LABEL|TAXCOLLECTOR_DEST) ;;
        TAXCOLLECTOR_*) ENV_ENTRIES+="        <key>$name</key><string>$value</string>"$'\n' ;;
    esac
done < <(env)
ENV_BLOCK=""
if [ -n "$ENV_ENTRIES" ]; then
    ENV_BLOCK="    <key>EnvironmentVariables</key>
    <dict>
$ENV_ENTRIES    </dict>"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/TaxCollector</string>
        <string>--launchd</string>
    </array>
$ENV_BLOCK
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>2</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/TaxCollector.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/TaxCollector.log</string>
</dict>
</plist>
PLIST
plutil -lint -s "$PLIST"

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed to $DEST and started. It will start at every login."

# One copy only. Opening the app from a disk image or Downloads makes it copy itself into /Applications, and an old
# copy left there shows up next to this one (two Tax Collectors in Spotlight and Launchpad). Move any other copy of
# the app to the Trash. Only for the real install: a throwaway test copy (TAXCOLLECTOR_DEST) leaves the others alone.
if [ -z "${TAXCOLLECTOR_DEST:-}" ]; then
    for other in "/Applications/Tax Collector.app"; do
        if [ -d "$other" ] && [ "$other" != "$DEST" ]; then
            mv "$other" "$HOME/.Trash/Tax Collector (old copy, $(date +%H%M%S)).app" \
                && echo "Moved the extra copy at $other to the Trash."
        fi
    done
fi

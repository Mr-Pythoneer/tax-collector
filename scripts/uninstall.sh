#!/bin/bash
# Stops Tax Collector and removes it. Your tasks and proofs stay unless you pass --purge.
set -euo pipefail

LABEL="io.github.mrpythoneer.taxcollector"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

rm -f "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$HOME/Applications/Tax Collector.app"
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/Library/Application Support/TaxCollector"
    echo "Removed Tax Collector and its data."
else
    echo "Removed Tax Collector. Data kept in ~/Library/Application Support/TaxCollector."
fi

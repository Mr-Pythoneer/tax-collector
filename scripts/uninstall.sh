#!/bin/bash
# Stops Tax Collector and removes it. Your tasks and proofs stay unless you pass --purge.
# TAXCOLLECTOR_LABEL and TAXCOLLECTOR_DEST pick a test copy, as in install.sh.
set -euo pipefail

LABEL="${TAXCOLLECTOR_LABEL:-io.github.mrpythoneer.taxcollector}"
DEST="${TAXCOLLECTOR_DEST:-$HOME/Applications/Tax Collector.app}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

rm -f "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/Library/Application Support/TaxCollector"
    echo "Removed Tax Collector and its data."
else
    echo "Removed Tax Collector. Data kept in ~/Library/Application Support/TaxCollector."
fi

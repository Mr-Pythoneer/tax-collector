#!/bin/bash
# End-to-end test of the parent link on this Mac: a relay, a quiet test copy of Tax Collector (its own data
# folder, dry run, no windows), and a fake parent phone that pairs and sends every command.
# Nothing touches the real install. Everything started here is stopped when it ends.
#   scripts/parent-link-e2e.sh                  # uses scripts/mini-relay.mjs
#   RELAY="node server/server.mjs" scripts/parent-link-e2e.sh   # the real relay (takes [port] [setupCode])
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8799}"
SETUP="E2ESETPC0DE1"   # 12 characters of Crockford base32, like a real setup code (spec §6.2)
APP="build.noindex/Tax Collector.app/Contents/MacOS/TaxCollector"
DATA="$(mktemp -d)"
RELAY="${RELAY:-node scripts/mini-relay.mjs}"

[ -x "$APP" ] || ./scripts/build-app.sh >/dev/null
cleanup() {
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
    [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$DATA"
}
trap cleanup EXIT

$RELAY "$PORT" "$SETUP" >"$DATA/relay.log" 2>&1 &
RELAY_PID=$!
sleep 1

# The app gives up on its own after 4 minutes, so it can never be left running.
TAXCOLLECTOR_DATA_DIR="$DATA/app" TAXCOLLECTOR_DRY_RUN=1 TAXCOLLECTOR_TEST_QUIET=1 \
TAXCOLLECTOR_PARENT_SERVER="http://127.0.0.1:$PORT" TAXCOLLECTOR_PARENT_SETUP="$SETUP" \
TAXCOLLECTOR_TEST_PAIR=1 TAXCOLLECTOR_TEST_PAIR_AUTOCONFIRM=1 \
    perl -e 'alarm 240; exec { $ARGV[0] } @ARGV' "$PWD/$APP" >"$DATA/app.log" 2>&1 &
APP_PID=$!

for _ in $(seq 1 40); do
    [ -s "$DATA/app/pairing-code.txt" ] && break
    sleep 0.5
done
if [ ! -s "$DATA/app/pairing-code.txt" ]; then
    echo "FAIL  the test copy never started pairing"
    grep -h "PARENT" "$DATA/app/events.log" 2>/dev/null | tail -5
    exit 1
fi

node scripts/fake-phone.mjs "http://127.0.0.1:$PORT" "$(cat "$DATA/app/pairing-code.txt")"
STATUS=$?
echo "--- what the test copy logged ---"
grep -h -E "PARENT|GUARDIAN paired|REPEAT|LOCK" "$DATA/app/events.log" | cut -c1-160 | tail -40
exit $STATUS

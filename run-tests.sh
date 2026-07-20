#!/bin/sh
set -eu

cd "$(dirname "$0")"

swift run RateGadgetTests

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rate-gadget-bridge-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM

BRIDGE_RESULT=$(printf '%s' \
  '{"session_id":"must-not-be-saved","rate_limits":{"five_hour":{"used_percentage":12.4,"resets_at":1800000000},"seven_day":{"used_percentage":61,"resets_at":1801000000}}}' \
  | env PATH=/usr/bin:/bin RATE_GADGET_TEST_HOME="$TEST_DIR" Resources/claude-statusline.sh)

if [ "$BRIDGE_RESULT" != "5h:12% 7d:61%" ]; then
  echo "FAIL: unexpected bridge output: $BRIDGE_RESULT" >&2
  exit 1
fi
RATE_FILE="$TEST_DIR/Library/Application Support/RateGadget/claude-rate.json"
if [ ! -f "$RATE_FILE" ]; then
  echo "FAIL: bridge did not create a rate file" >&2
  exit 1
fi
if [ "$(stat -f '%Lp' "$RATE_FILE")" != "600" ]; then
  echo "FAIL: bridge rate file is not mode 0600" >&2
  exit 1
fi
PERCENT=$(/usr/bin/plutil -extract five_hour.used_percentage raw "$RATE_FILE")
case "$PERCENT" in
  12.4|12.400000) ;;
  *)
    echo "FAIL: bridge wrote an unexpected percentage: $PERCENT" >&2
    exit 1
    ;;
esac
if /usr/bin/grep -q 'session_id\|must-not-be-saved' "$RATE_FILE"; then
  echo "FAIL: bridge retained private input" >&2
  exit 1
fi

echo "Claude bridge integration test passed"

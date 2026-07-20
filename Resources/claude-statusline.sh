#!/bin/sh
# Claude Code statusLine entry point for RateGadget. Parsing and atomic output
# are handled by JXA, which is included with every supported macOS release.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BRIDGE="$SCRIPT_DIR/rate-gadget-statusline.js"
# The app bundle keeps the resource's source name; the installed copy uses the
# RateGadget-specific name next to this entry point.
[ -f "$BRIDGE" ] || BRIDGE="$SCRIPT_DIR/claude-statusline.js"
exec /usr/bin/osascript -l JavaScript "$BRIDGE"

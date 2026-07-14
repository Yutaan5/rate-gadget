#!/bin/sh
# Claude Code statusLine bridge for rate-gadget.
#
# Reads the JSON Claude Code feeds to a statusLine command on stdin, extracts
# the `rate_limits` snapshot (five_hour / seven_day used_percentage + resets_at),
# writes it to a shared file that the rate-gadget menu bar app watches, and
# echoes a short human-readable line back so Claude Code's own status line
# stays useful.

set -eu

OUT_DIR="$HOME/Library/Application Support/RateGadget"
OUT_FILE="$OUT_DIR/claude-rate.json"
mkdir -p "$OUT_DIR"

input="$(cat)"

# Debug: keep the latest raw payload so integration issues are inspectable.
printf '%s' "$input" > "$OUT_DIR/claude-statusline-last-input.json"

five_pct=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null || true)
five_reset=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null || true)
week_pct=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null || true)
week_reset=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null || true)
now=$(date +%s)

jq -n \
  --argjson five_pct "${five_pct:-null}" \
  --argjson five_reset "${five_reset:-null}" \
  --argjson week_pct "${week_pct:-null}" \
  --argjson week_reset "${week_reset:-null}" \
  --argjson updated_at "$now" \
  '{
    five_hour: (if $five_pct == null then null else {used_percentage: $five_pct, resets_at: $five_reset} end),
    seven_day: (if $week_pct == null then null else {used_percentage: $week_pct, resets_at: $week_reset} end),
    updated_at: $updated_at
  }' > "$OUT_FILE.tmp"
mv "$OUT_FILE.tmp" "$OUT_FILE"

out=""
[ -n "$five_pct" ] && out="5h:${five_pct}%"
[ -n "$week_pct" ] && out="${out:+$out }7d:${week_pct}%"
printf '%s' "$out"

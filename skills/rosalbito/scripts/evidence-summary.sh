#!/usr/bin/env bash
# evidence-summary.sh — latest result per check label for the current run
#   evidence-summary.sh         plain text
#   evidence-summary.sh --md    markdown table rows for the PR body
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ -f "$STATE_FILE" ] || die "no run"
EV="$EVIDENCE_FILE"
[ -s "$EV" ] || { echo "no evidence recorded"; exit 0; }
if [ "${1:-}" = "--md" ]; then
  jq -r 'to_entries | group_by(.value.label) | map(.[-1]) | .[] | "| \(.value.label) | `\(.value.command)` | \(.value.exit) | #\(.key+1) \(.value.ts) |"' <(jq -s '.' "$EV")
else
  jq -r 'to_entries | group_by(.value.label) | map(.[-1]) | .[] | "\(if .value.exit==0 then "✓" else "✗" end) \(.value.label) — exit \(.value.exit) — \(.value.command) — evidence #\(.key+1) @ \(.value.ts)"' <(jq -s '.' "$EV")
fi

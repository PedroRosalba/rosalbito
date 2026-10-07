#!/usr/bin/env bash
# dashboard.sh — rebuild the run index (collect.sh) and render it as one self-contained HTML
# page: $ROSALBITO_HOME/dashboard.html (default ~/.rosalbito). Local file, no server, no CDN.
#
#   dashboard.sh [--no-collect] [--open] [root ...]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,6p' "$0"; exit 0; }
COLLECT=1; OPEN=0; ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-collect) COLLECT=0; shift;;
    --open) OPEN=1; shift;;
    *) ROOTS+=("$1"); shift;;
  esac
done
[ "$COLLECT" = 1 ] && { bash "$SKILL_DIR/scripts/collect.sh" ${ROOTS[@]+"${ROOTS[@]}"} || exit 1; }
INDEX="$ROSALBITO_HOME/runs.jsonl"
[ -f "$INDEX" ] || die "no index at $INDEX (run collect.sh)"
OUT="$ROSALBITO_HOME/dashboard.html"
DATA="$(mktemp)"; trap 'rm -f "$DATA"' EXIT
# `</` is escaped so no string in the data can close the <script> element
jq -sc --arg at "$(now_iso)" --arg index "$INDEX" --slurpfile p "$SKILL_DIR/config/pricing.json" \
  '{generated_at: $at, index: $index, pricing_as_of: $p[0].as_of, runs: .}' "$INDEX" | sed 's#</#<\\/#g' > "$DATA"
awk -v data="$DATA" '
  index($0, "__ROSALBITO_DATA__") { split($0, parts, "__ROSALBITO_DATA__"); printf "%s", parts[1];
    while ((getline line < data) > 0) printf "%s", line; print parts[2]; next }
  { print }' "$SKILL_DIR/templates/dashboard.html" > "$OUT"
echo "dashboard -> $OUT"
[ "$OPEN" = 1 ] && command -v open >/dev/null && open "$OUT"
exit 0

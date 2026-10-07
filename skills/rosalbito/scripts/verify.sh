#!/usr/bin/env bash
# verify.sh — run a check, append the result as JSONL evidence, exit with its exit code
#
#   verify.sh <label> <command...>          e.g. verify.sh test cargo test
#   verify.sh --tail 60 <label> <command>   keep a longer output tail (default 40 lines)
#
# Evidence line: {"ts","run_id","iteration","label","command","exit","duration_s","output_tail"}
# appended to .agent/runs/<run_id>/evidence.jsonl (or .agent/runs/adhoc.jsonl without a run).
# Without a .agent directory the check still runs; nothing is recorded (TRIVIAL tier).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TAIL=40
[ "${1:-}" = "--help" ] && { sed -n '2,10p' "$0"; exit 0; }
if [ "${1:-}" = "--tail" ]; then TAIL="$2"; shift 2; fi
[ $# -ge 2 ] || die "usage: verify.sh <label> <command...>"
LABEL="$1"; shift
CMD="$*"

RUN_ID="adhoc"; ITER=""
if [ -f "$STATE_FILE" ]; then RUN_ID="$(state_get run_id)"; ITER="$(state_get iteration)"; fi

OUT="$(mktemp)"
START=$(date +%s)
( cd "$ROOT" && bash -c "$CMD" ) >"$OUT" 2>&1
EXIT=$?
DUR=$(( $(date +%s) - START ))

if [ -d "$AGENT_DIR" ]; then
  mkdir -p "$RUNS_DIR"
  if [ -f "$STATE_FILE" ]; then FILE="$EVIDENCE_FILE"; else FILE="$RUNS_DIR/adhoc.jsonl"; fi
  jq -cn --arg ts "$(now_iso)" --arg run "$RUN_ID" --arg iter "$ITER" --arg label "$LABEL" \
         --arg cmd "$CMD" --argjson exit "$EXIT" --argjson dur "$DUR" \
         --rawfile tail <(tail -n "$TAIL" "$OUT") \
         '{ts:$ts, run_id:$run, iteration:($iter|tonumber? // null), label:$label, command:$cmd, exit:$exit, duration_s:$dur, output_tail:$tail}' >> "$FILE"
  N=$(wc -l < "$FILE" | tr -d ' ')
  REF="evidence #$N"
else
  REF="not recorded (no .agent dir)"
fi

if [ "$EXIT" -eq 0 ]; then
  echo "✓ $LABEL — exit 0 in ${DUR}s — $REF"
else
  echo "✗ $LABEL — exit $EXIT in ${DUR}s — $REF"
  echo "--- last 20 lines ---"; tail -n 20 "$OUT"
fi
rm -f "$OUT"
exit "$EXIT"

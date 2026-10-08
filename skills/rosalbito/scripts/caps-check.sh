#!/usr/bin/env bash
# caps-check.sh — enforce hard caps from caps.yaml against state + evidence
#
# exit 0  ok (prints iteration/elapsed)
# exit 2  CAP_HIT  (max_iterations_per_run or max_wall_clock_hours)
# exit 3  LOOP_DETECTED (same verify label failed max_same_failure times in a row)
# Caps: <repo>/.agent/caps.yaml, else SKILL_DIR/config/caps.yaml.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,8p' "$0"; exit 0; }
[ -f "$STATE_FILE" ] || die "no run (no $STATE_FILE)"

# a resumed run continues in a new session: record it so usage.sh finds its transcript
SID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$SID" ]; then
  SESS="$(state_get sessions)"
  case ",$SESS," in *",$SID,"*) ;; *) bash "$SKILL_DIR/scripts/state.sh" set sessions "${SESS:+$SESS,}$SID" >/dev/null;; esac
fi

CAPS="$(config_file caps.yaml)"
MAX_IT="$(yaml_scalar "$CAPS" max_iterations_per_run)"; MAX_IT="${MAX_IT:-25}"
MAX_H="$(yaml_scalar "$CAPS" max_wall_clock_hours)";    MAX_H="${MAX_H:-8}"
MAX_SAME="$(yaml_scalar "$CAPS" max_same_failure)";     MAX_SAME="${MAX_SAME:-3}"

IT="$(state_get iteration)"; IT="${IT:-1}"
STARTED="$(state_get started_at)"
NOW=$(date +%s); S=$(iso_to_epoch "$STARTED"); S="${S:-$NOW}"
ELAPSED_H=$(( (NOW - S) / 3600 ))
ELAPSED_M=$(( (NOW - S) / 60 ))

if [ "$IT" -gt "$MAX_IT" ]; then
  echo "CAP_HIT: iteration $IT > max_iterations_per_run $MAX_IT"; exit 2
fi
if [ "$ELAPSED_H" -ge "$MAX_H" ]; then
  echo "CAP_HIT: elapsed ${ELAPSED_H}h >= max_wall_clock_hours $MAX_H"; exit 2
fi

EV="$EVIDENCE_FILE"
if [ -s "$EV" ] && command -v jq >/dev/null; then
  # longest current streak of consecutive failures per label (streak resets on a pass)
  loop="$(jq -rs --argjson max "$MAX_SAME" '
    reduce .[] as $e ({};
      if $e.exit == 0 then .[$e.label] = 0 else .[$e.label] = ((.[$e.label] // 0) + 1) end)
    | to_entries | map(select(.value >= $max)) | .[0].key // empty' "$EV")"
  if [ -n "$loop" ]; then
    echo "LOOP_DETECTED: check '$loop' failed $MAX_SAME+ times in a row — escalate to a fresh-context debugger, then block"; exit 3
  fi
fi
echo "ok: iteration $IT/$MAX_IT, elapsed ${ELAPSED_M}m of ${MAX_H}h"

#!/usr/bin/env bash
# metrics.sh — derive one JSONL metrics line for the current run from state + evidence
# (only what the agent can observe: no token or tool-call counts)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ -f "$STATE_FILE" ] || die "no run"
RUN_ID="$(state_get run_id)"
EV="$AGENT_DIR/evidence/$RUN_ID.jsonl"
ev_total=0; ev_failed=0; same_max=0; labels_passed="[]"
if [ -s "$EV" ]; then
  ev_total=$(wc -l < "$EV" | tr -d ' ')
  ev_failed=$(jq -s 'map(select(.exit != 0)) | length' "$EV")
  same_max=$(jq -s 'reduce .[] as $e ({cur:{},max:0}; if $e.exit==0 then .cur[$e.label]=0 else .cur[$e.label]=((.cur[$e.label]//0)+1) | .max=([.max, .cur[$e.label]]|max) end) | .max' "$EV")
  labels_passed=$(jq -sc 'group_by(.label) | map(select(.[-1].exit==0) | .[0].label)' "$EV")
fi
reviews=$(grep -cE '^- round' "$STATE_FILE" 2>/dev/null || true); reviews="${reviews:-0}"
rejections=$(grep -ciE '^- round.*(reject|fail|changes requested)' "$STATE_FILE" 2>/dev/null || true); rejections="${rejections:-0}"
decisions=$(ls "$AGENT_DIR/decisions" 2>/dev/null | wc -l | tr -d ' ')
open_dec=$(awk '/^## Open decisions/{f=1;next} /^## /{f=0} f && /^- /' "$STATE_FILE" | wc -l | tr -d ' ')
tests_added=$(git -C "$ROOT" diff --stat "$(state_get base_branch)"...HEAD 2>/dev/null | grep -ciE 'test' || true); tests_added="${tests_added:-0}"
jq -cn --arg run "$RUN_ID" --arg risk "$(state_get risk)" --arg status "$(state_get status)" \
  --arg started "$(state_get started_at)" --arg finished "$(now_iso)" --arg pr "$(state_get pr)" \
  --arg human "$(state_get human_level)" --argjson it "$(state_get iteration)" \
  --argjson ev "$ev_total" --argjson evf "$ev_failed" --argjson same "$same_max" --argjson passed "$labels_passed" \
  --argjson rev "$reviews" --argjson rej "$rejections" --argjson dec "$decisions" --argjson open "$open_dec" --argjson tests "$tests_added" \
  '{run_id:$run, risk:$risk, status:$status, started_at:$started, finished_at:$finished, iterations:$it,
    checks_run:$ev, checks_failed:$evf, same_failure_max:$same, checks_passing:$passed,
    review_rounds:$rev, review_rejections:$rej, decisions_recorded:$dec, human_interventions:$open,
    human_level:$human, test_files_touched:$tests, pr:$pr}'

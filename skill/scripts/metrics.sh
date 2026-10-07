#!/usr/bin/env bash
# metrics.sh — derive one JSONL metrics line for a run from its state + evidence, plus the
# usage block (agents, tokens, estimated cost) that usage.sh reads from Claude Code's
# transcripts. The model never self-counts tokens or tool calls.
#
#   metrics.sh                 the current run (runs/current)
#   metrics.sh --run <dir>     any run directory (collect.sh); run from inside its repo
#
# ROSALBITO_NO_USAGE=1 skips the transcript scan (usage: null).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,9p' "$0"; exit 0; }
if [ "${1:-}" = "--run" ]; then
  RD="$(cd "${2:?--run <dir>}" && pwd -P)" || die "no run dir $2"
  STATE_FILE="$RD/state.md"; EVIDENCE_FILE="$RD/evidence.jsonl"
  ROOT="$(cd "$RD/../../.." && pwd -P)"; CONTEXT_DIR="$ROOT/.agent/context"
else
  RD="$(run_dir)"
fi
[ -f "$STATE_FILE" ] || die "no run"
RUN_ID="$(state_get run_id)"
STATUS="$(state_get status)"
EV="$EVIDENCE_FILE"
ev_total=0; ev_failed=0; same_max=0; labels_passed="[]"
if [ -s "$EV" ]; then
  ev_total=$(wc -l < "$EV" | tr -d ' ')
  ev_failed=$(jq -s 'map(select(.exit != 0)) | length' "$EV")
  same_max=$(jq -s 'reduce .[] as $e ({cur:{},max:0}; if $e.exit==0 then .cur[$e.label]=0 else .cur[$e.label]=((.cur[$e.label]//0)+1) | .max=([.max, .cur[$e.label]]|max) end) | .max' "$EV")
  labels_passed=$(jq -sc 'group_by(.label) | map(select(.[-1].exit==0) | .[0].label)' "$EV")
fi
reviews=$(grep -cE '^- round' "$STATE_FILE" 2>/dev/null || true); reviews="${reviews:-0}"
rejections=$(grep -ciE '^- round.*(reject|fail|changes requested)' "$STATE_FILE" 2>/dev/null || true); rejections="${rejections:-0}"
decisions=$(grep -ls "^- run: $RUN_ID" "$CONTEXT_DIR"/adr/*.md 2>/dev/null | wc -l | tr -d ' ')
open_dec=$(awk '/^## Open decisions/{f=1;next} /^## /{f=0} f && /^- /' "$STATE_FILE" | wc -l | tr -d ' ')
tests_added=$(git -C "$ROOT" diff --stat "$(state_get base_branch)"...HEAD 2>/dev/null | grep -ciE 'test' || true); tests_added="${tests_added:-0}"

STARTED="$(state_get started_at)"; UPDATED="$(state_get updated_at)"
FINISHED="$(state_get finished_at)"
case "$STATUS" in done|blocked) FINISHED="${FINISHED:-$UPDATED}";; *) FINISHED="";; esac
s_e="$(iso_to_epoch "$STARTED")"; f_e="$(iso_to_epoch "${FINISHED:-$UPDATED}")"
wall=null; [ -n "$s_e" ] && [ -n "$f_e" ] && wall=$(( (f_e - s_e) / 60 ))
# an unfinished run nobody touched for ROSALBITO_STALE_HOURS (24) is abandoned, not running
stale=false; u_e="$(iso_to_epoch "$UPDATED")"
[ -z "$FINISHED" ] && [ -n "$u_e" ] && [ $(( $(date +%s) - u_e )) -gt $(( ${ROSALBITO_STALE_HOURS:-24} * 3600 )) ] && stale=true

usage=null
if [ "${ROSALBITO_NO_USAGE:-0}" != 1 ]; then
  usage="$(bash "$SKILL_DIR/scripts/usage.sh" --run-id "$RUN_ID" --start "$STARTED" \
    --end "${FINISHED:-$UPDATED}" --sessions "$(state_get sessions)" 2>/dev/null)" || usage=null
  [ -n "$usage" ] || usage=null
fi

jq -cn --arg run "$RUN_ID" --arg risk "$(state_get risk)" --arg status "$STATUS" \
  --arg started "$STARTED" --arg finished "$FINISHED" --arg updated "$UPDATED" --arg pr "$(state_get pr)" \
  --arg human "$(state_get human_level)" --argjson it "$(IT="$(state_get iteration)"; echo "${IT:-0}")" \
  --arg task "$(state_get task)" --arg repo "$(basename "$ROOT")" --arg repo_path "$ROOT" \
  --arg harness "$(state_get harness_version)" \
  --argjson report "$([ -n "$RD" ] && [ -f "$RD/reports/report.md" ] && echo true || echo false)" \
  --argjson blocked_report "$([ -n "$RD" ] && [ -f "$RD/reports/blocked.md" ] && echo true || echo false)" \
  --argjson wall "$wall" --argjson stale "$stale" --argjson usage "$usage" \
  --argjson ev "$ev_total" --argjson evf "$ev_failed" --argjson same "$same_max" --argjson passed "$labels_passed" \
  --argjson rev "$reviews" --argjson rej "$rejections" --argjson dec "$decisions" --argjson open "$open_dec" --argjson tests "$tests_added" \
  '{run_id:$run, repo:$repo, repo_path:$repo_path, task:$task, risk:$risk, status:$status, stale:$stale,
    started_at:$started, finished_at:(if $finished == "" then null else $finished end), updated_at:$updated,
    wall_minutes:$wall, iterations:$it,
    checks_run:$ev, checks_failed:$evf, same_failure_max:$same, checks_passing:$passed,
    review_rounds:$rev, review_rejections:$rej, decisions_recorded:$dec, human_interventions:$open,
    human_level:$human, test_files_touched:$tests, has_report:$report, has_blocked_report:$blocked_report,
    harness_version:(if $harness == "" then null else $harness end), pr:$pr, usage:$usage}'

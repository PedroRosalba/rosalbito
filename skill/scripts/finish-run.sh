#!/usr/bin/env bash
# finish-run.sh — terminal state for a run
#
#   finish-run.sh done   [--pr <url>]
#   finish-run.sh blocked
#
# Sets status and finished_at, writes one metrics line to .agent/runs/metrics.jsonl (with the
# usage block from the transcripts), registers the repo for collect.sh, disarms the driver.
# `done` on a HIGH/CRITICAL run requires runs/<id>/reports/report.md (exit 1 otherwise).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,10p' "$0"; exit 0; }
STATUS="${1:-}"; shift || true
case "$STATUS" in done|blocked) ;; *) die "usage: finish-run.sh done|blocked [--pr url]";; esac
[ -f "$STATE_FILE" ] || die "no run"
PR=""
while [ $# -gt 0 ]; do case "$1" in --pr) PR="$2"; shift 2;; *) die "unknown arg $1";; esac; done

if [ "$STATUS" = done ] && [ "$(tier_rank "$(state_get risk)")" -ge 3 ] && [ ! -f "$(run_dir)/reports/report.md" ]; then
  die "$(state_get risk) run: write $(run_dir)/reports/report.md from templates/report.md before finishing"
fi

S="$SKILL_DIR/scripts/state.sh"
[ -n "$PR" ] && bash "$S" set pr "$PR"
bash "$S" set status "$STATUS"
bash "$S" set finished_at "$(now_iso)"
bash "$S" set next_action "none — run $STATUS"
bash "$S" log "run $STATUS${PR:+ — PR $PR}"
bash "$SKILL_DIR/scripts/metrics.sh" >> "$METRICS_FILE"
register_repo
rm -f "$ROOT/.claude/ralph-loop.local.md"
echo "run $(state_get run_id) $STATUS${PR:+ — $PR}; metrics appended; loop disarmed"

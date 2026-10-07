#!/usr/bin/env bash
# finish-run.sh — terminal state for a run
#
#   finish-run.sh done   [--pr <url>]
#   finish-run.sh blocked
#
# Sets status, writes one metrics line to .agent/metrics.jsonl, disarms the loop driver.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,8p' "$0"; exit 0; }
STATUS="${1:-}"; shift || true
case "$STATUS" in done|blocked) ;; *) die "usage: finish-run.sh done|blocked [--pr url]";; esac
[ -f "$STATE_FILE" ] || die "no run"
PR=""
while [ $# -gt 0 ]; do case "$1" in --pr) PR="$2"; shift 2;; *) die "unknown arg $1";; esac; done

S="$SKILL_DIR/scripts/state.sh"
[ -n "$PR" ] && bash "$S" set pr "$PR"
bash "$S" set status "$STATUS"
bash "$S" set next_action "none — run $STATUS"
bash "$S" log "run $STATUS${PR:+ — PR $PR}"
bash "$SKILL_DIR/scripts/metrics.sh" >> "$AGENT_DIR/metrics.jsonl"
rm -f "$ROOT/.claude/ralph-loop.local.md"
echo "run $(state_get run_id) $STATUS${PR:+ — $PR}; metrics appended; loop disarmed"

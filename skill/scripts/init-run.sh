#!/usr/bin/env bash
# init-run.sh — create .agent/, the feature branch, and .agent/state/current.md
#
#   init-run.sh --task "<task>" --risk <TIER> [--human visibility] [--floor <TIER>] [--branch <name>]
#
# Refuses if an active run (status not done|blocked) already exists: resume it instead.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TASK=""; RISK=""; HUMAN="visibility"; FLOOR="TRIVIAL"; BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="$2"; shift 2;;
    --risk) RISK="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; shift 2;;
    --human) HUMAN="$2"; shift 2;;
    --floor) FLOOR="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    *) die "unknown arg $1";;
  esac
done
[ -n "$TASK" ] || die "--task required"
[ "$(tier_rank "$RISK")" -ge 0 ] || die "--risk must be TRIVIAL|LOW|MEDIUM|HIGH|CRITICAL"
[ "$(tier_rank "$RISK")" -ge "$(tier_rank "$FLOOR")" ] || die "risk $RISK is below path floor $FLOOR"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git repository"

if [ -f "$STATE_FILE" ]; then
  st="$(state_get status)"
  case "$st" in
    done|blocked)
      mkdir -p "$AGENT_DIR/state/history"
      mv "$STATE_FILE" "$AGENT_DIR/state/history/$(state_get run_id).md"
      ;;
    *) die "active run $(state_get run_id) (status=$st). Resume it, or finish-run.sh blocked first.";;
  esac
fi

mkdir -p "$AGENT_DIR"/{state,acceptance,evidence,decisions,reports,understanding}
SLUG="$(slugify "$TASK")"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-${SLUG:-run}"
STARTED="$(now_iso)"

# base branch: the repo default, falling back to current
BASE="$( { git -C "$ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true; } | sed 's#^origin/##')"
[ -n "$BASE" ] || BASE="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
CURRENT="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"

if [ -z "$BRANCH" ]; then
  case "$CURRENT" in
    main|master|HEAD) BRANCH="feature/${SLUG:-rosalbito-run}";;
    *) BRANCH="$CURRENT";;   # already on a working branch: stay on it
  esac
fi
if [ "$BRANCH" != "$CURRENT" ]; then
  git -C "$ROOT" checkout -q -B "$BRANCH"
fi

# keep the driver's state file out of the repo without touching .gitignore
EXCL="$(git -C "$ROOT" rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$EXCL")"
grep -q '^\.claude/\*\.local\.md$' "$EXCL" 2>/dev/null || echo '.claude/*.local.md' >> "$EXCL"
# run artifacts are internal: never committed to the target repo (opt in with ROSALBITO_COMMIT_AGENT_DIR=1)
if [ "${ROSALBITO_COMMIT_AGENT_DIR:-0}" != "1" ]; then
  grep -q '^\.agent/$' "$EXCL" 2>/dev/null || echo '.agent/' >> "$EXCL"
fi

HUMAN_REQUIRED=false
case "$HUMAN" in decision|hard_gate) HUMAN_REQUIRED=true;; esac

sed -e "s|__RUN_ID__|$RUN_ID|g" \
    -e "s|__TASK__|$(printf '%s' "$TASK" | sed -e 's/[\/&|]/\\&/g' -e 's/"/\\"/g')|g" \
    -e "s|__REPO__|$(basename "$ROOT")|g" \
    -e "s|__BRANCH__|$BRANCH|g" \
    -e "s|__BASE__|$BASE|g" \
    -e "s|__RISK__|$RISK|g" \
    -e "s|__FLOOR__|$FLOOR|g" \
    -e "s|__HUMAN_REQUIRED__|$HUMAN_REQUIRED|g" \
    -e "s|__HUMAN_LEVEL__|$HUMAN|g" \
    -e "s|__STARTED_AT__|$STARTED|g" \
    "$SKILL_DIR/templates/current.md" > "$STATE_FILE"

# acceptance contracts are MEDIUM+ ceremony; LOW/TRIVIAL runs do not get an empty one to fill
if [ "$(tier_rank "$RISK")" -ge 2 ]; then
  sed -e "s|__RUN_ID__|$RUN_ID|g" -e "s|__TASK__|$(printf '%s' "$TASK" | sed -e 's/[\/&|]/\\&/g' -e 's/"/\\"/g')|g" \
      "$SKILL_DIR/templates/acceptance.yaml" > "$AGENT_DIR/acceptance/$RUN_ID.yaml"
fi
: > "$AGENT_DIR/evidence/$RUN_ID.jsonl"

echo "run_id=$RUN_ID"
echo "branch=$BRANCH (base $BASE)"
echo "state=$STATE_FILE"

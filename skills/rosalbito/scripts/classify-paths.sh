#!/usr/bin/env bash
# classify-paths.sh — path-based risk floor
#
#   classify-paths.sh [path...]      explicit paths
#   classify-paths.sh                changed paths vs base branch (+ uncommitted)
#
# Prints MIN_TIER=<tier> and one "matched" line per rule hit. Exit 0 always.
# Rules: <repo>/.agent/risk-overrides.yaml, else SKILL_DIR/config/risk-overrides.yaml.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,9p' "$0"; exit 0; }

RULES="$(config_file risk-overrides.yaml)"

if [ $# -gt 0 ]; then
  PATHS="$(printf '%s\n' "$@")"
else
  BASE=""; [ -f "$STATE_FILE" ] && BASE="$(state_get base_branch)"
  [ -n "$BASE" ] || BASE="$(git -C "$ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$BASE" ] || BASE=main
  PATHS="$( { git -C "$ROOT" diff --name-only "$BASE"...HEAD 2>/dev/null; git -C "$ROOT" diff --name-only HEAD 2>/dev/null; git -C "$ROOT" ls-files --others --exclude-standard; } | sort -u )"
fi

# parse rules: blocks of "- match: '<re>'" / "tier: X" / "reason: text"
MAX=0; MAXNAME=TRIVIAL
while IFS=$'\t' read -r re tier reason; do
  [ -n "$re" ] || continue
  hits="$(printf '%s\n' "$PATHS" | grep -iE -- "$re" || true)"
  if [ -n "$hits" ]; then
    echo "matched: $tier — $reason — $(echo "$hits" | tr '\n' ' ')"
    r="$(tier_rank "$tier")"
    if [ "$r" -gt "$MAX" ]; then MAX="$r"; MAXNAME="$tier"; fi
  fi
done < <(awk '
  function flush(){ if (re!="") printf "%s\t%s\t%s\n", re, tier, reason; re=""; tier=""; reason="" }
  /^[[:space:]]*-[[:space:]]*match:/ { flush(); s=$0; sub(/^[[:space:]]*-[[:space:]]*match:[[:space:]]*/, "", s); gsub(/^'"'"'|'"'"'$/, "", s); gsub(/^"|"$/, "", s); re=s; next }
  /^[[:space:]]*tier:/   { s=$0; sub(/^[[:space:]]*tier:[[:space:]]*/, "", s); sub(/[[:space:]]*#.*$/, "", s); tier=s; next }
  /^[[:space:]]*reason:/ { s=$0; sub(/^[[:space:]]*reason:[[:space:]]*/, "", s); reason=s; next }
  END { flush() }' "$RULES")

echo "MIN_TIER=$MAXNAME"

#!/usr/bin/env bash
# state.sh — read/write .agent/state/current.md (the resume entry point)
#
#   state.sh show                 print frontmatter + next action (exit 1 if no run)
#   state.sh get <key>            print a frontmatter scalar
#   state.sh set <key> <value>    set a frontmatter scalar (updates updated_at)
#   state.sh bump                 iteration += 1
#   state.sh log "<message>"      append a timestamped line under ## Log
#   state.sh path                 print the state file path
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cmd="${1:-show}"; shift || true

[ "$cmd" = "--help" ] && { sed -n '2,10p' "$0"; exit 0; }
[ "$cmd" = "path" ] && { echo "$STATE_FILE"; exit 0; }

if [ ! -f "$STATE_FILE" ]; then
  [ "$cmd" = "show" ] && { echo "no rosalbito run in $ROOT (no .agent/state/current.md)"; exit 1; }
  die "no run: $STATE_FILE missing (run init-run.sh first)"
fi

set_scalar() {
  local key="$1" value="$2" tmp="$STATE_FILE.tmp.$$"
  # only touch the frontmatter block; escape sed specials in value
  local esc; esc=$(printf '%s' "$value" | sed -e 's/[\/&|]/\\&/g')
  awk -v key="$key" -v val="$esc" '
    BEGIN{fm=0; done=0}
    /^---$/ {fm++; print; next}
    fm==1 && !done && $0 ~ "^"key":" {print key": "val; done=1; next}
    {print}
    END{}
  ' "$STATE_FILE" > "$tmp"
  if ! grep -q "^${key}:" "$tmp"; then
    # key absent: insert before closing ---
    awk -v key="$key" -v val="$esc" 'BEGIN{fm=0} /^---$/ {fm++; if(fm==2){print key": "val}} {print}' "$STATE_FILE" > "$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
}

case "$cmd" in
  show)
    frontmatter "$STATE_FILE"
    ;;
  get)
    [ $# -ge 1 ] || die "get <key>"
    state_get "$1"
    ;;
  set)
    [ $# -ge 2 ] || die "set <key> <value>"
    set_scalar "$1" "$2"
    set_scalar updated_at "$(now_iso)"
    ;;
  bump)
    cur="$(state_get iteration)"; cur="${cur:-0}"
    set_scalar iteration "$((cur + 1))"
    set_scalar updated_at "$(now_iso)"
    echo "iteration $((cur + 1))"
    ;;
  log)
    [ $# -ge 1 ] || die "log <message>"
    grep -q '^## Log' "$STATE_FILE" || printf '\n## Log\n' >> "$STATE_FILE"
    printf -- '- %s %s\n' "$(now_iso)" "$*" >> "$STATE_FILE"
    set_scalar updated_at "$(now_iso)"
    ;;
  *) die "unknown command: $cmd";;
esac

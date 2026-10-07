#!/usr/bin/env bash
# collect.sh — rebuild the cross-repo run index $ROSALBITO_HOME/runs.jsonl (default ~/.rosalbito)
#
#   collect.sh [--full] [root ...]
#
# Incremental: a run whose state, evidence, reports and session transcripts have not changed
# since the previous collect keeps its previous line (no transcript re-parse).
# --full recomputes everything.
# Repos: the ones init-run/finish-run registered ($ROSALBITO_HOME/repos) plus every repo with
# an .agent/ directory under the roots (default: $ROSALBITO_ROOTS, else $HOME; depth 5). One line per
# run, finished or not, with the usage block from usage.sh. Lines from an old metrics.jsonl
# whose run directory is gone are kept and marked legacy. Local only: nothing leaves the machine.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,14p' "$0"; exit 0; }
FULL=0; [ "${1:-}" = "--full" ] && { FULL=1; shift; }
[ $# -gt 0 ] || set -- ${ROSALBITO_ROOTS:-$HOME}
mkdir -p "$ROSALBITO_HOME"
OUT="$ROSALBITO_HOME/runs.jsonl"; TMPOUT="$OUT.tmp.$$"; : > "$TMPOUT"
PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
PREV=""; [ "$FULL" = 0 ] && [ -s "$OUT" ] && PREV="$OUT"

# previous line of a run that was already finished and has not changed since the last collect
cached_line() {  # cached_line <run_id> <run_dir>
  [ -n "$PREV" ] || return 1
  local f line
  for f in "$2/state.md" "$2/evidence.jsonl" "$2/reports"; do
    [ ! -e "$f" ] || [ "$f" -ot "$PREV" ] || return 1
  done
  line="$(grep -F "\"run_id\":\"$1\"" "$PREV" | head -1)"; [ -n "$line" ] || return 1
  case "$(jq -r .status <<< "$line")" in
    done|blocked) ;;
    *)  # still open: also require its transcripts (and subagents') to be unchanged
      local sid
      for sid in $(jq -r '.usage.sessions[]?' <<< "$line"); do
        [ -z "$(find "$PROJ"/*/"$sid".jsonl "$PROJ"/*/"$sid"/subagents -newer "$PREV" 2>/dev/null | head -1)" ] || return 1
      done;;
  esac
  echo "$line"
}

repos="$(
  cat "$ROSALBITO_HOME/repos" 2>/dev/null
  for r in "$@"; do
    find "$r" -maxdepth 5 \( -name node_modules -o -name Library -o -name .Trash -o -name target -o -name .git \) -prune \
      -o -type d -name .agent -print 2>/dev/null | sed 's#/\.agent$##'
  done
)"
repos="$(printf '%s\n' "$repos" | sed '/^$/d' | while read -r r; do [ -d "$r/.agent" ] && (cd "$r" && pwd -P); done | sort -u)"

n=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  for rd in "$repo"/.agent/runs/*/; do
    rd="${rd%/}"
    [ -L "$rd" ] && continue                      # runs/current
    [ -f "$rd/state.md" ] || continue
    if ! cached_line "$(basename "$rd")" "$rd" >> "$TMPOUT"; then
      (cd "$repo" && bash "$SKILL_DIR/scripts/metrics.sh" --run "$rd") >> "$TMPOUT"
    fi && n=$((n + 1))
  done
  # legacy lines (pre context/runs layout, or a run dir removed since)
  for mf in "$repo/.agent/metrics.jsonl" "$repo/.agent/runs/metrics.jsonl"; do
    [ -f "$mf" ] || continue
    while IFS= read -r line; do
      id="$(jq -r '.run_id // empty' <<< "$line" 2>/dev/null)"; [ -n "$id" ] || continue
      grep -qF "\"run_id\":\"$id\"" "$TMPOUT" && continue
      if [ -n "$PREV" ] && [ "$mf" -ot "$PREV" ] && grep -F "\"run_id\":\"$id\"" "$PREV" | grep -F '"legacy":true' >> "$TMPOUT"; then
        n=$((n + 1)); continue
      fi
      st="$(jq -r '.started_at' <<< "$line")"; fin="$(jq -r '.finished_at' <<< "$line")"
      usage="$(bash "$SKILL_DIR/scripts/usage.sh" --run-id "$id" --start "$st" --end "$fin" 2>/dev/null)"
      jq -c --arg repo "$(basename "$repo")" --arg path "$repo" --argjson usage "${usage:-null}" \
        '. + {repo:$repo, repo_path:$path, legacy:true, usage:$usage}' <<< "$line" >> "$TMPOUT" && n=$((n + 1))
    done < "$mf"
  done
done <<< "$repos"

jq -sc 'sort_by(.started_at) | .[]' "$TMPOUT" > "$TMPOUT.sorted" && mv "$TMPOUT.sorted" "$OUT"; rm -f "$TMPOUT"   # atomic for the live server
echo "$n runs from $(printf '%s\n' "$repos" | sed '/^$/d' | wc -l | tr -d ' ') repos -> $OUT"

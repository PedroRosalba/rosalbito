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
# run, finished or not, with the usage block from usage.sh and input_size {task_chars,
# first_context_tokens (orchestrator's first request), diff {files, added, removed, base, head,
# branch, base_branch} | null}. Lines from an old metrics.jsonl whose run directory is gone are
# kept and marked legacy. Local only: nothing leaves the machine.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,16p' "$0"; exit 0; }
FULL=0; [ "${1:-}" = "--full" ] && { FULL=1; shift; }
[ $# -gt 0 ] || set -- ${ROSALBITO_ROOTS:-$HOME}
mkdir -p "$ROSALBITO_HOME"
OUT="$ROSALBITO_HOME/runs.jsonl"; TMPOUT="$OUT.tmp.$$"; : > "$TMPOUT"
PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
PREV=""; [ "$FULL" = 0 ] && [ -s "$OUT" ] && PREV="$OUT"

# a line written by an older collect lacks the newer fields: recompute it once
current_schema() { jq -e '(.legacy == true or has("fix_cycles")) and (.usage == null or (.usage.totals | has("total_tokens")))' >/dev/null 2>&1 <<< "$1"; }

# previous line of a run that was already finished and has not changed since the last collect
cached_line() {  # cached_line <run_id> <run_dir>
  [ -n "$PREV" ] || return 1
  local f line
  for f in "$2/state.md" "$2/evidence.jsonl" "$2/reports"; do
    [ ! -e "$f" ] || [ "$f" -ot "$PREV" ] || return 1
  done
  line="$(grep -F "\"run_id\":\"$1\"" "$PREV" | head -1)"; [ -n "$line" ] || return 1
  current_schema "$line" || return 1
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

# --- input size: what a run was handed, and what it changed --------------------------------
# Read-only git (`git -C`, no fetch, no index refresh). The diff is the run's branch as it was
# when the run finished against its base as it was when the run started, from their merge-base,
# so a base that later merged the branch does not hide the change. Committed changes only.
# Anything missing (repo, branch, base, history) gives diff: null, never a guess. Numstat
# results are reused from the previous index while merge-base and head are unchanged.
export GIT_OPTIONAL_LOCKS=0
DIFFPREV=""; [ -s "$OUT" ] && DIFFPREV="$OUT"
git_ref() {  # local branch, else origin's remote-tracking copy, else a remote ref named as such (upstream/dev)
  local r
  for r in "refs/heads/$2" "refs/remotes/origin/$2" "refs/remotes/$2"; do
    git -C "$1" rev-parse -q --verify "$r^{commit}" 2>/dev/null && return 0
  done
  return 1
}
diff_json() {  # diff_json <repo> <branch> <base|""> <started_at> <finished_at|"">
  local repo="$1" branch="$2" base="$3" st="$4" fin="$5" head base_tip base_at mb fe hit
  [ -n "$branch" ] && [ -n "$st" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo null; return; }
  if [ -z "$base" ]; then
    base="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; base="${base#origin/}"
    [ -n "$base" ] || for b in main master; do git_ref "$repo" "$b" >/dev/null && { base="$b"; break; }; done
  fi
  [ -n "$base" ] && head="$(git_ref "$repo" "$branch")" && base_tip="$(git_ref "$repo" "$base")" || { echo null; return; }
  if [ -n "$fin" ]; then
    fe="$(iso_to_epoch "$fin")"; [ -n "$fe" ] || { echo null; return; }
    head="$(git -C "$repo" rev-list -1 --first-parent --before="$(epoch_to_iso $((fe + 600)))" "$head" 2>/dev/null)"
  fi
  base_at="$(git -C "$repo" rev-list -1 --first-parent --before="$st" "$base_tip" 2>/dev/null)"; base_at="${base_at:-$base_tip}"
  [ -n "$head" ] && mb="$(git -C "$repo" merge-base "$base_at" "$head" 2>/dev/null)" && [ -n "$mb" ] || { echo null; return; }
  if [ -n "$DIFFPREV" ]; then
    hit="$(grep -F "\"head\":\"$head\"" "$DIFFPREV" | jq -c --arg b "$mb" --arg h "$head" \
      'select(.input_size.diff.base == $b and .input_size.diff.head == $h) | .input_size.diff' 2>/dev/null | head -1)"
    [ -n "$hit" ] && { jq -c --arg br "$branch" --arg bb "$base" '.branch = $br | .base_branch = $bb' <<< "$hit"; return; }
  fi
  local ns; ns="$(git -C "$repo" diff --numstat --no-ext-diff --no-textconv "$mb" "$head" 2>/dev/null)" || { echo null; return; }
  awk 'NF { f++; if ($1 != "-") a += $1; if ($2 != "-") r += $2 } END { print f + 0, a + 0, r + 0 }' <<< "$ns" | {
    read -r f a r
    jq -cn --argjson f "$f" --argjson a "$a" --argjson r "$r" --arg b "$mb" --arg h "$head" --arg br "$branch" --arg bb "$base" \
      '{files: $f, added: $a, removed: $r, base: $b, head: $h, branch: $br, base_branch: $bb}'
  }
}
with_input_size() {  # with_input_size <line> <run_dir|"">: the line plus input_size
  local line="$1" rd="$2" repo branch="" base="" st fin diff
  repo="$(jq -r '.repo_path // empty' <<< "$line")"
  st="$(jq -r '.started_at // empty' <<< "$line")"; fin="$(jq -r '.finished_at // empty' <<< "$line")"
  if [ -n "$rd" ] && [ -f "$rd/state.md" ]; then
    branch="$(frontmatter "$rd/state.md" | sed -n 's/^branch:[[:space:]]*//p' | head -1 | sed -e 's/^"\(.*\)"$/\1/')"
    base="$(frontmatter "$rd/state.md" | sed -n 's/^base_branch:[[:space:]]*//p' | head -1 | sed -e 's/^"\(.*\)"$/\1/')"
  fi
  diff="null"; [ -n "$repo" ] && [ -n "$branch" ] && diff="$(diff_json "$repo" "$branch" "$base" "$st" "$fin")"
  jq -c --argjson diff "${diff:-null}" '. + {input_size: {
      task_chars: (if (.task | type) == "string" then (.task | length) else null end),
      first_context_tokens: ([.usage.agents[]? | select(.agent_id == "main")] | sort_by(.first_ts) | .[0].first_context_tokens // null),
      diff: $diff}}' <<< "$line"
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
    if line="$(cached_line "$(basename "$rd")" "$rd")" && jq -e '.input_size and (.status == "done" or .status == "blocked")' >/dev/null 2>&1 <<< "$line"; then
      echo "$line" >> "$TMPOUT" && n=$((n + 1)); continue   # finished and unchanged: its diff is fixed (--full re-measures)
    fi
    [ -n "$line" ] || line="$(cd "$repo" && bash "$SKILL_DIR/scripts/metrics.sh" --run "$rd")"
    [ -n "$line" ] && with_input_size "$line" "$rd" >> "$TMPOUT" && n=$((n + 1))
  done
  # legacy lines (pre context/runs layout, or a run dir removed since)
  for mf in "$repo/.agent/metrics.jsonl" "$repo/.agent/runs/metrics.jsonl"; do
    [ -f "$mf" ] || continue
    while IFS= read -r line; do
      id="$(jq -r '.run_id // empty' <<< "$line" 2>/dev/null)"; [ -n "$id" ] || continue
      grep -qF "\"run_id\":\"$id\"" "$TMPOUT" && continue
      if [ -n "$PREV" ] && [ "$mf" -ot "$PREV" ]; then
        line="$(grep -F "\"run_id\":\"$id\"" "$PREV" | grep -F '"legacy":true' | grep -F '"input_size"' | head -1)"
        if [ -n "$line" ] && current_schema "$line"; then echo "$line" >> "$TMPOUT"; n=$((n + 1)); continue; fi
      fi
      st="$(jq -r '.started_at' <<< "$line")"; fin="$(jq -r '.finished_at' <<< "$line")"
      usage="$(bash "$SKILL_DIR/scripts/usage.sh" --run-id "$id" --start "$st" --end "$fin" 2>/dev/null)"
      line="$(jq -c --arg repo "$(basename "$repo")" --arg path "$repo" --argjson usage "${usage:-null}" \
        '. + {repo:$repo, repo_path:$path, legacy:true, usage:$usage}' <<< "$line")" \
        && with_input_size "$line" "" >> "$TMPOUT" && n=$((n + 1))
    done < "$mf"
  done
done <<< "$repos"

jq -sc 'sort_by(.started_at) | .[]' "$TMPOUT" > "$TMPOUT.sorted" && mv "$TMPOUT.sorted" "$OUT"; rm -f "$TMPOUT"   # atomic for the live server
echo "$n runs from $(printf '%s\n' "$repos" | sed '/^$/d' | wc -l | tr -d ' ') repos -> $OUT"

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
current_schema() { jq -e '(.legacy == true or has("fix_cycles_command_changed")) and (.usage == null or (.usage.totals | has("peak_context_tokens")))
  and (.input_size == null or ((.input_size | has("first_context_mid_session")) and (.input_size.diff == null or (.input_size.diff | has("basis")))))' >/dev/null 2>&1 <<< "$1"; }

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
# Read-only git (`git -C`, no fetch, no index refresh), committed changes only. Head = the branch
# as it was when the run finished (10 min slack; its tip while open). Lower bound, in order:
#   "since run start": the branch's own commit at started_at, when it descends from the merge-base
#                      with the base as of started_at, so a wrong or stale base_branch in state.md
#                      cannot inflate the diff with work that was already on the branch;
#   "vs merge-base":   that merge-base, when the branch's commit at start does not descend from it;
#   "since repo creation": the empty tree, when the repository itself was created during the run.
# The diff is null unless lower..head has at least one commit dated inside the run's window: a
# branch rewritten after the run, or a run that committed nothing, gives null, never a confident
# wrong number. Numstat results are reused from the previous index while lower and head match.
export GIT_OPTIONAL_LOCKS=0
DIFFPREV=""; [ -s "$OUT" ] && DIFFPREV="$OUT"
git_ref() {  # the fresher of the local branch and origin's copy (the one containing the other, else
             # origin), else a remote ref named as such (upstream/dev)
  local l o
  l="$(git -C "$1" rev-parse -q --verify "refs/heads/$2^{commit}" 2>/dev/null)"
  o="$(git -C "$1" rev-parse -q --verify "refs/remotes/origin/$2^{commit}" 2>/dev/null)"
  if [ -n "$l" ] && [ -n "$o" ]; then
    if git -C "$1" merge-base --is-ancestor "$o" "$l" 2>/dev/null; then echo "$l"; else echo "$o"; fi
  elif [ -n "$l$o" ]; then echo "$l$o"
  else git -C "$1" rev-parse -q --verify "refs/remotes/$2^{commit}" 2>/dev/null; fi
}
TEST_PATH_AWK='p ~ /(^|\/)(tests?|__tests__|specs?|e2e)\// || p ~ /[._-](test|spec)s?\.[A-Za-z0-9]+$/ || p ~ /(^|\/)test_[^\/]*\.py$/'
diff_json() {  # diff_json <repo> <branch> <base|""> <started_at> <finished_at|"">
  local repo="$1" branch="$2" base="$3" st="$4" fin="$5" head base_tip base_at mb="" start lower basis range se he hit ns
  [ -n "$branch" ] && [ -n "$st" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo null; return; }
  se="$(iso_to_epoch "$st")"; [ -n "$se" ] || { echo null; return; }
  if [ -n "$fin" ]; then he="$(iso_to_epoch "$fin")"; [ -n "$he" ] || { echo null; return; }; else he="$(date +%s)"; fi
  he=$((he + 600))
  head="$(git_ref "$repo" "$branch")" || { echo null; return; }
  [ -z "$fin" ] || head="$(git -C "$repo" rev-list -1 --first-parent --before="$(epoch_to_iso "$he")" "$head" 2>/dev/null)"
  [ -n "$head" ] || { echo null; return; }
  if [ -z "$base" ]; then
    base="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; base="${base#origin/}"
    [ -n "$base" ] || for b in main master; do git_ref "$repo" "$b" >/dev/null && { base="$b"; break; }; done
  fi
  # the base as it was at run start (fresher copy first); a copy that did not exist yet, shares no
  # history with head, or already contains head (merged after the run) cannot bound the run's work
  if [ -n "$base" ]; then
    for base_tip in $(git_ref "$repo" "$base") $(git -C "$repo" rev-parse -q --verify "refs/heads/$base^{commit}" 2>/dev/null); do
      base_at="$(git -C "$repo" rev-list -1 --first-parent --before="$st" "$base_tip" 2>/dev/null)"
      [ -n "$base_at" ] && mb="$(git -C "$repo" merge-base "$base_at" "$head" 2>/dev/null)" && [ -n "$mb" ] && [ "$mb" != "$head" ] && break
      mb=""
    done
  fi
  start="$(git -C "$repo" rev-list -1 --first-parent --before="$st" "$head" 2>/dev/null)"
  range="$head"
  if [ -n "$start" ] && { [ -z "$mb" ] || git -C "$repo" merge-base --is-ancestor "$mb" "$start" 2>/dev/null; }; then
    lower="$start"; basis="since run start"; range="$start..$head"
  elif [ -n "$mb" ]; then lower="$mb"; basis="vs merge-base"; range="$mb..$head"
  elif [ -z "$start" ] && [ "$(git -C "$repo" log -1 --format=%ct "$(git -C "$repo" rev-list --max-parents=0 "$head" 2>/dev/null | tail -1)" 2>/dev/null)" -ge "$se" ] 2>/dev/null; then
    lower="$(git -C "$repo" hash-object -t tree /dev/null)"; basis="since repo creation"   # the run created the repo: empty tree
  else echo null; return; fi
  # the run must own at least one commit in the range (by committer date, inside its window)
  [ "$lower" != "$head" ] && git -C "$repo" log --format=%ct "$range" 2>/dev/null \
    | awk -v lo="$se" -v hi="$he" '$1 >= lo && $1 <= hi { found = 1 } END { exit !found }' || { echo null; return; }
  if [ -n "$DIFFPREV" ]; then
    hit="$(grep -F "\"head\":\"$head\"" "$DIFFPREV" | jq -c --arg b "$lower" --arg h "$head" \
      'select(.input_size.diff.base == $b and .input_size.diff.head == $h and (.input_size.diff | has("test_files"))) | .input_size.diff' 2>/dev/null | head -1)"
    [ -n "$hit" ] && { jq -c --arg br "$branch" --arg bb "$base" --arg mb "$mb" --arg basis "$basis" \
      '.branch = $br | .base_branch = $bb | .merge_base = (if $mb == "" then null else $mb end) | .basis = $basis' <<< "$hit"; return; }
  fi
  ns="$(git -C "$repo" diff --numstat --no-ext-diff --no-textconv "$lower" "$head" 2>/dev/null)" || { echo null; return; }
  awk -F'\t' "NF { f++; if (\$1 != \"-\") a += \$1; if (\$2 != \"-\") r += \$2; p = \$3; if ($TEST_PATH_AWK) t++ }
       END { print f + 0, a + 0, r + 0, t + 0 }" <<< "$ns" | {
    read -r f a r t
    jq -cn --argjson f "$f" --argjson a "$a" --argjson r "$r" --argjson t "$t" --arg b "$lower" --arg h "$head" \
      --arg br "$branch" --arg bb "$base" --arg mb "$mb" --arg basis "$basis" \
      '{files: $f, added: $a, removed: $r, test_files: $t, base: $b, head: $h, basis: $basis,
        merge_base: (if $mb == "" then null else $mb end), branch: $br, base_branch: $bb}'
  }
}
with_input_size() {  # with_input_size <line> <run_dir|"">: the line plus input_size; test_files_touched from its diff
  local line="$1" rd="$2" repo branch="" base="" st fin diff
  repo="$(jq -r '.repo_path // empty' <<< "$line")"
  st="$(jq -r '.started_at // empty' <<< "$line")"; fin="$(jq -r '.finished_at // empty' <<< "$line")"
  if [ -n "$rd" ] && [ -f "$rd/state.md" ]; then
    branch="$(frontmatter "$rd/state.md" | sed -n 's/^branch:[[:space:]]*//p' | head -1 | sed -e 's/^"\(.*\)"$/\1/')"
    base="$(frontmatter "$rd/state.md" | sed -n 's/^base_branch:[[:space:]]*//p' | head -1 | sed -e 's/^"\(.*\)"$/\1/')"
  fi
  diff="null"; [ -n "$repo" ] && [ -n "$branch" ] && diff="$(diff_json "$repo" "$branch" "$base" "$st" "$fin")"
  jq -c --argjson diff "${diff:-null}" '([.usage.agents[]? | select(.agent_id == "main")] | sort_by(.first_ts) | .[0]) as $o
    | . + {test_files_touched: (if $diff then $diff.test_files else null end), input_size: {
      task_chars: (if (.task | type) == "string" then (.task | length) else null end),
      first_context_tokens: (if $o then $o.first_context_tokens else null end),
      first_context_mid_session: (if $o then $o.mid_session else null end),
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

# runs that read the same session over overlapping windows (usage.sh's 10 min slack included) share
# transcript messages: usage_overlaps lists them; when the usage is identical, every run but the
# earliest is usage_duplicate_of it, and aggregates count that usage once
jq -sc 'def win: [(.started_at | fromdateiso8601? // null),
                  ((.finished_at // .updated_at) | fromdateiso8601? // null | if . then . + 600 else null end)];
  sort_by(.started_at) | . as $all | map(. as $r | ($r.usage.sessions // []) as $ss | ($r | win) as $w
    | [$all[] | select(.run_id != $r.run_id and ((.usage.sessions // []) as $o | any($ss[]; . as $x | $o | index([$x]) != null)))
       | (win) as $v | select($w[0] != null and $w[1] != null and $v[0] != null and $v[1] != null and $w[0] <= $v[1] and $v[0] <= $w[1])] as $ov
    | . + {usage_overlaps: ($ov | map(.run_id)),
           usage_duplicate_of: ([$ov[] | select(.usage.totals.total_tokens == $r.usage.totals.total_tokens
               and .usage.totals.cost_usd == $r.usage.totals.cost_usd
               and (.started_at < $r.started_at or (.started_at == $r.started_at and .run_id < $r.run_id)))] | .[0].run_id // null)})
  | .[]' "$TMPOUT" > "$TMPOUT.sorted" && mv "$TMPOUT.sorted" "$OUT"; rm -f "$TMPOUT"   # atomic for the live server
echo "$n runs from $(printf '%s\n' "$repos" | sed '/^$/d' | wc -l | tr -d ' ') repos -> $OUT"

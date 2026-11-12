#!/usr/bin/env bash
# eval-candidates.sh — merged PRs worth turning into eval drafts (see references/evals.md)
#
#   eval-candidates.sh --since <YYYY-MM-DD> [--repo <owner/name>]... [--author <login>]
#   eval-candidates.sh --built <pr-url>     exit 0 if built or dropped, 1 if not
#
# The list needs at least one of --repo/--author. --repo takes a concrete repo, never owner/*.
# It prints a TSV header, then rows, best first:
#   score  repo  number  additions  files  title  url
# additions, files and the limits count code and test files only.
# Code: a known source extension. Test: a test directory or name, any case, except that
# *Test.* and *Tests.* are CamelCase only (lower-cased, they would match latest.js). Test wins
# over code. Docs, lockfiles, .github/ and everything else are neither, and count for nothing.
# Known overcount: src/spec/parser.rs, src/test_utils.rs and assets/fixtures/x.json classify as
# test. Reading the diff in the pick step catches those.
# A file with 0 additions and 0 deletions (a pure rename or mode change) counts for nothing.
# Left out: no code file, no test file (a file only removed qualifies as neither), over
# max_additions or max_files (config/evals.yaml), or already built or dropped.
# max_additions limits additions plus deletions, removed files included, so a mass deletion
# can't rank near the top; the additions column shows additions only.
# Built or dropped: a source_pr in <evals_dir>/tasks/*/task.toml or a line in
# <evals_dir>/dropped.txt, compared as <owner>/<repo>/pull/<n>. A renamed repo may be proposed
# again, which is acceptable: dropping the owner would mark other/tools#12 built because of
# acme/tools#12. No evals dir means nothing is left out. ROSALBITO_EVALS_DIR overrides evals_dir.
# Score: max_additions - (additions + deletions), plus 200 if the body closes an issue (Fixes #n,
# Closes #n, **Fixes** #n), because the issue is a natural prompt. HTML comments don't count,
# nor does a keyword right after "not" or "n't". Ties sort by repo, then number.
# Progress goes to stderr every 25 PRs: each PR costs one gh api call.
# Only the header = no candidates. A gh failure exits 1 and prints no table. Bad arguments exit 2.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,29p' "$0"; exit 0; }

USAGE="usage: eval-candidates.sh --since <YYYY-MM-DD> [--repo <owner/name>]... [--author <login>] | --built <pr-url>"
ISSUE_BONUS=200
SEARCH_LIMIT=1000   # GitHub search returns at most this many results per query
PROGRESS_EVERY=25
# the optional first group is the negation: a match that has it earns nothing
ISSUE_RE="((?:not|n['’]t)\\s+)?(?<![a-z0-9_/-])\\*{0,2}(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\*{0,2}:?\\*{0,2}\\s+(?:[\\w.-]+/[\\w.-]+#\\d+|#\\d+|https://github\\.com/[\\w.-]+/[\\w.-]+/issues/\\d+)"

bad() { echo "rosalbito: $*" >&2; exit 2; }

SINCE="" AUTHOR="" CHECK=""; REPOS=()
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || bad "$USAGE"
  case "$1" in
    --since)  SINCE="$2" ;;
    --repo)   REPOS+=("$2")
              case "$2" in *'*'*) bad "--repo takes a concrete owner/name, not a pattern: '$2'. Pass each repo the patrol collected." ;; esac ;;
    --author) AUTHOR="$2" ;;
    --built)  CHECK="$2" ;;
    *) bad "$USAGE" ;;
  esac
  shift 2
done

CFG="$(config_file evals.yaml)"
EVALS_DIR="${ROSALBITO_EVALS_DIR:-$(yaml_scalar "$CFG" evals_dir)}"; EVALS_DIR="${EVALS_DIR:-$HOME/Projects/pr-evals}"
case "$EVALS_DIR" in "~"*) EVALS_DIR="$HOME${EVALS_DIR#\~}" ;; esac

# URLs on stdin -> <owner>/<repo>/pull/<n> keys. Scheme, case and anything after the number go.
to_keys() {
  tr '[:upper:]' '[:lower:]' \
    | sed -nE 's|^[[:space:]]*([a-z]+://)?(www\.)?github\.com/([^/]+)/([^/]+)/pull/([0-9]+)([/?#].*)?[[:space:]]*$|\3/\4/pull/\5|p'
}
pr_key() { printf '%s\n' "$1" | to_keys; }

# every built or dropped PR, one key per line
built_keys() {
  { cat "$EVALS_DIR"/tasks/*/task.toml 2>/dev/null \
      | sed -nE "s/^[[:space:]]*[\"']?source_pr[\"']?[[:space:]]*=[[:space:]]*[\"']([^\"']*)[\"'].*/\1/p"
    cat "$EVALS_DIR/dropped.txt" 2>/dev/null
  } | to_keys | sort -u
}
BUILT="$(built_keys)"
is_built() { case $'\n'"$BUILT"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

if [ -n "$CHECK" ]; then
  [ -z "$SINCE$AUTHOR" ] && [ ${#REPOS[@]} -eq 0 ] || bad "--built takes no other flags"
  key="$(pr_key "$CHECK")"
  [ -n "$key" ] || bad "not a GitHub PR URL: '$CHECK'"
  is_built "$key"; exit $?
fi

[[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || bad "$USAGE"
[ ${#REPOS[@]} -gt 0 ] || [ -n "$AUTHOR" ] || bad "$USAGE"
for r in ${REPOS[@]+"${REPOS[@]}"}; do
  [[ "$r" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || bad "--repo must be owner/name, got '$r'"
done
command -v jq >/dev/null || die "jq is required"

MAX_ADD="$(yaml_scalar "$CFG" max_additions)"; MAX_ADD="${MAX_ADD:-800}"
MAX_FILES="$(yaml_scalar "$CFG" max_files)";   MAX_FILES="${MAX_FILES:-12}"
[[ "$MAX_ADD$MAX_FILES" =~ ^[0-9]+$ ]] || die "max_additions and max_files in $CFG must be numbers"

# file_kind <lower-cased path> <path>: sets KIND to code, test or other.
# Docs and lockfiles come first: tests/README.md is not a test. So does .github/:
# .github/workflows/test_x.yml is CI, not a test.
file_kind() {
  local path="/$1" base="${1##*/}" exact="${2##*/}"
  KIND=other
  case "$base" in
    cargo.lock|pnpm-lock.yaml|package-lock.json|npm-shrinkwrap.json|yarn.lock|bun.lock|bun.lockb|\
    poetry.lock|uv.lock|gemfile.lock|composer.lock|flake.lock|go.sum) return ;;
    *.md|*.mdx|changelog*) return ;;
  esac
  case "$path" in
    */docs/*|*/.changeset/*|*/.github/*) return ;;
    */test/*|*/tests/*|*/__tests__/*|*/testdata/*|*/spec/*|*/specs/*|*/e2e/*|*/__snapshots__/*|*/fixtures/*)
      KIND=test; return ;;
  esac
  case "$base" in
    *_test.*|*-test.*|*.test.*|*.spec.*|*_spec.*|test_*|tests.rs|conftest.py|*.snap) KIND=test; return ;;
  esac
  case "$exact" in *Test.*|*Tests.*) KIND=test; return ;; esac
  case "$base" in
    *.rs|*.c|*.cc|*.cpp|*.cxx|*.c++|*.h|*.hpp|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.go|\
    *.java|*.kt|*.rb|*.php|*.swift|*.zig) KIND=code ;;
  esac
}

# appends "repo, number, url, closes-an-issue, title" rows to PRS. The title goes last and has
# its tabs and newlines removed, so it can't shift a column.
PRS=""
collect() {
  local json n rows
  json="$(gh search prs "$@" --merged --merged-at ">=$SINCE" --limit "$SEARCH_LIMIT" \
    --json number,title,url,body,repository ${AUTHOR:+--author "$AUTHOR"} </dev/null)" \
    || die "gh search prs failed"
  jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1 || die "gh search prs did not return a JSON list"
  n="$(jq length <<<"$json")"
  [ "$n" -lt "$SEARCH_LIMIT" ] || echo "rosalbito: warning: search stopped at $n results ($*), use a later --since" >&2
  rows="$(jq -r --arg re "$ISSUE_RE" '.[] | [.repository.nameWithOwner, (.number | tostring), .url,
      (if any((.body // "") | gsub("<!--[\\s\\S]*?(?:-->|\\z)"; "") | match($re; "gi"); .captures[0].string == null)
       then "1" else "0" end),
      ((.title // "") | gsub("[\\t\\r\\n]+"; " "))] | join("\t")' <<<"$json")" \
    || die "could not read the gh search prs output"
  [ -z "$rows" ] || PRS+="$rows"$'\n'
}
if [ ${#REPOS[@]} -gt 0 ]; then
  for r in "${REPOS[@]}"; do collect --repo "$r"; done
else
  collect
fi

TOTAL="$(printf '%s' "$PRS" | grep -c .)"
OUT="" seen=0
while IFS=$'\t' read -r repo number url closes title; do
  [ -n "$repo" ] || continue
  seen=$((seen+1))
  [ $((seen % PROGRESS_EVERY)) -ne 0 ] || echo "rosalbito: checked $seen of $TOTAL PRs" >&2
  is_built "$(pr_key "$url")" && continue
  files="$(gh api --paginate "repos/$repo/pulls/$number/files?per_page=100" \
    --jq '.[] | [.additions, .deletions, .status, (.filename | ascii_downcase), .filename] | @tsv' </dev/null)" \
    || die "gh api failed for the files of $url"
  additions=0 changed=0 count=0 code=0 tests=0
  while IFS=$'\t' read -r added deleted status lower path; do
    [ -n "$path" ] || continue
    [ $((added+deleted)) -gt 0 ] || continue    # a pure rename or mode change
    file_kind "$lower" "$path"
    [ "$KIND" != other ] || continue
    additions=$((additions+added)); changed=$((changed+added+deleted)); count=$((count+1))
    [ "$status" != removed ] || continue    # part of the diff, but it doesn't qualify the PR
    case "$KIND" in code) code=$((code+1)) ;; test) tests=$((tests+1)) ;; esac
  done <<<"$files"
  [ "$code" -gt 0 ] && [ "$tests" -gt 0 ] || continue
  [ "$changed" -le "$MAX_ADD" ] && [ "$count" -le "$MAX_FILES" ] || continue
  score=$((MAX_ADD - changed + closes * ISSUE_BONUS))
  printf -v row '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$score" "$repo" "$number" "$additions" "$count" "$title" "$url"
  OUT+="$row"
done <<<"$PRS"

printf 'score\trepo\tnumber\tadditions\tfiles\ttitle\turl\n'
# -u: a repo passed twice lists its PRs twice
[ -z "$OUT" ] || printf '%s' "$OUT" | LC_ALL=C sort -u -t $'\t' -k1,1nr -k2,2 -k3,3n

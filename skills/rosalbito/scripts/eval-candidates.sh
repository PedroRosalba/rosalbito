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


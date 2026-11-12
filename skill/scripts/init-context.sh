#!/usr/bin/env bash
# init-context.sh — create the repo's internal .agent/ tree and keep it out of git. Idempotent.
#
#   init-context.sh            in the target repo root
#
# Layout (see references/state-schema.md):
#   .agent/context/{understanding,diagrams,glossary,adr,telemetry}   durable: what we know
#   .agent/runs/<run_id>/                                             ephemeral: what happened
#
# Mechanical enforcement of "docs stay internal":
#   - `.agent/` goes into .git/info/exclude (never .gitignore: the target repo is not modified)
#   - the Matt Pocock skills (grilling, domain-modeling) hard-code `CONTEXT.md` at the repo
#     root and `docs/adr/`. Both become symlinks into .agent/context/ and are excluded too, so
#     those skills write where we want without knowing it. Existing real files are left alone
#     and reported.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,15p' "$0"; exit 0; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git repository"

mkdir -p "$CONTEXT_DIR"/{understanding,diagrams,glossary,adr,telemetry} "$RUNS_DIR"

EXCL="$(git -C "$ROOT" rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$EXCL")"
exclude() { grep -qxF "$1" "$EXCL" 2>/dev/null || echo "$1" >> "$EXCL"; }
exclude '.agent/'
exclude '.claude/*.local.md'

if [ "${ROSALBITO_COMMIT_AGENT_DIR:-0}" = "1" ]; then
  echo "note: ROSALBITO_COMMIT_AGENT_DIR=1 — .agent/ exclusion skipped by request" >&2
  sed -i.bak '/^\.agent\/$/d' "$EXCL" && rm -f "$EXCL.bak"
fi

# redirect the Matt Pocock domain docs into context/ (symlink + exclude)
link() {  # link <repo-relative path> <target relative to that path's dir>
  local path="$ROOT/$1" target="$2"
  if [ -L "$path" ]; then
    exclude "$1"
  elif [ -e "$path" ]; then
    echo "note: $1 exists as a real file/dir — left alone; the domain docs will be written there (repo-owned)" >&2
  else
    mkdir -p "$(dirname "$path")"
    ln -s "$target" "$path"
    exclude "$1"
    echo "linked $1 -> $target"
  fi
}
link CONTEXT.md .agent/context/glossary/CONTEXT.md
link docs/adr ../.agent/context/adr
# docs/ may have been created only to hold the symlink; it is empty from git's point of view

echo "context: $CONTEXT_DIR"
echo "runs:    $RUNS_DIR"
echo "exclude: $EXCL ($(grep -c . "$EXCL") entries)"

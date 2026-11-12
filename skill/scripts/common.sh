#!/usr/bin/env bash
# Shared helpers for rosalbito scripts. Source, do not execute.

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

ROOT="$(repo_root)"
AGENT_DIR="$ROOT/.agent"            # internal, never committed (see references/state-schema.md)
CONTEXT_DIR="$AGENT_DIR/context"    # durable: what we know about this repo
RUNS_DIR="$AGENT_DIR/runs"          # ephemeral: what happened during each run
CURRENT_LINK="$RUNS_DIR/current"    # symlink -> runs/<run_id>
STATE_FILE="$CURRENT_LINK/state.md"
EVIDENCE_FILE="$CURRENT_LINK/evidence.jsonl"
METRICS_FILE="$RUNS_DIR/metrics.jsonl"

# directory of the current run (resolved), empty if none
run_dir() { [ -L "$CURRENT_LINK" ] && [ -d "$CURRENT_LINK/" ] && (cd "$CURRENT_LINK" && pwd -P) || true; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# iso -> epoch seconds, portable between BSD date (macOS) and GNU date
iso_to_epoch() {
  local ts="$1"
  if date -j >/dev/null 2>&1; then
    date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null
  else
    date -u -d "$ts" +%s 2>/dev/null
  fi
}

epoch_to_iso() {
  if date -j >/dev/null 2>&1; then date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; else date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; fi
}

# cross-repo index (collect.sh, dashboard.sh): local only, never pushed anywhere
ROSALBITO_HOME="${ROSALBITO_HOME:-$HOME/.rosalbito}"
register_repo() {
  mkdir -p "$ROSALBITO_HOME" 2>/dev/null || return 0
  grep -qxF "$ROOT" "$ROSALBITO_HOME/repos" 2>/dev/null || echo "$ROOT" >> "$ROSALBITO_HOME/repos"
}

die() { echo "rosalbito: $*" >&2; exit 1; }

# config lookup: repo context override first, then skill default
config_file() {
  local name="$1"
  if [ -f "$CONTEXT_DIR/$name" ]; then echo "$CONTEXT_DIR/$name"; else echo "$SKILL_DIR/config/$name"; fi
}

# read a flat scalar `key: value` from a yaml/frontmatter file
yaml_scalar() {
  local file="$1" key="$2"
  sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -1 | sed -e 's/[[:space:]]*#.*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# frontmatter only (between the first two --- lines)
frontmatter() { sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$1"; }

state_get() { frontmatter "$STATE_FILE" | sed -n "s/^${1}:[[:space:]]*//p" | head -1 | sed -e 's/^"\(.*\)"$/\1/'; }

tier_rank() {
  case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
    TRIVIAL) echo 0;; LOW) echo 1;; MEDIUM) echo 2;; HIGH) echo 3;; CRITICAL) echo 4;; *) echo -1;;
  esac
}

# lower-case, dash-separated, at most 40 chars, trimmed to a word boundary when truncated
slugify() {
  local s; s="$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
  if [ "${#s}" -gt 40 ]; then s="$(echo "$s" | cut -c1-41 | sed -e 's/-[a-z0-9]*$//')"; fi
  echo "$s" | cut -c1-40 | sed 's/-$//'
}

#!/usr/bin/env bash
# Shared helpers for rosalbito scripts. Source, do not execute.

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

ROOT="$(repo_root)"
AGENT_DIR="$ROOT/.agent"
STATE_FILE="$AGENT_DIR/state/current.md"

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

die() { echo "rosalbito: $*" >&2; exit 1; }

# config lookup: repo override first, then skill default
config_file() {
  local name="$1"
  if [ -f "$AGENT_DIR/$name" ]; then echo "$AGENT_DIR/$name"; else echo "$SKILL_DIR/config/$name"; fi
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

slugify() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]+/-/g' -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40; }

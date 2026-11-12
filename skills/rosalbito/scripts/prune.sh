#!/usr/bin/env bash
# prune.sh — free disk on this machine by deleting only what rebuilds or re-downloads itself.
# Machine-wide, not per repo. Dry run unless told otherwise.
#
#   prune.sh                      dry run: what would go, how much, plus suggestions
#   prune.sh --apply              delete it
#   prune.sh --auto               what init-run.sh calls (in the background): --apply, but only when
#                                 the last prune is older than interval_days, or free disk is under
#                                 min_free_gb and the last prune is older than 6h; otherwise a no-op.
#                                 ROSALBITO_PRUNE=0 turns --auto off
#   --only caches|artifacts|tmp   restrict to one class (repeatable)
#   --root <dir>                  scan this dir for projects instead of the configured roots (repeatable)
#
# Deletes (each class is regenerable by construction):
#   caches     package-manager and tool download caches: npm, yarn, pnpm (unreferenced), Homebrew
#              downloads, uv, pip, Cypress, node-gyp, go-build, cargo registry, Docker *build* cache
#   artifacts  node_modules (next to a package.json) and cargo target/ (carrying CACHEDIR.TAG) of
#              projects where no file was touched in stale_days
#   tmp        Claude Code scratch dirs ($ROSALBITO_CLAUDE_TMP, default /tmp/claude-<uid>/*) untouched
#              in tmp_stale_days
# Never deletes source, git data, worktrees, toolchains, app data, Docker images or volumes: stale
# clean worktrees and non-default rust toolchains are only listed as suggestions.
# Config: config/prune.yaml, keys overridden by $ROSALBITO_HOME/prune.yaml.
# Log: one JSON line per --apply/--auto run in $ROSALBITO_HOME/prune.jsonl.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MODE=dry; ONLY=""; ROOTS_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply; shift;;
    --auto) MODE=auto; shift;;
    --only) case "${2:-}" in caches|artifacts|tmp) ONLY="$ONLY $2";; *) die "--only takes caches|artifacts|tmp";; esac; shift 2;;
    --root) [ -d "${2:-}" ] || die "--root ${2:-}: not a directory"; ROOTS_ARG="$ROOTS_ARG $(cd "$2" && pwd -P)"; shift 2;;
    -h|--help) sed -n '2,27p' "$0"; exit 0;;
    *) die "unknown arg $1";;
  esac
done
want() { [ -z "$ONLY" ] || case " $ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }

# --- config: per key, $ROSALBITO_HOME/prune.yaml wins over the skill default ---
cfg() {
  local v=""
  [ -f "$ROSALBITO_HOME/prune.yaml" ] && v="$(yaml_scalar "$ROSALBITO_HOME/prune.yaml" "$1")"
  [ -n "$v" ] || v="$(yaml_scalar "$SKILL_DIR/config/prune.yaml" "$1")"
  echo "$v"
}
INTERVAL_DAYS="$(cfg interval_days)"; INTERVAL_DAYS="${INTERVAL_DAYS:-7}"
MIN_FREE_GB="$(cfg min_free_gb)";     MIN_FREE_GB="${MIN_FREE_GB:-20}"
STALE_DAYS="$(cfg stale_days)";       STALE_DAYS="${STALE_DAYS:-14}"
TMP_STALE_DAYS="$(cfg tmp_stale_days)"; TMP_STALE_DAYS="${TMP_STALE_DAYS:-3}"
CLAUDE_TMP="${ROSALBITO_CLAUDE_TMP:-/tmp/claude-$(id -u)}"
STAMP="$ROSALBITO_HOME/prune.last"
LOG="$ROSALBITO_HOME/prune.jsonl"

free_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}'; }
human() { awk -v k="${1:-0}" 'BEGIN{ if (k>=1048576) printf "%.1fG", k/1048576; else if (k>=1024) printf "%.0fM", k/1024; else printf "%dK", k }'; }
size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }

# --- --auto: decide whether this is the time ---
if [ "$MODE" = auto ]; then
  [ "${ROSALBITO_PRUNE:-1}" = 0 ] && exit 0
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"; case "$last" in ''|*[!0-9]*) last=0;; esac
  age=$(( $(date +%s) - last ))
  free_gb=$(( $(free_kb) / 1048576 ))
  if [ "$age" -lt $(( INTERVAL_DAYS * 86400 )) ] && ! { [ "$free_gb" -lt "$MIN_FREE_GB" ] && [ "$age" -ge 21600 ]; }; then
    exit 0
  fi
  mkdir -p "$ROSALBITO_HOME" && date +%s > "$STAMP"   # stamp first: a concurrent init-run must not start a second prune
fi
APPLY=0; [ "$MODE" = dry ] || APPLY=1

TOTAL=0; COUNT=0; ITEMS=""
# act on one path: size it, then delete (apply) or list (dry). $1=class $2=path $3=note
take() {
  local class="$1" path="$2" note="${3:-}" kb
  [ -e "$path" ] || return 0
  case "$path" in ""|/|"$HOME"|"$HOME/") return 0;; esac   # belt and braces: never a root
  kb="$(size_kb "$path")"; [ "${kb:-0}" -gt 0 ] || return 0
  if [ "$APPLY" = 1 ]; then
    rm -rf "$path" 2>/dev/null || { echo "  could not remove $path" >&2; return 0; }
    printf '  freed      %7s  %-9s %s%s\n' "$(human "$kb")" "$class" "$path" "${note:+  ($note)}"
  else
    printf '  would free %7s  %-9s %s%s\n' "$(human "$kb")" "$class" "$path" "${note:+  ($note)}"
  fi
  TOTAL=$((TOTAL + kb)); COUNT=$((COUNT + 1))
}
# a tool's own cleanup command, sized by the dir it empties. $1=label $2=dir-or-empty $3...=command
take_cmd() {
  local label="$1" dir="$2" kb=0 shown="?"; shift 2
  if [ -n "$dir" ]; then   # sized by its dir: nothing there, nothing to do
    kb="$(size_kb "$dir")"; [ "${kb:-0}" -gt 0 ] || return 0; shown="$(human "$kb")"
  fi
  if [ "$APPLY" = 1 ]; then
    "$@" >/dev/null 2>&1 || { echo "  $label: cleanup command failed" >&2; return 0; }
    printf '  freed      %7s  %-9s %s\n' "$shown" caches "$label"
  else
    printf '  would free %7s  %-9s %s\n' "$shown" caches "$label"
  fi
  TOTAL=$((TOTAL + kb)); COUNT=$((COUNT + 1))
}

FREE_BEFORE="$(free_kb)"
echo "rosalbito prune ($([ "$APPLY" = 1 ] && echo apply || echo "dry run: --apply to delete")) — free $(human "$FREE_BEFORE")"

# --- caches ---
# a background prune must not empty a cache under a live install or build
BUSY="$(pgrep -x '(cargo|rustc|npm|npx|yarn|pnpm|bun|uv|pip|pip3|brew)' 2>/dev/null | head -1)"
if want caches && [ "$MODE" = auto ] && [ -n "$BUSY" ]; then
  echo "caches: skipped, a package manager or build is running"
elif want caches; then
  echo "caches"
  take caches "$HOME/.npm/_cacache"
  take caches "$HOME/.yarn/berry/cache"
  take caches "$HOME/Library/Caches/Yarn"
  take caches "$HOME/.cache/yarn"
  take caches "$HOME/Library/Caches/pip"
  take caches "$HOME/.cache/pip"
  take caches "$HOME/Library/Caches/Cypress"
  take caches "$HOME/.cache/Cypress"
  take caches "$HOME/Library/Caches/node-gyp"
  take caches "$HOME/.cache/node-gyp"
  take caches "$HOME/Library/Caches/go-build"
  take caches "$HOME/.cache/go-build"
  take caches "$HOME/.cargo/registry/cache"
  take caches "$HOME/.cargo/registry/src"
  # Homebrew: downloads only. Never `brew cleanup`: it removes old kegs that installed formulae may still load.
  command -v brew >/dev/null 2>&1 && take caches "$(brew --cache 2>/dev/null)"
  command -v uv >/dev/null 2>&1 && take_cmd "uv cache" "$(uv cache dir 2>/dev/null)" uv cache clean
  command -v pnpm >/dev/null 2>&1 && take_cmd "pnpm store (unreferenced)" "" pnpm store prune
  # Docker: build cache only. Images, containers and volumes are data (the guard denies deleting them too).
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    take_cmd "docker build cache" "" docker builder prune -af
  fi
fi

# --- roots: configured, else the parents of repos rosalbito has worked in ---
ROOTS="$ROOTS_ARG"
if [ -z "$ROOTS" ]; then
  for r in $(cfg roots); do r="${r/#\~/$HOME}"; [ -d "$r" ] && ROOTS="$ROOTS $r"; done
fi
if [ -z "$ROOTS" ] && [ -f "$ROSALBITO_HOME/repos" ]; then
  ROOTS="$(while read -r repo; do [ -d "$repo" ] && dirname "$repo"; done < "$ROSALBITO_HOME/repos" | sort -u | tr '\n' ' ')"
fi

# a project is fresh when any of its own files changed within N days (artifacts, .git excluded)
CHECKED=""   # newline list of "fresh|stale<TAB>project" (bash 3.2: no associative arrays)
PSTATE=""   # set by project_state (not echoed: a $(...) subshell would drop the cache)
project_state() {
  local proj="$1" hit
  hit="$(printf '%s\n' "$CHECKED" | awk -F'\t' -v p="$proj" '$2==p{print $1; exit}')"
  if [ -z "$hit" ]; then
    if [ -n "$(find "$proj" \( -name node_modules -o -name target -o -name .git \) -prune -o -type f -mtime -"$STALE_DAYS" -print 2>/dev/null | head -1)" ]; then hit=fresh; else hit=stale; fi
    CHECKED="$CHECKED
$hit	$proj"
  fi
  PSTATE="$hit"
}

LIST="$(mktemp)"; trap 'rm -f "$LIST"' EXIT
if want artifacts && [ -n "$ROOTS" ]; then
  echo "artifacts (projects untouched ${STALE_DAYS}d) in:$ROOTS"
  for root in $ROOTS; do
    find "$root" -name .git -prune -o -type d \( -name node_modules -o -name target \) -prune -print 2>/dev/null
  done | sort -u > "$LIST"
  while read -r d; do   # read from a file, not a pipe: totals and the project cache must survive the loop
    parent="$(dirname "$d")"
    case "$(basename "$d")" in
      node_modules) [ -f "$parent/package.json" ] || continue;;
      target) [ -f "$d/CACHEDIR.TAG" ] || continue;;   # cargo writes it; any other target/ is not ours
    esac
    # tracked in git (test fixtures, vendored deps): part of the source, not an install
    [ -z "$(git -C "$parent" ls-files -- "$(basename "$d")" 2>/dev/null | head -1)" ] || continue
    proj="$(git -C "$parent" rev-parse --show-toplevel 2>/dev/null || echo "$parent")"
    project_state "$proj"; [ "$PSTATE" = stale ] || continue
    take artifacts "$d"
  done < "$LIST"
fi

if want tmp && [ -d "$CLAUDE_TMP" ]; then
  echo "tmp (Claude scratch untouched ${TMP_STALE_DAYS}d) in $CLAUDE_TMP"
  for d in "$CLAUDE_TMP"/*/; do
    d="${d%/}"; [ -d "$d" ] || continue
    [ -n "$(find "$d" -mtime -"$TMP_STALE_DAYS" -print 2>/dev/null | head -1)" ] && continue
    take tmp "$d"
  done
fi

# --- suggestions: never deleted here, Pedro's call ---
SUG=""
if command -v rustup >/dev/null 2>&1; then
  active="$(rustup default 2>/dev/null | awk '{print $1}')"
  for tc in $(rustup toolchain list 2>/dev/null | awk '{print $1}'); do
    [ "$tc" = "$active" ] && continue
    case "$tc" in nightly-*) continue;; esac   # commonly needed by tooling; keep
    kb="$(size_kb "${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$tc")"
    SUG="$SUG
  $(human "$kb")  rust toolchain $tc  →  rustup toolchain uninstall $tc"
  done
fi
for root in $ROOTS; do
  find "$root" -maxdepth 4 -name .git -type f 2>/dev/null
done | sort -u > "$LIST"
while read -r g; do
  wt="$(dirname "$g")"
  grep -q '/worktrees/' "$g" 2>/dev/null || continue            # a linked worktree, not a submodule
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
  [ "$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo x)" = 0 ] || continue   # pushed
  last="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"
  [ $(( $(date +%s) - last )) -ge $(( STALE_DAYS * 86400 )) ] || continue
  main="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')"
  SUG="$SUG
  $(human "$(size_kb "$wt")")  clean, pushed worktree idle ${STALE_DAYS}d+: $wt  →  git -C $main worktree remove $wt"
done < "$LIST"
[ -n "$SUG" ] && { echo "suggestions (not deleted; clean and pushed, still your call)$SUG"; }

FREE_AFTER="$(free_kb)"
if [ "$APPLY" = 1 ]; then
  echo "freed $(human "$TOTAL") across $COUNT items — free now $(human "$FREE_AFTER")"
  mkdir -p "$ROSALBITO_HOME" && date +%s > "$STAMP"
  printf '{"at":"%s","mode":"%s","items":%d,"freed_kb":%d,"free_kb_before":%d,"free_kb_after":%d}\n' \
    "$(now_iso)" "$MODE" "$COUNT" "$TOTAL" "${FREE_BEFORE:-0}" "${FREE_AFTER:-0}" >> "$LOG"
else
  echo "would free $(human "$TOTAL") across $COUNT items — run with --apply to delete"
fi

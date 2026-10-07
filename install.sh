#!/usr/bin/env bash
# install.sh — standalone install: link the skills into ~/.claude/skills and register the
# hard-gate hook. Alternative to the Claude Code plugin; use one or the other, not both.
#   ./install.sh               install (idempotent; re-run after pulling to move to current paths)
#   ./install.sh --uninstall   remove the symlinks and the hook entry (idempotent); refuses while
#                              the plugin is not enabled, so you never end up with no guard
#   ./install.sh --uninstall --force   remove anyway
# Backs up settings.json before every real edit; never writes it if jq fails. Run from anywhere.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="$HOME/.claude/skills"
SETTINGS="$HOME/.claude/settings.json"
HOOK="$HERE/skills/rosalbito/hooks/rosalbito-guard.sh"
HOOK_CMD="\"$HOOK\""          # quoted: the hook command runs in a shell, paths may contain spaces

FORCE=0
case "${1:-}" in
  "") ;;
  --uninstall) [ "${2:-}" = "--force" ] && FORCE=1 || [ -z "${2:-}" ] || { echo "unknown argument: $2 (try --help)" >&2; exit 1; } ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 1 ;;
esac
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

# jq helpers over settings.json, null-safe for any group shape inside PreToolUse.
#   guard: a hook entry whose command mentions rosalbito-guard.sh (any path, quoted or not)
#   strip: remove every guard entry; drop a group only if removing guards emptied it
#   registered: exactly one guard entry, it is $cmd, in a group whose matcher is "Bash"
JQ_DEFS='
def hs: if type == "object" and (.hooks | type) == "array" then .hooks else [] end;
def guard: (if type == "object" then .command else null end) as $c
           | ($c | type) == "string" and ($c | contains("rosalbito-guard.sh"));
def pre: .hooks.PreToolUse // [];
def guards: [pre[] | hs[] | select(guard)];
def registered: (guards | length) == 1
  and any(pre[]; (if type == "object" then .matcher else null end) == "Bash" and any(hs[]; guard and .command == $cmd));
def strip: if (.hooks.PreToolUse | type) == "array" then
    .hooks.PreToolUse |= map(if any(hs[]; guard)
      then (.hooks |= map(select(guard | not))) | select((.hooks | length) > 0) else . end)
  else . end;
'
q() { jq --arg cmd "$HOOK_CMD" "$JQ_DEFS $1" "$SETTINGS"; }   # q <filter>: query settings.json

check_settings() {
  if ! jq -e 'type == "object" and ((.hooks // {}) | type) == "object"
              and ((.hooks.PreToolUse // []) | type) == "array"' "$SETTINGS" >/dev/null 2>&1; then
    echo "error: $SETTINGS is not valid JSON or has an unexpected hooks shape; fix it by hand. Untouched." >&2
    exit 1
  fi
}

# settings_edit <filter>: apply, keep a backup, return 1 if nothing changed semantically.
# Any jq failure or a non-object result aborts the script with settings.json untouched.
settings_edit() {
  local tmp; tmp="$(mktemp)"
  if ! q "$1" > "$tmp" || [ ! -s "$tmp" ] || ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; echo "error: jq failed; $SETTINGS untouched" >&2; exit 1
  fi
  if [ "$(jq -S . "$tmp")" = "$(jq -S . "$SETTINGS")" ]; then rm -f "$tmp"; return 1; fi
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)" && mv "$tmp" "$SETTINGS" \
    || { rm -f "$tmp"; echo "error: could not back up or replace $SETTINGS" >&2; exit 1; }
}

if [ "${1:-}" = "--uninstall" ]; then
  # Removing the standalone guard while the plugin's guard is not active leaves no guard at all.
  if [ "$FORCE" -eq 0 ] && [ -f "$SETTINGS" ] \
    && jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | strings | select(test("rosalbito-guard\\.sh"))] | length > 0' "$SETTINGS" >/dev/null 2>&1 \
    && ! jq -e '.enabledPlugins["rosalbito@rosalbito"] == true' "$SETTINGS" >/dev/null 2>&1; then
    echo "refusing: the rosalbito plugin is not enabled in $SETTINGS, so removing this guard would leave none." >&2
    echo "Install the plugin first (/plugin install rosalbito@rosalbito), or re-run with --uninstall --force." >&2
    exit 1
  fi
  # A link is ours if it points into a rosalbito checkout (old `skill/` or new `skills/`
  # layout), or dangles with that shape. Anything else is left alone.
  unlink_skill() {  # unlink_skill <name>
    local link="$SKILLS/$1" target repo
    if [ ! -L "$link" ]; then
      if [ -e "$link" ]; then echo "warning: $link is not a symlink; leaving it alone" >&2; fi
      return 0
    fi
    target="$(readlink "$link")"; target="${target%/}"
    case "$target" in
      */skill) repo="${target%/skill}" ;;
      */skills/rosalbito|*/skills/telemetry) repo="${target%/skills/*}" ;;
      *) echo "warning: $link -> $target is not a rosalbito link; leaving it alone" >&2; return 0 ;;
    esac
    if [ ! -e "$link" ] || grep -qs "rosalbito-guard.sh" "$repo/install.sh"; then
      rm "$link"; echo "removed $link"
    else
      echo "warning: $link -> $target is not from a rosalbito checkout; leaving it alone" >&2
    fi
  }
  unlink_skill rosalbito
  unlink_skill telemetry
  if [ ! -f "$SETTINGS" ]; then
    echo "no $SETTINGS; no hook to remove"
  else
    check_settings
    if [ "$(q 'guards | length')" -eq 0 ]; then
      echo "no rosalbito-guard hook in $SETTINGS"
    else
      settings_edit 'strip' || true
      [ "$(q 'guards | length')" -eq 0 ] || { echo "error: rosalbito-guard hook still present in $SETTINGS" >&2; exit 1; }
      echo "removed the rosalbito-guard hook from $SETTINGS (backup kept next to it)"
    fi
  fi
  echo "Restart Claude Code for the change to take effect."
  exit 0
fi

mkdir -p "$SKILLS"
link_skill() {  # link_skill <name> <source dir>
  if [ -L "$SKILLS/$1" ] || [ ! -e "$SKILLS/$1" ]; then
    ln -sfn "$2" "$SKILLS/$1"; echo "linked $SKILLS/$1 -> $2"
  else
    echo "warning: $SKILLS/$1 exists and is not a symlink; leaving it alone" >&2
  fi
}
# Validate settings before touching anything, so a bad settings.json never leaves a half install.
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
check_settings
link_skill rosalbito "$HERE/skills/rosalbito"
link_skill telemetry "$HERE/skills/telemetry"
if [ "$(q 'registered')" = "true" ]; then
  echo "hook already registered in $SETTINGS"
else
  had="$(q 'guards | length')"
  settings_edit 'strip | .hooks.PreToolUse = (pre + [{matcher: "Bash", hooks: [{type: "command", command: $cmd}]}])' || true
  if [ "$(q 'registered')" != "true" ]; then
    echo "error: could not register $HOOK_CMD in $SETTINGS; check the file by hand" >&2; exit 1
  fi
  if [ "$had" -gt 0 ]; then
    echo "updated PreToolUse hook to $HOOK_CMD (replaced $had old entr$([ "$had" -eq 1 ] && echo y || echo ies); backup kept next to settings.json)"
  else
    echo "registered PreToolUse hook: $HOOK_CMD (backup kept next to settings.json)"
  fi
fi
echo
echo "Restart Claude Code to load the skills and the hook. Then: /rosalbito <task>"
echo "Do not also install the rosalbito plugin: the hook would run twice and the skill would be listed twice."
echo "Recommended primitives: /plugin install mattpocock-skills@claude-plugins-official (grilling, domain-modeling, diagnosing-bugs, research)"
echo "Optional driver: /plugin install ralph-loop@claude-plugins-official (see docs/driver-decision.md)"

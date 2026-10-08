#!/usr/bin/env bash
# install.sh — link the skill into ~/.claude/skills and register the hard-gate hook.
# Idempotent. Backs up settings.json before editing. Run from the repo root.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="$HOME/.claude/skills"
SETTINGS="$HOME/.claude/settings.json"
HOOK="$HERE/skills/rosalbito/hooks/rosalbito-guard.sh"

mkdir -p "$SKILLS"
link_skill() {  # link_skill <name> <source dir>
  if [ -L "$SKILLS/$1" ] || [ ! -e "$SKILLS/$1" ]; then
    ln -sfn "$2" "$SKILLS/$1"; echo "linked $SKILLS/$1 -> $2"
  else
    echo "warning: $SKILLS/$1 exists and is not a symlink; leaving it alone" >&2
  fi
}
link_skill rosalbito "$HERE/skills/rosalbito"
link_skill telemetry "$HERE/skills/telemetry"

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if grep -q "rosalbito-guard.sh" "$SETTINGS"; then
  echo "hook already registered in $SETTINGS"
else
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  jq --arg cmd "$HOOK" '
    .hooks //= {} | .hooks.PreToolUse //= [] |
    .hooks.PreToolUse += [{matcher:"Bash", hooks:[{type:"command", command:$cmd}]}]' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "registered PreToolUse hook: $HOOK (backup kept next to settings.json)"
fi
echo
echo "Restart Claude Code to load the skills and the hook. Then: /rosalbito <task>"
echo "Recommended primitives: /plugin install mattpocock-skills@claude-plugins-official (grilling, domain-modeling, diagnosing-bugs, research)"
echo "Optional driver: /plugin install ralph-loop@claude-plugins-official (see docs/driver-decision.md)"

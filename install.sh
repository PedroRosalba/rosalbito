#!/usr/bin/env bash
# install.sh — link the skill into ~/.claude/skills and register the hard-gate hook.
# Idempotent. Backs up settings.json before editing. Run from the repo root.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="$HOME/.claude/skills"
SETTINGS="$HOME/.claude/settings.json"
HOOK="$HERE/skill/hooks/rosalbito-guard.sh"

mkdir -p "$SKILLS"
if [ -L "$SKILLS/rosalbito" ] || [ ! -e "$SKILLS/rosalbito" ]; then
  ln -sfn "$HERE/skill" "$SKILLS/rosalbito"
  echo "linked $SKILLS/rosalbito -> $HERE/skill"
else
  echo "warning: $SKILLS/rosalbito exists and is not a symlink; leaving it alone" >&2
fi

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
echo "Restart Claude Code to load the skill and the hook. Then: /rosalbito <task>"
echo "Optional driver: /plugin install ralph-loop@claude-plugins-official (see docs/driver-decision.md)"

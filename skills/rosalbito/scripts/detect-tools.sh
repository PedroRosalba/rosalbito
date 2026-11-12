#!/usr/bin/env bash
# detect-tools.sh — which optional capabilities are installed right now (check, don't assume)
set -uo pipefail
PLUG="$HOME/.claude/plugins/installed_plugins.json"
SET="$HOME/.claude/settings.json"
has_plugin() { [ -f "$PLUG" ] && jq -e --arg p "$1" '.plugins | keys[] | select(startswith($p+"@"))' "$PLUG" >/dev/null 2>&1; }
echo "ralph-loop plugin: $(has_plugin ralph-loop && echo yes || echo no)"
echo "gh cli: $(command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && echo yes || echo no)"
echo "jq: $(command -v jq >/dev/null && echo yes || echo no)"
echo "rosalbito guard hook: $([ -f "$SET" ] && grep -q rosalbito-guard "$SET" && echo installed || echo missing)"
echo "skills dir: $([ -e "$HOME/.claude/skills/rosalbito" ] && echo linked || echo not-linked)"
echo "# built-in (verify in-session): /code-review, security-review, Agent (Explore/Plan/general-purpose), Workflow, /loop"

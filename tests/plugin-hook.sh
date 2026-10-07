#!/usr/bin/env bash
# tests/plugin-hook.sh — the guard, invoked exactly as the plugin registers it.
# Reads the PreToolUse command from hooks/hooks.json, runs it the way Claude Code does
# (a shell with CLAUDE_PLUGIN_ROOT set to the plugin root), and checks deny/allow.
# The plugin root is reached through a path containing a space to prove the quoting.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/plugin root"; ln -s "$HERE" "$ROOT"
mkdir -p "$TMP/repo" && git -C "$TMP/repo" init -q -b feature/x . 2>/dev/null || git -C "$TMP/repo" init -q .

CMD="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.type=="command") | .command' "$HERE/hooks/hooks.json")"
[ "$(printf '%s\n' "$CMD" | grep -c .)" -eq 1 ] && ok "hooks.json has exactly one Bash command hook" || fail "hooks.json has exactly one Bash command hook"
case "$CMD" in *'${CLAUDE_PLUGIN_ROOT}'*) ok "command is rooted at \${CLAUDE_PLUGIN_ROOT}" ;; *) fail "command is rooted at \${CLAUDE_PLUGIN_ROOT}" ;; esac
SCRIPT="$(CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "printf '%s' $CMD")"
[ -x "$SCRIPT" ] && ok "resolved guard script is executable" || fail "resolved guard script is executable ($SCRIPT)"

run() {  # run <tool_name> <command> -> sets RC and OUT
  local payload
  payload="$(jq -n --arg t "$1" --arg c "$2" --arg d "$TMP/repo" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c},cwd:$d}')"
  OUT="$(cd "$TMP/repo" && printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$CMD" 2>&1)"; RC=$?
}

run Bash "git push origin main"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; then ok "push to main denied (exit 2 + deny JSON)"; else fail "push to main denied (rc=$RC out=$OUT)"; fi
run Bash "git push --force origin feature/x"
[ "$RC" -eq 2 ] && ok "force push denied" || fail "force push denied (rc=$RC)"
run Bash "gh pr merge 12 --squash"
[ "$RC" -eq 2 ] && ok "PR merge denied" || fail "PR merge denied (rc=$RC)"
run Bash "ls"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "ls allowed (exit 0, no output)" || fail "ls allowed (rc=$RC out=$OUT)"
run Bash "git push -u origin feature/x"
[ "$RC" -eq 0 ] && ok "push of a feature branch allowed" || fail "push of a feature branch allowed (rc=$RC out=$OUT)"

echo "plugin-hook: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

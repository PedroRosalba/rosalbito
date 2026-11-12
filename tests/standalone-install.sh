#!/usr/bin/env bash
# tests/standalone-install.sh — install.sh / install.sh --uninstall against throwaway HOMEs.
# Never touches the real ~/.claude. Every case asserts settings.json stays valid, non-empty
# JSON, that unrelated user settings survive, and that what install.sh printed is true.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOOK="$HERE/skills/rosalbito/hooks/rosalbito-guard.sh"
CMD="\"$HOOK\""
N=0
fresh() {  # fresh '<settings.json content>' — new throwaway HOME
  N=$((N+1)); export HOME="$TMP/home$N"; mkdir -p "$HOME/.claude/skills"
  S="$HOME/.claude/settings.json"; printf '%s\n' "$1" > "$S"
}
inst()   { OUT="$(bash "$HERE/install.sh" "$@" 2>&1)"; RC=$?; }
valid()  { [ -s "$S" ] && jq -e 'type == "object"' "$S" >/dev/null 2>&1; }
guards() { jq -r '[.hooks.PreToolUse[]? | (.hooks? // [])[]? | .command? // empty | select(contains("rosalbito-guard.sh"))] | .[]' "$S"; }
said()   { printf '%s' "$OUT" | grep >/dev/null -- "$1"; }
nbak()   { ls "$HOME/.claude" | grep -c '^settings.json.bak\.'; }

echo "fresh install"
fresh '{}'
inst
check "exits 0"                                   '[ $RC -eq 0 ] && valid'
check "rosalbito skill resolves to SKILL.md"      '[ -L "$HOME/.claude/skills/rosalbito" ] && grep >/dev/null "^name: rosalbito$" "$HOME/.claude/skills/rosalbito/SKILL.md"'
check "telemetry skill resolves to SKILL.md"      '[ -L "$HOME/.claude/skills/telemetry" ] && grep >/dev/null "^name: telemetry$" "$HOME/.claude/skills/telemetry/SKILL.md"'
check "telemetry finds rosalbito scripts as sibling" '[ -f "$HOME/.claude/skills/telemetry/../rosalbito/scripts/verify.sh" ]'
check "hook registered, quoted, new layout path"  '[ "$(guards)" = "$CMD" ] && [ -x "$HOOK" ] && said "registered PreToolUse hook"'
cp "$S" "$TMP/before"; b="$(nbak)"
inst
check "re-install: no change, no backup"          '[ $RC -eq 0 ] && cmp -s "$S" "$TMP/before" && [ "$(nbak)" -eq "$b" ] && said "already registered"'

echo "path with a space: the registered command runs"
mkdir -p "$TMP/with space" && ln -s "$HERE" "$TMP/with space/repo"
fresh '{}'
OUT="$(bash "$TMP/with space/repo/install.sh" 2>&1)"; RC=$?
c="$(guards)"
run_hook() { printf '%s' "$1" | bash -c "$c" >/dev/null 2>&1; echo $?; }
check "registered path contains the space"       '[ $RC -eq 0 ] && case "$c" in *"with space"*) true;; *) false;; esac'
check "command allows ls"                         '[ "$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}")" -eq 0 ]'
check "command denies a force push"              '[ "$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force origin feature/x\"}}")" -eq 2 ]'

echo "old skill/ layout (unquoted path) is recognised and rewritten"
check "old hook path still resolves (skill compat link)" '[ -x "$HERE/skill/hooks/rosalbito-guard.sh" ] && [ -f "$HERE/skill/SKILL.md" ]'
fresh "$(jq -n --arg old "$HERE/skill/hooks/rosalbito-guard.sh" '{permissions:{allow:["Bash(ls)"]},
  hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"other-hook.sh"},{type:"command",command:$old}]},
                     {matcher:"Write",hooks:[]},
                     {matcher:"Bash",hooks:[{type:"command",command:$old}]}]}}')"
ln -sfn "$HERE/skill" "$HOME/.claude/skills/rosalbito"
inst
check "exactly one guard, quoted new path"        '[ $RC -eq 0 ] && valid && [ "$(guards)" = "$CMD" ] && said "updated PreToolUse hook" && [ "$(nbak)" -eq 1 ]'
check "other hook, empty group, permissions kept" '[ "$(jq -c "[.hooks.PreToolUse[] | {matcher, n: (.hooks|length)}][0:2], .permissions" "$S" | tr "\n" " ")" = "[{\"matcher\":\"Bash\",\"n\":1},{\"matcher\":\"Write\",\"n\":0}] {\"allow\":[\"Bash(ls)\"]} " ]'
check "old skill symlink re-pointed"              '[ "$(readlink "$HOME/.claude/skills/rosalbito")" = "$HERE/skills/rosalbito" ]'

echo "A: guard name only under permissions.allow"
fresh '{"permissions":{"allow":["Bash(bash /x/rosalbito-guard.sh)"]}}'
inst
check "registers, permissions kept, says so"      '[ $RC -eq 0 ] && valid && [ "$(guards)" = "$CMD" ] && said "registered PreToolUse hook" && [ "$(jq -r ".permissions.allow[0]" "$S")" = "Bash(bash /x/rosalbito-guard.sh)" ]'

echo "B: guard name mentioned but not registered, other PreToolUse hooks present"
fresh '{"env":{"NOTE":"see rosalbito-guard.sh"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk-rewrite.sh"}]}]}}'
inst
check "registers, user hook and env kept"         '[ $RC -eq 0 ] && valid && [ "$(guards)" = "$CMD" ] && said "registered PreToolUse hook" && [ "$(jq -r ".hooks.PreToolUse[0].hooks[0].command, .env.NOTE" "$S" | tr "\n" "|")" = "rtk-rewrite.sh|see rosalbito-guard.sh|" ]'

echo "E: guard only under PostToolUse"
fresh '{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/x/rosalbito-guard.sh"}]}]}}'
inst
check "registers PreToolUse, PostToolUse untouched" '[ $RC -eq 0 ] && valid && [ "$(guards)" = "$CMD" ] && said "registered PreToolUse hook" && [ "$(jq -r ".hooks.PostToolUse[0].hooks[0].command" "$S")" = "/x/rosalbito-guard.sh" ]'

echo "invalid settings.json"
fresh '{"hooks": '
cp "$S" "$TMP/before"
inst
check "fails loudly, file untouched"              '[ $RC -ne 0 ] && cmp -s "$S" "$TMP/before" && [ "$(nbak)" -eq 0 ] && said "error:"'
fresh '{"hooks":"oops"}'
cp "$S" "$TMP/before"
inst
check "unexpected hooks shape: fails, untouched"  '[ $RC -ne 0 ] && cmp -s "$S" "$TMP/before" && [ "$(nbak)" -eq 0 ] && said "error:"'

echo "reformat only: no write, no backup"
fresh "$(jq -nc --arg c "$CMD" '{model:"x",hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]}]}}')"
cp "$S" "$TMP/before"
inst
check "registered compact file: byte-identical"   '[ $RC -eq 0 ] && cmp -s "$S" "$TMP/before" && [ "$(nbak)" -eq 0 ] && said "already registered"'
fresh '{"model":"x","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}'
cp "$S" "$TMP/before"
inst --uninstall
check "uninstall without guard: byte-identical"   '[ $RC -eq 0 ] && cmp -s "$S" "$TMP/before" && [ "$(nbak)" -eq 0 ] && said "no rosalbito-guard hook"'

echo "C: uninstall with a PreToolUse group lacking .hooks"
fresh "$(jq -n --arg c "$CMD" '{permissions:{deny:["Bash(rm:*)"]},hooks:{PreToolUse:[{matcher:"Bash"},{matcher:"Edit",hooks:[]},
  {matcher:"Bash",hooks:[{type:"command",command:"other-hook.sh"},{type:"command",command:$c}]},
  {matcher:"Bash",hooks:[{type:"command",command:"/old/skill/hooks/rosalbito-guard.sh"}]}]}}')"
inst --uninstall --force
check "guard removed, says so, backup made"       '[ $RC -eq 0 ] && valid && [ -z "$(guards)" ] && said "removed the rosalbito-guard hook" && [ "$(nbak)" -eq 1 ]'
check "groups without hooks / empty hooks kept"   '[ "$(jq -c "[.hooks.PreToolUse[] | [.matcher, (.hooks|length)]]" "$S")" = "[[\"Bash\",0],[\"Edit\",0],[\"Bash\",1]]" ] && [ "$(jq -r ".hooks.PreToolUse[0] | has(\"hooks\")" "$S")" = "false" ]'
check "other hook and permissions kept"           '[ "$(jq -r ".hooks.PreToolUse[2].hooks[0].command, .permissions.deny[0]" "$S" | tr "\n" "|")" = "other-hook.sh|Bash(rm:*)|" ]'

echo "uninstall of a full install"
fresh '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-hook.sh"}]}]}}'
inst
cp "$S" "$TMP/before"
inst --uninstall
check "refuses while the plugin is not enabled"   '[ $RC -ne 0 ] && said "refusing" && cmp -s "$S" "$TMP/before" && [ -n "$(guards)" ] && [ -L "$HOME/.claude/skills/rosalbito" ]'
jq '.enabledPlugins = {"rosalbito@rosalbito": true}' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
inst --uninstall
check "symlinks removed"                          '[ $RC -eq 0 ] && [ ! -L "$HOME/.claude/skills/rosalbito" ] && [ ! -L "$HOME/.claude/skills/telemetry" ]'
check "guard removed, other hook kept"            'valid && [ -z "$(guards)" ] && [ "$(jq -r ".hooks.PreToolUse[0].hooks[0].command" "$S")" = "other-hook.sh" ]'
cp "$S" "$TMP/before"
inst --uninstall
check "uninstall is idempotent"                   '[ $RC -eq 0 ] && cmp -s "$S" "$TMP/before"'
echo "keep me" > "$TMP/unrelated"
rm -f "$HOME/.claude/skills/telemetry" "$HOME/.claude/skills/rosalbito"; mkdir "$HOME/.claude/skills/telemetry"; ln -sfn "$TMP/unrelated" "$HOME/.claude/skills/rosalbito"
inst --uninstall
check "leaves non-rosalbito skills alone"         '[ -d "$HOME/.claude/skills/telemetry" ] && [ -L "$HOME/.claude/skills/rosalbito" ]'

echo "standalone-install: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

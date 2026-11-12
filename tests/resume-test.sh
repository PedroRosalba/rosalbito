#!/usr/bin/env bash
# tests/resume-test.sh — kill a /rosalbito session mid-run, start a fresh one, prove it continues.
#
# This is the spec's "if this test fails, nothing else matters" test (§11). It spends real
# model calls: it starts a headless `claude -p "/rosalbito <task>"` in a scratch repo, kills
# the process once the run is past classification, then starts a brand-new session with a
# bare `/rosalbito` and checks that it resumed from .agent/state/current.md and finished.
#
# Requires: claude CLI, the skill installed (install.sh), network. ~5–15 minutes.
#   tests/resume-test.sh [workdir]
set -uo pipefail
WORK="${1:-$(mktemp -d)}"; mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
LOG="$WORK/.resume-test"; mkdir -p "$LOG"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
status() { sed -n 's/^status: //p' .agent/state/current.md 2>/dev/null | head -1; }

cd "$WORK"
echo "== scratch project in $WORK"
git init -q -b main . 2>/dev/null || git init -q .
git config user.email rosalbito-test@example.com; git config user.name "rosalbito test"
cat > calc.py <<'PY'
"""Tiny calculator module used by the rosalbito resume test."""


def add(a, b):
    return a + b


def sub(a, b):
    return a - b
PY
cat > test_calc.py <<'PY'
import unittest

import calc


class CalcTest(unittest.TestCase):
    def test_add(self):
        self.assertEqual(calc.add(2, 3), 5)

    def test_sub(self):
        self.assertEqual(calc.sub(5, 3), 2)


if __name__ == "__main__":
    unittest.main()
PY
printf 'test:\n\tpython3 -m unittest -v\n' > Makefile
git add -A && git commit -qm "init: calc module with tests"
# local bare origin so the feature branch can be pushed without GitHub
BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git init -q --bare "$WORK.origin.git" && git remote add origin "$WORK.origin.git" && git push -q -u origin "$BASE_BRANCH"
TASK="add a power(base, exp) function to calc.py with unit tests in test_calc.py. This scratch repo has a local bare origin and no GitHub remote: push the feature branch, and when gh pr create fails because there is no GitHub remote, treat the run as done and report the branch instead of a PR URL."

echo "== phase 1: start a run and kill it once it is past classification"
env -u CLAUDECODE claude -p --dangerously-skip-permissions --max-turns 80 --output-format stream-json --verbose \
  "/rosalbito $TASK" > "$LOG/session1.jsonl" 2>&1 &
P1=$!
st=""
for i in $(seq 1 180); do
  st="$(status)"
  case "$st" in implementing|verifying|reviewing|documenting|pr) break;; done|blocked) break;; esac
  kill -0 $P1 2>/dev/null || break
  sleep 5
done
if kill -0 $P1 2>/dev/null; then
  kill -9 $P1 2>/dev/null; wait $P1 2>/dev/null
  echo "  killed session 1 (pid $P1) at status='$st'"
else
  echo "  session 1 exited on its own at status='$st' (could not kill mid-run)"
fi
cp .agent/state/current.md "$LOG/state-at-kill.md" 2>/dev/null
RUN1="$(sed -n 's/^run_id: //p' .agent/state/current.md 2>/dev/null | head -1)"
IT1="$(sed -n 's/^iteration: //p' .agent/state/current.md 2>/dev/null | head -1)"
check "state file existed at kill time"           '[ -n "$RUN1" ]'
check "killed mid-run (not done/blocked)"         '[ "$st" != done ] && [ "$st" != blocked ] && [ -n "$st" ]'
rm -f .claude/ralph-loop.local.md   # the dead session's driver state must not block the new one

echo "== phase 2: fresh session, bare /rosalbito"
env -u CLAUDECODE claude -p --dangerously-skip-permissions --max-turns 80 --output-format stream-json --verbose \
  "/rosalbito" > "$LOG/session2.jsonl" 2>&1
echo "  session 2 exited ($?)"
cp .agent/state/current.md "$LOG/state-at-end.md" 2>/dev/null

echo "== assertions"
RUN2="$(sed -n 's/^run_id: //p' .agent/state/current.md | head -1)"
IT2="$(sed -n 's/^iteration: //p' .agent/state/current.md | head -1)"
FINAL="$(status)"
# first tool calls of session 2 (excluding the Skill invocation itself)
# stderr warnings share the file with the JSONL stream: keep only JSON lines
FIRST_TOOLS="$(grep '^{' "$LOG/session2.jsonl" | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | "\(.name) \(.input.command // .input.file_path // .input.skill // "")"' 2>/dev/null | grep -v '^Skill' | head -3)"
echo "$FIRST_TOOLS" | sed 's/^/    first tools: /'
check "session 2 read state first (current.md or state.sh in first 3 tool calls)" 'echo "$FIRST_TOOLS" | grep -E "current\.md|state\.sh" >/dev/null'
check "same run resumed (run_id unchanged)"       '[ "$RUN1" = "$RUN2" ]'
check "no second run was created"                 '[ ! -d .agent/state/history ] || [ -z "$(ls .agent/state/history 2>/dev/null)" ]'
check "run reached a terminal state"              '[ "$FINAL" = done ] || [ "$FINAL" = blocked ]'
check "run finished as done"                      '[ "$FINAL" = done ]'
check "evidence recorded with a passing test"     'jq -e "select(.label|test(\"test\")) | select(.exit==0)" .agent/evidence/$RUN2.jsonl >/dev/null 2>&1'
check "power() exists and the real tests pass"    'grep -q "def power" calc.py && python3 -m unittest >/dev/null 2>&1'
check "feature branch pushed to origin"           'git -C "$WORK.origin.git" branch | grep -E "feature/" >/dev/null'
check "metrics line written"                      '[ -s .agent/metrics.jsonl ]'
check "loop state removed at finish"              '[ ! -f .claude/ralph-loop.local.md ]'
echo
echo "run=$RUN2 killed_at=$st/iter=$IT1 final=$FINAL/iter=$IT2 logs=$LOG"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]

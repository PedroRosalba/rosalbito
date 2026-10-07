#!/usr/bin/env bash
# tests/run.sh — deterministic tests for the rosalbito scripts and the guard hook.
# Creates a throwaway git repo, exercises every script, checks exit codes and files.
# Note: greps consume all input (no -q) because pipefail would turn a SIGPIPE into a failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SKILL_DIR="$HERE/skill"
S="$SKILL_DIR/scripts"
HOOK="$SKILL_DIR/hooks/rosalbito-guard.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" && git init -q -b main . 2>/dev/null || git init -q .
git config user.email t@t; git config user.name t
echo hi > README.md; git add . && git commit -qm init

echo "state / init-run"
check "state.sh show fails without a run"       '! bash "$S/state.sh" show >/dev/null 2>&1'
out="$(bash "$S/init-run.sh" --task "Add CI badge to README" --risk low 2>&1)"; rc=$?
check "init-run exits 0"                        '[ $rc -eq 0 ]'
check "creates .agent tree"                     '[ -d .agent/state ] && [ -d .agent/evidence ] && [ -d .agent/decisions ]'
check "creates feature branch"                  '[ "$(git rev-parse --abbrev-ref HEAD)" = "feature/add-ci-badge-to-readme" ]'
check "state has run_id"                        '[ -n "$(bash "$S/state.sh" get run_id)" ]'
check "risk recorded"                           '[ "$(bash "$S/state.sh" get risk)" = "LOW" ]'
check "refuses a second active run"             '! bash "$S/init-run.sh" --task x --risk low >/dev/null 2>&1'
check "rejects risk below floor"                '! (git checkout -q main && bash "$S/init-run.sh" --task y --risk low --floor high >/dev/null 2>&1)'
git checkout -q feature/add-ci-badge-to-readme
bash "$S/state.sh" set status implementing
check "set/get scalar"                          '[ "$(bash "$S/state.sh" get status)" = "implementing" ]'
bash "$S/state.sh" set next_action "Run the tests & fix /paths|pipes/"
check "set handles special chars"               '[ "$(bash "$S/state.sh" get next_action)" = "Run the tests & fix /paths|pipes/" ]'
bash "$S/state.sh" bump >/dev/null
check "bump increments iteration"               '[ "$(bash "$S/state.sh" get iteration)" = "2" ]'
bash "$S/state.sh" log "hello log"
check "log appends"                             'grep >/dev/null "hello log" .agent/state/current.md'
check "frontmatter still well-formed"           '[ "$(grep -c "^---$" .agent/state/current.md)" -eq 2 ]'
check "driver state file excluded from git"     'grep >/dev/null ".claude/\*.local.md" .git/info/exclude'

echo "verify / evidence"
RUN="$(bash "$S/state.sh" get run_id)"
bash "$S/verify.sh" echo-ok 'echo fine' >/dev/null; rc=$?
check "verify passes through exit 0"            '[ $rc -eq 0 ]'
bash "$S/verify.sh" boom 'echo bad >&2; exit 7' >/dev/null; rc=$?
check "verify passes through exit 7"            '[ $rc -eq 7 ]'
check "two evidence lines"                      '[ "$(wc -l < .agent/evidence/$RUN.jsonl | tr -d " ")" -eq 2 ]'
check "evidence is valid JSON with fields"      'jq -e ".label==\"boom\" and .exit==7 and (.output_tail|contains(\"bad\")) and .iteration==2" <(tail -1 .agent/evidence/$RUN.jsonl) >/dev/null'
check "evidence-summary lists both"             '[ "$(bash "$S/evidence-summary.sh" | wc -l | tr -d " ")" -eq 2 ]'
check "evidence-summary --md rows"              'bash "$S/evidence-summary.sh" --md | grep >/dev/null "^| boom |"'

echo "caps-check"
check "caps ok initially"                       'bash "$S/caps-check.sh" | grep >/dev/null "^ok"'
bash "$S/verify.sh" boom 'exit 1' >/dev/null; bash "$S/verify.sh" boom 'exit 1' >/dev/null
bash "$S/caps-check.sh" >/dev/null; rc=$?
check "same failure x3 => LOOP_DETECTED (3)"    '[ $rc -eq 3 ]'
bash "$S/verify.sh" boom 'exit 0' >/dev/null
check "a pass resets the streak"                'bash "$S/caps-check.sh" | grep >/dev/null "^ok"'
bash "$S/state.sh" set iteration 26
bash "$S/caps-check.sh" >/dev/null; rc=$?
check "iteration cap => CAP_HIT (2)"            '[ $rc -eq 2 ]'
bash "$S/state.sh" set iteration 3
bash "$S/state.sh" set started_at 2020-01-01T00:00:00Z
bash "$S/caps-check.sh" >/dev/null; rc=$?
check "wall clock cap => CAP_HIT (2)"           '[ $rc -eq 2 ]'
bash "$S/state.sh" set started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p .agent && printf 'max_iterations_per_run: 2\nmax_wall_clock_hours: 8\nmax_same_failure: 3\n' > .agent/caps.yaml
bash "$S/caps-check.sh" >/dev/null; rc=$?
check "per-repo caps override honored"          '[ $rc -eq 2 ]'
rm .agent/caps.yaml

echo "classify-paths"
check "auth path => HIGH"                       'bash "$S/classify-paths.sh" src/auth/login.rs | grep >/dev/null "MIN_TIER=HIGH"'
check "payments path => HIGH"                   'bash "$S/classify-paths.sh" app/billing/invoice.ts | grep >/dev/null "MIN_TIER=HIGH"'
check "migration => HIGH"                       'bash "$S/classify-paths.sh" db/migrations/001_init.sql | grep >/dev/null "MIN_TIER=HIGH"'
check ".env => HIGH"                            'bash "$S/classify-paths.sh" .env.production | grep >/dev/null "MIN_TIER=HIGH"'
check "CI => HIGH"                              'bash "$S/classify-paths.sh" .github/workflows/ci.yml | grep >/dev/null "MIN_TIER=HIGH"'
check "Dockerfile => HIGH"                      'bash "$S/classify-paths.sh" Dockerfile | grep >/dev/null "MIN_TIER=HIGH"'
check "plain src => TRIVIAL floor"              'bash "$S/classify-paths.sh" src/engine.rs README.md | grep >/dev/null "MIN_TIER=TRIVIAL"'
check "author.rs does not match auth"           'bash "$S/classify-paths.sh" src/author.rs | grep >/dev/null "MIN_TIER=TRIVIAL"'
check "diff mode works"                         'echo x > src.txt && git add src.txt && bash "$S/classify-paths.sh" | grep >/dev/null "MIN_TIER="'
printf 'rules:\n  - match: '"'"'(^|/)engine\\.rs$'"'"'\n    tier: CRITICAL\n    reason: ledger core\n' > .agent/risk-overrides.yaml
check "per-repo override => CRITICAL"           'bash "$S/classify-paths.sh" src/engine.rs | grep >/dev/null "MIN_TIER=CRITICAL"'
rm .agent/risk-overrides.yaml

echo "detect-checks"
printf '[package]\nname="x"\nversion="0.1.0"\n' > Cargo.toml
check "cargo detected"                          'bash "$S/detect-checks.sh" 2>/dev/null | grep >/dev/null "^test	cargo test"'
rm Cargo.toml

echo "start-loop / finish-run / metrics"
out="$(CLAUDE_CODE_SESSION_ID=test-session bash "$S/start-loop.sh" 2>&1)"; rc=$?
check "start-loop exits 0"                      '[ $rc -eq 0 ]'
if [ -f .claude/ralph-loop.local.md ]; then
  check "ralph state has promise"               'grep >/dev/null "completion_promise: \"ROSALBITO RUN FINISHED\"" .claude/ralph-loop.local.md'
  check "ralph state has session id"            'grep >/dev/null "session_id: test-session" .claude/ralph-loop.local.md'
  check "ralph state max_iterations from caps"  'grep >/dev/null "max_iterations: 25" .claude/ralph-loop.local.md'
  check "driver recorded"                       '[ "$(bash "$S/state.sh" get driver)" = "ralph-loop" ]'
else
  echo "  (ralph-loop not installed here: driver degraded path exercised)"
  check "driver none recorded"                  '[ "$(bash "$S/state.sh" get driver)" = "none" ]'
fi
check "metrics line is JSON"                    'bash "$S/metrics.sh" | jq -e ".iterations==3 and .checks_run==5 and .checks_failed==3" >/dev/null'
bash "$S/finish-run.sh" done --pr https://example.com/pr/1 >/dev/null; rc=$?
check "finish-run done"                         '[ $rc -eq 0 ] && [ "$(bash "$S/state.sh" get status)" = "done" ]'
check "pr recorded"                             '[ "$(bash "$S/state.sh" get pr)" = "https://example.com/pr/1" ]'
check "metrics.jsonl appended"                  '[ -s .agent/metrics.jsonl ] && jq -e ".status==\"done\"" .agent/metrics.jsonl >/dev/null'
check "loop disarmed"                           '[ ! -f .claude/ralph-loop.local.md ]'
check "new run archives the finished one"       'bash "$S/init-run.sh" --task "second task" --risk trivial >/dev/null 2>&1 && ls .agent/state/history | grep >/dev/null .'

echo "guard hook"
g() { printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' "$(printf '%s' "$1" | jq -Rs .)" "$TMP" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
denied() { [ "$(g "$1")" -ne 0 ]; }
allowed() { [ "$(g "$1")" -eq 0 ]; }
check "deny git push --force"                   'denied "git push --force origin feature/x"'
check "deny git push -f"                        'denied "git push -f"'
check "deny git push origin main"               'denied "git push origin main"'
check "deny git push -u origin master"          'denied "git push -u origin master"'
check "deny push HEAD:main"                     'denied "git push origin HEAD:main"'
check "deny rtk git push origin main"           'denied "rtk git push origin main"'
check "deny chained push to main"               'denied "git commit -m x && git push origin main"'
check "allow push feature branch"               'allowed "git push -u origin feature/issue-3-thing"'
check "allow push feature named main-ish"       'allowed "git push origin feature/maintenance"'
git checkout -q main 2>/dev/null
check "deny bare git push on main"              'denied "git push"'
git checkout -q feature/add-ci-badge-to-readme 2>/dev/null
check "allow bare git push on feature branch"   'allowed "git push"'
check "deny gh pr merge"                        'denied "gh pr merge 12 --squash"'
check "allow gh pr create"                      'allowed "gh pr create --title x --body y"'
check "deny vercel --prod"                      'denied "vercel deploy --prod"'
check "deny terraform apply"                    'denied "terraform apply -auto-approve"'
check "deny DROP TABLE"                         'denied "psql -c \"DROP TABLE users\""'
check "deny rm -rf /"                           'denied "rm -rf /"'
check "deny rm -rf ~"                           'denied "rm -rf ~"'
check "deny rm -rf .git"                        'denied "rm -rf .git"'
check "allow rm -rf target"                     'allowed "rm -rf target node_modules"'
check "deny prod credential env"                'denied "PROD_DATABASE_URL=postgres://x ./migrate"'
check "deny --profile prod"                     'denied "aws s3 rm s3://bucket --profile prod"'
check "allow cargo test"                        'allowed "cargo test"'
check "allow git push --force-with-lease? no"   'denied "git push --force-with-lease origin feature/x"'
check "deny git branch -D main"                 'denied "git branch -D main"'
check "ignores non-Bash tool input"             '[ "$(printf "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"x\"}}" | bash "$HOOK" >/dev/null 2>&1; echo $?)" -eq 0 ]'

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]

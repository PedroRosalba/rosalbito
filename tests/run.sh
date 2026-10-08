#!/usr/bin/env bash
# tests/run.sh — deterministic tests for the rosalbito scripts and the guard hook.
# Creates a throwaway git repo, exercises every script, checks exit codes and files.
# Note: greps consume all input (no -q) because pipefail would turn a SIGPIPE into a failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SKILL_DIR="$HERE/skills/rosalbito"
S="$SKILL_DIR/scripts"
HOOK="$SKILL_DIR/hooks/rosalbito-guard.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export ROSALBITO_HOME="$TMP/.rosalbito" CLAUDE_PROJECTS_DIR="$TMP/.projects"   # never touch the real index or transcripts
unset CLAUDE_CODE_SESSION_ID
cd "$TMP" && git init -q -b main . 2>/dev/null || git init -q .
git config user.email t@t; git config user.name t
echo hi > README.md; git add . && git commit -qm init

echo "state / init-run"
check "state.sh show fails without a run"       '! bash "$S/state.sh" show >/dev/null 2>&1'
out="$(bash "$S/init-run.sh" --task "Add CI badge to README" --risk low 2>&1)"; rc=$?
check "init-run exits 0"                        '[ $rc -eq 0 ]'
check "creates context + runs tree"             '[ -d .agent/context/adr ] && [ -d .agent/context/telemetry ] && [ -L .agent/runs/current ] && [ -f .agent/runs/current/state.md ]'
check "LOW run gets no acceptance file"          '[ ! -f .agent/runs/current/acceptance.yaml ]'
check "CONTEXT.md and docs/adr redirected"       '[ -L CONTEXT.md ] && [ -L docs/adr ] && grep >/dev/null "^CONTEXT.md$" .git/info/exclude && grep >/dev/null "^docs/adr$" .git/info/exclude'
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
check "log appends"                             'grep >/dev/null "hello log" .agent/runs/current/state.md'
check "frontmatter still well-formed"           '[ "$(grep -c "^---$" .agent/runs/current/state.md)" -eq 2 ]'
check "driver state file excluded from git"     'grep >/dev/null ".claude/\*.local.md" .git/info/exclude'
check ".agent/ excluded from git by default"    'grep >/dev/null "^.agent/$" .git/info/exclude && [ -z "$(git status --porcelain | grep .agent)" ]'

echo "verify / evidence"
RUN="$(bash "$S/state.sh" get run_id)"
bash "$S/verify.sh" echo-ok 'echo fine' >/dev/null; rc=$?
check "verify passes through exit 0"            '[ $rc -eq 0 ]'
bash "$S/verify.sh" boom 'echo bad >&2; exit 7' >/dev/null; rc=$?
check "verify passes through exit 7"            '[ $rc -eq 7 ]'
check "two evidence lines"                      '[ "$(wc -l < .agent/runs/$RUN/evidence.jsonl | tr -d " ")" -eq 2 ]'
check "evidence is valid JSON with fields"      'jq -e ".label==\"boom\" and .exit==7 and (.output_tail|contains(\"bad\")) and .iteration==2" <(tail -1 .agent/runs/$RUN/evidence.jsonl) >/dev/null'
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
printf 'max_iterations_per_run: 2\nmax_wall_clock_hours: 8\nmax_same_failure: 3\n' > .agent/context/caps.yaml
bash "$S/caps-check.sh" >/dev/null; rc=$?
check "per-repo caps override honored"          '[ $rc -eq 2 ]'
rm .agent/context/caps.yaml

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
printf 'rules:\n  - match: '"'"'(^|/)engine\\.rs$'"'"'\n    tier: CRITICAL\n    reason: ledger core\n' > .agent/context/risk-overrides.yaml
check "per-repo override => CRITICAL"           'bash "$S/classify-paths.sh" src/engine.rs | grep >/dev/null "MIN_TIER=CRITICAL"'
rm .agent/context/risk-overrides.yaml

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
  check "loop prompt names the real SKILL_DIR"   'grep -F >/dev/null "bash \"$SKILL_DIR/scripts/caps-check.sh\"" .claude/ralph-loop.local.md && ! grep >/dev/null "SKILL_DIR = the rosalbito" .claude/ralph-loop.local.md'
  check "driver recorded"                       '[ "$(bash "$S/state.sh" get driver)" = "ralph-loop" ]'
else
  echo "  (ralph-loop not installed here: driver degraded path exercised)"
  check "driver none recorded"                  '[ "$(bash "$S/state.sh" get driver)" = "none" ]'
fi
check "metrics line is JSON"                    'bash "$S/metrics.sh" | jq -e ".iterations==3 and .checks_run==5 and .checks_failed==3" >/dev/null'
check "metrics: fail-then-pass label is a fix cycle" 'bash "$S/metrics.sh" | jq -e ".fix_cycles==1 and .fix_cycle_labels==[\"boom\"] and (.check_labels|map(select(.label==\"boom\"))[0] | .runs==4 and .failed==3 and .last_exit==0)" >/dev/null'
bash "$S/finish-run.sh" done --pr https://example.com/pr/1 >/dev/null; rc=$?
check "finish-run done"                         '[ $rc -eq 0 ] && [ "$(bash "$S/state.sh" get status)" = "done" ]'
check "pr recorded"                             '[ "$(bash "$S/state.sh" get pr)" = "https://example.com/pr/1" ]'
check "metrics.jsonl appended"                  '[ -s .agent/runs/metrics.jsonl ] && jq -e ".status==\"done\"" .agent/runs/metrics.jsonl >/dev/null'
check "loop disarmed"                           '[ ! -f .claude/ralph-loop.local.md ]'
check "new run re-points current, keeps the old" 'bash "$S/init-run.sh" --task "second task" --risk medium >/dev/null 2>&1 && [ -d .agent/runs/$RUN ] && [ "$(bash "$S/state.sh" get task)" = "second task" ]'
check "MEDIUM run gets an acceptance file"       '[ -f .agent/runs/current/acceptance.yaml ]'

echo "usage / collect / dashboard"
source "$SKILL_DIR/scripts/common.sh"
RUN2="$(bash "$S/state.sh" get run_id)"; ST2="$(bash "$S/state.sh" get started_at)"
TS="$(epoch_to_iso $(( $(iso_to_epoch "$ST2") + 2 )) | sed 's/Z$/.250Z/')"
OLD_TS="2020-01-01T00:00:00.000Z"
P="$CLAUDE_PROJECTS_DIR/-tmp-repo"; mkdir -p "$P/sess-a/subagents"
U='{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":0}}'
{
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"run_id=%s"}}\n' "$TS" "$RUN2"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"m1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":%s,"content":[{"type":"thinking","thinking":""}]}}\n' "$TS" "$U"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"m1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":%s,"content":[{"type":"tool_use","name":"Agent","input":{}}]}}\n' "$TS" "$U"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"m0","model":"claude-opus-5-5","stop_reason":"end_turn","usage":%s,"content":[]}}\n' "$OLD_TS" "$U"
} > "$P/sess-a.jsonl"
TXT="$(printf 'x%.0s' $(seq 1 400))"
printf '{"type":"assistant","isSidechain":true,"agentId":"abc","timestamp":"%s","message":{"id":"s1","model":"claude-opus-5-5","stop_reason":null,"usage":{"input_tokens":0,"output_tokens":3,"cache_read_input_tokens":1000000},"content":[{"type":"text","text":"%s"}]}}\n' "$TS" "$TXT" > "$P/sess-a/subagents/agent-abc.jsonl"
echo '{"agentType":"general-purpose","description":"[review:security] Security review of the diff","spawnDepth":1}' > "$P/sess-a/subagents/agent-abc.meta.json"
u="$(bash "$S/usage.sh" --run-id "$RUN2" --start "$ST2")"
check "usage finds the session by run_id"       'jq -e ".sessions==[\"sess-a\"]" <<< "$u" >/dev/null'
check "one subagent, depth 1"                   'jq -e ".totals.agents_spawned==1 and .totals.max_depth==1" <<< "$u" >/dev/null'
check "role tag honored"                        'jq -e "([.agents[].role]|sort)==[\"orchestrator\",\"review:security\"]" <<< "$u" >/dev/null'
check "streamed chunks deduped, old msg outside window" 'jq -e "(.agents[] | select(.agent_id==\"main\") | .messages==1 and .tools.Agent==1)" <<< "$u" >/dev/null'
check "partial subagent output estimated"       'jq -e "(.agents[] | select(.agent_id==\"abc\") | .output_tokens==100 and .output_estimated_messages==1)" <<< "$u" >/dev/null'
check "cost from pricing.json"                  'jq -e "(.totals.cost_usd * 1000 | round) == 431" <<< "$u" >/dev/null'
# effort, thinking time and context sizes: a separate session, picked by --sessions only
mkdir -p "$P/sess-b/subagents"
am() {  # am <ts> <id> <uuid> <model> <effort|null> <thinking_ms|null> <input> <cache_write> <cache_read> <output>
  local e='null'; [ "$5" = null ] || e="\"$5\""
  printf '{"type":"assistant","timestamp":"%s","uuid":"%s","effort":%s,"perTurnEffort":%s,"thinkingDurationMs":%s,"message":{"id":"%s","model":"%s","stop_reason":"end_turn","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s},"content":[]}}\n' \
    "$1" "$3" "$e" "$e" "$6" "$2" "$4" "$7" "$8" "$9" "${10}"
}
{
  am 2021-01-01T00:00:01.000Z e1 u1 claude-opus-5-5 high 1000 10 100 1000 50
  am 2021-01-01T00:00:01.000Z e1 u2 claude-opus-5-5 high null 10 100 1000 50      # 2nd chunk of e1
  am 2021-01-01T00:00:02.000Z e2 u3 claude-opus-5-5 high 500 20 0 3000 30
  am 2021-01-01T00:00:03.000Z e3 u4 claude-opus-5-5 medium 700 5 0 2000 10
  am 2021-01-01T00:00:03.000Z e3 u4 claude-opus-5-5 medium 700 5 0 2000 10       # duplicated line: thinking counted once
  am 2021-01-01T00:00:04.000Z e4 u5 claude-sonnet-5-5 null null 1 0 100 1
} > "$P/sess-b.jsonl"
am 2021-01-01T00:00:02.000Z x1 v1 claude-opus-5-5 xhigh 250 0 0 500 4 | sed 's/^{/{"isSidechain":true,"agentId":"def",/' > "$P/sess-b/subagents/agent-def.jsonl"
echo '{"agentType":"general-purpose","description":"[implementer] fixture","spawnDepth":1}' > "$P/sess-b/subagents/agent-def.meta.json"
ue="$(bash "$S/usage.sh" --run-id fixture-effort --start 2021-01-01T00:00:00Z --end 2021-01-01T00:01:00Z --sessions sess-b)"
check "usage: effort per message, dominant per agent" 'jq -e "(.agents[] | select(.agent_id==\"main\") | .effort==\"high\" and .effort_messages=={\"high\":2,\"medium\":1,\"unknown\":1}) and (.agents[] | select(.agent_id==\"def\") | .effort==\"xhigh\")" <<< "$ue" >/dev/null'
check "usage: thinking ms summed, duplicate lines once" 'jq -e "(.agents[] | select(.agent_id==\"main\") | .thinking_ms==2200) and .totals.thinking_ms==2450" <<< "$ue" >/dev/null'
check "usage: first and peak context per agent" 'jq -e "(.agents[] | select(.agent_id==\"main\") | .first_context_tokens==1110 and .peak_context_tokens==3020) and (.agents[] | select(.agent_id==\"def\") | .first_context_tokens==500)" <<< "$ue" >/dev/null'
check "usage: total tokens per agent and run"   'jq -e "(.agents[] | select(.agent_id==\"main\") | .total_tokens==6327) and .totals.total_tokens==6831" <<< "$ue" >/dev/null'
check "usage: effort mix and model mix totals"  'jq -e ".totals.effort_mix=={\"high\":2,\"medium\":1,\"unknown\":1,\"xhigh\":1} and .totals.model_mix=={\"claude-opus-5-5\":6729,\"claude-sonnet-5-5\":102}" <<< "$ue" >/dev/null'
check "usage: existing fields unchanged"         'jq -e ".totals.messages==5 and .totals.input_tokens==36 and .totals.cache_write_tokens==100 and .totals.cache_read_tokens==6600 and .totals.output_tokens==95 and (.agents|map(has(\"_model_tokens\"))|any|not)" <<< "$ue" >/dev/null'
check "metrics line carries usage + version"   'bash "$S/metrics.sh" | jq -e ".usage.totals.agents_spawned==1 and (.harness_version|type)==\"string\" and .finished_at==null" >/dev/null'
# +4 -1 in 2 files on the run branch, committed (by date) after the second run started
CD="$(epoch_to_iso $(( $(iso_to_epoch "$ST2") + 5 )))"
printf 'a\nb\nc\n' > feature.txt && echo bye > README.md && git add feature.txt README.md \
  && GIT_COMMITTER_DATE="$CD" GIT_AUTHOR_DATE="$CD" git commit -qm feat feature.txt README.md
bash "$S/collect.sh" "$TMP" >/dev/null
check "collect indexes done and open runs"      '[ "$(jq -s "length" "$ROSALBITO_HOME/runs.jsonl")" -eq 2 ] && jq -se "map(.status)|sort==[\"classifying\",\"done\"]" "$ROSALBITO_HOME/runs.jsonl" >/dev/null'
check "repo registered by init/finish"          'grep >/dev/null -xF "$(pwd -P)" "$ROSALBITO_HOME/repos"'
IX() { jq -c --arg r "$1" "select(.run_id==\$r)" "$ROSALBITO_HOME/runs.jsonl"; }
check "collect: input size from task and first context" 'IX "$RUN2" | jq -e ".input_size.task_chars==11 and .input_size.first_context_tokens==1002000" >/dev/null'
check "collect: real branch diff vs base merge-base" 'IX "$RUN2" | jq -e ".input_size.diff | .files==2 and .added==4 and .removed==1 and .branch==\"feature/add-ci-badge-to-readme\" and .base_branch==.branch and .head==\"$(git rev-parse HEAD)\" and .base==\"$(git rev-parse HEAD~1)\"" >/dev/null'
check "collect: fix cycles carried into the index" 'IX "$RUN" | jq -e ".fix_cycles==1 and .fix_cycle_labels==[\"boom\"]" >/dev/null'
jq -c 'if .input_size.diff then .input_size.diff.files=99 else . end' "$ROSALBITO_HOME/runs.jsonl" > "$TMP/ix" && mv "$TMP/ix" "$ROSALBITO_HOME/runs.jsonl"
check "collect: numstat reused while base and head are unchanged" 'bash "$S/collect.sh" "$TMP" >/dev/null && IX "$RUN2" | jq -e ".input_size.diff.files==99" >/dev/null'
sed -i.bak 's#^branch: .*#branch: feature/gone#' ".agent/runs/$RUN/state.md" && rm -f ".agent/runs/$RUN/state.md.bak"
check "collect: missing branch gives diff null, not a guess" 'bash "$S/collect.sh" --full "$TMP" >/dev/null && IX "$RUN" | jq -e ".input_size.diff==null and .input_size.task_chars==22" >/dev/null'
rm -f "$ROSALBITO_HOME/runs.jsonl" && bash "$S/collect.sh" "$TMP" >/dev/null
check "collect: a fresh index measures the diff again" 'IX "$RUN2" | jq -e ".input_size.diff.files==2" >/dev/null'
bash "$S/dashboard.sh" --no-collect >/dev/null
check "dashboard renders with data inlined"     'grep >/dev/null "$RUN2" "$ROSALBITO_HOME/dashboard.html" && ! grep >/dev/null "__ROSALBITO_DATA__" "$ROSALBITO_HOME/dashboard.html"'
check "incremental collect reuses unchanged runs" 'bash "$S/collect.sh" "$TMP" >/dev/null && [ "$(jq -s "length" "$ROSALBITO_HOME/runs.jsonl")" -eq 2 ]'
if command -v node >/dev/null && command -v curl >/dev/null; then
  PORT=$(( 20000 + RANDOM % 20000 ))
  ROSALBITO_PORT=$PORT ROSALBITO_REFRESH=3600 node "$S/dashboard-server.mjs" >/dev/null 2>&1 & SRV=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "localhost:$PORT/api/runs" >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,0.3)'; done
  check "live server: /api/runs serves the index" 'curl -s "localhost:$PORT/api/runs" | jq -e ".live==true and (.runs|length)==2 and (.version|length)==12" >/dev/null'
  check "live server: page has live data inlined"  'curl -s "localhost:$PORT/" | grep >/dev/null "\"live\":true"'
  check "live server: rejects non-local Host"      '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: evil.example" "localhost:$PORT/api/runs")" = 403 ]'
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  # --install-service against a throwaway HOME and a stub launchctl: nothing real is installed
  mkdir -p "$TMP/bin" "$TMP/svchome"; printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/launchctl"; chmod +x "$TMP/bin/launchctl"
  PL="$TMP/svchome/Library/LaunchAgents/com.rosalbito.dashboard.plist"
  HOME="$TMP/svchome" PATH="$TMP/bin:$PATH" bash "$S/dashboard.sh" --install-service >/dev/null 2>&1
  check "install-service runs a copy, not the skill dir" 'grep -F >/dev/null "<string>$ROSALBITO_HOME/service/scripts/dashboard-server.mjs</string>" "$PL" && ! grep -F >/dev/null "$SKILL_DIR" "$PL" && [ -f "$ROSALBITO_HOME/service/templates/dashboard.html" ] && [ -f "$ROSALBITO_HOME/service/config/pricing.json" ]'
  PORT=$(( 20000 + RANDOM % 20000 ))
  ROSALBITO_PORT=$PORT ROSALBITO_REFRESH=3600 node "$ROSALBITO_HOME/service/scripts/dashboard-server.mjs" >/dev/null 2>&1 & SRV=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "localhost:$PORT/api/runs" >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,0.3)'; done
  check "copied server serves the index"          'curl -s "localhost:$PORT/api/runs" | jq -e ".live==true and (.runs|length)==2" >/dev/null'
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  HOME="$TMP/svchome" PATH="$TMP/bin:$PATH" bash "$S/dashboard.sh" --uninstall-service >/dev/null 2>&1
  check "uninstall-service removes plist and copy" '[ ! -e "$PL" ] && [ ! -e "$ROSALBITO_HOME/service" ]'
  mkdir -p "$ROSALBITO_HOME/service" && echo keep > "$ROSALBITO_HOME/service/user-file"
  check "install-service refuses a service dir it did not create" '! HOME="$TMP/svchome" PATH="$TMP/bin:$PATH" bash "$S/dashboard.sh" --install-service >/dev/null 2>&1 && [ -f "$ROSALBITO_HOME/service/user-file" ]'
  HOME="$TMP/svchome" PATH="$TMP/bin:$PATH" bash "$S/dashboard.sh" --uninstall-service >/dev/null 2>&1
  check "uninstall-service leaves a dir it did not create" '[ -f "$ROSALBITO_HOME/service/user-file" ]'
  rm -rf "$ROSALBITO_HOME/service"
fi
bash "$S/state.sh" set risk HIGH
check "HIGH run cannot finish done without report.md" '! bash "$S/finish-run.sh" done >/dev/null 2>&1 && [ "$(bash "$S/state.sh" get status)" = "classifying" ]'
echo "# report" > .agent/runs/current/reports/report.md
check "HIGH run finishes done with report.md"   'bash "$S/finish-run.sh" done >/dev/null 2>&1 && [ -n "$(bash "$S/state.sh" get finished_at | tr -d \"\")" ]'

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

echo "packaging (for details run each script directly)"
check "plugin hook: guard via hooks/hooks.json"  'bash "$HERE/tests/plugin-hook.sh" >/dev/null 2>&1'
check "standalone install.sh in a throwaway HOME" 'bash "$HERE/tests/standalone-install.sh" >/dev/null 2>&1'
check "plugin manifests name the rosalbito plugin" 'jq -e ".name==\"rosalbito\"" "$HERE/.claude-plugin/plugin.json" >/dev/null && jq -e ".plugins[0].name==\"rosalbito\"" "$HERE/.claude-plugin/marketplace.json" >/dev/null'

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]

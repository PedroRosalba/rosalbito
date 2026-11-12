#!/usr/bin/env bash
# start-loop.sh — arm the loop driver for the current run
#
# Driver: the installed ralph-loop plugin's Stop hook (see references/driver.md).
# Writes .claude/ralph-loop.local.md with the Rosalbito re-entry prompt, max_iterations
# from caps.yaml and completion promise ROSALBITO RUN FINISHED. If the plugin is not
# installed, warns and exits 0: the run still works, it just will not self-continue.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,9p' "$0"; exit 0; }
[ -f "$STATE_FILE" ] || die "no run (run init-run.sh first)"

PROMISE="ROSALBITO RUN FINISHED"
CAPS="$(config_file caps.yaml)"
MAX_IT="$(yaml_scalar "$CAPS" max_iterations_per_run)"; MAX_IT="${MAX_IT:-25}"
RUN_ID="$(state_get run_id)"

installed=false
PLUG="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$PLUG" ] && command -v jq >/dev/null && jq -e '.plugins | keys[] | select(startswith("ralph-loop@"))' "$PLUG" >/dev/null 2>&1; then
  installed=true
fi
SETTINGS="$HOME/.claude/settings.json"
if $installed && [ -f "$SETTINGS" ] && ! jq -e '.enabledPlugins | to_entries[] | select(.key|startswith("ralph-loop@")) | select(.value==true)' "$SETTINGS" >/dev/null 2>&1; then
  installed=false
fi

if ! $installed; then
  echo "warning: ralph-loop plugin not installed/enabled — no loop driver. The run continues in this session only;" >&2
  echo "         resume later with /rosalbito (reads .agent/runs/current/state.md). Install: /plugin install ralph-loop@claude-plugins-official" >&2
  bash "$SKILL_DIR/scripts/state.sh" set driver none
  exit 0
fi

# the plugin's Stop hook reads .claude/ralph-loop.local.md relative to the SESSION's directory;
# a run in another repo than the one Claude Code was started in will never re-enter.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]; then
  echo "warning: session project dir ($CLAUDE_PROJECT_DIR) != repo root ($ROOT): the Stop hook will not re-enter this run." >&2
  echo "         Start Claude Code inside the target repo for overnight runs." >&2
fi
mkdir -p "$ROOT/.claude"
STATE_LOCAL="$ROOT/.claude/ralph-loop.local.md"
if [ -f "$STATE_LOCAL" ]; then
  echo "warning: $STATE_LOCAL already exists (another loop?). Replacing it." >&2
fi
cat > "$STATE_LOCAL" <<EOF2
---
active: true
iteration: 1
session_id: ${CLAUDE_CODE_SESSION_ID:-}
max_iterations: $MAX_IT
completion_promise: "$PROMISE"
started_at: "$(now_iso)"
---

Continue the Rosalbito run $RUN_ID in this repository.

1. Read .agent/runs/current/state.md first. It is the only source of truth about this run. Durable repo knowledge is in .agent/context/.
2. Run \`bash "$SKILL_DIR/scripts/caps-check.sh"\` (the rosalbito skill directory is $SKILL_DIR). If it exits non-zero, write the blocked report and finish the run as blocked.
3. Continue from \`next_action\`. Record every check through \`bash "$SKILL_DIR/scripts/verify.sh" <label> '<command>'\`. Keep current.md truthful: status, next_action, log.
4. When the run reaches status done or blocked (finish-run.sh has been called and the final report printed), output exactly: <promise>$PROMISE</promise>

Do not restart classification or planning unless next_action says so. Do not return the transcript; return the report.
EOF2
bash "$SKILL_DIR/scripts/state.sh" set driver ralph-loop
echo "loop armed: ralph-loop Stop hook, max_iterations=$MAX_IT, promise='$PROMISE' ($STATE_LOCAL)"

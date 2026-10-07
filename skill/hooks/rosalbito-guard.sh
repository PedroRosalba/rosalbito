#!/usr/bin/env bash
# rosalbito-guard.sh — PreToolUse hard gate for Bash commands.
#
# Denies operations that must never happen autonomously, regardless of model confidence:
#   force-push, push to main/master, merging PRs, --prod deploys, destructive SQL,
#   rm -rf on roots/home/.git, infra destroy/apply, production credentials.
# Installed into ~/.claude/settings.json by install.sh. Reads the hook JSON on stdin.
# A denied command is a hard_gate decision for Pedro, not something to work around.
set -uo pipefail
INPUT="$(cat)"
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
else
  CMD="$INPUT"; CWD=""
fi
[ -n "$CMD" ] || exit 0

deny() {
  local reason="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "rosalbito hard gate: $reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    echo "rosalbito hard gate: $reason" >&2
  fi
  exit 2
}

# strip quoted strings' innards lightly so patterns match the command shape
C="$CMD"

# --- git ---
if printf '%s' "$C" | grep -qE '(^|[;&|]\s*)\s*(rtk\s+)?git\s+push\b'; then
  printf '%s' "$C" | grep -qE 'git\s+push\b[^;&|]*(\s--force\b|\s-f\b|\s--force-with-lease|\s-[a-zA-Z]*f[a-zA-Z]*\s|\+[A-Za-z0-9_./-]+)' && deny "force push"
  printf '%s' "$C" | grep -qE 'git\s+push\b[^;&|]*\s(origin|upstream|[A-Za-z0-9_.-]+)\s+(refs/heads/)?(main|master)(\s|$|:)' && deny "push to main/master"
  printf '%s' "$C" | grep -qE 'git\s+push\b[^;&|]*:(refs/heads/)?(main|master)(\s|$)' && deny "push to main/master"
  printf '%s' "$C" | grep -qE 'git\s+push\b[^;&|]*\s--delete\b' && deny "remote branch deletion"
  # bare `git push` while on main/master
  if printf '%s' "$C" | grep -qE 'git\s+push\s*($|[;&|]|\s-u\s+\S+\s*$|\s(origin|upstream)\s*$)'; then
    br="$(git -C "${CWD:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    case "$br" in main|master) deny "bare git push while on $br";; esac
  fi
fi
printf '%s' "$C" | grep -qE 'git\s+branch\s+(-D|-d|--delete)\s+(main|master)\b' && deny "deleting main/master"
printf '%s' "$C" | grep -qE 'gh\s+pr\s+merge\b' && deny "merging a PR is Pedro's approval"
printf '%s' "$C" | grep -qE 'gh\s+(repo\s+delete|api\s+[^;&|]*-X\s*DELETE)' && deny "destructive GitHub operation"

# --- deploys / infra ---
printf '%s' "$C" | grep -qE '\b(vercel|netlify|firebase|fly|flyctl|railway|now|wrangler|sst|amplify|heroku|eb)\b[^;&|]*\s--(prod|production)\b' && deny "production deploy"
printf '%s' "$C" | grep -qE '\b(vercel\s+promote|vercel\s+rollback|vercel\s+alias)\b' && deny "production deploy"
printf '%s' "$C" | grep -qE '\b(terraform|tofu|pulumi)\s+(apply|destroy)\b' && deny "infrastructure mutation"
printf '%s' "$C" | grep -qE '\bkubectl\s+(delete|drain|cordon)\b|\bkubectl\s+[^;&|]*prod' && deny "kubernetes mutation"
printf '%s' "$C" | grep -qE '\bhelm\s+(uninstall|delete|rollback)\b' && deny "helm mutation"
printf '%s' "$C" | grep -qE '\bdocker\s+(system\s+prune|volume\s+(rm|prune))\b' && deny "docker data deletion"

# --- data ---
printf '%s' "$C" | grep -qiE '\b(drop\s+(table|database|schema)|truncate\s+(table\s+)?[a-z_])' && deny "destructive SQL"
printf '%s' "$C" | grep -qE '\brm\s+-[a-zA-Z]*[rR][^;&|]*\s(/|~|~/|\$HOME|\$HOME/|\.git|\.git/|\*|/\*)(\s|$)' && deny "rm -rf on root/home/.git"
printf '%s' "$C" | grep -qE '\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+/(etc|usr|var|bin|home|Users)(\s|/|$)' && deny "rm -rf on system path"
printf '%s' "$C" | grep -qE '\bmkfs\b|\bdd\s+[^;&|]*of=/dev/' && deny "disk destruction"

# --- credentials ---
printf '%s' "$C" | grep -qE '\b[A-Z0-9_]*(PROD|PRODUCTION)[A-Z0-9_]*(KEY|SECRET|TOKEN|PASSWORD|PASS|DSN|URL)[A-Z0-9_]*=' && deny "production credential in command"
printf '%s' "$C" | grep -qE '\s--profile[= ]+(prod|production)\b|\s--env(ironment)?[= ]+(prod|production)\b|\s--stage[= ]+(prod|production)\b' && deny "production environment target"

exit 0

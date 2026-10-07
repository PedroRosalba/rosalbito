# Environment inventory (verified 2026-10-06, Pedro's Mac Mini)

Verified by inspection, not assumed. Re-check with `skill/scripts/detect-tools.sh`.

| Capability | Status | Evidence | Rosalbito use |
|---|---|---|---|
| Claude Code CLI | 2.1.292 at `~/.local/bin/claude` | `claude --version` | host |
| `/code-review` (incl. `ultra`) | built-in skill, listed in session | skill list | inside reviewer subagents (MEDIUM+) |
| `security-review` skill | built-in, listed | skill list | inside security reviewer (HIGH+) |
| `ralph-loop` plugin 1.0.0 | installed + enabled | `~/.claude/plugins/installed_plugins.json`, `settings.json enabledPlugins` | **the loop driver** (Stop hook, `.claude/ralph-loop.local.md`) |
| `/loop` | built-in (ScheduleWakeup / CronCreate) | skill list | not used by Rosalbito (polling-shaped) |
| Workflow tool | available (medium size guideline, user opt-in required) | tool list | not used in Phase 1 (needs explicit user opt-in per call) |
| Agent tool | available: general-purpose, Explore, Plan, fork | tool list | understanding pass, implementer, reviewers, debugger |
| Hooks | `~/.claude/settings.json` has PreToolUse (rtk-rewrite, safety-check) and PostToolUse (auto-push) | file read | `rosalbito-guard.sh` added by `install.sh` |
| Existing `safety-check.sh` | reads `$CLAUDE_TOOL_INPUT`, which hooks do not receive (stdin JSON) → effectively a no-op | file read | superseded by the guard hook |
| Existing `auto-push.sh` | pushes `~/projects` (not a repo) → effectively a no-op | file read | ignored |
| `enor-plan` / `enor-log` | symlinked skills in `~/.claude/skills` (Enor suite) | ls | not wired; heavy planning is replaced by the understanding pass + plan section. Candidate for HIGH+ if real runs show plans are too thin |
| `skill-creator` | synced Anthropic skill | `~/.claude/skills/synced/.../skill-creator` | conventions followed: SKILL.md < 500 lines, `scripts/`, `references/`, progressive disclosure |
| `gh` | 2.x, logged in as PedroRosalba, scopes repo/workflow | `gh auth status` | PR creation |
| `jq` | /opt/homebrew/bin/jq | which | evidence, hooks, metrics |
| `yq` | absent | which | not needed (awk/sed parsing of flat YAML) |
| Node 26 / cargo 1.93 / python 3.14 | present | versions | target repos' checks |
| `rtk` hook | rewrites Bash commands through `rtk` | settings.json | transparent; guard matches `rtk git push …` too |
| Nested `claude -p` | works when `CLAUDECODE` is unset | tested | resume test harness |
| `CLAUDE_CODE_SESSION_ID` | exposed to the Bash tool | `env` | ralph-loop session isolation |

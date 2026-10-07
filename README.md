# Rosalbito

**One command for every engineering task.** `/rosalbito <task>` is a Claude Code skill that
takes anything from "fix this typo" to "migrate the payment schema overnight", classifies
it, routes it through an autonomous understand → plan → implement → verify → review loop,
and delivers either a verified pull request or a precise decision that genuinely needs a
human.

The single most important design property: **overhead scales with the task.** A trivial
fix gets near-zero ceremony. A critical change gets fresh-context adversarial reviewers,
an understanding pass, and an engineering report. Rosalbito decides which, you don't.

```
CLASSIFY (risk + human dependency) → (UNDERSTAND) → ACCEPTANCE
→ (DECISION GATE only if a human is truly needed) → PLAN
→ IMPLEMENT → VERIFY → REVIEW → FIX → VERIFY → DOCUMENT → PR → DONE
```

## Principles

- **Thin orchestrator.** The skill classifies, routes, delegates, verifies, reports. Heavy
  work runs in subagents with their own focused prompts.
- **Deterministic verification is the backbone.** A command with an exit code, recorded to
  `.agent/evidence/*.jsonl`, outranks any model opinion. "Done" cites evidence lines.
- **Instructions are soft; mechanisms are hard.** Force-push, push to main, `--prod`
  deploys, destructive SQL, PR merges and production credentials are denied by a
  PreToolUse hook, not by a sentence in a prompt.
- **The PR is the human gate.** Every code change lands as a PR on a feature branch.
  Merging is approval. Rosalbito never deploys and never merges.
- **Risk and human dependency are separate axes.** High risk buys more reviewers, not
  more interruptions. A wake-up happens only after investigation, with options and a
  recommendation.
- **State survives.** `.agent/state/current.md` is the single re-entry point. A fresh agent
  reads it and continues. Tested by killing a session mid-run.

## Install

```bash
git clone https://github.com/PedroRosalba/rosalbito ~/rosalbito
cd ~/rosalbito && ./install.sh      # symlinks the skill, registers the guard hook
# optional loop driver (recommended):
#   in Claude Code: /plugin install ralph-loop@claude-plugins-official
```

Restart Claude Code. Then, in any repository:

```
/rosalbito add an integration test that runs the CLI on the sample CSV
/rosalbito status
/rosalbito            # resumes an interrupted run
```

Requires: Claude Code, `git`, `gh` (authenticated), `jq`, bash 3.2+ (macOS default works).

## How a run works

| Risk tier | What happens |
|---|---|
| TRIVIAL | branch → change → run the relevant checks → PR. No state, no loop. One paragraph. |
| LOW | + `.agent/` run state, loop driver, full verification with evidence. |
| MEDIUM | + acceptance contract (every criterion names its verification), implementation subagent, one fresh-context adversarial review. |
| HIGH | + read-only understanding pass, security review, architecture review. Reviewers re-run the checks themselves. |
| CRITICAL | + independent correctness review, full engineering report, decision record for every non-obvious choice. |

Path floors (`skill/config/risk-overrides.yaml`): anything touching auth, payments,
migrations, secrets, CI or infrastructure is HIGH at minimum, whatever the model thinks.

The human axis is separate: `none | visibility | decision | hard_gate`. Visibility is the
default even for CRITICAL work. `decision` fires only for the triggers in
`skill/references/routing.md`, after the inference sources are exhausted, and stops
*before* implementation. `hard_gate` is operation-triggered and backed by the hook.

## Layout

```
skill/                      the Claude Code skill (symlinked to ~/.claude/skills/rosalbito)
  SKILL.md                  thin orchestrator (~170 lines)
  config/                   risk-overrides.yaml, caps.yaml (per-repo overridable via .agent/)
  scripts/                  init-run, state, verify, detect-checks, classify-paths,
                            caps-check, start-loop, finish-run, metrics, evidence-summary
  hooks/rosalbito-guard.sh  PreToolUse hard gate
  templates/                current.md, acceptance.yaml, decision.md, blocked.md, report.md, pr-body.md
  references/               routing, driver, reviews, understanding, reports, state-schema
install.sh                  symlink + hook registration (idempotent, backs up settings.json)
tests/run.sh                74 deterministic checks for scripts and the hook
docs/                       spec, inventory, reuse-vs-build, driver decision, resume test, experiments
```

Inside a target repository, a run leaves:

```
.agent/
  state/current.md   resume entry point      evidence/<run>.jsonl   verification results
  acceptance/        contracts               decisions/             decision records
  reports/           reports / blocked       understanding/         dated run artifacts
  metrics.jsonl      one line per run
```

Committed on the feature branch so the PR carries its own audit trail
(`ROSALBITO_COMMIT_AGENT_DIR=0` to keep it local).

## Hard caps

`max_iterations_per_run: 25`, `max_wall_clock_hours: 8`, `max_same_failure: 3`.
`caps-check.sh` enforces them at every loop re-entry. Hitting one writes a blocked report
with full state. Never continues indefinitely.

## Status

Phase 1 (MVP) is implemented and tested: entrypoint + two-axis router, persistent state +
resume protocol, deterministic verification + evidence, PR delivery, hard caps, loop driver
(ralph-loop Stop hook), guard hook. See `docs/` for the inventory, the reuse-vs-build
analysis, the driver decision, the resume test, and the first real experiment.
Phases 2–4 (acceptance wiring, reviewer prompts, reports, metrics) exist as minimal
templates and are only expanded against failures observed in real runs.

## Development

```bash
bash tests/run.sh          # script + hook tests (throwaway git repo, no network)
```

## License

MIT

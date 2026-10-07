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

Restart Claude Code **inside the target repository** (the loop driver's Stop hook is bound
to the session's directory). Then:

```
/rosalbito add an integration test that runs the CLI on the sample CSV
/rosalbito understand            # read-only pass: understanding doc + Mermaid diagrams into .agent/context/
/rosalbito grill custody model   # interactive grilling (Matt Pocock's grilling + domain-modeling), in your session
/rosalbito status
/rosalbito                       # resumes an interrupted run
```

Recommended primitives (Rosalbito routes to them; `/rosalbito` stays the only entrypoint):
`/plugin install mattpocock-skills@claude-plugins-official` for `grilling`, `domain-modeling`,
`diagnosing-bugs`, `research`, `code-review`.

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
  SKILL.md                  thin orchestrator (~200 lines): dispatch, classify, loop, understand and grill modes
  config/                   risk-overrides.yaml, caps.yaml (per-repo overridable via .agent/), pricing.json
  scripts/                  init-context, init-run, state, verify, detect-checks, classify-paths,
                            caps-check, start-loop, finish-run, metrics, evidence-summary,
                            usage, collect, dashboard
  hooks/rosalbito-guard.sh  PreToolUse hard gate
  templates/                current.md, acceptance.yaml, decision.md, blocked.md, report.md, pr-body.md, dashboard.html
  references/               routing, driver, reviews, understanding, reports, state-schema
skills/telemetry/           generic telemetry-engineering skill (model-invoked; symlinked to ~/.claude/skills/telemetry)
install.sh                  symlinks + hook registration (idempotent, backs up settings.json)
tests/run.sh                90 deterministic checks for scripts and the hook
tests/resume-test.sh        kill-a-session-mid-run test (real model calls)
docs/                       spec, inventory, reuse-vs-build, driver decision
```

Inside a target repository, Rosalbito keeps an internal tree that is **never committed**
(`init-context.sh` excludes it through `.git/info/exclude`, so the repo itself is untouched):

```
.agent/
  context/        durable — what we know about this repo
    understanding/  diagrams/  glossary/CONTEXT.md  adr/  telemetry/  invariants.md
  runs/           ephemeral — what happened during each run
    current -> <run_id>/   <run_id>/{state.md, acceptance.yaml, evidence.jsonl, reports/}   metrics.jsonl
```

Runs read `context/` and write `runs/`. The PR body carries the evidence table and decision
summaries; the files stay local for Pedro and the agents. Matt Pocock's `grilling` and
`domain-modeling` hard-code `CONTEXT.md` and `docs/adr/`; `init-context.sh` turns both into
excluded symlinks into `context/`, so they land in the right place without the skills knowing.
Run write-ups and experiment logs are kept locally too, not in this repository.

## Observability

```bash
bash skill/scripts/dashboard.sh --open      # or /rosalbito dashboard
```

Every run, in every repo, on one local page (`~/.rosalbito/dashboard.html`): outcome, wall
time, iterations, checks, review rejections, subagents spawned, and API-equivalent cost per
agent role and per token kind, plus a "Needs attention" list (abandoned runs, HIGH runs
without a report, runs with no transcript, loops). The numbers are read after the fact:

- `usage.sh` parses Claude Code's own transcripts (`~/.claude/projects/<dir>/<session>.jsonl`
  and `<session>/subagents/agent-*.jsonl` + `.meta.json`), finds a run's sessions by the
  `run_id` it printed (or the `sessions` recorded in `state.md`), keeps the messages inside
  the run's time window, and prices them with `config/pricing.json`. Subagent transcripts often
  keep only partial output counts; those are estimated from visible text and flagged.
- `collect.sh` rebuilds `~/.rosalbito/runs.jsonl` from every repo with an `.agent/` (registered
  by init-run/finish-run, or found under `$HOME`), finished or not.
- `dashboard.sh` renders that index into one self-contained HTML file. Nothing leaves the machine.

On a Claude subscription the cost is a comparison figure, not the invoice.

## Hard caps

`max_iterations_per_run: 25`, `max_wall_clock_hours: 8`, `max_same_failure: 3`.
`caps-check.sh` enforces them at every loop re-entry. Hitting one writes a blocked report
with full state. Never continues indefinitely.

## Status

Phase 1 (MVP) is implemented and tested: entrypoint + two-axis router, persistent state +
resume protocol (validated by `tests/resume-test.sh`: a session killed mid-run was resumed by
a fresh one from `.agent/` alone), deterministic verification + evidence, PR delivery, hard
caps, loop driver (ralph-loop Stop hook), guard hook, understand and grill modes, and the
generic telemetry skill. The first real run shipped a PR on a Rust payment CLI in 6.5 minutes
with zero interruptions; the lessons from it are folded into the skill.
Phases 2–4 (acceptance wiring, reviewer prompts, reports, metrics) exist as minimal
templates and are only expanded against failures observed in real runs.

## Development

```bash
bash tests/run.sh          # script + hook tests (throwaway git repo, no network)
```

## License

MIT

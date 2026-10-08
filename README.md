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

As a Claude Code plugin (this repository is both the marketplace and the plugin), in Claude Code:

```
/plugin marketplace add PedroRosalba/rosalbito
/plugin install rosalbito@rosalbito
# optional loop driver (recommended):
/plugin install ralph-loop@claude-plugins-official
```

That installs three things: the `rosalbito` skill, the companion `telemetry` skill
(model-invoked: the implementer reaches for it on telemetry-shaped work), and the PreToolUse guard hook (the hard gate below),
registered by the plugin itself: no hook entry is written to `settings.json` (Claude Code only records that the plugin is enabled). Update with
`/plugin marketplace update rosalbito` then `/plugin update rosalbito@rosalbito`; remove with
`/plugin uninstall rosalbito@rosalbito`.

Restart Claude Code **inside the target repository** (the loop driver's Stop hook is bound
to the session's directory). The skill answers to `/rosalbito` (the plugin-qualified name
`/rosalbito:rosalbito` always works too, and is the one to use if another skill called
`rosalbito` is installed). Then:

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

### Standalone install (alternative)

Without the plugin system, from a clone:

```bash
git clone https://github.com/PedroRosalba/rosalbito ~/rosalbito
cd ~/rosalbito && ./install.sh      # symlinks both skills, registers the guard hook in ~/.claude/settings.json
```

`install.sh` is idempotent, registers the hook path quoted, backs up `settings.json` before
every real edit, and refuses to write it if the file is not valid JSON. The skill moved from
`skill/` to `skills/rosalbito/`; a `skill` symlink keeps the old hook path working, and
re-running `./install.sh` after pulling moves the links and the hook to the new path.

Use **one** install, not both: with the plugin and `install.sh` active together the guard
runs twice and every skill is listed twice.

### Switching from install.sh to the plugin

Install the plugin first (the two `/plugin` commands above), then remove the standalone
install, so there is never a window without the guard (running it twice meanwhile is
harmless):

```bash
cd ~/rosalbito && git pull           # an older install.sh does not know --uninstall
./install.sh --uninstall             # removes ~/.claude/skills/{rosalbito,telemetry} links and the rosalbito-guard hook entry
```

Before uninstalling, check that the plugin's guard is live: `/hooks` should list the
rosalbito plugin's `PreToolUse` hook. `--uninstall` refuses while the plugin is not enabled
in `settings.json` (it would leave no guard at all); `--uninstall --force` overrides that.
It only removes symlinks that point into a rosalbito checkout, leaves every other hook in
`settings.json` alone, and backs the file up first. Restart Claude Code. (By hand: delete
the two symlinks and the `PreToolUse` entry whose command contains `rosalbito-guard.sh`.)
If `git pull` aborts with "untracked working tree files would be overwritten", move the
untracked files out of `skill/` first: the old guard path keeps working until you do.

The `skill -> skills/rosalbito` link keeps hook paths registered by older standalone installs
working. Removing it would silently disable those guards (a missing hook file is a
non-blocking error), so it stays until standalone install mode is retired; the PR that
removes it must also make `install.sh` and the preflight refuse a dead guard path.

## How a run works

| Risk tier | What happens |
|---|---|
| TRIVIAL | branch → change → run the relevant checks → PR. No state, no loop. One paragraph. |
| LOW | + `.agent/` run state, loop driver, full verification with evidence. |
| MEDIUM | + acceptance contract (every criterion names its verification), implementation subagent, one fresh-context adversarial review. |
| HIGH | + read-only understanding pass, security review, architecture review. Reviewers re-run the checks themselves. |
| CRITICAL | + independent correctness review, full engineering report, decision record for every non-obvious choice. |

Path floors (`skills/rosalbito/config/risk-overrides.yaml`): anything touching auth, payments,
migrations, secrets, CI or infrastructure is HIGH at minimum, whatever the model thinks.

The human axis is separate: `none | visibility | decision | hard_gate`. Visibility is the
default even for CRITICAL work. `decision` fires only for the triggers in
`skills/rosalbito/references/routing.md`, after the inference sources are exhausted, and stops
*before* implementation. `hard_gate` is operation-triggered and backed by the hook.

## Layout

```
.claude-plugin/             plugin.json + marketplace.json (the repo is its own marketplace)
hooks/hooks.json            plugin hook registration: the guard on every Bash call
skills/rosalbito/           the Claude Code skill (standalone: symlinked to ~/.claude/skills/rosalbito)
  SKILL.md                  thin orchestrator (~200 lines): dispatch, classify, loop, understand and grill modes
  config/                   risk-overrides.yaml, caps.yaml (per-repo overridable via .agent/), pricing.json
  scripts/                  init-context, init-run, state, verify, detect-checks, classify-paths,
                            caps-check, start-loop, finish-run, metrics, evidence-summary,
                            usage, collect, dashboard (+ dashboard-server.mjs)
  hooks/rosalbito-guard.sh  PreToolUse hard gate
  templates/                current.md, acceptance.yaml, decision.md, blocked.md, report.md, pr-body.md, dashboard.html
  references/               routing, driver, reviews, understanding, reports, state-schema
skill -> skills/rosalbito   compatibility link: keeps hook paths from older standalone installs working
skills/telemetry/           generic telemetry-engineering skill (model-invoked; standalone: symlinked to ~/.claude/skills/telemetry)
install.sh                  standalone install: symlinks + hook registration, --uninstall (idempotent, backs up settings.json)
tests/run.sh                101 deterministic checks for scripts, the hook and the packaging
tests/plugin-hook.sh        the guard run exactly as hooks/hooks.json registers it
tests/standalone-install.sh install.sh / --uninstall against a throwaway HOME
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
bash skills/rosalbito/scripts/dashboard.sh --serve --open    # live: http://localhost:7777, updates itself
bash skills/rosalbito/scripts/dashboard.sh --install-service # same, kept running by launchd (starts at login)
bash skills/rosalbito/scripts/dashboard.sh --open            # one-off static snapshot: ~/.rosalbito/dashboard.html
```

Paths are relative to a clone; with the plugin, `/rosalbito dashboard` finds the script for you.
`--install-service` runs a copy of the server from `~/.rosalbito/service/` (plugin paths are
versioned and replaced on update); re-run it after updating to pick up a newer dashboard.

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
- `collect.sh` is incremental: a run whose state, evidence and transcripts did not change since the
  last pass keeps its line, so a refresh with nothing new costs well under a second.
- `dashboard-server.mjs` (Node, no dependencies, 127.0.0.1 only) re-collects every 15 s, with a full pass
  every 10 min; the page polls `/api/runs` every 5 s and re-renders in place when the data changes,
  keeping filters and expanded rows. `dashboard.sh` without `--serve` writes the same page as a static file.

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
bash tests/run.sh          # script + hook + packaging tests (throwaway git repo and HOME, no network)
claude plugin validate .                            # marketplace manifest (and the plugin it lists)
claude plugin validate .claude-plugin/plugin.json   # plugin manifest
claude --plugin-dir .      # load this checkout as the plugin for one session
```

## License

MIT

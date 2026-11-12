# Persistent state: `.agent/` (internal, never committed)

```
.agent/
  context/                   durable — what we know about this repository
    understanding/<date>-<slug>.md   understanding passes (KNOWN / INFERRED / UNKNOWN)
    diagrams/*.mmd                   architecture, data flow, trust boundaries (Mermaid)
    glossary/CONTEXT.md              domain glossary (Matt Pocock domain-modeling format)
    adr/<n>-<slug>.md                decision records (context, options, choice, why)
    telemetry/                       instrumentation map, conventions (telemetry skill)
    invariants.md                    repo invariants handed to reviewers (candidate → confirmed)
    risk-overrides.yaml, caps.yaml   optional per-repo config overrides
  runs/                      ephemeral — what happened during each execution
    current -> <run_id>              symlink to the active (or last) run
    <run_id>/state.md                resume entry point (frontmatter scalars + sections)
    <run_id>/acceptance.yaml         contract (MEDIUM+)
    <run_id>/evidence.jsonl          verification results (verify.sh)
    <run_id>/reports/                engineering report, blocked report
    adhoc.jsonl                      evidence recorded outside a run
    metrics.jsonl                    one line per finished run (metrics.sh, with usage block)
~/.rosalbito/                cross-repo, local: repos (registry), runs.jsonl (collect.sh), dashboard.html
```

Runs read `context/` and write `runs/`. Durable learnings produced by a run (decisions,
terms, understanding) go to `context/`, so the next run starts smarter.

**Never committed.** `init-context.sh` adds `.agent/` to `.git/info/exclude` (not
`.gitignore`: the target repo is not modified). The PR body carries the evidence table and
decision summaries; the files stay on the machine for Pedro and the agents.
`ROSALBITO_COMMIT_AGENT_DIR=1` opts in to committing them.

**Matt Pocock skills redirection.** `grilling` + `domain-modeling` hard-code `CONTEXT.md` at
the repo root and `docs/adr/`. `init-context.sh` makes both symlinks into `context/` and
excludes them, so those skills write where we want without knowing it. If the repo already
has a real `CONTEXT.md` or `docs/adr/`, they are left alone (repo-owned) and reported.

## `state.md` frontmatter

| key | meaning |
|-----|---------|
| run_id | `YYYYMMDD-HHMMSS-<slug>` |
| task | the task statement |
| repo, branch, base_branch | where the run lives |
| risk, path_floor | tier and the path-rule floor |
| human_required, human_level | axis 2 |
| status | classifying · understanding · acceptance · planning · implementing · verifying · reviewing · documenting · pr · done · blocked |
| iteration | bumped per loop re-entry (`state.sh bump`) |
| started_at, updated_at, finished_at | UTC ISO (`finished_at` set by finish-run.sh) |
| sessions | Claude Code session ids that worked on the run (init-run, caps-check on resume) |
| harness_version | rosalbito commit the run started on: compare runs across harness versions |
| driver | ralph-loop · none |
| acceptance, evidence | paths |
| pr | URL once opened |
| next_action | one imperative sentence a fresh agent can execute |

Sections: Task · Classification · Plan · Verified · Failed · Reviews · Open decisions · Log.

## Resume protocol

1. Read `runs/current/state.md`. 2. `caps-check.sh`. 3. `start-loop.sh` (re-arm for this
session). 4. Continue from `next_action`, re-verifying before advancing.
A brand-new agent reading only `.agent/` must know: the task, what happened, what remains,
what is verified, what failed, what was decided. Tested by killing a session mid-run
(`tests/resume-test.sh`).

## Evidence line

```json
{"ts":"2026-10-06T23:10:02Z","run_id":"…","iteration":2,"label":"test","command":"cargo test","exit":0,"duration_s":4,"output_tail":"…last 40 lines…"}
```

## Index line (`~/.rosalbito/runs.jsonl`)

One JSON object per run: the `metrics.sh` line plus what `collect.sh` adds.

| key | meaning |
|-----|---------|
| run_id, repo, repo_path, task, risk, status, stale | identity and outcome (`stale`: open and untouched for 24 h) |
| started_at, finished_at, updated_at, wall_minutes, iterations | timing |
| checks_run, checks_failed, same_failure_max, checks_passing | evidence totals; labels whose last result passed |
| check_labels | `[{label, command (first, up to 600 chars), runs, failed, last_exit}]` per evidence label; `failed` counts numeric non-zero exits only |
| fix_cycles, fix_cycles_command_changed, fix_cycle_labels | fail → pass transitions per label (a missing exit is unknown; `x-2`..`x-9` counts as `x` when `x` exists); how many passed with a different command than the failing run; the labels involved |
| review_rounds, review_rejections, decisions_recorded, human_interventions | from state.md and ADRs |
| test_files_touched | files in the run's own diff under `tests/`, `__tests__/`, `spec/`, `e2e/` or named `*.test.*`, `*.spec.*`, `test_*.py`; `null` when the diff is |
| usage | `usage.sh` block: `sessions`, `agents[]` (role, models, messages, token kinds, cost, tools, `effort`, `effort_messages`, `thinking_ms`, `total_tokens`, `first_context_tokens`, `peak_context_tokens`; orchestrators also `session_started_at`, `mid_session`), `totals` (the same sums plus `peak_context_tokens`, `effort_mix`, `model_mix`, `cost_by_role`). Fork subagents' replayed lines count once, for the agent that owns them |
| usage_overlaps, usage_duplicate_of | runs reading the same session over overlapping windows; when the usage is identical, every run but the earliest names it in `usage_duplicate_of` and aggregates count that usage once |
| input_size | `{task_chars, first_context_tokens (orchestrator's first request in the run window), first_context_mid_session, diff}` |
| input_size.diff | `{files, added, removed, test_files, base, head, basis, merge_base, branch, base_branch}` — see below |
| legacy | recovered from an old `metrics.jsonl` whose run directory is gone (no evidence detail) |

**The diff** is what the run committed, measured with read-only git. `head` is the branch as it
was at `finished_at` + 10 min (its tip while open; the fresher of the local and `origin/` copy).
`base` is the lower bound, named by `basis`: `since run start` = the branch's own commit at
`started_at`, used when it descends from the merge-base with the base branch as of `started_at`
(so a wrong or stale `base_branch` cannot pull earlier work in); `vs merge-base` = that
merge-base otherwise; `since repo creation` = the empty tree when the repository was created
during the run. The diff is `null` — never a guess — when no range can be resolved or the range
holds no commit dated inside the run's window (a branch rewritten after the run, or nothing
committed).

Context of one request = input + cache write + cache read tokens; `total_tokens` adds output
(which for some subagent messages is estimated: `output_estimated_messages`). Effort is the
`effort` (else `perTurnEffort`) field Claude Code writes on each assistant message; messages
without one count as `unknown`. `mid_session`: the orchestrator's session began more than 15
minutes (`ROSALBITO_MID_SESSION_MINUTES`) before the run, so its first context includes earlier work.

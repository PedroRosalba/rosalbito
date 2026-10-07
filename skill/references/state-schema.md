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
    metrics.jsonl                    one line per finished run (metrics.sh)
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
| started_at, updated_at | UTC ISO |
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

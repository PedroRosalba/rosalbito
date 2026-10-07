# Persistent state: `.agent/`

```
.agent/
  state/current.md        # resume entry point (frontmatter scalars + sections)
  state/history/<run>.md  # finished runs
  acceptance/<run>.yaml   # contracts
  evidence/<run>.jsonl    # verification results (verify.sh)
  decisions/<n>-<slug>.md # context, options, choice, why
  reports/<run>.md        # engineering reports; blocked-<run>.md
  understanding/<run>.md  # dated run artifacts (+ .mmd)
  metrics.jsonl           # one line per finished run (metrics.sh)
  invariants.md           # optional, per repo, hand-maintained
  risk-overrides.yaml     # optional per-repo path floors
  caps.yaml               # optional per-repo caps
```

**Internal, never committed.** `init-run.sh` adds `.agent/` to `.git/info/exclude` (not
`.gitignore`, so the target repo is not modified). The PR body carries the evidence table and
decision summaries; the files stay on the machine for Pedro and the agents.
`ROSALBITO_COMMIT_AGENT_DIR=1` opts in to committing them.

## `current.md` frontmatter

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

1. Read `current.md`. 2. `caps-check.sh`. 3. Continue from `next_action`.
A brand-new agent reading only `.agent/` must know: the task, what happened, what remains,
what is verified, what failed, what was decided. Tested by killing a session mid-run
(`docs/resume-test.md`).

## Evidence line

```json
{"ts":"2026-10-06T23:10:02Z","run_id":"…","iteration":2,"label":"test","command":"cargo test","exit":0,"duration_s":4,"output_tail":"…last 40 lines…"}
```

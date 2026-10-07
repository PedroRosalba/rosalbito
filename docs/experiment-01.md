# Experiment 01: first real run (spec §16)

Date: 2026-10-06 · Repo: `PedroRosalba/rust-tx-processor` (Rust payment engine CLI) ·
Result: **PR [#2](https://github.com/PedroRosalba/rust-tx-processor/pull/2) opened, run `done`** (replaces #1, see finding 7)

## Task

> Make the CLI output deterministic: sort the final account rows by client id. Add an
> integration test that runs the built binary on `transactions.csv` and asserts the output
> matches `accounts.csv` exactly. Update the README line that says row order is undefined.

A real, representative backlog item: a small code change in a money-handling CLI plus a new
test, in a repo with no CI and no open issues.

## How it ran

| Step | What happened | Wall clock (UTC) |
|---|---|---|
| Classify | `risk=MEDIUM floor=TRIVIAL human=visibility` (observable output contract of a ledger CLI; reversible; no DB/concurrency). `detect-checks.sh` found build/test/clippy/fmt. | 02:03 |
| Start | `init-run.sh` → branch `feature/deterministic-cli-output-sort-account-ro`, `.agent/`, loop armed. Acceptance contract: 6 criteria, each with a `command` or `reviewer`. Plan: 4 steps naming files and proving checks. | 02:03 |
| Implement | `general-purpose` subagent with task + plan + contract. Changed `src/main.rs` (+6/−1), new `tests/cli.rs` (2 tests), README line. Recorded 9 evidence lines. **Escalated a contradiction** instead of resolving it silently (below). | 02:04–02:05 |
| Verify (gate) | Orchestrator re-derived: test #10, cli #11, determinism ×5 #12, README grep #13, **clippy delta vs base** #14, rustfmt on changed files #15. All pass. | 02:06 |
| Decide | Decision 001 written: keep the PR scoped; pre-existing lint stays out, proven by the delta check. Inferred from task scope + repo evidence; Pedro not woken. | 02:06 |
| Review | Fresh-context adversarial reviewer: **ACCEPT, no findings** after header-only input, all-invalid rows, u16 boundaries, duplicates, locked accounts, 2000 random ids, CRLF, `cmp` byte checks. Recorded 9 more evidence lines (#16–#24). Flagged a real portability risk (LF fixture under autocrlf) → `.gitattributes` added, #25. | 02:07–02:09 |
| Deliver | Path floor re-checked on the real diff (TRIVIAL). 3 small commits + 1 closing commit, push, `gh pr create` with the evidence table, `finish-run.sh done`, metrics line. | 02:09 |

Metrics line: `iterations=2 checks_run=25 checks_failed=4 same_failure_max=2 review_rounds=1
review_rejections=0 decisions_recorded=1 human_interventions=0`. About 6.5 minutes end to end,
two subagents, zero interruptions.

## Where the workflow broke or wobbled, and what changed

1. **Contradictory acceptance criteria.** "repo-wide clippy/fmt pass" and "engine/money files
   untouched" could not both hold because the base branch already fails clippy and rustfmt
   in those files. The implementer did the right thing (proved the failures pre-existing,
   reverted its out-of-scope formatting, reported options). The workflow lacked a rule.
   → SKILL §Verify now says: if a repo check fails on the base branch too, record a **delta
   check against base** and a decision record; never widen scope silently.
2. **`cargo fmt` reformatted the whole crate.** Repo-wide formatters are a scope trap.
   → SKILL: format only the files you changed.
3. **The loop driver is cwd-bound.** The ralph-loop Stop hook looks for
   `.claude/ralph-loop.local.md` relative to the *session's* directory. This run was driven
   from a session started in another directory, so the hook would never have re-entered.
   It did not matter here (the run finished in one session) but it would overnight.
   → `start-loop.sh` now warns when the repo root differs from the session's project dir
   (`CLAUDE_PROJECT_DIR`), and the README says to start Claude Code in the target repo.
4. **Headless nested runs on real repos are blocked by auto mode.** Launching
   `claude -p --dangerously-skip-permissions "/rosalbito …"` from inside a Claude session was
   denied by the auto-mode classifier ("Create Unsafe Agents"); the same launch in a scratch
   repo was allowed. Overnight runs must be started by Pedro (or a scheduler) directly, not
   spawned by another agent. Documented in `docs/driver-decision.md`.
5. **Run slug truncation** cut mid-word (`…sort-account-ro`). Cosmetic. → `slugify` trims to
   a word boundary.
6. **Run artifacts were committed to the target repo.** The spec's "audit it in the PR" idea
   put `.agent/` (state, evidence, decisions) into PR #1. Pedro's rule: that documentation is
   internal to the organization and its agents, never committed to GitHub. → `init-run.sh`
   now excludes `.agent/` through `.git/info/exclude`; the PR body carries the evidence
   table and decision summaries instead. PR #1 was closed and replaced by #2 with only the
   two code commits. Lesson for the recovery itself: `gh pr close --delete-branch` also
   deletes the local branch, and switching branches drops tracked-but-now-excluded files
   from the working tree; the artifacts were restored from the commit objects.
7. **Evidence is noisy but useful.** 25 lines for a MEDIUM run, 9 from the reviewer. The
   `evidence-summary.sh` "latest per label" view is what the PR needs; the raw JSONL stays as
   the audit trail. No change.

## What worked as designed

- Overhead scaled: no understanding pass, no security/architecture review, no engineering
  report for a MEDIUM run; the PR body paragraph is the report.
- The gate re-derived evidence instead of trusting the implementer; the reviewer re-ran the
  checks and found a real portability issue the implementer and the gate both missed.
- The hard-gate hook fired three times during the day on real commands (two heredocs whose
  text contained a push-to-main line and an infrastructure apply command, and an
  infrastructure apply command in a headless test), including under
  `--dangerously-skip-permissions`. Side effect worth knowing: the hook matches the command
  *text*, so writing a file that merely mentions a denied command via a Bash heredoc is
  denied too; use the editor tools for such files.
- Decision 001 is in the PR for audit; Pedro was not woken for an inferable choice.

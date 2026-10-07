# Resume protocol test (spec §11): kill a session mid-run, start a fresh one

Date: 2026-10-06 · Harness: `tests/resume-test.sh` · Result: **passed**

> "Test it in Phase 1: kill a session mid-run, start a fresh one, confirm it continues
> correctly. If that test fails, nothing else matters."

## Setup

- Scratch repo: `calc.py` + `test_calc.py` (unittest) + `Makefile`, local bare `origin`, no GitHub remote.
- Task: *add `power(base, exp)` to calc.py with unit tests*; the task text tells the run to treat
  a failed `gh pr create` (no GitHub remote) as done and report the branch.
- Both sessions: headless `claude -p` with the installed skill, driver armed (ralph-loop).

## What happened

| Phase | Observation |
|---|---|
| Session 1 | classified `LOW / floor TRIVIAL / visibility`, wrote plan, `init-run`, armed loop, implemented, recorded evidence #1 test, #2 compile. **Killed with SIGKILL** at `status: implementing`, iteration 2, ~40 s in. |
| Session 2 (`/rosalbito`, no args) | First tool call: `state.sh show`. Second: read `current.md`, `caps-check.sh`, acceptance, evidence, `git diff`. Logged *"resumed after session death; implementation found in tree; re-verifying"*. Re-ran checks (#3 test, #4 compile), re-ran `classify-paths.sh` on the real diff, committed, pushed `feature/…` to origin, attempted `gh pr create` once (failed as expected), `finish-run.sh done`, printed the completion block and the promise. |

Assertions (11/11 substantive): same `run_id`, no second run created, terminal status `done`,
passing test evidence, `power()` present and real tests green, feature branch on origin,
metrics line written, loop state removed. The harness's one false negative was its own
JSONL parsing (the CLI's stderr warning shares the stream); fixed in the harness.

## What the test taught

1. **The resume protocol works from `.agent/` alone.** Session 2 never saw session 1's
   conversation. `current.md` + evidence + the working tree were enough.
2. **Evidence survives and is reused correctly.** Session 2 did not trust the dead session's
   "done" — the state said `implementing` — and re-verified before advancing. Right behavior.
3. **The dead session's driver state must be cleared.** `.claude/ralph-loop.local.md` carried
   session 1's `session_id`; the plugin's Stop hook ignores a mismatched id (so session 2 was
   never blocked), but the harness removes the file to be safe. `start-loop.sh` should replace
   it when a run is resumed from a new session — added to the follow-ups.
4. **`init-run.sh` creates an acceptance file even for LOW**, which the resumed agent then
   felt obliged to fill. Harmless, but LOW should not carry MEDIUM ceremony → follow-up.
5. The run used a status value (`delivering`) not in the schema's list. The scripts don't
   care; the docs should either enumerate loosely or the SKILL should name the phases
   explicitly. → follow-up (SKILL now names the phases).

## Reproduce

```bash
./install.sh && bash tests/resume-test.sh /tmp/rosalbito-resume   # ~5 minutes, real model calls
```

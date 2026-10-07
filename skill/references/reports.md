# Report formats

Optimize Pedro's reading time, not completeness. Separate **what Pedro needs to
understand** (semantics, invariants, boundaries, tradeoffs, irreversible decisions) from
**what the agent discovered** (file locations, call graphs, implementation detail).
Never return the transcript.

## Completion block (always, as the last message of a run)

```
ROSALBITO RUN COMPLETE
Task: <task> · Risk: <tier> (floor <tier>) · Human: <level> · Status: done
Changed: <files / one line>
Verification: ✓ test (#3) ✓ lint (#4) ✓ build (#5) ✓ review correctness (round 1)
Important discoveries: <≤3 bullets, only if Pedro must know>
Tradeoffs / remaining risks: <≤3 bullets or "none">
PR: <url>
```

TRIVIAL/LOW: the PR body paragraph is the report. HIGH+: also `.agent/reports/<run_id>.md`
from `templates/report.md`.

## Blocked block

`templates/blocked.md`, printed in full. It must be worth waking up for: the actual
decision, what was investigated, options with tradeoffs, why it cannot be inferred, a
recommendation when there is one, and what continues after the decision.

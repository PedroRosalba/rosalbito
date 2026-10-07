# Understanding pass brief (read-only Explore subagent, HIGH/CRITICAL)

Build enough repository understanding that an engineer could safely modify it for this
task. Write `.agent/understanding/<run_id>.md`. Do not modify code.

Cover, briefly and only as relevant: what the system does; entry points; components; data
flow; persistence; external dependencies; auth/security boundaries; testing and CI;
invariants the code relies on; unknowns.

Label every important claim:

```
KNOWN     — read it in code/config/tests (cite file:line)
INFERRED  — deduced from evidence (say which)
UNKNOWN   — could not determine
```

Never promote a guess to a fact. Generate a Mermaid `.mmd` file only when it genuinely
compresses understanding (architecture, data flow, trust boundaries). These are dated run
artifacts, not living documentation.

If the repo has no `.agent/invariants.md`, propose up to five candidate invariants derived
from the code (e.g. "payment state changes only through PaymentService") at the end of the
file; the orchestrator decides whether to persist them.

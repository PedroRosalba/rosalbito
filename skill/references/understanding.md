# Understanding pass brief (read-only Explore subagent, HIGH/CRITICAL)

Build enough repository understanding that an engineer could safely modify it. You are one
lens (system map · data flow & persistence · trust boundaries · testing/CI/invariants/
unknowns); the orchestrator assembles the lenses into
`.agent/context/understanding/<date>-<slug>.md` and the diagrams into
`.agent/context/diagrams/*.mmd`. Return your findings as Markdown; do not modify code.

Cover, briefly and only as relevant: what the system does; entry points; components; data
flow; persistence; external dependencies; auth/security boundaries; testing and CI;
invariants the code relies on; unknowns.

Label every important claim:

```
KNOWN     — read it in code/config/tests (cite file:line)
INFERRED  — deduced from evidence (say which)
UNKNOWN   — could not determine
```

Never promote a guess to a fact. Produce Mermaid source only when it genuinely compresses
understanding (architecture, data flow, trust boundaries; ≤25 nodes). Understanding files
are dated: a later pass supersedes, it does not edit.

Propose up to five candidate invariants derived from the code (e.g. "payment state changes
only through PaymentService") and up to ten questions only Pedro can answer (product
semantics, architecture choices, security boundaries); the orchestrator persists the
invariants as *candidate* in `.agent/context/invariants.md` and feeds the questions to
`/rosalbito grill`.

# Routing: two independent axes

> Engineering risk decides how much machinery and verification deploy.
> Human decision dependency decides whether Pedro gets woken.

Never use the risk tier as a proxy for "ask Pedro". A HIGH-risk task with clear
requirements runs fully autonomously. A LOW-risk task with an ambiguous product question
wakes him (after investigation).

## Axis 1 — engineering risk

Criteria: scope, uncertainty, security / data-integrity / production / financial
relevance, reversibility, concurrency, database implications. Money is one example of
risk, not the point.

| Tier | Typical | Machinery |
|------|---------|-----------|
| TRIVIAL | typo, comment, config tweak, rename in one file | implement directly; run relevant checks; no state; one-paragraph report; PR |
| LOW | small isolated change, obvious tests | run + state + evidence; PR; short report |
| MEDIUM | multi-file feature or bug fix, moderate uncertainty | + acceptance contract, implementation subagent, one fresh-context review |
| HIGH | security/data/concurrency/money relevant, or hard to reverse | + understanding pass, security review, architecture review; reviewers re-derive evidence |
| CRITICAL | wrong = data loss, money loss, outage, legal | + independent correctness review, full engineering report, decision record for every non-obvious choice |

**Path floors** (`config/risk-overrides.yaml`): auth, payments, migrations, secrets, CI,
infrastructure, cryptography → HIGH minimum. The classifier is the same model that wants
to proceed, so its incentive is to under-classify; path rules make that impossible where
it matters. The classifier may raise above the floor, never lower. Re-run
`classify-paths.sh` on the real diff before the PR.

## Axis 2 — human decision dependency

```yaml
human:
  required: true|false
  level: none | visibility | decision | hard_gate
  reason: []        # mandatory for decision and hard_gate
```

- **none** — TRIVIAL only.
- **visibility** — default for everything else, including HIGH/CRITICAL. Pedro sees the
  PR, the report and the decision records; he approves by merging. No interruption.
- **decision** — a genuine unresolved decision blocks progress. Wake him, but only after
  investigating. Gate position: **before implementation**.
- **hard_gate** — operation-triggered, never tier-triggered: production credentials or
  secrets, destructive or irreversible operations, real financial transactions, production
  data changes, anything a merge cannot undo. Backed by `hooks/rosalbito-guard.sh`.

### Inference sources (exhaust these before `decision`)

1. the task statement
2. repository evidence (code, tests, docs, git history)
3. the acceptance contract
4. established invariants (`.agent/invariants.md` when present)
5. prior decisions in `.agent/decisions/`

If the answer can be inferred from these, decide, and write a decision record. Waking
Pedro to rubber-stamp an inferable choice is a failure, same as guessing silently.

### Decision triggers

- requirements materially ambiguous after investigation; evidence contradicts itself
- two materially different valid architectures with no inferable winner
- unclear security boundary
- missing credentials or access the agent cannot obtain
- tests contradict the stated expected behavior
- the agent cannot determine what "correct" means

### Shape of a wake-up

```
I don't know.
Here is what I investigated.
Here are the plausible interpretations.
Here is why I cannot safely choose.
Here is the decision I need from you.
```

"I need clarification" without investigation is a failed run, not a question.

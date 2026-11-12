# Build `/rosalbito`: My Universal Engineering Entrypoint

## 0. What this is

`/rosalbito` is the ONE command I give engineering tasks to. I will embed it in essentially every prompt — from "fix this typo" to "migrate the payment schema overnight."

That means the single most important design property is:

> **Overhead must scale with the task.**

A trivial task gets near-zero ceremony. A critical task gets the full loop. Rosalbito decides which, not me.

The goal:

> I give Rosalbito any task, disappear, and come back to either a completed, independently verified change (delivered as a PR), or a precise decision that genuinely requires me.

Two failure modes, both fatal:

1. It produces impressive Markdown but does not reliably ship correct code.
2. It wraps a 2-minute fix in 40 minutes of ritual — I will stop using it, and a workflow I don't use has failed.

## 1. Ground rules (read these before designing anything)

- **Rosalbito is a thin orchestrator, not a monolith.** It classifies, routes, delegates, verifies, and reports. The heavy work happens in subagents.
- **Composition happens via subagents, not stacked slash commands.** A skill invocation loads its instructions into the *current* context; chaining skills in one session stacks their instruction surfaces and contaminates everything downstream. The orchestrator stays small and spawns subagents with their own focused prompts (a subagent's prompt may tell it to use a specific skill).
- **Deterministic verification is the backbone.** A shell command with an exit code, recorded to a file, outranks any model opinion. Model-based review is a supplement, never a substitute.
- **Instructions are soft; mechanisms are hard.** A safety rule that exists only as Markdown is a soft gate. Hard gates are hooks, permission settings, absent credentials, and branch protection. Anything labeled "must never happen" needs a mechanism, not a sentence.
- **The PR is the human gate.** Rosalbito's terminal output for any code change is a pull request on a feature branch (my global git rules already mandate this). I approve by merging. Rosalbito never deploys, never pushes to main, never touches production state.
- **Risk and human dependency are separate axes.** Engineering risk decides how much machinery and verification deploy; human decision dependency decides whether I get woken. High-risk work is autonomous by default — more risk buys more reviewers, not more interruptions.

## 2. Use the model budget

We have substantial model capacity. Do not optimize for minimum tokens. Spend model calls freely where they buy *independent evidence*: fresh-context reviews, adversarial testing, debugging in a clean context, repository exploration in subagents.

The optimization target is **maximum verified engineering output per unit of model usage**. Waste is repeating the same failed reasoning, not running a second reviewer.

## 3. Inventory before building (verify, don't assume)

Before designing anything, check what is actually installed in this environment and record it in a file. Known candidates to verify:

- `/code-review` (including `ultra` multi-agent adversarial review)
- the `security-review` skill
- the `ralph-loop` plugin
- `/loop` (self-paced recurring execution)
- the Workflow tool (deterministic multi-agent fan-out)
- the Agent tool (fresh-context subagents, including Explore and Plan)
- hooks and permission settings (for hard gates)
- `enor-plan` / `enor-log` (heavy planning + decision logging)
- `skill-creator` and the Anthropic skills conventions

**The rule: Rosalbito may use any of these internally, but I only ever type `/rosalbito`.** Never require me to know or remember an internal tool. If an installed capability covers a subsystem, wrap it; if it disappears later, degrade gracefully (check availability at run time, don't hard-code).

Study the Anthropic skills repo (https://github.com/anthropics/skills) for packaging conventions: `SKILL.md`, metadata, progressive disclosure, keeping the main instruction surface small. Timebox all external research to ~30 minutes total; skip any reference you cannot quickly resolve.

## 4. Reuse vs build

Produce the analysis per subsystem (SUBSYSTEM / EXISTING / REUSE / CANNOT REUSE / WILL BUILD / WHY), but start from these presumptive defaults and overturn one only with a concrete recorded reason:

**Will NOT build:** a code reviewer, a security scanner, a loop runner, an orchestration framework, a metrics platform, a context-management framework, any database or custom runtime.

**WILL build (this is the actual project):**

1. The `/rosalbito` entrypoint skill with its router
2. The persistent state schema and resume protocol
3. Task classification with path-based risk overrides
4. The acceptance-contract format (every criterion names its verification method)
5. Evidence recording (small scripts that run checks and append results)
6. Hard-gate configuration (hooks + permissions)
7. Report and blocked-report templates

Prefer Claude Code primitives, shell scripts, Markdown, YAML, JSONL, and Git for everything.

## 5. Routing: two independent axes

Classify every task on two axes, then route:

> **Engineering risk decides how much machinery and verification Rosalbito deploys.
> Human decision dependency decides whether it wakes me.**

These are independent. A HIGH-risk task with clear requirements runs fully autonomously. A LOW-risk task with an ambiguous product question wakes me. Never use risk tier as a proxy for "ask Pedro."

### Axis 1 — Engineering risk (machinery)

How dangerous it is to get wrong. Determines verification depth and review count:

```yaml
TRIVIAL:   # typo, comment, config tweak
  do: implement directly
  verify: run the relevant checks (test/lint/build)
  state: none
  report: one paragraph

LOW:
  do: implement
  verify: full deterministic verification, evidence recorded
  deliver: PR
  report: short

MEDIUM:
  adds: state file, acceptance contract, one fresh-context review

HIGH:
  adds: understanding pass (subagent), security review, architecture review

CRITICAL:
  adds: independent correctness review, full engineering report,
        decision records mandatory for every non-obvious choice
```

Note what is absent: **no tier automatically wakes me.** HIGH and CRITICAL risk follow the normal autonomous path — understand → plan → implement → verify → independent review → PR.

**Path-based overrides (hard rules):** any diff touching authentication, authorization, payments, migrations, secrets handling, CI config, or infrastructure is HIGH minimum — regardless of the model's own judgment. The classifier may *raise* a tier above a path rule, never lower it below one. The classifier is the same model that wants to proceed, so its incentive is to under-classify; the path rules exist to make that impossible where it matters. Keep the rules in an editable YAML file.

Classification criteria: scope, uncertainty, security/data-integrity/production/financial relevance, reversibility, concurrency and database implications. Money is just one example of risk, not the point.

### Axis 2 — Human decision dependency (interruption)

How much the task requires my product, architecture, or judgment calls. Every run carries an explicit routing field, re-evaluated as evidence comes in:

```yaml
human:
  required: true|false
  level: none | visibility | decision | hard_gate
  reason: []        # mandatory whenever level is decision or hard_gate
```

- **none** — nothing worth my attention (TRIVIAL only).
- **visibility** — the default for everything else, *including HIGH/CRITICAL risk*: I see the finished PR, the report, and the decision records. I approve by merging. No interruption.
- **decision** — a genuine unresolved decision blocks progress; wake me, but only after investigating (below).
- **hard_gate** — operations that always require explicit approval **regardless of model confidence or investigation quality**: production credentials or secrets, destructive or irreversible operations, real financial transactions, production data changes, anything a merge cannot undo. Hard gates are *operation-triggered*, never tier-triggered, and are backed by the mechanisms in §10 — a Markdown rule is not a gate.

**A decision requires me only when it cannot be safely inferred from:** the task statement, repository evidence, the acceptance contract, established invariants, or my prior decisions in `.agent/decisions/`. If it can be inferred, proceed — and record the decision with its rationale in a decision record so I can audit it in the PR. The decision triggers in §10 are what legitimately set `level: decision`.

**Investigate first.** Before waking me, do the work: explore the code, test the hypotheses, price each option. A wake-up must contain the actual decision I need to make, the evidence gathered, the plausible options with their tradeoffs, and a recommendation when you have one. "I need clarification" without investigation is a failed run, not a question.

**Gate position:** when a decision gate fires about product behavior, architecture, or acceptance criteria, stop **before implementation** — the cheapest intervention is early. Don't build the wrong thing correctly and ask afterwards.

## 6. Understanding pass (runs as a subagent, read-only)

For HIGH/CRITICAL tasks (or on demand), a subagent builds enough repository understanding that an engineer could safely modify it: what the system does, entry points, components, data flow, persistence, external dependencies, auth/security boundaries, testing, CI, invariants, unknowns.

Every important claim is labeled:

```text
KNOWN | INFERRED | UNKNOWN
```

Never promote a guess to a fact. A guess made in hour 1 must not become a "fact" by hour 4.

Generate Mermaid diagrams (as editable `.mmd` files) only when they genuinely compress understanding — architecture, data flow, trust boundaries. Never for decoration. Understanding artifacts are **run artifacts** (dated, tied to a run), not living documentation — do not pretend they will be maintained.

## 7. Acceptance contracts

Acceptance is multidimensional (functional, security, architecture, testing, operational — only the dimensions the task needs). The non-negotiable rule:

> **Every criterion names its verification method.** Unverifiable criteria are not allowed.

```yaml
acceptance:
  - criterion: webhook signatures verified before processing
    verify: { command: "cargo test webhook_signature" }
  - criterion: no business logic in HTTP handlers
    verify: { reviewer: architecture }
  - criterion: refund flow matches product intent
    verify: { human: true }
```

A `human`-verified criterion is normally checked by me at PR review via the report (`visibility` level, §5); it blocks implementation only when it is itself an unresolved decision.

Repo-level security and architectural invariants (e.g. "external events must be authenticated", "payment state changes only through PaymentService") live in a persistent per-repo file, derived from the actual repository, and are handed to reviewers. They are examples to derive from, not universal rules to copy.

## 8. Deterministic verification (Phase 1, day one)

The backbone of the whole system, present from the very first version:

- Verification = commands with exit codes: tests, lint, type check, build, and whatever the repo's CI runs.
- Every run appends to `.agent/evidence/` as JSONL: timestamp, command, exit code, output tail.
- "Done" claims cite evidence entries. No evidence, not done.
- The implementation agent does not get to declare itself done; gates do.

If tests fail: investigate → hypothesis → fix → verify. That loop is the normal case, not an exception.

## 9. Reviews (fresh contexts, re-derived evidence)

For MEDIUM and above, reviews run in **fresh contexts** — the implementer's assumptions must not contaminate the reviewer.

Reviewers are adversarial. Never "does this look good?" — always "**try to prove this implementation is wrong**." Correctness reviewers construct counterexamples: malformed input, duplicates, retries, concurrency, partial failures, timeouts, stale state, boundary values.

**For HIGH/CRITICAL, reviewers re-derive the evidence themselves**: they run the tests, read the surrounding code fresh — they do not merely audit the diff and the implementer's evidence bundle, because that bundle was authored by the party under review.

Use installed review capabilities (`/code-review`, `security-review`) inside reviewer subagents where available instead of writing new reviewer prompts from scratch. Security review distinguishes *scanner finding* from *actually exploitable finding*.

Review rejection → understand why → replan → implement → review again. This loop continues autonomously.

## 10. Gates: hard mechanisms + decision triggers

**Hard gates (mechanisms, built in Phase 3 — these fire on the *operation*, never on risk tier, and no amount of model confidence bypasses them):**

- All code changes land as PRs on feature branches; merging is my approval. This is already enforced by my global git rules — lean on it.
- PreToolUse hooks that deny destructive or production-shaped commands (force-push, prod credentials, data deletion, `--prod` deploys).
- No production credentials available to the agent, ever.
- Irreversible external operations (real transactions, production data changes, anything a merge cannot undo) stop and wait for explicit approval, always.

**Decision triggers (these set `human.level: decision` per §5 — instructions, not mechanisms):**

- requirements materially ambiguous after investigation; evidence contradicts itself
- two materially different valid architectures with no inferable winner; unclear security boundary
- missing credentials or access the agent cannot obtain
- tests contradict the stated expected behavior
- the agent cannot determine what "correct" means

A trigger fires only after the inference sources in §5 (task, repo evidence, acceptance contract, invariants, prior decisions) have been exhausted. The correct response to genuine uncertainty is never a silent guess:

```text
I don't know.
Here is what I investigated.
Here are the plausible interpretations.
Here is why I cannot safely choose.
Here is the decision I need from you.
```

And the inverse holds too: a decision that *can* be safely inferred is made autonomously and written to `.agent/decisions/` — waking me to rubber-stamp an inferable choice is also a failure.

## 11. The loop, and what actually drives it

```text
CLASSIFY (risk + human dependency) → (UNDERSTAND) → ACCEPTANCE
→ (DECISION GATE only if human.required) → PLAN
→ IMPLEMENT → VERIFY → REVIEW → FIX → VERIFY → DOCUMENT → PR → DONE
```

"Runs overnight" is a mechanism decision, not an aspiration. In Phase 1, pick ONE concrete driver — the `ralph-loop` plugin, `/loop`, or a small driver script — document the choice, and test it. Sessions end, contexts compact; something must re-enter the loop.

**Resume protocol (designed, not aspired to):** `.agent/state/current.md` is the single re-entry point. The first action of any fresh or resumed agent is to read it. It must always contain: the task, risk tier, status, pointer to the acceptance contract, what is verified, what failed, the next action, and open decisions. **Test it in Phase 1: kill a session mid-run, start a fresh one, confirm it continues correctly.** If that test fails, nothing else matters.

## 12. Loop detection AND hard caps

Pattern detection: the same failure 3 times, oscillating implementations, repeatedly rewriting the same files → escalate to a fresh-context debugger subagent → if still stuck, write a blocked report for me.

Plus dumb global caps, because detection misses things:

```yaml
caps:
  max_iterations_per_run: 25     # tune from real runs
  max_wall_clock_hours: 8
```

Hitting a cap → stop, write the blocked report with full state. Never continue indefinitely.

## 13. Persistent state

```text
.agent/
  state/current.md      # resume entry point (see §11)
  acceptance/           # contracts
  evidence/             # JSONL verification results
  decisions/            # decision records: context, options, choice, why
  reports/              # final reports
  understanding/        # dated run artifacts from §6
```

Markdown, YAML, JSONL, Git. Must survive compaction and session death. A brand-new agent reading `.agent/` must understand: what the task is, what happened, what remains, what is verified, what failed, what was decided — without the previous conversation.

## 14. Metrics (only what the agent can actually observe)

Track per run, as one JSONL line derived from the state files: iterations, same-failure count, review findings and rejections, gates passed, human interventions, tests added, outcome.

Do NOT attempt to self-count tool calls or tokens — the model cannot observe those reliably. Do not build a metrics platform.

*Amendment (2026-10-07):* tokens, cost and spawned agents **are** measured, but by a script, after the fact, from Claude Code's own transcripts (`usage.sh`), never by the model. A cross-repo index (`collect.sh`) and a static local page (`dashboard.sh`) make the per-repo `.agent/runs/` data visible in one place. Still no server, database or exporter.

## 15. Reports and final output

Reports separate **what I need to understand** (product semantics, invariants, boundaries, tradeoffs, irreversible decisions — e.g. "payment verification is the trust boundary") from **what the agent discovered** (file locations, call graphs, implementation detail — e.g. "`verify_signature()` is in `src/payments/signature.rs:42`"). Optimize my reading time, not completeness.

On completion:

```text
ROSALBITO RUN COMPLETE
Task / Risk / Status
Changed: ...
Verification: ✓ tests ✓ lint ✓ build ✓ reviews (each citing evidence)
Important discoveries / Tradeoffs / Remaining risks
PR: #N
```

When blocked on a decision (this is the wake-up — it must be worth waking up for):

```text
ROSALBITO RUN BLOCKED — DECISION NEEDED
The decision: the specific question, not "I need clarification"
What I investigated: code read, hypotheses tested, evidence gathered
Options: A / B (each with concrete tradeoffs)
Why I cannot safely infer this: which inference sources I exhausted
My recommendation: (when I have one, with reasoning)
Everything else: state of the run, what continues after the decision
```

Substantial runs (HIGH+) additionally produce an engineering write-up in `.agent/reports/` (Problem, Investigation, Options, Decision, Implementation, Security, Testing, Tradeoffs, Lessons). TRIVIAL/LOW runs produce a paragraph. Never return the transcript.

## 16. Phases

**Phase 1 — the MVP (everything here ships before anything else):**
- `/rosalbito` entrypoint + two-axis router: risk tier AND `human:` routing field (§5)
- persistent state + resume protocol, **tested by killing a session** (§11, §13)
- deterministic verification + evidence recording (§8)
- PR delivery
- hard caps (§12)
- the loop driver, chosen and documented (§11)

**→ FIRST REAL EXPERIMENT.** A real task from my actual backlog — representative, not a toy. Run it, let it work, then inspect exactly where the workflow failed, and fix those failures. This happens immediately after Phase 1, not after Phase 4.

**Phase 2:** acceptance contracts, fresh-context review wiring (reusing installed review skills).
**Phase 3:** hard gates as hooks + permissions, path-override config, security/architecture reviewer prompts.
**Phase 4:** engineering reports, decision records, metrics, Mermaid artifacts.

**Every Phase 2–4 component must justify itself against a failure observed in a real run.** If no real run has demonstrated the need, it waits.

## 17. Prime directive

Build the smallest system that can actually run real engineering work overnight and ship correct code as a reviewable PR. Let real work teach us what it needs.

If it produces impressive Markdown but does not reliably ship correct code, it has failed.
If it makes small tasks slow, it has failed.

Now begin:

1. Inventory the environment (§3) — verify, record.
2. Reuse-vs-build analysis (§4) from the presumptive defaults.
3. Implement Phase 1.
4. Run the first real experiment.
5. Iterate on what actually broke.

Do not wait for me between these steps except at the explicit human gates in §10.

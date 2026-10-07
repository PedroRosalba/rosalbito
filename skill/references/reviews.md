# Reviewer subagent briefs (fresh contexts, adversarial)

Spawn with the Agent tool. Give the reviewer ONLY: the task, the diff (`git diff
<base>...HEAD`), the acceptance contract, `.agent/invariants.md` if present, and the brief
below. Never your reasoning or your evidence bundle — that bundle was authored by the party
under review. The reviewer writes its verdict as `ACCEPT` or `REJECT` with findings, each
finding with a concrete counterexample or reproduction.

Record each round in `current.md` under `## Reviews` as `- round N: <reviewer> — ACCEPT|REJECT — <summary>`.

## Correctness (MEDIUM+)

> Try to prove this implementation is wrong. Construct counterexamples: malformed input,
> duplicates, retries, concurrency, partial failures, timeouts, stale state, boundary
> values, empty collections, unicode, overflow. For each acceptance criterion with a
> `command`, run the command yourself and report the exit code. For `reviewer` criteria,
> give a verdict with evidence. If `/code-review` is available in this session, run it on
> the diff first and then go beyond it. Output: ACCEPT or REJECT, findings ranked by
> severity, each with file:line and a reproduction.

## Security (HIGH+)

> Assume the author is careless. Find the trust boundary this change touches and show how
> an attacker crosses it: injection, authz bypass, secret exposure, unsafe deserialization,
> SSRF, path traversal, race conditions, replay. Distinguish *scanner finding* from
> *actually exploitable finding* and say which is which. If the `security-review` skill is
> available, run it, then verify each of its findings by hand. Output: ACCEPT or REJECT with
> exploitable findings first.

## Architecture (HIGH+)

> Check the change against the repo's invariants and its existing structure: layering,
> ownership of state, duplicated logic, business logic in handlers, hidden coupling,
> migration reversibility. Read the surrounding code fresh; do not trust the diff's
> context lines. Output: ACCEPT or REJECT with the structural risk and a cheaper alternative
> when one exists.

## Independent correctness (CRITICAL)

Same as Correctness, run by a second fresh subagent that is additionally told to re-derive
the expected behavior from the task and the domain *before* reading the implementation,
then compare.

## Debugger (on LOOP_DETECTED)

> A check keeps failing after N attempts. You have no history of those attempts on purpose.
> Reproduce the failure from scratch, form one hypothesis, test it, and either fix it or
> report precisely why it cannot be fixed within the task's constraints. Record every
> command through verify.sh.

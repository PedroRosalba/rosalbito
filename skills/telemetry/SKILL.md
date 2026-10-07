---
name: telemetry
description: Telemetry engineering for any repo. Use whenever a task adds, changes, reviews or verifies a signal somebody will later query — observability, instrumentation, tracing, spans, metrics, counters, histograms, structured logging, events, OpenTelemetry, OTel, OTLP, exporters, collectors, SLOs, SLIs, error budgets, dashboards, alerts, "add tracing", "instrument this", "add a metric for", "log when", "we can't see what happens in prod", "where does the time go", "propagate trace context", "correlate across services / queues / NATS / jobs / agents". Reads and maintains the target repo's durable telemetry context in .agent/context/telemetry/. Model-invoked: Rosalbito's implementer subagent reaches for it on any telemetry-shaped task.
---

# telemetry — instrument so a question can be answered, then prove it

One generic capability. Per-repo knowledge is **context** (`.agent/context/telemetry/`),
never procedure. You read that context, you decide with the rules below, you verify with
commands that exit non-zero on failure, and you write back what you learned.

`SKILL_DIR` = `${CLAUDE_SKILL_DIR}` — the directory containing this file. Rosalbito's scripts
are at `SKILL_DIR/../rosalbito/scripts/` (the sibling skill, installed with this one by the
plugin or by `install.sh`).

## When to use / when not

Use when the task touches any signal a human or alert will query: spans, metrics, logs,
events, exporters, collectors, SLOs, dashboards, alerts, or "we need visibility into X".

Do **not** instrument what you cannot name a question for. Before adding any signal, write
the question it answers, in one line: *"What will someone ask of this data?"* Examples:
"p95 latency of order checkout per route, over the last hour" (metric); "why was request
X slow, which downstream stalled" (trace); "what exactly happened to job 123 and in what
order" (events). No question → no signal. Remove dead signals you find the same way.

Not for: product analytics pipelines, billing meters, audit logs with legal retention.
Those share plumbing but have different owners and rules; say so and stop.

## Workflow

### 1. Read context first

```bash
ls .agent/context/telemetry/ .agent/context/understanding/ 2>/dev/null
cat .agent/context/telemetry/conventions.md .agent/context/telemetry/instrumentation-map.md 2>/dev/null
```

Present → treat `conventions.md` as law (prefixes, resource attributes, exporter,
sampling, PII policy) and `instrumentation-map.md` as the inventory of flows already
instrumented. Absent → proceed with the defaults in `references/`, and create both files
lazily at step 9 from `templates/`, filling only what you actually learned, marking the
rest `TBD`. Also read `.agent/context/understanding/` if present for flow boundaries.
Then find the existing telemetry entry point: grep for `@opentelemetry`, `opentelemetry`,
`tracing_subscriber`, `prom-client`, `pino`/`winston`, `OTEL_`, `traceparent`.

### 2. Identify flows and questions

List the flows the task touches (request → handler → db/queue/external → response; job
enqueue → consume; cron tick; agent → tool → agent). For each flow write the questions,
then map each question to exactly one primary signal with the rules in step 3. A flow
with no question is not instrumented.

### 3. Design signals — decision rules

| The question is about | Signal | Why |
|---|---|---|
| rate, error ratio, duration distribution, saturation, over time, per bounded dimension | **metric** (counter / histogram / up-down counter / gauge) | cheap, aggregable, alertable |
| *this* request/job: where time went, which dependency failed, causal order | **trace / spans** | per-instance causality |
| a discrete fact with high-cardinality payload (ids, reasons), needed for forensics | **structured event / log**, carrying `trace_id` | searchable, not aggregated |
| a point-in-time fact inside one operation ("cache miss", "retry 2/3") | **span event** (`span.addEvent`) | stays attached to the span |
| failure | span status `ERROR` + recorded exception **and** a counter with bounded `error.type` | traces explain, metrics alert |

Rules: anything alertable must be a metric. Never derive a metric from grepping logs.
One signal per question; add a second only when it answers a different question.
Instrument boundaries (ingress, egress, queue, storage, external API), not every
function. Budget: ≤ ~50 spans per request, ≤ ~1000 series per metric per instance.
Read `references/signals-and-naming.md` for instrument choice, RED/USE, SLO metrics.

### 4. Naming, attributes, cardinality

- Span names are low-cardinality operation names: `POST /orders/{id}`, `db.query orders`,
  `nats.publish orders.created`, `job.process send-invoice`. Never raw paths, ids, SQL.
- Metric names: `<namespace>.<thing>.<unit-ish>`, dots, lowercase, singular nouns; units
  via the instrument's `unit` field (`s`, `ms`, `By`, `{request}`), not in the name.
- Attributes: `namespace.key`, OTel semantic conventions first (`http.request.method`,
  `http.route`, `http.response.status_code`, `db.system`, `messaging.system`,
  `error.type`), repo prefix for domain keys (`conventions.md` → `attribute_prefix`).
- Every attribute on a metric needs a bounded value set you can enumerate in the test
  (step 8). Unbounded → not a metric attribute; it goes on a span or an event.
- Same name ⇒ same meaning everywhere. Check `instrumentation-map.md` before inventing.

### 5. Correlation — trace context propagation

Use W3C `traceparent`/`tracestate`, injected and extracted via the OTel propagation API,
never hand-built. Per boundary:

- **HTTP**: inject on outgoing requests (CLIENT span), extract on inbound (SERVER span).
- **Queues / NATS / Kafka / SQS**: inject into message *headers* (NATS `headers`, Kafka
  headers, SQS message attributes), never the body. Producer: `PRODUCER` span. Consumer:
  `CONSUMER` span; parent = producer context when processing is near-synchronous, a
  **span link** when it is batched or delayed so traces stay readable.
- **Background jobs**: capture `traceparent` at enqueue into the job payload metadata;
  restore it in the worker before starting the job span. Add `job.name`, `job.attempt`.
- **Cron**: each tick is a new root span (`cron.tick <job>`), attribute `cron.schedule`.
- **Agent-to-agent / tool calls**: treat as RPC. CLIENT span on the caller, SERVER on the
  callee, propagate in the request metadata; attributes `agent.name`, `tool.name`
  (bounded), never the prompt or the result.
- Async context: use the SDK's context manager (AsyncLocalStorage in Node). Verify the
  parent-child relation in a test; "I think it propagates" is not evidence.
- Logs: put `trace_id`/`span_id` on every log record emitted inside a span (log bridge or
  logger mixin) so the three signals join.

### 6. PII and secrets

Never in any attribute, span name, event, metric label or log field: message bodies,
prompts/completions, request/response bodies, tokens, API keys, auth headers, cookies,
passwords, phone numbers, emails, personal names, addresses, card/bank numbers, raw SQL
with values, full URLs with query strings, IPs when policy says so.
Mechanisms, not promises: **allow-list** attribute keys per signal in `conventions.md`;
one `redact()` function at the attribute boundary with its own tests; opaque ids only
(`order.id` fine; `user.email` never). Hashing an email is still identifying: treat as
PII. Review auto-instrumentation defaults (`db.statement`, `http.url`, headers capture)
and disable or redact them explicitly.

### 7. Sampling and cost

Default: `ParentBased(TraceIdRatio(r))` head sampling, `r` from `conventions.md`
(`1.0` in dev/test, lower in prod). Errors should survive sampling: keep tail sampling
in the collector if there is one; otherwise document the gap. Never sample metrics.
Cost drivers: attribute cardinality × metric count × histogram buckets; span volume ×
attribute bytes; log volume. State the expected series count for every new metric.
Test and dev configuration: `AlwaysOn` + in-memory (tests) or console/OTLP (dev).

### 8. Verification — mandatory, deterministic

Nothing is "instrumented" until a command proves it. Minimum per task:

1. **Unit, in-process exporters** (`InMemorySpanExporter`, in-memory metric reader/
   exporter, in-memory log exporter): assert span exists by name; parent-child via
   `spanId`/parent span id; `kind`; attributes (exact key set and values); status code;
   recorded exception. Metrics: instrument name, unit, type, data point value or delta,
   exact attribute set. Events/logs: name, attributes, `trace_id` present and equal to
   the span's.
2. **Cardinality check**: for every metric attribute, a test that drives the hot path
   with varied inputs and asserts the observed value set ⊆ the enumerated allowed set.
3. **PII check**: the redaction test plus an assertion that no attribute key outside the
   allow-list appears on the signals of the flow.
4. **Pipeline smoke**: start the app with the real exporter wired (console or OTLP to a
   local collector), hit the flow once, assert the span/metric name appears in the
   exporter output or collector endpoint. This catches "SDK not started", "exporter not
   registered", "sampler drops everything" — the failures unit tests cannot see.
5. Flush/shutdown the providers in tests; otherwise exports race and tests flake.

Run every check through Rosalbito's `verify.sh` (below). Read `references/verification.md`
for the assertion catalogue, snippets, and false positives; the language file for setup.

### 9. Write back durable context

Update `.agent/context/telemetry/instrumentation-map.md` (one row per flow: spans,
metrics, events, owner, verified-by command) and `conventions.md` (any naming, exporter,
sampling or PII decision you made). Create from `templates/` when absent. Keep rows
truthful: `verified-by` names a command that exists. `.agent/` is local and uncommitted
unless the repo opts in (`ROSALBITO_COMMIT_AGENT_DIR=1`); say in the report which rows
you added. A decision with alternatives also gets an ADR in `.agent/context/adr/`
(Rosalbito `templates/decision.md`).

## Rosalbito integration

Inside a Rosalbito run (`.agent/runs/current/state.md` exists) — and whenever the
Rosalbito skill is installed — every check runs as

```bash
bash "SKILL_DIR/../rosalbito/scripts/verify.sh" <label> <command...>
# e.g. bash "SKILL_DIR/../rosalbito/scripts/verify.sh" telemetry-unit bun test test/telemetry
```

so the result becomes an evidence line in `.agent/runs/<run_id>/evidence.jsonl`
(`runs/adhoc.jsonl` outside a run). Labels: `telemetry-unit`, `telemetry-cardinality`,
`telemetry-pii`, `telemetry-smoke`. Acceptance contract (`.agent/runs/<run_id>/acceptance.yaml`):
each telemetry criterion names a command, in the Rosalbito shape:

```yaml
- criterion: "POST /orders emits SERVER span 'POST /orders' with http.route, order.status; child span 'db.query orders'"
  dimension: operational
  verify: { command: "bun test test/telemetry/orders.trace.test.ts" }
- criterion: "orders.checkout.duration histogram attributes ⊆ {http.route, http.response.status_code, order.status}"
  dimension: operational
  verify: { command: "bun test test/telemetry/cardinality.test.ts" }
```

Do not declare done; report what you instrumented, which questions each signal answers,
the evidence lines, and what you could not verify. Rosalbito's reviewers re-derive it.

## References — read X when Y

- `references/signals-and-naming.md` — when choosing instruments, naming anything,
  judging an attribute's cardinality, designing SLO metrics, deciding event vs log.
- `references/otel-typescript.md` — when the repo is TypeScript/Node/Bun: SDK setup,
  propagation across HTTP and NATS, in-memory test patterns, Bun caveats, pitfalls.
- `references/otel-rust-python.md` — when the repo is Rust (`tracing` +
  `tracing-opentelemetry`) or Python (`opentelemetry-sdk`).
- `references/verification.md` — always, before writing the tests and the acceptance
  criteria: layering, assertion catalogue, cardinality test, false positives.
- `templates/instrumentation-map.md`, `templates/conventions.md` — when
  `.agent/context/telemetry/` is missing or a file needs a new section.

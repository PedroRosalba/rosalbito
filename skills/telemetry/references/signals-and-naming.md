# Signals and naming

Read when choosing an instrument, naming anything, judging an attribute's cardinality,
designing SLO metrics, or deciding event vs log. OpenTelemetry semantic conventions are the
default vocabulary; the repo's `conventions.md` overrides only where it says so.

## Three signals, one question each

| Signal | Answers | Shape | Cost model |
|---|---|---|---|
| Metric | "how many / how long / what fraction, over time, per bounded dimension" | time series: name + attribute set → value | series count = product of attribute value-set sizes |
| Trace | "what happened to *this* operation, where did time go, what called what" | tree of spans sharing a `trace_id` | span count × attribute bytes × sampling rate |
| Log / event | "what exactly happened, with which (possibly high-cardinality) facts" | timestamped record with structured fields | volume × field bytes |

Metrics aggregate and alert. Traces explain one instance. Logs/events keep the facts that
would blow up a metric's cardinality. Join them with `trace_id` on logs and **exemplars**
on histograms (a data point that carries a sample `trace_id`); enable exemplars when the
backend supports them (Prometheus/OTLP do), it turns "p99 is bad" into "here is a slow
trace".

## Spans

**Name** = the operation, low cardinality, stable across instances of the same operation.

| Good | Bad | Why |
|---|---|---|
| `GET /users/{id}` (route template) | `GET /users/42` | raw path → one name per user |
| `db.query users` / `SELECT users` | `SELECT * FROM users WHERE id=42` | statement with values |
| `nats.publish orders.created` | `publish 7f3a…` | message id |
| `job.process send-invoice` | `send-invoice #8812` | job id |
| `agent.call summarizer` | `agent.call "Summarize this…"` | prompt text |

**Kind** carries the topology: `SERVER` (inbound request), `CLIENT` (outbound call),
`PRODUCER` (enqueue/publish), `CONSUMER` (dequeue/subscribe), `INTERNAL` (everything
else). Backends compute service maps and RED-from-traces from kinds; get them right.

**Status**: `UNSET` by default, `ERROR` with a message on failure, `OK` only when you
explicitly know it succeeded (SERVER spans with 5xx → ERROR; 4xx → UNSET, the client
erred). Record the exception (`recordException` / equivalent) *and* set status; one
without the other loses either the stack or the alert.

**Attributes** (semantic conventions, stable names at time of writing — check the installed
`semantic-conventions` package):
`http.request.method`, `http.route`, `http.response.status_code`, `url.path` (no query),
`server.address`, `db.system`, `db.namespace`, `db.operation.name`,
`messaging.system`, `messaging.destination.name`, `messaging.operation.type`,
`rpc.system`, `rpc.service`, `rpc.method`, `error.type`, `exception.type`,
`exception.message`, `exception.stacktrace`.
Domain attributes under the repo prefix: `orders.status`, `orders.payment_method`.

**Span events** are timestamped facts inside a span: `retry` with `retry.attempt`,
`cache.lookup` with `cache.hit`, state transitions. Use them instead of log lines when
the fact only matters together with the span. Span **links** connect causally related
spans that are not parent-child (batch consumer → each producer span, fan-in).

Spans are for boundaries: ingress, egress, storage, queue, external API, expensive
compute. Wrapping every function produces unreadable traces and doubles cost.

## Metrics

### Instrument types

| Instrument | Semantics | Use for | Not for |
|---|---|---|---|
| Counter | monotonic sum; you add ≥ 0 | requests, errors, bytes, items processed | anything that goes down |
| UpDownCounter | sum that can decrease | in-flight requests, queue depth you add/remove from, open connections | rates (derive from counter) |
| Histogram | distribution of recorded values | durations, sizes, batch lengths; anything needing p50/p95/p99 | monotonically increasing totals |
| Gauge (observable or sync) | last-sampled value, not summed | memory, temperature, config value, queue depth read from the broker | things you could count |

Rule of thumb: if you can say "+1", counter; if "+n/-n", up-down counter; if "took X",
histogram; if "currently is X" and you *read* it rather than track it, gauge.

### Naming and units

- Name: `<namespace>.<object>.<property>`; lowercase, dots, singular noun, no unit suffix,
  no `total`/`count` suffix (backends add `_total` themselves for Prometheus).
  `http.server.request.duration`, `orders.checkout.duration`, `queue.job.attempts`.
- Unit in the instrument's `unit` field using UCUM: `s` (preferred for durations),
  `ms`, `By`, `1`, or annotations like `{request}`, `{job}`, `{error}`.
- Description in the instrument's `description`. Both show up in the backend.
- Histogram buckets: set explicit bucket boundaries for durations if the default
  (0,5,10,25,…,10000 ms-ish) does not match the unit you record. Recording seconds into
  millisecond-shaped buckets puts everything in the first bucket.
- Match the OTel semconv metric when one exists (`http.server.request.duration`,
  `http.client.request.duration`, `db.client.operation.duration`,
  `messaging.client.operation.duration`) so dashboards port.

### Cardinality budget

Series per metric = ∏ (distinct values of each attribute). Budget ≤ ~1000 per instance
per metric unless `conventions.md` says otherwise; keep hot metrics ≤ 100. Every
attribute must have a value set you can **enumerate in a test**.

| Attribute | Verdict | Reason |
|---|---|---|
| `http.route` = `/orders/{id}` | good | bounded by the router table |
| `http.response.status_code` | good | ≤ ~60 values; or bucket to `2xx/4xx/5xx` |
| `orders.status` ∈ {pending, paid, failed, refunded} | good | enum |
| `error.type` = exception class name | good if bounded | map unknowns to `other` |
| `user.id`, `session.id`, `order.id`, `message.id` | **bad** | unbounded → one series per entity |
| `url.full`, raw path `/orders/4711` | **bad** | unbounded; use the route template |
| timestamps, durations as attributes | **bad** | continuous; that is the *value* of a histogram |
| `agent.prompt`, `message.body` | **bad** and PII | content, unbounded |
| `host.name` on a per-request metric | caution | fine at resource level; on the metric it multiplies by fleet size |

Unbounded facts go on spans (attributes) or events, never on metrics.

### RED, USE, SLO

- **RED** for every request-driven service/flow: Rate (`counter` of requests), Errors
  (same counter with `error.type`/status attribute, or a separate counter), Duration
  (`histogram`). Three instruments per flow is the baseline.
- **USE** for every resource (pool, queue, worker, cache): Utilization (gauge or
  up-down counter: in-use/limit), Saturation (queue depth, waiting), Errors.
- **SLO-oriented**: an SLI is a ratio of good events / valid events. Emit the data so the
  ratio is computable in the backend: a counter for valid events with an attribute that
  classifies good vs bad (or a histogram with the threshold inside its bucket bounds, so
  "fraction under 300 ms" is a bucket read). Burn-rate alerts need the ratio over several
  windows; make sure one query expresses it. Write the SLI formula next to the metric in
  `instrumentation-map.md`.

## Structured events vs logs

- **Log**: a record from a code location, severity, message template, structured
  fields, `trace_id`/`span_id` when inside a span. Use for forensics and for facts that
  are not tied to one span's lifetime. Structured means fields, not interpolated strings:
  `logger.info({ order_id, attempt }, "retrying payment")`, never
  `"retrying payment for order 4711 attempt 2"`.
- **Event** (OTel event = log record with `event.name`, or a span event): a named
  domain fact with a defined schema (`orders.paid`, `job.failed`). Prefer an event over a
  freeform log when the fact will be queried by name.
- Severity: `ERROR` only for actionable failures; `WARN` for degraded-but-handled;
  `INFO` for state changes someone queries; `DEBUG` off in prod.
- Logs never carry: bodies, secrets, PII (see SKILL.md §6). Keys use the same
  `namespace.key` scheme as attributes so a search works across signals.

## Resource attributes

Set once on the SDK resource, not per signal: `service.name` (mandatory),
`service.version`, `service.namespace`, `deployment.environment.name` (check the
installed semconv package for the exact constant; older versions use
`deployment.environment`), `service.instance.id`. Everything per-signal inherits them.

## Naming checklist (apply before writing code)

1. Is the span name a route/operation template, not an instance?
2. Does every metric have a unit and a description? Is the unit `s` for durations?
3. Can every metric attribute's value set be written down in the test?
4. Is every key `namespace.key` and does the same key mean the same thing everywhere?
5. Does an OTel semconv name already exist for this? Use it.
6. Does `instrumentation-map.md` already name this flow? Extend, do not duplicate.

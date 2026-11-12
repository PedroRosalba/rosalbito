# Verification playbook — prove the instrumentation works

Read before writing telemetry tests and acceptance criteria. Rule: no telemetry claim
without a command that exits non-zero when the claim is false. TypeScript snippets are
primary; the Rust/Python file has the equivalents. API names here match the OTel JS SDK at
time of writing; where a constructor shape changed between major versions it is noted —
check the installed version's docs when in doubt.

## Layering

| Layer | Proves | Harness | Runs in |
|---|---|---|---|
| 1. Unit, in-process | spans/metrics/logs are *produced* with the right names, tree, attributes, status | in-memory exporters/readers wired to a test-only provider | every CI run |
| 2. Cardinality + PII | attribute value sets are bounded; no forbidden keys/values | same harness, driven with varied inputs | every CI run |
| 3. Integration (optional) | the OTLP path works end-to-end | local collector (`otel/opentelemetry-collector` with a `debug`/`file` exporter) or a tiny HTTP server that accepts `/v1/traces` | CI when docker is available; otherwise dev |
| 4. Smoke | the *real* app wiring exports: SDK started before app code, exporter registered, sampler not dropping | run the app with console/OTLP exporter, trigger the flow once, grep | at least once per task, recorded as evidence |

Layer 1+2 are mandatory. Layer 4 is mandatory because layers 1–2 use a test provider and
therefore cannot detect that production bootstrap never registers one.

## Test harness pattern (TS, vitest or `bun test`)

Build the providers yourself in the test; do not rely on the app's global bootstrap.

```ts
import { trace, metrics, context, SpanStatusCode, SpanKind } from "@opentelemetry/api";
import { BasicTracerProvider, SimpleSpanProcessor, InMemorySpanExporter, AlwaysOnSampler } from "@opentelemetry/sdk-trace-base";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { MeterProvider, PeriodicExportingMetricReader, InMemoryMetricExporter, AggregationTemporality } from "@opentelemetry/sdk-metrics";

export function makeTestTelemetry() {
  const spanExporter = new InMemorySpanExporter();
  // sdk-trace-base 2.x: processors go in the constructor. 1.x: provider.addSpanProcessor(...)
  const tracerProvider = new BasicTracerProvider({
    sampler: new AlwaysOnSampler(),
    spanProcessors: [new SimpleSpanProcessor(spanExporter)],
  });
  const metricExporter = new InMemoryMetricExporter(AggregationTemporality.CUMULATIVE);
  const metricReader = new PeriodicExportingMetricReader({ exporter: metricExporter, exportIntervalMillis: 60_000 });
  // sdk-metrics 2.x: readers in the constructor. 1.x: meterProvider.addMetricReader(reader)
  const meterProvider = new MeterProvider({ readers: [metricReader] });

  const cm = new AsyncLocalStorageContextManager().enable();
  context.setGlobalContextManager(cm);
  trace.setGlobalTracerProvider(tracerProvider);
  metrics.setGlobalMeterProvider(meterProvider);

  return {
    spans: () => spanExporter.getFinishedSpans(),
    metrics: async () => { const { resourceMetrics } = await metricReader.collect(); return resourceMetrics.scopeMetrics.flatMap(s => s.metrics); },
    reset: () => { spanExporter.reset(); },
    shutdown: async () => {
      await tracerProvider.shutdown(); await meterProvider.shutdown();
      trace.disable(); metrics.disable(); context.disable();
    },
  };
}
```

If the code under test fetches `trace.getTracer()` at module top level, the test provider
must be registered **before** that module is imported (dynamic `await import()` after
setup, or a setup file). Otherwise the code holds a no-op tracer and every assertion
fails with "span not found" — a real bug in the test, not in the code.

## Assertion catalogue

### Spans

```ts
const spans = t.spans();
const server = spans.find(s => s.name === "POST /orders");
expect(server, "SERVER span missing").toBeDefined();
expect(server!.kind).toBe(SpanKind.SERVER);
expect(server!.attributes["http.route"]).toBe("/orders");
expect(server!.attributes["http.response.status_code"]).toBe(201);
expect(server!.status.code).toBe(SpanStatusCode.UNSET);         // or ERROR on the failure path
expect(Object.keys(server!.attributes).sort()).toEqual(ALLOWED_ORDER_SPAN_KEYS); // exact key set

// parent-child. sdk-trace-base 1.x exposes span.parentSpanId; 2.x exposes span.parentSpanContext?.spanId
const parentIdOf = (s: ReadableSpan) => (s as any).parentSpanContext?.spanId ?? (s as any).parentSpanId;
const db = spans.find(s => s.name === "db.query orders")!;
expect(parentIdOf(db)).toBe(server!.spanContext().spanId);
expect(db.spanContext().traceId).toBe(server!.spanContext().traceId);

// error path
expect(failed.status.code).toBe(SpanStatusCode.ERROR);
expect(failed.events.some(e => e.name === "exception")).toBe(true);
expect(failed.attributes["error.type"]).toBe("PaymentDeclined");

// span event
expect(server!.events.find(e => e.name === "cache.lookup")?.attributes?.["cache.hit"]).toBe(false);

// link (batch consumer → producer)
expect(consumer.links.map(l => l.context.spanId)).toContain(producer.spanContext().spanId);
```

### Propagation across a boundary

Simulate the carrier instead of a network: inject into a headers object, hand it to the
consumer code, assert same `traceId` and parent relation.

```ts
import { propagation, context, trace } from "@opentelemetry/api";
const carrier: Record<string, string> = {};
await tracer.startActiveSpan("nats.publish orders.created", async (span) => {
  propagation.inject(context.active(), carrier); span.end();
});
expect(carrier.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]$/);
await handleMessage({ headers: carrier, data: payload });             // the real consumer entry point
const [pub, con] = ["nats.publish orders.created", "nats.process orders.created"].map(n => t.spans().find(s => s.name === n)!);
expect(con.spanContext().traceId).toBe(pub.spanContext().traceId);
```

A propagator must be registered (`propagation.setGlobalPropagator(new W3CTraceContextPropagator())`
from `@opentelemetry/core`) or `inject` writes nothing and `carrier.traceparent` is
`undefined`; that assertion exists to catch exactly that.

### Metrics

```ts
const all = await t.metrics();
const m = all.find(x => x.descriptor.name === "orders.checkout.duration");
expect(m, "metric missing").toBeDefined();
expect(m!.descriptor.unit).toBe("s");
expect(m!.descriptor.type).toBe("HISTOGRAM");                       // enum from sdk-metrics InstrumentType; compare to the constant in the installed version
const dp = m!.dataPoints.find(d => d.attributes["http.route"] === "/orders");
expect(dp).toBeDefined();
expect((dp!.value as any).count).toBe(1);                           // histogram value: {count,sum,min,max,buckets}
expect(Object.keys(dp!.attributes).sort()).toEqual(["http.response.status_code", "http.route", "orders.status"]);

// counter delta: collect before and after when temporality is CUMULATIVE
const before = valueOf(await t.metrics(), "orders.created", { "orders.status": "paid" }) ?? 0;
await createOrder();
const after = valueOf(await t.metrics(), "orders.created", { "orders.status": "paid" });
expect(after - before).toBe(1);
```

Use `AggregationTemporality.DELTA` on the in-memory exporter if you prefer per-collect
deltas; then reset expectations accordingly. Always `await reader.collect()` *after* the
code path; synchronous instruments record immediately but the reader only materialises on
collect.

### Logs / events

With the OTel logs SDK (`@opentelemetry/sdk-logs`: `LoggerProvider`,
`SimpleLogRecordProcessor`, `InMemoryLogRecordExporter`; `logs.setGlobalLoggerProvider`
from `@opentelemetry/api-logs`):

```ts
const rec = logExporter.getFinishedLogRecords().find(r => r.attributes["event.name"] === "orders.paid");
expect(rec).toBeDefined();
expect(rec!.spanContext?.traceId).toBe(server.spanContext().traceId);
expect(rec!.attributes["orders.id"]).toBe("ord_123");
expect(rec!.attributes).not.toHaveProperty("user.email");
```

With pino/winston instead: capture the stream (pino `destination` to a writable, or a
transport that pushes to an array), parse JSON lines, assert fields and `trace_id`.

### Cardinality test pattern

```ts
const ALLOWED: Record<string, Set<string | number>> = {
  "http.route": new Set(router.routes.map(r => r.path)),          // derive from the source of truth
  "http.response.status_code": new Set([200, 201, 400, 404, 409, 500]),
  "orders.status": new Set(["pending", "paid", "failed", "refunded"]),
};
for (const input of fuzzInputs(200)) await createOrder(input);     // varied ids, users, amounts
const m = (await t.metrics()).find(x => x.descriptor.name === "orders.created")!;
for (const dp of m.dataPoints) {
  for (const [k, v] of Object.entries(dp.attributes)) {
    expect(ALLOWED[k], `unexpected attribute ${k}`).toBeDefined();
    expect(ALLOWED[k].has(v as any), `${k}=${v} outside allowed set`).toBe(true);
  }
}
expect(m.dataPoints.length).toBeLessThanOrEqual(50);               // series budget for this flow
```

Spans get a lighter version: the key set of each span name is fixed, and no attribute
value matches `/^[0-9a-f]{8}-|@|\+?\d{8,}/` (ids, emails, phones) unless the key is on the
id allow-list.

### PII test

```ts
const FORBIDDEN_KEYS = ["user.email", "user.name", "http.request.header.authorization", "db.statement", "message.body", "agent.prompt"];
for (const s of t.spans()) for (const k of FORBIDDEN_KEYS) expect(s.attributes, `${s.name} has ${k}`).not.toHaveProperty(k);
expect(redact({ email: "a@b.c", token: "sk-123", order_id: "o1" })).toEqual({ order_id: "o1" });
```

## Smoke check (layer 4)

The goal is to execute the production bootstrap, not a test double.

```bash
# console exporter: the app's own telemetry bootstrap, started once, output greppable
OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=console OTEL_TRACES_SAMPLER=always_on \
  timeout 20 bun run src/server.ts > /tmp/otel-smoke.log 2>&1 &
sleep 3 && curl -sf -X POST localhost:3000/orders -d '{}' -H 'content-type: application/json' >/dev/null
sleep 2; grep -q "'POST /orders'" /tmp/otel-smoke.log && grep -q "orders.checkout.duration" /tmp/otel-smoke.log
```

Wrap it in a script (`scripts/telemetry-smoke.sh`) so the acceptance criterion can name
it. OTLP variant: run `otel/opentelemetry-collector` with a `debug` exporter (verbosity
detailed) and grep its stdout, or point `OTEL_EXPORTER_OTLP_ENDPOINT` at a 20-line
HTTP server that writes request bodies to a file. If the app honours `OTEL_*` env vars
only through `@opentelemetry/sdk-node`, confirm that is what it uses; otherwise pass the
exporter through the repo's own config and say so in `conventions.md`.

## Acceptance criteria — Rosalbito shape

```yaml
dimensions: [functional, operational, testing]
acceptance:
  - criterion: "POST /orders emits a SERVER span 'POST /orders' with exactly {http.request.method, http.route, http.response.status_code, orders.status}; 'db.query orders' is its child in the same trace"
    dimension: operational
    verify: { command: "bun test test/telemetry/orders.trace.test.ts" }
  - criterion: "Histogram orders.checkout.duration (unit s) records one point per checkout; attribute value sets bounded to the enumerated allow-list under 200 varied inputs"
    dimension: operational
    verify: { command: "bun test test/telemetry/orders.cardinality.test.ts" }
  - criterion: "No span, metric or log of the orders flow carries a forbidden key; redact() strips email/token"
    dimension: security
    verify: { command: "bun test test/telemetry/pii.test.ts" }
  - criterion: "nats consumer span shares trace_id with the publisher span via traceparent header"
    dimension: operational
    verify: { command: "bun test test/telemetry/nats.propagation.test.ts" }
  - criterion: "Real bootstrap exports: console exporter prints 'POST /orders' and orders.checkout.duration after one request"
    dimension: operational
    verify: { command: "bash scripts/telemetry-smoke.sh" }
  - criterion: "instrumentation-map.md row for 'order checkout' names these commands"
    dimension: operational
    verify: { command: "grep -q 'orders.trace.test.ts' .agent/context/telemetry/instrumentation-map.md" }
```

Run each through `bash ~/.claude/skills/rosalbito/scripts/verify.sh <label> <command>`.

## Common false positives

- **Global no-op**: assertions pass because they only check "no exception"; the tracer was
  the API's no-op. Always assert a span *exists by name* first.
- **Provider registered after import**: module-level `getTracer()` captured a no-op.
  Import the code under test after `makeTestTelemetry()`.
- **Spans never ended**: `InMemorySpanExporter` only sees finished spans. A missing span
  often means a missing `span.end()` on an early-return/throw path. Use `startActiveSpan`
  with try/finally.
- **Batch processor in tests**: `BatchSpanProcessor` exports on a timer; use
  `SimpleSpanProcessor` in tests or `await provider.forceFlush()`.
- **Metric read before collect**: cumulative readers return nothing until `collect()`.
- **Shared exporter across tests**: call `reset()` in `beforeEach` or counts leak.
- **Sampler**: a `TraceIdRatioBased` sampler in the test provider makes tests flaky;
  use `AlwaysOnSampler` in tests and verify the production sampler separately.
- **Propagation "works" only in-process**: `context.active()` carries across awaits so a
  test that never serialises to a carrier does not prove cross-process propagation.
  Always go through `inject`/`extract` on a plain object.
- **Auto-instrumentation masks manual spans**: an HTTP auto-instrumentation span with the
  same name makes "span exists" pass while your manual attributes are on another span.
  Assert on the span that carries your attribute.
- **Green smoke with a stale process**: an older server on the port answers the curl.
  Check the PID or use a random port.
- **Console exporter output format**: it prints a JS object, not JSON; grep for the name
  with quotes as printed (`name: 'POST /orders'`).

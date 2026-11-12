# OpenTelemetry in TypeScript / Node / Bun

Read when the repo is TypeScript. No versions are pinned here; the JS SDK changed
constructor shapes between 1.x and 2.x, and the notes say where. When unsure, check the
installed package's docs (`node_modules/@opentelemetry/<pkg>/README.md`) before writing.

## Packages — what each is for

| Package | Role |
|---|---|
| `@opentelemetry/api` | the only thing application code imports: `trace`, `metrics`, `context`, `propagation`, `SpanKind`, `SpanStatusCode`. No-op until a provider is registered |
| `@opentelemetry/api-logs` | `logs.getLogger` for the logs bridge (optional) |
| `@opentelemetry/sdk-node` | `NodeSDK`: one-call bootstrap (resource, exporters, readers, context manager, instrumentations) |
| `@opentelemetry/sdk-trace-base` | `BasicTracerProvider`, processors, samplers, `InMemorySpanExporter`, `ConsoleSpanExporter` |
| `@opentelemetry/sdk-trace-node` | `NodeTracerProvider` (= base + Node context manager) |
| `@opentelemetry/sdk-metrics` | `MeterProvider`, `PeriodicExportingMetricReader`, `InMemoryMetricExporter`, `ConsoleMetricExporter`, views |
| `@opentelemetry/sdk-logs` | `LoggerProvider`, `InMemoryLogRecordExporter` |
| `@opentelemetry/resources` | resource construction (`resourceFromAttributes` in 2.x; `new Resource({...})` in 1.x) |
| `@opentelemetry/semantic-conventions` | `ATTR_SERVICE_NAME`, `ATTR_HTTP_ROUTE`, …; incubating names under `/incubating` |
| `@opentelemetry/core` | `W3CTraceContextPropagator`, `CompositePropagator`, `W3CBaggagePropagator` |
| `@opentelemetry/context-async-hooks` | `AsyncLocalStorageContextManager` |
| `@opentelemetry/exporter-trace-otlp-http`, `exporter-metrics-otlp-http`, `exporter-logs-otlp-http` (or `-grpc`, `-proto`) | OTLP exporters |
| `@opentelemetry/auto-instrumentations-node`, `instrumentation-http`, `instrumentation-pg`, … | module-patching auto-instrumentation (Node only; see Bun) |

Keep SDK packages out of application modules. Application code imports `@opentelemetry/api`
only; one bootstrap module owns the SDK.

## Bootstrap (must run before any application import)

`src/telemetry.ts` — imported first in the entry point, or loaded via
`node --import ./telemetry.js` / `--require`, so the context manager and instrumentations
are in place before application modules capture tracers or load `http`.

```ts
import { NodeSDK } from "@opentelemetry/sdk-node";
import { resourceFromAttributes } from "@opentelemetry/resources";           // 1.x: new Resource({...})
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from "@opentelemetry/semantic-conventions";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-http";
import { PeriodicExportingMetricReader, ConsoleMetricExporter } from "@opentelemetry/sdk-metrics";
import { ConsoleSpanExporter, ParentBasedSampler, TraceIdRatioBasedSampler } from "@opentelemetry/sdk-trace-base";

const console_ = process.env.OTEL_TRACES_EXPORTER === "console";
export const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME ?? "orders-api",
    [ATTR_SERVICE_VERSION]: process.env.APP_VERSION ?? "dev",
    "deployment.environment.name": process.env.APP_ENV ?? "dev",   // check semconv incubating export for the constant
  }),
  sampler: new ParentBasedSampler({ root: new TraceIdRatioBasedSampler(Number(process.env.OTEL_TRACES_SAMPLER_ARG ?? 1)) }),
  traceExporter: console_ ? new ConsoleSpanExporter() : new OTLPTraceExporter(),   // url from OTEL_EXPORTER_OTLP_ENDPOINT
  metricReader: new PeriodicExportingMetricReader({ exporter: console_ ? new ConsoleMetricExporter() : new OTLPMetricExporter() }),
  // instrumentations: [getNodeAutoInstrumentations()],   // Node only; see Bun section
});
sdk.start();
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => sdk.shutdown().finally(() => process.exit(0)));
```

`NodeSDK` reads `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER`,
`OTEL_TRACES_SAMPLER_ARG`, `OTEL_RESOURCE_ATTRIBUTES` when you do not override them in
code; explicit code options win. `OTEL_TRACES_EXPORTER=console` is honoured by `NodeSDK`
only in versions that implement exporter env config — the explicit branch above is the
portable way and is what the smoke check in `verification.md` relies on.

Without `sdk-node` (smaller, Bun-friendly), assemble the pieces: `NodeTracerProvider`
(or `BasicTracerProvider` + `AsyncLocalStorageContextManager`) with
`spanProcessors: [new BatchSpanProcessor(exporter)]` (2.x) / `addSpanProcessor` (1.x),
`provider.register({ propagator: new W3CTraceContextPropagator() })`; `MeterProvider`
with `readers: [...]` (2.x) / `addMetricReader` (1.x) and `metrics.setGlobalMeterProvider`.

## Manual instrumentation (the safe default)

```ts
import { trace, metrics, context, propagation, SpanKind, SpanStatusCode } from "@opentelemetry/api";
const tracer = trace.getTracer("orders", APP_VERSION);        // instrumentation scope name, not service name
const meter = metrics.getMeter("orders", APP_VERSION);
const checkoutDuration = meter.createHistogram("orders.checkout.duration", { unit: "s", description: "Checkout handler duration" });
const ordersCreated = meter.createCounter("orders.created", { unit: "{order}", description: "Orders created, by status" });
const inFlight = meter.createUpDownCounter("orders.checkout.in_flight", { unit: "{request}" });

export async function checkout(req: Request, route: string) {
  return tracer.startActiveSpan(`POST ${route}`, { kind: SpanKind.SERVER, attributes: { "http.request.method": "POST", "http.route": route } }, async (span) => {
    const t0 = performance.now(); inFlight.add(1); let status = 500;
    try {
      const order = await createOrder(await req.json());        // child spans start inside: context is active
      status = 201;
      span.setAttribute("orders.status", order.status);
      ordersCreated.add(1, { "orders.status": order.status });
      return Response.json(order, { status });
    } catch (err) {
      span.recordException(err as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (err as Error).message });
      span.setAttribute("error.type", (err as Error).constructor.name);
      ordersCreated.add(1, { "orders.status": "failed" });
      throw err;
    } finally {
      span.setAttribute("http.response.status_code", status);
      inFlight.add(-1);
      checkoutDuration.record((performance.now() - t0) / 1000, { "http.route": route, "http.response.status_code": status });
      span.end();
    }
  });
}
```

`startActiveSpan` makes the span current for everything awaited inside the callback; it
does **not** end the span. `finally { span.end() }` on every path. Keep status and other
values you need later in local variables: the API `Span` type does not expose
`attributes` (only the SDK's `ReadableSpan`, which tests see, does).

Synchronous `createGauge` exists in newer API versions; otherwise use
`meter.createObservableGauge(name, opts)` + `gauge.addCallback(result => result.observe(value, attrs))`.

## Context propagation

Propagator: register once (`NodeSDK` does; manual setups call
`propagation.setGlobalPropagator(new W3CTraceContextPropagator())` or
`provider.register({ propagator })`). Then:

```ts
// outbound HTTP (CLIENT span)
await tracer.startActiveSpan("GET /payments/{id}", { kind: SpanKind.CLIENT }, async (span) => {
  const headers: Record<string, string> = {};
  propagation.inject(context.active(), headers);                // writes traceparent (+ tracestate)
  try { return await fetch(url, { headers }); } finally { span.end(); }
});

// inbound HTTP (SERVER span) when no auto-instrumentation does it
const parentCtx = propagation.extract(context.active(), Object.fromEntries(req.headers));
tracer.startActiveSpan("POST /orders", { kind: SpanKind.SERVER }, parentCtx, async (span) => { /* ... */ });

// NATS publish: headers, never the payload
import { headers as natsHeaders } from "nats";
const h = natsHeaders();
await tracer.startActiveSpan("nats.publish orders.created", { kind: SpanKind.PRODUCER, attributes: { "messaging.system": "nats", "messaging.destination.name": "orders.created" } }, async (span) => {
  propagation.inject(context.active(), h, { set: (c, k, v) => c.set(k, v) });   // custom setter: NATS MsgHdrs is not a plain object
  nc.publish("orders.created", payload, { headers: h }); span.end();
});

// NATS subscribe
for await (const msg of sub) {
  const ctx = propagation.extract(context.active(), msg.headers ?? {}, { get: (c: any, k) => c.get?.(k) ?? undefined, keys: (c: any) => c.keys?.() ?? [] });
  await tracer.startActiveSpan("nats.process orders.created", { kind: SpanKind.CONSUMER, attributes: { "messaging.system": "nats", "messaging.destination.name": msg.subject, "messaging.operation.type": "process" } }, ctx, async (span) => {
    try { await handle(msg.json()); } finally { span.end(); }
  });
}

// background job: carry the context in the job's metadata, restore in the worker
const meta: Record<string, string> = {}; propagation.inject(context.active(), meta);
await queue.add("send-invoice", { orderId, _otel: meta });
// worker:
const ctx = propagation.extract(context.active(), job.data._otel ?? {});
tracer.startActiveSpan("job.process send-invoice", { kind: SpanKind.CONSUMER, attributes: { "job.name": "send-invoice", "job.attempt": job.attemptsMade } }, ctx, run);

// cron tick: new root
tracer.startActiveSpan("cron.tick reconcile-payments", { kind: SpanKind.INTERNAL, root: true, attributes: { "cron.schedule": "*/5 * * * *" } }, run);

// batched consumer: links instead of parent
const links = batch.map(m => ({ context: trace.getSpanContext(propagation.extract(context.active(), m.headers))! })).filter(l => l.context);
tracer.startActiveSpan("nats.process orders.batch", { kind: SpanKind.CONSUMER, links }, run);
```

Getters/setters for `inject`/`extract` take any carrier when you pass a `TextMapSetter` /
`TextMapGetter`; the defaults assume a plain object with string values. Agent-to-agent
calls follow the HTTP pattern over whatever transport they use (headers, metadata field,
or a `_otel` field in the request envelope).

Logs: with pino, add `trace_id`/`span_id` with a `mixin`:
`pino({ mixin() { const s = trace.getActiveSpan()?.spanContext(); return s ? { trace_id: s.traceId, span_id: s.spanId } : {}; } })`.
The OTel logs bridge (`@opentelemetry/sdk-logs` + `instrumentation-pino`/`-winston`)
does the same through the SDK when the repo already ships logs over OTLP.

## Testing patterns

Full harness and assertion catalogue: `verification.md`. Essentials:

- Test providers built per file (or per suite), **registered before importing the code
  under test**: `const mod = await import("../src/orders")` after `makeTestTelemetry()`.
- `SimpleSpanProcessor` + `InMemorySpanExporter`; `getFinishedSpans()`; `reset()` in
  `beforeEach`; `shutdown()` + `trace.disable()`/`metrics.disable()`/`context.disable()`
  in `afterAll` so the next file can register its own globals (the API refuses a second
  global registration and logs a diagnostic; `disable()` clears it).
- Metrics: `InMemoryMetricExporter(AggregationTemporality.CUMULATIVE)` behind a
  `PeriodicExportingMetricReader` with a long interval; call `await reader.collect()` and
  read `resourceMetrics.scopeMetrics[].metrics[]` → `descriptor.{name,unit,type}` and
  `dataPoints[].{attributes,value}`. Histogram `value` is `{ count, sum, min, max, buckets }`.
- vitest: one `setupFiles` entry is acceptable for the context manager + propagator, but
  keep exporters per test file so assertions are isolated. `bun test`: same, with
  `preload` in `bunfig.toml`.
- Never share the production `sdk` instance with tests: `NodeSDK.start()` installs global
  instrumentations and a batch processor you cannot flush deterministically.

## Bun

- `@opentelemetry/api`, `sdk-trace-base`, `sdk-metrics`, `sdk-logs`, OTLP HTTP exporters,
  `AsyncLocalStorageContextManager` (Bun implements `AsyncLocalStorage`) work in practice;
  verify with the smoke check in the target repo rather than assuming.
- **Auto-instrumentations** (`auto-instrumentations-node`, `instrumentation-http`,
  `instrumentation-pg`, …) rely on `require-in-the-middle` / `import-in-the-middle`
  module patching. Under Bun that patching is partial or silently absent: spans simply do
  not appear, with no error. Do not depend on it. **Manual instrumentation through the
  API is the safe default on Bun**, and the propagation code above is what replaces the
  HTTP instrumentation. Bun's own `fetch` and `Bun.serve` are not patched by Node
  instrumentations at all.
- `NodeSDK` can start under Bun but its value (auto-instrumentation, env-driven setup)
  is mostly lost; assembling providers directly is simpler and easier to test.
- Some OTLP gRPC exporters depend on `@grpc/grpc-js` native behaviour; prefer the HTTP
  (`-http` / `-proto`) exporters under Bun.
- Re-check against the installed Bun and SDK versions; this situation improves over time.

## Pitfalls

- **SDK started after imports**: application modules captured a no-op tracer, or `http`
  was loaded before the instrumentation patched it. Bootstrap first, always.
- **Double instrumentation**: auto HTTP spans + manual SERVER spans for the same request.
  Pick one per boundary; if both exist, make the manual span `INTERNAL` or drop it.
- **Forgetting `span.end()`** on throw/early return: the span never exports and leaks
  memory in batch processors. `try/finally`.
- **Context lost across callbacks** (event emitters, timers, callback-style libs):
  bind with `context.bind(context.active(), fn)` or re-enter with `context.with(ctx, fn)`.
- **No flush before exit**: short-lived processes (CLI, cron, serverless) lose the last
  batch. `await sdk.shutdown()` (or `provider.forceFlush()`) before `process.exit`.
- **Attributes with `undefined`/objects**: dropped silently. Only string/number/boolean
  and arrays of those; stringify enums explicitly.
- **Units**: recording milliseconds into a histogram declared `s` (or vice versa) ruins
  every percentile; the test asserts the unit, the code must match.
- **`getTracer` name = service name**: wrong; it is the instrumentation scope
  (library/module). The service name lives on the resource.
- **Two API copies** (monorepo, mismatched versions): the SDK registers on one, your code
  calls the other, everything is no-op. `npm ls @opentelemetry/api` must show one version.

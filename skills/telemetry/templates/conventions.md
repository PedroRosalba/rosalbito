# Telemetry conventions — <repo>

> Durable per-repo context read by the `telemetry` skill (`.agent/context/telemetry/`).
> These are decisions, not suggestions: the skill follows them and extends them. Fill what
> is known; mark the rest `TBD`. Updated: <date>

## Stack

- language / runtime: `<TypeScript on Bun | Node 22 | Rust | Python 3.x>`
- SDK packages: `<@opentelemetry/api + sdk-trace-base + sdk-metrics | tracing + tracing-opentelemetry | opentelemetry-sdk>`
- auto-instrumentation: `<none (manual via API) | list>` — reason: `<Bun | policy>`
- logging library and bridge: `<pino with trace_id mixin | tracing-subscriber json | stdlib + LoggingInstrumentor>`

## Resource attributes (set once in the bootstrap)

| attribute | value / source |
|---|---|
| `service.name` | `<name>` (env `OTEL_SERVICE_NAME` overrides) |
| `service.version` | `<git sha / package version>` |
| `service.namespace` | `<product>` |
| `deployment.environment.name` | `<dev | staging | prod>` from `<env var>` |

## Naming

- metric prefix / namespace: `<orders.>`; `attribute_prefix` for domain keys: `<orders.>`
- span names: route templates / `<system>.<operation> <target>`; never ids or raw paths
- metric units: durations in `s`; sizes in `By`; counts `{noun}`
- instrumentation scope names (`getTracer(name)`): `<module names, e.g. orders, payments>`
- semantic conventions package pinned in the repo: `<yes/no>`; use `ATTR_*` constants

## Exporter / backend

- traces: `<OTLP http → collector :4318 | vendor endpoint>`; env: `OTEL_EXPORTER_OTLP_ENDPOINT`
- metrics: `<OTLP | Prometheus scrape /metrics>`; temporality: `<cumulative | delta>`
- logs: `<OTLP via bridge | stdout JSON shipped by …>`
- dev: `OTEL_TRACES_EXPORTER=console` (or `<repo's own switch>`) ; tests: in-memory only
- collector config location: `<path | none>`

## Sampling

- head: `ParentBased(TraceIdRatio(<r>))`; `r` = 1.0 dev/test, `<0.1>` prod (env `OTEL_TRACES_SAMPLER_ARG`)
- tail / error keeping: `<collector tail_sampling policy | none — documented gap>`
- metrics: never sampled; logs: `<severity ≥ INFO in prod>`
- budgets: ≤ `<1000>` series per metric per instance; ≤ `<50>` spans per request

## PII and secrets policy

- forbidden everywhere: bodies, prompts/completions, tokens, keys, auth headers, cookies, passwords, phone numbers, emails, names, addresses, card/bank numbers, raw SQL with values, full URLs with query strings`<, client IPs>`
- allowed id keys (opaque identifiers only, spans/events only, never metric attributes): `<orders.id, job.id, …>`
- allow-listed attribute keys per signal: see `instrumentation-map.md` rows; anything else fails the PII test
- redaction function: `<path/to/redact.ts>` — tested by `<command>`
- auto-instrumentation options disabled: `<db.statement capture, header capture, url query>`

## Verification commands

| check | command |
|---|---|
| unit (in-memory exporters) | `<bun test test/telemetry>` |
| cardinality | `<bun test test/telemetry/cardinality.test.ts>` |
| PII | `<bun test test/telemetry/pii.test.ts>` |
| smoke (real pipeline) | `<bash scripts/telemetry-smoke.sh>` |

## Decisions log

- <date> — <decision, e.g. "manual instrumentation only; auto-instrumentations unreliable under Bun"> — <.agent/context/adr/<n>-<slug>.md if any>

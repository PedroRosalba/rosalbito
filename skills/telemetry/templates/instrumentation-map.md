# Instrumentation map — <repo>

> Durable per-repo context read by the `telemetry` skill (`.agent/context/telemetry/`).
> One row per flow. Every `verified-by` names a command that exists and exits non-zero when
> the row is false. Keep rows truthful; mark unknowns `TBD`, never guess. Updated: <date>

## Entry point and pipeline

- bootstrap module: `<path/to/telemetry.ts|rs|py>` — started by: `<entry point / --import / launcher>`
- exporter(s): `<otlp-http → collector at … | console in dev>` (details in `conventions.md`)
- auto-instrumentation in use: `<none | list>`
- smoke check: `<scripts/telemetry-smoke.sh>`

## Flows

| flow | question(s) answered | spans (name · kind) | metrics (name · type · unit · attrs) | events / logs | owner | verified-by |
|---|---|---|---|---|---|---|
| order checkout | p95 latency per route; why is this checkout slow; which status outcomes | `POST /orders` · SERVER → `db.query orders` · INTERNAL → `nats.publish orders.created` · PRODUCER | `orders.checkout.duration` · histogram · s · {http.route, http.response.status_code}; `orders.created` · counter · {order} · {orders.status} | event `orders.paid` {orders.id} | <team/person> | `bun test test/telemetry/orders.trace.test.ts`; `bun test test/telemetry/orders.cardinality.test.ts` |
| <flow> | | | | | | TBD |

## SLIs

| SLI | formula (backend query) | metric(s) | target | verified-by |
|---|---|---|---|---|
| checkout availability | 1 − (orders.created{orders.status="failed"} / orders.created) over 30d | `orders.created` | 99.9% | `<dashboard/alert file or test>` |

## Known gaps

- <flow or boundary with no instrumentation, and the question it would answer>
- <attribute flagged for cardinality or PII review>

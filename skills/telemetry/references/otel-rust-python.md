# OpenTelemetry in Rust and Python — compact equivalents

Same rules as the TypeScript file (SKILL.md §3–§8); only the mechanics differ. Crate and
package APIs below are current at time of writing but both ecosystems rename types between
minor versions — confirm against the installed version's docs (`cargo doc --open`,
`python -c "import opentelemetry.sdk.trace as t; help(t)"`).

## Rust

Crates: `opentelemetry` (API: `global`, `KeyValue`, `trace::Tracer`),
`opentelemetry_sdk` (providers, processors, samplers, in-memory exporters behind the
`testing` feature), `opentelemetry-otlp` (OTLP exporters), `opentelemetry-semantic-conventions`,
`opentelemetry-http` (`HeaderInjector`/`HeaderExtractor` for `http::HeaderMap`),
`tracing` + `tracing-subscriber` + `tracing-opentelemetry` (bridge: `tracing` spans → OTel spans).

Idiomatic setup is `tracing` for instrumentation and `tracing-opentelemetry` as the bridge:

```rust
use opentelemetry::{global, KeyValue, trace::TracerProvider as _};
use opentelemetry_sdk::{trace::SdkTracerProvider, Resource, propagation::TraceContextPropagator}; // older: trace::TracerProvider
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

pub fn init() -> SdkTracerProvider {
    global::set_text_map_propagator(TraceContextPropagator::new());
    let exporter = opentelemetry_otlp::SpanExporter::builder().with_http().build().expect("otlp");
    let provider = SdkTracerProvider::builder()
        .with_batch_exporter(exporter)                       // builder method names vary by version
        .with_resource(Resource::builder().with_service_name("orders-api").build())
        .build();
    global::set_tracer_provider(provider.clone());
    let tracer = provider.tracer("orders");
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer().json())       // structured logs
        .with(tracing_opentelemetry::layer().with_tracer(tracer))
        .init();
    provider                                                 // keep it; call provider.shutdown() on exit
}
```

Instrument with `#[tracing::instrument(name = "POST /orders", skip_all, fields(http.route = %route, orders.status = tracing::field::Empty))]`
and fill later with `tracing::Span::current().record("orders.status", "paid")`. Span kind
and status go through `tracing_opentelemetry::OpenTelemetrySpanExt` (`span.set_status`,
`set_attribute`) or the `otel.kind` / `otel.status_code` / `otel.name` special fields.
Errors: `tracing::error!(error = %e, error.type = "PaymentDeclined")` inside the span plus
`otel.status_code = "ERROR"`.

Propagation across HTTP/NATS/jobs:

```rust
use tracing_opentelemetry::OpenTelemetrySpanExt;
// inject (outbound)
let cx = tracing::Span::current().context();
global::get_text_map_propagator(|p| p.inject_context(&cx, &mut opentelemetry_http::HeaderInjector(req.headers_mut())));
// NATS: async_nats::HeaderMap is not http::HeaderMap — implement opentelemetry::propagation::Injector/Extractor (set/get/keys) for a thin wrapper
// extract (inbound) and parent the handler span
let parent = global::get_text_map_propagator(|p| p.extract(&opentelemetry_http::HeaderExtractor(req.headers())));
let span = tracing::info_span!("POST /orders", otel.kind = "server", http.route = "/orders");
span.set_parent(parent);
```

Metrics: `opentelemetry::global::meter("orders")` →
`meter.u64_counter("orders.created").with_unit("{order}").with_description("…").build()`
(older: `.init()`), `f64_histogram("orders.checkout.duration").with_unit("s")`,
`i64_up_down_counter`, `u64_observable_gauge(...).with_callback(...)`. Record with
`.add(1, &[KeyValue::new("orders.status", "paid")])` / `.record(secs, &attrs)`.
`SdkMeterProvider::builder().with_reader(PeriodicReader::builder(exporter).build())`.
`metrics` crate + `metrics-exporter-prometheus` is the common non-OTel alternative; the
naming/cardinality rules apply unchanged.

Testing (feature `testing` on `opentelemetry_sdk`):

```rust
use opentelemetry_sdk::trace::{SdkTracerProvider, SimpleSpanProcessor, InMemorySpanExporter}; // older: opentelemetry_sdk::testing::trace::InMemorySpanExporter
// metrics: opentelemetry_sdk::metrics::{InMemoryMetricExporter, PeriodicReader} (module path also moved between versions)
let exporter = InMemorySpanExporter::default();
let provider = SdkTracerProvider::builder().with_span_processor(SimpleSpanProcessor::new(exporter.clone())).build();
let tracer = provider.tracer("test");
let subscriber = tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
let _guard = tracing::subscriber::set_default(subscriber);   // per-test, not global: global init is once-per-process
checkout(&req).await;
let _ = provider.force_flush();                               // return type differs by version; check it, do not ignore errors in real tests
let spans = exporter.get_finished_spans().unwrap();
let server = spans.iter().find(|s| s.name == "POST /orders").expect("SERVER span missing");
assert_eq!(server.span_kind, opentelemetry::trace::SpanKind::Server);
assert!(server.attributes.iter().any(|kv| kv.key.as_str() == "http.route" && kv.value.as_str() == "/orders"));
let db = spans.iter().find(|s| s.name == "db.query orders").unwrap();
assert_eq!(db.parent_span_id, server.span_context.span_id());
assert_eq!(db.span_context.trace_id(), server.span_context.trace_id());
assert!(matches!(failed.status, opentelemetry::trace::Status::Error { .. }));
```

Metrics: `InMemoryMetricExporter` + `PeriodicReader`, `provider.force_flush()`, then
`exporter.get_finished_metrics()` → `scope_metrics[].metrics[]` with `name`, `unit`, and
a `data` enum (`Sum`, `Histogram`, `Gauge`) holding `data_points[].{attributes, value}`.
Cardinality test: same loop as the TS one over `data_points`.

Pitfalls: a `tracing` span without the OTel layer installed is silently a no-op (assert
span presence first); `set_global_default` can run once per process — use `set_default`
guards in tests; `tracing` fields set after `record` on a field not declared as `Empty`
are dropped; batch exporters need `shutdown()`/`force_flush()` before process exit,
including in CLIs and cron binaries; async runtimes need the matching
`opentelemetry_sdk` feature (`rt-tokio`) for batch processors in older versions.

## Python

Packages: `opentelemetry-api`, `opentelemetry-sdk`, `opentelemetry-exporter-otlp-proto-http`
(or `-grpc`), `opentelemetry-semantic-conventions`, `opentelemetry-instrumentation-*`
(`fastapi`, `requests`, `httpx`, `sqlalchemy`, `psycopg`, `logging`, …) and the
`opentelemetry-instrument` launcher that applies them without code changes
(`opentelemetry-instrument --traces_exporter otlp python app.py`, configured by `OTEL_*`).

Bootstrap:

```python
from opentelemetry import trace, metrics
from opentelemetry.sdk.resources import Resource, SERVICE_NAME, SERVICE_VERSION
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter

resource = Resource.create({SERVICE_NAME: "orders-api", SERVICE_VERSION: "1.2.3", "deployment.environment.name": "dev"})
tp = TracerProvider(resource=resource, sampler=ParentBased(TraceIdRatioBased(1.0)))
tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))           # endpoint from OTEL_EXPORTER_OTLP_ENDPOINT
trace.set_tracer_provider(tp)                                            # once per process; later calls are ignored with a warning
mp = MeterProvider(resource=resource, metric_readers=[PeriodicExportingMetricReader(OTLPMetricExporter())])
metrics.set_meter_provider(mp)
import atexit; atexit.register(tp.shutdown); atexit.register(mp.shutdown)
```

Instrument:

```python
from opentelemetry import trace, metrics, propagate, context
from opentelemetry.trace import SpanKind, Status, StatusCode
tracer = trace.get_tracer("orders"); meter = metrics.get_meter("orders")
checkout_duration = meter.create_histogram("orders.checkout.duration", unit="s", description="Checkout handler duration")
orders_created = meter.create_counter("orders.created", unit="{order}")

def checkout(req, route="/orders"):
    with tracer.start_as_current_span(f"POST {route}", kind=SpanKind.SERVER, attributes={"http.request.method": "POST", "http.route": route}) as span:
        t0 = time.perf_counter()
        try:
            order = create_order(req.json)                    # child spans inherit the current context
            span.set_attribute("orders.status", order.status); span.set_attribute("http.response.status_code", 201)
            orders_created.add(1, {"orders.status": order.status}); return order
        except Exception as e:
            span.record_exception(e); span.set_status(Status(StatusCode.ERROR, str(e))); span.set_attribute("error.type", type(e).__name__)
            orders_created.add(1, {"orders.status": "failed"}); raise
        finally:
            checkout_duration.record(time.perf_counter() - t0, {"http.route": route})
```

`start_as_current_span` ends the span on exit and records exceptions by default
(`record_exception=True`, `set_status_on_exception=True`); explicit calls keep intent
visible. Propagation: `propagate.inject(headers)` on outbound, `ctx = propagate.extract(headers)`
then `tracer.start_as_current_span(..., context=ctx)` on inbound; NATS/queues carry the
dict in message headers / job metadata; batched consumers use `links=[Link(span_context)]`.
Logs: `opentelemetry.instrumentation.logging.LoggingInstrumentor().instrument()` adds
`otelTraceID`/`otelSpanID` to stdlib log records; the OTel logs SDK lives under
`opentelemetry.sdk._logs` (still provisional — expect renames).

Testing (`pytest`):

```python
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import InMemoryMetricReader

@pytest.fixture
def telemetry(monkeypatch):
    exporter = InMemorySpanExporter(); tp = TracerProvider(); tp.add_span_processor(SimpleSpanProcessor(exporter))
    reader = InMemoryMetricReader(); mp = MeterProvider(metric_readers=[reader])
    # global providers can only be set once per process: patch the module-level tracer/meter instead
    monkeypatch.setattr(orders, "tracer", tp.get_tracer("orders"))
    monkeypatch.setattr(orders, "meter", mp.get_meter("orders")); orders._rebuild_instruments()
    yield exporter, reader
    tp.shutdown(); mp.shutdown()

def test_checkout_span_tree(telemetry):
    exporter, reader = telemetry
    orders.checkout(fake_request())
    spans = {s.name: s for s in exporter.get_finished_spans()}
    server, db = spans["POST /orders"], spans["db.query orders"]
    assert server.kind == SpanKind.SERVER and server.attributes["http.route"] == "/orders"
    assert db.parent.span_id == server.context.span_id and db.context.trace_id == server.context.trace_id
    assert server.status.status_code == StatusCode.UNSET
    data = reader.get_metrics_data()
    m = next(m for rm in data.resource_metrics for sm in rm.scope_metrics for m in sm.metrics if m.name == "orders.checkout.duration")
    assert m.unit == "s"
    (dp,) = m.data.data_points; assert dp.attributes == {"http.route": "/orders"} and dp.count == 1
```

Alternative to monkeypatching: create instruments lazily inside functions, or pass
`tracer_provider=` / `meter_provider=` explicitly (`trace.get_tracer("orders", tracer_provider=tp)`).
Pitfalls: `set_tracer_provider` is once-per-process (tests that call it twice silently
keep the first); `InMemoryMetricReader.get_metrics_data()` triggers collection itself;
`BatchSpanProcessor` in tests → use `SimpleSpanProcessor` or `tp.force_flush()`; stdlib
`logging` with f-strings is not structured — use `extra={...}` or a structured logger;
auto-instrumentation with `opentelemetry-instrument` must wrap the real entry point
(gunicorn workers need the `post_fork` hook) or the smoke check shows nothing.

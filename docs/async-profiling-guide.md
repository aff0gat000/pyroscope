# Profiling Asynchronous Frameworks

Why continuous profiling is harder with reactive/async frameworks like Vert.x, what
Pyroscope labels can and cannot solve, and what the community recommends.

---

## The problem

In traditional thread-per-request frameworks (Spring MVC, JAX-RS, Django), each HTTP
request runs on its own thread from start to finish. A flame graph naturally groups
work by thread, so you can see which endpoint is burning CPU:

```
Thread-1  →  GET /triage/myapp      →  CPU: 200ms  (visible in flame graph)
Thread-2  →  GET /diff/myapp        →  CPU: 50ms   (visible in flame graph)
Thread-3  →  GET /triage/otherapp   →  CPU: 180ms  (visible in flame graph)
```

In **reactive/async frameworks** (Vert.x, Spring WebFlux, Netty, Node.js, Go goroutines),
a small pool of event loop threads handles **all** requests. Multiple requests share the
same thread:

```
EventLoop-0  →  GET /triage/myapp      ─┐
                GET /diff/myapp        ─┤  all interleaved on one thread
                GET /triage/otherapp   ─┘

Flame graph shows: "EventLoop-0 spent 430ms in CPU"
                   ... but which endpoint? which request? impossible to tell.
```

The flame graph becomes a flat blob of Netty internals and Vert.x router dispatch code.
You can see the application is spending CPU, but you cannot attribute it to a specific
endpoint, function, or request.

---

## Why this matters

Without request-level attribution, you cannot answer:

| Question | Traditional framework | Async framework (no labels) |
|----------|----------------------|----------------------------|
| Which endpoint is slowest? | Filter by thread name | Cannot tell |
| Is v1 or v2 of my function slower? | Separate thread pools | Cannot tell |
| Which downstream call (SOR, DB, API) is the bottleneck? | Visible in thread stack | Interleaved with other requests |
| Did my code change improve performance? | Compare before/after by endpoint | Noise from unrelated endpoints |

This is not a Pyroscope limitation — it affects **all** profilers (async-profiler, JFR,
YourKit, VisualVM) when used with async frameworks. The Quarkus team built a dedicated
[Reactive Code Profiler](https://github.com/quarkusio/quarkus/issues/25712) specifically
because standard profiling tools are insufficient for reactive code.

---

## What profiling can and cannot tell you

| Capability | Vert.x / reactive | Status |
|------------|-------------------|--------|
| Global CPU flame graph (all requests merged) | Works well | Tells you "40% of CPU is in JSON serialization" globally |
| Memory allocation profiling | Works well | Find allocation hotspots and leak sources |
| Detect blocking calls on event loop | Works (wall-clock mode) | Critical for Vert.x — find accidental blocking |
| Per-endpoint CPU attribution via labels (Tier 1) | Synchronous handler path | Labels cover route matching, computation, request construction |
| Per-endpoint CPU attribution in async callbacks (Tier 2) | Opt-in via `LabeledFuture` | Captures Tier 1 labels, re-applies in `.onSuccess()` / `.compose()` / `.map()` |
| Downstream service attribution (Tier 2) | Opt-in via `LabeledFuture` downstream overload | Identifies which dependency call is consuming CPU |
| Span-correlated profiling via OpenTelemetry | Partial (CPU only) | Requires OTel tracing setup; misses spans < 10ms |

**Bottom line:** Tier 1 (automatic label handler) gives you per-endpoint CPU attribution
for synchronous handler code — roughly 80% of CPU work. Tier 2 (`LabeledFuture`, opt-in)
extends attribution into async callbacks and adds downstream service identification,
covering ~95% of CPU work. The remaining ~5% (framework internals, event loop overhead)
is not attributable to specific requests — this is an industry-wide limitation.

---

## The solution: Pyroscope labels (with known limitations)

Pyroscope's Java agent supports **dynamic labels** — key-value pairs that tag profiling
samples at runtime. Labels replace thread identity as the grouping mechanism:

```java
Pyroscope.LabelsWrapper.run(
    new LabelsSet("endpoint", "/triage", "function", "v1"),
    () -> {
        // All CPU/memory samples taken during this block
        // are tagged with endpoint=/triage, function=v1
    }
);
```

In the Pyroscope UI, you can then filter flame graphs by label:

```
{service_name="pyroscope-bor", endpoint="/triage"}   → shows only triage CPU
{service_name="pyroscope-bor", function="v2"}         → shows only v2 variant
```

This restores the per-request visibility that traditional frameworks provide for free.

---

## Labeling strategy

### Recommended labels

| Label | Value | Purpose | Example |
|-------|-------|---------|---------|
| `endpoint` | Route path | Filter by API endpoint | `/triage/:appName`, `/diff/:appName` |
| `http.method` | HTTP method | Distinguish GET/POST | `GET`, `POST` |
| `function` | FUNCTION env var | Filter by function variant | `ReadPyroscopeTriageAssessment.v1` |
| `layer` | `bor` or `sor` | Filter by architecture layer | `bor` |
| `downstream` | Target service | Identify slow dependencies | `pyroscope-api`, `postgresql` |

### Naming conventions

- Use lowercase, dot-separated names (`http.method`, not `HTTP_METHOD`)
- Use short, stable values (route patterns like `/triage/:appName`, not actual paths like `/triage/my-app-123`)
- Avoid high-cardinality labels (no request IDs, timestamps, or user IDs)
- Keep label count under 5 per request to minimize overhead

### Cardinality warning

Every unique label combination creates a separate profiling series. High cardinality
(many unique values) increases storage and makes the UI harder to navigate:

| Label | Cardinality | OK? |
|-------|-------------|-----|
| `endpoint=/triage` | ~10 routes | Good |
| `function=v1` | 2-3 variants | Good |
| `request_id=abc-123` | Unbounded | Bad — never do this |
| `user_id=12345` | Thousands | Bad — never do this |

---

## Implementation: Vert.x (this project)

### How it works

The `AbstractFunctionVerticle` base class registers a route handler **before** all
endpoint routes. This handler wraps the request execution with Pyroscope labels, so
every verticle gets labeled automatically — no per-verticle code changes.

```java
// In AbstractFunctionVerticle.start()
router.route().handler(ctx -> {
    String endpoint = ctx.currentRoute() != null
            ? ctx.currentRoute().getPath()
            : ctx.request().path();
    LabelsSet labels = new LabelsSet(
        "endpoint", endpoint != null ? endpoint : "unknown",
        "http.method", ctx.request().method().name()
    );
    Pyroscope.LabelsWrapper.run(labels, () -> ctx.next());
});
```

### What gets labeled

The `LabelsWrapper.run()` call tags all CPU and memory samples captured **during the
synchronous handler execution**. For Vert.x, this covers:

- Route matching and parameter extraction
- JSON parsing and serialization
- Business logic computation (triage rules, diff calculation, scoring)
- WebClient request construction (building the HTTP call to SOR or Pyroscope API)

### What does NOT get labeled (known limitation)

Async callbacks (`.onSuccess()`, `.onComplete()`) execute **after** the label scope ends.
Pyroscope labels use `ThreadLocal` storage, which does not propagate across async
boundaries. This is confirmed by the pyroscope-java maintainer in
[grafana/pyroscope-java#237](https://github.com/grafana/pyroscope-java/issues/237):
*"No, there is no good way to handle this at the moment."*

The async-profiler project proposed a context ID feature specifically for reactive
frameworks ([async-profiler PR #576](https://github.com/async-profiler/async-profiler/pull/576)),
but it was **closed without merging** due to JNI overhead concerns. No replacement has
been shipped as of March 2026.

**Unlabeled async callbacks include:**

- I/O completion handlers (`.onSuccess()`, `.onComplete()`)
- Future composition (`.map()`, `.compose()`)
- Response writing (`ctx.response().end()`)

**Why this is still useful for most cases:**

1. **CPU time is concentrated in the synchronous path.** For this project's FaaS verticles,
   JSON parsing, triage rule computation, diff calculation, and HTTP request construction
   all happen synchronously — this is where labels are active.
2. **Async callbacks are typically cheap.** They move data from network buffers to response
   objects. Very little CPU work.
3. **I/O waiting is non-blocking.** The event loop thread is not consuming CPU while
   waiting for a network response — there is nothing to profile.

**When this limitation hurts:**

- Heavy JSON processing inside `.onSuccess()` handlers
- Significant computation in `.compose()` chains
- Worker verticle callbacks with business logic

If you need async-boundary labeling, see
[Tier 2: LabeledFuture (async label propagation)](#tier-2-labeledfuture-async-label-propagation) below.

### Dependency setup

The Pyroscope agent is loaded at runtime via `-javaagent`. Add the labels API as a
`compileOnly` dependency so you can call it from code without bundling the agent JAR:

```groovy
// build.gradle (shared)
compileOnly 'io.pyroscope:agent:0.13.1'
```

The agent JAR is configured via environment variables or properties file — see
[configuration-reference.md](configuration-reference.md).

### Graceful fallback when agent is not running

If the Pyroscope agent is not attached (e.g., local development), the `LabelsWrapper.run()`
call is a no-op — it simply executes the wrapped code without labeling. No errors, no
performance impact. This means the label handler is safe to deploy everywhere.

---

## Implementation: other frameworks

The labeling pattern is the same across languages — middleware that wraps request
handlers with Pyroscope labels. Only the middleware API differs.

### Spring WebFlux (Java)

```java
@Component
public class PyroscopeLabelFilter implements WebFilter {
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        String endpoint = exchange.getRequest().getPath().value();
        String method = exchange.getRequest().getMethod().name();
        return Mono.defer(() -> {
            LabelsSet labels = new LabelsSet("endpoint", endpoint, "http.method", method);
            return Mono.fromRunnable(() ->
                Pyroscope.LabelsWrapper.run(labels, () -> {})
            ).then(chain.filter(exchange));
        });
    }
}
```

### Go (net/http)

```go
func pyroscopeLabels(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        pprof.Do(r.Context(), pprof.Labels(
            "endpoint", r.URL.Path,
            "method", r.Method,
        ), func(ctx context.Context) {
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    })
}
```

### Python (FastAPI)

```python
import pyroscope

@app.middleware("http")
async def pyroscope_labels(request, call_next):
    with pyroscope.tag_wrapper({
        "endpoint": request.url.path,
        "method": request.method,
    }):
        return await call_next(request)
```

### Node.js / Express

```javascript
app.use((req, res, next) => {
    Pyroscope.wrapWithLabels(
        { endpoint: req.path, method: req.method },
        () => next()
    );
});
```

Each implementation is 5-15 lines. The **labeling strategy** (which labels, naming
conventions, cardinality rules) is shared across all languages — only the middleware
syntax differs.

---

## Two-tier labeling architecture

Profiling labels are split into two tiers, each solving a different problem:

| Tier | What it does | Developer effort | Coverage |
|------|-------------|-----------------|----------|
| **Tier 1** — Label handler in `AbstractFunctionVerticle` | Tags all synchronous handler code with endpoint, function, layer, http.method | Zero — automatic for every verticle | ~80% of CPU work (route matching, JSON parsing, computation, request construction) |
| **Tier 2** — `LabeledFuture` in `pyroscope-vertx` library | Captures Tier 1 labels and re-applies them inside async callbacks | One line per async call — opt-in | ~95% of CPU work (adds async callbacks: `.onSuccess()`, `.compose()`, `.map()`) |

**Tier 1 is always active.** It covers all verticles with zero code changes because
it runs in the base class. This is the enterprise solution — developers deploy functions
and get per-endpoint profiling automatically.

**Tier 2 is opt-in.** When a developer sees a hot function in the flame graph but the
bottleneck is inside an async callback (`.onSuccess()`, `.compose()`), they add
`LabeledFuture` to that specific handler to get deeper attribution.

---

## Tier 2: LabeledFuture (async label propagation)

### The problem it solves

Pyroscope labels use `ThreadLocal` storage. When Tier 1 calls `LabelsWrapper.run()`,
labels are active on the event loop thread during synchronous handler execution. But
async callbacks (`.onSuccess()`, `.compose()`, `.map()`) execute **after** the label
scope ends — the `ThreadLocal` labels are gone by the time the callback fires.

This is confirmed by the pyroscope-java maintainer in
[grafana/pyroscope-java#237](https://github.com/grafana/pyroscope-java/issues/237):
*"No, there is no good way to handle this at the moment."*

The async-profiler project proposed solving this at the JVM level
([async-profiler PR#576](https://github.com/async-profiler/async-profiler/pull/576)),
but it was **closed without merging** due to JNI overhead. No automatic solution exists.

### How LabeledFuture works

`LabeledFuture` uses a capture-and-replay pattern:

1. **Capture:** When you call `LabeledFuture.from(ctx, future)`, it snapshots the
   labels that the Tier 1 handler stored on the `RoutingContext` (endpoint, function,
   layer, http.method).
2. **Replay:** When an async callback fires (`.onSuccess()`, `.compose()`, `.map()`),
   LabeledFuture re-applies those captured labels via `LabelsWrapper.run()` before
   executing the callback.

```
Tier 1 handler sets labels on ThreadLocal AND stores on RoutingContext
    │
    ▼
Handler code runs (labels active via ThreadLocal)
    │
    ├── LabeledFuture.from(ctx, future)  ◄── snapshots labels from RoutingContext
    │
    ▼
Handler returns, ThreadLocal labels cleared
    │
    ... async I/O completes ...
    │
    ▼
LabeledFuture.onSuccess() fires
    │
    ├── Re-applies captured labels via LabelsWrapper.run()
    ├── Executes callback (labels active — profiler attributes CPU correctly)
    └── Clears labels
```

### Usage

Add the dependency to your verticle project's `build.gradle`:

```groovy
dependencies {
    implementation project(':pyroscope-vertx')
}
```

Then wrap async calls with `LabeledFuture.from()`:

```java
import com.pyroscope.vertx.LabeledFuture;

// Before — labels lost in callback
webClient.get(sorPort, "localhost", "/baseline").send()
    .onSuccess(response -> {
        // ❌ No labels — profiler can't attribute this CPU to an endpoint
        JsonObject result = computeTriageRules(response.bodyAsJsonObject());
        ctx.response().end(result.encode());
    });

// After — labels preserved
LabeledFuture.from(ctx, webClient.get(sorPort, "localhost", "/baseline").send())
    .onSuccess(response -> {
        // ✅ Labels active: endpoint=/triage, function=v1, layer=bor, http.method=GET
        JsonObject result = computeTriageRules(response.bodyAsJsonObject());
        ctx.response().end(result.encode());
    });
```

### Downstream service attribution

When calling another service, pass a downstream name to identify which dependency
is being called:

```java
LabeledFuture.from(ctx, "pyroscope-sor",
        webClient.get(sorPort, "localhost", "/baseline").send())
    .onSuccess(response -> {
        // Labels: endpoint=/triage, function=v1, downstream=pyroscope-sor
    });
```

In the Pyroscope UI, you can then filter:

```
{service_name="pyroscope-bor", downstream="pyroscope-sor"}   → all SOR calls
{service_name="pyroscope-bor", endpoint="/triage", downstream="pyroscope-sor"} → triage's SOR calls
```

### Chained async calls

Labels propagate through `.compose()` and `.map()` chains:

```java
LabeledFuture.from(ctx, "pyroscope-sor",
        webClient.get(sorPort, "localhost", "/baseline").send())
    .compose(sorResponse -> {
        // ✅ Labels active — profiler sees this computation
        JsonObject baseline = sorResponse.bodyAsJsonObject();
        return webClient.post(apiPort, "localhost", "/render")
            .sendJsonObject(baseline);
    })
    .onSuccess(apiResponse -> {
        // ✅ Labels still active
        ctx.response().end(apiResponse.bodyAsJsonObject().encode());
    });
```

### Performance impact

| Operation | Cost |
|-----------|------|
| `LabeledFuture.from()` | One `RoutingContext.get()` + object allocation — nanoseconds |
| Callback label replay | One `ThreadLocal.set()` + callback + `ThreadLocal.remove()` — nanoseconds |
| Downstream overload | One extra `HashMap.put()` — nanoseconds |
| Memory | One wrapper object per async call, GC'd after callback completes |
| No agent attached | `NoClassDefFoundError` caught once, callback runs without labels — zero overhead |

No JNI, no bytecode manipulation, no reflection. The same `ThreadLocal` read/write
that Tier 1 already does.

### When to use LabeledFuture

| Scenario | Use LabeledFuture? |
|----------|--------------------|
| Tier 1 flame graphs show the bottleneck clearly | No — Tier 1 is sufficient |
| Bottleneck is inside `.onSuccess()` or `.compose()` | Yes — wrap that specific call |
| Want to know which downstream service is slow | Yes — use the `downstream` overload |
| Every function should use it by default | No — opt-in only, not a blanket requirement |

### What LabeledFuture does NOT solve

- **Automatic propagation** — you must explicitly wrap each async call. This is
  intentional: automatic instrumentation carries JNI overhead and fragility risks
  across Vert.x versions (see [async-profiler PR#576](https://github.com/async-profiler/async-profiler/pull/576)).
- **I/O wait time** — async I/O is non-blocking; the event loop is not consuming CPU
  while waiting for a network response. There is nothing to profile during the wait.
- **Sub-10ms resolution** — at 100Hz sampling (default), only callbacks that consume
  >10ms of CPU will reliably appear in profiles.

### Library structure

```
services/pyroscope-vertx/
├── build.gradle                                    # Java 11 compatible
└── src/main/java/com/pyroscope/vertx/
    └── LabeledFuture.java                          # Single class, ~120 lines of code
```

The library depends on `vertx-core`, `vertx-web`, and `io.pyroscope:agent` (compileOnly).
It is included in the Gradle build as `project(':pyroscope-vertx')` and any verticle
project can opt in by adding `implementation project(':pyroscope-vertx')` to its
dependencies.

---

## Alternative approaches

### OpenTelemetry span profiling

The `otel-profiling-java` package can annotate CPU samples with OTel span IDs,
allowing you to filter profiles for a specific trace span in Grafana.

**Limitations:**
- CPU profiling only (not memory or lock contention)
- Spans shorter than 10ms (default 100Hz sampling) may be missed entirely
- Requires OTel tracing infrastructure with correct Vert.x context propagation
- OTel context is also `ThreadLocal`-based — same propagation issue in reactive code

See [otel-profiling-java](https://github.com/grafana/otel-profiling-java) for setup.

### Virtual threads (Project Loom)

Vert.x 4.5+ supports virtual threads via `@RunOnVirtualThread`. Virtual threads
restore thread-per-request semantics, making labels and profiling work naturally.

**Caveats:**
- Requires JDK 21+ (this project deploys on temurin:21)
- async-profiler has known bugs with virtual threads on JDK 21; fixed in JDK 23.
  Workaround: `-XX:-DoJVMTIVirtualThreadTransitions`
  ([async-profiler#1096](https://github.com/async-profiler/async-profiler/issues/1096))
- Requires rewriting handlers from reactive to blocking style
- Best long-term solution but biggest migration effort

### Custom reactive code profiler

The Quarkus team built a dedicated
[Reactive Code Profiler](https://github.com/quarkusio/quarkus/issues/25712) that
intercepts Vert.x requests and Mutiny functional interfaces, transforms lambda names
to human-readable form, and maps async events to business operations. This bypasses
the sampling profiler entirely with custom instrumentation. This confirms the community
recognizes standard profiling tools are insufficient for reactive code.

---

## Recommended path forward

| Phase | Action | Effort | Value |
|-------|--------|--------|-------|
| **Tier 1 (done)** | Label handler in `AbstractFunctionVerticle` | Zero — automatic | Per-endpoint aggregate CPU, covers ~80% of CPU work |
| **Review** | Analyze flame graphs, identify if async callbacks are a bottleneck | Low | Determines if Tier 2 is needed for specific functions |
| **Tier 2 (available)** | Add `LabeledFuture` to specific hot functions | One line per async call | Per-endpoint attribution in async callbacks, downstream identification (~95% coverage) |
| **Long-term** | Evaluate virtual threads (JDK 23+) or OTel span profiling | High | Full per-request attribution (100%) |

---

## Resources and support

### Pyroscope and profiling

| Resource | URL |
|----------|-----|
| Pyroscope Java agent docs | https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/java/ |
| Pyroscope Labels API | https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/java/#add-profiling-labels-to-tracing-spans |
| async-profiler (underlying engine) | https://github.com/async-profiler/async-profiler |
| async-profiler manual (by use case) | https://krzysztofslusarski.github.io/2022/12/12/async-manual.html |
| otel-profiling-java (span profiles) | https://github.com/grafana/otel-profiling-java |

### Known issues and community discussions

| Issue | Summary |
|-------|---------|
| [pyroscope-java#237](https://github.com/grafana/pyroscope-java/issues/237) | Label propagation to async worker threads — maintainer confirms no solution |
| [async-profiler PR#576](https://github.com/async-profiler/async-profiler/pull/576) | Context ID for reactive code — closed, JNI overhead too high |
| [async-profiler#1096](https://github.com/async-profiler/async-profiler/issues/1096) | Virtual thread profiling bugs on JDK 21 |
| [async-profiler#758](https://github.com/async-profiler/async-profiler/issues/758) | Method mis-attribution on certain JDK versions |
| [quarkus#25712](https://github.com/quarkusio/quarkus/issues/25712) | Quarkus Reactive Code Profiler — custom instrumentation for reactive |
| [pyroscope-java#103](https://github.com/grafana/pyroscope-java/issues/103) | Thread-level profiling support request |

### Framework-specific

| Resource | URL |
|----------|-----|
| Vert.x Context documentation | https://vertx.io/docs/vertx-core/java/#_the_context_object |
| Go pprof labels | https://pkg.go.dev/runtime/pprof#Do |
| Python Pyroscope SDK | https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/python/ |

---

## Cross-references

- [configuration-reference.md](configuration-reference.md) — Agent properties and environment variables
- [deployment-guide.md Section 15](deployment-guide.md#15-agent-instrumentation) — Agent configuration on OCP pods
- [tls-setup.md](tls-setup.md) — Agent HTTPS trust configuration
- code-to-profiling-guide.md (available in the repo at docs/code-to-profiling-guide.md) — Source code to flame graph mapping

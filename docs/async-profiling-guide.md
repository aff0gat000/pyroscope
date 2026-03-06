# Profiling Asynchronous Frameworks

Why continuous profiling is harder with reactive/async frameworks like Vert.x, and
how Pyroscope labels solve it.

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
YourKit, VisualVM) when used with async frameworks.

---

## The solution: Pyroscope labels

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

### What does NOT get labeled (and why that is OK)

Async callbacks (`.onSuccess()`, `.onComplete()`) execute **after** the label scope ends.
These callbacks are typically:

- I/O completion handlers (response arrived from network)
- Future composition (`.map()`, `.compose()`)
- Response writing (`ctx.response().end()`)

This is acceptable because:

1. **CPU time is in the synchronous path.** JSON parsing, computation, and request
   construction dominate CPU. Async callbacks are cheap (they just move data).
2. **I/O waiting is non-blocking.** The event loop thread is not consuming CPU while
   waiting for a network response — there is nothing to profile.
3. **The Pyroscope UI shows cumulative CPU time.** Even without async callback labeling,
   you see which endpoint is spending the most CPU in its synchronous handler.

If you need async-boundary labeling (rare), see
[Advanced: async label propagation](#advanced-async-label-propagation) below.

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

## When to build a shared library

| Signal | Action |
|--------|--------|
| Single language (Java), single framework (Vert.x) | Handler in `AbstractFunctionVerticle` — no library needed |
| 2-3 services in different frameworks but same language | Shared JAR with middleware adapters |
| Multiple languages (Java + Go + Python) | Per-language thin libraries + one shared labeling strategy doc |
| Enterprise-wide adoption (50+ services) | Published internal package with versioning and docs |

For this project, the handler in `AbstractFunctionVerticle` covers all 11 verticles
with zero per-verticle changes. A separate library is premature until a second
language/framework is involved.

---

## Advanced: async label propagation

For cases where you need labels on async callbacks (rare), use Vert.x's `Context`
to carry labels through the event loop:

```java
// Set labels on Vert.x context in middleware
router.route().handler(ctx -> {
    ctx.put("pyroscope.labels", Map.of(
        "endpoint", ctx.request().path(),
        "function", System.getenv("FUNCTION")
    ));
    ctx.next();
});

// Re-apply labels in async callbacks
webClient.get("/api").send().onSuccess(response -> {
    Map<String, String> labels = ctx.get("pyroscope.labels");
    Pyroscope.LabelsWrapper.run(new LabelsSet(labels), () -> {
        // Process response with labels active
        processResponse(response);
    });
});
```

This approach requires wrapping each async callback, so it is more invasive. Only
use it if you have significant CPU work happening inside async callbacks (e.g.,
heavy JSON processing in `.onSuccess()` handlers).

---

## Resources and support

| Resource | URL |
|----------|-----|
| Pyroscope Java agent docs | https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/java/ |
| Pyroscope Labels API | https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/java/#add-profiling-labels-to-tracing-spans |
| Vert.x Context documentation | https://vertx.io/docs/vertx-core/java/#_the_context_object |
| async-profiler (underlying engine) | https://github.com/async-profiler/async-profiler |
| Go pprof labels | https://pkg.go.dev/runtime/pprof#Do |
| Python Pyroscope SDK | https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/python/ |

---

## Cross-references

- [configuration-reference.md](configuration-reference.md) — Agent properties and environment variables
- [deployment-guide.md Section 15](deployment-guide.md#15-java-agent-configuration-ocp-pods) — Agent configuration on OCP pods
- [tls-setup.md](tls-setup.md) — Agent HTTPS trust configuration
- [code-to-profiling-guide.md](code-to-profiling-guide.md) — Source code to flame graph mapping

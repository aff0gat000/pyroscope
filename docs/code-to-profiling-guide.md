# Code-to-Profiling Correlation Guide

Maps Java source code to Pyroscope flame graph frames. Use this to correlate code with profiling data when debugging performance issues.

## How Pyroscope Works With This Codebase

Pyroscope attaches as a Java agent (`-javaagent:pyroscope.jar`) to every service via `JAVA_TOOL_OPTIONS` in `docker-compose.yaml`. It uses JFR (Java Flight Recorder) to continuously sample what each thread is doing and sends that data to the Pyroscope server. No code changes are needed.

Each service reports under a unique application name (e.g., `bank-payment-service`, `bank-faas-server`). Pyroscope captures four profile types simultaneously:

| Profile Type | What It Samples | Flame Graph Shows |
|---|---|---|
| **CPU** (`process_cpu`) | Which methods are on-CPU | Computation hotspots — tall stacks = deep call chains |
| **Wall Clock** (`wall`) | All threads regardless of state | Real elapsed time including sleeps, I/O, locks |
| **Allocation** (`memory:alloc`) | Where `new` objects are created | GC pressure sources — wide frames = many allocations |
| **Mutex** (`mutex`) | Threads blocked on `synchronized` / locks | Contention points — wide frames = long waits |

## Source Code → Flame Graph Mapping

Every method in the source code can appear as a frame in the flame graph. The frame label is `com.example.ClassName.methodName`. The width of a frame indicates how much of that resource (CPU time, allocations, lock wait time) the method consumed.

### Payment Service (`PaymentVerticle.java`)

#### `sha256()` — line 262

```java
// Unoptimized: creates a new MessageDigest instance per call
MessageDigest md = MessageDigest.getInstance("SHA-256");
byte[] hash = md.digest(input.getBytes());
StringBuilder sb = new StringBuilder();
for (byte b : hash) sb.append(String.format("%02x", b));
```

**CPU profile:** Look for `PaymentVerticle.sha256` → `MessageDigest.getInstance` → `Provider.getService`. The `getInstance` call searches the security provider list every time. In the optimized path (`sha256Optimized`, line 275), a `ThreadLocal<MessageDigest>` is reused, and `getInstance` disappears from the flame graph.

**Allocation profile:** `String.format("%02x", b)` creates a new `Formatter`, `StringBuilder`, and autoboxes the byte for every byte in the hash (32 times per call). The optimized version uses `Character.forDigit` which allocates nothing.

**What to look for in Grafana:** Select `bank-payment-service` → CPU profile → search for `sha256`. Compare flame graph width with `OPTIMIZED=true` vs default. The `getInstance` and `String.format` frames shrink or vanish.

#### `handlePayroll()` — line 127

```java
private synchronized void handlePayroll(RoutingContext ctx) {
    for (int i = 0; i < employees; i++) {
        BigDecimal salary = BigDecimal.valueOf(...);
        BigDecimal withholding = salary.multiply(new BigDecimal("0.22"), MathContext.DECIMAL128);
        String sig = sha256(txnId + "|" + net + "|" + i);
        ledger.put(txnId, entry);
    }
}
```

**Mutex profile:** The entire method is `synchronized`. Under concurrent load (multiple `/payment/payroll` requests), threads queue up waiting for the lock. Look for `PaymentVerticle.handlePayroll` as a wide frame in the mutex profile — its width is proportional to how long threads waited to enter.

**CPU profile:** `BigDecimal.multiply` with `MathContext.DECIMAL128` and `sha256()` inside a 200–500 iteration loop. Look for a tall stack: `handlePayroll` → loop body → `BigDecimal.multiply` → `BigDecimalLayoutForm` and `sha256` → `MessageDigest`.

**Allocation profile:** Each loop iteration creates `BigDecimal` objects, `LinkedHashMap` entries, and `String` concatenations for `sha256()`. Visible as wide `handlePayroll` frames with `BigDecimal.<init>` and `LinkedHashMap.put` underneath.

#### `handleTransfer()` — line 99

```java
synchronized (ledger) {
    Map<String, Object> entry = new LinkedHashMap<>();
    // ... populate entry ...
    ledger.put(txnId, entry);
}
```

**Mutex profile:** `synchronized (ledger)` creates contention when multiple transfers run concurrently. The frame `PaymentVerticle.handleTransfer` appears in the mutex profile, with width indicating wait time.

### Order Service (`OrderVerticle.java`)

#### `buildOrder()` — line 129

```java
String item = "";
item += "product-" + rng.nextInt(200);
item += "|qty=" + (1 + rng.nextInt(20));
item += "|price=" + String.format("%.2f", ...);
```

**Allocation profile:** String concatenation with `+=` in a loop creates intermediate `StringBuilder` and `String` objects that become garbage immediately. Look for `OrderVerticle.buildOrder` with `StringBuilder.<init>` and `String.concat` frames underneath. The `String.format("%.2f")` call adds `Formatter` allocations on top.

#### `processOrdersSynchronized()` — line 160

```java
private synchronized void processOrdersSynchronized() {
    for (String id : toProcess) {
        String[] parts = item.split("\\|");
        // ... parse prices ...
    }
    sleep(20 + rng.nextInt(40));
}
```

**Mutex profile:** The `synchronized` keyword on the method means only one thread can process orders at a time. Under load, this shows as a wide `processOrdersSynchronized` frame in the mutex profile.

**Wall profile:** The `sleep()` call at line 190 adds 20–60 ms of wall time per invocation. This appears in wall profiles but NOT in CPU profiles, since the thread is sleeping. Look for `Thread.sleep` under `processOrdersSynchronized` in the wall profile.

**CPU profile:** `String.split("\\|")` compiles a regex pattern per call. Visible as `Pattern.compile` → `Pattern.matcher` frames under `processOrdersSynchronized`.

#### `validateOrder()` — line 222

```java
if (!id.matches("ORD-\\d+")) return false;
if (!customer.matches("customer-\\d+")) return false;
```

**CPU profile:** `String.matches()` compiles a new `Pattern` object every call. Under load (validating 500 orders per request), this creates 1000 `Pattern.compile` calls. Look for `OrderVerticle.validateOrder` → `Pattern.compile` → `Pattern.<init>`. The optimized fix would precompile patterns as `static final Pattern` fields.

### Notification Service (`NotificationVerticle.java`)

#### `handleRender()` — template rendering

```java
String.format("Dear %s, your transfer of $%s has been completed. Reference: %s. ...", args...)
```

**Allocation profile:** `String.format` creates a `Formatter` object, an internal `StringBuilder`, and the resulting `String` for each notification. When rendering hundreds of notifications in `handleBulk`, this produces heavy allocation pressure. Look for `NotificationVerticle.handleRender` or `handleBulk` → `String.format` → `Formatter.<init>`.

#### `handleDrain()` — queue processing with retry

**Wall profile:** Retry logic with `Thread.sleep` for exponential backoff. These appear as idle wall-clock time. In the wall profile, look for `handleDrain` → `Thread.sleep` — these frames are invisible in CPU profiles.

### Fraud Service (`FraudDetectionVerticle.java`)

#### Precompiled patterns — line 31

```java
private static final Pattern[] SUSPICIOUS_PATTERNS = {
    Pattern.compile("^(TXN|PAY)-\\d{1,3}$"),
    // ...
};
```

**CPU profile:** Because patterns are precompiled as `static final`, the `Pattern.compile` cost is paid once at class load, not per request. The fraud service `handleScan` shows `Matcher.matches` but NOT `Pattern.compile` in CPU profiles. Compare this to `OrderVerticle.validateOrder` which compiles patterns per call — the difference is visible in the flame graph.

### FaaS Server (`FaasVerticle.java`)

The FaaS server is unique because every function invocation deploys a new verticle, executes it, then undeploys it. This makes the Vert.x deployment infrastructure itself visible in flame graphs.

#### Deploy/undeploy lifecycle

**CPU profile:** Each invocation shows:
```
FaasVerticle.handleInvoke
  └─ Vertx.deployVerticle
       └─ VertxImpl.deployVerticle
            └─ DeploymentManager.doDeploy
                 └─ ClassLoader.loadClass  (cold deploy)
  └─ Vertx.undeploy
       └─ DeploymentManager.doUndeploy
```

The `deployVerticle` and `undeploy` frames disappear when using warm pools (`OPTIMIZED=true`), because the verticle is already deployed and reused.

#### Function-specific signatures

| Function | CPU Profile | Allocation Profile | Wall Profile |
|---|---|---|---|
| `fibonacci` | Deep recursive stack: `fibonacci$compute` repeated 30+ levels | Minimal — primitive recursion | Same as CPU (compute-bound) |
| `transform` | Flat — mostly in `JsonObject.put` | Heavy — `HashMap`, `ArrayList`, `String` objects | Same as CPU |
| `hash` | `MessageDigest.digest` in tight loop | `byte[]` arrays per iteration | Same as CPU |
| `sort` | `Arrays.sort` → `TimSort.mergeSort` | `String[]` and `ArrayList` from dataset generation | Same as CPU |
| `sleep` | Nearly invisible | Nearly invisible | Wide `Thread.sleep` frame |
| `matrix` | `matrixMultiply` with nested loops | `double[][]` array allocation | Same as CPU |
| `regex` | `Pattern.matcher` → `Matcher.matches` | `Matcher` and `String` objects | Same as CPU |
| `compress` | `GZIPOutputStream.write` → `Deflater` | `byte[]` buffers | Same as CPU |
| `primes` | Tight loop in sieve | `boolean[]` array (one large allocation) | Same as CPU |
| `contention` | Minimal — tight compute loop | Minimal | `synchronized` lock wait frames — primary mutex data source |
| `fanout` | Multiple `deployVerticle` calls in parallel | Deployment overhead objects | Longer than CPU — includes deploy wait time |

#### Burst endpoint — concurrent contention

`POST /fn/burst/hash?count=10` deploys 10 hash verticles simultaneously.

**Mutex profile:** `DeploymentManager` internal locks during concurrent deployment. Look for `VertxImpl.deployVerticle` contention frames when burst count is high.

**CPU profile:** Thread pool saturation — the Vert.x worker pool has limited threads. With 10 concurrent deploys, some block waiting for a thread. Visible as wider `WorkerPool.execute` frames.

## Diagnostic Procedures

### 1. High CPU usage

**Symptom:** Process CPU metric in Grafana above 80%.

**Procedure:**
1. Open the service's flame graph in Grafana → select **CPU** profile type.
2. Look for the widest frame at the bottom of the graph — this is where CPU time is spent.
3. Trace upward to find the application method responsible.

**Example:** `bank-payment-service` shows `PaymentVerticle.sha256` → `MessageDigest.getInstance` consuming 30% of CPU. The fix: set `OPTIMIZED=true` to switch to `ThreadLocal<MessageDigest>` reuse. Verify by comparing flame graphs before and after — `getInstance` should disappear.

### 2. High latency with low CPU

**Symptom:** Response times are slow but CPU is under 20%.

**Procedure:**
1. Switch to the **Wall Clock** profile. Wall captures time regardless of thread state.
2. Compare wall profile to CPU profile. Methods present in wall but absent in CPU are off-CPU bottlenecks (sleeping, waiting for I/O, blocked on locks).
3. Look for `Thread.sleep`, `Object.wait`, `LockSupport.park`, or I/O frames.

**Example:** `bank-order-service` `/order/fulfill` shows high wall time but low CPU. Wall profile reveals `Thread.sleep` in `executeBlocking` → the simulated inventory/payment/shipping steps have artificial latency. In production, this pattern points to slow downstream services or database queries.

### 3. High GC pauses

**Symptom:** GC Pause Rate panel in Grafana shows frequent pauses; JVM Heap Used is sawtoothing.

**Procedure:**
1. Switch to the **Allocation** (`alloc`) profile type.
2. The widest frames show where the most bytes are being allocated.
3. Reduce allocations at those points (reuse objects, use primitives, avoid `String.format` in loops).

**Example:** `bank-notification-service` allocation profile shows `handleBulk` → `String.format` → `Formatter.<init>` dominating. Each bulk send creates thousands of `Formatter` objects. Fix: use `StringBuilder` directly instead of `String.format`, or pre-build templates.

### 4. Thread contention / serialization

**Symptom:** Throughput plateaus despite available CPU. Thread count is high.

**Procedure:**
1. Switch to the **Mutex** profile type.
2. Look for wide frames — these are methods where threads waited to acquire a lock.
3. The method holding the lock is one frame above the contention frame.

**Example:** `bank-order-service` mutex profile shows `processOrdersSynchronized` as a wide frame. The `synchronized` keyword on the method means only one thread can process orders at a time. Fix: switch to `processOrdersOptimized` (lock-free `computeIfPresent`) via `OPTIMIZED=true`. The mutex frame vanishes.

### 5. Cold-start overhead (FaaS server)

**Symptom:** First invocations of FaaS functions are slower than subsequent ones.

**Procedure:**
1. Look at the FaaS server CPU profile.
2. Find `deployVerticle` → `ClassLoader.loadClass` frames — these are cold-start costs.
3. Compare with warm pool enabled: `POST /fn/warmpool/hash?size=5`, then invoke. The deploy frames disappear.

## Reducing MTTR With Profiling Data

Continuous profiling reduces MTTR by cutting out the investigation gap between detecting a symptom and finding the root cause.

### Detection → Diagnosis

Without profiling, diagnosis requires reading code, adding logging, redeploying, and waiting for reproduction. With continuous profiling:

1. **Alert fires** (e.g., high p99 latency on payment service).
2. **Open Grafana** → Payment service dashboard → Flame graph panel.
3. **Select the time range** matching the alert.
4. **Switch profile types** to narrow down the bottleneck:
   - CPU elevated → computation bottleneck.
   - Wall elevated, CPU flat → off-CPU issue (I/O, sleep, external dependency).
   - Alloc elevated → GC pressure. Identify the allocation source.
   - Mutex elevated → lock contention. Identify the synchronized block.
5. **Read the frame names** — they are fully qualified Java method names. Go directly to that line in the source code.

### Diagnosis → Fix

The flame graph identifies both the slow method and the underlying cause:

| Flame Graph Finding | Root Cause | Fix Pattern |
|---|---|---|
| `MessageDigest.getInstance` in hot path | Security provider lookup per call | Cache in `ThreadLocal` or instance field |
| `Pattern.compile` in loop | Regex compilation per iteration | Precompile as `static final Pattern` |
| `String.format` in bulk operation | `Formatter` object churn | Use `StringBuilder` directly |
| `synchronized` method with wide mutex frame | Coarse-grained locking | Use `ConcurrentHashMap.computeIfPresent` or finer locks |
| `Thread.sleep` in wall profile | Simulated latency / backoff | Reduce sleep, use async timers |
| `deployVerticle`/`undeploy` frames | Cold-start overhead | Use warm pools or persistent deployments |

### Fix Validation

After deploying a fix:

1. Open the same flame graph view for the same service.
2. Compare the current time range to the pre-fix time range (use Grafana's time shift or split view).
3. The problematic frame should be narrower (less time spent) or gone entirely.
4. Confirm the metric (CPU usage, p99 latency, GC pause rate) has improved in the corresponding Prometheus panel.

### Comparing optimized vs unoptimized

Every service supports `OPTIMIZED=true`. Use `scripts/run.sh optimize` and `scripts/run.sh unoptimize` to toggle modes on running containers. Then compare flame graphs side by side:

- **Payment:** `sha256` frame shrinks (ThreadLocal reuse vs getInstance per call).
- **Order:** `processOrdersSynchronized` mutex contention disappears (lock-free path).
- **FaaS:** `deployVerticle`/`undeploy` frames vanish (warm pool reuse).

## Quick Reference: Service → Code → Profile Type

| Service | Endpoint | Source Method | Profile Type | Flame Graph Signature |
|---|---|---|---|---|
| Payment | `/payment/transfer` | `handleTransfer` (line 99) | CPU, Mutex | `sha256` CPU burn; `synchronized(ledger)` contention |
| Payment | `/payment/payroll` | `handlePayroll` (line 127) | Mutex, Alloc | Entire method locked; BigDecimal + Map allocations |
| Payment | `/payment/fx` | `handleFxConversion` (line 154) | CPU, Alloc | `BigDecimal.multiply` loop; 20-hop conversion chain |
| Payment | `/payment/orchestrate` | `handleOrchestration` (line 172) | Wall | Fan-out with `Thread.sleep` — visible in wall only |
| Order | `/order/create` | `buildOrder` (line 129) | Alloc | String `+=` concatenation creates garbage |
| Order | `/order/process` | `processOrdersSynchronized` (line 160) | Mutex, Wall | `synchronized` blocks threads; `sleep()` adds wall time |
| Order | `/order/validate` | `validateOrder` (line 222) | CPU | `String.matches` recompiles regex per call |
| Notification | `/notify/bulk` | `handleBulk` | Alloc | `String.format` per message creates Formatter objects |
| Notification | `/notify/drain` | `handleDrain` | Wall | Retry backoff with `Thread.sleep` |
| Fraud | `/fraud/scan` | `handleScan` | CPU | Precompiled `Pattern.matches` — efficient baseline |
| FaaS | `/fn/invoke/*` | `handleInvoke` | CPU | `deployVerticle`/`undeploy` lifecycle frames |
| FaaS | `/fn/burst/*` | `handleBurst` | Mutex, CPU | Concurrent deployment lock contention |

## Grafana Navigation

1. Select the service from the dashboard list (e.g., "FaaS Server", "Service Performance").
2. Review metric panels: request rate, response time, JVM heap, GC pauses, threads, CPU.
3. Scroll to the flame graph panel at the bottom of each dashboard.
4. Switch the `profile_type` dropdown between CPU, alloc, mutex, and wall.
5. Click a frame to zoom into that subtree. Click the root frame to reset.
6. Search (magnifying glass) for a method name to highlight it across the graph.
7. Adjust the time range to compare before/after a deploy or incident.

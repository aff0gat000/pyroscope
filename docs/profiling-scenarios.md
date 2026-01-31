# Profiling Scenarios

Use Pyroscope in Grafana to identify performance issues across CPU, memory, and lock contention.

Each scenario follows the same pattern: observe a symptom in metrics panels, then switch to a Pyroscope flame graph to find the root cause.

## Prerequisites

- Stack running with load generation active (`bash scripts/run.sh`).
- Grafana accessible at `http://localhost:3000`.
- For related documentation, see [dashboard-guide.md](dashboard-guide.md) and [mttr-guide.md](mttr-guide.md).

## Scenario 1: CPU hotspot from a recursive algorithm

**Symptom:** The API Gateway has high CPU usage relative to other services.

**Investigate with metrics:**

1. Open the **Service Performance** dashboard.
2. Check **Request Rate by Service**. All services receive similar traffic.
3. Check **Avg Latency by Service**. The `api-gateway` latency is noticeably higher on the `/cpu` endpoint.
4. Metrics confirm the problem exists but do not explain the cause.

**Investigate with the flame graph:**

5. On the same dashboard, scroll to the **Flame Graph** panel, or open **Pyroscope Java Overview**.
6. Set `pyroscope_app` to `bank-api-gateway`.
7. Set `profile_type` to `cpu`.
8. Look for the widest bar near the top of the graph.

**Expected flame graph:**

```
MainVerticle.handleCpu()
  └── MainVerticle.fibonacci()
        ├── MainVerticle.fibonacci()     ← recursive call (wide)
        │     └── MainVerticle.fibonacci()
        └── MainVerticle.fibonacci()     ← recursive call (wide)
```

The `fibonacci()` frame dominates CPU time. The recursion is visible as nested calls of the same function, indicating O(2^n) complexity.

**Root cause:** Recursive Fibonacci implementation. Each call spawns two additional calls.

**Verification:** Deploy with `OPTIMIZED=true` (uses an iterative version), then compare the flame graph. The `fibonacci` frame shrinks dramatically. Use the **Before vs After Fix** dashboard to view both side by side.

## Scenario 2: Hidden per-request overhead from a crypto provider lookup

**Symptom:** The payment service has higher CPU usage than expected for its traffic volume.

**Investigate with the flame graph:**

1. Open **Pyroscope Java Overview**.
2. Set `application` to `bank-payment-service`.
3. Set `profile_type` to `cpu`.

**Expected flame graph:**

```
PaymentVerticle.handleTransfer()
  └── PaymentVerticle.sha256()
        ├── MessageDigest.getInstance("SHA-256")   ← 18% self-time
        ├── MessageDigest.digest()                  ← 12% self-time (expected)
        └── String.format("%02x", b)               ← 4% self-time
```

`MessageDigest.getInstance()` is wide because it performs a JCE security provider registry lookup on every request. This lookup should happen once and be reused. `String.format` boxes each byte into an `Integer` for hex formatting, adding unnecessary allocation and CPU overhead.

**Root cause:** Per-request provider lookup combined with autoboxing in a tight loop. Neither issue is obvious from code review alone.

**Key takeaway:** Flame graphs expose overhead hidden inside JDK library calls. The application code did not implement `MessageDigest.getInstance()`, but it pays for the cost on every request.

## Scenario 3: Memory allocation pressure from String.format

**Symptom:** The notification service has frequent GC pauses visible in the JVM Metrics dashboard as a high GC collection duration rate.

**Investigate with metrics:**

1. Open **JVM Metrics Deep Dive**. Confirm a high GC rate for `notification-service`.
2. The heap panel shows a rapid sawtooth pattern: memory fills quickly and GC runs frequently.
3. Something is allocating at a high rate, but the metrics do not identify the source.

**Investigate with the allocation flame graph:**

4. Open **Pyroscope Java Overview**.
5. Set `application` to `bank-notification-service`.
6. Set `profile_type` to `alloc (memory)`.

**Expected flame graph:**

```
NotificationVerticle.handleRender()
  └── NotificationVerticle.renderTemplate()
        └── String.format()
              ├── Formatter.format()          ← wide bar
              │     └── Formatter.parse()
              └── new Object[]{}              ← varargs array allocation
```

`String.format()` and `Formatter` dominate the allocation profile. Every template render creates multiple intermediate `String` objects, a `Formatter` instance, and a varargs `Object[]` array.

**Root cause:** `String.format()` called in a hot loop. Each invocation allocates temporary objects that become garbage immediately.

**Fix pattern:** Replace with `StringBuilder` and manual substitution. The optimized version (`OPTIMIZED=true`) applies this change, and the allocation flame graph flattens to a single `StringBuilder` buffer resize.

**Correlation technique:** Open two browser tabs side by side: JVM Metrics (GC rate) and Pyroscope Overview (alloc profile). The GC rate shows the severity of the problem. The allocation flame graph identifies which function to fix.

## Scenario 4: Lock contention from synchronized methods

**Symptom:** Order service latency increases under load, but CPU stays low.

Low CPU combined with high latency typically indicates threads are waiting rather than working.

**Investigate with metrics:**

1. Open **HTTP Performance**. Confirm that order-service latency is high.
2. Open **JVM Metrics Deep Dive**. CPU is low (~15%) and thread count may be elevated.
3. Low CPU with high latency indicates threads are blocked.

**Investigate with the mutex flame graph:**

4. Open **Pyroscope Java Overview**.
5. Set `application` to `bank-order-service`.
6. Set `profile_type` to `mutex (lock)`.

**Expected flame graph:**

```
OrderVerticle.handleProcess()
  └── OrderVerticle.processOrdersSynchronized()     ← wide bar
        └── java.lang.Object.wait()                  ← threads waiting for the lock
```

The `processOrdersSynchronized` frame is wide in the mutex profile. This `synchronized` method forces all concurrent requests through a single lock. Under load, threads queue up waiting.

**Root cause:** The `synchronized` method serializes all order processing. Only one thread can execute at a time.

**Fix pattern:** Replace with `ConcurrentHashMap.computeIfPresent()` for lock-free updates. After the fix, the mutex flame graph flattens and contention disappears.

**Key takeaway:** This issue is invisible in CPU profiles. CPU is low because threads are sleeping, not computing. Only the mutex profile type reveals it.

## Scenario 5: Before and after comparison

**Use case:** Verify that a deployed fix reduced resource consumption using profiling data rather than assumptions.

The **Before vs After Fix** dashboard is already provisioned in Grafana. No additional setup is required. The `compare` command automates the two-phase load generation, or you can use the default pipeline which handles both phases.

**Option A: Automated comparison on a running stack**

1. Run `bash scripts/run.sh compare`. This generates load against the unoptimized services, restarts them with `OPTIMIZED=true`, then generates load again.
2. Note the timestamps printed in the terminal output for each phase.

**Option B: Full pipeline (handles everything automatically)**

1. Run `bash scripts/run.sh`. The default pipeline deploys, generates load, and validates.
2. Run `bash scripts/run.sh --fixed` to redeploy with optimizations and generate a second round of load.

**Option C: Manual comparison**

1. With the stack running, generate load: `bash scripts/run.sh load 60`.
2. Note the start and end time (Phase 1: unoptimized).
3. Redeploy with fixes: `COMPOSE_EXTRA_FILES=docker-compose.fixed.yml bash scripts/deploy.sh`.
4. Generate load again: `bash scripts/run.sh load 60`.
5. Note the start and end time (Phase 2: optimized).

**View results in Grafana:**

1. Open the **Before vs After Fix** dashboard at `http://localhost:3000/d/before-after-comparison`.
2. Set the Grafana time range to cover both phases (for example, "Last 1 hour").
3. Set `application` to the service to investigate (for example, `bank-payment-service`).
4. Set `profile_type` to the relevant type (for example, `cpu` for the `sha256` fix).
5. Adjust the **Before Fix** panel's time override to cover Phase 1, and the **After Fix** panel to cover Phase 2.

**Expected result:**

Two flame graph panels appear side by side:

- **Before Fix:** `sha256()` calls `MessageDigest.getInstance()`, which appears as a wide bar at approximately 18% of CPU.
- **After Fix:** `sha256Optimized()` shows only `MessageDigest.digest()`. The `getInstance()` frame is gone.

The CPU and Heap metrics panels below show the aggregate impact across all seven services over time.

**What each optimization changes:**

| Service | Fix applied | Flame graph impact |
|---|---|---|
| API Gateway | `fibonacci()` replaced with iterative loop | `fibonacci` frame: dominant to near-zero |
| Order Service | `processOrders()` replaced with lock-free `computeIfPresent` | Lock contention frames disappear |
| Payment Service | `sha256()` replaced with ThreadLocal + `Character.forDigit` | `getInstance` and `String.format` frames vanish |
| Fraud Service | Percentile sort replaced with primitive `double[]` + `Arrays.sort` | `Double.compareTo` boxing eliminated |
| Notification Service | `renderTemplate()` replaced with StringBuilder + `indexOf` | `Formatter.format` frames disappear |

**Why this matters:** Before-and-after flame graph screenshots provide concrete evidence for pull request reviews, incident postmortems, and stakeholder communication. The data shows that a specific function went from 18% CPU to 0%, replacing guesswork with measurement.

## Scenario 6: Cross-referencing profile types

**Use case:** A service is slow, but the bottleneck type (CPU, memory, or locks) is unknown.

**Steps:**

1. Open **Pyroscope Java Overview**.
2. Select the affected service.
3. Cycle through each profile type using the `profile_type` dropdown.

| Profile type | Indicator | If the flame graph is flat |
|---|---|---|
| `cpu` | Wide bars indicate a computation bottleneck | CPU is not the problem |
| `alloc (memory)` | Wide bars indicate a GC pressure source | Allocation rates are reasonable |
| `mutex (lock)` | Wide bars indicate thread contention | No lock contention exists |

**Decision matrix:**

| CPU | Alloc | Mutex | Diagnosis |
|---|---|---|---|
| Hot | Flat | Flat | Pure computation problem. Optimize the algorithm. |
| Flat | Hot | Flat | GC pressure. Reduce allocations or reuse objects. |
| Flat | Flat | Hot | Lock contention. Reduce `synchronized` scope or use concurrent data structures. |
| Hot | Hot | Flat | Computation creating temporary objects. Optimize both. |
| Flat | Flat | Flat | Off-CPU bottleneck. Check for network I/O, external service calls, or `Thread.sleep`. |

This is the core profiling workflow: triangulate across profile types to classify the bottleneck before attempting a fix.

## Reference: Reading flame graphs

| Concept | Meaning |
|---|---|
| Width | Proportion of the resource consumed (CPU time, allocations, or lock wait time). |
| Depth (vertical) | Call stack depth. Deeper frames indicate more nested calls. |
| Top of graph | Leaf functions performing the actual work. Start reading here. |
| Bottom of graph | Entry points such as `main`, the event loop, or the HTTP handler. |
| Color | No semantic meaning in Pyroscope. Colors are assigned for visual distinction. |
| Self time | Time in the function itself, excluding callees. A wide bar with no children means the function itself is expensive. |
| Total time | Time including all callees. A wide bar with many children means the function calls expensive code. |

**Sandwich view:** Click a function name to see all callers above and all callees below. This is useful when the same function is called from multiple locations.

**Diff view:** Available in the Before vs After dashboard. Red indicates increased resource usage; green indicates decreased usage.

## Reference: Grafana dashboard navigation

| Investigation goal | Dashboard | Profile type |
|---|---|---|
| High CPU usage | Pyroscope Java Overview | `cpu` |
| Frequent GC or memory pressure | Pyroscope Java Overview | `alloc (memory)` |
| High latency with low CPU | Pyroscope Java Overview | `mutex (lock)` |
| Identify the worst-performing service | Service Performance | Metrics panels, then flame graph |
| Verify a fix | Before vs After Fix | Match the profile type to the fix |
| Compare two services side by side | Service Comparison | CPU flame graphs for both services |
| JVM health overview | JVM Metrics Deep Dive | Prometheus metrics only |
| Endpoint-level latency breakdown | HTTP Performance | Prometheus metrics only |

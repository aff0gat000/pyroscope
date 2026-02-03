# Continuous Profiling with Pyroscope — Implementation Runbook

A step-by-step guide to implementing Pyroscope for continuous profiling of Java services, using the Java agent (zero code changes). Covers deployment, configuration, UI usage, production use cases, MTTR reduction, and operational cost.

---

## What is Continuous Profiling

Continuous profiling samples what every thread in a running application is doing — which methods consume CPU, where memory is allocated, and where threads wait on locks — and records this data over time. Unlike traditional profiling (attach a debugger, reproduce the issue, detach), continuous profiling runs permanently in production with low overhead, capturing data before an incident occurs.

The output is a **flame graph**: a visualization where each horizontal bar represents a function, and its width represents the proportion of the sampled resource (CPU time, allocation bytes, lock wait time) consumed by that function. Wider bars indicate higher resource consumption.

### What continuous profiling answers

| Question | Profile Type | Without Profiling |
|----------|-------------|-------------------|
| Which method is burning CPU? | CPU | Guess from metrics, add logging, redeploy |
| What is allocating memory and driving GC pauses? | Allocation | Heap dump analysis (disruptive, point-in-time) |
| Where are threads blocked on locks? | Mutex | Thread dump analysis (point-in-time, manual) |
| What is the real elapsed time including I/O waits? | Wall clock | Distributed tracing (shows service boundaries, not internal code paths) |

### How it differs from other observability signals

| Signal | Shows | Does Not Show |
|--------|-------|---------------|
| **Metrics** (Prometheus) | Resource consumption rates (CPU %, heap bytes, request latency) | Which function or code path caused the consumption |
| **Logs** | Application-level events and errors | Runtime behavior of code that does not log |
| **Traces** (Jaeger, Tempo) | Request flow across services, per-span latency | Internal CPU/memory/lock behavior within a service |
| **Continuous Profiling** (Pyroscope) | Exact function-level resource consumption over time | Request-level correlation (use traces for that) |

Metrics show which resource is elevated. Profiling shows which code path is responsible.

---

## How Pyroscope Works

Pyroscope uses [async-profiler](https://github.com/async-profiler/async-profiler) under the hood, which attaches to the JVM via JVMTI. It uses `AsyncGetCallTrace` for stack sampling (avoids safepoint bias) and `perf_events` or `itimer` signals for CPU sampling.

The Java agent:
1. Attaches at JVM startup via `-javaagent:pyroscope.jar`
2. Periodically samples thread stacks (default ~100 Hz for CPU)
3. Aggregates samples into flame graph data
4. Compresses and pushes profile data to the Pyroscope server over HTTP

No application code changes, bytecode modification, or recompilation is required.

### Profile types captured

| Profile Type | JFR Event | What It Captures | Sampling Mechanism |
|-------------|-----------|------------------|-------------------|
| **CPU** (`process_cpu`) | `itimer` / `cpu` | Methods actively executing on CPU | Timer signal interrupts at ~100 Hz |
| **Wall clock** (`wall`) | `wall` | All threads regardless of state (running, sleeping, blocked) | Timer signal at ~100 Hz across all threads |
| **Allocation** (`memory:alloc`) | `alloc` | Where `new` objects are allocated | TLAB (Thread-Local Allocation Buffer) callback at configurable threshold |
| **Mutex** (`mutex`) | `lock` | Threads blocked on `synchronized` or `Lock` | Lock contention callback above configurable threshold |

All four types run simultaneously with a combined overhead of 3-8% CPU.

---

## Step 1: Deploy Pyroscope Server

### Docker Compose

```yaml
# docker-compose.yaml

services:
  pyroscope:
    image: grafana/pyroscope:latest
    container_name: pyroscope
    ports:
      - "4040:4040"
    volumes:
      - pyroscope-data:/data
      - ./config/pyroscope/pyroscope.yaml:/etc/pyroscope/config.yaml
    command:
      - "-config.file=/etc/pyroscope/config.yaml"
    networks:
      - monitoring

volumes:
  pyroscope-data:

networks:
  monitoring:
    driver: bridge
```

### Pyroscope server configuration

```yaml
# config/pyroscope/pyroscope.yaml

storage:
  backend: filesystem
  filesystem:
    dir: /data

server:
  http_listen_port: 4040

self_profiling:
  disable_push: true
```

For production deployments with higher ingestion volume, use object storage (S3, GCS) instead of filesystem:

```yaml
storage:
  backend: s3
  s3:
    bucket_name: pyroscope-profiles
    endpoint: s3.amazonaws.com
    region: us-east-1
```

### Verify the server is running

```bash
curl -s http://localhost:4040/ready
# Expected: "ready"
```

---

## Step 2: Attach the Java Agent

Add the Pyroscope agent to each Java service via `JAVA_TOOL_OPTIONS`. No code changes are required — the agent is loaded at JVM startup.

### Docker Compose service definition

```yaml
  order-service:
    build:
      context: ./sample-app
      dockerfile: Dockerfile
    container_name: order-service
    ports:
      - "8081:8080"
    environment:
      JAVA_TOOL_OPTIONS: >-
        -javaagent:/opt/pyroscope/pyroscope.jar
        -Dpyroscope.application.name=bank-order-service
        -Dpyroscope.server.address=http://pyroscope:4040
        -Dpyroscope.format=jfr
        -Dpyroscope.profiler.event=itimer
        -Dpyroscope.profiler.alloc=512k
        -Dpyroscope.profiler.lock=10ms
        -Dpyroscope.labels.env=production
        -Dpyroscope.labels.service=order-service
        -Dpyroscope.log.level=info
    depends_on:
      - pyroscope
    networks:
      - monitoring
```

### Agent flags reference

| Flag | Purpose | Recommended Value |
|------|---------|-------------------|
| `-javaagent:/opt/pyroscope/pyroscope.jar` | Load the Pyroscope agent | Path to agent JAR in container |
| `-Dpyroscope.application.name` | Application name in Pyroscope UI | Unique per service (e.g., `bank-order-service`) |
| `-Dpyroscope.server.address` | Pyroscope server URL | `http://pyroscope:4040` (Docker network) |
| `-Dpyroscope.format=jfr` | Profile data format | `jfr` (Java Flight Recorder) |
| `-Dpyroscope.profiler.event=itimer` | CPU sampling method | `itimer` (portable) or `cpu` (Linux perf_events, lower overhead) |
| `-Dpyroscope.profiler.alloc=512k` | Allocation sampling threshold | `512k` (sample every 512 KB allocated per thread) |
| `-Dpyroscope.profiler.lock=10ms` | Lock contention threshold | `10ms` (report locks held longer than 10 ms) |
| `-Dpyroscope.labels.*` | Static labels for filtering | `env`, `service`, `region`, `version` |
| `-Dpyroscope.log.level` | Agent log verbosity | `info` for production, `debug` for troubleshooting |

### Dockerfile (agent download)

```dockerfile
FROM eclipse-temurin:21-jre

# Download Pyroscope Java agent
ADD https://github.com/grafana/pyroscope-java/releases/download/v0.14.0/pyroscope.jar /opt/pyroscope/pyroscope.jar

# Download JMX Exporter (optional — for Prometheus JVM metrics)
ADD https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar /opt/jmx-exporter/jmx_prometheus_javaagent.jar
COPY jmx-exporter-config.yaml /opt/jmx-exporter/config.yaml

COPY target/app.jar /app/app.jar
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

The agent is loaded via `JAVA_TOOL_OPTIONS` at container startup — the Dockerfile only needs to include the JAR file.

### Verify profiles are being received

```bash
# List all application names reporting to Pyroscope
curl -s http://localhost:4040/pyroscope/label-values?label=__name__

# List all services by label
curl -s 'http://localhost:4040/querier.v1.QuerierService/LabelValues' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"name":"service_name"}'
```

---

## Step 3: Connect Grafana (Optional)

Pyroscope has a built-in UI at `http://localhost:4040`, but Grafana provides richer dashboarding with correlated metrics and profiles.

### Add Pyroscope as a Grafana datasource

```yaml
# config/grafana/provisioning/datasources/datasources.yaml

apiVersion: 1
datasources:
  - name: Pyroscope
    type: grafana-pyroscope-datasource
    uid: pyroscope
    url: http://pyroscope:4040
    access: proxy
    isDefault: false
    jsonData:
      minStep: '15s'
```

### Install the Explore Profiles plugin

```yaml
# docker-compose.yaml — Grafana service
  grafana:
    image: grafana/grafana:11.5.2
    environment:
      GF_INSTALL_PLUGINS: grafana-pyroscope-app
    volumes:
      - ./config/grafana/provisioning:/etc/grafana/provisioning
```

Enable the plugin via provisioning:

```yaml
# config/grafana/provisioning/plugins/plugins.yaml

apiVersion: 1
apps:
  - type: grafana-pyroscope-app
    org_id: 1
    disabled: false
```

### Grafana URLs

| View | URL | Purpose |
|------|-----|---------|
| Explore Profiles | `/a/grafana-pyroscope-app/explore` | Browse and compare profiles without building dashboards |
| Explore | `/explore` (select Pyroscope datasource) | Ad-hoc flame graph queries with label selectors |
| Dashboards | `/dashboards` | Pre-built panels combining metrics and profiles |

---

## Step 4: Read Flame Graphs

### Pyroscope UI (http://localhost:4040)

1. Select an application from the dropdown (e.g., `bank-order-service`)
2. Select a profile type (CPU, alloc, mutex, wall)
3. Set the time range to cover the period of interest
4. The flame graph renders automatically

**Reading the flame graph:**
- Each bar = one function (fully qualified: `com.example.OrderVerticle.processOrders`)
- Width = proportion of the sampled resource consumed by that function
- The bottom bar is the root (usually `Thread.run` or `main`)
- Trace upward to find application code responsible for resource consumption
- Click a bar to zoom into that subtree
- Search (magnifying glass) to highlight a specific method across the graph

### Grafana Explore

1. Go to Explore, select the Pyroscope datasource
2. Set the profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
3. Set the label selector: `{service_name="bank-order-service"}`
4. The flame graph renders in the panel

### Label selectors

```
{service_name="bank-order-service"}
{service_name="bank-payment-service"}
{service_name="bank-order-service", env="production"}
```

### Comparing profiles

**Pyroscope UI:** Use the Comparison view to place two flame graphs side by side. Red frames = more resource consumption in the right panel; green = less.

**Grafana:** Use the Explore Profiles plugin or the Pyroscope diff API:

```bash
curl -s "http://localhost:4040/pyroscope/render-diff?leftQuery=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-order-service%22%7D&leftFrom=now-2h&leftUntil=now-1h&rightFrom=now-1h&rightUntil=now&format=json"
```

---

## Production Use Cases

### 1. Incident root cause: high CPU

**Trigger:** Prometheus alert fires for CPU > 80% on a service.

**Without profiling:** Check metrics (confirms CPU is high), check logs (nothing useful), guess, restart, escalate to developers, read code, attempt reproduction.

**With profiling:**
1. Open the flame graph for the affected service and time window
2. Identify the widest bar at the leaf level — this is the CPU-consuming method
3. Read the fully qualified method name → go directly to that line in source code

**Example:** `PaymentVerticle.sha256()` consumes 34% self-time. The flame graph shows `MessageDigest.getInstance("SHA-256")` called per request (security provider lookup every call). Fix: cache the `MessageDigest` in a `ThreadLocal`. CPU drops from 82% to 12%.

### 2. Memory leak / GC pressure

**Trigger:** Heap usage trending upward, frequent GC pauses, or OOM restarts.

**With profiling:**
1. Switch to the **allocation** profile type
2. The widest frames show where the most bytes are allocated
3. Reduce allocations at those points (reuse objects, avoid `String.format` in loops, pre-size collections)

**Example:** `NotificationVerticle.handleBulk()` → `String.format()` → `Formatter.<init>` dominates the allocation profile. Each bulk notification creates thousands of `Formatter` objects. Fix: use `StringBuilder` directly.

### 3. Lock contention / throughput plateau

**Trigger:** Throughput plateaus despite available CPU. Thread count is rising.

**With profiling:**
1. Switch to the **mutex** profile type
2. Wide frames = methods where threads waited to acquire a lock
3. The method one frame above the contention frame holds the lock

**Example:** `OrderVerticle.processOrdersSynchronized()` is a wide mutex frame. The `synchronized` keyword on the method serializes all request processing. Fix: replace with `ConcurrentHashMap.computeIfPresent` (lock-free). Mutex frame vanishes, throughput scales with thread count.

### 4. High latency with low CPU

**Trigger:** Response times are slow but CPU is under 20%.

**With profiling:**
1. Switch to the **wall clock** profile type
2. Compare wall profile to CPU profile — methods present in wall but absent in CPU are off-CPU bottlenecks
3. Look for `Thread.sleep`, `Object.wait`, `LockSupport.park`, or I/O frames

**Example:** Wall profile shows `Thread.sleep` inside `executeBlocking` for downstream service calls. In production, this pattern points to slow database queries or external API calls.

### 5. Performance regression detection

**Trigger:** Latency increased after a deployment.

**With profiling:**
1. Compare flame graphs from before and after the deployment (use Pyroscope's time range selector or diff API)
2. New or wider frames in the post-deploy profile indicate the regression source
3. Correlate with the git diff to identify the responsible commit

### 6. Capacity planning

**With profiling:**
1. Query top CPU functions across all services
2. Services where application code (not JVM internals) dominates CPU are candidates for code optimization
3. Services where JVM internals dominate may need more resources or JVM tuning (GC algorithm, heap size)

---

## JVM Diagnostics: Metrics + Flame Graph Correlation

Each diagnostic procedure combines Prometheus metrics (detect the symptom) with Pyroscope flame graphs (identify the cause).

### Garbage Collection

**Metrics (JVM Metrics Deep Dive dashboard):**

| Metric | PromQL | Healthy Pattern | Problem Pattern |
|--------|--------|-----------------|-----------------|
| GC duration rate | `rate(jvm_gc_collection_seconds_sum{job="jvm"}[1m])` | Below 0.05 s/s | Above 0.05 = GC consuming >5% of wall time |
| GC frequency | `rate(jvm_gc_collection_seconds_count{job="jvm"}[1m])` | Stable minor GC rate | Frequent major GCs = old gen filling up |
| Heap used | `jvm_memory_used_bytes{job="jvm", area="heap"}` | Sawtooth (rises, GC drops it) | Rising baseline = leak; flat at max = OOM imminent |
| Heap used vs max | `jvm_memory_used_bytes / jvm_memory_max_bytes` | Below 0.75 | Above 0.80 sustained = resize heap or fix leak |
| Memory pool utilization | `jvm_memory_pool_used_bytes{job="jvm"} / jvm_memory_pool_max_bytes{job="jvm"} > 0` | Eden full = normal | Old Gen > 80% = investigate |

**Procedure:**
1. Confirm GC pressure in metrics: high `jvm_gc_collection_seconds_sum` rate or sawtooth heap with rising baseline
2. Open Pyroscope → select the affected service → switch to **allocation** profile type (`memory:alloc_in_new_tlab_bytes`)
3. The widest frames show which methods allocate the most bytes — these drive GC pressure
4. Reduce allocations at those call sites (reuse objects, use `StringBuilder` instead of `String.format`, pre-size collections, use primitives instead of boxed types)
5. Verify: GC duration rate drops, heap sawtooth baseline stabilizes

**Example:** Allocation profile shows `NotificationVerticle.handleBulk` → `String.format` → `Formatter.<init>` consuming 40% of allocation bytes. Each bulk notification creates thousands of short-lived `Formatter` objects. Fix: replace `String.format` with `StringBuilder`. GC pause rate drops from 0.08 to 0.01.

### Thread Leaks

**Metrics (JVM Metrics Deep Dive dashboard):**

| Metric | PromQL | Healthy Pattern | Problem Pattern |
|--------|--------|-----------------|-----------------|
| Live threads | `jvm_threads_current{job="jvm"}` | Plateaus after startup, scales with load | Monotonically increasing regardless of load |
| Daemon threads | `jvm_threads_daemon{job="jvm"}` | Stable | Rising independently of traffic = leaked daemon threads |
| Peak threads | `jvm_threads_peak{job="jvm"}` | Reaches a ceiling | Keeps climbing = threads not being cleaned up |
| Thread delta | `jvm_threads_peak - jvm_threads_current` | Small gap | Zero gap + rising count = every thread stays alive |

**Procedure:**
1. Confirm thread leak in metrics: `jvm_threads_current` rising over hours regardless of traffic pattern
2. Open Pyroscope → select the affected service → switch to **wall clock** profile type
3. Look for `Thread.sleep`, `Object.wait`, `LockSupport.park` frames — these are threads alive but idle (leaked threads often park or sleep indefinitely)
4. Switch to **mutex** profile type to check if rising thread count correlates with lock contention (threads piling up waiting for a lock)
5. Trace the wall profile frames to identify which code path creates threads without cleaning them up (missing `ExecutorService.shutdown()`, unbounded `new Thread()` calls, unclosed event bus consumers)

**Thread pool exhaustion variant:** Thread count hits a ceiling (pool max size) + latency spikes. The wall profile shows many threads in `LockSupport.park` inside the pool's work queue. Fix: increase pool size, reduce per-task duration, or fix the upstream bottleneck causing tasks to back up.

### Memory Leaks (Heap and Non-Heap)

**Metrics:**

| Metric | PromQL | What It Detects |
|--------|--------|-----------------|
| Heap leak | `jvm_memory_used_bytes{job="jvm", area="heap"}` | Post-GC baseline rising over hours |
| Non-heap leak | `jvm_memory_used_bytes{job="jvm", area="nonheap"}` | Metaspace + code cache rising = classloader leak |
| Classloader leak | `jvm_classes_currently_loaded{job="jvm"}` | Should plateau after startup; rising = classes loaded but never unloaded |

**Procedure — heap leak:**
1. Confirm: heap used trends upward over hours, GC reclaims less each cycle
2. Open Pyroscope → **allocation** profile for the affected time window
3. If the dominant allocator is obvious (one method allocating disproportionately), reduce its allocation rate
4. If allocation profile looks normal but heap still rises, the issue is object retention (references held but never released). This requires a heap dump for further analysis:
   ```bash
   docker exec <container> jmap -dump:live,format=b,file=/tmp/heap.hprof 1
   docker cp <container>:/tmp/heap.hprof ./heap.hprof
   # Analyze with Eclipse MAT or VisualVM
   ```
5. Common retention causes: growing `Map` or `List` used as a cache without eviction, event listeners registered but never removed, static collections accumulating entries

**Procedure — classloader/metaspace leak:**
1. Confirm: `jvm_classes_currently_loaded` rising beyond startup, `jvm_memory_used_bytes{area="nonheap"}` trending upward
2. Open Pyroscope → **CPU** profile → search for `ClassLoader.loadClass` or `defineClass`
3. If classloading frames appear in steady-state (not just startup), something is repeatedly loading classes — common causes: runtime code generation, repeated `Class.forName()`, frameworks creating proxy classes per request
4. The FaaS server's deploy/undeploy lifecycle intentionally loads classes per invocation (visible as `ClassLoader.loadClass` in the CPU profile). In production FaaS workloads, use warm pools to avoid this.

### File Descriptor Leaks

**Metrics:**

| Metric | PromQL | Healthy Pattern | Problem Pattern |
|--------|--------|-----------------|-----------------|
| Open FDs | `process_open_fds{job="jvm"}` | Stable after startup | Rising = unclosed connections, files, or sockets |
| FD rate of change | `deriv(process_open_fds{job="jvm"}[10m])` | Near zero | Positive = leak rate (FDs/second) |

**Procedure:**
1. Confirm: `process_open_fds` rising over time in the JVM Metrics Deep Dive dashboard
2. This is not directly visible in flame graphs — FD leaks are resource handle leaks, not CPU/memory/lock issues
3. Common causes: HTTP client connections opened but never closed, database connection pool not returning connections, file streams not closed in `finally`/try-with-resources
4. Correlate timing: if FD count rises proportionally to request rate, the leak is per-request. Check the **wall** profile for I/O-related frames (`SocketInputStream.read`, `FileInputStream.read`) to identify which code paths perform I/O
5. Verify with `lsof`:
   ```bash
   docker exec <container> bash -c "ls -la /proc/1/fd | wc -l"
   docker exec <container> bash -c "ls -la /proc/1/fd" | sort -k11 | tail -20
   ```

### Diagnostic Summary

| Problem | Detect With (Metric) | Investigate With (Profile Type) | Flame Graph Signature |
|---------|---------------------|-------------------------------|----------------------|
| GC pressure | GC duration rate > 0.05 | **Allocation** | Wide `BigDecimal.<init>`, `String.format`, `HashMap.put` frames |
| Heap memory leak | Heap baseline rising | **Allocation** + heap dump | Normal allocation profile but heap won't reclaim |
| Thread leak | `jvm_threads_current` rising | **Wall** + **Mutex** | Idle threads in `Thread.sleep`, `Object.wait`, `LockSupport.park` |
| Thread pool exhaustion | Thread count at ceiling + latency spike | **Wall** | Threads parked in pool work queue |
| Classloader leak | `jvm_classes_currently_loaded` rising | **CPU** | `ClassLoader.loadClass` in steady-state |
| File descriptor leak | `process_open_fds` rising | **Wall** (I/O correlation) | Not directly visible; correlate I/O frames with FD timing |
| Lock contention | Low CPU + high latency + rising threads | **Mutex** | Wide `synchronized` method frames |

---

## MTTR Reduction

Continuous profiling eliminates the investigation gap between symptom detection and root cause identification.

| Incident Phase | Without Profiling | With Profiling |
|----------------|-------------------|----------------|
| **Detection** | Alert fires | Alert fires (same) |
| **Triage** | 5-15 min: check metrics, logs, guess | 30 sec: open flame graph for alert time window |
| **Root cause** | 15-60 min: reproduce, attach debugger, read code | 2-5 min: read frame names in flame graph |
| **Verification** | Redeploy, wait, check metrics | Compare before/after flame graphs |
| **Total** | 30-90 min | 5-15 min |

Profiling data is already captured when the incident occurs. No reproduction, no debugger, no logging changes — the flame graph for the incident time window is available immediately.

### Triage workflow

```bash
# Automated root cause detection (queries Prometheus + Pyroscope)
bash scripts/bottleneck.sh

# Output per service:
#   [!!!] payment-service → CPU-BOUND
#        Hotspot: PaymentVerticle.sha256 (34.2% self-time)
#        Action:  Optimize PaymentVerticle.sha256
```

### Fix validation

After deploying a fix:
1. Open the same flame graph view for the same service
2. Compare the current time range to the pre-fix time range
3. The problematic frame should be narrower or absent
4. Confirm the corresponding metric (CPU usage, p99 latency, GC pause rate) improved

---

## Overhead and Cost

### CPU overhead

| Profile Type | Mechanism | Expected Overhead | Notes |
|-------------|-----------|-------------------|-------|
| CPU | `itimer` signal at ~100 Hz | 1-3% | Interrupt + stack walk per sample |
| Wall clock | Timer signal at ~100 Hz | 1-2% | Same mechanism, all threads |
| Allocation | TLAB callback at 512 KB threshold | 0.5-2% | Triggered by allocation rate, not timer |
| Mutex | Lock contention callback at 10 ms | 0.1-0.5% | Only fires on actual contention above threshold |
| **Combined (all four)** | | **3-8%** | Acceptable for most production workloads |

Overhead is bounded because the sampling frequency is fixed. A service handling 100 req/s and one handling 10,000 req/s generate the same ~100 stack samples per second. The profiler does not sample more often for busier workloads.

### Memory overhead

- Agent heap: 20-40 MB for sample buffers and compression
- Network: compressed profile uploads every 10 seconds, typically 10-50 KB per upload

### Server-side storage

- Pyroscope compresses profile data efficiently
- Filesystem storage: ~1-5 GB per service per month at default retention (depends on function diversity and label cardinality)
- Object storage (S3/GCS): same volume, lower cost at scale

### Reducing overhead if needed

| Goal | Configuration Change |
|------|---------------------|
| Minimize CPU overhead | Use `cpu` event instead of `itimer` on Linux (uses `perf_events`, lower overhead) |
| Reduce allocation profiling cost | Increase `-Dpyroscope.profiler.alloc` threshold (e.g., `1m` instead of `512k`) |
| Disable mutex profiling | Remove `-Dpyroscope.profiler.lock` flag |
| Reduce upload frequency | Set `-Dpyroscope.upload.interval=30s` (default 10s) |
| CPU-only profiling | Remove `alloc` and `lock` flags; keep only `event=itimer` |

### Measuring overhead in your environment

```bash
# Run service without profiling
# Record: requests/sec, avg CPU %, avg latency

# Enable profiling (add JAVA_TOOL_OPTIONS)
# Record same metrics under same load

# Compare:
#   CPU delta = profiling overhead
#   Latency delta = profiling impact on request path
```

The overhead should be stable over time. If CPU usage per request increases over time with profiling enabled, investigate agent version or configuration issues.

### Cost comparison

| Approach | Data Collected | Overhead | Root Cause Capability |
|----------|---------------|----------|-----------------------|
| Metrics only (Prometheus) | Rates and gauges | <1% | Identifies *what* is wrong, not *why* |
| APM agent (Datadog, New Relic) | Traces + metrics | 5-15% | Request-level latency breakdown; limited code-level detail |
| Continuous profiling (Pyroscope) | Function-level CPU/memory/lock data | 3-8% | Exact method and line consuming the resource |
| Profiling + Metrics (this project) | Both | 3-8% (profiling) + <1% (metrics) | Full picture: resource rates + code-level root cause |

Pyroscope is open source (AGPL-3.0) with no per-host or per-service licensing cost. Grafana Cloud offers a managed Pyroscope service with usage-based pricing for teams that prefer not to self-host.

---

## Troubleshooting

### Profiles not appearing in Pyroscope

1. Verify the Pyroscope server is running: `curl http://localhost:4040/ready`
2. Check agent logs in the service container: `docker logs <service> 2>&1 | grep -i pyroscope`
3. Verify the `pyroscope.server.address` is reachable from the service container (use Docker network name, not `localhost`)
4. Confirm `JAVA_TOOL_OPTIONS` is set: `docker exec <service> env | grep JAVA_TOOL_OPTIONS`
5. Verify the application name is correct: query `http://localhost:4040/pyroscope/label-values?label=__name__`

### Flame graph is empty for a profile type

- **CPU empty:** Service may be idle. Generate load first.
- **Allocation empty:** Threshold may be too high. Lower `-Dpyroscope.profiler.alloc` (e.g., `256k`).
- **Mutex empty:** No lock contention above threshold. Lower `-Dpyroscope.profiler.lock` (e.g., `1ms`) or confirm the service uses `synchronized` blocks.
- **Wall empty:** Same as CPU — requires active threads.

### Grafana dashboards show "No data" or display stale panels

The Grafana Docker volume caches dashboard state. After modifying dashboard JSON files, the volume may serve old versions.

1. Tear down and redeploy to clear the volume:
   ```bash
   bash scripts/run.sh teardown
   bash scripts/run.sh
   ```
2. Verify dashboards loaded correctly:
   ```bash
   for uid in pyroscope-java-overview jvm-metrics-deep-dive http-performance verticle-performance before-after-comparison faas-server; do
     title=$(curl -sf -u admin:admin "http://localhost:3000/api/dashboards/uid/$uid" | python3 -c "import json,sys; print(json.load(sys.stdin)['dashboard']['title'])" 2>/dev/null)
     echo "  $uid: ${title:-MISSING}"
   done
   ```
3. If specific panels show "No data" but others work:
   - Check the time range picker (top right) covers the period when load was running
   - Verify the template variable dropdowns have a value selected (not empty)
   - For Prometheus panels: confirm the `job` label matches (`jvm` for JMX metrics, `vertx-apps` for HTTP metrics)
   - For Pyroscope panels: confirm load has been running for at least 30 seconds

### High overhead observed

1. Switch from `itimer` to `cpu` event on Linux
2. Increase allocation threshold
3. Increase upload interval
4. Disable mutex profiling if not needed
5. Verify the overhead is from the profiler and not from the application itself (compare with and without `JAVA_TOOL_OPTIONS`)

---

## Quick Reference

### Pyroscope API endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/ready` | GET | Health check |
| `/pyroscope/label-values?label=__name__` | GET | List all application names |
| `/pyroscope/render?query=...&from=...&until=...&format=json` | GET | Render a profile as JSON |
| `/pyroscope/render-diff?leftQuery=...&rightQuery=...` | GET | Diff two profiles |
| `/querier.v1.QuerierService/LabelValues` | POST | List label values (gRPC-web) |

### Profile type identifiers (for queries)

| Profile Type | Query Identifier |
|-------------|-----------------|
| CPU | `process_cpu:cpu:nanoseconds:cpu:nanoseconds` |
| Allocation (bytes) | `memory:alloc_in_new_tlab_bytes:bytes:space:bytes` |
| Allocation (objects) | `memory:alloc_in_new_tlab_objects:count:space:bytes` |
| Mutex (contentions) | `mutex:contentions:count:mutex:count` |
| Mutex (delay) | `mutex:delay:nanoseconds:mutex:count` |

### Render a CPU profile via curl

```bash
curl -s "http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-order-service%22%7D&from=now-1h&until=now&format=json" | python3 -m json.tool
```

# FaaS Server

A lightweight Function-as-a-Service runtime built as a Vert.x verticle. The FaaS server dynamically deploys and undeploys short-lived verticle "functions" on demand via HTTP, producing a profiling signature distinct from long-running services: classloader activity, deployment lifecycle overhead, short-burst compute, and concurrent deploy/undeploy contention.

## Quick Start

```bash
docker compose up -d faas-server pyroscope
curl http://localhost:8088/health
```

## Built-in Functions (11 Dynamically Deployed Verticles)

Each function is a separate Vert.x verticle that is deployed, executed, and undeployed per invocation. Every invocation gets a unique event bus address, so concurrent invocations never collide.

| Function | Description | Profile Signature |
|----------|-------------|-------------------|
| `fibonacci` | Recursive Fibonacci (CPU-bound) | CPU hotspot, deep recursive call stacks |
| `transform` | JSON dataset generation and filtering (alloc-heavy) | GC pressure, allocation profiling |
| `hash` | SHA-256 iterated hashing (CPU-bound, short burst) | Crypto CPU burn |
| `sort` | Generate and sort large string list (CPU + alloc) | Mixed CPU and allocation |
| `sleep` | Timer-based simulated I/O latency | Wall-clock profiling, idle threads |
| `matrix` | O(n³) matrix multiplication (CPU-heavy) | Dense CPU compute, array allocation |
| `regex` | Pattern matching against generated candidates | CPU from regex backtracking |
| `compress` | GZIP compression of random data (CPU + I/O buffer) | CPU + byte buffer allocation |
| `primes` | Sieve of Eratosthenes (CPU-bound) | Boolean array allocation + tight loop |
| `contention` | Synchronized lock contention (mutex) | Lock wait frames in mutex profile |
| `fanout` | Deploys N child function verticles in parallel | Concurrent deployment contention |

### Profile type coverage

Every Pyroscope profile type is exercised by at least one function:

| Profile Type | Functions That Produce Data |
|---|---|
| **CPU** (`process_cpu`) | `fibonacci`, `hash`, `matrix`, `regex`, `compress`, `primes`, `sort`, `contention` |
| **Wall Clock** (`wall`) | `sleep` (timer latency), plus all CPU functions show wall time |
| **Allocation** (`memory:alloc`) | `transform`, `sort`, `compress`, `matrix` (array alloc) |
| **Mutex** (`mutex`) | `contention` (4 threads competing for one `synchronized` lock) |

## API Reference

### Invoke a single function

Each invocation deploys a new verticle, sends it a message, collects the result, then undeploys it.

```bash
curl -X POST http://localhost:8088/fn/invoke/fibonacci
curl -X POST http://localhost:8088/fn/invoke/hash \
  -H "Content-Type: application/json" \
  -d '{"rounds": 5000}'
curl -X POST http://localhost:8088/fn/invoke/matrix \
  -H "Content-Type: application/json" \
  -d '{"dim": 150}'
curl -X POST http://localhost:8088/fn/invoke/primes \
  -H "Content-Type: application/json" \
  -d '{"limit": 500000}'
curl -X POST http://localhost:8088/fn/invoke/compress \
  -H "Content-Type: application/json" \
  -d '{"size": 100000}'
curl -X POST http://localhost:8088/fn/invoke/regex \
  -H "Content-Type: application/json" \
  -d '{"count": 10000}'
curl -X POST http://localhost:8088/fn/invoke/contention \
  -H "Content-Type: application/json" \
  -d '{"threads": 8, "iterations": 300}'
```

### Burst — N concurrent invocations

Deploys N instances of the same function concurrently, producing deploy contention and thread pool saturation.

```bash
curl -X POST "http://localhost:8088/fn/burst/hash?count=10"
curl -X POST "http://localhost:8088/fn/burst/primes?count=5"
curl -X POST "http://localhost:8088/fn/burst/matrix?count=3"
```

### Chain — sequential function execution

Deploys, runs, and undeploys each function in sequence. Each step pays the full verticle lifecycle cost.

```bash
curl -X POST http://localhost:8088/fn/chain \
  -H "Content-Type: application/json" \
  -d '{"chain": ["hash", "sort", "fibonacci"], "params": {}}'
curl -X POST http://localhost:8088/fn/chain \
  -H "Content-Type: application/json" \
  -d '{"chain": ["regex", "compress", "primes"], "params": {}}'
```

### Fanout — parallel child verticle deployment

The `fanout` function itself deploys N child function verticles in parallel, aggregates results, then undeploys them.

```bash
curl -X POST http://localhost:8088/fn/invoke/fanout \
  -H "Content-Type: application/json" \
  -d '{"count": 5, "function": "hash"}'
```

### List available functions

```bash
curl http://localhost:8088/fn/list
```

### Invocation stats

```bash
curl http://localhost:8088/fn/stats
```

### Warm pool — pre-deploy instances

```bash
# Create a warm pool of 5 instances
curl -X POST "http://localhost:8088/fn/warmpool/hash?size=5"

# Delete the warm pool
curl -X DELETE http://localhost:8088/fn/warmpool/hash
```

## Optimized vs Unoptimized Mode

Set the `OPTIMIZED` environment variable to `true` to enable warm pool reuse:

- **Unoptimized (default):** Every invocation deploys a new verticle, executes, then undeploys it. This creates cold-start overhead visible in flame graphs as `deployVerticle`/`undeploy` frames.
- **Optimized:** Functions are served from a warm pool when available, skipping the deploy/undeploy cycle. Invoke the warm pool endpoints first to pre-populate.

## Pyroscope Profile Types

All services (including the FaaS server) are configured with four profile types:

| Profile Type | Agent Flag | What It Captures | When to Use |
|---|---|---|---|
| **CPU** (`process_cpu`) | `-Dpyroscope.profiler.event=itimer` | Which methods consume CPU time | High CPU alerts, computation bottlenecks |
| **Wall Clock** (`wall`) | `-Dpyroscope.profiler.event=wall` | Real elapsed time including I/O waits, sleeps, and off-CPU time | High latency with low CPU (I/O-bound, locks, sleeps) |
| **Memory Allocation** (`memory:alloc`) | `-Dpyroscope.profiler.alloc=512k` | Where memory is allocated (bytes and object counts) | GC pressure, memory leaks, allocation hotspots |
| **Mutex Contention** (`mutex`) | `-Dpyroscope.profiler.lock=10ms` | Which synchronized blocks cause thread contention | Lock contention, thread serialization |

### Profile types not applicable to Java

- **Goroutine** — Go-specific. Shows goroutine stacks. Not available in Java/JFR.
- **Block** — Go-specific. Shows goroutine blocking events. The Java equivalent is the **mutex** profile.

### Viewing all profile types in Grafana

1. Open the **FaaS Server** dashboard or **Pyroscope Java Overview**.
2. Use the `profile_type` dropdown to switch between CPU, alloc (memory), mutex (lock), and wall.
3. Each profile type produces a separate flame graph showing a different dimension of the same execution.

### Cross-referencing profile types for diagnosis

| CPU | Wall | Alloc | Mutex | Diagnosis |
|-----|------|-------|-------|-----------|
| Hot | Hot | Flat | Flat | Pure computation — optimize the algorithm |
| Flat | Hot | Flat | Flat | Off-CPU bottleneck — I/O, sleep, external call |
| Flat | Flat | Hot | Flat | GC pressure — reduce allocations |
| Flat | Hot | Flat | Hot | Lock contention — threads waiting |
| Hot | Hot | Hot | Flat | CPU + allocation — computation creating temp objects |

## What to Look for in Pyroscope

1. **Deploy/undeploy overhead** — In unoptimized mode, look for `io.vertx.core.impl` deployment frames wrapping each function call.
2. **Classloader activity** — Each cold deploy triggers class resolution; visible in CPU profiles under `java.lang.ClassLoader`.
3. **Short-burst compute** — Functions like `fibonacci`, `matrix`, and `primes` produce narrow, intense CPU spikes.
4. **Concurrent contention** — Burst endpoints show thread pool saturation and lock contention in deploy/undeploy paths.
5. **Wall-clock I/O** — The `sleep` function appears in wall-clock profiles but not in CPU profiles, demonstrating off-CPU visibility.
6. **Warm vs cold comparison** — Compare flame graphs with and without `OPTIMIZED=true` to see the lifecycle overhead disappear.

## Performance Impact of Pyroscope Profiling

### How sampling-based profiling works

Pyroscope uses async-profiler, a sampling-based profiler. Understanding the difference between sampling and instrumentation is key to understanding why this is production-safe.

**Instrumentation profilers** (like most APM agents) modify application bytecode. They wrap every method entry and exit with timing code. The overhead scales linearly with the number of method calls — a method called 1 million times per second pays 1 million times the instrumentation cost. This makes instrumentation impractical for production.

**Sampling profilers** do not modify application code at all. Instead, they periodically interrupt the JVM (e.g., 100 times per second) and record what each thread's call stack looks like at that instant. The cost is fixed: 100 samples per second costs the same whether the application is idle or handling 50,000 requests per second. Methods that consume more CPU time appear in more samples, which is how the profiler determines where time is spent — the same statistical principle as polling or survey sampling.

The tradeoff: sampling produces a statistical approximation, not exact counts. A method that runs for 1% of wall time appears in roughly 1% of samples. With 100 samples/second over 10 seconds (1,000 samples), that method appears in ~10 samples — enough to identify it. With a 1-second window, it might appear in 0 or 1 sample — not enough. This is why Pyroscope aggregates data over 10-15 second windows by default, and why flame graphs become more accurate over longer time ranges.

### How the Pyroscope agent attaches

The agent attaches via `-javaagent` in `JAVA_TOOL_OPTIONS` (see `docker-compose.yaml`). It runs inside the JVM process as a native library (async-profiler uses `JVMTI` and `perf_events` / `itimer` signals). It periodically compresses and ships profile data to the Pyroscope server over HTTP. No application code changes are needed. The agent is the same for all services — the FaaS server, payment service, and every other service all use identical agent configuration.

### Overhead per profile type

Each profile type uses a different sampling mechanism and adds independent overhead:

| Profile Type | Config Flag | Sampling Mechanism | Overhead | Why This Cost |
|---|---|---|---|---|
| **CPU** | `-Dpyroscope.profiler.event=itimer` | `ITIMER_PROF` signal fires ~100 times/sec. On each signal, the agent calls `AsyncGetCallTrace` to capture the current call stack. | 1-3% CPU | Signal handling + stack walking. Cost is per-second, not per-request. |
| **Wall** | `-Dpyroscope.profiler.event=wall` | Same signal mechanism, but samples all threads (not just running ones). Captures sleeping, blocked, and waiting threads. | 1-2% CPU | Slightly cheaper than CPU because wall sampling skips threads in native code more often. |
| **Allocation** | `-Dpyroscope.profiler.alloc=512k` | JVM TLAB (Thread-Local Allocation Buffer) callback. Every time a thread allocates 512 KB of heap, the agent captures a stack trace. | 2-5% CPU | More allocation-heavy code triggers more samples. The 512 KB threshold controls this — higher threshold = fewer samples = less overhead. |
| **Mutex** | `-Dpyroscope.profiler.lock=10ms` | JVM monitor contention callback. When a thread waits >10 ms to acquire a `synchronized` lock, the agent captures a stack trace. | <1% CPU | Only fires during actual contention. Services with no lock contention see zero mutex overhead. |
| **All combined** | Current config | All four mechanisms run simultaneously | **3-8% total** | The mechanisms are independent — they don't amplify each other. |

### Why overhead is bounded (not proportional to load)

The CPU and wall profilers fire at a fixed frequency (~100 Hz). This means:

- A service handling **10 requests/second** generates ~100 stack samples/second
- A service handling **10,000 requests/second** generates ~100 stack samples/second

The cost is identical. What changes is the distribution of samples across methods — under higher load, more samples land in hot methods, giving the flame graph better resolution. But the profiler itself does the same amount of work.

Allocation profiling is the exception: it scales with allocation rate, not time. A service allocating 50 MB/sec triggers ~100 samples/sec (50 MB / 512 KB). A service allocating 500 MB/sec triggers ~1,000 samples/sec. This is why allocation profiling has a wider overhead range (2-5%) and why the threshold is tunable.

### Overhead for the FaaS server

The FaaS server produces more diverse profiling data than other services because of its deploy/undeploy lifecycle:

1. **Frequent classloading** — Each cold deploy may trigger class resolution. CPU samples capture `ClassLoader.loadClass` frames that don't appear in long-running services.
2. **Short-lived verticles** — Deploy/undeploy cycles exercise JVM internal code paths (thread pool scheduling, event bus registration), producing richer flame graphs.
3. **The `contention` function** — Spawns threads competing on a `synchronized` lock, triggering the mutex profiler. Other functions don't produce mutex data.

The overhead percentage stays within the same 3-8% range because the sampling rate is fixed. The profiler doesn't sample more often because the workload is more complex — it captures more varied frames at the same rate.

### Production feasibility

**Sampling-based continuous profiling is standard practice in production.** Grafana, Datadog, Netflix (with their JVM profiler), and Google (Cloud Profiler) all recommend always-on profiling in production at similar sampling rates.

Why it is safe:

- **No bytecode modification** — The agent never rewrites application classes. It only observes. There is no risk of changing application behavior.
- **Fixed CPU cost** — 100 stack captures/second is the same cost at 10 req/s or 100,000 req/s. Overhead does not grow with load.
- **No stop-the-world pauses** — Async-profiler uses `AsyncGetCallTrace`, which reads call stacks without requiring a JVM safepoint. Unlike `jstack` or `JMX ThreadMXBean.getThreadInfo()`, it does not pause all threads.
- **No safepoint bias** — Many profilers can only sample at JVM safepoints (GC pauses, method returns, loop backedges). This creates blind spots — methods that run tight loops without safepoints are invisible. Async-profiler samples at arbitrary points, giving accurate results for all code.
- **Graceful degradation** — If the Pyroscope server is unreachable, the agent buffers data locally and retries. It does not block application threads or throw exceptions.
- **Low memory footprint** — The agent adds ~20-40 MB heap for profile buffers. This is visible in the JVM Metrics dashboard under `jvm_memory_used_bytes`.

### When to disable specific profile types

Not every service needs all four profile types. Use the following guidelines:

| Scenario | Recommendation | How to Disable |
|---|---|---|
| **Sub-millisecond latency SLA** (e.g., in-memory cache, hot path proxy) | Keep CPU only. Disable wall, alloc, mutex. | Remove `-Dpyroscope.profiler.alloc=512k`, `-Dpyroscope.profiler.lock=10ms`, and the wall `-Dpyroscope.profiler.event=wall` line from `JAVA_TOOL_OPTIONS` in `docker-compose.yaml`. Overhead drops to 1-3%. |
| **Memory-constrained container** (<256 MB heap) | Disable alloc profiling or raise threshold. | Remove `-Dpyroscope.profiler.alloc=512k` or change to `-Dpyroscope.profiler.alloc=2m`. |
| **No synchronized blocks in the codebase** | Disable mutex profiling. | Remove `-Dpyroscope.profiler.lock=10ms`. Saves <1% CPU and eliminates that profile type from data collection. |
| **Debugging a specific issue temporarily** | Enable only the relevant type. | For a memory leak, keep only alloc. For lock contention, keep only mutex. Reduces overhead and noise. |
| **Batch/offline processing** (no latency SLA) | Keep all four. The 3-8% overhead is negligible for throughput-oriented workloads. | No changes needed. |
| **FaaS server in production** | Keep all four. The deploy/undeploy lifecycle and `contention` function are designed to exercise all profile types. Reducing them would reduce the demo's value. | No changes needed for demo purposes. In a real production FaaS, apply the same rules as any other service. |

### How to verify overhead

**Method 1: Built-in benchmark**

```bash
# Runs each endpoint with and without the agent, compares latency
bash scripts/run.sh benchmark
```

This starts all services with the Pyroscope agent, measures avg/p50/p95/p99 latency, then restarts without the agent and repeats. The output shows percentage overhead per service.

**Method 2: Manual comparison for the FaaS server**

```bash
# Step 1: Measure with profiling (current config)
for i in $(seq 1 50); do
  curl -w "%{time_total}\n" -s -o /dev/null \
    -X POST http://localhost:8088/fn/invoke/hash \
    -H "Content-Type: application/json" -d '{"rounds": 5000}'
done 2>&1 | awk '{sum+=$1; n++} END {print "avg:", sum/n, "sec"}'

# Step 2: Disable profiling for faas-server
# In docker-compose.yaml, comment out or clear JAVA_TOOL_OPTIONS for faas-server
# Then: docker compose up -d faas-server

# Step 3: Repeat the same curl loop
# Compare the averages. Expect 3-8% difference.
```

**Method 3: Prometheus metrics (no restart needed)**

Compare `rate(process_cpu_seconds_total[5m])` for the FaaS server against its request rate. If CPU usage per request is stable over time, the profiler is not adding variable overhead. Check the JVM Metrics Deep Dive dashboard — the CPU panel shows this directly.

**What to look for:**

- avg latency overhead < 10% → safe for production
- p99 latency overhead < 15% → no tail latency spikes from the agent
- `jvm_memory_used_bytes` increase of 20-40 MB → expected agent buffer cost
- No increase in GC pause rate (`jvm_gc_collection_seconds_sum`) → agent is not creating GC pressure

## Demo Walkthrough

```bash
# 1. Start services
docker compose up -d faas-server pyroscope

# 2. Generate cold-start traffic across all functions
for fn in fibonacci transform hash sort sleep matrix regex compress primes contention; do
  curl -s -X POST http://localhost:8088/fn/invoke/$fn &
done
wait

# 3. Check Pyroscope for deploy/undeploy frames (CPU profile)

# 4. Check mutex profile — contention function shows synchronized lock waits
curl -X POST http://localhost:8088/fn/invoke/contention \
  -H "Content-Type: application/json" \
  -d '{"threads": 8, "iterations": 300}'

# 5. Try a burst to see concurrent deployment contention
curl -X POST "http://localhost:8088/fn/burst/hash?count=10"

# 6. Try fanout to see parallel child verticle deploys
curl -X POST http://localhost:8088/fn/invoke/fanout \
  -H "Content-Type: application/json" \
  -d '{"count": 5, "function": "primes"}'

# 7. Switch to wall-clock profile in Grafana — sleep function visible here

# 8. Create a warm pool and compare
curl -X POST "http://localhost:8088/fn/warmpool/fibonacci?size=10"
for i in $(seq 1 20); do
  curl -s -X POST http://localhost:8088/fn/invoke/fibonacci &
done
wait

# 9. Compare flame graphs — warm pool invocations lack deployment overhead

# 10. Clean up
curl -X DELETE http://localhost:8088/fn/warmpool/fibonacci
```

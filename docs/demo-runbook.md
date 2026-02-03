# Demo Runbook

Step-by-step instructions for running the continuous profiling demo. ~20-25 minutes total.

---

## Prerequisites

- Docker and Docker Compose installed
- Ports available: 3000, 4040, 9090, 18080-18087, 8088
- At least 8 GB RAM free (9 JVMs + Pyroscope + Prometheus + Grafana)
- Browser open and ready

---

## Agenda

| Part | Topic | Time | Format |
|------|-------|------|--------|
| 1 | The problem | 3 min | Talking / slides |
| 2 | The solution | 2 min | Talking / slides |
| 3 | Live demo | 15-20 min | Terminal + browser |
| 4 | Cost and next steps | 2 min | Talking / slides |

---

## Part 1 — The problem (3 min)

Reference: [demo-guide.md](demo-guide.md), "The Problem" and "What existing tools miss."

Cover:
- Production incidents follow a predictable cycle: alert → metrics → logs → traces → guess → redeploy → repeat. Takes 30-90 min.
- Metrics show *what* is wrong (CPU at 85%). Logs show events. Traces show which service. None show *which function*.
- That gap between symptom and root cause is where all the time goes.

Use the comparison table from demo-guide.md to show what each tool misses.

---

## Part 2 — The solution (2 min)

Reference: [demo-guide.md](demo-guide.md), "The Solution: Continuous Profiling."

Cover:
- Continuous profiling samples what every thread is doing and records it continuously.
- Zero code changes — a Java agent attaches via an environment variable.
- 4 profile types: CPU, allocation, mutex, wall clock.
- Data is already captured when an incident occurs. No reproduction step.

---

## Part 3 — Live demo (15-20 min)

### Step 1 — Start the stack

```bash
bash scripts/run.sh
```

Automated pipeline:
1. Tears down any previous stack
2. Builds and deploys 12 containers (9 Java services + Pyroscope + Prometheus + Grafana)
3. Generates load across all endpoints
4. Validates health, metrics, profiles, and dashboards
5. Prints URLs when ready

Wait for the ready banner:

```
  ✔ Ready! Data is flowing to all dashboards.

    Grafana:    http://localhost:3000  (admin/admin)
    Pyroscope:  http://localhost:4040
```

Leave this terminal open. Load continues in the background.

For verbose output (useful for troubleshooting):
```bash
bash scripts/run.sh --verbose
```

### Step 2 — Metrics show the symptom

Open http://localhost:3000 (admin/admin).

1. Go to **Service Performance** (`/d/verticle-performance`)
   - Point out CPU usage, request rates, latency per service
   - "We can see API Gateway and Payment Service are consuming more CPU"
2. Go to **JVM Metrics Deep Dive** (`/d/jvm-metrics-deep-dive`)
   - Point out heap sawtooth (GC working), GC pause rate, thread counts
   - "Metrics confirm something is consuming CPU and memory. They don't tell us which function. That's where profiling comes in."

### Step 3 — CPU profiling identifies the cause

1. Go to **Pyroscope Java Overview** (`/d/pyroscope-java-overview`)
2. Select `bank-api-gateway` from the application dropdown
3. In the CPU flame graph, find the `fibonacci` frame — it dominates the profile
   - "Recursive Fibonacci, consuming ~40% of CPU. No logging, no debugging, no reproduction — the data was already there."
4. Switch to `bank-payment-service`
5. Find `MessageDigest.getInstance()` in the flame graph
   - "Payment service creates a new SHA-256 digest on every request instead of reusing one."

### Step 4 — Allocation profiling

1. Scroll to the **Memory Allocation** flame graph (same dashboard)
2. Select `bank-notification-service`
3. Find `String.format` / `Formatter.format` frames
   - "String.format inside a loop — each call creates Formatter, StringBuilder, char arrays. All garbage. That's why GC runs constantly."

### Step 5 — Mutex profiling

1. Scroll to the **Mutex Contention** flame graph
2. Select `bank-order-service`
3. Find `synchronized` block frames
   - "Synchronized method on a shared cache. Under concurrent load, threads queue for the lock. CPU available, throughput flat."

### Step 6 — Apply the fix, compare before/after

In a second terminal:

```bash
bash scripts/run.sh optimize
```

Restarts all services with `OPTIMIZED=true`:

| Service | Before | After |
|---------|--------|-------|
| API Gateway | Recursive `fibonacci()` | Iterative loop |
| Payment | `MessageDigest.getInstance()` per call | `ThreadLocal` reuse |
| Notification | `String.format` in loops | `StringBuilder` |
| Order | `synchronized` method | `ConcurrentHashMap` |
| Fraud | `Double` boxing in percentile calc | Primitive `double[]` + `Arrays.sort` |

Generate load on the optimized code:

```bash
bash scripts/run.sh load 60
```

Open **Before vs After Fix** (`/d/before-after-comparison`):

1. Select `bank-api-gateway`
2. Set the "Before" panel time range to cover the pre-optimize period
3. Set the "After" panel time range to cover the post-optimize period
4. "The fibonacci frame dominated before. After: gone. Iterative implementation, O(n) instead of O(2^n)."
5. Switch to `bank-payment-service`
6. "getInstance and String.format frames are gone. Not 'metrics look better' — the frame is eliminated."

### Step 7 — CLI tooling (optional, 2 min)

```bash
# Classify each service: CPU-bound, GC-bound, lock-bound, or healthy
bash scripts/run.sh bottleneck

# Top CPU-consuming functions across all services
bash scripts/run.sh top cpu

# Full diagnostic report
bash scripts/run.sh diagnose
```

"These scripts automate triage. In a real incident, `bottleneck` tells you which services need attention, `top` tells you which functions to look at — no browser needed."

### Step 8 — Teardown

```bash
bash scripts/run.sh teardown
```

---

## Part 4 — Cost and next steps (2 min)

Reference: [demo-guide.md](demo-guide.md), "Cost of Implementation" and "Outcomes and Use Cases."

| Profile Type | CPU Overhead |
|-------------|-------------|
| CPU | 1-3% |
| Wall clock | 1-2% |
| Allocation | 0.5-2% |
| Mutex | 0.1-0.5% |
| **All four combined** | **3-8%** |

Cover:
- Overhead is bounded by fixed sampling frequency, not request rate.
- Pyroscope is open source (AGPL-3.0). No per-host licensing.
- MTTR: 30-90 min investigation → 5-15 min lookup.
- Data is captured before the incident. No reproduction.

---

## Command Reference

| Action | Command |
|--------|---------|
| Start everything | `bash scripts/run.sh` |
| Start with optimized code only | `bash scripts/run.sh --fixed` |
| Verbose output | `bash scripts/run.sh --verbose` |
| Switch to optimized | `bash scripts/run.sh optimize` |
| Switch to unoptimized | `bash scripts/run.sh unoptimize` |
| Before/after comparison | `bash scripts/run.sh compare` |
| Generate load (60s) | `bash scripts/run.sh load 60` |
| Check health | `bash scripts/run.sh health` |
| Top functions by CPU | `bash scripts/run.sh top cpu` |
| Classify bottlenecks | `bash scripts/run.sh bottleneck` |
| Diagnostic report | `bash scripts/run.sh diagnose` |
| Validate stack | `bash scripts/run.sh validate` |
| Tear down | `bash scripts/run.sh teardown` |

---

## URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3000 | admin / admin |
| Pyroscope | http://localhost:4040 | — |
| Prometheus | http://localhost:9090 | — |

### Grafana dashboards

| Dashboard | Path |
|-----------|------|
| Pyroscope Java Overview | `/d/pyroscope-java-overview` |
| Service Performance | `/d/verticle-performance` |
| JVM Metrics Deep Dive | `/d/jvm-metrics-deep-dive` |
| HTTP Performance | `/d/http-performance` |
| Before vs After Fix | `/d/before-after-comparison` |
| FaaS Server | `/d/faas-server` |

---

## Troubleshooting

**Dashboards show "No data"**
1. Check time range picker is set to "Last 1 hour"
2. Check the dropdown matches a running service
3. Verify load is running (terminal should show curl output)
4. If stale after file changes: `bash scripts/run.sh teardown && bash scripts/run.sh`

**Service not responding**
```bash
bash scripts/run.sh health
```

**Flame graphs empty**
- Profiles take ~30 seconds to appear after load starts
- Check http://localhost:4040 and verify the application dropdown has entries

**Slow startup**
- First run builds 9 Docker images. Pre-build before the demo: `docker compose build`

---

## Follow-up docs

| Audience | Document |
|----------|----------|
| Everyone (start here) | [demo-guide.md](demo-guide.md) |
| Hands-on exercises | [profiling-scenarios.md](profiling-scenarios.md) |
| Implementation guide | [continuous-profiling-runbook.md](continuous-profiling-runbook.md) |
| Copy-paste queries | [sample-queries.md](sample-queries.md) |
| Dashboard reference | [dashboard-guide.md](dashboard-guide.md) |
| Code ↔ flame graph mapping | [code-to-profiling-guide.md](code-to-profiling-guide.md) |
| MTTR reduction | [mttr-guide.md](mttr-guide.md) |
| Architecture | [architecture.md](architecture.md) |

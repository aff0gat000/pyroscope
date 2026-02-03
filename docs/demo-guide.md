# Continuous Profiling Demo Guide

This document frames the demo for audiences unfamiliar with continuous profiling. It covers the problem, the solution, what this repository demonstrates, and the cost of implementation.

---

## The Problem

Production incidents follow a predictable pattern: an alert fires (high CPU, elevated latency, OOM restart), and the engineering team begins investigating. The investigation typically involves:

1. **Check metrics** — Prometheus confirms CPU is at 85%. Heap is near max. Latency p99 is 800ms. This confirms the symptom but not the cause.
2. **Check logs** — Application logs show normal request processing. No errors, no stack traces. The problem is in runtime behavior, not application-level events.
3. **Check traces** — Distributed traces show the slow service and the slow span, but not what the code is doing inside that span. A 400ms span could be CPU computation, lock contention, GC pauses, or a slow downstream call.
4. **Guess and iterate** — Add logging, redeploy, wait for reproduction, read the new logs, form a hypothesis, add more logging, redeploy again.

This cycle takes 30-90 minutes per incident. The gap is between symptom detection (metrics tell you *what* is wrong) and root cause identification (which function, class, and line of code is responsible).

### What existing tools do not show

| Tool | What It Shows | What It Does Not Show |
|------|-------------|----------------------|
| Prometheus / Metrics | CPU %, heap bytes, request rate, latency percentiles | Which method consumes the CPU or allocates the memory |
| Application Logs | Events the developer chose to log | Runtime behavior of code that does not log (hot loops, GC pressure, lock waits) |
| Distributed Tracing | Request flow across services, per-span latency | Internal code paths within a span — CPU vs I/O vs lock contention |
| Heap Dumps | Object retention at a single point in time | Allocation rate over time, which methods create short-lived garbage |
| Thread Dumps | Thread state at a single point in time | How long threads wait, which locks they contend on over time |

Each tool answers part of the question. None answers: "Which function in which service is consuming the most CPU / allocating the most memory / holding a lock the longest, and how has that changed over the last hour?"

---

## The Solution: Continuous Profiling

Continuous profiling samples what every thread in a running JVM is doing — which methods are on-CPU, where memory is allocated, and where threads wait on locks — and records this data continuously. The output is a **flame graph**: a visualization where each bar represents a function, and its width represents resource consumption.

### How it works (Java agent, zero code changes)

1. A Java agent (`pyroscope.jar`) attaches at JVM startup via `JAVA_TOOL_OPTIONS`
2. The agent uses async-profiler to sample thread stacks at ~100 Hz
3. Samples are aggregated into flame graph data and pushed to a Pyroscope server over HTTP
4. The Pyroscope server stores profiles and serves them via UI and API
5. Grafana connects to Pyroscope as a datasource for dashboarding alongside metrics

No application code changes. No bytecode modification. No recompilation. The agent is added as a JVM flag in the deployment configuration.

### What continuous profiling adds

| Profile Type | What It Captures | Incident Use Case |
|-------------|-----------------|-------------------|
| **CPU** | Which methods are actively executing | "CPU is at 85% — which function?" |
| **Allocation** | Where `new` objects are created | "GC is running constantly — what is allocating?" |
| **Mutex** | Threads blocked on `synchronized` / locks | "Throughput plateaued despite available CPU — where is the contention?" |
| **Wall clock** | All threads regardless of state | "Latency is high but CPU is low — what is the thread waiting on?" |

### How it changes incident response

| Phase | Without Profiling | With Profiling |
|-------|-------------------|----------------|
| Detection | Alert fires | Alert fires (same) |
| Triage | 5-15 min: check metrics, logs, guess | 30 sec: open flame graph for the alert time window |
| Root cause | 15-60 min: reproduce, attach debugger, read code | 2-5 min: read function names in flame graph |
| Verification | Redeploy, wait, check metrics | Compare before/after flame graphs side by side |
| **Total MTTR** | **30-90 min** | **5-15 min** |

The critical difference: profiling data is already captured when the incident occurs. Reproduction is unnecessary.

---

## What This Repository Demonstrates

This repository is a self-contained demo environment that deploys a realistic microservices architecture with continuous profiling enabled from the start. It is designed to be run locally with Docker Compose.

### Architecture

- **9 Java Vert.x services** — API Gateway, Order, Payment, Fraud Detection, Account, Loan, Notification, Stream Processing, FaaS Runtime
- **Pyroscope** — Continuous profiling backend (receives and stores profiles)
- **Prometheus** — Metrics collection (JVM metrics via JMX Exporter, HTTP metrics via Vert.x Micrometer)
- **Grafana** — 6 pre-built dashboards combining metrics and flame graphs

### What the demo shows

**1. Zero-code agent attachment**
Every service is profiled via a single environment variable (`JAVA_TOOL_OPTIONS`). No SDK integration, no code annotations, no build changes. This demonstrates that continuous profiling can be added to any Java service as a deployment configuration change.

**2. Four profile types running simultaneously**
CPU, allocation, mutex, and wall clock profiles are captured for all services. The demo includes workloads that exercise each type:
- CPU-bound: recursive algorithms, cryptographic hashing, matrix multiplication
- Allocation-heavy: string concatenation, `String.format` in loops, `BigDecimal` operations
- Lock contention: `synchronized` methods under concurrent load
- I/O simulation: `Thread.sleep`, retry backoff, fan-out with latency

**3. Before/after optimization**
Each service supports an `OPTIMIZED=true` mode that applies specific performance fixes. The demo pipeline runs both phases and produces side-by-side flame graph comparisons showing:
- `MessageDigest.getInstance()` per call → `ThreadLocal` reuse (CPU reduction)
- `String.format` in loops → `StringBuilder` (allocation reduction)
- `synchronized` method → `ConcurrentHashMap` (lock contention elimination)
- Cold-start verticle deploy → warm pool reuse (lifecycle overhead reduction)

**4. Metrics + profiling correlation**
Grafana dashboards display Prometheus metrics (CPU %, heap, GC rate, HTTP latency) alongside Pyroscope flame graphs. This demonstrates the workflow: metrics detect the symptom, flame graphs identify the cause.

**5. CLI tooling for automated triage**
Scripts automate the investigation workflow:
- `scripts/bottleneck.sh` — Classifies each service (CPU-bound, GC-bound, lock-bound, healthy) and identifies the top contributing function
- `scripts/top-functions.sh` — Lists the hottest functions by CPU, allocation, or mutex across all services
- `scripts/diagnose.sh` — Full diagnostic report combining health, HTTP stats, profile data, and alert status

### Quick start

```bash
bash scripts/run.sh          # Deploy, generate load, validate, wait for data
# Grafana:   http://localhost:3000 (admin/admin)
# Pyroscope: http://localhost:4040
bash scripts/run.sh teardown  # Clean up
```

---

## Outcomes and Use Cases

### Concrete outcomes

| Outcome | Without Profiling | With Profiling |
|---------|-------------------|----------------|
| **Identify the exact method causing a CPU alert** | Guess from metrics, add logging, redeploy, wait | Open flame graph for the alert window, read the widest frame |
| **Distinguish real bottlenecks from noise** | Anecdotal ("it feels slow") | Quantitative — frame width shows proportional resource consumption |
| **Prove a fix worked** | "Metrics look better, ship it" | Side-by-side flame graph comparison showing the hot frame eliminated |
| **Plan capacity from actual resource usage** | Extrapolate from CPU % and request rate | Know which functions consume resources and whether they scale linearly |
| **Onboard engineers to unfamiliar services** | Read code, guess hot paths | Flame graph shows what the service actually spends time doing |
| **Detect regressions before users notice** | Wait for alerts or complaints | Compare flame graphs across deploys — new frames or wider frames indicate regressions |

### Production use cases

**1. CPU spike triage**
An alert fires: CPU at 85%. Prometheus confirms the symptom. Open the CPU flame graph for that service and time window. The widest frame is the function consuming the most CPU. No reproduction needed, no logging changes, no redeployment.

**2. Memory leak and GC pressure**
GC runs constantly, heap usage climbs. The allocation flame graph shows which methods create the most short-lived objects. Fix the allocation pattern (e.g., move `String.format` out of a loop) and compare before/after allocation profiles to confirm the fix.

**3. Lock contention under load**
Throughput plateaus despite available CPU. The mutex profile shows which `synchronized` blocks or locks threads contend on. Replace with concurrent data structures or reduce critical section scope.

**4. Latency investigation when CPU is low**
P99 latency is high but CPU utilization is normal. The wall clock profile shows what threads are waiting on — downstream calls, DNS resolution, connection pool exhaustion, or sleep/backoff logic.

**5. Deployment regression detection**
After a deploy, compare the current flame graph with the previous period. New frames or significantly wider frames indicate code changes that increased resource consumption, even if metrics haven't yet triggered alerts.

**6. Cross-service bottleneck identification**
A request spans multiple services. Distributed tracing identifies the slow service and span. The flame graph for that service and time window identifies the slow function within the span, closing the gap between trace-level and code-level visibility.

### Why this is valuable

Metrics, logs, and traces answer **what** is happening and **where** in the request path. Profiling answers **why** — which function, which line, which resource consumption pattern. This is the difference between "payment-service is slow" and "`PaymentVerticle.sha256()` calls `MessageDigest.getInstance()` on every request, spending 40% of CPU on object creation."

The value compounds over time:
- **Always-on capture** means the data exists before the incident. No reproduction needed.
- **Low overhead** (3-8%) makes it safe for production, not just staging.
- **Function-level granularity** eliminates the guess-and-iterate cycle that dominates most incident investigations.
- **Before/after comparison** provides objective proof that a fix worked, replacing "it seems better" with "the frame is 80% narrower."

For organizations where production incidents cost engineering hours and customer trust, continuous profiling converts a 30-90 minute investigation into a 5-15 minute lookup.

---

## Cost of Implementation

### Agent overhead

| Profile Type | CPU Overhead | Mechanism |
|-------------|-------------|-----------|
| CPU | 1-3% | Timer signal at ~100 Hz |
| Wall clock | 1-2% | Same mechanism, all threads |
| Allocation | 0.5-2% | TLAB callback at 512 KB threshold |
| Mutex | 0.1-0.5% | Lock contention callback at 10 ms threshold |
| **All four combined** | **3-8%** | |

Overhead is bounded: a service handling 100 req/s and one handling 10,000 req/s generate the same ~100 stack samples per second. The profiler does not increase sampling with load.

### Resource consumption

| Resource | Impact |
|----------|--------|
| Agent memory | 20-40 MB per JVM for sample buffers and compression |
| Network | 10-50 KB per upload every 10 seconds (compressed) |
| Server storage | 1-5 GB per service per month (filesystem); less with object storage compression |
| Server CPU | Minimal — Pyroscope ingestion and query are lightweight |

### Comparison with alternatives

| Approach | Overhead | Root Cause Capability | Licensing Cost |
|----------|----------|-----------------------|----------------|
| Metrics only (Prometheus) | <1% | Identifies symptom, not cause | Free (open source) |
| APM agent (Datadog, New Relic) | 5-15% | Request-level latency; limited code-level detail | Per-host pricing ($15-35/host/month) |
| On-demand profiling (attach debugger) | 0% when off, 20-50% when on | Full detail, but only during reproduction | Free, but requires incident reproduction |
| **Continuous profiling (Pyroscope)** | **3-8%** | **Function-level CPU/memory/lock data, always-on** | **Free (open source, AGPL-3.0)** |

Pyroscope is open source with no per-host licensing. Grafana Cloud offers a managed Pyroscope service for teams that prefer not to self-host.

### When to implement

Continuous profiling provides the highest value when:
- Services have performance-sensitive workloads where 30-90 minute investigation cycles are costly
- The team lacks the ability to reproduce production performance issues in staging
- Multiple services interact and the bottleneck location is not obvious from metrics alone
- The organization wants to reduce MTTR systematically rather than per-incident

The 3-8% CPU overhead is acceptable for most production workloads. For ultra-low-latency services (sub-millisecond SLAs), start with CPU-only profiling (1-3% overhead) and add allocation/mutex profiling selectively.

---

## Documentation Map

After running the demo, use these documents for deeper exploration:

| Document | Audience | Content |
|----------|----------|---------|
| [continuous-profiling-runbook.md](continuous-profiling-runbook.md) | Engineers implementing Pyroscope | Step-by-step deployment, agent config, Grafana setup, JVM diagnostics |
| [profiling-scenarios.md](profiling-scenarios.md) | Engineers learning flame graph analysis | 6 hands-on scenarios with investigation workflows |
| [code-to-profiling-guide.md](code-to-profiling-guide.md) | Engineers correlating code with profiles | Source code → flame graph mapping for every service |
| [dashboard-guide.md](dashboard-guide.md) | Dashboard users | Panel-by-panel reference for all 6 Grafana dashboards |
| [mttr-guide.md](mttr-guide.md) | Engineering managers, SREs | MTTR reduction workflow, bottleneck decision matrix, observability outcomes |
| [architecture.md](architecture.md) | System architects | Service topology, data flow, JVM agent configuration |
| [runbook.md](runbook.md) | On-call engineers | Incident response playbooks, operational procedures |
| [faas-server.md](faas-server.md) | Engineers exploring FaaS profiling | FaaS runtime with deploy/undeploy lifecycle profiling |
| [ai-profiling-roadmap.md](ai-profiling-roadmap.md) | Technical leadership | Roadmap for AI/ML integration with profiling data |
| [sample-queries.md](sample-queries.md) | Engineers querying data | Copy-paste Pyroscope, Prometheus, and Grafana queries |

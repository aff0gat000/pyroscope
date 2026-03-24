# Frequently Asked Questions — Pyroscope and Continuous Profiling

Quick answers to common questions. Each answer links to the relevant document
for full detail.

---

## Table of Contents

- [Continuous profiling concepts](#continuous-profiling-concepts)
- [Pyroscope specifics](#pyroscope-specifics)
- [Security and compliance](#security-and-compliance)
- [Operations](#operations)
- [Development and integration](#development-and-integration)
- [Cost and licensing](#cost-and-licensing)

---

## Continuous profiling concepts

### What is continuous profiling?

Always-on, low-overhead sampling of what application code is doing at the function level.
A lightweight agent inspects every thread every 10ms, records which function is executing,
and streams the results to a central server. This runs continuously in production — not
during debugging sessions, but all the time, on every instance.

> **Deep dive:** [what-is-pyroscope.md § 1](what-is-pyroscope.md)

### How is it different from metrics (Prometheus)?

Metrics tell you **that** something is slow. Profiling tells you **why** — down to the exact
function and line of code. Metrics show symptoms (high latency, high CPU). Profiling shows
root causes (expensive regex, synchronous crypto, unbounded allocation).

| Tool | Tells you | Granularity | Example |
|------|-----------|-------------|---------|
| Prometheus metrics | CPU is at 90% | Service level | "Payment service is hot" |
| Continuous profiling | `MessageDigest.getInstance("SHA-256")` takes 34% of CPU | Function level | "SHA-256 in the auth filter is the bottleneck" |

### How is it different from distributed tracing (Jaeger/Tempo)?

Tracing shows **where** time is spent across services (network hops, queue waits).
Profiling shows **where** time is spent within a single service (which functions).
They are complementary — tracing narrows the problem to a service, profiling narrows
it to a function.

### How is it different from APM (Datadog, Dynatrace, New Relic)?

Commercial APMs bundle metrics, tracing, logging, and sometimes profiling into one
platform. Pyroscope focuses exclusively on continuous profiling — it does one thing
well, costs nothing, and you own the data. APMs charge per host per month
($15-35/host for profiling features).

> **Comparison table:** [what-is-pyroscope.md § 6](what-is-pyroscope.md)

### What is a flame graph?

A visualization where each bar represents a function, bar width represents time spent
in that function, and the y-axis shows the call stack. Wider bars = more time = where
to optimize. You read from bottom (entry point) to top (leaf functions).

> **Full guide:** [reading-flame-graphs.md](reading-flame-graphs.md)

### What profile types are collected?

| Profile type | What it measures | When to use |
|-------------|-----------------|-------------|
| CPU | Time spent executing code | High CPU usage, slow responses |
| Alloc (allocation) | Memory allocated by function | High GC pressure, memory growth |
| Lock (mutex) | Time spent waiting for locks | Contention, thread starvation |
| Wall clock | Elapsed real time per function | I/O waits, sleep, blocking calls |

### Does profiling replace logging?

No. Logs tell you **what happened** (errors, events, user actions). Profiling tells you
**how the code is performing** (which functions are slow, where memory is allocated).
Use both — they answer different questions.

---

## Pyroscope specifics

### What is Pyroscope?

An open-source continuous profiling platform maintained by Grafana Labs. It stores
profiling data, provides a query engine, and integrates with Grafana for visualization.
Licensed under AGPL-3.0 — free to deploy on-premise with no per-host or per-service fees.

> **Executive overview:** [what-is-pyroscope.md](what-is-pyroscope.md)

### What languages does Pyroscope support?

Java, Go, Python, Ruby, .NET, Rust, Node.js, and eBPF (any language). For JVM applications,
it uses JFR (Java Flight Recorder) which is built into every JDK since Java 11. No code
changes are needed — the agent attaches via `JAVA_TOOL_OPTIONS`.

### What are the deployment modes?

| Mode | Components | When to use |
|------|-----------|-------------|
| **Monolith** | Single process | Up to ~100 services, simplest to operate |
| **Microservices** | 7 components (distributor, ingester, querier, query-frontend, query-scheduler, compactor, store-gateway) | 100+ services, need HA, horizontal scaling |

> **Architecture details:** [architecture.md](architecture.md)
> **Decision trees:** [deployment-guide.md](deployment-guide.md)

### What are BOR and SOR functions?

Custom analysis functions built on top of Pyroscope:

- **BOR (Business Object Rules)** — business logic layer. Three functions: Triage (diagnose
  an application), Diff Report (compare pre/post deploy), Fleet Search (find hotspots across
  all services).
- **SOR (System of Record)** — data access layer. Wraps the Pyroscope API (Phase 1) and
  adds PostgreSQL persistence (Phase 2).

BORs call SORs. BORs never talk to Pyroscope or databases directly.

> **API reference:** [function-reference.md](function-reference.md)
> **Architecture:** [function-architecture.md](function-architecture.md)

### What is Phase 1 vs Phase 2?

| Aspect | Phase 1 | Phase 2 |
|--------|---------|---------|
| Pyroscope server | Monolith on VM | Optionally microservices on OCP |
| Functions | 3 BOR + 1 SOR | 3 BOR (v2) + 5 SOR |
| Database | None | PostgreSQL |
| Features | Triage, diff report, fleet search | + baselines, audit trails, ownership, alerts |

> **Project plan:** [project-plan-phase1.md](project-plan-phase1.md)

---

## Security and compliance

### Does the Java agent open any listening ports?

No. The agent is push-only — it makes outbound HTTP POST requests to the Pyroscope server
every 10 seconds. It opens no inbound ports and accepts no incoming connections.

### Does profiling data contain PII or sensitive business data?

No. Profiling data contains **function names, call stacks, and sample counts**. It does not
capture variable values, method arguments, return values, request payloads, database queries,
or any application data. It records *which* function was executing, not *what* it was processing.

### What network ports does Pyroscope use?

| Port | Protocol | Purpose | Required for |
|------|----------|---------|-------------|
| 4040 | HTTP | API, UI, agent ingestion | All modes |
| 9095 | gRPC | Inter-component communication | Microservices only |
| 7946 | TCP+UDP | Memberlist gossip | Microservices only |

> **Full port matrix:** [architecture.md § 7](architecture.md)
> **Firewall rules:** [deployment-guide.md § 17](deployment-guide.md)

### Is Pyroscope FIPS 140-2 compliant?

Pyroscope can be built with FIPS-compliant cryptography using three strategies:
`GOEXPERIMENT=boringcrypto` (most common), Red Hat Go Toolset (OpenSSL-backed), or
Go 1.24+ native FIPS module. TLS termination at the load balancer or reverse proxy
can also satisfy FIPS requirements without custom builds.

> **FIPS build details:** [deployment-guide.md § 5b](deployment-guide.md)

### What is the licensing model?

Pyroscope is AGPL-3.0. It is free to deploy on-premise. You do not need a commercial
license unless you modify the source code and distribute it externally. Internal deployment
does not trigger AGPL distribution requirements.

### Can it run air-gapped (no internet)?

Yes. Pull the container image once, push it to your internal registry, and deploy from there.
Pyroscope makes no outbound calls. The Java agent pushes to an internal URL only.

---

## Operations

### What is the performance overhead?

| Resource | Agent overhead | Notes |
|----------|:-------------:|-------|
| CPU | 3-8% | JFR sampling, bounded by sample interval |
| Memory | 20-40 MB | Agent buffer, constant regardless of application size |
| Network | 10-50 KB/upload | Compressed profile data every 10 seconds |

The overhead is bounded — it does not increase with application load, request volume,
or number of threads. JFR is built into the JVM and has been production-safe since Java 11.

> **Overhead data:** [what-is-pyroscope.md § 5](what-is-pyroscope.md)

### How much disk does Pyroscope use?

Approximately 1-5 GB per monitored service per month with default 24-hour retention.
A 100 GB disk supports roughly 20 services. Retention is configurable — longer retention
increases storage linearly.

### What happens if Pyroscope goes down?

- **Applications are unaffected.** The Java agent silently drops data if the server
  is unreachable. No errors, no retries that consume resources, no impact on latency.
- **Profiling data is lost** for the duration of the outage (profiling data is not queued).
- **Grafana dashboards show gaps** but continue to work once the server recovers.

### How do I know if profiles are being collected?

1. Open the Pyroscope UI at `http://<server>:4040`
2. Check the application dropdown — your service names should appear
3. Select an application — flame graph should render with recent data

If nothing appears, follow the diagnostic steps in [troubleshooting.md](troubleshooting.md).

### Can I back up Pyroscope data?

Yes. For monolith mode, back up the `/data` directory. For microservices mode with
object storage, use your object store's backup mechanism. PVC snapshots work for
Kubernetes deployments.

> **Backup procedures:** [pyroscope-reference-guide.md § Backup and restore](pyroscope-reference-guide.md)

---

## Development and integration

### How do I add the Java agent to my application?

Add the agent JAR to your container image and set one environment variable:

```
JAVA_TOOL_OPTIONS=-javaagent:/opt/pyroscope/pyroscope.jar
  -Dpyroscope.server.address=http://<pyroscope-vm>:4040
  -Dpyroscope.application.name=my-service
```

No code changes, no recompilation, no dependency additions.

> **Agent setup:** [deployment-guide.md § Tree 7](deployment-guide.md)
> **Properties reference:** [continuous-profiling-runbook.md](continuous-profiling-runbook.md)

### Does Pyroscope integrate with Grafana?

Yes. Pyroscope is a native Grafana datasource. Add it under Configuration → Data Sources →
Pyroscope. Flame graphs render directly in Grafana panels alongside your existing
Prometheus and Loki dashboards.

> **Setup guide:** [grafana-setup.md](grafana-setup.md)
> **Dashboard reference:** [dashboard-guide.md](dashboard-guide.md)

### Can I query Pyroscope from the command line?

Yes. The Pyroscope HTTP API is available at `http://<server>:4040`. Common queries:

```bash
# List all applications
curl http://<server>:4040/pyroscope/render?query=list

# Get CPU profile for a specific app
curl "http://<server>:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name=\"my-app\"}&from=now-1h&until=now"
```

> **Query examples:** [sample-queries.md](sample-queries.md)

### How do I compare two time periods (before/after a deploy)?

Use the Diff Report BOR function or the Pyroscope diff view in Grafana. Both compare
flame graphs from two time windows and highlight functions that got faster (green) or
slower (red).

> **Diff Report API:** [function-reference.md](function-reference.md)

---

## Cost and licensing

### How much does Pyroscope cost?

$0 for software licensing. The only costs are infrastructure (1 VM for monolith mode)
and engineering time to deploy and maintain.

| Cost category | Pyroscope | Commercial APM (50 hosts) |
|--------------|:---------:|:------------------------:|
| Software license | $0/year | $9,000-21,000/year |
| Infrastructure | 1 VM (existing fleet) | Included in SaaS price |
| Engineering | 7-10 weeks Phase 1 | 1-2 weeks (vendor-managed) |
| Data ownership | You own all data | Vendor retains data |

> **Full cost analysis:** [what-is-pyroscope.md § 5](what-is-pyroscope.md)
> **Project timeline:** [project-plan-phase1.md § 5](project-plan-phase1.md)

### Why not just use Datadog / New Relic / Dynatrace?

Three reasons:

1. **Cost.** Commercial profiling features cost $15-35 per host per month. At 50 hosts,
   that is $9,000-21,000/year. Pyroscope is free.
2. **Data sovereignty.** Profiling data stays on your infrastructure. No data leaves your
   network. No vendor lock-in.
3. **Air-gapped support.** Commercial APMs require internet connectivity for their SaaS
   backend. Pyroscope runs entirely on-premise.

If your organization already has a commercial APM with profiling features included in
your contract, it may be simpler to use that. Pyroscope is the clear choice when
profiling is not already bundled or when air-gapped / data-sovereignty requirements exist.

> **Competitive analysis:** [pyroscope-reference-guide.md § Competitive analysis](pyroscope-reference-guide.md)

### What is the ROI?

The primary return is **MTTR reduction**. With continuous profiling, root-cause identification
drops from 30-90 minutes (manual flame graph analysis during an incident) to 5-15 minutes
(data already captured, automated triage available). For a team handling 2-4 performance
incidents per month, this saves 2-6 engineering hours per month.

Secondary returns include:
- Catching performance regressions before they reach production (diff report)
- Proactive optimization of fleet-wide hotspots (fleet search)
- Eliminating the need for expensive commercial profiling tools

> **MTTR data:** [what-is-pyroscope.md § 4](what-is-pyroscope.md)

---

## References

| Document | Description |
|----------|-------------|
| [what-is-pyroscope.md](what-is-pyroscope.md) | Executive overview and business case |
| [reading-flame-graphs.md](reading-flame-graphs.md) | How to read flame graphs |
| [architecture.md](architecture.md) | Component internals and topology diagrams |
| [deployment-guide.md](deployment-guide.md) | Step-by-step deployment with decision trees |
| [project-plan-phase1.md](project-plan-phase1.md) | Phase 1 project plan and timeline |
| [function-reference.md](function-reference.md) | BOR/SOR API reference |
| [pyroscope-reference-guide.md](pyroscope-reference-guide.md) | Reference guide and competitive analysis |
| [troubleshooting.md](troubleshooting.md) | Diagnostic procedures |

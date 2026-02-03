# Sample Queries Reference

Copy-paste queries for Pyroscope, Prometheus, and Grafana. Each query includes context on when and why to use it.

Ports assume defaults from `.env`. Replace `4040`, `9090`, `3000` if you remapped them.

---

## Services and Profile Types

### All 9 services

| Service | Pyroscope Application Name | HTTP Port | JMX Port |
|---------|---------------------------|-----------|----------|
| API Gateway | `bank-api-gateway` | 18080 | 9404 |
| Order Service | `bank-order-service` | 18081 | 9404 |
| Payment Service | `bank-payment-service` | 18082 | 9404 |
| Fraud Service | `bank-fraud-service` | 18083 | 9404 |
| Account Service | `bank-account-service` | 18084 | 9404 |
| Loan Service | `bank-loan-service` | 18085 | 9404 |
| Notification Service | `bank-notification-service` | 18086 | 9404 |
| Stream Service | `bank-stream-service` | 18087 | 9404 |
| FaaS Server | `bank-faas-server` | 8088 | 9404 |

### All 8 profile types

| Profile Type ID | Short Name | What It Captures | When To Use |
|----------------|-----------|-----------------|-------------|
| `process_cpu:cpu:nanoseconds:cpu:nanoseconds` | CPU | Methods actively executing on CPU | "CPU is high — which function?" |
| `wall:wall:nanoseconds:wall:nanoseconds` | Wall clock | All threads regardless of state (on-CPU, blocked, sleeping) | "Latency is high but CPU is low — what are threads waiting on?" |
| `memory:alloc_in_new_tlab_bytes:bytes:space:bytes` | Alloc (bytes) | Where `new` objects are created, measured in bytes | "GC runs constantly — what is allocating the most memory?" |
| `memory:alloc_in_new_tlab_objects:count:space:bytes` | Alloc (objects) | Where `new` objects are created, measured in object count | "GC runs constantly — what creates the most short-lived objects?" |
| `mutex:contentions:count:mutex:count` | Mutex (count) | How many times threads block on `synchronized` / locks | "Throughput plateaued — where is lock contention?" |
| `mutex:delay:nanoseconds:mutex:count` | Mutex (delay) | Total time threads spend waiting on locks | "Threads are blocked — how long are they waiting?" |
| `block:contentions:count:block:count` | Block (count) | Thread block events (I/O, park, sleep) | "Threads are parked — how often?" |
| `block:delay:nanoseconds:block:count` | Block (delay) | Total time threads spend in blocked state | "Threads are parked — for how long?" |

---

## Pyroscope UI Queries

Open http://localhost:4040.

### Label selectors

Paste these into the Pyroscope UI "Label Selector" field after selecting a profile type.

**Single service:**
```
{service_name="bank-api-gateway"}
```

**Filter by environment label:**
```
{service_name="bank-api-gateway", env="production"}
```

**All services (regex):**
```
{service_name=~"bank-.*"}
```

### Comparison view

Use the Pyroscope Comparison view to diff two time ranges or two services. This is the primary tool for verifying that a code change reduced resource consumption.

1. Open Pyroscope UI → Comparison view
2. Left panel: `{service_name="bank-api-gateway"}` with time range covering the "before" period
3. Right panel: same selector with time range covering the "after" period
4. Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
5. Red frames = increased in the right panel, green = decreased

**Useful comparisons:**

| Left | Right | What It Shows |
|------|-------|--------------|
| `bank-api-gateway` (before fix) | `bank-api-gateway` (after fix) | Whether the optimization reduced CPU/alloc/mutex |
| `bank-payment-service` | `bank-fraud-service` | Compare CPU patterns between payment processing and fraud detection |
| `bank-order-service` (CPU) | `bank-order-service` (mutex) | Whether a service is CPU-bound or lock-bound |

---

## Pyroscope HTTP API (curl)

These queries hit the Pyroscope server directly. Useful for scripting, CI checks, and debugging without a browser.

### List all applications reporting profiles

**Why:** Verify all 9 services are sending profile data to Pyroscope.

```bash
curl -s "http://localhost:4040/querier.v1.QuerierService/LabelValues" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"name":"service_name"}'
```

### List all available profile types

**Why:** Confirm which profile types the agents are producing. You should see all 8 types listed above.

```bash
curl -s "http://localhost:4040/pyroscope/label-values?label=__name__&name=process_cpu:cpu:nanoseconds:cpu:nanoseconds" \
  | python3 -m json.tool
```

### Render a CPU profile as JSON

**Why:** Fetch raw flame graph data for a specific service and time range. Useful for automated analysis or piping into scripts.

```bash
# API Gateway — last 1 hour
curl -s "http://localhost:4040/pyroscope/render" \
  --data-urlencode 'query=process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name="bank-api-gateway"}' \
  --data-urlencode 'from=now-1h' \
  --data-urlencode 'until=now' \
  --data-urlencode 'format=json' \
  | python3 -m json.tool | head -50
```

Replace `bank-api-gateway` with any service name. Replace the profile type ID with any from the table above.

### Render a memory allocation profile

**Why:** Identify which methods allocate the most memory. Useful when investigating GC pressure.

```bash
curl -s "http://localhost:4040/pyroscope/render" \
  --data-urlencode 'query=memory:alloc_in_new_tlab_bytes:bytes:space:bytes{service_name="bank-payment-service"}' \
  --data-urlencode 'from=now-1h' \
  --data-urlencode 'until=now' \
  --data-urlencode 'format=json' \
  | python3 -m json.tool | head -50
```

### Render a mutex contention profile

**Why:** Find which `synchronized` blocks or locks cause thread contention. The Order Service is a good target — it uses `synchronized` methods under concurrent load.

```bash
curl -s "http://localhost:4040/pyroscope/render" \
  --data-urlencode 'query=mutex:contentions:count:mutex:count{service_name="bank-order-service"}' \
  --data-urlencode 'from=now-1h' \
  --data-urlencode 'until=now' \
  --data-urlencode 'format=json' \
  | python3 -m json.tool | head -50
```

---

## Prometheus Queries (PromQL)

Use these in Grafana Explore (select the Prometheus datasource) or query directly via the Prometheus API at http://localhost:9090.

Two Prometheus jobs scrape the services:
- `job="jvm"` — JVM metrics from JMX Exporter on port 9404 (CPU, heap, GC, threads)
- `job="vertx-apps"` — HTTP metrics from Vert.x Micrometer on port 8080 (request rate, latency, errors)

### CPU and compute

**CPU usage per service**

Why: First check during a CPU alert. Shows which service is consuming CPU.

```promql
rate(process_cpu_seconds_total{job="jvm"}[1m])
```

**CPU usage for a single service**

Why: Drill into one service after identifying it from the overview.

```promql
rate(process_cpu_seconds_total{job="jvm", instance="api-gateway:9404"}[1m])
```

### Memory and GC

**Heap memory used per service**

Why: Spot services approaching heap limits. A rising baseline indicates a memory leak.

```promql
sum by (instance) (jvm_memory_used_bytes{job="jvm", area="heap"})
```

**Heap utilization percentage**

Why: More actionable than raw bytes. Above 85% means GC is working hard to reclaim space.

```promql
sum by (instance) (jvm_memory_used_bytes{job="jvm", area="heap"})
/
sum by (instance) (jvm_memory_max_bytes{job="jvm", area="heap"}) > 0
```

**GC pause rate (seconds spent in GC per second)**

Why: Above 0.05 (5% of time in GC) warrants investigation. Use the allocation flame graph to find what is allocating.

```promql
sum by (instance, gc) (rate(jvm_gc_collection_seconds_sum{job="jvm"}[1m]))
```

**GC collection count rate**

Why: Frequent minor GCs indicate high allocation rate. Frequent major GCs indicate heap pressure.

```promql
sum by (instance, gc) (rate(jvm_gc_collection_seconds_count{job="jvm"}[1m]))
```

**Memory pool utilization (per pool)**

Why: Identify which memory pool (Eden, Survivor, Old Gen, Metaspace) is under pressure.

```promql
jvm_memory_pool_used_bytes{job="jvm"} / jvm_memory_pool_max_bytes{job="jvm"} > 0
```

### Threads

**Thread count per service**

Why: A monotonically rising thread count indicates a thread leak. Correlate with wall clock / mutex flame graphs.

```promql
jvm_threads_current{job="jvm"}
```

**Thread count rate of change**

Why: Positive rate for an extended period confirms a thread leak.

```promql
deriv(jvm_threads_current{job="jvm"}[5m])
```

### File descriptors

**Open file descriptors**

Why: A rising count can indicate connection leaks or file handle leaks.

```promql
process_open_fds{job="jvm"}
```

**File descriptor utilization**

Why: Approaching 100% causes "Too many open files" errors.

```promql
process_open_fds{job="jvm"} / process_max_fds{job="jvm"}
```

### Classloader

**Classes currently loaded**

Why: A rising count in a long-running JVM can indicate classloader leaks, common with dynamic class generation or repeated deployments.

```promql
jvm_classes_currently_loaded{job="jvm"}
```

### HTTP performance

**Request rate by endpoint**

Why: Understand traffic distribution. Identify which endpoints receive the most load.

```promql
sum by (route) (rate(vertx_http_server_requests_total{job="vertx-apps"}[1m]))
```

**Request rate by service**

Why: Compare overall load across services.

```promql
sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps"}[1m]))
```

**Average latency by endpoint**

Why: Find the slowest endpoints. Correlate with the wall clock flame graph to find what the code is waiting on inside slow endpoints.

```promql
sum by (route) (rate(vertx_http_server_response_time_seconds_sum{job="vertx-apps"}[1m]))
/
sum by (route) (rate(vertx_http_server_response_time_seconds_count{job="vertx-apps"}[1m]))
```

**Average latency by service**

Why: Identify which service is the latency bottleneck in a request chain.

```promql
sum by (instance) (rate(vertx_http_server_response_time_seconds_sum{job="vertx-apps"}[1m]))
/
sum by (instance) (rate(vertx_http_server_response_time_seconds_count{job="vertx-apps"}[1m]))
```

**5xx error rate**

Why: Detect error spikes. Correlate with CPU/heap/GC metrics to determine if errors are caused by resource exhaustion.

```promql
sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps", code=~"5.."}[1m]))
```

**Error rate as percentage of total**

Why: A low absolute error rate on a low-traffic service may still be a high percentage.

```promql
sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps", code=~"5.."}[1m]))
/
sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps"}[1m]))
```

**Top 10 slowest endpoints**

Why: Quick triage — immediately shows which endpoints need attention.

```promql
topk(10,
  sum by (route) (rate(vertx_http_server_response_time_seconds_sum{job="vertx-apps"}[5m]))
  /
  sum by (route) (rate(vertx_http_server_response_time_seconds_count{job="vertx-apps"}[5m]))
)
```

### Alerting queries

These queries can be used as Prometheus alerting rules or Grafana alert conditions.

**High CPU (above 80% for 5 minutes)**

```promql
rate(process_cpu_seconds_total{job="jvm"}[5m]) > 0.8
```

**High GC pressure (above 5% time in GC)**

```promql
sum by (instance) (rate(jvm_gc_collection_seconds_sum{job="jvm"}[5m])) > 0.05
```

**Heap above 85%**

```promql
sum by (instance) (jvm_memory_used_bytes{job="jvm", area="heap"})
/
sum by (instance) (jvm_memory_max_bytes{job="jvm", area="heap"})
> 0.85
```

**Thread leak (thread count rising)**

```promql
deriv(jvm_threads_current{job="jvm"}[10m]) > 0.5
```

**Error rate above 1%**

```promql
sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps", code=~"5.."}[5m]))
/
sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps"}[5m]))
> 0.01
```

---

## Grafana Explore (Pyroscope Datasource)

Open http://localhost:3000/explore, select the **Pyroscope** datasource.

### Investigate a CPU spike

**Why:** An alert fires for high CPU on the API Gateway. The Prometheus query tells you CPU is high. The flame graph tells you which function.

- Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
- Label selector: `{service_name="bank-api-gateway"}`
- Time range: match the alert window

### Investigate GC pressure

**Why:** GC rate is high. The allocation flame graph shows which methods create the most objects.

- Profile type: `memory:alloc_in_new_tlab_bytes:bytes:space:bytes`
- Label selector: `{service_name="bank-payment-service"}`

### Investigate lock contention

**Why:** Throughput is flat despite available CPU. The mutex profile shows which locks threads contend on.

- Profile type: `mutex:contentions:count:mutex:count`
- Label selector: `{service_name="bank-order-service"}`

### Investigate high latency with low CPU

**Why:** P99 latency is high but CPU is normal. The wall clock profile shows what threads are waiting on (I/O, sleep, downstream calls).

- Profile type: `wall:wall:nanoseconds:wall:nanoseconds`
- Label selector: `{service_name="bank-stream-service"}`

### Investigate FaaS cold start overhead

**Why:** FaaS invocations show high latency on first call. The wall clock profile reveals verticle deployment and classloader overhead.

- Profile type: `wall:wall:nanoseconds:wall:nanoseconds`
- Label selector: `{service_name="bank-faas-server"}`

---

## Grafana Dashboards

All 6 dashboards are provisioned under the **Pyroscope** folder at http://localhost:3000.

| Dashboard | URL | What It Shows |
|-----------|-----|--------------|
| Pyroscope Java Overview | `/d/pyroscope-java-overview` | CPU, allocation, and mutex flame graphs with JVM metrics for all services |
| Service Performance | `/d/verticle-performance` | Per-service HTTP rates, latency, JVM metrics, and a flame graph panel |
| JVM Metrics Deep Dive | `/d/jvm-metrics-deep-dive` | Heap pools, GC pauses, threads, classloading, file descriptors |
| HTTP Performance | `/d/http-performance` | Request rate, latency, error rate, slowest endpoints across all services |
| Before vs After Fix | `/d/before-after-comparison` | Side-by-side flame graphs for comparing before and after optimization |
| FaaS Server | `/d/faas-server` | FaaS-specific metrics: deploy rate, invocation count, cold vs warm start |

### Template variables

Most dashboards have dropdowns at the top:

- **application / pyroscope_app** — Select which service's flame graph to display
- **profile_type** — Switch between CPU, allocation, mutex, wall clock, block profiles
- **service / instance** — Filter Prometheus panels to a specific service

### Troubleshooting "No data"

1. Verify load has been running for at least 30 seconds
2. Set the time range picker (top right) to "Last 1 hour"
3. Confirm the template variable matches a running service
4. If dashboards are stale after file changes, tear down and redeploy:
   ```bash
   bash scripts/run.sh teardown
   bash scripts/run.sh
   ```

---

## CLI Tools

### Top functions

Find the hottest functions without opening a browser.

```bash
# All services, all profile types
bash scripts/top-functions.sh

# CPU profile for one service
bash scripts/top-functions.sh cpu bank-api-gateway

# Memory allocation, top 20 functions
bash scripts/top-functions.sh memory --top 20

# Mutex contention, last 30 minutes
bash scripts/top-functions.sh mutex --range 30m
```

### Bottleneck classification

Classify each service as CPU-bound, GC-bound, lock-bound, or healthy.

```bash
bash scripts/bottleneck.sh
```

### Full diagnostic report

Combines health checks, HTTP stats, profile data, and alert status.

```bash
bash scripts/diagnose.sh
```

---

## Quick Smoke Test

Run after deploying to verify the full stack is working. All 9 services, both Prometheus jobs, Pyroscope ingestion, and all 6 Grafana dashboards.

```bash
source .env 2>/dev/null

# 1. All 9 services responding
for pair in \
  "API Gateway:${API_GATEWAY_PORT:-18080}" \
  "Order:${ORDER_SERVICE_PORT:-18081}" \
  "Payment:${PAYMENT_SERVICE_PORT:-18082}" \
  "Fraud:${FRAUD_SERVICE_PORT:-18083}" \
  "Account:${ACCOUNT_SERVICE_PORT:-18084}" \
  "Loan:${LOAN_SERVICE_PORT:-18085}" \
  "Notification:${NOTIFICATION_SERVICE_PORT:-18086}" \
  "Stream:${STREAM_SERVICE_PORT:-18087}" \
  "FaaS:${FAAS_PORT:-8088}"; do
  name="${pair%%:*}"; port="${pair##*:}"
  curl -sf --max-time 3 "http://localhost:$port/health" >/dev/null 2>&1 \
    && echo "  [OK]   $name (:$port)" \
    || echo "  [FAIL] $name (:$port)"
done

# 2. Prometheus scraping JVM metrics (expect 9 targets)
echo ""
echo "Prometheus JVM targets:"
curl -s "http://localhost:${PROMETHEUS_PORT:-9090}/api/v1/query" \
  --data-urlencode 'query=count(up{job="jvm"} == 1)' \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(f'  {r[0][\"value\"][1]} of 9 up') if r else print('  0 of 9 up')"

# 3. Prometheus scraping Vert.x metrics (expect 9 targets)
echo "Prometheus Vert.x targets:"
curl -s "http://localhost:${PROMETHEUS_PORT:-9090}/api/v1/query" \
  --data-urlencode 'query=count(up{job="vertx-apps"} == 1)' \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(f'  {r[0][\"value\"][1]} of 9 up') if r else print('  0 of 9 up')"

# 4. Pyroscope receiving profiles
echo ""
echo "Pyroscope profile types:"
curl -s "http://localhost:${PYROSCOPE_PORT:-4040}/pyroscope/label-values?label=__name__&name=process_cpu:cpu:nanoseconds:cpu:nanoseconds" \
  | python3 -c "import json,sys; types=json.load(sys.stdin); print(f'  {len(types)} profile types ingested')"

# 5. Grafana datasources
echo ""
echo "Grafana datasources:"
curl -s -u admin:admin "http://localhost:${GRAFANA_PORT:-3000}/api/datasources" \
  | python3 -c "import json,sys; [print(f'  {ds[\"name\"]} ({ds[\"type\"]})') for ds in json.load(sys.stdin)]"

# 6. All 6 dashboards provisioned
echo ""
echo "Grafana dashboards:"
for uid in pyroscope-java-overview verticle-performance jvm-metrics-deep-dive http-performance before-after-comparison faas-server; do
  title=$(curl -s -u admin:admin "http://localhost:${GRAFANA_PORT:-3000}/api/dashboards/uid/$uid" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['dashboard']['title'])" 2>/dev/null)
  echo "  ${title:-MISSING}: /d/$uid"
done
```

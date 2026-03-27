# Pyroscope Monitoring Guide

How to monitor the health and performance of the Pyroscope server itself.

---

## Health Check Endpoints

| Endpoint | Method | Expected Response | Purpose |
|----------|--------|-------------------|---------|
| `/ready` | GET | `200 OK` (empty body) | Liveness/readiness probe — server is accepting traffic |
| `/metrics` | GET | `200` with Prometheus text format | Prometheus scrape endpoint |
| `/pyroscope/label-values?label=__name__` | GET | `200` with JSON array of application names | Data availability — confirms profiles are being ingested |

Quick verification:

```bash
# Server health
curl -sf http://<pyroscope-vm>:4040/ready && echo "OK" || echo "FAIL"

# Profiles being ingested (should list your application names)
curl -s "http://<pyroscope-vm>:4040/pyroscope/label-values?label=service_name" | python3 -m json.tool

# Prometheus metrics available
curl -s http://<pyroscope-vm>:4040/metrics | head -20
```

Cross-ref: [troubleshooting.md](troubleshooting.md) for full diagnostic procedures when checks fail.

---

## Prometheus Metrics Reference

Key metrics exported by the Pyroscope server process:

### Ingestion Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `pyroscope_ingestion_received_profiles_total` | Counter | Total profiles received (rate = profiles/second) |
| `pyroscope_ingestion_received_bytes_total` | Counter | Total bytes received from agents |
| `pyroscope_distributor_bytes_received_total` | Counter | Bytes processed by the distributor component |

### Storage Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `pyroscope_tsdb_head_samples_appended_total` | Counter | Samples written to the head block |
| `pyroscope_tsdb_compactions_total` | Counter | Number of compaction cycles completed |
| `pyroscope_tsdb_blocks_loaded` | Gauge | Current number of loaded storage blocks |

### Query Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `pyroscope_query_frontend_queries_total` | Counter | Total query requests |
| `pyroscope_query_frontend_queue_duration_seconds` | Histogram | Time spent in query queue |

### Process Metrics (Standard Go)

| Metric | Type | Description |
|--------|------|-------------|
| `process_cpu_seconds_total` | Counter | Total CPU time consumed by Pyroscope |
| `process_resident_memory_bytes` | Gauge | Resident memory of the Pyroscope process |
| `go_goroutines` | Gauge | Number of goroutines |

**Scrape health:**
`up{job="pyroscope"}` — Prometheus scrape success (1 = up, 0 = down)

---

## Prometheus Scrape Configuration

```yaml
# Add to your existing prometheus.yml
scrape_configs:
  - job_name: "pyroscope"
    scrape_interval: 15s
    static_configs:
      - targets: ["<pyroscope-vm>:4040"]
```

After adding, reload Prometheus:

```bash
curl -X POST http://localhost:9090/-/reload
```

Cross-ref: [deployment-guide.md](deployment-guide.md) for full Prometheus integration steps.

---

## Recommended Alert Rules

These rules target the **Pyroscope server itself** (not the profiled applications).

```yaml
# Add to your Prometheus alerting rules
groups:
  - name: pyroscope-server
    rules:
      - alert: PyroscopeDown
        expr: up{job="pyroscope"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Pyroscope server is unreachable"
          runbook: "Check: docker ps | grep pyroscope; docker logs pyroscope --tail 50"

      - alert: PyroscopeIngestionStopped
        expr: rate(pyroscope_ingestion_received_profiles_total{job="pyroscope"}[10m]) == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "No profiles received in 10 minutes"
          runbook: "Check agent connectivity and OCP pod health"

      - alert: PyroscopeHighMemory
        expr: process_resident_memory_bytes{job="pyroscope"} > 3.2e9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Pyroscope memory usage above 3.2 GB (80% of 4 GB)"
          runbook: "Check for high-cardinality labels or reduce retention"

      - alert: PyroscopeHighCPU
        expr: rate(process_cpu_seconds_total{job="pyroscope"}[5m]) > 1.6
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Pyroscope CPU usage above 80% of 2 cores"
          runbook: "Check ingestion rate and query volume"
```

Note: The existing `config/prometheus/alerts.yaml` contains 6 rules for profiled applications (`job="jvm"` / `job="vertx-apps"`). The rules above are for the Pyroscope server itself and should be added separately.

### Alert Summary

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| PyroscopeDown | Server unreachable for 2 min | Critical | Restart container, check Docker/VM health |
| PyroscopeIngestionStopped | No profiles for 10 min | Warning | Check agent connectivity, OCP pod status |
| PyroscopeHighMemory | > 80% of allocated RAM | Warning | Reduce retention, check label cardinality |
| PyroscopeHighCPU | > 80% of allocated CPU | Warning | Check ingestion rate, add resources |

---

## Grafana Health Dashboard

Suggested panels for a Pyroscope health dashboard (create manually in Grafana):

| Panel | Metric / Query | Visualization | Threshold |
|-------|----------------|---------------|-----------|
| Server Status | `up{job="pyroscope"}` | Stat (1=Up, 0=Down) | Green: 1, Red: 0 |
| Ingestion Rate | `rate(pyroscope_ingestion_received_profiles_total[5m])` | Time series | Yellow: < 1/s |
| Memory Usage | `process_resident_memory_bytes{job="pyroscope"}` | Gauge | Yellow: 70%, Red: 85% |
| CPU Usage | `rate(process_cpu_seconds_total{job="pyroscope"}[5m])` | Gauge | Yellow: 60%, Red: 80% |
| Storage Blocks | `pyroscope_tsdb_blocks_loaded` | Stat | Informational |
| Query Latency (p95) | `histogram_quantile(0.95, pyroscope_query_frontend_queue_duration_seconds_bucket)` | Time series | Yellow: 3s, Red: 10s |

Cross-ref: [grafana-setup.md](grafana-setup.md) for Grafana datasource configuration.
Cross-ref: dashboard-guide.md (available in the repo at docs/dashboard-guide.md) for existing application dashboards.

---

## Capacity Alerts

Monitor disk growth to prevent ingestion failure:

```bash
# VM deployments — check Docker volume size
docker system df -v 2>/dev/null | grep pyroscope-data

# K8s/OCP — check PVC usage
kubectl exec -n monitoring deploy/pyroscope -- df -h /data
```

Alert thresholds:

- **Warning** at 75% disk used — plan expansion or reduce retention
- **Critical** at 90% disk used — immediate action required

Cross-ref: [capacity-planning.md](capacity-planning.md) for sizing formulas and scaling triggers.
Cross-ref: [configuration-reference.md](configuration-reference.md) for `compactor.blocks_retention_period`.

# Service Level Objectives

Defines service level objectives and recovery targets for the Pyroscope deployment.

---

## Service Classification

Pyroscope is a **non-critical observability tool**. Profiling data loss during outages does not impact application availability or business operations. Applications continue to function normally — the Java agent silently drops data when the server is unreachable.

Cross-ref: [adr/ADR-001-continuous-profiling.md](adr/ADR-001-continuous-profiling.md) — decision driver D8 classifies HA as Low priority.

---

## Phase 1 SLO Definitions

These are **recommended targets** (not yet agreed with stakeholders).

### Data Availability

- Target: 95% of 10-second push intervals successfully ingested
- Measurement: `rate(pyroscope_ingestion_received_profiles_total[5m]) > 0`
- Rationale: Non-critical tool; 5% error budget allows for maintenance windows and brief outages

### Query Latency

- Target: p95 < 5 seconds for single-application flame graph queries
- Target: p95 < 30 seconds for fleet search (all services)
- Measurement: `histogram_quantile(0.95, pyroscope_query_duration_seconds_bucket)`

### Ingestion Success Rate

- Target: 99% of agent pushes acknowledged within 30 seconds
- Note: Agent retries with exponential backoff; brief server restarts cause no data loss

---

## RPO and RTO

| Metric | Target | Notes |
|--------|--------|-------|
| RPO (Recovery Point Objective) | ~2 minutes | Agent buffers ~2 minutes of data before dropping on server unavailability |
| RTO (Recovery Time Objective) | < 5 minutes | `docker restart pyroscope` recovers the service; data volume is persistent |
| Data loss on VM failure | Up to 2 minutes | Profiles in the agent buffer are lost; all previously ingested data survives in the Docker volume |

---

## Error Budget

For a 95% data availability SLO over a 30-day month:

- Error budget = 5% x 30 days x 24 hours = **36 hours**
- This means: up to 36 hours of total downtime per month is within the SLO
- This is intentionally generous — Pyroscope is a non-critical observability tool

Monthly budget consumption examples:

| Event | Duration | Budget Used |
|-------|----------|-------------|
| Planned maintenance (monthly VM patching) | 30 minutes | 1.4% |
| Container restart (after config change) | 2 minutes | 0.1% |
| Unplanned outage (VM failure + recovery) | 1 hour | 2.8% |

---

## Monitoring Against SLOs

Cross-ref: [monitoring-guide.md](monitoring-guide.md) for Prometheus metrics and alert rules.

Key signals:

- `up{job="pyroscope"}` — server reachability (1 = up, 0 = down)
- `pyroscope_ingestion_received_profiles_total` — ingestion rate (should be > 0 during business hours)
- Pyroscope UI at `http://<server>:4040` — manual verification

---

## Escalation Matrix

| Scenario | First Responder | Escalation | Threshold |
|----------|-----------------|------------|-----------|
| Server down < 5 minutes | On-call SRE | No escalation needed | Within RTO |
| Server down 5-30 minutes | On-call SRE | Notify engineering lead | Approaching SLO impact |
| Server down > 30 minutes | Engineering lead | Notify project owner | SLO breach risk |
| Data loss > 2 hours | Engineering lead | Project owner + stakeholders | Exceeds RPO significantly |
| Storage > 85% capacity | On-call SRE | Engineering lead | Risk of ingestion failure |

---

## Phase 2 and Phase 3 SLO Targets

### Phase 2 (Multi-VM monolith with S3-compatible object storage)

| SLO | Phase 1 | Phase 2 |
|-----|---------|---------|
| Data availability | 95% | 99% |
| Query latency (p95) | < 5s | < 5s |
| RPO | ~2 minutes | ~2 minutes (S3-compatible object storage) |
| RTO | < 5 minutes | < 2 minutes (VIP failover to standby VM) |

### Phase 3 (Microservices on OpenShift)

| SLO | Phase 2 | Phase 3 |
|-----|---------|---------|
| Data availability | 99% | 99.5% |
| Query latency (p95) | < 5s | < 2s |
| RPO | ~2 minutes | ~30 seconds (replicated ingesters) |
| RTO | < 2 minutes | < 1 minute (pod rescheduling) |

Cross-ref: [project-plan-phase2.md](project-plan-phase2.md) and [project-plan-phase3.md](project-plan-phase3.md) for scope.

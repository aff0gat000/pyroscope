# Observability SLOs, Measures, and Controls

Service level objectives, observability measures, operational controls, and
escalation procedures for the Pyroscope continuous profiling platform.

Covers the four pillars of observability governance [^sre-book]: **SLIs** (what we
measure), **SLOs** (what we commit to), **error budgets** (how much failure is
acceptable), and **operational controls** (how we detect, respond to, and prevent
issues).

Target audience: SREs, platform engineers, operations managers, technology risk.

> **Terminology:** This document uses standard SRE and ITIL terminology. See the
> [Definitions](#definitions) section at the end for formal definitions of all
> terms. A broader glossary is available in [getting-started.md](getting-started.md#glossary).

---

## Table of Contents

- [1. Service classification](#1-service-classification)
- [2. Service level indicators (SLIs)](#2-service-level-indicators-slis)
- [3. Service level objectives (SLOs)](#3-service-level-objectives-slos)
- [4. Error budgets](#4-error-budgets)
- [5. Recovery objectives (RPO/RTO)](#5-recovery-objectives-rporto)
- [6. Monitoring and alerting controls](#6-monitoring-and-alerting-controls)
- [7. Health check and readiness controls](#7-health-check-and-readiness-controls)
- [8. Capacity and performance controls](#8-capacity-and-performance-controls)
- [9. Incident detection and response](#9-incident-detection-and-response)
- [10. Escalation matrix](#10-escalation-matrix)
- [11. Operational runbook controls](#11-operational-runbook-controls)
- [12. Change management controls](#12-change-management-controls)
- [13. Observability of the observability platform](#13-observability-of-the-observability-platform)
- [14. Phase 2 and Phase 3 SLO targets](#14-phase-2-and-phase-3-slo-targets)
- [15. Cross-references](#15-cross-references)
- [Definitions](#definitions)
- [References](#references)

---

## 1. Service classification

Pyroscope is a **Tier 3 — non-critical observability tool**. Profiling data loss
during outages does not impact application availability or business operations.
Applications continue to function normally — the Java agent silently drops profiling
data when the server is unreachable and resumes when connectivity is restored.

| Classification | Value | Rationale |
|----------------|-------|-----------|
| **Service tier** | Tier 3 (non-critical) | No customer-facing impact if unavailable |
| **Business impact of outage** | Low — profiling gap only | Applications unaffected; only investigation capability is degraded |
| **Data sensitivity** | Internal / non-sensitive | Function names, stack traces, sample counts. No PII, no financial data. |
| **Availability requirement** | Standard (95-99%) | Not a transaction-processing system. Gaps are acceptable. |
| **Recovery priority** | Standard | Restore within normal business hours unless coincides with an incident |

Cross-ref: [adr/ADR-001-continuous-profiling.md](adr/ADR-001-continuous-profiling.md) —
decision driver D8 classifies HA as Low priority.

---

## 2. Service level indicators (SLIs)

SLIs are the **metrics we measure** to determine whether the service is healthy
[^sre-book] Ch. 4. Each SLI has a Prometheus query [^prometheus-docs], a good/bad
threshold, and a measurement window.

### Ingestion SLIs

| SLI | What it measures | Prometheus query | Good threshold |
|-----|-----------------|-----------------|:------------:|
| **Ingestion availability** | Percentage of 10-second push intervals with successful ingestion | `avg_over_time(up{job="pyroscope"}[5m])` | > 0.95 |
| **Ingestion success rate** | Ratio of successful profile pushes to total attempts | `rate(pyroscope_ingestion_received_profiles_total[5m]) / rate(pyroscope_ingestion_attempted_profiles_total[5m])` | > 0.99 |
| **Ingestion latency** | Time from agent push to server acknowledgment | `histogram_quantile(0.95, pyroscope_ingestion_duration_seconds_bucket)` | < 5s (p95) |
| **Ingestion error rate** | Rate of failed ingestion requests | `rate(pyroscope_ingestion_errors_total[5m])` | < 0.01 |
| **Active series count** | Number of unique profiling time series | `pyroscope_tsdb_active_series` | Stable (no unexpected growth) |

### Query SLIs

| SLI | What it measures | Prometheus query | Good threshold |
|-----|-----------------|-----------------|:------------:|
| **Query latency (single app)** | Time to render a flame graph for one application | `histogram_quantile(0.95, pyroscope_query_duration_seconds_bucket{type="single"})` | < 5s (p95) |
| **Query latency (fleet search)** | Time to search across all profiled applications | `histogram_quantile(0.95, pyroscope_query_duration_seconds_bucket{type="fleet"})` | < 30s (p95) |
| **Query success rate** | Ratio of successful queries to total queries | `1 - rate(pyroscope_query_errors_total[5m]) / rate(pyroscope_query_total[5m])` | > 0.99 |
| **Query availability** | Whether the query endpoint responds to health checks | `probe_success{job="pyroscope-query"}` | 1 |

### Storage SLIs

| SLI | What it measures | Prometheus query | Good threshold |
|-----|-----------------|-----------------|:------------:|
| **Storage utilization** | Disk/S3 usage as percentage of allocated capacity | `pyroscope_storage_used_bytes / pyroscope_storage_total_bytes` | < 0.85 |
| **Compaction lag** | Time since last successful compaction | `time() - pyroscope_compactor_last_successful_run_timestamp_seconds` | < 2 hours |
| **Retention compliance** | Whether data older than retention policy is purged | `pyroscope_oldest_block_timestamp_seconds` | Within retention window |

### Agent SLIs

| SLI | What it measures | Prometheus query | Good threshold |
|-----|-----------------|-----------------|:------------:|
| **Agent push success rate** | Per-host ratio of successful pushes | `rate(pyroscope_agent_push_success_total[5m]) / rate(pyroscope_agent_push_total[5m])` | > 0.99 |
| **Agent CPU overhead** | CPU consumed by the profiling agent per host | `process_cpu_usage{job="profiled-app"} - baseline` | < 8% |
| **Agent memory overhead** | Memory consumed by the agent buffer | `pyroscope_agent_buffer_bytes` | < 50 MB |
| **Hosts reporting** | Number of hosts actively pushing profiles | `count(up{job="pyroscope-agent"} == 1)` | Matches expected fleet size |

---

## 3. Service level objectives (SLOs)

SLOs are the **targets we commit to** for each SLI [^sre-book] Ch. 4. They define
the boundary between "acceptable" and "needs attention." SLOs are internal
targets — stricter than any external SLA to provide a buffer.

### Phase 1 SLOs (recommended targets — not yet agreed with stakeholders)

| SLO | Target | Measurement window | Error budget |
|-----|--------|:------------------:|:------------:|
| **Data availability** | 95% of 10-second push intervals successfully ingested | 30-day rolling | 36 hours/month |
| **Ingestion success rate** | 99% of agent pushes acknowledged within 30 seconds | 30-day rolling | 7.2 hours/month |
| **Query latency (single app)** | p95 < 5 seconds | 30-day rolling | 5% of queries may exceed |
| **Query latency (fleet search)** | p95 < 30 seconds | 30-day rolling | 5% of queries may exceed |
| **Query availability** | 95% uptime | 30-day rolling | 36 hours/month |
| **Storage utilization** | < 85% of allocated capacity | Continuous | Alert at 85%, critical at 95% |

### Why 95% (not 99.9%)

Pyroscope is a Tier 3 non-critical tool. A 99.9% SLO would allow only 43 minutes
of downtime per month — this is unnecessarily strict for an observability platform
where data gaps are tolerable. The 95% target allows 36 hours per month, which
accommodates:

- Monthly VM patching (30 min)
- Pyroscope version upgrades (15 min)
- Unplanned container restarts (5 min each)
- One unplanned outage per month (up to 1 hour)

---

## 4. Error budgets

The error budget is the **maximum acceptable amount of unreliability** over a
measurement window [^sre-book] Ch. 3. When the error budget is consumed, further
changes that risk reliability should be deferred.

### Budget calculation

```
Error budget = (1 - SLO target) × measurement window

Data availability (95% SLO, 30-day window):
  Budget = 5% × 30 days × 24 hours = 36 hours
  Budget = 5% × 30 × 24 × 60 = 2,160 minutes

Ingestion success rate (99% SLO, 30-day window):
  Budget = 1% × 30 × 24 = 7.2 hours = 432 minutes
```

### Budget consumption examples

| Event | Duration | Availability budget consumed | Ingestion budget consumed |
|-------|:--------:|:---------------------------:|:------------------------:|
| Planned maintenance (VM patching) | 30 min | 1.4% (30/2160) | 6.9% (30/432) |
| Container restart (config change) | 2 min | 0.1% | 0.5% |
| Unplanned outage (VM failure + recovery) | 1 hour | 2.8% | 13.9% |
| S3 storage endpoint unreachable | 15 min | 0.7% | 3.5% |
| Pyroscope version upgrade | 15 min | 0.7% | 3.5% |

### Error budget policy

| Budget remaining | Action |
|:----------------:|--------|
| > 50% | Normal operations. Deployments and changes proceed as planned. |
| 25-50% | Caution. Review planned maintenance windows. Defer non-essential changes. |
| 10-25% | Restrict changes to critical fixes only. Investigate top budget consumers. |
| < 10% | Freeze non-essential changes. Post-mortem on budget consumption. Escalate to engineering lead. |
| Exhausted (0%) | Change freeze until budget resets. All reliability-impacting changes require project owner approval. |

---

## 5. Recovery objectives (RPO/RTO)

| Metric | Phase 1 target | Basis |
|--------|:--------------:|-------|
| **RPO (Recovery Point Objective)** | ~2 minutes | Agent buffers ~2 minutes of profiling data before dropping on server unavailability |
| **RTO (Recovery Time Objective)** | < 5 minutes | `docker restart pyroscope` restores the service; data volume is persistent |
| **Data loss on VM failure** | Up to 2 minutes | Profiles in the agent buffer are lost; all previously ingested data survives on disk |
| **Data loss on storage failure** | Zero (with S3 replication in Phase 2+) | Phase 1 uses local disk — single point of failure. Phase 2+ uses S3 with built-in durability. |

### RPO/RTO by phase

| Phase | RPO | RTO | Basis |
|-------|:---:|:---:|-------|
| **Phase 1** (single VM) | ~2 min | < 5 min | Agent buffer window; container restart |
| **Phase 2** (multi-VM + S3) | ~2 min | < 2 min | S3 durability; VIP failover to standby VM |
| **Phase 3** (OCP microservices) | ~30 sec | < 1 min | Replicated ingesters; pod rescheduling |

---

## 6. Monitoring and alerting controls

### Alert definitions

Each alert maps to an SLI and fires when the SLI breaches its threshold.

| Alert name | Severity | Condition | For | Action |
|-----------|:--------:|-----------|:---:|--------|
| `PyroscopeDown` | Critical | `up{job="pyroscope"} == 0` | 2 min | Page on-call. Restart container. Check VM health. |
| `PyroscopeIngestionDrop` | Warning | `rate(pyroscope_ingestion_received_profiles_total[5m]) == 0` | 5 min | Check agent connectivity. Verify firewall rules. |
| `PyroscopeIngestionErrors` | Warning | `rate(pyroscope_ingestion_errors_total[5m]) > 0.01` | 5 min | Check server logs for rejection reason. |
| `PyroscopeQuerySlow` | Warning | `histogram_quantile(0.95, pyroscope_query_duration_seconds_bucket) > 10` | 10 min | Check compaction status. Review query complexity. |
| `PyroscopeStorageHigh` | Warning | `pyroscope_storage_used_bytes / pyroscope_storage_total_bytes > 0.85` | 15 min | Reduce retention or expand storage. |
| `PyroscopeStorageCritical` | Critical | `pyroscope_storage_used_bytes / pyroscope_storage_total_bytes > 0.95` | 5 min | Immediate: reduce retention. Risk of ingestion failure. |
| `PyroscopeCompactionLag` | Warning | `time() - pyroscope_compactor_last_successful_run_timestamp_seconds > 7200` | 30 min | Check compactor logs. May indicate storage issue. |
| `PyroscopeAgentDropoff` | Warning | `count(up{job="pyroscope-agent"} == 1) < expected_count * 0.9` | 10 min | 10%+ of hosts stopped reporting. Check agent health. |
| `PyroscopeSeriesExplosion` | Warning | `rate(pyroscope_tsdb_active_series[1h]) > threshold` | 30 min | Cardinality issue — new label value or unbounded label. |

### Alert routing

| Severity | Notification channel | Response expectation |
|:--------:|---------------------|---------------------|
| Critical | PagerDuty / on-call pager | Acknowledge within 15 min. Begin investigation immediately. |
| Warning | Slack #pyroscope-alerts + email | Acknowledge within 1 hour. Investigate during business hours. |
| Info | Slack #pyroscope-alerts only | Review during daily standup or weekly review. |

### Alert silence policy

| Scenario | Silence duration | Approval |
|----------|:----------------:|----------|
| Planned maintenance window | Duration of maintenance + 15 min buffer | Pre-approved in change record |
| Known issue under investigation | 4 hours max | On-call SRE |
| Extended silence (> 4 hours) | Requires explicit renewal | Engineering lead |

---

## 7. Health check and readiness controls

### Endpoint definitions

| Endpoint | Method | Purpose | Expected response | Used by |
|----------|:------:|---------|:-----------------:|---------|
| `/ready` | GET | Readiness probe — server can accept requests | 200 OK | Kubernetes/OCP readiness probe, F5 VIP health check |
| `/healthy` | GET | Liveness probe — process is alive | 200 OK | Kubernetes/OCP liveness probe |
| `/metrics` | GET | Prometheus metrics endpoint | 200 + metrics payload | Prometheus scrape |
| `/api/v1/apps` | GET | Functional check — can list applications | 200 + JSON | Synthetic monitoring |

### Health check configuration

| Platform | Health check type | Endpoint | Interval | Timeout | Failure threshold |
|----------|:-----------------:|:--------:|:--------:|:-------:|:-----------------:|
| **F5 VIP** (Phase 2) | HTTP monitor | `/ready` | 10s | 5s | 3 consecutive failures |
| **Kubernetes/OCP** readiness | httpGet | `/ready` | 10s | 3s | 3 consecutive failures |
| **Kubernetes/OCP** liveness | httpGet | `/healthy` | 30s | 5s | 5 consecutive failures |
| **Prometheus** scrape | HTTP GET | `/metrics` | 15s | 10s | Alert after 2 min |
| **Synthetic monitor** | HTTP GET | `/api/v1/apps` | 60s | 30s | Alert after 2 consecutive |

### Readiness vs liveness semantics

| Probe | Passes when | Fails when | Consequence of failure |
|-------|-------------|------------|----------------------|
| **Readiness** | Server can accept and process new requests | Server is starting up, overloaded, or draining | Removed from load balancer pool. No traffic routed. No restart. |
| **Liveness** | Process is running and responsive | Process is deadlocked, OOM, or unresponsive | Container/pod restarted. Last resort. |

**Important:** Liveness timeout (5s) must be generous. A slow query should not
trigger a liveness failure and restart the server. Readiness checks are the
primary mechanism for traffic management.

---

## 8. Capacity and performance controls

### Capacity thresholds

| Resource | Warning | Critical | Action at warning | Action at critical |
|----------|:-------:|:--------:|-------------------|-------------------|
| **Disk / S3 usage** | 85% | 95% | Review retention policy. Plan expansion. | Reduce retention immediately. Expand storage. |
| **CPU** | 80% sustained (15 min) | 95% sustained (5 min) | Review query load. Check compaction. | Scale up VM or add replicas. |
| **Memory** | 80% of limit | 95% of limit | Check for query-induced memory spikes. | Increase memory limit. Restart if OOM imminent. |
| **Ingestion rate** | 80% of tested capacity | 95% of tested capacity | Plan capacity upgrade. | Defer new agent onboarding. |
| **Active series** | 80% of planned cardinality | > planned cardinality | Review label cardinality. Check for unbounded labels. | Identify and remove offending label. |

### Performance baselines

Establish baselines during Phase 1 deployment. Record these values after 2 weeks
of stable operation and update quarterly.

| Metric | Baseline value | How to measure | Review frequency |
|--------|:--------------:|----------------|:----------------:|
| Ingestion rate (profiles/sec) | Record after 2 weeks | `rate(pyroscope_ingestion_received_profiles_total[1h])` | Monthly |
| Query latency p50 / p95 / p99 | Record after 2 weeks | `histogram_quantile(0.5/0.95/0.99, ...)` | Monthly |
| Storage growth rate (GB/day) | Record after 2 weeks | `deriv(pyroscope_storage_used_bytes[24h])` | Monthly |
| Active series count | Record after 2 weeks | `pyroscope_tsdb_active_series` | Monthly |
| Agent push success rate | Record after 2 weeks | Per-host success ratio | Monthly |

### Capacity planning triggers

| Trigger | Action | Lead time |
|---------|--------|:---------:|
| Storage > 70% with current growth rate exceeding retention purge rate | Expand storage or reduce retention | 2 weeks |
| Ingestion rate approaching 80% of tested capacity | Plan Phase 2 or Phase 3 upgrade | 4-6 weeks |
| Series count growing faster than function deployment rate | Investigate label cardinality | 1 week |
| Query latency trending upward over 4 weeks | Review compaction, add query caching, or scale | 2 weeks |

---

## 9. Incident detection and response

### Detection mechanisms

| Mechanism | What it detects | Detection latency | Coverage |
|-----------|----------------|:-----------------:|----------|
| **Prometheus alerts** | SLI threshold breaches (down, slow, errors) | 2-10 min (depends on `for` duration) | All SLIs |
| **Health check probes** | Server unreachable or unresponsive | 30-60 sec | Readiness and liveness |
| **Synthetic monitoring** | End-to-end query failure | 1-2 min | Query path only |
| **Agent-side alerting** | Push failures from agent perspective | 5 min | Ingestion path |
| **Grafana dashboard** | Visual anomaly detection by humans | Minutes to hours | All metrics (requires human attention) |
| **Error budget burn rate** | SLO at risk of breach | Hours (trend-based) | All SLOs |

### Burn rate alerting

Burn rate [^sre-workbook] Ch. 5 measures how fast the error budget is being
consumed. A burn rate of 1x means the budget will be exactly exhausted at the end
of the window. A burn rate of 10x means the budget will be exhausted in 1/10 of
the window.

| Burn rate | Budget consumed in | Alert severity | Response |
|:---------:|:------------------:|:--------------:|----------|
| > 14x | < 2 hours | Critical | Page on-call immediately |
| > 6x | < 5 hours | Warning | Investigate within 1 hour |
| > 1x | Before window ends | Info | Review in daily standup |

**Prometheus burn rate alert (example):**

```
# 14x burn rate over 1 hour — budget will exhaust in ~2 hours
(1 - avg_over_time(up{job="pyroscope"}[1h])) / (1 - 0.95) > 14
```

### Incident severity classification

| Severity | Definition | Example | Response time |
|:--------:|-----------|---------|:-------------:|
| **Sev 1** | Complete loss of profiling capability — no data ingested | Server down, S3 unreachable, all agents failing | 15 min |
| **Sev 2** | Partial degradation — some data lost or queries slow | 30% of agents failing, query latency > 30s | 1 hour |
| **Sev 3** | Minor issue — SLO not at risk but anomaly detected | Compaction lag, single host not reporting | Next business day |
| **Sev 4** | Cosmetic or informational | Dashboard rendering issue, log noise | Backlog |

---

## 10. Escalation matrix

| Scenario | First responder | Escalation to | Escalation trigger |
|----------|:---------------:|:-------------:|-------------------|
| Server down < 5 min | On-call SRE | No escalation | Within RTO |
| Server down 5-30 min | On-call SRE | Engineering lead | Approaching SLO impact |
| Server down > 30 min | Engineering lead | Project owner | SLO breach risk |
| Data loss > 2 hours | Engineering lead | Project owner + stakeholders | Exceeds RPO significantly |
| Storage > 85% | On-call SRE | Engineering lead | Risk of ingestion failure |
| Storage > 95% | Engineering lead | Project owner | Imminent ingestion failure |
| Error budget < 25% | Engineering lead | Project owner | Monthly review escalation |
| Error budget exhausted | Project owner | VP Engineering | Change freeze required |
| Security incident (agent compromise) | Security team | CISO + engineering lead | Immediate |
| Correlated with production incident | On-call SRE | Incident commander | Profiling data needed for investigation |

### Escalation during production incidents

When Pyroscope is down **during a production application incident**, the escalation
priority increases because profiling data is needed for root cause analysis:

| Combined scenario | Priority | Response |
|-------------------|:--------:|----------|
| App incident + Pyroscope healthy | Normal | Use profiling data for investigation |
| App incident + Pyroscope down | **Elevated** | Restore Pyroscope first — profiling data is the investigation tool |
| App incident + Pyroscope down + recent deploy | **High** | Diff profiling needed — restore and compare pre/post deploy |

---

## 11. Operational runbook controls

### Routine operational procedures

| Procedure | Frequency | Owner | Estimated time | Documented in |
|-----------|:---------:|:-----:|:--------------:|---------------|
| Review Grafana dashboard for anomalies | Daily (business days) | On-call SRE | 5 min | [monitoring-guide.md](monitoring-guide.md) |
| Check error budget consumption | Weekly | Engineering lead | 10 min | This document, Section 4 |
| Review capacity baselines | Monthly | Platform engineer | 30 min | [capacity-planning.md](capacity-planning.md) |
| Update performance baselines | Quarterly | Platform engineer | 1 hour | This document, Section 8 |
| Retention policy review | Quarterly | Engineering lead | 30 min | [capacity-planning.md](capacity-planning.md) |
| Pyroscope version upgrade | Monthly or as-needed | Platform engineer | 30 min | [upgrade-guide.md](upgrade-guide.md) |
| Failover drill (Phase 2+) | Quarterly | SRE team | 2 hours | [runbook.md](runbook.md) |
| Disaster recovery test (Phase 2+) | Semi-annually | SRE team + stakeholders | 4 hours | [runbook.md](runbook.md) |

### Runbook coverage requirements

Every alert in Section 6 must have a corresponding runbook entry that includes:

1. **Symptom** — what the engineer sees (alert text, dashboard state)
2. **Verification** — how to confirm the issue is real (not a false positive)
3. **Triage** — determine severity and scope
4. **Resolution** — step-by-step fix
5. **Validation** — how to confirm the fix worked
6. **Post-mortem** — whether a post-mortem is required (Sev 1 and Sev 2: yes)

Cross-ref: [runbook.md](runbook.md) for operational procedures.

---

## 12. Change management controls

### Change categories for Pyroscope

| Change type | Risk level | Approval required | Rollback plan |
|-------------|:----------:|:-----------------:|:-------------:|
| Agent version upgrade | Low | Engineering lead | Remove agent flag from JAVA_TOOL_OPTIONS |
| Pyroscope server version upgrade | Medium | Engineering lead + change record | `docker pull` previous version + restart |
| Retention policy change | Low | Engineering lead | Revert config change + restart |
| Storage expansion (S3 bucket resize) | Low | Storage team | N/A (non-destructive) |
| Phase migration (1→2 or 2→3) | High | Project owner + CAB | Full rollback plan per [templates/rollback-plan.md](templates/rollback-plan.md) |
| Label handler change (new label, name change) | Medium | Engineering lead | Revert handler code + deploy |
| New application onboarded to profiling | Low | Application team + platform team | Remove agent from application |

### Pre-change checklist

Before any change to the Pyroscope platform:

- [ ] Error budget > 25% (do not make changes if budget is low)
- [ ] No active production incidents
- [ ] Change tested in dev → stage → prod (environment promotion)
- [ ] Rollback procedure documented and tested
- [ ] Monitoring in place to detect regression within 15 minutes
- [ ] Maintenance window scheduled (if downtime expected)
- [ ] Alerting silenced for maintenance window (if applicable)
- [ ] Stakeholders notified (if customer-visible impact)

### Post-change validation

After any change:

- [ ] All health check endpoints return 200
- [ ] Ingestion rate matches pre-change baseline (± 10%)
- [ ] Query latency matches pre-change baseline (± 20%)
- [ ] Active series count matches pre-change baseline (± 5%)
- [ ] No new errors in server logs
- [ ] Grafana dashboards rendering correctly
- [ ] Agent push success rate > 99%

---

## 13. Observability of the observability platform

### The meta-monitoring problem

Pyroscope monitors application performance. But who monitors Pyroscope?
[^observability-eng] Ch. 12 calls this the "meta-monitoring problem" — if the
monitoring platform is down, you lose visibility into the applications it monitors.

### Meta-monitoring strategy

| Layer | What monitors it | How |
|-------|-----------------|-----|
| **Pyroscope server process** | Prometheus + alerting | `up{job="pyroscope"}` alert |
| **Pyroscope metrics endpoint** | Prometheus scrape | Scrape failure triggers alert |
| **Pyroscope query capability** | Synthetic monitor | Periodic query to `/api/v1/apps` |
| **S3 storage (Phase 2+)** | Cloud provider / MinIO monitoring | S3 bucket health metrics |
| **VM / pod health** | Infrastructure monitoring (existing) | CPU, memory, disk alerts from existing platform |
| **Network connectivity** | Infrastructure monitoring (existing) | Port checks, firewall rule validation |
| **Prometheus itself** | Prometheus federation or Alertmanager watchdog | `watchdog` alert (always-firing) — absence of alert = Prometheus is down |

### Watchdog alert pattern

The Prometheus `Watchdog` alert fires continuously. If Alertmanager stops receiving
the Watchdog, it means Prometheus is down — and therefore all Pyroscope alerts are
also down.

```yaml
# Watchdog alert — always fires. Absence = Prometheus failure.
- alert: Watchdog
  expr: vector(1)
  labels:
    severity: none
  annotations:
    summary: "Watchdog alert — confirms Prometheus and Alertmanager are functional"
```

Configure a dead man's switch (e.g., PagerDuty heartbeat, Healthchecks.io) that
expects the Watchdog alert at regular intervals. If the heartbeat stops, page the
on-call team — the monitoring system itself is down.

### Dashboard for meta-monitoring

| Panel | Metric | Purpose |
|-------|--------|---------|
| Pyroscope uptime (30d) | `avg_over_time(up{job="pyroscope"}[30d])` | SLO compliance at a glance |
| Error budget remaining | `1 - (budget_consumed / budget_total)` | Budget burn visualization |
| Ingestion rate trend | `rate(pyroscope_ingestion_received_profiles_total[1h])` | Detect drops or spikes |
| Active agents count | `count(up{job="pyroscope-agent"} == 1)` | Detect agent fleet changes |
| Storage utilization | `pyroscope_storage_used_bytes / pyroscope_storage_total_bytes` | Capacity trend |
| Alertmanager health | `alertmanager_notifications_total` | Verify alert delivery |

---

## 14. Phase 2 and Phase 3 SLO targets

### Phase 2 (Multi-VM monolith with S3-compatible object storage)

| SLO | Phase 1 | Phase 2 | Basis for improvement |
|-----|:-------:|:-------:|----------------------|
| Data availability | 95% | 99% | VIP failover eliminates single-VM downtime |
| Ingestion success rate | 99% | 99.5% | Redundant ingestion path via load balancer |
| Query latency (p95) | < 5s | < 5s | Unchanged — same Pyroscope version |
| RPO | ~2 min | ~2 min | Agent buffer unchanged; S3 provides durability |
| RTO | < 5 min | < 2 min | VIP automatic failover to standby VM |
| Error budget (availability) | 36 hrs/month | 7.2 hrs/month | Higher SLO = tighter budget |

### Phase 3 (Microservices on OpenShift)

| SLO | Phase 2 | Phase 3 | Basis for improvement |
|-----|:-------:|:-------:|----------------------|
| Data availability | 99% | 99.5% | Replicated ingesters; pod rescheduling |
| Ingestion success rate | 99.5% | 99.9% | Distributor → ingester replication |
| Query latency (p95) | < 5s | < 2s | Query-frontend caching + query scheduler |
| RPO | ~2 min | ~30 sec | Replicated ingesters flush independently |
| RTO | < 2 min | < 1 min | OCP pod rescheduling + health checks |
| Error budget (availability) | 7.2 hrs/month | 3.6 hrs/month | Higher SLO = tighter budget |

---

## 15. Cross-references

| Document | Relevance |
|----------|-----------|
| [monitoring-guide.md](monitoring-guide.md) | Prometheus metrics reference, alert rule definitions, Grafana dashboard details |
| [capacity-planning.md](capacity-planning.md) | Storage sizing, retention calculations, infrastructure scaling |
| [runbook.md](runbook.md) | Operational procedures, incident playbooks, failover drills |
| [architecture.md](architecture.md) | Deployment topology, component health, data flow |
| [upgrade-guide.md](upgrade-guide.md) | Upgrade procedures, rollback steps |
| [security-model.md](security-model.md) | Data classification, access controls |
| [project-plan-phase1.md](project-plan-phase1.md) | Phase 1 implementation plan |
| [project-plan-phase2.md](project-plan-phase2.md) | Phase 2 HA implementation plan |
| [project-plan-phase3.md](project-plan-phase3.md) | Phase 3 microservices implementation plan |
| [templates/change-request.md](templates/change-request.md) | Change request template for CAB |
| [templates/rollback-plan.md](templates/rollback-plan.md) | Rollback plan template |
| [adr/ADR-001-continuous-profiling.md](adr/ADR-001-continuous-profiling.md) | Service tier classification decision |
| [getting-started.md § Glossary](getting-started.md#glossary) | Full project glossary including observability terms |

---

## Definitions

Formal definitions for observability and reliability terms used in this document.
Sourced from Google SRE [^sre-book], ITIL 4 [^itil4], and NIST [^nist-glossary].

| Term | Definition | Source |
|------|-----------|--------|
| **SLA** (Service Level Agreement) | A formal contract between a service provider and consumer specifying the expected level of service, consequences of non-compliance, and measurement methodology. SLAs are externally facing and legally binding. | ITIL 4 [^itil4] |
| **SLO** (Service Level Objective) | An internal target for the reliability of a service, expressed as a percentage of an SLI over a time window (e.g., "99% of queries complete in < 5 seconds over 30 days"). SLOs are stricter than SLAs to provide a buffer. | Google SRE [^sre-book] |
| **SLI** (Service Level Indicator) | A quantitative measure of a specific aspect of the service — the raw metric that SLOs are defined against (e.g., request latency, error rate, availability). | Google SRE [^sre-book] |
| **Error budget** | The maximum amount of unreliability permitted by the SLO over a measurement window. Calculated as `(1 - SLO) x window`. Consumed by outages, degradation, and maintenance. When exhausted, changes that risk reliability are frozen. | Google SRE [^sre-book] |
| **Burn rate** | The rate at which the error budget is being consumed relative to the budget period. A burn rate of 1x means the budget will be exactly exhausted at the end of the window. A burn rate of 10x means exhaustion in 1/10 of the window. | Google SRE Workbook [^sre-workbook] |
| **RPO** (Recovery Point Objective) | The maximum acceptable amount of data loss measured in time. An RPO of 2 minutes means up to 2 minutes of data may be lost during a failure. | NIST SP 800-34 [^nist-glossary] |
| **RTO** (Recovery Time Objective) | The maximum acceptable time to restore service after a failure. An RTO of 5 minutes means the service must be operational within 5 minutes of a failure. | NIST SP 800-34 [^nist-glossary] |
| **MTTR** (Mean Time to Restore/Resolve) | The average time from incident detection to service restoration. DORA uses "time to restore service" as one of four key software delivery metrics. | DORA [^dora-2024] |
| **MTTD** (Mean Time to Detect) | The average time from the start of a failure to detection by monitoring systems or humans. | PagerDuty [^pagerduty-2024] |
| **Readiness probe** | A health check that determines whether a service instance can accept new traffic. A failed readiness probe removes the instance from the load balancer pool but does not restart it. | Kubernetes documentation [^k8s-probes] |
| **Liveness probe** | A health check that determines whether a service instance is alive. A failed liveness probe triggers a container restart. Should be used as a last resort — not for transient slowness. | Kubernetes documentation [^k8s-probes] |
| **Synthetic monitoring** | Automated, periodic execution of predefined transactions against a service to verify end-to-end functionality from the client perspective. | Gartner IT Glossary [^gartner-glossary] |
| **Dead man's switch** | An alerting pattern where a continuously-firing alert (Watchdog) is expected by an external system. If the alert stops firing, the external system notifies operators — indicating the monitoring system itself has failed. | Prometheus documentation [^prometheus-docs] |
| **Toil** | Repetitive, manual, automatable work tied to running a production service that scales linearly with service size. Google SRE targets < 50% of SRE time on toil. | Google SRE [^sre-book] |
| **Change failure rate** | The percentage of deployments that result in a degraded service requiring remediation (rollback, hotfix, patch). One of DORA's four key metrics. | DORA [^dora-2024] |
| **Service tier** | A classification of a service's business criticality that determines SLO targets, support response times, and change management requirements. Tier 1 = business-critical, Tier 3 = non-critical. | ITIL 4 [^itil4] |
| **Observability** | The ability to understand the internal state of a system by examining its external outputs (metrics, logs, traces, profiles). Distinguished from monitoring (which checks known failure modes) by its ability to answer novel questions. | Charity Majors, "Observability Engineering" [^observability-eng] |
| **Cardinality** | The number of unique values a label or tag can take. High cardinality (e.g., request ID per label) causes storage explosion. Low, bounded cardinality (e.g., function name) is safe. | Prometheus documentation [^prometheus-docs] |
| **Compaction** | The process of merging, deduplicating, and downsampling stored profiling blocks to reduce storage consumption and improve query performance. | Pyroscope documentation [^pyroscope-docs] |
| **Retention** | The duration for which profiling data is stored before being purged. Shorter retention reduces storage cost; longer retention enables wider historical comparison. | Pyroscope documentation [^pyroscope-docs] |

---

## References

| Reference | Full citation | Used in |
|-----------|--------------|---------|
| [^sre-book] | Beyer, Jones, Petoff, Murphy, *Site Reliability Engineering: How Google Runs Production Systems*, O'Reilly, 2016. Chapters 4 (SLOs), 3 (Embracing Risk), 31 (Communication). | SLI, SLO, error budget, toil definitions |
| [^sre-workbook] | Beyer, Murphy, Rensin, Kawahara, Thorne, *The Site Reliability Workbook*, O'Reilly, 2018. Chapter 5 (Alerting on SLOs), burn rate methodology. | Burn rate alerting, error budget policy |
| [^itil4] | AXELOS, *ITIL 4: Create, Deliver and Support*, TSO, 2019. Service level management practice. | SLA, service tier classification, change management |
| [^dora-2024] | Google Cloud / DORA, *Accelerate State of DevOps Report 2024*. 39,000+ respondents. | MTTR benchmarks, change failure rate |
| [^pagerduty-2024] | PagerDuty, *State of Digital Operations Report 2024*. Analysis of 18,000+ organizations. | MTTD benchmarks, alert routing practices |
| [^nist-glossary] | NIST SP 800-34 Rev. 1, *Contingency Planning Guide for Federal Information Systems*, 2010. Updated 2024. | RPO, RTO definitions |
| [^k8s-probes] | Kubernetes documentation, *Configure Liveness, Readiness and Startup Probes*, v1.29, 2024. | Readiness/liveness probe semantics |
| [^prometheus-docs] | Prometheus project documentation, *Alerting Rules* and *Recording Rules*, 2025. | Watchdog pattern, cardinality, PromQL examples |
| [^gartner-glossary] | Gartner IT Glossary, *Synthetic Monitoring*, 2025. | Synthetic monitoring definition |
| [^observability-eng] | Majors, Fong-Jones, Miranda, *Observability Engineering*, O'Reilly, 2022. | Observability definition, pillars of observability |
| [^pyroscope-docs] | Grafana Pyroscope documentation, *Storage and Retention*, 2025. | Compaction, retention, storage architecture |

# Production Onboarding Questionnaire — Phase 1 (No Database)

## Initiative Summary

| Field | Answer |
|-------|--------|
| Initiative | Continuous profiling analysis functions for Pyroscope — Phase 1 |
| MVP / Use Case | Phase 1 deploys 3 BOR functions and 1 SOR (no database) that automate profiling analysis on top of Pyroscope — triaging incidents by diagnosing CPU/memory issues from flame graphs, comparing pre/post-deploy performance to catch regressions, and searching fleet-wide for shared-library hotspots. |
| Business Benefit | Reduces incident MTTR by replacing manual flame graph interpretation with automated diagnosis, gives engineers quantified go/no-go deployment decisions at the function level, and enables the platform team to prioritize optimization work by fleet-wide cost — all without requiring profiling expertise from the on-call engineer. |
| BOR functions | 3 (Triage, Diff Report, Fleet Search) |
| SOR functions | 1 (Profile Data — stateless, no database) |
| Total functions | 4 |
| Database required | No |
| External dependencies | Pyroscope (already deployed) |
| Building off existing SOR? | No — new SOR wrapping Pyroscope API |
| Type of service | Intranet |
| Hosted | Internal |
| External deployment | No |
| Expected Volume(s) | All functions are well under the 100 TPS threshold. Peak TPS is the Profile Data SOR at under 50 TPS due to fan-out from the 3 BOR functions; individual BOR functions are under 10 TPS each. All requests are on-demand and human-triggered (no batch, polling, or streaming). Expected daily volume is under 500 requests across all functions. Request and response payloads are small JSON (under 50 KB). No database and no persistent storage — the SOR is stateless and holds no data at rest. The single shared SOR is not a bottleneck; Vert.x is non-blocking and the serverless platform scales each function independently. |

All functions are HTTP request/response only. No file upload/download, cron triggers, Kafka, or protobuf.

---

## Volume and TPS Estimates

These functions are on-demand, human-triggered tools — not streaming pipelines or batch jobs. An engineer calls Triage during an incident, Diff Report after a deployment, or Fleet Search when investigating a shared-library issue. There is no background polling, scheduled execution, or automated triggering in Phase 1.

### BOR vs SOR volume relationship

Each BOR request fans out to one or more SOR calls. The SOR TPS is higher than any individual BOR because all three BOR functions share the same Profile Data SOR.

```
1 Triage request     → 2 SOR calls  (CPU profile + memory profile)
1 Diff Report request → 2 SOR calls  (baseline window + current window)
1 Fleet Search request → N SOR calls (1 per monitored service, typically 5-20)
```

### TPS summary

| Function | Type | Expected TPS | Usage Pattern |
|----------|------|:------------:|---------------|
| Triage BOR | BOR | Under 10 | On-demand during incidents. A few engineers may triage the same app simultaneously. |
| Diff Report BOR | BOR | Under 5 | Post-deployment. Typically one request per deploy, sometimes re-run with different time windows. |
| Fleet Search BOR | BOR | Under 5 | Ad-hoc investigation. A platform engineer searches for a function across the fleet. |
| Profile Data SOR | SOR | Under 50 | Receives fan-out from all three BOR functions. Peak occurs when Fleet Search scans many services. |

### How TPS estimates were calculated

TPS is derived from: **(concurrent users) x (requests per user action) x (fan-out multiplier)**.

All functions are human-triggered. A human can realistically invoke one action every few seconds at most. The calculation assumes a peak-concurrent-user count (worst case, all happening at the same time) and multiplies by the fan-out each request produces.

**BOR TPS (inbound requests from engineers):**

| Scenario | Concurrent Users | Requests per Action | Peak BOR TPS |
|----------|:----------------:|:-------------------:|:------------:|
| Incident triage | 3-5 engineers triaging same app | 1 | 5 |
| Post-deploy diff | 2-3 deploys in progress across teams | 1 | 3 |
| Fleet search | 1-2 platform engineers investigating | 1 | 2 |
| **Combined peak** (all scenarios at once) | | | **10** |

**SOR TPS (internal calls from BOR functions):**

| Source | BOR TPS | Fan-out per Request | SOR TPS |
|--------|:-------:|:-------------------:|:-------:|
| Triage | 5 | x 2 (CPU + memory profile) | 10 |
| Diff Report | 3 | x 2 (baseline + current window) | 6 |
| Fleet Search | 2 | x 15 (avg monitored services) | 30 |
| **Combined peak** | | | **46** |

46 rounds to "under 50 TPS" for the Profile Data SOR. This is the absolute peak — all three scenarios happening simultaneously with maximum concurrent users. Typical steady-state is well below this.

**Why these numbers hold at enterprise scale:** The constraint is concurrent human users, not total user count. Even with 100+ engineers on the platform, these functions are diagnostic tools used during incidents or deployments — not called continuously. The number of concurrent incidents and deployments at any given second stays roughly constant regardless of team size.

**Daily volume estimate:** Assuming 5-10 triage calls, 10-20 diff reports, and 2-5 fleet searches per day = 50-200 BOR requests/day, producing 200-1000 SOR requests/day after fan-out. Well under 500 BOR requests/day, well under 2000 SOR requests/day.

---

## BOR Functions

All BOR functions are stateless HTTP GET endpoints. Java 11 and Java 17 versions provided. No database.

### 1. Triage — `ReadPyroscopeTriageAssessment.v1`

| Field | Answer |
|-------|--------|
| Use Case | Automates incident diagnosis by analyzing CPU and memory flame graphs and returning a severity-ranked assessment with actionable recommendations, eliminating the need for profiling expertise on call. |
| Business Benefit | Cuts incident MTTR by removing the manual flame graph interpretation step and provides consistent diagnosis regardless of who is on call. |
| Verticle | `TriageVerticle.java` |
| Volume | Under 10 TPS (on-demand during incidents) |

### 2. Diff Report — `ReadPyroscopeDiffReport.v1`

| Field | Answer |
|-------|--------|
| Use Case | Compares pre- and post-deployment profiling data to quantify per-function regressions and improvements, giving engineers a data-driven go/no-go decision after every deploy. |
| Business Benefit | Quantifies deployment impact at the function level so regressions are caught before they reach production traffic, with markdown output that can go straight to PRs or Slack. |
| Verticle | `DiffReportVerticle.java` |
| Volume | Under 5 TPS (post-deploy or on-demand) |

### 3. Fleet Search — `ReadPyroscopeFleetSearch.v1`

| Field | Answer |
|-------|--------|
| Use Case | Searches for a specific function across all monitored services and ranks fleet-wide hotspots by impact score, enabling the platform team to prioritize optimization work where it matters most. |
| Business Benefit | Finds cross-cutting performance issues in shared libraries and prioritizes optimization work by fleet-wide cost rather than individual service complaints. |
| Verticle | `FleetSearchVerticle.java` |
| Volume | Under 5 TPS (on-demand) |

---

## SOR Functions

### 4. Profile Data — `ReadPyroscopeProfile.sor.v1`

| Field | Answer |
|-------|--------|
| Use Case | Wraps the Pyroscope HTTP API to parse raw flamebearer JSON into ranked function lists with percentages, serving as the single data access layer for all three BOR functions. |
| Business Benefit | Isolates Pyroscope API coupling into one SOR so BOR functions are insulated from upstream API changes and all profiling data parsing logic is centralized and tested in one place. |
| Verticle | `ProfileDataVerticle.java` — 3 GET endpoints |
| Database | None (calls Pyroscope over HTTP) |
| Volume | Under 50 TPS (each BOR request fans out to 1-N calls here) |

---

## Architecture

All three BOR functions call the Profile Data SOR over HTTP. The Profile Data SOR calls the Pyroscope API and parses flamebearer responses into ranked function lists.

```
Engineer → Triage BOR ──→ Profile Data SOR ──→ Pyroscope
Engineer → Diff Report BOR ──→ Profile Data SOR ──→ Pyroscope
Engineer → Fleet Search BOR ──→ Profile Data SOR ──→ Pyroscope
```

---

## Testing and Quality Assurance

### Test Framework

| Component | Technology | Version |
|-----------|-----------|---------|
| Test framework | JUnit 5 (Jupiter) | 5.10.2 |
| Assertions | AssertJ | 3.26.0 |
| Vert.x test support | vertx-junit5 | 4.5.8 |

### Test Coverage

All functions are provided in two Java versions (Java 11 and Java 17). Each version has its own test suite.

| Project | Unit Tests | Integration Tests | Total |
|---------|-----------|-------------------|-------|
| pyroscope-bor (Java 17) | 77 (5 classes) | 16 (4 classes) | 93 |
| pyroscope-bor-java11 | 77 (5 classes) | 16 (4 classes) | 93 |
| pyroscope-sor (Java 17) | 31 (2 classes) | — | 31 |
| pyroscope-sor-java11 | 26 (2 classes) | — | 26 |
| **Total** | **211** | **32** | **243** |

BOR integration tests use mock HTTP servers (no Docker required). Phase 1 SOR (Profile Data) has unit tests only — no database to integration test.

### Running Tests

```bash
make test-bor       # All BOR tests (no Docker required)
make compile        # Compile all projects
```

---

## Deployment Configuration

| Function | FUNCTION Value | Port | Depends On |
|----------|---------------|------|------------|
| Profile Data SOR | `ReadPyroscopeProfile.sor.v1` | 8082 | Pyroscope |
| Triage BOR | `ReadPyroscopeTriageAssessment.v1` | 8080 | Profile Data SOR |
| Diff Report BOR | `ReadPyroscopeDiffReport.v1` | 8080 | Profile Data SOR |
| Fleet Search BOR | `ReadPyroscopeFleetSearch.v1` | 8080 | Profile Data SOR |

### Environment Variables

**Profile Data SOR:**

| Variable | Required | Value |
|----------|:--------:|-------|
| `FUNCTION` | Yes | `ReadPyroscopeProfile.sor.v1` |
| `PYROSCOPE_URL` | Yes | `http://pyroscope:4040` |
| `PORT` | No | `8082` (default: 8080) |

**BOR Functions (all three):**

| Variable | Required | Value |
|----------|:--------:|-------|
| `FUNCTION` | Yes | See table above |
| `PROFILE_DATA_URL` | Yes | `http://profile-data-sor:8082` |
| `PORT` | No | `8080` (default: 8080) |

---

## Upgrade Path to Phase 2

When PostgreSQL is approved, upgrade to Phase 2 by:
1. Deploying 4 new PostgreSQL-backed SORs (Baseline, History, Registry, AlertRule)
2. Switching BOR `FUNCTION` values from v1 to v2
3. Setting additional SOR URL environment variables (`BASELINE_URL`, `HISTORY_URL`, `REGISTRY_URL`)

The v2 BORs handle missing SOR URLs gracefully, so the upgrade can be done incrementally. See [production-questionnaire-phase2.md](production-questionnaire-phase2.md).

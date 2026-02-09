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

All functions are HTTP request/response only. No file upload/download, cron triggers, Kafka, or protobuf.

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

# Production Onboarding Questionnaire — Phase 2 (With PostgreSQL)

Builds on [Phase 1](production-questionnaire-phase1.md). Adds 4 PostgreSQL-backed SORs and upgrades 3 BOR functions from v1 to v2.

## Initiative Summary

| Field | Answer |
|-------|--------|
| Initiative | Continuous profiling analysis functions for Pyroscope — Phase 2 |
| MVP / Use Case | Phase 2 adds baseline threshold comparison, triage audit trails, service ownership enrichment, and alerting rules on top of the Phase 1 automated diagnosis, diff reporting, and fleet search capabilities. |
| Business Benefit | Enables data-driven threshold enforcement ("GC is at 34% which exceeds the approved baseline of 15%"), provides an audit trail for compliance and post-mortem reviews, enriches fleet search results with team ownership for direct routing, and lays the foundation for automated profiling-based alerts. |
| BOR functions | 3 (Triage v2, Diff Report v2, Fleet Search v2 — replace Phase 1 v1 variants) |
| SOR functions | 5 total: 1 stateless (Profile Data, unchanged), 4 PostgreSQL-backed (Baseline, History, Registry, AlertRule) |
| Total functions | 8 |
| Database required | PostgreSQL (single instance, 4 tables) |
| External dependencies | Pyroscope (already deployed) |
| Building off existing SOR? | Yes — extends Phase 1 Profile Data SOR |
| Type of service | Intranet |
| Hosted | Internal |
| External deployment | No |

All functions are HTTP request/response only. No file upload/download, cron triggers, Kafka, or protobuf.

---

## Volume and TPS Estimates

Phase 2 adds 4 PostgreSQL-backed SORs and upgrades the 3 BOR functions to v2. The usage pattern remains on-demand and human-triggered — no background polling, scheduled execution, or automated triggering.

### BOR vs SOR volume relationship

Phase 2 increases the fan-out per BOR request because v2 BOR functions call additional SORs (Baseline, History, Registry) alongside the Profile Data SOR.

```
1 Triage v2 request       → 2 Profile Data calls + 1 Baseline call + 1 History write = 4 SOR calls
1 Diff Report v2 request  → 2 Profile Data calls + 1 Baseline call + 1 History write = 4 SOR calls
1 Fleet Search v2 request → N Profile Data calls + 1 Registry call = N+1 SOR calls
```

### TPS summary

| Function | Type | Expected TPS | Usage Pattern |
|----------|------|:------------:|---------------|
| Triage v2 BOR | BOR | Under 10 | On-demand during incidents. Same as Phase 1, now with baseline comparison. |
| Diff Report v2 BOR | BOR | Under 5 | Post-deployment. Same as Phase 1, now with threshold annotation. |
| Fleet Search v2 BOR | BOR | Under 5 | Ad-hoc investigation. Same as Phase 1, now with ownership enrichment. |
| Profile Data SOR | SOR | Under 50 | Fan-out from all three BOR functions. Unchanged from Phase 1. |
| Baseline SOR | SOR | Under 1 | Reference data lookups. Read on each Triage/Diff request, written rarely by admins setting thresholds. |
| History SOR | SOR | Under 5 | Write-heavy relative to reads. Every Triage and Diff assessment writes one audit record. Reads happen during post-mortem reviews. |
| Registry SOR | SOR | Under 1 | Reference data lookups. Read on each Fleet Search request, written rarely by admins registering services. |
| Alert Rule SOR | SOR | Under 1 | Admin-only CRUD. Rules are created and updated infrequently. Read when evaluating alerts (future phase). |

### How TPS estimates were calculated

See [Phase 1 questionnaire](production-questionnaire-phase1.md#how-tps-estimates-were-calculated) for the full methodology. TPS is derived from: **(concurrent users) x (requests per user action) x (fan-out multiplier)**.

Phase 2 BOR TPS is unchanged from Phase 1 — the same human-triggered usage patterns apply. The additional SOR TPS comes from the increased fan-out per BOR request.

**SOR TPS (internal calls from v2 BOR functions):**

| Source | BOR TPS | Profile Data Fan-out | Baseline | History | Registry | Total SOR TPS |
|--------|:-------:|:--------------------:|:--------:|:-------:|:--------:|:-------------:|
| Triage v2 | 5 | x 2 = 10 | x 1 = 5 | x 1 = 5 | — | 20 |
| Diff Report v2 | 3 | x 2 = 6 | x 1 = 3 | x 1 = 3 | — | 12 |
| Fleet Search v2 | 2 | x 15 = 30 | — | — | x 1 = 2 | 32 |
| **Combined peak** | | **46** | **8** | **8** | **2** | **64** |

- Profile Data SOR: 46 TPS (unchanged from Phase 1, still under 50)
- Baseline SOR: 8 TPS peak, rounds to "under 10" — but typical is under 1 because incidents and deploys rarely overlap
- History SOR: 8 TPS peak, rounds to "under 10" — write-only during BOR requests, reads are rare post-mortem queries
- Registry SOR: 2 TPS peak, rounds to "under 5" — one lookup per Fleet Search request
- Alert Rule SOR: Under 1 TPS — admin-only CRUD, not called by any BOR function in Phase 2

All estimates are peak concurrent scenarios. The PostgreSQL-backed SORs handle small reference data and audit trail records — total database storage is expected to stay under 1 GB. No function exceeds the 100 TPS threshold.

---

## Upgraded BOR Functions (v1 → v2)

The v2 functions serve the same API endpoints with the same parameters. The response includes additional fields. No breaking changes.

### 1. Triage v2 — `ReadPyroscopeTriageAssessment.v2`

| Field | Answer |
|-------|--------|
| Use Case | Extends Phase 1 triage with baseline threshold comparison (e.g., "GC is at 34.2% which exceeds the approved baseline of 15%") and saves every assessment to an audit trail for trend analysis and post-mortem review. |
| Business Benefit | Replaces subjective "GC looks high" with quantified baseline violations and creates a compliance-ready audit trail of every diagnosis. |
| Verticle | `TriageFullVerticle.java` |
| Additional dependencies | Baseline SOR, History SOR |
| Volume | Under 10 TPS |

### 2. Diff Report v2 — `ReadPyroscopeDiffReport.v2`

| Field | Answer |
|-------|--------|
| Use Case | Extends Phase 1 diff report by annotating regressions with whether they breach approved thresholds, and saves each comparison to the audit trail for deployment history tracking. |
| Business Benefit | Provides data-driven deployment go/no-go decisions with threshold context so teams know not just what changed but whether it matters. |
| Verticle | `DiffReportFullVerticle.java` |
| Additional dependencies | Baseline SOR, History SOR |
| Volume | Under 5 TPS |

### 3. Fleet Search v2 — `ReadPyroscopeFleetSearch.v2`

| Field | Answer |
|-------|--------|
| Use Case | Extends Phase 1 fleet search by enriching results with team ownership and service tier from the service registry, adding a critical service count to prioritize hotspots affecting production-critical services. |
| Business Benefit | Hotspot findings route directly to the responsible team with tier context, eliminating the manual step of looking up who owns each affected service. |
| Verticle | `FleetSearchFullVerticle.java` |
| Additional dependencies | Service Registry SOR |
| Volume | Under 5 TPS |

---

## New SOR Functions (4)

All require PostgreSQL. Same JAR as Phase 1's Profile Data SOR — different `FUNCTION` env var.

### 4. Profile Data — `ReadPyroscopeProfile.sor.v1` (unchanged)

| Field | Answer |
|-------|--------|
| Use Case | Wraps the Pyroscope HTTP API to parse raw flamebearer JSON into ranked function lists with percentages, serving as the single data access layer for all three BOR functions. |
| Business Benefit | Isolates Pyroscope API coupling into one SOR so BOR functions are insulated from upstream API changes and all profiling data parsing logic is centralized and tested in one place. |
| Verticle | `ProfileDataVerticle.java` — 3 GET endpoints |
| Database | None (calls Pyroscope over HTTP) |
| Volume | Under 50 TPS |

### 5. Baseline — `ReadPyroscopeBaseline.sor.v1`

| Field | Answer |
|-------|--------|
| Use Case | CRUD for approved performance thresholds per function so that Triage and Diff Report can automatically flag when a function exceeds its approved self-percent. |
| Business Benefit | Establishes approved baselines that turn subjective performance assessments into objective threshold violations, enabling automated enforcement. |
| Verticle | `BaselineVerticle.java` — POST, GET, GET, PUT, DELETE |
| Database | PostgreSQL, `performance_baseline` table, unique on `(app_name, profile_type, function_name)` |
| Volume | Under 1 TPS |

### 6. History — `CreatePyroscopeTriageHistory.sor.v1`

| Field | Answer |
|-------|--------|
| Use Case | Stores every triage and diff assessment as an audit trail entry so post-mortem reviews can reference exactly what was diagnosed and when, and trend analysis can track performance over time. |
| Business Benefit | Provides a compliance-ready audit trail of every automated diagnosis and enables trend analysis to detect slow-burn regressions across releases. |
| Verticle | `TriageHistoryVerticle.java` — POST, GET by app, GET latest, DELETE |
| Database | PostgreSQL, `triage_history` table, index on `(app_name, created_at DESC)` |
| Volume | Under 5 TPS |

### 7. Registry — `ReadPyroscopeServiceRegistry.sor.v1`

| Field | Answer |
|-------|--------|
| Use Case | Maintains metadata for each monitored service (team owner, tier, environment, notification channel) so fleet search results include who owns each service and its criticality. |
| Business Benefit | Eliminates the manual lookup of service ownership when a fleet-wide hotspot is found, routing findings directly to the responsible team. |
| Verticle | `ServiceRegistryVerticle.java` — POST, GET all, GET by app, PUT, DELETE |
| Database | PostgreSQL, `service_registry` table, unique on `app_name` |
| Volume | Under 1 TPS |

### 8. Alert Rule — `ReadPyroscopeAlertRule.sor.v1`

| Field | Answer |
|-------|--------|
| Use Case | CRUD for profiling-based alert rules (e.g., "alert if GC exceeds 30% for app X") that will drive future automated alerting when a function breaches its threshold. |
| Business Benefit | Lays the foundation for proactive profiling-based alerts, shifting from reactive incident diagnosis to automated detection before users are impacted. |
| Verticle | `AlertRuleVerticle.java` — POST, GET all, GET by app, active rules, PUT, DELETE |
| Database | PostgreSQL, `alert_rule` table, index on `(app_name, enabled)` |
| Volume | Under 1 TPS |

---

## Database Details

| Field | Answer |
|-------|--------|
| Database type | PostgreSQL |
| Number of databases | 1 |
| Number of tables | 4 (performance_baseline, triage_history, service_registry, alert_rule) |
| Estimated storage | Under 1 GB. Small reference data and audit trail records. |
| Connection pooling | Vert.x PgPool with configurable pool size (default 5). |
| Retry logic | Exponential backoff, max 3 retries, 5 second cap. |
| Schema management | SQL DDL in `schema.sql`. Applied manually or via migration tool. |

---

## Testing and Quality Assurance

### Test Framework

| Component | Technology | Version |
|-----------|-----------|---------|
| Test framework | JUnit 5 (Jupiter) | 5.10.2 |
| Assertions | AssertJ | 3.26.0 |
| Vert.x test support | vertx-junit5 | 4.5.8 |
| Database testing | Testcontainers (PostgreSQL) | 1.19.8 |

### Test Coverage

All functions are provided in two Java versions (Java 11 and Java 17). Each version has its own test suite.

| Project | Unit Tests | Integration Tests | Total |
|---------|-----------|-------------------|-------|
| pyroscope-bor (Java 17) | 77 (5 classes) | 16 (4 classes) | 93 |
| pyroscope-bor-java11 | 77 (5 classes) | 16 (4 classes) | 93 |
| pyroscope-sor (Java 17) | 31 (2 classes) | 43 (4 classes) | 74 |
| pyroscope-sor-java11 | 26 (2 classes) | 43 (4 classes) | 69 |
| **Total** | **211** | **118** | **329** |

SOR integration tests use Testcontainers to spin up a real PostgreSQL database (Docker required).

### Running Tests

```bash
make test-bor       # BOR tests (no Docker required)
make test-sor       # SOR tests (requires Docker for Testcontainers)
make test           # All tests
make compile        # Compile all projects
```

---

## Deployment Configuration

| Function | FUNCTION Value | Port | Depends On |
|----------|---------------|------|------------|
| Profile Data SOR | `ReadPyroscopeProfile.sor.v1` | 8082 | Pyroscope |
| Baseline SOR | `ReadPyroscopeBaseline.sor.v1` | 8081 | PostgreSQL |
| History SOR | `CreatePyroscopeTriageHistory.sor.v1` | 8081 | PostgreSQL |
| Registry SOR | `ReadPyroscopeServiceRegistry.sor.v1` | 8081 | PostgreSQL |
| Alert Rule SOR | `ReadPyroscopeAlertRule.sor.v1` | 8081 | PostgreSQL |
| Triage v2 BOR | `ReadPyroscopeTriageAssessment.v2` | 8080 | Profile Data + Baseline + History |
| Diff Report v2 BOR | `ReadPyroscopeDiffReport.v2` | 8080 | Profile Data + Baseline + History |
| Fleet Search v2 BOR | `ReadPyroscopeFleetSearch.v2` | 8080 | Profile Data + Registry |

### Environment Variables — PostgreSQL SORs

| Variable | Required | Description |
|----------|:--------:|-------------|
| `FUNCTION` | Yes | See table above |
| `PORT` | No | HTTP listen port (default: 8080) |
| `DB_HOST` | Yes | PostgreSQL host |
| `DB_PORT` | No | PostgreSQL port (default: 5432) |
| `DB_NAME` | Yes | Database name |
| `DB_USER` | Yes | Database username |
| `DB_PASSWORD` | Yes | Database password |
| `DB_POOL_SIZE` | No | Connection pool size (default: 5) |

### Environment Variables — v2 BOR Functions

| Variable | Required | Description |
|----------|:--------:|-------------|
| `FUNCTION` | Yes | See table above |
| `PORT` | No | HTTP listen port (default: 8080) |
| `PROFILE_DATA_URL` | Yes | URL of Profile Data SOR |
| `BASELINE_URL` | No | URL of Baseline SOR (omit to disable) |
| `HISTORY_URL` | No | URL of Triage History SOR (omit to disable) |
| `REGISTRY_URL` | No | URL of Service Registry SOR (omit to disable) |

---

## Upgrade Path from Phase 1

1. Apply `schema.sql` to PostgreSQL (creates 4 tables)
2. Deploy 4 new PostgreSQL-backed SORs
3. Switch BOR `FUNCTION` values from v1 to v2
4. Set `BASELINE_URL`, `HISTORY_URL`, `REGISTRY_URL`

Steps 2-4 can be done incrementally — the v2 BORs silently skip any SOR whose URL is not set.

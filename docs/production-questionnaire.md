# Production Onboarding Questionnaire — Pyroscope BOR/SOR

## Initiative Summary

| Field | Answer |
|-------|--------|
| Initiative | Continuous profiling functions for Pyroscope |
| BOR functions | 3 (Triage, Diff Report, Fleet Search) — each has a v1 (lite) and v2 (full) variant |
| SOR functions | 5 total: 1 stateless (Profile Data), 4 PostgreSQL-backed (Baseline, History, Registry, AlertRule) |
| Building off existing SOR? | No — new SOR wrapping Pyroscope API |
| Type of service | Intranet |
| Hosted | Internal |
| External deployment | No |

All functions are HTTP request/response only. No file upload/download, cron triggers, Kafka, or protobuf.

---

## BOR Functions

All BOR functions are stateless HTTP GET endpoints. Java 11 and Java 21 versions provided. No database.

### 1. Triage — `ReadPyroscopeTriageAssessment.v1`

Queries an app's CPU and allocation profiles, applies pattern-matching diagnostic rules, returns diagnosis + severity + recommendation. Called during incidents instead of manually reading flame graphs.

- **Verticle:** `TriageVerticle.java`
- **Impact:** Cuts incident MTTR by removing the manual flame graph interpretation step. Consistent diagnosis regardless of who's on call.
- **Volume:** Under 10 TPS (on-demand during incidents)

### 2. Diff Report — `ReadPyroscopeDiffReport.v1`

Compares profiling data between two time windows to find per-function regressions and improvements. JSON or Markdown output. Called post-deploy to validate no regressions.

- **Verticle:** `DiffReportVerticle.java`
- **Impact:** Quantifies deployment impact at the function level. Markdown output can go straight to PRs or Slack.
- **Volume:** Under 5 TPS (post-deploy or on-demand)

### 3. Fleet Search — `ReadPyroscopeFleetSearch.v1`

Two endpoints: search for a function across all monitored apps, and rank fleet-wide hotspots by impact score (`serviceCount x maxSelfPercent`). Used by the platform team.

- **Verticle:** `FleetSearchVerticle.java`
- **Impact:** Finds cross-cutting issues in shared libraries, prioritizes optimization work by fleet-wide cost.
- **Volume:** Under 5 TPS (on-demand)

---

## SOR Functions

All SOR functions are stateless HTTP endpoints. Java 11 and Java 21 versions provided.

### 4. Profile Data — `ReadPyroscopeProfile.sor.v1`

Wraps the Pyroscope HTTP API. Parses flamebearer JSON into a ranked list of top functions with sample counts and percentages. All BOR functions go through this SOR.

- **Verticle:** `ProfileDataVerticle.java` — 3 GET endpoints
- **Database:** None (calls Pyroscope over HTTP)
- **Volume:** Under 50 TPS (each BOR request fans out to 1-N calls here)

### 5. Baseline — `ReadPyroscopeBaseline.sor.v1` *(requires DB approval)*

CRUD for approved performance thresholds (self-percent per app/type/function). Triage and Diff Report full variants check these to flag threshold violations.

- **Verticle:** `BaselineVerticle.java` — POST, GET, GET, PUT, DELETE. Upsert via `ON CONFLICT DO UPDATE`.
- **Database:** PostgreSQL, `performance_baseline` table, unique on `(app_name, profile_type, function_name)`
- **Volume:** Under 1 TPS

### 6. History — `CreatePyroscopeTriageHistory.sor.v1` *(requires DB approval)*

Audit trail for triage assessments. Full BOR variants write here after each diagnosis. Used in post-mortems and trend analysis.

- **Verticle:** `TriageHistoryVerticle.java` — POST, GET by app w/ time range, GET latest, DELETE. JSONB column.
- **Database:** PostgreSQL, `triage_history` table, index on `(app_name, created_at DESC)`
- **Volume:** Under 5 TPS

### 7. Registry — `ReadPyroscopeServiceRegistry.sor.v1` *(requires DB approval)*

Metadata for monitored apps: team owner, tier, environment, notification channel. Fleet Search full variant reads this for ownership enrichment.

- **Verticle:** `ServiceRegistryVerticle.java` — POST, GET all, GET by app, PUT, DELETE. JSONB columns.
- **Database:** PostgreSQL, `service_registry` table, unique on `app_name`
- **Volume:** Under 1 TPS

### 8. Alert Rule — `ReadPyroscopeAlertRule.sor.v1` *(requires DB approval)*

CRUD for profiling-based alert thresholds (e.g., "alert if GC > 30% for app X"). For future automation.

- **Verticle:** `AlertRuleVerticle.java` — POST, GET all, GET by app, active rules, PUT, DELETE
- **Database:** PostgreSQL, `alert_rule` table, index on `(app_name, enabled)`
- **Volume:** Under 1 TPS

---

## Deployment Phases

### Phase 1 — No Database (3 BOR + 1 SOR)

| Item | Detail |
|------|--------|
| BOR functions | 3: ReadPyroscopeTriageAssessment.v1, ReadPyroscopeDiffReport.v1, ReadPyroscopeFleetSearch.v1 |
| SOR functions | 1: ReadPyroscopeProfile.sor.v1 (wraps Pyroscope HTTP API, no database) |
| Total functions | 4 |
| Database required | No |
| External dependencies | Pyroscope (already deployed) |

All three BOR functions call the Profile Data SOR over HTTP. The Profile Data SOR calls the Pyroscope API and parses flamebearer responses into ranked function lists. No PostgreSQL needed.

### Phase 2 — With PostgreSQL (3 BOR + 5 SOR)

| Item | Detail |
|------|--------|
| BOR functions | 3: ReadPyroscopeTriageAssessment.v2, ReadPyroscopeDiffReport.v2, ReadPyroscopeFleetSearch.v2 (replace Phase 1 v1 BORs) |
| SOR functions | 5: ReadPyroscopeProfile.sor.v1 (unchanged), ReadPyroscopeBaseline.sor.v1, CreatePyroscopeTriageHistory.sor.v1, ReadPyroscopeServiceRegistry.sor.v1, ReadPyroscopeAlertRule.sor.v1 |
| Total functions | 8 |
| Database required | PostgreSQL (single instance, 4 tables) |
| External dependencies | Pyroscope (already deployed) |

Phase 1 → Phase 2 upgrade: deploy the 4 new PostgreSQL-backed SORs, then switch BOR `FUNCTION` env vars from v1 to v2 and set the additional SOR URLs. The v2 BORs handle missing SOR URLs gracefully, so the upgrade can be done incrementally.

---

## Database Details (Phase 2 only)

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

### Test Coverage by Project

All functions are provided in two Java versions (Java 11 and Java 17). Each version has its own test suite.

| Project | Unit Tests | Integration Tests | Total |
|---------|-----------|-------------------|-------|
| pyroscope-bor (Java 17) | 77 (5 classes) | 16 (4 classes) | 93 |
| pyroscope-bor-java11 | 77 (5 classes) | 16 (4 classes) | 93 |
| pyroscope-sor (Java 17) | 31 (2 classes) | 43 (4 classes) | 74 |
| pyroscope-sor-java11 | 26 (2 classes) | 43 (4 classes) | 69 |
| **Total** | **211** | **118** | **329** |

### Unit Test Classes

**BOR (both versions):**

| Class | What It Tests |
|-------|--------------|
| `ProfileTypeTest` | Profile type parsing, aliases, case insensitivity, query string generation |
| `PyroscopeClientExtractTest` | Flamebearer JSON parsing, function extraction, aggregation, sorting, edge cases |
| `TriageRulesTest` | Diagnosis pattern matching for all profile types, recommendations, severity levels |
| `DiffComputationTest` | Delta computation, filtering, sorting, threshold comparison, utility methods |
| `HotspotScorerTest` | Impact score calculation, ranking, limit enforcement |

**SOR (both versions):**

| Class | What It Tests |
|-------|--------------|
| `ProfileTypeTest` | Profile type parsing, aliases, case insensitivity, query string generation |
| `PyroscopeClientExtractTest` | Flamebearer JSON parsing, function extraction, aggregation, sorting, edge cases |

### Integration Test Classes

**BOR (both versions) — no Docker required:**

BOR integration tests use mock HTTP servers (Vert.x `HttpServer` + `Router`) to simulate upstream SOR services. No external dependencies needed.

| Class | What It Tests |
|-------|--------------|
| `TriageVerticleIntegrationTest` | End-to-end triage flow: health check, default diagnosis, severity levels, upstream failure handling |
| `DiffReportVerticleIntegrationTest` | End-to-end diff: JSON and markdown output, regression/improvement detection, upstream failure |
| `FleetSearchVerticleIntegrationTest` | End-to-end fleet search: parameter validation, function search, hotspot ranking |
| `SorClientIntegrationTest` | SOR client: profile retrieval, app listing, baseline fallback, history saving |

**SOR (both versions) — Docker required for Testcontainers:**

SOR integration tests use Testcontainers to spin up a real PostgreSQL database. Docker daemon must be running.

| Class | What It Tests |
|-------|--------------|
| `BaselineVerticleIntegrationTest` | CRUD for performance baselines: create, upsert, list, update, delete, validation |
| `TriageHistoryVerticleIntegrationTest` | CRUD for triage history: create, list with pagination, latest entry, delete, audit trail |
| `ServiceRegistryVerticleIntegrationTest` | CRUD for service registry: create, upsert, list with tier filter, update JSONB fields, delete |
| `AlertRuleVerticleIntegrationTest` | CRUD for alert rules: create, list with app filter, active rules, update, delete, validation |

### Running Tests

From the `services/` directory using the Makefile:

```bash
# Run all unit tests (no Docker required)
make test-unit

# Run all BOR tests (unit + integration, no Docker required)
make test-bor

# Run all SOR tests (unit + integration, requires Docker)
make test-sor

# Run everything
make test

# Run tests for a specific project
make test-bor-21    # pyroscope-bor (Java 17)
make test-bor-11    # pyroscope-bor-java11
make test-sor-21    # pyroscope-sor (Java 17)
make test-sor-11    # pyroscope-sor-java11

# Compile all projects without running tests
make compile
```

Or directly with Gradle from any project directory:

```bash
cd services/pyroscope-bor
./gradlew test                                    # All tests
./gradlew test --tests '*TriageRulesTest'         # Specific test class
./gradlew test --tests '*IntegrationTest'         # Integration tests only
```

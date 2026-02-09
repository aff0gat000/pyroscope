# Production Onboarding Questionnaire — Pyroscope BOR/SOR Functions

## Initiative Summary

| Field | Answer |
|-------|--------|
| Initiative | Continuous profiling observability functions for Pyroscope |
| Total BOR functions | 6 — 3 lite (ReadPyroscopeTriageAssessment.v1, ReadPyroscopeDiffReport.v1, ReadPyroscopeFleetSearch.v1) + 3 full (ReadPyroscopeTriageAssessment.v2, ReadPyroscopeDiffReport.v2, ReadPyroscopeFleetSearch.v2) |
| Total SOR functions | 1 for initial deployment (ReadPyroscopeProfile.sor.v1). 4 additional when database is approved (ReadPyroscopeBaseline.sor.v1, CreatePyroscopeTriageHistory.sor.v1, ReadPyroscopeServiceRegistry.sor.v1, ReadPyroscopeAlertRule.sor.v1). |
| Building off existing SOR? | No. Profile Data SOR is new — wraps the Pyroscope API. |
| Type of service | Intranet |
| Hosted | Internally at enterprise |
| External deployment (AWS/cloud/3rd party) | No |

---

## BOR Functions

### 1. Triage

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `ReadPyroscopeTriageAssessment.v1` |
| **Description / MVP** | Automated diagnosis of an application's profiling data. Accepts an application name, queries its CPU and allocation profiles from the Profile Data SOR, applies pattern-matching diagnostic rules, and returns the primary issue, severity level, and actionable recommendation. Engineers call this during incidents instead of manually reading flame graphs. |
| **Business benefit / impact** | Reduces mean time to resolution during incidents by eliminating the manual profiling investigation step. Provides consistent diagnostic quality regardless of who is on call. Enables junior engineers to get the same profiling diagnosis as experts. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`TriageVerticle.java`). HTTP GET endpoint. Stateless — no local storage, no sessions. Calls Profile Data SOR over HTTP. |
| **Expected volumes** | Low. Called on-demand during incidents or by automation. Estimated under 10 TPS. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | None |

### 2. Diff Report

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `ReadPyroscopeDiffReport.v1` |
| **Description / MVP** | Compares profiling data between two time windows (baseline vs current) to detect per-function performance regressions and improvements after a deployment. Returns results as JSON or Markdown. Engineers call this after deploying to verify no regressions were introduced. |
| **Business benefit / impact** | Provides deployment confidence by quantifying performance changes at the function level. Gives teams evidence for rollback decisions. Validates optimization work with numbers. Markdown output can be posted to pull requests or Slack as deployment evidence. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`DiffReportVerticle.java`). HTTP GET endpoint. Stateless. Calls Profile Data SOR over HTTP. |
| **Expected volumes** | Low. Called after deployments or on-demand for performance review. Estimated under 5 TPS. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | None |

### 3. Fleet Search

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `ReadPyroscopeFleetSearch.v1` |
| **Description / MVP** | Searches for functions across all Pyroscope-monitored applications and ranks fleet-wide hotspots by impact score. Two endpoints: search by function name (e.g., find all apps where `HashMap.resize` appears) and hotspot ranking (top N functions by fleet-wide impact). Used by the platform team for fleet-wide performance visibility. |
| **Business benefit / impact** | Identifies cross-cutting performance issues in shared libraries that affect multiple applications. Prioritizes optimization work by organizational impact. Detects when multiple applications share a common root cause during incidents. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`FleetSearchVerticle.java`). Two HTTP GET endpoints. Stateless. Calls Profile Data SOR over HTTP. |
| **Expected volumes** | Low. Called on-demand by platform engineering team. Estimated under 5 TPS. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | None |

---

## SOR Functions

### 4. Profile Data

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `ReadPyroscopeProfile.sor.v1` |
| **Description / MVP** | Data access layer wrapping the Pyroscope HTTP API. Accepts profile queries from BOR functions, calls Pyroscope's render and label-values endpoints, parses the flamebearer JSON response into a clean list of top functions with sample counts and percentages. All BOR functions call this SOR — none access Pyroscope directly. |
| **Business benefit / impact** | Enforces the BOR/SOR architectural pattern. Centralizes Pyroscope API access, flamebearer parsing logic, and connection management in one place. If Pyroscope API changes, only this SOR needs to be updated. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`ProfileDataVerticle.java`). Three HTTP GET endpoints (`/profiles/:appName`, `/profiles/:appName/diff`, `/profiles/apps`). Stateless. Calls Pyroscope over HTTP. |
| **Expected volumes** | Low. Called by BOR functions only. Each BOR request generates 1-N calls to this SOR (N = number of profile types or applications). Estimated under 50 TPS even under peak fleet search usage. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | None. Reads from Pyroscope (HTTP API), not a database. |

### 5. Baseline (requires database approval)

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `ReadPyroscopeBaseline.sor.v1` |
| **Description / MVP** | CRUD for approved performance thresholds. Teams define acceptable self-percent thresholds per application, profile type, and function name. The Triage and Diff Report full BOR variants read these baselines to produce threshold-aware diagnoses. |
| **Business benefit / impact** | Enables data-driven deployment go/no-go decisions. Teams define what "acceptable performance" means for their application, and the system flags when thresholds are exceeded. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`BaselineVerticle.java`). Five HTTP endpoints (POST, GET by app, GET by app+type, PUT, DELETE). Idempotent upsert via `ON CONFLICT DO UPDATE`. |
| **Expected volumes** | Very low. CRUD operations by engineers setting thresholds. Estimated under 1 TPS. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | PostgreSQL. Single table `performance_baseline` with unique constraint on (app_name, profile_type, function_name). |

### 6. History (requires database approval)

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `CreatePyroscopeTriageHistory.sor.v1` |
| **Description / MVP** | CRUD for triage assessment audit trail. Records every triage assessment for trend analysis, incident post-mortems, and compliance. The Triage and Diff Report full BOR variants write here after each assessment. |
| **Business benefit / impact** | Provides an audit trail for compliance. Enables trend analysis — track whether an application's performance is improving or degrading over time. Supports post-mortem review with historical triage data. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`TriageHistoryVerticle.java`). Four HTTP endpoints (POST, GET by app with time range, GET latest, DELETE). JSONB column for top functions. |
| **Expected volumes** | Low. Writes occur after each triage or diff report (full variants only). Reads during post-mortem review. Estimated under 5 TPS. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | PostgreSQL. Single table `triage_history` with index on (app_name, created_at DESC). |

### 7. Registry (requires database approval)

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `ReadPyroscopeServiceRegistry.sor.v1` |
| **Description / MVP** | CRUD for Pyroscope-monitored application metadata. Stores team ownership, tier, environment, and notification channel for each application. The Fleet Search full BOR variant reads this to enrich search results with ownership context. |
| **Business benefit / impact** | Enables the platform team to route performance findings to the correct team. Tracks which applications are profiled and who owns them. Supports tier-based prioritization of hotspots. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`ServiceRegistryVerticle.java`). Five HTTP endpoints (POST, GET all, GET by app, PUT, DELETE). Idempotent upsert by app_name. JSONB columns for labels and metadata. |
| **Expected volumes** | Very low. CRUD operations by platform team managing application metadata. Estimated under 1 TPS. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | PostgreSQL. Single table `service_registry` with unique constraint on app_name. |

### 8. Alert Rule (requires database approval)

| Field | Answer |
|-------|--------|
| **FUNCTION value** | `ReadPyroscopeAlertRule.sor.v1` |
| **Description / MVP** | CRUD for profiling-based alert rules. Stores per-application alert thresholds (e.g., alert if GC percentage exceeds 30% for a given application). Used by future automation to trigger alerts based on profiling data. |
| **Business benefit / impact** | Enables proactive alerting based on profiling thresholds instead of reactive incident response. Teams define performance guardrails that generate alerts before issues impact users. |
| **Function details** | Java 11 or Java 21 (both versions provided), Vert.x 4.5.8. Single verticle (`AlertRuleVerticle.java`). Five HTTP endpoints (POST, GET all, GET by app, PUT, DELETE). Index on (app_name, enabled). |
| **Expected volumes** | Very low. CRUD operations by engineers managing alert rules. Estimated under 1 TPS. Well below 100 TPS threshold. |
| **Additional capabilities** | None. HTTP request/response only. No file upload/download, no cron triggers, no Kafka streaming, no protobuf. |
| **Database** | PostgreSQL. Single table `alert_rule` with index on (app_name, enabled). |

---

## Deployment Phases

### Phase 1 — Standalone Triage (no SOR, no database)

| Item | Count |
|------|-------|
| BOR functions to deploy | 1 (ReadPyroscopeTriageAssessment.v1) |
| SOR functions to deploy | 0 — data access is embedded in the BOR |
| Total functions | 1 |
| Database required | No |
| External dependencies | Pyroscope (already deployed) |
| Notes | The triage BOR calls Pyroscope directly via an embedded data access layer. No separate SOR deployment needed. Logical BOR/SOR separation is maintained in code (business logic in `TriageVerticle`, data access in `com.pyroscope.bor.sor.PyroscopeClient`). |

### Phase 2 — Full (SOR services + database required)

| Item | Count |
|------|-------|
| BOR functions to deploy | 3 (ReadPyroscopeTriageAssessment.v2, ReadPyroscopeDiffReport.v2, ReadPyroscopeFleetSearch.v2) — replaces Phase 1 standalone triage |
| SOR functions to deploy | 5 (ReadPyroscopeProfile.sor.v1, ReadPyroscopeBaseline.sor.v1, CreatePyroscopeTriageHistory.sor.v1, ReadPyroscopeServiceRegistry.sor.v1, ReadPyroscopeAlertRule.sor.v1) |
| Total functions | 8 |
| Database required | PostgreSQL (single instance, 4 tables) |
| External dependencies | Pyroscope (already deployed) |

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

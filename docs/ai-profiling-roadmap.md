# AI-Assisted Continuous Profiling Roadmap

AI/ML applied to continuous profiling data enables automated anomaly detection, root cause analysis, and optimization recommendations. This document outlines integration phases from foundational data pipelines to autonomous remediation.

---

## Phase 1: Data Pipeline

Foundation: export profiling data to ML-consumable formats.

- Export Pyroscope profile data via API (`/pyroscope/render` JSON format) into a data lake or feature store
- Normalize flame graph data into tabular features: function name, self-time percentage, call count, allocation bytes, mutex wait time
- Join with Prometheus metrics (CPU, heap, GC, HTTP latency) for correlated feature vectors
- Establish baseline profiles per service per deploy version
- Storage: time-series DB or columnar store (Parquet on S3, ClickHouse, BigQuery)

Produces per-service, per-function feature vectors at regular intervals (e.g., 1-minute granularity).

---

## Phase 2: Anomaly Detection

Detect profile shape changes automatically.

- Statistical methods: compare current function-level CPU/alloc shares against rolling baselines using z-scores or KL divergence
- ML models: train autoencoders or isolation forests on flame graph feature vectors to detect novel execution patterns
- Alert when a function's resource share deviates beyond threshold (e.g., CPU share increased >20% vs 7-day baseline)
- Correlate profile anomalies with metric anomalies (latency spike + new hot function = high confidence alert)
- Reduce alert noise: only fire when both metric AND profile anomalies co-occur

Integration point: Prometheus Alertmanager webhook → profile anomaly enrichment → PagerDuty/Slack.

---

## Phase 3: Automated Root Cause Analysis

Given an anomaly, identify the probable root cause.

- Diff flame graphs: compute frame-level deltas between anomalous window and baseline
- Rank functions by delta magnitude (largest increase in self-time = most likely cause)
- Correlate with deployment events (git SHA, config changes) to attribute regressions to specific commits
- Use LLM integration: feed the diff summary (function name, package, delta %, call stack) to an LLM with codebase context to generate a natural-language explanation
- Output: "Function X in service Y increased CPU share by 30% after deploy Z. Call stack shows new code path through method A → B → C."

Integration point: incident management system receives structured root cause reports.

---

## Phase 4: Optimization Recommendations

Suggest code-level fixes based on profiling patterns.

- Pattern library: maintain a catalog of known anti-patterns and their profiling signatures
  - `MessageDigest.getInstance()` in hot path → recommend ThreadLocal caching
  - `Pattern.compile()` per request → recommend static final precompilation
  - `synchronized` method with wide mutex frame → recommend ConcurrentHashMap or lock-free structures
  - `String.format()` in tight loop → recommend StringBuilder
- LLM-powered recommendations: given a flame graph hotspot and source code context, generate specific refactoring suggestions
- Confidence scoring: rank recommendations by expected impact (self-time % × request rate = resource savings)
- PR integration: auto-generate draft PRs with suggested fixes and expected profile impact

---

## Phase 5: CI/CD Profile Regression Gates

Prevent performance regressions from reaching production.

- Baseline capture: after each main branch deploy, snapshot per-service profile data
- PR pipeline: deploy candidate build, generate synthetic load, capture profiles
- Automated comparison: diff candidate profiles against baseline using Phase 2 anomaly detection
- Gate criteria: fail pipeline if any function's CPU/alloc share increased beyond threshold
- Report: post profile diff summary as PR comment (function, baseline %, candidate %, delta)
- Artifact storage: archive flame graph snapshots per build for historical comparison

---

## Phase 6: Autonomous Remediation (Experimental)

Closed-loop: detect, diagnose, and fix without human intervention.

- Scope: limited to well-understood patterns with high-confidence fixes (e.g., JVM flag tuning, thread pool sizing, cache enabling)
- Guardrails: canary deployment, automatic rollback if metrics degrade post-fix
- Human approval gate: autonomous system proposes fix → human approves → system deploys
- Full autonomy (future): for pre-approved fix categories with bounded blast radius

---

## Architecture

```
Pyroscope API ──→ Profile Exporter ──→ Feature Store
                                            │
Prometheus API ──→ Metric Exporter ──────→──┤
                                            │
Git/Deploy Events ──→ Event Ingester ────→──┤
                                            ▼
                                    Anomaly Detector
                                            │
                                    ┌───────┴───────┐
                                    ▼               ▼
                              Root Cause        Regression
                              Analyzer          Gate (CI/CD)
                                    │               │
                                    ▼               ▼
                              Incident          PR Comment /
                              Report            Pipeline Gate
                                    │
                                    ▼
                              Fix Recommender
                                    │
                                    ▼
                              Draft PR / Remediation
```

---

## Implementation Priorities

| Priority | Phase | Prerequisite | Effort |
|----------|-------|-------------|--------|
| 1 | Data Pipeline | Pyroscope + Prometheus running | Low |
| 2 | CI/CD Gates | Data Pipeline + CI infrastructure | Medium |
| 3 | Anomaly Detection | Data Pipeline + baseline data | Medium |
| 4 | Root Cause Analysis | Anomaly Detection + deploy tracking | High |
| 5 | Optimization Recommendations | Root Cause Analysis + pattern library | High |
| 6 | Autonomous Remediation | All above + canary infrastructure | Very High |

---

## References

- Pyroscope API: `/pyroscope/render`, `/pyroscope/label-values`, `/pyroscope/render-diff`
- Prometheus API: `/api/v1/query`, `/api/v1/query_range`
- This project's CLI tools: `scripts/bottleneck.sh`, `scripts/top-functions.sh`, `scripts/diagnose.sh`

# Explanation — ML use cases mapped to features

Three tiers, ranked by "value for effort at demo scale".

## Tier 1 — shipped

| use case                       | feature path                                          | signal |
|--------------------------------|--------------------------------------------------------|--------|
| Per-integration anomalies      | `anomaly_detect` DAG → `anomalies` table → Web UI      | z-score > 3 on rolling window |
| Regression detection + LLM     | `regression_detect` DAG → `regressions` + `llm_summary` | relative shift > 50% |
| Hotspot leaderboard            | `function_features` SQL → `/hotspots/leaderboard`      | aggregate over window |
| Incident similarity            | `fingerprints` + `incidents.fingerprint` pgvector      | cosine nearest-neighbour |
| Daily report                   | `daily_hotspot_report` DAG → MinIO + MLflow            | markdown summary |
| Chat with context              | `/chat` endpoint + live hotspot/anomaly snapshot       | LLM + injected data |

## Tier 2 — designed, not shipped

| use case                       | what it would need                                      |
|--------------------------------|---------------------------------------------------------|
| Root-cause similarity on live flame graphs | fingerprint the *current* flame graph and search `fingerprints` instead of `incidents.fingerprint` |
| Predictive latency             | join `function_features` with phase-1 `http_server_*` Prometheus metrics; train per-service regressor |
| Code-diff blast-radius         | label (commit SHA, profile delta) pairs; train simple classifier |

## Tier 3 — research-grade

| use case                       | why hard                                                |
|--------------------------------|---------------------------------------------------------|
| LLM-generated patches          | needs source-code access + sandboxed verify             |
| Automated topology map         | requires causal trace links (OpenTelemetry), not just profiles |

## Why "fingerprint" is a hash bag

```python
# lib/feature_extraction.py :: fingerprint()
rows = top-N functions by (self + total) value
for fn in rows: v[ hash(fn) % dim ] += weight
v /= ||v||
```

This is intentionally simple. It is not an embedding model. It works for
the demo because:

- Similar incidents tend to share a handful of dominant functions.
- 128-D hash bags give pgvector enough room to disambiguate.
- Zero training data required.

When to upgrade:

- Once you have >200 incidents, train a simple autoencoder on fingerprints
  to get a learned embedding. pgvector column stays the same size.
- For cross-language profiles, switch to a learned embedding over tokenised
  function names.

## Where MLflow fits in

Only the `daily_hotspot_report` DAG uses MLflow today — it logs the report
as an artifact so users exploring the demo see the integration. When you
add Tier 2 use cases, each trained model goes in the registry and the BFF
loads by alias.

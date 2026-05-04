# Explanation — ML use cases and what makes each one differentiated

Six shipped use cases. For each: the manual workflow it replaces, what
makes it different from what APM vendors offer, and where you'd extend
it for a real production rollout.

## 1. Function-level regression detection with LLM summary

**Pipeline:** `regression_detect` DAG → `regressions` + `llm_summary` →
Web UI Regression page.

**What it replaces.** Today: an SRE notices p99 ticked up, opens
Pyroscope, manually picks two windows, eyeballs the diff flame graph,
identifies the regressed function, writes a Slack message explaining
it. Total: 10–20 minutes per incident, varies by experience.

**What this gives you.** Every hour, the DAG diffs the previous 30 min
vs the 30 min before that, ranks every function by relative shift, and
sends the top 10 to the configured LLM with a tight system prompt. The
output is stored alongside every regression row.

**What's differentiated.**
- **Function-level**, not just service-level. APM regression alerts
  fire on aggregate metrics; this fires on `OrderVerticle.process` or
  `Netty.directBuffer`.
- **Auto-summarized.** Datadog's "Compare profiles" view exists but
  shows you raw deltas. You still write the summary yourself.
- **Provider-neutral.** Same code path runs against Ollama (free,
  local) or Claude (best summaries) — you choose per environment.

**Production extension.** Add a confidence score to the LLM output and
suppress noisy regressions below threshold. Wire to PagerDuty when
shift > 5x with high confidence.

## 2. Cross-incident similarity search (pgvector)

**Pipeline:** `profile_etl` writes a 128-D fingerprint per (service,
profile_type) every 5 min. Incidents get the same fingerprint at
creation. `/similarity` does cosine nearest-neighbour over `incidents`.

**What it replaces.** "I swear we saw this before" → grep Slack →
search Confluence → ask senior engineer. A regular feature of incident
response that nobody owns.

**What this gives you.** Click an incident in the Web UI, see the K
most-similar past incidents ranked by cosine similarity. The
fingerprint is captured at incident time so similarity is over the
*flame graph shape*, not over alerting metadata.

**What's differentiated.**
- **No mainstream profiler ships this.** Vendors do "intelligent
  grouping" of *errors*, not flame graphs.
- **Sub-millisecond search** via pgvector ivfflat index.
- **Embeddings are explainable**: hash-bag of top-N function names,
  L2-normalized. You can read the function and audit why two
  incidents matched.

**Production extension.** Replace hash-bag with a learned autoencoder
once you have ≥200 labeled incidents. Same `vector(128)` column,
better recall.

## 3. Hotspot leaderboard across the fleet

**Pipeline:** `function_features` table populated by `profile_etl`;
`/hotspots/leaderboard` SQL aggregates.

**What it replaces.** Per-service flame-graph spelunking. Nobody
thinks about which function across **all 50 services** is wasting the
most CPU; the data is sharded one Pyroscope query at a time.

**What this gives you.** A single SQL `GROUP BY service, function ORDER
BY total DESC` over the last hour / 24h / 7d. Sorted by impact, not
alphabet.

**What's differentiated.**
- **Cross-service ranking.** Pyroscope's UI is single-service-at-a-
  time. The leaderboard view inverts the index: function-first,
  service second.
- **Drives roadmap decisions.** Engineering managers can ask "what's
  the top-10 ROI for performance work this quarter?" and get a
  data-backed answer instead of vibes.
- **Same data exposed in Grafana** via the Postgres + Infinity
  datasources, so non-React users get the same view.

**Production extension.** Multiply each row by `request_rate` from
Prometheus to convert "CPU% per process" to "CPU$ per quarter".

## 4. Per-integration anomaly detection

**Pipeline:** `anomaly_detect` DAG every 5 min → rolling z-score on
`integration_series` → `anomalies` table → Incidents page panel.

**What it replaces.** Per-metric Prometheus alerts that fire on
absolute thresholds. Tedious to tune; alert on a fixed value, miss the
slow drift.

**What this gives you.** Per-(service, integration) z-score on a 20-
sample rolling window. Anything beyond ±3σ is flagged. The integration
label means the alert is scoped: "redis on demo-jvm21 spiked", not
"something somewhere is up".

**What's differentiated.**
- **Self-tuning.** No `alert: rate > 1000`-style hardcoded thresholds.
- **Integration-scoped.** APM tools alert on host or service. This
  alerts on `service × integration` — narrow enough to ignore one of
  three Redis clients while watching the other two.
- **Correlatable with regressions.** Anomalies have timestamps; the
  Incidents page panel surfaces them inside the incident window.

**Production extension.** Layer Prophet or BOCPD on the same series
to handle seasonality. Pipe alerts to a queue instead of a UI panel.

## 5. Daily fleet hotspot report (artifact pipeline)

**Pipeline:** `daily_hotspot_report` DAG at 02:00 → top-10 CPU/alloc/lock
last 24h → Markdown to MinIO + MLflow artifact.

**What it replaces.** Nothing — usually. Most teams don't have a daily
performance digest. They wait for a customer to complain.

**What this gives you.** A markdown report you can wire to Slack,
email, or just leave in MinIO for the engineering manager's Monday
review. MLflow logs each run, so you have history for trend analysis.

**What's differentiated.**
- **MLflow integration** — every report is a logged "experiment run"
  with reproducible inputs. APM vendors don't speak MLflow.
- **Vendor-neutral artifact store** — MinIO is S3-compatible. Your
  artifacts are portable, not stuck behind a SaaS UI.

**Production extension.** Add a "diff vs yesterday" section. Train a
classifier on (report features → actual incident next day) for
predictive alerting.

## 6. Chat with profiles (LLM grounded in live state)

**Pipeline:** `/chat` SSE endpoint → context snapshot from Postgres →
LLM (Ollama/Claude/GPT/Gemini) → streaming tokens to React UI.

**What it replaces.** "Here, take this 6 MB JSON flame graph and tell
me what's wrong" → hand-rolled prompt → garbage output. Or just having
a senior engineer interpret. Both expensive.

**What this gives you.** A chat that **always sees**:
- Top 10 CPU hotspots (last hour, optionally service-filtered).
- Top 10 active anomalies with z-scores.

The system prompt anchors the LLM to that data, with explicit
instructions to cite function names and not speculate. Result: when
you ask "why is demo-jvm11 slow?" the LLM answers from data, not
hallucinates.

**What's differentiated.**
- **Grounded by construction.** Most "AI for observability" demos
  paste raw JSON into ChatGPT and hope. This injects a structured
  snapshot via the BFF; the LLM doesn't need to parse a flame graph
  format.
- **Provider-neutral.** Same prompt template runs against any of the
  four LLMs. No vendor lock-in.
- **Streaming UX.** SSE from BFF → React; tokens render as they
  arrive. Feels like Cursor / ChatGPT, not a "submit and wait" form.
- **Air-gappable.** Default Ollama means zero data leaves your
  network. Most APM "AI features" are SaaS-only.

**Production extension.** Add tool-calling so the LLM can run its own
queries (`/profiles/diff`, `/incidents/{id}`) instead of being limited
to the seed snapshot. Feed back successful query patterns into prompt
caching.

---

## Tier 2 — designed but not shipped

| use case | why valuable | what it would need |
|---|---|---|
| Root-cause similarity on **live** flame graphs | "this current incident looks like the OOM in March" before the on-call escalates | fingerprint the live flame graph and search `fingerprints` (not just `incidents`) |
| Predictive latency | early-warning before users notice | join `function_features` with phase-1 `http_server_*` metrics; train per-service regressor |
| Code-diff blast-radius | "this PR will regress N% of services" | label (commit SHA, profile delta) pairs; train classifier |

## Tier 3 — research-grade

| use case | why hard |
|---|---|
| LLM-generated patches | needs source-code access + sandboxed verify |
| Automated topology map | requires causal trace links (OpenTelemetry), not just profiles |

## Why "fingerprint" is a hash bag (not a learned embedding)

```python
# lib/feature_extraction.py :: fingerprint()
rows = top-N functions by (self + total) value
for fn in rows: v[ hash(fn) % dim ] += weight
v /= ||v||
```

Intentionally simple. Works for the demo because:
- Similar incidents share a handful of dominant functions.
- 128-D hash bags give pgvector enough room to disambiguate.
- Zero training data required.

Upgrade path:
- ≥200 labeled incidents → train autoencoder, swap embeddings, keep
  pgvector column the same size.
- Cross-language profiles → learned embedding over tokenized function
  names.

## Where MLflow fits in

Today only `daily_hotspot_report` uses MLflow — it logs the report as
an artifact so the integration is exercised. When Tier 2 use cases
ship, every trained model goes in the registry; the BFF loads by
alias for prediction endpoints.

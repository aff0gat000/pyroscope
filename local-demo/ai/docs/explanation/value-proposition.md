# Explanation — value proposition

Phase 1 made continuous profiling legible. Phase 2 answers the next
question a platform team asks: *what can I automate on top of this?*

## Why this exists

Teams installing Pyroscope typically stop at "we have flame graphs". The
gap from there to "we auto-detect regressions" / "we answer incident
questions in natural language" is a non-trivial pipeline: feature
extraction, a time-series store, anomaly detection, a model registry, an
LLM, and a UI that ties them together.

This phase builds that pipeline **at demo scale**, with real components
(Postgres, Airflow, MLflow, React+FastAPI, pgvector, Ollama) so teams
evaluating the approach can see the shape, not just a vision deck.

## Who it serves

- **Platform teams** deciding whether to invest in a profiling AI layer.
- **Data engineers** looking at a reference data-model for profiling ETL.
- **Incident responders** who want to ask "why" questions without
  hand-crafting SQL against a TSDB.
- **Architects** who want a layered-architecture example (BFF + SPA +
  shared lib + orchestrator).

## What it is not

- Not a benchmark or SLO test — traffic and data volumes are demo-scale.
- Not production-ready on security: no auth, default credentials,
  permissive CORS. See [`auth-strategy.md`](auth-strategy.md) for the
  path to fix that.
- Not a ML-research artifact — anomaly detection is z-score, similarity
  is hash-bag cosine. The point is the *wiring*, not the models.

## Measurable outcomes

A team that runs phase 2 should be able to:

1. Spot an injected regression in `<= 2 min` via the Web UI.
2. Read an LLM-generated summary of that regression.
3. Find similar past incidents via pgvector cosine.
4. Replicate the same data views in Grafana without writing a plugin.
5. Swap LLM providers (Ollama → Claude/GPT/Gemini) without code changes.

## Sibling, not replacement

Phase 2 does **not replace** phase 1's Grafana + Pyroscope view. It
layers on top. Some investigations still want the raw flame graph;
some want the LLM + leaderboard. The demo supports both.

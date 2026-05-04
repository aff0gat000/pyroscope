# Phase 2 — AI/ML on top of Pyroscope

React SPA + FastAPI BFF + Postgres+pgvector + MLflow + Airflow + Ollama.
Reads profiling data from phase 1, writes features/incidents/regressions
to Postgres, exposes them through a modern UI and through phase-1 Grafana.

## Quickstart

```bash
# phase 1 must be running first
(cd .. && ./scripts/up.sh)
# then:
./scripts/up.sh
./scripts/seed.sh                               # run DAGs once
docker compose --profile simulate up -d simulator   # continuous patterns
```

URLs printed by `up.sh`. Defaults:

| service    | default |
|------------|---------|
| Web UI     | 18500   |
| API docs   | 18000/docs |
| Airflow    | 18081   |
| MLflow     | 15000   |
| MinIO      | 19001   |
| Postgres   | 15433   |
| Ollama     | 11434   |

## Documentation — [docs/README.md](docs/README.md)

Diataxis-structured. Headline documents:

- [docs/tutorials/01-getting-started.md](docs/tutorials/01-getting-started.md)
- [docs/how-to/runbook.md](docs/how-to/runbook.md)
- [docs/reference/architecture.md](docs/reference/architecture.md) — infrastructure + mermaid
- [docs/explanation/value-proposition.md](docs/explanation/value-proposition.md) — what shifts when this layer is in place
- [docs/explanation/differentiation.md](docs/explanation/differentiation.md) — vs Datadog / Grafana Cloud / New Relic / DIY
- [docs/explanation/ml-use-cases.md](docs/explanation/ml-use-cases.md) — per use case: what it replaces, what's unique
- [docs/explanation/auth-strategy.md](docs/explanation/auth-strategy.md) — future auth plan

## Teardown

```bash
./scripts/down.sh
```

# How-to — runbook

Canonical lifecycle commands. CWD = `local-demo/ai/`.

## Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Stopped
    Stopped --> Building: ./scripts/up.sh (first time)
    Building --> Running
    Running --> Seeded: ./scripts/seed.sh
    Seeded --> Simulating: docker compose --profile simulate up -d simulator
    Seeded --> Running
    Running --> Stopped: ./scripts/down.sh
```

## Start / Stop

```bash
./scripts/up.sh               # builds + starts
./scripts/down.sh             # removes containers + volumes (ai project only)
docker compose stop           # keep volumes
docker compose restart api    # restart one container
```

## Seeding + simulating

```bash
./scripts/seed.sh                                    # trigger DAGs once
docker compose --profile simulate up -d simulator    # continuous patterns
./scripts/simulate-incident.sh blocker               # one-shot
./scripts/simulate-incident.sh leak
./scripts/simulate-incident.sh gc
./scripts/simulate-incident.sh contention
```

## Health

```bash
source .env
curl -sf localhost:$API_PORT/health | jq .
curl -sf localhost:$AIRFLOW_PORT/health | jq .
curl -sf localhost:$MLFLOW_PORT/health
curl -sf localhost:$WEB_PORT/ | head -c 200
psql "postgresql://postgres:postgres@localhost:$POSTGRES_PORT/ai" -c "SELECT COUNT(*) FROM function_features"
```

## Logs

```bash
docker compose logs -f api
docker compose logs -f airflow | grep -i error
docker compose logs --tail 100 ollama
```

## Rebuilding after changes

| change in…                     | command                                         |
|--------------------------------|-------------------------------------------------|
| `apps/api/*.py`                | `docker compose up -d --build api`              |
| `apps/web/**`                  | `docker compose up -d --build web`              |
| `lib/*.py`                     | restart consumers: `docker compose restart api airflow simulator` |
| `dags/*.py`                    | Airflow auto-reloads (file is mounted)           |
| `config/postgres/init.sql`     | `docker volume rm pyroscope-local-demo-ai_postgres-data` then `up.sh` |
| `.env` (port change)           | `docker compose up -d`                          |

## Postgres surgery

```bash
psql "postgresql://postgres:postgres@localhost:$POSTGRES_PORT/ai"
# prune manually:
\c ai
SELECT prune_old_data();
# reset all feature tables:
TRUNCATE function_features, integration_series, fingerprints, anomalies, regressions;
```

## MLflow + MinIO

- MLflow UI lists runs under experiment `daily-hotspots`.
- MinIO console (minioadmin/minioadmin) has buckets `mlflow` (model
  artifacts) and `artifacts` (DAG markdown outputs).

## Teardown

```bash
./scripts/down.sh                          # containers + volumes for phase 2
docker volume prune -f                     # optional, remove dangling
```

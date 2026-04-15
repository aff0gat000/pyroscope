# Reference — Postgres schema

DDL lives in [`../../config/postgres/init.sql`](../../config/postgres/init.sql)
and runs once on first Postgres boot. Three logical DBs on one container:

| DB         | purpose                                    | created by                |
|------------|--------------------------------------------|---------------------------|
| `ai`       | features, incidents, regressions, anomalies | `init.sql`                |
| `airflow`  | Airflow metadata                            | `init.sql` + Airflow init |
| `mlflow`   | MLflow tracking backend                     | `init.sql` + MLflow boot  |

## Tables in `ai`

```mermaid
erDiagram
    function_features {
      timestamptz ts
      text service
      text profile_type
      text function
      double self_value
      double total_value
    }
    integration_series {
      timestamptz ts
      text service
      text integration
      text profile_type
      double value
    }
    fingerprints {
      timestamptz ts
      text service
      text profile_type
      vector vector "128"
    }
    incidents {
      uuid id PK
      text kind
      text service
      timestamptz start_ts
      timestamptz end_ts
      text notes
      text postmortem_md
      vector fingerprint "128"
    }
    anomalies {
      timestamptz ts
      text service
      text metric
      double score
      timestamptz window_start
      timestamptz window_end
    }
    regressions {
      timestamptz detected_at
      text service
      text function
      text profile_type
      double before_value
      double after_value
      double shift
      text llm_summary
    }
```

## Indexes

| table                  | index                                                  | purpose                              |
|------------------------|--------------------------------------------------------|--------------------------------------|
| `function_features`    | `(service, profile_type, ts DESC)`                     | hotspot leaderboards                 |
| `function_features`    | `(ts DESC)`                                            | retention prune                      |
| `integration_series`   | `(service, integration, ts DESC)`                      | per-integration anomaly detection    |
| `fingerprints`         | `ivfflat vector_cosine_ops`                            | flame-graph similarity search        |
| `incidents`            | `(kind, start_ts DESC)` + `ivfflat fingerprint`        | incident listing + similar-to lookup |
| `anomalies`            | `(ts DESC)`                                            | recent anomalies                     |
| `regressions`          | `(service, detected_at DESC)`                          | regression inspector feed            |

## Retention

`SELECT prune_old_data();` in `daily_hotspot_report` DAG:

- `function_features`, `integration_series`, `fingerprints`: 30 days.
- `anomalies`, `regressions`, `incidents`: 90 days.

## Connecting manually

```bash
source .env
psql "postgresql://postgres:postgres@localhost:${POSTGRES_PORT}/ai"
```

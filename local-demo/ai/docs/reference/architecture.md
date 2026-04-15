# Reference — architecture & infrastructure

## Topology

```mermaid
flowchart TB
    subgraph host["Host (your laptop)"]
      BR[Browser]
      CLI[curl / scripts]
    end

    subgraph p1["Phase 1 (sibling stack)"]
      APPS[demo-jvm11 · demo-jvm21]
      PYR[Pyroscope]
      GF[Grafana]
      APPS -->|-javaagent push| PYR
      GF -->|flame graphs| PYR
    end

    subgraph p2["Phase 2 (this stack)"]
      direction TB
      subgraph data["Data"]
        PG[(ai-postgres<br/>pgvector)]
        MIO[(ai-minio)]
      end
      subgraph compute["Compute"]
        AF[ai-airflow<br/>LocalExecutor]
        SIM[ai-simulator]
      end
      subgraph serving["Serving"]
        API[ai-api<br/>FastAPI BFF]
        WEB[ai-web<br/>React SPA + nginx]
      end
      subgraph ml["ML"]
        ML[ai-mlflow]
        OL[ai-ollama]
      end
    end

    BR -->|:WEB_PORT| WEB
    WEB -->|/api/*| API
    API --> PG
    API --> PYR
    API --> OL
    API -.->|optional| CLAUDE[Claude / GPT / Gemini]
    API --> ML

    AF -->|query| PYR
    AF -->|write features| PG
    AF -->|log runs| ML
    ML --> PG
    ML --> MIO

    SIM -->|traffic + faults| APPS
    SIM -->|write incident| PG

    GF -.->|Postgres DS| PG
    GF -.->|Infinity DS| API
    CLI -->|up.sh / seed.sh / simulate-incident.sh| AF
```

## Container inventory

| container      | image / build                              | role                                           |
|----------------|--------------------------------------------|------------------------------------------------|
| `ai-postgres`  | `pgvector/pgvector:pg16`                   | single DB; 3 logical DBs (ai, airflow, mlflow) |
| `ai-minio`     | `minio/minio`                              | S3-compatible artifact store                   |
| `ai-minio-init`| `minio/mc`                                 | one-shot bucket creation                       |
| `ai-mlflow`    | `ghcr.io/mlflow/mlflow`                    | tracking + model registry                      |
| `ai-ollama`    | `ollama/ollama`                            | local LLM runtime                              |
| `ai-ollama-init`| `curlimages/curl`                         | one-shot `/api/pull` for default model         |
| `ai-airflow`   | built (`config/airflow/Dockerfile`)        | scheduler + webserver (`standalone`)           |
| `ai-api`       | built (`apps/api/Dockerfile`)              | FastAPI BFF                                    |
| `ai-web`       | built (`apps/web/Dockerfile`)              | Vite-built SPA served by nginx                 |
| `ai-simulator` | built (`apps/simulator/Dockerfile`)        | traffic + incident patterns (profile: simulate)|

## Profiling-data flow

```mermaid
sequenceDiagram
    autonumber
    participant APPS as phase-1 apps
    participant PYR as Pyroscope
    participant AF as Airflow (profile_etl)
    participant PG as Postgres
    participant API as FastAPI
    participant WEB as React SPA

    APPS->>PYR: push JFR every 15s
    loop every 5 min
      AF->>PYR: SelectMergeStacktraces / SelectSeries
      AF->>PG: INSERT function_features, integration_series, fingerprints
    end
    WEB->>API: GET /hotspots/leaderboard
    API->>PG: SELECT ... ORDER BY total DESC
    API-->>WEB: top-N rows
    WEB->>API: POST /chat (question)
    API->>PG: context snapshot (hotspots + anomalies)
    API->>OL: prompt with context
    API-->>WEB: SSE stream tokens
```

## Layered architecture rationale

```mermaid
flowchart TB
    subgraph frontend["Frontend (stateless)"]
      SPA[React SPA<br/>d3-flame-graph, SSE chat, TanStack Query]
    end
    subgraph bff["BFF (thin)"]
      ROUT[FastAPI routers]
    end
    subgraph lib["Shared lib (pure Python)"]
      PYRC[pyroscope_client]
      FX[feature_extraction]
      FS[feature_store]
      LG[llm_gateway]
      AN[anomaly]
      EM[embeddings]
    end
    subgraph backends["Backends"]
      PYR_[(Pyroscope)]
      PG_[(Postgres)]
      LLMS[(LLM providers)]
    end
    SPA --> ROUT
    ROUT --> PYRC & FX & FS & LG & AN & EM
    PYRC --> PYR_
    FS --> PG_
    EM --> PG_
    LG --> LLMS
    AFLOW[Airflow DAGs] --> PYRC & FX & FS & LG & AN & EM
```

**One lib, two consumers.** The Airflow DAGs and the FastAPI endpoints both
import from `lib/`. No duplicated "DAG logic" vs "API logic".

## Isolation from phase 1

- Separate compose project (`name: pyroscope-local-demo-ai`).
- Separate network, volumes namespaced.
- Host-bridge access to phase-1 Pyroscope via `host.docker.internal:4041`.
- Phase-1 Grafana talks to phase-2 Postgres and API via `host.docker.internal`.

## Ports (defaults; autowired)

See [../../README.md](../../README.md) Quickstart.

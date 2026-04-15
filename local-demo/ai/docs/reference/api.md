# Reference — API endpoints

FastAPI served at `:$API_PORT`. OpenAPI UI at `/docs`.

## Meta

| method | path        | returns                                    |
|--------|-------------|--------------------------------------------|
| GET    | `/health`   | `{"ok": true}`                             |
| GET    | `/config`   | `llm_provider`, `pyroscope_url`, etc.      |

## Profiles

| method | path                     | query params                                | returns                                     |
|--------|--------------------------|----------------------------------------------|---------------------------------------------|
| GET    | `/profiles/services`     | —                                            | list of Pyroscope `service_name` labels     |
| GET    | `/profiles/profile-types`| —                                            | all profile type IDs                        |
| GET    | `/profiles/flamegraph`   | `service`, `profile_type`, `seconds`, `thread?`, `integration?` | flamebearer JSON   |
| GET    | `/profiles/diff`         | `service`, `profile_type`, `before_seconds`, `after_seconds` | `{before, after, delta[]}` |

## Hotspots

| method | path                    | query params                                | returns                                |
|--------|-------------------------|----------------------------------------------|----------------------------------------|
| GET    | `/hotspots/leaderboard` | `metric` in `{cpu, alloc, lock, block}`, `hours`, `service?`, `limit` | rows        |

## Incidents

| method | path                    | params                  | returns                                     |
|--------|-------------------------|-------------------------|---------------------------------------------|
| GET    | `/incidents`            | `limit`                 | list                                        |
| GET    | `/incidents/{id}`       | path                    | detail + related anomalies                  |

## Similarity

| method | path            | body                                | returns                                  |
|--------|-----------------|-------------------------------------|------------------------------------------|
| POST   | `/similarity`   | `{incident_id, k}`                  | `{results[]}` (cosine-similar past incidents) |

## Regressions

| method | path             | query params         | returns                                  |
|--------|------------------|----------------------|------------------------------------------|
| GET    | `/regressions`   | `limit`, `service?`  | rows with `llm_summary`                  |

## Chat (SSE)

| method | path    | body                     | returns                            |
|--------|---------|--------------------------|------------------------------------|
| POST   | `/chat` | `{question, service?}`   | SSE stream: `event: token` / `event: done` / `event: error` |

Server enriches the prompt with a snapshot of the most recent hotspots +
anomalies so the LLM has context. See
[../explanation/llm-provider-neutrality.md](../explanation/llm-provider-neutrality.md).

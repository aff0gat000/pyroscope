# How-to — trigger an incident

Four canned incident types map to four Vert.x pathologies.

| kind         | what it does                                             | expected signal                                       |
|--------------|----------------------------------------------------------|-------------------------------------------------------|
| `blocker`    | hammers `/blocking/on-eventloop?ms=400` for 2 min        | event-loop threads blocked; p99 latency spike         |
| `leak`       | `/leak/start?n=25` × 8                                   | thread count climbs                                   |
| `gc`         | large MongoDB writes + frequent Postgres queries         | alloc profile grows; GC pressure                      |
| `contention` | 30 concurrent Postgres queries against `MaxSize=4` pool  | lock profile grows; request queuing                   |

## Trigger one

```bash
./scripts/simulate-incident.sh blocker
# or: leak | gc | contention
```

Records an `incidents` row immediately (kind, start_ts, notes). When the
simulator finishes, it updates `end_ts` and writes a placeholder vector
fingerprint so similarity search has something to retrieve.

## Follow the data

1. `./scripts/seed.sh` — or wait up to 5 min for the scheduled `profile_etl`.
2. Trigger `regression_detect`:
   ```bash
   docker compose exec -T airflow airflow dags trigger regression_detect
   ```
3. Open the Web UI → **Regression** → LLM summary appears.
4. Open **Incidents** → click your incident → similar past incidents on the right.

## Continuous patterns

```bash
docker compose --profile simulate up -d simulator
```

The `loop` mode runs baseline traffic and injects a random incident every
10 min. Leave it running overnight to get a realistic incident history.

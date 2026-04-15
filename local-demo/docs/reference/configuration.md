# Reference — configuration

## Files

```
local-demo/
├── .env                                         # auto-written by up.sh
├── .env.example                                 # defaults
├── docker-compose.yaml                          # stack definition
├── config/
│   ├── pyroscope/
│   │   ├── pyroscope.yaml                       # server: storage, retention
│   │   └── pyroscope.properties                 # agent: events, intervals, labels
│   ├── prometheus/prometheus.yaml               # scrape targets
│   ├── grafana/
│   │   ├── provisioning/datasources/*.yaml      # Pyroscope + Prometheus DS
│   │   ├── provisioning/dashboards/*.yaml       # dashboard provider
│   │   └── dashboards/*.json                    # dashboard definitions
│   └── k6/load.js                               # load script
```

## Pyroscope agent (`pyroscope.properties`)

| key                          | demo value                                           | meaning                                    |
|------------------------------|------------------------------------------------------|--------------------------------------------|
| `pyroscope.server.address`   | `http://pyroscope:4040`                              | push destination                           |
| `pyroscope.format`           | `jfr`                                                | JFR wire format (not pprof)                |
| `pyroscope.profiler.event`   | `itimer`                                             | CPU sampling via itimer (no perf_events)   |
| `pyroscope.profiler.interval`| `10ms`                                               | CPU sample interval                        |
| `pyroscope.profiler.wall`    | `20ms`                                               | wall-clock sample interval                 |
| `pyroscope.profiler.alloc`   | `256k`                                               | allocation profiling threshold             |
| `pyroscope.profiler.lock`    | `10ms`                                               | lock contention threshold                  |
| `pyroscope.upload.interval`  | `15s`                                                | batch push interval                        |
| `pyroscope.profiler.include` | `vert.x-eventloop-*\|vert.x-worker-*\|vert.x-internal-blocking-*\|demo-*` | thread name allow-list |
| `pyroscope.labels`           | `env=local-demo`                                     | static labels                              |
| `pyroscope.log.level`        | `warn`                                               | keep logs quiet                            |

## Per-app env (`docker-compose.yaml`)

| variable                       | purpose                                               |
|--------------------------------|-------------------------------------------------------|
| `PYROSCOPE_APPLICATION_NAME`   | Pyroscope `service_name` label (jvm11 vs jvm21)       |
| `PYROSCOPE_LABELS`             | additional static labels                              |
| `PYROSCOPE_CONFIGURATION_FILE` | path to `pyroscope.properties` inside the container   |
| `JAVA_TOOL_OPTIONS`            | `-javaagent:/opt/pyroscope/pyroscope.jar`             |
| `REDIS_URL`, `PG_*`, `MONGO_URL`, `CB_*`, `KAFKA_BROKERS`, `VAULT_*` | backend connection details |

## Pyroscope server (`pyroscope.yaml`)

| key                                     | demo value      | notes                           |
|-----------------------------------------|-----------------|---------------------------------|
| `storage.backend`                       | `filesystem`    | local disk, no S3               |
| `compactor.blocks_retention_period`     | `7d`            | demo only                       |
| `self_profiling.disable_push`           | `true`          | skip profiling the profiler     |

## Prometheus (`prometheus.yaml`)

Scrapes `demo-jvm11:8080/metrics` and `demo-jvm21:8080/metrics` every 10 s.
Exposes `jvm_*`, `process_*`, and `http_server_*` metrics via Micrometer.

## Grafana

- Datasources (provisioned): Pyroscope (`uid: pyroscope-ds`, default),
  Prometheus (`uid: prometheus-ds`).
- Dashboards auto-provisioned from
  `/var/lib/grafana/dashboards/*.json` into folder **"Local Demo"**.
- Anonymous access enabled (`GF_AUTH_ANONYMOUS_ENABLED=true`) so anyone
  with the URL can view dashboards. Edit requires admin login
  (`admin`/`admin`).

## Couchbase bootstrap

`couchbase-init` runs once:
1. Waits for UI to respond.
2. Sets memory quota (`512 MB`) + services (`kv`).
3. Creates admin `Administrator`/`password`.
4. Creates bucket `demo` (128 MB).

Idempotent — rerun safely.

## Vault bootstrap

`vault-init` runs once:
1. Waits for vault status.
2. `vault kv put secret/demo value=hello-from-vault`.

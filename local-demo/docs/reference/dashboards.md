# Reference — dashboards

All three are provisioned into the Grafana folder **"Local Demo"** and
live in `config/grafana/dashboards/`. Each is self-contained — no
dependencies on dashboards outside this demo directory.

## Demo Overview (`demo-overview.json`)

Three flame graphs, one view.

| panel                | profile type                                 | purpose                          |
|----------------------|----------------------------------------------|----------------------------------|
| CPU                  | `process_cpu:cpu:nanoseconds:cpu:nanoseconds`| where cycles are burning         |
| Allocations          | `memory:alloc_in_new_tlab_bytes:bytes:space:bytes` | GC pressure source        |
| Lock Contention      | `mutex:lock_duration:nanoseconds:contentions:count` | thread coordination cost |

Template variables:
- `service` — `demo-jvm11` or `demo-jvm21`.

## Per-Verticle Profile (`per-verticle.json`)

Drill into one thread group at a time.

| panel         | profile type                                      |
|---------------|---------------------------------------------------|
| CPU           | `process_cpu:cpu:nanoseconds:cpu:nanoseconds`     |
| Wall Clock    | `wall:wall:nanoseconds:wall:nanoseconds`          |

Template variables:
- `service` — `demo-jvm11` or `demo-jvm21`.
- `thread` — regex on `thread_name`; choose
  - `vert.x-eventloop-.*`
  - `vert.x-worker-.*`
  - `vert.x-internal-blocking-.*`

**Use when:** you suspect blocking on the event loop, or want to see what
the worker pool is doing versus sitting idle.

## Integration Hotspots (`integration-hotspots.json`)

Eight flame graphs filtered by the `integration` label, so each panel is
scoped to one integration client's calls.

| panel       | label filter           |
|-------------|------------------------|
| Redis       | `integration="redis"`    |
| Postgres    | `integration="postgres"` |
| Mongo       | `integration="mongo"`    |
| Couchbase   | `integration="couchbase"`|
| Kafka       | `integration="kafka"`    |
| HTTP Client | `integration="http"`     |
| Vault       | `integration="vault"`    |
| EventBus    | `integration="eventbus"` |

The label is applied by `com.demo.Label.tag(...)` around each integration
call — see [configuration.md](configuration.md) and
[explanation/code-walkthrough.md](../explanation/code-walkthrough.md).

## Adding a dashboard

Drop a JSON file in `config/grafana/dashboards/`. Grafana re-scans every
10 s (`updateIntervalSeconds: 10`). No container restart needed.

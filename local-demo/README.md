# Pyroscope local demo

Self-contained stack: **Pyroscope + Grafana + Prometheus** profiling two
Vert.x apps — **Java 11** and **Java 21 (with virtual threads)** — against
Redis, Postgres, Mongo, Couchbase, Kafka, Vault, and each other.

Purpose: rehearse continuous-profiling debugging on canned antipatterns
before you see them in production.

## Quickstart

```bash
cd local-demo
./scripts/up.sh              # builds, auto-wires ports, launches
./scripts/load.sh            # continuous traffic in another terminal
```

Then open the Grafana URL printed by `up.sh` (default `http://localhost:3001`,
admin/admin) → **Dashboards → Local Demo**.

## Layout

```
local-demo/
├── docker-compose.yaml
├── .env.example
├── apps/
│   ├── demo-jvm11/         # Java 11, Vert.x 4.5
│   └── demo-jvm21/         # Java 21, + VirtualThreadVerticle
├── config/
│   ├── pyroscope/          # server yaml + agent .properties
│   ├── prometheus/
│   ├── grafana/            # provisioning + 3 dashboards
│   └── k6/                 # load.js
├── scripts/
│   ├── up.sh               # launch (port autowiring)
│   ├── down.sh
│   └── load.sh             # curl-based load
└── docs/                   # Diataxis-structured documentation
```

## Documentation — [docs/README.md](docs/README.md)

Diataxis four-quadrant layout:

| quadrant                  | intent                                | entry point                                            |
|---------------------------|---------------------------------------|--------------------------------------------------------|
| Tutorials (learning)      | "teach me from zero"                  | [docs/tutorials/01-getting-started.md](docs/tutorials/01-getting-started.md) |
| How-to (task)             | "I need to do X"                      | [docs/how-to/runbook.md](docs/how-to/runbook.md)        |
| Reference (information)   | "look something up"                   | [docs/reference/architecture.md](docs/reference/architecture.md) |
| Explanation (understanding) | "why is it like this?"              | [docs/explanation/value-proposition.md](docs/explanation/value-proposition.md) |

Headline documents:

- [docs/how-to/runbook.md](docs/how-to/runbook.md) — operate the stack.
- [docs/how-to/debugging-incidents.md](docs/how-to/debugging-incidents.md) —
  apply the demo to simulated incidents.
- [docs/reference/architecture.md](docs/reference/architecture.md) —
  topology & infrastructure diagrams (mermaid).
- [docs/explanation/profiling-concepts.md](docs/explanation/profiling-concepts.md) —
  what CPU / wall / alloc / lock actually measure.
- [docs/explanation/value-proposition.md](docs/explanation/value-proposition.md) —
  why this demo exists.

## Port defaults

Defaults sit in a non-standard band (see
[docs/reference/ports.md](docs/reference/ports.md)); `up.sh` auto-bumps
any conflict and writes the effective map to `.env`.

## Teardown

```bash
./scripts/down.sh            # stops and removes volumes (demo project only)
```

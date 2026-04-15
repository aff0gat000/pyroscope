# Reference — infrastructure & architecture

## High-level topology

```mermaid
flowchart TB
    subgraph host["Host (your laptop)"]
      direction TB
      BROWSER[Browser / curl / k6]
      ENV[.env — effective port map]
    end

    subgraph net["Docker network: demo"]
      direction TB

      subgraph observability["Observability plane"]
        PYRO[Pyroscope<br/>profiling TSDB<br/>:4040]
        PROM[Prometheus<br/>metrics TSDB<br/>:9090]
        GRAF[Grafana<br/>dashboards<br/>:3000]
      end

      subgraph apps["Demo apps"]
        J11[demo-jvm11<br/>Vert.x 4.5 · JDK 11<br/>:8080]
        J21[demo-jvm21<br/>Vert.x 4.5 · JDK 21<br/>:8080]
      end

      subgraph infra["Backends"]
        REDIS[(Redis)]
        PG[(Postgres)]
        MG[(Mongo)]
        CB[(Couchbase<br/>+ init job)]
        KAFKA[Kafka + ZooKeeper]
        VAULT[Vault dev<br/>+ init job]
      end

      K6[k6 load<br/>profile: load]
    end

    BROWSER -->|HTTP| J11
    BROWSER -->|HTTP| J21
    BROWSER -->|:3001| GRAF
    BROWSER -->|:4041| PYRO
    BROWSER -->|:9091| PROM

    J11 -->|agent push| PYRO
    J21 -->|agent push| PYRO
    PROM -->|scrape /metrics| J11
    PROM -->|scrape /metrics| J21
    GRAF --> PYRO
    GRAF --> PROM

    J11 <--> REDIS & PG & MG & CB & KAFKA & VAULT
    J21 <--> REDIS & PG & MG & CB & KAFKA & VAULT
    J11 <-->|HTTP| J21

    K6 -.->|HTTP| J11
    K6 -.->|HTTP| J21
```

Legend: solid = request; dashed = load.

## Container inventory

| container               | image                             | role                                       |
|-------------------------|-----------------------------------|--------------------------------------------|
| `demo-pyroscope`        | grafana/pyroscope:1.8.0           | profile ingest + TSDB + query API          |
| `demo-prometheus`       | prom/prometheus:v2.53.0           | metrics scrape + query                     |
| `demo-grafana`          | grafana/grafana:11.5.2            | UI; datasources + dashboards provisioned   |
| `demo-redis`            | redis:7-alpine                    | KV store                                   |
| `demo-postgres`         | postgres:16-alpine                | relational DB (`demo`/`demo`/`demo`)       |
| `demo-mongo`            | mongo:7                           | document DB                                |
| `demo-couchbase`        | couchbase:community-7.2.0         | document DB                                |
| `demo-couchbase-init`   | curlimages/curl:8.5.0             | one-shot bucket setup                      |
| `demo-zookeeper`        | confluentinc/cp-zookeeper:7.6.1   | Kafka coordination                         |
| `demo-kafka`            | confluentinc/cp-kafka:7.6.1       | message bus                                |
| `demo-vault`            | hashicorp/vault:1.17              | secrets (dev mode, root token)             |
| `demo-vault-init`       | hashicorp/vault:1.17              | one-shot kv seeding                        |
| `demo-jvm11`            | built from `./apps/demo-jvm11`    | Java 11 Vert.x app                         |
| `demo-jvm21`            | built from `./apps/demo-jvm21`    | Java 21 Vert.x app                         |
| `demo-k6`               | grafana/k6:0.51.0                 | load generator (profile `load`)            |

## Data flow — profiling

```mermaid
sequenceDiagram
    autonumber
    participant App as demo-jvm{11,21}
    participant Agent as pyroscope.jar<br/>(in-JVM agent)
    participant Srv as Pyroscope server
    participant UI as Grafana
    Note over App,Agent: -javaagent attaches at JVM start<br/>config from pyroscope.properties
    loop every 10 ms (itimer) / 20 ms (wall)
      Agent->>Agent: sample stacks<br/>async-profiler native
    end
    loop every 15 s
      Agent->>Srv: push JFR batch +<br/>labels (service, thread, integration)
    end
    UI->>Srv: query profileTypeId + labelSelector
    Srv-->>UI: flame graph JSON
```

## Data flow — request

```mermaid
sequenceDiagram
    actor Client
    participant J11 as demo-jvm11
    participant EV as Event loop<br/>vert.x-eventloop-*
    participant W as Worker pool<br/>vert.x-worker-*
    participant RD as Redis
    Client->>J11: GET /redis/set?k=..&v=..
    J11->>EV: route dispatch
    EV->>EV: Label.tag("redis", …)
    EV->>RD: non-blocking send
    RD-->>EV: reply
    EV-->>Client: 200 {"ok":true}
    Note right of W: For /blocking/execute-blocking<br/>or /couchbase/* handlers only
```

## Request paths exercised

| integration | primary thread group                 | client type    | demo route                               |
|-------------|--------------------------------------|----------------|------------------------------------------|
| redis       | vert.x-eventloop-*                    | non-blocking   | `/redis/{set,get}`                       |
| postgres    | vert.x-eventloop-*                    | non-blocking   | `/postgres/query`                        |
| mongo       | vert.x-eventloop-*                    | non-blocking   | `/mongo/{insert,find}`                   |
| couchbase   | vert.x-worker-*                       | **blocking**   | `/couchbase/{upsert,get}`                |
| kafka       | vert.x-eventloop-*                    | non-blocking   | `/kafka/{produce,consume}`               |
| http        | vert.x-eventloop-*                    | non-blocking   | `/http/client`                           |
| vault       | vert.x-eventloop-*                    | non-blocking   | `/vault/read`                            |
| eventbus    | vert.x-eventloop-*                    | non-blocking   | `/f2f/call`                              |
| vt (jvm21)  | virtual                               | Loom           | `/vt/sleep`, `/vt/info`                  |

## Isolation from the main stack

- Compose project name `pyroscope-local-demo` (set via `name:` at the top
  of `docker-compose.yaml`). Volumes and network are namespaced under this
  project; `down.sh` only affects this project.
- Host ports default to a non-overlapping band (see [ports.md](ports.md))
  so the demo can run alongside the repo's main compose stack.

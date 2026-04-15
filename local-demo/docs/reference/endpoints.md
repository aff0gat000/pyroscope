# Reference — endpoints

Both apps expose the same routes on port `8080` (internal) / the mapped
host ports `$DEMO_JVM11_PORT` and `$DEMO_JVM21_PORT`. `demo-jvm21` adds a
virtual-thread-only route.

## Core

| route        | method | description                                |
|--------------|--------|--------------------------------------------|
| `/health`    | GET    | `{"ok":true}`                              |
| `/metrics`   | GET    | Prometheus scrape (Micrometer + JVM)       |
| `/functions` | GET    | list of all demo routes                    |
| `/registry`  | GET    | verticle + JVM version info                |

## Thread & blocking

| route                           | params                 | behaviour                                      |
|---------------------------------|------------------------|------------------------------------------------|
| `/leak/start`                   | `n` (default 10)       | spawns N `demo-leak-*` platform threads        |
| `/leak/stop`                    | —                      | interrupts and clears all leaked threads       |
| `/leak/status`                  | —                      | current leaked count                           |
| `/blocking/on-eventloop`        | `ms` (default 200)     | `Thread.sleep` on event loop (antipattern)     |
| `/blocking/execute-blocking`    | `ms` (default 200)     | `Thread.sleep` via `vertx.executeBlocking`     |

## HTTP

| route           | params                        | behaviour                                 |
|-----------------|-------------------------------|-------------------------------------------|
| `/http/echo`    | —                             | responds with verticle + thread info      |
| `/http/client`  | `host`, `port`                | WebClient GET to another app's `/http/echo` |

## Data stores

| route                                 | params                         | notes                                     |
|---------------------------------------|--------------------------------|-------------------------------------------|
| `/redis/set`                          | `k`, `v`                       | non-blocking client                       |
| `/redis/get`                          | `k`                            | —                                         |
| `/postgres/query`                     | —                              | runs `SELECT now(), version()`            |
| `/mongo/insert`                       | `msg`                          | inserts into `events` collection          |
| `/mongo/find`                         | —                              | returns document count                    |
| `/couchbase/upsert`                   | `id`, `v`                      | blocking SDK via `executeBlocking`         |
| `/couchbase/get`                      | `id`                           | blocking SDK via `executeBlocking`         |

## Messaging

| route                | params    | notes                                       |
|----------------------|-----------|---------------------------------------------|
| `/kafka/produce`     | `v`       | produces to topic `demo`                    |
| `/kafka/consume`     | —         | returns running consumed counter            |

## Vert.x framework

| route                          | params  | notes                                      |
|--------------------------------|---------|--------------------------------------------|
| `/f2f/call`                    | `p`     | EventBus request/reply to child verticle   |
| `/framework/future-chain`      | —       | `CompositeFuture.all` of composed futures  |
| `/framework/timer`             | —       | `vertx.setTimer(50, …)`                    |

## Secrets

| route           | params           | notes                      |
|-----------------|------------------|----------------------------|
| `/vault/read`   | `path` (default `secret/data/demo`) | reads KV via HTTP |

## Java 21 only

| route         | params                | notes                                    |
|---------------|-----------------------|------------------------------------------|
| `/vt/sleep`   | `ms` (default 200)    | blocks on a virtual thread; loom unmounts carrier |
| `/vt/info`    | —                     | `{"thread":"…","isVirtual":true}`        |

## Response conventions

- Success: `200` with JSON body.
- Backend unreachable / mis-configured: `502` with text error.
- Couchbase not ready: `503` until init completes.

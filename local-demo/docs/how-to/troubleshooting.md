# Troubleshooting

Symptom → probable cause → fix.

## Build / launch

**`./scripts/up.sh` fails at "docker compose up"**
Cause: Docker daemon not running, or out of disk.
Fix: `docker info`, `df -h`, prune with `docker system prune -f`.

**Build takes forever on first run**
Normal. Gradle downloads Vert.x + Couchbase SDK + Kafka clients (~300 MB).
Subsequent builds use the Docker layer cache.

**"port is already allocated" after up.sh**
Another container (maybe the main `docker-compose.yaml` stack) is holding
the port. `up.sh` probes *host* free ports only — it can't see another
Docker project holding a port via iptables. Stop the other stack or edit
`.env` manually.

## Apps won't start

**`/health` returns connection refused**
```bash
docker compose logs demo-jvm11
```
Look for `http :8080 ready`. If absent:
- `ClassNotFoundException` → dependency missing; rebuild with `--no-cache`.
- Vert.x deployment failure → feature verticle threw in `start()`.

**Couchbase verticle reports 503**
Couchbase init takes 30–60 s. Wait, then `docker compose logs couchbase-init`.
If the init job failed, rerun:
```bash
docker compose up -d couchbase-init
```

**Kafka producer times out**
Kafka listener misconfigured or Kafka not ready. Check:
```bash
docker compose logs kafka | grep -i "started"
```
Clients inside the network must connect to `kafka:9092`, not `localhost`.

## No flame graphs in Grafana

**Empty flame graph panels**
In order of likelihood:
1. No load — run `./scripts/load.sh`.
2. <15 s since load started — agent upload interval. Wait.
3. Agent not attached — `docker compose logs demo-jvm11 | grep -i pyroscope`.
   Expect `INFO: Profiling started`.
4. Pyroscope server not reachable — `docker compose logs pyroscope`.
5. Wrong `service_name` filter — check `PYROSCOPE_APPLICATION_NAME` env
   matches the dashboard variable.

**Dashboards missing**
`docker compose logs grafana | grep dashboard`. Provisioning errors print
here. Common cause: invalid JSON in a dashboard file.

**"integration" label panels empty**
Requires the app to wrap calls in `Label.tag`. If a custom verticle skipped
this, panels show nothing for that integration.

## Load generation

**`load.sh` prints many `miss:` lines**
Integrations not warm yet (Couchbase, Kafka broker election). Usually
resolves within 30–60 s of startup.

**k6 container exits immediately**
Compose profile not set: `docker compose --profile load up k6`.

## Cleanup

**`down.sh` leaves dangling images**
Expected. `docker image prune -f` removes them. Volumes are removed by
`down.sh` because of `-v`.

**"no space left on device"**
```bash
docker system df
docker system prune -af --volumes
```

## Environment variables not applied

Compose re-reads `.env` on `up`. After editing, run `docker compose up -d`
to recreate affected containers.

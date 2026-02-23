# Configuration Reference

All configuration keys for the Pyroscope continuous profiling stack in one place.
Covers the Java agent, Pyroscope server, deploy script, Ansible role, and Helm chart.

---

## Java Agent Properties

The Pyroscope Java agent (v0.14.0) accepts configuration through three mechanisms.

**Precedence:** System Properties (`-D`) > Environment Variables > Properties File.
See [deployment-guide.md](deployment-guide.md) for agent setup instructions.

| System Property | Environment Variable | Default | Description |
|-----------------|---------------------|---------|-------------|
| `pyroscope.server.address` | `PYROSCOPE_SERVER_ADDRESS` | `http://localhost:4040` | Pyroscope server URL |
| `pyroscope.application.name` | `PYROSCOPE_APPLICATION_NAME` | `""` | Application name shown in Pyroscope UI |
| `pyroscope.labels` | `PYROSCOPE_LABELS` | `""` | Comma-separated `key=value` static labels |
| `pyroscope.format` | `PYROSCOPE_FORMAT` | `jfr` | Profile format |
| `pyroscope.profiler.event` | `PYROSCOPE_PROFILER_EVENT` | `itimer` | CPU event type (`itimer`, `cpu`, `wall`) |
| `pyroscope.profiler.alloc` | `PYROSCOPE_PROFILER_ALLOC` | `512k` | Allocation profiling threshold |
| `pyroscope.profiler.lock` | `PYROSCOPE_PROFILER_LOCK` | `10ms` | Lock contention threshold |
| `pyroscope.log.level` | `PYROSCOPE_LOG_LEVEL` | `info` | Agent log level (`debug`, `info`, `warn`, `error`) |
| `pyroscope.configuration.file` | `PYROSCOPE_CONFIGURATION_FILE` | `""` | Path to `.properties` config file |
| `pyroscope.upload.interval` | `PYROSCOPE_UPLOAD_INTERVAL` | `10s` | Profile upload interval |
| `pyroscope.profiling.interval` | `PYROSCOPE_PROFILING_INTERVAL` | `10ms` | Sampling interval |
| `pyroscope.tenant.id` | `PYROSCOPE_TENANT_ID` | `""` | Multi-tenant isolation header (`X-Scope-OrgID`) |
| `pyroscope.http.headers` | `PYROSCOPE_HTTP_HEADERS` | `""` | Custom HTTP headers (`key1=value1,key2=value2`) |
| `pyroscope.basic.auth.user` | `PYROSCOPE_BASIC_AUTH_USER` | `""` | Basic auth username |
| `pyroscope.basic.auth.password` | `PYROSCOPE_BASIC_AUTH_PASSWORD` | `""` | Basic auth password |
| `pyroscope.gc.before.dump` | `PYROSCOPE_GC_BEFORE_DUMP` | `false` | Force GC before heap dump |
| `pyroscope.alloc.live` | `PYROSCOPE_ALLOC_LIVE` | `false` | Track only live objects |
| `pyroscope.java.stack.depth` | `PYROSCOPE_JAVA_STACK_DEPTH` | `2048` | Maximum stack depth |

### Example: properties file

```properties
# pyroscope.properties
pyroscope.server.address=http://pyroscope-vm:4040
pyroscope.application.name=vertx-faas-server
pyroscope.format=jfr
pyroscope.labels=env=production,namespace=my-ns
pyroscope.upload.interval=10s
pyroscope.profiling.interval=10ms
pyroscope.log.level=info
```

### Example: system properties

```bash
java -javaagent:/opt/pyroscope.jar \
     -Dpyroscope.server.address=http://pyroscope-vm:4040 \
     -Dpyroscope.application.name=my-service \
     -Dpyroscope.profiler.event=itimer \
     -jar myapp.jar
```

---

## Pyroscope Server Configuration

The Pyroscope server reads its configuration from `pyroscope.yaml` (or CLI flags).
See [architecture.md](architecture.md) for storage architecture details.

| Key | Default | Description |
|-----|---------|-------------|
| `storage.backend` | `filesystem` | Storage backend (`filesystem`, `s3`, `gcs`) |
| `storage.filesystem.dir` | `/data` | Local storage directory |
| `server.http_listen_port` | `4040` | HTTP API port |
| `self_profiling.disable_push` | `true` | Disable self-profiling push |
| `compactor.blocks_retention_period` | `""` (unlimited) | Data retention period (e.g. `24h`, `30d`) |
| `limits.max_query_length` | `721h` | Maximum query time range |
| `limits.max_query_lookback` | `721h` | Maximum lookback window |

### Minimal pyroscope.yaml

```yaml
# Minimal — accepts defaults for everything except storage path
storage:
  backend: filesystem
  filesystem:
    dir: /data
```

### Annotated pyroscope.yaml with retention

```yaml
storage:
  backend: filesystem
  filesystem:
    dir: /data

server:
  http_listen_port: 4040

self_profiling:
  disable_push: true

# Delete profile blocks older than 30 days
compactor:
  blocks_retention_period: 30d

limits:
  max_query_length: 721h
  max_query_lookback: 721h
```

---

## deploy.sh Flags

The `deploy.sh` script accepts 30+ flags organized into 5 groups: General (9),
Pyroscope (4), Grafana (6), TLS (7), and K8s/OCP (5). See
[deploy/monolith/README.md](../deploy/monolith/README.md) for the complete flag
reference.

---

## Ansible Role Variables

Key variables from the `pyroscope-stack` role defaults. Override in inventory
`group_vars`, `host_vars`, or playbook `vars`.

| Variable | Default | Description |
|----------|---------|-------------|
| `pyroscope_mode` | `full-stack` | Deployment mode (`full-stack`, `add-to-existing`) |
| `pyroscope_image` | `grafana/pyroscope:latest` | Pyroscope container image |
| `pyroscope_port` | `4040` | Pyroscope HTTP port |
| `pyroscope_volume` | `pyroscope-data` | Docker volume name for Pyroscope data |
| `grafana_image` | `grafana/grafana:11.5.2` | Grafana container image |
| `grafana_port` | `3000` | Grafana HTTP port |
| `grafana_admin_password` | `admin` | Grafana admin password |
| `grafana_config_mode` | `mounted` | Config mode (`mounted`, `baked`) |
| `skip_grafana` | `false` | Deploy Pyroscope without Grafana |
| `tls_enabled` | `false` | Enable TLS via Envoy reverse proxy |
| `tls_self_signed` | `false` | Generate self-signed certificate on target |
| `tls_port_pyroscope` | `4443` | HTTPS port for Pyroscope (Envoy) |
| `health_check_timeout` | `60` | Seconds to wait for container health checks |

See [deploy/monolith/ansible/README.md](../deploy/monolith/ansible/README.md)
for the full variable reference.

---

## Helm Chart Values

Key values from `deploy/helm/pyroscope/values.yaml`.

| Key | Default | Description |
|-----|---------|-------------|
| `mode` | `monolith` | Deployment mode (`monolith`, `microservices`) |
| `image.repository` | `grafana/pyroscope` | Container image repository |
| `image.tag` | `"1.18.0"` | Container image tag |
| `storage.accessMode` | `ReadWriteOnce` | PVC access mode (`ReadWriteMany` for microservices) |
| `storage.size` | `10Gi` | PVC storage size |
| `route.enabled` | `true` | Create OpenShift Route |
| `networkPolicy.enabled` | `false` | Create NetworkPolicy for cross-namespace access |
| `grafana.location` | `external` | Grafana location (`same-namespace`, `different-namespace`, `external`) |

See [deploy/helm/pyroscope/values.yaml](../deploy/helm/pyroscope/values.yaml)
for all values.

---

## Environment Variable Index

Alphabetical cross-reference of all environment variables in this document.

| Env Var | Component | Default | Description |
|---------|-----------|---------|-------------|
| `PYROSCOPE_ALLOC_LIVE` | Java Agent | `false` | Track only live objects |
| `PYROSCOPE_APPLICATION_NAME` | Java Agent | `""` | Application name in Pyroscope UI |
| `PYROSCOPE_BASIC_AUTH_PASSWORD` | Java Agent | `""` | Basic auth password |
| `PYROSCOPE_BASIC_AUTH_USER` | Java Agent | `""` | Basic auth username |
| `PYROSCOPE_CONFIGURATION_FILE` | Java Agent | `""` | Path to properties config file |
| `PYROSCOPE_FORMAT` | Java Agent | `jfr` | Profile format |
| `PYROSCOPE_GC_BEFORE_DUMP` | Java Agent | `false` | Force GC before heap dump |
| `PYROSCOPE_HTTP_HEADERS` | Java Agent | `""` | Custom HTTP headers |
| `PYROSCOPE_JAVA_STACK_DEPTH` | Java Agent | `2048` | Maximum stack depth |
| `PYROSCOPE_LABELS` | Java Agent | `""` | Comma-separated key=value labels |
| `PYROSCOPE_LOG_LEVEL` | Java Agent | `info` | Agent log level |
| `PYROSCOPE_PROFILER_ALLOC` | Java Agent | `512k` | Allocation profiling threshold |
| `PYROSCOPE_PROFILER_EVENT` | Java Agent | `itimer` | CPU event type |
| `PYROSCOPE_PROFILER_LOCK` | Java Agent | `10ms` | Lock contention threshold |
| `PYROSCOPE_PROFILING_INTERVAL` | Java Agent | `10ms` | Sampling interval |
| `PYROSCOPE_SERVER_ADDRESS` | Java Agent | `http://localhost:4040` | Pyroscope server URL |
| `PYROSCOPE_TENANT_ID` | Java Agent | `""` | Multi-tenant isolation header |
| `PYROSCOPE_UPLOAD_INTERVAL` | Java Agent | `10s` | Profile upload interval |

# Pyroscope + Grafana Observability Deployment

Unified script for deploying Pyroscope continuous profiling with Grafana visualization. Supports multiple modes, TLS/HTTPS, and air-gapped deployments.

For detailed decision flowcharts and step-by-step recipes, see the [Deployment Decision Guide](../../docs/observability-deployment-guide.md).

## Modes

| Mode | Description |
|------|-------------|
| `full-stack` | Deploy Pyroscope + Grafana together (default) |
| `add-to-existing` | Add Pyroscope datasource and dashboards to an existing Grafana instance |
| `save-images` | Save Docker images to tar for air-gapped transfer |
| `status` / `stop` / `clean` / `logs` | Day-2 operations |

## Deployment Targets

| Target | Flag | Use Case |
|--------|------|----------|
| VM / EC2 / bare metal | `--target vm` | Production. Uses `docker run` directly. **Default.** |
| Local machine | `--target local` | Development. Uses Docker Compose. |
| Kubernetes | `--target k8s` | Cloud container environments. Uses kubectl. |
| OpenShift | `--target openshift` | Enterprise container platform. Uses oc CLI + routes. |

## Deployment Stages

The recommended progression from first deployment to production:

| Stage | Protocol | Registry | TLS | Use Case |
|-------|----------|----------|-----|----------|
| **Standalone HTTP** | HTTP | `docker save/load` | None | First deployment — prove the stack works |
| **Standalone HTTPS** | HTTPS | `docker save/load` | Self-signed (auto) | Second deployment — prove HTTPS works |
| **Enterprise-Integrated** | HTTPS | Internal registry | Enterprise CA | Production — full integration |

## Quick Start

### Standalone HTTP (first deployment)

No registry, no TLS — simplest possible deployment.

```bash
# 1. On a machine with internet access: save images to tar
bash deploy/observability/deploy.sh save-images
# Output: pyroscope-stack-images.tar

# 2. Transfer to VM
scp pyroscope-stack-images.tar operator@vm01.corp.example.com:/tmp/

# 3. SSH to VM, elevate to root
ssh operator@vm01.corp.example.com
pbrun /bin/su -

# 4. Dry run first to validate (no changes made)
bash deploy/observability/deploy.sh full-stack --target vm \
    --load-images /tmp/pyroscope-stack-images.tar --dry-run

# 5. Deploy (log to file — recommended for pbrun sessions)
bash deploy/observability/deploy.sh full-stack --target vm \
    --load-images /tmp/pyroscope-stack-images.tar --log-file /tmp/deploy.log
```

This deploys:
- Pyroscope on port 4040 (with persistent named volume)
- Grafana on port 3000 (with Pyroscope datasource + 6 dashboards pre-loaded)
- Config files at `/opt/pyroscope/grafana/` (volume-mounted into Grafana container)

### Standalone HTTPS (self-signed TLS)

Same air-gapped workflow, plus automated TLS with Envoy reverse proxy.

```bash
# Save images (includes Envoy when --tls is used at deploy time)
bash deploy/observability/deploy.sh save-images

# On the VM: deploy with self-signed cert
bash deploy/observability/deploy.sh full-stack --target vm \
    --load-images /tmp/pyroscope-stack-images.tar \
    --tls --tls-self-signed
```

This deploys:
- Pyroscope on `127.0.0.1:4040` (localhost only — not network-reachable)
- Grafana on `127.0.0.1:3000` (localhost only)
- Envoy TLS proxy on ports 4443 (Pyroscope) and 443 (Grafana)
- Self-signed certificate auto-generated at `/opt/pyroscope/tls/`

### Enterprise-Integrated HTTPS (CA certificates)

When enterprise CA certificates are available:

```bash
bash deploy/observability/deploy.sh full-stack --target vm \
    --tls --tls-cert /path/to/cert.pem --tls-key /path/to/key.pem
```

### Full stack locally (development)

```bash
bash deploy/observability/deploy.sh full-stack --target local
```

### Add Pyroscope to existing Grafana (API method)

No Grafana restart needed. Requires an API key or admin credentials.

```bash
bash deploy/observability/deploy.sh add-to-existing \
    --grafana-url http://grafana.corp:3000 \
    --grafana-api-key eyJrIj... \
    --pyroscope-url http://pyroscope.corp:4040
```

This will:
1. Install the Pyroscope plugins
2. Add Pyroscope as a datasource
3. Import 6 profiling dashboards into a "Pyroscope" folder

### Add Pyroscope to existing Grafana (provisioning files)

Requires Grafana restart but no API key.

```bash
bash deploy/observability/deploy.sh add-to-existing \
    --method provisioning \
    --pyroscope-url http://pyroscope.corp:4040 \
    --grafana-provisioning-dir /etc/grafana/provisioning \
    --grafana-dashboard-dir /var/lib/grafana/dashboards

# Then restart Grafana
systemctl restart grafana-server
```

### Full stack on Kubernetes

```bash
# Persistent storage (default — PVCs for Pyroscope and Grafana data)
bash deploy/observability/deploy.sh full-stack \
    --target k8s \
    --namespace monitoring

# With specific storage class (enterprise clusters)
bash deploy/observability/deploy.sh full-stack \
    --target k8s \
    --namespace monitoring \
    --storage-class managed-premium \
    --pvc-size-pyroscope 50Gi

# Ephemeral (no PVC — for dev/testing)
bash deploy/observability/deploy.sh full-stack \
    --target k8s \
    --namespace monitoring \
    --no-pvc
```

### Full stack on OpenShift

```bash
bash deploy/observability/deploy.sh full-stack \
    --target openshift \
    --namespace monitoring
```

OpenShift routes are created automatically for both Pyroscope and Grafana.

## Image Transfer (Air-Gapped / No Registry)

For VMs that cannot reach Docker Hub or an internal registry, use `save-images` to create a portable tar file.

### Save images (on a machine with internet)

```bash
bash deploy/observability/deploy.sh save-images
# Creates: pyroscope-stack-images.tar
# Includes: pyroscope, grafana, envoy (for TLS)
```

### Transfer and load on VM

```bash
# Transfer
scp pyroscope-stack-images.tar operator@vm01:/tmp/

# On VM: deploy with --load-images
bash deploy/observability/deploy.sh full-stack --target vm \
    --load-images /tmp/pyroscope-stack-images.tar
```

The `--load-images` flag runs `docker load` from the tar file before deploying. This is idempotent — images already present are skipped.

## TLS / HTTPS Mode

TLS is opt-in. When enabled, an Envoy reverse proxy terminates TLS in front of Pyroscope and Grafana. Backend containers bind to `127.0.0.1` and are not directly network-reachable.

### Architecture (TLS enabled)

```
┌──────────────────────────────────────────────────────┐
│  VM (RHEL 8.10)                                      │
│                                                      │
│  Java Agent ──HTTPS:4443──► ┌─────────┐ ┌──────────┐│
│                             │  Envoy  │→│Pyroscope ││
│  Browser ────HTTPS:443────► │ (proxy) │→│ Grafana  ││
│                             └─────────┘ └──────────┘│
│                                 ▲                    │
│                      /opt/pyroscope/tls/             │
│                      (cert.pem + key.pem)            │
└──────────────────────────────────────────────────────┘
```

### Self-signed certificate (dev/demo)

Fully automated — generates cert + key with hostname SAN. No CA knowledge needed.

```bash
bash deploy/observability/deploy.sh full-stack --target vm \
    --tls --tls-self-signed
```

The self-signed cert is regenerated only if missing or expiring within 7 days.

### Enterprise CA certificate (production)

Provide cert and key as file paths. Never pass certificate content as CLI arguments.

```bash
bash deploy/observability/deploy.sh full-stack --target vm \
    --tls --tls-cert /path/to/cert.pem --tls-key /path/to/key.pem
```

### TLS validation rules

- `--tls` alone fails — must specify `--tls-self-signed` OR `--tls-cert`/`--tls-key`
- `--tls-cert` requires `--tls-key` (and vice versa)
- `--tls-self-signed` checks that `openssl` is on PATH
- `--tls-client-ca` is accepted but warns "not yet implemented" (reserved for mTLS)

### Port reference

| Service | HTTP (default) | HTTPS (TLS) |
|---------|---------------|-------------|
| Pyroscope | `:4040` | `:4443` via Envoy |
| Grafana | `:3000` | `:443` via Envoy |
| Envoy admin | - | `127.0.0.1:9901` |

## Skip Grafana (Pyroscope-Only Deployment)

When deploying to a dedicated Pyroscope VM — or when Grafana already exists elsewhere — use `--skip-grafana` to deploy only the Pyroscope container.

```bash
# Pyroscope-only VM (HTTP)
bash deploy/observability/deploy.sh full-stack --target vm --skip-grafana

# Pyroscope-only VM (HTTPS)
bash deploy/observability/deploy.sh full-stack --target vm \
    --skip-grafana --tls --tls-self-signed
```

The existing Grafana instance connects to this Pyroscope via datasource URL (`http://pyro-vm:4040` or `https://pyro-vm:4443`).

## Day-2 Operations

```bash
# Check status (includes Envoy if TLS deployed)
bash deploy/observability/deploy.sh status --target vm

# View logs
bash deploy/observability/deploy.sh logs --target vm

# Stop (data preserved)
bash deploy/observability/deploy.sh stop --target vm

# Full cleanup (removes containers, volumes, images, certs)
bash deploy/observability/deploy.sh clean --target vm
```

## Configuration

Override via flags or environment variables:

### General

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--target <env>` | - | `vm` | Deployment target: `vm`, `local`, `k8s`, `openshift` |
| `--dry-run` | - | - | Validate without making changes |
| `--log-file <path>` | - | - | Append all output to a log file |
| `--skip-grafana` | - | - | Deploy Pyroscope only (no Grafana container) |
| `--load-images <path>` | - | - | Load Docker images from tar before deploying |
| `--bake-config` | - | - | Bake config into custom Docker image instead of volume mounts |
| `--grafana-config-dir` | `GRAFANA_CONFIG_DIR` | `/opt/pyroscope/grafana` | Host directory for mounted Grafana config |

### Pyroscope

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--pyroscope-port` | `PYROSCOPE_PORT` | `4040` | Pyroscope host port |
| `--pyroscope-url` | `PYROSCOPE_URL` | auto-detected | Pyroscope server URL |
| `--pyroscope-image` | `PYROSCOPE_IMAGE` | `grafana/pyroscope:latest` | Pyroscope Docker image |

### Grafana

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--grafana-port` | `GRAFANA_PORT` | `3000` | Grafana host port |
| `--grafana-url` | `GRAFANA_URL` | - | Existing Grafana URL (for `add-to-existing`) |
| `--grafana-api-key` | `GRAFANA_API_KEY` | - | API key for Grafana |
| `--grafana-admin-password` | `GRAFANA_ADMIN_PASSWORD` | `admin` | Grafana admin password |
| `--grafana-image` | `GRAFANA_IMAGE` | `grafana/grafana:11.5.2` | Grafana Docker image |

### TLS / HTTPS

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--tls` | - | - | Enable TLS mode (requires cert source) |
| `--tls-self-signed` | - | - | Auto-generate self-signed cert (dev/demo) |
| `--tls-cert <path>` | - | - | TLS certificate file path (PEM) |
| `--tls-key <path>` | - | - | TLS private key file path (PEM) |
| `--tls-cert-dir` | `TLS_CERT_DIR` | `/opt/pyroscope/tls` | Cert directory on host |
| `--tls-port-pyroscope` | `TLS_PORT_PYROSCOPE` | `4443` | HTTPS port for Pyroscope |
| `--tls-port-grafana` | `TLS_PORT_GRAFANA` | `443` | HTTPS port for Grafana |
| `--tls-client-ca` | - | - | *(Future)* mTLS client CA — not yet implemented |
| `--envoy-image` | `ENVOY_IMAGE` | `envoyproxy/envoy:v1.31-latest` | Envoy Docker image |

### Kubernetes / OpenShift

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--namespace` | `NAMESPACE` | `monitoring` | K8s/OpenShift namespace |
| `--no-pvc` | - | - | Use emptyDir instead of PVC (dev/testing) |
| `--storage-class` | - | cluster default | Storage class for PVCs |
| `--pvc-size-pyroscope` | `PVC_SIZE_PYROSCOPE` | `10Gi` | Pyroscope PVC size |
| `--pvc-size-grafana` | `PVC_SIZE_GRAFANA` | `2Gi` | Grafana PVC size |

## Grafana Config Modes

By default, config files (grafana.ini, provisioning, dashboards) are volume-mounted from the host. This uses the stock Grafana image and config survives image upgrades. Use `--bake-config` to build a custom image with config baked in instead.

| Mode | Flag | How it works | Config survives image upgrade? |
|------|------|-------------|-------------------------------|
| **Mounted** (default) | - | Stock `grafana/grafana` image with config bind-mounted from host | Yes — just `docker pull` + `docker restart` |
| **Baked** | `--bake-config` | Builds custom `grafana-pyroscope` image with provisioning + dashboards built in | No — must re-run deploy |

```bash
# Default (volume-mounted config at /opt/pyroscope/grafana)
bash deploy/observability/deploy.sh full-stack --target vm

# Custom config directory
bash deploy/observability/deploy.sh full-stack --target vm --grafana-config-dir /etc/pyroscope

# Bake config into image instead
bash deploy/observability/deploy.sh full-stack --target vm --bake-config
```

With mounted mode, to update dashboards or config after deployment:
1. Edit files in the config directory (default: `/opt/pyroscope/grafana/`)
2. Run `docker restart grafana`

## Enterprise VM Notes (RHEL / pbrun)

The script handles common enterprise VM concerns:

- **`pbrun /bin/su -`**: PATH is hardened to include `/usr/local/bin`, `/usr/bin`, `/sbin`, etc. so Docker is found even after environment reset
- **SELinux**: Automatically detects enforcing mode and adds `:z` flag to Docker volume mounts
- **firewalld**: Automatically opens ports (4040/3000 for HTTP, 4443/443 for HTTPS) if firewalld is active
- **Idempotent**: Safe to re-run after partial failures. Each step checks current state before acting (container exists? volume exists? port open?)
- **Crash detection**: Health checks detect crashed containers immediately and dump logs instead of waiting for the full timeout
- **Docker pull retry**: Retries image pulls 3 times with backoff for transient network issues
- **Docker save/load**: Use `save-images` + `--load-images` to bypass Docker registry entirely
- **Log file**: Use `--log-file /tmp/deploy.log` to persist output — critical for pbrun sessions where SSH may disconnect
- **Dry run**: Use `--dry-run` to validate preflight checks and parameters without making changes

## Dashboards Included

| Dashboard | Description |
|-----------|-------------|
| Pyroscope Overview | CPU, allocation, lock profiles across all services |
| Verticle Performance | Per-verticle flame graph analysis |
| JVM Metrics | GC, heap, thread pool deep dive |
| HTTP Performance | Request latency correlated with CPU profiles |
| Before/After Comparison | Diff flame graph for optimization validation |
| FaaS Server | Serverless function profiling |

## Architecture

### Full-stack mode (HTTP)

```
+------------------+    +------------------+
|   Java Services  |    |     Grafana      |
|   (with agent)   |    |   :3000          |
+--------+---------+    +--------+---------+
         |                       |
         | push profiles         | query profiles
         v                       v
+------------------------------------------+
|            Pyroscope :4040               |
|   (ingest, storage, query — monolithic)  |
+------------------------------------------+
```

### Full-stack mode (HTTPS with Envoy)

```
+------------------+    +------------------+
|   Java Services  |    |     Browser      |
|   (with agent)   |    |                  |
+--------+---------+    +--------+---------+
         |                       |
         | HTTPS :4443           | HTTPS :443
         v                       v
+------------------------------------------+
|         Envoy TLS Proxy                  |
|   (terminates TLS, forwards to backend) |
+--------+---------+--------+--------------+
         |                   |
         v                   v
+------------------+  +------------------+
|   Pyroscope      |  |    Grafana       |
| 127.0.0.1:4040   |  | 127.0.0.1:3000   |
+------------------+  +------------------+
```

### Add-to-existing mode

```
Existing Stack                    New Component
+------------------+              +------------------+
|     Grafana      | -- query --> |    Pyroscope      |
|  (+ datasource)  |             |     :4040          |
|  (+ dashboards)  |             +--------+-----------+
+------------------+                      ^
                                          | push profiles
                                 +--------+-----------+
                                 |   Java Services    |
                                 |   (with agent)     |
                                 +--------------------+
```

## Data Persistence

| Target | Pyroscope data | Grafana data | Grafana config | Survives restart? |
|--------|---------------|-------------|----------------|-------------------|
| **VM** (docker) | Named volume `pyroscope-data` | Named volume `grafana-data` | Host dir (default) or baked | Yes |
| **Local** (compose) | Named volume | Named volume | Bind mount from repo | Yes |
| **K8s** (default) | PVC 10Gi | PVC 2Gi | ConfigMaps | Yes |
| **K8s** (`--no-pvc`) | emptyDir | emptyDir | ConfigMaps | No (dev only) |
| **Ansible** | Named volume | Named volume | Host dir (default) or baked | Yes |

## Ansible

For teams that use Ansible, an equivalent Ansible role is provided in `ansible/`. It provides the same functionality as `deploy.sh` — including TLS, skip-grafana, and image loading — but uses native Ansible modules (`community.docker`, `ansible.posix`). See [ansible/README.md](ansible/README.md) for details.

```bash
cd deploy/observability/ansible

# Deploy (HTTP)
ansible-playbook -i inventory playbooks/deploy.yml

# Deploy (HTTPS, self-signed)
ansible-playbook -i inventory playbooks/deploy.yml \
    -e tls_enabled=true -e tls_self_signed=true

# Deploy with pre-loaded images
ansible-playbook -i inventory playbooks/deploy.yml \
    -e docker_load_path=/tmp/pyroscope-stack-images.tar

# Add to an existing playbook — see ansible/README.md "Integrating into Existing Playbooks"
```

The role can be dropped into any existing Ansible playbook:

```yaml
- name: My infrastructure playbook
  hosts: profiling_servers
  become: true
  roles:
    - role: pyroscope-stack
```

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Main deployment script (bash) |
| `ansible/` | Ansible role + playbooks (same functionality) |
| `docker-compose.yaml` | Generated on first `--target local` run |
| `kubernetes/` | Generated on first `--target k8s` run |
| `README.md` | This file |

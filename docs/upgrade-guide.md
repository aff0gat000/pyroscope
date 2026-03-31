# Upgrade and Rollback Guide

Step-by-step procedures for upgrading the Pyroscope stack across all deployment
methods, with pre-upgrade checks, rollback procedures, and post-change verification.

---

## Pre-upgrade Checklist

Complete every item before starting the upgrade.

| # | Check | Command | Pass Condition |
|---|-------|---------|----------------|
| 1 | Backup profiling data | See [deploy/monolith/README.md](../deploy/monolith/README.md) | Backup tar exists and is non-empty |
| 2 | Verify current version | `docker inspect pyroscope --format='{{.Config.Image}}'` | Version noted for rollback |
| 3 | Confirm server healthy | `curl -sf http://<vm>:4040/ready` | Returns `200 OK` |
| 4 | Check disk headroom | `df -h /var/lib/docker` | > 20% free space |
| 5 | Confirm rollback image available | `docker images grafana/pyroscope` | Previous version tag present locally |
| 6 | Review changelog | Check [Pyroscope releases](https://github.com/grafana/pyroscope/releases) for breaking changes | No blockers identified |
| 7 | Silence Prometheus alerts | Silence `PyroscopeDown` alert for the maintenance window | Alert silenced |

---

## Backup Before Upgrade

The Docker volume persists through container replacement — data is safe during
normal upgrades. A backup is recommended before major version bumps (e.g., 1.18.x to 1.19.x).

```bash
# Backup (Pyroscope can remain running)
docker run --rm \
    -v pyroscope-data:/data:ro \
    -v /tmp:/backup \
    alpine tar czf /backup/pyroscope-backup-$(date +%Y%m%d).tar.gz -C /data .
```

See [deploy/monolith/README.md](../deploy/monolith/README.md) for full backup and restore procedures.

---

## Upgrade Procedures

### VM — Manual Docker

```bash
# 1. Pull or load the new image
docker pull grafana/pyroscope:1.19.0
# Air-gapped: docker load -i /tmp/pyroscope-1.19.0.tar

# 2. Stop and remove the old container (volume is preserved)
docker rm -f pyroscope

# 3. Start with the new image
docker run -d --name pyroscope --restart unless-stopped \
    -p 4040:4040 -v pyroscope-data:/data \
    grafana/pyroscope:1.19.0

# 4. Verify (see Post-upgrade Verification below)
```

### VM — deploy.sh

```bash
bash deploy.sh full-stack --target vm --pyroscope-image grafana/pyroscope:1.19.0
```

Air-gapped:
```bash
bash deploy.sh save-images --pyroscope-image grafana/pyroscope:1.19.0
# Transfer tar to target VM, then:
bash deploy.sh full-stack --target vm --load-images /tmp/pyroscope-stack-images.tar
```

See [deploy/monolith/README.md](../deploy/monolith/README.md) for full deploy.sh reference.

### VM — Ansible

```bash
ansible-playbook -i inventory playbooks/deploy.yml \
    -e pyroscope_image=grafana/pyroscope:1.19.0
```

The Ansible role is idempotent — it stops the old container and starts the new one.
The data volume is preserved across image upgrades.

See [deploy/monolith/ansible/README.md](../deploy/monolith/ansible/README.md) for full Ansible reference.

### Helm (OCP / K8s)

```bash
helm upgrade pyroscope deploy/helm/pyroscope/ \
    --reuse-values \
    --set image.tag=1.19.0
```

Rollback to a previous Helm release:
```bash
helm rollback pyroscope [REVISION]
```

See [deploy/helm/pyroscope/README.md](../deploy/helm/pyroscope/README.md) for full Helm reference.

---

## Post-upgrade Verification

Run these checks within 5 minutes of completing the upgrade.

```bash
# 1. Server is healthy
curl -sf http://<vm>:4040/ready && echo "OK"

# 2. Correct version running
docker inspect pyroscope --format='{{.Config.Image}}'

# 3. Profiles still being ingested (wait 60 seconds for agents to push)
curl -s "http://<vm>:4040/pyroscope/label-values?label=service_name" | python3 -m json.tool

# 4. Prometheus metrics flowing
curl -s http://<vm>:4040/metrics | grep pyroscope_ingestion
```

Cross-ref: [monitoring-guide.md](monitoring-guide.md) for full health check procedures.

---

## Rollback Procedures

### When to Rollback

| Symptom | Threshold | Decision |
|---------|-----------|----------|
| `/ready` returns non-200 | After 5 minutes | Immediate rollback |
| No profiles ingested | After 10 minutes | Immediate rollback |
| Query errors > 50% | For 5 minutes | Immediate rollback |
| Elevated CPU/memory | Sustained 15 minutes | Investigate first, rollback if unresolvable |

### Rollback — VM Manual

```bash
docker rm -f pyroscope
docker run -d --name pyroscope --restart unless-stopped \
    -p 4040:4040 -v pyroscope-data:/data \
    grafana/pyroscope:<PREVIOUS_VERSION>
```

### Rollback — deploy.sh

```bash
bash deploy.sh full-stack --target vm --pyroscope-image grafana/pyroscope:<PREVIOUS_VERSION>
```

### Rollback — Ansible

```bash
ansible-playbook -i inventory playbooks/deploy.yml \
    -e pyroscope_image=grafana/pyroscope:<PREVIOUS_VERSION>
```

### Rollback — Helm

```bash
# List release history
helm history pyroscope

# Rollback to previous revision
helm rollback pyroscope [REVISION]
```

---

## Rollback Verification

Run the same checks as [Post-upgrade Verification](#post-upgrade-verification). Additionally:

```bash
# Confirm the rollback version is running
docker inspect pyroscope --format='{{.Config.Image}}'
# Expected: grafana/pyroscope:<PREVIOUS_VERSION>
```

---

## Version Compatibility

| Component | Compatibility Rule |
|-----------|--------------------|
| Java agent vs server | Agent v0.14.x works with any Pyroscope server 1.x (push protocol is stable) |
| Server vs Grafana datasource | Match the Grafana Pyroscope plugin version to your Grafana version range |
| Monolith vs microservices data | Data format is compatible; monolith data can be read by microservices mode |

Best practice: Pin versions in production. Use `grafana/pyroscope:1.18.0`, not `:latest`.

---

## Phase 1 to Phase 2 Migration (Single VM → Multi-VM)

The migration adds a second Pyroscope VM behind a load balancer, with S3-compatible
object storage (MinIO, AWS S3, GCS, or Azure Blob). Java agents are updated to push
to the VIP instead of the direct VM address.

Steps:
1. Provision second VM and S3-compatible object storage bucket
2. Configure Pyroscope on both VMs to use S3-compatible object storage
3. Configure F5 VIP with health check (`GET /ready`)
4. Update agent `pyroscope.server.address` to point to VIP
5. Validate failover by stopping one VM

Cross-ref: [project-plan-phase2.md](project-plan-phase2.md) for Phase 2 scope.

---

## Phase 2 to Phase 3 Migration (Multi-VM → Microservices on OCP)

The migration from multi-VM monolith to microservices is **server-side only** — Java
agents do not change. The agent pushes to a URL; you change what is behind that URL.

Steps:
1. Deploy microservices Pyroscope on OCP (new namespace, S3-compatible object storage)
2. Migrate DNS or update agent `pyroscope.server.address` to point to the OCP distributor
3. Run parallel for a retention overlap period
4. Decommission multi-VM monolith after verification

Cross-ref: [project-plan-phase3.md](project-plan-phase3.md) for Phase 3 scope.
Cross-ref: [production-questionnaire-phase2.md](production-questionnaire-phase2.md) for the upgrade path checklist.

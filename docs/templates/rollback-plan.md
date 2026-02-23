# Rollback Plan Template

Fill-in template for documenting rollback procedures when submitting a change
request. Attach this to the corresponding change request.

See [upgrade-guide.md](../upgrade-guide.md) for full rollback procedures and verification steps.

---

## Rollback Plan

### 1. Change Reference

| Field | Value |
|-------|-------|
| Change ID | CR-____-___ (from [change-request.md](change-request.md)) |
| Component being rolled back | [ ] Pyroscope server [ ] Java agent [ ] Grafana [ ] Other: _____ |
| Current version (after change) | |
| Rollback-to version | |

### 2. Trigger Criteria

Initiate rollback if any of these conditions are met:

| # | Condition | Threshold |
|---|-----------|-----------|
| 1 | `/ready` returns non-200 | After 5 minutes post-change |
| 2 | No profiles ingested | After 10 minutes post-change |
| 3 | Query errors > 50% | For 5 consecutive minutes |
| 4 | Other (specify): | |

Decision authority: ________________ (name/role)

### 3. Rollback Steps

Select and complete the section matching your deployment method.

**VM — Manual Docker:**
```bash
docker rm -f pyroscope
docker run -d --name pyroscope --restart unless-stopped \
    -p 4040:4040 -v pyroscope-data:/data \
    grafana/pyroscope:<ROLLBACK_VERSION>
```

**VM — deploy.sh:**
```bash
bash deploy.sh full-stack --target vm \
    --pyroscope-image grafana/pyroscope:<ROLLBACK_VERSION>
```

**VM — Ansible:**
```bash
ansible-playbook -i inventory playbooks/deploy.yml \
    -e pyroscope_image=grafana/pyroscope:<ROLLBACK_VERSION>
```

**Helm (OCP / K8s):**
```bash
helm rollback pyroscope <REVISION_NUMBER>
```

See [upgrade-guide.md](../upgrade-guide.md) for full procedures.

### 4. Verification Steps

Complete after executing the rollback.

```bash
# 1. Server is healthy
curl -sf http://<vm>:4040/ready && echo "OK"

# 2. Correct version running
docker inspect pyroscope --format='{{.Config.Image}}'
# Expected: grafana/pyroscope:<ROLLBACK_VERSION>

# 3. Profiles still being ingested (wait 60 seconds)
curl -s "http://<vm>:4040/pyroscope/label-values?label=service_name" | python3 -m json.tool
```

| Check | Status |
|-------|--------|
| `/ready` returns 200 | [ ] Pass |
| Correct version confirmed | [ ] Pass |
| Profiles visible in UI | [ ] Pass |
| Prometheus scraping resumed | [ ] Pass |

### 5. Communication Plan

| Action | Responsible | Channel | When |
|--------|-------------|---------|------|
| Announce rollback decision | | | Immediately on trigger |
| Notify stakeholders | | | Within 15 minutes |
| Declare rollback complete | | | After verification passes |

### 6. Post-rollback Actions

| Action | Status |
|--------|--------|
| Incident report filed | [ ] Yes [ ] Not required |
| Root cause identified | [ ] Yes [ ] Pending investigation |
| Next upgrade attempt date | ____-__-__ |
| Lessons learned documented | [ ] Yes |
| Change request updated with outcome | [ ] Yes |

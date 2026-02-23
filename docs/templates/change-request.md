# Change Request Template

Fill-in template for Change Advisory Board (CAB) submissions for Pyroscope
infrastructure changes. Copy this template and complete all sections before
submitting for approval.

See [project-plan-phase1.md](../project-plan-phase1.md) for CAB context and lead times.

---

## Change Request

### 1. Change Identification

| Field | Value |
|-------|-------|
| Change ID | CR-____-___ |
| Date submitted | ____-__-__ |
| Requestor name | |
| Requestor team | |
| Priority | [ ] Standard [ ] Expedited [ ] Emergency |

### 2. System

| Field | Value |
|-------|-------|
| System | Pyroscope continuous profiling platform |
| Environment | [ ] Dev [ ] Staging [ ] Production |
| Deployment method | [ ] Manual VM [ ] deploy.sh [ ] Ansible [ ] Helm |
| Affected components | [ ] Pyroscope server [ ] Java agent [ ] Grafana [ ] Prometheus |

### 3. Change Description

**Summary (1-2 sentences):**

_Describe what is changing and why._

**Detailed description:**

_Include: current state, target state, and what actions will be performed._

**Scope of impact:**

_Which services, pods, or VMs are affected? Is there user-facing impact?_

### 4. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Profiling data gap during upgrade | High | Low | Non-critical tool; gap is acceptable per [sla-slo.md](../sla-slo.md) |
| New version has performance regression | Low | Medium | Rollback to previous version within 5 minutes |
| Agent incompatibility with new server | Low | Low | Agent protocol is stable across 1.x versions |
| Configuration error prevents startup | Medium | Low | Pre-validated config; `/ready` health check within 2 min |

### 5. Rollback Plan

| Field | Value |
|-------|-------|
| Rollback document | [rollback-plan.md](rollback-plan.md) |
| Rollback time estimate | < 5 minutes |
| Rollback trigger criteria | See [upgrade-guide.md](../upgrade-guide.md) |
| Previous version (rollback target) | grafana/pyroscope:_______ |

### 6. Test Evidence

| Check | Status |
|-------|--------|
| Pre-change: `/ready` returns 200 | [ ] Pass |
| Pre-change: backup completed | [ ] Pass [ ] N/A |
| Post-change: `/ready` returns 200 | [ ] Pass |
| Post-change: profiles visible in Pyroscope UI | [ ] Pass |
| Post-change: Grafana datasource connected | [ ] Pass [ ] N/A |
| Post-change: Prometheus scraping metrics | [ ] Pass [ ] N/A |

### 7. Approvals

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Requestor | | | |
| Technical lead | | | |
| Change manager | | | |
| CAB representative | | | |

### 8. Change Window

| Field | Value |
|-------|-------|
| Planned start | ____-__-__ __:__ |
| Planned end | ____-__-__ __:__ |
| Maintenance window | __ minutes |
| Communication sent | [ ] Yes — notified: ________________ |

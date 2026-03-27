# Presentation Guide

How to present Pyroscope continuous profiling to different audiences. Covers what
to emphasize, what to skip, recommended flow, and common objections with responses.

Target audience: anyone presenting Pyroscope to stakeholders.

---

## Quick Reference: Audience → Message

| Audience | Time | Lead with | Show | Skip | Key doc |
|----------|:----:|-----------|------|------|---------|
| **VP / Director** | 15 min | Cost savings + MTTR reduction | Value table, before/after flame graph (one slide) | Architecture, agent config, ports | [what-is-pyroscope.md](what-is-pyroscope.md) |
| **Architects / Tech Leads** | 30 min | Architecture + deployment phases | Topology diagrams, deployment decision tree, phasing | Demo walkthrough, code-level details | [architecture.md](architecture.md) |
| **Developers** | 30 min | Live demo — flame graphs are addictive | Live Grafana, 3 profiling scenarios, before/after fix | Infrastructure, capacity planning | demo-runbook.md (in repo) |
| **SREs / Platform** | 30 min | Operational simplicity + incident response | Deploy scripts, monitoring, runbook playbooks | Business case, code patterns | [deployment-guide.md](deployment-guide.md) |
| **Security / Compliance** | 20 min | Data classification + network isolation | Security model, no PII in profiles, network diagrams | Demo, performance optimization | [security-model.md](security-model.md) |
| **Change Advisory Board** | 15 min | Risk assessment + rollback plan | Overhead data, rollback steps, change request template | Everything else | [templates/change-request.md](templates/change-request.md) |

---

## Presentation 1: Leadership / Funding (15 minutes)

### Objective
Get approval and budget for Phase 1 deployment.

### Flow

**Slide 1 — The Problem (3 min)**
> "When a production incident happens, how long does it take to find the root cause?
> Not the symptom — the actual line of code. Today that's hours to days. We want
> to make it minutes."

- Current MTTR for performance issues: hours to days
- Root cause: we're blind to function-level behavior in production
- We can see *what* is slow (metrics), but not *why* (no profiling)

**Slide 2 — The Solution (3 min)**
> "Continuous profiling captures what every thread is doing, all the time, with
> no code changes. When an incident happens, the data is already there."

- Always-on, zero code changes, 3-5% CPU overhead
- Open source (Grafana Labs) — no license cost
- Integrates with existing Grafana

**Slide 3 — Value (5 min)**

Use this table directly from [capacity-planning.md](capacity-planning.md):

| Benefit | Without | With Pyroscope | Impact |
|---------|---------|----------------|--------|
| MTTR for performance issues | Hours to days | Minutes | 5-50x faster |
| Production debugging | SSH + restart + reproduce | Always-on flame graphs | No emergency profiling |
| Resource optimization | Over-provisioned by guess | Data-driven right-sizing | 10-30% infra cost reduction |
| Regression detection | Caught by users in prod | Before/after flame graph diff | Caught in CI, not prod |

**Slide 4 — Cost and Risk (3 min)**
- Infrastructure: 1 VM (4 CPU, 8 GB RAM) for Phase 1
- Agent overhead: 3-5% CPU per JVM, bounded, does not grow with load
- Rollback: remove one environment variable, pod restarts in 30s
- No code changes, no bytecode modification, no application dependencies

**Slide 5 — Ask (1 min)**
- Phase 1: One VM, 10-20 services, 4-6 weeks
- Phase 1b: Add HA with second VM + object storage (MinIO / S3)
- Phase 2: Migrate to OCP microservices when ready

### Common Objections

| Objection | Response |
|-----------|----------|
| "Will it slow down our apps?" | 3-5% CPU, bounded. Does not increase with load. Netflix, Uber, and Datadog run this in production on every JVM. Rollback is one env var change. |
| "We already have APM / Datadog" | APM shows request flow (traces). Profiling shows *which function* inside a service is consuming CPU/memory. They're complementary, not competing. APM overhead is typically 5-15% vs Pyroscope's 3-5%. |
| "Is it secure?" | Profiles contain function names and stack traces only. No request payloads, no PII, no secrets. Network: agents push out, server accepts in. No inbound access to app pods. |
| "Can we remove it if needed?" | Yes. Remove `JAVA_TOOL_OPTIONS` env var → pod restarts → agent gone. 30 seconds. Historical data stays in Pyroscope for review. |

---

## Presentation 2: Architecture Review (30 minutes)

### Objective
Get architectural approval for deployment topology and network requirements.

### Flow

**Part 1 — What Pyroscope Is (5 min)**
- 7 internal components, runs as monolith or microservices
- Show [architecture.md §1 Component Table](architecture.md#1-pyroscope-components)

**Part 2 — Deployment Phases (10 min)**
- Show the 3-phase progression diagram from [deployment-guide.md §2](deployment-guide.md#2-pyroscope-server-mode)
- Phase 1a: Single monolith VM — show [architecture.md §3a](architecture.md#3a-vm-single-monolith-with-nginx-tls-phase-1a) topology diagram
- Phase 1b: Multi-instance with object storage — show [architecture.md §3a-ii](architecture.md#3a-ii-vm-multi-instance-monolith-with-shared-storage-phase-1b)
- Phase 2: OCP microservices — show [architecture.md §3d](architecture.md#3d-ocp-microservices-helm-chart-phase-2)

**Part 3 — Network + Ports (10 min)**
- Show port matrix from [architecture.md §7](architecture.md#7-port-matrix-summary)
- Walk through [capacity-planning.md port matrix](capacity-planning.md#port-matrix) for VM monolith
- Firewall rules are pre-documented — hand the capacity-planning.md networking section directly to the network team

**Part 4 — Capacity + Storage (5 min)**
- Show sizing table from [capacity-planning.md](capacity-planning.md#server-sizing)
- Show enterprise scoping checklists — these are designed as handoff documents for infra/network/storage teams

### What to bring
- Print or share [capacity-planning.md](capacity-planning.md) — it's designed as a standalone requirements doc
- The networking section has team-specific checklists (VM team, network team, storage team, security team)

---

## Presentation 3: Developer Live Demo (30 minutes)

### Objective
Show developers what profiling data looks like and how to use it.

### Flow
Follow demo-runbook.md (available in the repo at docs/demo-runbook.md) exactly — it has a minute-by-minute agenda.

**Key tips:**
- Start the stack *before* the meeting: `bash scripts/run.sh`
- Keep the terminal visible — background load makes flame graphs richer
- Show 3 scenarios, not 6 — pick the most dramatic (Payment SHA-256, Order lock contention, API Gateway Fibonacci)
- End with the before/after fix — this is the "aha moment"
- Show `bash scripts/run.sh bottleneck` — automated root cause is impressive

### What NOT to do
- Don't explain architecture or deployment — developers don't care about VMs and F5
- Don't show configuration — they see `JAVA_TOOL_OPTIONS` and one env var, that's enough
- Don't lecture about profiling theory — let the flame graphs speak
- Don't try to show everything — 3 scenarios > 6 rushed scenarios

---

## Presentation 4: SRE / Platform Team (30 minutes)

### Objective
Get operational buy-in and assign deployment tasks.

### Flow

**Part 1 — Operational Model (10 min)**
- Show deploy scripts: `deploy/monolith/stage1-build.sh` (Mac) → `stage2-deploy.sh` (VM)
- Idempotent, air-gapped support, SELinux-aware, health checks built in
- Day-2: `stage2-deploy.sh --status`, `--stop`, `--restart`
- Show [runbook.md](runbook.md) incident playbooks — pre-written for common scenarios

**Part 2 — Monitoring (5 min)**
- Pyroscope exposes `/metrics` — Prometheus scrapes it like any other target
- Show [monitoring-guide.md](monitoring-guide.md) alert rules
- Grafana dashboards are pre-provisioned — no manual setup

**Part 3 — Network + Firewall (10 min)**
- Walk through [capacity-planning.md networking section](capacity-planning.md#networking-requirements--deployment-reference)
- This section is designed as a handoff doc — share it directly with the network team
- Show the enterprise scoping checklists with lead times

**Part 4 — What We Need From You (5 min)**
- Hand out the Phase 1a scoping checklist from [capacity-planning.md](capacity-planning.md#phase-1a-vm-single-monolith-with-nginx-tls)
- Assign owners for each row (VM, network, PKI, monitoring)

---

## Presentation 5: Security Review (20 minutes)

### Objective
Get security clearance for production deployment.

### Flow

**Part 1 — Data Classification (5 min)**
> "Profiles contain function names, class names, and thread names. No request payloads,
> no query parameters, no headers, no secrets, no PII."

- Show [security-model.md](security-model.md) data classification section
- Profile data is structural (code paths), not content (user data)

**Part 2 — Network Model (10 min)**
- Agents push *out* to Pyroscope. Pyroscope never connects *in* to app pods
- Show [architecture.md §5 Network Boundaries](architecture.md#5-network-boundaries)
- Port 4041 is localhost only — never exposed
- All external traffic is HTTPS via Nginx TLS termination
- NetworkPolicy examples provided for OCP

**Part 3 — Controls (5 min)**
- No privileged containers needed (SCC `restricted` is sufficient)
- No PII in profiles — but consider: custom label values set by app teams could theoretically contain PII. Recommend label policy.
- TLS everywhere in production (Nginx terminates, F5 VIP fronts)
- Rollback: remove env var, pod restarts

---

## General Presentation Tips

### Before the meeting
1. Know your audience — pick the right presentation above
2. Have the stack running if doing a live demo (`bash scripts/run.sh` takes 3-5 min)
3. Pre-load Grafana tabs: flame graph, dashboard, before/after comparison
4. Print or share relevant docs as pre-reads (capacity-planning.md for architects, what-is-pyroscope.md for leadership)

### During the meeting
1. Lead with the problem, not the solution
2. Use flame graphs visually — they're the most compelling artifact
3. Keep it short — 80% of the value comes from 20% of the content
4. For technical audiences: show real data, not slides
5. For non-technical audiences: focus on outcomes (MTTR, cost, risk), not mechanisms

### After the meeting
1. Share the relevant doc links (not the whole docs/ folder)
2. For architects: share capacity-planning.md as the requirements handoff
3. For developers: share the Grafana URL and profiling-scenarios.md (available in the repo at docs/profiling-scenarios.md)
4. For SREs: share the deploy/ README and runbook.md
5. Follow up with a one-paragraph summary and next-step action items

### Exporting for Confluence / Wiki
If your audience prefers Confluence:
```bash
bash scripts/export-to-confluence.sh                    # Export all docs
bash scripts/export-to-confluence.sh docs/runbook.md    # Export one doc
```
Paste the output into Confluence's wiki markup editor. See [scripts/export-to-confluence.sh](../scripts/export-to-confluence.sh).

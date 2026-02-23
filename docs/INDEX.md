# Documentation Index

33 documents organized by the [Diataxis framework](https://diataxis.fr/) — the same
documentation standard used by Kubernetes, Django, Grafana, and other CNCF projects.

---

## How this documentation is organized

Every document falls into one of four categories:

```
                  ┌──────────────────────┬──────────────────────┐
                  │                      │                      │
   Practical      │     TUTORIALS        │      HOW-TO          │
   (doing)        │     Learning-        │      Task-           │
                  │     oriented          │      oriented        │
                  │                      │                      │
                  ├──────────────────────┼──────────────────────┤
                  │                      │                      │
   Theoretical    │     EXPLANATION       │      REFERENCE       │
   (understanding)│     Understanding-   │      Information-    │
                  │     oriented          │      oriented        │
                  │                      │                      │
                  └──────────────────────┴──────────────────────┘
                        Studying                Working
```

| Category | Purpose | When to use |
|----------|---------|-------------|
| **Tutorial** | Learn by doing — guided walkthroughs | You are new and want to get started |
| **How-to** | Solve a specific task — step-by-step | You know what you want to do but need instructions |
| **Explanation** | Understand concepts — why things work | You want deeper knowledge of how Pyroscope works |
| **Reference** | Look up facts — APIs, ports, configs | You need specific details while working |

---

## Tutorials (learning-oriented)

Start here if you are new to Pyroscope or continuous profiling.

| Document | Description |
|----------|-------------|
| [getting-started.md](getting-started.md) | Day-one orientation — glossary, environment setup, reading path by role, team contacts |
| [what-is-pyroscope.md](what-is-pyroscope.md) | Executive overview — what it is, what problem it solves, cost, adoption phases |
| [faq.md](faq.md) | Frequently asked questions — profiling concepts, security, operations, cost |
| [reading-flame-graphs.md](reading-flame-graphs.md) | How to read flame graphs — axes, width, color, self vs total time |
| [demo-runbook.md](demo-runbook.md) | Step-by-step demo agenda with commands and talking points (20-25 min) |
| [profiling-scenarios.md](profiling-scenarios.md) | 6 hands-on scenarios with quick reference of all bottlenecks by service |

---

## How-to guides (task-oriented)

Follow these when you have a specific goal.

| Document | Description |
|----------|-------------|
| [deployment-guide.md](deployment-guide.md) | Deploy Pyroscope — decision trees, quick reference, step-by-step, firewall rules |
| [continuous-profiling-runbook.md](continuous-profiling-runbook.md) | Agent configuration, Grafana integration, bottleneck analysis workflow |
| [grafana-setup.md](grafana-setup.md) | Connect Grafana to Pyroscope via provisioning files |
| [monitoring-guide.md](monitoring-guide.md) | Monitor Pyroscope server health — endpoints, metrics reference, alert rules |
| [upgrade-guide.md](upgrade-guide.md) | Upgrade and rollback — pre-upgrade checklist, procedures for all deployment methods |
| [troubleshooting.md](troubleshooting.md) | Diagnose common issues — no data, empty flame graphs, connectivity, overhead |
| [runbook.md](runbook.md) | Incident response playbooks and operational procedures |
| [project-plan-phase1.md](project-plan-phase1.md) | Phase 1 project plan — epics, stories, timeline, effort estimates |
| [workflow.md](workflow.md) | Development workflow — issues, PRs, async communication, incremental adoption |

---

## Explanation (understanding-oriented)

Read these to deepen your understanding of Pyroscope internals and architecture.

| Document | Description |
|----------|-------------|
| [architecture.md](architecture.md) | Component internals, topology diagrams per deployment mode, data flow, storage |
| [security-model.md](security-model.md) | Security model — data classification, authentication gaps, TLS, secrets, compliance checklist |
| [code-to-profiling-guide.md](code-to-profiling-guide.md) | Source code to flame graph mapping for every service and endpoint |
| [pyroscope-study-guide.md](pyroscope-study-guide.md) | Expert mastery — internals, operations, competitive analysis, talking points |

---

## Reference (information-oriented)

Look up specific facts while working.

| Document | Description |
|----------|-------------|
| [configuration-reference.md](configuration-reference.md) | All configuration keys — agent properties, pyroscope.yaml, deploy.sh flags, Ansible, Helm |
| [capacity-planning.md](capacity-planning.md) | Sizing formulas — server resources, storage calculator, worked examples (10/50/100 services) |
| [sla-slo.md](sla-slo.md) | SLO definitions — data availability, query latency, RPO/RTO, error budget, escalation matrix |
| [function-reference.md](function-reference.md) | BOR/SOR function API reference — triage, diff report, fleet search, Phase 1/2 |
| [function-architecture.md](function-architecture.md) | Project structure, design patterns, Gradle multi-project build |
| [endpoint-reference.md](endpoint-reference.md) | Complete endpoint list with curl examples for all 9 services |
| [sample-queries.md](sample-queries.md) | Copy-paste queries for Pyroscope, Prometheus, and Grafana |
| [dashboard-guide.md](dashboard-guide.md) | Panel-by-panel reference for all 6 Grafana dashboards |
| [faas-server.md](faas-server.md) | FaaS runtime — function deploy/undeploy lifecycle profiling |
| [production-questionnaire-phase1.md](production-questionnaire-phase1.md) | Production onboarding questionnaire — Phase 1 volume estimates, deployment config |
| [production-questionnaire-phase2.md](production-questionnaire-phase2.md) | Phase 2 questionnaire — PostgreSQL SORs, upgrade path, test coverage |

---

## Deployment references

Infrastructure-level READMEs for operators.

| Document | Description |
|----------|-------------|
| [deploy/monolith/README.md](../deploy/monolith/README.md) | Monolith Pyroscope server — deploy.sh, build-and-push.sh, Ansible |
| [deploy/monolith/DOCKER-BUILD.md](../deploy/monolith/DOCKER-BUILD.md) | Pyroscope image build and push to internal registry (air-gapped) |
| [deploy/monolith/ansible/README.md](../deploy/monolith/ansible/README.md) | Ansible role for enterprise VMs (TLS, skip-grafana, image loading) |
| [deploy/microservices/README.md](../deploy/microservices/README.md) | Distributed Pyroscope deployment (VM, K8s, OpenShift) |
| [deploy/microservices/vm/README.md](../deploy/microservices/vm/README.md) | Microservices on VM — NFS-backed Docker Compose |
| [deploy/helm/pyroscope/](../deploy/helm/pyroscope/) | Unified Helm chart — monolith and microservices, OCP and K8s |
| [deploy/profiling-workload/README.md](../deploy/profiling-workload/README.md) | Profiling workload — validates Pyroscope on VM (no OCP needed) |
| [deploy/grafana/README.md](../deploy/grafana/README.md) | Standalone Grafana image build |
| [deploy/grafana/DOCKER-BUILD.md](../deploy/grafana/DOCKER-BUILD.md) | Grafana image build with Pyroscope datasource baked in (air-gapped) |

---

## Templates

Fill-in templates for change management and governance.

| Document | Description |
|----------|-------------|
| [templates/change-request.md](templates/change-request.md) | CAB change request template — risk assessment, test evidence, approval signatures |
| [templates/rollback-plan.md](templates/rollback-plan.md) | Rollback plan template — trigger criteria, steps, verification, communication |

---

## By audience

### New team members (any role)

> "Where do I start?"

1. [getting-started.md](getting-started.md) — orientation, glossary, environment setup
2. [what-is-pyroscope.md](what-is-pyroscope.md) — understand the project
3. [adr/ADR-001-continuous-profiling.md](adr/ADR-001-continuous-profiling.md) — understand why we made these choices
4. (then follow the path for your specific role below)

### Leadership / project management

> "Why should we fund this?"

1. [what-is-pyroscope.md](what-is-pyroscope.md) — business case, cost, risk assessment
2. [project-plan-phase1.md](project-plan-phase1.md) — project plan, timeline, effort estimates
3. [pyroscope-study-guide.md § Talking Points](pyroscope-study-guide.md) — funding justification and competitive analysis
4. [continuous-profiling-runbook.md](continuous-profiling-runbook.md) — MTTR reduction data

### Operators / SREs

> "How do I deploy and operate this?"

1. [project-plan-phase1.md](project-plan-phase1.md) — project plan with prerequisites and milestones
2. [deployment-guide.md](deployment-guide.md) — choose deployment mode (decision trees 1-7)
3. [architecture.md](architecture.md) — understand topology and port requirements
4. [security-model.md](security-model.md) — authentication gaps and network isolation requirements
5. [monitoring-guide.md](monitoring-guide.md) — configure Prometheus alerts for the server
6. [upgrade-guide.md](upgrade-guide.md) — perform upgrades safely
7. [troubleshooting.md](troubleshooting.md) — diagnose issues
8. [runbook.md](runbook.md) — incident response procedures

### Developers

> "How do I use profiling data to fix performance issues?"

1. [reading-flame-graphs.md](reading-flame-graphs.md) — learn to read flame graphs
2. [profiling-scenarios.md](profiling-scenarios.md) — hands-on exercises
3. [code-to-profiling-guide.md](code-to-profiling-guide.md) — source code to flame graph mapping
4. [sample-queries.md](sample-queries.md) — copy-paste queries

### Demo presenters

> "How do I show this to my team?"

1. [what-is-pyroscope.md](what-is-pyroscope.md) — understand the value proposition
2. [reading-flame-graphs.md](reading-flame-graphs.md) — learn to read flame graphs
3. [demo-runbook.md](demo-runbook.md) — follow the 20-minute agenda
4. [dashboard-guide.md](dashboard-guide.md) — know which panels to highlight

### FaaS function developers

> "How do I build profiling analysis functions?"

1. [function-reference.md](function-reference.md) — understand the 3 BOR functions and Phase 1/2
2. [function-architecture.md](function-architecture.md) — learn the project structure
3. [production-questionnaire-phase1.md](production-questionnaire-phase1.md) — production onboarding

### Governance / change managers

> "How do I get this approved and track ongoing changes?"

1. [what-is-pyroscope.md](what-is-pyroscope.md) — business case and risk assessment
2. [security-model.md](security-model.md) — security controls and compliance checklist
3. [sla-slo.md](sla-slo.md) — SLO definitions and error budget
4. [templates/change-request.md](templates/change-request.md) — CAB submission template
5. [templates/rollback-plan.md](templates/rollback-plan.md) — rollback plan template

---

## Architecture Decision Records (ADRs)

Immutable records of key technical decisions and the reasoning behind them.

| ADR | Decision |
|-----|----------|
| [ADR-001](adr/ADR-001-continuous-profiling.md) | Continuous profiling — Pyroscope monolith on VM with OCP agents |

---

## Tools

| Tool | Description |
|------|-------------|
| [scripts/mermaid-to-svg.sh](../scripts/mermaid-to-svg.sh) | Convert Mermaid diagrams in docs to SVG images |

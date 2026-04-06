# Documentation Index

Enterprise documentation organized by the [Diataxis framework](https://diataxis.fr/) — the same
standard used by Kubernetes, Django, Grafana, and other CNCF projects.

**35 enterprise docs** are published to Confluence (see [confluence-manifest.txt](confluence-manifest.txt)).
Development and demo resources remain in-repo only.

---

## How to read this documentation

### What's in this repo

This repository contains **four types of content**. Knowing which is which prevents
confusion about what's "real" vs what's a demo.

```
pyroscope/
│
├── app/                         DEMO — Bank microservices with deliberate bottlenecks
│   └── src/                     9 Vert.x verticles with intentional performance anti-patterns
│                                (recursive Fibonacci, SHA-256 reuse, synchronized hot paths)
│                                Purpose: generate interesting flame graphs for learning
│
├── deploy/                      PRODUCTION — Enterprise deployment automation
│   ├── monolith/                VM deployment: stage1-build.sh (Mac) → stage2-deploy.sh (VM)
│   │   ├── deploy.sh            Multi-target deployer (VM, K8s, OCP, air-gapped)
│   │   └── ansible/             Ansible role for enterprise VMs (TLS, Grafana, idempotent)
│   ├── helm/pyroscope/          Helm chart for Kubernetes and OpenShift (monolith + microservices)
│   ├── microservices/vm/        Docker Compose with S3-compatible object storage for multi-component VM deployment
│   └── grafana/                 Standalone Grafana image build with Pyroscope plugin baked in
│
├── services/                    APPLICATION — FaaS BOR/SOR analysis functions
│   ├── faas-jvm11/              Phase 1: Java 11 (triage, diff report, fleet search)
│   └── faas-jvm21/              Phase 3: Java 21 (records, switch expressions)
│
├── config/                      BOTH — Configuration files used by demo AND production
│   ├── pyroscope/pyroscope.properties   Java agent config (demo values, production-grade comments)
│   ├── pyroscope/pyroscope.yaml         Pyroscope server config
│   ├── grafana/                         Dashboard JSON, datasources, provisioning
│   └── prometheus/                      Scrape config, alert rules
│
├── scripts/                     DEMO — Local demo lifecycle and analysis tools
│   ├── run.sh                   Main entry point: deploy → load → validate → teardown
│   ├── deploy.sh                Build + start 12 containers locally
│   ├── generate-load.sh         Traffic generator for all 9 services
│   ├── bottleneck.sh            Automated root-cause analysis
│   └── ...                      validate, diagnose, benchmark, teardown
│
├── docker-compose.yaml          DEMO — 12 containers (9 services + Pyroscope + Prometheus + Grafana)
│
├── docs/                        DOCUMENTATION — You are here
│
└── postman/                     DEMO — Postman collection for interactive API exploration
```

**Key distinction:**
- **To run the demo locally**: use `scripts/run.sh` and `docker-compose.yaml`
- **To deploy to production VMs**: use `deploy/monolith/stage1-build.sh` → `stage2-deploy.sh`
- **To deploy to Kubernetes/OCP**: use `deploy/helm/pyroscope/`
- **Agent config for production**: start from `config/pyroscope/pyroscope.properties` — it has extensive comments explaining each setting

### Canonical sources (avoid duplication)

Several topics appear across multiple documents. To avoid contradictions, each topic
has **one canonical source**. All other documents should cross-reference it.

| Topic | Canonical source | Don't duplicate in |
|-------|-----------------|-------------------|
| Agent overhead (3-5% CPU, ~30 MB) | [capacity-planning.md § Performance Impact](capacity-planning.md#performance-impact-assessment) | Other docs should say "3-5% CPU overhead ([details](capacity-planning.md#performance-impact-assessment))" |
| Profile types (CPU, alloc, lock, wall) | [agent-configuration-reference.md § Profile Types](agent-configuration-reference.md#1-profile-types) | Other docs should link, not repeat the full table |
| Port matrix | [architecture.md § 7 Port Matrix](architecture.md#7-port-matrix-summary) | capacity-planning.md has deployment-specific ports; architecture.md has the master list |
| Agent configuration properties | [agent-configuration-reference.md](agent-configuration-reference.md) | capacity-planning.md has quick examples; agent-config-ref has the full reference |
| Deployment topologies | [architecture.md § 3 Topology Diagrams](architecture.md#3-topology-diagrams) | Other docs should link to the diagram, not redraw it |

### Presenting to different audiences

See [presentation-guide.md](presentation-guide.md) for audience-specific presentation
flows, slide structures, objection handling, and tips. Quick reference:

| Audience | Time | Start with | Key doc to share |
|----------|:----:|------------|-----------------|
| Leadership | 15 min | MTTR + cost savings | [what-is-pyroscope.md](what-is-pyroscope.md) |
| Architects | 30 min | Topology diagrams + phasing | [capacity-planning.md](capacity-planning.md) |
| Developers | 30 min | Live flame graph demo | [demo-runbook.md](demo-runbook.md) |
| SREs | 30 min | Deploy scripts + runbook | [deployment-guide.md](deployment-guide.md) |
| Security | 20 min | Data classification + network model | [security-model.md](security-model.md) |

### Exporting to Confluence

```bash
# Export enterprise docs only (35 docs from confluence-manifest.txt)
bash scripts/export-to-confluence.sh --enterprise

# Upload to Confluence Server/DC with PAT
export CONFLUENCE_URL=https://wiki.company.com
export CONFLUENCE_SPACE_KEY=PYRO
export CONFLUENCE_TOKEN=your-personal-access-token

# Preview what would be uploaded (dry run — default)
bash scripts/upload-to-confluence.sh --enterprise

# Upload for real (requires --confirm)
bash scripts/upload-to-confluence.sh --enterprise --confirm

# Export/upload a single file
bash scripts/export-to-confluence.sh docs/runbook.md
```

Pages are auto-nested under a "Pyroscope Documentation" parent page in the space sidebar.
The space landing page is never overwritten.

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

## Enterprise Documentation (published to Confluence)

These 26 docs are the enterprise documentation set. They are exported and uploaded
to Confluence via `scripts/upload-to-confluence.sh --enterprise`.

### Tutorials (learning-oriented)

Start here if you are new to Pyroscope or continuous profiling.

| Document | Description |
|----------|-------------|
| [getting-started.md](getting-started.md) | Day-one orientation — glossary, environment setup, reading path by role, team contacts |
| [reading-flame-graphs.md](reading-flame-graphs.md) | How to read flame graphs — axes, width, color, self vs total time |

### How-to guides (task-oriented)

Follow these when you have a specific goal.

| Document | Description |
|----------|-------------|
| [deployment-guide.md](deployment-guide.md) | Deploy Pyroscope — decision trees, quick reference, step-by-step, firewall rules |
| [continuous-profiling-runbook.md](continuous-profiling-runbook.md) | End-to-end implementation — intro to profiling, agent setup, Grafana integration, analysis workflow |
| [grafana-setup.md](grafana-setup.md) | Connect Grafana to Pyroscope via provisioning files |
| [monitoring-guide.md](monitoring-guide.md) | Monitor Pyroscope server health — endpoints, metrics reference, alert rules |
| [upgrade-guide.md](upgrade-guide.md) | Upgrade and rollback — pre-upgrade checklist, procedures for all deployment methods |
| [troubleshooting.md](troubleshooting.md) | Diagnose common issues — no data, empty flame graphs, connectivity, overhead |
| [tls-setup.md](tls-setup.md) | TLS setup — F5 VIP, native TLS, Nginx/Envoy proxy, certificate strategies, agent trust |
| [runbook.md](runbook.md) | Operations and incident response — demo and production procedures, playbooks |
| [project-plan-phase1.md](project-plan-phase1.md) | Phase 1 project plan — single VM monolith, epics, stories, timeline |
| [project-plan-phase2.md](project-plan-phase2.md) | Phase 2 project plan — multi-VM monolith with S3-compatible object storage, HA |
| [project-plan-phase3.md](project-plan-phase3.md) | Phase 3 project plan — microservices on OpenShift, PostgreSQL, v2 functions |
| [workflow.md](workflow.md) | Development workflow — issues, PRs, async communication, incremental adoption |
| [presentation-guide.md](presentation-guide.md) | How to present Pyroscope to leadership, architects, developers, SREs, and security |

### Explanation (understanding-oriented)

Read these to deepen your understanding of Pyroscope internals and architecture.

| Document | Description |
|----------|-------------|
| [what-is-pyroscope.md](what-is-pyroscope.md) | Executive overview — what continuous profiling is, business case, cost, adoption phases |
| [value-proposition.md](value-proposition.md) | Enterprise value proposition — quantified ROI, compliance alignment, cost analysis |
| [architecture.md](architecture.md) | Component internals, topology diagrams per deployment mode, data flow, storage |
| [vertx-labeling-guide.md](vertx-labeling-guide.md) | Vert.x component reference, profiling label strategy, implementation approaches |
| [profiling-use-cases.md](profiling-use-cases.md) | Enterprise use cases, AI/ML initiatives, always-on rationale, dashboard strategy |
| [security-model.md](security-model.md) | Security model — data classification, authentication gaps, TLS, secrets, compliance checklist |
| [async-profiling-guide.md](async-profiling-guide.md) | Profiling async frameworks — two-tier labeling (automatic + LabeledFuture), async limitations |
| [faq.md](faq.md) | Frequently asked questions — profiling concepts, security, operations, cost |

### Reference (information-oriented)

Look up specific facts while working.

| Document | Description |
|----------|-------------|
| [configuration-reference.md](configuration-reference.md) | All configuration keys — agent properties, pyroscope.yaml, deploy.sh flags, Ansible, Helm |
| [agent-configuration-reference.md](agent-configuration-reference.md) | Java agent deep dive — profile types, thread context, Vert.x edge cases, OpenTelemetry integration |
| [capacity-planning.md](capacity-planning.md) | Sizing (Phase 1a single monolith, Phase 1b multi-instance monolith, Phase 2 OCP microservices), networking, firewall rules, enterprise scoping |
| [observability.md](observability.md) | Observability SLOs, measures, and controls — SLIs, SLOs, error budgets, alerting, health checks, capacity controls, incident response, change management |
| [function-reference.md](function-reference.md) | BOR/SOR function API reference — triage, diff report, fleet search, Phase 1/3 |
| [function-architecture.md](function-architecture.md) | Project structure, design patterns, Gradle multi-project build |
| [endpoint-reference.md](endpoint-reference.md) | Complete endpoint list with curl examples for all 9 services |
| [sample-queries.md](sample-queries.md) | Copy-paste queries for Pyroscope, Prometheus, and Grafana |
| [dashboard-guide.md](dashboard-guide.md) | Panel-by-panel reference for all 6 Grafana dashboards |
| [faas-server.md](faas-server.md) | FaaS runtime — function deploy/undeploy lifecycle profiling |
| [production-questionnaire-phase1.md](production-questionnaire-phase1.md) | Production onboarding questionnaire — Phase 1 volume estimates, deployment config |
| [production-questionnaire-phase2.md](production-questionnaire-phase2.md) | Phase 3 questionnaire — PostgreSQL SORs, upgrade path, test coverage |

---

## Development & Demo Resources (repo only — not published to Confluence)

These docs support the demo banking app, internal development workflow, and
competitive analysis. They are useful for the team but not appropriate for
the enterprise Confluence space.

| Document | Description | Why repo-only |
|----------|-------------|---------------|
| [demo-runbook.md](demo-runbook.md) | Step-by-step demo agenda with commands and talking points (20-25 min) | References demo docker-compose app |
| [profiling-scenarios.md](profiling-scenarios.md) | 6 hands-on scenarios with quick reference of all bottlenecks by service | Demo app bottlenecks (Fibonacci, SHA-256) |
| [code-to-profiling-guide.md](code-to-profiling-guide.md) | Source code to flame graph mapping for every service and endpoint | Maps demo app source to flame graphs |
| [sample-queries.md](sample-queries.md) | Copy-paste queries for Pyroscope, Prometheus, and Grafana | Queries reference demo service names |
| [dashboard-guide.md](dashboard-guide.md) | Panel-by-panel reference for all 6 Grafana dashboards | Demo dashboard panels |
| [endpoint-reference.md](endpoint-reference.md) | Complete endpoint list with curl examples for all 9 services | Demo app endpoints |
| [pyroscope-reference-guide.md](pyroscope-reference-guide.md) | Expert reference — internals, competitive analysis, talking points | Internal talking points, competitive intel |
| [function-reference.md](function-reference.md) | BOR/SOR function API reference — triage, diff report, fleet search | Developer-only, BOR/SOR internals |
| [function-architecture.md](function-architecture.md) | Project structure, design patterns, Gradle multi-project build | Developer-only, build system |
| [faas-server.md](faas-server.md) | FaaS runtime — function deploy/undeploy lifecycle profiling | Developer-only, FaaS internals |
| [workflow.md](workflow.md) | Development workflow — issues, PRs, async communication | Team process notes |

---

## Deployment references

Infrastructure-level READMEs for operators. These are **production code**, not demo.

| Document | Type | Description |
|----------|:----:|-------------|
| [deploy/monolith/README.md](../deploy/monolith/README.md) | Production | Monolith Pyroscope server — deploy.sh, build-and-push.sh, Ansible |
| [deploy/monolith/DOCKER-BUILD.md](../deploy/monolith/DOCKER-BUILD.md) | Production | Pyroscope image build and push to internal registry (air-gapped) |
| [deploy/monolith/ansible/README.md](../deploy/monolith/ansible/README.md) | Production | Ansible role for enterprise VMs (TLS, skip-grafana, image loading) |
| [deploy/microservices/README.md](../deploy/microservices/README.md) | Production | Distributed Pyroscope deployment (VM, K8s, OpenShift) |
| [deploy/microservices/vm/README.md](../deploy/microservices/vm/README.md) | Production | Microservices on VM — S3-compatible object storage backed Docker Compose |
| [deploy/helm/pyroscope/](../deploy/helm/pyroscope/) | Production | Unified Helm chart — monolith and microservices, OCP and K8s |
| [deploy/profiling-workload/README.md](../deploy/profiling-workload/README.md) | Testing | Profiling workload — validates Pyroscope on VM (no OCP needed) |
| [deploy/grafana/README.md](../deploy/grafana/README.md) | Production | Standalone Grafana image build |
| [deploy/grafana/DOCKER-BUILD.md](../deploy/grafana/DOCKER-BUILD.md) | Production | Grafana image build with Pyroscope datasource baked in (air-gapped) |

---

## Templates

Fill-in templates for change management and governance.

| Document | Description |
|----------|-------------|
| [templates/change-request.md](templates/change-request.md) | CAB change request template — risk assessment, test evidence, approval signatures |
| [templates/rollback-plan.md](templates/rollback-plan.md) | Rollback plan template — trigger criteria, steps, verification, communication |
| [labeling-analysis-prompt.md](labeling-analysis-prompt.md) | AI copilot prompt for analyzing Vert.x server codebase for profiling label strategy |

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
2. [capacity-planning.md § Value Proposition](capacity-planning.md#why-pyroscope-enterprise-value-proposition) — quantified benefits
3. [project-plan-phase1.md](project-plan-phase1.md) — Phase 1 plan, timeline, effort estimates
4. [project-plan-phase2.md](project-plan-phase2.md) — Phase 2 plan (multi-VM HA)
5. [project-plan-phase3.md](project-plan-phase3.md) — Phase 3 plan (microservices on OCP)
6. [presentation-guide.md § Leadership](presentation-guide.md#presentation-1-leadership--funding-15-minutes) — how to present to executives
7. [pyroscope-reference-guide.md § Talking Points](pyroscope-reference-guide.md) — funding justification and competitive analysis
8. [continuous-profiling-runbook.md](continuous-profiling-runbook.md) — MTTR reduction data

### Architects / tech leads

> "What's the architecture and what do we need?"

1. [architecture.md](architecture.md) — component internals, topology diagrams, data flow
2. [capacity-planning.md](capacity-planning.md) — sizing, networking, enterprise scoping checklists
3. [deployment-guide.md § Decision Trees](deployment-guide.md#1-what-are-you-deploying) — choose deployment mode
4. [presentation-guide.md § Architecture](presentation-guide.md#presentation-2-architecture-review-30-minutes) — how to present to architects

### Operators / SREs

> "How do I deploy and operate this?"

1. [deployment-guide.md](deployment-guide.md) — choose deployment mode (decision trees 1-7)
2. [deploy/monolith/README.md](../deploy/monolith/README.md) — production deploy scripts (stage1 + stage2)
3. [architecture.md](architecture.md) — understand topology and port requirements
4. [tls-setup.md](tls-setup.md) — TLS strategy and certificate setup
5. [monitoring-guide.md](monitoring-guide.md) — configure Prometheus alerts for the server
6. [runbook.md](runbook.md) — operations procedures and incident response playbooks
7. [troubleshooting.md](troubleshooting.md) — diagnose issues

### Developers

> "How do I use profiling data to fix performance issues?"

1. [reading-flame-graphs.md](reading-flame-graphs.md) — learn to read flame graphs
2. [async-profiling-guide.md](async-profiling-guide.md) — why profiling Vert.x/async is hard, labeling strategy
3. [profiling-scenarios.md](profiling-scenarios.md) — hands-on exercises
4. [code-to-profiling-guide.md](code-to-profiling-guide.md) — source code to flame graph mapping
5. [sample-queries.md](sample-queries.md) — copy-paste queries

### Demo presenters

> "How do I show this to my team?"

1. [presentation-guide.md](presentation-guide.md) — pick the right presentation for your audience
2. [demo-runbook.md](demo-runbook.md) — follow the 20-minute live demo agenda
3. [dashboard-guide.md](dashboard-guide.md) — know which panels to highlight

### FaaS function developers

> "How do I build profiling analysis functions?"

1. [function-reference.md](function-reference.md) — understand the 3 BOR functions and Phase 1/3
2. [function-architecture.md](function-architecture.md) — learn the project structure
3. [production-questionnaire-phase1.md](production-questionnaire-phase1.md) — production onboarding

### Governance / change managers

> "How do I get this approved and track ongoing changes?"

1. [what-is-pyroscope.md](what-is-pyroscope.md) — business case and risk assessment
2. [security-model.md](security-model.md) — security controls and compliance checklist
3. [observability.md](observability.md) — SLO definitions and error budget
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
| [scripts/export-to-confluence.sh](../scripts/export-to-confluence.sh) | Export Markdown docs to Confluence wiki markup (`--enterprise` for manifest docs only) |
| [scripts/upload-to-confluence.sh](../scripts/upload-to-confluence.sh) | Upload exported docs to Confluence via PAT auth (`--enterprise` for manifest docs only) |
| [scripts/mermaid-to-svg.sh](../scripts/mermaid-to-svg.sh) | Convert Mermaid diagrams in docs to SVG images |
| [docs/confluence-manifest.txt](confluence-manifest.txt) | Enterprise docs manifest — controls which docs are exported/uploaded to Confluence |

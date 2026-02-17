# Documentation Index

25 documents organized by topic. Start with **Getting Started**, then follow the path for your use case.

---

## Getting Started

| Document | Description |
|----------|-------------|
| [demo-guide.md](demo-guide.md) | What this project is, the problem it solves, and what it demonstrates |
| [demo-runbook.md](demo-runbook.md) | Step-by-step demo agenda with commands and talking points (20-25 min) |
| [reading-flame-graphs.md](reading-flame-graphs.md) | How to read flame graphs — axes, width, color, self vs total time |
| [architecture.md](architecture.md) | Service topology, data flow, and JVM agent configuration |

---

## Bank App Demo (9 Microservices)

The `app/` directory contains a bank enterprise demo with 9 Vert.x services profiled by Pyroscope.

| Document | Description |
|----------|-------------|
| [profiling-scenarios.md](profiling-scenarios.md) | 6 hands-on scenarios with quick reference of all bottlenecks by service |
| [code-to-profiling-guide.md](code-to-profiling-guide.md) | Source code → flame graph mapping for every service and endpoint |
| [faas-server.md](faas-server.md) | FaaS runtime — function deploy/undeploy lifecycle profiling |
| [endpoint-reference.md](endpoint-reference.md) | Complete endpoint list with curl examples for all 9 services |
| [pipeline.md](pipeline.md) | Pipeline stages (deploy, load, validate, teardown) and configuration |
| [sample-queries.md](sample-queries.md) | Copy-paste queries for Pyroscope, Prometheus, and Grafana |

---

## FaaS BOR/SOR Functions

The `services/` directory contains FaaS profiling analysis functions built on Vert.x. Two JVM targets: `faas-jvm11/` (Phase 1) and `faas-jvm21/` (Phase 2).

| Document | Description |
|----------|-------------|
| [function-reference.md](function-reference.md) | BOR function API reference — triage, diff report, fleet search |
| [function-architecture.md](function-architecture.md) | Project structure, design patterns, Gradle multi-project build |
| [profiling-functions-phase1.md](profiling-functions-phase1.md) | Phase 1: 3 BOR + 1 SOR, no database |
| [profiling-functions-phase2.md](profiling-functions-phase2.md) | Phase 2: v2 BORs + 4 PostgreSQL-backed SORs |
| [production-questionnaire.md](production-questionnaire.md) | Production onboarding questionnaires (links to Phase 1 + Phase 2) |
| [production-questionnaire-phase1.md](production-questionnaire-phase1.md) | Phase 1 questionnaire — volume estimates, deployment config, testing |
| [production-questionnaire-phase2.md](production-questionnaire-phase2.md) | Phase 2 questionnaire — PostgreSQL SORs, upgrade path, test coverage |

---

## Grafana and Dashboards

| Document | Description |
|----------|-------------|
| [dashboard-guide.md](dashboard-guide.md) | Panel-by-panel reference for all 6 Grafana dashboards |
| [grafana-setup.md](grafana-setup.md) | Connecting Grafana to Pyroscope via provisioning files |
| [deploy/grafana/README.md](../deploy/grafana/README.md) | Standalone Grafana image build |
| [deploy/observability/README.md](../deploy/observability/README.md) | Unified Pyroscope + Grafana deployment (VM, local, K8s, OpenShift) |
| [deploy/observability/ansible/README.md](../deploy/observability/ansible/README.md) | Ansible role for Pyroscope + Grafana on enterprise VMs |
| [observability-deployment-guide.md](observability-deployment-guide.md) | Decision flowcharts, mind map, and step-by-step deployment recipes |

---

## Deployment

| Document | Description |
|----------|-------------|
| [monolithic-deployment-guide.md](monolithic-deployment-guide.md) | Pyroscope monolithic deployment — mind map and decision guide |
| [observability-deployment-guide.md](observability-deployment-guide.md) | Observability stack decision flowcharts, mind map, and step-by-step recipes |
| [deploy/monolithic/README.md](../deploy/monolithic/README.md) | Single-node Pyroscope server (VM/EC2) — 4 deployment options |
| [deploy/observability/README.md](../deploy/observability/README.md) | Unified Pyroscope + Grafana: add-to-existing or full-stack (HTTP/HTTPS, air-gapped) |
| [deploy/observability/ansible/README.md](../deploy/observability/ansible/README.md) | Ansible role for enterprise VMs (TLS, skip-grafana, image loading) |
| [deploy/microservices/README.md](../deploy/microservices/README.md) | Distributed Pyroscope deployment (VM + OpenShift) |

---

## Operations

| Document | Description |
|----------|-------------|
| [continuous-profiling-runbook.md](continuous-profiling-runbook.md) | Deploying Pyroscope, agent configuration, Grafana integration |
| [runbook.md](runbook.md) | Incident response playbooks and operational procedures |
| [mttr-guide.md](mttr-guide.md) | MTTR reduction workflow and bottleneck decision matrix |

---

## Strategy and Roadmap

| Document | Description |
|----------|-------------|
| [continuous-profiling-rfc.md](continuous-profiling-rfc.md) | RFC for adopting continuous profiling with Grafana Pyroscope |
| [ai-profiling-roadmap.md](ai-profiling-roadmap.md) | Roadmap for AI/ML integration with profiling data |

---

## Learning Paths

### "I want to demo Pyroscope to my team"
1. [demo-guide.md](demo-guide.md) — understand what to show
2. [reading-flame-graphs.md](reading-flame-graphs.md) — learn to read flame graphs
3. [demo-runbook.md](demo-runbook.md) — follow the step-by-step agenda
4. [dashboard-guide.md](dashboard-guide.md) — know which Grafana panels to highlight

### "I want to deploy Pyroscope in production"
1. [continuous-profiling-rfc.md](continuous-profiling-rfc.md) — get buy-in from leadership
2. [monolithic-deployment-guide.md](monolithic-deployment-guide.md) — choose deployment option
3. [observability-deployment-guide.md](observability-deployment-guide.md) — decision flowcharts (HTTP vs HTTPS, bash vs Ansible, air-gapped)
4. [deploy/observability/README.md](../deploy/observability/README.md) — deploy via bash script (VM, K8s, OpenShift)
5. [deploy/observability/ansible/README.md](../deploy/observability/ansible/README.md) — deploy via Ansible (enterprise VMs)
6. [grafana-setup.md](grafana-setup.md) — connect Grafana
7. [runbook.md](runbook.md) — set up incident response

### "I want to build FaaS profiling functions"
1. [function-reference.md](function-reference.md) — understand the 3 BOR functions
2. [function-architecture.md](function-architecture.md) — learn the project structure
3. [profiling-functions-phase1.md](profiling-functions-phase1.md) — start with Phase 1 (no database)
4. [profiling-functions-phase2.md](profiling-functions-phase2.md) — add Phase 2 (PostgreSQL SORs)
5. [production-questionnaire.md](production-questionnaire.md) — production onboarding

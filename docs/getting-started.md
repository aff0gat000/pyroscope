# Getting Started

Day-one orientation for new team members — what this project is, key terminology,
environment setup, and where to go next based on your role.

---

## What This Project Is

This repository contains the deployment code, analysis functions, and documentation
for a continuous profiling platform based on Grafana Pyroscope. The platform collects
function-level performance data from Java services running on OpenShift Container
Platform (OCP) 4.12, enabling engineers to identify CPU hotspots, memory allocation
issues, and lock contention in production without code changes.

See [what-is-pyroscope.md](what-is-pyroscope.md) for the full business case.
See [adr/ADR-001-continuous-profiling.md](adr/ADR-001-continuous-profiling.md) for why we chose this architecture.

---

## Glossary

| Term | Definition |
|------|------------|
| **ADR** | Architecture Decision Record — immutable record of a technical decision and its rationale |
| **AGPL-3.0** | Affero General Public License — Pyroscope's open-source license; free for internal deployment |
| **APM** | Application Performance Monitoring — commercial platforms (Datadog, Dynatrace, New Relic) |
| **BOR** | Business Object Rules — business logic layer in the FaaS function architecture (Triage, Diff Report, Fleet Search) |
| **Burn rate** | Rate of error budget consumption relative to budget period. 1x = budget consumed at window end. 10x = exhausted in 1/10 of window. See [sla-slo.md](sla-slo.md). |
| **CA** | Certificate Authority — issues TLS certificates for HTTPS |
| **CAB** | Change Advisory Board — approves production changes in enterprise environments |
| **CNCF** | Cloud Native Computing Foundation — stewards Kubernetes, Prometheus, and other projects |
| **Compactor** | Pyroscope component that merges and deduplicates storage blocks and enforces retention |
| **Continuous profiling** | Always-on, low-overhead sampling of application code at the function level in production |
| **Cardinality** | Number of unique values a label can take. High cardinality (request IDs) causes storage explosion. Low cardinality (function names) is safe. |
| **Dead man's switch** | Alerting pattern where a continuously-firing alert (Watchdog) is expected by an external system. Absence of the alert indicates monitoring failure. |
| **Diataxis** | Documentation framework with four quadrants: Tutorial, How-to, Explanation, Reference |
| **Distributor** | Pyroscope component that receives profiles from agents and routes them to ingesters |
| **Envoy** | Reverse proxy used for TLS termination in front of Pyroscope |
| **Error budget** | Maximum acceptable unreliability over a measurement window. Calculated as `(1 - SLO) x window`. Consumed by outages and maintenance. See [sla-slo.md](sla-slo.md). |
| **FaaS** | Function-as-a-Service — lightweight runtime for deploying analysis functions |
| **FIPS** | Federal Information Processing Standards — cryptographic compliance requirement (140-2/140-3) |
| **Flame graph** | Visualization where bar width represents time spent in a function; wider = more time = optimize here |
| **Flamebearer** | Pyroscope's internal JSON format for profile and flame graph data |
| **GC** | Garbage Collection — JVM automatic memory management; high GC = memory pressure |
| **HA** | High Availability — redundant deployment to survive component failures |
| **Ingester** | Pyroscope component that writes incoming profiles to storage |
| **JFR** | Java Flight Recorder — built-in JVM profiling engine (JDK 11+); used by the Pyroscope agent |
| **JVM** | Java Virtual Machine — runtime for Java, Kotlin, Scala, and other JVM languages |
| **Liveness probe** | Health check determining if a process is alive. Failure triggers container restart. Last resort — not for transient slowness. |
| **Memberlist** | Hashicorp gossip protocol used by Pyroscope microservices for hash ring coordination |
| **MTTD** | Mean Time to Detect — average time from failure start to detection by monitoring or humans |
| **Monolith mode** | Single-process Pyroscope deployment; supports up to ~100 profiled services |
| **Microservices mode** | 7-component Pyroscope deployment; supports 100+ services with HA and horizontal scaling |
| **MTTR** | Mean Time To Resolution — average time from incident detection to root cause identification |
| **Object storage** | S3-compatible storage backend (MinIO, AWS S3, GCS, Azure Blob) used by multi-VM monolith (Phase 2) and microservices (Phase 3) modes |
| **Observability** | Ability to understand a system's internal state from its external outputs (metrics, logs, traces, profiles). Distinguished from monitoring by ability to answer novel questions. |
| **OCP** | OpenShift Container Platform — Red Hat's enterprise Kubernetes distribution |
| **OTel** | OpenTelemetry — open-source observability framework for metrics, traces, logs (profiling signal emerging) |
| **pbrun** | PowerBroker run — enterprise privilege escalation tool (similar to sudo) |
| **PVC** | PersistentVolumeClaim — Kubernetes storage request |
| **Querier** | Pyroscope component that executes profile queries |
| **Readiness probe** | Health check determining if a service instance can accept traffic. Failure removes it from load balancer but does NOT restart it. |
| **Retention** | Duration for which profiling data is stored before purging. Shorter = less storage; longer = wider historical comparison. |
| **RPO** | Recovery Point Objective — maximum acceptable data loss measured in time (e.g., RPO of 2 min = up to 2 min of data may be lost) |
| **RTO** | Recovery Time Objective — maximum acceptable time to restore service after a failure |
| **RWX** | ReadWriteMany — Kubernetes storage access mode; microservices mode uses S3-compatible object storage instead of RWX PVCs |
| **SLA** | Service Level Agreement — formal contract specifying expected service level and consequences of non-compliance. External-facing and binding. |
| **SLI** | Service Level Indicator — quantitative metric measuring a specific aspect of service (latency, error rate, availability). The raw data SLOs are defined against. |
| **SLO** | Service Level Objective — internal target for service reliability, expressed as percentage of an SLI over a time window (e.g., "99% of queries < 5s over 30 days"). |
| **SOR** | System of Record — data access layer in the FaaS function architecture; wraps Pyroscope API |
| **Synthetic monitoring** | Automated, periodic execution of predefined checks against a service to verify end-to-end functionality from the client perspective. |
| **TLS** | Transport Layer Security — encryption for data in transit (HTTPS) |
| **Toil** | Repetitive, manual, automatable work tied to running a production service. Google SRE targets < 50% of SRE time on toil. |
| **Verticle** | Vert.x unit of deployment — each FaaS function runs as a separate Verticle |
| **WAL** | Write-Ahead Log — crash recovery mechanism; profiles are written to WAL before storage |

---

## Environment Setup

### Required Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Docker | 20.10+ | Container runtime for Pyroscope server and workloads |
| Java (JDK) | 21 | Build and test FaaS functions (services/ directory). Java 11 modules compile with JDK 11 or 21 |
| Gradle | 7.6.4 | Build tool (wrapper included at `services/gradlew`) |
| curl | Any | Health checks and API verification |
| jq | Any | JSON output formatting (optional but recommended) |
| Helm | 3.x | OCP/K8s chart deployments (if applicable) |
| Ansible | 2.9+ | Automated VM deployments (if applicable) |

### Repository Structure

```
pyroscope/
├── services/                  # Gradle multi-project build (FaaS functions)
│   ├── faas-jvm11/bor/        #   BOR functions targeting JVM 11
│   ├── faas-jvm11/sor/        #   SOR functions targeting JVM 11
│   ├── faas-jvm21/bor/        #   BOR functions targeting JVM 21
│   ├── faas-jvm21/sor/        #   SOR functions targeting JVM 21
│   └── gradlew                #   Shared Gradle wrapper
├── deploy/                    # Deployment code
│   ├── monolith/              #   VM deployment (deploy.sh, Ansible, Dockerfile)
│   ├── microservices/         #   Distributed deployment (Docker Compose, VM)
│   ├── helm/pyroscope/        #   Unified Helm chart (OCP + K8s)
│   ├── grafana/               #   Standalone Grafana build
│   └── profiling-workload/    #   Test workload for validating Pyroscope
├── docs/                      # Documentation (Diataxis framework)
│   ├── adr/                   #   Architecture Decision Records
│   └── templates/             #   Change management templates
├── config/                    # Configuration files
│   ├── pyroscope/             #   Pyroscope server config (pyroscope.yaml)
│   ├── grafana/               #   Grafana dashboards and provisioning
│   └── prometheus/            #   Prometheus scrape config and alert rules
└── scripts/                   # Utility scripts (validate.sh, run.sh)
```

See [function-architecture.md](function-architecture.md) for detailed `services/` project structure.

---

## Reading Path by Role

Start with this document, then follow the path for your role.

| Role | Start With | Then Read |
|------|-----------|-----------|
| Leadership / project management | [what-is-pyroscope.md](what-is-pyroscope.md) | [project-plan-phase1.md](project-plan-phase1.md), [adr/ADR-001-continuous-profiling.md](adr/ADR-001-continuous-profiling.md) |
| Operators / SREs | [deployment-guide.md](deployment-guide.md) | [architecture.md](architecture.md), [monitoring-guide.md](monitoring-guide.md), [troubleshooting.md](troubleshooting.md) |
| Developers | [reading-flame-graphs.md](reading-flame-graphs.md) | profiling-scenarios.md (available in the repo at docs/profiling-scenarios.md), sample-queries.md (available in the repo at docs/sample-queries.md) |
| FaaS function developers | [function-reference.md](function-reference.md) | [function-architecture.md](function-architecture.md), [production-questionnaire-phase1.md](production-questionnaire-phase1.md) |
| Governance / change managers | [security-model.md](security-model.md) | [sla-slo.md](sla-slo.md), [templates/change-request.md](templates/change-request.md) |

See INDEX.md (available in the repo at docs/INDEX.md) for the complete documentation index with audience-specific reading paths.

---

## Team Contacts and Escalation

> **Note:** Fill in the names and contact methods for your team.

| Role | Name | Contact | Escalation Scenario |
|------|------|---------|---------------------|
| Project owner | _TBD_ | _TBD_ | Business decisions, Phase 2/3 approval |
| Technical lead | _TBD_ | _TBD_ | Architecture questions, security review |
| On-call SRE | _TBD / rotation_ | _TBD_ | Pyroscope server down, infrastructure issues |
| OCP platform team | _TBD_ | _TBD_ | Namespace, NetworkPolicy, storage issues |
| Change advisory board | _TBD_ | _TBD_ | Production change approval |

See [sla-slo.md](sla-slo.md) for the full escalation matrix.

---

## Quick Start (5 Minutes)

Verify your environment can build and test the FaaS functions:

```bash
# Clone the repository
git clone <repo-url> && cd pyroscope

# Build and run a quick test (no Docker required)
cd services && ./gradlew :faas-jvm11:bor:test --tests '*ProfileTypeTest*'

# Verify documentation is complete
ls docs/*.md | wc -l
# Expected: 30+ files
```

See workflow.md (available in the repo at docs/workflow.md) for the development workflow and contribution guidelines.
See demo-runbook.md (available in the repo at docs/demo-runbook.md) for a guided 20-minute Pyroscope demo.

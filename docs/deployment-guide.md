# Pyroscope Deployment Guide

Comprehensive guide covering every deployment scenario for Pyroscope continuous profiling:
monolith mode, microservices mode, sample apps, Java agent integration, VM, Kubernetes,
OpenShift, Docker Compose, TLS, air-gapped, and Ansible automation.

---

## Table of Contents

- **Part 1: Decision Trees** -- [1. What are you deploying?](#1-what-are-you-deploying) | [2. Server mode](#2-pyroscope-server-mode) | [3. Grafana integration](#3-grafana-integration) | [4. Environment and method](#4-environment-and-deployment-method) | [5. Enterprise concerns](#5-enterprise-concerns) | [5b. FIPS compliance](#5b-fips-140-2--140-3-compliance-future) | [6. OpenShift Container Platform](#6-openshift-container-platform) | [7-tree. Hybrid topology](#7-tree-hybrid-topology-vm-pyroscope--ocp-agents)
- **Part 2: Quick Reference** -- [6a. Monolith](#6a-monolith-quick-reference) | [6b. Microservices](#6b-microservices-quick-reference) | [6c. Sample apps](#6c-sample-apps-and-agent-instrumentation-quick-reference)
- **Part 3: Pyroscope Server** -- [SSH config](#ssh-configuration) | [HTTP vs HTTPS config](#pyroscope-server-configuration-http-vs-https) | [7. Manual VM](#7-monolith-manual-vm-deployment) | [8. Bash script](#8-monolith-bash-script-on-vm) | [9. Ansible](#9-monolith-ansible-on-vm) | [10. K8s/OpenShift](#10-monolith-kubernetes-and-openshift) | [11. Local Compose](#11-monolith-local-docker-compose) | [12. Microservices](#12-microservices-mode)
- **Part 4: Sample Apps** -- [13. Microservices demo](#13-microservices-demo-bank-app) | [14. FaaS runtime demo](#14-faas-runtime-demo)
- **Part 5: Agent Instrumentation** -- [15. Agent instrumentation](#15-agent-instrumentation)
- **Part 6: Reference** -- [16. TLS architecture](#16-tls-architecture) | [17. Port reference](#17-port-reference) | [17a-e. Firewall rules](#17a-firewall-rules-monolith-on-vm-http) | [18. Day-2 operations](#18-day-2-operations) | [19. File map](#19-file-map) | [20. Troubleshooting](#20-troubleshooting-no-data-in-pyroscope-ui)

---

# Part 1: Decision Trees

## 1. What are you deploying?

```mermaid
graph TD
    A{What are you deploying?} -->|Pyroscope server<br/>profiling backend| B{Sample workloads?}
    A -->|Agent instrumentation<br/>Pyroscope already running| F["Add agent to existing JVMs<br/>Section 15"]

    B -->|Server only| C["Deploy Pyroscope server<br/>Tree 2"]
    B -->|"Microservices demo<br/>9 services · 1 JVM per container"| D["docker compose up -d<br/>Tree 2 → Section 13"]
    B -->|"FaaS runtime demo<br/>1 JVM · dynamic function verticles"| E["docker compose up -d faas-server pyroscope<br/>Tree 2 → Section 14"]
```

| Scenario | Architecture | What you get | Next step |
|----------|-------------|--------------|-----------|
| **Pyroscope server only** | — | Profiling backend (monolith or microservices) | [Tree 2: Choose server mode](#2-pyroscope-server-mode) → [Tree 3: Grafana](#3-grafana-integration) → [Tree 4: Environment](#4-environment-and-deployment-method) |
| **Microservices demo** | Service-per-container (9 JVMs) | Bank app + Pyroscope + Prometheus + Grafana | [Tree 2](#2-pyroscope-server-mode) → [Section 13](#13-microservices-demo-bank-app): `docker compose up -d` |
| **FaaS runtime demo** | Single-JVM function host | FaaS server + Pyroscope (11 built-in functions) | [Tree 2](#2-pyroscope-server-mode) → [Section 14](#14-faas-runtime-demo): `docker compose up -d faas-server pyroscope` |
| **Agent instrumentation** | Any (monolith, microservices, FaaS, batch) | Pyroscope Java agent in existing JVMs | [Section 15](#15-agent-instrumentation): `JAVA_TOOL_OPTIONS="-javaagent:pyroscope.jar"` |

---

## 2. Pyroscope server mode

```mermaid
graph TD
    A{How many apps<br/>sending profiles?} -->|"< 100 apps<br/>simpler setup"| B["<b>Monolith</b><br/>Single process"]
    A -->|"> 100 apps<br/>need HA"| C["<b>Microservices</b><br/>9 distributed components<br/>Needs RWX storage (NFS)"]
```

| Outcome | Go to |
|---------|-------|
| Monolith -- single process, simple operations | Sections [7](#7-monolith-manual-vm-deployment) - [11](#11-monolith-local-docker-compose) |
| Microservices -- 9 components, HA, NFS required | [Section 12: Microservices mode](#12-microservices-mode) |

---

## 3. Grafana integration

```mermaid
graph TD
    A{Grafana integration?} -->|Pyroscope only<br/>no Grafana| B["<b>--skip-grafana</b><br/>No Grafana container deployed"]
    A -->|Fresh Grafana<br/>alongside Pyroscope| C["<b>full-stack</b> (default)<br/>Pyroscope + Grafana with dashboards"]
    A -->|Add to existing Grafana| D{Method?}

    D -->|API - no restart| E["<b>add-to-existing --method api</b><br/>Installs plugin, datasource, dashboards"]
    D -->|File provisioning - needs restart| F["<b>add-to-existing --method provisioning</b><br/>Writes YAML + JSON to Grafana dirs"]
```

| Outcome | Where to find it |
|---------|-----------------|
| Pyroscope only (`--skip-grafana`) | [Section 7b](#7b-http-pyroscope-only), [Section 8b](#8b-deploysh-examples) |
| Full stack (Pyroscope + fresh Grafana) | [Section 7a](#7a-http-with-grafana-full-stack), [Section 8b](#8b-deploysh-examples) |
| Add to existing Grafana (API) | [Section 8b](#8b-deploysh-examples) (`add-to-existing --method api`) |
| Add to existing Grafana (provisioning) | [Section 8b](#8b-deploysh-examples) (`add-to-existing --method provisioning`) |

---

## 4. Environment and deployment method

```mermaid
graph TD
    A{Server mode?} -->|Monolith| B{Environment?}
    A -->|Microservices| C{Environment?}

    B -->|VM / bare metal| D{Deployment method?}
    B -->|Kubernetes| E["bash deploy.sh full-stack --target k8s"]
    B -->|OpenShift| F["bash deploy.sh full-stack --target openshift"]
    B -->|Local dev| G["bash deploy.sh full-stack --target local"]

    D -->|Manual docker CLI| H["Manual: docker run<br/>Section 7"]
    D -->|Bash script| I["bash deploy.sh<br/>Section 8"]
    D -->|Ansible role| J["ansible-playbook<br/>Section 9"]

    C -->|VM / Docker Compose| K["cd deploy/microservices/vm<br/>bash deploy.sh"]
    C -->|Kubernetes| L["helm install pyroscope deploy/helm/pyroscope/<br/>-f examples/microservices-kubernetes.yaml"]
    C -->|OpenShift| M["helm install pyroscope deploy/helm/pyroscope/<br/>-f examples/microservices-openshift.yaml"]
```

| Mode | Environment | Method | Command | Guide |
|------|-------------|--------|---------|-------|
| Monolith | VM | Manual | `docker run -d --name pyroscope --network host -v pyroscope-data:/data grafana/pyroscope:1.18.0` | [Section 7](#7-monolith-manual-vm-deployment) |
| Monolith | VM | Bash script | `bash deploy.sh full-stack --target vm` | [Section 8](#8-monolith-bash-script-on-vm) |
| Monolith | VM | Ansible | `ansible-playbook -i inventory playbooks/deploy.yml` | [Section 9](#9-monolith-ansible-on-vm) |
| Monolith | Kubernetes | Bash script | `bash deploy.sh full-stack --target k8s --namespace monitoring` | [Section 10a](#10a-kubernetes-with-kubectl) |
| Monolith | OpenShift | Helm | `helm upgrade --install pyroscope deploy/helm/pyroscope/ -n monitoring -f examples/monolith-same-namespace.yaml` | [Section 10b](#10b-openshift-with-helm) |
| Monolith | Local dev | Bash script | `bash deploy.sh full-stack --target local` | [Section 11](#11-monolith-local-docker-compose) |
| Microservices | VM | Docker Compose | `cd deploy/microservices/vm && bash deploy.sh` | [Section 12a](#12a-vm-with-docker-compose) |
| Microservices | Kubernetes | Helm | `helm upgrade --install pyroscope deploy/helm/pyroscope/ -n pyroscope --create-namespace -f examples/microservices-kubernetes.yaml` | [Section 12b](#12b-kubernetes) |
| Microservices | OpenShift | Helm | `helm upgrade --install pyroscope deploy/helm/pyroscope/ -n pyroscope --create-namespace -f examples/microservices-openshift.yaml` | [Section 12c](#12c-openshift) |

> **Note:** Ansible is supported for VM deployments only. Kubernetes and OpenShift have native
> tooling (kubectl, Helm, GitOps) that is more appropriate than wrapping in Ansible modules.

---

## 5. Enterprise concerns

```mermaid
graph TD
    A{Enterprise concern?} -->|Image source| B{Can target pull<br/>from Docker Hub?}
    A -->|TLS / HTTPS| C{Have CA certs?}
    A -->|Cross-platform build| D{Workstation arch?}

    B -->|Yes| B1["Pull directly<br/>docker pull grafana/pyroscope:1.18.0"]
    B -->|Internal registry| B2["Push to registry first<br/>bash build-and-push.sh --push"]
    B -->|Air-gapped| B3["Save + scp + load<br/>bash deploy.sh save-images"]

    C -->|No TLS needed| C1["HTTP (default)<br/>No extra flags"]
    C -->|Self-signed| C2["--tls --tls-self-signed<br/>Auto-generated cert"]
    C -->|Enterprise CA certs| C3["--tls --tls-cert ... --tls-key ..."]

    D -->|Linux x86_64 / Mac Intel| D1["docker build as normal"]
    D -->|Mac Apple Silicon| D2["--platform linux/amd64"]
```

| Concern | Outcome | Where |
|---------|---------|-------|
| Docker Hub direct pull | Default -- no special flags | [Section 7a](#7a-http-with-grafana-full-stack) |
| Push to internal registry | `bash build-and-push.sh --version 1.18.0 --push` | [DOCKER-BUILD.md](../deploy/monolith/DOCKER-BUILD.md) |
| Air-gapped (save/load) | `bash deploy.sh save-images` then `--load-images` | [Section 8a](#8a-ssh-with-pbrun-workflow) |
| HTTP (default) | No TLS flags | [Section 7a](#7a-http-with-grafana-full-stack) |
| HTTPS self-signed | `--tls --tls-self-signed` | [Section 7c](#7c-https-with-self-signed-cert) |
| HTTPS CA certs | `--tls --tls-cert cert.pem --tls-key key.pem` | [Section 7d](#7d-https-with-ca-certs) |
| Cross-platform (Mac ARM to Linux) | `--platform linux/amd64` | [DOCKER-BUILD.md](../deploy/monolith/DOCKER-BUILD.md) |

### 5b. FIPS 140-2 / 140-3 compliance (future)

If your organization requires FIPS-validated cryptographic modules, Pyroscope must be
compiled with a FIPS-compliant crypto backend. The standard Go crypto library is **not**
FIPS-validated.

```mermaid
graph TD
    A{FIPS requirement?} -->|No| B["Use upstream image<br/>grafana/pyroscope:1.18.0"]
    A -->|Yes| C{Build strategy?}

    C -->|"Go BoringCrypto<br/>(most common)"| D["GOEXPERIMENT=boringcrypto<br/>Statically links BoringSSL"]
    C -->|"Red Hat Go Toolset<br/>(OpenSSL-backed)"| E["ubi8/go-toolset base<br/>Links system OpenSSL via dlopen"]
    C -->|"Go 1.24+ native<br/>(newest)"| F["GOFIPS140=latest<br/>Built-in validated module"]
```

| Strategy | Go version | Crypto backend | Image overhead | Notes |
|----------|-----------|---------------|---------------|-------|
| **BoringCrypto** | 1.19+ | BoringSSL (Google, FIPS 140-2 #4407) | ~8 MB larger binary | Most widely adopted; static linking |
| **Red Hat Go Toolset** | RHEL-shipped | System OpenSSL (Red Hat, FIPS 140-2 #4282) | Requires UBI base | Dynamic linking; auto-FIPS when OS is in FIPS mode |
| **Go native FIPS** | 1.24+ | Go stdlib FIPS module (140-3 pending) | Minimal | Newest; validation still in progress |

#### Dockerfile: BoringCrypto build

```dockerfile
# Stage 1: Build Pyroscope from source with FIPS crypto
FROM golang:1.22-bookworm AS builder
ARG PYROSCOPE_VERSION=v1.18.0

RUN git clone --depth 1 --branch ${PYROSCOPE_VERSION} \
      https://github.com/grafana/pyroscope.git /src
WORKDIR /src

# Enable BoringCrypto — swaps Go crypto with FIPS-validated BoringSSL
ENV GOEXPERIMENT=boringcrypto
RUN go build -tags requires_cgo -o /pyroscope ./cmd/pyroscope

# Stage 2: Minimal runtime
FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=builder /pyroscope /usr/bin/pyroscope
ENTRYPOINT ["/usr/bin/pyroscope"]
```

#### Dockerfile: Red Hat Go Toolset build (UBI)

```dockerfile
FROM registry.access.redhat.com/ubi8/go-toolset:1.21 AS builder
ARG PYROSCOPE_VERSION=v1.18.0

RUN git clone --depth 1 --branch ${PYROSCOPE_VERSION} \
      https://github.com/grafana/pyroscope.git /tmp/src
WORKDIR /tmp/src

# Red Hat Go Toolset patches Go to use OpenSSL; FIPS mode inherited from OS
RUN go build -o /tmp/pyroscope ./cmd/pyroscope

FROM registry.access.redhat.com/ubi8/ubi-micro:latest
COPY --from=builder /tmp/pyroscope /usr/bin/pyroscope
USER 65534
ENTRYPOINT ["/usr/bin/pyroscope"]
```

#### Verifying FIPS mode

```bash
# Check OCP cluster FIPS mode
oc debug node/$(oc get nodes -o jsonpath='{.items[0].metadata.name}') \
    -- chroot /host fips-mode-setup --check

# Verify binary uses BoringCrypto (look for "boringcrypto" in symbols)
go tool nm pyroscope | grep -i boring

# Verify at runtime (Go BoringCrypto sets this)
curl -s http://localhost:4040/debug/vars | grep -i fips
```

#### FIPS compliance layers

| Layer | Responsible party | How |
|-------|------------------|-----|
| **OS / node crypto** | OCP cluster admin | Install OCP with `fips: true` in install-config.yaml |
| **TLS termination** | OCP Route / Envoy | Inherits node OpenSSL (FIPS-validated on FIPS nodes) |
| **Application binary** | Image builder | Compile with BoringCrypto or Red Hat Go Toolset |
| **Storage at rest** | Storage admin | FIPS-validated encryption at storage class level |
| **Pod-to-pod traffic** | Service mesh | OpenShift Service Mesh / Istio mTLS with FIPS crypto |

> **Note:** FIPS compliance is a future consideration. The upstream `grafana/pyroscope` image
> works correctly for non-FIPS deployments. Only build a custom FIPS image if your compliance
> framework explicitly requires FIPS 140-2/3 validated crypto modules.

---

## 6. OpenShift Container Platform

Decision trees for deploying Pyroscope on OCP 4.12+ using the unified Helm chart at `deploy/helm/pyroscope/`.

### 6a-ocp. Server mode and namespace

```mermaid
graph TD
    A{Server mode?} -->|"Monolith<br/>< 100 apps"| B{Namespace strategy?}
    A -->|"Microservices<br/>> 100 apps, HA"| C{RWX storage available?}

    B -->|Same namespace as apps| D["helm upgrade --install pyroscope deploy/helm/pyroscope/<br/>-n APP_NS -f examples/monolith-same-namespace.yaml<br/>Section 10b"]
    B -->|Dedicated namespace| E{NetworkPolicy enforced?}

    E -->|No| F["helm upgrade --install pyroscope deploy/helm/pyroscope/<br/>-n pyroscope --create-namespace<br/>-f examples/monolith-dedicated-namespace.yaml<br/>Section 10b"]
    E -->|Yes| G["Edit allowedNamespaces in values file<br/>helm upgrade --install ... -f monolith-dedicated-namespace.yaml<br/>Section 10b"]

    C -->|Yes| H["helm upgrade --install pyroscope deploy/helm/pyroscope/<br/>-n pyroscope --create-namespace<br/>-f examples/microservices-openshift.yaml<br/>Section 12c"]
    C -->|No| I["Set up NFS provisioner first<br/>then return here"]
```

| Scenario | Example values file | Agent target URL |
|----------|-------------------|-----------------|
| Monolith, same namespace | `monolith-same-namespace.yaml` | `http://pyroscope.<namespace>.svc:4040` |
| Monolith, dedicated namespace | `monolith-dedicated-namespace.yaml` | `http://pyroscope.pyroscope.svc:4040` |
| Microservices, dedicated namespace | `microservices-openshift.yaml` | `http://pyroscope-distributor.pyroscope.svc:4040` |

### 6b-ocp. Agent configuration

```mermaid
graph TD
    A{How does the Pyroscope agent<br/>get the server address?} -->|Properties file<br/>baked into image| B["Set in pyroscope.properties during image build:<br/>pyroscope.server.address=http://pyroscope.NS.svc:4040"]
    A -->|Environment variable<br/>in Deployment/DeploymentConfig| C["Set in pod spec:<br/>PYROSCOPE_SERVER_ADDRESS=http://pyroscope.NS.svc:4040"]
    A -->|Init container<br/>agent JAR not in image| D["See Section 15f:<br/>Kubernetes init container pattern"]
```

### 6c-ocp. Grafana integration

```mermaid
graph TD
    A{Where is Grafana?} -->|Same OCP cluster<br/>different namespace| B["Datasource URL:<br/>http://pyroscope.PYROSCOPE_NS.svc.cluster.local:4040"]
    A -->|External<br/>outside OCP| C["Datasource URL:<br/>https://ROUTE_HOSTNAME<br/>oc get route pyroscope -n PYROSCOPE_NS"]
    A -->|Not deployed yet| D["Use Pyroscope built-in UI:<br/>https://ROUTE_HOSTNAME"]
```

---

## 7-tree. Hybrid topology: VM Pyroscope + OCP agents

For deployments where Pyroscope runs on a VM (outside OCP) and receives profiling data
from Java agents running inside an OCP cluster, with Grafana and Prometheus on separate VMs.

### Architecture diagram

```mermaid
graph TB
    subgraph OCP["OCP 4.12 Cluster"]
        subgraph NS["App Namespace"]
            FaaS["Vert.x FaaS Pod<br/>Java agent → pyroscope.jar<br/>pushes to VM:4040"]
        end
    end

    subgraph PyroVM["Pyroscope VM"]
        P[":4040 Pyroscope<br/>monolith mode"]
    end

    subgraph GrafVM["Grafana VM"]
        G[":3000 Grafana<br/>pyroscope datasource"]
    end

    subgraph PromVM["Prometheus VM"]
        PR[":9090 Prometheus<br/>scrapes /metrics"]
    end

    FaaS -->|"HTTP POST /ingest<br/>TCP 4040"| P
    G -->|"HTTP GET /querier.v1.*<br/>TCP 4040"| P
    PR -->|"HTTP GET /metrics<br/>TCP 4040"| P
    G -->|"PromQL queries<br/>TCP 9090"| PR
```

### Decision tree

```mermaid
graph TD
    A{Where is Pyroscope?} -->|"VM (container)<br/>outside OCP"| B{Grafana location?}

    B -->|"Separate VM<br/>(existing Grafana)"| C{Prometheus?}
    B -->|"Same VM as Pyroscope"| D["Deploy full-stack on VM<br/>Section 7a"]

    C -->|"Separate VM<br/>(existing Prometheus)"| E["1. Deploy Pyroscope on VM → Section 7b<br/>2. Add datasource to Grafana → Section 6a quick ref<br/>3. Add scrape target to Prometheus<br/>4. Configure agent in OCP pods → Section 15"]
    C -->|No Prometheus| F["1. Deploy Pyroscope on VM → Section 7b<br/>2. Add datasource to Grafana → Section 6a quick ref<br/>3. Configure agent in OCP pods → Section 15"]
```

### Step-by-step: VM Pyroscope + OCP agents + existing Grafana/Prometheus

**Phase 1 — Deploy Pyroscope on VM** (use [Section 7b](#7b-http-pyroscope-only) or [Section 8](#8-monolith-bash-script-on-vm)):

```bash
# On the Pyroscope VM
docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    grafana/pyroscope:1.18.0

# Verify
curl -s http://localhost:4040/ready
# Expected: ready
```

**Phase 2 — Configure Java agent in OCP pods:**

The agent JAR is already baked into your Vert.x FaaS image. Configure the server address
to point to the Pyroscope VM. Use either a properties file or environment variable:

*Option A: Properties file (baked into image during build)*
```properties
# pyroscope.properties
pyroscope.server.address=http://PYROSCOPE_VM_IP:4040
pyroscope.application.name=vertx-faas-server
pyroscope.format=jfr
pyroscope.labels=env=production,namespace=APP_NS
pyroscope.log.level=info
```

*Option B: Environment variable in DeploymentConfig/Deployment*
```yaml
env:
  - name: PYROSCOPE_SERVER_ADDRESS
    value: "http://PYROSCOPE_VM_IP:4040"
  - name: PYROSCOPE_APPLICATION_NAME
    value: "vertx-faas-server"
  - name: PYROSCOPE_LOG_LEVEL
    value: "info"
```

> **Key:** Replace `PYROSCOPE_VM_IP` with the actual IP or hostname of the Pyroscope VM
> reachable from OCP worker nodes.

**Phase 3 — Add Pyroscope datasource to existing Grafana:**

```bash
# On the Grafana VM — add via API
curl -s -X POST http://localhost:3000/api/datasources \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer YOUR_GRAFANA_API_KEY" \
    -d '{
      "name": "Pyroscope",
      "type": "grafana-pyroscope-datasource",
      "uid": "pyroscope-ds",
      "access": "proxy",
      "url": "http://PYROSCOPE_VM_IP:4040",
      "isDefault": false
    }'
```

Or via provisioning file (copy to Grafana's provisioning/datasources/ directory):
```yaml
apiVersion: 1
datasources:
  - name: Pyroscope
    type: grafana-pyroscope-datasource
    uid: pyroscope-ds
    access: proxy
    url: http://PYROSCOPE_VM_IP:4040
    isDefault: false
    editable: true
```

**Phase 4 — Add Pyroscope scrape target to existing Prometheus:**

Add to your `prometheus.yml`:
```yaml
scrape_configs:
  - job_name: "pyroscope"
    static_configs:
      - targets: ["PYROSCOPE_VM_IP:4040"]
```

Reload Prometheus: `curl -X POST http://localhost:9090/-/reload`

### Firewall rules for this topology

See [Section 17: Port reference](#17-port-reference) for the complete firewall matrix.

---

# Part 2: Quick Reference Tables

## 6a. Monolith quick reference

All commands run from `deploy/monolith/` unless otherwise noted.

| I want to... | Command |
|---|---|
| Deploy Pyroscope + Grafana on VM (HTTP) | `bash deploy.sh full-stack --target vm` |
| Deploy Pyroscope + Grafana on VM (HTTP, air-gapped) | `bash deploy.sh full-stack --target vm --load-images /tmp/pyroscope-stack-images.tar` |
| Deploy Pyroscope only on VM (HTTP) | `bash deploy.sh full-stack --target vm --skip-grafana` |
| Deploy Pyroscope only on VM (HTTP, air-gapped) | `bash deploy.sh full-stack --target vm --skip-grafana --load-images /tmp/pyroscope-stack-images.tar` |
| Deploy Pyroscope + Grafana on VM (HTTPS self-signed) | `bash deploy.sh full-stack --target vm --tls --tls-self-signed` |
| Deploy Pyroscope + Grafana on VM (HTTPS self-signed, air-gapped) | `bash deploy.sh full-stack --target vm --tls --tls-self-signed --load-images /tmp/pyroscope-stack-images.tar` |
| Deploy Pyroscope + Grafana on VM (HTTPS CA certs) | `bash deploy.sh full-stack --target vm --tls --tls-cert cert.pem --tls-key key.pem` |
| Deploy Pyroscope only on VM (HTTPS self-signed) | `bash deploy.sh full-stack --target vm --skip-grafana --tls --tls-self-signed` |
| Deploy Pyroscope only on VM (HTTPS CA certs) | `bash deploy.sh full-stack --target vm --skip-grafana --tls --tls-cert cert.pem --tls-key key.pem` |
| Add to existing Grafana via API | `bash deploy.sh add-to-existing --grafana-url http://grafana:3000 --grafana-api-key eyJr... --pyroscope-url http://pyro:4040` |
| Add to existing Grafana via provisioning | `bash deploy.sh add-to-existing --method provisioning --pyroscope-url http://pyro:4040` |
| Deploy via Ansible (HTTP) | `ansible-playbook -i inventory playbooks/deploy.yml` |
| Deploy via Ansible (HTTPS self-signed) | `ansible-playbook -i inventory playbooks/deploy.yml -e tls_enabled=true -e tls_self_signed=true` |
| Deploy via Ansible (HTTPS CA) | `ansible-playbook -i inventory playbooks/deploy.yml -e tls_enabled=true -e tls_cert_src=cert.pem -e tls_key_src=key.pem` |
| Deploy via Ansible (Pyroscope only) | `ansible-playbook -i inventory playbooks/deploy.yml -e skip_grafana=true` |
| Deploy via Ansible (air-gapped) | `ansible-playbook -i inventory playbooks/deploy.yml -e docker_load_path=/tmp/images.tar` |
| Deploy on Kubernetes | `bash deploy.sh full-stack --target k8s --namespace monitoring` |
| Deploy on Kubernetes (custom storage) | `bash deploy.sh full-stack --target k8s --namespace monitoring --storage-class gp3 --pvc-size-pyroscope 50Gi` |
| Deploy on Kubernetes (no PVC, dev) | `bash deploy.sh full-stack --target k8s --namespace monitoring --no-pvc` |
| Deploy on Kubernetes (skip Grafana) | `bash deploy.sh full-stack --target k8s --namespace monitoring --skip-grafana` |
| Deploy on OpenShift | `bash deploy.sh full-stack --target openshift --namespace monitoring` |
| Deploy locally with Docker Compose | `bash deploy.sh full-stack --target local` |
| Deploy with custom Pyroscope image | `bash deploy.sh full-stack --target vm --pyroscope-image pyroscope-server:1.18.0` |
| Deploy with mounted pyroscope.yaml | `bash deploy.sh full-stack --target vm --pyroscope-config /opt/pyroscope/pyroscope.yaml` |
| Save images for air-gapped transfer | `bash deploy.sh save-images` |
| Save images (Pyroscope only, no Grafana) | `bash deploy.sh save-images --skip-grafana` |
| Save images (including Envoy for TLS) | `bash deploy.sh save-images --tls` |
| Build custom image and push to registry | `bash build-and-push.sh --version 1.18.0 --push` |
| Build custom image and save as tar | `bash build-and-push.sh --version 1.18.0 --save` |
| Push stock image to internal registry | `bash build-and-push.sh --version 1.18.0 --pull-only --push` |
| List available Pyroscope versions | `bash build-and-push.sh --list-tags` |
| Dry run (validate without changes) | `bash deploy.sh full-stack --target vm --dry-run` |
| Check status | `bash deploy.sh status --target vm` |
| View logs | `bash deploy.sh logs --target vm` |
| Stop (preserve data) | `bash deploy.sh stop --target vm` |
| Full cleanup (remove everything) | `bash deploy.sh clean --target vm` |
| Run deployment tests | `bash deploy-test.sh` |

---

## 6b. Microservices quick reference

| I want to... | Command |
|---|---|
| Deploy on VM with Docker Compose | `cd deploy/microservices/vm && bash deploy.sh` |
| Stop microservices (VM) | `cd deploy/microservices/vm && bash deploy.sh stop` |
| Clean microservices (VM) | `cd deploy/microservices/vm && bash deploy.sh clean` |
| View logs (VM) | `cd deploy/microservices/vm && bash deploy.sh logs` |
| Deploy on Kubernetes | `helm upgrade --install pyroscope deploy/helm/pyroscope/ -n pyroscope --create-namespace -f deploy/helm/pyroscope/examples/microservices-kubernetes.yaml` |
| Clean Kubernetes | `helm uninstall pyroscope -n pyroscope` |
| Deploy on OpenShift (microservices) | `helm upgrade --install pyroscope deploy/helm/pyroscope/ -n pyroscope --create-namespace -f deploy/helm/pyroscope/examples/microservices-openshift.yaml` |
| Deploy on OpenShift (monolith, same ns) | `helm upgrade --install pyroscope deploy/helm/pyroscope/ -n <app-ns> -f deploy/helm/pyroscope/examples/monolith-same-namespace.yaml` |
| Deploy on OpenShift (monolith, dedicated ns) | `helm upgrade --install pyroscope deploy/helm/pyroscope/ -n pyroscope --create-namespace -f deploy/helm/pyroscope/examples/monolith-dedicated-namespace.yaml` |
| Clean OpenShift | `helm uninstall pyroscope -n pyroscope` |

---

## 6c. Sample apps and agent instrumentation quick reference

| I want to... | Architecture | Command |
|---|---|---|
| **Microservices demo** (9 services + Pyroscope + Grafana) | Service-per-container | `docker compose up -d` (from repo root) |
| Start specific microservices | Service-per-container | `docker compose up -d pyroscope grafana order-service payment-service` |
| **FaaS runtime demo** (1 JVM + Pyroscope) | Single-JVM function host | `docker compose up -d faas-server pyroscope` |
| Invoke a FaaS function | — | `curl -X POST http://localhost:8088/fn/invoke/fibonacci` |
| Burst test (100 concurrent) | — | `curl -X POST "http://localhost:8088/fn/burst/fibonacci?count=100"` |
| **Agent instrumentation** (Docker) | Any existing JVM | `JAVA_TOOL_OPTIONS="-javaagent:/path/to/pyroscope.jar"` — [Section 15](#15-agent-instrumentation) |
| **Agent instrumentation** (K8s) | Any existing JVM | Init container pattern — [Section 15f](#15f-kubernetes-init-container-pattern) |
| Stop all sample apps | — | `docker compose down` (from repo root) |

---

# Part 3: Step-by-Step: Pyroscope Server

## SSH configuration

Enterprise environments often require RSA key algorithm compatibility for SSH connections.
Add these options inline or configure `~/.ssh/config`.

**Inline (per command):**

```bash
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa operator@<hostname>
scp -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa file.tar operator@<hostname>:/tmp/
```

**Recommended: `~/.ssh/config`** (applies to all commands automatically):

```
# ~/.ssh/config — Pyroscope deployment targets
Host pyro-* *.example.com
    User operator
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```

With this config, all `ssh`/`scp` commands in this guide work without extra flags.
Replace the `Host` pattern with your actual hostname pattern (e.g., `*.corp.mycompany.com`).

---

## Pyroscope server configuration (HTTP vs HTTPS)

Pyroscope serves plain HTTP. TLS is terminated by an **Nginx reverse proxy** on the
same VM. Two configurations are supported:

**HTTP mode** (no TLS):

```yaml
# /opt/pyroscope/pyroscope.yaml
server:
  http_listen_port: 4040

storage:
  backend: filesystem
  filesystem:
    dir: /data

self_profiling:
  disable_push: true
```

**HTTPS mode** (Nginx handles TLS on :4040, Pyroscope moves to :4041):

```yaml
# /opt/pyroscope/pyroscope.yaml — note port change to 4041
server:
  http_listen_port: 4041

storage:
  backend: filesystem
  filesystem:
    dir: /data

self_profiling:
  disable_push: true
```

In HTTPS mode, Nginx listens on `:4040` with TLS and proxies to `localhost:4041`.
This keeps the external port unchanged (F5 VIP still points to `:4040`). Pyroscope
itself never handles TLS. This means:

- Grafana on the same host connects to Pyroscope via `http://localhost:4041`
- External clients (Java agents, browsers) use HTTPS on `:4040` (through Nginx)
- Certificate management is handled by Nginx, not Pyroscope

See [tls-setup.md](tls-setup.md) for all TLS options and
[Section 16: TLS architecture](#16-tls-architecture) for diagrams.

---

## 7. Monolith: Manual VM deployment

Manual `docker` CLI commands. No scripts required. Good for understanding the deployment
or for environments where third-party scripts cannot be used.

### 7a. HTTP with Grafana (full stack)

> **SSH note:** If your environment requires RSA key compatibility, add SSH options
> or configure `~/.ssh/config` — see [SSH configuration](#ssh-configuration) below.

```bash
# ---- On your workstation (has internet) ----

# 1. Pull and save images (specify platform to match target VM architecture)
#    Check target VM architecture first: ssh operator@<hostname> "uname -m"
#    x86_64 = linux/amd64, aarch64 = linux/arm64, ppc64le = linux/ppc64le, s390x = linux/s390x
docker pull --platform linux/amd64 grafana/pyroscope:1.18.0
docker pull --platform linux/amd64 grafana/grafana:11.5.2
docker save -o pyroscope-stack-images.tar \
    grafana/pyroscope:1.18.0 \
    grafana/grafana:11.5.2

# 2. Transfer images and config to VM
scp pyroscope-stack-images.tar operator@<hostname>:/tmp/
scp config/pyroscope/pyroscope.yaml operator@<hostname>:/tmp/

# ---- On the target VM (as root) ----
ssh operator@<hostname>
pbrun /bin/su -

# 3. Load images and verify architecture matches host
docker load -i /tmp/pyroscope-stack-images.tar
docker inspect grafana/pyroscope:1.18.0 --format='Architecture: {{.Architecture}}'
# Must match host: uname -m (x86_64 = amd64, aarch64 = arm64)

# 4. Stage Pyroscope server config (must be world-readable for container process)
mkdir -p /opt/pyroscope
cp /tmp/pyroscope.yaml /opt/pyroscope/pyroscope.yaml
chmod 644 /opt/pyroscope/pyroscope.yaml

# 5. Create volumes
docker volume create pyroscope-data
docker volume create grafana-data

# 6. Start Pyroscope (host networking avoids memberlist interface detection
#    errors on RHEL/enterprise VMs where interfaces are named ens192, etc.)
docker run -d --name pyroscope --restart unless-stopped \
    --network host \
    --log-opt max-size=50m --log-opt max-file=3 \
    -v pyroscope-data:/data \
    -v /opt/pyroscope/pyroscope.yaml:/etc/pyroscope/config.yaml:ro \
    grafana/pyroscope:1.18.0 \
    -config.file=/etc/pyroscope/config.yaml
# Note: --network host binds directly to host port 4040 (no -p flag needed).
# Safe for monolith on a dedicated VM. Port 4040 must not be in use.

# 7. Verify Pyroscope (wait ~15-20s for ingester to become ready)
sleep 20
curl -sf http://localhost:4040/ready && echo "OK"

# 8. Stage Grafana config (copy from repo's config/grafana/ directory)
mkdir -p /opt/pyroscope/grafana/{provisioning/datasources,provisioning/dashboards,provisioning/plugins,dashboards}
# Copy provisioning YAML files and dashboards from the repo.
# Update datasource URL in provisioning/datasources/datasources.yaml
# to point to this VM's IP or hostname.

# 9. Start Grafana (stock image with volume-mounted config)
docker run -d --name grafana --restart unless-stopped \
    --log-opt max-size=50m --log-opt max-file=3 \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    -v /opt/pyroscope/grafana/grafana.ini:/etc/grafana/grafana.ini:ro \
    -v /opt/pyroscope/grafana/provisioning:/etc/grafana/provisioning:ro \
    -v /opt/pyroscope/grafana/dashboards:/var/lib/grafana/dashboards:ro \
    -e GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource \
    -e GF_SECURITY_ADMIN_PASSWORD=admin \
    grafana/grafana:11.5.2

# 10. Verify both
curl -sf http://localhost:4040/ready && echo "Pyroscope OK"
curl -sf http://localhost:3000/api/health && echo "Grafana OK"
```

### 7b. HTTP Pyroscope only

Single VM, no Grafana.

```bash
# ---- On your workstation (has internet) ----

# 1. Pull and save image (specify platform to match target VM architecture)
#    Check target VM architecture first: ssh operator@<hostname> "uname -m"
#    x86_64 = linux/amd64, aarch64 = linux/arm64, ppc64le = linux/ppc64le, s390x = linux/s390x
docker pull --platform linux/amd64 grafana/pyroscope:1.18.0
docker save -o pyroscope-images.tar grafana/pyroscope:1.18.0

# 2. Transfer image and config to VM
scp pyroscope-images.tar operator@<hostname>:/tmp/
scp config/pyroscope/pyroscope.yaml operator@<hostname>:/tmp/

# ---- On the target VM (as root) ----
ssh operator@<hostname>
pbrun /bin/su -

# 3. Load image, verify architecture, and stage config
docker load -i /tmp/pyroscope-images.tar
docker inspect grafana/pyroscope:1.18.0 --format='Architecture: {{.Architecture}}'
# Must match host: uname -m (x86_64 = amd64, aarch64 = arm64)
mkdir -p /opt/pyroscope
cp /tmp/pyroscope.yaml /opt/pyroscope/pyroscope.yaml
chmod 644 /opt/pyroscope/pyroscope.yaml    # container runs as non-root; must be readable
docker volume create pyroscope-data

# 4. Start Pyroscope (host networking avoids memberlist interface detection
#    errors on RHEL/enterprise VMs where interfaces are named ens192, etc.)
docker run -d --name pyroscope --restart unless-stopped \
    --network host \
    --log-opt max-size=50m --log-opt max-file=3 \
    -v pyroscope-data:/data \
    -v /opt/pyroscope/pyroscope.yaml:/etc/pyroscope/config.yaml:ro \
    grafana/pyroscope:1.18.0 \
    -config.file=/etc/pyroscope/config.yaml
# Note: --network host binds directly to host port 4040 (no -p flag needed).
# Safe for monolith on a dedicated VM. Port 4040 must not be in use.

# 5. Verify (wait ~15-20s for ingester to become ready)
sleep 20
curl -sf http://localhost:4040/ready && echo "OK"
```

Configure Java agents on OCP pods to point to the VM's IP or FQDN (not a Kubernetes
service name): `PYROSCOPE_SERVER_ADDRESS=http://<VM_IP_OR_FQDN>:4040`.

### 7b-multi. HTTP Pyroscope only: multiple VMs

```bash
# ---- On your workstation ----

# Pull with correct platform for target VMs (check with: ssh <vm> "uname -m")
# x86_64 = linux/amd64, aarch64 = linux/arm64, ppc64le = linux/ppc64le, s390x = linux/s390x
docker pull --platform linux/amd64 grafana/pyroscope:1.18.0
docker save -o pyroscope-images.tar grafana/pyroscope:1.18.0

TARGETS="vm01.example.com vm02.example.com vm03.example.com"  # replace with your hostnames

for vm in ${TARGETS}; do
    scp pyroscope-images.tar operator@${vm}:/tmp/
done

# ---- Deploy on each VM ----
for vm in ${TARGETS}; do
    ssh operator@${vm} "pbrun /bin/su - -c '
        docker load -i /tmp/pyroscope-images.tar
        docker volume create pyroscope-data
        docker run -d \
            --name pyroscope \
            --restart unless-stopped \
            --network host \
            -v pyroscope-data:/data \
            grafana/pyroscope:1.18.0
    '"
done

# Verify all VMs
for vm in ${TARGETS}; do
    echo -n "${vm}: "
    curl -s http://${vm}:4040/ready && echo " OK" || echo " FAIL"
done
```

### 7c. HTTPS with self-signed cert

> **Alternative TLS approaches:** This section uses Envoy. For other options
> (F5 VIP, Pyroscope native TLS, Nginx) see [tls-setup.md](tls-setup.md).

```bash
# ---- On the target VM (as root) ----

# 1. Load images (including Envoy for TLS termination)
docker load -i /tmp/pyroscope-stack-images.tar

# 2. Generate self-signed certificate
mkdir -p /opt/pyroscope/tls
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_FQDN=$(hostname -f)

openssl req -x509 \
    -newkey rsa:2048 -nodes -days 365 \
    -subj "/CN=${HOST_FQDN}" \
    -addext "subjectAltName=DNS:${HOST_FQDN},DNS:localhost,IP:${HOST_IP},IP:127.0.0.1" \
    -keyout /opt/pyroscope/tls/key.pem \
    -out /opt/pyroscope/tls/cert.pem

chmod 600 /opt/pyroscope/tls/key.pem
chmod 644 /opt/pyroscope/tls/cert.pem

# 3. Stage Pyroscope server config
mkdir -p /opt/pyroscope
cp /tmp/pyroscope.yaml /opt/pyroscope/pyroscope.yaml
chmod 644 /opt/pyroscope/pyroscope.yaml

# 4. Start Pyroscope (host networking — Envoy handles external TLS traffic)
docker volume create pyroscope-data
docker run -d --name pyroscope --restart unless-stopped \
    --network host \
    --log-opt max-size=50m --log-opt max-file=3 \
    -v pyroscope-data:/data \
    -v /opt/pyroscope/pyroscope.yaml:/etc/pyroscope/config.yaml:ro \
    grafana/pyroscope:1.18.0 \
    -config.file=/etc/pyroscope/config.yaml
# Note: --network host binds to host port 4040. Firewall rules allow only
# :4443 (Envoy TLS) externally; :4040 stays internal on the VM.

# 5. Start Grafana
docker volume create grafana-data
docker run -d --name grafana --restart unless-stopped \
    --log-opt max-size=50m --log-opt max-file=3 \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    -v /opt/pyroscope/grafana/grafana.ini:/etc/grafana/grafana.ini:ro \
    -v /opt/pyroscope/grafana/provisioning:/etc/grafana/provisioning:ro \
    -v /opt/pyroscope/grafana/dashboards:/var/lib/grafana/dashboards:ro \
    -e GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource \
    -e GF_SECURITY_ADMIN_PASSWORD=admin \
    grafana/grafana:11.5.2

# 6. Write Envoy config (TLS termination proxy)
# See deploy.sh generate_envoy_config for the full template,
# or tls-setup.md for the complete copy-paste envoy.yaml.
# Listeners: :4443 -> 127.0.0.1:4040, :443 -> 127.0.0.1:3000

# 7. Start Envoy TLS proxy
docker run -d --name envoy-proxy --restart unless-stopped \
    --network host \
    -v /opt/pyroscope/tls/envoy.yaml:/etc/envoy/envoy.yaml:ro \
    -v /opt/pyroscope/tls:/etc/envoy/tls:ro \
    envoyproxy/envoy:v1.31-latest

# 8. Verify (wait ~15-20s for ingester to become ready)
sleep 20
curl -k https://localhost:4443/ready       # Pyroscope via Envoy
curl -k https://localhost:443/api/health   # Grafana via Envoy
```

### 7d. HTTPS with enterprise CA certs (F5 VIP + Nginx)

This is the **recommended production deployment**. F5 VIP forwards HTTPS to the VM.
Nginx on the VM terminates TLS on `:4040` and proxies to Pyroscope on `:4041`.

```bash
# ---- On the target VM (as root) ----

# 1. Load Pyroscope and Nginx images
docker load -i /tmp/pyroscope-images.tar
docker load -i /tmp/nginx-images.tar
# If online: docker pull --platform linux/amd64 grafana/pyroscope:1.18.0
# If online: docker pull --platform linux/amd64 nginx:1.27-alpine

# 2. Stage enterprise certificate files
mkdir -p /opt/pyroscope/tls
cp /path/to/enterprise-cert.pem /opt/pyroscope/tls/cert.pem
cp /path/to/enterprise-key.pem  /opt/pyroscope/tls/key.pem
chmod 644 /opt/pyroscope/tls/cert.pem
chmod 600 /opt/pyroscope/tls/key.pem

# 3. Stage Pyroscope config (port 4041 — Nginx takes 4040)
cat > /opt/pyroscope/pyroscope.yaml <<'PYRO_EOF'
server:
  http_listen_port: 4041

storage:
  backend: filesystem
  filesystem:
    dir: /data

self_profiling:
  disable_push: true
PYRO_EOF
chmod 644 /opt/pyroscope/pyroscope.yaml

# 4. Write Nginx config (TLS termination on :4040, proxy to :4041)
cat > /opt/pyroscope/nginx.conf <<'NGINX_EOF'
events { worker_connections 1024; }

http {
    server {
        listen 4040 ssl;
        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass http://127.0.0.1:4041;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 60s;
        }
    }
}
NGINX_EOF

# 5. Start Pyroscope (HTTP on port 4041, internal only)
docker volume create pyroscope-data
docker run -d --name pyroscope --restart unless-stopped \
    --network host \
    --log-opt max-size=50m --log-opt max-file=3 \
    -v pyroscope-data:/data \
    -v /opt/pyroscope/pyroscope.yaml:/etc/pyroscope/config.yaml:ro \
    grafana/pyroscope:1.18.0 \
    -config.file=/etc/pyroscope/config.yaml

# 6. Start Nginx TLS proxy (HTTPS on port 4040)
docker run -d --name nginx-tls --restart unless-stopped \
    --network host \
    --log-opt max-size=50m --log-opt max-file=3 \
    -v /opt/pyroscope/nginx.conf:/etc/nginx/nginx.conf:ro \
    -v /opt/pyroscope/tls:/etc/nginx/tls:ro \
    nginx:1.27-alpine

# 7. Verify (wait ~15-20s for ingester to become ready)
sleep 20
curl http://localhost:4041/ready && echo "Pyroscope OK"
curl -k https://localhost:4040/ready && echo "Nginx TLS OK"
```

Java agents do not need special trust configuration when the CA is already
in the JVM default truststore. Agent config:

```properties
# Via F5 VIP (recommended)
pyroscope.server.address=https://domain-pyroscope.company.com

# Or direct to VM
pyroscope.server.address=https://<VM_IP>:4040
```

For self-signed cert trust setup, see
[tls-setup.md](tls-setup.md#java-agent-trust-configuration).

---

## 8. Monolith: Bash script on VM

The `deploy.sh` script in `deploy/monolith/` handles pre-flight checks, image loading,
container lifecycle, TLS setup, firewall ports, SELinux volume labels, and health checks.
All operations are idempotent -- safe to re-run.

### 8a. SSH with pbrun workflow

```bash
# On your workstation -- save images
cd deploy/monolith
bash deploy.sh save-images
# Output: pyroscope-stack-images.tar

# Transfer to VM
scp pyroscope-stack-images.tar operator@<hostname>:/tmp/

# SSH to VM and become root
ssh operator@<hostname>
pbrun /bin/su -

# Run from the repo checkout on the VM
cd /path/to/repo/deploy/monolith
bash deploy.sh full-stack --target vm \
    --load-images /tmp/pyroscope-stack-images.tar \
    --log-file /tmp/deploy.log
```

### 8b. deploy.sh examples

```bash
# --- Full stack, HTTP ---
bash deploy.sh full-stack --target vm \
    --load-images /tmp/pyroscope-stack-images.tar \
    --log-file /tmp/deploy.log

# --- Full stack, HTTP, Pyroscope only ---
bash deploy.sh full-stack --target vm --skip-grafana \
    --load-images /tmp/pyroscope-stack-images.tar

# --- Full stack, HTTPS (self-signed) ---
bash deploy.sh save-images --tls     # includes Envoy image
# scp to VM, then:
bash deploy.sh full-stack --target vm \
    --tls --tls-self-signed \
    --load-images /tmp/pyroscope-stack-images.tar

# --- Full stack, HTTPS (CA certs) ---
bash deploy.sh full-stack --target vm \
    --tls --tls-cert /path/to/cert.pem --tls-key /path/to/key.pem

# --- Pyroscope only, HTTPS (self-signed) ---
bash deploy.sh full-stack --target vm --skip-grafana \
    --tls --tls-self-signed

# --- Pyroscope only, HTTPS (CA certs) ---
bash deploy.sh full-stack --target vm --skip-grafana \
    --tls --tls-cert /path/to/cert.pem --tls-key /path/to/key.pem

# --- Add to existing Grafana (API method, no restart) ---
bash deploy.sh add-to-existing \
    --grafana-url http://grafana.corp:3000 \
    --grafana-api-key eyJrIj... \
    --pyroscope-url http://pyroscope.corp:4040

# --- Add to existing Grafana (provisioning files) ---
bash deploy.sh add-to-existing --method provisioning \
    --pyroscope-url http://pyroscope.corp:4040

# --- Custom Pyroscope image with mounted config ---
bash deploy.sh full-stack --target vm \
    --pyroscope-image pyroscope-server:1.18.0 \
    --pyroscope-config /opt/pyroscope/pyroscope.yaml

# --- Docker Compose locally ---
bash deploy.sh full-stack --target local

# --- Dry run (validate without making changes) ---
bash deploy.sh full-stack --target vm --dry-run
```

### 8c. Verify after deploy

**HTTP deployment:**

```bash
bash deploy.sh status --target vm
curl -s http://localhost:4040/ready        # Pyroscope
curl -s http://localhost:3000/api/health   # Grafana (if deployed)
```

**HTTPS deployment** (TLS via Envoy):

```bash
bash deploy.sh status --target vm
curl -ks https://localhost:4443/ready       # Pyroscope via Envoy
curl -ks https://localhost:443/api/health   # Grafana via Envoy (if deployed)
```

> **Note:** The Pyroscope server config (`pyroscope.yaml`) is identical for HTTP and
> HTTPS. TLS is handled by the Envoy proxy — see [SSH and config notes](#pyroscope-server-configuration-http-vs-https).

---

## 9. Monolith: Ansible on VM

The Ansible role in `deploy/monolith/ansible/` provides the same features as `deploy.sh`
using native Ansible modules (`community.docker`, `ansible.posix`).

### 9a. Inventory with pbrun

Edit `deploy/monolith/ansible/inventory/hosts.yml`:

```yaml
all:
  children:
    pyroscope_full_stack:
      hosts:
        vm01.corp.example.com:
        # vm02.corp.example.com:

    pyroscope_add_to_existing:
      hosts:
        # grafana01.corp.example.com:
        #   grafana_url: http://localhost:3000
        #   grafana_api_key: "eyJrIj..."

  vars:
    ansible_user: operator
    ansible_become: true
    ansible_become_method: su
    # For pbrun:
    # ansible_become_method: pbrun
    # ansible_become_exe: /usr/local/bin/pbrun
```

### 9b. Group vars

Edit `deploy/monolith/ansible/inventory/group_vars/pyroscope.yml`:

```yaml
pyroscope_mode: full-stack
pyroscope_image: grafana/pyroscope:1.18.0
pyroscope_port: 4040
grafana_image: grafana/grafana:11.5.2
grafana_port: 3000
grafana_admin_password: admin  # use ansible-vault in production
```

### 9c. Playbook examples

All commands run from `deploy/monolith/ansible/`:

```bash
# --- Full stack, HTTP ---
ansible-playbook -i inventory playbooks/deploy.yml

# --- Full stack, HTTP, air-gapped ---
ansible-playbook -i inventory playbooks/deploy.yml \
    -e docker_load_path=/tmp/pyroscope-stack-images.tar

# --- Full stack, HTTPS (self-signed) ---
ansible-playbook -i inventory playbooks/deploy.yml \
    -e tls_enabled=true \
    -e tls_self_signed=true

# --- Full stack, HTTPS (CA certs) ---
ansible-playbook -i inventory playbooks/deploy.yml \
    -e tls_enabled=true \
    -e tls_cert_src=/path/to/cert.pem \
    -e tls_key_src=/path/to/key.pem

# --- Pyroscope only (no Grafana) ---
ansible-playbook -i inventory playbooks/deploy.yml \
    -e skip_grafana=true

# --- Add to existing Grafana ---
ansible-playbook -i inventory playbooks/deploy.yml \
    -e pyroscope_mode=add-to-existing \
    -e grafana_url=http://grafana.corp:3000 \
    -e grafana_api_key=eyJrIj...

# --- Target a single host ---
ansible-playbook -i inventory playbooks/deploy.yml \
    --limit vm01.corp.example.com

# --- Dry run (check mode) ---
ansible-playbook -i inventory playbooks/deploy.yml --check

# --- Status ---
ansible-playbook -i inventory playbooks/status.yml

# --- Stop (preserve data) ---
ansible-playbook -i inventory playbooks/stop.yml

# --- Full cleanup ---
ansible-playbook -i inventory playbooks/clean.yml
```

### 9d. Split-VM topology

Pyroscope on one VM group, Grafana on another:

```yaml
# inventory/production/hosts.yml
all:
  children:
    pyroscope_full_stack:
      hosts:
        pyro-vm01.corp.example.com:
      vars:
        skip_grafana: true
        tls_enabled: true
        tls_self_signed: true

    pyroscope_add_to_existing:
      hosts:
        grafana-vm01.corp.example.com:
      vars:
        pyroscope_mode: add-to-existing
        pyroscope_url: "https://pyro-vm01.corp.example.com:4443"
        grafana_url: "http://localhost:3000"
        grafana_api_key: "{{ vault_grafana_api_key }}"
```

```bash
ansible-playbook -i inventory/production playbooks/deploy.yml
```

### 9e. Importing the role into existing playbooks

The `pyroscope-stack` role can be added to any Ansible project. It is NOT installed
via Galaxy -- use one of these methods:

**Method 1: Symlink**

```bash
ln -s /path/to/pyroscope/deploy/monolith/ansible/roles/pyroscope-stack \
      /path/to/your/playbook/roles/pyroscope-stack
```

**Method 2: roles_path in ansible.cfg**

```ini
# ansible.cfg
[defaults]
roles_path = /path/to/pyroscope/deploy/monolith/ansible/roles
```

When using the role from an external playbook, override `pyroscope_repo_root`
so it can find the config files:

```yaml
- name: Deploy Pyroscope
  hosts: profiling_servers
  become: true
  roles:
    - role: pyroscope-stack
      pyroscope_repo_root: /path/to/pyroscope
```

The default value (`{{ playbook_dir }}/../../..`) only works when running from
the repo's own `ansible/playbooks/` directory.

---

## 10. Monolith: Kubernetes and OpenShift

### 10a. Kubernetes with kubectl

```bash
# Create namespace and deploy
bash deploy.sh full-stack --target k8s --namespace monitoring

# The script creates:
#   - Namespace (if needed)
#   - ConfigMaps for Grafana provisioning and dashboards
#   - Deployments + Services for Pyroscope and Grafana
#   - PVCs for persistent storage (10Gi Pyroscope, 2Gi Grafana)

# Access via port-forward
kubectl -n monitoring port-forward svc/pyroscope 4040:4040
kubectl -n monitoring port-forward svc/grafana 3000:3000

# Verify
kubectl -n monitoring get pods
```

**Customization:**

```bash
# Custom storage class and PVC size
bash deploy.sh full-stack --target k8s \
    --namespace monitoring \
    --storage-class gp3 \
    --pvc-size-pyroscope 50Gi

# Ephemeral (no PVC -- for dev/testing)
bash deploy.sh full-stack --target k8s --namespace monitoring --no-pvc

# Pyroscope only (skip Grafana)
bash deploy.sh full-stack --target k8s --namespace monitoring --skip-grafana

# Status / cleanup
bash deploy.sh status --target k8s --namespace monitoring
bash deploy.sh clean --target k8s --namespace monitoring
```

### 10b. OpenShift with Helm

The unified Helm chart at `deploy/helm/pyroscope/` supports both monolith and microservices
modes on OCP 4.12+. See [Tree 6](#6-openshift-container-platform) for the full decision tree.

**Same namespace as existing apps (recommended starting point):**

```bash
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n <your-app-namespace> \
    -f deploy/helm/pyroscope/examples/monolith-same-namespace.yaml
```

**Dedicated namespace:**

```bash
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/monolith-dedicated-namespace.yaml
```

**Verify:**

```bash
# Route URL
oc get route pyroscope -n <namespace>

# Pod status
oc get pods -n <namespace> -l app.kubernetes.io/part-of=pyroscope

# Readiness
oc exec deploy/pyroscope -n <namespace> -- wget -qO- http://localhost:4040/ready
```

Agent push endpoint: `http://pyroscope.<namespace>.svc:4040`

Configure via properties file (`pyroscope.server.address=...`) or environment variable
(`PYROSCOPE_SERVER_ADDRESS=...`). See [Section 15](#15-agent-instrumentation).

**Cleanup:**

```bash
helm uninstall pyroscope -n <namespace>
```

**Legacy approach:** `bash deploy.sh full-stack --target openshift` still works for
VM-style `oc` commands without Helm.

---

## 11. Monolith: Local Docker Compose

For local development and testing:

```bash
bash deploy.sh full-stack --target local
```

This generates a `docker-compose.yaml` in `deploy/monolith/` and runs `docker compose up -d`.
Pyroscope is on `:4040`, Grafana on `:3000` with provisioning bind-mounted from the repo.

```bash
# Stop
bash deploy.sh stop --target local

# Clean (removes volumes)
bash deploy.sh clean --target local
```

---

## 12. Microservices mode

Runs Pyroscope as 9 separate, independently scalable components. Requires NFS-backed
shared storage (ReadWriteMany). All storage is filesystem-based -- no MinIO or S3.

### Architecture

```mermaid
graph TB
    SDK[JVM Services] -->|push profiles| DIST[Distributor]
    G[Grafana] -->|query| QF[Query Frontend]

    subgraph Write Path
        DIST --> ING1[Ingester 1]
        DIST --> ING2[Ingester 2]
        DIST --> ING3[Ingester 3]
    end

    subgraph Read Path
        QF --> QS[Query Scheduler]
        QS --> Q1[Querier 1]
        QS --> Q2[Querier 2]
    end

    SG[Store Gateway]
    C[Compactor]

    subgraph Shared Storage
        NFS[("NFS / RWX PVC")]
    end

    ING1 -->|flush| NFS
    ING2 -->|flush| NFS
    ING3 -->|flush| NFS
    Q1 -->|read| SG
    Q2 -->|read| SG
    SG -->|read blocks| NFS
    C -->|compact blocks| NFS
```

**Components:**

| Component | Replicas | Description |
|-----------|----------|-------------|
| Distributor | 1 | Receives push requests, distributes to ingesters |
| Ingester | 3 | Writes profiling data to storage |
| Querier | 2 | Reads from ingesters and store-gateway |
| Query Frontend | 1 | Query gateway, splits/retries queries |
| Query Scheduler | 1 | Distributes queries across queriers |
| Compactor | 1 | Compacts stored blocks on shared storage |
| Store Gateway | 1 | Reads compacted data from shared storage |

### 12a. VM with Docker Compose

**Prerequisites:** NFS mount at `/mnt/pyroscope-data` shared across all VMs.

```bash
cd deploy/microservices/vm

# Start all services
bash deploy.sh

# Push endpoint (distributor):  http://localhost:4040
# Query endpoint (frontend):    http://localhost:4041
```

Day-2 operations:

```bash
bash deploy.sh status
bash deploy.sh logs
bash deploy.sh stop
bash deploy.sh clean
```

### 12b. Kubernetes

**Prerequisites:** ReadWriteMany (RWX) storage provisioner (NFS, CephFS, etc.).

```bash
# Install with Helm
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/microservices-kubernetes.yaml

# Or generate raw manifests without Helm
helm template pyroscope deploy/helm/pyroscope/ \
    -f deploy/helm/pyroscope/examples/microservices-kubernetes.yaml \
    --namespace pyroscope | kubectl apply -n pyroscope -f -

# Verify
kubectl -n pyroscope get pods

# Cleanup
helm uninstall pyroscope -n pyroscope
```

Customize image tag, replicas, and storage class in a values file derived from
`deploy/helm/pyroscope/examples/microservices-kubernetes.yaml`.

### 12c. OpenShift

```bash
# Install via unified Helm chart (microservices mode)
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    --namespace pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/microservices-openshift.yaml

# With custom storage class override
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    --namespace pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/microservices-openshift.yaml \
    --set storage.storageClassName=ocs-storagecluster-cephfs \
    --set storage.size=100Gi

# Uninstall
helm uninstall pyroscope --namespace pyroscope
```

### 12d. Connecting Grafana to microservices Pyroscope

The Grafana Pyroscope datasource URL depends on where Grafana runs:

| Grafana location | Datasource URL |
|------------------|----------------|
| Same VM (Docker Compose) | `http://query-frontend:4040` (container name) |
| Different VM | `http://<pyroscope-host>:4041` (query-frontend mapped port) |
| Same K8s cluster | `http://pyroscope-query-frontend.pyroscope.svc:4040` |
| External to K8s | Use Ingress or port-forward |

---

# Part 4: Sample App Deployment

## 13. Microservices demo (bank app)

**Architecture:** Service-per-container — 9 long-running JVMs, each hosting one service.
All services share a single Docker image; the `VERTICLE` environment variable selects
which service verticle to run. Each JVM has the Pyroscope Java agent pre-attached
via `JAVA_TOOL_OPTIONS`.

The repo root `docker-compose.yaml` deploys the full stack: Pyroscope + Prometheus
+ Grafana + 9 Java services.

```bash
# From the repo root:

# Start everything: Pyroscope + Prometheus + Grafana + all 9 bank services
docker compose up -d

# Start specific services only
docker compose up -d pyroscope grafana order-service payment-service

# Verify
curl -s http://localhost:4040/ready          # Pyroscope
curl -s http://localhost:3000/api/health     # Grafana
curl -s http://localhost:8080/api/health     # API Gateway
```

**Services:**

| Service | Port | VERTICLE | Pyroscope App Name |
|---------|------|----------|-------------------|
| API Gateway | :8080 | *(default)* | bank-api-gateway |
| Order Service | :8081 | `order` | bank-order-service |
| Payment Service | :8082 | `payment` | bank-payment-service |
| Fraud Service | :8083 | `fraud` | bank-fraud-service |
| Account Service | :8084 | `account` | bank-account-service |
| Loan Service | :8085 | `loan` | bank-loan-service |
| Notification Service | :8086 | `notification` | bank-notification-service |
| Stream Service | :8087 | `stream` | bank-stream-service |
| FaaS Server | :8088 | `faas` | bank-faas-server |

All services have the Pyroscope agent pre-configured via `JAVA_TOOL_OPTIONS` and
use a shared `pyroscope.properties` config mounted from `config/pyroscope/`.

```bash
# Stop everything
docker compose down
```

---

## 14. FaaS runtime demo

**Architecture:** Single-JVM function host — one JVM dynamically deploys and undeploys
short-lived Vert.x verticle "functions" on demand via HTTP. Produces distinct profiling
signatures compared to long-running services: classloader activity, deployment lifecycle
overhead, short-burst compute, and concurrent deploy/undeploy contention.

```bash
# Start FaaS server + Pyroscope only
docker compose up -d faas-server pyroscope

# Invoke a function
curl -X POST http://localhost:8088/fn/invoke/fibonacci

# Burst test (100 concurrent invocations)
curl -X POST "http://localhost:8088/fn/burst/fibonacci?count=100"
```

See [docs/faas-server.md](faas-server.md) for the full function API reference,
including all 11 built-in functions and their profiling signatures.

---

# Part 5: Agent Instrumentation for Existing Workloads

## 15. Agent instrumentation

**Architecture:** Non-invasive, agent-based profiling — attach the Pyroscope Java agent
to any existing JVM without code changes. Supports any application architecture:
monolith, microservices, FaaS runtime, batch jobs, or legacy applications.

### 15a. Download the agent

```bash
# Download Pyroscope Java agent
curl -L -o pyroscope.jar \
    https://github.com/grafana/pyroscope-java/releases/download/v0.14.0/pyroscope.jar
```

### 15b. HTTP configuration

```bash
PYROSCOPE_SERVER_ADDRESS=http://pyroscope-vm:4040
JAVA_TOOL_OPTIONS="-javaagent:/path/to/pyroscope.jar"
```

Or as JVM system properties:

```bash
java -javaagent:/path/to/pyroscope.jar \
     -Dpyroscope.server.address=http://pyroscope-vm:4040 \
     -Dpyroscope.application.name=my-service \
     -jar myapp.jar
```

### 15c. HTTPS with CA cert

If the CA is already in the JVM default truststore, just change the URL scheme:

```bash
PYROSCOPE_SERVER_ADDRESS=https://domain-pyroscope.company.com
# Or direct to VM: https://<VM_IP>:4040
```

### 15d. HTTPS with self-signed cert

Import into the JVM truststore:

```bash
keytool -importcert -noprompt -alias pyroscope \
    -file /path/to/cert.pem \
    -keystore $JAVA_HOME/lib/security/cacerts \
    -storepass changeit
```

Or use a custom truststore:

```bash
JAVA_TOOL_OPTIONS="-javaagent:/path/to/pyroscope.jar -Djavax.net.ssl.trustStore=/path/to/truststore.jks"
```

### 15e. Docker Compose

Add to any service in your `docker-compose.yaml`:

```yaml
environment:
  PYROSCOPE_APPLICATION_NAME: my-service
  PYROSCOPE_SERVER_ADDRESS: http://pyroscope:4040
  PYROSCOPE_LABELS: env=production,service=my-service
  JAVA_TOOL_OPTIONS: >-
    -javaagent:/opt/pyroscope/pyroscope.jar
```

The agent JAR must be in the image (ADD in Dockerfile) or mounted as a volume.

### 15f. Kubernetes: init container pattern

```yaml
initContainers:
  - name: pyroscope-agent
    image: grafana/pyroscope-java:0.14.0
    command: ['cp', '/pyroscope.jar', '/agent/pyroscope.jar']
    volumeMounts:
      - name: agent
        mountPath: /agent
containers:
  - name: app
    env:
      - name: JAVA_TOOL_OPTIONS
        value: "-javaagent:/agent/pyroscope.jar"
      - name: PYROSCOPE_SERVER_ADDRESS
        value: "http://pyroscope.monitoring.svc:4040"
      - name: PYROSCOPE_APPLICATION_NAME
        value: "my-service"
    volumeMounts:
      - name: agent
        mountPath: /agent
volumes:
  - name: agent
    emptyDir: {}
```

### 15g. Agent configuration reference

| Property | Env Var | Default | Description |
|----------|---------|---------|-------------|
| `pyroscope.server.address` | `PYROSCOPE_SERVER_ADDRESS` | `http://localhost:4040` | Pyroscope server URL |
| `pyroscope.application.name` | `PYROSCOPE_APPLICATION_NAME` | `""` | Application name in Pyroscope UI |
| `pyroscope.labels` | `PYROSCOPE_LABELS` | `""` | Comma-separated key=value labels |
| `pyroscope.format` | `PYROSCOPE_FORMAT` | `jfr` | Profile format |
| `pyroscope.profiler.event` | `PYROSCOPE_PROFILER_EVENT` | `itimer` | CPU profiling event |
| `pyroscope.profiler.alloc` | `PYROSCOPE_PROFILER_ALLOC` | `512k` | Allocation profiling threshold |
| `pyroscope.profiler.lock` | `PYROSCOPE_PROFILER_LOCK` | `10ms` | Lock contention threshold |
| `pyroscope.log.level` | `PYROSCOPE_LOG_LEVEL` | `info` | Agent log level |
| `pyroscope.configuration.file` | `PYROSCOPE_CONFIGURATION_FILE` | `""` | Path to properties file |

**Precedence:** System Properties (`-D`) > Environment Variables > Properties File

---

# Part 6: Reference

## 16. TLS architecture

For HTTPS deployments, an **Nginx reverse proxy** on the VM terminates TLS on `:4040`
and forwards plain HTTP to Pyroscope on `localhost:4041`. This keeps the external port
unchanged so F5 VIP configuration does not need to change.

### F5 VIP + Nginx (recommended production)

```mermaid
graph LR
    subgraph F5["F5 VIP"]
        VIP["domain-pyroscope.company.com :443"]
    end
    subgraph VM["Pyroscope VM"]
        N[":4040 Nginx (TLS)"] --> P["Pyroscope<br/>127.0.0.1:4041 (HTTP)"]
    end
    Agent -->|HTTPS :443| VIP
    VIP -->|HTTPS :4040| N
```

### Standalone Nginx (no F5)

```mermaid
graph LR
    subgraph VM
        N[":4040 Nginx (TLS)"] --> P["Pyroscope<br/>127.0.0.1:4041 (HTTP)"]
    end
    Agent -->|HTTPS :4040| N
    Grafana["Grafana (elsewhere)"] -->|HTTPS :4040| N
```

### Full stack with Grafana

```mermaid
graph LR
    subgraph VM
        N[":4040 Nginx (TLS)"] --> P["Pyroscope<br/>127.0.0.1:4041 (HTTP)"]
        G["Grafana<br/>:3000"]
    end
    Agent -->|HTTPS :4040| N
    G -->|"datasource: http://localhost:4041"| P
    Browser -->|HTTP :3000| G
```

---

## 17. Port reference

### Pyroscope server ports

| Service | Monolith HTTP | Monolith HTTPS | Microservices |
|---------|:---:|:---:|:---:|
| Pyroscope | :4040 | :4041 (internal HTTP) | :4040 (distributor push) |
| Nginx TLS proxy | N/A | :4040 (TLS termination) | N/A |
| Grafana | :3000 | :3000 | N/A (external) |
| Query Frontend | N/A | N/A | :4041 (VM) / :4040 (K8s svc) |
| Memberlist | N/A | N/A | :7946 (inter-component) |

### Bank app ports

| Service | Port | VERTICLE |
|---------|------|----------|
| API Gateway | :8080 | *(default)* |
| Order Service | :8081 | `order` |
| Payment Service | :8082 | `payment` |
| Fraud Service | :8083 | `fraud` |
| Account Service | :8084 | `account` |
| Loan Service | :8085 | `loan` |
| Notification Service | :8086 | `notification` |
| Stream Service | :8087 | `stream` |
| FaaS Server | :8088 | `faas` |

### 17a. Firewall rules: Monolith on VM (HTTP)

Minimum rules for Pyroscope monolith on a VM receiving data from external agents.

**Pyroscope VM — Ingress (inbound)**

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| OCP worker nodes (agent pods) | TCP 4040 | HTTP | Agent push (`POST /ingest`) |
| Grafana VM | TCP 4040 | HTTP | Datasource queries (`/querier.v1.*`) |
| Prometheus VM | TCP 4040 | HTTP | Metrics scrape (`GET /metrics`) |
| Admin workstation | TCP 4040 | HTTP | Pyroscope UI and `GET /ready` health check |

**Pyroscope VM — Egress (outbound)**

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| DNS server | TCP/UDP 53 | DNS | Container image pulls, hostname resolution |
| Docker registry | TCP 443 | HTTPS | Image pulls (if not air-gapped) |

> **No outbound connectivity to OCP is needed.** Agents push to Pyroscope (inbound);
> Pyroscope never initiates connections to agents.

**OCP cluster — Egress (outbound from pods)**

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Pyroscope VM | TCP 4040 | HTTP | Java agent push (`POST /ingest` every 10s) |

> **OCP NetworkPolicy / EgressNetworkPolicy:** If your OCP project has a default-deny
> egress policy, add an EgressNetworkPolicy or NetworkPolicy allowing TCP 4040 to
> the Pyroscope VM IP.

**Grafana VM — Egress (outbound)**

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Pyroscope VM | TCP 4040 | HTTP | Datasource queries (on-demand, user-driven) |

**Prometheus VM — Egress (outbound)**

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| Pyroscope VM | TCP 4040 | HTTP | Metrics scrape (every 15-30s, configurable) |

### 17b. Firewall rules: Monolith on VM (HTTPS with Nginx)

Same as 17a but all external traffic uses HTTPS on port 4040.
Nginx terminates TLS on `:4040` and forwards to Pyroscope on `127.0.0.1:4041`.
Port 4041 is internal only and should **not** be exposed externally.

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| F5 VIP / OCP worker nodes | TCP 4040 | HTTPS | Agent push (via Nginx TLS) |
| Grafana VM | TCP 4040 | HTTPS | Datasource queries |
| Prometheus VM | TCP 4040 | HTTPS | Metrics scrape |
| Admin workstation | TCP 4040 | HTTPS | Pyroscope UI |

### 17c. Firewall rules: Monolith on OCP (Helm chart)

When Pyroscope runs inside OCP, traffic stays within the cluster network.

**Intra-cluster (covered by OCP SDN, no firewall rules needed)**

| Source | Destination | Port | Purpose |
|--------|-------------|------|---------|
| App pods (same namespace) | Pyroscope pod | TCP 4040 | Agent push |
| Grafana pod (same/different namespace) | Pyroscope pod | TCP 4040 | Datasource queries |
| Prometheus pod | Pyroscope pod | TCP 4040 | Metrics scrape |

**External access (if Route is enabled)**

| Source | Destination | Port | Purpose |
|--------|-------------|------|---------|
| External Grafana | OCP Route | TCP 443 | Datasource queries via Route |
| Admin browser | OCP Route | TCP 443 | Pyroscope UI |

> **NetworkPolicy:** If enabled in the Helm chart (`networkPolicy.enabled: true`), only
> pods in the same namespace and explicitly listed namespaces can reach port 4040.

### 17d. Firewall rules: Microservices mode (OCP/K8s)

All inter-component traffic is intra-cluster. External rules same as 17c.

**Intra-cluster (between Pyroscope components)**

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| All components | Ingester headless service | TCP 7946 | Memberlist gossip | Hash ring coordination |
| All components | Ingester headless service | UDP 7946 | Memberlist gossip | Ring state propagation |
| Distributor | Ingester | TCP 4040 | HTTP | Profile write path |
| Querier | Store-gateway | TCP 4040 | HTTP | Profile read path |
| Querier | Ingester | TCP 4040 | HTTP | Recent profile read |
| Query-frontend | Query-scheduler | TCP 4040 | HTTP | Query scheduling |
| Query-scheduler | Querier | TCP 4040 | HTTP | Query dispatch |

**External (agent push and Grafana query)**

| Source | Destination | Port | Purpose |
|--------|-------------|------|---------|
| App pods | Distributor service | TCP 4040 | Agent push (`POST /ingest`) |
| Grafana | Query-frontend service | TCP 4040 | Datasource queries |
| Prometheus | Any component | TCP 4040 | Metrics scrape (`GET /metrics`) |

### 17e. Firewall rules: Hybrid (VM Pyroscope + OCP agents)

This is the [Tree 7](#7-tree-hybrid-topology-vm-pyroscope--ocp-agents) topology.

```
┌────────────────────────────┐
│       OCP 4.12 Cluster     │
│  ┌──────────────────────┐  │         ┌──────────────────┐
│  │  Vert.x FaaS Pod     │  │         │  Pyroscope VM    │
│  │  java agent ──────────│──│── 4040 →│  :4040 monolith  │
│  └──────────────────────┘  │         └────────┬─────────┘
│                            │                  │
└────────────────────────────┘            4040 ↑│↑ 4040
                                              │││
                              ┌───────────────┘│└──────────────┐
                              │                │               │
                     ┌────────┴───────┐ ┌──────┴─────┐ ┌──────┴──────┐
                     │ Grafana VM     │ │Prometheus  │ │ Admin       │
                     │ :3000 → query  │ │VM :9090    │ │ browser     │
                     └────────────────┘ │scrape      │ └─────────────┘
                                        └────────────┘
```

**Summary: only TCP 4040 needs to be open on the Pyroscope VM from these sources:**

| # | Source | Destination | Port | Direction | Purpose |
|---|--------|-------------|------|-----------|---------|
| 1 | OCP worker nodes | Pyroscope VM | TCP 4040 | Ingress on VM | Agent push (every 10s per pod) |
| 2 | Grafana VM | Pyroscope VM | TCP 4040 | Ingress on VM | Datasource queries |
| 3 | Prometheus VM | Pyroscope VM | TCP 4040 | Ingress on VM | Metrics scrape |
| 4 | OCP app pods | Pyroscope VM IP | TCP 4040 | Egress from OCP | Same as #1, from OCP perspective |

> **That's it — port 4040 is the only port needed for monolith mode.**
> No gRPC (9095), no memberlist (7946), no embedded Grafana (4041).

---

## 18. Day-2 operations

### Monolith: Bash script

```bash
# Status
bash deploy.sh status --target vm

# Logs
bash deploy.sh logs --target vm
docker logs -f pyroscope          # follow a single container
docker logs -f grafana
docker logs -f envoy-proxy

# Stop (containers removed, volumes preserved)
bash deploy.sh stop --target vm

# Full cleanup (containers, volumes, images, config, certs)
bash deploy.sh clean --target vm
```

### Monolith: Ansible

```bash
ansible-playbook -i inventory playbooks/status.yml
ansible-playbook -i inventory playbooks/stop.yml
ansible-playbook -i inventory playbooks/clean.yml
```

### Microservices: Docker Compose

```bash
cd deploy/microservices/vm
bash deploy.sh status
bash deploy.sh logs
bash deploy.sh stop
bash deploy.sh clean
```

### Upgrade workflow

```bash
# 1. Save new images on workstation
bash build-and-push.sh --version 1.19.0 --save
scp pyroscope-server-1.19.0.tar operator@<hostname>:/tmp/

# 2. On VM: load new image
docker load -i /tmp/pyroscope-server-1.19.0.tar

# 3. Replace container (volume preserved = data preserved)
docker rm -f pyroscope
docker run -d --name pyroscope --restart unless-stopped \
    --log-opt max-size=50m --log-opt max-file=3 \
    -p 4040:4040 -v pyroscope-data:/data \
    grafana/pyroscope:1.19.0

# 4. Verify
curl -s http://localhost:4040/ready
```

Or with `deploy.sh`:

```bash
bash deploy.sh full-stack --target vm \
    --pyroscope-image grafana/pyroscope:1.19.0
```

### Rollback

```bash
# Same as upgrade, use the old image tag
docker rm -f pyroscope
docker run -d --name pyroscope --restart unless-stopped \
    --log-opt max-size=50m --log-opt max-file=3 \
    -p 4040:4040 -v pyroscope-data:/data \
    grafana/pyroscope:1.18.0
```

### Log management

Docker stores container logs at `/var/lib/docker/containers/<id>/<id>-json.log`.
Without limits, these grow indefinitely and can fill the VM disk.

**Add log rotation to all `docker run` commands:**

```bash
docker run -d --name pyroscope --restart unless-stopped \
    --log-opt max-size=50m --log-opt max-file=3 \
    -p 4040:4040 -v pyroscope-data:/data \
    grafana/pyroscope:1.18.0
```

This caps logs at 150 MB total (3 files x 50 MB). Applies to new containers only.

**Clean up logs from an existing container:**

```bash
# Find and truncate the log file (container can stay running)
truncate -s 0 $(docker inspect --format='{{.LogPath}}' pyroscope)
```

**Clean up logs after removing a container:**

```bash
# Remove stopped containers and their logs
docker container prune -f

# Remove unused images, build cache, and volumes (careful — removes ALL unused volumes)
docker system prune -f

# Check disk usage
docker system df
```

**Set a default log limit for all containers** (prevents the problem globally):

```bash
# /etc/docker/daemon.json
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker
```

### Config changes

If config is volume-mounted (default):

```bash
vi /opt/pyroscope/pyroscope.yaml
docker restart pyroscope
```

### Certificate renewal (TLS)

```bash
cp new-cert.pem /opt/pyroscope/tls/cert.pem
cp new-key.pem /opt/pyroscope/tls/key.pem
chmod 600 /opt/pyroscope/tls/key.pem
docker restart envoy-proxy
```

### Backup profiling data

```bash
# Find volume location
docker volume inspect pyroscope-data

# Backup (Pyroscope can remain running)
docker run --rm \
    -v pyroscope-data:/data:ro \
    -v /tmp:/backup \
    alpine tar czf /backup/pyroscope-backup-$(date +%Y%m%d).tar.gz -C /data .

# Restore (stop Pyroscope first)
docker stop pyroscope
docker run --rm \
    -v pyroscope-data:/data \
    -v /tmp:/backup:ro \
    alpine sh -c "rm -rf /data/* && tar xzf /backup/pyroscope-backup-YYYYMMDD.tar.gz -C /data"
docker start pyroscope
```

---

## 19. File map

### Monolith deployment

| Path | Purpose |
|------|---------|
| `deploy/monolith/deploy.sh` | Lifecycle script -- deploy, status, stop, clean, logs, save-images |
| `deploy/monolith/build-and-push.sh` | Build, tag, push, save Docker images |
| `deploy/monolith/deploy-test.sh` | Unit tests for deploy.sh (no root/Docker needed) |
| `deploy/monolith/Dockerfile` | Standard build (official `grafana/pyroscope` base) |
| `deploy/monolith/Dockerfile.custom` | Custom base image (Alpine, UBI, Debian, distroless) |
| `deploy/monolith/pyroscope.yaml` | Server config (filesystem storage, port 4040) |
| `deploy/monolith/DOCKER-BUILD.md` | Image building reference |
| `deploy/monolith/README.md` | Monolith deployment reference |

### Ansible

| Path | Purpose |
|------|---------|
| `deploy/monolith/ansible/inventory/hosts.yml` | Target VM inventory |
| `deploy/monolith/ansible/inventory/group_vars/pyroscope.yml` | Shared role variables |
| `deploy/monolith/ansible/playbooks/deploy.yml` | Deploy the stack |
| `deploy/monolith/ansible/playbooks/status.yml` | Check running status |
| `deploy/monolith/ansible/playbooks/stop.yml` | Stop (preserve data) |
| `deploy/monolith/ansible/playbooks/clean.yml` | Full cleanup |
| `deploy/monolith/ansible/roles/pyroscope-stack/defaults/main.yml` | Role defaults |
| `deploy/monolith/ansible/roles/pyroscope-stack/tasks/main.yml` | Entry point |
| `deploy/monolith/ansible/roles/pyroscope-stack/templates/envoy.yaml.j2` | Envoy TLS config |
| `deploy/monolith/ansible/README.md` | Ansible deployment reference |

### Microservices deployment

| Path | Purpose |
|------|---------|
| `deploy/microservices/vm/docker-compose.yaml` | 9-service Docker Compose for VM |
| `deploy/microservices/vm/deploy.sh` | Start/stop/logs/status/clean script |
| `deploy/microservices/vm/pyroscope.yaml` | Microservices Pyroscope config |
| `deploy/microservices/vm/README.md` | VM deployment reference |
| `deploy/helm/pyroscope/` | Unified Helm chart — monolith and microservices, OCP and K8s |
| `deploy/helm/pyroscope/values.yaml` | All configuration knobs with inline documentation |
| `deploy/helm/pyroscope/examples/` | Ready-to-use values files for 4 deployment scenarios |
| `deploy/microservices/README.md` | Microservices overview |

### Grafana config

| Path | Purpose |
|------|---------|
| `config/grafana/provisioning/datasources/datasources.yaml` | Pyroscope datasource |
| `config/grafana/provisioning/dashboards/dashboards.yaml` | Dashboard provider |
| `config/grafana/provisioning/plugins/plugins.yaml` | Pyroscope plugin config |
| `config/grafana/dashboards/pyroscope-overview.json` | Overview dashboard |
| `config/grafana/dashboards/http-performance.json` | HTTP performance dashboard |
| `config/grafana/dashboards/verticle-performance.json` | Verticle profiling dashboard |
| `config/grafana/dashboards/before-after-comparison.json` | Diff flame graph dashboard |
| `config/grafana/dashboards/faas-server.json` | FaaS function dashboard |
| `config/grafana/dashboards/jvm-metrics.json` | JVM metrics dashboard |
| `deploy/grafana/grafana.ini` | Grafana server config |
| `deploy/grafana/Dockerfile` | Custom Grafana image build |

### Pyroscope config

| Path | Purpose |
|------|---------|
| `config/pyroscope/pyroscope.yaml` | Pyroscope server config (sample app) |
| `config/pyroscope/pyroscope.properties` | Java agent shared config |

### Sample app

| Path | Purpose |
|------|---------|
| `app/Dockerfile` | Bank app Docker image (all 9 services) |
| `docker-compose.yaml` | Full demo orchestration (Pyroscope + Prometheus + Grafana + 9 services) |

### Documentation

| Path | Purpose |
|------|---------|
| [docs/deployment-guide.md](deployment-guide.md) | This guide |
| [docs/faas-server.md](faas-server.md) | FaaS server API and function reference |
| [docs/grafana-setup.md](grafana-setup.md) | Grafana configuration details |
| [docs/dashboard-guide.md](dashboard-guide.md) | Dashboard usage guide |
| [docs/reading-flame-graphs.md](reading-flame-graphs.md) | Flame graph interpretation |
| [README.md](../README.md) | System architecture, data flow, service catalog |
| [docs/endpoint-reference.md](endpoint-reference.md) | API endpoint reference |

---

## 20. Troubleshooting: No data in Pyroscope UI

If you have deployed Pyroscope and configured the Java agent but see no profiling data
in the Pyroscope UI or Grafana, work through these steps in order.

### Step 1: Is Pyroscope server running and healthy?

```bash
# From the Pyroscope VM (or any machine that can reach it)
curl -sv http://PYROSCOPE_VM_IP:4040/ready
```

**Expected:** HTTP 200 with body `ready`

If this fails:
- Check the container is running: `docker ps | grep pyroscope`
- Check container logs: `docker logs pyroscope`
- Check the VM firewall allows inbound TCP 4040: `ss -tlnp | grep 4040`
- Check `iptables` / `firewalld` rules: `firewall-cmd --list-ports` or `iptables -L -n | grep 4040`

### Step 2: Can OCP pods reach Pyroscope?

```bash
# From inside an OCP pod (exec into the Vert.x FaaS pod)
oc exec -it <pod-name> -n <namespace> -- curl -sv http://PYROSCOPE_VM_IP:4040/ready

# If curl is not in the image, use nc:
oc exec -it <pod-name> -n <namespace> -- nc -zv PYROSCOPE_VM_IP 4040

# Or start a debug pod:
oc run debug-net --rm -it --image=registry.access.redhat.com/ubi8/ubi-minimal \
    -- curl -sv http://PYROSCOPE_VM_IP:4040/ready
```

**If this fails, traffic is blocked.** Check:

1. **OCP egress rules:** Does the project have an EgressNetworkPolicy or NetworkPolicy
   restricting outbound traffic?
   ```bash
   oc get egressnetworkpolicy -n <namespace>
   oc get networkpolicy -n <namespace>
   ```

2. **OCP egress firewall (OVN-Kubernetes):**
   ```bash
   oc get egressfirewall -n <namespace>
   ```

3. **Corporate firewall / network appliance** between OCP and the VM subnet — this is
   the most common blocker in enterprise environments. Work with your network team to
   allow TCP 4040 from OCP worker node IPs to the Pyroscope VM.

4. **Proxy settings:** If OCP routes external traffic through an HTTP proxy, the agent's
   HTTP POST to the VM may be going through the proxy. Check `HTTP_PROXY` / `NO_PROXY`
   env vars in the pod.

### Step 3: Is the Java agent loaded?

```bash
# Check pod logs for agent startup messages
oc logs <pod-name> -n <namespace> | grep -i "pyroscope\|async-profiler"
```

**Expected:** You should see lines like:
```
[pyroscope] INFO  io.pyroscope.javaagent.PyroscopeAgent - starting profiling...
[pyroscope] INFO  io.pyroscope.javaagent.PyroscopeAgent - server address: http://...
```

If no agent messages appear:
- Verify `JAVA_TOOL_OPTIONS` includes `-javaagent:/path/to/pyroscope.jar`
- Verify the JAR exists at that path inside the container:
  ```bash
  oc exec <pod-name> -n <namespace> -- ls -la /path/to/pyroscope.jar
  ```
- Check if another agent or JVM flag is overriding `JAVA_TOOL_OPTIONS`

### Step 4: Is the agent sending data?

Enable debug logging to see push attempts:

```bash
# In the pod's environment (Deployment or properties file)
PYROSCOPE_LOG_LEVEL=debug
# or in pyroscope.properties:
pyroscope.log.level=debug
```

Then check logs for:
```bash
oc logs <pod-name> -n <namespace> | grep -i "upload\|ingest\|push\|error\|fail"
```

**Look for:**
- `uploaded profile` — agent is successfully sending data
- `connection refused` — Pyroscope is unreachable (Step 2)
- `timeout` — network latency or firewall silently dropping packets
- `401` / `403` — authentication issue (if basic auth / tenant ID configured)

### Step 5: Is the server address correct?

```bash
# Check what address the agent is configured with
oc exec <pod-name> -n <namespace> -- env | grep -i pyroscope

# If using a properties file:
oc exec <pod-name> -n <namespace> -- cat /path/to/pyroscope.properties
```

Common mistakes:
- Using `localhost:4040` (only works if Pyroscope is in the same pod)
- Using a Kubernetes service DNS name for a VM-based Pyroscope (e.g., `pyroscope.monitoring.svc`)
- Wrong IP/hostname for the Pyroscope VM
- Missing port number (agent defaults to `http://localhost:4040`)

### Step 6: Is Pyroscope receiving the data?

```bash
# On the Pyroscope VM — check if any application names exist
curl -s 'http://localhost:4040/pyroscope/label-values?label=service_name'

# Or check the /ingest endpoint with verbose logging
docker logs pyroscope 2>&1 | grep -i "ingest\|error\|warn"

# Check the Pyroscope config
curl -s http://localhost:4040/config
```

If applications appear in the label-values response but not in the UI:
- Check the **time range** in the UI — profiles only appear after the agent has been
  running for at least one upload interval (default 10 seconds)
- Check the **application name** filter matches what the agent sends

### Step 7: Can Grafana reach Pyroscope?

```bash
# From the Grafana VM
curl -sv http://PYROSCOPE_VM_IP:4040/ready

# Test a query (same as Grafana datasource would)
curl -s -X POST http://PYROSCOPE_VM_IP:4040/querier.v1.QuerierService/ProfileTypes \
    -H "Content-Type: application/json" \
    -d '{}'
```

In Grafana:
- Go to **Connections → Data sources → Pyroscope → Test**
- If "Data source is working" appears, Grafana can reach Pyroscope
- Check the datasource URL matches `http://PYROSCOPE_VM_IP:4040`

### Quick diagnostic script

Run this from a machine with access to all components:

```bash
#!/bin/bash
PYROSCOPE_HOST="PYROSCOPE_VM_IP"
PYROSCOPE_PORT=4040

echo "=== 1. Pyroscope server ==="
curl -sf http://${PYROSCOPE_HOST}:${PYROSCOPE_PORT}/ready && echo " OK" || echo " FAIL"

echo "=== 2. Known applications ==="
curl -sf "http://${PYROSCOPE_HOST}:${PYROSCOPE_PORT}/pyroscope/label-values?label=service_name"
echo

echo "=== 3. Profile types ==="
curl -sf -X POST "http://${PYROSCOPE_HOST}:${PYROSCOPE_PORT}/querier.v1.QuerierService/ProfileTypes" \
    -H "Content-Type: application/json" -d '{}'
echo

echo "=== 4. Port listening ==="
nc -zv ${PYROSCOPE_HOST} ${PYROSCOPE_PORT} 2>&1

echo "=== 5. Pyroscope container logs (last 20 lines) ==="
# Run this on the Pyroscope VM:
# docker logs --tail 20 pyroscope
```

### Common root causes summary

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `curl: connection refused` from OCP pod | Firewall blocking TCP 4040 | Open firewall from OCP worker nodes to VM:4040 |
| `curl: connection timed out` from OCP pod | Silent drop by firewall/ACL | Same as above; check corporate firewall |
| Agent logs show no pyroscope messages | Agent JAR not loaded | Verify `-javaagent` in `JAVA_TOOL_OPTIONS` |
| Agent logs show `connection refused` | Wrong address or server down | Fix `PYROSCOPE_SERVER_ADDRESS`; verify server running |
| Server running, label-values returns `[]` | Agent not pushing (or pushing to wrong address) | Enable `PYROSCOPE_LOG_LEVEL=debug` on agent |
| Label-values returns apps, UI shows no data | Wrong time range in UI | Select "Last 15 minutes" and refresh |
| Grafana "No data" | Datasource URL wrong | Test datasource in Grafana settings |
| Grafana "Plugin not found" | Pyroscope datasource plugin not installed | Install `grafana-pyroscope-datasource` plugin |

# Pyroscope Unified Helm Chart

Deploys Pyroscope continuous profiling server on Kubernetes and OpenShift Container
Platform (OCP 4.12+). Supports both **monolith** and **microservices** modes from a
single chart with configurable namespace strategy, storage, networking, and Grafana
integration.

## Quick Start

```bash
# Monolith — same namespace as your apps (simplest)
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n <your-app-namespace> \
    -f deploy/helm/pyroscope/examples/monolith-same-namespace.yaml

# Monolith — dedicated namespace with NetworkPolicy
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/monolith-dedicated-namespace.yaml

# Microservices HA — OpenShift (requires RWX/NFS storage)
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/microservices-openshift.yaml

# Microservices HA — vanilla Kubernetes with Ingress
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/microservices-kubernetes.yaml
```

After install, the NOTES output shows the agent push URL and Grafana datasource URL.

## Configuration Reference

All values are in `values.yaml` with inline comments. Key settings:

| Value | Default | Description |
|-------|---------|-------------|
| `mode` | `monolith` | `monolith` (single pod) or `microservices` (7 pods, HA) |
| `image.repository` | `grafana/pyroscope` | Container image |
| `image.tag` | `"1.18.0"` | Image tag (quoted to prevent YAML float coercion) |
| `storage.accessMode` | `ReadWriteOnce` | `ReadWriteOnce` for monolith, `ReadWriteMany` for microservices |
| `storage.storageClassName` | `""` | Empty = cluster default; set to your RWX class for microservices |
| `storage.size` | `10Gi` | PVC size |
| `route.enabled` | `true` | Create OpenShift Route (set `false` on vanilla K8s) |
| `ingress.enabled` | `false` | Create K8s Ingress (alternative to Route) |
| `networkPolicy.enabled` | `false` | Create NetworkPolicy for cross-namespace access |
| `networkPolicy.allowedNamespaces` | `[]` | Namespace label selectors that can reach port 4040 |
| `grafana.location` | `external` | `same-namespace`, `different-namespace`, or `external` |
| `grafana.datasource.enabled` | `false` | Create ConfigMap for Grafana sidecar auto-provisioning |
| `monolith.replicas` | `1` | Monolith replica count |
| `distributor.replicas` | `1` | Microservices: distributor replicas |
| `ingester.replicas` | `3` | Microservices: ingester replicas (spread via pod anti-affinity) |
| `querier.replicas` | `2` | Microservices: querier replicas |

Override any value with `--set` or a custom values file:

```bash
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n pyroscope --create-namespace \
    -f deploy/helm/pyroscope/examples/microservices-openshift.yaml \
    --set storage.storageClassName=ocs-storagecluster-cephfs \
    --set storage.size=100Gi \
    --set ingester.replicas=5
```

## Example Values Files

| File | Scenario |
|------|----------|
| `examples/monolith-same-namespace.yaml` | Monolith alongside existing apps — simplest starting point |
| `examples/monolith-dedicated-namespace.yaml` | Monolith in own namespace with NetworkPolicy |
| `examples/microservices-openshift.yaml` | Full HA on OCP with RWX/NFS and Route |
| `examples/microservices-kubernetes.yaml` | Full HA on K8s with RWX/NFS and nginx Ingress |

## Agent Configuration

After deploying, configure your JVM applications to push profiles to Pyroscope.

**Agent target URL:**

| Mode | URL |
|------|-----|
| Monolith | `http://pyroscope.<namespace>.svc:4040` |
| Microservices | `http://<release>-distributor.<namespace>.svc:4040` |

**Option 1 — Properties file** (baked into image at build time):

```properties
pyroscope.server.address=http://pyroscope.<namespace>.svc:4040
pyroscope.application.name=my-service
pyroscope.format=jfr
```

**Option 2 — Environment variable** (in Deployment/DeploymentConfig spec):

```yaml
env:
  - name: PYROSCOPE_SERVER_ADDRESS
    value: "http://pyroscope.<namespace>.svc:4040"
  - name: PYROSCOPE_APPLICATION_NAME
    value: "my-service"
  - name: JAVA_TOOL_OPTIONS
    value: "-javaagent:/path/to/pyroscope.jar"
```

## Testing

### Offline test suite (`chart-test.sh`)

The chart ships with a comprehensive test script that validates all template
rendering offline — no cluster access required. It uses `helm lint` and
`helm template` to verify the chart produces correct Kubernetes manifests.

**Prerequisites:** `helm` 3.x on PATH.

**Run:**

```bash
bash deploy/helm/pyroscope/chart-test.sh
```

**Output:** Each test prints `PASS` or `FAIL`. The script exits 0 on success, 1 on failure.
Failed test names are listed at the bottom for triage.

```
=== 1. HELM LINT ===
  PASS: lint: default values
  PASS: lint: monolith-same-namespace
  ...
========================================
  RESULTS: 76 passed, 0 failed
========================================
```

### Test categories

The 76 tests are organized into 17 sections:

| # | Section | Tests | What it validates |
|---|---------|-------|-------------------|
| 1 | **Helm lint** | 5 | Chart syntax is valid for default values and all 4 example files |
| 2 | **Monolith resource counts** | 7 | Default monolith renders exactly 5 resources: ConfigMap, Deployment, PVC, Service, Route. No NetworkPolicy or Ingress. |
| 3 | **Monolith dedicated namespace** | 1 | Adding `monolith-dedicated-namespace.yaml` values enables NetworkPolicy |
| 4 | **Microservices OCP counts** | 5 | Microservices OCP renders 14 resources: ConfigMap, 7 Deployments, PVC, 3 Services, Route, NetworkPolicy |
| 5 | **Microservices K8s counts** | 5 | Microservices K8s renders 12 resources: swaps Route for Ingress, no NetworkPolicy |
| 6 | **ConfigMap content** | 7 | Monolith has no `memberlist` section; microservices uses headless service DNS (not StatefulSet-style per-pod DNS); correct `filesystem.dir` per mode; `self_profiling.disable_push` set |
| 7 | **PVC access modes** | 4 | Monolith PVC is `ReadWriteOnce`; microservices PVC is `ReadWriteMany` with `storageClassName` |
| 8 | **Headless service bug fix** | 3 | Ingester headless service exists with `clusterIP: None` and memberlist port 7946 (was missing in old chart) |
| 9 | **Route targets** | 2 | Monolith Route points to the monolith service; microservices Route points to `query-frontend` |
| 10 | **Ingress targets** | 1 | K8s Ingress backend points to `query-frontend` in microservices mode |
| 11 | **NetworkPolicy** | 3 | Allows TCP port 4040, includes same-namespace `podSelector: {}`, includes `namespaceSelector` for cross-namespace access |
| 12 | **Grafana datasource** | 6 | Disabled by default (no extra ConfigMap); when enabled creates ConfigMap with sidecar label, correct uid, correct URL per `grafana.location` (short DNS for same-namespace, FQDN for different-namespace) |
| 13 | **Deployment details** | 13 | Image tag flows through; monolith mounts `/data` without `-target` flag; all 7 microservices components have correct `-target=<component>` args; ingester has `podAntiAffinity` with `kubernetes.io/hostname` topology |
| 14 | **Labels** | 3 | All resources have `app.kubernetes.io/part-of`, `helm.sh/chart`, `app.kubernetes.io/managed-by` |
| 15 | **Idempotency (determinism)** | 2 | Running `helm template` twice with identical inputs produces byte-identical output for both monolith and microservices modes |
| 16 | **Value overrides** | 5 | `image.tag`, `storage.size`, `route.enabled=false`, `ingester.replicas`, `fullnameOverride` all propagate correctly |
| 17 | **Mutual exclusion** | 4 | Monolith mode renders zero microservices resources (no distributor, no ingester, no `-target=` flag); microservices mode renders zero monolith resources (no `component: monolith` label) |

### Test framework internals

The script uses three assertion functions:

| Function | Purpose |
|----------|---------|
| `assert "desc" command args...` | Passes if the command exits 0 |
| `assert_output "desc" "expected" command args...` | Passes if command stdout contains the expected string (fixed-string grep) |
| `assert_no_output "desc" "unexpected" command args...` | Passes if command stdout does NOT contain the string |

The helper `count_kind <Kind>` renders `helm template` and counts lines matching `^kind: <Kind>$`.

### What the offline tests cannot validate

These require a running Kubernetes/OCP cluster:

| Concern | Why | How to verify on cluster |
|---------|-----|------------------------|
| PVC binds to storage | Needs a real storage provisioner | `oc get pvc -n <ns>` — status should be `Bound` |
| Route gets a hostname | OCP router assigns it at runtime | `oc get route pyroscope -o jsonpath='{.spec.host}'` |
| NetworkPolicy blocks traffic | Needs real pod-to-pod networking | Deploy a pod in an unlisted namespace: `curl http://pyroscope.<ns>.svc:4040/ready` should timeout |
| Pyroscope pod passes readiness | Needs the container image to pull and start | `oc get pods -l app.kubernetes.io/part-of=pyroscope` — wait for `1/1 Running` |
| Agent can push profiles | Needs a JVM with agent pointing at the service | Check Pyroscope UI for incoming application names |
| `helm upgrade --install` idempotency | Needs Helm release state in the cluster | Run the install command twice; second run should print `Release "pyroscope" has been upgraded` |
| Grafana sidecar discovers datasource | Needs Grafana with sidecar watching the namespace | Check Grafana UI datasource list after setting `grafana.datasource.enabled=true` |

### On-cluster validation runbook

When you have OCP access, run this sequence:

```bash
# 1. Dry-run (validates API server accepts all resource types)
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n <app-ns> \
    -f deploy/helm/pyroscope/examples/monolith-same-namespace.yaml \
    --dry-run

# 2. Install
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n <app-ns> \
    -f deploy/helm/pyroscope/examples/monolith-same-namespace.yaml

# 3. Verify resources
oc get pods -n <app-ns> -l app.kubernetes.io/part-of=pyroscope
oc get pvc -n <app-ns>
oc get route pyroscope -n <app-ns>

# 4. Readiness check
oc exec deploy/pyroscope -n <app-ns> -- wget -qO- http://localhost:4040/ready

# 5. Idempotency — re-run the same command
helm upgrade --install pyroscope deploy/helm/pyroscope/ \
    -n <app-ns> \
    -f deploy/helm/pyroscope/examples/monolith-same-namespace.yaml
# Should say "Release ... has been upgraded" with no errors

# 6. Agent connectivity (from a FaaS pod in the same namespace)
oc exec deploy/<faas-bor> -n <app-ns> -- \
    wget -qO- http://pyroscope:4040/ready

# 7. Clean teardown
helm uninstall pyroscope -n <app-ns>
oc get pods -n <app-ns> -l app.kubernetes.io/part-of=pyroscope
# Should return "No resources found"
```

## Uninstall

```bash
helm uninstall pyroscope -n <namespace>
```

The PVC is not deleted by `helm uninstall` (Helm default for data safety). To remove it:

```bash
oc delete pvc pyroscope-data -n <namespace>
```

# Pyroscope Microservices — OpenShift (Helm)

Deploys Pyroscope in microservices mode on OpenShift 4.x using a Helm chart. Storage is backed by a ReadWriteMany PVC (typically NFS-backed via a storage class like `nfs-client`).

## Architecture

```mermaid
graph TB
    SDK[JVM Services] -->|push profiles<br/>Route / :4040| DIST
    G[Grafana] -->|query<br/>Route / :4040| QF

    subgraph OpenShift Project
        subgraph Write Path
            DIST[Distributor Pod]
            DIST --> ING1[Ingester Pod 1]
            DIST --> ING2[Ingester Pod 2]
            DIST --> ING3[Ingester Pod 3]
        end

        subgraph Read Path
            QF[Query Frontend Pod]
            QS[Query Scheduler Pod]
            Q1[Querier Pod 1]
            Q2[Querier Pod 2]
            QF --> QS
            QS --> Q1
            QS --> Q2
        end

        SG[Store Gateway Pod]
        C[Compactor Pod]

        RT[OpenShift Route]
        SVC_D[Service: distributor :4040]
        SVC_QF[Service: query-frontend :4040]
    end

    subgraph Storage
        PVC[("PVC (ReadWriteMany)<br/>NFS-backed")]
    end

    RT --> SVC_QF
    SVC_D --> DIST
    SVC_QF --> QF

    ING1 -->|flush| PVC
    ING2 -->|flush| PVC
    ING3 -->|flush| PVC
    Q1 --> SG
    Q2 --> SG
    SG -->|read blocks| PVC
    C -->|compact blocks| PVC
```

## Prerequisites

- OpenShift 4.x cluster with `helm` CLI
- A ReadWriteMany-capable storage class (e.g. `nfs-client`, `ocs-storagecluster-cephfs`)

## Quick start

```bash
# Install
helm install pyroscope deploy/microservices/openshift/helm/ \
  --namespace pyroscope --create-namespace

# Upgrade after changing values
helm upgrade pyroscope deploy/microservices/openshift/helm/ \
  --namespace pyroscope

# Uninstall
helm uninstall pyroscope --namespace pyroscope
```

## Values reference

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `grafana/pyroscope` | Container image repository |
| `image.tag` | `latest` | Container image tag |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `storage.storageClassName` | `""` (cluster default) | Storage class for the RWX PVC |
| `storage.size` | `50Gi` | PVC size |
| `distributor.replicas` | `1` | Distributor replica count |
| `ingester.replicas` | `3` | Ingester replica count |
| `querier.replicas` | `2` | Querier replica count |
| `queryFrontend.replicas` | `1` | Query Frontend replica count |
| `queryScheduler.replicas` | `1` | Query Scheduler replica count |
| `compactor.replicas` | `1` | Compactor replica count |
| `storeGateway.replicas` | `1` | Store Gateway replica count |
| `route.enabled` | `true` | Create an OpenShift Route for external access |
| `route.host` | `""` | Route hostname (auto-generated if empty) |

## Customizing storage class

```bash
helm install pyroscope deploy/microservices/openshift/helm/ \
  --namespace pyroscope --create-namespace \
  --set storage.storageClassName=nfs-client \
  --set storage.size=100Gi
```

## Endpoints

| Resource | Purpose |
|----------|---------|
| Service `*-distributor:4040` | SDK push endpoint (`/ingest`) |
| Service `*-query-frontend:4040` | Query endpoint (Grafana data source) |
| Route (if enabled) | External access to query-frontend |

For monolithic mode (single-node) deployments, see [`../../../monolithic/`](../../../monolithic/).

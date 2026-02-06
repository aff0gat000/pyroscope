# Pyroscope Microservices Deployment

Runs Pyroscope as separate, independently scalable components for high-availability production workloads. All storage uses NFS-backed filesystems — no MinIO or S3 required.

## Architecture

```mermaid
graph TB
    SDK[Application SDKs] -->|push profiles| DIST[Distributor]
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

## Choose your environment

| Environment | Path | How it works |
|-------------|------|-------------|
| **VM / Docker Compose** | [`vm/`](vm/) | Docker Compose on bare-metal or EC2; NFS bind-mounted into containers |
| **OpenShift** | [`openshift/`](openshift/) | Helm chart deploying Kubernetes Deployments with a ReadWriteMany PVC |

Both environments use identical Pyroscope component topology (9 services) and NFS-backed filesystem storage.

For simpler single-node deployments, see [`../monolithic/`](../monolithic/).

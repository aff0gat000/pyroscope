# Pyroscope Microservices — VM / Docker Compose

Runs Pyroscope as separate, independently scalable components on VMs using NFS-backed filesystem storage. Suitable for private enterprise environments where NFS is already available.

## Architecture

```mermaid
graph TB
    SDK1[Java SDK] -->|push profiles<br/>:4040| DIST
    SDK2[Go SDK] -->|push profiles<br/>:4040| DIST
    G[Grafana] -->|query<br/>:4041| QF

    subgraph VM 1
        DIST[Distributor]
        ING1[Ingester 1]
        C[Compactor]
    end

    subgraph VM 2
        ING2[Ingester 2]
        QF[Query Frontend]
        QS[Query Scheduler]
    end

    subgraph VM 3
        ING3[Ingester 3]
        Q1[Querier 1]
        Q2[Querier 2]
        SG[Store Gateway]
    end

    subgraph NFS Share
        NFS[("/mnt/pyroscope-data")]
    end

    DIST --> ING1
    DIST --> ING2
    DIST --> ING3
    ING1 -->|flush| NFS
    ING2 -->|flush| NFS
    ING3 -->|flush| NFS
    Q1 -->|read| SG
    Q2 -->|read| SG
    SG -->|read blocks| NFS
    C -->|compact blocks| NFS
    QF --> QS
    QS --> Q1
    QS --> Q2
```

### Data flow

```mermaid
sequenceDiagram
    participant SDK as Application SDK
    participant D as Distributor
    participant I as Ingester (x3)
    participant NFS as NFS Share
    participant C as Compactor
    participant QF as Query Frontend
    participant QS as Query Scheduler
    participant Q as Querier (x2)
    participant SG as Store Gateway

    SDK->>D: POST /ingest (profiles)
    D->>I: Route to ingester (hash ring)
    I->>NFS: Flush blocks to filesystem
    C->>NFS: Compact small blocks

    Note over QF,SG: Read path
    QF->>QS: Incoming query
    QS->>Q: Schedule query work
    Q->>I: Read recent data (in-memory)
    Q->>SG: Read historical data
    SG->>NFS: Fetch blocks from filesystem
    Q->>QF: Merged result
```

## Components

| Service | Replicas | Role |
|---------|----------|------|
| **distributor** | 1 | Routes incoming profiles to ingesters via consistent hash ring |
| **ingester** | 3 | Buffers profiles in memory, flushes completed blocks to NFS |
| **compactor** | 1 | Merges and deduplicates stored blocks for query efficiency |
| **query-frontend** | 1 | Entry point for reads; caches and parallelizes queries |
| **query-scheduler** | 1 | Distributes query work across querier replicas |
| **querier** | 2 | Reads and merges profile data from ingesters and store-gateway |
| **store-gateway** | 1 | Serves historical blocks from NFS |

All Pyroscope components discover each other via **memberlist** (gossip on port 7946).

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yaml` | Defines all services with NFS bind mounts |
| `pyroscope.yaml` | Shared config: filesystem storage, memberlist ring, port 4040 |
| `deploy.sh` | Lifecycle script with NFS pre-check (start/stop/restart/logs/status/clean) |

## Prerequisites

1. An NFS share mounted on every VM at the same path (default: `/mnt/pyroscope-data`)
2. Docker and Docker Compose installed

Example NFS mount:

```bash
sudo mkdir -p /mnt/pyroscope-data
sudo mount -t nfs nfs-server:/export/pyroscope /mnt/pyroscope-data
```

Add to `/etc/fstab` for persistence:

```
nfs-server:/export/pyroscope  /mnt/pyroscope-data  nfs  defaults,rw  0 0
```

## Quick start

```bash
bash deploy.sh          # Start all services
```

- Push profiles to `http://localhost:4040` (distributor)
- Query profiles at `http://localhost:4041` (query-frontend)

## Usage

```bash
bash deploy.sh              # Start (default)
bash deploy.sh stop         # Stop and remove all services
bash deploy.sh restart      # Restart all services
bash deploy.sh logs         # Tail logs from all services
bash deploy.sh status       # Show service status and health
bash deploy.sh clean        # Stop services and remove all volumes
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PYROSCOPE_DATA_DIR` | `/mnt/pyroscope-data` | Host path to the NFS-backed shared storage directory |
| `PYROSCOPE_PUSH_PORT` | `4040` | Host port for the distributor (SDK push endpoint) |
| `PYROSCOPE_QUERY_PORT` | `4041` | Host port for the query-frontend (Grafana data source) |

## Endpoints

| Port | Service | Purpose |
|------|---------|---------|
| `:4040` | Distributor | SDK push endpoint (`/ingest`) |
| `:4041` | Query Frontend | Query endpoint (configure as Grafana data source) |

For simpler single-node deployments, see [`../../monolithic/`](../../monolithic/).

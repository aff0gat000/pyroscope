# Pyroscope Monolithic Deployment — Mind Map & Decision Guide

## Mind Map

```mermaid
mindmap
  root((Pyroscope<br/>Monolithic<br/>Deployment))
    **Deploy Fresh**
      Option A: Script
        scp files to VM
        bash deploy.sh start --from-local
        Builds on VM — needs Docker Hub
      Option B: Manual
        scp Dockerfile + pyroscope.yaml
        docker build + docker run
        Builds on VM — needs Docker Hub
      Option C: Registry
        Build on workstation
        Push to internal registry
        Pull on VM — no Docker Hub needed
      Option D: docker save/load
        Build on workstation
        docker save → scp tar → docker load
        No registry, no Docker Hub on VM
    **Build & Push Images**
      build-and-push.sh
        --version to pin release
        --registry for internal registry
        --platform linux/amd64 for Mac→Linux
        --push to push to registry
        --save to export tar
        --pull-only for official image
        --dry-run to preview
        --list-tags to check versions
        --clean to remove everything
      Manual docker build
        Stage files in deploy/monolithic/
        docker build + docker tag + docker push
    **Day-2 Operations**
      Health & Status
        curl localhost:4040/ready
        bash deploy.sh status
        docker exec pyroscope wget /ready
      Logs
        docker logs -f pyroscope
        docker logs --since 1h pyroscope
      Config Changes
        Baked-in: edit yaml → rebuild → restart
        Mounted: edit /opt/pyroscope/pyroscope.yaml → docker restart
      Upgrade
        Build new version
        docker rm -f pyroscope
        docker run with new tag
        Volume preserved
      Rollback
        docker rm -f pyroscope
        docker run with old tag
      Backup & Restore
        docker run alpine tar czf backup
        Stop → restore → start
      Cleanup
        deploy.sh clean
        build-and-push.sh --clean
        Manual: rm container + image + volume
    **Troubleshooting**
      Build fails: i/o timeout
        VM cannot reach Docker Hub
        Use Option C or D instead
      Port 4040 already in use
        Change port: PYROSCOPE_PORT=9090
      Container not healthy
        Check logs: docker logs pyroscope
        Check config: pyroscope.yaml
      Permission denied
        Must run as root: pbrun /bin/su -
    **Files in Repo**
      deploy/monolithic/
        Dockerfile — official base image
        Dockerfile.custom — Alpine/UBI/Debian base
        pyroscope.yaml — server config
        deploy.sh — lifecycle script
        deploy-test.sh — 45 unit tests
        build-and-push.sh — build + push + save
      config/grafana/
        provisioning/ — datasources, plugins
        dashboards/ — 6 JSON dashboards
      docs/
        grafana-setup.md — add to existing Grafana
```

## Decision Flowchart: Which Option Do I Use?

```mermaid
flowchart TD
    START([I need to deploy Pyroscope]) --> Q1{Can the target VM<br/>reach Docker Hub?}

    Q1 -->|Yes| Q2{Do you want a<br/>script or manual?}
    Q1 -->|No| Q3{Do you have an<br/>internal Docker registry?}

    Q2 -->|Script| A["**Option A: Deploy with Script**<br/>───────────────────<br/>scp deploy.sh + Dockerfile + pyroscope.yaml<br/>→ ssh + pbrun<br/>→ bash deploy.sh start --from-local<br/>───────────────────<br/>📁 deploy/monolithic/deploy.sh"]
    Q2 -->|Manual| B["**Option B: Deploy Manually**<br/>───────────────────<br/>scp Dockerfile + pyroscope.yaml<br/>→ docker build -t pyroscope-server .<br/>→ docker run -d -p 4040:4040 ...<br/>───────────────────<br/>📁 deploy/monolithic/README.md"]

    Q3 -->|Yes| Q4{Script or manual<br/>build + push?}
    Q3 -->|No| D["**Option D: docker save/load**<br/>───────────────────<br/>Workstation: build + docker save<br/>→ scp tar to VM<br/>→ VM: docker load + docker run<br/>───────────────────<br/>📁 deploy/monolithic/build-and-push.sh --save"]

    Q4 -->|Script| C1["**Option C: Script Build + Push**<br/>───────────────────<br/>bash build-and-push.sh \<br/>  --version 1.18.0 --push<br/>VM: docker pull + docker run<br/>───────────────────<br/>📁 deploy/monolithic/build-and-push.sh"]
    Q4 -->|Manual| C2["**Option C: Manual Build + Push**<br/>───────────────────<br/>docker build + docker tag + docker push<br/>VM: docker pull + docker run<br/>───────────────────<br/>📁 deploy/monolithic/DOCKER-BUILD.md"]
    Q4 -->|Just pull official| C3["**Option C: Pull-Only**<br/>───────────────────<br/>docker pull grafana/pyroscope:1.18.0<br/>→ docker tag → docker push to registry<br/>VM: docker pull + mount pyroscope.yaml<br/>───────────────────<br/>📁 build-and-push.sh --pull-only"]

    A --> DONE([✅ Pyroscope running on :4040])
    B --> DONE
    C1 --> DONE
    C2 --> DONE
    C3 --> DONE
    D --> DONE

    style A fill:#e8f5e9,stroke:#4caf50
    style B fill:#e8f5e9,stroke:#4caf50
    style C1 fill:#e3f2fd,stroke:#2196f3
    style C2 fill:#e3f2fd,stroke:#2196f3
    style C3 fill:#e3f2fd,stroke:#2196f3
    style D fill:#fff3e0,stroke:#ff9800
    style DONE fill:#c8e6c9,stroke:#388e3c
```

## Decision Flowchart: Building on Mac for Linux VM

```mermaid
flowchart TD
    START([Building Docker image]) --> Q1{What is your<br/>workstation?}

    Q1 -->|Linux x86_64| BUILD["docker build -t pyroscope-server ."]
    Q1 -->|Mac Intel| BUILD
    Q1 -->|Mac Apple Silicon<br/>M1/M2/M3/M4| CROSS["Must cross-compile:<br/>docker build **--platform linux/amd64** ..."]

    BUILD --> OK([Image ready])
    CROSS --> OK

    style CROSS fill:#fff3e0,stroke:#ff9800
```

## Config Baked-in vs Mounted — When to Use Which

```mermaid
flowchart TD
    START([How should pyroscope.yaml<br/>be handled?]) --> Q1{Will you need to<br/>change config on the VM<br/>without rebuilding?}

    Q1 -->|Yes — mount it| MOUNT["**Mount at runtime**<br/>───────────────────<br/>docker run ... \<br/>  -v /opt/pyroscope/pyroscope.yaml:/etc/pyroscope/config.yaml:ro \<br/>  pyroscope-server:1.18.0<br/>───────────────────<br/>Edit → docker restart pyroscope<br/>No rebuild needed"]

    Q1 -->|No — bake it in| BAKE["**Bake into image**<br/>───────────────────<br/>docker run ... \<br/>  pyroscope-server:1.18.0<br/>───────────────────<br/>Config changes require rebuild<br/>Simpler runtime (no files on VM)"]

    Q1 -->|Not sure| REC["**Recommended: mount it**<br/>Even if config is baked in,<br/>mounting overrides it.<br/>Best of both worlds."]

    style MOUNT fill:#e3f2fd,stroke:#2196f3
    style BAKE fill:#e8f5e9,stroke:#4caf50
    style REC fill:#f3e5f5,stroke:#9c27b0
```

## Day-2 Operations Quick Reference

```mermaid
flowchart LR
    subgraph "Health & Monitoring"
        H1["curl localhost:4040/ready"]
        H2["bash deploy.sh status"]
        H3["docker logs -f pyroscope"]
    end

    subgraph "Lifecycle"
        L1["deploy.sh stop"]
        L2["deploy.sh start"]
        L3["deploy.sh restart"]
        L4["docker restart pyroscope"]
    end

    subgraph "Upgrade"
        U1["Build new version"] --> U2["docker rm -f pyroscope"]
        U2 --> U3["docker run with new tag"]
        U3 --> U4["Volume preserved ✓"]
    end

    subgraph "Rollback"
        R1["docker rm -f pyroscope"] --> R2["docker run with OLD tag"]
        R2 --> R3["Volume preserved ✓"]
    end

    subgraph "Cleanup"
        C1["deploy.sh clean<br/>(removes everything)"]
        C2["build-and-push.sh --clean-keep-data<br/>(keeps volume + config)"]
    end
```

## File Map: What's Where and When to Use It

```
repo root/
│
├── deploy/monolithic/                     ← ALL DEPLOYMENT FILES
│   │
│   ├── Dockerfile                         ← Standard build (official grafana/pyroscope base)
│   │                                        Used by: Options A, B, C (build), D
│   │
│   ├── Dockerfile.custom                  ← Custom base (Alpine, UBI, Debian, distroless)
│   │                                        Used by: enterprises requiring specific base images
│   │
│   ├── pyroscope.yaml                     ← Server config (filesystem storage at /data, port 4040)
│   │                                        Used by: ALL options
│   │
│   ├── deploy.sh                          ← Lifecycle script (start/stop/restart/logs/status/clean)
│   │                                        Used by: Option A, day-2 operations
│   │
│   ├── build-and-push.sh                  ← Build, tag, push, save, clean
│   │                                        Used by: Options C, D, cleanup
│   │
│   ├── deploy-test.sh                     ← 45 unit tests for deploy.sh
│   │                                        Run: bash deploy-test.sh (no root/Docker needed)
│   │
│   ├── README.md                          ← Complete deployment guide (Options A-D, day-2)
│   │                                        START HERE if deploying Pyroscope
│   │
│   └── DOCKER-BUILD.md                    ← Docker image build guide (Options A-D build focus)
│                                            START HERE if building images for registry
│
├── config/grafana/                        ← GRAFANA CONFIGURATION
│   ├── provisioning/
│   │   ├── datasources/datasources.yaml   ← Pyroscope + Prometheus datasources
│   │   ├── dashboards/dashboards.yaml     ← Dashboard provisioning config
│   │   └── plugins/plugins.yaml           ← Pyroscope plugin enablement
│   └── dashboards/
│       ├── pyroscope-overview.json        ← Top-level profiling overview
│       ├── http-performance.json          ← HTTP endpoint profiling
│       ├── verticle-performance.json      ← Vert.x verticle profiling
│       ├── before-after-comparison.json   ← Before/after flame graph comparison
│       ├── faas-server.json               ← FaaS runtime dashboard
│       └── jvm-metrics.json               ← JVM internals (needs Prometheus)
│
├── deploy/grafana/                        ← GRAFANA DEPLOYMENT (separate process)
│   └── README.md                          ← Standalone Grafana with baked-in dashboards
│
└── docs/
    ├── grafana-setup.md                   ← Add Pyroscope to EXISTING Grafana
    └── monolithic-deployment-guide.md     ← THIS FILE (mind map & decision guide)
```

## Scenario Quick Reference

| I want to... | Go to | Command / Option |
|---|---|---|
| Deploy Pyroscope for the first time | [README.md Option A](../deploy/monolithic/README.md#option-a-deploy-with-script) | `bash deploy.sh start --from-local` |
| Deploy without any script | [README.md Option B](../deploy/monolithic/README.md#option-b-deploy-manually-without-script) | `docker build` + `docker run` |
| Deploy but VM has no internet | [README.md Option C](../deploy/monolithic/README.md#option-c-pre-built-image-from-internal-registry) | `build-and-push.sh --push` then `docker pull` on VM |
| Deploy but VM has no internet AND no registry | [README.md Option D](../deploy/monolithic/README.md#option-d-build-locally-and-scp-image-to-vm-no-registry-needed) | `build-and-push.sh --save` then `scp` + `docker load` |
| Build image and push to internal registry | [DOCKER-BUILD.md](../deploy/monolithic/DOCKER-BUILD.md#option-a-build-and-push-with-script-recommended) | `build-and-push.sh --version 1.18.0 --push` |
| Push official image without building | [DOCKER-BUILD.md Option C](../deploy/monolithic/DOCKER-BUILD.md#option-c-pull-and-push-official-image-directly-no-build) | `build-and-push.sh --pull-only --push` |
| Build on Mac for Linux VM | [README.md cross-compile](../deploy/monolithic/README.md#building-from-a-mac-for-rhel) | Add `--platform linux/amd64` |
| Check what versions are available | [build-and-push.sh](../deploy/monolithic/build-and-push.sh) | `build-and-push.sh --list-tags` |
| Preview build without executing | [build-and-push.sh](../deploy/monolithic/build-and-push.sh) | `build-and-push.sh --dry-run` |
| Check if Pyroscope is healthy | [README.md Day-2](../deploy/monolithic/README.md#health-check) | `curl localhost:4040/ready` or `deploy.sh status` |
| View Pyroscope logs | [README.md Day-2](../deploy/monolithic/README.md#view-logs) | `docker logs -f pyroscope` or `deploy.sh logs` |
| Change pyroscope.yaml config | [README.md Day-2](../deploy/monolithic/README.md#config-changes) | Edit file → `docker restart pyroscope` |
| Upgrade to a new version | [README.md Upgrading](../deploy/monolithic/README.md#upgrading-to-a-new-pyroscope-version) | Build new → `docker rm -f` → `docker run` new |
| Roll back to previous version | [README.md Rolling back](../deploy/monolithic/README.md#rolling-back) | `docker rm -f` → `docker run` old tag |
| Back up profiling data | [README.md Backup](../deploy/monolithic/README.md#backup-profiling-data) | `docker run alpine tar czf` |
| Remove everything from VM | [README.md Cleanup](../deploy/monolithic/README.md#cleanup-and-uninstall) | `build-and-push.sh --clean` or `deploy.sh clean` |
| Remove container/image but keep data | [build-and-push.sh](../deploy/monolithic/build-and-push.sh) | `build-and-push.sh --clean-keep-data` |
| Add Pyroscope dashboards to existing Grafana | [grafana-setup.md](grafana-setup.md) | Copy provisioning + dashboards + restart |
| Deploy standalone Grafana with Pyroscope | [deploy/grafana/](../deploy/grafana/README.md) | Same patterns as Pyroscope deployment |
| Run deployment tests | [deploy-test.sh](../deploy/monolithic/deploy-test.sh) | `bash deploy-test.sh` (no root/Docker needed) |
| Use a custom base image (UBI, Alpine, Debian) | [DOCKER-BUILD.md Custom](../deploy/monolithic/DOCKER-BUILD.md#building-with-a-custom-base-image) | `docker build -f Dockerfile.custom` |

## Deployment Lifecycle

```mermaid
flowchart LR
    subgraph "1. BUILD<br/>(workstation — has internet)"
        B1[Dockerfile]
        B2[pyroscope.yaml]
        B3[build-and-push.sh]
    end

    subgraph "2. DEPLOY<br/>(target VM — may not have internet)"
        D1["deploy.sh start"]
        D2["--from-local"]
        D3["--from-git"]
    end

    subgraph "3. OPERATE<br/>(target VM — as root)"
        O1[status / logs]
        O2[config changes]
        O3[upgrade / rollback]
        O4[backup / restore]
    end

    subgraph "4. RETIRE<br/>(target VM — as root)"
        R1["deploy.sh clean"]
        R2["build-and-push.sh --clean"]
    end

    B1 --> D1
    B2 --> D1
    B3 --> D1
    D1 --> O1
    O1 --> R1

    style B1 fill:#e3f2fd,stroke:#2196f3
    style B2 fill:#e3f2fd,stroke:#2196f3
    style B3 fill:#e3f2fd,stroke:#2196f3
    style D1 fill:#e8f5e9,stroke:#4caf50
    style D2 fill:#e8f5e9,stroke:#4caf50
    style D3 fill:#e8f5e9,stroke:#4caf50
    style R1 fill:#ffebee,stroke:#f44336
    style R2 fill:#ffebee,stroke:#f44336
```

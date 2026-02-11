# Grafana Deployment

Grafana deployed as a standalone Docker container with **baked-in Pyroscope datasource, dashboards, and provisioning config**. Suitable for teams that need a dedicated Grafana instance for Pyroscope profiling visualization on enterprise VMs.

> **Already have Grafana?** You don't need this deployment. Instead, follow [docs/grafana-setup.md](../../docs/grafana-setup.md) to add the Pyroscope datasource and dashboards to your existing Grafana instance.

## Architecture

```mermaid
graph LR
    subgraph Grafana VM
        subgraph Docker Container
            G[Grafana Server<br/>port 3000]
            GD[("/var/lib/grafana<br/>(dashboards, DB)")]
            G --> GD
        end
    end

    subgraph Pyroscope VM
        P[Pyroscope Server<br/>port 4040]
    end

    subgraph Prometheus VM
        PR[Prometheus<br/>port 9090]
    end

    G -->|query profiles<br/>:4040| P
    G -.->|query metrics<br/>:9090<br/>(optional)| PR
    U[Operator] -->|browse<br/>:3000| G
```

Grafana connects to Pyroscope as a datasource to visualize flame graphs, profile comparisons, and application profiling data. The Prometheus connection is optional — it's only needed if you want JVM metrics dashboards alongside profiling.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Production image from official `grafana/grafana` base. Pinned version, non-root user, HEALTHCHECK. Bakes in grafana.ini, provisioning, and dashboards. |
| `grafana.ini` | Grafana config: port 3000, admin credentials, provisioning paths, Pyroscope plugin allowlist |
| `deploy.sh` | Lifecycle script (start/stop/restart/logs/status/clean) with Git and local source options |
| `deploy-test.sh` | Mock-based unit tests for deploy.sh (no root or Docker needed) |
| `build-and-push.sh` | Build Grafana image with pinned version and push to internal Docker registry |
| `DOCKER-BUILD.md` | Full guide for building, pushing, and managing Grafana Docker images |

## Prerequisites

- **Docker** installed and running on the target VM
- **Root access** via `pbrun /bin/su -`
- **Port 3000** available (or choose a different port)
- **Pyroscope running** — verify with `curl -s http://<PYROSCOPE_VM_IP>:4040/ready`

## Directory Layout

| Location | Purpose |
|----------|---------|
| **Your workstation** | |
| `deploy/grafana/` | Source files in your local repo clone (Dockerfile, grafana.ini, deploy.sh) |
| `config/grafana/` | Provisioning configs and dashboard JSON files (copied into image at build time) |
| **Target VM** | |
| `/tmp/grafana-deploy/` | Temporary landing directory for scp (deleted after install) |
| `/opt/grafana/` | Permanent install directory on the VM (Dockerfile + config live here) |
| Docker volume `grafana-data` | Mounted as `/var/lib/grafana` inside the container — stores Grafana DB, sessions, plugins |

---

## Option A: Deploy with Script

### Step 1: Copy files to the VM (from your workstation)

The build script stages provisioning and dashboard files from `config/grafana/` into the build context. When deploying via scp, you need to include these files.

```bash
# Create the landing directory on the VM
ssh operator@vm01.corp.example.com "mkdir -p /tmp/grafana-deploy"

# Copy the deploy files
scp deploy/grafana/deploy.sh \
    deploy/grafana/Dockerfile \
    deploy/grafana/grafana.ini \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/

# Copy provisioning and dashboard files
scp -r config/grafana/provisioning \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/provisioning

scp -r config/grafana/dashboards \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/dashboards
```

After this step, the VM has:

```
/tmp/grafana-deploy/
├── deploy.sh
├── Dockerfile
├── grafana.ini
├── provisioning/
│   ├── dashboards/
│   │   └── dashboards.yaml
│   ├── datasources/
│   │   └── datasources.yaml
│   └── plugins/
│       └── plugins.yaml
└── dashboards/
    ├── before-after-comparison.json
    ├── faas-server.json
    ├── http-performance.json
    ├── jvm-metrics.json
    ├── pyroscope-overview.json
    └── verticle-performance.json
```

### Step 2: SSH to the VM

```bash
ssh operator@vm01.corp.example.com
```

### Step 3: Elevate to root

```bash
pbrun /bin/su -
```

### Step 4: Pre-flight checks

```bash
# Verify Docker is installed and running
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker NOT available"

# Check that port 3000 is not already in use
ss -tlnp | grep :3000

# Check no container named 'grafana' already exists
docker ps -a --format '{{.Names}}' | grep -x grafana || echo "No conflict"
```

If Docker is not installed (RHEL 8):

```bash
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io
systemctl start docker && systemctl enable docker
```

### Step 5: Deploy

```bash
bash /tmp/grafana-deploy/deploy.sh start --from-local /tmp/grafana-deploy
```

The script will:

1. Verify you are root and Docker is running
2. Copy `Dockerfile`, `grafana.ini`, `provisioning/`, and `dashboards/` from `/tmp/grafana-deploy/` to `/opt/grafana/`
3. Build the Docker image `grafana-server` from `/opt/grafana/Dockerfile`
4. Create a Docker volume `grafana-data` (if it does not already exist)
5. Start the container `grafana` on port 3000
6. Wait up to 60 seconds for the health check (`/api/health` endpoint)
7. Print a connection summary with the VM IP address

> **If step 3 fails with `i/o timeout` or `failed to resolve source metadata`:**
> The VM cannot reach Docker Hub. Use [Option C](#option-c-pre-built-image-from-internal-registry) instead — build the image on your workstation (which has internet access), push to your internal registry, then pull on the VM. See [DOCKER-BUILD.md](DOCKER-BUILD.md) for the full walkthrough.

To use a different port:

```bash
GRAFANA_PORT=8080 bash /tmp/grafana-deploy/deploy.sh start --from-local /tmp/grafana-deploy
```

### Step 6: Verify

```bash
curl -s http://localhost:3000/api/health && echo " OK"
```

Open `http://<VM_IP>:3000` in a browser. Default credentials: `admin` / `admin`.

### Step 7: Clean up and keep deploy.sh for day-2

```bash
# Copy deploy.sh to the install directory for future use
cp /tmp/grafana-deploy/deploy.sh /opt/grafana/deploy.sh

# Remove the temp landing directory
rm -rf /tmp/grafana-deploy
```

After cleanup, the VM has:

```
/opt/grafana/
├── deploy.sh          # lifecycle script for day-2 operations
├── Dockerfile         # used by docker build
├── grafana.ini        # Grafana config
├── provisioning/      # datasources, dashboards, plugins provisioning
└── dashboards/        # 6 pre-built dashboard JSON files
```

---

## Option B: Deploy Manually (without script)

If you prefer not to use the deploy script, run the Docker commands directly.

### Step 1: Copy files to the VM (from your workstation)

```bash
ssh operator@vm01.corp.example.com "mkdir -p /tmp/grafana-deploy"

scp deploy/grafana/Dockerfile \
    deploy/grafana/grafana.ini \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/

scp -r config/grafana/provisioning \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/provisioning

scp -r config/grafana/dashboards \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/dashboards
```

### Step 2: SSH to the VM and elevate to root

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -
```

### Step 3: Pre-flight checks

```bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker NOT available"
ss -tlnp | grep :3000
```

### Step 4: Copy files to the install directory

```bash
mkdir -p /opt/grafana
cp /tmp/grafana-deploy/Dockerfile   /opt/grafana/Dockerfile
cp /tmp/grafana-deploy/grafana.ini  /opt/grafana/grafana.ini
cp -r /tmp/grafana-deploy/provisioning /opt/grafana/provisioning
cp -r /tmp/grafana-deploy/dashboards  /opt/grafana/dashboards
```

### Step 5: Build the Docker image

```bash
cd /opt/grafana
docker build -t grafana-server .
```

This builds an image from the Dockerfile, which:
- Pulls `grafana/grafana:11.5.2` from Docker Hub
- Copies `grafana.ini` into the image as `/etc/grafana/grafana.ini`
- Copies provisioning files and dashboards into the image
- Installs Pyroscope plugins via `GF_INSTALL_PLUGINS`

If the VM cannot reach Docker Hub, use a base image from your internal registry:

```bash
docker build --build-arg BASE_IMAGE=company.corp.com/docker-proxy/grafana/grafana:11.5.2 \
    -t grafana-server .
```

Or use [Option C](#option-c-pre-built-image-from-internal-registry) to avoid building on the VM entirely.

### Step 6: Create the data volume

```bash
docker volume create grafana-data
```

This volume persists Grafana's database, sessions, and plugin data across container restarts. It is mounted as `/var/lib/grafana` inside the container.

### Step 7: Start the container

```bash
docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    grafana-server
```

To use a different host port (e.g., 8080):

```bash
docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 8080:3000 \
    -v grafana-data:/var/lib/grafana \
    grafana-server
```

To override admin credentials:

```bash
docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    -e GF_SECURITY_ADMIN_PASSWORD=MySecurePassword \
    grafana-server
```

### Step 8: Wait for health check

```bash
# Poll until ready (up to 60 seconds)
for i in $(seq 1 30); do
    if docker exec grafana wget -q --spider http://localhost:3000/api/health 2>/dev/null; then
        echo "Grafana is ready"
        break
    fi
    sleep 2
done
```

### Step 9: Verify

```bash
curl -s http://localhost:3000/api/health && echo " OK"
docker ps --filter "name=^grafana$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### Step 10: Clean up temp files

```bash
rm -rf /tmp/grafana-deploy
```

After cleanup, the VM has:

```
/opt/grafana/
├── Dockerfile         # kept for rebuilds
├── grafana.ini        # kept for reference
├── provisioning/      # kept for reference
└── dashboards/        # kept for reference

Docker:
  Image:     grafana-server
  Container: grafana (port 3000)
  Volume:    grafana-data (mounted as /var/lib/grafana)
```

### Manual day-2 operations

```bash
# View logs
docker logs -f grafana

# Stop (data volume preserved)
docker rm -f grafana

# Restart (rebuild image first if config changed)
cd /opt/grafana && docker build -t grafana-server .
docker rm -f grafana 2>/dev/null
docker run -d --name grafana --restart unless-stopped -p 3000:3000 -v grafana-data:/var/lib/grafana grafana-server

# Full cleanup (removes container, image, and all Grafana data)
docker rm -f grafana 2>/dev/null
docker rmi grafana-server 2>/dev/null
docker volume rm grafana-data 2>/dev/null
```

---

## Option C: Pre-built Image from Internal Registry

Use this when VMs cannot reach Docker Hub (common in enterprise networks). Build the image once from a machine with internet access, push to your internal Docker registry (e.g., Artifactory, Nexus, Harbor), then pull on VMs.

### Why this option?

Options A and B run `docker build` on the VM, which requires pulling `grafana/grafana` from Docker Hub. If the VM has no internet access, the build fails with:

```
failed to resolve source metadata for docker.io/grafana/grafana:11.5.2: dial ... i/o timeout
```

Option C solves this by building and pushing the image from your workstation (which has internet access) to an internal registry that VMs can reach.

### Building from a Mac for RHEL

If building on an Apple Silicon Mac (M1/M2/M3) for a RHEL 8 x86_64 VM, you must specify the target platform. Without this, Docker builds an ARM image that will not run on the VM.

Add `--platform linux/amd64` to all `docker build` commands:

```bash
docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/grafana:11.5.2 \
    -t grafana-server:11.5.2 .
```

Or with the script:

```bash
bash build-and-push.sh --version 11.5.2 --platform linux/amd64 \
    --registry company.corp.com/docker-proxy/grafana --push
```

### Step 1: Check available versions (from your workstation)

Using the script:

```bash
bash deploy/grafana/build-and-push.sh --list-tags
```

Or manually with curl:

```bash
curl -s "https://hub.docker.com/v2/repositories/grafana/grafana/tags/?page_size=15&ordering=last_updated" \
    | grep -oP '"name"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | head -10
```

Pick a version (e.g., `11.5.2`). Avoid using `latest` in production.

### Step 2: Build and push from your workstation

Choose **2a** (script), **2b** (manual), or **2c** (pull official image directly). All three produce the same registry image.

#### Step 2a: Build and push with script

```bash
cd deploy/grafana

# Preview what would happen (no changes made)
bash build-and-push.sh --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --push --dry-run

# Build and push to your internal registry
bash build-and-push.sh --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --push

# Also update the :latest tag in the registry
bash build-and-push.sh --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --push --latest
```

If building on a Mac/ARM workstation for Linux x86_64 VMs:

```bash
bash build-and-push.sh --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --platform linux/amd64 --push
```

#### Step 2b: Build and push manually (without script)

You must stage the provisioning and dashboard files before building:

```bash
cd deploy/grafana

# Stage files from config/grafana/ into build context
cp -r ../../config/grafana/provisioning .
cp -r ../../config/grafana/dashboards .

# 1. Build the image with a pinned version
docker build --build-arg BASE_IMAGE=grafana/grafana:11.5.2 \
    -t grafana-server:11.5.2 .

# 2. Tag for your internal registry
docker tag grafana-server:11.5.2 \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2

# 3. Log in to your internal registry (if not already authenticated)
docker login company.corp.com

# 4. Push
docker push company.corp.com/docker-proxy/grafana/grafana-server:11.5.2

# 5. Optionally update the :latest tag
docker tag grafana-server:11.5.2 \
    company.corp.com/docker-proxy/grafana/grafana-server:latest
docker push company.corp.com/docker-proxy/grafana/grafana-server:latest

# 6. Clean up staged files
rm -rf provisioning dashboards
```

If building on a Mac/ARM workstation for Linux x86_64 VMs, add `--platform linux/amd64` to the build:

```bash
docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/grafana:11.5.2 \
    -t grafana-server:11.5.2 .
```

#### Step 2c: Pull and push official image directly (no build)

The simplest option — pull the official `grafana/grafana` image from Docker Hub on your workstation, re-tag it for your internal registry, and push. No Dockerfile or build step needed. Config is mounted at runtime on the VM instead of baked into the image.

With the script:

```bash
bash build-and-push.sh --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --pull-only --push
```

From a Mac for RHEL x86_64:

```bash
bash build-and-push.sh --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --pull-only --platform linux/amd64 --push
```

Or manually without the script:

```bash
# 1. Pull the official image
docker pull --platform linux/amd64 grafana/grafana:11.5.2

# 2. Tag for your internal registry
docker tag grafana/grafana:11.5.2 \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2

# 3. Log in to your internal registry (if not already authenticated)
docker login company.corp.com

# 4. Push
docker push company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

> **Note:** Step 2c pushes the official image without `grafana.ini` or dashboards baked in. You must copy configuration files to the VM and mount them at runtime (see step 6 below).

#### Result

Steps 2a, 2b, and 2c all produce:

```
company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
company.corp.com/docker-proxy/grafana/grafana-server:latest   (if --latest)
```

If you used step 2a or 2b, the image has `grafana.ini`, provisioning, and dashboards baked in — no config files needed on the VM. If you used step 2c, you must copy configuration to the VM and mount it at runtime (see step 6).

### Step 3: Copy config files to the VM (step 2c only)

Skip this step if you used 2a or 2b (config is already baked into the image).

From your workstation:

```bash
ssh operator@vm01.corp.example.com "mkdir -p /opt/grafana"
scp deploy/grafana/grafana.ini operator@vm01.corp.example.com:/opt/grafana/grafana.ini
scp -r config/grafana/provisioning operator@vm01.corp.example.com:/opt/grafana/provisioning
scp -r config/grafana/dashboards operator@vm01.corp.example.com:/opt/grafana/dashboards
```

### Step 4: SSH to the VM and elevate to root

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -
```

### Step 5: Pre-flight checks

```bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker NOT available"
ss -tlnp | grep :3000
```

### Step 6: Pull the image from your internal registry

```bash
docker pull company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 7: Create the data volume and start the container

If you used **step 2a or 2b** (config baked in):

```bash
docker volume create grafana-data

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

If you used **step 2c** (official image, config mounted at runtime):

```bash
docker volume create grafana-data

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    -v /opt/grafana/grafana.ini:/etc/grafana/grafana.ini:ro \
    -v /opt/grafana/provisioning:/etc/grafana/provisioning:ro \
    -v /opt/grafana/dashboards:/var/lib/grafana/dashboards:ro \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 8: Verify

```bash
# Wait for health check
for i in $(seq 1 30); do
    if docker exec grafana wget -q --spider http://localhost:3000/api/health 2>/dev/null; then
        echo "Grafana is ready"
        break
    fi
    sleep 2
done

curl -s http://localhost:3000/api/health && echo " OK"
```

Open `http://<VM_IP>:3000` in a browser. Default credentials: `admin` / `admin`.

After deployment, the VM has:

```
/opt/grafana/
├── grafana.ini        # only if step 2c (mounted at runtime)
├── provisioning/      # only if step 2c
└── dashboards/        # only if step 2c

Docker:
  Image:     company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
  Container: grafana (port 3000)
  Volume:    grafana-data (mounted as /var/lib/grafana)
```

### Upgrading to a new Grafana version

**On your workstation — build and push the new version:**

With the script:

```bash
bash deploy/grafana/build-and-push.sh --version 11.6.0 \
    --registry company.corp.com/docker-proxy/grafana \
    --push --latest
```

Or manually:

```bash
cd deploy/grafana

# Stage files
cp -r ../../config/grafana/provisioning .
cp -r ../../config/grafana/dashboards .

docker build --build-arg BASE_IMAGE=grafana/grafana:11.6.0 \
    -t grafana-server:11.6.0 .

docker tag grafana-server:11.6.0 \
    company.corp.com/docker-proxy/grafana/grafana-server:11.6.0

docker push company.corp.com/docker-proxy/grafana/grafana-server:11.6.0

rm -rf provisioning dashboards
```

**On the VM — pull and replace the container:**

```bash
docker pull company.corp.com/docker-proxy/grafana/grafana-server:11.6.0
docker rm -f grafana
docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    company.corp.com/docker-proxy/grafana/grafana-server:11.6.0
```

The data volume is preserved across upgrades.

### Rolling back

```bash
docker rm -f grafana
docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

---

## Option D: Build Locally and SCP Image to VM (No Registry Needed)

Use this when the VM cannot pull from Docker Hub or your internal registry (e.g., `client does not have permissions to that manifest`). Build the image on your workstation, export it as a tar file, scp it to the VM, and load it directly. No registry access needed on the VM at all.

### Steps 1-2: Build and export (with script)

The script builds the image and saves it as a tar file in one command:

```bash
cd deploy/grafana

bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --save
```

This produces `./grafana-server-11.5.2.tar` with `grafana.ini`, provisioning, and dashboards baked in. No config files needed on the VM.

To save to a custom path:

```bash
bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --save /tmp/grafana.tar
```

### Steps 1-2: Build and export (manually)

```bash
cd deploy/grafana

# Stage files
cp -r ../../config/grafana/provisioning .
cp -r ../../config/grafana/dashboards .

# 1. Build the image
docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/grafana:11.5.2 \
    -t grafana-server:11.5.2 .

# 2. Export to tar
docker save -o grafana-server-11.5.2.tar grafana-server:11.5.2

# Clean up staged files
rm -rf provisioning dashboards
```

Check the file size (typically ~400-500 MB for Grafana):

```bash
ls -lh grafana-server-11.5.2.tar
```

### Step 3: SCP the tar file to the VM

```bash
ssh operator@vm01.corp.example.com "mkdir -p /tmp/grafana-deploy"

scp grafana-server-11.5.2.tar \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/

# Also copy grafana.ini so you can edit config without rebuilding
scp deploy/grafana/grafana.ini \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/
```

### Step 4: SSH to the VM and elevate to root

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -
```

### Step 5: Load the image and place config on disk

```bash
docker load -i /tmp/grafana-deploy/grafana-server-11.5.2.tar
```

Verify it loaded:

```bash
docker images grafana-server
```

Copy `grafana.ini` to a permanent location on the VM:

```bash
mkdir -p /opt/grafana
cp /tmp/grafana-deploy/grafana.ini /opt/grafana/grafana.ini
```

### Step 6: Create the data volume and start the container

**Recommended — mount config from host** (edit config without rebuilding):

```bash
docker volume create grafana-data

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    -v /opt/grafana/grafana.ini:/etc/grafana/grafana.ini:ro \
    grafana-server:11.5.2
```

The mounted file overrides the baked-in config. To change settings, edit `/opt/grafana/grafana.ini` on the VM and restart the container — no rebuild needed.

**Alternative — use baked-in config only** (no files on VM):

```bash
docker volume create grafana-data

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    grafana-server:11.5.2
```

This uses the `grafana.ini` that was copied into the image at build time. To change config you must rebuild the image.

### Step 7: Verify

```bash
# Wait for health check
for i in $(seq 1 30); do
    if docker exec grafana wget -q --spider http://localhost:3000/api/health 2>/dev/null; then
        echo "Grafana is ready"
        break
    fi
    sleep 2
done

curl -s http://localhost:3000/api/health && echo " OK"
```

Open `http://<VM_IP>:3000` in a browser. Default credentials: `admin` / `admin`.

### Step 8: Clean up temp files

```bash
rm -rf /tmp/grafana-deploy
```

After deployment, the VM has:

```
/opt/grafana/
└── grafana.ini        # editable config (if using mounted config)

Docker:
  Image:     grafana-server:11.5.2
  Container: grafana (port 3000)
  Volume:    grafana-data (mounted as /var/lib/grafana)
```

### Changing config after deployment

If you used the mounted config (recommended), edit the file and restart:

```bash
vi /opt/grafana/grafana.ini        # make changes
docker restart grafana              # pick up new config
```

No rebuild, no scp, no downtime beyond the restart.

### Upgrading via docker save/load

**On your workstation:**

With the script:

```bash
bash build-and-push.sh --version 11.6.0 --platform linux/amd64 --save
scp grafana-server-11.6.0.tar operator@vm01.corp.example.com:/tmp/grafana-deploy/
```

Or manually:

```bash
cd deploy/grafana

cp -r ../../config/grafana/provisioning .
cp -r ../../config/grafana/dashboards .

docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/grafana:11.6.0 \
    -t grafana-server:11.6.0 .

docker save -o grafana-server-11.6.0.tar grafana-server:11.6.0

rm -rf provisioning dashboards

scp grafana-server-11.6.0.tar \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/
```

**On the VM:**

```bash
docker load -i /tmp/grafana-deploy/grafana-server-11.6.0.tar
docker rm -f grafana
docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    -v /opt/grafana/grafana.ini:/etc/grafana/grafana.ini:ro \
    grafana-server:11.6.0

rm -f /tmp/grafana-deploy/grafana-server-11.6.0.tar
```

The data volume and config file are preserved across upgrades.

### Where Grafana stores data

Grafana stores its database (dashboards saved via UI, users, preferences), plugin data, and sessions in the `/var/lib/grafana` directory inside the container. This maps to the Docker named volume `grafana-data` on the host.

| What | Inside Container | On the VM Host | Persists across restarts? |
|------|-----------------|----------------|:------------------------:|
| Grafana DB & plugins | `/var/lib/grafana` | Docker volume `grafana-data` | Yes |
| Server config | `/etc/grafana/grafana.ini` | `/opt/grafana/grafana.ini` (bind mount) | Yes |
| Logs | stdout/stderr | `docker logs grafana` | Until container is removed |

The Docker volume is managed by Docker and stored at `/var/lib/docker/volumes/grafana-data/` on the host. You should never modify files in that directory directly — use the Grafana UI instead.

To check volume size:

```bash
docker system df -v 2>/dev/null | grep grafana-data
```

### Cleanup and uninstall

#### Full cleanup (remove everything including Grafana data)

With the script:

```bash
bash build-and-push.sh --clean
```

Or manually:

```bash
# 1. Stop and remove the container
docker rm -f grafana

# 2. Remove the image
docker rmi grafana-server:11.5.2

# 3. Remove Grafana data (THIS DELETES ALL DASHBOARDS, USERS, AND SETTINGS)
docker volume rm grafana-data

# 4. Remove config from disk
rm -rf /opt/grafana

# 5. Remove temp files (if still present)
rm -rf /tmp/grafana-deploy
```

After full cleanup, the VM has no Grafana artifacts remaining.

#### Partial cleanup (keep data and config for redeployment)

With the script:

```bash
bash build-and-push.sh --clean-keep-data
```

Or manually:

```bash
# 1. Stop and remove the container
docker rm -f grafana

# 2. Remove the image
docker rmi grafana-server:11.5.2
```

This keeps:
- `grafana-data` volume — all Grafana data preserved
- `/opt/grafana/grafana.ini` — config preserved

You can redeploy later by loading a new image and running `docker run` with the same volume and config mount.

#### Failed deployment cleanup

If a deployment failed partway through, run full cleanup to remove any partial state, then retry from step 1:

```bash
bash build-and-push.sh --clean
```

---

### build-and-push.sh configuration

All settings can be set via flags or environment variables. Flags take precedence.

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--version` | `VERSION` | `11.5.2` | Grafana version to build (pinned, not `latest`) |
| `--registry` | `REGISTRY` | `company.corp.com/docker-proxy/grafana` | Internal registry path |
| `--image` | `IMAGE_NAME` | `grafana-server` | Image name appended to registry path |
| `--upstream` | `UPSTREAM_IMAGE` | `grafana/grafana` | Upstream Docker Hub image |
| `--platform` | `PLATFORM` | *(current)* | Target platform (e.g., `linux/amd64`) |
| `--pull-only` | | | Pull official image and push directly (no Dockerfile build, config mounted at runtime) |
| `--save [path]` | | | Export image as tar file for scp to VM (default: `./<image>-<version>.tar`) |
| `--clean` | | | Remove container, image, volume, and config from the VM |
| `--clean-keep-data` | | | Remove container and image but keep volume and config |
| `--push` | | | Push to internal registry after building |
| `--latest` | | | Also tag and push as `:latest` (requires `--push`) |
| `--dry-run` | | | Show commands without executing |
| `--list-tags` | | | List recent upstream versions from Docker Hub |
| `--no-cache` | | | Build without Docker cache (force fresh pull) |

---

## Docker Image Build and Push

See [DOCKER-BUILD.md](DOCKER-BUILD.md) for the step-by-step guide covering:

- **Option A:** Build and push with `build-and-push.sh` script (7 steps)
- **Option B:** Build and push manually without the script (9 steps)
- **Option C:** Pull and push official image directly — no build needed (8 steps)
- **Option D:** Build locally and scp image to VM — no registry needed (8 steps)
- **Upgrading and rolling back** to a different Grafana version

Use this when your VM cannot reach Docker Hub (e.g., `i/o timeout` during `docker build`).

---

## Integrating into an Existing Grafana Instance

If you already have Grafana running (package install, Docker, or Kubernetes), you don't need this deployment. Instead, add the Pyroscope datasource and dashboards to your existing instance:

1. Follow [docs/grafana-setup.md](../../docs/grafana-setup.md) for the step-by-step guide
2. Copy provisioning files from `config/grafana/provisioning/` to your Grafana provisioning directory
3. Copy dashboard JSON files from `config/grafana/dashboards/` to your Grafana dashboards directory
4. Update the Pyroscope datasource URL in `datasources.yaml` to point to your Pyroscope server
5. Restart Grafana

---

## Idempotency and Safety

All four deployment options are safe to run on a VM with existing services:

- **Only manages its own container.** The container is named `grafana`. No other containers are affected.
- **Port binding is scoped.** Only binds port 3000 (or your override). If that port is taken, Docker will fail with a clear error — it will not steal the port.
- **Re-running is safe.** Running `start` again (or the manual commands) replaces the existing `grafana` container and rebuilds the image. The data volume `grafana-data` is preserved.
- **No system-level changes.** No firewall rules, systemd units, cron jobs, or package installations. Only Docker API calls.

---

## Script Commands

```bash
bash deploy.sh start   [--from-git [url] | --from-local <path>]
bash deploy.sh stop
bash deploy.sh restart [--from-git [url] | --from-local <path>]
bash deploy.sh logs
bash deploy.sh status
bash deploy.sh clean
bash deploy.sh help
```

| Command | Description |
|---------|-------------|
| `start` | Build the image and start the container. If a container already exists, it is replaced. The data volume is preserved. |
| `stop` | Stop and remove the container. The data volume is preserved. |
| `restart` | Stop then start. Equivalent to running `stop` followed by `start`. |
| `logs` | Tail the container logs (Ctrl+C to stop). |
| `status` | Show whether the container is running and the health check result. |
| `clean` | Stop the container, remove the image, and delete the data volume. This deletes all stored Grafana data. |
| `help` | Show usage information. |

### Source Options (for `start` and `restart`)

| Option | Description |
|--------|-------------|
| *(none)* | Use files already present in `/opt/grafana/` (or `INSTALL_DIR`). |
| `--from-local <path>` | Copy `Dockerfile`, `grafana.ini`, `provisioning/`, and `dashboards/` from a local directory to `INSTALL_DIR`, then build and start. Use this when you have scp'd the files to the VM. The path can point to the `deploy/grafana/` subdirectory or directly to a directory containing the Dockerfile. |
| `--from-git [url]` | Clone (or pull) the repo into `INSTALL_DIR`, then build and start. If the repo is already cloned, it fetches and resets to the latest commit. An optional URL overrides the default `REPO_URL`. |

## Configuration

Override these environment variables to change defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `GRAFANA_PORT` | `3000` | Host port mapped to the container |
| `INSTALL_DIR` | `/opt/grafana` | Directory where Dockerfile and config are installed |
| `REPO_URL` | `git@github.com:aff0gat000/pyroscope.git` | Git repo URL for `--from-git` |
| `REPO_BRANCH` | `main` | Git branch for `--from-git` |

Example with overrides:

```bash
GRAFANA_PORT=8080 INSTALL_DIR=/srv/grafana bash deploy.sh start --from-local /tmp/grafana-deploy
```

### Grafana Environment Variables

Grafana supports overriding any `grafana.ini` setting via environment variables. Pass them with `-e` in the `docker run` command:

| Variable | Default | Description |
|----------|---------|-------------|
| `GF_SECURITY_ADMIN_USER` | `admin` | Admin username |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` | Admin password |
| `GF_INSTALL_PLUGINS` | *(set in Dockerfile)* | Comma-separated list of plugins to install |

Example:

```bash
docker run -d \
    --name grafana \
    -e GF_SECURITY_ADMIN_PASSWORD=MySecurePassword \
    -p 3000:3000 -v grafana-data:/var/lib/grafana \
    grafana-server
```

See [Grafana docs: Override configuration with environment variables](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#override-configuration-with-environment-variables) for the full list.

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `:3000` | Grafana UI |
| `:3000/api/health` | Health/readiness check |

## Connecting to Pyroscope

The baked-in `datasources.yaml` configures the Pyroscope datasource with URL `http://pyroscope:4040`. If Pyroscope runs on a different host or port, update the URL:

**Option 1 — Edit before building:**

Edit `config/grafana/provisioning/datasources/datasources.yaml` in the repo, change the Pyroscope URL, then rebuild the image.

**Option 2 — Mount updated config at runtime:**

```bash
# Copy provisioning files to the VM
mkdir -p /opt/grafana/provisioning/datasources
cp datasources.yaml /opt/grafana/provisioning/datasources/

# Edit the Pyroscope URL
vi /opt/grafana/provisioning/datasources/datasources.yaml
# Change: url: http://pyroscope:4040
# To:     url: http://<PYROSCOPE_VM_IP>:4040

# Run with mounted provisioning
docker run -d --name grafana --restart unless-stopped \
    -p 3000:3000 -v grafana-data:/var/lib/grafana \
    -v /opt/grafana/provisioning:/etc/grafana/provisioning:ro \
    grafana-server
```

**Option 3 — Update via Grafana UI:**

After deploying, go to **Configuration** > **Data Sources** > **Pyroscope** and change the URL. This is stored in Grafana's database (the `grafana-data` volume) and persists across restarts.

### Prometheus (optional)

The provisioned `datasources.yaml` also includes a Prometheus datasource. This is only needed for JVM metrics dashboards (`jvm-metrics.json`). If you don't have Prometheus, those dashboard panels will show "No data" — the profiling dashboards will still work.

To configure Prometheus, update the URL in `datasources.yaml` the same way as Pyroscope above.

## Day-2 Operations

### Health check

```bash
# From the Grafana VM
curl -s http://localhost:3000/api/health && echo " OK"

# From inside the container (no curl needed)
docker exec grafana wget -q --spider http://localhost:3000/api/health && echo " OK"

# From another server (verify network connectivity)
curl -s http://<GRAFANA_VM_IP>:3000/api/health && echo " OK"
```

### View logs

```bash
# Last 100 lines
docker logs --tail 100 grafana

# Follow logs in real time (Ctrl+C to stop)
docker logs -f grafana

# Logs from the last hour
docker logs --since 1h grafana

# Filter for errors
docker logs grafana 2>&1 | grep -i error
```

### Start / stop / restart

**With the deploy script** (if you copied `deploy.sh` to `/opt/grafana/`):

```bash
bash /opt/grafana/deploy.sh status          # Check status and health
bash /opt/grafana/deploy.sh stop            # Stop (data preserved)
bash /opt/grafana/deploy.sh start           # Start (rebuild image)
bash /opt/grafana/deploy.sh restart         # Stop + start
```

**Manual Docker commands:**

```bash
# Stop the container (data volume preserved)
docker stop grafana

# Start a stopped container
docker start grafana

# Restart the container
docker restart grafana

# Remove the container entirely (data volume still preserved)
docker rm -f grafana
```

### Config changes

If `grafana.ini` is bind-mounted from `/opt/grafana/grafana.ini` (Options C pull-only and D):

```bash
vi /opt/grafana/grafana.ini           # Edit config
docker restart grafana                # Pick up changes
```

If the config is baked into the image (Options A, B, and C build):

```bash
# Edit grafana.ini in /opt/grafana, rebuild the image, then replace the container
cd /opt/grafana
docker build -t grafana-server .
docker rm -f grafana
docker run -d --name grafana --restart unless-stopped \
    -p 3000:3000 -v grafana-data:/var/lib/grafana grafana-server
```

### Disk usage monitoring

```bash
# Check the grafana-data volume size
docker system df -v 2>/dev/null | grep grafana-data

# Check overall Docker disk usage
docker system df
```

### Backup Grafana data

```bash
# Create a compressed backup of all Grafana data
docker run --rm \
    -v grafana-data:/data:ro \
    -v "$(pwd)":/backup \
    alpine tar czf /backup/grafana-backup-$(date +%Y%m%d).tar.gz -C /data .
```

This creates `grafana-backup-YYYYMMDD.tar.gz` in the current directory. The Grafana container can remain running during backup (the data directory is mounted read-only in the backup container).

### Restore Grafana data

```bash
# Stop the Grafana container first
docker stop grafana

# Restore from backup (overwrites existing data)
docker run --rm \
    -v grafana-data:/data \
    -v "$(pwd)":/backup:ro \
    alpine sh -c "rm -rf /data/* && tar xzf /backup/grafana-backup-YYYYMMDD.tar.gz -C /data"

# Start Grafana again
docker start grafana
```

### Full cleanup

With the script:

```bash
bash /opt/grafana/deploy.sh clean
```

Or see the [cleanup and uninstall](#cleanup-and-uninstall) section under Option D for manual steps.

If you deployed manually (Option B), see the [manual day-2 operations](#manual-day-2-operations) section above.

## Running Tests

The test suite uses mock binaries for docker, git, id, and hostname. No root, Docker, or network access is required.

```bash
bash deploy/grafana/deploy-test.sh
```

# Pyroscope Monolithic Deployment

Pyroscope server deployed in **monolithic mode** (`-target=all`), suitable for development, testing, and small-to-medium workloads. All components (ingestion, storage, querying) run in a single process inside one container with local filesystem storage. See [Grafana docs: deployment modes](https://grafana.com/docs/pyroscope/latest/reference-pyroscope-architecture/deployment-modes/) for details.

## Architecture

```mermaid
graph LR
    subgraph Pyroscope VM
        subgraph Docker Container
            P[Pyroscope Server<br/>monolithic mode]
            FS[("/data<br/>(filesystem)")]
            P --> FS
        end
    end

    subgraph App Server 1
        V1[Vert.x FaaS Server<br/>Java Functions]
        A1[Pyroscope Agent<br/>JFR profiler]
        V1 -.- A1
    end

    subgraph App Server 2
        V2[Vert.x FaaS Server<br/>Java Functions]
        A2[Pyroscope Agent<br/>JFR profiler]
        V2 -.- A2
    end

    A1 -->|push profiles<br/>:4040/ingest| P
    A2 -->|push profiles<br/>:4040/ingest| P
    G[Grafana] -->|query<br/>:4040| P
```

The Pyroscope Java agent runs as a `-javaagent` inside each Vert.x JVM process. It continuously samples CPU, memory, lock, and wall-clock profiles using JFR and pushes them to the Pyroscope server every 10 seconds. No application code changes are required — the agent is attached at JVM startup via `JAVA_TOOL_OPTIONS`.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds a container image from `grafana/pyroscope:latest` with baked-in config |
| `pyroscope.yaml` | Server config: filesystem storage at `/data`, port 4040 |
| `deploy.sh` | Lifecycle script (start/stop/restart/logs/status/clean) with Git and local source options |
| `deploy-test.sh` | 45 mock-based unit tests for deploy.sh (no root or Docker needed) |

## Prerequisites

- **Docker** installed and running on the target VM
- **Root access** via `pbrun /bin/su -`
- **Port 4040** available (or choose a different port)

## Directory Layout

| Location | Purpose |
|----------|---------|
| **Your workstation** | |
| `deploy/monolithic/` | Source files in your local repo clone (Dockerfile, pyroscope.yaml, deploy.sh) |
| **Target VM** | |
| `/tmp/pyroscope-deploy/` | Temporary landing directory for scp (deleted after install) |
| `/opt/pyroscope/` | Permanent install directory on the VM (Dockerfile + pyroscope.yaml live here) |
| Docker volume `pyroscope-data` | Mounted as `/data` inside the container — stores profiling data |

---

## Option A: Deploy with Script

### Step 1: Copy files to the VM (from your workstation)

`scp` (secure copy) transfers files over SSH. The syntax is `scp <local-files> <user>@<host>:<remote-path>`. Run this from your workstation, not from the VM.

```bash
# Create the landing directory on the VM
ssh operator@vm01.corp.example.com "mkdir -p /tmp/pyroscope-deploy"

# Copy the 3 required files from your local repo clone
scp deploy/monolithic/deploy.sh \
    deploy/monolithic/Dockerfile \
    deploy/monolithic/pyroscope.yaml \
    operator@vm01.corp.example.com:/tmp/pyroscope-deploy/
```

After this step, the VM has:

```
/tmp/pyroscope-deploy/
├── deploy.sh
├── Dockerfile
└── pyroscope.yaml
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

# Check that port 4040 is not already in use
ss -tlnp | grep :4040

# Check no container named 'pyroscope' already exists
docker ps -a --format '{{.Names}}' | grep -x pyroscope || echo "No conflict"
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
bash /tmp/pyroscope-deploy/deploy.sh start --from-local /tmp/pyroscope-deploy
```

The script will:

1. Verify you are root and Docker is running
2. Copy `Dockerfile` and `pyroscope.yaml` from `/tmp/pyroscope-deploy/` to `/opt/pyroscope/`
3. Build the Docker image `pyroscope-server` from `/opt/pyroscope/Dockerfile`
4. Create a Docker volume `pyroscope-data` (if it does not already exist)
5. Start the container `pyroscope` on port 4040
6. Wait up to 60 seconds for the health check (`/ready` endpoint)
7. Print a connection summary with the VM IP address

To use a different port:

```bash
PYROSCOPE_PORT=9090 bash /tmp/pyroscope-deploy/deploy.sh start --from-local /tmp/pyroscope-deploy
```

### Step 6: Verify

```bash
curl -s http://localhost:4040/ready && echo " OK"
```

Open `http://<VM_IP>:4040` in a browser to access the Pyroscope UI.

### Step 7: Clean up and keep deploy.sh for day-2

```bash
# Copy deploy.sh to the install directory for future use
cp /tmp/pyroscope-deploy/deploy.sh /opt/pyroscope/deploy.sh

# Remove the temp landing directory
rm -rf /tmp/pyroscope-deploy
```

After cleanup, the VM has:

```
/opt/pyroscope/
├── deploy.sh          # lifecycle script for day-2 operations
├── Dockerfile         # used by docker build
└── pyroscope.yaml     # Pyroscope server config
```

---

## Option B: Deploy Manually (without script)

If you prefer not to use the deploy script, run the Docker commands directly.

### Step 1: Copy files to the VM (from your workstation)

Only 2 files are needed (no deploy.sh).

```bash
ssh operator@vm01.corp.example.com "mkdir -p /tmp/pyroscope-deploy"

scp deploy/monolithic/Dockerfile \
    deploy/monolithic/pyroscope.yaml \
    operator@vm01.corp.example.com:/tmp/pyroscope-deploy/
```

### Step 2: SSH to the VM and elevate to root

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -
```

### Step 3: Pre-flight checks

```bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker NOT available"
ss -tlnp | grep :4040
```

### Step 4: Copy files to the install directory

```bash
mkdir -p /opt/pyroscope
cp /tmp/pyroscope-deploy/Dockerfile     /opt/pyroscope/Dockerfile
cp /tmp/pyroscope-deploy/pyroscope.yaml /opt/pyroscope/pyroscope.yaml
```

### Step 5: Build the Docker image

```bash
cd /opt/pyroscope
docker build -t pyroscope-server .
```

This builds an image from the Dockerfile, which:
- Pulls `grafana/pyroscope:latest`
- Copies `pyroscope.yaml` into the image as `/etc/pyroscope/config.yaml`
- Sets the entrypoint to `pyroscope -config.file=/etc/pyroscope/config.yaml`

### Step 6: Create the data volume

```bash
docker volume create pyroscope-data
```

This volume persists profiling data across container restarts. It is mounted as `/data` inside the container.

### Step 7: Start the container

```bash
docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    pyroscope-server
```

To use a different host port (e.g., 9090):

```bash
docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 9090:4040 \
    -v pyroscope-data:/data \
    pyroscope-server
```

### Step 8: Wait for health check

```bash
# Poll until ready (up to 60 seconds)
for i in $(seq 1 30); do
    if docker exec pyroscope wget -q --spider http://localhost:4040/ready 2>/dev/null; then
        echo "Pyroscope is ready"
        break
    fi
    sleep 2
done
```

### Step 9: Verify

```bash
curl -s http://localhost:4040/ready && echo " OK"
docker ps --filter "name=^pyroscope$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### Step 10: Clean up temp files

```bash
rm -rf /tmp/pyroscope-deploy
```

After cleanup, the VM has:

```
/opt/pyroscope/
├── Dockerfile         # kept for rebuilds
└── pyroscope.yaml     # kept for reference

Docker:
  Image:     pyroscope-server
  Container: pyroscope (port 4040)
  Volume:    pyroscope-data (mounted as /data)
```

### Manual day-2 operations

```bash
# View logs
docker logs -f pyroscope

# Stop (data volume preserved)
docker rm -f pyroscope

# Restart (rebuild image first if config changed)
cd /opt/pyroscope && docker build -t pyroscope-server .
docker rm -f pyroscope 2>/dev/null
docker run -d --name pyroscope --restart unless-stopped -p 4040:4040 -v pyroscope-data:/data pyroscope-server

# Full cleanup (removes container, image, and all profiling data)
docker rm -f pyroscope 2>/dev/null
docker rmi pyroscope-server 2>/dev/null
docker volume rm pyroscope-data 2>/dev/null
```

---

## Idempotency and Safety

Both deployment options are safe to run on a VM with existing services:

- **Only manages its own container.** The container is named `pyroscope`. No other containers are affected.
- **Port binding is scoped.** Only binds port 4040 (or your override). If that port is taken, Docker will fail with a clear error — it will not steal the port.
- **Re-running is safe.** Running `start` again (or the manual commands) replaces the existing `pyroscope` container and rebuilds the image. The data volume `pyroscope-data` is preserved.
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
| `clean` | Stop the container, remove the image, and delete the data volume. This deletes all stored profiling data. |
| `help` | Show usage information. |

### Source Options (for `start` and `restart`)

| Option | Description |
|--------|-------------|
| *(none)* | Use files already present in `/opt/pyroscope/` (or `INSTALL_DIR`). |
| `--from-local <path>` | Copy `Dockerfile` and `pyroscope.yaml` from a local directory to `INSTALL_DIR`, then build and start. Use this when you have scp'd the files to the VM. The path can point to the `deploy/monolithic/` subdirectory or directly to a directory containing the Dockerfile. |
| `--from-git [url]` | Clone (or pull) the repo into `INSTALL_DIR`, then build and start. If the repo is already cloned, it fetches and resets to the latest commit. An optional URL overrides the default `REPO_URL`. |

## Configuration

Override these environment variables to change defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `PYROSCOPE_PORT` | `4040` | Host port mapped to the container |
| `INSTALL_DIR` | `/opt/pyroscope` | Directory where Dockerfile and config are installed |
| `REPO_URL` | `git@github.com:aff0gat000/pyroscope.git` | Git repo URL for `--from-git` |
| `REPO_BRANCH` | `main` | Git branch for `--from-git` |

Example with overrides:

```bash
PYROSCOPE_PORT=9090 INSTALL_DIR=/srv/pyroscope bash deploy.sh start --from-local /tmp/pyroscope-deploy
```

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `:4040` | Pyroscope UI |
| `:4040/ingest` | Java agent push endpoint |
| `:4040/ready` | Health/readiness check |

## Connecting Java Agents

Once Pyroscope is running, configure the Java agent on your application servers to push profiles to this instance. Set the server address in your `pyroscope.properties` file or as an environment variable:

```properties
# pyroscope.properties
pyroscope.server.address=http://<PYROSCOPE_VM_IP>:4040
```

Or as an environment variable:

```bash
PYROSCOPE_SERVER_ADDRESS=http://<PYROSCOPE_VM_IP>:4040
```

## Day-2 Operations

If you deployed with the script (Option A) and copied `deploy.sh` to `/opt/pyroscope/`:

```bash
docker logs -f pyroscope                     # View logs
bash /opt/pyroscope/deploy.sh status         # Check status and health
bash /opt/pyroscope/deploy.sh restart        # Restart with fresh image
bash /opt/pyroscope/deploy.sh stop           # Stop (data preserved)
bash /opt/pyroscope/deploy.sh clean          # Full cleanup (deletes data)
```

If you deployed manually (Option B), see the [manual day-2 operations](#manual-day-2-operations) section above.

## Running Tests

The test suite uses mock binaries for docker, git, id, and hostname. No root, Docker, or network access is required.

```bash
bash deploy/monolithic/deploy-test.sh
```

## When to Use This Mode

- Single-node deployments with moderate ingestion volume
- Environments where operational simplicity is preferred over horizontal scaling
- Development and testing

For high-availability or high-throughput workloads, use [microservices mode](../microservices/).

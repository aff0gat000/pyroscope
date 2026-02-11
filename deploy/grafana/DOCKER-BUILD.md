# Building and Pushing Grafana Docker Images

Step-by-step guide to building the Grafana Docker image on your workstation (with Pyroscope datasource, dashboards, and provisioning baked in) and pushing it to an internal Docker registry so VMs can pull it without Docker Hub access. All push operations target internal registries only — never push to public Docker Hub.

## When to Use This Guide

Use this when your target VMs cannot reach Docker Hub directly. The workflow is:

```
Workstation (has internet) → Internal Registry → VM (no internet)
```

If your VM can reach Docker Hub, you can build on the VM directly — see [README.md Options A and B](README.md#option-a-deploy-with-script).

## Prerequisites

| Requirement | Where | How to Check |
|-------------|-------|--------------|
| Docker installed and running | Workstation | `docker info` |
| Internet access to Docker Hub | Workstation | `docker pull hello-world` |
| Access to internal Docker registry | Workstation | `docker login company.corp.com` |
| Docker installed and running | Target VM | `docker info` |
| Access to internal Docker registry | Target VM | `docker pull company.corp.com/hello-world` (or similar) |

## Files Involved

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds from official `grafana/grafana` base (Alpine, ~400 MB with plugins) |
| `grafana.ini` | Grafana config baked into the image |
| `provisioning/` | Datasources, dashboards, plugins provisioning (staged from `config/grafana/`) |
| `dashboards/` | 6 pre-built dashboard JSON files (staged from `config/grafana/`) |
| `build-and-push.sh` | Script that handles staging, building, tagging, and pushing in one command |

The Dockerfile bakes in `grafana.ini`, provisioning config, and dashboards. It installs the Pyroscope plugins via `GF_INSTALL_PLUGINS`. The resulting image runs as a non-root user (UID 472) on port 3000.

---

## Option A: Build and Push with Script (Recommended)

Run all steps from your **workstation** in the `deploy/grafana/` directory.

### Step 1: Check available Grafana versions

```bash
cd deploy/grafana
bash build-and-push.sh --list-tags
```

Pick a version (e.g., `11.5.2`). Avoid using `latest` in production.

### Step 2: Preview the build (dry run)

```bash
bash build-and-push.sh \
    --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --push --dry-run
```

This shows exactly what commands would run without executing them. Verify the registry path and version look correct.

### Step 3: Build and push to your internal registry

```bash
bash build-and-push.sh \
    --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --push
```

This will:
1. Stage provisioning and dashboard files from `config/grafana/` into the build context
2. Pull `grafana/grafana:11.5.2` from Docker Hub
3. Build the image with `grafana.ini`, provisioning, and dashboards baked in
4. Tag as `company.corp.com/docker-proxy/grafana/grafana-server:11.5.2`
5. Push to your internal registry
6. Clean up staged files

To also update the `:latest` tag in the registry, add `--latest`:

```bash
bash build-and-push.sh \
    --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --push --latest
```

If building on a Mac/ARM workstation for Linux x86_64 VMs, add `--platform`:

```bash
bash build-and-push.sh \
    --version 11.5.2 \
    --registry company.corp.com/docker-proxy/grafana \
    --platform linux/amd64 \
    --push
```

### Step 4: SSH to the VM and elevate to root

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -
```

### Step 5: Pull the image from your internal registry

```bash
docker pull company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 6: Create the data volume and start the container

```bash
docker volume create grafana-data

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 7: Verify

```bash
# Wait for health check (up to 60 seconds)
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
No files on disk — the image was pulled from the internal registry.

Docker:
  Image:     company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
  Container: grafana (port 3000)
  Volume:    grafana-data (mounted as /var/lib/grafana)
```

---

## Option B: Build and Push Manually (Without Script)

Run steps 1-5 on your **workstation** in the `deploy/grafana/` directory. Run steps 6-9 on the **VM**.

### Step 1: Choose a version

Check available versions on Docker Hub:

```bash
curl -s "https://hub.docker.com/v2/repositories/grafana/grafana/tags/?page_size=15&ordering=last_updated" \
    | grep -oP '"name"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | head -10
```

### Step 2: Stage files and build the image

```bash
cd deploy/grafana

# Stage provisioning and dashboard files into build context
cp -r ../../config/grafana/provisioning .
cp -r ../../config/grafana/dashboards .

docker build \
    --build-arg BASE_IMAGE=grafana/grafana:11.5.2 \
    -t grafana-server:11.5.2 .

# Clean up staged files
rm -rf provisioning dashboards
```

This pulls `grafana/grafana:11.5.2` from Docker Hub and bakes in `grafana.ini`, provisioning, and dashboards.

If building on a Mac/ARM workstation for Linux x86_64 VMs:

```bash
docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/grafana:11.5.2 \
    -t grafana-server:11.5.2 .
```

### Step 3: Tag for your internal registry

```bash
docker tag grafana-server:11.5.2 \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 4: Log in to your internal registry

```bash
docker login company.corp.com
```

### Step 5: Push to your internal registry

```bash
docker push company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

Optionally update the `:latest` tag:

```bash
docker tag grafana-server:11.5.2 \
    company.corp.com/docker-proxy/grafana/grafana-server:latest
docker push company.corp.com/docker-proxy/grafana/grafana-server:latest
```

### Step 6: SSH to the VM and elevate to root

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -
```

### Step 7: Pull the image from your internal registry

```bash
docker pull company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 8: Create the data volume and start the container

```bash
docker volume create grafana-data

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 9: Verify

```bash
for i in $(seq 1 30); do
    if docker exec grafana wget -q --spider http://localhost:3000/api/health 2>/dev/null; then
        echo "Grafana is ready"
        break
    fi
    sleep 2
done

curl -s http://localhost:3000/api/health && echo " OK"
```

---

## Option C: Pull and Push Official Image Directly (No Build)

The simplest option — pull the official `grafana/grafana` image from Docker Hub on your workstation, re-tag it for your internal registry, and push. No Dockerfile or build step needed. Config is mounted at runtime on the VM.

Run steps 1-4 on your **workstation**. Run steps 5-8 on the **VM**.

### Step 1: Pull the official image

```bash
docker pull --platform linux/amd64 grafana/grafana:11.5.2
```

Or with the script:

```bash
bash build-and-push.sh --version 11.5.2 --pull-only --platform linux/amd64 --push \
    --registry company.corp.com/docker-proxy/grafana
```

If using the script with `--push`, skip to step 5 — the script handles steps 2-4 for you.

### Step 2: Tag for your internal registry

```bash
docker tag grafana/grafana:11.5.2 \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 3: Log in to your internal registry

```bash
docker login company.corp.com
```

### Step 4: Push to your internal registry

```bash
docker push company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 5: Copy config files to the VM (from your workstation)

Since the official image does not have config baked in, copy it to the VM:

```bash
ssh operator@vm01.corp.example.com "mkdir -p /opt/grafana"
scp deploy/grafana/grafana.ini operator@vm01.corp.example.com:/opt/grafana/grafana.ini
scp -r config/grafana/provisioning operator@vm01.corp.example.com:/opt/grafana/provisioning
scp -r config/grafana/dashboards operator@vm01.corp.example.com:/opt/grafana/dashboards
```

### Step 6: SSH to the VM and pull the image

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -

docker pull company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 7: Create the data volume and start the container

Mount all config from the VM filesystem into the container:

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
    -e GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource \
    company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
```

### Step 8: Verify

```bash
for i in $(seq 1 30); do
    if docker exec grafana wget -q --spider http://localhost:3000/api/health 2>/dev/null; then
        echo "Grafana is ready"
        break
    fi
    sleep 2
done

curl -s http://localhost:3000/api/health && echo " OK"
```

---

## Option D: Build Locally and SCP Image to VM (No Registry Needed)

Use this when the VM cannot pull from Docker Hub or your internal registry. Build the image on your workstation, export to a tar file with `docker save`, scp to the VM, and load with `docker load`.

Run steps 1-3 on your **workstation**. Run steps 4-7 on the **VM**.

### Steps 1-2: Build and export (with script)

```bash
cd deploy/grafana
bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --save
```

This produces `./grafana-server-11.5.2.tar`. To save to a custom path:

```bash
bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --save /tmp/grafana.tar
```

### Steps 1-2: Build and export (manually)

```bash
cd deploy/grafana

# Stage files
cp -r ../../config/grafana/provisioning .
cp -r ../../config/grafana/dashboards .

docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/grafana:11.5.2 \
    -t grafana-server:11.5.2 .

docker save -o grafana-server-11.5.2.tar grafana-server:11.5.2

rm -rf provisioning dashboards
```

### Step 3: SCP the tar file and config to the VM

```bash
ssh operator@vm01.corp.example.com "mkdir -p /tmp/grafana-deploy"

scp grafana-server-11.5.2.tar \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/

# Also copy grafana.ini so you can edit config without rebuilding
scp deploy/grafana/grafana.ini \
    operator@vm01.corp.example.com:/tmp/grafana-deploy/
```

### Step 4: Load the image and place config on disk

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -

docker load -i /tmp/grafana-deploy/grafana-server-11.5.2.tar

mkdir -p /opt/grafana
cp /tmp/grafana-deploy/grafana.ini /opt/grafana/grafana.ini
```

### Step 5: Create the data volume and start the container

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

To change settings later, edit `/opt/grafana/grafana.ini` and `docker restart grafana`.

**Alternative — use baked-in config only:**

```bash
docker volume create grafana-data

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    grafana-server:11.5.2
```

### Step 6: Verify

```bash
for i in $(seq 1 30); do
    if docker exec grafana wget -q --spider http://localhost:3000/api/health 2>/dev/null; then
        echo "Grafana is ready"
        break
    fi
    sleep 2
done

curl -s http://localhost:3000/api/health && echo " OK"
```

### Step 7: Clean up temp files

```bash
rm -rf /tmp/grafana-deploy
```

### Where Grafana stores data

| What | Inside Container | On the VM Host |
|------|-----------------|----------------|
| Grafana DB & plugins | `/var/lib/grafana` | Docker volume `grafana-data` |
| Server config | `/etc/grafana/grafana.ini` | `/opt/grafana/grafana.ini` (bind mount) |

Both the volume and the config file persist across container restarts, removals, and upgrades.

### Cleanup and uninstall

Full cleanup (removes everything including Grafana data):

```bash
bash build-and-push.sh --clean
```

Partial cleanup (keeps data volume and config for redeployment):

```bash
bash build-and-push.sh --clean-keep-data
```

See [README.md Option D — Cleanup and uninstall](README.md#cleanup-and-uninstall) for the manual cleanup steps.

---

## Upgrading to a New Version

### Step 1: Build and push the new version (from your workstation)

With the script:

```bash
bash build-and-push.sh \
    --version 11.6.0 \
    --registry company.corp.com/docker-proxy/grafana \
    --push --latest
```

Or manually:

```bash
cd deploy/grafana

cp -r ../../config/grafana/provisioning .
cp -r ../../config/grafana/dashboards .

docker build --build-arg BASE_IMAGE=grafana/grafana:11.6.0 \
    -t grafana-server:11.6.0 .

docker tag grafana-server:11.6.0 \
    company.corp.com/docker-proxy/grafana/grafana-server:11.6.0
docker push company.corp.com/docker-proxy/grafana/grafana-server:11.6.0

rm -rf provisioning dashboards
```

### Step 2: Pull the new version on the VM

```bash
docker pull company.corp.com/docker-proxy/grafana/grafana-server:11.6.0
```

### Step 3: Replace the running container

```bash
docker rm -f grafana

docker run -d \
    --name grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    -v grafana-data:/var/lib/grafana \
    company.corp.com/docker-proxy/grafana/grafana-server:11.6.0
```

The `grafana-data` volume is preserved — dashboards, users, and settings are not lost.

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

## build-and-push.sh Reference

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--version` | `VERSION` | `11.5.2` | Grafana version to build |
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

## Security Notes

- **Never push to public Docker Hub.** All push operations target internal registries only.
- **Pin versions in production.** Use `--version 11.5.2`, not `latest`. The `build-and-push.sh` script warns when `latest` is used.
- **Non-root by default.** The official Grafana image runs as UID 472. No root access inside the container.
- **Change default credentials.** The default admin password is `admin`. Override with `-e GF_SECURITY_ADMIN_PASSWORD=<password>` or by editing `grafana.ini`.
- **No secrets in images.** The only files baked in are `grafana.ini` (server config), provisioning configs, and dashboard JSON. No credentials, tokens, or keys.
- **Scan images before pushing.** Run `docker scout cves grafana-server:11.5.2` or your enterprise scanning tool before pushing to the registry.

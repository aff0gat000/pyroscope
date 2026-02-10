# Building and Pushing Pyroscope Docker Images

Step-by-step guide to building the Pyroscope monolithic mode Docker image on your workstation and pushing it to an internal Docker registry so VMs can pull it without Docker Hub access. All push operations target internal registries only — never push to public Docker Hub.

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
| `Dockerfile` | Builds from official `grafana/pyroscope` base (distroless, ~30 MB) |
| `Dockerfile.custom` | Builds from Alpine, UBI, Debian, or distroless when official image is unavailable or enterprise policy requires a specific base |
| `pyroscope.yaml` | Server config baked into the image |
| `build-and-push.sh` | Script that handles building, tagging, and pushing in one command |

Both Dockerfiles produce the same result: a Pyroscope server image with `pyroscope.yaml` baked in, running as a non-root user (UID 10001) on port 4040.

---

## Option A: Build and Push with Script (Recommended)

Run all steps from your **workstation** in the `deploy/monolithic/` directory.

### Step 1: Check available Pyroscope versions

```bash
cd deploy/monolithic
bash build-and-push.sh --list-tags
```

Pick a version (e.g., `1.18.0`). Avoid using `latest` in production.

### Step 2: Preview the build (dry run)

```bash
bash build-and-push.sh \
    --version 1.18.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push --dry-run
```

This shows exactly what commands would run without executing them. Verify the registry path and version look correct.

### Step 3: Build and push to your internal registry

```bash
bash build-and-push.sh \
    --version 1.18.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push
```

This will:
1. Pull `grafana/pyroscope:1.18.0` from Docker Hub
2. Build the image with `pyroscope.yaml` baked in
3. Tag as `company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0`
4. Push to your internal registry

To also update the `:latest` tag in the registry, add `--latest`:

```bash
bash build-and-push.sh \
    --version 1.18.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push --latest
```

If building on a Mac/ARM workstation for Linux x86_64 VMs, add `--platform`:

```bash
bash build-and-push.sh \
    --version 1.18.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
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
docker pull company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
```

### Step 6: Create the data volume and start the container

```bash
docker volume create pyroscope-data

docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
```

### Step 7: Verify

```bash
# Wait for health check (up to 60 seconds)
for i in $(seq 1 30); do
    if docker exec pyroscope wget -q --spider http://localhost:4040/ready 2>/dev/null; then
        echo "Pyroscope is ready"
        break
    fi
    sleep 2
done

curl -s http://localhost:4040/ready && echo " OK"
```

Open `http://<VM_IP>:4040` in a browser to access the Pyroscope UI.

After deployment, the VM has:

```
No files on disk — the image was pulled from the internal registry.

Docker:
  Image:     company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
  Container: pyroscope (port 4040)
  Volume:    pyroscope-data (mounted as /data)
```

---

## Option B: Build and Push Manually (Without Script)

Run steps 1-5 on your **workstation** in the `deploy/monolithic/` directory. Run steps 6-9 on the **VM**.

### Step 1: Choose a version

Check available versions on Docker Hub:

```bash
curl -s "https://hub.docker.com/v2/repositories/grafana/pyroscope/tags/?page_size=15&ordering=last_updated" \
    | grep -oP '"name"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | head -10
```

### Step 2: Build the image

```bash
cd deploy/monolithic

docker build \
    --build-arg BASE_IMAGE=grafana/pyroscope:1.18.0 \
    -t pyroscope-server:1.18.0 .
```

This pulls `grafana/pyroscope:1.18.0` from Docker Hub and bakes in `pyroscope.yaml`.

If building on a Mac/ARM workstation for Linux x86_64 VMs:

```bash
docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/pyroscope:1.18.0 \
    -t pyroscope-server:1.18.0 .
```

### Step 3: Tag for your internal registry

```bash
docker tag pyroscope-server:1.18.0 \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
```

### Step 4: Log in to your internal registry

```bash
docker login company.corp.com
```

### Step 5: Push to your internal registry

```bash
docker push company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
```

Optionally update the `:latest` tag:

```bash
docker tag pyroscope-server:1.18.0 \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:latest
docker push company.corp.com/docker-proxy/pyroscope/pyroscope-server:latest
```

### Step 6: SSH to the VM and elevate to root

```bash
ssh operator@vm01.corp.example.com
pbrun /bin/su -
```

### Step 7: Pull the image from your internal registry

```bash
docker pull company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
```

### Step 8: Create the data volume and start the container

```bash
docker volume create pyroscope-data

docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
```

### Step 9: Verify

```bash
for i in $(seq 1 30); do
    if docker exec pyroscope wget -q --spider http://localhost:4040/ready 2>/dev/null; then
        echo "Pyroscope is ready"
        break
    fi
    sleep 2
done

curl -s http://localhost:4040/ready && echo " OK"
```

---

## Building with a Custom Base Image

Use `Dockerfile.custom` when the official `grafana/pyroscope` image is not available or enterprise policy requires a specific base (e.g., UBI for RHEL compliance).

The Dockerfile uses a multi-stage build: stage 1 copies the Pyroscope binary from the official image, stage 2 places it on your chosen base with a non-root user.

### Step 1: Build with your chosen base

**Alpine (default, recommended):**

```bash
cd deploy/monolithic

docker build -f Dockerfile.custom \
    --build-arg PYROSCOPE_VERSION=1.18.0 \
    -t pyroscope-server:1.18.0 .
```

**Red Hat UBI Minimal (RHEL compliance):**

```bash
docker build -f Dockerfile.custom \
    --build-arg PYROSCOPE_VERSION=1.18.0 \
    --build-arg BASE_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10 \
    -t pyroscope-server:1.18.0-ubi .
```

**Debian slim:**

```bash
docker build -f Dockerfile.custom \
    --build-arg PYROSCOPE_VERSION=1.18.0 \
    --build-arg BASE_IMAGE=debian:bookworm-slim \
    -t pyroscope-server:1.18.0-debian .
```

**Distroless (same as official, most secure):**

```bash
docker build -f Dockerfile.custom \
    --build-arg PYROSCOPE_VERSION=1.18.0 \
    --build-arg BASE_IMAGE=gcr.io/distroless/static-debian12:nonroot \
    -t pyroscope-server:1.18.0-distroless .
```

### Step 2: Tag and push to your internal registry

```bash
docker tag pyroscope-server:1.18.0-ubi \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0-ubi

docker push company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0-ubi
```

Use a tag suffix (e.g., `-ubi`, `-alpine`, `-debian`) to distinguish custom base images from the default.

### Step 3: Pull and run on the VM

Same as Option A steps 4-7 or Option B steps 6-9, using the custom-tagged image name.

### Base image comparison

| Base Image | Size | Shell | Debugging | Enterprise Compliance | Notes |
|-----------|:----:|:-----:|:---------:|:---------------------:|-------|
| Alpine 3.20 | ~8 MB | Yes | Easy | Widely accepted | Default. Best balance of size and usability. |
| UBI 8 Minimal | ~80 MB | Yes | Easy | Required by some orgs | Use when RHEL-based images are mandated. |
| Debian slim | ~75 MB | Yes | Easy | Widely accepted | Broadest package ecosystem for debugging. |
| Distroless | ~5 MB | No | Hard | Highest security posture | No shell. Same as official image. Hardest to troubleshoot. |

**Recommendation:** Use Alpine unless your enterprise requires UBI.

---

## Upgrading to a New Version

### Step 1: Build and push the new version (from your workstation)

With the script:

```bash
bash build-and-push.sh \
    --version 1.19.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push --latest
```

Or manually:

```bash
docker build --build-arg BASE_IMAGE=grafana/pyroscope:1.19.0 \
    -t pyroscope-server:1.19.0 deploy/monolithic/

docker tag pyroscope-server:1.19.0 \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.19.0
docker push company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.19.0
```

### Step 2: Pull the new version on the VM

```bash
docker pull company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.19.0
```

### Step 3: Replace the running container

```bash
docker rm -f pyroscope

docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.19.0
```

The `pyroscope-data` volume is preserved — profiling data is not lost.

### Rolling back

```bash
docker rm -f pyroscope

docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
```

---

## build-and-push.sh Reference

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--version` | `VERSION` | `1.18.0` | Pyroscope version to build |
| `--registry` | `REGISTRY` | `company.corp.com/docker-proxy/pyroscope` | Internal registry path |
| `--image` | `IMAGE_NAME` | `pyroscope-server` | Image name appended to registry path |
| `--upstream` | `UPSTREAM_IMAGE` | `grafana/pyroscope` | Upstream Docker Hub image |
| `--platform` | `PLATFORM` | *(current)* | Target platform (e.g., `linux/amd64`) |
| `--push` | | | Push to internal registry after building |
| `--latest` | | | Also tag and push as `:latest` (requires `--push`) |
| `--dry-run` | | | Show commands without executing |
| `--list-tags` | | | List recent upstream versions from Docker Hub |
| `--no-cache` | | | Build without Docker cache (force fresh pull) |

---

## Security Notes

- **Never push to public Docker Hub.** All push operations target internal registries only.
- **Pin versions in production.** Use `--version 1.18.0`, not `latest`. The `build-and-push.sh` script warns when `latest` is used.
- **Non-root by default.** Both Dockerfiles run as UID 10001. The official base inherits this from distroless; the custom base creates the user explicitly.
- **No secrets in images.** The only file baked in is `pyroscope.yaml` (server config). No credentials, tokens, or keys.
- **Scan images before pushing.** Run `docker scout cves pyroscope-server:1.18.0` or your enterprise scanning tool before pushing to the registry.

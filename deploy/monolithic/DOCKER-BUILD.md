# Building and Pushing Pyroscope Docker Images

This guide covers building the Pyroscope monolithic mode Docker image and pushing it to an internal Docker registry (Artifactory, Nexus, Harbor, etc.). All push operations target internal registries only — never push to public Docker Hub.

## Overview

There are two Dockerfiles in this directory:

| Dockerfile | Base | Use When |
|-----------|------|----------|
| `Dockerfile` | `grafana/pyroscope` (official, distroless) | You can pull the official image from Docker Hub or an internal mirror |
| `Dockerfile.custom` | Alpine, UBI, Debian, or distroless (your choice) | The official image is unavailable, or enterprise policy requires a specific base |

Both produce the same result: a Pyroscope server image with `pyroscope.yaml` baked in, running as a non-root user on port 4040.

---

## Quick Start

```bash
# Build locally with the official base image
docker build -t pyroscope-server .

# Build with a pinned version
docker build --build-arg BASE_IMAGE=grafana/pyroscope:1.18.0 -t pyroscope-server:1.18.0 .

# Build and push to internal registry in one step
bash build-and-push.sh --version 1.18.0 --registry company.corp.com/docker-proxy/pyroscope --push
```

---

## 1. Building from the Official Image (Dockerfile)

### Default build (pulls latest from Docker Hub)

```bash
cd deploy/monolithic
docker build -t pyroscope-server .
```

### Pinned version (recommended)

```bash
docker build --build-arg BASE_IMAGE=grafana/pyroscope:1.18.0 \
    -t pyroscope-server:1.18.0 .
```

### From an internal mirror of the official image

If your internal registry mirrors Docker Hub:

```bash
docker build --build-arg BASE_IMAGE=company.corp.com/docker-hub/grafana/pyroscope:1.18.0 \
    -t pyroscope-server:1.18.0 .
```

### What the Dockerfile does

```
grafana/pyroscope:latest (or pinned version)
  └── COPY pyroscope.yaml → /etc/pyroscope/config.yaml
  └── HEALTHCHECK via "pyroscope admin ready"
  └── ENTRYPOINT: pyroscope -config.file=/etc/pyroscope/config.yaml
  └── Runs as non-root user pyroscope (UID 10001) — inherited from base
```

### Official base image details

The `grafana/pyroscope` image is already hardened:

- **Distroless base** (`gcr.io/distroless/static`) — no shell, no package manager
- **Non-root user** — `pyroscope` (UID 10001, GID 10001)
- **Statically compiled Go binary** — no runtime dependencies
- **~30 MB** total image size

---

## 2. Building from a Custom Base (Dockerfile.custom)

Use this when the official `grafana/pyroscope` image is not available, or when enterprise policy requires a specific base image.

The Dockerfile uses a multi-stage build: stage 1 copies the Pyroscope binary from the official image, stage 2 places it on your chosen base with a non-root user.

### Alpine (default, recommended)

```bash
cd deploy/monolithic
docker build -f Dockerfile.custom -t pyroscope-server:1.18.0 .
```

### Red Hat UBI Minimal (RHEL compliance)

```bash
docker build -f Dockerfile.custom \
    --build-arg BASE_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10 \
    -t pyroscope-server:1.18.0 .
```

### Debian slim

```bash
docker build -f Dockerfile.custom \
    --build-arg BASE_IMAGE=debian:bookworm-slim \
    -t pyroscope-server:1.18.0 .
```

### Distroless (same as official, most secure)

```bash
docker build -f Dockerfile.custom \
    --build-arg BASE_IMAGE=gcr.io/distroless/static-debian12:nonroot \
    -t pyroscope-server:1.18.0 .
```

### Pinning the Pyroscope version

```bash
docker build -f Dockerfile.custom \
    --build-arg PYROSCOPE_VERSION=1.18.0 \
    --build-arg BASE_IMAGE=alpine:3.20 \
    -t pyroscope-server:1.18.0 .
```

### Base image comparison

| Base Image | Size | Shell | Debugging | Enterprise Compliance | Notes |
|-----------|:----:|:-----:|:---------:|:---------------------:|-------|
| Alpine 3.20 | ~8 MB | Yes | Easy | Widely accepted | Default. Best balance of size and usability. |
| UBI 8 Minimal | ~80 MB | Yes | Easy | Required by some orgs | Use when RHEL-based images are mandated. |
| Debian slim | ~75 MB | Yes | Easy | Widely accepted | Broadest package ecosystem for debugging. |
| Distroless | ~5 MB | No | Hard | Highest security posture | No shell. Same as official image. Hardest to troubleshoot. |

**Recommendation:** Use Alpine unless your enterprise requires UBI. Alpine is production-grade, widely used, and small enough that image pulls are fast even on slow networks.

---

## 3. Pushing to an Internal Registry

### Using the build-and-push.sh script (recommended)

The script handles building, tagging, and pushing in one step.

```bash
# Check available Pyroscope versions
bash build-and-push.sh --list-tags

# Preview what will happen (no changes made)
bash build-and-push.sh --version 1.18.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push --dry-run

# Build and push
bash build-and-push.sh --version 1.18.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push

# Also update the :latest tag in the registry
bash build-and-push.sh --version 1.18.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push --latest
```

This produces:

```
company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
company.corp.com/docker-proxy/pyroscope/pyroscope-server:latest   (if --latest)
```

### Pushing manually

If you prefer not to use the script:

```bash
# 1. Build with a pinned version
docker build --build-arg BASE_IMAGE=grafana/pyroscope:1.18.0 \
    -t pyroscope-server:1.18.0 .

# 2. Tag for your internal registry
docker tag pyroscope-server:1.18.0 \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0

# 3. Log in to your internal registry (if not already authenticated)
docker login company.corp.com

# 4. Push
docker push company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0

# 5. Optionally update the :latest tag
docker tag pyroscope-server:1.18.0 \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:latest
docker push company.corp.com/docker-proxy/pyroscope/pyroscope-server:latest
```

### Pushing a custom base image

Same workflow, just build with `Dockerfile.custom` first:

```bash
# Build with UBI base
docker build -f Dockerfile.custom \
    --build-arg PYROSCOPE_VERSION=1.18.0 \
    --build-arg BASE_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10 \
    -t pyroscope-server:1.18.0-ubi .

# Tag and push
docker tag pyroscope-server:1.18.0-ubi \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0-ubi
docker push company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0-ubi
```

Use a tag suffix (e.g., `-ubi`, `-alpine`) to distinguish custom base images from the default.

### Cross-platform builds (Mac workstation to Linux VM)

If building on a Mac with Apple Silicon for a Linux x86_64 VM:

```bash
bash build-and-push.sh --version 1.18.0 --platform linux/amd64 \
    --registry company.corp.com/docker-proxy/pyroscope --push
```

Or manually:

```bash
docker build --platform linux/amd64 \
    --build-arg BASE_IMAGE=grafana/pyroscope:1.18.0 \
    -t pyroscope-server:1.18.0 .
```

---

## 4. Pulling and Running on VMs

After pushing to your internal registry, VMs pull directly — no Docker Hub access needed.

```bash
# Pull
docker pull company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0

# Run
docker volume create pyroscope-data
docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0

# Verify
curl -s http://localhost:4040/ready && echo " OK"
```

---

## 5. Upgrading

### Build and push the new version (from your workstation)

```bash
bash build-and-push.sh --version 1.19.0 \
    --registry company.corp.com/docker-proxy/pyroscope \
    --push --latest
```

### Upgrade on the VM

```bash
docker pull company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.19.0
docker rm -f pyroscope
docker run -d \
    --name pyroscope \
    --restart unless-stopped \
    -p 4040:4040 \
    -v pyroscope-data:/data \
    company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.19.0
```

The `pyroscope-data` volume is preserved across upgrades — profiling data is not lost.

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

#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-and-push.sh — Build Grafana image and push to internal registry
#
# Run this from a machine with internet access (your workstation or a build
# server). It pulls the upstream Grafana image, bakes in grafana.ini,
# provisioning files, and dashboards, pins the version, and pushes to your
# internal Docker registry.
#
# After pushing, VMs that cannot reach Docker Hub can pull the pre-built
# image directly from the internal registry.
#
# Usage:
#   bash build-and-push.sh [options]
#
# Examples:
#   # Build with default version, do not push
#   bash build-and-push.sh
#
#   # Build a specific version
#   bash build-and-push.sh --version 11.5.2
#
#   # Build and push to internal registry
#   bash build-and-push.sh --version 11.5.2 --push
#
#   # Build, push, and also tag as :latest in the registry
#   bash build-and-push.sh --version 11.5.2 --push --latest
#
#   # Override registry
#   bash build-and-push.sh --version 11.5.2 --registry mycompany.jfrog.io/docker/grafana --push
#
#   # Pull official image and push directly (no Dockerfile build)
#   bash build-and-push.sh --version 11.5.2 --pull-only --push
#
#   # Build and save as tar file for scp to VM (no registry needed)
#   bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --save
#
#   # Dry run — show what would be built and pushed without executing
#   bash build-and-push.sh --version 11.5.2 --push --dry-run
#
#   # List available upstream versions
#   bash build-and-push.sh --list-tags
# ---------------------------------------------------------------------------

# ---- Configuration (edit these or override via environment / flags) -------

# Upstream Grafana image on Docker Hub
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-grafana/grafana}"

# Version to build — pin to a specific release, avoid "latest" in production
VERSION="${VERSION:-11.5.2}"

# Internal Docker registry path
# The full image will be: <REGISTRY>/<IMAGE_NAME>:<VERSION>
# Example: company.corp.com/docker-proxy/grafana/grafana-server:11.5.2
REGISTRY="${REGISTRY:-company.corp.com/docker-proxy/grafana}"

# Image name (appended to REGISTRY path)
IMAGE_NAME="${IMAGE_NAME:-grafana-server}"

# Platform to build for (default: current platform)
# Set to "linux/amd64" if building on Mac/ARM for Linux VMs
PLATFORM="${PLATFORM:-}"

# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---- Logging -------------------------------------------------------------
if [ -t 1 ]; then
    info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
    ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
    warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
    err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
else
    info()  { printf '[INFO]  %s\n' "$*"; }
    ok()    { printf '[OK]    %s\n' "$*"; }
    warn()  { printf '[WARN]  %s\n' "$*"; }
    err()   { printf '[ERROR] %s\n' "$*" >&2; }
fi

# ---- Usage ----------------------------------------------------------------
usage() {
    cat <<USAGE
Usage: bash build-and-push.sh [options]

Options:
  --version <version>  Grafana version to build (default: ${VERSION})
  --registry <url>     Internal registry path (default: ${REGISTRY})
  --image <name>       Image name (default: ${IMAGE_NAME})
  --upstream <image>   Upstream Docker Hub image (default: ${UPSTREAM_IMAGE})
  --platform <platform> Target platform, e.g., linux/amd64 (default: current)
  --pull-only          Pull the official image and push directly (no Dockerfile build)
  --save [path]        Export image as tar file for scp to VM (default: ./<image>-<version>.tar)
  --push               Push the image to the internal registry after building
  --latest             Also tag and push as :latest (requires --push)
  --clean              Remove Grafana container, image, volume, and config from the VM
  --clean-keep-data    Remove container and image but keep volume and config
  --dry-run            Show what would be done without executing
  --list-tags          List recent upstream tags from Docker Hub
  --no-cache           Build without Docker cache (force fresh pull)
  -h, --help           Show this help

Environment Variables (alternative to flags):
  VERSION              Grafana version (default: ${VERSION})
  REGISTRY             Internal registry path
  IMAGE_NAME           Image name (default: ${IMAGE_NAME})
  UPSTREAM_IMAGE       Upstream Docker Hub image (default: ${UPSTREAM_IMAGE})
  PLATFORM             Target platform (e.g., linux/amd64)

Examples:
  # Pin to a specific version and build locally
  bash build-and-push.sh --version 11.5.2

  # Build and push to Artifactory
  bash build-and-push.sh --version 11.5.2 --push

  # Push versioned tag and update :latest
  bash build-and-push.sh --version 11.5.2 --push --latest

  # Override registry for a different environment
  bash build-and-push.sh --version 11.5.2 --registry mycompany.jfrog.io/docker/grafana --push

  # Build for Linux AMD64 from a Mac
  bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --push

  # Pull official image and push directly (no build, no Dockerfile needed)
  bash build-and-push.sh --version 11.5.2 --pull-only --push

  # Pull official image for Linux AMD64 from a Mac
  bash build-and-push.sh --version 11.5.2 --pull-only --platform linux/amd64 --push

  # Build and save as tar for scp to VM (no registry needed on VM)
  bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --save

  # Save to a custom path
  bash build-and-push.sh --version 11.5.2 --platform linux/amd64 --save /tmp/grafana.tar

  # Clean up everything on the VM (container, image, volume, config)
  bash build-and-push.sh --clean

  # Clean up but keep data volume and config (for redeployment)
  bash build-and-push.sh --clean-keep-data

  # Preview without executing
  bash build-and-push.sh --version 11.5.2 --push --dry-run
USAGE
    exit 0
}

# ---- Parse arguments ------------------------------------------------------
DO_PUSH=false
DO_SAVE=false
SAVE_PATH=""
DO_CLEAN=false
CLEAN_KEEP_DATA=false
TAG_LATEST=false
DRY_RUN=false
LIST_TAGS=false
NO_CACHE=false
PULL_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --version)    VERSION="${2:?--version requires a value}"; shift 2 ;;
        --registry)   REGISTRY="${2:?--registry requires a value}"; shift 2 ;;
        --image)      IMAGE_NAME="${2:?--image requires a value}"; shift 2 ;;
        --upstream)   UPSTREAM_IMAGE="${2:?--upstream requires a value}"; shift 2 ;;
        --platform)   PLATFORM="${2:?--platform requires a value}"; shift 2 ;;
        --pull-only)  PULL_ONLY=true; shift ;;
        --save)       DO_SAVE=true
                      # Optional path argument: if next arg exists and doesn't start with --, use it
                      if [ $# -ge 2 ] && [[ ! "$2" =~ ^-- ]]; then
                          SAVE_PATH="$2"; shift
                      fi
                      shift ;;
        --clean)      DO_CLEAN=true; shift ;;
        --clean-keep-data) DO_CLEAN=true; CLEAN_KEEP_DATA=true; shift ;;
        --push)       DO_PUSH=true; shift ;;
        --latest)     TAG_LATEST=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --list-tags)  LIST_TAGS=true; shift ;;
        --no-cache)   NO_CACHE=true; shift ;;
        -h|--help|help) usage ;;
        -*)           err "Unknown option: $1"; exit 1 ;;
        *)            err "Unexpected argument: $1. Use --version <version> to specify a version."; exit 1 ;;
    esac
done

# ---- List tags ------------------------------------------------------------
if [ "${LIST_TAGS}" = true ]; then
    info "Fetching recent tags for ${UPSTREAM_IMAGE} from Docker Hub..."
    # Use Docker Hub API to list tags, filter to semver-like tags
    if command -v curl >/dev/null 2>&1; then
        curl -s "https://hub.docker.com/v2/repositories/${UPSTREAM_IMAGE}/tags/?page_size=25&ordering=last_updated" \
            | grep -oP '"name"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -t. -k1,1nr -k2,2nr -k3,3nr \
            | head -15
    else
        err "curl is required for --list-tags"
        exit 1
    fi
    exit 0
fi

# ---- Clean ----------------------------------------------------------------
if [ "${DO_CLEAN}" = true ]; then
    echo ""
    info "Cleaning up Grafana deployment on this machine..."
    echo ""

    # Stop and remove container
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx grafana; then
        info "Stopping and removing container: grafana"
        docker rm -f grafana 2>/dev/null || true
        ok "Container removed"
    else
        info "No container named 'grafana' found — skipping"
    fi

    # Remove image
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${IMAGE_NAME}:"; then
        info "Removing image: ${IMAGE_NAME}"
        docker rmi $(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${IMAGE_NAME}:") 2>/dev/null || true
        ok "Image removed"
    else
        info "No image named '${IMAGE_NAME}' found — skipping"
    fi

    if [ "${CLEAN_KEEP_DATA}" = true ]; then
        warn "Keeping volume 'grafana-data' and config '/opt/grafana/' (--clean-keep-data)"
    else
        # Remove volume
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx grafana-data; then
            warn "Removing volume: grafana-data (THIS DELETES ALL GRAFANA DATA)"
            docker volume rm grafana-data 2>/dev/null || true
            ok "Volume removed"
        else
            info "No volume named 'grafana-data' found — skipping"
        fi

        # Remove config directory
        if [ -d /opt/grafana ]; then
            info "Removing config directory: /opt/grafana/"
            rm -rf /opt/grafana
            ok "Config directory removed"
        else
            info "No config directory at /opt/grafana/ — skipping"
        fi
    fi

    # Remove temp files
    if [ -d /tmp/grafana-deploy ]; then
        info "Removing temp directory: /tmp/grafana-deploy/"
        rm -rf /tmp/grafana-deploy
        ok "Temp directory removed"
    fi

    echo ""
    ok "Cleanup complete"
    exit 0
fi

# ---- Validate -------------------------------------------------------------
if [ "${TAG_LATEST}" = true ] && [ "${DO_PUSH}" = false ]; then
    err "--latest requires --push"
    exit 1
fi

if [ "${VERSION}" = "latest" ]; then
    warn "Using 'latest' is not recommended for production. Pin a specific version with --version."
    warn "Use --list-tags to see available versions."
fi

# ---- Derived values -------------------------------------------------------
REGISTRY_IMAGE="${REGISTRY}/${IMAGE_NAME}"
UPSTREAM_TAG="${UPSTREAM_IMAGE}:${VERSION}"
LOCAL_TAG="${IMAGE_NAME}:${VERSION}"
REGISTRY_TAG="${REGISTRY_IMAGE}:${VERSION}"
REGISTRY_LATEST="${REGISTRY_IMAGE}:latest"

# Default save path: ./<image-name>-<version>.tar
if [ "${DO_SAVE}" = true ] && [ -z "${SAVE_PATH}" ]; then
    SAVE_PATH="./${IMAGE_NAME}-${VERSION}.tar"
fi

# ---- Pre-flight -----------------------------------------------------------
if [ "${DRY_RUN}" = false ]; then
    if ! command -v docker >/dev/null 2>&1; then
        err "Docker is not installed"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        err "Docker daemon is not running"
        exit 1
    fi
fi

if [ "${PULL_ONLY}" = false ]; then
    if [ ! -f "${SCRIPT_DIR}/Dockerfile" ]; then
        err "Dockerfile not found in ${SCRIPT_DIR}"
        exit 1
    fi

    if [ ! -f "${SCRIPT_DIR}/grafana.ini" ]; then
        err "grafana.ini not found in ${SCRIPT_DIR}"
        exit 1
    fi
fi

# ---- Stage build context --------------------------------------------------
# The Dockerfile expects provisioning/ and dashboards/ in the build context.
# These live in config/grafana/ in the repo. Copy them alongside the Dockerfile.
STAGED_FILES=false

stage_build_context() {
    if [ -d "${SCRIPT_DIR}/provisioning" ] && [ -d "${SCRIPT_DIR}/dashboards" ]; then
        return 0
    fi

    if [ -d "${REPO_ROOT}/config/grafana/provisioning" ] && [ -d "${REPO_ROOT}/config/grafana/dashboards" ]; then
        info "Staging provisioning and dashboard files into build context"
        cp -rf "${REPO_ROOT}/config/grafana/provisioning" "${SCRIPT_DIR}/provisioning"
        cp -rf "${REPO_ROOT}/config/grafana/dashboards"   "${SCRIPT_DIR}/dashboards"
        STAGED_FILES=true
    else
        err "Cannot find config/grafana/provisioning/ and config/grafana/dashboards/ in repo root"
        err "Repo root: ${REPO_ROOT}"
        exit 1
    fi
}

cleanup_staged_files() {
    if [ "${STAGED_FILES}" = true ]; then
        rm -rf "${SCRIPT_DIR}/provisioning" "${SCRIPT_DIR}/dashboards"
    fi
}

trap cleanup_staged_files EXIT

# ---- Summary --------------------------------------------------------------
echo ""
info "Configuration:"
info "  Upstream image:    ${UPSTREAM_TAG}"
info "  Local tag:         ${LOCAL_TAG}"
info "  Registry tag:      ${REGISTRY_TAG}"
if [ "${TAG_LATEST}" = true ]; then
    info "  Registry latest:   ${REGISTRY_LATEST}"
fi
if [ -n "${PLATFORM}" ]; then
    info "  Platform:          ${PLATFORM}"
fi
info "  Push to registry:  ${DO_PUSH}"
if [ "${DO_SAVE}" = true ]; then
    info "  Save to file:      ${SAVE_PATH}"
fi
if [ "${PULL_ONLY}" = true ]; then
    info "  Mode:              PULL ONLY (no Dockerfile build)"
fi
if [ "${DRY_RUN}" = true ]; then
    info "  Mode:              DRY RUN (no commands executed)"
fi
echo ""

# ---- Dry run exit ---------------------------------------------------------
if [ "${DRY_RUN}" = true ]; then
    info "Commands that would be executed:"
    echo ""
    PLATFORM_FLAG=""
    if [ -n "${PLATFORM}" ]; then
        PLATFORM_FLAG="--platform ${PLATFORM} "
    fi
    if [ "${PULL_ONLY}" = true ]; then
        echo "  docker pull ${PLATFORM_FLAG}${UPSTREAM_TAG}"
        echo "  docker tag ${UPSTREAM_TAG} ${REGISTRY_TAG}"
    else
        CACHE_FLAG=""
        if [ "${NO_CACHE}" = true ]; then
            CACHE_FLAG="--no-cache "
        fi
        echo "  docker build ${PLATFORM_FLAG}${CACHE_FLAG}--build-arg BASE_IMAGE=${UPSTREAM_TAG} -t ${LOCAL_TAG} -t ${REGISTRY_TAG} ${SCRIPT_DIR}"
    fi
    if [ "${TAG_LATEST}" = true ]; then
        echo "  docker tag ${REGISTRY_TAG} ${REGISTRY_LATEST}"
    fi
    if [ "${DO_SAVE}" = true ]; then
        echo "  docker save -o ${SAVE_PATH} ${LOCAL_TAG}"
    fi
    if [ "${DO_PUSH}" = true ]; then
        echo "  docker push ${REGISTRY_TAG}"
        if [ "${TAG_LATEST}" = true ]; then
            echo "  docker push ${REGISTRY_LATEST}"
        fi
    fi
    echo ""
    if [ "${PULL_ONLY}" = true ]; then
        warn "Note: --pull-only pushes the official image without grafana.ini or dashboards baked in."
        info "Mount your config at runtime:"
        info "  -v /opt/grafana/grafana.ini:/etc/grafana/grafana.ini:ro"
        info "  -v /opt/grafana/provisioning:/etc/grafana/provisioning:ro"
        info "  -v /opt/grafana/dashboards:/var/lib/grafana/dashboards:ro"
    fi
    if [ "${DO_SAVE}" = true ]; then
        info "After saving, scp the tar and config to the VM:"
        info "  scp ${SAVE_PATH} operator@vm:/tmp/grafana-deploy/"
        info "  scp ${SCRIPT_DIR}/grafana.ini operator@vm:/tmp/grafana-deploy/"
        info "  ssh operator@vm 'docker load -i /tmp/grafana-deploy/$(basename "${SAVE_PATH}")'"
    fi
    info "Re-run without --dry-run to execute."
    exit 0
fi

# ---- Build or Pull --------------------------------------------------------
if [ "${PULL_ONLY}" = true ]; then
    # Pull the official image directly and re-tag for internal registry
    PULL_ARGS=()
    if [ -n "${PLATFORM}" ]; then
        PULL_ARGS+=(--platform "${PLATFORM}")
    fi

    info "Pulling official image ${UPSTREAM_TAG}..."
    docker pull "${PULL_ARGS[@]}" "${UPSTREAM_TAG}"

    docker tag "${UPSTREAM_TAG}" "${REGISTRY_TAG}"
    ok "Pulled: ${UPSTREAM_TAG}"
    ok "Tagged: ${REGISTRY_TAG}"

    if [ "${TAG_LATEST}" = true ]; then
        docker tag "${UPSTREAM_TAG}" "${REGISTRY_LATEST}"
        ok "Tagged: ${REGISTRY_LATEST}"
    fi

    warn "Note: --pull-only pushes the official image without grafana.ini or dashboards baked in."
    info "Mount your config at runtime:"
    info "  -v /opt/grafana/grafana.ini:/etc/grafana/grafana.ini:ro"
    info "  -v /opt/grafana/provisioning:/etc/grafana/provisioning:ro"
    info "  -v /opt/grafana/dashboards:/var/lib/grafana/dashboards:ro"
else
    # Stage provisioning and dashboard files into build context
    stage_build_context

    # Build custom image with grafana.ini, provisioning, and dashboards baked in
    BUILD_ARGS=(
        --build-arg "BASE_IMAGE=${UPSTREAM_TAG}"
        -t "${LOCAL_TAG}"
        -t "${REGISTRY_TAG}"
    )

    if [ -n "${PLATFORM}" ]; then
        BUILD_ARGS+=(--platform "${PLATFORM}")
    fi

    if [ "${NO_CACHE}" = true ]; then
        BUILD_ARGS+=(--no-cache)
    fi

    info "Building image from ${UPSTREAM_TAG}..."
    docker build "${BUILD_ARGS[@]}" "${SCRIPT_DIR}"

    ok "Built: ${LOCAL_TAG}"
    ok "Tagged: ${REGISTRY_TAG}"

    if [ "${TAG_LATEST}" = true ]; then
        docker tag "${LOCAL_TAG}" "${REGISTRY_LATEST}"
        ok "Tagged: ${REGISTRY_LATEST}"
    fi
fi

# ---- Print image info -----------------------------------------------------
echo ""
info "Image details:"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" \
    --filter "reference=${IMAGE_NAME}" \
    --filter "reference=${REGISTRY_IMAGE}"
echo ""

# ---- Push -----------------------------------------------------------------
if [ "${DO_PUSH}" = true ]; then
    info "Pushing ${REGISTRY_TAG}..."
    docker push "${REGISTRY_TAG}"
    ok "Pushed: ${REGISTRY_TAG}"

    if [ "${TAG_LATEST}" = true ]; then
        info "Pushing ${REGISTRY_LATEST}..."
        docker push "${REGISTRY_LATEST}"
        ok "Pushed: ${REGISTRY_LATEST}"
    fi

    echo ""
    ok "Done. Pull on VMs with:"
    info "  docker pull ${REGISTRY_TAG}"
    echo ""
    info "Run on VMs with:"
    if [ "${PULL_ONLY}" = true ]; then
        info "  # Copy grafana.ini, provisioning/, and dashboards/ to the VM first, then mount at runtime:"
        info "  docker run -d \\"
        info "      --name grafana \\"
        info "      --restart unless-stopped \\"
        info "      -p 3000:3000 \\"
        info "      -v grafana-data:/var/lib/grafana \\"
        info "      -v /opt/grafana/grafana.ini:/etc/grafana/grafana.ini:ro \\"
        info "      -v /opt/grafana/provisioning:/etc/grafana/provisioning:ro \\"
        info "      -v /opt/grafana/dashboards:/var/lib/grafana/dashboards:ro \\"
        info "      ${REGISTRY_TAG}"
    else
        info "  docker run -d \\"
        info "      --name grafana \\"
        info "      --restart unless-stopped \\"
        info "      -p 3000:3000 \\"
        info "      -v grafana-data:/var/lib/grafana \\"
        info "      ${REGISTRY_TAG}"
    fi
    echo ""
else
    echo ""
    info "Image built locally. To push to your internal registry, re-run with --push:"
    info "  bash build-and-push.sh --version ${VERSION} --push"
    echo ""
    info "To save as tar for scp to VM, re-run with --save:"
    info "  bash build-and-push.sh --version ${VERSION} --save"
    echo ""
    info "To inspect the image locally:"
    info "  docker run --rm -p 3000:3000 ${LOCAL_TAG}"
    echo ""
fi

# ---- Save as tar file ----------------------------------------------------
if [ "${DO_SAVE}" = true ]; then
    info "Saving image to ${SAVE_PATH}..."
    docker save -o "${SAVE_PATH}" "${LOCAL_TAG}"
    SAVE_SIZE=$(ls -lh "${SAVE_PATH}" | awk '{print $5}')
    ok "Saved: ${SAVE_PATH} (${SAVE_SIZE})"
    echo ""
    info "Copy to your VM and load:"
    info "  scp ${SAVE_PATH} operator@vm:/tmp/grafana-deploy/"
    info "  scp ${SCRIPT_DIR}/grafana.ini operator@vm:/tmp/grafana-deploy/"
    info "  ssh operator@vm"
    info "  docker load -i /tmp/grafana-deploy/$(basename "${SAVE_PATH}")"
    info "  mkdir -p /opt/grafana"
    info "  cp /tmp/grafana-deploy/grafana.ini /opt/grafana/grafana.ini"
    echo ""
    info "Then run on the VM:"
    info "  docker volume create grafana-data"
    info "  docker run -d \\"
    info "      --name grafana \\"
    info "      --restart unless-stopped \\"
    info "      -p 3000:3000 \\"
    info "      -v grafana-data:/var/lib/grafana \\"
    info "      ${LOCAL_TAG}"
    echo ""
    info "To change config later: edit /opt/grafana/grafana.ini, then docker restart grafana"
    echo ""
fi

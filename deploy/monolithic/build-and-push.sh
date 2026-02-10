#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-and-push.sh — Build Pyroscope image and push to internal registry
#
# Run this from a machine with internet access (your workstation or a build
# server). It pulls the upstream Pyroscope image, bakes in pyroscope.yaml,
# pins the version, and pushes to your internal Docker registry.
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
#   bash build-and-push.sh --version 1.18.0
#
#   # Build and push to internal registry
#   bash build-and-push.sh --version 1.18.0 --push
#
#   # Build, push, and also tag as :latest in the registry
#   bash build-and-push.sh --version 1.18.0 --push --latest
#
#   # Override registry
#   bash build-and-push.sh --version 1.18.0 --registry mycompany.jfrog.io/docker/pyroscope --push
#
#   # Dry run — show what would be built and pushed without executing
#   bash build-and-push.sh --version 1.18.0 --push --dry-run
#
#   # List available upstream versions
#   bash build-and-push.sh --list-tags
# ---------------------------------------------------------------------------

# ---- Configuration (edit these or override via environment / flags) -------

# Upstream Pyroscope image on Docker Hub
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-grafana/pyroscope}"

# Version to build — pin to a specific release, avoid "latest" in production
VERSION="${VERSION:-1.18.0}"

# Internal Docker registry path
# The full image will be: <REGISTRY>/<IMAGE_NAME>:<VERSION>
# Example: company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.18.0
REGISTRY="${REGISTRY:-company.corp.com/docker-proxy/pyroscope}"

# Image name (appended to REGISTRY path)
IMAGE_NAME="${IMAGE_NAME:-pyroscope-server}"

# Platform to build for (default: current platform)
# Set to "linux/amd64" if building on Mac/ARM for Linux VMs
PLATFORM="${PLATFORM:-}"

# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  --version <version>  Pyroscope version to build (default: ${VERSION})
  --registry <url>     Internal registry path (default: ${REGISTRY})
  --image <name>       Image name (default: ${IMAGE_NAME})
  --upstream <image>   Upstream Docker Hub image (default: ${UPSTREAM_IMAGE})
  --platform <platform> Target platform, e.g., linux/amd64 (default: current)
  --push               Push the image to the internal registry after building
  --latest             Also tag and push as :latest (requires --push)
  --dry-run            Show what would be done without executing
  --list-tags          List recent upstream tags from Docker Hub
  --no-cache           Build without Docker cache (force fresh pull)
  -h, --help           Show this help

Environment Variables (alternative to flags):
  VERSION              Pyroscope version (default: ${VERSION})
  REGISTRY             Internal registry path
  IMAGE_NAME           Image name (default: ${IMAGE_NAME})
  UPSTREAM_IMAGE       Upstream Docker Hub image (default: ${UPSTREAM_IMAGE})
  PLATFORM             Target platform (e.g., linux/amd64)

Examples:
  # Pin to a specific version and build locally
  bash build-and-push.sh --version 1.18.0

  # Build and push to Artifactory
  bash build-and-push.sh --version 1.18.0 --push

  # Push versioned tag and update :latest
  bash build-and-push.sh --version 1.18.0 --push --latest

  # Override registry for a different environment
  bash build-and-push.sh --version 1.18.0 --registry mycompany.jfrog.io/docker/pyroscope --push

  # Build for Linux AMD64 from a Mac
  bash build-and-push.sh --version 1.18.0 --platform linux/amd64 --push

  # Preview without executing
  bash build-and-push.sh --version 1.18.0 --push --dry-run
USAGE
    exit 0
}

# ---- Parse arguments ------------------------------------------------------
DO_PUSH=false
TAG_LATEST=false
DRY_RUN=false
LIST_TAGS=false
NO_CACHE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --version)    VERSION="${2:?--version requires a value}"; shift 2 ;;
        --registry)   REGISTRY="${2:?--registry requires a value}"; shift 2 ;;
        --image)      IMAGE_NAME="${2:?--image requires a value}"; shift 2 ;;
        --upstream)   UPSTREAM_IMAGE="${2:?--upstream requires a value}"; shift 2 ;;
        --platform)   PLATFORM="${2:?--platform requires a value}"; shift 2 ;;
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

if [ ! -f "${SCRIPT_DIR}/Dockerfile" ]; then
    err "Dockerfile not found in ${SCRIPT_DIR}"
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/pyroscope.yaml" ]; then
    err "pyroscope.yaml not found in ${SCRIPT_DIR}"
    exit 1
fi

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
    CACHE_FLAG=""
    if [ "${NO_CACHE}" = true ]; then
        CACHE_FLAG="--no-cache "
    fi
    echo "  docker build ${PLATFORM_FLAG}${CACHE_FLAG}--build-arg BASE_IMAGE=${UPSTREAM_TAG} -t ${LOCAL_TAG} -t ${REGISTRY_TAG} ${SCRIPT_DIR}"
    if [ "${TAG_LATEST}" = true ]; then
        echo "  docker tag ${LOCAL_TAG} ${REGISTRY_LATEST}"
    fi
    if [ "${DO_PUSH}" = true ]; then
        echo "  docker push ${REGISTRY_TAG}"
        if [ "${TAG_LATEST}" = true ]; then
            echo "  docker push ${REGISTRY_LATEST}"
        fi
    fi
    echo ""
    info "Re-run without --dry-run to execute."
    exit 0
fi

# ---- Build ----------------------------------------------------------------
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
    info "  docker run -d \\"
    info "      --name pyroscope \\"
    info "      --restart unless-stopped \\"
    info "      -p 4040:4040 \\"
    info "      -v pyroscope-data:/data \\"
    info "      ${REGISTRY_TAG}"
    echo ""
else
    echo ""
    info "Image built locally. To push to your internal registry, re-run with --push:"
    info "  bash build-and-push.sh --version ${VERSION} --push"
    echo ""
    info "To inspect the image locally:"
    info "  docker run --rm -p 4040:4040 ${LOCAL_TAG}"
    echo ""
fi

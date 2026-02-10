#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-and-push.sh — Build Pyroscope image and push to internal registry
#
# Run this from a machine with internet access (your workstation or a build
# server). It pulls the upstream Pyroscope image, bakes in pyroscope.yaml,
# pins the version, and pushes to your internal Artifactory Docker registry.
#
# After pushing, VMs that cannot reach Docker Hub can pull the pre-built
# image directly from Artifactory.
#
# Usage:
#   bash build-and-push.sh                          # latest version
#   bash build-and-push.sh 1.13.0                   # pinned version
#   bash build-and-push.sh 1.13.0 --push            # build and push
#   bash build-and-push.sh 1.13.0 --push --latest   # also tag as :latest
#
# Examples:
#   # Build only (inspect locally before pushing)
#   bash deploy/monolithic/build-and-push.sh 1.13.0
#
#   # Build and push to Artifactory
#   bash deploy/monolithic/build-and-push.sh 1.13.0 --push
#
#   # Build, push versioned tag, and update :latest tag
#   bash deploy/monolithic/build-and-push.sh 1.13.0 --push --latest
# ---------------------------------------------------------------------------

# ---- Configuration (edit these or override via environment) ---------------

# Internal Artifactory Docker registry
# Format: <registry>/<repo-path>/<image-name>
REGISTRY="${REGISTRY:-company.corp.com/docker-proxy/pyroscope}"
IMAGE_NAME="${IMAGE_NAME:-pyroscope-server}"

# Full image path in Artifactory
# e.g., company.corp.com/docker-proxy/pyroscope/pyroscope-server:1.13.0
REGISTRY_IMAGE="${REGISTRY}/${IMAGE_NAME}"

# Upstream Pyroscope image (Docker Hub)
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-grafana/pyroscope}"

# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Logging -------------------------------------------------------------
if [ -t 1 ]; then
    info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
    ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
    err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
else
    info()  { printf '[INFO]  %s\n' "$*"; }
    ok()    { printf '[OK]    %s\n' "$*"; }
    err()   { printf '[ERROR] %s\n' "$*" >&2; }
fi

# ---- Usage ----------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: bash build-and-push.sh [version] [options]

Arguments:
  version              Pyroscope version to build (e.g., 1.13.0). Default: latest

Options:
  --push               Push the image to the internal registry after building
  --latest             Also tag and push as :latest (requires --push)
  -h, --help           Show this help

Environment Variables:
  REGISTRY             Registry path (default: company.corp.com/docker-proxy/pyroscope)
  IMAGE_NAME           Image name (default: pyroscope-server)
  UPSTREAM_IMAGE       Upstream image (default: grafana/pyroscope)

Examples:
  bash build-and-push.sh 1.13.0                  # build locally
  bash build-and-push.sh 1.13.0 --push           # build and push
  bash build-and-push.sh 1.13.0 --push --latest  # push versioned + latest tag
USAGE
    exit 0
}

# ---- Parse arguments ------------------------------------------------------
VERSION="latest"
DO_PUSH=false
TAG_LATEST=false

while [ $# -gt 0 ]; do
    case "$1" in
        --push)   DO_PUSH=true; shift ;;
        --latest) TAG_LATEST=true; shift ;;
        -h|--help|help) usage ;;
        -*)       err "Unknown option: $1"; exit 1 ;;
        *)        VERSION="$1"; shift ;;
    esac
done

if [ "${TAG_LATEST}" = true ] && [ "${DO_PUSH}" = false ]; then
    err "--latest requires --push"
    exit 1
fi

# ---- Pre-flight -----------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running"
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/Dockerfile" ]; then
    err "Dockerfile not found in ${SCRIPT_DIR}"
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/pyroscope.yaml" ]; then
    err "pyroscope.yaml not found in ${SCRIPT_DIR}"
    exit 1
fi

# ---- Resolve upstream tag -------------------------------------------------
UPSTREAM_TAG="${UPSTREAM_IMAGE}:${VERSION}"
LOCAL_TAG="${IMAGE_NAME}:${VERSION}"
REGISTRY_TAG="${REGISTRY_IMAGE}:${VERSION}"
REGISTRY_LATEST="${REGISTRY_IMAGE}:latest"

echo ""
info "Upstream image:  ${UPSTREAM_TAG}"
info "Local tag:       ${LOCAL_TAG}"
info "Registry tag:    ${REGISTRY_TAG}"
if [ "${TAG_LATEST}" = true ]; then
    info "Registry latest: ${REGISTRY_LATEST}"
fi
echo ""

# ---- Build ----------------------------------------------------------------
info "Building image from ${UPSTREAM_TAG}..."
docker build \
    --build-arg "BASE_IMAGE=${UPSTREAM_TAG}" \
    -t "${LOCAL_TAG}" \
    -t "${REGISTRY_TAG}" \
    "${SCRIPT_DIR}"

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
    info "  docker run -d --name pyroscope --restart unless-stopped -p 4040:4040 -v pyroscope-data:/data ${REGISTRY_TAG}"
    echo ""
else
    echo ""
    info "Image built locally. To push to Artifactory, re-run with --push:"
    info "  bash build-and-push.sh ${VERSION} --push"
    echo ""
    info "To inspect the image locally:"
    info "  docker run --rm -p 4040:4040 ${LOCAL_TAG}"
    echo ""
fi

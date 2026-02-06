#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy.sh — Deploy Pyroscope on a VM / EC2 instance
#
# Usage:
#   bash deploy.sh              # Build image, start container
#   bash deploy.sh stop         # Stop and remove container
#   bash deploy.sh restart      # Restart container
#   bash deploy.sh logs         # Tail container logs
#   bash deploy.sh status       # Show container status and health
#   bash deploy.sh clean        # Stop container and remove image + volume
# ---------------------------------------------------------------------------

IMAGE_NAME="pyroscope-server"
CONTAINER_NAME="pyroscope"
HOST_PORT="${PYROSCOPE_PORT:-4040}"
VOLUME_NAME="pyroscope-data"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
    ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
    err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
else
    info()  { printf '[INFO]  %s\n' "$*"; }
    ok()    { printf '[OK]    %s\n' "$*"; }
    err()   { printf '[ERROR] %s\n' "$*" >&2; }
fi

check_docker() {
    if ! command -v docker &>/dev/null; then
        err "Docker is not installed. Install it first:"
        err "  curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        err "Docker daemon is not running or current user lacks permissions."
        err "Try: sudo systemctl start docker && sudo usermod -aG docker \$USER"
        exit 1
    fi
}

wait_healthy() {
    local max_attempts=30
    local attempt=0
    info "Waiting for Pyroscope to become ready..."
    while [ $attempt -lt $max_attempts ]; do
        if docker exec "${CONTAINER_NAME}" wget -q --spider "http://localhost:4040/ready" 2>/dev/null; then
            ok "Pyroscope is ready at http://localhost:${HOST_PORT}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    err "Pyroscope did not become ready within 60 seconds"
    err "Check logs: $0 logs"
    return 1
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_start() {
    check_docker

    info "Building image: ${IMAGE_NAME}"
    docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

    # Stop existing container if running
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        info "Removing existing container: ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null
    fi

    # Create volume if it doesn't exist
    if ! docker volume ls --format '{{.Name}}' | grep -q "^${VOLUME_NAME}$"; then
        info "Creating volume: ${VOLUME_NAME}"
        docker volume create "${VOLUME_NAME}" >/dev/null
    fi

    info "Starting container: ${CONTAINER_NAME} (port ${HOST_PORT})"
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "${HOST_PORT}:4040" \
        -v "${VOLUME_NAME}:/data" \
        "${IMAGE_NAME}"

    wait_healthy
    echo ""
    info "Pyroscope UI:  http://localhost:${HOST_PORT}"
    info "Push endpoint: http://localhost:${HOST_PORT}/ingest"
    info "Ready endpoint: http://localhost:${HOST_PORT}/ready"
    echo ""
    info "To point your Java apps at this instance, set:"
    info "  -Dpyroscope.server.address=http://<VM_IP>:${HOST_PORT}"
}

cmd_stop() {
    check_docker
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        info "Stopping container: ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null
        ok "Container stopped and removed"
    else
        info "Container ${CONTAINER_NAME} is not running"
    fi
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_logs() {
    check_docker
    docker logs -f "${CONTAINER_NAME}"
}

cmd_status() {
    check_docker
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        ok "Container is running"
        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        if docker exec "${CONTAINER_NAME}" wget -q --spider "http://localhost:4040/ready" 2>/dev/null; then
            ok "Health check: ready"
        else
            err "Health check: not ready"
        fi
    else
        info "Container ${CONTAINER_NAME} is not running"
    fi
}

cmd_clean() {
    check_docker
    cmd_stop
    info "Removing image: ${IMAGE_NAME}"
    docker rmi "${IMAGE_NAME}" 2>/dev/null || true
    info "Removing volume: ${VOLUME_NAME}"
    docker volume rm "${VOLUME_NAME}" 2>/dev/null || true
    ok "Cleaned up image and volume"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-start}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    logs)    cmd_logs    ;;
    status)  cmd_status  ;;
    clean)   cmd_clean   ;;
    *)
        echo "Usage: bash deploy.sh {start|stop|restart|logs|status|clean}"
        exit 1
        ;;
esac

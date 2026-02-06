#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy.sh — Deploy Pyroscope in microservices mode (docker compose + NFS)
#
# Requires an NFS-mounted directory shared across all VMs. Set
# PYROSCOPE_DATA_DIR to override the default path (/mnt/pyroscope-data).
#
# Usage:
#   bash deploy.sh              # Start all services
#   bash deploy.sh stop         # Stop and remove all services
#   bash deploy.sh restart      # Restart all services
#   bash deploy.sh logs         # Tail logs from all services
#   bash deploy.sh status       # Show service status and health
#   bash deploy.sh clean        # Stop services and remove volumes
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yaml"
PROJECT_NAME="pyroscope-microservices"

PYROSCOPE_DATA_DIR="${PYROSCOPE_DATA_DIR:-/mnt/pyroscope-data}"
export PYROSCOPE_DATA_DIR

DISTRIBUTOR_PORT="${PYROSCOPE_PUSH_PORT:-4040}"
QUERY_PORT="${PYROSCOPE_QUERY_PORT:-4041}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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

compose() {
    docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" "$@"
}

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

check_nfs() {
    info "Checking NFS data directory: ${PYROSCOPE_DATA_DIR}"

    if [ ! -d "${PYROSCOPE_DATA_DIR}" ]; then
        err "Data directory does not exist: ${PYROSCOPE_DATA_DIR}"
        err "Mount your NFS share first, e.g.:"
        err "  sudo mount -t nfs nfs-server:/export/pyroscope ${PYROSCOPE_DATA_DIR}"
        exit 1
    fi

    if ! touch "${PYROSCOPE_DATA_DIR}/.pyroscope-write-test" 2>/dev/null; then
        err "Data directory is not writable: ${PYROSCOPE_DATA_DIR}"
        err "Check NFS export permissions and mount options (rw)."
        exit 1
    fi
    rm -f "${PYROSCOPE_DATA_DIR}/.pyroscope-write-test"

    ok "Data directory is accessible and writable"
}

wait_healthy() {
    local max_attempts=30
    local attempt=0
    info "Waiting for Pyroscope distributor to become ready..."
    while [ "$attempt" -lt "$max_attempts" ]; do
        if docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" \
            exec -T distributor wget -q --spider "http://localhost:4040/ready" 2>/dev/null; then
            ok "Distributor is ready"
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
    check_nfs

    info "Starting Pyroscope microservices cluster..."
    compose up -d

    wait_healthy
    echo ""
    info "Push endpoint (distributor):  http://localhost:${DISTRIBUTOR_PORT}"
    info "Query endpoint (frontend):   http://localhost:${QUERY_PORT}"
    echo ""
    info "To point your Java apps at this instance, set:"
    info "  -Dpyroscope.server.address=http://<HOST_IP>:${DISTRIBUTOR_PORT}"
}

cmd_stop() {
    check_docker
    info "Stopping Pyroscope microservices cluster..."
    compose down
    ok "All services stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_logs() {
    check_docker
    compose logs -f
}

cmd_status() {
    check_docker
    compose ps
    echo ""
    if docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" \
        exec -T distributor wget -q --spider "http://localhost:4040/ready" 2>/dev/null; then
        ok "Health check: distributor ready"
    else
        err "Health check: distributor not ready"
    fi
}

cmd_clean() {
    check_docker
    info "Stopping services and removing volumes..."
    compose down -v
    ok "Cleaned up all services and volumes"
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

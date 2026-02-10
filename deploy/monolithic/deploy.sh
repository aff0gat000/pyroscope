#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# vm-deploy.sh — Deploy Pyroscope on a remote VM (idempotent)
#
# Operator workflow:
#   1. SSH to the target VM
#   2. Elevate to root:  pbrun /bin/su -
#   3. Run this script
#
# Source options (choose one):
#   --from-local <path>   Copy from a local directory (e.g., scp'd from laptop)
#   --from-git  [url]     Clone or pull from a Git repository
#   --from-git            Clone from default repo (set REPO_URL below)
#
# Commands:
#   bash vm-deploy.sh start   [--from-local <path>|--from-git [url]]
#   bash vm-deploy.sh stop
#   bash vm-deploy.sh restart [--from-local <path>|--from-git [url]]
#   bash vm-deploy.sh logs
#   bash vm-deploy.sh status
#   bash vm-deploy.sh clean
#
# Idempotent: running "start" twice produces the same result. Existing
# containers are replaced, volumes are preserved, images are rebuilt.
#
# Examples:
#   # Operator SSHs to VM, elevates, deploys from Git
#   ssh operator@vm01.corp.example.com
#   pbrun /bin/su -
#   bash /tmp/vm-deploy.sh start --from-git
#
#   # Deploy from files scp'd to the VM
#   scp -r ./deploy/monolithic operator@vm01:/tmp/pyroscope-deploy
#   ssh operator@vm01
#   pbrun /bin/su -
#   bash /tmp/pyroscope-deploy/vm-deploy.sh start --from-local /tmp/pyroscope-deploy
# ---------------------------------------------------------------------------

# ---- Configuration (edit these or override via environment) ---------------
REPO_URL="${REPO_URL:-git@github.com:aff0gat000/pyroscope.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/pyroscope}"
HOST_PORT="${PYROSCOPE_PORT:-4040}"
CONTAINER_NAME="${CONTAINER_NAME:-pyroscope}"
IMAGE_NAME="${IMAGE_NAME:-pyroscope-server}"
VOLUME_NAME="${VOLUME_NAME:-pyroscope-data}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
readonly REPO_URL REPO_BRANCH INSTALL_DIR HOST_PORT
readonly CONTAINER_NAME IMAGE_NAME VOLUME_NAME HEALTH_TIMEOUT

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

# ---- Pre-flight checks ---------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root."
        err "Run:  pbrun /bin/su -"
        return 1
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        err "Docker is not installed."
        err "Install with:  curl -fsSL https://get.docker.com | sh"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        err "Docker daemon is not running."
        err "Start with:  systemctl start docker"
        return 1
    fi
    ok "Docker is available"
}

preflight() {
    check_root
    check_docker
}

# ---- Source acquisition ---------------------------------------------------
acquire_from_local() {
    local src="$1"
    if [ ! -d "${src}" ]; then
        err "Local source directory not found: ${src}"
        return 1
    fi

    info "Copying from local directory: ${src}"
    mkdir -p "${INSTALL_DIR}"

    local deploy_dir=""
    if [ -f "${src}/deploy/monolithic/Dockerfile" ]; then
        deploy_dir="${src}/deploy/monolithic"
    elif [ -f "${src}/Dockerfile" ]; then
        deploy_dir="${src}"
    else
        err "Cannot find Dockerfile in ${src} or ${src}/deploy/monolithic/"
        return 1
    fi

    cp -f "${deploy_dir}/Dockerfile"     "${INSTALL_DIR}/Dockerfile"
    cp -f "${deploy_dir}/pyroscope.yaml" "${INSTALL_DIR}/pyroscope.yaml"
    ok "Files copied to ${INSTALL_DIR}"
}

acquire_from_git() {
    local url="${1:-${REPO_URL}}"

    if ! command -v git >/dev/null 2>&1; then
        err "git is not installed."
        err "Install with:  yum install -y git  OR  apt-get install -y git"
        return 1
    fi

    if [ -d "${INSTALL_DIR}/.git" ]; then
        info "Updating existing repo at ${INSTALL_DIR}"
        git -C "${INSTALL_DIR}" fetch origin
        git -C "${INSTALL_DIR}" reset --hard "origin/${REPO_BRANCH}"
    else
        info "Cloning ${url} (branch: ${REPO_BRANCH})"
        mkdir -p "$(dirname "${INSTALL_DIR}")"
        git clone --branch "${REPO_BRANCH}" --depth 1 "${url}" "${INSTALL_DIR}"
    fi
    ok "Repo ready at ${INSTALL_DIR}"
}

# ---- Resolve the Dockerfile directory ------------------------------------
resolve_deploy_dir() {
    if [ -f "${INSTALL_DIR}/deploy/monolithic/Dockerfile" ]; then
        printf '%s' "${INSTALL_DIR}/deploy/monolithic"
    elif [ -f "${INSTALL_DIR}/Dockerfile" ]; then
        printf '%s' "${INSTALL_DIR}"
    else
        err "Cannot find Dockerfile in ${INSTALL_DIR}"
        return 1
    fi
}

# ---- Container helpers (idempotent) --------------------------------------
remove_container_if_exists() {
    if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        info "Removing existing container: ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null
    fi
}

ensure_volume() {
    if ! docker volume ls --format '{{.Name}}' | grep -qx "${VOLUME_NAME}"; then
        info "Creating volume: ${VOLUME_NAME}"
        docker volume create "${VOLUME_NAME}" >/dev/null
    fi
}

container_running() {
    docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"
}

wait_healthy() {
    local max_seconds="${HEALTH_TIMEOUT}"
    local elapsed=0
    info "Waiting for Pyroscope to become ready (timeout: ${max_seconds}s)..."
    while [ "${elapsed}" -lt "${max_seconds}" ]; do
        if docker exec "${CONTAINER_NAME}" wget -q --spider "http://localhost:4040/ready" 2>/dev/null; then
            ok "Pyroscope is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    err "Pyroscope did not become ready within ${max_seconds} seconds"
    err "Check logs:  $0 logs"
    return 1
}

print_summary() {
    local vm_ip
    vm_ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || vm_ip="<VM_IP>"

    echo ""
    ok  "Pyroscope is running"
    info "UI:             http://${vm_ip}:${HOST_PORT}"
    info "Push endpoint:  http://${vm_ip}:${HOST_PORT}/ingest"
    info "Ready check:    http://${vm_ip}:${HOST_PORT}/ready"
    echo ""
    info "Configure Java services with:"
    info "  pyroscope.server.address=http://${vm_ip}:${HOST_PORT}"
    echo ""
}

# ---- Commands ------------------------------------------------------------
cmd_start() {
    preflight

    local deploy_dir
    deploy_dir="$(resolve_deploy_dir)"

    info "Building image: ${IMAGE_NAME}"
    docker build -t "${IMAGE_NAME}" "${deploy_dir}"

    remove_container_if_exists
    ensure_volume

    info "Starting container: ${CONTAINER_NAME} (port ${HOST_PORT})"
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "${HOST_PORT}:4040" \
        -v "${VOLUME_NAME}:/data" \
        "${IMAGE_NAME}"

    wait_healthy
    print_summary
}

cmd_stop() {
    preflight
    remove_container_if_exists
    ok "Container stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_logs() {
    preflight
    if ! container_running; then
        err "Container ${CONTAINER_NAME} is not running"
        return 1
    fi
    docker logs -f "${CONTAINER_NAME}"
}

cmd_status() {
    preflight
    if container_running; then
        ok "Container is running"
        docker ps --filter "name=^${CONTAINER_NAME}$" \
            --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        if docker exec "${CONTAINER_NAME}" wget -q --spider "http://localhost:4040/ready" 2>/dev/null; then
            ok "Health check: ready"
        else
            warn "Health check: not ready"
        fi
    else
        info "Container ${CONTAINER_NAME} is not running"
    fi
}

cmd_clean() {
    preflight
    remove_container_if_exists
    info "Removing image: ${IMAGE_NAME}"
    docker rmi "${IMAGE_NAME}" 2>/dev/null || true
    info "Removing volume: ${VOLUME_NAME}"
    docker volume rm "${VOLUME_NAME}" 2>/dev/null || true
    ok "Cleaned up"
}

# ---- Argument parsing & main ---------------------------------------------
usage() {
    cat <<'USAGE'
Usage: bash vm-deploy.sh <command> [options]

Commands:
  start     Build image and start Pyroscope container
  stop      Stop and remove container
  restart   Stop then start
  logs      Tail container logs
  status    Show container status and health
  clean     Stop container, remove image and volume

Options (for start/restart):
  --from-local <path>   Use files from a local directory
  --from-git  [url]     Clone or pull from Git (default: REPO_URL)

Examples:
  # Deploy from GitHub
  bash vm-deploy.sh start --from-git

  # Deploy from scp'd files
  bash vm-deploy.sh start --from-local /tmp/pyroscope-deploy

  # Just start (files already in /opt/pyroscope)
  bash vm-deploy.sh start

Environment Variables:
  REPO_URL        Git repo URL (default: git@github.com:aff0gat000/pyroscope.git)
  REPO_BRANCH     Git branch   (default: main)
  INSTALL_DIR     Install path (default: /opt/pyroscope)
  PYROSCOPE_PORT  Host port    (default: 4040)
USAGE
    exit 0
}

main() {
    local command="${1:-}"
    if [ -z "${command}" ]; then
        usage
    fi
    shift

    # Parse options
    local source_type=""
    local source_arg=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --from-local)
                source_type="local"
                source_arg="${2:?--from-local requires a path argument}"
                shift 2
                ;;
            --from-git)
                source_type="git"
                if [ $# -ge 2 ] && [[ "${2:-}" != --* ]]; then
                    source_arg="$2"
                    shift 2
                else
                    source_arg=""
                    shift
                fi
                ;;
            -h|--help|help)
                usage
                ;;
            *)
                err "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Acquire source if requested (only for start/restart)
    if [ -n "${source_type}" ]; then
        case "${command}" in
            start|restart)
                case "${source_type}" in
                    local) acquire_from_local "${source_arg}" ;;
                    git)   acquire_from_git "${source_arg}"   ;;
                esac
                ;;
            *)
                warn "--from-* options are ignored for '${command}' command"
                ;;
        esac
    fi

    # Dispatch
    case "${command}" in
        start)        cmd_start   ;;
        stop)         cmd_stop    ;;
        restart)      cmd_restart ;;
        logs)         cmd_logs    ;;
        status)       cmd_status  ;;
        clean)        cmd_clean   ;;
        help|-h|--help) usage     ;;
        *)
            err "Unknown command: ${command}"
            exit 1
            ;;
    esac
}

main "$@"

#!/usr/bin/env bash
# =============================================================================
# Stage 2: Deploy on VM (runs on RHEL VM as root)
# =============================================================================
#
# Loads Docker images, configures Pyroscope + Nginx TLS proxy, and starts
# containers. Run this after stage1-build.sh has transferred files to the VM.
#
# Prerequisites:
#   - Docker installed and running
#   - /tmp/pyroscope-images.tar (from stage1-build.sh)
#   - /tmp/pyroscope-deploy/pyroscope.yaml
#   - /tmp/pyroscope-deploy/nginx.conf
#   - /tmp/pyroscope-deploy/tls/cert.pem and key.pem
#
# Usage:
#   sudo /tmp/pyroscope-deploy/stage2-deploy.sh [options]
#
# Options:
#   --images-tar <path>     Path to images tarball (default: /tmp/pyroscope-images.tar)
#   --deploy-dir <path>     Path to deploy directory (default: /tmp/pyroscope-deploy)
#   --install-dir <path>    Installation directory (default: /opt/pyroscope)
#   --skip-firewall         Skip firewalld configuration
#   --http-only             Deploy without Nginx TLS (HTTP mode on port 4040)
#   --status                Show running containers and health
#   --stop                  Stop all containers
#   --restart               Restart all containers
#   --help                  Show this help
# =============================================================================

set -euo pipefail

# --- Defaults ---
IMAGES_TAR="/tmp/pyroscope-images.tar"
DEPLOY_DIR="/tmp/pyroscope-deploy"
INSTALL_DIR="/opt/pyroscope"
SKIP_FIREWALL=false
HTTP_ONLY=false
ACTION="deploy"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --images-tar)    IMAGES_TAR="$2";   shift 2 ;;
        --deploy-dir)    DEPLOY_DIR="$2";   shift 2 ;;
        --install-dir)   INSTALL_DIR="$2";  shift 2 ;;
        --skip-firewall) SKIP_FIREWALL=true; shift ;;
        --http-only)     HTTP_ONLY=true;    shift ;;
        --status)        ACTION="status";   shift ;;
        --stop)          ACTION="stop";     shift ;;
        --restart)       ACTION="restart";  shift ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *)               die "Unknown option: $1" ;;
    esac
done

# =============================================================================
# Actions: status, stop, restart
# =============================================================================

if [[ "$ACTION" == "status" ]]; then
    echo ""
    echo "=== Container Status ==="
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter name=pyroscope --filter name=nginx-tls
    echo ""
    echo "=== Health Checks ==="
    if docker ps --format '{{.Names}}' | grep -q '^pyroscope$'; then
        PYRO_PORT=$( [[ "$HTTP_ONLY" == true ]] && echo "4040" || echo "4041" )
        printf "  Pyroscope (:%s): " "$PYRO_PORT"
        curl -sf "http://localhost:${PYRO_PORT}/ready" 2>/dev/null && echo " OK" || echo " FAILED"
    fi
    if docker ps --format '{{.Names}}' | grep -q '^nginx-tls$'; then
        printf "  Nginx TLS (:4040):  "
        curl -ksf "https://localhost:4040/ready" 2>/dev/null && echo " OK" || echo " FAILED"
    fi
    exit 0
fi

if [[ "$ACTION" == "stop" ]]; then
    info "Stopping containers..."
    docker stop nginx-tls pyroscope 2>/dev/null || true
    info "Containers stopped."
    exit 0
fi

if [[ "$ACTION" == "restart" ]]; then
    info "Restarting containers..."
    docker restart pyroscope 2>/dev/null || true
    [[ "$HTTP_ONLY" == false ]] && docker restart nginx-tls 2>/dev/null || true
    info "Containers restarted."
    exit 0
fi

# =============================================================================
# Pre-flight checks
# =============================================================================

info "=== Stage 2: Deploy on VM ==="
info ""

# Must be root
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo)"
fi

# Docker must be running
if ! docker info >/dev/null 2>&1; then
    die "Docker is not running. Start it with: systemctl start docker"
fi

# Images tarball must exist
if [[ ! -f "$IMAGES_TAR" ]]; then
    die "Images tarball not found: ${IMAGES_TAR}\n  Run stage1-build.sh on your Mac first."
fi

# Config files must exist
if [[ ! -f "${DEPLOY_DIR}/pyroscope.yaml" ]]; then
    die "Config not found: ${DEPLOY_DIR}/pyroscope.yaml\n  Run stage1-build.sh on your Mac first."
fi

# TLS cert check (unless HTTP-only mode)
if [[ "$HTTP_ONLY" == false ]]; then
    if [[ ! -f "${DEPLOY_DIR}/tls/cert.pem" || ! -f "${DEPLOY_DIR}/tls/key.pem" ]]; then
        die "TLS cert/key not found in ${DEPLOY_DIR}/tls/\n  Either:\n  - Copy cert.pem and key.pem to ${DEPLOY_DIR}/tls/\n  - Or use --http-only for HTTP mode"
    fi
fi

# =============================================================================
# Step 1: Load Docker images
# =============================================================================

info "Step 1/5: Loading Docker images..."
docker load -i "$IMAGES_TAR"
info "  Images loaded."

# Verify images
PYRO_ARCH=$(docker inspect grafana/pyroscope:1.18.0 --format='{{.Architecture}}' 2>/dev/null || echo "missing")
if [[ "$PYRO_ARCH" != "amd64" ]]; then
    die "Pyroscope image architecture is ${PYRO_ARCH}, expected amd64"
fi
info "  Architecture verified: amd64"

# =============================================================================
# Step 2: Stage configuration files
# =============================================================================

info "Step 2/5: Staging configuration..."

mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/tls"

if [[ "$HTTP_ONLY" == true ]]; then
    # HTTP mode — use port 4040 directly
    cat > "${INSTALL_DIR}/pyroscope.yaml" <<'EOF'
server:
  http_listen_port: 4040

storage:
  backend: filesystem
  filesystem:
    dir: /data

self_profiling:
  disable_push: true
EOF
else
    # HTTPS mode — Pyroscope on 4041, Nginx on 4040
    cp "${DEPLOY_DIR}/pyroscope.yaml" "${INSTALL_DIR}/pyroscope.yaml"
    cp "${DEPLOY_DIR}/nginx.conf"     "${INSTALL_DIR}/nginx.conf"
    cp "${DEPLOY_DIR}/tls/cert.pem"   "${INSTALL_DIR}/tls/cert.pem"
    cp "${DEPLOY_DIR}/tls/key.pem"    "${INSTALL_DIR}/tls/key.pem"
fi

chmod 644 "${INSTALL_DIR}/pyroscope.yaml"
[[ "$HTTP_ONLY" == false ]] && chmod 644 "${INSTALL_DIR}/nginx.conf"
[[ "$HTTP_ONLY" == false ]] && chmod 644 "${INSTALL_DIR}/tls/cert.pem"
[[ "$HTTP_ONLY" == false ]] && chmod 600 "${INSTALL_DIR}/tls/key.pem"

info "  Config staged to ${INSTALL_DIR}/"

# =============================================================================
# Step 3: Configure firewall
# =============================================================================

if [[ "$SKIP_FIREWALL" == false ]] && command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        info "Step 3/5: Configuring firewall..."
        firewall-cmd --permanent --add-port=4040/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "  Port 4040/tcp opened"
    else
        info "Step 3/5: Firewalld not active, skipping."
    fi
else
    info "Step 3/5: Firewall configuration skipped."
fi

# =============================================================================
# Step 4: Stop existing containers (if any)
# =============================================================================

info "Step 4/5: Starting containers..."

# Remove existing containers (idempotent)
docker rm -f pyroscope 2>/dev/null || true
docker rm -f nginx-tls 2>/dev/null || true

# Create data volume
docker volume create pyroscope-data >/dev/null 2>&1 || true

# =============================================================================
# Step 5: Start containers
# =============================================================================

if [[ "$HTTP_ONLY" == true ]]; then
    # --- HTTP mode: Pyroscope on :4040 ---

    docker run -d --name pyroscope --restart unless-stopped \
        --network host \
        --log-opt max-size=50m --log-opt max-file=3 \
        -v pyroscope-data:/data \
        -v "${INSTALL_DIR}/pyroscope.yaml:/etc/pyroscope/config.yaml:ro" \
        grafana/pyroscope:1.18.0 \
        -config.file=/etc/pyroscope/config.yaml

    info "  Pyroscope started (HTTP :4040)"

else
    # --- HTTPS mode: Pyroscope on :4041, Nginx on :4040 ---

    docker run -d --name pyroscope --restart unless-stopped \
        --network host \
        --log-opt max-size=50m --log-opt max-file=3 \
        -v pyroscope-data:/data \
        -v "${INSTALL_DIR}/pyroscope.yaml:/etc/pyroscope/config.yaml:ro" \
        grafana/pyroscope:1.18.0 \
        -config.file=/etc/pyroscope/config.yaml

    info "  Pyroscope started (HTTP :4041, internal)"

    docker run -d --name nginx-tls --restart unless-stopped \
        --network host \
        --log-opt max-size=50m --log-opt max-file=3 \
        -v "${INSTALL_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "${INSTALL_DIR}/tls:/etc/nginx/tls:ro" \
        nginx:1.27-alpine

    info "  Nginx TLS proxy started (HTTPS :4040)"
fi

# =============================================================================
# Health check
# =============================================================================

info ""
info "Waiting for Pyroscope to initialize..."
sleep 20

PYRO_PORT=$( [[ "$HTTP_ONLY" == true ]] && echo "4040" || echo "4041" )
if curl -sf "http://localhost:${PYRO_PORT}/ready" >/dev/null 2>&1; then
    info "  Pyroscope: ready"
else
    warn "  Pyroscope: not ready yet (may need more time)"
fi

if [[ "$HTTP_ONLY" == false ]]; then
    if curl -ksf "https://localhost:4040/ready" >/dev/null 2>&1; then
        info "  Nginx TLS: ready"
    else
        warn "  Nginx TLS: not ready (check: docker logs nginx-tls)"
    fi
fi

# =============================================================================
# Summary
# =============================================================================

VM_IP=$(hostname -I | awk '{print $1}')

info ""
info "=== Deployment Complete ==="
info ""
if [[ "$HTTP_ONLY" == true ]]; then
    info "Mode:      HTTP"
    info "Pyroscope: http://${VM_IP}:4040"
    info ""
    info "Agent config:"
    info "  pyroscope.server.address=http://${VM_IP}:4040"
else
    info "Mode:      HTTPS (Nginx TLS proxy)"
    info "Pyroscope: https://${VM_IP}:4040 (via Nginx)"
    info "Internal:  http://localhost:4041 (direct, no TLS)"
    info ""
    info "Agent config:"
    info "  pyroscope.server.address=https://domain-pyroscope.company.com"
    info "  # Or direct: https://${VM_IP}:4040"
fi
info ""
info "Day-2 operations:"
info "  Status:   $(realpath "$0") --status"
info "  Stop:     $(realpath "$0") --stop"
info "  Restart:  $(realpath "$0") --restart"
info "  Logs:     docker logs -f pyroscope"
info "  Nginx:    docker logs -f nginx-tls"

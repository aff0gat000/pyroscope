#!/usr/bin/env bash
# =============================================================================
# Stage 1: Build & Transfer (runs on local Mac workstation)
# =============================================================================
#
# Pulls Docker images for linux/amd64, saves as tarballs, and SCPs everything
# to the target RHEL VM. Run this from your Mac before running stage2-deploy.sh
# on the VM.
#
# Usage:
#   ./stage1-build.sh --vm-host <VM_IP_OR_HOSTNAME> [options]
#
# Examples:
#   # Basic — pull images, save, SCP to VM
#   ./stage1-build.sh --vm-host 10.1.2.3
#
#   # With SSH user and custom key
#   ./stage1-build.sh --vm-host 10.1.2.3 --vm-user deployer --ssh-key ~/.ssh/id_deploy
#
#   # With cert files (after CSR is signed)
#   ./stage1-build.sh --vm-host 10.1.2.3 --tls-cert /path/to/cert.pem --tls-key /path/to/key.pem
#
#   # Build only (no SCP) — useful for pre-staging
#   ./stage1-build.sh --build-only
#
# What gets transferred to the VM:
#   /tmp/pyroscope-images.tar        — Pyroscope + Nginx Docker images
#   /tmp/pyroscope-deploy/           — Config files (pyroscope.yaml, nginx.conf, stage2-deploy.sh)
#   /tmp/pyroscope-deploy/tls/       — TLS cert + key (if provided)
# =============================================================================

set -euo pipefail

# --- Defaults ---
PYROSCOPE_VERSION="${PYROSCOPE_VERSION:-1.18.0}"
NGINX_VERSION="${NGINX_VERSION:-1.27-alpine}"
PLATFORM="linux/amd64"
VM_HOST=""
VM_USER="${USER}"
SSH_KEY=""
SSH_OPTS=""
TLS_CERT=""
TLS_KEY=""
BUILD_ONLY=false
STAGING_DIR="${TMPDIR:-/tmp}/pyroscope-stage"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-host)      VM_HOST="$2";       shift 2 ;;
        --vm-user)      VM_USER="$2";       shift 2 ;;
        --ssh-key)      SSH_KEY="$2";       shift 2 ;;
        --ssh-opts)     SSH_OPTS="$2";      shift 2 ;;
        --tls-cert)     TLS_CERT="$2";      shift 2 ;;
        --tls-key)      TLS_KEY="$2";       shift 2 ;;
        --pyroscope-version) PYROSCOPE_VERSION="$2"; shift 2 ;;
        --build-only)   BUILD_ONLY=true;    shift ;;
        --help|-h)      usage ;;
        *)              die "Unknown option: $1" ;;
    esac
done

if [[ "$BUILD_ONLY" == false && -z "$VM_HOST" ]]; then
    die "Required: --vm-host <IP_OR_HOSTNAME> (or use --build-only)"
fi

# Build SSH command with options
SSH_CMD="ssh"
SCP_CMD="scp"
if [[ -n "$SSH_KEY" ]]; then
    SSH_CMD="$SSH_CMD -i $SSH_KEY"
    SCP_CMD="$SCP_CMD -i $SSH_KEY"
fi
if [[ -n "$SSH_OPTS" ]]; then
    SSH_CMD="$SSH_CMD $SSH_OPTS"
    SCP_CMD="$SCP_CMD $SSH_OPTS"
fi

# =============================================================================
# Step 1: Pull Docker images for linux/amd64
# =============================================================================

info "=== Stage 1: Build & Transfer ==="
info ""
info "Pyroscope version: ${PYROSCOPE_VERSION}"
info "Nginx version:     ${NGINX_VERSION}"
info "Platform:          ${PLATFORM}"
[[ "$BUILD_ONLY" == false ]] && info "Target VM:         ${VM_USER}@${VM_HOST}"
info ""

info "Step 1/4: Pulling Docker images for ${PLATFORM}..."

docker pull --platform "$PLATFORM" "grafana/pyroscope:${PYROSCOPE_VERSION}"
docker pull --platform "$PLATFORM" "nginx:${NGINX_VERSION}"

# Verify architecture
PYRO_ARCH=$(docker inspect "grafana/pyroscope:${PYROSCOPE_VERSION}" --format='{{.Architecture}}')
NGINX_ARCH=$(docker inspect "nginx:${NGINX_VERSION}" --format='{{.Architecture}}')
info "  Pyroscope architecture: ${PYRO_ARCH}"
info "  Nginx architecture:     ${NGINX_ARCH}"

if [[ "$PYRO_ARCH" != "amd64" || "$NGINX_ARCH" != "amd64" ]]; then
    die "Architecture mismatch. Expected amd64, got pyroscope=${PYRO_ARCH}, nginx=${NGINX_ARCH}"
fi

# =============================================================================
# Step 2: Save images as tarball
# =============================================================================

info "Step 2/4: Saving images to tarball..."

mkdir -p "$STAGING_DIR"
docker save -o "${STAGING_DIR}/pyroscope-images.tar" \
    "grafana/pyroscope:${PYROSCOPE_VERSION}" \
    "nginx:${NGINX_VERSION}"

TAR_SIZE=$(du -h "${STAGING_DIR}/pyroscope-images.tar" | cut -f1)
info "  Saved: ${STAGING_DIR}/pyroscope-images.tar (${TAR_SIZE})"

# =============================================================================
# Step 3: Stage config files
# =============================================================================

info "Step 3/4: Staging configuration files..."

mkdir -p "${STAGING_DIR}/config"

# Pyroscope config (port 4041 — Nginx takes 4040)
cat > "${STAGING_DIR}/config/pyroscope.yaml" <<'PYRO_EOF'
server:
  http_listen_port: 4041

storage:
  backend: filesystem
  filesystem:
    dir: /data

self_profiling:
  disable_push: true
PYRO_EOF

# Nginx config (TLS on :4040, proxy to :4041)
cat > "${STAGING_DIR}/config/nginx.conf" <<'NGINX_EOF'
events { worker_connections 1024; }

http {
    server {
        listen 4040 ssl;
        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass http://127.0.0.1:4041;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 60s;
        }
    }
}
NGINX_EOF

# Copy stage2 deploy script
cp "${SCRIPT_DIR}/stage2-deploy.sh" "${STAGING_DIR}/config/stage2-deploy.sh"
chmod +x "${STAGING_DIR}/config/stage2-deploy.sh"

# Copy TLS cert/key if provided
if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then
    mkdir -p "${STAGING_DIR}/config/tls"
    cp "$TLS_CERT" "${STAGING_DIR}/config/tls/cert.pem"
    cp "$TLS_KEY"  "${STAGING_DIR}/config/tls/key.pem"
    info "  TLS cert and key staged"
elif [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
    die "Both --tls-cert and --tls-key must be provided together"
fi

info "  Staged files:"
find "${STAGING_DIR}" -type f | sort | while read -r f; do
    echo "    $(basename "$f")"
done

# =============================================================================
# Step 4: SCP to VM
# =============================================================================

if [[ "$BUILD_ONLY" == true ]]; then
    info ""
    info "Build-only mode. Files staged at: ${STAGING_DIR}/"
    info "To transfer manually:"
    info "  scp ${STAGING_DIR}/pyroscope-images.tar ${VM_USER}@<VM>:/tmp/"
    info "  scp -r ${STAGING_DIR}/config/* ${VM_USER}@<VM>:/tmp/pyroscope-deploy/"
    exit 0
fi

info "Step 4/4: Transferring to ${VM_USER}@${VM_HOST}..."

# Create target directory on VM
$SSH_CMD "${VM_USER}@${VM_HOST}" "mkdir -p /tmp/pyroscope-deploy/tls"

# Transfer images tarball
info "  Transferring images tarball (${TAR_SIZE})..."
$SCP_CMD "${STAGING_DIR}/pyroscope-images.tar" "${VM_USER}@${VM_HOST}:/tmp/pyroscope-images.tar"

# Transfer config files
info "  Transferring config files..."
$SCP_CMD "${STAGING_DIR}/config/pyroscope.yaml" "${VM_USER}@${VM_HOST}:/tmp/pyroscope-deploy/"
$SCP_CMD "${STAGING_DIR}/config/nginx.conf"     "${VM_USER}@${VM_HOST}:/tmp/pyroscope-deploy/"
$SCP_CMD "${STAGING_DIR}/config/stage2-deploy.sh" "${VM_USER}@${VM_HOST}:/tmp/pyroscope-deploy/"

# Transfer TLS files if present
if [[ -d "${STAGING_DIR}/config/tls" ]]; then
    info "  Transferring TLS cert and key..."
    $SCP_CMD "${STAGING_DIR}/config/tls/cert.pem" "${VM_USER}@${VM_HOST}:/tmp/pyroscope-deploy/tls/"
    $SCP_CMD "${STAGING_DIR}/config/tls/key.pem"  "${VM_USER}@${VM_HOST}:/tmp/pyroscope-deploy/tls/"
fi

# =============================================================================
# Summary
# =============================================================================

info ""
info "=== Transfer complete ==="
info ""
info "Files on ${VM_HOST}:"
info "  /tmp/pyroscope-images.tar          — Docker images"
info "  /tmp/pyroscope-deploy/pyroscope.yaml"
info "  /tmp/pyroscope-deploy/nginx.conf"
info "  /tmp/pyroscope-deploy/stage2-deploy.sh"
if [[ -d "${STAGING_DIR}/config/tls" ]]; then
    info "  /tmp/pyroscope-deploy/tls/cert.pem"
    info "  /tmp/pyroscope-deploy/tls/key.pem"
fi
info ""
info "Next steps:"
info "  1. SSH to the VM:  ssh ${VM_USER}@${VM_HOST}"
if [[ ! -d "${STAGING_DIR}/config/tls" ]]; then
    info "  2. Generate CSR and get cert signed (see below)"
    info "  3. Copy cert.pem and key.pem to /tmp/pyroscope-deploy/tls/"
    info "  4. Run:  sudo /tmp/pyroscope-deploy/stage2-deploy.sh"
else
    info "  2. Run:  sudo /tmp/pyroscope-deploy/stage2-deploy.sh"
fi
info ""

if [[ ! -d "${STAGING_DIR}/config/tls" ]]; then
    info "=== CSR Generation (run on VM) ==="
    info ""
    info "  # Generate private key and CSR"
    info '  openssl req -new -newkey rsa:2048 -nodes \'
    info '      -keyout /tmp/pyroscope-deploy/tls/key.pem \'
    info '      -out /tmp/pyroscope-deploy/tls/pyroscope.csr \'
    info '      -subj "/CN=domain-pyroscope.company.com" \'
    info '      -addext "subjectAltName=DNS:domain-pyroscope.company.com,IP:$(hostname -I | awk '"'"'{print $1}'"'"')"'
    info ""
    info "  # Upload pyroscope.csr to your internal cert platform"
    info "  # Download signed cert.pem and copy to /tmp/pyroscope-deploy/tls/cert.pem"
    info ""
fi

# Cleanup local staging
rm -rf "$STAGING_DIR"
info "Local staging directory cleaned up."

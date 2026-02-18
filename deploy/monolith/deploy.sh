#!/usr/bin/env bash
set -uo pipefail
# NOTE: -e is NOT set globally. We use explicit error handling with die() and
# step_run() so failures produce actionable diagnostics instead of silent exits.

# ---------------------------------------------------------------------------
# deploy.sh — Deploy Pyroscope (monolith mode) with optional Grafana
#
# Designed for enterprise VMs (RHEL, CentOS, Ubuntu) accessed via:
#   ssh operator@vm01.corp && pbrun /bin/su -
#
# Deployment modes:
#   full-stack        Deploy Pyroscope + Grafana together (default)
#   add-to-existing   Add Pyroscope datasource and dashboards to existing Grafana
#   save-images       Save Docker images to tar for air-gapped transfer
#   status / stop / clean / logs   Day-2 operations
#
# Target environments:
#   --target vm         Docker on VM/EC2/bare metal (default)
#   --target local      Docker Compose on local machine
#   --target k8s        Kubernetes (kubectl/helm)
#   --target openshift  OpenShift (oc CLI)
#
# TLS/HTTPS support:
#   --tls --tls-self-signed       Auto-generate self-signed cert (dev/demo)
#   --tls --tls-cert/--tls-key    Enterprise CA certs (production)
#   Uses Envoy as TLS-terminating reverse proxy.
#
# Idempotent — safe to re-run after partial failures. Each step checks
# current state before acting (container exists? volume exists? port open?).
#
# Examples:
#   # Deploy full stack on a VM (HTTP)
#   bash deploy.sh full-stack --target vm
#
#   # Deploy with self-signed TLS (HTTPS)
#   bash deploy.sh full-stack --target vm --tls --tls-self-signed
#
#   # Deploy Pyroscope only (no Grafana)
#   bash deploy.sh full-stack --target vm --skip-grafana
#
#   # Save images for air-gapped VM (no Docker registry)
#   bash deploy.sh save-images
#   scp pyroscope-stack-images.tar operator@vm01:/tmp/
#   bash deploy.sh full-stack --target vm --load-images /tmp/pyroscope-stack-images.tar
#
#   # Dry run — validate everything without making changes
#   bash deploy.sh full-stack --target vm --dry-run
#
#   # Log to file (recommended for pbrun sessions)
#   bash deploy.sh full-stack --target vm --log-file /tmp/deploy.log
# ---------------------------------------------------------------------------

# ---- Defaults & Configuration ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MODE=""
TARGET="vm"
METHOD="api"
DRY_RUN=false
LOG_FILE=""
CURRENT_STEP=""
MOUNT_CONFIG=true
GRAFANA_CONFIG_DIR="${GRAFANA_CONFIG_DIR:-/opt/pyroscope/grafana}"
SKIP_GRAFANA=false

# Image transfer (air-gapped / no registry)
LOAD_IMAGES_PATH=""

# TLS / HTTPS (Envoy reverse proxy)
TLS_ENABLED=false
TLS_CERT=""
TLS_KEY=""
TLS_SELF_SIGNED=false
TLS_CERT_DIR="${TLS_CERT_DIR:-/opt/pyroscope/tls}"
TLS_PORT_PYROSCOPE="${TLS_PORT_PYROSCOPE:-4443}"
TLS_PORT_GRAFANA="${TLS_PORT_GRAFANA:-443}"
TLS_CLIENT_CA=""
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.31-latest}"
ENVOY_CONTAINER_NAME="envoy-proxy"

# Pyroscope settings
PYROSCOPE_URL="${PYROSCOPE_URL:-}"
PYROSCOPE_PORT="${PYROSCOPE_PORT:-4040}"
PYROSCOPE_IMAGE="${PYROSCOPE_IMAGE:-grafana/pyroscope:latest}"
PYROSCOPE_CONFIG="${PYROSCOPE_CONFIG:-}"
PYROSCOPE_VOLUME="${PYROSCOPE_VOLUME:-pyroscope-data}"

# Grafana settings
GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_API_KEY="${GRAFANA_API_KEY:-}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:11.5.2}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
GRAFANA_PROVISIONING_DIR="${GRAFANA_PROVISIONING_DIR:-/etc/grafana/provisioning}"
GRAFANA_DASHBOARD_DIR="${GRAFANA_DASHBOARD_DIR:-/var/lib/grafana/dashboards}"
GRAFANA_VOLUME="${GRAFANA_VOLUME:-grafana-data}"

# Kubernetes / OpenShift
NAMESPACE="${NAMESPACE:-monitoring}"
GRAFANA_ROUTE="${GRAFANA_ROUTE:-}"
PERSISTENT_STORAGE=true
STORAGE_CLASS=""
PVC_SIZE_PYROSCOPE="${PVC_SIZE_PYROSCOPE:-10Gi}"
PVC_SIZE_GRAFANA="${PVC_SIZE_GRAFANA:-2Gi}"

# Repo paths
CONFIG_DIR="${REPO_ROOT}/config/grafana"
DASHBOARDS_SRC="${CONFIG_DIR}/dashboards"
PROVISIONING_SRC="${CONFIG_DIR}/provisioning"

# ---- PATH hardening for pbrun/su environments ----------------------------
# pbrun /bin/su - resets PATH. Ensure common binary locations are included.
for p in /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin; do
    case ":${PATH}:" in
        *:"${p}":*) ;;
        *) PATH="${p}:${PATH}" ;;
    esac
done
export PATH

# ---- Logging ---------------------------------------------------------------
_log() {
    local prefix="$1"; shift
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') ${prefix} $*"
    printf '%s\n' "${msg}"
    if [ -n "${LOG_FILE}" ]; then
        printf '%s\n' "${msg}" >> "${LOG_FILE}"
    fi
}

info()  { _log "[INFO] " "$*"; }
ok()    { _log "[OK]   " "$*"; }
warn()  { _log "[WARN] " "$*"; }
err()   { _log "[ERROR]" "$*" >&2; }
step()  { CURRENT_STEP="$*"; _log "[STEP] " "$*"; }

die() {
    err "$*"
    if [ -n "${CURRENT_STEP}" ]; then
        err "Failed during: ${CURRENT_STEP}"
    fi
    err "Re-run the same command to retry — the script is idempotent."
    if [ -n "${LOG_FILE}" ]; then
        err "Full log: ${LOG_FILE}"
    fi
    exit 1
}

# Run a command with error context. Usage: step_run "description" command args...
step_run() {
    local desc="$1"; shift
    info "  ${desc}"
    if [ "${DRY_RUN}" = true ]; then
        info "  [DRY RUN] would execute: $*"
        return 0
    fi
    if ! "$@" 2>&1; then
        die "${desc} failed. Command: $*"
    fi
}

# ---- RHEL / SELinux helpers ------------------------------------------------
selinux_volume_flag() {
    # On SELinux-enforcing systems, Docker bind mounts need :z to relabel
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        echo ":z"
    else
        echo ""
    fi
}

open_firewall_port() {
    local port="$1"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        if ! firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
            info "Opening firewall port ${port}/tcp..."
            firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        else
            info "Firewall port ${port}/tcp already open"
        fi
    fi
}

# ---- Pre-flight checks ----------------------------------------------------
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "Docker is not installed. Install with: curl -fsSL https://get.docker.com | sh"
    fi
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running. Start with: systemctl start docker"
    fi
    ok "Docker is available ($(docker --version | head -1))"
}

check_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        die "Docker Compose is not installed. Install with: yum install docker-compose-plugin"
    fi
    ok "Docker Compose is available (${COMPOSE_CMD})"
}

check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        die "kubectl is not installed."
    fi
    if ! kubectl cluster-info >/dev/null 2>&1; then
        die "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    fi
    ok "kubectl connected to cluster"
}

check_oc() {
    if ! command -v oc >/dev/null 2>&1; then
        die "oc CLI is not installed."
    fi
    if ! oc whoami >/dev/null 2>&1; then
        die "Not logged into OpenShift. Run: oc login"
    fi
    ok "oc connected as $(oc whoami)"
}

check_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        die "curl is not installed. Install with: yum install curl"
    fi
}

check_config_files() {
    if [ ! -d "${DASHBOARDS_SRC}" ]; then
        die "Dashboards not found at: ${DASHBOARDS_SRC}. Ensure the repo is cloned completely."
    fi
    if [ ! -d "${PROVISIONING_SRC}" ]; then
        die "Provisioning config not found at: ${PROVISIONING_SRC}"
    fi
    local dashboard_count
    dashboard_count=$(find "${DASHBOARDS_SRC}" -name '*.json' 2>/dev/null | wc -l)
    ok "Found ${dashboard_count} dashboard(s) in ${DASHBOARDS_SRC}"
}

preflight() {
    step "Running pre-flight checks..."
    info "  Script directory: ${SCRIPT_DIR}"
    info "  Repo root: ${REPO_ROOT}"
    info "  Mode: ${MODE}, Target: ${TARGET}, Method: ${METHOD}"
    info "  Running as: $(whoami) (uid=$(id -u))"
    if [ "$(id -u)" -ne 0 ] && [ "${MODE}" = "full-stack" ] && [ "${TARGET}" = "vm" ]; then
        warn "Not running as root — Docker commands may fail without sudo/pbrun"
    fi

    case "${TARGET}" in
        vm|local)  check_docker ;;
        k8s)       check_kubectl ;;
        openshift) check_oc ;;
    esac
    check_config_files
    ok "Pre-flight checks passed"
}

# ---- Parameter validation --------------------------------------------------
validate_add_to_existing() {
    case "${METHOD}" in
        api)
            if [ -z "${GRAFANA_URL}" ]; then
                die "add-to-existing (API method) requires --grafana-url. Example: --grafana-url http://grafana.corp:3000"
            fi
            if [ -z "${GRAFANA_API_KEY}" ] && [ "${GRAFANA_ADMIN_PASSWORD}" = "admin" ]; then
                warn "No --grafana-api-key provided and admin password is default. Will use admin/admin."
            fi
            if [ -z "${PYROSCOPE_URL}" ]; then
                warn "No --pyroscope-url provided. Defaulting to http://pyroscope:${PYROSCOPE_PORT}"
            fi
            ;;
        provisioning)
            if [ -z "${PYROSCOPE_URL}" ]; then
                warn "No --pyroscope-url provided. Defaulting to http://pyroscope:${PYROSCOPE_PORT}"
            fi
            info "Provisioning directory: ${GRAFANA_PROVISIONING_DIR}"
            info "Dashboard directory: ${GRAFANA_DASHBOARD_DIR}"
            ;;
    esac
}

validate_full_stack() {
    case "${TARGET}" in
        vm)
            # Check grafana.ini exists (needed for Grafana image build)
            if [ ! -f "${REPO_ROOT}/deploy/grafana/grafana.ini" ]; then
                die "grafana.ini not found at ${REPO_ROOT}/deploy/grafana/grafana.ini"
            fi
            ;;
    esac
}

# ===========================================================================
#  MODE: add-to-existing
# ===========================================================================

# ---- Grafana API helpers ---------------------------------------------------
grafana_api() {
    local method="$1" path="$2"
    shift 2
    local url="${GRAFANA_URL}${path}"
    local auth_header=""

    if [ -n "${GRAFANA_API_KEY}" ]; then
        auth_header="Authorization: Bearer ${GRAFANA_API_KEY}"
    else
        auth_header="Authorization: Basic $(printf 'admin:%s' "${GRAFANA_ADMIN_PASSWORD}" | base64)"
    fi

    local http_code body
    body=$(curl -s -w '\n%{http_code}' -X "${method}" \
        -H "Content-Type: application/json" \
        -H "${auth_header}" \
        "$@" "${url}")
    http_code=$(printf '%s' "${body}" | tail -1)
    body=$(printf '%s' "${body}" | sed '$d')

    if [ "${http_code}" -ge 200 ] 2>/dev/null && [ "${http_code}" -lt 300 ] 2>/dev/null; then
        printf '%s' "${body}"
        return 0
    elif [ "${http_code}" = "409" ]; then
        # Conflict — resource already exists (idempotent)
        printf '%s' "${body}"
        return 0
    else
        err "Grafana API ${method} ${path} returned HTTP ${http_code}"
        err "Response: ${body}"
        return 1
    fi
}

grafana_api_check() {
    info "Checking Grafana connectivity at ${GRAFANA_URL}..."
    if ! curl -sf "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
        die "Cannot reach Grafana at ${GRAFANA_URL}. Check the URL and network connectivity."
    fi
    ok "Grafana is reachable (${GRAFANA_URL})"
}

# ---- API-based integration -------------------------------------------------
api_install_plugin() {
    step "Installing Pyroscope plugins via API..."

    # Check if plugin is already installed
    if grafana_api GET "/api/plugins/grafana-pyroscope-datasource" >/dev/null 2>&1; then
        ok "Pyroscope datasource plugin already installed (skipping)"
        return 0
    fi

    # Install plugin via admin API
    if grafana_api POST "/api/plugins/grafana-pyroscope-datasource/install" \
        -d '{}' >/dev/null 2>&1; then
        ok "Pyroscope datasource plugin installed"
    else
        warn "Could not install plugin via API — may need manual install or Grafana restart"
        warn "Add to grafana.ini or env: GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource"
    fi

    if grafana_api POST "/api/plugins/grafana-pyroscope-app/install" \
        -d '{}' >/dev/null 2>&1; then
        ok "Pyroscope app plugin installed"
    fi
}

api_add_datasource() {
    local pyroscope_url="$1"
    step "Adding Pyroscope datasource (${pyroscope_url})..."

    local ds_payload
    ds_payload=$(cat <<EOF
{
    "name": "Pyroscope",
    "type": "grafana-pyroscope-datasource",
    "uid": "pyroscope-ds",
    "access": "proxy",
    "url": "${pyroscope_url}",
    "isDefault": false,
    "editable": true
}
EOF
)

    # Check if datasource already exists
    local existing
    existing=$(grafana_api GET "/api/datasources/name/Pyroscope" 2>/dev/null) || true

    if [ -n "${existing}" ]; then
        ok "Pyroscope datasource already exists — updating URL"
        local ds_id
        ds_id=$(printf '%s' "${existing}" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        if grafana_api PUT "/api/datasources/${ds_id}" -d "${ds_payload}" >/dev/null; then
            ok "Datasource updated"
        else
            die "Failed to update existing datasource (id=${ds_id})"
        fi
        return 0
    fi

    if grafana_api POST "/api/datasources" -d "${ds_payload}" >/dev/null; then
        ok "Pyroscope datasource added"
    else
        die "Failed to create datasource. Check Grafana logs: docker logs grafana"
    fi
}

api_import_dashboards() {
    step "Importing dashboards via API..."

    local count=0 failed=0
    local folder_id

    # Create or get folder
    folder_id=$(grafana_api POST "/api/folders" \
        -d '{"title":"Pyroscope","uid":"pyroscope-folder"}' 2>/dev/null \
        | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2) || true

    if [ -z "${folder_id}" ]; then
        folder_id=$(grafana_api GET "/api/folders/pyroscope-folder" 2>/dev/null \
            | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2) || true
    fi

    for dashboard_file in "${DASHBOARDS_SRC}"/*.json; do
        [ -f "${dashboard_file}" ] || continue
        local name
        name="$(basename "${dashboard_file}" .json)"

        local dashboard_json
        dashboard_json=$(cat "${dashboard_file}")

        if grafana_api POST "/api/dashboards/db" \
            -d "{\"dashboard\": ${dashboard_json}, \"folderId\": ${folder_id:-0}, \"overwrite\": true, \"message\": \"Imported by deploy.sh\"}" \
            >/dev/null 2>&1; then
            count=$((count + 1))
            info "  Imported: ${name}"
        else
            failed=$((failed + 1))
            warn "  Failed to import: ${name}"
        fi
    done

    ok "Imported ${count} dashboard(s)"
    if [ "${failed}" -gt 0 ]; then
        warn "${failed} dashboard(s) failed to import — check Grafana logs"
    fi
}

do_add_to_existing_api() {
    check_curl
    grafana_api_check

    local pyroscope_url="${PYROSCOPE_URL:-http://pyroscope:${PYROSCOPE_PORT}}"

    api_install_plugin
    api_add_datasource "${pyroscope_url}"
    api_import_dashboards

    echo ""
    ok "Pyroscope integration complete (API method)"
    info "Datasource: ${pyroscope_url}"
    info "Dashboards: Pyroscope folder in Grafana"
    echo ""
}

# ---- Provisioning-file-based integration -----------------------------------
do_add_to_existing_provisioning() {
    local prov_dir="${GRAFANA_PROVISIONING_DIR}"
    local dash_dir="${GRAFANA_DASHBOARD_DIR}"

    step "Generating provisioning files..."

    local pyroscope_url="${PYROSCOPE_URL:-http://pyroscope:${PYROSCOPE_PORT}}"

    # Datasource provisioning
    info "Writing datasource config to ${prov_dir}/datasources/pyroscope.yaml"
    mkdir -p "${prov_dir}/datasources" || die "Cannot create ${prov_dir}/datasources — check permissions"
    cat > "${prov_dir}/datasources/pyroscope.yaml" <<EOF
apiVersion: 1

datasources:
  - name: Pyroscope
    type: grafana-pyroscope-datasource
    uid: pyroscope-ds
    access: proxy
    url: ${pyroscope_url}
    editable: true
EOF

    # Plugin provisioning
    info "Writing plugin config to ${prov_dir}/plugins/pyroscope.yaml"
    mkdir -p "${prov_dir}/plugins" || die "Cannot create ${prov_dir}/plugins — check permissions"
    cat > "${prov_dir}/plugins/pyroscope.yaml" <<EOF
apiVersion: 1

apps:
  - type: grafana-pyroscope-app
    org_id: 1
    disabled: false
  - type: grafana-pyroscope-datasource
    org_id: 1
    disabled: false
EOF

    # Dashboard provisioning
    info "Writing dashboard provider config to ${prov_dir}/dashboards/pyroscope.yaml"
    mkdir -p "${prov_dir}/dashboards" || die "Cannot create ${prov_dir}/dashboards — check permissions"
    cat > "${prov_dir}/dashboards/pyroscope.yaml" <<EOF
apiVersion: 1

providers:
  - name: "pyroscope"
    orgId: 1
    folder: "Pyroscope"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: ${dash_dir}/pyroscope
      foldersFromFilesStructure: false
EOF

    # Copy dashboards
    info "Copying dashboards to ${dash_dir}/pyroscope/"
    mkdir -p "${dash_dir}/pyroscope" || die "Cannot create ${dash_dir}/pyroscope — check permissions"
    cp -f "${DASHBOARDS_SRC}"/*.json "${dash_dir}/pyroscope/" || die "Failed to copy dashboards"
    local copied
    copied=$(find "${dash_dir}/pyroscope" -name '*.json' | wc -l)
    ok "Copied ${copied} dashboard(s)"

    echo ""
    ok "Provisioning files written"
    warn "Grafana must be restarted to pick up changes:"
    info "  systemctl restart grafana-server"
    info "  OR: docker restart grafana"
    echo ""
    info "Also ensure Pyroscope plugins are installed. Add to grafana.ini or env:"
    info "  GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource"
    echo ""
}

# ===========================================================================
#  MODE: full-stack
# ===========================================================================

# ---- Docker helpers (with retry) ------------------------------------------
docker_pull_with_retry() {
    local image="$1"
    local max_attempts=3
    local attempt=1

    while [ "${attempt}" -le "${max_attempts}" ]; do
        info "  Pulling ${image} (attempt ${attempt}/${max_attempts})..."
        if docker pull "${image}" 2>&1; then
            ok "  Pulled ${image}"
            return 0
        fi
        warn "  Pull failed (attempt ${attempt}/${max_attempts})"
        attempt=$((attempt + 1))
        sleep 5
    done
    die "Failed to pull ${image} after ${max_attempts} attempts. Check network/proxy/registry access."
}

# ---- Image transfer (save/load for air-gapped VMs) -------------------------
cmd_save_images() {
    local images=("${PYROSCOPE_IMAGE}")
    if [ "${SKIP_GRAFANA}" != true ]; then
        images+=("${GRAFANA_IMAGE}")
    fi
    if [ "${TLS_ENABLED}" = true ]; then
        images+=("${ENVOY_IMAGE}")
    fi

    local save_path="${1:-pyroscope-stack-images.tar}"
    step "Saving Docker images to ${save_path}..."

    for img in "${images[@]}"; do
        info "  Pulling ${img}..."
        docker pull "${img}" || die "Failed to pull ${img}. Check network access."
    done

    info "  Saving ${#images[@]} image(s) to tar..."
    docker save -o "${save_path}" "${images[@]}" \
        || die "docker save failed"

    local size
    size=$(du -h "${save_path}" | cut -f1)
    ok "Saved ${#images[@]} image(s) to ${save_path} (${size})"
    echo ""
    info "Transfer to target VM:"
    info "  scp ${save_path} operator@<vm>:/tmp/"
    info ""
    info "Then deploy with:"
    info "  bash deploy.sh full-stack --target vm --load-images /tmp/$(basename "${save_path}")"
    echo ""
}

load_images() {
    local tar_path="$1"
    if [ ! -f "${tar_path}" ]; then
        die "Image tar not found: ${tar_path}"
    fi
    step "Loading Docker images from ${tar_path}..."
    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would run: docker load -i ${tar_path}"
    else
        docker load -i "${tar_path}" || die "docker load failed for ${tar_path}"
        ok "Images loaded from ${tar_path}"
    fi
}

# ---- TLS / HTTPS (Envoy reverse proxy) ------------------------------------
validate_tls() {
    if [ "${TLS_ENABLED}" != true ]; then
        return 0
    fi

    # Both cert and key required (check partial before checking missing)
    if [ -n "${TLS_CERT}" ] && [ -z "${TLS_KEY}" ]; then
        die "Both --tls-cert and --tls-key are required."
    fi
    if [ -z "${TLS_CERT}" ] && [ -n "${TLS_KEY}" ]; then
        die "Both --tls-cert and --tls-key are required."
    fi

    # Must specify cert source
    if [ "${TLS_SELF_SIGNED}" != true ] && [ -z "${TLS_CERT}" ] && [ -z "${TLS_KEY}" ]; then
        die "TLS enabled but no certificate source specified.
  Use --tls-self-signed for auto-generated certs (dev/demo), or
  Use --tls-cert <path> --tls-key <path> for enterprise CA certs."
    fi

    # Cert files must exist
    if [ -n "${TLS_CERT}" ] && [ ! -f "${TLS_CERT}" ]; then
        die "TLS certificate file not found: ${TLS_CERT}"
    fi
    if [ -n "${TLS_KEY}" ] && [ ! -f "${TLS_KEY}" ]; then
        die "TLS key file not found: ${TLS_KEY}"
    fi

    # Self-signed needs openssl
    if [ "${TLS_SELF_SIGNED}" = true ]; then
        if ! command -v openssl >/dev/null 2>&1; then
            die "openssl is required for --tls-self-signed but not found on PATH."
        fi
    fi

    # mTLS placeholder
    if [ -n "${TLS_CLIENT_CA}" ]; then
        warn "mTLS (--tls-client-ca) is not yet implemented — flag reserved for future use."
        warn "The provided CA file will be ignored for now."
    fi
}

generate_self_signed_cert() {
    local cert_path="${TLS_CERT_DIR}/cert.pem"
    local key_path="${TLS_CERT_DIR}/key.pem"

    # Skip if cert exists and is valid for >7 days
    if [ -f "${cert_path}" ]; then
        local remaining
        remaining=$(openssl x509 -in "${cert_path}" -checkend 604800 2>/dev/null && echo "valid" || echo "expired")
        if [ "${remaining}" = "valid" ]; then
            info "Existing self-signed certificate is still valid (>7 days). Reusing."
            return 0
        fi
        info "Existing certificate expires within 7 days. Regenerating."
    fi

    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would generate self-signed cert at ${TLS_CERT_DIR}/"
        return 0
    fi

    mkdir -p "${TLS_CERT_DIR}" || die "Cannot create ${TLS_CERT_DIR}"

    local cn
    cn="$(hostname 2>/dev/null || echo 'localhost')"
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || ip="127.0.0.1"

    info "Generating self-signed certificate..."
    info "  CN=${cn}, SAN=DNS:${cn},IP:${ip}"
    openssl req -x509 \
        -newkey rsa:2048 \
        -nodes \
        -days 365 \
        -subj "/CN=${cn}" \
        -addext "subjectAltName=DNS:${cn},DNS:localhost,IP:${ip},IP:127.0.0.1" \
        -keyout "${key_path}" \
        -out "${cert_path}" \
        >/dev/null 2>&1 \
        || die "Failed to generate self-signed certificate"

    chmod 600 "${key_path}"
    chmod 644 "${cert_path}"

    ok "Self-signed certificate generated at ${TLS_CERT_DIR}/"
    warn "==========================================================="
    warn " SELF-SIGNED CERTIFICATE — NOT FOR PRODUCTION"
    warn " Java agents will need: -Djavax.net.ssl.trustStore=..."
    warn " For production, use --tls-cert/--tls-key with"
    warn " enterprise CA certificates."
    warn "==========================================================="
}

copy_provided_certs() {
    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would copy certs to ${TLS_CERT_DIR}/"
        return 0
    fi

    mkdir -p "${TLS_CERT_DIR}" || die "Cannot create ${TLS_CERT_DIR}"
    cp -f "${TLS_CERT}" "${TLS_CERT_DIR}/cert.pem" || die "Failed to copy TLS cert"
    cp -f "${TLS_KEY}" "${TLS_CERT_DIR}/key.pem" || die "Failed to copy TLS key"
    chmod 600 "${TLS_CERT_DIR}/key.pem"
    chmod 644 "${TLS_CERT_DIR}/cert.pem"
    ok "TLS certificates copied to ${TLS_CERT_DIR}/"
}

generate_envoy_config() {
    local config_path="${TLS_CERT_DIR}/envoy.yaml"

    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would generate envoy.yaml at ${config_path}"
        return 0
    fi

    mkdir -p "${TLS_CERT_DIR}"

    # Build listeners dynamically based on which services are deployed
    local pyroscope_listener grafana_listener=""

    pyroscope_listener="      - name: pyroscope_listener
        address:
          socket_address:
            address: 0.0.0.0
            port_value: ${TLS_PORT_PYROSCOPE}
        filter_chains:
          - transport_socket:
              name: envoy.transport_sockets.tls
              typed_config:
                \"@type\": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
                common_tls_context:
                  tls_certificates:
                    - certificate_chain:
                        filename: /etc/envoy/tls/cert.pem
                      private_key:
                        filename: /etc/envoy/tls/key.pem
                # Future: require_client_certificate: true (for mTLS)
            filters:
              - name: envoy.filters.network.http_connection_manager
                typed_config:
                  \"@type\": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                  stat_prefix: pyroscope
                  route_config:
                    virtual_hosts:
                      - name: pyroscope
                        domains: [\"*\"]
                        routes:
                          - match: { prefix: \"/\" }
                            route:
                              cluster: pyroscope_backend
                              timeout: 60s
                  http_filters:
                    - name: envoy.filters.http.router
                      typed_config:
                        \"@type\": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"

    if [ "${SKIP_GRAFANA}" != true ]; then
        grafana_listener="      - name: grafana_listener
        address:
          socket_address:
            address: 0.0.0.0
            port_value: ${TLS_PORT_GRAFANA}
        filter_chains:
          - transport_socket:
              name: envoy.transport_sockets.tls
              typed_config:
                \"@type\": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
                common_tls_context:
                  tls_certificates:
                    - certificate_chain:
                        filename: /etc/envoy/tls/cert.pem
                      private_key:
                        filename: /etc/envoy/tls/key.pem
            filters:
              - name: envoy.filters.network.http_connection_manager
                typed_config:
                  \"@type\": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                  stat_prefix: grafana
                  route_config:
                    virtual_hosts:
                      - name: grafana
                        domains: [\"*\"]
                        routes:
                          - match: { prefix: \"/\" }
                            route:
                              cluster: grafana_backend
                              timeout: 60s
                  http_filters:
                    - name: envoy.filters.http.router
                      typed_config:
                        \"@type\": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"
    fi

    # Build clusters
    local pyroscope_cluster grafana_cluster=""

    pyroscope_cluster="      - name: pyroscope_backend
        connect_timeout: 5s
        type: STATIC
        load_assignment:
          cluster_name: pyroscope_backend
          endpoints:
            - lb_endpoints:
                - endpoint:
                    address:
                      socket_address:
                        address: 127.0.0.1
                        port_value: ${PYROSCOPE_PORT}"

    if [ "${SKIP_GRAFANA}" != true ]; then
        grafana_cluster="      - name: grafana_backend
        connect_timeout: 5s
        type: STATIC
        load_assignment:
          cluster_name: grafana_backend
          endpoints:
            - lb_endpoints:
                - endpoint:
                    address:
                      socket_address:
                        address: 127.0.0.1
                        port_value: ${GRAFANA_PORT}"
    fi

    cat > "${config_path}" <<ENVOY_CONFIG
# Envoy TLS proxy configuration
# Generated by deploy.sh — do not edit manually
# Terminates TLS and forwards to backend services on localhost

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901

static_resources:
  listeners:
${pyroscope_listener}
${grafana_listener}

  clusters:
${pyroscope_cluster}
${grafana_cluster}
ENVOY_CONFIG

    ok "Envoy config generated at ${config_path}"
}

deploy_envoy() {
    local zflag="$1"

    step "Deploying Envoy TLS proxy..."
    remove_container "${ENVOY_CONTAINER_NAME}"
    docker_pull_with_retry "${ENVOY_IMAGE}"

    # Build port bindings
    local port_flags="-p ${TLS_PORT_PYROSCOPE}:${TLS_PORT_PYROSCOPE}"
    if [ "${SKIP_GRAFANA}" != true ]; then
        port_flags="${port_flags} -p ${TLS_PORT_GRAFANA}:${TLS_PORT_GRAFANA}"
    fi

    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would run: docker run -d --name ${ENVOY_CONTAINER_NAME} ${port_flags} ${ENVOY_IMAGE}"
    else
        # shellcheck disable=SC2086
        docker run -d \
            --name "${ENVOY_CONTAINER_NAME}" \
            --restart unless-stopped \
            --network host \
            -v "${TLS_CERT_DIR}/envoy.yaml:/etc/envoy/envoy.yaml:ro${zflag}" \
            -v "${TLS_CERT_DIR}:/etc/envoy/tls:ro${zflag}" \
            "${ENVOY_IMAGE}" \
            || die "Failed to start Envoy container"

        # Health check via admin endpoint
        wait_for_url "http://127.0.0.1:9901/ready" "Envoy proxy" 30
    fi
}

# ---- Grafana deployment: baked into image ----------------------------------
deploy_grafana_baked() {
    local pyroscope_url="$1" zflag="$2" grafana_bind="$3"

    # Build Grafana image with Pyroscope provisioning baked in
    step "[2/4] Building Grafana image with Pyroscope provisioning..."
    local grafana_build_dir
    grafana_build_dir="$(mktemp -d)"

    # Stage build context
    cp -f "${REPO_ROOT}/deploy/grafana/grafana.ini" "${grafana_build_dir}/grafana.ini" \
        || die "grafana.ini not found at ${REPO_ROOT}/deploy/grafana/grafana.ini"
    cp -rf "${PROVISIONING_SRC}" "${grafana_build_dir}/provisioning"
    cp -rf "${DASHBOARDS_SRC}" "${grafana_build_dir}/dashboards"

    # Update Pyroscope URL in datasource config
    sed -i "s|http://pyroscope:4040|${pyroscope_url}|g" \
        "${grafana_build_dir}/provisioning/datasources/datasources.yaml"

    cat > "${grafana_build_dir}/Dockerfile" <<DOCKERFILE
FROM ${GRAFANA_IMAGE}
COPY grafana.ini /etc/grafana/grafana.ini
COPY provisioning/ /etc/grafana/provisioning/
COPY dashboards/ /var/lib/grafana/dashboards/
ENV GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource
ENV GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD wget --spider -q http://localhost:3000/api/health || exit 1
DOCKERFILE

    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would run: docker build -t grafana-pyroscope ${grafana_build_dir}"
    else
        docker build -t grafana-pyroscope "${grafana_build_dir}" \
            || die "Docker build failed for grafana-pyroscope image. Check network access for base image pull."
    fi
    rm -rf "${grafana_build_dir}"

    # Deploy Grafana
    step "[3/4] Deploying Grafana..."
    remove_container "grafana"
    ensure_volume "${GRAFANA_VOLUME}"
    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would run: docker run -d --name grafana -p ${grafana_bind} grafana-pyroscope"
    else
        docker run -d \
            --name grafana \
            --restart unless-stopped \
            -p "${grafana_bind}" \
            -v "${GRAFANA_VOLUME}:/var/lib/grafana${zflag}" \
            grafana-pyroscope || die "Failed to start grafana container"
        wait_for_health "grafana" "http://localhost:3000/api/health" 90
    fi
}

# ---- Grafana deployment: volume-mounted config ----------------------------
# Config files live on the host at GRAFANA_CONFIG_DIR. The stock Grafana image
# is used — no custom image build. Config and dashboards survive image upgrades.
deploy_grafana_mounted() {
    local pyroscope_url="$1" zflag="$2" grafana_bind="$3"

    step "[2/4] Staging Grafana config to ${GRAFANA_CONFIG_DIR}..."

    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would create ${GRAFANA_CONFIG_DIR} and copy config files"
    else
        mkdir -p "${GRAFANA_CONFIG_DIR}/provisioning/datasources" \
                 "${GRAFANA_CONFIG_DIR}/provisioning/dashboards" \
                 "${GRAFANA_CONFIG_DIR}/provisioning/plugins" \
                 "${GRAFANA_CONFIG_DIR}/dashboards" \
            || die "Cannot create ${GRAFANA_CONFIG_DIR} — check permissions"

        cp -f "${REPO_ROOT}/deploy/grafana/grafana.ini" "${GRAFANA_CONFIG_DIR}/grafana.ini" \
            || die "grafana.ini not found at ${REPO_ROOT}/deploy/grafana/grafana.ini"
        cp -f "${PROVISIONING_SRC}/datasources/"* "${GRAFANA_CONFIG_DIR}/provisioning/datasources/"
        cp -f "${PROVISIONING_SRC}/dashboards/"*  "${GRAFANA_CONFIG_DIR}/provisioning/dashboards/"
        cp -f "${PROVISIONING_SRC}/plugins/"*    "${GRAFANA_CONFIG_DIR}/provisioning/plugins/"
        cp -f "${DASHBOARDS_SRC}/"*.json         "${GRAFANA_CONFIG_DIR}/dashboards/"

        # Update Pyroscope URL in datasource config
        sed -i "s|http://pyroscope:4040|${pyroscope_url}|g" \
            "${GRAFANA_CONFIG_DIR}/provisioning/datasources/datasources.yaml"

        local copied
        copied=$(find "${GRAFANA_CONFIG_DIR}/dashboards" -name '*.json' | wc -l)
        ok "Staged grafana.ini, provisioning, and ${copied} dashboard(s) to ${GRAFANA_CONFIG_DIR}"
    fi

    # Deploy Grafana with bind mounts (stock image — no custom build)
    step "[3/4] Deploying Grafana (volume-mounted config)..."
    remove_container "grafana"
    ensure_volume "${GRAFANA_VOLUME}"
    docker_pull_with_retry "${GRAFANA_IMAGE}"

    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would run: docker run -d --name grafana -p ${grafana_bind} ${GRAFANA_IMAGE} (with bind mounts)"
    else
        docker run -d \
            --name grafana \
            --restart unless-stopped \
            -p "${grafana_bind}" \
            -v "${GRAFANA_VOLUME}:/var/lib/grafana${zflag}" \
            -v "${GRAFANA_CONFIG_DIR}/grafana.ini:/etc/grafana/grafana.ini:ro${zflag}" \
            -v "${GRAFANA_CONFIG_DIR}/provisioning:/etc/grafana/provisioning:ro${zflag}" \
            -v "${GRAFANA_CONFIG_DIR}/dashboards:/var/lib/grafana/dashboards:ro${zflag}" \
            -e "GF_INSTALL_PLUGINS=grafana-pyroscope-app,grafana-pyroscope-datasource" \
            -e "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}" \
            "${GRAFANA_IMAGE}" || die "Failed to start grafana container"
        wait_for_health "grafana" "http://localhost:3000/api/health" 90
    fi
}

# ---- VM target (docker run) -----------------------------------------------
do_full_stack_vm() {
    step "Deploying full observability stack on VM..."

    # Load images from tar if specified (air-gapped / no registry)
    if [ -n "${LOAD_IMAGES_PATH}" ]; then
        load_images "${LOAD_IMAGES_PATH}"
    fi

    local vm_ip
    vm_ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || vm_ip="localhost"
    local pyroscope_url="http://${vm_ip}:${PYROSCOPE_PORT}"
    local zflag
    zflag="$(selinux_volume_flag)"
    if [ -n "${zflag}" ]; then
        info "SELinux enforcing detected — using ${zflag} volume flag"
    fi

    # Determine step count and port binding
    local total_steps=2
    local pyroscope_bind="${PYROSCOPE_PORT}:4040"
    local grafana_bind="${GRAFANA_PORT}:3000"

    if [ "${SKIP_GRAFANA}" != true ]; then
        total_steps=$((total_steps + 2))
    fi
    if [ "${TLS_ENABLED}" = true ]; then
        total_steps=$((total_steps + 1))
        # When TLS enabled, bind backends to localhost only (Envoy handles external)
        pyroscope_bind="127.0.0.1:${PYROSCOPE_PORT}:4040"
        grafana_bind="127.0.0.1:${GRAFANA_PORT}:3000"
    fi

    # Open firewall ports
    if [ "${TLS_ENABLED}" = true ]; then
        open_firewall_port "${TLS_PORT_PYROSCOPE}"
        if [ "${SKIP_GRAFANA}" != true ]; then
            open_firewall_port "${TLS_PORT_GRAFANA}"
        fi
    else
        open_firewall_port "${PYROSCOPE_PORT}"
        if [ "${SKIP_GRAFANA}" != true ]; then
            open_firewall_port "${GRAFANA_PORT}"
        fi
    fi

    # Deploy Pyroscope
    local current_step=1
    step "[${current_step}/${total_steps}] Deploying Pyroscope..."
    remove_container "pyroscope"
    ensure_volume "${PYROSCOPE_VOLUME}"
    local config_mount=""
    local config_cmd=""
    if [ -n "${PYROSCOPE_CONFIG}" ]; then
        if [ ! -f "${PYROSCOPE_CONFIG}" ]; then
            die "Pyroscope config file not found: ${PYROSCOPE_CONFIG}"
        fi
        config_mount="-v ${PYROSCOPE_CONFIG}:/etc/pyroscope/config.yaml:ro${zflag}"
        config_cmd="-config.file=/etc/pyroscope/config.yaml"
        info "Mounting Pyroscope config: ${PYROSCOPE_CONFIG}"
    fi
    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would run: docker run -d --name pyroscope -p ${pyroscope_bind} ${config_mount} ${PYROSCOPE_IMAGE} ${config_cmd}"
    else
        docker_pull_with_retry "${PYROSCOPE_IMAGE}"
        # shellcheck disable=SC2086
        docker run -d \
            --name pyroscope \
            --restart unless-stopped \
            -p "${pyroscope_bind}" \
            -v "${PYROSCOPE_VOLUME}:/data${zflag}" \
            ${config_mount} \
            "${PYROSCOPE_IMAGE}" ${config_cmd} || die "Failed to start pyroscope container"
        wait_for_health "pyroscope" "http://localhost:4040/ready" 60
    fi

    # Deploy Grafana (unless --skip-grafana)
    if [ "${SKIP_GRAFANA}" != true ]; then
        current_step=$((current_step + 1))
        if [ "${MOUNT_CONFIG}" = true ]; then
            deploy_grafana_mounted "${pyroscope_url}" "${zflag}" "${grafana_bind}"
        else
            deploy_grafana_baked "${pyroscope_url}" "${zflag}" "${grafana_bind}"
        fi
    fi

    # Deploy Envoy TLS proxy (if --tls)
    if [ "${TLS_ENABLED}" = true ]; then
        current_step=$((current_step + 1))
        # Setup certificates
        if [ "${TLS_SELF_SIGNED}" = true ]; then
            generate_self_signed_cert
        else
            copy_provided_certs
        fi
        generate_envoy_config
        deploy_envoy "${zflag}"
    fi

    # Summary
    current_step=$((current_step + 1))
    step "[${current_step}/${total_steps}] Stack deployed"
    print_full_stack_summary
}

# ---- Local target (docker compose) ----------------------------------------
do_full_stack_local() {
    check_docker_compose
    step "Deploying full stack locally with Docker Compose..."

    local compose_file="${SCRIPT_DIR}/docker-compose.yaml"
    if [ ! -f "${compose_file}" ]; then
        generate_compose_file "${compose_file}"
    fi

    if [ "${DRY_RUN}" = true ]; then
        info "[DRY RUN] would run: ${COMPOSE_CMD} -f ${compose_file} up -d"
        return 0
    fi

    ${COMPOSE_CMD} -f "${compose_file}" up -d || die "Docker Compose up failed"
    info "Waiting for services to start..."
    sleep 10

    wait_for_url "http://localhost:${PYROSCOPE_PORT}/ready" "Pyroscope" 60
    wait_for_url "http://localhost:${GRAFANA_PORT}/api/health" "Grafana" 90

    print_full_stack_summary
}

# ---- Kubernetes target -----------------------------------------------------
do_full_stack_k8s() {
    step "Deploying full stack on Kubernetes (namespace: ${NAMESPACE})..."

    kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

    local manifests_dir="${SCRIPT_DIR}/kubernetes"
    if [ ! -d "${manifests_dir}" ]; then
        generate_k8s_manifests "${manifests_dir}"
    fi

    # Create ConfigMaps for Grafana provisioning and dashboards
    step "Creating ConfigMaps..."
    kubectl -n "${NAMESPACE}" create configmap grafana-datasources \
        --from-file="${PROVISIONING_SRC}/datasources/datasources.yaml" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "${NAMESPACE}" create configmap grafana-dashboard-provider \
        --from-file="${PROVISIONING_SRC}/dashboards/dashboards.yaml" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "${NAMESPACE}" create configmap grafana-plugins \
        --from-file="${PROVISIONING_SRC}/plugins/plugins.yaml" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "${NAMESPACE}" create configmap grafana-dashboards \
        --from-file="${DASHBOARDS_SRC}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Apply manifests
    step "Applying Kubernetes manifests..."
    kubectl apply -n "${NAMESPACE}" -f "${manifests_dir}/"

    info "Waiting for pods..."
    kubectl -n "${NAMESPACE}" wait --for=condition=ready pod -l app=pyroscope --timeout=120s \
        || die "Pyroscope pod not ready. Run: kubectl -n ${NAMESPACE} describe pod -l app=pyroscope"
    kubectl -n "${NAMESPACE}" wait --for=condition=ready pod -l app=grafana --timeout=120s \
        || die "Grafana pod not ready. Run: kubectl -n ${NAMESPACE} describe pod -l app=grafana"

    ok "Stack deployed on Kubernetes"
    echo ""
    info "Pyroscope: kubectl -n ${NAMESPACE} port-forward svc/pyroscope ${PYROSCOPE_PORT}:4040"
    info "Grafana:   kubectl -n ${NAMESPACE} port-forward svc/grafana ${GRAFANA_PORT}:3000"
    echo ""
}

# ---- OpenShift target ------------------------------------------------------
do_full_stack_openshift() {
    step "Deploying full stack on OpenShift (namespace: ${NAMESPACE})..."

    oc new-project "${NAMESPACE}" 2>/dev/null || oc project "${NAMESPACE}"

    # Use the same K8s manifests
    local manifests_dir="${SCRIPT_DIR}/kubernetes"
    if [ ! -d "${manifests_dir}" ]; then
        generate_k8s_manifests "${manifests_dir}"
    fi

    # Create ConfigMaps
    step "Creating ConfigMaps..."
    oc -n "${NAMESPACE}" create configmap grafana-datasources \
        --from-file="${PROVISIONING_SRC}/datasources/datasources.yaml" \
        --dry-run=client -o yaml | oc apply -f -
    oc -n "${NAMESPACE}" create configmap grafana-dashboard-provider \
        --from-file="${PROVISIONING_SRC}/dashboards/dashboards.yaml" \
        --dry-run=client -o yaml | oc apply -f -
    oc -n "${NAMESPACE}" create configmap grafana-plugins \
        --from-file="${PROVISIONING_SRC}/plugins/plugins.yaml" \
        --dry-run=client -o yaml | oc apply -f -
    oc -n "${NAMESPACE}" create configmap grafana-dashboards \
        --from-file="${DASHBOARDS_SRC}" \
        --dry-run=client -o yaml | oc apply -f -

    # Apply manifests
    step "Applying manifests..."
    oc apply -n "${NAMESPACE}" -f "${manifests_dir}/"

    # Create routes (OpenShift-specific)
    step "Creating routes..."
    oc -n "${NAMESPACE}" expose svc/pyroscope --name=pyroscope 2>/dev/null || true
    oc -n "${NAMESPACE}" expose svc/grafana --name=grafana 2>/dev/null || true

    info "Waiting for pods..."
    oc -n "${NAMESPACE}" wait --for=condition=ready pod -l app=pyroscope --timeout=120s \
        || die "Pyroscope pod not ready. Run: oc -n ${NAMESPACE} describe pod -l app=pyroscope"
    oc -n "${NAMESPACE}" wait --for=condition=ready pod -l app=grafana --timeout=120s \
        || die "Grafana pod not ready. Run: oc -n ${NAMESPACE} describe pod -l app=grafana"

    local pyroscope_route grafana_route
    pyroscope_route=$(oc -n "${NAMESPACE}" get route pyroscope -o jsonpath='{.spec.host}' 2>/dev/null) || true
    grafana_route=$(oc -n "${NAMESPACE}" get route grafana -o jsonpath='{.spec.host}' 2>/dev/null) || true

    ok "Stack deployed on OpenShift"
    echo ""
    info "Pyroscope: http://${pyroscope_route:-<pending>}"
    info "Grafana:   http://${grafana_route:-<pending>}"
    info "Credentials: admin / ${GRAFANA_ADMIN_PASSWORD}"
    echo ""
}

# ===========================================================================
#  Shared helpers
# ===========================================================================

remove_container() {
    local name="$1"
    if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
        info "Removing existing container: ${name}"
        if [ "${DRY_RUN}" = true ]; then
            info "[DRY RUN] would remove container ${name}"
        else
            docker rm -f "${name}" >/dev/null || warn "Could not remove container ${name}"
        fi
    else
        info "Container ${name} does not exist (nothing to remove)"
    fi
}

ensure_volume() {
    local name="$1"
    if ! docker volume ls --format '{{.Name}}' | grep -qx "${name}"; then
        info "Creating volume: ${name}"
        if [ "${DRY_RUN}" = true ]; then
            info "[DRY RUN] would create volume ${name}"
        else
            docker volume create "${name}" >/dev/null || die "Failed to create Docker volume: ${name}"
        fi
    else
        info "Volume ${name} already exists (reusing)"
    fi
}

wait_for_health() {
    local container="$1" endpoint="$2" timeout="${3:-60}"
    local elapsed=0
    info "Waiting for ${container} to become ready (timeout: ${timeout}s)..."
    while [ "${elapsed}" -lt "${timeout}" ]; do
        # Check if container is still running (detect crash loops)
        local state
        state=$(docker inspect --format='{{.State.Status}}' "${container}" 2>/dev/null) || state="missing"
        if [ "${state}" = "exited" ] || [ "${state}" = "dead" ] || [ "${state}" = "missing" ]; then
            err "Container ${container} is ${state}."
            err "Logs:"
            docker logs --tail 30 "${container}" 2>&1 | while IFS= read -r line; do err "  ${line}"; done
            die "Container ${container} crashed. Fix the issue and re-run."
        fi

        if docker exec "${container}" wget -q --spider "${endpoint}" 2>/dev/null; then
            ok "${container} is ready (took ${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    err "Container ${container} did not become ready within ${timeout}s."
    err "Container state: $(docker inspect --format='{{.State.Status}}' "${container}" 2>/dev/null || echo 'unknown')"
    err "Recent logs:"
    docker logs --tail 30 "${container}" 2>&1 | while IFS= read -r line; do err "  ${line}"; done
    die "Health check timeout for ${container}. Check logs above."
}

wait_for_url() {
    local url="$1" name="$2" timeout="${3:-60}"
    local elapsed=0
    info "Waiting for ${name} at ${url} (timeout: ${timeout}s)..."
    while [ "${elapsed}" -lt "${timeout}" ]; do
        if curl -sf "${url}" >/dev/null 2>&1; then
            ok "${name} is ready (took ${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    die "${name} at ${url} did not respond within ${timeout}s."
}

print_full_stack_summary() {
    local vm_ip
    vm_ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || vm_ip="localhost"

    local proto="http" pyro_port="${PYROSCOPE_PORT}" graf_port="${GRAFANA_PORT}"
    if [ "${TLS_ENABLED}" = true ]; then
        proto="https"
        pyro_port="${TLS_PORT_PYROSCOPE}"
        graf_port="${TLS_PORT_GRAFANA}"
    fi

    echo ""
    ok "========================================="
    if [ "${TLS_ENABLED}" = true ]; then
        ok " Observability stack is running (HTTPS)"
    else
        ok " Observability stack is running"
    fi
    ok "========================================="
    echo ""
    info "Pyroscope:"
    info "  UI:       ${proto}://${vm_ip}:${pyro_port}"
    info "  Ingest:   ${proto}://${vm_ip}:${pyro_port}/ingest"
    echo ""
    if [ "${SKIP_GRAFANA}" != true ]; then
        info "Grafana:"
        info "  UI:       ${proto}://${vm_ip}:${graf_port}"
        info "  Login:    admin / ${GRAFANA_ADMIN_PASSWORD}"
        echo ""
        info "Dashboards are pre-loaded in the 'Pyroscope' folder in Grafana."
    fi
    echo ""
    info "Configure Java services with:"
    info "  PYROSCOPE_SERVER_ADDRESS=${proto}://${vm_ip}:${pyro_port}"
    if [ "${TLS_ENABLED}" = true ] && [ "${TLS_SELF_SIGNED}" = true ]; then
        echo ""
        warn "Self-signed cert: Java agents need TLS trust configured."
        info "  Option 1: Import cert into JVM truststore:"
        info "    keytool -import -alias pyroscope -file ${TLS_CERT_DIR}/cert.pem -keystore \$JAVA_HOME/lib/security/cacerts"
        info "  Option 2: Disable cert verification (dev only):"
        info "    -Djavax.net.ssl.trustStore=${TLS_CERT_DIR}/cert.pem"
    fi
    if [ "${MOUNT_CONFIG}" = true ] && [ "${SKIP_GRAFANA}" != true ]; then
        echo ""
        info "Config is volume-mounted from: ${GRAFANA_CONFIG_DIR}"
        info "  Edit config and restart Grafana:  docker restart grafana"
        info "  Config survives image upgrades — just re-pull and re-run."
    fi
    if [ "${TLS_ENABLED}" = true ]; then
        echo ""
        info "TLS certificates: ${TLS_CERT_DIR}/"
        info "Envoy config:     ${TLS_CERT_DIR}/envoy.yaml"
    fi
    echo ""
    info "Day-2 operations:"
    info "  bash deploy.sh status  --target ${TARGET}"
    info "  bash deploy.sh logs    --target ${TARGET}"
    info "  bash deploy.sh stop    --target ${TARGET}"
    info "  bash deploy.sh clean   --target ${TARGET}"
    echo ""
}

generate_compose_file() {
    local file="$1"
    info "Generating docker-compose.yaml at ${file}"
    cat > "${file}" <<YAML
# Pyroscope + Grafana observability stack
# Generated by deploy.sh — edit as needed

services:
  pyroscope:
    image: ${PYROSCOPE_IMAGE}
    ports:
      - "${PYROSCOPE_PORT}:4040"
    volumes:
      - pyroscope-data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:4040/ready"]
      interval: 15s
      timeout: 3s
      start_period: 10s
      retries: 3

  grafana:
    image: ${GRAFANA_IMAGE}
    ports:
      - "${GRAFANA_PORT}:3000"
    volumes:
      - grafana-data:/var/lib/grafana
      - ${PROVISIONING_SRC}/datasources:/etc/grafana/provisioning/datasources:ro
      - ${PROVISIONING_SRC}/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ${PROVISIONING_SRC}/plugins:/etc/grafana/provisioning/plugins:ro
      - ${DASHBOARDS_SRC}:/var/lib/grafana/dashboards:ro
    environment:
      GF_INSTALL_PLUGINS: grafana-pyroscope-app,grafana-pyroscope-datasource
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS: grafana-pyroscope-app,grafana-pyroscope-datasource
      GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: /var/lib/grafana/dashboards/pyroscope-overview.json
    depends_on:
      pyroscope:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000/api/health"]
      interval: 15s
      timeout: 5s
      start_period: 30s
      retries: 3

volumes:
  pyroscope-data:
  grafana-data:
YAML
    ok "docker-compose.yaml generated"
}

generate_k8s_manifests() {
    local dir="$1"
    mkdir -p "${dir}"
    info "Generating Kubernetes manifests at ${dir}"
    info "  Persistent storage: ${PERSISTENT_STORAGE}"
    if [ "${PERSISTENT_STORAGE}" = true ]; then
        info "  Pyroscope PVC: ${PVC_SIZE_PYROSCOPE}, Grafana PVC: ${PVC_SIZE_GRAFANA}"
        [ -n "${STORAGE_CLASS}" ] && info "  Storage class: ${STORAGE_CLASS}"
    fi

    # --- Pyroscope volume spec (PVC or emptyDir) ---
    local pyroscope_pvc="" pyroscope_vol_spec=""
    if [ "${PERSISTENT_STORAGE}" = true ]; then
        pyroscope_pvc="apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pyroscope-data
  labels:
    app: pyroscope
spec:
  accessModes:
    - ReadWriteOnce"
        [ -n "${STORAGE_CLASS}" ] && pyroscope_pvc="${pyroscope_pvc}
  storageClassName: ${STORAGE_CLASS}"
        pyroscope_pvc="${pyroscope_pvc}
  resources:
    requests:
      storage: ${PVC_SIZE_PYROSCOPE}
---"
        pyroscope_vol_spec="          persistentVolumeClaim:
            claimName: pyroscope-data"
    else
        pyroscope_vol_spec="          emptyDir: {}"
    fi

    cat > "${dir}/pyroscope.yaml" <<YAML
${pyroscope_pvc}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pyroscope
  labels:
    app: pyroscope
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pyroscope
  template:
    metadata:
      labels:
        app: pyroscope
    spec:
      containers:
        - name: pyroscope
          image: ${PYROSCOPE_IMAGE}
          ports:
            - containerPort: 4040
          readinessProbe:
            httpGet:
              path: /ready
              port: 4040
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 2Gi
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
${pyroscope_vol_spec}
---
apiVersion: v1
kind: Service
metadata:
  name: pyroscope
  labels:
    app: pyroscope
spec:
  selector:
    app: pyroscope
  ports:
    - port: 4040
      targetPort: 4040
  type: ClusterIP
YAML

    # --- Grafana volume spec (PVC or emptyDir) ---
    local grafana_pvc="" grafana_vol_spec=""
    if [ "${PERSISTENT_STORAGE}" = true ]; then
        grafana_pvc="apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-data
  labels:
    app: grafana
spec:
  accessModes:
    - ReadWriteOnce"
        [ -n "${STORAGE_CLASS}" ] && grafana_pvc="${grafana_pvc}
  storageClassName: ${STORAGE_CLASS}"
        grafana_pvc="${grafana_pvc}
  resources:
    requests:
      storage: ${PVC_SIZE_GRAFANA}
---"
        grafana_vol_spec="          persistentVolumeClaim:
            claimName: grafana-data"
    else
        grafana_vol_spec="          emptyDir: {}"
    fi

    cat > "${dir}/grafana.yaml" <<YAML
${grafana_pvc}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  labels:
    app: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: ${GRAFANA_IMAGE}
          ports:
            - containerPort: 3000
          env:
            - name: GF_INSTALL_PLUGINS
              value: "grafana-pyroscope-app,grafana-pyroscope-datasource"
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: "${GRAFANA_ADMIN_PASSWORD}"
            - name: GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS
              value: "grafana-pyroscope-app,grafana-pyroscope-datasource"
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
          volumeMounts:
            - name: datasources
              mountPath: /etc/grafana/provisioning/datasources
            - name: dashboard-provider
              mountPath: /etc/grafana/provisioning/dashboards
            - name: plugins
              mountPath: /etc/grafana/provisioning/plugins
            - name: dashboards
              mountPath: /var/lib/grafana/dashboards
            - name: data
              mountPath: /var/lib/grafana
      volumes:
        - name: datasources
          configMap:
            name: grafana-datasources
        - name: dashboard-provider
          configMap:
            name: grafana-dashboard-provider
        - name: plugins
          configMap:
            name: grafana-plugins
        - name: dashboards
          configMap:
            name: grafana-dashboards
        - name: data
${grafana_vol_spec}
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  labels:
    app: grafana
spec:
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
  type: ClusterIP
YAML
    ok "Kubernetes manifests generated"
}

# ===========================================================================
#  Status / Stop / Clean commands
# ===========================================================================

cmd_status() {
    case "${TARGET}" in
        vm|local)
            echo "=== Pyroscope ==="
            if docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter "name=^pyroscope$" 2>/dev/null | grep -q pyroscope; then
                docker ps --filter "name=^pyroscope$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            else
                info "pyroscope container is not running"
            fi
            echo ""
            if [ "${SKIP_GRAFANA}" != true ]; then
                echo "=== Grafana ==="
                if docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter "name=^grafana$" 2>/dev/null | grep -q grafana; then
                    docker ps --filter "name=^grafana$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                else
                    info "grafana container is not running"
                fi
                echo ""
            fi
            if [ "${TLS_ENABLED}" = true ]; then
                echo "=== Envoy TLS Proxy ==="
                if docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' --filter "name=^${ENVOY_CONTAINER_NAME}$" 2>/dev/null | grep -q "${ENVOY_CONTAINER_NAME}"; then
                    docker ps --filter "name=^${ENVOY_CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                else
                    info "${ENVOY_CONTAINER_NAME} container is not running"
                fi
                echo ""
            fi
            ;;
        k8s)
            kubectl -n "${NAMESPACE}" get pods,svc -l 'app in (pyroscope,grafana)'
            ;;
        openshift)
            oc -n "${NAMESPACE}" get pods,svc,routes -l 'app in (pyroscope,grafana)'
            ;;
    esac
}

cmd_stop() {
    case "${TARGET}" in
        vm)
            remove_container "${ENVOY_CONTAINER_NAME}"
            if [ "${SKIP_GRAFANA}" != true ]; then
                remove_container "grafana"
            fi
            remove_container "pyroscope"
            ok "Stack stopped (volumes preserved)"
            ;;
        local)
            check_docker_compose
            local compose_file="${SCRIPT_DIR}/docker-compose.yaml"
            if [ -f "${compose_file}" ]; then
                ${COMPOSE_CMD} -f "${compose_file}" down
            else
                remove_container "grafana"
                remove_container "pyroscope"
            fi
            ok "Stack stopped"
            ;;
        k8s)
            kubectl -n "${NAMESPACE}" delete deploy,svc -l 'app in (pyroscope,grafana)' 2>/dev/null || true
            ok "Stack removed from Kubernetes"
            ;;
        openshift)
            oc -n "${NAMESPACE}" delete deploy,svc,route -l 'app in (pyroscope,grafana)' 2>/dev/null || true
            ok "Stack removed from OpenShift"
            ;;
    esac
}

cmd_clean() {
    cmd_stop
    case "${TARGET}" in
        vm|local)
            info "Removing volumes..."
            docker volume rm "${PYROSCOPE_VOLUME}" 2>/dev/null || true
            if [ "${SKIP_GRAFANA}" != true ]; then
                docker volume rm "${GRAFANA_VOLUME}" 2>/dev/null || true
            fi
            info "Removing images..."
            docker rmi grafana-pyroscope 2>/dev/null || true
            if [ -d "${GRAFANA_CONFIG_DIR}" ]; then
                info "Removing mounted config at ${GRAFANA_CONFIG_DIR}..."
                rm -rf "${GRAFANA_CONFIG_DIR}"
            fi
            if [ -d "${TLS_CERT_DIR}" ]; then
                info "Removing TLS certificates at ${TLS_CERT_DIR}..."
                rm -rf "${TLS_CERT_DIR}"
            fi
            ok "Fully cleaned up"
            ;;
        k8s)
            kubectl -n "${NAMESPACE}" delete configmap \
                grafana-datasources grafana-dashboard-provider \
                grafana-plugins grafana-dashboards 2>/dev/null || true
            info "Removing PVCs..."
            kubectl -n "${NAMESPACE}" delete pvc pyroscope-data grafana-data 2>/dev/null || true
            ok "Cleaned up ConfigMaps and PVCs"
            ;;
        openshift)
            oc -n "${NAMESPACE}" delete configmap \
                grafana-datasources grafana-dashboard-provider \
                grafana-plugins grafana-dashboards 2>/dev/null || true
            info "Removing PVCs..."
            oc -n "${NAMESPACE}" delete pvc pyroscope-data grafana-data 2>/dev/null || true
            ok "Cleaned up ConfigMaps and PVCs"
            ;;
    esac
}

cmd_logs() {
    case "${TARGET}" in
        vm|local)
            info "=== Pyroscope logs ==="
            docker logs --tail 20 pyroscope 2>/dev/null || warn "pyroscope not running"
            echo ""
            if [ "${SKIP_GRAFANA}" != true ]; then
                info "=== Grafana logs ==="
                docker logs --tail 20 grafana 2>/dev/null || warn "grafana not running"
                echo ""
            fi
            if [ "${TLS_ENABLED}" = true ]; then
                info "=== Envoy TLS Proxy logs ==="
                docker logs --tail 20 "${ENVOY_CONTAINER_NAME}" 2>/dev/null || warn "${ENVOY_CONTAINER_NAME} not running"
                echo ""
            fi
            info "Use 'docker logs -f <container>' to follow"
            ;;
        k8s)
            kubectl -n "${NAMESPACE}" logs -l app=pyroscope --tail=20
            kubectl -n "${NAMESPACE}" logs -l app=grafana --tail=20
            ;;
        openshift)
            oc -n "${NAMESPACE}" logs -l app=pyroscope --tail=20
            oc -n "${NAMESPACE}" logs -l app=grafana --tail=20
            ;;
    esac
}

# ===========================================================================
#  Argument parsing & dispatch
# ===========================================================================

usage() {
    cat <<'USAGE'
Usage: bash deploy.sh <mode> [options]

Modes:
  full-stack         Deploy Pyroscope + Grafana stack (default)
  add-to-existing    Add Pyroscope to an existing Grafana instance
  save-images        Save Docker images to tar for air-gapped transfer
  status             Show stack status
  stop               Stop the stack (preserve data)
  clean              Stop and remove all data
  logs               Show recent logs

Options:
  --target <env>                 vm (default), local, k8s, openshift
  --method <type>                api (default) or provisioning
  --dry-run                      Validate without making changes
  --log-file <path>              Append all output to a log file
  --skip-grafana                 Deploy Pyroscope only (no Grafana)
  --load-images <path>           Load Docker images from tar before deploying
  --bake-config                  Bake config into custom image (not default)
  --mount-config                 Mount config as volumes (default)
  --grafana-config-dir <path>    Host directory for mounted config (default: /opt/pyroscope/grafana)

  Pyroscope:
  --pyroscope-url <url>          Pyroscope server URL
  --pyroscope-port <port>        Host port (default: 4040)
  --pyroscope-image <image>      Docker image (default: grafana/pyroscope:latest)
  --pyroscope-config <path>      Mount custom pyroscope.yaml into container

  Grafana:
  --grafana-url <url>            Existing Grafana URL (for add-to-existing)
  --grafana-api-key <key>        Grafana API key (prefer GRAFANA_API_KEY env var)
  --grafana-admin-password <pw>  Admin password (prefer GRAFANA_ADMIN_PASSWORD env var)
  --grafana-port <port>          Host port (default: 3000)
  --grafana-provisioning-dir <d> Provisioning directory (for provisioning method)
  --grafana-dashboard-dir <d>    Dashboard directory (for provisioning method)

  TLS / HTTPS (Envoy reverse proxy):
  --tls                          Enable TLS mode (requires cert source below)
  --tls-self-signed              Auto-generate self-signed cert (dev/demo)
  --tls-cert <path>              TLS certificate file path (PEM)
  --tls-key <path>               TLS private key file path (PEM)
  --tls-cert-dir <path>          Cert directory on host (default: /opt/pyroscope/tls)
  --tls-port-pyroscope <port>    HTTPS port for Pyroscope (default: 4443)
  --tls-port-grafana <port>      HTTPS port for Grafana (default: 443)
  --tls-client-ca <path>         (Future) mTLS client CA — not yet implemented

  Kubernetes / OpenShift:
  --namespace <ns>               Kubernetes namespace (default: monitoring)
  --no-pvc                       Use emptyDir instead of PVC (ephemeral, for dev/testing)
  --storage-class <sc>           Storage class for PVCs (default: cluster default)
  --pvc-size-pyroscope <size>    PVC size for Pyroscope data (default: 10Gi)
  --pvc-size-grafana <size>      PVC size for Grafana data (default: 2Gi)

Examples:
  # === Standalone HTTP (first deployment) ===
  # Save images on a machine with internet access
  bash deploy.sh save-images
  # scp pyroscope-stack-images.tar operator@vm01:/tmp/
  # On the VM: load images and deploy
  bash deploy.sh full-stack --target vm --load-images /tmp/pyroscope-stack-images.tar

  # === Standalone HTTPS (self-signed TLS) ===
  bash deploy.sh full-stack --target vm --tls --tls-self-signed \
      --load-images /tmp/pyroscope-stack-images.tar

  # === Enterprise-Integrated HTTPS (CA certs) ===
  bash deploy.sh full-stack --target vm --tls \
      --tls-cert /path/to/cert.pem --tls-key /path/to/key.pem

  # === Pyroscope-only VM (no Grafana) ===
  bash deploy.sh full-stack --target vm --skip-grafana

  # Dry run first to validate
  bash deploy.sh full-stack --target vm --dry-run

  # Full stack locally
  bash deploy.sh full-stack --target local

  # Add to existing Grafana via API
  bash deploy.sh add-to-existing --grafana-url http://grafana:3000 \
      --grafana-api-key eyJrIj... --pyroscope-url http://pyroscope:4040

  # Custom Pyroscope image with pinned version
  bash deploy.sh full-stack --target vm \
      --pyroscope-image pyroscope-server:1.18.0 \
      --pyroscope-config /opt/pyroscope/pyroscope.yaml

  # Kubernetes (persistent — default)
  bash deploy.sh full-stack --target k8s --namespace monitoring

  # OpenShift with routes
  bash deploy.sh full-stack --target openshift --namespace monitoring

Companion script for image building:
  bash build-and-push.sh --version 1.18.0 --save         # Build + export tar
  bash build-and-push.sh --version 1.18.0 --push         # Build + push to registry
  bash build-and-push.sh --list-tags                      # List available versions
  See DOCKER-BUILD.md for full image building guide.
USAGE
    exit 0
}

main() {
    MODE="${1:-}"
    if [ -z "${MODE}" ]; then
        usage
    fi
    shift

    # Parse options
    while [ $# -gt 0 ]; do
        case "$1" in
            --target)                   TARGET="${2:?--target requires a value}"; shift 2 ;;
            --method)                   METHOD="${2:?--method requires a value}"; shift 2 ;;
            --dry-run)                  DRY_RUN=true; shift ;;
            --log-file)                 LOG_FILE="${2:?--log-file requires a path}"; shift 2 ;;
            --skip-grafana)             SKIP_GRAFANA=true; shift ;;
            --load-images)              LOAD_IMAGES_PATH="${2:?--load-images requires a path}"; shift 2 ;;
            --mount-config)             MOUNT_CONFIG=true; shift ;;
            --bake-config)              MOUNT_CONFIG=false; shift ;;
            --grafana-config-dir)       GRAFANA_CONFIG_DIR="${2:?--grafana-config-dir requires a path}"; shift 2 ;;
            --pyroscope-url)            PYROSCOPE_URL="$2"; shift 2 ;;
            --pyroscope-port)           PYROSCOPE_PORT="$2"; shift 2 ;;
            --pyroscope-image)          PYROSCOPE_IMAGE="$2"; shift 2 ;;
            --pyroscope-config)         PYROSCOPE_CONFIG="${2:?--pyroscope-config requires a path}"; shift 2 ;;
            --grafana-url)              GRAFANA_URL="$2"; shift 2 ;;
            --grafana-api-key)          GRAFANA_API_KEY="$2"; _API_KEY_FROM_CLI=true; shift 2 ;;
            --grafana-admin-password)   GRAFANA_ADMIN_PASSWORD="$2"; _ADMIN_PW_FROM_CLI=true; shift 2 ;;
            --grafana-port)             GRAFANA_PORT="$2"; shift 2 ;;
            --grafana-image)            GRAFANA_IMAGE="$2"; shift 2 ;;
            --grafana-provisioning-dir) GRAFANA_PROVISIONING_DIR="$2"; shift 2 ;;
            --grafana-dashboard-dir)    GRAFANA_DASHBOARD_DIR="$2"; shift 2 ;;
            --tls)                      TLS_ENABLED=true; shift ;;
            --tls-self-signed)          TLS_ENABLED=true; TLS_SELF_SIGNED=true; shift ;;
            --tls-cert)                 TLS_ENABLED=true; TLS_CERT="${2:?--tls-cert requires a path}"; shift 2 ;;
            --tls-key)                  TLS_ENABLED=true; TLS_KEY="${2:?--tls-key requires a path}"; shift 2 ;;
            --tls-cert-dir)             TLS_CERT_DIR="${2:?--tls-cert-dir requires a path}"; shift 2 ;;
            --tls-port-pyroscope)       TLS_PORT_PYROSCOPE="${2:?--tls-port-pyroscope requires a value}"; shift 2 ;;
            --tls-port-grafana)         TLS_PORT_GRAFANA="${2:?--tls-port-grafana requires a value}"; shift 2 ;;
            --tls-client-ca)            TLS_CLIENT_CA="${2:?--tls-client-ca requires a path}"; shift 2 ;;
            --envoy-image)              ENVOY_IMAGE="$2"; shift 2 ;;
            --namespace)                NAMESPACE="$2"; shift 2 ;;
            --no-pvc)                   PERSISTENT_STORAGE=false; shift ;;
            --storage-class)            STORAGE_CLASS="${2:?--storage-class requires a value}"; shift 2 ;;
            --pvc-size-pyroscope)       PVC_SIZE_PYROSCOPE="${2:?--pvc-size-pyroscope requires a value}"; shift 2 ;;
            --pvc-size-grafana)         PVC_SIZE_GRAFANA="${2:?--pvc-size-grafana requires a value}"; shift 2 ;;
            --grafana-route)            GRAFANA_ROUTE="$2"; shift 2 ;;
            -h|--help|help)             usage ;;
            *)  die "Unknown option: $1" ;;
        esac
    done

    # Initialize log file
    if [ -n "${LOG_FILE}" ]; then
        mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
        info "Logging to ${LOG_FILE}"
    fi

    if [ "${DRY_RUN}" = true ]; then
        warn "DRY RUN mode — no changes will be made"
    fi

    # Warn about secrets passed as CLI flags (visible in ps output and shell history)
    if [ "${_API_KEY_FROM_CLI:-false}" = true ]; then
        warn "API key passed via --grafana-api-key flag (visible in 'ps' and shell history)."
        warn "Recommended: export GRAFANA_API_KEY=<key> instead."
    fi
    if [ "${_ADMIN_PW_FROM_CLI:-false}" = true ]; then
        warn "Password passed via --grafana-admin-password flag (visible in 'ps' and shell history)."
        warn "Recommended: export GRAFANA_ADMIN_PASSWORD=<password> instead."
    fi

    # Dispatch
    case "${MODE}" in
        add-to-existing)
            preflight
            validate_add_to_existing
            case "${METHOD}" in
                api)          do_add_to_existing_api ;;
                provisioning) do_add_to_existing_provisioning ;;
                *)            die "Unknown method: ${METHOD}. Use 'api' or 'provisioning'." ;;
            esac
            ;;
        full-stack)
            validate_tls
            preflight
            validate_full_stack
            case "${TARGET}" in
                vm)        do_full_stack_vm ;;
                local)     do_full_stack_local ;;
                k8s)       do_full_stack_k8s ;;
                openshift) do_full_stack_openshift ;;
                *)         die "Unknown target: ${TARGET}" ;;
            esac
            ;;
        save-images)
            check_docker
            cmd_save_images "${2:-pyroscope-stack-images.tar}"
            ;;
        status)  cmd_status ;;
        stop)    cmd_stop ;;
        clean)   cmd_clean ;;
        logs)    cmd_logs ;;
        -h|--help|help) usage ;;
        *)
            die "Unknown mode: ${MODE}. Run with --help for usage."
            ;;
    esac
}

main "$@"

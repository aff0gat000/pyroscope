#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-test.sh — Unit tests for deploy.sh
#
# Exercises every code path using mock binaries for docker, id, git, hostname.
# No root, Docker, or network access required.
#
# Usage:  bash deploy/grafana/deploy-test.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy.sh"

PASSED=0
FAILED=0
TOTAL=0

# ---- Test framework -------------------------------------------------------
setup() {
    TEST_TMP="$(mktemp -d)"
    MOCK_BIN="${TEST_TMP}/bin"
    mkdir -p "${MOCK_BIN}"

    # Default mock: id -u returns 0 (root)
    cat > "${MOCK_BIN}/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then echo "0"; else command id "$@"; fi
EOF
    chmod +x "${MOCK_BIN}/id"

    # Default mock: hostname
    cat > "${MOCK_BIN}/hostname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-I" ]; then echo "10.0.0.1"; else echo "testvm"; fi
EOF
    chmod +x "${MOCK_BIN}/hostname"

    # Default mock: docker (records calls, succeeds)
    DOCKER_LOG="${TEST_TMP}/docker.log"
    cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "${DOCKER_LOG}"
case "\$1" in
    info)   exit 0 ;;
    build)  exit 0 ;;
    run)    echo "abc123"; exit 0 ;;
    rm)     exit 0 ;;
    rmi)    exit 0 ;;
    ps)
        if [ "\${2:-}" = "-a" ]; then
            # "ps -a --format" — list all containers
            echo ""
        else
            # "ps --format" — list running containers
            echo ""
        fi
        ;;
    exec)   exit 0 ;;  # health check succeeds
    volume)
        case "\${2:-}" in
            ls)     echo "" ;;
            create) exit 0 ;;
            rm)     exit 0 ;;
        esac
        ;;
    logs)   echo "[mock] log output"; exit 0 ;;
esac
EOF
    chmod +x "${MOCK_BIN}/docker"

    # Default mock: git
    GIT_LOG="${TEST_TMP}/git.log"
    cat > "${MOCK_BIN}/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "${GIT_LOG}"
exit 0
EOF
    chmod +x "${MOCK_BIN}/git"

    # Default mock: sleep (no-op for speed)
    cat > "${MOCK_BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${MOCK_BIN}/sleep"

    # Create a fake INSTALL_DIR with Dockerfile and required files
    FAKE_INSTALL="${TEST_TMP}/install"
    mkdir -p "${FAKE_INSTALL}"
    echo "FROM scratch" > "${FAKE_INSTALL}/Dockerfile"
    echo "[server]" > "${FAKE_INSTALL}/grafana.ini"
    mkdir -p "${FAKE_INSTALL}/provisioning/datasources"
    echo "apiVersion: 1" > "${FAKE_INSTALL}/provisioning/datasources/datasources.yaml"
    mkdir -p "${FAKE_INSTALL}/dashboards"
    echo "{}" > "${FAKE_INSTALL}/dashboards/test.json"

    export PATH="${MOCK_BIN}:${PATH}"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

run_deploy() {
    INSTALL_DIR="${FAKE_INSTALL}" \
    CONTAINER_NAME="test-grafana" \
    IMAGE_NAME="test-grafana-server" \
    VOLUME_NAME="test-grafana-data" \
    HEALTH_TIMEOUT="4" \
    GRAFANA_PORT="13000" \
        bash "${DEPLOY_SCRIPT}" "$@" 2>&1
}

assert_success() {
    local test_name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    local output
    if output=$(run_deploy "$@" 2>&1); then
        PASSED=$((PASSED + 1))
        printf '  \033[32mPASS\033[0m  %s\n' "${test_name}"
    else
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m  %s\n' "${test_name}"
        printf '        Output: %s\n' "${output}"
    fi
}

assert_failure() {
    local test_name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    local output
    if output=$(run_deploy "$@" 2>&1); then
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m  %s (expected failure, got success)\n' "${test_name}"
        printf '        Output: %s\n' "${output}"
    else
        PASSED=$((PASSED + 1))
        printf '  \033[32mPASS\033[0m  %s\n' "${test_name}"
    fi
}

assert_output_contains() {
    local test_name="$1"
    local pattern="$2"
    shift 2
    TOTAL=$((TOTAL + 1))
    local output
    output=$(run_deploy "$@" 2>&1) || true
    if echo "${output}" | grep -q "${pattern}"; then
        PASSED=$((PASSED + 1))
        printf '  \033[32mPASS\033[0m  %s\n' "${test_name}"
    else
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m  %s\n' "${test_name}"
        printf '        Expected pattern: %s\n' "${pattern}"
        printf '        Actual output: %s\n' "${output}" | head -5
    fi
}

assert_file_contains() {
    local test_name="$1"
    local file="$2"
    local pattern="$3"
    TOTAL=$((TOTAL + 1))
    if [ -f "${file}" ] && grep -q "${pattern}" "${file}"; then
        PASSED=$((PASSED + 1))
        printf '  \033[32mPASS\033[0m  %s\n' "${test_name}"
    else
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m  %s\n' "${test_name}"
        if [ -f "${file}" ]; then
            printf '        File contents: %s\n' "$(cat "${file}")"
        else
            printf '        File not found: %s\n' "${file}"
        fi
    fi
}

# ---- Tests ----------------------------------------------------------------
echo ""
echo "Running deploy.sh tests (Grafana)..."
echo ""

# -- help -------------------------------------------------------------------
echo "--- help / usage ---"
setup
assert_output_contains "help shows usage"       "Usage:" help
assert_output_contains "--help shows usage"      "Usage:" --help
assert_output_contains "no args shows usage"     "Usage:"
teardown

# -- start ------------------------------------------------------------------
echo "--- start ---"
setup
assert_success       "start succeeds with Dockerfile in INSTALL_DIR" start
assert_file_contains "start calls docker build"  "${DOCKER_LOG}" "docker build"
assert_file_contains "start calls docker run"    "${DOCKER_LOG}" "docker run"
assert_file_contains "start calls docker exec"   "${DOCKER_LOG}" "docker exec"
teardown

# -- start idempotent (container already exists) ----------------------------
echo "--- start idempotent ---"
setup
# Mock docker ps -a to report existing container
cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "${DOCKER_LOG}"
case "\$1" in
    info)   exit 0 ;;
    build)  exit 0 ;;
    run)    echo "abc123"; exit 0 ;;
    rm)     exit 0 ;;
    ps)
        if [ "\${2:-}" = "-a" ]; then
            echo "test-grafana"
        else
            echo "test-grafana"
        fi
        ;;
    exec)   exit 0 ;;
    volume)
        case "\${2:-}" in
            ls)     echo "test-grafana-data" ;;
            create) exit 0 ;;
        esac
        ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"
assert_success       "start is idempotent (replaces existing)" start
assert_file_contains "idempotent start removes old container" "${DOCKER_LOG}" "docker rm -f"
teardown

# -- start shows connection info --------------------------------------------
echo "--- start output ---"
setup
assert_output_contains "start prints VM IP"            "10.0.0.1"    start
assert_output_contains "start prints port"             "13000"       start
assert_output_contains "start prints health URL"       "api/health"  start
assert_output_contains "start prints datasource hint"  "datasources.yaml" start
teardown

# -- stop -------------------------------------------------------------------
echo "--- stop ---"
setup
assert_success "stop succeeds (no container)" stop
teardown

setup
# Mock: container exists
cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "${DOCKER_LOG}"
case "\$1" in
    info)   exit 0 ;;
    rm)     exit 0 ;;
    ps)     echo "test-grafana" ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"
assert_success       "stop succeeds (container exists)" stop
assert_file_contains "stop calls docker rm"             "${DOCKER_LOG}" "docker rm -f"
teardown

# -- stop idempotent --------------------------------------------------------
echo "--- stop idempotent ---"
setup
assert_success "stop twice is safe" stop
assert_success "stop again is safe" stop
teardown

# -- status -----------------------------------------------------------------
echo "--- status ---"
setup
assert_output_contains "status reports not running" "not running" status
teardown

setup
# Mock: container running
cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    info)   exit 0 ;;
    ps)     echo "test-grafana" ;;
    exec)   exit 0 ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"
assert_output_contains "status reports running"    "running" status
assert_output_contains "status reports health"     "ready"   status
teardown

# -- clean ------------------------------------------------------------------
echo "--- clean ---"
setup
assert_success "clean succeeds" clean
assert_file_contains "clean calls docker rmi" "${DOCKER_LOG}" "docker rmi"
assert_file_contains "clean calls docker volume rm" "${DOCKER_LOG}" "docker volume rm"
teardown

# -- clean idempotent -------------------------------------------------------
echo "--- clean idempotent ---"
setup
assert_success "clean twice is safe" clean
assert_success "clean again is safe" clean
teardown

# -- --from-local -----------------------------------------------------------
echo "--- --from-local ---"
setup
LOCAL_SRC="${TEST_TMP}/local-src"
mkdir -p "${LOCAL_SRC}"
echo "FROM scratch" > "${LOCAL_SRC}/Dockerfile"
echo "[server]" > "${LOCAL_SRC}/grafana.ini"
mkdir -p "${LOCAL_SRC}/provisioning/datasources"
echo "apiVersion: 1" > "${LOCAL_SRC}/provisioning/datasources/datasources.yaml"
mkdir -p "${LOCAL_SRC}/dashboards"
echo "{}" > "${LOCAL_SRC}/dashboards/test.json"
assert_success "start --from-local succeeds" start --from-local "${LOCAL_SRC}"
teardown

setup
LOCAL_SRC="${TEST_TMP}/local-src-repo"
mkdir -p "${LOCAL_SRC}/deploy/grafana"
echo "FROM scratch" > "${LOCAL_SRC}/deploy/grafana/Dockerfile"
echo "[server]" > "${LOCAL_SRC}/deploy/grafana/grafana.ini"
mkdir -p "${LOCAL_SRC}/deploy/grafana/provisioning/datasources"
echo "apiVersion: 1" > "${LOCAL_SRC}/deploy/grafana/provisioning/datasources/datasources.yaml"
mkdir -p "${LOCAL_SRC}/deploy/grafana/dashboards"
echo "{}" > "${LOCAL_SRC}/deploy/grafana/dashboards/test.json"
assert_success "start --from-local (repo root) succeeds" start --from-local "${LOCAL_SRC}"
teardown

setup
assert_failure "start --from-local bad path fails" start --from-local "/nonexistent/path"
teardown

setup
LOCAL_SRC="${TEST_TMP}/local-no-dockerfile"
mkdir -p "${LOCAL_SRC}"
assert_failure "start --from-local no Dockerfile fails" start --from-local "${LOCAL_SRC}"
teardown

# -- --from-git -------------------------------------------------------------
echo "--- --from-git ---"
setup
# acquire_from_git creates INSTALL_DIR via git clone mock, but resolve_deploy_dir
# needs a Dockerfile there. Pre-create it so the start command can proceed.
# The git mock is a no-op, so we set up the directory structure it would create.
mkdir -p "${FAKE_INSTALL}"
echo "FROM scratch" > "${FAKE_INSTALL}/Dockerfile"
assert_success       "start --from-git succeeds"          start --from-git
assert_file_contains "git clone was called"                "${GIT_LOG}" "git clone"
teardown

setup
# Simulate existing .git directory (update path)
mkdir -p "${FAKE_INSTALL}/.git"
echo "FROM scratch" > "${FAKE_INSTALL}/Dockerfile"
run_deploy start --from-git >/dev/null 2>&1 || true
assert_file_contains "existing repo uses git fetch" "${GIT_LOG}" "git -C.*fetch"
teardown

# -- not root ---------------------------------------------------------------
echo "--- root check ---"
setup
cat > "${MOCK_BIN}/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then echo "1000"; else command id "$@"; fi
EOF
chmod +x "${MOCK_BIN}/id"
assert_failure "start fails when not root" start
assert_output_contains "not root shows pbrun hint" "pbrun" start
teardown

# -- no docker --------------------------------------------------------------
echo "--- docker check ---"
setup
rm "${MOCK_BIN}/docker"
assert_failure "start fails without docker" start
teardown

# -- docker daemon not running ----------------------------------------------
echo "--- docker daemon check ---"
setup
cat > "${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    info) exit 1 ;;
    *)    exit 0 ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"
assert_failure       "start fails with daemon stopped" start
assert_output_contains "daemon stopped shows hint"     "systemctl" start
teardown

# -- no git -----------------------------------------------------------------
echo "--- git check ---"
setup
rm "${MOCK_BIN}/git"
assert_failure "start --from-git fails without git" start --from-git
teardown

# -- unknown command --------------------------------------------------------
echo "--- unknown command ---"
setup
assert_failure "unknown command fails" badcommand
teardown

# -- unknown option ---------------------------------------------------------
echo "--- unknown option ---"
setup
assert_failure "unknown option fails" start --bad-flag
teardown

# -- health check timeout ---------------------------------------------------
echo "--- health timeout ---"
setup
# Mock docker exec to always fail (unhealthy)
cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "${DOCKER_LOG}"
case "\$1" in
    info)   exit 0 ;;
    build)  exit 0 ;;
    run)    echo "abc123"; exit 0 ;;
    rm)     exit 0 ;;
    ps)     echo "" ;;
    exec)   exit 1 ;;  # health check fails
    volume) echo "" ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"
assert_failure "start fails on health timeout" start
assert_output_contains "timeout shows error" "did not become ready" start
teardown

# -- logs when not running --------------------------------------------------
echo "--- logs check ---"
setup
assert_failure "logs fails when container not running" logs
teardown

# -- --from-local missing arg -----------------------------------------------
echo "--- arg validation ---"
setup
assert_failure "from-local without path fails" start --from-local
teardown

# ---- Summary --------------------------------------------------------------
echo ""
echo "========================================"
printf "  Total: %d  Passed: %d  Failed: %d\n" "${TOTAL}" "${PASSED}" "${FAILED}"
echo "========================================"
echo ""

if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi

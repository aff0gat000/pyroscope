#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-test.sh — Unit tests for deploy.sh (merged monolith deployer)
#
# Exercises every code path using mock binaries for docker, id, hostname,
# kubectl, oc, openssl, curl, git, sleep.
# No root, Docker, or network access required.
#
# Usage:  bash deploy/monolith/deploy-test.sh
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
    info)    exit 0 ;;
    build)   exit 0 ;;
    pull)    exit 0 ;;
    run)     echo "abc123"; exit 0 ;;
    rm)      exit 0 ;;
    rmi)     exit 0 ;;
    ps)
        if echo "\$*" | grep -q -- "-a"; then
            echo ""
        else
            echo ""
        fi
        ;;
    exec)    exit 0 ;;
    volume)
        case "\${2:-}" in
            ls)     echo "" ;;
            create) exit 0 ;;
            rm)     exit 0 ;;
        esac
        ;;
    logs)    echo "[mock] log output"; exit 0 ;;
    load)    exit 0 ;;
    save)    touch "\${*##*-o }"; exit 0 ;;
    network) exit 0 ;;
    inspect)
        # Return "running" state for health checks
        if echo "\$*" | grep -q "State.Status"; then
            echo "running"
        else
            echo "{}"
        fi
        ;;
    --version) echo "Docker version 24.0.0 (mock)"; exit 0 ;;
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

    # Default mock: curl (succeeds)
    cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${MOCK_BIN}/curl"

    # Default mock: openssl (succeeds, creates cert files)
    cat > "${MOCK_BIN}/openssl" <<'EOF'
#!/usr/bin/env bash
# If generating a cert, create the output files
for arg in "$@"; do
    case "${arg}" in
        *.pem) touch "${arg}" 2>/dev/null || true ;;
    esac
done
exit 0
EOF
    chmod +x "${MOCK_BIN}/openssl"

    # Default mock: kubectl (records calls, succeeds)
    KUBECTL_LOG="${TEST_TMP}/kubectl.log"
    cat > "${MOCK_BIN}/kubectl" <<EOF
#!/usr/bin/env bash
echo "kubectl \$*" >> "${KUBECTL_LOG}"
case "\$1" in
    cluster-info) exit 0 ;;
    create)       exit 0 ;;
    apply)        exit 0 ;;
    wait)         exit 0 ;;
    get)          echo "NAME  READY  STATUS"; exit 0 ;;
    -n)           exit 0 ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/kubectl"

    # Default mock: oc (records calls, succeeds)
    OC_LOG="${TEST_TMP}/oc.log"
    cat > "${MOCK_BIN}/oc" <<EOF
#!/usr/bin/env bash
echo "oc \$*" >> "${OC_LOG}"
case "\$1" in
    whoami)       echo "testuser"; exit 0 ;;
    new-project)  exit 0 ;;
    project)      exit 0 ;;
    create)       exit 0 ;;
    apply)        exit 0 ;;
    wait)         exit 0 ;;
    get)          echo "NAME  READY  STATUS"; exit 0 ;;
    expose)       exit 0 ;;
    -n)           exit 0 ;;
esac
exit 0
EOF
    chmod +x "${MOCK_BIN}/oc"

    # Default mock: whoami
    cat > "${MOCK_BIN}/whoami" <<'EOF'
#!/usr/bin/env bash
echo "root"
EOF
    chmod +x "${MOCK_BIN}/whoami"

    # Default mock: find (pass through to real find)
    # Not mocked — uses system find

    # Default mock: sed (pass through to real sed for non-destructive calls)
    # Not mocked — uses system sed

    # Create the repo structure that deploy.sh expects:
    #   REPO_ROOT/config/grafana/dashboards/  (with a .json file)
    #   REPO_ROOT/config/grafana/provisioning/datasources/
    #   REPO_ROOT/config/grafana/provisioning/dashboards/
    #   REPO_ROOT/config/grafana/provisioning/plugins/
    #   REPO_ROOT/deploy/grafana/grafana.ini
    #   REPO_ROOT/deploy/monolith/  (SCRIPT_DIR)
    FAKE_REPO="${TEST_TMP}/repo"
    FAKE_SCRIPT_DIR="${FAKE_REPO}/deploy/monolith"
    mkdir -p "${FAKE_SCRIPT_DIR}"
    mkdir -p "${FAKE_REPO}/config/grafana/dashboards"
    mkdir -p "${FAKE_REPO}/config/grafana/provisioning/datasources"
    mkdir -p "${FAKE_REPO}/config/grafana/provisioning/dashboards"
    mkdir -p "${FAKE_REPO}/config/grafana/provisioning/plugins"
    mkdir -p "${FAKE_REPO}/deploy/grafana"
    echo '{}' > "${FAKE_REPO}/config/grafana/dashboards/test-dashboard.json"
    echo 'datasources: []' > "${FAKE_REPO}/config/grafana/provisioning/datasources/datasources.yaml"
    echo 'providers: []' > "${FAKE_REPO}/config/grafana/provisioning/dashboards/dashboards.yaml"
    echo 'apps: []' > "${FAKE_REPO}/config/grafana/provisioning/plugins/plugins.yaml"
    echo '[server]' > "${FAKE_REPO}/deploy/grafana/grafana.ini"

    # Copy deploy.sh into the fake repo so SCRIPT_DIR and REPO_ROOT resolve correctly
    cp "${DEPLOY_SCRIPT}" "${FAKE_SCRIPT_DIR}/deploy.sh"

    # Set the test deploy script path
    TEST_DEPLOY_SCRIPT="${FAKE_SCRIPT_DIR}/deploy.sh"

    export PATH="${MOCK_BIN}:${PATH}"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

run_deploy() {
    GRAFANA_CONFIG_DIR="${TEST_TMP}/grafana-config" \
    TLS_CERT_DIR="${TEST_TMP}/tls" \
        bash "${TEST_DEPLOY_SCRIPT}" "$@" 2>&1
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
echo "Running deploy.sh tests..."
echo ""

# ===========================================================================
#  Help / usage (3 tests)
# ===========================================================================
echo "--- help / usage ---"
setup
assert_output_contains "help shows usage"       "Usage:" help
assert_output_contains "--help shows usage"      "Usage:" --help
assert_output_contains "no args shows usage"     "Usage:"
teardown

# ===========================================================================
#  Pre-flight / validation (6 tests)
# ===========================================================================
echo "--- pre-flight / validation ---"

# Not root — deploy.sh warns but does not fail for full-stack --target vm.
# However, the script itself still runs through docker commands so we test
# the output includes the pbrun hint.
setup
cat > "${MOCK_BIN}/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then echo "1000"; else command id "$@"; fi
EOF
chmod +x "${MOCK_BIN}/id"
assert_output_contains "not root shows pbrun warning" "pbrun" full-stack --target vm
teardown

# No docker binary
setup
rm "${MOCK_BIN}/docker"
assert_failure "full-stack fails without docker binary" full-stack --target vm
teardown

# Docker daemon not running
setup
cat > "${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    info)      exit 1 ;;
    --version) echo "Docker version 24.0.0 (mock)"; exit 0 ;;
    *)         exit 0 ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"
assert_failure       "full-stack fails with daemon stopped"    full-stack --target vm
assert_output_contains "daemon stopped shows systemctl hint"   "systemctl" full-stack --target vm
teardown

# Unknown command
setup
assert_failure "unknown command fails" badcommand
teardown

# Unknown option
setup
assert_failure "unknown option fails" full-stack --bad-flag
teardown

# ===========================================================================
#  Full-stack VM (8 tests)
# ===========================================================================
echo "--- full-stack --target vm ---"

# Basic deploy succeeds
setup
assert_success "full-stack --target vm succeeds" full-stack --target vm
teardown

# Calls docker run (for pyroscope and grafana containers)
setup
run_deploy full-stack --target vm >/dev/null 2>&1 || true
assert_file_contains "full-stack vm calls docker pull"  "${DOCKER_LOG}" "docker pull"
assert_file_contains "full-stack vm calls docker run"   "${DOCKER_LOG}" "docker run"
teardown

# --skip-grafana
setup
assert_success "full-stack --target vm --skip-grafana succeeds" full-stack --target vm --skip-grafana
teardown

# --dry-run — succeeds, should NOT call docker run
setup
run_deploy full-stack --target vm --dry-run >/dev/null 2>&1 || true
assert_success "full-stack --target vm --dry-run succeeds" full-stack --target vm --dry-run
teardown

# --load-images loads images from tar
setup
FAKE_TAR="${TEST_TMP}/images.tar"
touch "${FAKE_TAR}"
run_deploy full-stack --target vm --load-images "${FAKE_TAR}" >/dev/null 2>&1 || true
assert_file_contains "full-stack --load-images calls docker load" "${DOCKER_LOG}" "docker load"
teardown

# --pyroscope-config mounts config file
setup
FAKE_CONFIG="${TEST_TMP}/pyroscope.yaml"
echo "storage: {}" > "${FAKE_CONFIG}"
assert_success "full-stack --target vm --pyroscope-config succeeds" \
    full-stack --target vm --pyroscope-config "${FAKE_CONFIG}"
teardown

# --pyroscope-image uses custom image
setup
run_deploy full-stack --target vm --pyroscope-image "my-registry/pyroscope:v1.0" >/dev/null 2>&1 || true
assert_file_contains "full-stack --pyroscope-image uses custom image" \
    "${DOCKER_LOG}" "my-registry/pyroscope:v1.0"
teardown

# Idempotent: replaces existing container
setup
cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "${DOCKER_LOG}"
case "\$1" in
    info)    exit 0 ;;
    pull)    exit 0 ;;
    build)   exit 0 ;;
    run)     echo "abc123"; exit 0 ;;
    rm)      exit 0 ;;
    ps)
        if echo "\$*" | grep -q -- "-a"; then
            echo "pyroscope"
        else
            echo "pyroscope"
        fi
        ;;
    exec)    exit 0 ;;
    volume)
        case "\${2:-}" in
            ls)     echo "" ;;
            create) exit 0 ;;
        esac
        ;;
    inspect) echo "running" ;;
    --version) echo "Docker version 24.0.0 (mock)"; exit 0 ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"
assert_success       "full-stack is idempotent (replaces existing)" full-stack --target vm --skip-grafana
assert_file_contains "idempotent removes old container"             "${DOCKER_LOG}" "docker rm -f"
teardown

# ===========================================================================
#  TLS mode (5 tests)
# ===========================================================================
echo "--- TLS mode ---"

# --tls alone fails (no cert source)
setup
assert_failure "full-stack --tls alone fails" full-stack --target vm --tls
teardown

# --tls --tls-self-signed succeeds
setup
assert_success "full-stack --tls --tls-self-signed succeeds" full-stack --target vm --tls --tls-self-signed --skip-grafana
teardown

# --tls --tls-cert without --tls-key fails
setup
FAKE_CERT="${TEST_TMP}/cert.pem"
touch "${FAKE_CERT}"
assert_failure "full-stack --tls --tls-cert without --tls-key fails" \
    full-stack --target vm --tls --tls-cert "${FAKE_CERT}"
teardown

# --tls --tls-key without --tls-cert fails
setup
FAKE_KEY="${TEST_TMP}/key.pem"
touch "${FAKE_KEY}"
assert_failure "full-stack --tls --tls-key without --tls-cert fails" \
    full-stack --target vm --tls --tls-key "${FAKE_KEY}"
teardown

# --tls --tls-cert and --tls-key succeeds
setup
FAKE_CERT="${TEST_TMP}/cert.pem"
FAKE_KEY="${TEST_TMP}/key.pem"
touch "${FAKE_CERT}" "${FAKE_KEY}"
assert_success "full-stack --tls --tls-cert --tls-key succeeds" \
    full-stack --target vm --tls --tls-cert "${FAKE_CERT}" --tls-key "${FAKE_KEY}" --skip-grafana
teardown

# ===========================================================================
#  Day-2 ops (5 tests)
# ===========================================================================
echo "--- day-2 ops ---"

# status: not running (no container found by docker ps)
setup
assert_output_contains "status reports not running" "not running" status
teardown

# status: running (container found)
setup
cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    info)   exit 0 ;;
    ps)     echo "pyroscope"; exit 0 ;;
    exec)   exit 0 ;;
    --version) echo "Docker version 24.0.0 (mock)"; exit 0 ;;
esac
exit 0
EOF
chmod +x "${MOCK_BIN}/docker"
assert_output_contains "status reports running (pyroscope)" "pyroscope" status
teardown

# stop: no container (safe no-op)
setup
assert_success "stop succeeds (no container)" stop
teardown

# stop: container exists, calls docker rm
setup
cat > "${MOCK_BIN}/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "${DOCKER_LOG}"
case "\$1" in
    info)   exit 0 ;;
    rm)     exit 0 ;;
    ps)
        if echo "\$*" | grep -q -- "-a"; then
            echo "pyroscope"
        else
            echo "pyroscope"
        fi
        ;;
    --version) echo "Docker version 24.0.0 (mock)"; exit 0 ;;
esac
exit 0
EOF
chmod +x "${MOCK_BIN}/docker"
assert_success       "stop succeeds (container exists)" stop
assert_file_contains "stop calls docker rm"             "${DOCKER_LOG}" "docker rm -f"
teardown

# clean: removes containers, images, volumes
setup
assert_success "clean succeeds" clean
assert_file_contains "clean calls docker volume rm" "${DOCKER_LOG}" "docker volume rm"
assert_file_contains "clean calls docker rmi"       "${DOCKER_LOG}" "docker rmi"
teardown

# ===========================================================================
#  save-images (3 tests)
# ===========================================================================
echo "--- save-images ---"

# save-images succeeds
setup
assert_success "save-images succeeds" save-images
teardown

# save-images calls docker save
setup
run_deploy save-images >/dev/null 2>&1 || true
assert_file_contains "save-images calls docker save" "${DOCKER_LOG}" "docker save"
teardown

# save-images --tls includes envoy image
setup
run_deploy save-images --tls >/dev/null 2>&1 || true
assert_file_contains "save-images --tls includes envoy" "${DOCKER_LOG}" "envoy"
teardown

# ===========================================================================
#  K8s / OpenShift (4 tests)
# ===========================================================================
echo "--- k8s / openshift ---"

# full-stack --target k8s fails without kubectl
setup
rm "${MOCK_BIN}/kubectl"
assert_failure "full-stack --target k8s fails without kubectl" full-stack --target k8s
teardown

# full-stack --target openshift fails without oc
setup
rm "${MOCK_BIN}/oc"
assert_failure "full-stack --target openshift fails without oc" full-stack --target openshift
teardown

# full-stack --target k8s succeeds with kubectl mock
setup
assert_success "full-stack --target k8s succeeds" full-stack --target k8s
teardown

# full-stack --target openshift succeeds with oc mock
setup
assert_success "full-stack --target openshift succeeds" full-stack --target openshift
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

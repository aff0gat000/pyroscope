#!/bin/bash
# ------------------------------------------------------------------
# Pyroscope Helm Chart Test Suite
#
# Offline validation of the unified Helm chart using only
# `helm lint` and `helm template`. No cluster access required.
#
# Prerequisites: helm 3.x on PATH
# Usage:         bash deploy/helm/pyroscope/chart-test.sh
#                (from the repo root, or from any directory)
#
# The script exits 0 if all tests pass, 1 if any test fails.
# Failed test names are printed at the bottom for triage.
# ------------------------------------------------------------------
set -euo pipefail

CHART="$(cd "$(dirname "$0")" && pwd)"
EXAMPLES="$CHART/examples"
PASS=0
FAIL=0
TESTS=()

assert() {
    local desc="$1" ; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc"
        TESTS+=("$desc")
    fi
}

assert_output() {
    local desc="$1" expected="$2" ; shift 2
    local output
    output=$("$@" 2>&1)
    if echo "$output" | grep -qF -- "$expected"; then
        PASS=$((PASS+1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc (expected: $expected)"
        TESTS+=("$desc")
    fi
}

assert_no_output() {
    local desc="$1" unexpected="$2" ; shift 2
    local output
    output=$("$@" 2>&1)
    if echo "$output" | grep -qF -- "$unexpected"; then
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc (found unexpected: $unexpected)"
        TESTS+=("$desc")
    else
        PASS=$((PASS+1))
        echo "  PASS: $desc"
    fi
}

count_kind() {
    local kind="$1" ; shift
    helm template test "$CHART" "$@" 2>&1 | grep "^kind: $kind$" | wc -l
}

echo "=== 1. HELM LINT ==="
assert "lint: default values"               helm lint "$CHART"
assert "lint: monolith-same-namespace"       helm lint "$CHART" -f "$EXAMPLES/monolith-same-namespace.yaml"
assert "lint: monolith-dedicated-namespace"  helm lint "$CHART" -f "$EXAMPLES/monolith-dedicated-namespace.yaml"
assert "lint: microservices-openshift"       helm lint "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"
assert "lint: microservices-kubernetes"       helm lint "$CHART" -f "$EXAMPLES/microservices-kubernetes.yaml"

echo ""
echo "=== 2. MONOLITH RESOURCE COUNTS ==="
assert "monolith: 1 ConfigMap"          test "$(count_kind ConfigMap)" -eq 1
assert "monolith: 1 Deployment"         test "$(count_kind Deployment)" -eq 1
assert "monolith: 1 PVC"               test "$(count_kind PersistentVolumeClaim)" -eq 1
assert "monolith: 1 Service"           test "$(count_kind Service)" -eq 1
assert "monolith: 1 Route"             test "$(count_kind Route)" -eq 1
assert "monolith: 0 NetworkPolicy"     test "$(count_kind NetworkPolicy)" -eq 0
assert "monolith: 0 Ingress"           test "$(count_kind Ingress)" -eq 0

echo ""
echo "=== 3. MONOLITH DEDICATED NS ==="
assert "monolith-dedicated: +NetworkPolicy"  test "$(count_kind NetworkPolicy -f $EXAMPLES/monolith-dedicated-namespace.yaml)" -eq 1

echo ""
echo "=== 4. MICROSERVICES OCP COUNTS ==="
assert "micro-ocp: 7 Deployments"   test "$(count_kind Deployment -f $EXAMPLES/microservices-openshift.yaml)" -eq 7
assert "micro-ocp: 3 Services"      test "$(count_kind Service -f $EXAMPLES/microservices-openshift.yaml)" -eq 3
assert "micro-ocp: 1 Route"         test "$(count_kind Route -f $EXAMPLES/microservices-openshift.yaml)" -eq 1
assert "micro-ocp: 1 NetworkPolicy" test "$(count_kind NetworkPolicy -f $EXAMPLES/microservices-openshift.yaml)" -eq 1
assert "micro-ocp: 0 Ingress"       test "$(count_kind Ingress -f $EXAMPLES/microservices-openshift.yaml)" -eq 0

echo ""
echo "=== 5. MICROSERVICES K8S COUNTS ==="
assert "micro-k8s: 7 Deployments"   test "$(count_kind Deployment -f $EXAMPLES/microservices-kubernetes.yaml)" -eq 7
assert "micro-k8s: 3 Services"      test "$(count_kind Service -f $EXAMPLES/microservices-kubernetes.yaml)" -eq 3
assert "micro-k8s: 1 Ingress"       test "$(count_kind Ingress -f $EXAMPLES/microservices-kubernetes.yaml)" -eq 1
assert "micro-k8s: 0 Route"         test "$(count_kind Route -f $EXAMPLES/microservices-kubernetes.yaml)" -eq 0
assert "micro-k8s: 0 NetworkPolicy"  test "$(count_kind NetworkPolicy -f $EXAMPLES/microservices-kubernetes.yaml)" -eq 0

echo ""
echo "=== 6. CONFIGMAP CONTENT ==="
assert_no_output "monolith: no memberlist"           "memberlist"  helm template test "$CHART"
assert_output    "micro: memberlist headless svc"     "test-pyroscope-ingester-headless:7946"  helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"
assert_no_output "micro: no StatefulSet DNS"          "ingester-0"  helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"
assert_output    "monolith: dir /data"                "dir: /data"  helm template test "$CHART"
assert_output    "micro: dir /data/pyroscope"         "dir: /data/pyroscope"  helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"
assert_output    "monolith: self_profiling disabled"  "disable_push: true"  helm template test "$CHART"
assert_output    "micro: self_profiling disabled"     "disable_push: true"  helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"

echo ""
echo "=== 7. PVC ACCESS MODES ==="
assert_output    "monolith: RWO"            "ReadWriteOnce"   helm template test "$CHART"
assert_no_output "monolith: not RWX"        "ReadWriteMany"   helm template test "$CHART"
assert_output    "micro: RWO (WAL only)"    "ReadWriteOnce"   helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"
assert_output    "micro: s3 endpoint"       "minio"           helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"

echo ""
echo "=== 8. HEADLESS SERVICE BUG FIX ==="
assert_output "headless svc exists"         "test-pyroscope-ingester-headless"  helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"
assert_output "headless clusterIP: None"    "clusterIP: None"   helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"
assert_output "headless memberlist port"    "port: 7946"        helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml"

echo ""
echo "=== 9. ROUTE TARGETS ==="
MONO_ROUTE=$(helm template test "$CHART" 2>&1 | sed -n '/kind: Route/,/^---/p')
assert_output    "monolith route -> test-pyroscope"              "name: test-pyroscope"               echo "$MONO_ROUTE"
MICRO_ROUTE=$(helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml" 2>&1 | sed -n '/kind: Route/,/^---/p')
assert_output    "micro route -> query-frontend"                 "name: test-pyroscope-query-frontend" echo "$MICRO_ROUTE"

echo ""
echo "=== 10. INGRESS TARGETS ==="
K8S_ING=$(helm template test "$CHART" -f "$EXAMPLES/microservices-kubernetes.yaml" 2>&1 | sed -n '/kind: Ingress/,/^---/p')
assert_output "k8s ingress -> query-frontend"   "name: test-pyroscope-query-frontend"  echo "$K8S_ING"

echo ""
echo "=== 11. NETWORK POLICY ==="
NP=$(helm template test "$CHART" -f "$EXAMPLES/monolith-dedicated-namespace.yaml" 2>&1 | sed -n '/kind: NetworkPolicy/,/^---/p')
assert_output "allows port 4040"        "port: 4040"           echo "$NP"
assert_output "same-ns podSelector"     "podSelector: {}"      echo "$NP"
assert_output "has namespaceSelector"   "namespaceSelector"    echo "$NP"

echo ""
echo "=== 12. GRAFANA DATASOURCE ==="
assert "disabled by default"  test "$(helm template test "$CHART" 2>&1 | grep -c 'grafana-datasource')" -eq 0

DS_ON=$(helm template test "$CHART" --set grafana.datasource.enabled=true --set grafana.location=same-namespace 2>&1)
assert_output "enabled: creates configmap"      "grafana-datasource"     echo "$DS_ON"
assert_output "enabled: uid pyroscope-ds"       "uid: pyroscope-ds"      echo "$DS_ON"
assert_output "enabled: sidecar label"          "grafana_datasource"     echo "$DS_ON"
assert_output "same-ns: short DNS"              "http://test-pyroscope:4040"  echo "$DS_ON"

DS_DIFF=$(helm template test "$CHART" --namespace mon --set grafana.datasource.enabled=true --set grafana.location=different-namespace 2>&1)
assert_output "diff-ns: FQDN"  "http://test-pyroscope.mon.svc.cluster.local:4040"  echo "$DS_DIFF"

echo ""
echo "=== 13. DEPLOYMENT DETAILS ==="
MONO_DEP=$(helm template test "$CHART" 2>&1 | sed -n '/kind: Deployment/,/^---/p')
assert_output    "monolith: image 1.18.0"      "grafana/pyroscope:1.18.0"  echo "$MONO_DEP"
assert_output    "monolith: mounts /data"       "mountPath: /data"          echo "$MONO_DEP"
assert_no_output "monolith: no -target"         "-target="                  echo "$MONO_DEP"
assert_output    "monolith: readiness /ready"   "path: /ready"              echo "$MONO_DEP"

MICRO_ALL=$(helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml" 2>&1)
assert_output "distributor: -target=distributor"   "-target=distributor"     echo "$MICRO_ALL"
assert_output "ingester: -target=ingester"         "-target=ingester"        echo "$MICRO_ALL"
assert_output "querier: -target=querier"           "-target=querier"         echo "$MICRO_ALL"
assert_output "compactor: -target=compactor"       "-target=compactor"       echo "$MICRO_ALL"
assert_output "store-gateway: -target=store-gateway" "-target=store-gateway" echo "$MICRO_ALL"
assert_output "query-frontend: -target=query-frontend" "-target=query-frontend" echo "$MICRO_ALL"
assert_output "query-scheduler: -target=query-scheduler" "-target=query-scheduler" echo "$MICRO_ALL"

MICRO_ING=$(helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml" 2>&1 | sed -n '/name: test-pyroscope-ingester$/,/^---/p')
assert_output "ingester: podAntiAffinity"       "podAntiAffinity"          echo "$MICRO_ING"
assert_output "ingester: hostname topology"     "kubernetes.io/hostname"   echo "$MICRO_ING"

echo ""
echo "=== 14. LABELS ==="
ALL=$(helm template test "$CHART" 2>&1)
assert_output "part-of: pyroscope"   "app.kubernetes.io/part-of: pyroscope"  echo "$ALL"
assert_output "chart: pyroscope-1.0.0" "helm.sh/chart: pyroscope-1.0.0"     echo "$ALL"
assert_output "managed-by: Helm"     "app.kubernetes.io/managed-by: Helm"    echo "$ALL"

echo ""
echo "=== 15. IDEMPOTENCY (determinism) ==="
R1=$(helm template test "$CHART" -f "$EXAMPLES/monolith-same-namespace.yaml" --namespace prod 2>&1)
R2=$(helm template test "$CHART" -f "$EXAMPLES/monolith-same-namespace.yaml" --namespace prod 2>&1)
assert "monolith: deterministic output" test "$R1" = "$R2"

R3=$(helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml" --namespace prod 2>&1)
R4=$(helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml" --namespace prod 2>&1)
assert "microservices: deterministic output" test "$R3" = "$R4"

echo ""
echo "=== 16. OVERRIDE TESTS ==="
assert_output    "override: image.tag=1.19.0"   "grafana/pyroscope:1.19.0"  helm template test "$CHART" --set image.tag=1.19.0
assert_output    "override: storage.size=100Gi"  "storage: 100Gi"            helm template test "$CHART" --set storage.size=100Gi
assert           "override: route disabled"       test "$(count_kind Route --set route.enabled=false)" -eq 0
assert_output    "override: ingester replicas=5" "replicas: 5"               helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml" --set ingester.replicas=5
assert_output    "override: fullnameOverride"    "name: my-pyro"             helm template test "$CHART" --set fullnameOverride=my-pyro

echo ""
echo "=== 17. MUTUAL EXCLUSION ==="
MONO_ONLY=$(helm template test "$CHART" 2>&1)
assert_no_output "monolith: no distributor"  "test-pyroscope-distributor"  echo "$MONO_ONLY"
assert_no_output "monolith: no ingester"     "test-pyroscope-ingester"     echo "$MONO_ONLY"
assert_no_output "monolith: no -target="     "-target="                    echo "$MONO_ONLY"

MICRO_ONLY=$(helm template test "$CHART" -f "$EXAMPLES/microservices-openshift.yaml" 2>&1)
assert_no_output "micro: no component=monolith"  "component: monolith"    echo "$MICRO_ONLY"

echo ""
echo "========================================"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "========================================"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "  Failed tests:"
    for t in "${TESTS[@]}"; do
        echo "    - $t"
    done
    exit 1
fi

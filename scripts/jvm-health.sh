#!/usr/bin/env bash
set -euo pipefail

# Identifies problematic JVMs across all bank services by checking key health
# indicators from Prometheus. Flags services exceeding thresholds and suggests
# Pyroscope queries for root-cause analysis.
#
# Usage:
#   bash scripts/jvm-health.sh              # check all services
#   bash scripts/jvm-health.sh --json       # output as JSON
#
# Requires: curl, python3, running Prometheus + Pyroscope instances

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

PROMETHEUS_URL="http://localhost:${PROMETHEUS_PORT:-9090}"
PYROSCOPE_URL="http://localhost:${PYROSCOPE_PORT:-4040}"
JSON_MODE=0

for arg in "$@"; do
  case "$arg" in
    --json) JSON_MODE=1 ;;
  esac
done

# Verify Prometheus is reachable
if ! curl -sf "$PROMETHEUS_URL/-/ready" > /dev/null 2>&1; then
  echo "ERROR: Cannot reach Prometheus at $PROMETHEUS_URL"
  echo "Make sure the stack is running: bash scripts/run.sh"
  exit 1
fi

# Python script that queries Prometheus and evaluates JVM health
HEALTH_SCRIPT='
import json, sys, urllib.request, urllib.error

prometheus = sys.argv[1]
pyroscope = sys.argv[2]
json_mode = sys.argv[3] == "1"

def prom_query(expr):
    """Query Prometheus and return list of {metric, value} results."""
    url = f"{prometheus}/api/v1/query?query={urllib.parse.quote(expr)}"
    try:
        resp = urllib.request.urlopen(url, timeout=5)
        data = json.loads(resp.read())
        return data.get("data", {}).get("result", [])
    except Exception:
        return []

def get_instance_value(results):
    """Extract {instance: float_value} from Prometheus results."""
    out = {}
    for r in results:
        inst = r["metric"].get("instance", "unknown")
        # Normalize instance to service name
        svc = inst.split(":")[0]
        val = float(r["value"][1])
        out[svc] = val
    return out

# Service name mapping (container name -> Pyroscope application name)
SVC_MAP = {
    "api-gateway": "bank-api-gateway",
    "order-service": "bank-order-service",
    "payment-service": "bank-payment-service",
    "fraud-service": "bank-fraud-service",
    "account-service": "bank-account-service",
    "loan-service": "bank-loan-service",
    "notification-service": "bank-notification-service",
}

# Thresholds
THRESHOLDS = {
    "cpu_rate":       {"warn": 0.5, "crit": 0.8, "unit": "", "label": "CPU usage (rate)"},
    "heap_pct":       {"warn": 0.70, "crit": 0.85, "unit": "%", "label": "Heap utilization"},
    "gc_rate":        {"warn": 0.03, "crit": 0.10, "unit": "s/s", "label": "GC time rate"},
    "threads":        {"warn": 50, "crit": 100, "unit": "", "label": "Live threads"},
}

# Collect metrics
cpu_rate = get_instance_value(prom_query("rate(process_cpu_seconds_total{job=\"jvm\"}[2m])"))
heap_used = get_instance_value(prom_query("jvm_memory_used_bytes{job=\"jvm\", area=\"heap\"}"))
heap_max = get_instance_value(prom_query("jvm_memory_max_bytes{job=\"jvm\", area=\"heap\"}"))
gc_rate = get_instance_value(prom_query("rate(jvm_gc_collection_seconds_sum{job=\"jvm\"}[2m])"))
threads = get_instance_value(prom_query("jvm_threads_current{job=\"jvm\"}"))

heap_pct = {}
for svc in heap_used:
    if svc in heap_max and heap_max[svc] > 0:
        heap_pct[svc] = heap_used[svc] / heap_max[svc]

# All known services
all_svcs = sorted(set(list(cpu_rate.keys()) + list(heap_pct.keys()) + list(gc_rate.keys()) + list(threads.keys())))

if not all_svcs:
    print("ERROR: No JVM metrics found in Prometheus.")
    print("Make sure services are running and load has been generated.")
    sys.exit(1)

# Evaluate each service
results = []
for svc in all_svcs:
    issues = []
    metrics = {}

    # CPU
    cpu = cpu_rate.get(svc, 0)
    metrics["cpu_rate"] = round(cpu, 3)
    t = THRESHOLDS["cpu_rate"]
    if cpu >= t["crit"]:
        issues.append(("CRITICAL", f"CPU {cpu:.1%} >= {t['crit']:.0%}"))
    elif cpu >= t["warn"]:
        issues.append(("WARNING", f"CPU {cpu:.1%} >= {t['warn']:.0%}"))

    # Heap
    hp = heap_pct.get(svc, 0)
    metrics["heap_pct"] = round(hp, 3)
    metrics["heap_used_mb"] = round(heap_used.get(svc, 0) / 1024 / 1024, 1)
    metrics["heap_max_mb"] = round(heap_max.get(svc, 0) / 1024 / 1024, 1)
    t = THRESHOLDS["heap_pct"]
    if hp >= t["crit"]:
        issues.append(("CRITICAL", f"Heap {hp:.1%} >= {t['crit']:.0%}"))
    elif hp >= t["warn"]:
        issues.append(("WARNING", f"Heap {hp:.1%} >= {t['warn']:.0%}"))

    # GC
    gc = gc_rate.get(svc, 0)
    metrics["gc_rate"] = round(gc, 4)
    t = THRESHOLDS["gc_rate"]
    if gc >= t["crit"]:
        issues.append(("CRITICAL", f"GC {gc:.3f}s/s >= {t['crit']}s/s"))
    elif gc >= t["warn"]:
        issues.append(("WARNING", f"GC {gc:.3f}s/s >= {t['warn']}s/s"))

    # Threads
    th = threads.get(svc, 0)
    metrics["threads"] = int(th)
    t = THRESHOLDS["threads"]
    if th >= t["crit"]:
        issues.append(("CRITICAL", f"Threads {int(th)} >= {t['crit']}"))
    elif th >= t["warn"]:
        issues.append(("WARNING", f"Threads {int(th)} >= {t['warn']}"))

    severity = "OK"
    if any(s == "CRITICAL" for s, _ in issues):
        severity = "CRITICAL"
    elif any(s == "WARNING" for s, _ in issues):
        severity = "WARNING"

    pyro_name = SVC_MAP.get(svc, svc)
    results.append({
        "service": svc,
        "pyroscope_name": pyro_name,
        "severity": severity,
        "metrics": metrics,
        "issues": issues,
    })

# Sort: CRITICAL first, then WARNING, then OK
order = {"CRITICAL": 0, "WARNING": 1, "OK": 2}
results.sort(key=lambda r: (order.get(r["severity"], 9), r["service"]))

if json_mode:
    print(json.dumps(results, indent=2))
    sys.exit(0)

# Human-readable output
print("")
print("=" * 72)
print("  JVM Health Check — All Bank Services")
print("=" * 72)

for r in results:
    svc = r["service"]
    sev = r["severity"]
    m = r["metrics"]

    if sev == "CRITICAL":
        badge = "!! CRITICAL"
    elif sev == "WARNING":
        badge = "!  WARNING "
    else:
        badge = "   OK      "

    print("")
    print(f"  [{badge}] {svc}")
    print(f"             CPU: {m['cpu_rate']:.1%}    Heap: {m['heap_used_mb']:.0f}/{m['heap_max_mb']:.0f} MB ({m['heap_pct']:.1%})    GC: {m['gc_rate']:.4f} s/s    Threads: {m['threads']}")

    if r["issues"]:
        for severity, msg in r["issues"]:
            print(f"             -> {msg}")
        print(f"             Investigate: bash scripts/top-functions.sh cpu {svc}")
        print(f"             Pyroscope:   {pyroscope} -> {r['pyroscope_name']}")

print("")
print("-" * 72)

crits = sum(1 for r in results if r["severity"] == "CRITICAL")
warns = sum(1 for r in results if r["severity"] == "WARNING")
oks = sum(1 for r in results if r["severity"] == "OK")

print(f"  Summary: {len(results)} services — {crits} critical, {warns} warning, {oks} healthy")

if crits > 0 or warns > 0:
    print("")
    print("  Next steps:")
    print("    1. Run: bash scripts/top-functions.sh cpu    # find CPU hotspots")
    print("    2. Run: bash scripts/top-functions.sh memory # find allocation hotspots")
    print("    3. Open Grafana JVM Deep Dive dashboard for detailed metrics")
    print("    4. Open Pyroscope flame graphs for root-cause analysis")

print("")
'

python3 -c "$HEALTH_SCRIPT" "$PROMETHEUS_URL" "$PYROSCOPE_URL" "$JSON_MODE"

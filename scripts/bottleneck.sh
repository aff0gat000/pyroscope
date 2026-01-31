#!/usr/bin/env bash
set -euo pipefail

# Automated bottleneck finder — correlates JVM health, HTTP latency,
# and profiling hotspots to output a root-cause summary per service.
#
# Goal: reduce MTTR by answering "what's wrong and where" in one command.
#
# Usage:
#   bash scripts/bottleneck.sh                         # all services
#   bash scripts/bottleneck.sh --service bank-payment-service  # one service
#   bash scripts/bottleneck.sh --json                  # machine-readable
#   bash scripts/bottleneck.sh --threshold cpu=0.3     # custom thresholds
#
# Output: per-service verdict (CPU-bound, GC-bound, lock-bound, I/O-bound,
# healthy) with the top offending function and recommended action.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

PROMETHEUS_URL="http://localhost:${PROMETHEUS_PORT:-9090}"
PYROSCOPE_URL="http://localhost:${PYROSCOPE_PORT:-4040}"
JSON_MODE=0
SERVICE_FILTER=""
THRESHOLDS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1 ;;
    --service)
      shift
      SERVICE_FILTER="${1:?--service requires a service name}"
      ;;
    --threshold)
      shift
      THRESHOLDS="${THRESHOLDS} ${1:?--threshold requires key=value}"
      ;;
    *)
      echo "Usage: bash scripts/bottleneck.sh [--json] [--service bank-SERVICE] [--threshold cpu=0.3]"
      exit 1
      ;;
  esac
  shift
done

# Verify stack is reachable
PROM_OK=0
PYRO_OK=0
if curl -sf "$PROMETHEUS_URL/-/ready" > /dev/null 2>&1; then PROM_OK=1; fi
if curl -sf "$PYROSCOPE_URL/ready" > /dev/null 2>&1; then PYRO_OK=1; fi

if [ $PROM_OK -eq 0 ] && [ $PYRO_OK -eq 0 ]; then
  echo "ERROR: Cannot reach Prometheus ($PROMETHEUS_URL) or Pyroscope ($PYROSCOPE_URL)"
  echo "Make sure the stack is running: bash scripts/run.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# Python analysis engine
# ---------------------------------------------------------------------------
ANALYSIS_SCRIPT='
import json, sys, urllib.request, urllib.parse

prometheus = sys.argv[1]
pyroscope = sys.argv[2]
prom_ok = sys.argv[3] == "1"
pyro_ok = sys.argv[4] == "1"
json_mode = sys.argv[5] == "1"
service_filter = sys.argv[6]
threshold_args = sys.argv[7]
from datetime import datetime

# Parse custom thresholds
THRESHOLDS = {
    "cpu": 0.3,        # CPU rate above which = CPU-bound
    "heap_pct": 0.75,  # heap utilization above which = memory pressure
    "gc": 0.03,        # GC seconds/second above which = GC-bound
    "threads": 60,     # threads above which = possible contention
    "err_pct": 2.0,    # error % above which = error concern
    "latency_ms": 500, # avg latency above which = latency concern
}
for tok in threshold_args.strip().split():
    if "=" in tok:
        k, v = tok.split("=", 1)
        if k in THRESHOLDS:
            THRESHOLDS[k] = float(v)

def prom_query(expr):
    if not prom_ok: return []
    url = f"{prometheus}/api/v1/query?query={urllib.parse.quote(expr)}"
    try:
        resp = urllib.request.urlopen(url, timeout=10)
        return json.loads(resp.read()).get("data", {}).get("result", [])
    except Exception:
        return []

def prom_instant(expr):
    out = {}
    for r in prom_query(expr):
        inst = r["metric"].get("instance", "unknown").split(":")[0]
        out[inst] = float(r["value"][1])
    return out

def pyro_top(svc, profile_id, n=3):
    if not pyro_ok: return []
    query = f"{profile_id}{{service_name=\"{svc}\"}}"
    url = f"{pyroscope}/pyroscope/render?query={urllib.parse.quote(query)}&from=now-1h&until=now&format=json"
    try:
        resp = urllib.request.urlopen(url, timeout=10)
        data = json.loads(resp.read())
    except Exception:
        return []
    fb = data.get("flamebearer", {})
    names = fb.get("names", [])
    levels = fb.get("levels", [])
    total = fb.get("numTicks", 0)
    if total == 0: return []
    self_map = {}
    for level in levels:
        i = 0
        while i + 3 < len(level):
            idx = level[i + 3]
            val = level[i + 2]
            if idx < len(names) and val > 0:
                self_map[names[idx]] = self_map.get(names[idx], 0) + val
            i += 4
    top = sorted(self_map.items(), key=lambda x: -x[1])[:n]
    return [{"function": name.replace("/", "."), "self_pct": round(val / total * 100, 1)} for name, val in top]

SVC_MAP = {
    "api-gateway": "bank-api-gateway",
    "order-service": "bank-order-service",
    "payment-service": "bank-payment-service",
    "fraud-service": "bank-fraud-service",
    "account-service": "bank-account-service",
    "loan-service": "bank-loan-service",
    "notification-service": "bank-notification-service",
}
REVERSE_MAP = {v: k for k, v in SVC_MAP.items()}

# Collect metrics
cpu = prom_instant("rate(process_cpu_seconds_total{job=\"jvm\"}[2m])")
heap_used = prom_instant("jvm_memory_used_bytes{job=\"jvm\", area=\"heap\"}")
heap_max = prom_instant("jvm_memory_max_bytes{job=\"jvm\", area=\"heap\"}")
gc = prom_instant("rate(jvm_gc_collection_seconds_sum{job=\"jvm\"}[2m])")
threads = prom_instant("jvm_threads_current{job=\"jvm\"}")
req_rate = prom_instant("sum by (instance) (rate(vertx_http_server_requests_total{job=\"vertx-apps\"}[2m]))")
err_rate = prom_instant("sum by (instance) (rate(vertx_http_server_requests_total{job=\"vertx-apps\", code=~\"5..\"}[2m]))")
lat_sum = prom_instant("sum by (instance) (rate(vertx_http_server_response_time_seconds_sum{job=\"vertx-apps\"}[2m]))")
lat_count = prom_instant("sum by (instance) (rate(vertx_http_server_response_time_seconds_count{job=\"vertx-apps\"}[2m]))")

services = sorted(set(cpu.keys()))
if service_filter:
    container = REVERSE_MAP.get(service_filter, service_filter)
    services = [s for s in services if s == container]

results = []
for svc in services:
    pyro_name = SVC_MAP.get(svc, svc)
    c = cpu.get(svc, 0)
    hu = heap_used.get(svc, 0)
    hm = heap_max.get(svc, 0)
    hp = hu / hm if hm > 0 else 0
    g = gc.get(svc, 0)
    t = int(threads.get(svc, 0))

    inst = f"{svc}:8080"
    rr = req_rate.get(inst, req_rate.get(svc, 0))
    er = err_rate.get(inst, err_rate.get(svc, 0))
    ls = lat_sum.get(inst, lat_sum.get(svc, 0))
    lc = lat_count.get(inst, lat_count.get(svc, 0))
    avg_lat = (ls / lc * 1000) if lc > 0 else 0
    err_pct = (er / rr * 100) if rr > 0 else 0

    # Get profiles
    cpu_top = pyro_top(pyro_name, "process_cpu:cpu:nanoseconds:cpu:nanoseconds")
    mem_top = pyro_top(pyro_name, "memory:alloc_in_new_tlab_bytes:bytes:space:bytes")
    mutex_top = pyro_top(pyro_name, "mutex:contentions:count:mutex:count")

    # Classify bottleneck
    signals = []
    if c >= THRESHOLDS["cpu"]:
        signals.append(("cpu-bound", c, cpu_top))
    if g >= THRESHOLDS["gc"]:
        signals.append(("gc-bound", g, mem_top))
    if hp >= THRESHOLDS["heap_pct"]:
        signals.append(("memory-pressure", hp, mem_top))
    if mutex_top and mutex_top[0]["self_pct"] > 5:
        signals.append(("lock-bound", mutex_top[0]["self_pct"], mutex_top))
    if avg_lat > THRESHOLDS["latency_ms"] and not signals:
        signals.append(("io-bound", avg_lat, []))

    if not signals:
        verdict = "healthy"
        severity = "ok"
        primary_function = None
        action = "No action needed"
    else:
        # Pick the dominant signal
        primary = signals[0]
        verdict = primary[0]
        severity = "critical" if c >= 0.8 or hp >= 0.85 or g >= 0.1 else "warning"
        funcs = primary[2]
        primary_function = funcs[0]["function"] if funcs else None

        # Generate action
        actions = {
            "cpu-bound": f"Optimize {primary_function or 'top CPU function'} — see CPU flame graph in Pyroscope",
            "gc-bound": f"Reduce allocations in {(mem_top[0]['function'] if mem_top else 'top allocator')} — GC rate {g:.3f} s/s",
            "memory-pressure": f"Heap at {hp:.0%} — check for leaks in allocation flame graph, consider increasing heap",
            "lock-bound": f"Reduce lock scope in {primary_function or 'contended method'} — see mutex flame graph",
            "io-bound": f"Avg latency {avg_lat:.0f}ms with low CPU — check downstream dependencies, connection pools, timeouts",
        }
        action = actions.get(verdict, "Investigate with: bash scripts/diagnose.sh --service " + pyro_name)

    results.append({
        "service": svc,
        "pyroscope_name": pyro_name,
        "verdict": verdict,
        "severity": severity,
        "metrics": {
            "cpu_rate": round(c, 3),
            "heap_pct": round(hp, 3),
            "gc_rate": round(g, 4),
            "threads": t,
            "req_per_sec": round(rr, 1),
            "err_pct": round(err_pct, 1),
            "avg_latency_ms": round(avg_lat, 1),
        },
        "top_cpu": cpu_top[:1],
        "top_alloc": mem_top[:1],
        "top_mutex": mutex_top[:1],
        "primary_function": primary_function,
        "action": action,
    })

# Sort: critical first, then warning, then ok
order = {"critical": 0, "warning": 1, "ok": 2}
results.sort(key=lambda r: (order.get(r["severity"], 9), r["service"]))

report = {
    "timestamp": datetime.now().isoformat(timespec="seconds"),
    "thresholds": THRESHOLDS,
    "services": results,
    "summary": {
        "total": len(results),
        "critical": sum(1 for r in results if r["severity"] == "critical"),
        "warning": sum(1 for r in results if r["severity"] == "warning"),
        "healthy": sum(1 for r in results if r["verdict"] == "healthy"),
    },
}

if json_mode:
    print(json.dumps(report, indent=2))
    sys.exit(0)

# Human-readable output
W = 80
ICONS = {"critical": "!!!", "warning": " ! ", "ok": " . "}
COLORS = {"critical": "\033[91m", "warning": "\033[93m", "ok": "\033[92m"}
RESET = "\033[0m"

print()
print("=" * W)
print(f"  Bottleneck Analysis — {report['timestamp']}")
print("=" * W)

s = report["summary"]
print(f"  {s['total']} services: {s['critical']} critical, {s['warning']} warning, {s['healthy']} healthy")
print()

for r in results:
    icon = ICONS[r["severity"]]
    color = COLORS[r["severity"]]
    print(f"  {color}[{icon}]{RESET} {r['service']}  →  {r['verdict'].upper()}")
    m = r["metrics"]
    print(f"       CPU: {m['cpu_rate']:.1%}  Heap: {m['heap_pct']:.0%}  GC: {m['gc_rate']:.3f}s/s  Threads: {m['threads']}  Lat: {m['avg_latency_ms']:.0f}ms  Err: {m['err_pct']:.1f}%")

    if r["primary_function"]:
        print(f"       Hotspot: {r['primary_function']}")

    if r["verdict"] != "healthy":
        print(f"       Action:  {r['action']}")

    # Show profile summaries for non-healthy services
    if r["verdict"] != "healthy":
        parts = []
        if r["top_cpu"]:
            parts.append(f"CPU: {r['top_cpu'][0]['function']} ({r['top_cpu'][0]['self_pct']}%)")
        if r["top_alloc"]:
            parts.append(f"Alloc: {r['top_alloc'][0]['function']} ({r['top_alloc'][0]['self_pct']}%)")
        if r["top_mutex"]:
            parts.append(f"Mutex: {r['top_mutex'][0]['function']} ({r['top_mutex'][0]['self_pct']}%)")
        if parts:
            print(f"       Profiles: {' | '.join(parts)}")

    print()

print("-" * W)
print("  Next steps:")
print("    bash scripts/bottleneck.sh --json          # pipe to jq or alerting")
print("    bash scripts/diagnose.sh --service <name>  # deep dive on one service")
print("    bash scripts/top-functions.sh cpu <name>    # full CPU function list")
print("    Grafana → Before vs After Fix dashboard     # compare before/after optimization")
print("-" * W)
print()
'

python3 -c "$ANALYSIS_SCRIPT" \
  "$PROMETHEUS_URL" \
  "$PYROSCOPE_URL" \
  "$PROM_OK" \
  "$PYRO_OK" \
  "$JSON_MODE" \
  "$SERVICE_FILTER" \
  "$THRESHOLDS"

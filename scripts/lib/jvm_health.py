#!/usr/bin/env python3
"""Evaluate JVM health across all bank services using Prometheus metrics.

Checks CPU, heap, GC, and thread metrics against thresholds and suggests
Pyroscope queries for root-cause analysis.

Usage:
    python3 scripts/lib/jvm_health.py PROMETHEUS_URL PYROSCOPE_URL [--json]
"""
import argparse
import json
import sys

from api import SVC_MAP, prom_instant

# --- Thresholds ---

THRESHOLDS = {
    "cpu_rate":  {"warn": 0.5,  "crit": 0.8},
    "heap_pct":  {"warn": 0.70, "crit": 0.85},
    "gc_rate":   {"warn": 0.03, "crit": 0.10},
    "threads":   {"warn": 50,   "crit": 100},
}


# --- Main ---

def main():
    parser = argparse.ArgumentParser(description="JVM health check for bank services")
    parser.add_argument("prometheus_url")
    parser.add_argument("pyroscope_url")
    parser.add_argument("--json", action="store_true", dest="json_mode")
    args = parser.parse_args()

    prometheus = args.prometheus_url
    pyroscope = args.pyroscope_url

    # Collect metrics
    cpu_rate = prom_instant(prometheus, 'rate(process_cpu_seconds_total{job="jvm"}[2m])')
    heap_used = prom_instant(prometheus, 'jvm_memory_used_bytes{job="jvm", area="heap"}')
    heap_max = prom_instant(prometheus, 'jvm_memory_max_bytes{job="jvm", area="heap"}')
    gc_rate = prom_instant(prometheus, 'rate(jvm_gc_collection_seconds_sum{job="jvm"}[2m])')
    threads = prom_instant(prometheus, 'jvm_threads_current{job="jvm"}')

    heap_pct = {}
    for svc in heap_used:
        if svc in heap_max and heap_max[svc] > 0:
            heap_pct[svc] = heap_used[svc] / heap_max[svc]

    all_svcs = sorted(set(
        list(cpu_rate.keys()) + list(heap_pct.keys())
        + list(gc_rate.keys()) + list(threads.keys())))

    if not all_svcs:
        print("ERROR: No JVM metrics found in Prometheus.")
        print("Make sure services are running and load has been generated.")
        sys.exit(1)

    # Evaluate each service
    results = []
    for svc in all_svcs:
        issues = []
        metrics = {}

        cpu = cpu_rate.get(svc, 0)
        metrics["cpu_rate"] = round(cpu, 3)
        t = THRESHOLDS["cpu_rate"]
        if cpu >= t["crit"]:
            issues.append(("CRITICAL", "CPU {:.1%} >= {:.0%}".format(cpu, t["crit"])))
        elif cpu >= t["warn"]:
            issues.append(("WARNING", "CPU {:.1%} >= {:.0%}".format(cpu, t["warn"])))

        hp = heap_pct.get(svc, 0)
        metrics["heap_pct"] = round(hp, 3)
        metrics["heap_used_mb"] = round(heap_used.get(svc, 0) / 1024 / 1024, 1)
        metrics["heap_max_mb"] = round(heap_max.get(svc, 0) / 1024 / 1024, 1)
        t = THRESHOLDS["heap_pct"]
        if hp >= t["crit"]:
            issues.append(("CRITICAL", "Heap {:.1%} >= {:.0%}".format(hp, t["crit"])))
        elif hp >= t["warn"]:
            issues.append(("WARNING", "Heap {:.1%} >= {:.0%}".format(hp, t["warn"])))

        gc = gc_rate.get(svc, 0)
        metrics["gc_rate"] = round(gc, 4)
        t = THRESHOLDS["gc_rate"]
        if gc >= t["crit"]:
            issues.append(("CRITICAL", "GC {:.3f}s/s >= {}s/s".format(gc, t["crit"])))
        elif gc >= t["warn"]:
            issues.append(("WARNING", "GC {:.3f}s/s >= {}s/s".format(gc, t["warn"])))

        th = threads.get(svc, 0)
        metrics["threads"] = int(th)
        t = THRESHOLDS["threads"]
        if th >= t["crit"]:
            issues.append(("CRITICAL", "Threads {} >= {}".format(int(th), t["crit"])))
        elif th >= t["warn"]:
            issues.append(("WARNING", "Threads {} >= {}".format(int(th), t["warn"])))

        severity = "OK"
        if any(s == "CRITICAL" for s, _ in issues):
            severity = "CRITICAL"
        elif any(s == "WARNING" for s, _ in issues):
            severity = "WARNING"

        results.append({
            "service": svc,
            "pyroscope_name": SVC_MAP.get(svc, svc),
            "severity": severity,
            "metrics": metrics,
            "issues": issues,
        })

    order = {"CRITICAL": 0, "WARNING": 1, "OK": 2}
    results.sort(key=lambda r: (order.get(r["severity"], 9), r["service"]))

    if args.json_mode:
        print(json.dumps(results, indent=2))
        return

    # Human-readable output
    print("")
    print("=" * 72)
    print("  JVM Health Check \u2014 All Vert.x Servers")
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
        print("  [{}] {}".format(badge, svc))
        print("             CPU: {:.1%}    Heap: {:.0f}/{:.0f} MB ({:.1%})    GC: {:.4f} s/s    Threads: {}".format(
            m["cpu_rate"], m["heap_used_mb"], m["heap_max_mb"], m["heap_pct"], m["gc_rate"], m["threads"]))

        if r["issues"]:
            for severity, msg in r["issues"]:
                print("             -> {}".format(msg))
            print("             Investigate: bash scripts/top-functions.sh cpu {}".format(svc))
            print("             Pyroscope:   {} -> {}".format(pyroscope, r["pyroscope_name"]))

    print("")
    print("-" * 72)

    crits = sum(1 for r in results if r["severity"] == "CRITICAL")
    warns = sum(1 for r in results if r["severity"] == "WARNING")
    oks = sum(1 for r in results if r["severity"] == "OK")

    print("  Summary: {} services \u2014 {} critical, {} warning, {} healthy".format(
        len(results), crits, warns, oks))

    if crits > 0 or warns > 0:
        print("")
        print("  Next steps:")
        print("    1. Run: bash scripts/top-functions.sh cpu    # find CPU hotspots")
        print("    2. Run: bash scripts/top-functions.sh memory # find allocation hotspots")
        print("    3. Open Grafana JVM Deep Dive dashboard for detailed metrics")
        print("    4. Open Pyroscope flame graphs for root-cause analysis")

    print("")


if __name__ == "__main__":
    main()

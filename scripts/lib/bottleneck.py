#!/usr/bin/env python3
"""Automated bottleneck finder for Pyroscope demo.

Correlates JVM health, HTTP latency, and profiling hotspots to output a
root-cause summary per service (CPU-bound, GC-bound, lock-bound, I/O-bound,
or healthy).

Usage:
    python3 scripts/lib/bottleneck.py PROMETHEUS_URL PYROSCOPE_URL \
        --prom-ok --pyro-ok [--json] [--service NAME] [--threshold cpu=0.3]
"""
import argparse
import json
import sys
from datetime import datetime

from api import (
    SVC_MAP, REVERSE_MAP,
    prom_instant, pyro_top_functions,
)

# --- Profile IDs ---

CPU_PROFILE = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
MEM_PROFILE = "memory:alloc_in_new_tlab_bytes:bytes:space:bytes"
MUTEX_PROFILE = "mutex:contentions:count:mutex:count"

# --- Default thresholds ---

DEFAULT_THRESHOLDS = {
    "cpu": 0.3,
    "heap_pct": 0.75,
    "gc": 0.03,
    "threads": 60,
    "err_pct": 2.0,
    "latency_ms": 500,
}


def parse_thresholds(threshold_str):
    thresholds = dict(DEFAULT_THRESHOLDS)
    for tok in threshold_str.strip().split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            if k in thresholds:
                thresholds[k] = float(v)
    return thresholds


def analyze(prometheus, pyroscope, prom_ok, pyro_ok, service_filter, thresholds):
    cpu = prom_instant(prometheus, 'rate(process_cpu_seconds_total{job="jvm"}[2m])') if prom_ok else {}
    heap_used = prom_instant(prometheus, 'jvm_memory_used_bytes{job="jvm", area="heap"}') if prom_ok else {}
    heap_max = prom_instant(prometheus, 'jvm_memory_max_bytes{job="jvm", area="heap"}') if prom_ok else {}
    gc = prom_instant(prometheus, 'rate(jvm_gc_collection_seconds_sum{job="jvm"}[2m])') if prom_ok else {}
    threads = prom_instant(prometheus, 'jvm_threads_current{job="jvm"}') if prom_ok else {}
    req_rate = prom_instant(prometheus, 'sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps"}[2m]))') if prom_ok else {}
    err_rate = prom_instant(prometheus, 'sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps", code=~"5.."}[2m]))') if prom_ok else {}
    lat_sum = prom_instant(prometheus, 'sum by (instance) (rate(vertx_http_server_response_time_seconds_sum{job="vertx-apps"}[2m]))') if prom_ok else {}
    lat_count = prom_instant(prometheus, 'sum by (instance) (rate(vertx_http_server_response_time_seconds_count{job="vertx-apps"}[2m]))') if prom_ok else {}

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

        inst = "{}:8080".format(svc)
        rr = req_rate.get(inst, req_rate.get(svc, 0))
        er = err_rate.get(inst, err_rate.get(svc, 0))
        ls = lat_sum.get(inst, lat_sum.get(svc, 0))
        lc = lat_count.get(inst, lat_count.get(svc, 0))
        avg_lat = (ls / lc * 1000) if lc > 0 else 0
        err_pct = (er / rr * 100) if rr > 0 else 0

        # Get profiles
        cpu_top = _pyro_top(pyroscope, pyro_ok, pyro_name, CPU_PROFILE)
        mem_top = _pyro_top(pyroscope, pyro_ok, pyro_name, MEM_PROFILE)
        mutex_top = _pyro_top(pyroscope, pyro_ok, pyro_name, MUTEX_PROFILE)

        # Classify bottleneck
        signals = []
        if c >= thresholds["cpu"]:
            signals.append(("cpu-bound", c, cpu_top))
        if g >= thresholds["gc"]:
            signals.append(("gc-bound", g, mem_top))
        if hp >= thresholds["heap_pct"]:
            signals.append(("memory-pressure", hp, mem_top))
        if mutex_top and mutex_top[0]["self_pct"] > 5:
            signals.append(("lock-bound", mutex_top[0]["self_pct"], mutex_top))
        if avg_lat > thresholds["latency_ms"] and not signals:
            signals.append(("io-bound", avg_lat, []))

        if not signals:
            verdict = "healthy"
            severity = "ok"
            primary_function = None
            action = "No action needed"
        else:
            primary = signals[0]
            verdict = primary[0]
            severity = "critical" if c >= 0.8 or hp >= 0.85 or g >= 0.1 else "warning"
            funcs = primary[2]
            primary_function = funcs[0]["function"] if funcs else None

            actions = {
                "cpu-bound": "Optimize {} — see CPU flame graph in Pyroscope".format(
                    primary_function or "top CPU function"),
                "gc-bound": "Reduce allocations in {} — GC rate {:.3f} s/s".format(
                    mem_top[0]["function"] if mem_top else "top allocator", g),
                "memory-pressure": "Heap at {:.0%} — check for leaks in allocation flame graph, consider increasing heap".format(hp),
                "lock-bound": "Reduce lock scope in {} — see mutex flame graph".format(
                    primary_function or "contended method"),
                "io-bound": "Avg latency {:.0f}ms with low CPU — check downstream dependencies, connection pools, timeouts".format(avg_lat),
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

    order = {"critical": 0, "warning": 1, "ok": 2}
    results.sort(key=lambda r: (order.get(r["severity"], 9), r["service"]))
    return results


def _pyro_top(pyroscope, pyro_ok, service, profile_id, n=3):
    if not pyro_ok:
        return []
    funcs = pyro_top_functions(pyroscope, service, profile_id, n)
    # Convert to {function, self_pct} format
    return [{"function": f["function"].replace("/", "."), "self_pct": f["pct"]} for f in funcs]


def print_report(report):
    W = 80
    ICONS = {"critical": "!!!", "warning": " ! ", "ok": " . "}
    COLORS = {"critical": "\033[91m", "warning": "\033[93m", "ok": "\033[92m"}
    RESET = "\033[0m"

    print()
    print("=" * W)
    print("  Bottleneck Analysis — {}".format(report["timestamp"]))
    print("=" * W)

    s = report["summary"]
    print("  {} services: {} critical, {} warning, {} healthy".format(
        s["total"], s["critical"], s["warning"], s["healthy"]))
    print()

    for r in report["services"]:
        icon = ICONS[r["severity"]]
        color = COLORS[r["severity"]]
        print("  {}[{}]{} {}  →  {}".format(color, icon, RESET, r["service"], r["verdict"].upper()))
        m = r["metrics"]
        print("       CPU: {:.1%}  Heap: {:.0%}  GC: {:.3f}s/s  Threads: {}  Lat: {:.0f}ms  Err: {:.1f}%".format(
            m["cpu_rate"], m["heap_pct"], m["gc_rate"], m["threads"], m["avg_latency_ms"], m["err_pct"]))

        if r["primary_function"]:
            print("       Hotspot: {}".format(r["primary_function"]))

        if r["verdict"] != "healthy":
            print("       Action:  {}".format(r["action"]))
            parts = []
            if r["top_cpu"]:
                parts.append("CPU: {} ({}%)".format(r["top_cpu"][0]["function"], r["top_cpu"][0]["self_pct"]))
            if r["top_alloc"]:
                parts.append("Alloc: {} ({}%)".format(r["top_alloc"][0]["function"], r["top_alloc"][0]["self_pct"]))
            if r["top_mutex"]:
                parts.append("Mutex: {} ({}%)".format(r["top_mutex"][0]["function"], r["top_mutex"][0]["self_pct"]))
            if parts:
                print("       Profiles: {}".format(" | ".join(parts)))

        print()

    print("-" * W)
    print("  Next steps:")
    print("    bash scripts/bottleneck.sh --json          # pipe to jq or alerting")
    print("    bash scripts/diagnose.sh --service <name>  # deep dive on one service")
    print("    bash scripts/top-functions.sh cpu <name>    # full CPU function list")
    print("    Grafana → Before vs After Fix dashboard     # compare before/after optimization")
    print("-" * W)
    print()


def main():
    parser = argparse.ArgumentParser(description="Bottleneck analysis for bank services")
    parser.add_argument("prometheus_url")
    parser.add_argument("pyroscope_url")
    parser.add_argument("--prom-ok", action="store_true")
    parser.add_argument("--pyro-ok", action="store_true")
    parser.add_argument("--json", action="store_true", dest="json_mode")
    parser.add_argument("--service", default="", dest="service_filter")
    parser.add_argument("--threshold", default="", dest="threshold_str")
    args = parser.parse_args()

    thresholds = parse_thresholds(args.threshold_str)
    results = analyze(
        args.prometheus_url, args.pyroscope_url,
        args.prom_ok, args.pyro_ok,
        args.service_filter, thresholds)

    report = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "thresholds": thresholds,
        "services": results,
        "summary": {
            "total": len(results),
            "critical": sum(1 for r in results if r["severity"] == "critical"),
            "warning": sum(1 for r in results if r["severity"] == "warning"),
            "healthy": sum(1 for r in results if r["verdict"] == "healthy"),
        },
    }

    if args.json_mode:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)


if __name__ == "__main__":
    main()

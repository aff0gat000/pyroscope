#!/usr/bin/env python3
"""Diagnostic report engine for Pyroscope demo.

Queries Prometheus (JVM metrics, HTTP stats, alerts) and Pyroscope (profiling
hotspots) to produce a unified diagnostic report.

Usage:
    python3 scripts/lib/diagnose.py PROMETHEUS_URL PYROSCOPE_URL \\
        --prom-ok --pyro-ok [--json] [--section SECTION] [--service NAME]
"""
import argparse
import json
import sys
from datetime import datetime

from api import (
    SVC_MAP, REVERSE_MAP,
    prom_query, prom_instant, prom_alerts,
    pyro_label_values, pyro_top_functions,
)

# --- Profile IDs ---

CPU_PROFILE = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
MEM_PROFILE = "memory:alloc_in_new_tlab_bytes:bytes:space:bytes"
MUTEX_PROFILE = "mutex:contentions:count:mutex:count"


# --- Section collectors ---

def collect_health(prometheus, prom_services):
    cpu = prom_instant(prometheus, 'rate(process_cpu_seconds_total{job="jvm"}[2m])')
    heap_used = prom_instant(prometheus, 'jvm_memory_used_bytes{job="jvm", area="heap"}')
    heap_max = prom_instant(prometheus, 'jvm_memory_max_bytes{job="jvm", area="heap"}')
    gc = prom_instant(prometheus, 'rate(jvm_gc_collection_seconds_sum{job="jvm"}[2m])')
    threads = prom_instant(prometheus, 'jvm_threads_current{job="jvm"}')

    severity_rank = {"OK": 0, "WARNING": 1, "CRITICAL": 2}
    services = []
    for svc in prom_services:
        hp_used = heap_used.get(svc, 0)
        hp_max = heap_max.get(svc, 0)
        hp_pct = hp_used / hp_max if hp_max > 0 else 0
        c = cpu.get(svc, 0)
        g = gc.get(svc, 0)
        t = int(threads.get(svc, 0))

        status = "OK"
        issues = []
        if c >= 0.8:
            issues.append("CPU critical"); status = "CRITICAL"
        elif c >= 0.5:
            issues.append("CPU warning"); status = "WARNING"
        if hp_pct >= 0.85:
            issues.append("Heap critical"); status = "CRITICAL"
        elif hp_pct >= 0.7:
            issues.append("Heap warning")
            status = max(status, "WARNING", key=lambda x: severity_rank[x])
        if g >= 0.1:
            issues.append("GC critical"); status = "CRITICAL"
        elif g >= 0.03:
            issues.append("GC warning")
            status = max(status, "WARNING", key=lambda x: severity_rank[x])

        services.append({
            "service": svc,
            "pyroscope_name": SVC_MAP.get(svc, svc),
            "status": status,
            "cpu_rate": round(c, 3),
            "heap_used_mb": round(hp_used / 1024 / 1024, 1),
            "heap_max_mb": round(hp_max / 1024 / 1024, 1),
            "heap_pct": round(hp_pct, 3),
            "gc_rate": round(g, 4),
            "threads": t,
            "issues": issues,
        })

    order = {"CRITICAL": 0, "WARNING": 1, "OK": 2}
    services.sort(key=lambda s: (order.get(s["status"], 9), s["service"]))
    return services


def collect_http(prometheus, service_filter):
    req_rate = prom_instant(prometheus,
        'sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps"}[2m]))')
    err_rate = prom_instant(prometheus,
        'sum by (instance) (rate(vertx_http_server_requests_total{job="vertx-apps", code=~"5.."}[2m]))')
    lat_sum = prom_instant(prometheus,
        'sum by (instance) (rate(vertx_http_server_response_time_seconds_sum{job="vertx-apps"}[2m]))')
    lat_count = prom_instant(prometheus,
        'sum by (instance) (rate(vertx_http_server_response_time_seconds_count{job="vertx-apps"}[2m]))')

    slow_results = prom_query(prometheus,
        'topk(10, sum by (route) (rate(vertx_http_server_response_time_seconds_sum{job="vertx-apps"}[5m])) '
        '/ sum by (route) (rate(vertx_http_server_response_time_seconds_count{job="vertx-apps"}[5m])))')
    slowest = []
    for r in slow_results:
        route = r["metric"].get("route", "unknown")
        val = float(r["value"][1])
        if val > 0:
            slowest.append({"route": route, "avg_latency_s": round(val, 4)})
    slowest.sort(key=lambda x: -x["avg_latency_s"])

    instances = sorted(set(list(req_rate.keys()) + list(lat_sum.keys())))
    if service_filter:
        container_name = REVERSE_MAP.get(service_filter, service_filter)
        instances = [i for i in instances if i.split(":")[0] == container_name]

    services = []
    for inst in instances:
        svc = inst.split(":")[0]
        rr = req_rate.get(inst, 0)
        er = err_rate.get(inst, 0)
        ls = lat_sum.get(inst, 0)
        lc = lat_count.get(inst, 0)
        avg_lat = ls / lc if lc > 0 else 0
        services.append({
            "instance": inst,
            "service": svc,
            "req_per_sec": round(rr, 2),
            "err_per_sec": round(er, 4),
            "err_pct": round(er / rr * 100, 2) if rr > 0 else 0,
            "avg_latency_ms": round(avg_lat * 1000, 1),
        })

    return {"services": services, "slowest_endpoints": slowest[:10]}


def collect_profiles(pyroscope, pyro_services):
    services = []
    for svc in pyro_services:
        entry = {"service": svc}
        entry["cpu_top5"] = pyro_top_functions(pyroscope, svc, CPU_PROFILE, 5)
        entry["memory_top5"] = pyro_top_functions(pyroscope, svc, MEM_PROFILE, 5)
        entry["mutex_top5"] = pyro_top_functions(pyroscope, svc, MUTEX_PROFILE, 5)
        services.append(entry)
    return services


def collect_alerts(prometheus):
    firing = prom_alerts(prometheus)
    return [{
        "name": a.get("labels", {}).get("alertname", "unknown"),
        "severity": a.get("labels", {}).get("severity", "unknown"),
        "instance": a.get("labels", {}).get("instance", ""),
        "summary": a.get("annotations", {}).get("summary", ""),
        "active_since": a.get("activeAt", ""),
    } for a in firing]


# --- Output ---

def print_report(report):
    W = 76
    print("")
    print("=" * W)
    print("  Diagnostic Report \u2014 {}".format(report["timestamp"]))
    print("=" * W)
    print("  Prometheus: {}".format(report["sources"]["prometheus"] or "UNREACHABLE"))
    print("  Pyroscope:  {}".format(report["sources"]["pyroscope"] or "UNREACHABLE"))

    if "health" in report:
        print("")
        print("-" * W)
        print("  JVM HEALTH")
        print("-" * W)
        for s in report["health"]:
            tag = {"OK": "  OK  ", "WARNING": " WARN ", "CRITICAL": " CRIT "}[s["status"]]
            print("  [{}] {}".format(tag, s["service"]))
            print("           CPU: {:.1%}   Heap: {:.0f}/{:.0f} MB ({:.1%})   GC: {:.4f} s/s   Threads: {}".format(
                s["cpu_rate"], s["heap_used_mb"], s["heap_max_mb"], s["heap_pct"], s["gc_rate"], s["threads"]))
            if s["issues"]:
                print("           Issues: {}".format(", ".join(s["issues"])))

    if "http" in report:
        http = report["http"]
        print("")
        print("-" * W)
        print("  HTTP TRAFFIC")
        print("-" * W)
        if http["services"]:
            print("  {:<25} {:>8} {:>7} {:>10}".format("Service", "Req/s", "Err%", "Avg Lat"))
            print("  {} {} {} {}".format("-" * 25, "-" * 8, "-" * 7, "-" * 10))
            for s in http["services"]:
                print("  {:<25} {:>8.1f} {:>6.1f}% {:>8.1f}ms".format(
                    s["service"], s["req_per_sec"], s["err_pct"], s["avg_latency_ms"]))
        else:
            print("  (no HTTP traffic data)")

        if http["slowest_endpoints"]:
            print("")
            print("  Slowest endpoints (avg latency, last 5m):")
            for i, ep in enumerate(http["slowest_endpoints"][:5], 1):
                print("    {}. {:>8.1f}ms  {}".format(i, ep["avg_latency_s"] * 1000, ep["route"]))

    if "profiles" in report:
        print("")
        print("-" * W)
        print("  PROFILING HOTSPOTS (last 1h)")
        print("-" * W)
        for s in report["profiles"]:
            print("")
            print("  {}".format(s["service"]))
            for label, key in [("CPU", "cpu_top5"), ("Memory", "memory_top5"), ("Mutex", "mutex_top5")]:
                funcs = s.get(key, [])
                if funcs:
                    top = funcs[0]
                    others = len(funcs) - 1
                    extra = "  (+{} more)".format(others) if others else ""
                    print("    {:8s}  {:5.1f}%  {}{}".format(label, top["pct"], top["function"], extra))
                else:
                    print("    {:8s}  (no data)".format(label))

    if "alerts" in report:
        alerts = report["alerts"]
        print("")
        print("-" * W)
        print("  FIRING ALERTS")
        print("-" * W)
        if alerts:
            for a in alerts:
                print("  [{:>8}] {}  {}".format(a["severity"].upper(), a["name"], a["instance"]))
                if a["summary"]:
                    print("             {}".format(a["summary"]))
        else:
            print("  (none)")

    print("")
    print("=" * W)
    print("  Quick follow-up commands:")
    print("    bash scripts/diagnose.sh --json              # pipe to jq, scripts, etc.")
    print("    bash scripts/diagnose.sh --section profiles  # just profiling data")
    print("    bash scripts/top-functions.sh cpu             # detailed CPU hotspots")
    print("    bash scripts/run.sh health                    # quick health check")
    print("=" * W)
    print("")


# --- Main ---

def main():
    parser = argparse.ArgumentParser(description="Diagnostic report for Pyroscope demo")
    parser.add_argument("prometheus_url")
    parser.add_argument("pyroscope_url")
    parser.add_argument("--prom-ok", action="store_true")
    parser.add_argument("--pyro-ok", action="store_true")
    parser.add_argument("--json", action="store_true", dest="json_mode")
    parser.add_argument("--section", default="all")
    parser.add_argument("--service", default="", dest="service_filter")
    args = parser.parse_args()

    prometheus = args.prometheus_url
    pyroscope = args.pyroscope_url

    report = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "sources": {
            "prometheus": prometheus if args.prom_ok else None,
            "pyroscope": pyroscope if args.pyro_ok else None,
        },
    }

    # Discover services
    prom_services = sorted(set(
        prom_instant(prometheus, 'up{job="jvm"}').keys())) if args.prom_ok else []
    pyro_services = pyro_label_values(pyroscope) if args.pyro_ok else []

    if args.service_filter:
        container_name = REVERSE_MAP.get(args.service_filter, args.service_filter)
        prom_services = [s for s in prom_services if s == container_name]
        pyro_services = [s for s in pyro_services if s == args.service_filter]

    sections = args.section.split(",") if "," in args.section else [args.section]

    if "all" in sections or "health" in sections:
        report["health"] = collect_health(prometheus, prom_services)
    if "all" in sections or "http" in sections:
        report["http"] = collect_http(prometheus, args.service_filter)
    if "all" in sections or "profiles" in sections:
        report["profiles"] = collect_profiles(pyroscope, pyro_services)
    if "all" in sections or "alerts" in sections:
        report["alerts"] = collect_alerts(prometheus)

    if args.json_mode:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)


if __name__ == "__main__":
    main()

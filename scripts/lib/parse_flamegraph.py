#!/usr/bin/env python3
"""Parse Pyroscope flamebearer JSON and report top functions by self-time.

Reads JSON from stdin, prints a category summary, top N overall functions,
and top application-code functions.

Usage:
    curl ... | python3 scripts/lib/parse_flamegraph.py [OPTIONS]

Options:
    --top N             Number of functions to show (default: 15)
    --unit UNIT         Value unit: samples, bytes, or count (default: samples)
    --app-prefix PREFIX Application package prefix (default: com.example.)
    --user-code         Only show application code
    --filter PREFIX     Only show functions matching this prefix
"""
import argparse
import json
import sys

# --- Classification ---

JVM_PREFIXES = (
    "java.", "javax.", "jdk.", "sun.", "com.sun.",
    "org.graalvm.", "jdk.internal.",
)

LIB_PREFIXES = (
    "io.vertx.", "io.netty.", "io.pyroscope.",
    "org.apache.", "org.slf4j.", "ch.qos.",
    "com.fasterxml.", "org.jboss.",
    "one.profiler.",
)


def normalize(name):
    """Convert JFR slash-separated names to dot-separated for matching."""
    return name.replace("/", ".")


def classify(name, app_prefix):
    n = normalize(name)
    if n.startswith(app_prefix):
        return "app"
    for p in JVM_PREFIXES:
        if n.startswith(p):
            return "jvm"
    for p in LIB_PREFIXES:
        if n.startswith(p):
            return "lib"
    return "other"


# --- Formatting ---

def format_val(val, unit):
    if unit == "bytes":
        return "{:,.1f} MB".format(val / 1024 / 1024)
    elif unit == "count":
        return "{:,} events".format(val)
    return "{:.2f}s".format(val / 1_000_000_000)


def print_ranked(items, top_n, total, unit, app_prefix):
    for rank, (name, val) in enumerate(items[:top_n], 1):
        pct = val / total * 100
        cat = classify(name, app_prefix)
        tag = "[{:5s}]".format(cat)
        parts = name.rsplit(".", 1)
        display = "{}.{}".format(parts[0], parts[1]) if len(parts) == 2 else name
        print("  {:3d}. {:5.1f}%  {:>14s}  {}  {}".format(
            rank, pct, format_val(val, unit), tag, display))


# --- Main ---

def main():
    parser = argparse.ArgumentParser(description="Parse Pyroscope flamegraph JSON")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--unit", default="samples", choices=["samples", "bytes", "count"])
    parser.add_argument("--app-prefix", default="com.example.")
    parser.add_argument("--user-code", action="store_true")
    parser.add_argument("--filter", default="", dest="filter_prefix")
    args = parser.parse_args()

    data = json.load(sys.stdin)
    fb = data.get("flamebearer", {})
    names = fb.get("names", [])
    levels = fb.get("levels", [])
    total = fb.get("numTicks", 0)

    if total == 0:
        print("  (no data — generate load first)")
        return

    # Sum self-time per function across all levels
    self_map = {}
    for level in levels:
        i = 0
        while i + 3 < len(level):
            name_idx = level[i + 3]
            self_val = level[i + 2]
            if name_idx < len(names) and self_val > 0:
                self_map[names[name_idx]] = self_map.get(names[name_idx], 0) + self_val
            i += 4

    all_sorted = sorted(self_map.items(), key=lambda x: -x[1])

    # Filtered modes
    if args.user_code:
        filtered = [(n, v) for n, v in all_sorted
                     if normalize(n).startswith(args.app_prefix)]
        if not filtered:
            print("  (no application code found — app prefix: {})".format(args.app_prefix))
            return
        print_ranked(filtered, args.top, total, args.unit, args.app_prefix)
        return

    if args.filter_prefix:
        filtered = [(n, v) for n, v in all_sorted
                     if normalize(n).startswith(args.filter_prefix)]
        if not filtered:
            print("  (no functions matching prefix: {})".format(args.filter_prefix))
            return
        print_ranked(filtered, args.top, total, args.unit, args.app_prefix)
        return

    # Default mode: category summary + all + user code

    # Category summary
    cat_totals = {}
    for name, val in self_map.items():
        cat = classify(name, args.app_prefix)
        cat_totals[cat] = cat_totals.get(cat, 0) + val

    if sum(cat_totals.values()) > 0:
        print("")
        print("  {:<10s} {:>14s} {:>7s} {:>10s}".format(
            "Category", "Self-time", "%", "Functions"))
        print("  " + "\u2500" * 10 + "  " + "\u2500" * 14 + " "
              + "\u2500" * 7 + " " + "\u2500" * 10)
        for cat in ["app", "lib", "jvm", "other"]:
            if cat in cat_totals:
                v = cat_totals[cat]
                pct = v / total * 100
                count = sum(1 for n in self_map if classify(n, args.app_prefix) == cat)
                print("  {:<10s} {:>14s} {:6.1f}% {:>10d}".format(
                    cat, format_val(v, args.unit), pct, count))
        print("")

    # Top N overall
    print("  All functions (top {}):".format(args.top))
    print_ranked(all_sorted, args.top, total, args.unit, args.app_prefix)

    # Top user-code functions
    app_sorted = [(n, v) for n, v in all_sorted
                  if normalize(n).startswith(args.app_prefix)]
    if app_sorted:
        app_top = min(args.top, len(app_sorted))
        print("")
        print("  Application code (top {}):".format(app_top))
        print_ranked(app_sorted, app_top, total, args.unit, args.app_prefix)


if __name__ == "__main__":
    main()

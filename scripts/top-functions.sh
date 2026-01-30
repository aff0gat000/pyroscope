#!/usr/bin/env bash
set -euo pipefail

# Reports the top classes and functions consuming CPU, memory, and mutex
# contention across all bank services. Uses the Pyroscope HTTP API.
#
# Usage:
#   bash scripts/top-functions.sh                  # all services, all profiles
#   bash scripts/top-functions.sh cpu               # CPU only
#   bash scripts/top-functions.sh memory            # memory allocation only
#   bash scripts/top-functions.sh mutex             # mutex contention only
#   bash scripts/top-functions.sh cpu bank-api-gateway   # CPU for one service
#   bash scripts/top-functions.sh --top 20          # show top 20 (default 15)
#   bash scripts/top-functions.sh --user-code       # only show application code
#   bash scripts/top-functions.sh --filter io.vertx # only show io.vertx.* functions
#
# Requires: curl, python3, running Pyroscope instance

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# Load port assignments
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

PYROSCOPE_URL="http://localhost:${PYROSCOPE_PORT:-4040}"
PROFILE_TYPE=""
SERVICE=""
TOP_N=15
TIME_RANGE="5m"
USER_CODE_ONLY=0
FILTER_PREFIX=""

# Application package prefix — functions matching this are tagged [app].
APP_PREFIX="com.example."

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    cpu|memory|mutex)
      PROFILE_TYPE="$1"
      ;;
    --top)
      shift
      TOP_N="${1:?--top requires a number}"
      ;;
    --range)
      shift
      TIME_RANGE="${1:?--range requires a value like 1h, 30m}"
      ;;
    --user-code)
      USER_CODE_ONLY=1
      ;;
    --filter)
      shift
      FILTER_PREFIX="${1:?--filter requires a package prefix}"
      ;;
    bank-*)
      SERVICE="$1"
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash scripts/top-functions.sh [cpu|memory|mutex] [bank-SERVICE] [--top N] [--range TIME] [--user-code] [--filter PREFIX]"
      exit 1
      ;;
  esac
  shift
done

# Profile type mappings
CPU_PROFILE="process_cpu:cpu:nanoseconds:cpu:nanoseconds"
MEMORY_PROFILE="memory:alloc_in_new_tlab_bytes:bytes:space:bytes"
MUTEX_PROFILE="mutex:contentions:count:mutex:count"

# Determine which profiles to query
PROFILES=""
case "${PROFILE_TYPE:-all}" in
  cpu)    PROFILES="cpu" ;;
  memory) PROFILES="memory" ;;
  mutex)  PROFILES="mutex" ;;
  all)    PROFILES="cpu memory mutex" ;;
esac

# Discover services from Pyroscope
if [ -n "$SERVICE" ]; then
  SERVICES="$SERVICE"
else
  SERVICES=$(curl -sf "$PYROSCOPE_URL/querier.v1.QuerierService/LabelValues" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"name":"service_name"}' 2>/dev/null \
    | python3 -c "import json,sys; [print(n) for n in json.load(sys.stdin).get('names',[])]" 2>/dev/null) || true
  if [ -z "$SERVICES" ]; then
    echo "ERROR: Cannot reach Pyroscope at $PYROSCOPE_URL or no services found."
    echo "Make sure the stack is running: bash scripts/run.sh"
    exit 1
  fi
fi

# Python script that parses flamebearer JSON and extracts top functions
PARSE_SCRIPT='
import json, sys

data = json.load(sys.stdin)
fb = data.get("flamebearer", {})
names = fb.get("names", [])
levels = fb.get("levels", [])
total = fb.get("numTicks", 0)
top_n = int(sys.argv[1]) if len(sys.argv) > 1 else 15
unit = sys.argv[2] if len(sys.argv) > 2 else "samples"
app_prefix = sys.argv[3] if len(sys.argv) > 3 else "com.example."
user_code_only = sys.argv[4] == "1" if len(sys.argv) > 4 else False
filter_prefix = sys.argv[5] if len(sys.argv) > 5 else ""

if total == 0:
    print("  (no data — generate load first)")
    sys.exit(0)

# Known JVM / runtime prefixes
JVM_PREFIXES = (
    "java.", "javax.", "jdk.", "sun.", "com.sun.",
    "org.graalvm.", "jdk.internal.",
)
# Known library/framework prefixes
LIB_PREFIXES = (
    "io.vertx.", "io.netty.", "io.pyroscope.",
    "org.apache.", "org.slf4j.", "ch.qos.",
    "com.fasterxml.", "org.jboss.",
    "one.profiler.",
)

def normalize(name):
    """Convert JFR slash-separated names to dot-separated for matching."""
    return name.replace("/", ".")

def classify(name):
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

def format_val(val):
    if unit == "bytes":
        return f"{val / 1024 / 1024:,.1f} MB"
    elif unit == "count":
        return f"{val:,} events"
    return f"{val / 1_000_000_000:.2f}s"

def print_ranked(items, top_n):
    for rank, (name, val) in enumerate(items[:top_n], 1):
        pct = val / total * 100
        cat = classify(name)
        tag = f"[{cat:5s}]"
        parts = name.rsplit(".", 1)
        display = f"{parts[0]}.{parts[1]}" if len(parts) == 2 else name
        print("  {:3d}. {:5.1f}%  {:>14s}  {}  {}".format(rank, pct, format_val(val), tag, display))

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

# If filtering, just show filtered results
if user_code_only:
    filtered = [(n, v) for n, v in all_sorted if normalize(n).startswith(app_prefix)]
    if not filtered:
        print(f"  (no application code found — app prefix: {app_prefix})")
        sys.exit(0)
    print_ranked(filtered, top_n)
    sys.exit(0)

if filter_prefix:
    filtered = [(n, v) for n, v in all_sorted if normalize(n).startswith(filter_prefix)]
    if not filtered:
        print(f"  (no functions matching prefix: {filter_prefix})")
        sys.exit(0)
    print_ranked(filtered, top_n)
    sys.exit(0)

# Default mode: summary + all + user code

# Category summary
cat_totals = {}
for name, val in self_map.items():
    cat = classify(name)
    cat_totals[cat] = cat_totals.get(cat, 0) + val
self_total = sum(cat_totals.values())
if self_total > 0:
    print("")
    hdr = "  {:<10s} {:>14s} {:>7s} {:>10s}".format("Category", "Self-time", "%", "Functions")
    print(hdr)
    print("  " + "─" * 10 + "  " + "─" * 14 + " " + "─" * 7 + " " + "─" * 10)
    for cat in ["app", "lib", "jvm", "other"]:
        if cat in cat_totals:
            v = cat_totals[cat]
            pct = v / total * 100
            count = sum(1 for n in self_map if classify(n) == cat)
            print("  {:<10s} {:>14s} {:6.1f}% {:>10d}".format(cat, format_val(v), pct, count))
    print("")

# Top N overall
print(f"  All functions (top {top_n}):")
print_ranked(all_sorted, top_n)

# Top user-code functions
app_sorted = [(n, v) for n, v in all_sorted if normalize(n).startswith(app_prefix)]
if app_sorted:
    app_top = min(top_n, len(app_sorted))
    print("")
    print(f"  Application code (top {app_top}):")
    print_ranked(app_sorted, app_top)
'

# Query and report
for profile in $PROFILES; do
  case "$profile" in
    cpu)    QUERY="$CPU_PROFILE";    LABEL="CPU";               UNIT="samples" ;;
    memory) QUERY="$MEMORY_PROFILE"; LABEL="Memory Allocation";  UNIT="bytes" ;;
    mutex)  QUERY="$MUTEX_PROFILE";  LABEL="Mutex Contention";   UNIT="count" ;;
  esac

  echo ""
  echo "================================================================"
  echo "  $LABEL — Top $TOP_N functions (last $TIME_RANGE)"
  echo "================================================================"

  for svc in $SERVICES; do
    echo ""
    echo "--- $svc ---"
    ENCODED_QUERY=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${QUERY}{service_name=\"${svc}\"}'))")
    RESULT=$(curl -sf "${PYROSCOPE_URL}/pyroscope/render?query=${ENCODED_QUERY}&from=now-${TIME_RANGE}&until=now&format=json" 2>/dev/null) || true
    if [ -z "$RESULT" ]; then
      echo "  (no data or Pyroscope unreachable)"
      continue
    fi
    echo "$RESULT" | python3 -c "$PARSE_SCRIPT" "$TOP_N" "$UNIT" "$APP_PREFIX" "$USER_CODE_ONLY" "$FILTER_PREFIX"
  done
done

echo ""

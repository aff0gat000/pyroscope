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
TIME_RANGE="1h"

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
    bank-*)
      SERVICE="$1"
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash scripts/top-functions.sh [cpu|memory|mutex] [bank-SERVICE] [--top N] [--range TIME]"
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

if total == 0:
    print("  (no data — generate load first)")
    sys.exit(0)

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

top = sorted(self_map.items(), key=lambda x: -x[1])[:top_n]

# Separate class and method for readability
for rank, (name, val) in enumerate(top, 1):
    pct = val / total * 100
    if unit == "bytes":
        human = f"{val / 1024 / 1024:,.1f} MB"
    elif unit == "count":
        human = f"{val:,} events"
    else:
        human = f"{val / 1_000_000_000:.2f}s"
    # Split into class.method if possible
    parts = name.rsplit(".", 1)
    if len(parts) == 2:
        display = f"{parts[0]}.{parts[1]}"
    else:
        display = name
    print(f"  {rank:3d}. {pct:5.1f}%  {human:>14s}  {display}")
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
    echo "$RESULT" | python3 -c "$PARSE_SCRIPT" "$TOP_N" "$UNIT"
  done
done

echo ""

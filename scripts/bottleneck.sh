#!/usr/bin/env bash
set -euo pipefail

# Automated bottleneck finder — correlates JVM health, HTTP latency,
# and profiling hotspots to output a root-cause summary per service.
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

# Check reachability
PROM_FLAG=""
PYRO_FLAG=""
if curl -sf "$PROMETHEUS_URL/-/ready" > /dev/null 2>&1; then PROM_FLAG="--prom-ok"; fi
if curl -sf "$PYROSCOPE_URL/ready" > /dev/null 2>&1; then PYRO_FLAG="--pyro-ok"; fi

if [ -z "$PROM_FLAG" ] && [ -z "$PYRO_FLAG" ]; then
  echo "ERROR: Cannot reach Prometheus ($PROMETHEUS_URL) or Pyroscope ($PYROSCOPE_URL)"
  echo "Make sure the stack is running: bash scripts/run.sh"
  exit 1
fi

# Collect threshold args to pass as single string
THRESHOLD_STR=""
PASSTHROUGH_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)
      shift
      THRESHOLD_STR="$THRESHOLD_STR ${1:?--threshold requires key=value}"
      ;;
    *)
      PASSTHROUGH_ARGS+=("$1")
      ;;
  esac
  shift
done

PYTHONPATH="$SCRIPT_DIR/lib" python3 "$SCRIPT_DIR/lib/bottleneck.py" \
  "$PROMETHEUS_URL" "$PYROSCOPE_URL" $PROM_FLAG $PYRO_FLAG \
  --threshold "$THRESHOLD_STR" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"

#!/usr/bin/env bash
set -euo pipefail

# Full diagnostic report for all Java bank services.
# Queries Prometheus (JVM metrics, HTTP stats) and Pyroscope (profiling hotspots).
#
# Usage:
#   bash scripts/diagnose.sh                  # full report, all services
#   bash scripts/diagnose.sh --service bank-api-gateway   # one service only
#   bash scripts/diagnose.sh --json           # machine-readable JSON output
#   bash scripts/diagnose.sh --section health # only health section
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

PYTHONPATH="$SCRIPT_DIR/lib" python3 "$SCRIPT_DIR/lib/diagnose.py" \
  "$PROMETHEUS_URL" "$PYROSCOPE_URL" $PROM_FLAG $PYRO_FLAG "$@"

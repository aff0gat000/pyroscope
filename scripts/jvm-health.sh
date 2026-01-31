#!/usr/bin/env bash
set -euo pipefail

# Identifies problematic JVMs across all bank services by checking key health
# indicators from Prometheus.
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

if ! curl -sf "$PROMETHEUS_URL/-/ready" > /dev/null 2>&1; then
  echo "ERROR: Cannot reach Prometheus at $PROMETHEUS_URL"
  echo "Make sure the stack is running: bash scripts/run.sh"
  exit 1
fi

PYTHONPATH="$SCRIPT_DIR/lib" python3 "$SCRIPT_DIR/lib/jvm_health.py" \
  "$PROMETHEUS_URL" "$PYROSCOPE_URL" "$@"

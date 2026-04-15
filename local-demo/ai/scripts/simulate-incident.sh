#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
KIND="${1:-blocker}"
docker compose --profile simulate run --rm simulator python /app/simulator.py incident --kind "$KIND"

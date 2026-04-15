#!/usr/bin/env bash
# Trigger one run of each DAG so feature tables populate immediately.
set -euo pipefail
cd "$(dirname "$0")/.."
for dag in profile_etl anomaly_detect daily_hotspot_report; do
  echo ">> $dag"
  docker compose exec -T airflow airflow dags trigger "$dag" || true
done

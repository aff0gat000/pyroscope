#!/usr/bin/env bash
# One-shot end-to-end demo: tear down, bring up both phases, generate load,
# inject all 4 incident kinds, trigger DAGs, verify, print URLs.
#
# Usage:
#   ./scripts/run-full-demo.sh                # full run, ~15-20 min first time
#   ./scripts/run-full-demo.sh --skip-teardown  # reuse a running stack
#   ./scripts/run-full-demo.sh --down          # tear everything down and exit
#
# Designed for Linux (Ubuntu) and macOS (Apple Silicon).
set -euo pipefail

# ---- resolve paths ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # local-demo/
P2_DIR="$P1_DIR/ai"                                # local-demo/ai/

SKIP_TEARDOWN=0
DOWN_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-teardown) SKIP_TEARDOWN=1 ;;
    --down)          DOWN_ONLY=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- helpers ---------------------------------------------------------------
say() { printf "\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n" "$*"; }
ok()  { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn(){ printf "  \033[33m!\033[0m %s\n" "$*"; }

wait_for() {
  # Accept any HTTP response (including 503 during slow boots like Grafana
  # installing plugins). Caller can pass "strict" to require 2xx.
  # Prints a live single-line progress indicator so long waits aren't silent.
  local url="$1" label="$2" tries="${3:-90}" mode="${4:-soft}"
  local start code elapsed max=$((tries * 2))
  start=$(date +%s)
  for ((i=0; i<tries; i++)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || echo 000)
    elapsed=$(( $(date +%s) - start ))
    if [[ "$mode" == "strict" ]]; then
      if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        printf "\r\033[K"; ok "$label ready (HTTP $code, ${elapsed}s)"; return 0
      fi
    else
      if [[ "$code" =~ ^[0-9]+$ && "$code" -ge 200 && "$code" != "000" ]]; then
        printf "\r\033[K"; ok "$label ready (HTTP $code, ${elapsed}s)"; return 0
      fi
    fi
    # Live progress on a single line; \033[K clears the rest of the line.
    printf "\r  \033[90m⏳ waiting for %s… %ds/%ds (HTTP %s)\033[0m\033[K" \
           "$label" "$elapsed" "$max" "$code"
    sleep 2
  done
  printf "\r\033[K"
  warn "$label not ready after ${max}s (continuing anyway)"; return 1
}

teardown() {
  say "Tearing down both phases"
  (cd "$P2_DIR" && docker compose --profile simulate down -v 2>/dev/null) || true
  (cd "$P1_DIR" && docker compose --profile load     down -v 2>/dev/null) || true
  pkill -f 'scripts/load.sh' 2>/dev/null || true
  docker container prune -f >/dev/null 2>&1 || true
  ok "teardown complete"
}

trap 'echo; warn "interrupted — stopping load.sh"; pkill -f scripts/load.sh 2>/dev/null || true' INT

# ---- --down: stop and exit -------------------------------------------------
if [[ $DOWN_ONLY -eq 1 ]]; then
  teardown
  exit 0
fi

# ---- 0. clean slate --------------------------------------------------------
if [[ $SKIP_TEARDOWN -eq 0 ]]; then
  teardown
fi

# ---- 1. phase 1 ------------------------------------------------------------
say "Phase 1 — starting profiling stack"
(cd "$P1_DIR" && ./scripts/up.sh)
# shellcheck disable=SC1091
source "$P1_DIR/.env"

wait_for "localhost:${DEMO_JVM11_PORT}/health"  "demo-jvm11" 90  strict
wait_for "localhost:${DEMO_JVM21_PORT}/health"  "demo-jvm21" 90  strict
wait_for "localhost:${PYROSCOPE_PORT}/ready"    "pyroscope"  90  strict
# Grafana on first run pulls the infinity-datasource plugin (~50 MB) into a
# fresh volume — can take 3-5 min on slow networks. Accept any HTTP response.
wait_for "localhost:${GRAFANA_PORT}/api/health" "grafana"   300 soft

say "Phase 1 — starting continuous load in background"
nohup "$P1_DIR/scripts/load.sh" >/tmp/local-demo-load.log 2>&1 &
LOAD_PID=$!
ok "load.sh pid=$LOAD_PID (log: /tmp/local-demo-load.log)"

say "Waiting 20s for pyroscope to ingest baseline samples"
sleep 20

# ---- 2. phase 2 ------------------------------------------------------------
say "Phase 2 — starting AI/ML stack"
(cd "$P2_DIR" && ./scripts/up.sh)
# shellcheck disable=SC1091
source "$P2_DIR/.env"

wait_for "localhost:${API_PORT}/health"      "api"      90  strict
wait_for "localhost:${AIRFLOW_PORT}/health"  "airflow" 180 soft
# MLflow on first run pip-installs psycopg2-binary + boto3 before starting
# the server (see ai/docker-compose.yaml). Can take 2-5 min.
wait_for "localhost:${MLFLOW_PORT}/health"   "mlflow"  300 soft
wait_for "localhost:${WEB_PORT}/"            "web"     120 soft

say "Phase 2 — seeding DAGs"
(cd "$P2_DIR" && ./scripts/seed.sh) || warn "seed had non-fatal errors"
sleep 30   # let profile_etl actually produce rows

# ---- 3. incidents ----------------------------------------------------------
say "Injecting 4 incident kinds (sequential, ~6 min total)"
for kind in blocker leak gc contention; do
  printf "\n  -> incident: %s\n" "$kind"
  if (cd "$P2_DIR" && ./scripts/simulate-incident.sh "$kind"); then
    ok "$kind done"
  else
    warn "$kind failed (continuing)"
  fi
done

# ---- 4. trigger analytical DAGs now ---------------------------------------
say "Triggering analytical DAGs (don't wait for schedule)"
for dag in profile_etl anomaly_detect regression_detect; do
  (cd "$P2_DIR" && docker compose exec -T airflow airflow dags trigger "$dag") \
    && ok "triggered $dag" || warn "trigger $dag failed"
done
say "Waiting 60s for regression_detect (LLM call) to finish"
sleep 60

# ---- 5. verify -------------------------------------------------------------
say "Verification"

(cd "$P2_DIR" && docker compose exec -T postgres psql -U postgres -d ai -t -c \
  "SELECT COUNT(*) FROM incidents") | awk '{print "  incidents rows: "$1}'
(cd "$P2_DIR" && docker compose exec -T postgres psql -U postgres -d ai -t -c \
  "SELECT COUNT(*) FROM regressions") | awk '{print "  regressions rows: "$1}'
(cd "$P2_DIR" && docker compose exec -T postgres psql -U postgres -d ai -t -c \
  "SELECT COUNT(*) FROM anomalies") | awk '{print "  anomalies rows: "$1}'
(cd "$P2_DIR" && docker compose exec -T postgres psql -U postgres -d ai -t -c \
  "SELECT COUNT(*) FROM function_features") | awk '{print "  function_features rows: "$1}'

FRAMES=$(curl -s "localhost:${PYROSCOPE_PORT}/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22demo-jvm11%22%7D&from=$(( $(date +%s) - 600 ))&until=$(date +%s)&format=json" \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("flamebearer",{}).get("names",[])))' 2>/dev/null)
ok "pyroscope CPU frames (demo-jvm11, last 10m): ${FRAMES:-0}"

# ---- 6. summary ------------------------------------------------------------
cat <<EOF

$(printf "\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m")
  Demo running. Open in a browser:

  PHASE 1 — profiling
    Grafana     http://localhost:${GRAFANA_PORT}        admin/admin
                → Dashboards → Local Demo → Demo Overview
    Pyroscope   http://localhost:${PYROSCOPE_PORT}

  PHASE 2 — AI/ML
    Web UI      http://localhost:${WEB_PORT}
                → Hotspots, Regression, Incidents, Chat
    API docs    http://localhost:${API_PORT}/docs
    Airflow     http://localhost:${AIRFLOW_PORT}        admin/admin
    MLflow     http://localhost:${MLFLOW_PORT}

  Load generator running: pid=${LOAD_PID} (tail /tmp/local-demo-load.log)
  Stop everything:  $0 --down
$(printf "\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m")
EOF

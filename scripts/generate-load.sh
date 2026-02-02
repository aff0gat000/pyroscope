#!/usr/bin/env bash
set -euo pipefail

# Generates synthetic traffic against all bank microservices so that
# Pyroscope has profiling data to display.

DURATION_SECONDS="${1:-300}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }

API_GW="http://localhost:${API_GATEWAY_PORT:-8080}"
ORDER="http://localhost:${ORDER_SERVICE_PORT:-8081}"
PAYMENT="http://localhost:${PAYMENT_SERVICE_PORT:-8082}"
FRAUD="http://localhost:${FRAUD_SERVICE_PORT:-8083}"
ACCOUNT="http://localhost:${ACCOUNT_SERVICE_PORT:-8084}"
LOAN="http://localhost:${LOAN_SERVICE_PORT:-8085}"
NOTIFY="http://localhost:${NOTIFICATION_SERVICE_PORT:-8086}"
STREAM="http://localhost:${STREAM_SERVICE_PORT:-8087}"
FAAS="http://localhost:${FAAS_SERVICE_PORT:-8088}"

echo "==> Bank Enterprise Load Generator (${DURATION_SECONDS}s)"
echo "    API Gateway :${API_GATEWAY_PORT:-8080} | Order :${ORDER_SERVICE_PORT:-8081} | Payment :${PAYMENT_SERVICE_PORT:-8082} | Fraud :${FRAUD_SERVICE_PORT:-8083}"
echo "    Account :${ACCOUNT_SERVICE_PORT:-8084} | Loan :${LOAN_SERVICE_PORT:-8085} | Notification :${NOTIFICATION_SERVICE_PORT:-8086} | Stream :${STREAM_SERVICE_PORT:-8087}"
echo "    FaaS :${FAAS_SERVICE_PORT:-8088}"
echo "    Press Ctrl-C to stop early."
echo ""

END_TIME=$(($(date +%s) + DURATION_SECONDS))

hit() {
  curl -sf -o /dev/null -w "  %{http_code}  %{time_total}s  $1\n" "$1" --max-time 15 || true
}

while [ "$(date +%s)" -lt "$END_TIME" ]; do
  # API Gateway — mixed workloads (60% light, 30% medium, 10% heavy)
  ROLL=$((RANDOM % 100))
  if [ "$ROLL" -lt 60 ]; then
    EP=("/health" "/redis/get" "/redis/set" "/json/process" "/xml/process")
  elif [ "$ROLL" -lt 90 ]; then
    EP=("/cpu" "/alloc" "/db/select" "/csv/process" "/mixed")
  else
    EP=("/db/join" "/batch/process" "/downstream/fanout")
  fi
  hit "${API_GW}${EP[$((RANDOM % ${#EP[@]}))]}" &

  # Order Service
  OEPS=("/order/create" "/order/list" "/order/validate" "/order/process" "/order/aggregate" "/order/fulfill")
  hit "${ORDER}${OEPS[$((RANDOM % ${#OEPS[@]}))]}" &

  # Payment Service
  PEPS=("/payment/transfer" "/payment/fx" "/payment/orchestrate" "/payment/history" "/payment/payroll" "/payment/reconcile")
  hit "${PAYMENT}${PEPS[$((RANDOM % ${#PEPS[@]}))]}" &

  # Fraud Service
  FEPS=("/fraud/score" "/fraud/ingest" "/fraud/scan" "/fraud/anomaly" "/fraud/velocity" "/fraud/report")
  hit "${FRAUD}${FEPS[$((RANDOM % ${#FEPS[@]}))]}" &

  # Account Service
  AEPS=("/account/open" "/account/balance" "/account/deposit" "/account/withdraw" "/account/statement" "/account/interest" "/account/search" "/account/branch-summary")
  hit "${ACCOUNT}${AEPS[$((RANDOM % ${#AEPS[@]}))]}" &

  # Loan Service
  LEPS=("/loan/apply" "/loan/amortize" "/loan/risk-sim" "/loan/portfolio" "/loan/delinquency" "/loan/originate")
  hit "${LOAN}${LEPS[$((RANDOM % ${#LEPS[@]}))]}" &

  # Notification Service
  NEPS=("/notify/send" "/notify/bulk" "/notify/drain" "/notify/render" "/notify/status" "/notify/retry")
  hit "${NOTIFY}${NEPS[$((RANDOM % ${#NEPS[@]}))]}" &

  # Stream Service
  SEPS=("/stream/transactions" "/stream/windowed-aggregation" "/stream/fanout" "/stream/transform-pipeline" "/stream/backpressure-stress" "/stream/merge-sorted")
  hit "${STREAM}${SEPS[$((RANDOM % ${#SEPS[@]}))]}" &

  # FaaS server — all 10 function verticles
  EFNS=("fibonacci" "transform" "hash" "sort" "sleep" "matrix" "regex" "compress" "primes" "contention" "fanout")
  EROLL=$((RANDOM % 100))
  if [ "$EROLL" -lt 50 ]; then
    # Single invoke — pick any function
    FN="${EFNS[$((RANDOM % ${#EFNS[@]}))]}"
    curl -sf -o /dev/null -w "  %{http_code}  %{time_total}s  POST ${FAAS}/fn/invoke/${FN}\n" \
      -X POST "${FAAS}/fn/invoke/${FN}" -H "Content-Type: application/json" -d '{}' --max-time 15 || true
  elif [ "$EROLL" -lt 75 ]; then
    # Burst — concurrent deploys of same function
    BURST_FNS=("hash" "sort" "regex" "compress" "primes" "matrix" "contention")
    FN="${BURST_FNS[$((RANDOM % ${#BURST_FNS[@]}))]}"
    curl -sf -o /dev/null -w "  %{http_code}  %{time_total}s  POST ${FAAS}/fn/burst/${FN}\n" \
      -X POST "${FAAS}/fn/burst/${FN}?count=$((2 + RANDOM % 5))" -H "Content-Type: application/json" -d '{}' --max-time 30 || true
  elif [ "$EROLL" -lt 90 ]; then
    # Chain — sequential deploy/run/undeploy across different functions
    CHAINS=('["hash","sort","fibonacci"]' '["regex","compress","primes"]' '["transform","matrix","hash"]' '["sleep","sort","compress"]')
    CHAIN="${CHAINS[$((RANDOM % ${#CHAINS[@]}))]}"
    curl -sf -o /dev/null -w "  %{http_code}  %{time_total}s  POST ${FAAS}/fn/chain\n" \
      -X POST "${FAAS}/fn/chain" -H "Content-Type: application/json" \
      -d "{\"chain\":${CHAIN},\"params\":{}}" --max-time 30 || true
  else
    # Fanout — deploy N child verticles in parallel
    FANOUT_FNS=("hash" "primes" "regex")
    FN="${FANOUT_FNS[$((RANDOM % ${#FANOUT_FNS[@]}))]}"
    curl -sf -o /dev/null -w "  %{http_code}  %{time_total}s  POST ${FAAS}/fn/invoke/fanout\n" \
      -X POST "${FAAS}/fn/invoke/fanout" -H "Content-Type: application/json" \
      -d "{\"count\":$((2 + RANDOM % 4)),\"function\":\"${FN}\"}" --max-time 30 || true
  fi &

  wait
  sleep "0.$((RANDOM % 3))"
done

echo ""
echo "==> Load generation complete. Check Pyroscope/Grafana for profiles."

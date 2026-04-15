#!/usr/bin/env bash
# Generate traffic across all demo endpoints on both apps.
# Uses ports from .env (written by up.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && set -a && . ./.env && set +a

J11="http://localhost:${DEMO_JVM11_PORT:-18080}"
J21="http://localhost:${DEMO_JVM21_PORT:-18081}"

hit() { curl -fsS --max-time 5 "$1" >/dev/null 2>&1 || echo "  miss: $1"; }

echo "Load target: $J11  and  $J21"
echo "Ctrl-C to stop."

trap 'echo; echo stopped; exit 0' INT

while true; do
  for base in "$J11" "$J21"; do
    hit "$base/health"
    hit "$base/registry"
    hit "$base/blocking/on-eventloop?ms=50"
    hit "$base/blocking/execute-blocking?ms=80"
    hit "$base/http/client?host=$( [[ $base == $J11 ]] && echo demo-jvm21 || echo demo-jvm11 )&port=8080"
    hit "$base/redis/set?k=demo&v=$RANDOM"
    hit "$base/redis/get?k=demo"
    hit "$base/postgres/query"
    hit "$base/mongo/insert?msg=hello-$RANDOM"
    hit "$base/mongo/find"
    hit "$base/couchbase/upsert?id=d1&v=$RANDOM"
    hit "$base/couchbase/get?id=d1"
    hit "$base/kafka/produce?v=msg-$RANDOM"
    hit "$base/kafka/consume"
    hit "$base/f2f/call?p=ping-$RANDOM"
    hit "$base/framework/future-chain"
    hit "$base/framework/timer"
    hit "$base/vault/read?path=secret/data/demo"
  done
  # occasional thread leak to demonstrate growth; auto-stop every few cycles
  if (( RANDOM % 10 == 0 )); then hit "$J11/leak/start?n=5"; fi
  if (( RANDOM % 20 == 0 )); then hit "$J11/leak/stop"; fi
  # Java 21 virtual-thread endpoint
  hit "$J21/vt/sleep?ms=80"
  sleep 0.5
done

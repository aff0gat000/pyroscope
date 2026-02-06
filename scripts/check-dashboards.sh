#!/usr/bin/env bash
set -euo pipefail

# Validate all Grafana dashboard queries against running Prometheus/Pyroscope.
# Catches stale metric references, wrong label values, etc.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_DIR="$PROJECT_DIR/config/grafana/dashboards"

# Load port assignments
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROJECT_DIR/.env"
  set +a
fi

PROMETHEUS_URL="http://localhost:${PROMETHEUS_PORT:-9090}"
PYROSCOPE_URL="http://localhost:${PYROSCOPE_PORT:-4040}"

# Counters
TOTAL_DASHBOARDS=0
TOTAL_PANELS=0
TOTAL_PASS=0
TOTAL_WARN=0
TOTAL_FAIL=0
HAS_FAIL=0

# Build template variable map from a dashboard JSON.
# Outputs lines: VAR_NAME=VALUE
build_var_map() {
  local json="$1"
  jq -r '
    .templating.list[]? |
    .name as $name |
    # Pick first non-$__all option value, fall back to current.value
    (
      (.options // [])
      | map(select(.value != "$__all"))
      | .[0].value // null
    ) as $opt_val |
    (.current.value // null) as $cur_val |
    $name + "=" + ($opt_val // $cur_val // ".*")
  ' <<< "$json"
}

# Substitute template variables in an expression
substitute_vars() {
  local expr="$1"
  shift
  # Apply each VAR=VALUE pair
  for mapping in "$@"; do
    local var="${mapping%%=*}"
    local val="${mapping#*=}"
    # Replace $var and ${var} forms
    expr="${expr//\$\{$var\}/$val}"
    expr="${expr//\$$var/$val}"
  done
  # Clean up remaining built-in variables
  expr="${expr//\$__all/.*}"
  expr="${expr//\$interval/5m}"
  expr="${expr//\$__interval/5m}"
  expr="${expr//\$__rate_interval/5m}"
  expr="${expr//\$__range/1h}"
  echo "$expr"
}

# Query Prometheus, return series count or -1 on error
query_prometheus() {
  local expr="$1"
  local encoded
  encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$expr" 2>/dev/null || echo "$expr")
  local response
  response=$(curl -sf --max-time 10 "${PROMETHEUS_URL}/api/v1/query?query=${encoded}" 2>/dev/null) || { echo "-1"; return; }
  local count
  count=$(echo "$response" | jq '.data.result | length' 2>/dev/null) || { echo "-1"; return; }
  echo "$count"
}

# Check if a service_name exists in Pyroscope
check_pyroscope_service() {
  local service_name="$1"
  local response
  response=$(curl -sf --max-time 10 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"name":"service_name"}' \
    "${PYROSCOPE_URL}/querier.v1.QuerierService/LabelValues" 2>/dev/null) || { echo "error"; return; }
  if echo "$response" | grep -q "$service_name" 2>/dev/null; then
    echo "found"
  else
    echo "not_found"
  fi
}

# Process a single dashboard file
check_dashboard() {
  local file="$1"
  local json
  json=$(cat "$file")

  local title uid
  title=$(jq -r '.title // "Untitled"' <<< "$json")
  uid=$(jq -r '.uid // "unknown"' <<< "$json")

  TOTAL_DASHBOARDS=$((TOTAL_DASHBOARDS + 1))
  echo ""
  echo "=== $title ($uid) ==="

  # Build variable substitution map
  local var_mappings=()
  while IFS= read -r line; do
    [ -n "$line" ] && var_mappings+=("$line")
  done < <(build_var_map "$json")

  # Extract all PromQL expressions (recursive into nested panels/rows)
  local promql_entries
  promql_entries=$(jq -r '
    [.. | objects | select(.targets?) | {title: .title, targets: .targets}] |
    .[] |
    .title as $title |
    .targets[]? |
    select(.expr? and .expr != "") |
    ($title // "Unnamed") + "\t" + .expr
  ' <<< "$json" 2>/dev/null || true)

  # Extract all Pyroscope labelSelector entries
  local pyroscope_entries
  pyroscope_entries=$(jq -r '
    [.. | objects | select(.targets?) | {title: .title, targets: .targets}] |
    .[] |
    .title as $title |
    .targets[]? |
    select(.labelSelector? and .labelSelector != "") |
    ($title // "Unnamed") + "\t" + .labelSelector
  ' <<< "$json" 2>/dev/null || true)

  # Check PromQL expressions
  if [ -n "$promql_entries" ]; then
    while IFS=$'\t' read -r panel_title expr; do
      [ -z "$expr" ] && continue
      TOTAL_PANELS=$((TOTAL_PANELS + 1))

      local substituted
      substituted=$(substitute_vars "$expr" "${var_mappings[@]+"${var_mappings[@]}"}")

      local count
      count=$(query_prometheus "$substituted")

      if [ "$count" = "-1" ]; then
        echo "  [FAIL] $panel_title — HTTP error querying Prometheus"
        echo "         expr: $substituted"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        HAS_FAIL=1
      elif [ "$count" = "0" ]; then
        echo "  [WARN] $panel_title — 0 series (may need load)"
        TOTAL_WARN=$((TOTAL_WARN + 1))
      else
        echo "  [PASS] $panel_title — $count series"
        TOTAL_PASS=$((TOTAL_PASS + 1))
      fi
    done <<< "$promql_entries"
  fi

  # Check Pyroscope labelSelector entries
  if [ -n "$pyroscope_entries" ]; then
    while IFS=$'\t' read -r panel_title selector; do
      [ -z "$selector" ] && continue
      TOTAL_PANELS=$((TOTAL_PANELS + 1))

      local substituted
      substituted=$(substitute_vars "$selector" "${var_mappings[@]+"${var_mappings[@]}"}")

      # Extract service_name value from selector like {service_name="bank-api-gateway"}
      local service_name
      service_name=$(echo "$substituted" | sed -n 's/.*service_name="\([^"]*\)".*/\1/p' | head -1)

      if [ -z "$service_name" ] || [ "$service_name" = '.*' ]; then
        echo "  [PASS] $panel_title — Pyroscope (wildcard/dynamic)"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        continue
      fi

      local result
      result=$(check_pyroscope_service "$service_name")

      if [ "$result" = "found" ]; then
        echo "  [PASS] $panel_title — $service_name found in Pyroscope"
        TOTAL_PASS=$((TOTAL_PASS + 1))
      elif [ "$result" = "not_found" ]; then
        echo "  [WARN] $panel_title — $service_name not found in Pyroscope (may need load)"
        TOTAL_WARN=$((TOTAL_WARN + 1))
      else
        echo "  [FAIL] $panel_title — error querying Pyroscope"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        HAS_FAIL=1
      fi
    done <<< "$pyroscope_entries"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "Checking Grafana dashboards against running Prometheus/Pyroscope..."
echo "  Prometheus: $PROMETHEUS_URL"
echo "  Pyroscope:  $PYROSCOPE_URL"

# Verify connectivity
if ! curl -sf --max-time 5 "$PROMETHEUS_URL/-/ready" >/dev/null 2>&1; then
  echo ""
  echo "ERROR: Prometheus not reachable at $PROMETHEUS_URL"
  echo "  Is the stack running? Try: bash scripts/run.sh deploy"
  exit 1
fi

for file in "$DASHBOARD_DIR"/*.json; do
  [ -f "$file" ] || continue
  check_dashboard "$file"
done

echo ""
echo "=== Results ==="
echo "  Dashboards: $TOTAL_DASHBOARDS  Panels: $TOTAL_PANELS"
echo "  Passed: $TOTAL_PASS  Warnings: $TOTAL_WARN  Failed: $TOTAL_FAIL"
echo ""

exit "$HAS_FAIL"

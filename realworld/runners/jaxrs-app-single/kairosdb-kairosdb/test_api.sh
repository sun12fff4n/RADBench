#!/usr/bin/env bash
# kairosdb — smoke test.


set -u

BASE="${BASE:-http://localhost:8080}"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; DIM='\033[2m'; N='\033[0m'
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

req() {
  local label="$1" expected="$2"; shift 2
  local body="$TMP/body"
  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^($expected)$ ]]; then
    printf "${G}PASS${N} %-60s ${DIM}[%s]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-60s ${DIM}[got %s, want %s]${N}\n" "$label" "$code" "$expected"
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -c 300 "$body" | sed 's/^/  /'; echo; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

req_body() {
  local label="$1" expected="$2" pattern="$3"; shift 3
  local body="$TMP/body"
  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  local status_ok=0 body_ok=0
  [[ "$code" =~ ^($expected)$ ]] && status_ok=1
  grep -qF "$pattern" "$body" 2>/dev/null && body_ok=1
  if [[ $status_ok -eq 1 && $body_ok -eq 1 ]]; then
    printf "${G}PASS${N} %-60s ${DIM}[%s, body ✓]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    local reason
    if [[ $status_ok -eq 0 ]]; then reason="got $code, want $expected"
    else reason="body missing '$pattern'"; fi
    printf "${R}FAIL${N} %-60s ${DIM}[%s]${N}\n" "$label" "$reason"
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -c 300 "$body" | sed 's/^/  /'; echo; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

req_fields() {
  local label="$1" expected="$2" patterns="$3"; shift 3
  local body="$TMP/body" code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  if [[ ! "$code" =~ ^($expected)$ ]]; then
    printf "${R}FAIL${N} %-60s ${DIM}[got %s, want %s]${N}\n" "$label" "$code" "$expected"
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -c 300 "$body" | sed 's/^/  /'; echo; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
    return
  fi
  local missing=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    grep -qF "$p" "$body" 2>/dev/null || missing+=("$p")
  done <<< "$patterns"
  if [[ ${#missing[@]} -eq 0 ]]; then
    printf "${G}PASS${N} %-60s ${DIM}[%s, all fields ✓]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-60s ${DIM}[missing: %s]${N}\n" "$label" "${missing[*]}"
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -c 300 "$body" | sed 's/^/  /'; echo; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

req_header() {
  local label="$1" expected_code="$2" header_pattern="$3"; shift 3
  local body="$TMP/body" headers="$TMP/headers"
  local code
  code=$(curl -sS -o "$body" -D "$headers" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  local status_ok=0 header_ok=0
  [[ "$code" =~ ^($expected_code)$ ]] && status_ok=1
  grep -qi "$header_pattern" "$headers" 2>/dev/null && header_ok=1
  if [[ $status_ok -eq 1 && $header_ok -eq 1 ]]; then
    printf "${G}PASS${N} %-60s ${DIM}[%s, header ✓]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    local reason
    if [[ $status_ok -eq 0 ]]; then reason="got $code, want $expected_code"
    else reason="header missing '$header_pattern'"; fi
    printf "${R}FAIL${N} %-60s ${DIM}[%s]${N}\n" "$label" "$reason"
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

# ==================================================================
section "Version endpoint — MetricsResource (Guice DI, JAX-RS)"
# Tests: MetricsResource.getVersion(), Guice injection, JAX-RS @Path/@GET
# ==================================================================

req_body "GET  /api/v1/version" "200" \
    '"version"' \
    "$BASE/api/v1/version"

req_header "GET  /api/v1/version (JSON content-type)" "200" "application/json" \
    "$BASE/api/v1/version"

# ==================================================================
section "Health check — HealthCheckResource (Codahale HealthCheck)"
# Tests: HealthCheckResource.check(), HealthCheckService DI binding,
#        HealthCheck.execute(), response code mapping
# ==================================================================

req "GET  /api/v1/health/check (→ 204 healthy)" "204" \
    "$BASE/api/v1/health/check"

req_body "GET  /api/v1/health/status" "200" \
    "OK" \
    "$BASE/api/v1/health/status"

# ==================================================================
section "Metric names — MetricsResource (Datastore query)"
# Tests: MetricsResource.getMetricNames(), datastore.getMetricNames(),
#        H2Datastore initialization, JSON response serialization
# ==================================================================

req_body "GET  /api/v1/metricnames (results array)" "200" \
    '"results"' \
    "$BASE/api/v1/metricnames"

# ==================================================================
section "Data ingestion — MetricsResource (DataPointsParser, Gson)"
# Tests: MetricsResource.add(), DataPointsParser.parse(), KairosDataPointFactory,
#        Gson deserialization, ValidationErrors, publisher chain
# ==================================================================

req "POST /api/v1/datapoints (ingest metric)" "204" \
    -X POST -H "Content-Type: application/json" \
    -d '[{"name":"test.metric","timestamp":1609459200000,"value":42,"tags":{"host":"testhost"}}]' \
    "$BASE/api/v1/datapoints"

req "POST /api/v1/datapoints (batch ingest)" "204" \
    -X POST -H "Content-Type: application/json" \
    -d '[{"name":"test.metric","timestamp":1609459201000,"value":43,"tags":{"host":"testhost"}},{"name":"test.metric","timestamp":1609459202000,"value":44,"tags":{"host":"testhost"}}]' \
    "$BASE/api/v1/datapoints"

# Invalid payload → 400
req_body "POST /api/v1/datapoints (invalid JSON → 400)" "400" \
    "error" \
    -X POST -H "Content-Type: application/json" \
    -d 'not-json-at-all' \
    "$BASE/api/v1/datapoints"

# Missing required fields
req_body "POST /api/v1/datapoints (missing name → 400)" "400" \
    "error" \
    -X POST -H "Content-Type: application/json" \
    -d '[{"timestamp":1609459200000,"value":42,"tags":{"host":"testhost"}}]' \
    "$BASE/api/v1/datapoints"

# gzip-compressed ingestion (triggers MetricsResource.addGzip, GZIPInputStream)
GZIP_PAYLOAD=$(printf '[{"name":"test.gzip","timestamp":1609459200000,"value":99,"tags":{"host":"gziphost"}}]' | gzip | base64)
if command -v base64 >/dev/null && command -v gzip >/dev/null; then
  printf '[{"name":"test.gzip","timestamp":1609459200000,"value":99,"tags":{"host":"gziphost"}}]' \
    | gzip > "$TMP/gzip_payload.gz"
  req "POST /api/v1/datapoints (gzip content-encoding)" "204|200" \
      -X POST -H "Content-Type: application/gzip" \
      --data-binary @"$TMP/gzip_payload.gz" \
      "$BASE/api/v1/datapoints"
fi

# ==================================================================
section "Data query — MetricsResource (QueryParser, DatastoreQuery)"
# Tests: MetricsResource.postQuery(), QueryParser.parseQueryMetric(),
#        DatastoreQuery.execute(), JsonResponse formatting, query plugins
# ==================================================================

req_fields "POST /api/v1/datapoints/query (query metric)" "200" \
'"queries"
"results"
"name":"test.metric"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"start_absolute":1609459200000,"end_absolute":1609459300000,"metrics":[{"name":"test.metric"}]}' \
    "$BASE/api/v1/datapoints/query"

# Query with aggregator
req_fields "POST /api/v1/datapoints/query (with aggregator)" "200" \
'"queries"
"results"
"values"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"start_absolute":1609459200000,"end_absolute":1609459300000,"metrics":[{"name":"test.metric","aggregators":[{"name":"sum","sampling":{"value":1,"unit":"minutes"}}]}]}' \
    "$BASE/api/v1/datapoints/query"

# Query with group_by (triggers GroupBy plugin reflection)
req_body "POST /api/v1/datapoints/query (group_by tag)" "200" \
    '"results"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"start_absolute":1609459200000,"end_absolute":1609459300000,"metrics":[{"name":"test.metric","group_by":[{"name":"tag","tags":["host"]}]}]}' \
    "$BASE/api/v1/datapoints/query"

# Query with group_by time
req_body "POST /api/v1/datapoints/query (group_by time)" "200" \
    '"results"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"start_absolute":1609459200000,"end_absolute":1609459300000,"metrics":[{"name":"test.metric","group_by":[{"name":"time","group_count":1,"range_size":{"value":1,"unit":"minutes"}}]}]}' \
    "$BASE/api/v1/datapoints/query"

# Invalid query → 400
req_body "POST /api/v1/datapoints/query (no metrics → 400)" "400" \
    "error" \
    -X POST -H "Content-Type: application/json" \
    -d '{"start_absolute":1609459200000}' \
    "$BASE/api/v1/datapoints/query"

# ==================================================================
section "Query tags — MetricsResource (tag query path)"
# Tests: MetricsResource.postQueryTags(), QueryParser, tag resolution
# ==================================================================

req_body "POST /api/v1/datapoints/query/tags" "200" \
    '"queries"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"start_absolute":1609459200000,"end_absolute":1609459300000,"metrics":[{"name":"test.metric"}]}' \
    "$BASE/api/v1/datapoints/query/tags"

# ==================================================================
section "Features — FeaturesResource (FeatureProcessor DI)"
# Tests: FeaturesResource.getFeatures(), FeatureProcessor chain, Gson
# ==================================================================

req "GET  /api/v1/features (list features)" "200" \
    "$BASE/api/v1/features"

req_body "GET  /api/v1/features/aggregators" "200" \
    '"name"' \
    "$BASE/api/v1/features/aggregators"

req_body "GET  /api/v1/features/nonexistent (→ 404)" "404" \
    "error" \
    "$BASE/api/v1/features/nonexistent"

# ==================================================================
section "Rollups — RollUpResource (RollUpTasksStore, Scheduler)"
# Tests: RollUpResource.create/list/get/update/delete, Gson, Scheduler
# ==================================================================

req "GET  /api/v1/rollups (list rollups)" "200|404" \
    "$BASE/api/v1/rollups"

# Create a rollup task (triggers Gson deserialization, RollUpTasksStore.write)
ROLLUP_RESP=$(curl -sS -o "$TMP/rollup_body" -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d '{"name":"smoke_rollup","execution_interval":{"value":1,"unit":"hours"},"rollups":[{"save_as":"test.rollup.result","query":{"start_relative":{"value":1,"unit":"hours"},"metrics":[{"name":"test.metric"}]}}]}' \
    "$BASE/api/v1/rollups" 2>/dev/null)
if [[ "$ROLLUP_RESP" =~ ^(200|201|204)$ ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[%s]${N}\n" "POST /api/v1/rollups (create rollup)" "$ROLLUP_RESP"
  PASS=$((PASS+1))
  ROLLUP_ID=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\).*/\1/p' "$TMP/rollup_body" | head -1)
  if [[ -n "$ROLLUP_ID" ]]; then
    req "GET  /api/v1/rollups/{id} (get rollup)" "200" \
        "$BASE/api/v1/rollups/$ROLLUP_ID"
    req "GET  /api/v1/rollups/status/{id}" "200|404" \
        "$BASE/api/v1/rollups/status/$ROLLUP_ID"
    req "DELETE /api/v1/rollups/{id} (delete rollup)" "200|204" \
        -X DELETE "$BASE/api/v1/rollups/$ROLLUP_ID"
  fi
else
  printf "${R}FAIL${N} %-60s ${DIM}[got %s, want 200|201|204]${N}\n" "POST /api/v1/rollups (create rollup)" "$ROLLUP_RESP"
  FAIL=$((FAIL+1))
fi

# ==================================================================
section "Admin — AdminResource (QueryQueuingManager, Scheduler)"
# Tests: AdminResource.listScheduledJobs(), AdminResource.listRunningQueries(),
#        QueryQueuingManager DI injection, KairosDBScheduler
# ==================================================================

req "GET  /api/v1/admin/scheduledjobs" "200" \
    "$BASE/api/v1/admin/scheduledjobs"

req_fields "GET  /api/v1/admin/runningqueries" "200" \
'"queries"
"queries waiting"' \
    "$BASE/api/v1/admin/runningqueries"

# ==================================================================
section "Metric delete — MetricsResource (H2Datastore.deleteDataPoints)"
# Tests: MetricsResource.delete(), H2Datastore delete path, CachedSearchResult
# ==================================================================

req "DELETE /api/v1/metric/test.metric (delete metric)" "200|204|404" \
    -X DELETE "$BASE/api/v1/metric/test.metric"

# Post-delete query to confirm
req "POST /api/v1/datapoints/delete (delete by query)" "200|204" \
    -X POST -H "Content-Type: application/json" \
    -d '{"metrics":[{"name":"test.metric.old"}],"start_absolute":0,"end_absolute":1609459300000}' \
    "$BASE/api/v1/datapoints/delete"

# ==================================================================
section "Metadata — MetadataResource (ServiceKeyStore CRUD)"
# Tests: MetadataResource.list/get/setValue/delete, H2Datastore metadata ops
# ==================================================================

req "GET  /api/v1/metadata/grafana (list service keys)" "200" \
    "$BASE/api/v1/metadata/grafana"

# Write metadata value (triggers H2Datastore.setValue)
req "POST /api/v1/metadata/grafana/smoke_key/test_val" "200|204" \
    -X POST -H "Content-Type: text/plain" \
    -d 'smoke_value' \
    "$BASE/api/v1/metadata/grafana/smoke_key/test_val"

# Read back metadata
req "GET  /api/v1/metadata/grafana/smoke_key" "200" \
    "$BASE/api/v1/metadata/grafana/smoke_key"

req "GET  /api/v1/metadata/grafana/smoke_key/test_val" "200" \
    "$BASE/api/v1/metadata/grafana/smoke_key/test_val"

# Delete metadata
req "DELETE /api/v1/metadata/grafana/smoke_key/test_val" "200|204" \
    -X DELETE "$BASE/api/v1/metadata/grafana/smoke_key/test_val"

# ==================================================================
section "Static web UI — Jetty StaticFileHandler"
# Tests: WebServletModule configuration, static_web_root binding, Jetty serving
# ==================================================================

req_body "GET  / (web UI root)" "200" \
    "kairosdb" \
    "$BASE/"

req_header "GET  / (Content-Type: text/html)" "200" "text/html" \
    "$BASE/"

# ==================================================================
section "CORS support — MetricsResource.setHeaders()"
# Tests: CORS header injection, Access-Control-Allow-Origin
# ==================================================================

req_header "GET  /api/v1/version (CORS headers)" "200" "Access-Control-Allow-Origin" \
    "$BASE/api/v1/version"

# ==================================================================
section "Error paths — 404/405 for unknown endpoints"
# Tests: JAX-RS routing, no-match handling
# ==================================================================

req "GET  /api/v1/nonexistent (→ 404)" "404" \
    "$BASE/api/v1/nonexistent"

req "DELETE /api/v1/version (→ 405)" "405" \
    -X DELETE "$BASE/api/v1/version"

# ==================================================================
section "Concurrent requests — Jetty thread pool"
# Tests: Non-blocking I/O, multiple clients served concurrently
# ==================================================================

pids=()
for i in $(seq 1 5); do
  curl -sS -o /dev/null -w "%{http_code}" "$BASE/api/v1/version" > "$TMP/par_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 5); do
  c=$(cat "$TMP/par_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "5x parallel GET /api/v1/version"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "5x parallel GET /api/v1/version"
  FAIL=$((FAIL+1))
fi

# ==================================================================
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

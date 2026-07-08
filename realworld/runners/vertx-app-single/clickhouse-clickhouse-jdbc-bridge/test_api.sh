#!/usr/bin/env bash
# clickhouse-jdbc-bridge — smoke test.
# Tests Vert.x Verticle deployment, Router-based HTTP handling,
# ClickHouse bridge protocol endpoints, Micrometer metrics, and
# extension/repository loading via reflection.
#
# Reflection-intensive paths exercised:
#   - Vert.x Verticle deployment (AbstractVerticle.start, vertx.deployVerticle)
#   - Extension loading via Utils.loadExtension() (Class.forName, newInstance)
#   - RepositoryManager SPI loading (ServiceLoader + reflection)
#   - JsonFileRepository initialization (config file scanning)
#   - JdbcDataSource / ConfigDataSource / ScriptDataSource instantiation
#   - Router.route() with BodyHandler, ResponseContentTypeHandler, TimeoutHandler
#   - Micrometer MeterRegistry binding (JVM/GC/Thread/Processor metrics)
#   - PrometheusScrapingHandler (Vert.x metrics export)
#   - HttpServerOptions from JSON config (Vert.x config binding)
#   - QueryParser.fromRequest() (request parameter extraction)
#
# Usage:
#   ./test_api.sh
#   BASE=http://host:port ./test_api.sh
#   ./test_api.sh --stop-on-fail

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
section "Ping — health check (Vert.x Router GET handler)"
# Tests: JdbcBridgeVerticle.handlePing(), Router.get("/ping"),
#        HttpServer.requestHandler(router), Verticle deployment
# ==================================================================

req_body "GET  /ping (→ Ok.)" "200" \
    "Ok." \
    "$BASE/ping"

# ==================================================================
section "Schema allowed — bridge protocol endpoint"
# Tests: JdbcBridgeVerticle.handleSchemaAllowed(), Router.get("/schema_allowed")
# ==================================================================

req_body "GET  /schema_allowed (→ 1)" "200" \
    "1" \
    "$BASE/schema_allowed"

# ==================================================================
section "Identifier quote — POST handler"
# Tests: JdbcBridgeVerticle.handleIdentifierQuote(), BodyHandler,
#        ResponseContentTypeHandler, NamedDataSource.DEFAULT_QUOTE_IDENTIFIER
# ==================================================================

req "POST /identifier_quote (→ 200)" "200" \
    -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "" \
    "$BASE/identifier_quote"

# ==================================================================
section "Prometheus metrics — Micrometer integration"
# Tests: PrometheusScrapingHandler, MicrometerMetricsOptions,
#        JvmMemoryMetrics, JvmGcMetrics, JvmThreadMetrics binding
# ==================================================================

req_fields "GET  /metrics (Prometheus scrape)" "200" \
'jvm_memory
jvm_threads
process_uptime
jvm_gc' \
    "$BASE/metrics"

req_header "GET  /metrics (text/plain content-type)" "200" "text/plain" \
    "$BASE/metrics"

# ==================================================================
section "Columns info — POST /columns_info"
# Tests: QueryParser.fromRequest(), ConfigDataSource resolution,
#        NamedDataSource lookup, TableDefinition generation
# ==================================================================

# Without a valid datasource, should return 500 (no datasource configured)
req "POST /columns_info (no datasource → 500)" "500" \
    -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "" \
    "$BASE/columns_info"

# ==================================================================
section "Query execution — POST / (blocking handler)"
# Tests: JdbcBridgeVerticle.handleQuery(), blockingHandler(SERIAL_MODE),
#        QueryParser, NamedDataSource.executeQuery(), ResponseWriter
# ==================================================================

# Without a valid datasource, should return 500
req "POST / (query without datasource → 500)" "500" \
    -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "" \
    "$BASE/"

# ==================================================================
section "Write endpoint — POST /write"
# Tests: JdbcBridgeVerticle.handleWrite(), blockingHandler
# ==================================================================

req "POST /write (without datasource → 500)" "500" \
    -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "" \
    "$BASE/write"

# ==================================================================
section "Error paths — unknown routes"
# Tests: Router no-match behavior, Vert.x default 404
# ==================================================================

req "GET  /nonexistent (→ 404)" "404" \
    "$BASE/nonexistent"

req "GET  /api/v1/status (→ 404)" "404" \
    "$BASE/api/v1/status"

# ==================================================================
section "Concurrent requests — Vert.x event loop"
# Tests: Non-blocking I/O, multiple clients served concurrently
# ==================================================================

pids=()
for i in $(seq 1 5); do
  curl -sS -o /dev/null -w "%{http_code}" "$BASE/ping" > "$TMP/par_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 5); do
  c=$(cat "$TMP/par_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "5x parallel GET /ping"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "5x parallel GET /ping"
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

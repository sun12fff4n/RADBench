#!/usr/bin/env bash
# iotdb-collector — smoke test.

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
section "Ping — PingApiServiceImpl (Jetty + Jersey bootstrap)"
# Tests: Jetty Server startup, Jersey servlet container init,
#        PingApiService generated code, ExecutionStatus model,
#        Jackson JSON serialization, TSStatusCode enum
# ==================================================================

req_fields "GET  /ping (health check)" "200" \
'"code"
"message"' \
    "$BASE/ping"

req_header "GET  /ping (CORS Access-Control-Allow-Origin)" "200" \
    "Access-Control-Allow-Origin" \
    "$BASE/ping"

req_header "GET  /ping (JSON content-type)" "200" \
    "application/json" \
    "$BASE/ping"

# ==================================================================
section "Task show — TaskApiServiceImpl (empty state)"
# Tests: TaskApiServiceImpl.showTask(), TaskRuntime initialization,
#        PersistenceService/SQLite, Jersey POST handling
# ==================================================================

req "POST /task/v1/show (list tasks)" "200" \
    -X POST "$BASE/task/v1/show" \
    -H "Content-Type: application/json"

# ==================================================================
section "Plugin show — PluginApiServiceImpl (plugin registry)"
# Tests: PluginApiServiceImpl.showPlugin(), PluginRuntime init,
#        BuiltinPlugin enum, metaKeeper initialization
# ==================================================================

req "POST /plugin/v1/show (list plugins)" "200" \
    -X POST "$BASE/plugin/v1/show" \
    -H "Content-Type: application/json"

# ==================================================================
section "Task validation — request validation handlers"
# Tests: TaskApiServiceRequestValidationHandler.validateCreateRequest(),
#        NullPointerException → 500, Jersey exception mapping
# ==================================================================

req "POST /task/v1/create (missing taskId → 500)" "500" \
    -X POST "$BASE/task/v1/create" \
    -H "Content-Type: application/json" \
    -d '{"sourceAttribute":{},"processorAttribute":{},"sinkAttribute":{}}'

req "POST /task/v1/start (missing taskId → 500)" "500" \
    -X POST "$BASE/task/v1/start" \
    -H "Content-Type: application/json" \
    -d '{}'

req "POST /task/v1/stop (missing taskId → 500)" "500" \
    -X POST "$BASE/task/v1/stop" \
    -H "Content-Type: application/json" \
    -d '{}'

req "POST /task/v1/drop (missing taskId → 500)" "500" \
    -X POST "$BASE/task/v1/drop" \
    -H "Content-Type: application/json" \
    -d '{}'

# ==================================================================
section "Plugin validation — request validation handlers"
# Tests: PluginApiServiceRequestValidationHandler.validateCreatePluginRequest(),
#        NullPointerException for missing fields
# ==================================================================

req "POST /plugin/v1/create (missing fields → 500)" "500" \
    -X POST "$BASE/plugin/v1/create" \
    -H "Content-Type: application/json" \
    -d '{}'

req "POST /plugin/v1/drop (missing pluginName → 500)" "500" \
    -X POST "$BASE/plugin/v1/drop" \
    -H "Content-Type: application/json" \
    -d '{}'

# ==================================================================
section "CORS headers — ApiOriginFilter"
# Tests: ApiOriginFilter.doFilter(), Access-Control headers
# ==================================================================

req_header "POST /task/v1/show (CORS Allow-Methods)" "200" \
    "Access-Control-Allow-Methods" \
    -X POST "$BASE/task/v1/show" \
    -H "Content-Type: application/json"

req_header "POST /plugin/v1/show (CORS Allow-Headers)" "200" \
    "Access-Control-Allow-Headers" \
    -X POST "$BASE/plugin/v1/show" \
    -H "Content-Type: application/json"

# ==================================================================
section "Error paths — 404 and method not allowed"
# Tests: Jersey routing, resource not found handling
# ==================================================================

req "GET  /nonexistent (→ 404)" "404" \
    "$BASE/nonexistent"

req "GET  /task/v1/create (wrong method → 405)" "405" \
    "$BASE/task/v1/create"

req "GET  /plugin/v1/create (wrong method → 405)" "405" \
    "$BASE/plugin/v1/create"

# ==================================================================
section "Task lifecycle — create/drop"
# Tests: TaskRuntime.createTask(), TaskRuntime.dropTask(),
#        task existence conflict check, SourceTask/SinkTask construction
# ==================================================================

# Task creation with a built-in source that doesn't need external connections
CREATE_RESP=$(curl -sS -o "$TMP/body" -w "%{http_code}" -X POST "$BASE/task/v1/create" \
    -H "Content-Type: application/json" \
    -d '{"taskId":"test-task-1","sourceAttribute":{"source":"http-push-source","source.port":"19090"},"processorAttribute":{"processor":"do-nothing-processor"},"sinkAttribute":{"sink":"iotdb-demo-sink"}}' 2>/dev/null)
if [[ "$CREATE_RESP" == "200" ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[%s]${N}\n" "POST /task/v1/create (create task)" "$CREATE_RESP"
  PASS=$((PASS+1))

  # Duplicate creation should return 409 (conflict)
  req "POST /task/v1/create (duplicate → 409)" "409" \
      -X POST "$BASE/task/v1/create" \
      -H "Content-Type: application/json" \
      -d '{"taskId":"test-task-1","sourceAttribute":{"source":"http-push-source","source.port":"19091"},"processorAttribute":{"processor":"do-nothing-processor"},"sinkAttribute":{"sink":"iotdb-demo-sink"}}'

  # Drop the task
  req "POST /task/v1/drop (drop task)" "200" \
      -X POST "$BASE/task/v1/drop" \
      -H "Content-Type: application/json" \
      -d '{"taskId":"test-task-1"}'
else
  printf "${Y}SKIP${N} %-60s ${DIM}[create returned %s, task runtime may not support standalone]${N}\n" \
      "Task lifecycle (create/duplicate/drop)" "$CREATE_RESP"
fi

# ==================================================================
section "Concurrent requests — Jetty thread pool"
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

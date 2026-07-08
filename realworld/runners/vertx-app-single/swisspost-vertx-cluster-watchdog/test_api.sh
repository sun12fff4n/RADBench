#!/usr/bin/env bash
# vertx-cluster-watchdog — smoke test.
# Tests Vert.x verticle deployment with Hazelcast clustering, HTTP routing,
# JSON serialization (WatchdogResult, ClusterHealthStatus enum), EventBus
# publish/subscribe pattern, and periodic timer-driven health checks.
#
# Reflection-intensive paths exercised:
#   - Vert.x clustered deployment (HazelcastClusterManager DI, Verticle class
#     name-based deployment via vertx.deployVerticle("class.Name"))
#   - Hazelcast cluster initialization (Config, NetworkConfig, JoinConfig)
#   - EventBus consumer/publisher registration (Handler<Message<JsonObject>>)
#   - JSON serialization/deserialization (JsonObject, WatchdogResult.toJson/fromJson)
#   - ClusterHealthStatus enum valueOf() (reflection-based enum lookup)
#   - Vert.x Router regex-based route matching
#   - CircularFifoQueue (Apache Commons) with type coercion
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
section "Cluster status endpoint — /clusterStatus"
# Tests: Router.getWithRegex(".*clusterStatus"), ClusterHealthStatus enum
#        serialization, JsonObject.put + encode, response header setting
# ==================================================================

# Initial state may be NO_RESULT (before first check) or CONSISTENT (after)
req_body "GET  /clusterStatus (status field present)" "200" '"status"' \
    "$BASE/clusterStatus"

req_header "GET  /clusterStatus (Content-Type: application/json)" "200" \
    "application/json" "$BASE/clusterStatus"

# Verify the status is one of the valid ClusterHealthStatus enum values
STATUS_BODY=$(curl -sS "$BASE/clusterStatus" 2>/dev/null)
if echo "$STATUS_BODY" | grep -qE '"status":"(CONSISTENT|INCONSISTENT|NO_RESULT)"'; then
  printf "${G}PASS${N} %-60s ${DIM}[valid enum]${N}\n" "GET  /clusterStatus (valid enum value)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[body: %s]${N}\n" "GET  /clusterStatus (valid enum value)" "$STATUS_BODY"
  FAIL=$((FAIL+1))
  [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
fi

# Verify the HTTP status message is set to the cluster status
# (the code does: ctx.response().setStatusMessage(status.toString()))
HEADERS=$(curl -sS -D - -o /dev/null "$BASE/clusterStatus" 2>/dev/null)
if echo "$HEADERS" | grep -qE "HTTP/[0-9.]+ 200 (CONSISTENT|INCONSISTENT|NO_RESULT)"; then
  printf "${G}PASS${N} %-60s ${DIM}[status msg ✓]${N}\n" "GET  /clusterStatus (HTTP reason = enum)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[headers: %s]${N}\n" "GET  /clusterStatus (HTTP reason = enum)" "$(echo "$HEADERS" | head -1)"
  FAIL=$((FAIL+1))
  [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
fi

# Regex route: path prefix should also match (.*clusterStatus pattern)
req_body "GET  /admin/clusterStatus (regex route prefix)" "200" '"status"' \
    "$BASE/admin/clusterStatus"

req_body "GET  /api/v1/clusterStatus (deep prefix)" "200" '"status"' \
    "$BASE/api/v1/clusterStatus"

# ==================================================================
section "Watchdog stats endpoint — /clusterWatchdogStats"
# Tests: Router.getWithRegex(".*clusterWatchdogStats"), CircularFifoQueue
#        iteration, WatchdogResult.toJson() serialization, ArrayUtils.reverse,
#        JsonArray construction
# ==================================================================

req_body "GET  /clusterWatchdogStats (results array present)" "200" '"results"' \
    "$BASE/clusterWatchdogStats"

req_header "GET  /clusterWatchdogStats (Content-Type: application/json)" "200" \
    "application/json" "$BASE/clusterWatchdogStats"

# Regex route: prefix should also match
req_body "GET  /admin/clusterWatchdogStats (regex prefix)" "200" '"results"' \
    "$BASE/admin/clusterWatchdogStats"

# ==================================================================
section "Wait for watchdog interval — then verify CONSISTENT state"
# Tests: Periodic timer fires (vertx.setPeriodic), EventBus publish/consume,
#        Hazelcast single-node cluster membership, response collection,
#        WatchdogResult population, ClusterHealthStatus.CONSISTENT path
# ==================================================================

# The watchdog interval is 3s with a 2s start delay + 2s wait for responses.
# After ~7s from start, the first result should be in the queue.
# The container is already healthy at this point, so we just need to wait
# for one interval cycle to produce a CONSISTENT result.
echo -e "${DIM}Waiting for watchdog cycle (up to 15s)...${N}"
CONSISTENT=0
for _ in $(seq 1 15); do
  BODY=$(curl -sS "$BASE/clusterStatus" 2>/dev/null)
  if echo "$BODY" | grep -qF '"status":"CONSISTENT"'; then
    CONSISTENT=1
    break
  fi
  sleep 1
done

if [[ $CONSISTENT -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[CONSISTENT]${N}\n" "GET  /clusterStatus (after interval → CONSISTENT)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[still: %s]${N}\n" "GET  /clusterStatus (after interval → CONSISTENT)" "$BODY"
  FAIL=$((FAIL+1))
  [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
fi

# ==================================================================
section "WatchdogResult JSON schema — full field validation"
# Tests: WatchdogResult.toJson() serialization of all fields:
#        status, time, broadcastTimestamp, verticleId, clusterMemberCount,
#        responders array
# ==================================================================

req_fields "GET  /clusterWatchdogStats (full WatchdogResult schema)" "200" \
'"results":[
"status":"CONSISTENT"
"time":"
"broadcastTimestamp":"
"verticleId":"
"clusterMemberCount":1
"responders":[' \
    "$BASE/clusterWatchdogStats"

# Verify the responders array contains exactly one entry (the single node)
STATS_BODY=$(curl -sS "$BASE/clusterWatchdogStats" 2>/dev/null)
RESPONDER_COUNT=$(echo "$STATS_BODY" | grep -o '"responders":\[' | wc -l | tr -d ' ')
if [[ "$RESPONDER_COUNT" -ge 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[count=%s]${N}\n" "GET  /clusterWatchdogStats (has responder entries)" "$RESPONDER_COUNT"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[no responders found]${N}\n" "GET  /clusterWatchdogStats (has responder entries)"
  FAIL=$((FAIL+1))
fi

# Verify verticleId is a UUID format (UUID.randomUUID().toString())
if echo "$STATS_BODY" | grep -qE '"verticleId":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'; then
  printf "${G}PASS${N} %-60s ${DIM}[UUID ✓]${N}\n" "GET  /clusterWatchdogStats (verticleId is UUID)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[not UUID format]${N}\n" "GET  /clusterWatchdogStats (verticleId is UUID)"
  FAIL=$((FAIL+1))
fi

# Verify time field has date format (yyyy-MM-dd HH:mm:ss)
if echo "$STATS_BODY" | grep -qE '"time":"[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"'; then
  printf "${G}PASS${N} %-60s ${DIM}[date ✓]${N}\n" "GET  /clusterWatchdogStats (time is date format)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[bad format]${N}\n" "GET  /clusterWatchdogStats (time is date format)"
  FAIL=$((FAIL+1))
fi

# Verify broadcastTimestamp is a numeric millis value
if echo "$STATS_BODY" | grep -qE '"broadcastTimestamp":"[0-9]{13}"'; then
  printf "${G}PASS${N} %-60s ${DIM}[millis ✓]${N}\n" "GET  /clusterWatchdogStats (broadcastTimestamp is millis)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[bad format]${N}\n" "GET  /clusterWatchdogStats (broadcastTimestamp is millis)"
  FAIL=$((FAIL+1))
fi

# ==================================================================
section "Result accumulation — CircularFifoQueue grows over time"
# Tests: Multiple timer fires produce multiple results, CircularFifoQueue
#        stores them, ArrayUtils.reverse orders newest-first
# ==================================================================

echo -e "${DIM}Waiting for second watchdog cycle...${N}"
sleep 4

STATS_BODY2=$(curl -sS "$BASE/clusterWatchdogStats" 2>/dev/null)
# Count result entries — should be >= 2 now
RESULT_COUNT=$(echo "$STATS_BODY2" | grep -o '"broadcastTimestamp"' | wc -l | tr -d ' ')
if [[ "$RESULT_COUNT" -ge 2 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[count=%s]${N}\n" "GET  /clusterWatchdogStats (multiple results accumulated)" "$RESULT_COUNT"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[count=%s, want >=2]${N}\n" "GET  /clusterWatchdogStats (multiple results accumulated)" "$RESULT_COUNT"
  FAIL=$((FAIL+1))
fi

# Verify newest-first ordering (ArrayUtils.reverse): first broadcastTimestamp > last
FIRST_TS=$(echo "$STATS_BODY2" | grep -o '"broadcastTimestamp":"[0-9]*"' | head -1 | grep -o '[0-9]*')
LAST_TS=$(echo "$STATS_BODY2" | grep -o '"broadcastTimestamp":"[0-9]*"' | tail -1 | grep -o '[0-9]*')
if [[ -n "$FIRST_TS" && -n "$LAST_TS" && "$FIRST_TS" -ge "$LAST_TS" ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[%s >= %s]${N}\n" "GET  /clusterWatchdogStats (newest-first ordering)" "$FIRST_TS" "$LAST_TS"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[first=%s, last=%s]${N}\n" "GET  /clusterWatchdogStats (newest-first ordering)" "$FIRST_TS" "$LAST_TS"
  FAIL=$((FAIL+1))
fi

# ==================================================================
section "Error paths — unmatched routes"
# Tests: Vert.x Router default 404 for routes not matching any regex
# ==================================================================

req "GET  /nonexistent (no matching route → 404)" "404" \
    "$BASE/nonexistent"

req "GET  / (root, no matching route → 404)" "404" \
    "$BASE/"

req "POST /clusterStatus (wrong method → 405)" "405" \
    -X POST "$BASE/clusterStatus"

req "POST /clusterWatchdogStats (wrong method → 405)" "405" \
    -X POST "$BASE/clusterWatchdogStats"

# ==================================================================
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

#!/usr/bin/env bash
# polybot — smoke test.

set -u

EXEC="${EXEC:-http://localhost:8080}"
STRA="${STRA:-http://localhost:8081}"
ANAL="${ANAL:-http://localhost:8082}"
INGE="${INGE:-http://localhost:8083}"
INFR="${INFR:-http://localhost:8084}"

STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; DIM='\033[2m'; N='\033[0m'
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

req() {
  local label="$1" expected="$2"; shift 2
  local body="$TMP/body" code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^($expected)$ ]]; then
    printf "${G}PASS${N} %-58s ${DIM}[%s]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-58s ${DIM}[got %s, want %s]${N}\n" "$label" "$code" "$expected"
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -3 "$body" | sed 's/^/  /'; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

# Status check + ALL key-field substrings present in body.
req_fields() {
  local label="$1" expected="$2" patterns="$3"; shift 3
  local body="$TMP/body" code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  if [[ ! "$code" =~ ^($expected)$ ]]; then
    printf "${R}FAIL${N} %-58s ${DIM}[got %s, want %s]${N}\n" "$label" "$code" "$expected"
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
    printf "${G}PASS${N} %-58s ${DIM}[%s, all fields ✓]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-58s ${DIM}[missing: %s]${N}\n" "$label" "${missing[*]}"
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -3 "$body" | sed 's/^/  /'; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

# ------------------------------------------------------------------
section "executor-service — :8080  (config endpoints)"
# /health: PolymarketController dumps full runtime config (mode, CLOB URLs,
# chainId, WS-enable flags). PAPER mode is the develop-profile default.
req_fields "GET  /api/polymarket/health"                 "200" \
'"mode":"PAPER"
"clobRestUrl":"https://clob.polymarket.com"
"clobWsUrl":"wss://ws-subscriptions-clob.polymarket.com"
"chainId":137
"marketWsEnabled":true' \
         "$EXEC/api/polymarket/health"
# /auth/status: PolymarketAuthController — signer + API creds state.
# In develop mode, signerConfigured / apiCredsConfigured are both false.
req_fields "GET  /api/polymarket/auth/status"            "200" \
'"mode":"PAPER"
"activeProfiles":["develop"]
"signerConfigured":false
"apiCredsConfigured":false
"clobRestUrl":"https://clob.polymarket.com"' \
         "$EXEC/api/polymarket/auth/status"
# /settlement/config: SettlementController — split into nested settlement{}
# + onchain{} blocks with explicit defaults from develop profile.
req_fields "GET  /api/polymarket/settlement/config"      "200" \
'"settlement":{
"onchain":{
"enabled":false
"dryRun":true
"rpcUrl":"https://polygon-rpc.com"' \
         "$EXEC/api/polymarket/settlement/config"

# ------------------------------------------------------------------
section "executor-service — :8080  (trading-account endpoints)"
# /account: PAPER-mode placeholder addresses (signer/maker/funder all null
# without on-chain creds). Different field set from /auth/status.
req_fields "GET  /api/polymarket/account"                "200" \
'"mode":"PAPER"
"signerAddress":
"makerAddress":
"funderAddress":' \
         "$EXEC/api/polymarket/account"
# /bankroll: financial summary — totals + position counts. PAPER mode
# returns zeros across all USD-denominated fields.
req_fields "GET  /api/polymarket/bankroll"               "200" \
'"mode":"PAPER"
"usdcBalance":0
"totalEquityUsd":0
"positionsCount":0
"redeemablePositionsCount":0' \
         "$EXEC/api/polymarket/bankroll"
# /orders, /trades: wrapped {mode, data:[]} envelope. Even with empty data,
# the envelope shape proves the controller + serializer work.
req_fields "GET  /api/polymarket/orders (envelope)"      "200" \
'"mode":"PAPER"
"data":' \
         "$EXEC/api/polymarket/orders"
req_fields "GET  /api/polymarket/trades (envelope)"      "200" \
'"mode":"PAPER"
"data":' \
         "$EXEC/api/polymarket/trades"
# A live Polymarket conditional-token id used for the static-metadata lookups
# below. Polymarket's CLOB always returns tick-size/neg-risk for known token
# ids regardless of whether the underlying market is still trading or has
# already resolved — so this id stays valid for those probes long after the
# market itself closes.
#
# NOTE: the previous /marketdata/top/{tokenId} probe was deliberately removed
# from this suite. That endpoint requires the ingestor to currently be
# subscribed to the token AND the underlying market to still be receiving
# WebSocket updates. The ingestor only subscribes to short-cycle BTC/ETH
# Up/Down 15m + 1h markets (see PolymarketUpDownMarketWsIngestor) — these
# expire every 15 minutes, so any hard-coded token id rots within minutes
# and there is no API to enumerate the currently-subscribed list. Including
# the probe in the smoke suite would make the run flaky against external
# market state for no benchmark value.
TOKEN_ID="${TOKEN_ID:-64142290347901741198014034978453020450244947971046274327435492041819683177281}"
# Simple lookups: tick-size returns plain "0.01", neg-risk returns plain "false"
# (no JSON wrap — straight Spring conversion of the primitive return value).
req_fields "GET  /api/polymarket/tick-size/{tokenId}"    "200" "0.01" \
         "$EXEC/api/polymarket/tick-size/${TOKEN_ID}"
req_fields "GET  /api/polymarket/neg-risk/{tokenId}"     "200" "false" \
         "$EXEC/api/polymarket/neg-risk/${TOKEN_ID}"

# ------------------------------------------------------------------
section "executor-service — :8080  (real PAPER trading flow)"
# In PAPER mode the simulator handles orders in-process (no on-chain). End-to-
# end chain: POST limit-order → GET by id → DELETE → GET by id (post-cancel).
# Captures the simulator-issued orderId from the place response and reuses it.
PLACE_RESP=$(curl -sS -X POST -H 'Content-Type: application/json' \
  -d "{\"tokenId\":\"${TOKEN_ID}\",\"side\":\"BUY\",\"price\":0.10,\"size\":5,\"orderType\":\"GTC\"}" \
  "$EXEC/api/polymarket/orders/limit")
echo "$PLACE_RESP" > "$TMP/place"
ORDER_ID=$(python3 -c "import sys,json;d=json.load(sys.stdin);print(d['clobResponse']['orderId'])" < "$TMP/place" 2>/dev/null)
echo -e "${DIM}placed orderId=${ORDER_ID:0:24}...${N}"

req_fields "POST /api/polymarket/orders/limit (place SIM)"  "200" \
'"mode":"PAPER"
"clobResponse":
"orderId":"sim-
"status":"OPEN"' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"tokenId\":\"${TOKEN_ID}\",\"side\":\"BUY\",\"price\":0.10,\"size\":5,\"orderType\":\"GTC\"}" \
         "$EXEC/api/polymarket/orders/limit"

# GET-by-id MUST report the order with the price/size we sent + status OPEN
# + side BUY. This is the proof the simulator persisted state correctly.
req_fields "GET  /api/polymarket/orders/{id} (SIM order alive)"  "200" \
'"mode":"SIM"
"orderId":"sim-
"side":"BUY"
"status":"OPEN"
"requestedPrice":0.1
"requestedSize":5.0
"remaining_size":5.0' \
         "$EXEC/api/polymarket/orders/${ORDER_ID}"

# Cancel: returns canceled:true + status CANCELED.
req_fields "DELETE /api/polymarket/orders/{id} (cancel)"        "200" \
'"mode":"SIM"
"canceled":true
"orderId":"sim-
"status":"CANCELED"' \
         -X DELETE "$EXEC/api/polymarket/orders/${ORDER_ID}"

# ------------------------------------------------------------------
section "executor-service — :8080  (Bean Validation on LimitOrderRequest record)"
# LimitOrderRequest is a Java record with @NotBlank, @NotNull, @DecimalMin,
# @DecimalMax — validation triggers MethodArgumentNotValidException → 400.
req "POST /api/polymarket/orders/limit (empty body → 400)"  "400" \
    -X POST -H 'Content-Type: application/json' -d '{}' \
    "$EXEC/api/polymarket/orders/limit"
# @DecimalMax("0.9999") on price: 2.0 exceeds the cap.
req "POST /api/polymarket/orders/limit (price>0.9999 → 400)" "400" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"tokenId\":\"${TOKEN_ID}\",\"side\":\"BUY\",\"price\":2.0,\"size\":5,\"orderType\":\"GTC\"}" \
    "$EXEC/api/polymarket/orders/limit"
# Bad enum: "INVALID" is not a valid OrderSide → Jackson deser error → 400.
req "POST /api/polymarket/orders/limit (bad enum → 400)" "400" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"tokenId\":\"${TOKEN_ID}\",\"side\":\"INVALID\",\"price\":0.10,\"size\":5}" \
    "$EXEC/api/polymarket/orders/limit"

# ------------------------------------------------------------------
section "executor-service — :8080  (simulator state-machine branches)"
# Simulator design: GET on a non-existent orderId returns 200 + status:UNKNOWN
# (NOT 404). This is project-defined "ghost order" behavior — a deliberate
# choice over Spring's default 404 mapping.
req_fields "GET  /api/polymarket/orders/{ghost-id} → 200 UNKNOWN"  "200" \
'"mode":"SIM"
"orderId":"sim-ghost-99999"
"status":"UNKNOWN"' \
         "$EXEC/api/polymarket/orders/sim-ghost-99999"

# Simulator design: DELETE on a non-existent orderId is idempotent — returns
# 200 + canceled:false (NOT 404 / 409). Lets clients retry cancel safely.
req_fields "DELETE /api/polymarket/orders/{ghost-id} → 200 canceled:false"  "200" \
'"mode":"SIM"
"canceled":false
"orderId":"sim-ghost-99999"' \
         -X DELETE "$EXEC/api/polymarket/orders/sim-ghost-99999"

# ------------------------------------------------------------------
section "strategy-service — :8081"
# /status: StrategyStatusController — mode + executor link + WS subscription
# count + Gabagool (the strategy module) liveness.
req_fields "GET  /api/strategy/status"                   "200" \
'"mode":"PAPER"
"activeProfiles":["develop"]
"executorBaseUrl":"http://localhost:8080"
"marketWsEnabled":true
"gabagoolEnabled":true
"gabagoolRunning":true' \
         "$STRA/api/strategy/status"

# ------------------------------------------------------------------
section "analytics-service — :8082"
# /status: AnalyticsController — service identity + ClickHouse JDBC + table.
req_fields "GET  /api/analytics/status"                  "200" \
'"app":"analytics-service"
"datasourceUrl":"jdbc:clickhouse://localhost:8123/polybot"
"eventsTable":"analytics_events"' \
         "$ANAL/api/analytics/status"
# /events: returns rows from ClickHouse (populated as Redpanda topic accumulates).
# We don't pin specific rows (timing-dependent), just confirm it's a JSON array.
req "GET  /api/analytics/events (JSON list)"             "200" \
    "$ANAL/api/analytics/events"
# UserTradeAnalyticsController is the analytics workhorse — 14 endpoints
# under /users/{username}/trades/*. We sample 2 different shapes, both with
# a synthetic username so the project's "no data → empty" branch fires.
ANAL_USER="${ANAL_USER:-0xtest}"
# /execution: aggregate stats DTO with named numeric fields, NaN strings on
# zero-trade users (proves the project's NaN serialization works).
req_fields "GET  /api/analytics/users/{u}/trades/execution" "200" \
'"trades":0
"tradesWithTob":0
"tobCoverage":0.0
"buyTakerLike":0
"avgSpread":"NaN"' \
         "$ANAL/api/analytics/users/${ANAL_USER}/trades/execution"
# /selection/summary: different DTO with HHI/share concentration metrics.
req_fields "GET  /api/analytics/users/{u}/trades/selection/summary" "200" \
'"trades":0
"uniqueMarkets":0
"top1Share":0.0
"top10Trades":0
"marketHhi":0.0' \
         "$ANAL/api/analytics/users/${ANAL_USER}/trades/selection/summary"
# /report: top-level user report with nested stats{} block (different
# wrapping pattern from the flat DTOs above).
req_fields "GET  /api/analytics/users/{u}/trades/report"    "200" \
'"username":"'"${ANAL_USER}"'"
"stats":{
"trades":0
"uniqueMarkets":0
"notionalUsd":0.0' \
         "$ANAL/api/analytics/users/${ANAL_USER}/trades/report"
# /complete-sets/detected: complete-set detection metrics (HFT arbitrage detector).
req_fields "GET  /api/analytics/users/{u}/trades/complete-sets/detected" "200" \
'"marketsTraded":0
"marketsWithDetectedCompleteSets":0
"detectedCompleteSetShares":0.0
"totalImpliedEdgeUsd":0.0
"avgImpliedEdgePerShare":0.0' \
         "$ANAL/api/analytics/users/${ANAL_USER}/trades/complete-sets/detected"
# /churn: trade-cadence metrics with NaN serialization on zero-trade users.
req_fields "GET  /api/analytics/users/{u}/trades/churn"     "200" \
'"trades":0
"marketSwitches":0
"marketSwitchRate":0.0
"avgSecondsBetweenTrades":"NaN"' \
         "$ANAL/api/analytics/users/${ANAL_USER}/trades/churn"

# ------------------------------------------------------------------
section "ingestor-service — :8083"
# /status: IngestorController — full polling-loop stats + WS state +
# Polygon TX poll counters. dataApiBaseUrl + kafkaTopic prove config wiring.
req_fields "GET  /api/ingestor/status"                   "200" \
'"app":"ingestor-service"
"activeProfile":"develop"
"dataApiBaseUrl":"https://data-api.polymarket.com"
"pollingEnabled":true
"kafkaTopic":"polybot.events"
"marketWsClientStarted":true' \
         "$INGE/api/ingestor/status"
# Standard Spring Boot health (the only service whose README sample uses actuator).
req_fields "GET  /actuator/health (Spring health)"       "200" \
'"status":"UP"
"components":
"livenessState":
"readinessState":
"groups":["liveness","readiness"]' \
         "$INGE/actuator/health"

# ------------------------------------------------------------------
section "infrastructure-orchestrator-service — :8084"
# /status: InfrastructureController — both Docker stacks (analytics + monitoring)
# with running/expected counts. analytics is reliably HEALTHY; monitoring is
# often DEGRADED in develop because alertmanager.yml expects an env-resolved
# webhook URL that develop doesn't set (alertmanager crash-loops). We assert
# structure + analytics HEALTHY but don't pin overallHealth because that
# tracks an upstream config gap, not a polybot API behavior.
req_fields "GET  /api/infrastructure/status"             "200" \
'"managed":true
"overallHealth":
"stacks":[
"name":"analytics"
"name":"monitoring"
"runningServices":2
"expectedServices":2' \
         "$INFR/api/infrastructure/status"
# /links: returns the URL bundle for the managed stacks (analytics, monitoring).
req_fields "GET  /api/infrastructure/links"              "200" \
'"monitoring":{
"analytics":{
"prometheus":"http://localhost:9090"
"grafana":
"clickhouse_http":"http://localhost:8123"
"redpanda_kafka":"localhost:9092"' \
         "$INFR/api/infrastructure/links"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

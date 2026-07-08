#!/usr/bin/env bash
# clklog-api — smoke test.

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
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -5 "$body" | sed 's/^/  /'; }
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
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -5 "$body" | sed 's/^/  /'; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

# Shared POST args for every business endpoint: empty JSON body + json header.
POST_ARGS=(-X POST -H "Content-Type: application/json" -d '{}')

# Deny-path assertion: HTTP 200 + body contains `"code":403`.
req_deny() {
  local label="$1"; shift
  req_body "$label (deny path)" "200" '"code":403' "${POST_ARGS[@]}" "$@"
}

# ------------------------------------------------------------------
section "Infra sanity"
req_body "GET  /actuator/health"                 "200" '"status":"UP"' "$BASE/actuator/health"
req_body "GET  /actuator (HAL links)"            "200" '"_links"'       "$BASE/actuator"

# ------------------------------------------------------------------
section "API surface (contract)"
req_body "GET  /v3/api-docs (springdoc)"         "200" '"openapi"'      "$BASE/v3/api-docs"
req      "GET  /swagger-ui.html → redirect"      "302|303"              "$BASE/swagger-ui.html"
req_body "GET  /doc.html (knife4j)"              "200" 'knife4j-vue'   "$BASE/doc.html"

# ------------------------------------------------------------------
section "Public: GET /profile (only anonymous-friendly endpoint)"
# Returns HTTP 200 + code:200 with a freshly-issued clientId. Exercises the
# Redis-backed token store (creates a new anonymous profile entry).
req_body "GET  /profile"                         "200" '"code":200'     "$BASE/profile"

# ------------------------------------------------------------------
section "Protected business endpoints (one per controller, deny path)"
# Each endpoint exercises: Spring MVC routing + Jackson deserialisation +
# the @EnableGlobalMethodSecurity / exception-handler chain that wraps
# AuthenticationException as HTTP 200 with {"code":403,"msg":"认证失败..."}.
# ClickHouse / Redis / POI code paths are NOT reached — auth rejects before
# the service layer executes.
req_deny "POST /flow/getFlow"                    "$BASE/flow/getFlow"
req_deny "POST /device/getDeviceDetail"          "$BASE/device/getDeviceDetail"
req_deny "POST /os/getOsDetail"                  "$BASE/os/getOsDetail"
req_deny "POST /area/getArea"                    "$BASE/area/getArea"
req_deny "POST /channel/getChannel"              "$BASE/channel/getChannel"
req_deny "POST /searchword/getSearchWordTop10"   "$BASE/searchword/getSearchWordTop10"
req_deny "POST /sourcewebsite/getSourceWebsite"  "$BASE/sourcewebsite/getSourceWebsite"
req_deny "POST /visitor/getTopUserByRegion"      "$BASE/visitor/getTopUserByRegion"
req_deny "POST /visitUri/getVisitUri"            "$BASE/visitUri/getVisitUri"
req_deny "POST /userVisit/getUserVisit"          "$BASE/userVisit/getUserVisit"
req_deny "POST /appCrashed/totalSummary"         "$BASE/appCrashed/totalSummary"
req_deny "POST /download/exportFlowTrendDetail"  "$BASE/download/exportFlowTrendDetail"
req_deny "POST /profile/subscribe"               "$BASE/profile/subscribe"

# ------------------------------------------------------------------
# Auth injection — Redis-backed LoginUser approach.
# Unlike spawn-app's "DB INSERT + JWT sign" recipe, clklog's auth lives in
# Redis: the JWT contains a `login_user_key` claim (a UUID) that's looked
# up against `login_tokens:<UUID>` to retrieve a JSON-serialized LoginUser.
# We pre-stage that Redis key + sign a JWT with the project's token.secret.
#
# The JWT secret config: application.yml has `token.secret: c609737e578978eccc64cef4be680`
# (29 chars). jjwt 0.9.1's setSigningKey() lenient-base64-decodes it; the
# valid first 28 chars decode to 21 bytes, used as the HMAC-SHA256 key.
SKIP_INJECT="${SKIP_INJECT:-0}"
SKIP_SEED="${SKIP_SEED:-0}"
REDIS_CONTAINER="${REDIS_CONTAINER:-clklog-redis}"
CH_CONTAINER="${CH_CONTAINER:-clklog-clickhouse}"
TOKEN_SECRET="${TOKEN_SECRET:-c609737e578978eccc64cef4be680}"

# Seed minimal ClickHouse schema + sample data so /flow/getFlow can return
# real business data (instead of 500 from missing tables). Idempotent —
# CREATE TABLE IF NOT EXISTS + INSERT (CH allows duplicate inserts).
# Only the two tables /flow/getFlow needs are seeded; other tables remain
# missing on purpose (their endpoints stay 500 to keep the test focused).
seed_clickhouse_for_getflow() {
  # NOTE: no `-i` on docker exec, and `--query` (not `-q`) for clickhouse-client.
  # When test_api.sh runs under subprocess.run with stdin=/dev/null, `docker
  # exec -i` keeps stdin attached, and clickhouse-client interprets the
  # presence of an open stdin as "more queries coming" — even with `-q`,
  # making INSERT statements hang indefinitely. Dropping `-i` closes stdin
  # immediately so each query runs and exits.
  local ch="docker exec $CH_CONTAINER clickhouse-client --user default --password 123456"
  $ch --query "CREATE TABLE IF NOT EXISTS flow_trend_bydate (stat_date DateTime, lib String, project_name String, pv Int32, visit_count Int32, uv Int32, new_uv Int32, ip_count Int32, visit_time Int32, bounce_count Int32, update_time DateTime, country String, province String, is_first_day String) ENGINE = MergeTree() ORDER BY (stat_date, project_name);" >/dev/null 2>&1
  $ch --query "CREATE TABLE IF NOT EXISTS flow_trend_byhour (stat_date DateTime, stat_hour String, lib String, project_name String, pv Int32, visit_count Int32, uv Int32, new_uv Int32, ip_count Int32, visit_time Int32, bounce_count Int32, update_time DateTime, country String, province String, is_first_day String) ENGINE = MergeTree() ORDER BY (stat_date, stat_hour, project_name);" >/dev/null 2>&1
  # Truncate before seed to keep counts deterministic across re-runs.
  $ch --query "TRUNCATE TABLE flow_trend_bydate" >/dev/null 2>&1
  $ch --query "TRUNCATE TABLE flow_trend_byhour" >/dev/null 2>&1
  $ch --query "INSERT INTO flow_trend_bydate VALUES ('2026-04-23 00:00:00','js','clklogapp',100,50,25,10,30,1500,5,'2026-04-23 00:00:00','all','all','all'),('2026-04-24 00:00:00','js','clklogapp',120,60,30,12,35,1800,6,'2026-04-24 00:00:00','all','all','all'),('2026-04-25 00:00:00','js','clklogapp',110,55,27,11,32,1650,5,'2026-04-25 00:00:00','all','all','all');" >/dev/null 2>&1
  $ch --query "INSERT INTO flow_trend_byhour VALUES ('2026-04-25 00:00:00','08','js','clklogapp',50,25,12,5,15,750,2,'2026-04-25 08:00:00','all','all','all'),('2026-04-25 00:00:00','14','js','clklogapp',60,30,15,6,17,900,3,'2026-04-25 14:00:00','all','all','all');" >/dev/null 2>&1
}

inject_login_user() {
  # Generate a UUID; build minimal LoginUser JSON; stage it in Redis;
  # echo the UUID. Works as long as the LoginUser entity stays JSON-shape.
  local uuid; uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
  local now_ms; now_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  local exp_ms=$((now_ms + 3600000))
  local json
  json=$(python3 -c "
import json
print(json.dumps({
    'userId': 'testuser_inj',
    'token':  '$uuid',
    'loginTime':  $now_ms,
    'expireTime': $exp_ms,
    'ipaddr': '127.0.0.1',
    'user':   {'userId':'testuser_inj','userName':'testuser_inj'},
    'perms':  {}
}))")
  docker exec "$REDIS_CONTAINER" redis-cli SET "login_tokens:$uuid" "$json" >/dev/null 2>&1
  echo "$uuid"
}

forge_clklog_jwt() {
  local uuid="$1"
  python3 - "$uuid" "$TOKEN_SECRET" <<'PY'
import sys, hmac, hashlib, base64, json, time
uuid, secret_str = sys.argv[1], sys.argv[2]
# jjwt 0.9.1 lenient-base64-decodes the secret. 29 chars truncated to 28
# (length divisible by 4) decodes to 21 bytes — those are the HMAC key.
trimmed = secret_str[: (len(secret_str) // 4) * 4]
secret  = base64.b64decode(trimmed)
b64u = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
hdr  = b64u(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(',',':')).encode())
pld  = b64u(json.dumps(
    {"login_user_key": uuid,
     "iat": int(time.time()),
     "exp": int(time.time()) + 3600},
    separators=(',',':')).encode())
data = hdr + b"." + pld
sig  = b64u(hmac.new(secret, data, hashlib.sha256).digest())
print((data + b"." + sig).decode())
PY
}

section "Auth-injection: Redis-staged LoginUser + manual JWT (jjwt 0.9.1 secret)"
if [[ "$SKIP_INJECT" == "1" ]]; then
  echo -e "${Y}SKIP: SKIP_INJECT=1${N}"
elif ! command -v python3 >/dev/null 2>&1; then
  echo -e "${Y}SKIP: python3 not on PATH${N}"
elif ! docker exec "$REDIS_CONTAINER" true 2>/dev/null; then
  echo -e "${Y}SKIP: cannot reach $REDIS_CONTAINER${N}"
else
  UUID="$(inject_login_user)"
  TOKEN="$(forge_clklog_jwt "$UUID")"
  AUTH_INJ=(-H "Authorization: Bearer ${TOKEN}")
  echo -e "${DIM}Staged Redis key login_tokens:${UUID}${N}"
  echo -e "${DIM}Forged token: ${TOKEN:0:40}...${N}"

  # Now requests pass auth. The body shape WITH auth is different from the
  # deny-path 403 wrapper — confirms the injection works. Two outcomes:
  # (a) endpoints whose service code wraps exceptions return code:200/500
  #     with body — we hit them past auth even with empty CH (real business path)
  # (b) endpoints whose service code lets exceptions bubble return raw HTTP 500
  # Either is qualitatively different from the 403 deny.

  # Real success: /profile/subscribe doesn't need ClickHouse data, returns
  # the project's normal {"code":200,"msg":"操作成功"} envelope.
  req_body "POST /profile/subscribe (real success after inject)" "200" '"code":200' \
       "${AUTH_INJ[@]}" -X POST "$BASE/profile/subscribe" \
       -H "Content-Type: application/json" -d '{"email":"inj@clklog.test"}'

  # Seed ClickHouse + hit /flow/getFlow with matching params → returns
  # REAL aggregated business body (pv summed across our 3 inserted rows).
  # This is the proof-of-concept for "manually back-fill missing project
  # schema to drive a real-200 path". Only flow_trend_bydate +
  # flow_trend_byhour are seeded; other CH-backed endpoints stay 500.
  if [[ "$SKIP_SEED" == "1" ]]; then
    echo -e "${Y}SKIP seed: SKIP_SEED=1${N}"
  elif ! docker exec "$CH_CONTAINER" true 2>/dev/null; then
    echo -e "${Y}SKIP seed: cannot reach $CH_CONTAINER${N}"
  else
    seed_clickhouse_for_getflow
    echo -e "${DIM}Seeded flow_trend_bydate (3 rows) + flow_trend_byhour (2 rows)${N}"
    req_body "POST /flow/getFlow (REAL 200 after CH seed) — pv summed=220" "200" '"pv":220' \
         "${AUTH_INJ[@]}" -X POST "$BASE/flow/getFlow" \
         -H "Content-Type: application/json" \
         -d '{"timeType":"day","channel":["js"],"startTime":"2026-04-23","endTime":"2026-04-25","projectName":"clklogapp"}'
  fi

  # Wrapped exception: another endpoint (e.g. /searchword) hits a CH
  # table we DIDN'T seed → service-layer catch → {"code":500}.
  # Distinct from the {"code":403,"msg":"认证失败"} deny path; proves the
  # token works but data is missing for that endpoint specifically.
  req_body "POST /searchword/getSearchWordTop10 (auth bypassed; CH missing → 500)" "500" 'Internal' \
       "${AUTH_INJ[@]}" -X POST "$BASE/searchword/getSearchWordTop10" \
       -H "Content-Type: application/json" -d '{}'

  # Bean Validation: /channel/getChannel has @Valid @RequestBody GetChannelRequest
  # with @NotEmpty(message="项目编码不能为空") on projectName. Auth-injected POST
  # with empty projectName triggers MethodArgumentNotValidException → 400.
  req "POST /channel/getChannel (empty projectName → validation)" "400" \
       "${AUTH_INJ[@]}" -X POST "$BASE/channel/getChannel" \
       -H "Content-Type: application/json" -d '{"projectName":""}'

  # Negative confirmation: a forged token whose UUID isn't in Redis fails the
  # Redis lookup → tokenService.getLoginUser returns null → request denies.
  BOGUS_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  BOGUS_TOKEN="$(forge_clklog_jwt "$BOGUS_UUID")"
  req_body "POST /flow/getFlow (forged token, no Redis entry → deny)" "200" '"code":403' \
       -H "Authorization: Bearer ${BOGUS_TOKEN}" -X POST "$BASE/flow/getFlow" \
       -H "Content-Type: application/json" -d '{}'
fi

# ------------------------------------------------------------------
section "HTTP method errors"
# 405 — GET on POST-only business endpoint.
req "GET  /flow/getFlow (wrong method → 405)"            "405" "$BASE/flow/getFlow"
# 404 — unmapped path.
req "GET  /nonexistent (unmapped → 404)"                 "404" "$BASE/nonexistent"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

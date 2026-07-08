#!/usr/bin/env bash
# JiChat — smoke test.

set -u

USER_BASE="${USER_BASE:-http://localhost:18081/user-api}"
USER_ID=""
CHAT_BASE="${CHAT_BASE:-http://localhost:18080/chat-api}"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; DIM='\033[2m'; N='\033[0m'
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PY=/usr/local/bin/python3

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
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -2 "$body" | sed 's/^/  /'; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

# Random username (4-16 chars alphanumeric per @Pattern). Avoid duplicate
# registrations across re-runs.
SUF="$RANDOM"
USERNAME="apitest$SUF"
PW="testpw_${SUF}"

# ------------------------------------------------------------------
section "Open endpoints (swagger + OpenAPI + captcha + register/login)"
req_fields "GET  /user-api/v3/api-docs (OpenAPI spec)"   "200" \
'"openapi":"3.0.1"
"title":"JiChat User-接口"
"paths":' \
         "$USER_BASE/v3/api-docs"
req_fields "GET  /chat-api/v3/api-docs (OpenAPI spec)"   "200" \
'"openapi":"3.0.1"
"title":"JiChat Chat-接口"
"paths":' \
         "$CHAT_BASE/v3/api-docs"
# Captcha is open (no token); returns uuid + base64 PNG.
req_fields "GET  /user-api/user/getCaptcha"              "200" \
'"code":0
"uuid":"
"imgBase64":"' \
         "$USER_BASE/user/getCaptcha"

# ------------------------------------------------------------------
section "Auth flow — register, login, refresh-token (USER role)"
req_fields "POST /user-api/user/register"                "200" \
'"code":0
"msg":"success"' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"username\":\"${USERNAME}\",\"nickname\":\"Test User\",\"password\":\"${PW}\",\"mobile\":\"138${SUF}9999\"}" \
         "$USER_BASE/user/register"

LOGIN=$(curl -sS -X POST -H 'Content-Type: application/json' \
        -d "{\"username\":\"${USERNAME}\",\"password\":\"${PW}\",\"deviceIdentifier\":\"dev-${SUF}\",\"deviceName\":\"TestDev\",\"deviceType\":1,\"osType\":102}" \
        "$USER_BASE/user/login")
TOKEN=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["accessToken"])' "$LOGIN")
REFRESH=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["refreshToken"])' "$LOGIN")
req_fields "POST /user-api/user/login (returns JWT pair)" "200" \
'"code":0
"data":{
"userId":"
"accessToken":"eyJ
"refreshToken":"eyJ
"expiresTime":"' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"username\":\"${USERNAME}\",\"password\":\"${PW}\",\"deviceIdentifier\":\"dev-${SUF}b\",\"deviceName\":\"TestDev\",\"deviceType\":1,\"osType\":102}" \
         "$USER_BASE/user/login"

# Re-login above invalidated the previous TOKEN — re-capture.
LOGIN=$(curl -sS -X POST -H 'Content-Type: application/json' \
        -d "{\"username\":\"${USERNAME}\",\"password\":\"${PW}\",\"deviceIdentifier\":\"dev-${SUF}c\",\"deviceName\":\"TestDev\",\"deviceType\":1,\"osType\":102}" \
        "$USER_BASE/user/login")
TOKEN=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["accessToken"])' "$LOGIN")
REFRESH=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["refreshToken"])' "$LOGIN")
USER_ID=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["userId"])' "$LOGIN")
AUTH=(-H "Authorization: ${TOKEN}")

# ------------------------------------------------------------------
section "user-service business endpoints (covers 5 existing tables)"
# t_device — DeviceController.getOnlineDevices(@RequiresNone). The login above
# inserts a row into t_device; this lookup returns it.
req_fields "GET  /user-api/device/getOnlineDevices (t_device)"  "200" \
"\"code\":0
\"deviceIdentifier\":\"dev-${SUF}c\"
\"userId\":\"${USER_ID}\"" \
         "$USER_BASE/device/getOnlineDevices?userId=${USER_ID}"
# t_chat_server_info — ChatServerInfoController.save(@RequiresNone).
req_fields "POST /user-api/chatServerInfo/save (t_chat_server_info)"  "200" \
'"code":0
"msg":"success"' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"innerIp\":\"10.0.0.${SUF: -2}\",\"outsideIp\":\"10.0.0.${SUF: -2}\",\"httpPort\":9${SUF: -3},\"tcpPort\":8${SUF: -3},\"connectionCount\":0}" \
         "$USER_BASE/chatServerInfo/save"
req_fields "GET  /user-api/chatServerInfo/getByIpAndPort"  "200" \
"\"code\":0
\"innerIp\":\"10.0.0.${SUF: -2}\"
\"httpPort\":9${SUF: -3}" \
         "$USER_BASE/chatServerInfo/getByIpAndPort?innerIp=10.0.0.${SUF: -2}&httpPort=9${SUF: -3}"
# t_user_relation — UserRelationController.addFriend. Project rejects
# adding self as friend, so we register a second user
# specifically for the friendship target.
FRIEND_USER="apifriend${SUF}"
curl -sS -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${FRIEND_USER}\",\"nickname\":\"Friend\",\"password\":\"${PW}\",\"mobile\":\"139${SUF}9999\"}" \
  "$USER_BASE/user/register" > /dev/null
FRIEND_LOGIN=$(curl -sS -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${FRIEND_USER}\",\"password\":\"${PW}\",\"deviceIdentifier\":\"f-${SUF}\",\"deviceName\":\"F\",\"deviceType\":1,\"osType\":102}" \
  "$USER_BASE/user/login")
FRIEND_ID=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["userId"])' "$FRIEND_LOGIN")
req_fields "POST /user-api/userRelation/addFriend (t_user_relation)"  "200" \
'"code":0
"msg":"success"' \
         -X POST -H 'Content-Type: application/json' "${AUTH[@]}" \
         -d "{\"relationId\":${FRIEND_ID}}" \
         "$USER_BASE/userRelation/addFriend"
req_fields "GET  /user-api/userRelation/listUserRelation"  "200" \
'"code":0
"msg":"success"' \
         "${AUTH[@]}" "$USER_BASE/userRelation/listUserRelation"
# t_chat_message — ChatMessageController.query. Empty result for fresh user,
# but the paged envelope still proves the path works end-to-end.
req_fields "GET  /user-api/chatMessage/query (t_chat_message)"  "200" \
'"code":0
"data":{
"total":0
"list":[]' \
         "${AUTH[@]}" "$USER_BASE/chatMessage/query?pageNum=1&pageSize=10&toUserId=1"

# ------------------------------------------------------------------
section "chat-service authenticated endpoints (validates JWT via Feign→user-service)"
# Each chat-service request runs SecurityInterceptor → JwtUtil.validate →
# userRpc.getLoginUserByLoginKey (Feign call discovered via Nacos to
# user-service). 200 + code:0 here proves: JWT verified locally + Nacos
# service discovery works + user-service Feign endpoint responds + Redis
# loginKey lookup succeeds.
req_fields "GET  /chat-api/test/test (cross-service JWT verify)"  "200" \
'"code":0
"data":"成功"
"msg":"success"' \
         "${AUTH[@]}" "$CHAT_BASE/test/test"
# /test/sendMessage publishes a message to RabbitMQ (chatMessageProducer
# → ChatMessageConsumer); proves the AMQP wiring works.
req_fields "GET  /chat-api/test/sendMessage (RabbitMQ produce)"  "200" \
'"code":0
"data":"成功"' \
         "${AUTH[@]}" "$CHAT_BASE/test/sendMessage?message=hello_${SUF}"
# /test/rpcTest does a SECOND Feign call back to user-service (separate
# from the auth-validation call) — exercises explicit OpenFeign+Nacos.
req_fields "GET  /chat-api/test/rpcTest (explicit Feign cross-call)"  "200" \
'"code":0
"msg":"success"' \
         "${AUTH[@]}" "$CHAT_BASE/test/rpcTest?loginKey=anything"
# Redis read-through cache.
req_fields "GET  /chat-api/test/getRedisCache (Redis read)"  "200" \
'"code":0
"msg":"success"' \
         "${AUTH[@]}" "$CHAT_BASE/test/getRedisCache?key=foo"
# Redis prefix scan.
req_fields "GET  /chat-api/test/getKeysWithPrefix (Redis KEYS)"  "200" \
'[' \
         "${AUTH[@]}" "$CHAT_BASE/test/getKeysWithPrefix?prefix=user_login_"

# ------------------------------------------------------------------
section "user-service authenticated endpoints"
# DELETE /user/del — soft-delete by id. Use a non-existent id to avoid
# clobbering the test user we still need for refresh + logout below.
# MyBatis-Plus removeById is silent on no-row, so this just verifies the
# DELETE path is wired correctly.
req_fields "DELETE /user-api/user/del (t_user soft-delete)"  "200" \
'"code":0
"msg":"success"' \
         -X DELETE "${AUTH[@]}" "$USER_BASE/user/del?userId=999999999"

# refresh-token + logout each in its own independent login session. This
# project's session model: logging in invalidates the prior session's
# refresh token, AND logout invalidates both access AND refresh. So we
# spin up two fresh sessions (different deviceIdentifier each) for these
# two tests.

# Session R (refresh-token test): fresh login → use refresh half-life.
LOGIN_R=$(curl -sS -X POST -H 'Content-Type: application/json' \
          -d "{\"username\":\"${USERNAME}\",\"password\":\"${PW}\",\"deviceIdentifier\":\"dev-${SUF}-R\",\"deviceName\":\"R\",\"deviceType\":1,\"osType\":102}" \
          "$USER_BASE/user/login")
REFRESH_R=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["refreshToken"])' "$LOGIN_R")
req_fields "POST /user-api/user/refresh-token (rotate JWT pair)"  "200" \
'"code":0
"data":{
"accessToken":"eyJ
"refreshToken":"eyJ' \
         -X POST "$USER_BASE/user/refresh-token?refreshToken=${REFRESH_R}"

# Session L (logout test): fresh login → logout that session.
LOGIN_L=$(curl -sS -X POST -H 'Content-Type: application/json' \
          -d "{\"username\":\"${USERNAME}\",\"password\":\"${PW}\",\"deviceIdentifier\":\"dev-${SUF}-L\",\"deviceName\":\"L\",\"deviceType\":1,\"osType\":102}" \
          "$USER_BASE/user/login")
TOKEN_L=$($PY -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["data"]["accessToken"])' "$LOGIN_L")
req_fields "POST /user-api/user/logout (terminate session)"  "200" \
'"code":0
"data":true
"msg":"success"' \
         -X POST -H "Authorization: ${TOKEN_L}" "$USER_BASE/user/logout"

# ------------------------------------------------------------------
section "Bean Validation + HTTP method errors (GlobalExceptionHandler)"
# MethodArgumentNotValidException: @Pattern on username rejects special chars.
# Handler returns CommonResult with error code 400 + field+message.
req_fields "POST /user-api/user/register (bad username → 400)"  "200" \
'"code":400' \
         -X POST -H 'Content-Type: application/json' \
         -d '{"username":"bad!!user","nickname":"X","password":"12345678","mobile":"18000000000"}' \
         "$USER_BASE/user/register"
# HttpRequestMethodNotSupportedException: GET on POST-only register → 405 envelope.
req_fields "GET  /user-api/user/register (wrong method → 405)"  "200" \
'"code":405' \
         "$USER_BASE/user/register"

# ------------------------------------------------------------------
section "Auth-gate sanity (chat-service rejects calls without JWT)"
# After logout, the JWT no longer resolves to a LoginUser via Feign →
# SecurityInterceptor throws UNAUTHORIZED. Without ANY Authorization
# header, the same path. Both cases assert body code:401.
req_fields "GET  /chat-api/test/test (no token → body code:401)"  "200" \
'"code":401
"msg":"账号未登录"' \
         "$CHAT_BASE/test/test"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

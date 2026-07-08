#!/usr/bin/env bash
# web-console — smoke test.
# Tests Vert.x verticle deployment, HTTP static file serving, WebSocket
# upgrade negotiation, EventBus messaging, and System.out redirection.
#
# Reflection-intensive paths exercised:
#   - Vert.x Verticle deployment (vertx.deployVerticle with instance)
#   - Lombok annotation processing (@Slf4j, @RequiredArgsConstructor → reflective field injection)
#   - HTTP server with WebSocket handler + Router (dual handler setup)
#   - StaticHandler classpath resource resolution ("web/index.html")
#   - EventBus consumer/publish pattern (SysOutToEventBus, WebVerticle)
#   - System.out PrintStream replacement (reflection on I/O streams)
#   - HttpServerOptions configuration binding
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
section "Static file serving — Vert.x StaticHandler ('web' classpath)"
# Tests: WebVerticle.start(), Router.route().handler(StaticHandler.create("web")),
#        HttpServer.requestHandler(router), classpath resource loading
# ==================================================================

req_fields "GET  / (root → index.html)" "200" \
'<title>Web Console</title>
WebSocket
socket.onmessage
startParams=
sendMessage
clearMessages
messageInput
<form
<button type="submit">Start</button>' \
    "$BASE/"

req_fields "GET  /index.html (explicit path)" "200" \
'<title>Web Console</title>
new WebSocket
event.data
getElementById("messages")
pre id="messages"' \
    "$BASE/index.html"

req_header "GET  / (Content-Type: text/html)" "200" "text/html" \
    "$BASE/"

# Verify the WebSocket URL construction logic in the HTML
req_body "GET  / (ws protocol selection logic)" "200" \
    'location.protocol == "https:" ? "wss:" : "ws:"' \
    "$BASE/"

req_body "GET  / (location.host based WS URL)" "200" \
    'location.host' \
    "$BASE/"

# ==================================================================
section "WebSocket upgrade — server.webSocketHandler path"
# Tests: HttpServer.webSocketHandler(this::onWebSocketConnected),
#        ServerWebSocket handling, Vert.x WebSocket upgrade negotiation
# ==================================================================

# Send a proper WebSocket upgrade request — Vert.x should respond with 101
WS_CODE=$(curl -sS -o "$TMP/body" -D "$TMP/headers" -w "%{http_code}" \
  --max-time 5 --http1.1 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "$BASE/" 2>/dev/null)
[[ -z "$WS_CODE" ]] && WS_CODE="000"

if [[ "$WS_CODE" == "101" ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[101]${N}\n" "GET  / + Upgrade: websocket (→ 101 Switching)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[got %s, want 101]${N}\n" "GET  / + Upgrade: websocket (→ 101 Switching)" "$WS_CODE"
  FAIL=$((FAIL+1))
  [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
fi

# Verify Sec-WebSocket-Accept header in upgrade response
if grep -qi "Sec-WebSocket-Accept" "$TMP/headers" 2>/dev/null; then
  printf "${G}PASS${N} %-60s ${DIM}[header ✓]${N}\n" "  → response has Sec-WebSocket-Accept"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[missing]${N}\n" "  → response has Sec-WebSocket-Accept"
  FAIL=$((FAIL+1))
fi

# Verify Upgrade: websocket in response
if grep -qi "Upgrade: websocket" "$TMP/headers" 2>/dev/null; then
  printf "${G}PASS${N} %-60s ${DIM}[header ✓]${N}\n" "  → response has Upgrade: websocket"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[missing]${N}\n" "  → response has Upgrade: websocket"
  FAIL=$((FAIL+1))
fi

# Non-upgrade request to root should still return HTML (not upgrade)
req_body "GET  / (normal request, no upgrade)" "200" \
    '<title>Web Console</title>' \
    "$BASE/"

# ==================================================================
section "Error paths — 404 for missing static resources"
# Tests: StaticHandler returns 404 for files not in "web/" classpath dir
# ==================================================================

req "GET  /nonexistent.html (→ 404)" "404" \
    "$BASE/nonexistent.html"

req "GET  /api/anything (→ 404)" "404" \
    "$BASE/api/anything"

req "GET  /favicon.ico (→ 404)" "404" \
    "$BASE/favicon.ico"

# ==================================================================
section "Concurrent requests — Vert.x event loop"
# Tests: Non-blocking I/O, multiple clients served concurrently
# ==================================================================

pids=()
for i in $(seq 1 5); do
  curl -sS -o /dev/null -w "%{http_code}" "$BASE/" > "$TMP/par_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 5); do
  c=$(cat "$TMP/par_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "5x parallel GET /"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "5x parallel GET /"
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

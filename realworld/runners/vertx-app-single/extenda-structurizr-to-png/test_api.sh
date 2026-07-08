#!/usr/bin/env bash
# structurizr-to-png — smoke test.
# Tests Vert.x verticle deployment, HTTP routing, static file serving,
# JSON serialization (theme), image serving, and EventBus bridge.
#
# Reflection-intensive paths exercised:
#   - Vert.x Verticle deployment & config injection (DI container init)
#   - HTTP request handler chain (Router, StaticHandler, SockJSHandler)
#   - JSON serialization/deserialization (JsonObject, ThemeUtils.loadThemes)
#   - Structurizr DSL parsing (StructurizrDslParser: reflection-heavy model)
#   - C4PlantUML diagram export (AbstractDiagramExporter via reflection)
#   - SockJS bridge options (PermittedOptions address regex matching)
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

req_binary() {
  local label="$1" expected="$2" magic="$3"; shift 3
  local body="$TMP/body"
  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  local status_ok=0 magic_ok=0
  [[ "$code" =~ ^($expected)$ ]] && status_ok=1
  head -c 8 "$body" 2>/dev/null | grep -q "$magic" && magic_ok=1
  if [[ $status_ok -eq 1 && $magic_ok -eq 1 ]]; then
    printf "${G}PASS${N} %-60s ${DIM}[%s, magic ✓]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    local reason
    if [[ $status_ok -eq 0 ]]; then reason="got $code, want $expected"
    else reason="binary magic mismatch (not $magic)"; fi
    printf "${R}FAIL${N} %-60s ${DIM}[%s]${N}\n" "$label" "$reason"
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

# ==================================================================
section "Static file serving — Vert.x StaticHandler (/ and /index.html)"
# Tests: Verticle deployment, Router.route("/*").handler(StaticHandler),
#        classpath resource resolution ("preview/index.html")
# ==================================================================

req_fields "GET  / (root → static index.html)" "200" \
'<title>structurizr-to-png
EventBus
eventbus
sockjs' \
    "$BASE/"

req_fields "GET  /index.html (explicit path)" "200" \
'<title>structurizr-to-png
preview.init
preview.changed
showImage' \
    "$BASE/index.html"

req_header "GET  /index.html (Content-Type: text/html)" "200" "text/html" \
    "$BASE/index.html"

# ==================================================================
section "Theme JSON — StaticHandler + JSON content at /themes/*"
# Tests: StaticHandler for /themes/*, ThemeUtils.loadThemes() reflection,
#        JSON deserialization of theme elements/tags/shapes
# ==================================================================

req_header "GET  /themes/theme.json (Content-Type: application/json)" "200" "application/json" \
    "$BASE/themes/theme.json"

req_fields "GET  /themes/theme.json (full schema)" "200" \
'"name": "dsl-to-png theme"
"elements": [
"tag": "Element"
"shape": "RoundedBox"
"tag": "Software System"
"background": "#1168bd"
"color": "#ffffff"
"stroke": "#3c7fc0"
"tag": "Container"
"background": "#438dd5"
"tag": "Component"
"background": "#85bbf0"
"tag": "Person"
"shape": "Person"
"background": "#08427b"
"tag": "Database"
"shape": "Cylinder"
"tag": "Topic"
"shape": "Pipe"
"tag": "External"
"background": "#999999"
"tag": "Existing System"' \
    "$BASE/themes/theme.json"

# ==================================================================
section "Image serving — /images/* route (DSL parse → render → file serve)"
# Tests: Custom lambda route handler, WorkspaceReader.loadFromDsl (reflection:
#        StructurizrDslParser, ThemeUtils), C4PlantUMLDiagramRenderer
#        (AbstractDiagramExporter subclass, PlantUML rendering), file I/O
# ==================================================================

# The demo.dsl defines system "Price Tracker" with 2 views:
#   - SystemContext → structurizr-PriceTracker-SystemContext.png
#   - Container    → structurizr-PriceTracker-Container.png

req_binary "GET  /images/structurizr-PriceTracker-SystemContext.png" "200" "PNG" \
    "$BASE/images/structurizr-PriceTracker-SystemContext.png"

req_header "GET  /images/...SystemContext.png (Content-Type: image/png)" "200" "image/png" \
    "$BASE/images/structurizr-PriceTracker-SystemContext.png"

req_binary "GET  /images/structurizr-PriceTracker-Container.png" "200" "PNG" \
    "$BASE/images/structurizr-PriceTracker-Container.png"

req_header "GET  /images/...Container.png (Content-Type: image/png)" "200" "image/png" \
    "$BASE/images/structurizr-PriceTracker-Container.png"

# ==================================================================
section "Error paths — 404 for missing/invalid resources"
# Tests: Route handler ctx.response().setStatusCode(404).end(),
#        findImage() returning Optional.empty()
# ==================================================================

req "GET  /images/structurizr-NonExistent.png (→ 404)" "404" \
    "$BASE/images/structurizr-NonExistent.png"

req "GET  /images/not-a-structurizr-file.png (→ 404)" "404" \
    "$BASE/images/not-a-structurizr-file.png"

req "GET  /images/ (empty name → 404)" "404" \
    "$BASE/images/"

req "GET  /nonexistent-path (no matching route → 404)" "404" \
    "$BASE/nonexistent-path"

req "GET  /themes/nonexistent.json (missing theme → 404)" "404" \
    "$BASE/themes/nonexistent.json"

# ==================================================================
section "EventBus bridge — SockJS info endpoint at /eventbus/*"
# Tests: SockJSHandler.create(vertx, options), SockJSBridgeOptions,
#        PermittedOptions with address regex "preview\\..+",
#        HeartbeatInterval config, RegisterWriteHandler flag
# ==================================================================

req_fields "GET  /eventbus/info (SockJS server info)" "200" \
'"websocket":true
"cookie_needed"
"entropy"' \
    "$BASE/eventbus/info"

# Verify SockJS generates unique entropy (non-static response → Vert.x
# event loop is processing requests, not serving cached stale data)
ENTROPY1=$(curl -sS "$BASE/eventbus/info" 2>/dev/null | grep -o '"entropy":[0-9]*' | head -1)
ENTROPY2=$(curl -sS "$BASE/eventbus/info" 2>/dev/null | grep -o '"entropy":[0-9]*' | head -1)
if [[ -n "$ENTROPY1" && -n "$ENTROPY2" && "$ENTROPY1" != "$ENTROPY2" ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[entropy differs]${N}\n" "GET  /eventbus/info (unique entropy per request)"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[entropy1=%s, entropy2=%s]${N}\n" "GET  /eventbus/info (unique entropy per request)" "$ENTROPY1" "$ENTROPY2"
  FAIL=$((FAIL+1))
  [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
fi

# ==================================================================
section "Concurrent requests — Vert.x event loop + CopyOnWriteArrayList"
# Tests: Non-blocking I/O under load, thread safety of shared state
# ==================================================================

pids=()
for i in $(seq 1 5); do
  curl -sS -o /dev/null -w "%{http_code}" "$BASE/index.html" > "$TMP/par_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 5); do
  c=$(cat "$TMP/par_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "5x parallel GET /index.html"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "5x parallel GET /index.html"
  FAIL=$((FAIL+1))
fi

pids=()
for i in $(seq 1 3); do
  curl -sS -o /dev/null -w "%{http_code}" "$BASE/images/structurizr-PriceTracker-Container.png" > "$TMP/img_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 3); do
  c=$(cat "$TMP/img_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "3x parallel GET /images/...Container.png"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "3x parallel GET /images/...Container.png"
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

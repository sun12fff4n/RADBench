#!/usr/bin/env bash
# cf-adahandle-resolver — smoke test.
# Covers the public API surface only: 3 REST endpoints + health + API docs.

set -u

BASE="${BASE:-http://localhost:8080}"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; DIM='\033[2m'; N='\033[0m'
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

has_jq=0; command -v jq >/dev/null 2>&1 && has_jq=1
pretty() { if [[ $has_jq -eq 1 ]]; then jq . 2>/dev/null || cat; else cat; fi; }

# req <label> <status-regex> <curl-args...>
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

# req_body <label> <status-regex> <body-fixed-string> <curl-args...>
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

# Bogus but syntactically plausible Cardano addresses / handle.
STAKE_ADDR="stake1u9cjrsudysffer34x2dghndjq2qxjcmj88hp3umfe6ldjhczx5lf3"
PAYMENT_ADDR="addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"
HANDLE="nonexistent_test_handle"

# ------------------------------------------------------------------
section "Infra sanity"
req_body "GET  /actuator/health"                          "200" '"status":"UP"' "$BASE/actuator/health"

# ------------------------------------------------------------------
section "API surface (contract)"
req_body "GET  /v3/api-docs (OpenAPI spec)"               "200" '"openapi"'     "$BASE/v3/api-docs"
req      "GET  /swagger-ui.html → redirect"               "302|303"             "$BASE/swagger-ui.html"
# Structural: OpenAPI spec lists exactly the 3 controller routes.
OPENAPI_PATHS=$(curl -s "$BASE/v3/api-docs" | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d.get('paths',{})))" 2>/dev/null || echo 0)
if [[ "$OPENAPI_PATHS" == "3" ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[3 paths exposed]${N}\n" "OpenAPI spec lists 3 controller routes"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[got %s, want 3]${N}\n" "OpenAPI spec lists 3 controller routes" "$OPENAPI_PATHS"
  FAIL=$((FAIL+1))
fi

# ------------------------------------------------------------------
section "API: ada-handles lookup by address"
# Empty DB returns [].
req_body "GET  /api/v1/ada-handles/by-stake-address/{}"   "200" "[]"            \
         "$BASE/api/v1/ada-handles/by-stake-address/$STAKE_ADDR"
req_body "GET  /api/v1/ada-handles/by-payment-address/{}" "200" "[]"            \
         "$BASE/api/v1/ada-handles/by-payment-address/$PAYMENT_ADDR"

# ------------------------------------------------------------------
section "API: addresses lookup by handle (not-found branch)"
# Different handler: returns 404 when handle not found, vs empty list above.
req      "GET  /api/v1/addresses/by-ada-handle/{} → 404"  "404"                 \
         "$BASE/api/v1/addresses/by-ada-handle/$HANDLE"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

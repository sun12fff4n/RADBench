#!/usr/bin/env bash
# oref-alerts-proxy-ms — smoke test.

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

req_body() {
  local label="$1" expected="$2" pattern="$3"; shift 3
  local body="$TMP/body" code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  local status_ok=0 body_ok=0
  [[ "$code" =~ ^($expected)$ ]] && status_ok=1
  grep -qF "$pattern" "$body" 2>/dev/null && body_ok=1
  if [[ $status_ok -eq 1 && $body_ok -eq 1 ]]; then
    printf "${G}PASS${N} %-58s ${DIM}[%s, body ✓]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    local reason
    if [[ $status_ok -eq 0 ]]; then reason="got $code, want $expected"
    else reason="body missing '$pattern'"; fi
    printf "${R}FAIL${N} %-58s ${DIM}[%s]${N}\n" "$label" "$reason"
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -3 "$body" | sed 's/^/  /'; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}


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
section "Endpoints — happy paths in test mode"
# /current returns CurrentAlertResponse{alert:bool, current:{id,cat,title,data,desc}}.
# In test mode, alert=true and the inner object's 5 README-documented fields
# are populated (see OrefAlertsService.java#62-69).
req_fields "GET  /current  → 200 + key fields present"   "200" \
'"alert":true
"current":{
"id":"
"cat":"
"title":"
"data":[
"desc":"' \
         "$BASE/current"

# /history returns HistoryResponse{history:[{alertDate,title,data,category},...]}.
# Test mode injects 3 hard-coded rows (OrefAlertsService.java#161-180).
req_fields "GET  /history  → 200 + key fields present"   "200" \
'"history":[
"alertDate":"
"title":"
"data":"
"category":1' \
         "$BASE/history"

# Confirm the proxy emits JSON content-type (header check, not body).
HDR=$(curl -sS -D - -o /dev/null "$BASE/current" 2>/dev/null | tr -d '\r')
if echo "$HDR" | grep -qi '^Content-Type: *application/json'; then
  printf "${G}PASS${N} %-58s ${DIM}[application/json]${N}\n" \
    "GET  /current  Content-Type header"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-58s ${DIM}[non-JSON header]${N}\n" \
    "GET  /current  Content-Type header"
  FAIL=$((FAIL+1))
  [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
fi

# ------------------------------------------------------------------
section "Project-defined non-2xx — sanity that routing works"
# 405: controller declares only @GetMapping for /current; Spring's
# RequestMappingHandlerMapping responds 405 (with Allow: GET) for POST.
req "POST /current → 405 (Method Not Allowed)"           "405" \
    -X POST "$BASE/current"
# 404: no handler registered at /. Confirms we're not accidentally on a
# permissive catch-all that masks misrouting.
req "GET  / → 404 (no route)"                            "404" \
    "$BASE/"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

#!/usr/bin/env bash
# ruoqus (RuoYi-Quarkus) — smoke test.


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
section "Login — SysLoginService (CDI, BCrypt, JWT creation)"
# Tests: SysLoginController.login(), SysLoginService.login(),
#        UserDetailsServiceImpl.loadUserByUsername(), BCrypt.checkpw(),
#        TokenService.createToken(), SmallRye JWT build
# ==================================================================

# Successful login with hardcoded user ry/admin123
req_fields "POST /login (valid credentials)" "200" \
'"status":"success"
"token"
"msg"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"ry","password":"admin123"}' \
    "$BASE/login"

# Extract token for subsequent authenticated requests
TOKEN=$(curl -sS -X POST -H "Content-Type: application/json" \
    -d '{"username":"ry","password":"admin123"}' \
    "$BASE/login" 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [[ -n "$TOKEN" ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[token extracted]${N}\n" "  → JWT token obtained"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[empty token]${N}\n" "  → JWT token obtained"
  FAIL=$((FAIL+1))
fi

# ==================================================================
section "Login validation — input checking"
# Tests: SysLoginService.loginPreCheck(), validation logic
# ==================================================================

# Wrong password
req_fields "POST /login (wrong password → 500)" "500" \
'"code":500
"msg":"user.password.not.match"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"ry","password":"wrongpassword"}' \
    "$BASE/login"

# Non-existent user
req_fields "POST /login (unknown user → 500)" "500" \
'"code":500
"msg":"user.not.exists"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"nonexistent","password":"admin123"}' \
    "$BASE/login"

# Empty credentials
req_fields "POST /login (empty username → 500)" "500" \
'"code":500
"msg"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"","password":"admin123"}' \
    "$BASE/login"

# Password too short
req_fields "POST /login (short password → 500)" "500" \
'"code":500
"msg"' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"ry","password":"ab"}' \
    "$BASE/login"

# ==================================================================
section "Authenticated endpoints — JWT verification"
# Tests: JwtAuthenticationMechanism.authenticate(), TokenService.getLoginUser(),
#        TokenService.verifyToken(), QuarkusSecurityIdentity.Builder
# ==================================================================

# /list requires auth — with valid token
if [[ -n "$TOKEN" ]]; then
  req_fields "GET  /list (with valid JWT)" "200" \
'"status":"success"
"message"' \
      -H "Authorization: Bearer $TOKEN" \
      "$BASE/list"
else
  printf "${Y}SKIP${N} %-60s ${DIM}[no token]${N}\n" "GET  /list (with valid JWT)"
fi

# /list without token → 401
req "GET  /list (no token → 401)" "401" \
    "$BASE/list"

# /getUserInfo requires specific permission → 403 with valid token but insufficient perms
if [[ -n "$TOKEN" ]]; then
  req "GET  /getUserInfo (insufficient perms → 403)" "403" \
      -H "Authorization: Bearer $TOKEN" \
      "$BASE/getUserInfo"
else
  printf "${Y}SKIP${N} %-60s ${DIM}[no token]${N}\n" "GET  /getUserInfo (insufficient perms → 403)"
fi

# /getUserInfo without token → 401
req "GET  /getUserInfo (no token → 401)" "401" \
    "$BASE/getUserInfo"

# ==================================================================
section "Logout — TokenService.delLoginUser()"
# Tests: SysLoginController.logout(), TokenService.delLoginUser(),
#        ConcurrentHashMap cache removal
# ==================================================================

if [[ -n "$TOKEN" ]]; then
  req_body "GET  /logout (with JWT)" "200" \
      '"message"' \
      -H "Authorization: Bearer $TOKEN" \
      "$BASE/logout"

  # After logout, token should be invalid
  req "GET  /list (after logout → 401)" "401" \
      -H "Authorization: Bearer $TOKEN" \
      "$BASE/list"
else
  printf "${Y}SKIP${N} %-60s ${DIM}[no token]${N}\n" "GET  /logout (with JWT)"
  printf "${Y}SKIP${N} %-60s ${DIM}[no token]${N}\n" "GET  /list (after logout → 401)"
fi

# ==================================================================
section "Invalid token — JWT parsing error paths"
# Tests: TokenService.parseToken(), JWT signature verification failure
# ==================================================================

req "GET  /list (invalid token → 401)" "401" \
    -H "Authorization: Bearer invalid.jwt.token" \
    "$BASE/list"

req "GET  /list (expired/malformed → 401)" "401" \
    -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.fake" \
    "$BASE/list"

# ==================================================================
section "CORS — Quarkus HTTP CORS configuration"
# Tests: quarkus.http.cors=true, Access-Control-Allow-Origin: *
# ==================================================================

req_header "OPTIONS /login (CORS preflight)" "200|204" "access-control-allow" \
    -X OPTIONS \
    -H "Origin: http://example.com" \
    -H "Access-Control-Request-Method: POST" \
    "$BASE/login"

# ==================================================================
section "Content-Type — Jackson JSON serialization"
# Tests: quarkus-rest-jackson, application/json response type
# ==================================================================

req_header "POST /login (JSON content-type response)" "200" "application/json" \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"ry","password":"admin123"}' \
    "$BASE/login"

# ==================================================================
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

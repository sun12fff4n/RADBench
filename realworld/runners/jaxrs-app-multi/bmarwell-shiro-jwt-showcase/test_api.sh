#!/usr/bin/env bash
# shiro-jwt-showcase — smoke test.


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

# Helper: obtain JWT token with given roles
get_token() {
  local roles="$1"
  curl -sS -X POST "$BASE/issuer/login?roles=$roles" \
    -H "Content-Type: application/json" \
    -d '{"username":"shiro","password":"shiro"}' 2>/dev/null \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\).*/\1/p'
}

# ==================================================================
section "Token issuance — IssueEndpoint (CDI, JJWT, MicroProfile Config)"
# Tests: IssueEndpoint.doLogin(), CredentialsValidatorImpl.validate(),
#        TokenServiceImpl.createJwt(), KeyService.createJwtBuilder(),
#        KeystoreLoader.loadKeystore(), JSON-B serialization
# ==================================================================

req_body "POST /issuer/login (valid credentials, admin)" "202" \
    '"token"' \
    -X POST "$BASE/issuer/login?roles=admin" \
    -H "Content-Type: application/json" \
    -d '{"username":"shiro","password":"shiro"}'

req_body "POST /issuer/login (valid credentials, user role)" "202" \
    '"token"' \
    -X POST "$BASE/issuer/login?roles=user" \
    -H "Content-Type: application/json" \
    -d '{"username":"shiro","password":"shiro"}'

req_body "POST /issuer/login (valid credentials, mod role)" "202" \
    '"token"' \
    -X POST "$BASE/issuer/login?roles=mod" \
    -H "Content-Type: application/json" \
    -d '{"username":"shiro","password":"shiro"}'

req "POST /issuer/login (invalid credentials → 401)" "401" \
    -X POST "$BASE/issuer/login?roles=admin" \
    -H "Content-Type: application/json" \
    -d '{"username":"shiro","password":"wrong"}'

# Get tokens for subsequent tests
ADMIN_TOKEN=$(get_token "admin")
MOD_TOKEN=$(get_token "mod")
USER_TOKEN=$(get_token "user")
GUEST_TOKEN=$(get_token "guest")

# ==================================================================
section "Unauthenticated access — Shiro JwtHttpAuthenticator"
# Tests: JwtHttpAuthenticator (no token → 401), Shiro filter chain,
#        shiro.ini authcJWT[permissive] handling
# ==================================================================

req "GET  /finish/troopers (no token → 401)" "401" \
    "$BASE/finish/troopers"

# ==================================================================
section "Guest role — Shiro RBAC (no permissions)"
# Tests: JwtRealm.doGetAuthorizationInfo(), StaticJwtRolePermissionResolver,
#        @RequiresPermissions denied → 403
# ==================================================================

req "GET  /finish/troopers (guest role → 403)" "403" \
    -H "Authorization: Bearer $GUEST_TOKEN" \
    "$BASE/finish/troopers"

# ==================================================================
section "Admin CRUD — StormtrooperResource (full permissions)"
# Tests: StormtrooperResource.createTrooper(), .listTroopers(),
#        .getTrooper(), .updateTrooper(), .deleteTrooper(),
#        StormtrooperDaoImpl, JSON-B Stormtrooper record, @JsonbCreator
# ==================================================================

# Create a trooper as admin
req_body "POST /finish/troopers (admin create)" "202" \
    '"id"' \
    -X POST "$BASE/finish/troopers" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"planetOfOrigin":"Tatooine","species":"Human","type":"Infantry"}'

# Create another trooper for later tests
CREATED=$(curl -sS -X POST "$BASE/finish/troopers" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"planetOfOrigin":"Kamino","species":"Clone","type":"ARC"}' 2>/dev/null)
TROOPER_ID=$(echo "$CREATED" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\).*/\1/p')

# List troopers
req_body "GET  /finish/troopers (admin list)" "200" \
    '"id"' \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$BASE/finish/troopers"

req_header "GET  /finish/troopers (JSON content-type)" "200" "application/json" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$BASE/finish/troopers"

# Get specific trooper
if [[ -n "$TROOPER_ID" ]]; then
  req_fields "GET  /finish/troopers/{id} (admin get)" "200" \
'"id"
"planetOfOrigin"
"species"
"type"' \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "$BASE/finish/troopers/$TROOPER_ID"

  # Update trooper
  req "PUT  /finish/troopers/{id} (admin update)" "202" \
      -X PUT "$BASE/finish/troopers/$TROOPER_ID" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"planetOfOrigin":"Coruscant","species":"Human","type":"Commander"}'

  # Verify update
  req_body "GET  /finish/troopers/{id} (verify update)" "200" \
      '"Coruscant"' \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "$BASE/finish/troopers/$TROOPER_ID"

  # Delete trooper
  req "DELETE /finish/troopers/{id} (admin delete)" "202" \
      -X DELETE "$BASE/finish/troopers/$TROOPER_ID" \
      -H "Authorization: Bearer $ADMIN_TOKEN"

  # Verify deletion
  req "GET  /finish/troopers/{id} (after delete → 404)" "404" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "$BASE/finish/troopers/$TROOPER_ID"
else
  echo -e "${Y}SKIP${N} Trooper CRUD tests (could not extract ID)"
fi

# ==================================================================
section "Moderator role — partial permissions (read, create, update)"
# Tests: StaticJwtRolePermissionResolver mod → troopers:read,create,update
#        @RequiresPermissions granular checks
# ==================================================================

req_body "GET  /finish/troopers (mod read)" "200" \
    '"id"' \
    -H "Authorization: Bearer $MOD_TOKEN" \
    "$BASE/finish/troopers"

req_body "POST /finish/troopers (mod create)" "202" \
    '"id"' \
    -X POST "$BASE/finish/troopers" \
    -H "Authorization: Bearer $MOD_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"planetOfOrigin":"Endor","species":"Ewok","type":"Scout"}'

# Get a trooper ID to test update/delete
MOD_LIST=$(curl -sS -H "Authorization: Bearer $MOD_TOKEN" "$BASE/finish/troopers" 2>/dev/null)
MOD_ID=$(echo "$MOD_LIST" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\).*/\1/p' | head -1)

if [[ -n "$MOD_ID" ]]; then
  req "PUT  /finish/troopers/{id} (mod update)" "202" \
      -X PUT "$BASE/finish/troopers/$MOD_ID" \
      -H "Authorization: Bearer $MOD_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"planetOfOrigin":"Hoth","species":"Human","type":"Snowtrooper"}'

  req "DELETE /finish/troopers/{id} (mod delete → 403)" "403" \
      -X DELETE "$BASE/finish/troopers/$MOD_ID" \
      -H "Authorization: Bearer $MOD_TOKEN"
fi

# ==================================================================
section "User role — read-only permissions"
# Tests: StaticJwtRolePermissionResolver user → troopers:read only
# ==================================================================

req_body "GET  /finish/troopers (user read)" "200" \
    '"id"' \
    -H "Authorization: Bearer $USER_TOKEN" \
    "$BASE/finish/troopers"

req "POST /finish/troopers (user create → 403)" "403" \
    -X POST "$BASE/finish/troopers" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"planetOfOrigin":"Naboo","species":"Gungan","type":"Warrior"}'

if [[ -n "$MOD_ID" ]]; then
  req "PUT  /finish/troopers/{id} (user update → 403)" "403" \
      -X PUT "$BASE/finish/troopers/$MOD_ID" \
      -H "Authorization: Bearer $USER_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"planetOfOrigin":"Dagobah","species":"Unknown","type":"Jedi"}'

  req "DELETE /finish/troopers/{id} (user delete → 403)" "403" \
      -X DELETE "$BASE/finish/troopers/$MOD_ID" \
      -H "Authorization: Bearer $USER_TOKEN"
fi

# ==================================================================
section "Invalid token — JwtCheckingCredentialsMatcher"
# Tests: JwtCheckingCredentialsMatcher.doCredentialsMatch(),
#        JWT signature verification, token parsing failure
# ==================================================================

req "GET  /finish/troopers (invalid token → 401)" "401" \
    -H "Authorization: Bearer invalid.jwt.token" \
    "$BASE/finish/troopers"

req "GET  /finish/troopers (empty bearer → 401)" "401" \
    -H "Authorization: Bearer " \
    "$BASE/finish/troopers"

# ==================================================================
section "Delete all — admin bulk operation"
# Tests: StormtrooperResource.deleteAllTroopers(),
#        StormtrooperDaoImpl.deleteAllStormTroopers()
# ==================================================================

req "DELETE /finish/troopers/ (admin delete all)" "202" \
    -X DELETE "$BASE/finish/troopers/" \
    -H "Authorization: Bearer $ADMIN_TOKEN"

# Verify empty list
req_body "GET  /finish/troopers (empty after delete all)" "200" \
    '[]' \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$BASE/finish/troopers"

# ==================================================================
section "Concurrent requests — Liberty thread pool"
# Tests: Non-blocking I/O, multiple clients served concurrently
# ==================================================================

pids=()
for i in $(seq 1 5); do
  curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$BASE/finish/troopers" > "$TMP/par_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 5); do
  c=$(cat "$TMP/par_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "5x parallel GET /finish/troopers"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "5x parallel GET /finish/troopers"
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

#!/usr/bin/env bash
# despensa-rest-api —smoke test.

set -u

BASE="${BASE:-http://localhost:8080}"
API="${BASE}/api"
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

# Status + fixed substring in body. Used to confirm the response is real
# business data, not an empty 200.
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

req_fields() {
  local label="$1" expected="$2" patterns="$3"; shift 3
  local body="$TMP/body" code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  if [[ ! "$code" =~ ^($expected)$ ]]; then
    printf "${R}FAIL${N} %-60s ${DIM}[got %s, want %s]${N}\n" "$label" "$code" "$expected"
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
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -5 "$body" | sed 's/^/  /'; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

# ------------------------------------------------------------------
section "Setup — register fresh user, login, capture JWT + user id"

USERNAME="apitest_$RANDOM$RANDOM"
PASSWORD="testpass123"

# Register: returns {"username":"..."} on 200. Repeated username → 400.
req_body "POST /auth/register"                           "200" '"username"' \
         -X POST -H "Content-Type: application/json" \
         -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
         "$API/auth/register"

# Login: returns {"accessToken":"<JWT>","user":{"id":N,"username":"..."}}.
LOGIN=$(curl -sS -X POST -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
        "$API/auth/login")
TOKEN=$(echo "$LOGIN" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("accessToken",""))')
USER_ID=$(echo "$LOGIN" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user",{}).get("id",""))')
[[ -z "$TOKEN" || -z "$USER_ID" ]] && { echo -e "${R}ERROR: login parse failed${N}"; exit 1; }
AUTH=(-H "Authorization: Bearer ${TOKEN}")
echo -e "${DIM}user_id=${USER_ID}  token=${TOKEN:0:32}...${N}"

# Re-run the login as a tracked test so it shows in the summary.
# AuthenticationRes carries: accessToken (JWT) + nested user{id, username}.
req_fields "POST /auth/login (key fields: token + user)"  "200" \
'"accessToken":"
"user":{
"id":
"username":"' \
         -X POST -H "Content-Type: application/json" \
         -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
         "$API/auth/login"

# ------------------------------------------------------------------
section "Read endpoints — every controller surface returns real 200"
# UserRes shape: id, username, shoppingList[].
req_fields "GET  /users/{self}"                          "200" \
'"id":
"username":"
"shoppingList":' \
         "${AUTH[@]}" "$API/users/${USER_ID}"
# Paged ProductRes: content[{id,name,price,...}] + pagination meta.
req_fields "GET  /products (paged)"                      "200" \
'"content":[
"currentPage":
"pageSize":
"totalPages":
"total":' \
         "${AUTH[@]}" "$API/products"
# Paged ShoppingListRes (empty for fresh user; pagination meta still present).
req_fields "GET  /shopping-lists (paged)"                "200" \
'"content":
"currentPage":
"pageSize":
"totalPages":
"total":' \
         "${AUTH[@]}" "$API/shopping-lists"
# Paged UnitTypeRes: content[{id,name}].
req_fields "GET  /unit-types (paged)"                    "200" \
'"content":[
"currentPage":
"totalPages":' \
         "${AUTH[@]}" "$API/unit-types"
# Admin variant adds createdAt/updatedAt — proves the admin-DTO mapper runs.
req_fields "GET  /admin/unit-types (paged, admin DTO)"   "200" \
'"content":[
"createdAt":"
"updatedAt":"
"totalPages":' \
         "${AUTH[@]}" "$API/admin/unit-types"
# i18n bundle: common.* + home.* sections.
req_fields "GET  /resources/languages (i18n bundle)"     "200" \
'"common":{
"home":{
"actions":
"shopping-lists":' \
         "${AUTH[@]}" "$API/resources/languages"

# ------------------------------------------------------------------
section "ShoppingList CRUD chain — create → read → update → list-products → delete"
# POST creates a list owned by the logged-in user, returns {"id":N,"name":"..."}.
CREATE=$(curl -sS -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{"name":"Weekly Groceries"}' "$API/shopping-lists")
LIST_ID=$(echo "$CREATE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
[[ -z "$LIST_ID" ]] && { echo -e "${R}ERROR: shopping-list create parse failed${N}"; exit 1; }

# Create response: minimal {id, name} — both fields required.
req_fields "POST /shopping-lists (create — id+name)"     "200" \
'"id":
"name":"' \
         -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{"name":"Weekly Groceries 2"}' "$API/shopping-lists"
# Single-list GET response is richer: id, name, totals, productList (paged),
# selectProductOption[]. Asserting all four sub-shapes are present.
req_fields "GET  /shopping-lists/{id} (full DTO)"        "200" \
'"id":
"name":"Weekly Groceries"
"totalProducts":
"productList":{
"selectProductOption":[' \
         "${AUTH[@]}" "$API/shopping-lists/${LIST_ID}"
req      "PUT  /shopping-lists/{id} (update name)"       "200" \
         -X PUT -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{"name":"Renamed"}' "$API/shopping-lists/${LIST_ID}"
req      "GET  /shopping-lists/{id}/products (empty list)" "200" \
         "${AUTH[@]}" "$API/shopping-lists/${LIST_ID}/products"
req      "DELETE /shopping-lists/{id}"                   "204" \
         -X DELETE "${AUTH[@]}" "$API/shopping-lists/${LIST_ID}"
# State-transition: list no longer exists → project-defined 404 (the only
# non-2xx in the test, and it IS the project's correct response).
req      "GET  /shopping-lists/{id} (after delete → 404)" "404" \
         "${AUTH[@]}" "$API/shopping-lists/${LIST_ID}"

# ------------------------------------------------------------------
section "Enum + JPA Specification — SelectedProducts enum via @ModelAttribute"
# GET /shopping-lists/{id}?selected=YES triggers:
#   1. SelectedProducts enum binding via Spring's StringToEnum converter (reflection)
#   2. ProductHasShoppingListSpecs.findAll() — JPA Criteria API root.get() path traversal
#   3. selectProductOption response contains serialised SelectedProducts enum values
# Create a fresh list for this section.
ENUM_LIST=$(curl -sS -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
            -d '{"name":"Enum Test List"}' "$API/shopping-lists" \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')

req_fields "GET  /shopping-lists/{id}?selected=YES (enum bind)"  "200" \
'"selectProductOption":[
"value":"YES"
"value":"NO"
"value":"ALL"
"label":' \
         "${AUTH[@]}" "$API/shopping-lists/${ENUM_LIST}?selected=YES"

req_fields "GET  /shopping-lists/{id}?selected=NO  (enum bind)"  "200" \
'"selectProductOption":[
"value":"NO"
"selected":true' \
         "${AUTH[@]}" "$API/shopping-lists/${ENUM_LIST}?selected=NO"

req_fields "GET  /shopping-lists/{id}?selected=ALL (enum bind)"  "200" \
'"selectProductOption":[
"value":"ALL"' \
         "${AUTH[@]}" "$API/shopping-lists/${ENUM_LIST}?selected=ALL"

# PUT /shopping-lists/{id}/products-selected — ActionType enum in JSON body
req      "PUT  /products-selected (ActionType.SELECT enum deser)" "204" \
         -X PUT -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{"action":"SELECT"}' "$API/shopping-lists/${ENUM_LIST}/products-selected"
req      "PUT  /products-selected (ActionType.DESELECT)"          "204" \
         -X PUT -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{"action":"DESELECT"}' "$API/shopping-lists/${ENUM_LIST}/products-selected"

# Cleanup
curl -sS -X DELETE "${AUTH[@]}" "$API/shopping-lists/${ENUM_LIST}" > /dev/null

# ------------------------------------------------------------------
section "Pageable parameter binding"
# Explicit page/size/sort params exercise Spring's PageableHandlerMethodArgumentResolver (reflection).
req_fields "GET  /products?page=0&size=2 (explicit pageable)"     "200" \
'"content":
"currentPage":0
"pageSize":2
"totalPages":' \
         "${AUTH[@]}" "$API/products?page=0&size=2"

req_fields "GET  /unit-types?page=0&size=1&sort=id,desc (sort)"   "200" \
'"content":[
"currentPage":0
"pageSize":1' \
         "${AUTH[@]}" "$API/unit-types?page=0&size=1&sort=id,desc"

# ------------------------------------------------------------------
section "Exception handling — @RestControllerAdvice → ErrorRes(ProblemDetail)"
# NotFoundException → ResponseStatusException → handleResponseStatusException → ErrorRes wrapping ProblemDetail (RFC 7807).
req_fields "GET  /users/999999 (NotFoundException → ErrorRes)"    "404" \
'"error":{
"status":404
"detail":' \
         "${AUTH[@]}" "$API/users/999999"

# 405 Method Not Allowed — POST on a GET-only endpoint. Handled by
# handleExceptionInternal override → ErrorRes with ProblemDetail.
req_fields "POST /users/{id} (405 → ErrorRes)"                   "405" \
'"error":{
"status":405' \
         -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{}' "$API/users/${USER_ID}"

# Invalid enum value — Spring binding error when SelectedProducts cannot parse.
req      "GET  /shopping-lists/{id}?selected=BOGUS (bad enum)"   "400|500" \
         "${AUTH[@]}" "$API/shopping-lists/1?selected=BOGUS"

# ------------------------------------------------------------------
section "Springdoc OpenAPI spec"
# Exercises springdoc-openapi auto-discovery — scans all @RestController classes via reflection.
req_body "GET  /api-docs (OpenAPI JSON)"                         "200" '"openapi"' \
         "$BASE/api-docs"
req      "GET  /api-docs (Public group)"                         "200" \
         "$BASE/api-docs/Public"
req      "GET  /api-docs (Admin group)"                          "200" \
         "$BASE/api-docs/Admin"

# ------------------------------------------------------------------
section "Auth-gate sanity"
# Permit-all=/** means a tokenless GET still gets 200 — that doesn't prove
# the JWT filter runs. A malformed Bearer DOES exercise the filter: the
# OAuth2 resource server's JwtDecoder rejects bad signature → 401.
req "GET  /users/{self} (garbage Bearer token → 401)"    "401" \
    -H "Authorization: Bearer garbage.garbage.garbage" "$API/users/${USER_ID}"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

#!/usr/bin/env bash
# favorite-coffee — smoke test.

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
section "Health check — SmallRye Health (@Readiness)"
# Tests: Health.call(), SmallRye Health integration, HealthCheckResponse
# ==================================================================

req_fields "GET  /q/health/ready (readiness check)" "200" \
'"status": "UP"
"coffee-shop"' \
    "$BASE/q/health/ready"

req_body "GET  /q/health/live (liveness check)" "200" \
    '"status": "UP"' \
    "$BASE/q/health/live"

# ==================================================================
section "Beans list — CoffeeBeansResource (Neo4j OGM, JSON-B)"
# Tests: CoffeeBeansResource.beans(), CoffeeBeans.getCoffeeBeans(),
#        Neo4j OGM session.loadAll(), JSON-B serialization
# ==================================================================

req_fields "GET  /beans (list all beans)" "200" \
'"name":"Buna"
"name":"El gato loco"
"name":"Saboroso"
"name":"Kahawa Nzuri"' \
    "$BASE/beans"

req_header "GET  /beans (JSON content-type)" "200" "application/json" \
    "$BASE/beans"

# Filter by flavor
req_body "GET  /beans?flavor=Fruit (filter by flavor)" "200" \
    '"name"' \
    "$BASE/beans?flavor=Fruit"

# ==================================================================
section "Bean ratings — CoffeeBeansResource (Cypher queries)"
# Tests: CoffeeBeans.getCoffeeBeanRatings(), session.queryDto(),
#        CoffeeBeanRating DTO mapping
# ==================================================================

req "GET  /beans/rated (rated beans list)" "200" \
    "$BASE/beans/rated"

# ==================================================================
section "Recommendations — CoffeeBeansResource (complex Cypher)"
# Tests: CoffeeBeans.getRecommendedBeans(), complex Cypher query,
#        OGM result mapping
# ==================================================================

req "GET  /beans/recommended (recommendations)" "200" \
    "$BASE/beans/recommended"

req "GET  /beans/untested (untested beans)" "200" \
    "$BASE/beans/untested"

# ==================================================================
section "Write — POST /beans (JSON-B deserialization, Neo4j OGM persist)"
# Tests: CoffeeBeansResource.create(), CoffeeBeans.createCoffeeBean(),
#        JSON-B deserialization of CoffeeBean, Neo4j OGM session.save(),
#        entity-to-node mapping, relationship persist
# ==================================================================

CREATED_BEAN=$(curl -sS -o "$TMP/created" -w "%{http_code}" \
    -X POST "$BASE/beans" \
    -H "Content-Type: application/json" \
    -d '{"name":"TestSmoke","origin":{"country":"Colombia"},"flavorProfiles":[{"flavor":{"name":"Chocolate"},"percentage":0.6},{"flavor":{"name":"Nutty"},"percentage":0.4}]}' 2>/dev/null)
if [[ "$CREATED_BEAN" =~ ^(200|201|204)$ ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[%s]${N}\n" "POST /beans (create bean)" "$CREATED_BEAN"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[got %s, want 200|201|204]${N}\n" "POST /beans (create bean)" "$CREATED_BEAN"
  FAIL=$((FAIL+1))
fi

# Extract a bean UUID for further tests
BEAN_UUID=$(curl -sS "$BASE/beans" 2>/dev/null | sed -n 's/.*"uuid"[[:space:]]*:[[:space:]]*"\([^"]*\).*/\1/p' | head -1)

# ==================================================================
section "Write — PUT /beans/{id}/ratings (Neo4j OGM relationship write)"
# Tests: CoffeeBeansResource.rate(), CoffeeBeans.rateCoffeeBean(),
#        Neo4j OGM relationship update, JSON-B deserialization of Rating
# ==================================================================

if [[ -n "$BEAN_UUID" ]]; then
  req "PUT  /beans/{id}/ratings (rate bean)" "200|204" \
      -X PUT "$BASE/beans/$BEAN_UUID/ratings" \
      -H "Content-Type: application/json" \
      -d '{"value":4}'

  # Verify rating appears
  req_body "GET  /beans/rated (after rating)" "200" \
      '"name"' \
      "$BASE/beans/rated"
else
  printf "${Y}SKIP${N} %-60s ${DIM}[no UUID]${N}\n" "PUT /beans/{id}/ratings"
fi

# ==================================================================
section "Write — PATCH /beans/{id} (Neo4j OGM partial update)"
# Tests: CoffeeBeansResource.updateFlavorProfiles(),
#        CoffeeBeans.updateFlavorProfiles(), Neo4j OGM partial save
# ==================================================================

if [[ -n "$BEAN_UUID" ]]; then
  req "PATCH /beans/{id} (update flavors)" "200|204" \
      -X PATCH "$BASE/beans/$BEAN_UUID" \
      -H "Content-Type: application/json" \
      -d '[{"flavor":{"name":"Sweet"},"percentage":0.5},{"flavor":{"name":"Caramel"},"percentage":0.5}]'
else
  printf "${Y}SKIP${N} %-60s ${DIM}[no UUID]${N}\n" "PATCH /beans/{id}"
fi

# ==================================================================
section "Write — DELETE /beans/{id} (Neo4j OGM delete)"
# Tests: CoffeeBeansResource.delete(), CoffeeBeans.deleteCoffeeBean(),
#        Neo4j OGM session.delete()
# ==================================================================

if [[ -n "$BEAN_UUID" ]]; then
  req "DELETE /beans/{id} (delete bean)" "200|204" \
      -X DELETE "$BASE/beans/$BEAN_UUID"
else
  printf "${Y}SKIP${N} %-60s ${DIM}[no UUID]${N}\n" "DELETE /beans/{id}"
fi

# ==================================================================
section "Profile page — UserPageController (Qute template)"
# Tests: UserPageController.profile(), Qute rendering, CDI injection
# ==================================================================

req "GET  /profile (user profile page)" "200" \
    "$BASE/profile"

# ==================================================================
section "Index page — IndexController (Qute templates)"
# Tests: IndexController.index(), Qute Template injection (@Location),
#        TemplateInstance rendering, @TemplateExtension
# ==================================================================

req_body "GET  / (HTML index page)" "200" \
    "Buna" \
    "$BASE/"

req_header "GET  / (text/html content-type)" "200" "text/html" \
    "$BASE/"

# Sort by name
req_body "GET  /?sortBy=NAME (sort criteria)" "200" \
    "Buna" \
    "$BASE/?sortBy=NAME"

# Sort by RATING triggers different OGM query path
req "GET  /?sortBy=RATING (sort by rating)" "200" \
    "$BASE/?sortBy=RATING"

# ==================================================================
section "Static resources — CSS/JS"
# Tests: Quarkus static resource serving (META-INF/resources)
# ==================================================================

req "GET  /style.css (static CSS)" "200" \
    "$BASE/style.css"

req "GET  /ratings.js (static JS)" "200" \
    "$BASE/ratings.js"

# ==================================================================
section "Error paths — 404 and validation"
# Tests: JAX-RS routing, NotFoundException, IllegalArgumentExceptionMapper
# ==================================================================

req "GET  /nonexistent (→ 404)" "404" \
    "$BASE/nonexistent"

req "GET  /beans/00000000-0000-0000-0000-000000000000 (→ 404)" "404" \
    "$BASE/beans/00000000-0000-0000-0000-000000000000"

# Invalid sortBy triggers IllegalArgumentExceptionMapper
req "GET  /?sortBy=INVALID (bad sort → 400|500)" "400|500" \
    "$BASE/?sortBy=INVALID"

# ==================================================================
section "Concurrent requests — Vert.x event loop (Quarkus)"
# Tests: Non-blocking I/O, multiple clients served concurrently
# ==================================================================

pids=()
for i in $(seq 1 5); do
  curl -sS -o /dev/null -w "%{http_code}" "$BASE/beans" > "$TMP/par_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 5); do
  c=$(cat "$TMP/par_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "5x parallel GET /beans"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "5x parallel GET /beans"
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

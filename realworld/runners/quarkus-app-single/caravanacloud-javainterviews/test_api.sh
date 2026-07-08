#!/usr/bin/env bash
# javainterviews — smoke test.

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
section "Hello endpoint — HelloResource (JAX-RS, ReverseInplace algo)"
# Tests: HelloResource.hello(), @QueryParam/@DefaultValue injection,
#        ReverseInplace.reverse(), Vert.x JsonObject serialization
# ==================================================================

# Default name "fulano" → reversed "onaluf"
req_fields "GET  /hello (default name)" "200" \
'"message"
"Hello onaluf"' \
    "$BASE/hello"

# Custom name parameter
req_body "GET  /hello?name=world (custom name)" "200" \
    '"Hello dlrow"' \
    "$BASE/hello?name=world"

req_header "GET  /hello (JSON content-type)" "200" "application/json" \
    "$BASE/hello"

# ==================================================================
section "PairSum random — PairSumResource (algorithm + JSON)"
# Tests: PairSumResource.getRandoms(), @QueryParam injection,
#        Random number generation, JsonObject response
# ==================================================================

req_fields "GET  /pairsum/random (default n=10)" "200" \
'"xs"
"target"' \
    "$BASE/pairsum/random"

req_fields "GET  /pairsum/random?n=5 (custom n)" "200" \
'"xs"
"target"' \
    "$BASE/pairsum/random?n=5"

req_header "GET  /pairsum/random (JSON content-type)" "200" "application/json" \
    "$BASE/pairsum/random"

# ==================================================================
section "PairSum solver — PairSumResource (algorithm variants)"
# Tests: PairSumResource.getIter/getMemo/getTunnel(),
#        Jackson deserialization of JSON body on GET,
#        PairSumIter/PairSumMemo/PairSumTunnel algorithm execution
# ==================================================================

# Generate a random input first
PAIR_INPUT=$(curl -sS "$BASE/pairsum/random?n=5" 2>/dev/null)
if [[ -n "$PAIR_INPUT" && "$PAIR_INPUT" == *'"xs"'* ]]; then
  # Call each solver variant with the same input
  req_body "GET  /pairsum/iter (iterative solver)" "200" \
      '"result"' \
      -H "Content-Type: application/json" \
      -d "$PAIR_INPUT" \
      "$BASE/pairsum/iter"

  req_body "GET  /pairsum/memo (memoized solver)" "200" \
      '"result"' \
      -H "Content-Type: application/json" \
      -d "$PAIR_INPUT" \
      "$BASE/pairsum/memo"

  req_body "GET  /pairsum/tunnel (tunnel solver)" "200" \
      '"result"' \
      -H "Content-Type: application/json" \
      -d "$PAIR_INPUT" \
      "$BASE/pairsum/tunnel"
fi

# ==================================================================
section "Mutant endpoint — MutantResource"
# Tests: MutantResource.getMutant(), @Path("mutant") + @Path("random")
# ==================================================================

req_body "GET  /mutant/random" "200" \
    "UALA" \
    "$BASE/mutant/random"

# Edge cases — empty/long names for Jackson deserialization
req_body "GET  /hello?name= (empty name)" "200" \
    '"Hello "' \
    "$BASE/hello?name="

req_body "GET  /hello?name=ABCDEFGHIJKLMNOPQRSTUVWXYZ (long name)" "200" \
    '"message"' \
    "$BASE/hello?name=ABCDEFGHIJKLMNOPQRSTUVWXYZ"

# ==================================================================
section "Static resources — META-INF/resources"
# Tests: Quarkus static resource serving (index.html)
# ==================================================================

req "GET  / (static index.html)" "200" \
    "$BASE/"

# ==================================================================
section "Error paths — 404 for unknown endpoints"
# Tests: JAX-RS routing, no-match handling
# ==================================================================

req "GET  /nonexistent (→ 404)" "404" \
    "$BASE/nonexistent"

req "GET  /api/v1/nothing (→ 404)" "404" \
    "$BASE/api/v1/nothing"

# ==================================================================
section "Concurrent requests — Vert.x event loop (Quarkus)"
# Tests: Non-blocking I/O, multiple clients served concurrently
# ==================================================================

pids=()
for i in $(seq 1 5); do
  curl -sS -o /dev/null -w "%{http_code}" "$BASE/hello" > "$TMP/par_$i" 2>/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
all_ok=1
for i in $(seq 1 5); do
  c=$(cat "$TMP/par_$i" 2>/dev/null)
  [[ "$c" != "200" ]] && all_ok=0
done
if [[ $all_ok -eq 1 ]]; then
  printf "${G}PASS${N} %-60s ${DIM}[all 200]${N}\n" "5x parallel GET /hello"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-60s ${DIM}[some failed]${N}\n" "5x parallel GET /hello"
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

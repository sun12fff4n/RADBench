#!/usr/bin/env bash
# conciliator  smoke test.
# OpenRefine reconciliation service with no auth (SecurityFilterChain is
# configured permitAll). Five data-source controllers (VIAF, ORCID,
# OpenLibrary, Solr, plus variants) + utility endpoints (/version, /stats,
# /debug). 

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
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -5 "$body" | sed 's/^/  /'; }
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
    [[ -s "$body" ]] && { echo -e "${Y}--- body ---${N}"; head -5 "$body" | sed 's/^/  /'; }
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

# ------------------------------------------------------------------
section "Utility / infra"
req_body "GET  /version"                          "200" "."                 "$BASE/version"
req_body "GET  /stats (JSON with dataSources)"    "200" '"dataSources"'     "$BASE/stats"
req_body "GET  /debug (memory usage line)"        "200" "memory usage"      "$BASE/debug"

# ------------------------------------------------------------------
section "Reconcile service-metadata (no query param)"
# Each GET on /reconcile/<source> without ?query returns the OpenRefine
# reconciliation service metadata JSON — includes name, identifierSpace,
# defaultTypes, view URL template.
req_body "GET  /reconcile/viaf (VIAFController)"            "200" '"name":"VIAF"'          "$BASE/reconcile/viaf"
req_body "GET  /reconcile/viaf/LC (VIAFSourceSpecificController)" "200" '"name":"VIAF - LC"' "$BASE/reconcile/viaf/LC"
req_body "GET  /reconcile/viafproxy/LC (VIAFProxyController)"   "200" '"LC (by way of VIAF)"' "$BASE/reconcile/viafproxy/LC"
req_body "GET  /reconcile/orcid (OrcidController)"          "200" '"name":"ORCID"'         "$BASE/reconcile/orcid"
req_body "GET  /reconcile/orcid/smartnames (OrcidSmartNamesController)" "200" 'Smart Names Mode' "$BASE/reconcile/orcid/smartnames"
req_body "GET  /reconcile/openlibrary (OpenLibraryController)" "200" '"OpenLibrary"'        "$BASE/reconcile/openlibrary"
req      "GET  /reconcile/solr (SolrController — unconfigured)" "200" "$BASE/reconcile/solr"
req      "GET  /reconcile/anothersolr (template controller)"  "200" "$BASE/reconcile/anothersolr"

# ------------------------------------------------------------------
section "Reconciliation query — Jackson JSON deser + SearchResponse serialization"
# Plain text query: DataSource.querySingle parses string, builds SearchQuery,
# calls upstream VIAF, serializes SearchResponse with @JsonProperty fields.
# Upstream may be unreachable in CI → 200 (results) or 200 (null/empty).
req_body "GET  /reconcile/viaf?query=Shakespeare (text)" "200" '"result"' \
    "$BASE/reconcile/viaf?query=Shakespeare"
# JSON-struct query: Jackson readTree → SearchQuery from JsonNode.
req      "GET  /reconcile/viaf?query={...} (JSON struct)" "200"          \
    "$BASE/reconcile/viaf?query=%7B%22query%22%3A%22Shakespeare%22%2C%22limit%22%3A3%7D"

# ------------------------------------------------------------------
section "ServiceNotImplementedException → 501"
# SuggestAPI / PreviewAPI default methods throw ServiceNotImplementedException;
# @ExceptionHandler on DataSource returns 501.
req "GET  /reconcile/viaf/suggest/entity (→ 501)"  "501"                  "$BASE/reconcile/viaf/suggest/entity"
req "GET  /reconcile/orcid/preview?id=x (→ 501)"   "501"                  "$BASE/reconcile/orcid/preview?id=x"

# ------------------------------------------------------------------
section "Spring 404 for unmapped paths"
req "GET  /bogus-no-such-route"                 "404"                                     "$BASE/bogus-no-such-route"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

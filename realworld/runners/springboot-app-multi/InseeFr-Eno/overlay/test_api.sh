#!/usr/bin/env bash
# Eno (InseeFr) — smoke test.
#
#  Works without external network:
#   - Swagger UI + OpenAPI spec
#   - GET /parameters/java/{ctx}/LUNATIC/{mode}  (pure Java parameters DTO)
#   - POST /questionnaire/{ctx}/lunatic-json/{mode}  (DDI → Lunatic, pure Java)
#   - POST /questionnaire/ddi-2-lunatic-json (custom-params variant)
#
#  NOT work in this environment (deliberately skipped):
#   - GET /parameters/xml/*    — proxies to eno-url.insee.fr (legacy XSLT WS)
#   - POST /questionnaire/{ctx}/xforms, /fo, /fodt   — same upstream
#   - POST /questionnaire/pogues-2-* (uses legacy WS for Pogues→DDI step)
#   - POST /questionnaire/in-2-out (same)
#   These all return 500 "Unknown error during generation: ConnectException"
#   because eno-url.insee.fr (configured via eno.legacy.ws.url) is unreachable. 

set -u

BASE="${BASE:-http://localhost:8080}"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; DIM='\033[2m'; N='\033[0m'
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Copy a small real DDI sample into a no-spaces path so curl multipart works.
DDI_SRC="$(dirname "$0")/eno-ws/src/test/resources/non-regression/ddi-ljps8p2l.xml"
if [[ ! -f "$DDI_SRC" ]]; then
  echo -e "${R}ERROR: DDI sample not found at $DDI_SRC${N}" >&2
  exit 1
fi
DDI="$TMP/ddi.xml"
cp "$DDI_SRC" "$DDI"

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
section "Root + Swagger + OpenAPI"
# HomeController returns 302 to /swagger-ui.html. With curl's default behavior
# (no -L) we observe the 302 directly.
req "GET  /  → 302 (redirect to swagger-ui.html)"        "302" \
    "$BASE/"
# /swagger-ui.html is itself a 302 to /swagger-ui/index.html. We follow once.
req_fields "GET  /swagger-ui/index.html"                 "200" \
'<html
swagger-ui' \
         "$BASE/swagger-ui/index.html"
# /v3/api-docs is the OpenAPI 3.1 spec. Heavy JSON — we sample tag-tagging
# fields the project deliberately puts in the openapi.info.title /
# .description block (see application.properties #springdoc.swagger-ui.* and
# the EnoWsApplication metadata).
req_fields "GET  /v3/api-docs (OpenAPI spec)"            "200" \
'"openapi":"3.1.0"
"info":
"title":"Eno Web Service"
"paths":' \
         "$BASE/v3/api-docs"

# ------------------------------------------------------------------
section "Parameters API (Java DTOs — 3 contexts × LUNATIC × CAPI)"
# /parameters/java/{ctx}/{outFormat}/{mode} returns an EnoParameters DTO with
# all defaults pre-filled per context. Lunatic out-format is the only one
# without a legacy-XSLT detour, so we cover all 3 contexts at LUNATIC×CAPI
# to prove the per-context defaults differ.
req_fields "GET  /parameters/java/DEFAULT/LUNATIC/CAPI"  "200" \
'"context":"DEFAULT"
"modeParameter":"CAPI"
"outFormat":"LUNATIC"
"lunatic":{
"sequenceNumbering":' \
         "$BASE/parameters/java/DEFAULT/LUNATIC/CAPI"
req_fields "GET  /parameters/java/BUSINESS/LUNATIC/CAWI" "200" \
'"context":"BUSINESS"
"modeParameter":"CAWI"
"outFormat":"LUNATIC"
"lunatic":{' \
         "$BASE/parameters/java/BUSINESS/LUNATIC/CAWI"
req_fields "GET  /parameters/java/HOUSEHOLD/LUNATIC/CAPI" "200" \
'"context":"HOUSEHOLD"
"modeParameter":"CAPI"
"outFormat":"LUNATIC"' \
         "$BASE/parameters/java/HOUSEHOLD/LUNATIC/CAPI"

# ------------------------------------------------------------------
section "Real DDI → Lunatic conversion (the project's core business)"
# Uploads a real DDI XML from the project's non-regression suite, asks Eno
# to convert it to a Lunatic JSON questionnaire. Two distinct contexts —
# the same DDI produces different output JSON sizes, proving context-specific
# pipeline rules ran.
#
# Input: ddi-ljps8p2l.xml (21 KB, "QNONREG - TAB DYNAMIQUES" — a dynamic-tab
# regression test fixture).
req_fields "POST /questionnaire/DEFAULT/lunatic-json/CAPI (DDI → Lunatic)" "200" \
'"id":"ljps8p2l"
"componentType":"Questionnaire"
"enoCoreVersion":"3.62.0"
"lunaticModelVersion":"5.12.0"
"label":
"components":[' \
         -X POST -F "in=@${DDI}" \
         "$BASE/questionnaire/DEFAULT/lunatic-json/CAPI"
req_fields "POST /questionnaire/BUSINESS/lunatic-json/CAPI (different ctx)" "200" \
'"id":"ljps8p2l"
"componentType":"Questionnaire"
"enoCoreVersion":"3.62.0"
"label":' \
         -X POST -F "in=@${DDI}" \
         "$BASE/questionnaire/BUSINESS/lunatic-json/CAPI"

# Custom-params variant: caller supplies their own parameters JSON instead of
# letting the controller build it from {ctx}/{mode} path vars. We round-trip
# the parameters DTO from /parameters/java first.
PARAMS="$TMP/params.json"
curl -sS -o "$PARAMS" "$BASE/parameters/java/DEFAULT/LUNATIC/CAPI"
req_fields "POST /questionnaire/ddi-2-lunatic-json (custom params)" "200" \
'"id":"ljps8p2l"
"componentType":"Questionnaire"
"enoCoreVersion":' \
         -X POST -F "in=@${DDI}" -F "params=@${PARAMS}" \
         "$BASE/questionnaire/ddi-2-lunatic-json"

# ------------------------------------------------------------------
section "Exception handling (EnoExceptionController — distinct handler paths)"
# ModeParameterException handler: PAPI mode is incompatible with Lunatic format.
# Controller checks mode==PAPI → throws ModeParameterException → 400.
req_fields "POST /questionnaire/DEFAULT/lunatic-json/PAPI (→ 400)" "400" \
'"Collection mode error:
Lunatic format is not compatible with the mode' \
         -X POST -F "in=@${DDI}" \
         "$BASE/questionnaire/DEFAULT/lunatic-json/PAPI"
# Bad enum path var: BOGUS is not a valid Context enum value.
# Spring's ConversionFailedException → catch-all @ExceptionHandler(Exception.class) → 500,
# or MethodArgumentTypeMismatchException → 400.
req "POST /questionnaire/BOGUS/lunatic-json/CAPI (bad enum → 400|500)" "400|500" \
    -X POST -F "in=@${DDI}" \
    "$BASE/questionnaire/BOGUS/lunatic-json/CAPI"

# ------------------------------------------------------------------
section "Pogues → Lunatic conversion (direct path, bypasses legacy WS)"
# Pogues is the upstream questionnaire-design format. Default flow is
# Pogues→DDI(legacy XSLT WS)→Lunatic(Java) — fails without internal network.
# With ENO_DIRECT_POGUES_LUNATIC=true (set in compose.yaml) the project
# uses the pure-Java direct path PoguesToLunatic#fromInputStream → no legacy
# WS call. See PoguesToLunaticService.java#27.
POGUES_SRC="$(dirname "$0")/eno-core/src/test/resources/integration/pogues/pogues-controls.json"
if [[ -f "$POGUES_SRC" ]]; then
  POGUES="$TMP/pogues.json"
  cp "$POGUES_SRC" "$POGUES"
  # Standard variant: {ctx}/{mode} in path.
  req_fields "POST /questionnaire/pogues-2-lunatic/DEFAULT/CAPI"  "200" \
'"id":"ltx6821m"
"componentType":"Questionnaire"
"enoCoreVersion":"3.62.0"
"label":' \
           -X POST -F "in=@${POGUES}" \
           "$BASE/questionnaire/pogues-2-lunatic/DEFAULT/CAPI"
  # Custom-params variant: caller supplies the parameters file.
  req_fields "POST /questionnaire/pogues-2-lunatic (custom params)"  "200" \
'"id":"ltx6821m"
"componentType":"Questionnaire"
"enoCoreVersion":"3.62.0"' \
           -X POST -F "in=@${POGUES}" -F "params=@${PARAMS}" \
           "$BASE/questionnaire/pogues-2-lunatic"
else
  echo -e "${Y}SKIP: pogues sample not found at $POGUES_SRC${N}"
fi

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

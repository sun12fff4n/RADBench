#!/usr/bin/env bash
# family-tree-xml-parser — smoke test.

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

# $1 label, $2 expected status regex, $3 newline-separated substring list,
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

# Reusable XML payloads (README's tree example shape).
read -r -d '' VALID_XML <<'XML'
<entries>
  <entry>Adam</entry>
  <entry parentName="Adam">Stjepan</entry>
  <entry parentName="Stjepan">Luka</entry>
  <entry parentName="Adam">Leopold</entry>
</entries>
XML
read -r -d '' TWO_ROOTS_XML <<'XML'
<entries>
  <entry>Adam</entry>
  <entry>Eve</entry>
</entries>
XML
read -r -d '' NO_ROOT_XML <<'XML'
<entries>
  <entry parentName="Adam">Stjepan</entry>
  <entry parentName="Stjepan">Luka</entry>
</entries>
XML

# ------------------------------------------------------------------
section "Project-defined states (controller + ErrorHandler)"
# Happy path: valid 4-node tree → 201 + canned message.
req_fields "POST /documents valid XML → 201"             "201" \
'"message":"Document inserted successfully"' \
         -X POST -H "Content-Type: application/xml" -d "$VALID_XML" \
         "$BASE/documents"

# MoreThanOneRoot: 2 entries with no parentName → service throws → 400.
req_fields "POST /documents two roots → 400 MoreThanOneRoot" "400" \
'"message":"Only one root entry is allowed"' \
         -X POST -H "Content-Type: application/xml" -d "$TWO_ROOTS_XML" \
         "$BASE/documents"

# RootIsMissing: every entry has a parentName → no root → 400.
req_fields "POST /documents no root → 400 RootIsMissing"   "400" \
'"message":"Root entry is missing"' \
         -X POST -H "Content-Type: application/xml" -d "$NO_ROOT_XML" \
         "$BASE/documents"

# ------------------------------------------------------------------
section "Content negotiation + error handling"
# 415 Unsupported Media Type — controller only consumes application/xml.
# Sending JSON triggers Spring MVC's HttpMediaTypeNotSupportedException.
req "POST /documents JSON body → 415 UnsupportedMediaType"  "415" \
    -X POST -H "Content-Type: application/json" \
    -d '{"entry":"Adam"}' "$BASE/documents"

# 405 Method Not Allowed — GET on POST-only endpoint.
req "GET  /documents (wrong method → 405)"                  "405" \
    "$BASE/documents"

# Malformed XML — triggers Spring's HttpMessageNotReadableException
# (JAXB/Jackson XML unmarshalling failure).
req "POST /documents malformed XML → 400"                   "400" \
    -X POST -H "Content-Type: application/xml" \
    -d '<not-valid-xml' "$BASE/documents"

# Empty entries — no <entry> children. Exercises JAXB deserialization
# with empty collection, then RootIsMissing validation.
req_fields "POST /documents empty entries → 400"            "400" \
'"message":' \
    -X POST -H "Content-Type: application/xml" \
    -d '<entries></entries>' "$BASE/documents"

# ------------------------------------------------------------------
section "H2 console + infrastructure"
# H2 web console is enabled (spring.h2.console.enabled=true).
# Accessing it exercises H2's reflection-based servlet registration.
req "GET  /h2-console (H2 web console)"                     "200" \
    "$BASE/h2-console"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

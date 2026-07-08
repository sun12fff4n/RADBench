#!/usr/bin/env bash
# gitlab-panorama — smoke test.

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
section "Root + actuator"
# RootResource serves index.txt by default and index.html when the client
# sends Accept: text/html. Both render a directory of available adapters.
req_fields "GET  /                              (text default)"  "200" \
'GitLab panorama
Adapter
api/adapter/ccmenu
api/adapter/prometheus' \
         "$BASE/"
req_fields "GET  /                              (Accept text/html)"  "200" \
'<!DOCTYPE html>
<title>GitLab panorama</title>
api/adapter/shell
api/adapter/json' \
         -H 'Accept: text/html' "$BASE/"
# Health probe. management.endpoints.enabled-by-default=false in
# application.properties, so only /health is exposed; show-details=never
# means body is just status + groups (no per-component details).
req_fields "GET  /actuator/health"                                "200" \
'"status":"UP"
"groups":["liveness","readiness"]' \
         "$BASE/actuator/health"

# ------------------------------------------------------------------
section "Adapter endpoints — empty in-memory state in 5 formats"
# CcmenuResource produces=application/xml. Empty state → root <Projects></Projects>.
req_fields "GET  /api/adapter/ccmenu (XML)"                       "200" \
'<Projects>
</Projects>' \
         "$BASE/api/adapter/ccmenu"
# JsonResource produces=application/json. Empty state → empty JSON array.
req_fields "GET  /api/adapter/json (JSON empty array)"            "200" \
'[' \
         "$BASE/api/adapter/json"
# HtmlResource produces=text/html (Vue SPA template). Doesn't depend on the
# pipeline state — the template is always served, JS fetches data later.
req_fields "GET  /api/adapter/html (SPA template)"                "200" \
'<!DOCTYPE html>
<title>GitLab panorama</title>
<body>' \
         "$BASE/api/adapter/html"
# Shell + Prometheus return blank bodies on empty state, so we can't grep
# for fields — only assert status.
req "GET  /api/adapter/shell (text/plain blank for empty state)"  "200" \
    "$BASE/api/adapter/shell"
req "GET  /api/adapter/prometheus (text/plain blank for empty state)" "200" \
    "$BASE/api/adapter/prometheus"

# ------------------------------------------------------------------
section "Mutating endpoints — refresh + webhook"
# /api/state/refresh: spawns an async refresh thread + returns "done"
# synchronously. With dummy GITLAB_TOKEN the spawned thread will fail to
# reach gitlab.com — but the controller returns the literal "done" before
# that, so this test passes regardless.
req_fields "GET  /api/state/refresh"                              "200" \
'done' \
         "$BASE/api/state/refresh"
# /webhook/test: WebhookResource — proves the receiver wiring works. With
# WEBHOOK_SECRET_TOKEN unset in compose, getSecretToken()=null; sending NO
# X-Gitlab-Token header passes the StringUtils.equals(null,null)=true check.
# X-Gitlab-Event header is required by Spring (otherwise 400).
req_fields "POST /webhook/test (headers + body → 'accepted')"     "200" \
'accepted' \
         -X POST -H 'X-Gitlab-Event: Pipeline Hook' \
         -H 'Content-Type: application/json' \
         -d '{"object_kind":"pipeline"}' \
         "$BASE/webhook/test"
# /webhook (real one) accepts WebhookEvent polymorphic JSON. The "object_kind"
# field selects the subtype (push / pipeline / merge_request) via
# @JsonTypeInfo. Returns 201 Created (declared via @ResponseStatus on the
# controller method, with no body). Two subtypes proved:
req "POST /webhook (push event → 201)"                            "201" \
    -X POST -H 'X-Gitlab-Event: Push Hook' \
    -H 'Content-Type: application/json' \
    -d '{"object_kind":"push"}' \
    "$BASE/webhook"
req "POST /webhook (pipeline event → 201)"                        "201" \
    -X POST -H 'X-Gitlab-Event: Pipeline Hook' \
    -H 'Content-Type: application/json' \
    -d '{"object_kind":"pipeline"}' \
    "$BASE/webhook"

# ------------------------------------------------------------------
section "Webhook — richer payloads (Jackson @JsonProperty + InstantDeserializer + Status enum)"
# Push event with full fields exercises @JsonProperty("event_name"),
# @JsonProperty("project") nested object deserialization, plus the
# isBranchRemoved() branch-delete check (after=SHA_DELETE).
req "POST /webhook (push event with nested project)"              "201" \
    -X POST -H 'X-Gitlab-Event: Push Hook' \
    -H 'Content-Type: application/json' \
    -d '{"object_kind":"push","event_name":"push","after":"abc123","ref":"refs/heads/main","project":{"id":1,"name":"test-proj","path_with_namespace":"group/test-proj"}}' \
    "$BASE/webhook"

# Pipeline event with object_attributes exercises:
#   1. @JsonProperty("object_attributes") → GitlabPipelineComplete deserialization
#   2. Status enum deserialization (status:"success")
#   3. Custom InstantDeserializer for created_at/updated_at (Instant fields)
req "POST /webhook (pipeline with attributes+timestamps)"         "201" \
    -X POST -H 'X-Gitlab-Event: Pipeline Hook' \
    -H 'Content-Type: application/json' \
    -d '{"object_kind":"pipeline","object_attributes":{"id":123,"ref":"main","status":"success","created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:05:00Z"},"project":{"id":1,"name":"test-proj"}}' \
    "$BASE/webhook"

# Push event simulating branch deletion (after=all-zeros SHA).
req "POST /webhook (push branch-delete SHA)"                      "201" \
    -X POST -H 'X-Gitlab-Event: Push Hook' \
    -H 'Content-Type: application/json' \
    -d '{"object_kind":"push","event_name":"push","after":"0000000000000000000000000000000000000000","ref":"refs/heads/feature-x","project":{"id":2,"name":"proj2"}}' \
    "$BASE/webhook"

# ------------------------------------------------------------------
section "Error handling — token rejection + unknown subtype + method not allowed"
# Wrong webhook secret token → ResponseStatusException(FORBIDDEN) → 403.
req "POST /webhook (wrong token → 403)"                           "403" \
    -X POST -H 'X-Gitlab-Event: Push Hook' \
    -H 'X-Gitlab-Token: wrong-secret' \
    -H 'Content-Type: application/json' \
    -d '{"object_kind":"push"}' \
    "$BASE/webhook"

# Unknown object_kind: @JsonTypeInfo cannot resolve subtype → Jackson error.
req "POST /webhook (unknown object_kind → 400)"                   "400|500" \
    -X POST -H 'X-Gitlab-Event: Unknown Hook' \
    -H 'Content-Type: application/json' \
    -d '{"object_kind":"unknown_event"}' \
    "$BASE/webhook"

# 405 — GET on webhook endpoint (only POST/RequestMapping).
req "GET  /webhook (wrong method → 405)"                          "405" \
    "$BASE/webhook"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

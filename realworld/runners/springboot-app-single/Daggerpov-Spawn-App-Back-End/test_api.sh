#!/usr/bin/env bash
# spawn-app — smoke test (test profile, MySQL backend).
set -u

BASE="${BASE:-http://localhost:8080}"
API="${BASE}/api/v1"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; DIM='\033[2m'; N='\033[0m'
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run a request, assert HTTP status matches `$expected` (regex).
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

# Status check + ALL key-field substrings present in body.
# $1 label, $2 expected status regex, $3 newline-separated substring list,
# then curl args. One PASS line if every substring is found.
# If any miss, lists exactly which substrings are missing.
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

# Run a request, assert status AND that the body contains a fixed substring.
# Used to confirm the response is real business data, not a stub/empty 200.
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

# Auth-injection helpers — see file header. Secret MUST match SIGNING_SECRET
# in docker-compose.yml's app.environment block.
SIGNING_SECRET_B64="${SIGNING_SECRET_B64:-U3Bhd25UZXN0U2VjcmV0S2V5MDEyMzQ1Njc4OWFiY2Q=}"
INJECT_USERNAME="${INJECT_USERNAME:-testuser_inj}"
DB_CONTAINER="${DB_CONTAINER:-spawn-mysql}"
SKIP_INJECT="${SKIP_INJECT:-0}"
INJECT_ACTIVITY_UUID="aaaabbbb-cccc-dddd-eeee-ffff00001111"
INJECT_LOCATION_UUID="11112222-3333-4444-5555-666677778888"

# Insert (idempotently) a status=ACTIVE user. UserStatus.ACTIVE ordinal = 4.
# Echoes the user UUID on stdout. Empty on failure.
inject_user() {
  docker exec -i "$DB_CONTAINER" mysql -uroot -pbenchmark spawn 2>/dev/null <<SQL >/dev/null
    INSERT IGNORE INTO user
      (id, username, email, password, status, has_completed_onboarding, date_created, last_updated, name)
    VALUES
      (UUID_TO_BIN(UUID()), '${INJECT_USERNAME}', '${INJECT_USERNAME}@spawn.test',
       '{noop}irrelevant', 4, 1, NOW(), NOW(), 'Injected Test User');
SQL
  docker exec -i "$DB_CONTAINER" mysql -uroot -pbenchmark spawn -N \
    -e "SELECT BIN_TO_UUID(id) FROM user WHERE username='${INJECT_USERNAME}';" 2>/dev/null \
    | tr -d '[:space:]'
}

# Insert (idempotently) a Location + Activity owned by the injected user.
# Lets the regex-permitAll route GET /activities/{uuid} return real data.
inject_activity() {
  local creator_id="$1"
  docker exec -i "$DB_CONTAINER" mysql -uroot -pbenchmark spawn 2>/dev/null <<SQL >/dev/null
    INSERT IGNORE INTO location (id, latitude, longitude, name)
      VALUES (UUID_TO_BIN('${INJECT_LOCATION_UUID}'), 49.28, -123.12, 'Test Loc');
    INSERT IGNORE INTO activity
      (id, title, creator_id, location_id, created_at, last_updated, start_time, end_time)
    VALUES
      (UUID_TO_BIN('${INJECT_ACTIVITY_UUID}'), 'Injected Test Activity',
       UUID_TO_BIN('${creator_id}'),
       UUID_TO_BIN('${INJECT_LOCATION_UUID}'),
       NOW(6), NOW(6), NOW(6), DATE_ADD(NOW(6), INTERVAL 1 HOUR));
SQL
}

# Forge an HS256 JWT — sub=$1, type=$2 (default ACCESS), exp=now+1h.
# Echoes token. type=REFRESH is accepted by JWTService#refreshAccessToken;
# type=ACCESS is accepted by JWTAuthenticationTokenFilter for /api/v1/**.
forge_jwt() {
  local username="$1" ttype="${2:-ACCESS}"
  python3 - "$username" "$SIGNING_SECRET_B64" "$ttype" <<'PY'
import sys, hmac, hashlib, base64, json, time
username, secret_b64, ttype = sys.argv[1], sys.argv[2], sys.argv[3]
secret = base64.b64decode(secret_b64)
b64u = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
hdr = b64u(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(',',':')).encode())
pld = b64u(json.dumps({"sub":username, "type":ttype,
                       "iat":int(time.time()), "exp":int(time.time())+3600},
                      separators=(',',':')).encode())
data = hdr + b"." + pld
sig  = b64u(hmac.new(secret, data, hashlib.sha256).digest())
print((data + b"." + sig).decode())
PY
}

# ------------------------------------------------------------------
section "Setup: inject ACTIVE user + activity, forge JWT"

if [[ "$SKIP_INJECT" == "1" ]]; then
  echo -e "${R}SKIP_INJECT=1 set — cannot run authenticated tests${N}"; exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo -e "${R}ERROR: python3 required for JWT signing${N}"; exit 1
fi
if ! docker exec "$DB_CONTAINER" true 2>/dev/null; then
  echo -e "${R}ERROR: cannot reach $DB_CONTAINER${N}"; exit 1
fi

USER_ID="$(inject_user)"
[[ -z "$USER_ID" ]] && { echo -e "${R}ERROR: failed to insert user${N}"; exit 1; }
inject_activity "$USER_ID"
TOKEN="$(forge_jwt "$INJECT_USERNAME")"
AUTH=(-H "Authorization: Bearer ${TOKEN}")

echo -e "${DIM}user_id=${USER_ID}${N}"
echo -e "${DIM}activity_id=${INJECT_ACTIVITY_UUID}${N}"
echo -e "${DIM}token=${TOKEN:0:32}...${N}"

# ------------------------------------------------------------------
section "Auth — token-pipeline endpoints"
# quick-sign-in: ACCESS token validated by JWTAuthenticationTokenFilter →
# user resolved from DB → AuthResponseDTO {user{id,username,...}, status, isOAuthUser}.
req_fields "GET  /auth/quick-sign-in"                    "200" \
'"user":{
"id":"
"username":"
"status":"ACTIVE"
"isOAuthUser":' \
         "${AUTH[@]}" "$API/auth/quick-sign-in"
# refresh-token: forge a REFRESH-typed JWT (same secret), POST it as Bearer
# → JWTService#refreshAccessToken validates type=REFRESH + subject exists →
# echoes a fresh ACCESS token. The body itself is the new token (a JWT prefix).
REFRESH_TOKEN="$(forge_jwt "$INJECT_USERNAME" REFRESH)"
req_body "POST /auth/refresh-token (forged REFRESH JWT)" "200" "eyJ" \
         -X POST -H "Authorization: Bearer ${REFRESH_TOKEN}" \
         "$API/auth/refresh-token"

# ------------------------------------------------------------------
section "Users — core profile surfaces"
# BaseUserDTO: id, name, email, username, bio, profilePicture, hasCompletedOnboarding.
req_fields "GET  /users/{self} (BaseUserDTO key fields)" "200" \
'"id":"
"username":"
"name":"
"email":"
"hasCompletedOnboarding":' \
         "${AUTH[@]}" "$API/users/${USER_ID}"
# UserProfileInfoDTO: userId, name, username, bio, profilePicture, dateCreated.
req_fields "GET  /users/{self}/profile-info"             "200" \
'"userId":"
"username":"
"name":"
"dateCreated":"' \
         "${AUTH[@]}" "$API/users/${USER_ID}/profile-info"
# UserStatsDTO: peopleMet, spawnsMade, spawnsJoined.
req_fields "GET  /users/{self}/stats"                    "200" \
'"peopleMet":
"spawnsMade":
"spawnsJoined":' \
         "${AUTH[@]}" "$API/users/${USER_ID}/stats"
req_body "GET  /users/{self}/interests (empty list)"     "200" '[]' \
         "${AUTH[@]}" "$API/users/${USER_ID}/interests"
# UserSocialMediaDTO: id, userId, whatsappLink, instagramLink (default-row fields).
req_fields "GET  /users/{self}/social-media"             "200" \
'"id":"
"userId":"
"whatsappLink":
"instagramLink":' \
         "${AUTH[@]}" "$API/users/${USER_ID}/social-media"
req_body "GET  /users/{self}/activity-types"             "200" "[" \
         "${AUTH[@]}" "$API/users/${USER_ID}/activity-types"
req_body "GET  /users/friends/{self} (empty)"            "200" '[]' \
         "${AUTH[@]}" "$API/users/friends/${USER_ID}"
req_body "GET  /users/recommended-friends/{self}"        "200" "[" \
         "${AUTH[@]}" "$API/users/recommended-friends/${USER_ID}"
req_body "GET  /users/{self}/recent-users"               "200" "[" \
         "${AUTH[@]}" "$API/users/${USER_ID}/recent-users"
req_body "GET  /users/search?query=test"                 "200" "[" \
         "${AUTH[@]}" "$API/users/search?query=test"

# ------------------------------------------------------------------
section "Activities — real injected activity + feed"
req_body "GET  /activities/feedActivities/{self}"        "200" "[" \
         "${AUTH[@]}" "$API/activities/feedActivities/${USER_ID}"
req_body "GET  /activities/profile/{self}"               "200" "[" \
         "${AUTH[@]}" "$API/activities/profile/${USER_ID}?requestingUserId=${USER_ID}"
# Regex-permitAll route — external invite share-link doesn't even need a token.
# Activity invite DTO: id, title, creatorUserId, startTime, endTime, participantUserIds[], invitedUserIds[].
req_fields "GET  /activities/{real-uuid}?isActivityExternalInvite=true (no token)" "200" \
'"id":"
"title":"
"creatorUserId":"
"startTime":"
"participantUserIds":[
"invitedUserIds":[' \
         "$API/activities/${INJECT_ACTIVITY_UUID}?isActivityExternalInvite=true"

# ------------------------------------------------------------------
section "Notifications + friend-requests + blocked-users"
# NotificationPreferencesDTO: 4 enable flags + userId.
req_fields "GET  /notifications/preferences/{self}"      "200" \
'"friendRequestsEnabled":
"chatMessagesEnabled":
"activityInvitesEnabled":
"activityUpdatesEnabled":
"userId":"' \
         "${AUTH[@]}" "$API/notifications/preferences/${USER_ID}"
req_body "GET  /friend-requests/incoming/{self}"         "200" "[" \
         "${AUTH[@]}" "$API/friend-requests/incoming/${USER_ID}"
req_body "GET  /friend-requests/sent/{self}"             "200" "[" \
         "${AUTH[@]}" "$API/friend-requests/sent/${USER_ID}"
req_body "GET  /blocked-users/{self}"                    "200" "[" \
         "${AUTH[@]}" "$API/blocked-users/${USER_ID}"

# ------------------------------------------------------------------
section "Bean Validation — @Valid on AuthUserDTO (Hibernate Validator reflection)"
# POST /auth/register with @Valid @RequestBody AuthUserDTO.
# AuthUserDTO inherits @Email, @ValidName, @ValidUsername from AbstractUserDTO,
# and adds @NotBlank + @Size(min=8) on password.
# Missing required fields → MethodArgumentNotValidException →
# GlobalExceptionHandler → VALIDATION_ERROR envelope.
req_fields "POST /auth/register (empty body → validation error)"   "400" \
'"error":true
"errorCode":"VALIDATION_ERROR"
"status":400
"errorId":"' \
         -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{}' "$API/auth/register"

# Password too short → @Size(min=8) violation.
req_fields "POST /auth/register (short password → validation)"    "400" \
'"error":true
"errorCode":"VALIDATION_ERROR"
"message":"' \
         -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{"username":"val_test","email":"val@test.com","password":"short","name":"Val Test"}' \
         "$API/auth/register"

# Invalid email → @Email violation.
req_fields "POST /auth/register (bad email → validation)"         "400" \
'"error":true
"errorCode":"VALIDATION_ERROR"' \
         -X POST -H "Content-Type: application/json" "${AUTH[@]}" \
         -d '{"username":"val_test2","email":"not-an-email","password":"longpassword123","name":"Val Test"}' \
         "$API/auth/register"

# ------------------------------------------------------------------
section "Exception handling — GlobalExceptionHandler error envelope"
# BaseNotFoundException → RESOURCE_NOT_FOUND envelope.
# Request a non-existent user UUID.
req_fields "GET  /users/{fake-uuid} (404 → RESOURCE_NOT_FOUND)"  "404" \
'"error":true
"errorCode":"RESOURCE_NOT_FOUND"
"status":404
"timestamp":"
"errorId":"' \
         "${AUTH[@]}" "$API/users/00000000-0000-0000-0000-000000000000"

# Also verify stats endpoint for a non-existent user.
req_fields "GET  /users/{fake-uuid}/stats (404 → error envelope)" "404" \
'"error":true
"errorCode":"RESOURCE_NOT_FOUND"' \
         "${AUTH[@]}" "$API/users/00000000-0000-0000-0000-000000000000/stats"

# ------------------------------------------------------------------
section "Auth-gate sanity — keep just one denial check"
# Confirms the JWT filter is actually running. Without this we wouldn't know
# the 200s above mean "auth passed" vs "auth disabled by mistake".
req "GET  /users/{self} (no Authorization header → 401)" "401" \
    -H "Accept: application/json" "$API/users/${USER_ID}"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

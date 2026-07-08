#!/usr/bin/env bash
# ymanvieu-trading — smoke test

set -u
BASE="${BASE:-http://localhost:8080}"

pass=0; fail=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" =~ ^($expected)$ ]]; then
        printf "  ok   %-65s -> %s\n" "$name" "$actual"
        pass=$((pass+1))
    else
        printf "  FAIL %-65s -> got %s, want %s\n" "$name" "$actual" "$expected"
        fail=$((fail+1))
    fi
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

echo "==> Wait for boot"
for _ in $(seq 1 60); do
    s=$(code "$BASE/api/rate/latest" || echo 000)
    [[ "$s" == "200" ]] && break
    sleep 2
done
echo "    /api/rate/latest=$s"
[[ "$s" != "200" ]] && { echo "boot failed"; exit 1; }

# --- Acquire admin + user JWTs (login endpoints exercise /api/auth) ---
ADMIN_JWT=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"password"}' "$BASE/api/auth" \
    | sed 's/.*accessToken":"\([^"]*\).*/\1/')
USER_JWT=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"username":"user","password":"password"}' "$BASE/api/auth" \
    | sed 's/.*accessToken":"\([^"]*\).*/\1/')

echo
echo "==> Public happy paths (200, permitAll)"
check "GET /api/rate/latest"                             "200" "$(code "$BASE/api/rate/latest")"
check "GET /api/rate/latest?fromcur=EUR&tocur=USD"       "200" "$(code "$BASE/api/rate/latest?fromcur=EUR&tocur=USD")"
# /api/auth login success, distinct from /api/auth bad-cred 400 below.
check "POST /api/auth (admin/password)"                  "200" \
    "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"admin","password":"password"}' "$BASE/api/auth")"

echo
echo "==> Authenticated happy paths (Bearer JWT, user role)"
check "GET /api/portofolio (user JWT)"                   "200" \
    "$(code -H "Authorization: Bearer $USER_JWT" "$BASE/api/portofolio")"
check "GET /api/portofolio/available-symbols (user)"     "200" \
    "$(code -H "Authorization: Bearer $USER_JWT" "$BASE/api/portofolio/available-symbols")"
# Note: admin endpoints (/api/admin search/add) call Yahoo Finance directly.
# Yahoo rate-limits anonymous traffic to 429 -> uncaught -> Spring 500. That
# 500 is *upstream-environment* noise, not a project-defined state, so the
# admin happy path is intentionally NOT asserted here. With a Yahoo wiremock
# stub the search would 200, but that's a separate harness concern.

echo
echo "==> Project-defined error envelopes (ExceptionRestHandler advice)"
# 400: BadCredentialsException -> ResponseDTO. Note the project chose 400, not
# 401 -- this is the project-defined mapping.
check "POST /api/auth wrong creds (BadCredentials -> 400)"  "400" \
    "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"admin","password":"wrong"}' "$BASE/api/auth")"
# 409: UserAlreadyExistsException. Two signups with same login -- second one
# trips the unique-key + custom advice branch.
SIGNUP_BODY='{"login":"sigtest_unique_'$RANDOM'","password":"longenough1"}'
check "POST /api/signup (1st time)"                      "200" \
    "$(code -X POST -H 'Content-Type: application/json' -d "$SIGNUP_BODY" "$BASE/api/signup")"
# 2nd time same login -> UserAlreadyExistsException -> 409 envelope.
SAME_LOGIN_BODY='{"login":"admin","password":"longenough1"}'
check "POST /api/signup (login=admin already exists)"    "409" \
    "$(code -X POST -H 'Content-Type: application/json' -d "$SAME_LOGIN_BODY" "$BASE/api/signup")"
# 401: JwtException -> handleExpiredJwtException advice branch.
check "POST /api/refresh (malformed token -> JwtException 401)" "401" \
    "$(code -X POST -H 'Content-Type: application/json' -d '{"refreshToken":"bad.bad.bad"}' "$BASE/api/refresh")"

echo
echo "==> Bean Validation (@Size on SignupForm, @NotEmpty on AuthenticationRequest)"
# SignupForm has @Size(min=3) on login, @Size(min=8) on password.
# Short login → MethodArgumentNotValidException → 400.
check "POST /api/signup (login too short → 400)"          "400" \
    "$(code -X POST -H 'Content-Type: application/json' -d '{"login":"ab","password":"longenough1"}' "$BASE/api/signup")"
# AuthenticationRequest has @NotEmpty on username/password.
# Empty body → MethodArgumentNotValidException → 400.
check "POST /api/auth (empty body → 400)"                 "400" \
    "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/auth")"

echo
echo "==> OAuth2 social login full flow (GitHub provider, mocked via wiremock)"
# Drives: /api/oauth2/authorization/github -> wiremock /login/oauth/authorize ->
# project callback /api/login/oauth2/code/github -> wiremock token + userinfo
# fetch -> customOAuth2UserService -> oAuth2AuthenticationSuccessHandler issues
# project JWT in the final redirect URL.
# Curl runs inside the app container so the wiremock hostname resolves.
OAUTH_OUT=$(docker exec ymanvieu-trading-app bash -c '
  J=$(mktemp); rm -f "$J"
  curl -s -c "$J" -b "$J" -L -o /dev/null \
    -w "redirects=%{num_redirects} final_url=%{url_effective}\n" \
    "http://localhost:8080/api/oauth2/authorization/github"
' 2>&1)
# Expected: 3 redirects, final URL has accessToken= (the project JWT issued
# by the OAuth2 success handler).
if echo "$OAUTH_OUT" | grep -q 'redirects=3' && echo "$OAUTH_OUT" | grep -q 'accessToken='; then
    OAUTH_RESULT="200"
else
    OAUTH_RESULT="FAIL ($OAUTH_OUT)"
fi
check "GET /api/oauth2/authorization/github (full OAuth2 dance)" "200" "$OAUTH_RESULT"
# Now extract the JWT from the OAuth2-success redirect and use it to hit a
# protected endpoint -- proves the social-login JWT actually authenticates.
OAUTH_JWT=$(echo "$OAUTH_OUT" | sed -n 's/.*accessToken=\([^&]*\).*/\1/p')
check "GET /api/portofolio (OAuth2-issued JWT)"           "200" \
    "$(code -H "Authorization: Bearer $OAUTH_JWT" "$BASE/api/portofolio")"

echo
echo "==> Order placement (drives JPA writes + JMS infra fully wired)"
# A successful UBI buy: user has 100k EUR base, UBI is EUR-priced (~27.86 EUR),
# 10 shares = ~278.60 EUR. Confirms portfolio update + JPA insert into orders.
# More importantly: this endpoint succeeding *at all* proves the entire
# spring-boot-starter-artemis chain is wired -- without a working
# JmsTemplate bean (which requires ConnectionFactory -> reachable Artemis
# broker -> the artemis-jakarta-client jar on classpath) the data-collect
# RatesUpdatedEventListener bean creation fails and the context never refreshes.
check "POST /api/portofolio/order BUY UBI x10 (success path)"  "200" \
    "$(code -X POST -H "Authorization: Bearer $USER_JWT" -H 'Content-Type: application/json' \
        -d '{"type":"BUY","code":"UBI","quantity":10}' "$BASE/api/portofolio/order")"
# Project's BusinessException advice branch: 'order.error.not_enough_fund'.
# user has 0 USD assets -> can't buy BTC (USD-priced) -> 400 envelope.
check "POST /api/portofolio/order BUY BTC (not_enough_fund 400)"  "400" \
    "$(code -X POST -H "Authorization: Bearer $USER_JWT" -H 'Content-Type: application/json' \
        -d '{"type":"BUY","code":"BTC","quantity":1}' "$BASE/api/portofolio/order")"

echo
echo "==> Additional handler coverage (project 200 paths only)"
# RateController missing handler: history. Same controller as latest-by-pair
# but separate code path (range query against RATES table).
check "GET /api/rate/history?fromcur=GFT&tocur=EUR"        "200" \
    "$(code "$BASE/api/rate/history?fromcur=GFT&tocur=EUR")"
# SymbolController POST /favorite + DELETE chain. Each Map<String,String>
# body field name was discovered empirically: fromSymbolCode + toSymbolCode.
# DELETE is idempotent (no 404 even when the row's gone) -- a project quirk.
FAV_BODY='{"fromSymbolCode":"UBI","toSymbolCode":"EUR"}'
check "POST /api/symbol/favorite (user JWT, add UBI/EUR)"  "200" \
    "$(code -X POST -H "Authorization: Bearer $USER_JWT" -H 'Content-Type: application/json' \
        -d "$FAV_BODY" "$BASE/api/symbol/favorite")"
check "DELETE /api/symbol/favorite/UBI/EUR (user JWT)"     "200" \
    "$(code -X DELETE -H "Authorization: Bearer $USER_JWT" "$BASE/api/symbol/favorite/UBI/EUR")"

# Note: Spring Security's framework defaults (anon -> 401 envelope, wrong-
# role -> 403 envelope) and Yahoo's upstream 429 (-> Spring 500) are
# intentionally NOT tested here -- they aren't states the project itself
# defines, and asserting them would couple the benchmark to framework /
# external-service behavior that drifts.

echo
echo "==> Summary: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

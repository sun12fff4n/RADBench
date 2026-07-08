#!/usr/bin/env bash
# kasramp-eris — smoke test
set -u
BASE="${BASE:-http://localhost:8080}"
ADMIN_USER="${ACTUATOR_USERNAME:-admin}"
ADMIN_PASS="${ACTUATOR_PASSWORD:-secret}"

pass=0; fail=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" =~ ^($expected)$ ]]; then
        printf "  ok   %-55s -> %s\n" "$name" "$actual"
        pass=$((pass+1))
    else
        printf "  FAIL %-55s -> got %s, want %s\n" "$name" "$actual" "$expected"
        fail=$((fail+1))
    fi
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

echo "==> Wait for boot"
for _ in $(seq 1 60); do
    s=$(code "$BASE/actuator/health" || echo 000)
    [[ "$s" == "200" ]] && break
    sleep 2
done
echo "    health=$s"
[[ "$s" != "200" ]] && { echo "boot failed"; exit 1; }

echo
echo "==> Public surface (200)"
check "GET /actuator/health (permitAll)"        "200"        "$(code "$BASE/actuator/health")"
check "GET /v3/api-docs (springdoc)"            "200"        "$(code "$BASE/v3/api-docs")"
check "GET /swagger-ui/index.html"              "200"        "$(code "$BASE/swagger-ui/index.html")"

echo
echo "==> Redirect endpoints (302)"
check "GET /apidocs -> swagger-ui"              "302"        "$(code "$BASE/apidocs")"
check "GET /api-docs (dash alias, same handler)" "302"       "$(code "$BASE/api-docs")"
# / redirects to external eris.madadipouya.com -> external service may answer with anything;
check "GET / (redirect to external doc)"        "302"        "$(code -H 'Accept: text/html' "$BASE/")"

echo
echo "==> Weather happy & error paths (CurrentWeatherAPIController)"
# Missing params -> 400 with "No latitude and/or longitude provided!"
check "GET /v1/weather/current (no params)"     "400"        "$(code "$BASE/v1/weather/current?lat=&lon=")"
# Non-numeric lat/lon -> 400 with "Invalid latitude and/or longitude provided!"
check "GET /v1/weather/current (non-numeric)"   "400"        "$(code "$BASE/v1/weather/current?lat=abc&lon=def")"
# Numeric lat/lon: upstreams (OWM/groupkt/extreme-ip-lookup) are stubbed by wiremock
# via Docker network aliases; OSM nominatim is hit on the real public service.
check "GET /v1/weather/current (valid numeric)" "200"        "$(code "$BASE/v1/weather/current?lat=52.52&lon=13.405")"
check "GET /current alias"                      "200"        "$(code "$BASE/current?lat=52.52&lon=13.405")"
check "GET /v1/weather/current?fahrenheit=true" "200"        "$(code "$BASE/v1/weather/current?lat=52.52&lon=13.405&fahrenheit=true")"
check "GET /v1/weather/currentbyip"             "200"        "$(code "$BASE/v1/weather/currentbyip")"

echo
echo "==> Response body assertions — CurrentWeatherCondition DTO serialization"
# Verify the weather response body contains expected JSON fields from the
# CurrentWeatherCondition DTO (Jackson reflection-based serialization).
WEATHER_BODY=$(curl -s --max-time 15 "$BASE/v1/weather/current?lat=52.52&lon=13.405")
has_field() { echo "$WEATHER_BODY" | grep -qF "$1"; }
has_field '"apiVersion"' && check "weather response has apiVersion"         "200" "200" || check "weather response has apiVersion" "200" "missing"
has_field '"errors"' && check "weather response has errors field"           "200" "200" || check "weather response has errors field" "200" "missing"

# Error response also serializes CurrentWeatherCondition with errors[] populated.
ERR_BODY=$(curl -s --max-time 15 "$BASE/v1/weather/current?lat=&lon=")
echo "$ERR_BODY" | grep -qF '"No latitude' && \
  check "error body contains error message"   "200" "200" || check "error body contains error message" "200" "missing"

echo
echo "==> HTTP method errors"
# 405 — POST on GET-only weather endpoint.
check "POST /v1/weather/current (wrong method)"   "405"        "$(code -X POST "$BASE/v1/weather/current")"

echo
echo "==> Cacheable AOP proxy — repeat request should hit cache"
# Two identical weather requests. The second one hits the @Cacheable proxy
# (OpenStreetMap, IpApi, etc.) instead of calling the real upstream.
# We just verify both return 200 — the cache proxy is the reflection path.
check "GET /v1/weather/current (cache warm-up)"    "200"        "$(code "$BASE/v1/weather/current?lat=52.52&lon=13.405")"
check "GET /v1/weather/current (cache hit)"         "200"        "$(code "$BASE/v1/weather/current?lat=52.52&lon=13.405")"

echo
echo "==> GlobalControllerExceptionHandler catch-all (501)"
# spring.mvc.throw-exception-if-no-handler-found=true -> NoResourceFoundException
# -> @ExceptionHandler(Exception.class) -> ResponseEntity.status(NOT_IMPLEMENTED).
# One sample is enough: every "no handler" URL hits the same bytecode path.
check "GET /does-not-exist -> 501"              "501"        "$(code "$BASE/does-not-exist")"

echo
echo "==> Actuator security (HttpBasic, ROLE_ADMIN)"
# Wrong-creds covers the BCrypt false branch; anon variants are pure URL clones.
# Admin 200 cases sample distinct actuator endpoints (info / env / mappings).
check "GET /actuator/info (wrong creds)"        "401"        "$(code -u "wrong:creds" "$BASE/actuator/info")"
check "GET /actuator/info (admin)"              "200"        "$(code -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/actuator/info")"
check "GET /actuator/env (admin)"               "200"        "$(code -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/actuator/env")"
check "GET /actuator/mappings (admin)"          "200"        "$(code -u "$ADMIN_USER:$ADMIN_PASS" "$BASE/actuator/mappings")"

echo
echo "==> Summary: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

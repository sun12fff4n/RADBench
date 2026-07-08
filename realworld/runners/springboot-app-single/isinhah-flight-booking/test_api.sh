#!/usr/bin/env bash
# isinhah-api-reserva-voos — smoke test.
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

# Random suffix per run so emails / flight numbers don't collide on re-run.
SUF="$RANDOM$RANDOM"
PASS_EMAIL="passenger_${SUF}@example.com"
ADMIN_EMAIL="admin_${SUF}@example.com"
PW="pw_${SUF}_test"

# ------------------------------------------------------------------
section "Public endpoints (no auth required)"
req_fields "GET  /v3/api-docs (OpenAPI spec)"            "200" \
'"openapi":"3.
"title":"Airline Ticket Reservation System"
"paths":' \
         "$BASE/v3/api-docs"
req_fields "GET  /swagger-ui/index.html"                 "200" \
'<html
swagger-ui' \
         "$BASE/swagger-ui/index.html"
# Public GET on /api/flights and /api/seats is in SecurityConfig#permitAll.
# Empty list on a fresh DB but the controller + JPA repo + Jackson all run.
req      "GET  /api/flights (public, empty list)"        "200" \
         "$BASE/api/flights"
req      "GET  /api/seats (public, empty list)"          "200" \
         "$BASE/api/seats"

# ------------------------------------------------------------------
section "Auth — register + login (passenger USER role)"
req_fields "POST /api/auth/passengers/register"          "200" \
'"name":"Test Passenger
"token":"eyJ
"expiresAt":' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"name\":\"Test Passenger ${SUF}\",\"email\":\"${PASS_EMAIL}\",\"password\":\"${PW}\",\"phone\":\"+10000${SUF}\"}" \
         "$BASE/api/auth/passengers/register"
USER_TOKEN=$(curl -sS -X POST -H 'Content-Type: application/json' \
             -d "{\"email\":\"${PASS_EMAIL}\",\"password\":\"${PW}\"}" \
             "$BASE/api/auth/passengers/login" \
             | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
req_fields "POST /api/auth/passengers/login"             "200" \
'"name":"Test Passenger
"token":"eyJ' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"email\":\"${PASS_EMAIL}\",\"password\":\"${PW}\"}" \
         "$BASE/api/auth/passengers/login"

# ------------------------------------------------------------------
section "Auth — register + login (employee ADMIN role)"
req_fields "POST /api/auth/employees/register"           "200" \
'"name":"Test Admin
"token":"eyJ' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"name\":\"Test Admin ${SUF}\",\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${PW}\"}" \
         "$BASE/api/auth/employees/register"
ADMIN_TOKEN=$(curl -sS -X POST -H 'Content-Type: application/json' \
             -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${PW}\"}" \
             "$BASE/api/auth/employees/login" \
             | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
req_fields "POST /api/auth/employees/login"              "200" \
'"name":"Test Admin
"token":"eyJ' \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${PW}\"}" \
         "$BASE/api/auth/employees/login"

USER_AUTH=(-H "Authorization: Bearer ${USER_TOKEN}")
ADMIN_AUTH=(-H "Authorization: Bearer ${ADMIN_TOKEN}")

# Capture passenger UUID by listing as admin and matching by email.
PASSENGER_ID=$(curl -sS "${ADMIN_AUTH[@]}" "$BASE/api/passengers" \
               | python3 -c "
import sys,json
for p in json.load(sys.stdin):
    if p.get('email')=='${PASS_EMAIL}': print(p['id']); break")
echo -e "${DIM}passenger_id=${PASSENGER_ID}${N}"

# ------------------------------------------------------------------
section "ADMIN-only listings (require ADMIN token)"
req_fields "GET  /api/passengers (ADMIN list)"           "200" \
"\"email\":\"${PASS_EMAIL}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/passengers"
req_fields "GET  /api/employees (ADMIN list)"            "200" \
"\"email\":\"${ADMIN_EMAIL}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/employees"

# ------------------------------------------------------------------
section "Real CRUD chain — flight → seat → reservation → ticket"
# Flight number must fit varchar(10). Use 8-char suffix.
FLIGHT_NUM="F${SUF: -7}"

# 1. Admin creates a flight. Capture id from response, then assert status+fields.
CREATE_FLIGHT=$(curl -sS -o "$TMP/flight" -w '%{http_code}' \
                -X POST -H 'Content-Type: application/json' "${ADMIN_AUTH[@]}" \
                -d "{\"airline\":\"TestAir\",\"flightNumber\":\"${FLIGHT_NUM}\",\"origin\":\"London\",\"destination\":\"Tokyo\",\"departureTime\":\"2026-12-01T15:30:00Z\",\"arrivalTime\":\"2026-12-01T18:45:00Z\",\"price\":299.99}" \
                "$BASE/api/flights")
FLIGHT_ID=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' < "$TMP/flight" 2>/dev/null)
if [[ "$CREATE_FLIGHT" == "201" && -n "$FLIGHT_ID" ]] \
   && grep -qF "\"flightNumber\":\"${FLIGHT_NUM}\"" "$TMP/flight" \
   && grep -qF '"price":299.99' "$TMP/flight"; then
  printf "${G}PASS${N} %-58s ${DIM}[201, flight created %s]${N}\n" \
    "POST /api/flights (ADMIN creates flight)" "${FLIGHT_ID:0:8}..."
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-58s ${DIM}[code=%s, id=%s]${N}\n" \
    "POST /api/flights (ADMIN creates flight)" "$CREATE_FLIGHT" "$FLIGHT_ID"
  head -3 "$TMP/flight" | sed 's/^/  /'; FAIL=$((FAIL+1))
fi

# 2. Admin creates a seat on that flight.
CREATE_SEAT=$(curl -sS -o "$TMP/seat" -w '%{http_code}' \
              -X POST -H 'Content-Type: application/json' "${ADMIN_AUTH[@]}" \
              -d "{\"seatNumber\":\"12A\",\"isAvailable\":true,\"flightId\":\"${FLIGHT_ID}\"}" \
              "$BASE/api/seats")
SEAT_ID=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' < "$TMP/seat" 2>/dev/null)
if [[ "$CREATE_SEAT" == "201" && -n "$SEAT_ID" ]] \
   && grep -qF '"seatNumber":"12A"' "$TMP/seat" \
   && grep -qF '"isAvailable":true' "$TMP/seat"; then
  printf "${G}PASS${N} %-58s ${DIM}[201, seat created %s]${N}\n" \
    "POST /api/seats (ADMIN creates seat)" "${SEAT_ID:0:8}..."
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-58s ${DIM}[code=%s, id=%s]${N}\n" \
    "POST /api/seats (ADMIN creates seat)" "$CREATE_SEAT" "$SEAT_ID"
  head -3 "$TMP/seat" | sed 's/^/  /'; FAIL=$((FAIL+1))
fi

# 3. USER creates a reservation referencing the seat + passenger. Response
#    DTO nests seat{} and passenger{} (not flat seatId/passengerId), so the
#    field assertions match the nested keys.
CREATE_RES=$(curl -sS -o "$TMP/res" -w '%{http_code}' \
             -X POST -H 'Content-Type: application/json' "${USER_AUTH[@]}" \
             -d "{\"seatId\":\"${SEAT_ID}\",\"passengerId\":\"${PASSENGER_ID}\"}" \
             "$BASE/api/reservations")
RES_ID=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' < "$TMP/res" 2>/dev/null)
if [[ "$CREATE_RES" == "201" && -n "$RES_ID" ]] \
   && grep -qF '"reservationDate":' "$TMP/res" \
   && grep -qF "\"id\":\"${SEAT_ID}\"" "$TMP/res" \
   && grep -qF "\"id\":\"${PASSENGER_ID}\"" "$TMP/res" \
   && grep -qF '"isAvailable":false' "$TMP/res"; then
  # Extra: reserving a seat flips isAvailable to false (state mutation).
  printf "${G}PASS${N} %-58s ${DIM}[201, seat→unavailable, %s]${N}\n" \
    "POST /api/reservations (USER reserves seat)" "${RES_ID:0:8}..."
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-58s ${DIM}[code=%s, res_id=%s]${N}\n" \
    "POST /api/reservations (USER reserves seat)" "$CREATE_RES" "$RES_ID"
  head -3 "$TMP/res" | sed 's/^/  /'; FAIL=$((FAIL+1))
fi

# 4. USER reads back the reservation by id (allowed: GET /reservations/{id}).
req_fields "GET  /api/reservations/{id} (USER reads own)"  "200" \
"\"id\":\"${RES_ID}\"
\"reservationDate\":
\"seat\":{
\"passenger\":{" \
         "${USER_AUTH[@]}" "$BASE/api/reservations/${RES_ID}"

# 5. Ticket auto-generated by ReservationService on creation. /api/tickets
#    (list) requires ADMIN. List DTO has flat reservationId (string) +
#    nested flight{}. The single-ticket GET returns the same shape.
TICKET_ID=$(curl -sS "${ADMIN_AUTH[@]}" "$BASE/api/tickets" \
            | python3 -c "
import sys,json
for t in json.load(sys.stdin):
    if t.get('reservationId')=='${RES_ID}': print(t['id']); break")
req_fields "GET  /api/tickets/{id} (auto-generated ticket)"  "200" \
"\"id\":\"${TICKET_ID}\"
\"ticketNumber\":
\"reservationId\":\"${RES_ID}\"
\"flight\":{" \
         "${USER_AUTH[@]}" "$BASE/api/tickets/${TICKET_ID}"

# ------------------------------------------------------------------
section "GET-by-id round-trips (verify writes are persistent + readable)"
# Public flight read by id — proves the FlightController.findById path
# (different from the GET / list path).
req_fields "GET  /api/flights/{id} (public)"            "200" \
"\"id\":\"${FLIGHT_ID}\"
\"airline\":\"TestAir\"
\"flightNumber\":\"${FLIGHT_NUM}\"
\"price\":299.99" \
         "$BASE/api/flights/${FLIGHT_ID}"
# Public seat read by id.
req_fields "GET  /api/seats/{id} (public)"              "200" \
"\"id\":\"${SEAT_ID}\"
\"seatNumber\":\"12A\"
\"isAvailable\":false" \
         "$BASE/api/seats/${SEAT_ID}"
# USER reads own passenger profile.
req_fields "GET  /api/passengers/{self} (USER reads own)"  "200" \
"\"id\":\"${PASSENGER_ID}\"
\"email\":\"${PASS_EMAIL}\"
\"phone\":\"+10000${SUF}\"" \
         "${USER_AUTH[@]}" "$BASE/api/passengers/${PASSENGER_ID}"
# ADMIN reads employee by id (capture admin id from list).
ADMIN_ID=$(curl -sS "${ADMIN_AUTH[@]}" "$BASE/api/employees" \
           | python3 -c "
import sys,json
for e in json.load(sys.stdin):
    if e.get('email')=='${ADMIN_EMAIL}': print(e['id']); break")
req_fields "GET  /api/employees/{id} (ADMIN)"           "200" \
"\"id\":\"${ADMIN_ID}\"
\"email\":\"${ADMIN_EMAIL}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/employees/${ADMIN_ID}"
# Explicit ADMIN list of tickets (we used this internally above, now assert).
req_fields "GET  /api/tickets (ADMIN list)"             "200" \
"\"id\":\"${TICKET_ID}\"
\"reservationId\":\"${RES_ID}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/tickets"
# Explicit ADMIN list of reservations (the catch-all reservation query).
req_fields "GET  /api/reservations (ADMIN list)"        "200" \
"\"id\":\"${RES_ID}\"
\"seat\":{" \
         "${ADMIN_AUTH[@]}" "$BASE/api/reservations"

# ------------------------------------------------------------------
section "PUT updates — mutate then verify via GET-by-id"
# PUT /api/flights replaces the whole record. Change price.
req      "PUT  /api/flights (ADMIN updates price)"      "200" \
         -X PUT -H 'Content-Type: application/json' "${ADMIN_AUTH[@]}" \
         -d "{\"id\":\"${FLIGHT_ID}\",\"airline\":\"TestAir\",\"flightNumber\":\"${FLIGHT_NUM}\",\"origin\":\"London\",\"destination\":\"Tokyo\",\"departureTime\":\"2026-12-01T15:30:00Z\",\"arrivalTime\":\"2026-12-01T18:45:00Z\",\"price\":399.99}" \
         "$BASE/api/flights"
# Verify the PUT actually persisted.
req_fields "GET  /api/flights/{id} (after PUT — new price)"  "200" \
'"price":399.99' \
         "$BASE/api/flights/${FLIGHT_ID}"
# PUT /api/passengers — USER can update own profile (allowed by SecurityConfig).
# We need full PassengerUpdateDTO body. Let me fetch the existing record + change phone.
# Phone must be 10-15 chars including +. SUF can be up to 10 chars, so cap.
NEW_PHONE="+99999${SUF: -8}"
# PassengerUpdateDTO requires every field (id, name, email, password >=8 chars,
# phone 10-15 chars). password=PW satisfies the >=8 constraint.
req      "PUT  /api/passengers (USER updates own phone)" "200" \
         -X PUT -H 'Content-Type: application/json' "${USER_AUTH[@]}" \
         -d "{\"id\":\"${PASSENGER_ID}\",\"name\":\"Test Passenger ${SUF}\",\"email\":\"${PASS_EMAIL}\",\"password\":\"${PW}\",\"phone\":\"${NEW_PHONE}\"}" \
         "$BASE/api/passengers"
req_fields "GET  /api/passengers/{self} (after PUT — new phone)" "200" \
"\"phone\":\"${NEW_PHONE}\"" \
         "${USER_AUTH[@]}" "$BASE/api/passengers/${PASSENGER_ID}"

# ------------------------------------------------------------------
section "Search/filter endpoints (representative sample, 1 per controller)"
# Each controller has 1-3 searchBy* / search variants — same backend path,
# different filters. Test 1 of each as a representative sample.
req_fields "GET  /api/flights/searchByAirline?airline=TestAir (public)" "200" \
"\"airline\":\"TestAir\"" \
         "$BASE/api/flights/searchByAirline?airline=TestAir"
req_fields "GET  /api/seats/searchAvailableSeats?flightId={FLIGHT_ID}"  "200" \
'[' \
         "${USER_AUTH[@]}" "$BASE/api/seats/searchAvailableSeats?flightId=${FLIGHT_ID}"
req_fields "GET  /api/passengers/searchByName?name=Test (ADMIN)"  "200" \
"\"email\":\"${PASS_EMAIL}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/passengers/searchByName?name=Test"
req_fields "GET  /api/passengers/search?email= (ADMIN)"   "200" \
"\"email\":\"${PASS_EMAIL}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/passengers/search?email=${PASS_EMAIL}"
req_fields "GET  /api/flights/searchByFlightNumber"      "200" \
"\"flightNumber\":\"${FLIGHT_NUM}\"" \
         "$BASE/api/flights/searchByFlightNumber?flightNumber=${FLIGHT_NUM}"
req_fields "GET  /api/flights/searchByLocation"          "200" \
"\"origin\":\"London\"" \
         "$BASE/api/flights/searchByLocation?origin=London&destination=Tokyo"
req_fields "GET  /api/seats/search?seatNumber"           "200" \
"\"seatNumber\":\"12A\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/seats/search?seatNumber=12A"
req_fields "GET  /api/reservations/search?passengerId (ADMIN)"  "200" \
"\"id\":\"${RES_ID}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/reservations/search?passengerId=${PASSENGER_ID}"
req      "GET  /api/reservations/searchByDate?reservationDate (ADMIN)" "200" \
         "${ADMIN_AUTH[@]}" "$BASE/api/reservations/searchByDate?reservationDate=$(date -u +%Y-%m-%dT00:00:00Z)"
# /api/tickets/search?reservationId returns a SINGLE ticket object (not list).
req_fields "GET  /api/tickets/search?reservationId (ADMIN)"  "200" \
"\"reservationId\":\"${RES_ID}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/tickets/search?reservationId=${RES_ID}"

# ------------------------------------------------------------------
section "Employee CRUD (POST + GET filters + PUT + DELETE)"
# ADMIN creates a SECOND employee, then exercises every remaining endpoint
# on it (byEmail, byName, PUT, DELETE) — proves all 7 EmployeeController
# endpoints really respond.
EMP2_EMAIL="emp2_${SUF}@example.com"
CREATE_EMP=$(curl -sS -o "$TMP/emp" -w '%{http_code}' \
             -X POST -H 'Content-Type: application/json' "${ADMIN_AUTH[@]}" \
             -d "{\"name\":\"Second Admin ${SUF}\",\"email\":\"${EMP2_EMAIL}\",\"password\":\"emp_${SUF}_pw\"}" \
             "$BASE/api/employees")
EMP_ID=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])' < "$TMP/emp" 2>/dev/null)
if [[ "$CREATE_EMP" == "201" && -n "$EMP_ID" ]] \
   && grep -qF "\"email\":\"${EMP2_EMAIL}\"" "$TMP/emp"; then
  printf "${G}PASS${N} %-58s ${DIM}[201, employee %s]${N}\n" \
    "POST /api/employees (ADMIN creates 2nd employee)" "${EMP_ID:0:8}..."
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-58s ${DIM}[code=%s]${N}\n" \
    "POST /api/employees (ADMIN creates 2nd employee)" "$CREATE_EMP"
  head -3 "$TMP/emp" | sed 's/^/  /'; FAIL=$((FAIL+1))
fi
req_fields "GET  /api/employees/byEmail (ADMIN)"         "200" \
"\"email\":\"${EMP2_EMAIL}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/employees/byEmail?email=${EMP2_EMAIL}"
req_fields "GET  /api/employees/byName (ADMIN)"          "200" \
"\"email\":\"${EMP2_EMAIL}\"" \
         "${ADMIN_AUTH[@]}" "$BASE/api/employees/byName?name=Second"
req      "PUT  /api/employees (update name)"             "200" \
         -X PUT -H 'Content-Type: application/json' "${ADMIN_AUTH[@]}" \
         -d "{\"id\":\"${EMP_ID}\",\"name\":\"Renamed Admin\",\"email\":\"${EMP2_EMAIL}\",\"password\":\"emp_${SUF}_pw\"}" \
         "$BASE/api/employees"
req      "DELETE /api/employees/{id}"                    "204" \
         -X DELETE "${ADMIN_AUTH[@]}" "$BASE/api/employees/${EMP_ID}"

# ------------------------------------------------------------------
section "Seat / Ticket PUT + DELETE"
# PUT seat — change seatNumber, then verify via GET-by-id.
req      "PUT  /api/seats (ADMIN updates seatNumber)"    "200" \
         -X PUT -H 'Content-Type: application/json' "${ADMIN_AUTH[@]}" \
         -d "{\"id\":\"${SEAT_ID}\",\"seatNumber\":\"99Z\",\"isAvailable\":false,\"flightId\":\"${FLIGHT_ID}\"}" \
         "$BASE/api/seats"
req_fields "GET  /api/seats/{id} (after PUT — new seatNumber)" "200" \
'"seatNumber":"99Z"' \
         "$BASE/api/seats/${SEAT_ID}"
# PUT ticket — change ticketNumber.
NEW_TICKET_NUM="UPDATED_${SUF}"
req      "PUT  /api/tickets (ADMIN updates ticketNumber)" "200" \
         -X PUT -H 'Content-Type: application/json' "${ADMIN_AUTH[@]}" \
         -d "{\"id\":\"${TICKET_ID}\",\"ticketNumber\":\"${NEW_TICKET_NUM}\",\"reservationId\":\"${RES_ID}\",\"flightId\":\"${FLIGHT_ID}\"}" \
         "$BASE/api/tickets"
req_fields "GET  /api/tickets/{id} (after PUT — new number)" "200" \
"\"ticketNumber\":\"${NEW_TICKET_NUM}\"" \
         "${USER_AUTH[@]}" "$BASE/api/tickets/${TICKET_ID}"

# ------------------------------------------------------------------
section "Cleanup"
# Reverse order: ticket → reservation → seat → flight. Cascading FKs handle
# tickets when reservation is deleted, but we DELETE explicitly for clarity.
[[ -n "$RES_ID" ]] && curl -sS -o /dev/null -X DELETE "${USER_AUTH[@]}" "$BASE/api/reservations/${RES_ID}"
# Use admin token for flights+seats (USER can't delete those).
[[ -n "$FLIGHT_ID" ]] && curl -sS -o /dev/null -X DELETE "${ADMIN_AUTH[@]}" "$BASE/api/flights/${FLIGHT_ID}"
echo -e "${DIM}cleanup: deleted reservation=${RES_ID} flight=${FLIGHT_ID} (CASCADE drops seats+tickets)${N}"

# ------------------------------------------------------------------
section "Bean Validation — @Valid on record DTOs (Hibernate Validator + Jackson record deser)"
# FlightRequestDTO is a Java record with @NotBlank, @NotNull, @Positive.
# Empty body triggers MethodArgumentNotValidException → ExceptionFields envelope.
req_fields "POST /flights (empty body → validation error)"     "400" \
'"Method Argument Not Valid"
"status":400
"fields":"
"fieldsMessage":"' \
         -X POST -H "Content-Type: application/json" "${ADMIN_AUTH[@]}" \
         -d '{}' "$BASE/api/flights"

# Negative price → @Positive violation.
req_fields "POST /flights (negative price → @Positive)"        "400" \
'"fields":"
"fieldsMessage":"' \
         -X POST -H "Content-Type: application/json" "${ADMIN_AUTH[@]}" \
         -d '{"airline":"Test","flightNumber":"T1","origin":"A","destination":"B","departureTime":"2025-01-01T10:00:00Z","arrivalTime":"2025-01-01T12:00:00Z","price":-5.0}' \
         "$BASE/api/flights"

# ------------------------------------------------------------------
section "Exception handling — GlobalExceptionHandler error envelopes"
# ResourceNotFoundException → ExceptionResponse with "Resource Not Found".
req_fields "GET  /flights/{bogus} (404 → ExceptionResponse)"   "404" \
'"Resource Not Found"
"status":404
"timestamp":"' \
         "${ADMIN_AUTH[@]}" "$BASE/api/flights/00000000-0000-0000-0000-000000000000"

# 405 Method Not Allowed — POST on GET-only search endpoint.
req_fields "POST /flights/search (405 → Method Not Allowed)"   "405" \
'"Method Not Allowed"
"status":405' \
         -X POST -H "Content-Type: application/json" "${ADMIN_AUTH[@]}" \
         -d '{}' "$BASE/api/flights/search/origin?origin=test"

# 404 — unmapped path.
req_fields "GET  /nonexistent (404 → No Resource Found)"       "404" \
'"No Resource Found"
"status":404' \
         "$BASE/api/nonexistent"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

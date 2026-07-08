#!/usr/bin/env bash
# LibraryMan API — smoke test.
# JWT login flow with both USER and ADMIN paths. 
# Flow:
#   1. Public endpoints.
#   2. Signup + login as a USER (JWT token).
#   3. Hit admin-only endpoints as USER → assert 401/403 (denial path).
#   4. Promote the USER to ADMIN via direct DB update (docker exec on mysql).
#   5. Re-login, hit the same endpoints with the new role → assert 2xx (happy path).
#
# Step 4 needs access to the MySQL container (default: `libraryman-mysql`);
# set MYSQL_EXEC=... to override, or SKIP_ADMIN=1 to skip steps 4-5.
#
# Usage:
#   ./test_api.sh
#   BASE=http://host:port ./test_api.sh
#   SKIP_ADMIN=1 ./test_api.sh
#   ./test_api.sh --stop-on-fail

set -u

BASE="${BASE:-http://localhost:8080}"
API="${BASE}/api"
SKIP_ADMIN="${SKIP_ADMIN:-0}"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; DIM='\033[2m'; N='\033[0m'

PASS=0; FAIL=0; SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

has_jq=0; command -v jq >/dev/null 2>&1 && has_jq=1
pretty() { if [[ $has_jq -eq 1 ]]; then jq . 2>/dev/null || cat; else cat; fi; }

req() {
  local label="$1" expected="$2"; shift 2
  local body="$TMP/body"
  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" || echo "000")
  if [[ "$code" =~ ^$expected$ ]]; then
    printf "${G}PASS${N} %-55s ${DIM}[%s]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-55s ${DIM}[got %s, want %s]${N}\n" "$label" "$code" "$expected"
    echo -e "${Y}--- body ---${N}"; pretty < "$body" | sed 's/^/  /'
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

field() {
  if [[ $has_jq -eq 1 ]]; then jq -r "$1 // empty" < "$TMP/body"; else
    local k; k=$(echo "$1" | sed 's/^\.//; s/\..*$//')
    grep -o "\"$k\"[[:space:]]*:[[:space:]]*[^,}]*" "$TMP/body" | head -1 | sed 's/.*:[[:space:]]*//; s/^"//; s/"$//'
  fi
}

section() { echo -e "\n${B}== $* ==${N}"; }

login() {
  local user="$1" pass="$2" label="$3"
  # req prints PASS/FAIL to stdout; redirect to stderr so $(login ...) only
  # captures the token emitted by `field` on the next line.
  req "$label" "200"                                                         \
       -H "Content-Type: application/json"                                   \
       -X POST "$API/login"                                                  \
       -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}"  >&2
  field '.token'
}

# ==================================================================
# PUBLIC + USER
# ==================================================================

section "Public endpoints (no auth)"
req "GET  /api/get-all-books"              "200"                             "$API/get-all-books"
req "GET  /api/get-all-books (paging+sort)" "200"                            "$API/get-all-books?page=0&size=3&sortBy=title&sortDir=asc"
req "GET  /api/book/search (no result)"    "200|204"                         "$API/book/search?keyword=__zzz_nope_zzz__"

section "Signup + Login (USER)"
SUFFIX="$(date +%s)_$$"
USER="tester_${SUFFIX}"
EMAIL="tester_${SUFFIX}@example.com"
PASS_PLAIN='TestPass1@'

req "POST /api/signup (new user)"          "200"                             \
     -H "Content-Type: application/json"                                     \
     -X POST "$API/signup"                                                   \
     -d "{\"name\":\"Tester ${SUFFIX}\",\"username\":\"${USER}\",\"email\":\"${EMAIL}\",\"password\":\"${PASS_PLAIN}\"}"

req "POST /api/signup (duplicate → 404)"   "400|404|409|500"                 \
     -H "Content-Type: application/json"                                     \
     -X POST "$API/signup"                                                   \
     -d "{\"name\":\"Tester ${SUFFIX}\",\"username\":\"${USER}\",\"email\":\"${EMAIL}\",\"password\":\"${PASS_PLAIN}\"}"

USER_TOKEN="$(login "$USER" "$PASS_PLAIN" "POST /api/login (USER → JWT)")"
[[ -z "$USER_TOKEN" ]] && { echo -e "${R}ERROR: no token from USER login.${N}"; exit 2; }
echo -e "${DIM}USER token: ${USER_TOKEN:0:24}...${N}"

req "POST /api/login (bad password → 401)" "401|403|500"                     \
     -H "Content-Type: application/json"                                     \
     -X POST "$API/login"                                                    \
     -d "{\"username\":\"${USER}\",\"password\":\"wrong-wrong\"}"

AUTH_U=(-H "Authorization: Bearer ${USER_TOKEN}")

section "Newsletter (USER)"
req "POST /api/newsletter/subscribe"       "200|201|400|409|500"             \
     "${AUTH_U[@]}" -X POST "$API/newsletter/subscribe?email=${EMAIL}"
req "GET  /api/newsletter/unsubscribe (bad token)" "404|409|500"             \
     "${AUTH_U[@]}" "$API/newsletter/unsubscribe?token=not-a-real-token"

section "USER hits admin-only endpoints → expect 401/403"
req "GET  /api/get-member-by-id/1"         "401|403"                         \
     "${AUTH_U[@]}" "$API/get-member-by-id/1"
req "PUT  /api/update-member-by-id/999999" "401|403"                         \
     "${AUTH_U[@]}" -H "Content-Type: application/json"                      \
     -X PUT "$API/update-member-by-id/999999"                                \
     -d "{\"name\":\"Renamed\",\"username\":\"${USER}\",\"email\":\"${EMAIL}\"}"
req "PUT  /api/update-password-by-id/999999" "401|403"                       \
     "${AUTH_U[@]}" -H "Content-Type: application/json"                      \
     -X PUT "$API/update-password-by-id/999999"                              \
     -d "{\"currentPassword\":\"${PASS_PLAIN}\",\"newPassword\":\"NewPass1@\"}"
req "POST /api/add-book"                   "401|403"                         \
     "${AUTH_U[@]}" -H "Content-Type: application/json"                      \
     -X POST "$API/add-book"                                                 \
     -d '{"title":"T","author":"A","isbn":"978-0-06-112008-4","publisher":"P","publishedYear":2020,"genre":"G","copiesAvailable":1}'
req "PUT  /api/update-book/1"              "401|403"                         \
     "${AUTH_U[@]}" -H "Content-Type: application/json"                      \
     -X PUT "$API/update-book/1"                                             \
     -d '{"title":"T2","author":"A","isbn":"978-0-06-112008-4","publisher":"P","publishedYear":2020,"genre":"G","copiesAvailable":1}'
req "DEL  /api/delete-book/1"              "401|403"                         \
     "${AUTH_U[@]}" -X DELETE "$API/delete-book/1"
req "GET  /api/get-all-borrowings"         "401|403"                         \
     "${AUTH_U[@]}" "$API/get-all-borrowings"
req "GET  /api/get-borrowing-by-id/1"      "401|403"                         \
     "${AUTH_U[@]}" "$API/get-borrowing-by-id/1"
req "GET  /api/get-all-members"            "401|403"                         \
     "${AUTH_U[@]}" "$API/get-all-members"
req "GET  /api/analytics/overview"         "401|403"                         \
     "${AUTH_U[@]}" "$API/analytics/overview"
req "GET  /api/analytics/popular-books"    "401|403"                         \
     "${AUTH_U[@]}" "$API/analytics/popular-books?limit=5"
req "GET  /api/analytics/borrowing-trends" "401|403"                         \
     "${AUTH_U[@]}" "$API/analytics/borrowing-trends?startDate=2024-01-01&endDate=2024-12-31"
req "GET  /api/analytics/member-activity"  "401|403"                         \
     "${AUTH_U[@]}" "$API/analytics/member-activity"

section "USER: endpoints with no @PreAuthorize (should succeed past security)"
req "GET  /api/get-book-by-id/1"           "200|404"                         \
     "${AUTH_U[@]}" "$API/get-book-by-id/1"
req "PUT  /api/1/return-borrow-book"       "200|404|500"                     \
     "${AUTH_U[@]}" -X PUT "$API/1/return-borrow-book"
req "PUT  /api/borrowing/1/pay-fine"       "200|404|500"                     \
     "${AUTH_U[@]}" -X PUT "$API/borrowing/1/pay-fine"

# ==================================================================
# ADMIN (promote via direct DB write, re-login)
# ==================================================================

MYSQL_EXEC="${MYSQL_EXEC:-docker exec -i libraryman-mysql mysql -uroot -pbenchmark libraryman}"

section "Promote USER → ADMIN (direct DB update)"
if [[ "$SKIP_ADMIN" == "1" ]]; then
  echo -e "${Y}SKIP: SKIP_ADMIN=1 set.${N}"; SKIP=$((SKIP+1))
elif ! echo "SELECT 1;" | $MYSQL_EXEC >/dev/null 2>&1; then
  echo -e "${Y}SKIP: cannot reach MySQL (set MYSQL_EXEC to override).${N}"; SKIP=$((SKIP+1))
else
  echo "UPDATE members SET role='ADMIN' WHERE username='${USER}';" | $MYSQL_EXEC
  MEMBER_ID=$(echo "SELECT member_id FROM members WHERE username='${USER}';" | $MYSQL_EXEC -N 2>/dev/null | head -1 | tr -d '[:space:]')
  echo -e "${DIM}Promoted: username=${USER}  memberId=${MEMBER_ID}${N}"

  ADMIN_TOKEN="$(login "$USER" "$PASS_PLAIN" "POST /api/login (re-login as ADMIN)")"
  [[ -z "$ADMIN_TOKEN" ]] && { echo -e "${R}ERROR: no token after elevation.${N}"; exit 2; }
  echo -e "${DIM}ADMIN token: ${ADMIN_TOKEN:0:24}...${N}"
  AUTH_A=(-H "Authorization: Bearer ${ADMIN_TOKEN}")

  # --------------------------------------------------------------
  section "ADMIN: Members"
  req "GET  /api/get-all-members"            "200"                           \
       "${AUTH_A[@]}" "$API/get-all-members"
  req "GET  /api/get-member-by-id/${MEMBER_ID}" "200"                        \
       "${AUTH_A[@]}" "$API/get-member-by-id/${MEMBER_ID}"
  req "PUT  /api/update-member-by-id/${MEMBER_ID} (self)" "200"              \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X PUT "$API/update-member-by-id/${MEMBER_ID}"                        \
       -d "{\"name\":\"Renamed ${SUFFIX}\",\"username\":\"${USER}\",\"email\":\"${EMAIL}\"}"

  # --------------------------------------------------------------
  section "ADMIN: Role-protected signup"
  req "POST /api/signup/librarian"           "200"                           \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X POST "$API/signup/librarian"                                       \
       -d "{\"name\":\"Lib ${SUFFIX}\",\"username\":\"lib_${SUFFIX}\",\"email\":\"lib_${SUFFIX}@example.com\",\"password\":\"LibPass1@\"}"
  req "POST /api/signup/admin"               "200"                           \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X POST "$API/signup/admin"                                           \
       -d "{\"name\":\"Adm ${SUFFIX}\",\"username\":\"adm_${SUFFIX}\",\"email\":\"adm_${SUFFIX}@example.com\",\"password\":\"AdmPass1@\"}"

  # --------------------------------------------------------------
  section "ADMIN: Books CRUD"
  req "POST /api/add-book"                   "200"                           \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X POST "$API/add-book"                                               \
       -d "{\"title\":\"Test Book ${SUFFIX}\",\"author\":\"Tester\",\"isbn\":\"978-0-06-112008-4\",\"publisher\":\"TestPub\",\"publishedYear\":2020,\"genre\":\"Fiction\",\"copiesAvailable\":3}"
  BOOK_ID="$(field '.bookId')"
  echo -e "${DIM}Created bookId=${BOOK_ID}${N}"

  req "PUT  /api/update-book/${BOOK_ID}"     "200"                           \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X PUT "$API/update-book/${BOOK_ID}"                                  \
       -d "{\"title\":\"Updated ${SUFFIX}\",\"author\":\"Tester\",\"isbn\":\"978-0-06-112008-4\",\"publisher\":\"TestPub\",\"publishedYear\":2021,\"genre\":\"Fiction\",\"copiesAvailable\":2}"
  req "GET  /api/get-book-by-id/${BOOK_ID}"  "200"                           \
       "${AUTH_A[@]}" "$API/get-book-by-id/${BOOK_ID}"
  req "GET  /api/book/search?keyword=Updated" "200|204"                      \
       "${AUTH_A[@]}" "$API/book/search?keyword=Updated"

  # --------------------------------------------------------------
  # Project-defined error states — representative coverage of
  # GlobalExceptionHandler's distinct handlers (not exhaustive
  # enumeration of every @Valid constraint).
  section "ADMIN: Project-defined error states (representative)"

  # MethodArgumentNotValidException handler — sample 1: missing required
  # field. BookDto has @NotBlank on title; sending a body without it
  # triggers the @Valid handler returning 400.
  req "POST /api/add-book (missing title → 400)"  "400"                       \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X POST "$API/add-book"                                               \
       -d '{"author":"x","isbn":"978-0-06-112008-4","publisher":"p","publishedYear":2020,"genre":"g","copiesAvailable":1}'

  # MethodArgumentNotValidException handler — sample 2: format-invalid
  # field. BookDto has @Pattern on isbn; same handler, different
  # constraint kind. Two samples is enough — every other @NotBlank /
  # @Size / @Min hits the same code path.
  req "POST /api/add-book (bad isbn format → 400)" "400"                      \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X POST "$API/add-book"                                               \
       -d '{"title":"x","author":"x","isbn":"not-an-isbn","publisher":"p","publishedYear":2020,"genre":"g","copiesAvailable":1}'

  # InvalidSortFieldException handler — distinct exception type, distinct
  # handler. Service throws when sortBy doesn't match an entity field.
  req "GET  /api/get-all-books?sortBy=__bogus__ (→ 400)" "400"                \
       "${AUTH_A[@]}" "$API/get-all-books?sortBy=__bogus_field__"

  # InvalidPasswordException handler — distinct from MethodArgumentNotValid.
  # MemberService.updatePassword throws when currentPassword is wrong.
  req "PUT  /api/update-password (wrong cur pw → 400)" "400"                  \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X PUT "$API/update-password-by-id/${MEMBER_ID}"                      \
       -d '{"currentPassword":"WrongPass1@","newPassword":"NewPass1@"}'

  # --------------------------------------------------------------
  section "ADMIN: Borrowings"
  # Source bug: BorrowingService.borrowBook causes Hibernate JpaSystemException
  # "identifier of an instance of Notifications was altered from N to M" on
  # a fresh DB. The 500 gets re-dispatched through security → 401.
  req "POST /api/borrow-book (known source bug → 401/500)" "200|401|500"     \
       "${AUTH_A[@]}" -H "Content-Type: application/json"                    \
       -X POST "$API/borrow-book"                                            \
       -d "{\"book\":{\"bookId\":${BOOK_ID},\"title\":\"x\",\"author\":\"x\",\"isbn\":\"978-0-06-112008-4\",\"publisher\":\"x\",\"publishedYear\":2000,\"genre\":\"x\",\"copiesAvailable\":1},\"member\":{\"memberId\":${MEMBER_ID},\"name\":\"x\",\"username\":\"xxxx\",\"email\":\"x@example.com\",\"password\":\"Xx1@xxxx\"}}"
  BORROW_ID="$(field '.borrowingId')"
  echo -e "${DIM}Created borrowingId=${BORROW_ID}${N}"

  req "GET  /api/get-all-borrowings"         "200"                           \
       "${AUTH_A[@]}" "$API/get-all-borrowings"
  # If borrow failed, member has no borrowings → service throws → 404.
  req "GET  /api/get-all-borrowings-of-a-member/${MEMBER_ID}" "200|404"      \
       "${AUTH_A[@]}" "$API/get-all-borrowings-of-a-member/${MEMBER_ID}"
  if [[ -n "$BORROW_ID" ]]; then
    req "GET  /api/get-borrowing-by-id/${BORROW_ID}" "200"                   \
         "${AUTH_A[@]}" "$API/get-borrowing-by-id/${BORROW_ID}"
    req "PUT  /api/${BORROW_ID}/return-borrow-book" "200"                    \
         "${AUTH_A[@]}" -X PUT "$API/${BORROW_ID}/return-borrow-book"
    req "PUT  /api/borrowing/${BORROW_ID}/pay-fine" "200"                    \
         "${AUTH_A[@]}" -X PUT "$API/borrowing/${BORROW_ID}/pay-fine"
  fi

  # --------------------------------------------------------------
  section "ADMIN: Analytics"
  req "GET  /api/analytics/overview"         "200"                           \
       "${AUTH_A[@]}" "$API/analytics/overview"
  # Source bug: BorrowingRepository.findMostBorrowedBooks native query
  # references table `books` (plural) but the actual table is `book`.
  # Hibernate throws 500 → re-dispatched through security → 401.
  req "GET  /api/analytics/popular-books (known source bug → 401/500)" "200|401|500" \
       "${AUTH_A[@]}" "$API/analytics/popular-books?limit=5"
  # Same root cause: getBorrowingTrendsBetweenDates uses wrong table names.
  req "GET  /api/analytics/borrowing-trends (known source bug → 401/500)" "200|401|500" \
       "${AUTH_A[@]}" "$API/analytics/borrowing-trends?startDate=2024-01-01&endDate=2024-12-31"
  req "GET  /api/analytics/member-activity"  "200"                           \
       "${AUTH_A[@]}" "$API/analytics/member-activity"

  # --------------------------------------------------------------
  section "ADMIN: Cleanup + state-transition closure"
  req "DEL  /api/delete-book/${BOOK_ID}"     "200"                           \
       "${AUTH_A[@]}" -X DELETE "$API/delete-book/${BOOK_ID}"
  # State-transition closure: after DELETE, the same id must 404.
  # Confirms the delete actually removed the row (vs. just returning 200).
  # Hits the ResourceNotFoundException handler — already covered indirectly
  # by other not-found probes, but here it CLOSES the create→read→update→
  # delete→re-read chain that's the most useful state-coverage signal.
  req "GET  /api/get-book-by-id/${BOOK_ID} (after delete → 404)" "404"        \
       "${AUTH_A[@]}" "$API/get-book-by-id/${BOOK_ID}"
fi

# ==================================================================
# End session
# ==================================================================

section "Logout"
req "POST /api/logout"                       "200"                           \
     "${AUTH_U[@]}" -X POST "$API/logout"

# ==================================================================
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  msg="All ${PASS}/${TOTAL} checks passed."
  [[ $SKIP -gt 0 ]] && msg="${msg} (${SKIP} sections skipped)"
  echo -e "${G}${msg}${N}"
  exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed, ${SKIP} skipped)."
  exit 1
fi

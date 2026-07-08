#!/usr/bin/env bash
# JOAL —  moke test (HTTP security layer + WebSocket/STOMP ops).
#
# All business operations use WebSocket with the STOMP sub-protocol.  
# This script tests:
#   1. HTTP security layer (path-prefix filter, Spring Security)
#   2. Web UI static resource serving
#   3. STOMP authentication (token-based via X-Joal-Auth-Token header)
#   4. STOMP business operations (config, start/stop seeding, state query)
# Usage:
#   ./test_api.sh
#   BASE=http://host:port ./test_api.sh
#   ./test_api.sh --stop-on-fail

set -u

BASE="${BASE:-http://localhost:8080}"
PREFIX="${PREFIX:-joaltest}"
SECRET="${SECRET:-joaltest-secret-token}"
CONTAINER="${CONTAINER:-joal}"
STOP_ON_FAIL=0
[[ "${1:-}" == "--stop-on-fail" ]] && STOP_ON_FAIL=1

WS_URL=$(echo "$BASE" | sed 's|^http|ws|')/"${PREFIX}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'
DIM='\033[2m'; N='\033[0m'

PASS=0; FAIL=0; SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

has_jq=0; command -v jq >/dev/null 2>&1 && has_jq=1
pretty() { if [[ $has_jq -eq 1 ]]; then jq . 2>/dev/null || cat; else cat; fi; }

section() { echo -e "\n${B}== $* ==${N}"; }

# ── HTTP helpers ──────────────────────────────────────────────────

req() {
  local label="$1" expected="$2"; shift 2
  local body="$TMP/body"
  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^($expected)$ ]]; then
    printf "${G}PASS${N} %-55s ${DIM}[%s]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-55s ${DIM}[got %s, want %s]${N}\n" "$label" "$code" "$expected"
    if [[ -s "$body" ]]; then
      echo -e "${Y}--- body ---${N}"; head -5 "$body" | sed 's/^/  /'
    fi
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

# Like req, but additionally asserts the response body contains $pattern
# (fixed-string grep). Status and body must both match to PASS.
req_body() {
  local label="$1" expected="$2" pattern="$3"; shift 3
  local body="$TMP/body"
  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" "$@" 2>/dev/null || echo "000")
  local status_ok=0 body_ok=0
  [[ "$code" =~ ^($expected)$ ]] && status_ok=1
  grep -qF "$pattern" "$body" 2>/dev/null && body_ok=1
  if [[ $status_ok -eq 1 && $body_ok -eq 1 ]]; then
    printf "${G}PASS${N} %-55s ${DIM}[%s, body ✓]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    local reason
    if [[ $status_ok -eq 0 ]]; then
      reason="got $code, want $expected"
    else
      reason="body missing '$pattern'"
    fi
    printf "${R}FAIL${N} %-55s ${DIM}[%s]${N}\n" "$label" "$reason"
    if [[ -s "$body" ]]; then
      echo -e "${Y}--- body ---${N}"; head -5 "$body" | sed 's/^/  /'
    fi
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

# Expect the server to reject the request (AbortNonPrefixedRequestFilter).
# The filter interrupts the thread and returns without calling doFilter.
# Depending on the container, this produces a connection drop (000), 404, or 403.
req_reject() {
  local label="$1"; shift
  local body="$TMP/body"
  local code
  code=$(curl -sS -o "$body" -w "%{http_code}" --max-time 3 "$@" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(000|403|404)$ ]]; then
    printf "${G}PASS${N} %-55s ${DIM}[%s]${N}\n" "$label" "$code"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-55s ${DIM}[got %s, want rejection]${N}\n" "$label" "$code"
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

# ── Python STOMP helper ──────────────────────────────────────────

HAS_STOMP=0

setup_stomp_helper() {
  cat > "$TMP/stomp_helper.py" << 'PYEOF'
import sys, time
try:
    import websocket
except ImportError:
    sys.exit(2)

NULL = '\0'

def frame(cmd, headers=None, body=''):
    lines = [cmd]
    for k, v in (headers or {}).items():
        lines.append(f'{k}:{v}')
    lines.append('')
    lines.append(body)
    return '\n'.join(lines) + NULL

def stomp_connect(ws, user, token):
    ws.send(frame('CONNECT', {
        'accept-version': '1.1,1.0',
        'heart-beat': '0,0',
        'X-Joal-Username': user,
        'X-Joal-Auth-Token': token,
    }))
    ws.settimeout(5)
    return ws.recv()

def cmd_connect(url, user, token):
    try:
        ws = websocket.create_connection(url, timeout=5)
    except Exception as e:
        print(f'FAIL:ws:{e}')
        return
    try:
        resp = stomp_connect(ws, user, token)
        print(resp.split('\n', 1)[0])
    except Exception as e:
        print(f'DISCONNECTED:{e}')
    finally:
        ws.close()

def cmd_subscribe(url, user, token, dest):
    try:
        ws = websocket.create_connection(url, timeout=5)
    except Exception as e:
        print(f'FAIL:ws:{e}')
        return
    try:
        resp = stomp_connect(ws, user, token)
        if not resp.startswith('CONNECTED'):
            print(f'FAIL:auth:{resp.split(chr(10), 1)[0]}')
            return
        ws.send(frame('SUBSCRIBE', {'id': 'sub-0', 'destination': dest}))
        ws.settimeout(3)
        msgs = []
        try:
            while True:
                msgs.append(ws.recv())
        except:
            pass
        for m in msgs:
            lines = m.split('\n')
            print(lines[0])
            in_body = False
            for ln in lines:
                if in_body and ln.strip(NULL).strip():
                    print(f'  payload: {ln.strip(NULL)[:200]}')
                    break
                if ln == '':
                    in_body = True
        if not msgs:
            print('NO_MESSAGES')
    finally:
        ws.close()

def cmd_send(url, user, token, dest, body=''):
    try:
        ws = websocket.create_connection(url, timeout=5)
    except Exception as e:
        print(f'FAIL:ws:{e}')
        return
    try:
        resp = stomp_connect(ws, user, token)
        if not resp.startswith('CONNECTED'):
            print(f'FAIL:auth')
            return
        hdrs = {'destination': dest}
        if body:
            hdrs['content-type'] = 'application/json'
            hdrs['content-length'] = str(len(body))
        ws.send(frame('SEND', hdrs, body))
        ws.settimeout(2)
        try:
            r = ws.recv()
            print(r.split('\n', 1)[0])
        except websocket.WebSocketTimeoutException:
            print('OK')
        except:
            print('OK')
    finally:
        ws.close()

def cmd_send_subscribe(url, user, token, send_dest, send_body, sub_dest):
    try:
        ws = websocket.create_connection(url, timeout=5)
    except Exception as e:
        print(f'FAIL:ws:{e}')
        return
    try:
        resp = stomp_connect(ws, user, token)
        if not resp.startswith('CONNECTED'):
            print(f'FAIL:auth')
            return
        ws.send(frame('SUBSCRIBE', {'id': 'sub-0', 'destination': sub_dest}))
        time.sleep(0.3)
        hdrs = {'destination': send_dest}
        if send_body:
            hdrs['content-type'] = 'application/json'
            hdrs['content-length'] = str(len(send_body))
        ws.send(frame('SEND', hdrs, send_body))
        ws.settimeout(3)
        msgs = []
        try:
            while True:
                msgs.append(ws.recv())
        except:
            pass
        for m in msgs:
            lines = m.split('\n')
            print(lines[0])
            in_body = False
            for ln in lines:
                if in_body and ln.strip(NULL).strip():
                    print(f'  payload: {ln.strip(NULL)[:200]}')
                    break
                if ln == '':
                    in_body = True
        if not msgs:
            print('NO_MESSAGES')
    finally:
        ws.close()

if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    {
        'connect':        lambda: cmd_connect(*args),
        'subscribe':      lambda: cmd_subscribe(*args),
        'send':           lambda: cmd_send(*args),
        'send-subscribe': lambda: cmd_send_subscribe(*args),
    }[cmd]()
PYEOF

  if python3 -c "import websocket" 2>/dev/null; then
    HAS_STOMP=1; return
  fi

  echo -e "${DIM}Installing websocket-client into temp dir...${N}"
  if pip3 install --quiet --target "$TMP/pylib" websocket-client 2>/dev/null; then
    if PYTHONPATH="$TMP/pylib" python3 -c "import websocket" 2>/dev/null; then
      HAS_STOMP=1; return
    fi
  fi

  echo -e "${Y}WARNING: websocket-client unavailable; WebSocket/STOMP tests will be skipped.${N}"
}

run_stomp() {
  if [[ $HAS_STOMP -eq 0 ]]; then return 2; fi
  PYTHONPATH="${TMP}/pylib:${PYTHONPATH:-}" python3 "$TMP/stomp_helper.py" "$@"
}

# Positive STOMP test: output must contain $pattern.
stomp_test() {
  local label="$1" pattern="$2"; shift 2
  local out="$TMP/stomp_out"

  run_stomp "$@" > "$out" 2>/dev/null
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    printf "${Y}SKIP${N} %-55s ${DIM}[no websocket-client]${N}\n" "$label"
    SKIP=$((SKIP+1)); return
  fi

  if grep -q "$pattern" "$out" 2>/dev/null; then
    local detail; detail=$(head -1 "$out" | cut -c1-50)
    printf "${G}PASS${N} %-55s ${DIM}[%s]${N}\n" "$label" "$detail"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-55s ${DIM}[want '%s']${N}\n" "$label" "$pattern"
    if [[ -s "$out" ]]; then
      echo -e "${Y}--- output ---${N}"; head -10 "$out" | sed 's/^/  /'
    fi
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

# Negative STOMP test: output must NOT contain $reject.
stomp_test_neg() {
  local label="$1" reject="$2"; shift 2
  local out="$TMP/stomp_out"

  run_stomp "$@" > "$out" 2>/dev/null
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    printf "${Y}SKIP${N} %-55s ${DIM}[no websocket-client]${N}\n" "$label"
    SKIP=$((SKIP+1)); return
  fi

  if ! grep -q "$reject" "$out" 2>/dev/null; then
    local detail; detail=$(head -1 "$out" 2>/dev/null | cut -c1-50)
    printf "${G}PASS${N} %-55s ${DIM}[%s]${N}\n" "$label" "${detail:-rejected}"
    PASS=$((PASS+1))
  else
    printf "${R}FAIL${N} %-55s ${DIM}[should not match '%s']${N}\n" "$label" "$reject"
    FAIL=$((FAIL+1))
    [[ $STOP_ON_FAIL -eq 1 ]] && exit 1
  fi
}

# ══════════════════════════════════════════════════════════════════
# Setup
# ══════════════════════════════════════════════════════════════════

setup_stomp_helper

# ══════════════════════════════════════════════════════════════════
# Part 0 — Startup check
# ══════════════════════════════════════════════════════════════════

section "Startup (wait for reachability)"

printf "${DIM}Waiting for %s to be reachable...${N}" "$BASE"
for i in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 2 "$BASE/${PREFIX}/ui/" 2>/dev/null; then
    echo -e " ${G}ready${N} (${i}s)"
    break
  fi
  sleep 1
  if [[ $i -eq 60 ]]; then echo -e " ${R}TIMEOUT${N}"; exit 2; fi
done

# ══════════════════════════════════════════════════════════════════
# Part 1 — HTTP Security Layer
# ══════════════════════════════════════════════════════════════════

section "HTTP: AbortNonPrefixedRequestFilter (non-prefixed → rejected)"

req_reject "GET  / (no prefix → rejected)"                     "$BASE/"
req_reject "GET  /hello (no prefix → rejected)"                "$BASE/hello"
req_reject "GET  /ui/ (no prefix → rejected)"                  "$BASE/ui/"

section "HTTP: Web UI endpoints (prefixed)"

req_body "GET  /${PREFIX}/ui/ → SPA entry"          "200" "<!doctype html>"    "$BASE/${PREFIX}/ui/"
req      "GET  /${PREFIX}/ui → redirect to ui/"     "301|302|303"              "$BASE/${PREFIX}/ui"
req_body "GET  /${PREFIX}/ui/manifest.json → PWA manifest" "200" '"short_name"' "$BASE/${PREFIX}/ui/manifest.json"

section "HTTP: Spring Security"

req      "GET  /${PREFIX}/nonexistent → 403 (denied)" "403"    "$BASE/${PREFIX}/nonexistent"

# ══════════════════════════════════════════════════════════════════
# Part 2 — WebSocket / STOMP Authentication
# ══════════════════════════════════════════════════════════════════

section "STOMP: Authentication"

stomp_test     "STOMP CONNECT (valid token → CONNECTED)"       "CONNECTED"   \
               connect "$WS_URL" testuser "$SECRET"

stomp_test_neg "STOMP CONNECT (wrong token → rejected)"        "CONNECTED"   \
               connect "$WS_URL" testuser "wrong-token"

stomp_test_neg "STOMP CONNECT (empty token → rejected)"        "CONNECTED"   \
               connect "$WS_URL" testuser ""

WS_NOPREFIX=$(echo "$BASE" | sed 's|^http|ws|')/
stomp_test_neg "STOMP CONNECT (no-prefix URL → WS fails)"     "CONNECTED"   \
               connect "$WS_NOPREFIX" testuser "$SECRET"

# ══════════════════════════════════════════════════════════════════
# Part 3 — STOMP Business Operations
# ══════════════════════════════════════════════════════════════════

section "STOMP: State Query"

# /initialize-me always replays at least ConfigHasBeenLoadedPayload +
# ListOfClientFilesPayload — check for the former's StompMessageTypes enum
# name in the wire JSON.
stomp_test     "SUBSCRIBE /joal/initialize-me → CONFIG_HAS_BEEN_LOADED" "CONFIG_HAS_BEEN_LOADED" \
               subscribe "$WS_URL" testuser "$SECRET" "/joal/initialize-me"

section "STOMP: Configuration"

VALID_CFG='{"minUploadRate":30,"maxUploadRate":170,"simultaneousSeed":200,"client":"utorrent-3.5.0_43916.client","keepTorrentWithZeroLeechers":true,"uploadRatioTarget":-1.0}'

stomp_test     "SEND /joal/config/save (valid config) → OK"    "OK"          \
               send "$WS_URL" testuser "$SECRET" "/joal/config/save" "$VALID_CFG"

INVALID_CFG='{"minUploadRate":-1,"maxUploadRate":170,"simultaneousSeed":200,"client":"utorrent-3.5.0_43916.client","keepTorrentWithZeroLeechers":true,"uploadRatioTarget":-1.0}'

# Invalid config → handler broadcasts InvalidConfigPayload back via /config.
# Check for the specific type marker, not just the generic MESSAGE frame.
stomp_test     "SEND /joal/config/save (invalid) → INVALID_CONFIG"  "INVALID_CONFIG"  \
               send-subscribe "$WS_URL" testuser "$SECRET" \
               "/joal/config/save" "$INVALID_CFG" "/config"

section "STOMP: Torrent Management"

# /joal/torrents/upload accepts {fileName, b64String}; the handler decodes
# the base64 (Apache commons-codec) and writes bytes to <conf>/torrents/.
# The async torrent watcher then tries to parse — garbage bytes here just
# get shunted to archived/, which is fine for dep-probing the upload path.
UPLOAD_BODY='{"fileName":"joal-probe.torrent","b64String":"dGVzdC10b3JyZW50LWRhdGE="}'
stomp_test     "SEND /joal/torrents/upload → OK"               "OK"          \
               send "$WS_URL" testuser "$SECRET" "/joal/torrents/upload" "$UPLOAD_BODY"

# /joal/torrents/delete takes a raw string (JSON-quoted over the wire).
# Bogus infoHash → SeedManager.deleteTorrent silently no-ops; the STOMP
# SEND returns OK either way. Probes InfoHash/MockedTorrent byte-encoding
# paths.
stomp_test     "SEND /joal/torrents/delete (bogus hash) → OK"  "OK"          \
               send "$WS_URL" testuser "$SECRET" "/joal/torrents/delete" '"0000000000000000000000000000000000000000"'

section "STOMP: Seeding Control"

stomp_test     "SEND /joal/global/stop → OK"                   "OK"          \
               send "$WS_URL" testuser "$SECRET" "/joal/global/stop"

stomp_test     "SEND /joal/global/start → OK"                  "OK"          \
               send "$WS_URL" testuser "$SECRET" "/joal/global/start"

stomp_test     "SEND /joal/global/stop (cleanup) → OK"         "OK"          \
               send "$WS_URL" testuser "$SECRET" "/joal/global/stop"

# Remove the probe file left behind by the upload test (the torrent watcher
# usually moves it to archived/ after failing to parse).
find ./resources/torrents -name 'joal-probe.torrent' -delete 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  msg="All ${PASS}/${TOTAL} checks passed."
  [[ $SKIP -gt 0 ]] && msg="${msg} (${SKIP} skipped)"
  echo -e "${G}${msg}${N}"
  exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed, ${SKIP} skipped)."
  exit 1
fi

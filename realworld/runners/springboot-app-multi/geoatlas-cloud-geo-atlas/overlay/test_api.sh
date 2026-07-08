#!/usr/bin/env bash
# geoatlas tile API — smoke test
set -u

BASE="${BASE:-http://localhost:11002}"
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

# Common envelope substring — every response gets wrapped by ResponseWrapperAdvice.
ENV_OK='"success":true
"status":200
"message":"success"
"timestamp":'

# ------------------------------------------------------------------
section "Health"
# HealthCheckEndpoint returns the literal string "OK" wrapped by the advice.
req_fields "GET  /v1/health/check"                       "200" \
"$ENV_OK
\"data\":\"OK\"" \
         "$BASE/v1/health/check"

# ------------------------------------------------------------------
section "Dashboard — counts and layer activity"
# DashboardEndpoint /count: aggregates from 4 metadata tables. With no
# user-defined data yet, only spatialReferenceCount is non-zero (8500+
# pre-seeded EPSG codes ship with the postgres image).
req_fields "GET  /v1/dashboard/count"                    "200" \
"$ENV_OK
\"namespaceCount\":0
\"dataStoreCount\":0
\"layerCount\":0
\"spatialReferenceCount\":" \
         "$BASE/v1/dashboard/count"
# Recent / active layers — both empty for fresh DB; envelope still shaped.
req_fields "GET  /v1/dashboard/layers/recent"            "200" \
"$ENV_OK
\"data\":[]" \
         "$BASE/v1/dashboard/layers/recent"
req_fields "GET  /v1/dashboard/layers/active"            "200" \
"$ENV_OK
\"data\":[]" \
         "$BASE/v1/dashboard/layers/active"

# ------------------------------------------------------------------
section "Metadata — namespaces / datastores / feature_layers (CRUD list/page)"
# Each metadata controller exposes /list (flat) + /page (paged). Empty
# result still proves the controller, JPA repository, and pagination
# wrapper all work end-to-end against PostGIS.
req_fields "GET  /v1/metadata/namespaces/list"           "200" \
"$ENV_OK
\"data\":[]" \
         "$BASE/v1/metadata/namespaces/list"
req_fields "GET  /v1/metadata/namespaces/page (paged shape)"  "200" \
"$ENV_OK
\"content\":[]
\"number\":0
\"size\":
\"totalElements\":0
\"totalPages\":0" \
         "$BASE/v1/metadata/namespaces/page"
req_fields "GET  /v1/metadata/datastores/list"           "200" \
"$ENV_OK
\"data\":[]" \
         "$BASE/v1/metadata/datastores/list"
req_fields "GET  /v1/metadata/datastores/page (paged shape)"  "200" \
"$ENV_OK
\"content\":[]
\"totalElements\":0" \
         "$BASE/v1/metadata/datastores/page"
req_fields "GET  /v1/metadata/feature_layers/page (paged shape)"  "200" \
"$ENV_OK
\"content\":[]
\"totalElements\":0" \
         "$BASE/v1/metadata/feature_layers/page"

# ------------------------------------------------------------------
section "Spatial references — pre-seeded EPSG catalog"
# SpatialReferenceInfoEndpoint /page: backed by the spatial_refs table that
# ships populated in the postgres image. EPSG:2001 is the lowest-id row
# always present + each row has srid/authName/authSrid/wktText.
req_fields "GET  /v1/metadata/spatial_refs/page (real seeded data)"  "200" \
"$ENV_OK
\"content\":[
\"name\":\"EPSG:2001\"
\"srid\":2001
\"authName\":\"EPSG\"
\"wktText\":\"PROJCS[" \
         "$BASE/v1/metadata/spatial_refs/page"

# ------------------------------------------------------------------
section "Virtual threads — JVM introspection + demo"
# VirtualThreadStatusEndpoint /virtual-thread-status: confirms the request
# is being served on a virtual thread (Spring Boot 3.5 + Java 21 default).
req_fields "GET  /api/system/virtual-thread-status"      "200" \
"$ENV_OK
\"isVirtual\":true
\"virtualThreadSupported\":true
\"javaVersion\":\"21
\"springVirtualThreadEnabled\":\"true\"" \
         "$BASE/api/system/virtual-thread-status"
# VirtualThreadDemoEndpoint /quick-demo: spawns 5 simulated tile-generation
# tasks on virtual threads, returns a Chinese summary string.
req_fields "GET  /v1/demo/virtual-threads/quick-demo"    "200" \
"$ENV_OK
\"data\":
处理了 5 个瓦片请求
瓦片生成完成: tile-005" \
         "$BASE/v1/demo/virtual-threads/quick-demo"
req "GET  /v1/demo/virtual-threads/comparison"           "200" \
    "$BASE/v1/demo/virtual-threads/comparison"
# VirtualThreadStatusEndpoint test endpoints — fire a virtual thread and
# return timing info. test-virtual-thread is single-task, the -concurrent
# variant runs 100 tasks and reports averageTimePerTask.
req_fields "GET  /api/system/test-virtual-thread"        "200" \
"$ENV_OK
\"isVirtual\":true
\"executionTime\":
\"threadId\":" \
         "$BASE/api/system/test-virtual-thread"
req_fields "GET  /api/system/test-virtual-thread-concurrent (100 tasks)" "200" \
"$ENV_OK
\"taskCount\":100
\"averageTimePerTask\":
\"executionTimeMs\":" \
         "$BASE/api/system/test-virtual-thread-concurrent"
# Three more demo endpoints — exercise different virtual-thread patterns.
req_fields "GET  /v1/demo/virtual-threads/performance/test (1000 tasks)"  "200" \
"$ENV_OK
性能测试完成" \
         "$BASE/v1/demo/virtual-threads/performance/test"
req_fields "GET  /v1/demo/virtual-threads/data/pipeline/{id}"  "200" \
"$ENV_OK
处理完成
数据内容-pipe42" \
         "$BASE/v1/demo/virtual-threads/data/pipeline/pipe42"
req_fields "GET  /v1/demo/virtual-threads/tiles/async/{id}"    "200" \
"$ENV_OK
异步瓦片生成完成: tile99" \
         "$BASE/v1/demo/virtual-threads/tiles/async/tile99"
# POST variants — body is a JSON string array; each entry processed in a
# virtual thread + collated. Two distinct POSTs in the demo controller.
req_fields "POST /v1/demo/virtual-threads/tiles/batch"   "200" \
"$ENV_OK
瓦片生成完成: t1
瓦片生成完成: t2" \
         -X POST -H 'Content-Type: application/json' -d '["t1","t2"]' \
         "$BASE/v1/demo/virtual-threads/tiles/batch"
req_fields "POST /v1/demo/virtual-threads/api/aggregate"  "200" \
"$ENV_OK
API响应-src1
API响应-src2" \
         -X POST -H 'Content-Type: application/json' -d '["src1","src2","src3"]' \
         "$BASE/v1/demo/virtual-threads/api/aggregate"

# ------------------------------------------------------------------
section "Real business chain — namespace → datastore → feature_layer → tile"
# This is the project's actual purpose: serve Mapbox Vector Tiles from a
# PostGIS table. The chain below configures one layer end-to-end and then
# fetches a real tile (1 MB PBF) covering eastern China.
#
# Random suffix per run so re-running doesn't trip uniqueness constraints.
SUF="${SUF:-$RANDOM$RANDOM}"
NS_NAME="cn_${SUF}"
DS_NAME="weather_db_${SUF}"
LAYER_NAME="provinces_${SUF}"

# 1. Namespace — pure logical grouping. POST controller returns
#    ResponseEntity.ok().build() — empty body — so only status is asserted.
#    Then look up the assigned id via /list. EPSG:4326 is spatial_ref id 2150.
req      "POST /v1/metadata/namespaces (create '$NS_NAME')"  "200" \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"name\":\"${NS_NAME}\",\"uri\":\"http://example.com/${NS_NAME}\",\"description\":\"chain test\"}" \
         "$BASE/v1/metadata/namespaces"
NS_ID=$(curl -sS "$BASE/v1/metadata/namespaces/list" \
        | python3 -c "import sys,json
for n in json.load(sys.stdin)['data']:
    if n.get('name')=='${NS_NAME}': print(n['id']); break")

# 2. DataStore — JDBC connection config to the postgis sidecar. Plaintext
#    password is fine here (controller has FIXME: 目前密码使用明文传递).
req      "POST /v1/metadata/datastores (postgis -> micro_weather_db_v100)" "200" \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"namespaceId\":${NS_ID},\"name\":\"${DS_NAME}\",\"type\":\"postgis\",\"host\":\"geospatial-data-source\",\"port\":\"5432\",\"schema\":\"public\",\"database\":\"micro_weather_db_v100\",\"user\":\"postgres\",\"password\":\"postgres123\"}" \
         "$BASE/v1/metadata/datastores"
DS_ID=$(curl -sS "$BASE/v1/metadata/datastores/list" \
        | python3 -c "import sys,json
for n in json.load(sys.stdin)['data']:
    if n.get('name')=='${DS_NAME}': print(n['id']); break")

# 3. FeatureLayer — declares: which SQL view to publish, primary key column,
#    geometry column + type (3=Polygon — the closest type for MULTIPOLYGON,
#    see FeatureLayerInfoManagement#324: 1=Point, 2=Line, 3=Polygon, else
#    binds Geometry.class), source SRID, declared bbox.
req      "POST /v1/metadata/feature_layers (admin_division -> provinces)" "200" \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"name\":\"${LAYER_NAME}\",\"namespaceId\":${NS_ID},\"datastoreId\":${DS_ID},\"spatialReferenceId\":2150,\"description\":\"chain test\",\"view\":{\"name\":\"view_${SUF}\",\"sql\":\"SELECT id, name, bounds FROM administrative_division\",\"pkColumns\":\"id\",\"geometryColumn\":\"bounds\",\"geometryType\":3,\"srid\":4326},\"bbox\":{\"minx\":73.0,\"miny\":3.0,\"maxx\":135.0,\"maxy\":54.0,\"natived\":true}}" \
         "$BASE/v1/metadata/feature_layers"

# 4. Verify the layer is wired up — /page should now contain it with the
#    SpatialReferenceInfo joined in.
req_fields "GET  /v1/metadata/feature_layers/page (layer registered)" "200" \
"$ENV_OK
\"name\":\"${LAYER_NAME}\"
\"spatialReferenceInfo\":
\"srid\":4326
\"authName\":\"EPSG\"" \
         "$BASE/v1/metadata/feature_layers/page"

# Look up auto-assigned ids for the GET-by-id round-trip + PUT updates below.
LAYER_ID=$(curl -sS "$BASE/v1/metadata/feature_layers/page" \
           | python3 -c "import sys,json
for n in json.load(sys.stdin)['data']['content']:
    if n.get('name')=='${LAYER_NAME}': print(n['id']); break")

# 4a. CRUD round-trip — GET each just-created entity by its assigned id.
req_fields "GET  /v1/metadata/namespaces/{id}"           "200" \
"$ENV_OK
\"id\":${NS_ID}
\"name\":\"${NS_NAME}\"
\"uri\":\"http://example.com/${NS_NAME}\"" \
         "$BASE/v1/metadata/namespaces/${NS_ID}"
req_fields "GET  /v1/metadata/datastores/{id}"           "200" \
"$ENV_OK
\"id\":${DS_ID}
\"namespaceId\":${NS_ID}
\"name\":\"${DS_NAME}\"
\"type\":\"postgis\"
\"database\":\"micro_weather_db_v100\"" \
         "$BASE/v1/metadata/datastores/${DS_ID}"
req_fields "GET  /v1/metadata/feature_layers/{id}"       "200" \
"$ENV_OK
\"id\":${LAYER_ID}
\"name\":\"${LAYER_NAME}\"
\"namespaceId\":${NS_ID}
\"datastoreId\":${DS_ID}
\"view\":
\"geometryColumn\":\"bounds\"" \
         "$BASE/v1/metadata/feature_layers/${LAYER_ID}"
# Reverse lookup — given a feature_layer id, find its parent namespace.
# (Different join direction from /v1/metadata/namespaces/{id}.)
req_fields "GET  /v1/metadata/namespaces/feature_layers/{layer_id} (reverse join)" "200" \
"$ENV_OK
\"id\":${NS_ID}
\"name\":\"${NS_NAME}\"" \
         "$BASE/v1/metadata/namespaces/feature_layers/${LAYER_ID}"
# /preview — separate DTO with center{x,y} + bbox snapshot. Used by the
# dashboard frontend to render a layer's footprint without fetching tiles.
req_fields "GET  /v1/metadata/feature_layers/preview/{id}"  "200" \
"$ENV_OK
\"id\":${LAYER_ID}
\"name\":\"${LAYER_NAME}\"
\"namespace\":\"${NS_NAME}\"
\"bbox\":
\"center\":" \
         "$BASE/v1/metadata/feature_layers/preview/${LAYER_ID}"
# Spatial reference read-by-id (id 2150 is EPSG:4326 — pre-seeded).
req_fields "GET  /v1/metadata/spatial_refs/{id}  (EPSG:4326)" "200" \
"$ENV_OK
\"id\":2150
\"name\":\"EPSG:4326\"
\"srid\":4326
\"authName\":\"EPSG\"" \
         "$BASE/v1/metadata/spatial_refs/2150"

# 4b. PUT updates — exercise the mutation path on each metadata entity.
# Body shape == the full POST body + id field (replace-style PUT).
req      "PUT  /v1/metadata/namespaces (update description)" "200" \
         -X PUT -H 'Content-Type: application/json' \
         -d "{\"id\":${NS_ID},\"name\":\"${NS_NAME}\",\"uri\":\"http://example.com/${NS_NAME}\",\"description\":\"updated\"}" \
         "$BASE/v1/metadata/namespaces"
req      "PUT  /v1/metadata/datastores (update fetchSize)"  "200" \
         -X PUT -H 'Content-Type: application/json' \
         -d "{\"id\":${DS_ID},\"namespaceId\":${NS_ID},\"name\":\"${DS_NAME}\",\"type\":\"postgis\",\"host\":\"geospatial-data-source\",\"port\":\"5432\",\"schema\":\"public\",\"database\":\"micro_weather_db_v100\",\"user\":\"postgres\",\"password\":\"postgres123\",\"fetchSize\":100}" \
         "$BASE/v1/metadata/datastores"
# Verify the PUT actually persisted: re-read namespace, expect new description.
req_fields "GET  /v1/metadata/namespaces/{id} (after PUT)"  "200" \
"$ENV_OK
\"description\":\"updated\"" \
         "$BASE/v1/metadata/namespaces/${NS_ID}"

# 4c. Bean Validation + RestExceptionHandler catch-all
# PUT namespace uses @Valid — blank name triggers MethodArgumentNotValidException
# → caught by RestExceptionHandler(@ExceptionHandler(Exception.class)) → 500,
# or Spring default → 400. Either path exercises the reflection chain.
req "PUT  /v1/metadata/namespaces (blank name → 400|500)"  "400|500" \
    -X PUT -H 'Content-Type: application/json' \
    -d "{\"id\":${NS_ID},\"name\":\"\",\"uri\":\"http://example.com\"}" \
    "$BASE/v1/metadata/namespaces"
# PUT with non-existent ID → RuntimeException("NamespaceInfo not found")
# → RestExceptionHandler catch-all → 500 with error envelope.
req_fields "PUT  /v1/metadata/namespaces (bogus id → 500)"  "500" \
"\"success\":false
\"message\":\"NamespaceInfo not found\"" \
    -X PUT -H 'Content-Type: application/json' \
    -d '{"id":999999,"name":"x","uri":"http://example.com"}' \
    "$BASE/v1/metadata/namespaces"

# 5. *** THE CORE BUSINESS ENDPOINT *** — fetch a Mapbox Vector Tile in
#    EPSG:3857 web-mercator at zoom=4 row=6 col=13. That tile covers eastern
#    China and is non-empty (~1 MB of pbf). Two assertions:
#      (a) HTTP 200
#      (b) Content-Type is application/vnd.mapbox-vector-tile (NOT json/xml)
#      (c) Body is non-empty binary (Content-Length > 0)
TILE_OUT="$TMP/tile.pbf"
HDR_OUT="$TMP/tile.hdr"
TILE_CODE=$(curl -sS -D "$HDR_OUT" -o "$TILE_OUT" -w '%{http_code}' \
            "$BASE/v1/tiles/${NS_NAME}/${LAYER_NAME}/EPSG:3857/4/6/13.pbf")
TILE_TYPE=$(grep -i '^Content-Type:' "$HDR_OUT" | tr -d '\r' | head -1)
TILE_SIZE=$(stat -f '%z' "$TILE_OUT" 2>/dev/null || stat -c '%s' "$TILE_OUT" 2>/dev/null || echo 0)
if [[ "$TILE_CODE" == "200" && "$TILE_TYPE" == *'application/vnd.mapbox-vector-tile'* && "$TILE_SIZE" -gt 1000 ]]; then
  printf "${G}PASS${N} %-58s ${DIM}[200, MVT, %s bytes ✓]${N}\n" \
    "GET  /v1/tiles/.../EPSG:3857/4/6/13.pbf  (REAL MVT)" "$TILE_SIZE"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-58s ${DIM}[code=%s, type=%s, size=%s]${N}\n" \
    "GET  /v1/tiles/.../EPSG:3857/4/6/13.pbf" "$TILE_CODE" "${TILE_TYPE:-none}" "$TILE_SIZE"
  FAIL=$((FAIL+1))
fi

# 6. Sync variant — same path mounted under /sync/, exercises the
#    non-CompletableFuture branch in TileEndpoint#getTileSync.
TILE2_CODE=$(curl -sS -o "$TILE_OUT" -w '%{http_code}' \
             "$BASE/v1/tiles/sync/${NS_NAME}/${LAYER_NAME}/EPSG:3857/4/6/13.pbf")
TILE2_SIZE=$(stat -f '%z' "$TILE_OUT" 2>/dev/null || stat -c '%s' "$TILE_OUT" 2>/dev/null || echo 0)
if [[ "$TILE2_CODE" == "200" && "$TILE2_SIZE" -gt 1000 ]]; then
  printf "${G}PASS${N} %-58s ${DIM}[200, %s bytes ✓]${N}\n" \
    "GET  /v1/tiles/sync/.../EPSG:3857/4/6/13.pbf" "$TILE2_SIZE"
  PASS=$((PASS+1))
else
  printf "${R}FAIL${N} %-58s ${DIM}[code=%s, size=%s]${N}\n" \
    "GET  /v1/tiles/sync/.../EPSG:3857/4/6/13.pbf" "$TILE2_CODE" "$TILE2_SIZE"
  FAIL=$((FAIL+1))
fi

# 7. Cleanup — delete in reverse dependency order so reruns stay clean.
[[ -n "$LAYER_ID" ]] && curl -sS -o /dev/null -X DELETE "$BASE/v1/metadata/feature_layers/${LAYER_ID}"
[[ -n "$DS_ID" ]] && curl -sS -o /dev/null -X DELETE "$BASE/v1/metadata/datastores/${DS_ID}"
[[ -n "$NS_ID" ]] && curl -sS -o /dev/null -X DELETE "$BASE/v1/metadata/namespaces/${NS_ID}"
echo -e "${DIM}cleanup: deleted layer=${LAYER_ID} datastore=${DS_ID} namespace=${NS_ID}${N}"

# ------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${G}All ${PASS}/${TOTAL} checks passed.${N}"; exit 0
else
  echo -e "${R}${FAIL}/${TOTAL} checks failed${N} (${PASS} passed)."; exit 1
fi

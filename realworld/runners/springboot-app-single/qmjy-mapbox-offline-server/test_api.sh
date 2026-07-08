#!/usr/bin/env bash
# qmjy-mapbox-offline-server — smoke test

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
    s=$(code "$BASE/" || echo 000)
    [[ "$s" == "200" ]] && break
    sleep 2
done
echo "    /=$s"
[[ "$s" != "200" ]] && { echo "boot failed"; exit 1; }

echo
echo "==> Thymeleaf web pages (200)"
check "GET /"                                              "200" "$(code "$BASE/")"
check "GET /tilesets.html"                                 "200" "$(code "$BASE/tilesets.html")"

echo
echo "==> springdoc / swagger (200)"
check "GET /v3/api-docs"                                   "200" "$(code "$BASE/v3/api-docs")"
check "GET /swagger-ui/index.html"                         "200" "$(code "$BASE/swagger-ui/index.html")"

echo
echo "==> Filesystem-scan listings (200) — distinct controllers"
check "GET /api/tilesets"                                  "200" "$(code "$BASE/api/tilesets")"
check "GET /api/fonts"                                     "200" "$(code "$BASE/api/fonts")"
check "GET /api/geo/admins (OSMB seeded)"                  "200" "$(code "$BASE/api/geo/admins")"
check "GET /api/geo/admins/nodes/1 (StubLand)"             "200" "$(code "$BASE/api/geo/admins/nodes/1")"

echo
echo "==> mbtiles success path (sqlite-jdbc + mapbox-vector-tile)"
# The mbtiles branch is selected only when {tileset} ends in .mbtiles.
check "GET /api/tilesets/stub.mbtiles/metadata"            "200" "$(code "$BASE/api/tilesets/stub.mbtiles/metadata")"
check "GET /api/tilesets/stub.mbtiles/tiles.json"          "200" "$(code "$BASE/api/tilesets/stub.mbtiles/tiles.json")"
check "GET /api/tilesets/stub.mbtiles/0/0/0.pbf (real tile)" "200" "$(code "$BASE/api/tilesets/stub.mbtiles/0/0/0.pbf")"
# DELETE returns 200 even for non-existent (idempotent). Different verb path.
check "DELETE /api/tilesets/none"                          "200" "$(code -X DELETE "$BASE/api/tilesets/none")"

echo
echo "==> Static map assets (200) — sprite/style file reads"
check "GET /api/sprites/streets/sprite.json"               "200" "$(code "$BASE/api/sprites/streets/sprite.json")"
check "GET /api/sprites/streets/sprite.png"                "200" "$(code "$BASE/api/sprites/streets/sprite.png")"
# {styleName} path var is the raw filename; .json must appear in the URL.
check "GET /api/styles/world.json"                         "200" "$(code "$BASE/api/styles/world.json")"

echo
echo "==> Distinct dep paths added in second pass"
# gt-referencing: real Position2D coordinate transform.
GEOREF_BODY='{"width":1920,"height":1080,"geometryPoints":"0,0;1,0;1,1;0,1","pixelPoints":"100,100;200,200"}'
check "POST /api/georeferencer (gt-referencing transform)"   "200" \
    "$(code -X POST -H 'Content-Type: application/json' -d "$GEOREF_BODY" "$BASE/api/georeferencer")"
# sqlite-jdbc INSERT path via async merge (target name must NOT exist yet).
# We pass a unique target each run so the merge isn't pre-empted by 'already exists'.
MERGE_BODY=$(printf '{"sourceNames":"stub.mbtiles","targetName":"merged-%s.mbtiles"}' "$RANDOM")
check "POST /api/tilesets/merge (async sqlite-jdbc INSERT)"  "200" \
    "$(code -X POST -H 'Content-Type: application/json' -d "$MERGE_BODY" "$BASE/api/tilesets/merge")"
# Geometry.covers() called with multiple test points; needs an OSMB seed.
check "GET /admins/nodes/1/contains (Geometry.covers true)"  "200" \
    "$(code "$BASE/api/geo/admins/nodes/1/contains?locations=0.5,0.5")"
# Fonts file fetch via boot-time fontsMap. Stub /data/fonts/Stub/0-255.pbf exists.
check "GET /api/fonts/Stub/0-255.pbf (stub file)"            "200" \
    "$(code "$BASE/api/fonts/Stub/0-255.pbf")"
# Route handler -- no .osm.pbf seeded, so hopperMap.get() returns null and the
# project's own "not ready" envelope (code=10001) is returned. Status is 200
# from ResponseMapUtil.nok; the envelope is project-defined. Touches the
# graphhopper-core types via the Map<String, GraphHopper> field reference.
check "GET /api/route/none?... (graphhopper not-ready env)"  "200" \
    "$(code "$BASE/api/route/none?startLongitude=104&startLatitude=30&endLongitude=105&endLatitude=31")"

echo
echo "==> POI / geocode happy paths (correct param names)"
# Both endpoints return 200 with an empty-result envelope when no data file
# matches; the controller code path runs regardless.
check "GET /api/poi?keywords=cafe"                         "200" "$(code "$BASE/api/poi?keywords=cafe")"
check "GET /api/geocode/regeo?location=0.5,0.5 (in Stub)"  "200" "$(code "$BASE/api/geocode/regeo?location=0.5,0.5")"

# NOTE: dropped three Spring-framework-default error tests that originally
# returned 405 / 415 / 404. None of these are *project*-defined states -- the
# project has no @ExceptionHandler / @ControllerAdvice and the responses come
# straight out of spring-webmvc's default error machinery. Per the
# representative-sampling rule we only assert states the project itself
# defines (here: 200 + project-internal error envelopes returned via
# ResponseEntity.badRequest() / ResponseMapUtil.notFound() that wrap as 200).

echo
echo "==> Summary: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

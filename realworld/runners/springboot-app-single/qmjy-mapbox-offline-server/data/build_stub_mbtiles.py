#!/usr/bin/env python3
"""Build a minimal valid .mbtiles for stub.mbtiles in /data/tilesets/.

mbtiles is sqlite3 with `metadata(name,value)` + `tiles(zoom_level, tile_column,
tile_row, tile_data)`. We seed one tile at (0,0,0) carrying a 1-byte payload --
content shape doesn't have to be a real tile; the controller just streams bytes.
"""
import os
import sqlite3
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "tilesets/stub.mbtiles"
os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
if os.path.exists(OUT):
    os.remove(OUT)

con = sqlite3.connect(OUT)
cur = con.cursor()
cur.executescript("""
CREATE TABLE metadata (name TEXT, value TEXT);
CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
CREATE UNIQUE INDEX metadata_name ON metadata (name);
CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
""")
for k, v in [
    ("name", "stub"),
    ("type", "baselayer"),
    ("version", "1.0"),
    ("description", "stub"),
    ("format", "pbf"),
    ("bounds", "-180,-85,180,85"),
    ("center", "0,0,0"),
    ("minzoom", "0"),
    ("maxzoom", "0"),
]:
    cur.execute("INSERT INTO metadata VALUES (?, ?)", (k, v))

# Seed one tile at z=0,x=0,y=0. tile_row uses TMS scheme but for z=0 it's 0.
cur.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (0, 0, 0, b"\x00"))
con.commit()
con.close()
print("wrote", OUT)

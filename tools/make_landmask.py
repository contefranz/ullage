#!/usr/bin/env python3
"""Build the Earth's land/water mask used for splashdowns.

Usage:
    python3 tools/make_landmask.py path/to/ne_10m_land.geojson Sources/OrbitCore/Resources/landmask.bin

Input is Natural Earth's 1:10m land polygons (public domain,
https://www.naturalearthdata.com), as GeoJSON from the natural-earth-vector
repository: https://github.com/nvkelso/natural-earth-vector, file
geojson/ne_10m_land.geojson. The mask in the repository was built from commit
ca96624a56bd078437bca8184e78163e5039ad19 (version 5.2.0-pre; 10,157,965 bytes,
sha256 1ac90796408bc6ad6911d69448485d3c4dbf2190370080368a09976e1c9f7416).

The grid is 0.25 deg in geodetic latitude and longitude, 1440 x 720 cells. A
cell is land when its centre lies inside a land polygon (even-odd rule, so
the holes, such as the Caspian Sea, are water). Natural Earth's land layer
counts lakes as land: a splashdown in the Great Lakes is a landing on land.

Output: 8 bytes magic "OSLAND01", int32 columns, int32 rows (little endian),
then one bit per cell, rows from the south (centre latitude -89.875) to the
north, each row from longitude -180 (centre -179.875) eastwards; the bit of
cell k = row * columns + column is bit k % 8 (least significant first) of
byte k // 8. Set bits are land.
"""
import json
import math
import struct
import sys

STEP = 0.25
COLUMNS = int(360 / STEP)
ROWS = int(180 / STEP)


def rings(geometry):
    if geometry["type"] == "Polygon":
        yield from geometry["coordinates"]
    elif geometry["type"] == "MultiPolygon":
        for polygon in geometry["coordinates"]:
            yield from polygon


def main(src, dst):
    with open(src) as f:
        features = json.load(f)["features"]
    # Each row's crossings of its centre latitude by every ring edge, taking
    # an edge's lower end in and its upper end out, so a vertex on the line
    # counts once.
    crossings = [[] for _ in range(ROWS)]
    edges = 0
    for feature in features:
        for ring in rings(feature["geometry"]):
            for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
                if y1 == y2:
                    continue
                edges += 1
                lo, hi = min(y1, y2), max(y1, y2)
                first = max(0, math.ceil((lo + 90) / STEP - 0.5))
                last = min(ROWS - 1, math.ceil((hi + 90) / STEP - 0.5) - 1)
                for row in range(first, last + 1):
                    y = -90 + (row + 0.5) * STEP
                    crossings[row].append(x1 + (x2 - x1) * (y - y1) / (y2 - y1))
    bits = bytearray(COLUMNS * ROWS // 8)
    land = 0
    for row, xs in enumerate(crossings):
        if len(xs) % 2:
            sys.exit("row %d: odd number of crossings (%d)" % (row, len(xs)))
        xs.sort()
        for a, b in zip(xs[0::2], xs[1::2]):
            first = max(0, math.ceil((a + 180) / STEP - 0.5))
            last = min(COLUMNS - 1, math.floor((b + 180) / STEP - 0.5))
            for column in range(first, last + 1):
                k = row * COLUMNS + column
                bits[k // 8] |= 1 << (k % 8)
                land += 1
    with open(dst, "wb") as out:
        out.write(b"OSLAND01")
        out.write(struct.pack("<ii", COLUMNS, ROWS))
        out.write(bits)
    print("%d features, %d edges: %d of %d cells land" % (len(features), edges, land, COLUMNS * ROWS))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

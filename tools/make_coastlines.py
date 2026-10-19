#!/usr/bin/env python3
"""Build the Earth's coastlines drawn by the MAP display.

Usage:
    python3 tools/make_coastlines.py path/to/ne_110m_coastline.geojson Sources/OrbitSim/MFD/Resources/coastlines.bin

Input is Natural Earth's 1:110m coastline (public domain,
https://www.naturalearthdata.com/downloads/110m-physical-vectors/110m-coastline/),
as GeoJSON from the natural-earth-vector repository:
https://github.com/nvkelso/natural-earth-vector, file
geojson/ne_110m_coastline.geojson. The file in the repository was built from
commit ca96624a56bd078437bca8184e78163e5039ad19 (version 5.2.0-pre, the
commit tools/make_landmask.py uses; 139,907 bytes, sha256
851f581ff5ffb844deed8ae1a9ce22e3c4bb3d74fa342cadb5d8e39b41ae7c3c):

    curl -LO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/ca96624a56bd078437bca8184e78163e5039ad19/geojson/ne_110m_coastline.geojson

Natural Earth's terms: "All versions of Natural Earth raster + vector map data
found on this website are in the public domain."
(https://www.naturalearthdata.com/about/terms-of-use/)

Every LineString (and each part of a MultiLineString) is kept as it is, in
order. Coordinates are longitude and latitude in degrees (WGS 84).

Output (little endian): 8 bytes magic "OSCOAST1", uint32 line count, then per
line a uint32 point count and its points as int16 latitude and int16
longitude in hundredths of a degree (the 1:110m data carry about 0.1 km, far
below 0.01 deg = 1.1 km). Longitudes stay in -180...180.
"""
import json
import struct
import sys


def lines(geometry):
    if geometry["type"] == "LineString":
        yield geometry["coordinates"]
    elif geometry["type"] == "MultiLineString":
        yield from geometry["coordinates"]
    else:
        raise ValueError("unexpected geometry " + geometry["type"])


def main(source, target):
    with open(source) as f:
        collection = json.load(f)
    out = []
    for feature in collection["features"]:
        for line in lines(feature["geometry"]):
            points = []
            for lon, lat, *_ in line:
                assert -180 <= lon <= 180 and -90 <= lat <= 90, (lon, lat)
                points.append((round(lat * 100), round(lon * 100)))
            # Drop repeats the rounding made.
            kept = [p for i, p in enumerate(points) if i == 0 or p != points[i - 1]]
            if len(kept) >= 2:
                out.append(kept)
    data = bytearray(b"OSCOAST1")
    data += struct.pack("<I", len(out))
    for line in out:
        data += struct.pack("<I", len(line))
        for lat, lon in line:
            data += struct.pack("<hh", lat, lon)
    with open(target, "wb") as f:
        f.write(data)
    count = sum(len(line) for line in out)
    print(f"{len(out)} lines, {count} points, {len(data)} bytes -> {target}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

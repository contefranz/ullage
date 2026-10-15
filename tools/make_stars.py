#!/usr/bin/env python3
"""Build the star catalogue used for the sky background.

Usage:
    python3 tools/make_stars.py path/to/hip_main.dat Sources/OrbitCore/Resources/stars.bin

Input is the pipe-separated Hipparcos main catalogue (ESA 1997). Every star
brighter than MAG_LIMIT is written as five little-endian float32 values:
unit direction x, y, z (ICRF/J2000 equatorial), visual magnitude, B-V colour.
Header: 8 bytes magic "OSSTAR01", int32 count, int32 reserved.
"""
import math
import struct
import sys

MAG_LIMIT = 7.0


def main(src, dst):
    stars = []
    with open(src) as f:
        for line in f:
            fields = line.split("|")
            ra, dec, vmag, bv = fields[8].strip(), fields[9].strip(), fields[5].strip(), fields[37].strip()
            if not (ra and dec and vmag):
                continue
            vmag = float(vmag)
            if vmag > MAG_LIMIT:
                continue
            ra, dec = math.radians(float(ra)), math.radians(float(dec))
            bv = float(bv) if bv else 0.6
            stars.append((math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec), vmag, bv))
    stars.sort(key=lambda s: s[3])
    with open(dst, "wb") as out:
        out.write(b"OSSTAR01")
        out.write(struct.pack("<ii", len(stars), 0))
        for s in stars:
            out.write(struct.pack("<5f", *s))
    print("wrote %d stars (V <= %.1f)" % (len(stars), MAG_LIMIT))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])

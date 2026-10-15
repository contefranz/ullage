#!/usr/bin/env python3
"""Extract a compact Chebyshev ephemeris from a JPL SPK (type 2) kernel.

Usage:
    python3 tools/make_ephemeris.py de421.bsp moon_pa_de421_1900-2050.bpc Sources/OrbitCore/Resources/ephem.bin

The output keeps only the bodies and time span the simulator needs, in a
trivially parseable little-endian format read by `ChebyshevEphemeris.swift`:

    header  : 8 bytes magic "OSEPH001", int32 segmentCount, int32 reserved
    segment : int32 target, int32 center, int32 coefficientCount, int32 recordCount,
              float64 startSeconds (TDB seconds past J2000), float64 intervalSeconds,
              then recordCount * 3 * coefficientCount float64
              (record-major, then x/y/z, then Chebyshev coefficient order).

Positions are in km in the ICRF frame. The lunar orientation from the binary
PCK is stored as one more segment with target 31006 (MOON_PA_DE421) and
center 1 (J2000): its three "components" are the Euler angles phi, theta, psi
in radians (ICRF -> MOON_PA = R3(psi) R1(theta) R3(phi), passive rotations). The DAF reader below is self-contained
(no jplephem dependency) so the tool can run anywhere with numpy.
"""
import struct
import sys

import numpy as np

# Span covered: 1960-01-01 to 2030-01-01 (TDB), in seconds past J2000.
J2000_JD = 2451545.0
START_JD = 2436934.5
END_JD = 2462502.5

# (target, center) pairs to keep. NAIF ids: 0 SSB, 1-8 planet barycentres,
# 10 Sun, 3 Earth-Moon barycentre, 301 Moon, 399 Earth.
WANTED = [(10, 0), (3, 0), (399, 3), (301, 3), (1, 0), (2, 0), (4, 0), (5, 0), (6, 0), (31006, 1)]


def read_daf_segments(path):
    """Yield (summary_doubles, summary_ints, data_array) for each SPK segment."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:8] not in (b"DAF/SPK ", b"DAF/PCK "):
        raise ValueError("not a DAF/SPK or DAF/PCK file")
    if raw[88:96] != b"LTL-IEEE":
        raise ValueError("only little-endian kernels are supported")
    nd, ni = struct.unpack_from("<ii", raw, 8)
    fward, = struct.unpack_from("<i", raw, 76)
    words = np.frombuffer(raw, dtype="<f8")  # 1-based word addressing below
    ss = nd + (ni + 1) // 2  # summary size in doubles
    record = fward
    while record:
        base = (record - 1) * 1024
        nxt, _prev, nsum = struct.unpack_from("<ddd", raw, base)
        for i in range(int(nsum)):
            off = base + 24 + i * ss * 8
            dc = struct.unpack_from("<%dd" % nd, raw, off)
            ic = struct.unpack_from("<%di" % ni, raw, off + nd * 8)
            start_word, end_word = ic[-2], ic[-1]
            yield dc, ic, words[start_word - 1:end_word]
        record = int(nxt)


def type2_segment(data):
    """Return (init, intlen, coeffs[rec, 3, ncoef]) from a type 2 data block."""
    init, intlen, rsize, n = data[-4:]
    rsize, n = int(rsize), int(n)
    recs = data[: n * rsize].reshape(n, rsize)
    ncoef = (rsize - 2) // 3
    coeffs = recs[:, 2:].reshape(n, 3, ncoef)
    return init, intlen, coeffs


def extract(init, intlen, coeffs, t0, t1):
    i0 = max(int(np.floor((t0 - init) / intlen)), 0)
    i1 = min(int(np.ceil((t1 - init) / intlen)), coeffs.shape[0])
    return init + i0 * intlen, intlen, np.ascontiguousarray(coeffs[i0:i1])


def main(src, pck, dst):
    t0 = (START_JD - J2000_JD) * 86400.0
    t1 = (END_JD - J2000_JD) * 86400.0
    found = {}
    for dc, ic, data in read_daf_segments(src):
        target, center, _frame, dtype = ic[0], ic[1], ic[2], ic[3]
        if (target, center) not in WANTED:
            continue
        if dtype != 2:
            raise ValueError("segment %d->%d is type %d" % (center, target, dtype))
        found[(target, center)] = extract(*type2_segment(data), t0, t1)

    for dc, ic, data in read_daf_segments(pck):
        frame, base, dtype = ic[0], ic[1], ic[2]
        if frame == 31006 and base == 1 and dtype == 2:
            found[(31006, 1)] = extract(*type2_segment(data), t0, t1)

    missing = [w for w in WANTED if w not in found]
    if missing:
        raise ValueError("missing segments: %r" % missing)

    with open(dst, "wb") as out:
        out.write(b"OSEPH001")
        out.write(struct.pack("<ii", len(WANTED), 0))
        for key in WANTED:
            start, intlen, coeffs = found[key]
            nrec, _, ncoef = coeffs.shape
            out.write(struct.pack("<iiii", key[0], key[1], ncoef, nrec))
            out.write(struct.pack("<dd", start, intlen))
            out.write(coeffs.astype("<f8").tobytes())
            print("%4d -> %3d  ncoef=%2d  records=%5d  interval=%5.1f d"
                  % (key[1], key[0], ncoef, nrec, intlen / 86400))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3])

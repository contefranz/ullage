#!/usr/bin/env python3
"""Extract UT1-UTC from the IERS EOP 20 C04 series into OrbitCore's UT1 table.

Usage:
    curl -O https://hpiers.obspm.fr/iers/eop/eopc04/eopc04.1962-now
    python3 tools/make_ut1.py eopc04.1962-now Sources/OrbitCore/Resources/ut1.txt \\
        --retrieved 2026-10-19 --last-modified "Sun, 18 Oct 2026 13:21:06 GMT"

EOP 20 C04 is the IERS's combined series of Earth orientation parameters,
consistent with ITRF 2020 and sampled daily at 0h UTC from 1962-01-01. Its
product centre (Paris Observatory) keeps the current file at the URL above;
the copy on datacenter.iers.org lags it (in October 2026 it ended in May 2025
and differed from 2021 on, where C04 had been reprocessed).

The output keeps C04's UT1-UTC column as published (seconds, 7 decimals),
one line per day:

    # header lines: source, retrieval, sha256 of the source file
    MJD UT1-UTC

`Epoch` subtracts TAI-UTC (its own table, USNO tai-utc.dat) to hold UT1-TAI,
which stays smooth across the leap seconds and the pre-1972 steps, and
interpolates it linearly between days. Polar motion (C04's x, y) and the
celestial pole offsets (dX, dY) are not kept: OrbitCore does not model them.
"""
import argparse
import hashlib

URL = "https://hpiers.obspm.fr/iers/eop/eopc04/eopc04.1962-now"


def read_c04(path):
    """Return (series line, [(mjd, ut1_utc)]) from a C04 file, checking its layout."""
    series, rows = None, []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                if "C04 TIME SERIES" in line:
                    series = " ".join(line.lstrip("# ").split())
                if line.startswith("# YR"):
                    cols = line[1:].split()
                    if cols[4:8] != ["MJD", 'x(")', 'y(")', "UT1-UTC(s)"]:
                        raise ValueError("unexpected C04 columns: %s" % cols[:8])
                continue
            if not line.strip():
                continue
            fields = line.split()
            if fields[3] != "0":
                raise ValueError("C04 row not at 0h UTC: %s" % line.strip())
            mjd = float(fields[4])
            if mjd != int(mjd):
                raise ValueError("fractional MJD: %s" % line.strip())
            rows.append((int(mjd), fields[7]))
    if series is None:
        raise ValueError("no 'C04 TIME SERIES' line in the header")
    for (a, _), (b, _) in zip(rows, rows[1:]):
        if b != a + 1:
            raise ValueError("C04 days not consecutive at MJD %d -> %d" % (a, b))
    for mjd, v in rows:
        if mjd >= 41317 and abs(float(v)) >= 0.9:  # 1972 on, |UT1-UTC| < 0.9 s
            raise ValueError("|UT1-UTC| >= 0.9 s at MJD %d" % mjd)
    return series, rows


def calendar(mjd):
    """Gregorian (year, month, day) of an MJD."""
    jd = mjd + 2400001  # JD at noon of that day, an integer
    a = jd + 32044
    b = (4 * a + 3) // 146097
    c = a - 146097 * b // 4
    d = (4 * c + 3) // 1461
    e = c - 1461 * d // 4
    m = (5 * e + 2) // 153
    return 100 * b + d - 4800 + m // 10, m + 3 - 12 * (m // 10), e - (153 * m + 2) // 5 + 1


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("c04", help="the downloaded eopc04.1962-now")
    p.add_argument("output", help="Sources/OrbitCore/Resources/ut1.txt")
    p.add_argument("--retrieved", required=True, help="date the C04 file was downloaded (YYYY-MM-DD)")
    p.add_argument("--last-modified", default="", help="the server's Last-Modified header for it")
    p.add_argument("--url", default=URL, help="where the C04 file came from")
    a = p.parse_args()

    series, rows = read_c04(a.c04)
    with open(a.c04, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    first, last = calendar(rows[0][0]), calendar(rows[-1][0])
    with open(a.output, "w") as out:
        out.write("# UT1-UTC (s) at 0h UTC, daily, from %s\n" % series)
        out.write("# Source: %s\n" % a.url)
        modified = ", Last-Modified %s" % a.last_modified if a.last_modified else ""
        out.write("# Retrieved %s%s; sha256 %s\n" % (a.retrieved, modified, sha))
        out.write("# Span: %04d-%02d-%02d to %04d-%02d-%02d, %d days\n" % (first + last + (len(rows),)))
        out.write("# Written by tools/make_ut1.py; the values are C04's UT1-UTC column as published.\n")
        out.write("# MJD UT1-UTC\n")
        for mjd, v in rows:
            out.write("%d %s\n" % (mjd, v))
    print("%d days, %s to %s" % (len(rows), first, last))


if __name__ == "__main__":
    main()

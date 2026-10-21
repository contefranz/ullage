#!/usr/bin/env python3
"""Write a mission's cloud field (OSCLOUD1) from ERA5.

Usage:
    python3 -I tools/make_clouds_era5.py check
    python3 -I tools/make_clouds_era5.py mission apollo8 [--out FILE] [--workers 8]
    python3 -I tools/make_clouds_era5.py window --start 1968-12-21T12 --hourly-until 1968-12-21T17 \\
        --end 1968-12-27T18 --out FILE
    python3 -I tools/make_clouds_era5.py pad [--csv tools/data/tmx64796_table1_saturn.csv]
    python3 -I tools/make_clouds_era5.py climatology [--years 1961-1990]

`check` prints the store's valid_time_start and stop. `mission` writes a
preset window (below) to Sources/OrbitScene/Resources/<mission>.oscloud;
`window` writes any window. `pad` prints ERA5's layers at the pad at the
launches of AS-205, AS-503 and AS-506 (`--all`: every Saturn launch of TM
X-64796 Table 1) beside the observed sky. `climatology` prints the
zonal-mean table of OrbitScene/Earth/CloudClimatology.swift.

Needs Python 3.9 or later and numpy; nothing else (no zarr, xarray or gcsfs).
On a python.org build of Python for macOS, run its "Install
Certificates.command" once if HTTPS fails certificate verification.

Source: ERA5 hourly reanalysis (Hersbach et al. 2020, QJRMS 146, 1999-2049),
0.25 deg, read from Google's analysis-ready ARCO-ERA5 copy, a public bucket
read anonymously over HTTPS:
https://storage.googleapis.com/gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3
(https://github.com/google-research/arco-era5). Its .zattrs gave
valid_time_start 1940-01-01 and valid_time_stop 2026-06-30 on 2026-10-21.
The store is Zarr v2 despite its name: one chunk per hour of 721 x 1440
float32 (latitude 90 to -90, longitude 0 to 359.75 east), blosc-LZ4 with
byte shuffle; pressure-level variables hold all 37 levels in one chunk, so
only the blosc blocks under 850, 500 and 250 hPa are fetched, by HTTP range.
The decoder below was checked byte for byte against numcodecs' Blosc.

Licence: ERA5 is CC BY 4.0. The output is a derived file and is not
committed (docs/m16/plan.md, owner decision 29); anything that shows it
credits "Contains modified Copernicus Climate Change Service information
2026" (the line is also stored in the file's note).

Variables, ERA5 name (plane):
- low_cloud_cover (lcc), medium_cloud_cover (mcc), high_cloud_cover (hcc):
  the fraction of the grid box covered by cloud in the layers below
  0.8 surface pressure (about 2 km), from 0.8 to 0.45 (about 2-6 km) and
  above 0.45 (about 6 km), at 0.25 deg;
- cloud_base_height (cbh): metres above the surface of the lowest cloud's
  base, at 0.25 deg; no value where ERA5 has no cloud;
- 10 m wind (u10, v10) and the wind at 850, 500 and 250 hPa (u850, v850,
  u500, v500, u250, v250), the layers' steering winds, in m/s towards the
  east and north, box-averaged to 1 deg.

Times: snapshots every hour from the window's start to --hourly-until (the
Earth-orbit phase), then every 3 hours to the end; ERA5's values are
instantaneous at each hour.

OSCLOUD1, little endian:
    8 bytes   magic "OSCLOUD1"
    uint32    header bytes H (the first snapshot starts there)
    uint32    snapshots N
    uint32    planes P
    uint32    0 (reserved)
    P x 32    planes: name (8 bytes ASCII, NUL padded), uint32 columns,
              uint32 rows, float64 offset, float64 scale
    N x 8     int64 snapshot times, POSIX seconds UTC, increasing
    uint32    note bytes, then the note (UTF-8)
    data      N snapshots, each its P planes in order, each rows x columns
              uint8 from the north: row r at latitude 90 - 180 r/(rows-1),
              column c at longitude 360 c/columns east. A byte b is
              offset + scale * b; 255 is "no value".
Cover is b/254; cloud base 60 m steps to 15,240 m; winds 1 m/s steps to
+-127 m/s, 10 m wind 0.5 m/s steps to +-63.5 m/s. The output depends only
on ERA5's values (elementwise float64 arithmetic in a fixed order, rounded
half to even), so its sha256 is the same on any machine.

Mission presets (UTC; launch, end of the Earth-orbit phase, splashdown):
- apollo8: 1968-12-21 12:51 launch, 15:41 TLI, 12-27 15:51 splashdown;
  hourly 12-21T12 to T17, 3-hourly from T18 to 12-27T18: 6 + 49 = 55
  snapshots, 257,084,321 bytes.
- apollo11: 1969-07-16 13:32 launch, 16:22 TLI, 07-24 16:50 splashdown;
  hourly 07-16T13 to T18, 3-hourly to 07-24T18.
- apollo7: 1968-10-11 15:03 launch, Earth orbit to the 10-22 11:12
  splashdown; hourly through launch day (10-11T15 to 10-12T00) and the last
  day (10-21T12 to 10-22T12), 3-hourly between. The whole flight hourly
  would be 262 snapshots (1.2 GB).
"""
import argparse
import concurrent.futures
import csv
import datetime as dt
import hashlib
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request

import numpy as np

STORE = ("https://storage.googleapis.com/gcp-public-data-arco-era5/ar/"
         "full_37-1h-0p25deg-chunk-1.zarr-v3")
EPOCH = dt.datetime(1900, 1, 1)  # the store's time axis: hours since then, index = value
ROWS, COLUMNS = 721, 1440
ATTRIBUTION = "Contains modified Copernicus Climate Change Service information 2026"

# Plane name, ERA5 variable, pressure level (None: single level), decimation
# (1: 0.25 deg, 4: 1 deg), offset, scale.
PLANES = [
    ("lcc", "low_cloud_cover", None, 1, 0.0, 1 / 254),
    ("mcc", "medium_cloud_cover", None, 1, 0.0, 1 / 254),
    ("hcc", "high_cloud_cover", None, 1, 0.0, 1 / 254),
    ("cbh", "cloud_base_height", None, 1, 0.0, 60.0),
    ("u10", "10m_u_component_of_wind", None, 4, -63.5, 0.5),
    ("v10", "10m_v_component_of_wind", None, 4, -63.5, 0.5),
    ("u850", "u_component_of_wind", 850, 4, -127.0, 1.0),
    ("v850", "v_component_of_wind", 850, 4, -127.0, 1.0),
    ("u500", "u_component_of_wind", 500, 4, -127.0, 1.0),
    ("v500", "v_component_of_wind", 500, 4, -127.0, 1.0),
    ("u250", "u_component_of_wind", 250, 4, -127.0, 1.0),
    ("v250", "v_component_of_wind", 250, 4, -127.0, 1.0),
]
LEVELS = [1, 2, 3, 5, 7, 10, 20, 30, 50, 70, 100, 125, 150, 175, 200, 225, 250, 300, 350, 400,
          450, 500, 550, 600, 650, 700, 750, 775, 800, 825, 850, 875, 900, 925, 950, 975, 1000]

MISSIONS = {
    "apollo8": [("1968-12-21T12", "1968-12-21T17", 1), ("1968-12-21T18", "1968-12-27T18", 3)],
    "apollo11": [("1969-07-16T13", "1969-07-16T18", 1), ("1969-07-16T21", "1969-07-24T18", 3)],
    "apollo7": [("1968-10-11T15", "1968-10-12T00", 1), ("1968-10-12T03", "1968-10-21T09", 3),
                ("1968-10-21T12", "1968-10-22T12", 1)],
}

# Launch pads (geodetic deg), for `pad`.
PADS = {
    "34": (28.5218, -80.5611),
    "37B": (28.5316, -80.5649),
    "39A": (28.6084, -80.6041),   # VesselLibrary.lc39A
    "39B": (28.6272, -80.6208),
}


# MARK: Zarr v2 chunks over HTTPS

def fetch(url, first=None, last=None, tries=4):
    """The bytes of `url`, or of its range first...last (inclusive)."""
    request = urllib.request.Request(url)
    if first is not None:
        request.add_header("Range", "bytes=%d-%d" % (first, last))
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
            if first is not None and len(data) != last - first + 1:
                raise IOError("short range read of %s" % url)
            return data
        except (urllib.error.URLError, IOError, TimeoutError) as error:
            if attempt == tries - 1:
                raise
            print("  retrying %s (%s)" % (url, error), file=sys.stderr)
            time.sleep(2 ** (attempt + 1))


def lz4_block(src, start, end):
    """Decode one LZ4 block (the raw block format, no frame) in src[start:end]."""
    out = bytearray()
    ip = start
    while ip < end:
        token = src[ip]
        ip += 1
        literals = token >> 4
        if literals == 15:
            while True:
                b = src[ip]
                ip += 1
                literals += b
                if b != 255:
                    break
        out += src[ip:ip + literals]
        ip += literals
        if ip >= end:
            break
        offset = src[ip] | (src[ip + 1] << 8)
        ip += 2
        length = token & 15
        if length == 15:
            while True:
                b = src[ip]
                ip += 1
                length += b
                if b != 255:
                    break
        length += 4
        if offset >= length:
            s = len(out) - offset
            out += out[s:s + length]
        else:  # the match overlaps what it writes: repeat its period
            period = bytes(out[-offset:])
            out += (period * (length // offset + 1))[:length]
    return out


def blosc_header(buf):
    flags, typesize = buf[2], buf[3]
    nbytes, blocksize, cbytes = struct.unpack_from("<III", buf, 4)
    return flags, typesize, nbytes, blocksize, cbytes


def blosc_block(buf, at, flags, typesize, size, blocksize):
    """Decode the blosc block of `size` bytes that starts at buf[at]."""
    if flags >> 5 != 1:
        raise ValueError("blosc compressor %d is not LZ4" % (flags >> 5))
    leftover = size != blocksize
    split = not flags & 0x10 and typesize <= 16 and blocksize // typesize >= 128 and not leftover
    streams = typesize if split else 1
    part = size // streams
    block = bytearray()
    for _ in range(streams):
        csize = struct.unpack_from("<i", buf, at)[0]
        at += 4
        block += buf[at:at + csize] if csize == part else lz4_block(buf, at, at + csize)
        at += csize
    if len(block) != size:
        raise ValueError("blosc block decoded to %d bytes, not %d" % (len(block), size))
    if flags & 0x01 and typesize > 1:
        n = size // typesize
        a = np.frombuffer(bytes(block[:n * typesize]), np.uint8).reshape(typesize, n).T
        block = a.tobytes() + bytes(block[n * typesize:])
    return bytes(block)


def blosc_decode(buf):
    flags, typesize, nbytes, blocksize, _ = blosc_header(buf)
    if flags & 0x02:
        return bytes(buf[16:16 + nbytes])
    nblocks = (nbytes + blocksize - 1) // blocksize
    starts = struct.unpack_from("<%di" % nblocks, buf, 16)
    parts = []
    for i, at in enumerate(starts):
        size = min(blocksize, nbytes - i * blocksize)
        parts.append(blosc_block(buf, at, flags, typesize, size, blocksize))
    return b"".join(parts)


def hour_index(when):
    return int((when - EPOCH).total_seconds()) // 3600


def single_level(variable, when):
    """ERA5's 721 x 1440 field of `variable` at the hour `when`, float32."""
    url = "%s/%s/%d.0.0" % (STORE, variable, hour_index(when))
    return np.frombuffer(blosc_decode(fetch(url)), "<f4").reshape(ROWS, COLUMNS)


def pressure_level(variable, level, when):
    """The 721 x 1440 field of `variable` at `level` hPa, from only the
    blosc blocks that hold it."""
    url = "%s/%s/%d.0.0.0" % (STORE, variable, hour_index(when))
    head = fetch(url, 0, 15)
    flags, typesize, nbytes, blocksize, cbytes = blosc_header(head)
    plane = ROWS * COLUMNS * 4
    first = LEVELS.index(level) * plane
    if flags & 0x02:  # stored, not compressed
        return np.frombuffer(fetch(url, 16 + first, 16 + first + plane - 1), "<f4").reshape(ROWS, COLUMNS)
    nblocks = (nbytes + blocksize - 1) // blocksize
    starts = struct.unpack_from("<%di" % nblocks, fetch(url, 16, 16 + 4 * nblocks - 1))
    b0, b1 = first // blocksize, (first + plane - 1) // blocksize
    end = starts[b1 + 1] if b1 + 1 < nblocks else cbytes
    data = fetch(url, starts[b0], end - 1)
    raw = b"".join(
        blosc_block(data, starts[i] - starts[b0], flags, typesize,
                    min(blocksize, nbytes - i * blocksize), blocksize)
        for i in range(b0, b1 + 1))
    skip = first - b0 * blocksize
    return np.frombuffer(raw[skip:skip + plane], "<f4").reshape(ROWS, COLUMNS)


def field(plane, when):
    _, variable, level, _, _, _ = plane
    return single_level(variable, when) if level is None else pressure_level(variable, level, when)


# MARK: OSCLOUD1

def box_average(a, k):
    """Average a 0.25 deg global field onto every k-th row and column (k
    even) over the k x k box around each point: weights 1/2, 1, ..., 1, 1/2
    on its k + 1 points each way, wrapping in longitude and renormalised at
    the poles. Float64, summed in a fixed order."""
    a = a.astype(np.float64)
    taps = [(d, 0.5 if abs(d) == k // 2 else 1.0) for d in range(-(k // 2), k // 2 + 1)]
    across = np.zeros_like(a)
    for d, w in taps:
        across = across + w * np.roll(a, -d, axis=1)
    rows = np.arange(0, ROWS, k)
    total = np.zeros((len(rows), COLUMNS))
    weight = np.zeros((len(rows), 1))
    for d, w in taps:
        r = rows + d
        ok = (r >= 0) & (r < ROWS)
        total[ok] = total[ok] + w * across[r[ok]]
        weight[ok] = weight[ok] + w
    return total[:, ::k] / (weight * k)


def quantise(a, offset, scale):
    """Bytes b = round((a - offset) / scale) in 0...254; NaN to 255."""
    b = np.rint((a.astype(np.float64) - offset) / scale)
    b = np.where(np.isnan(b), 255.0, np.clip(b, 0.0, 254.0))
    return b.astype(np.uint8)


def snapshot(when, workers):
    """One snapshot's planes, in PLANES order, as bytes."""
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        fields = list(pool.map(lambda p: field(p, when), PLANES))
    out = []
    for plane, a in zip(PLANES, fields):
        name, _, _, k, offset, scale = plane
        if k > 1:
            a = box_average(a, k)
        out.append(quantise(a, offset, scale).tobytes())
    return b"".join(out)


def header(times, note):
    names = b"".join(
        struct.pack("<8sIIdd", name.encode(), COLUMNS // k, (ROWS - 1) // k + 1, offset, scale)
        for name, _, _, k, offset, scale in PLANES)
    stamps = struct.pack("<%dq" % len(times), *(int((t - dt.datetime(1970, 1, 1)).total_seconds())
                                                 for t in times))
    note = note.encode()
    size = 24 + len(names) + len(stamps) + 4 + len(note)
    return (b"OSCLOUD1" + struct.pack("<IIII", size, len(times), len(PLANES), 0) + names + stamps
            + struct.pack("<I", len(note)) + note)


def schedule(segments):
    times = []
    for start, end, step in segments:
        t, end = parse_hour(start), parse_hour(end)
        while t <= end:
            times.append(t)
            t += dt.timedelta(hours=step)
    if any(b <= a for a, b in zip(times, times[1:])):
        raise SystemExit("the window's times must increase")
    return times


def parse_hour(text):
    return dt.datetime.strptime(text, "%Y-%m-%dT%H")


def write(times, out, label, workers):
    note = "%s. ERA5 hourly reanalysis (Hersbach et al. 2020), from %s; %s; made by tools/make_clouds_era5.py." % (
        ATTRIBUTION, STORE, label)
    tmp = out + ".part"
    sha = hashlib.sha256()
    with open(tmp, "wb") as f:
        head = header(times, note)
        f.write(head)
        sha.update(head)
        for i, when in enumerate(times):
            t0 = time.time()
            data = snapshot(when, workers)
            f.write(data)
            sha.update(data)
            print("  %s (%d/%d) %.1f s" % (when.isoformat(), i + 1, len(times), time.time() - t0),
                  file=sys.stderr)
    os.replace(tmp, out)
    print("%s: %d snapshots, %d bytes, sha256 %s" % (out, len(times), os.path.getsize(out),
                                                    sha.hexdigest()))


# MARK: Commands

def check(_):
    attrs = json.loads(fetch(STORE + "/.zattrs"))
    print("valid_time_start %s, valid_time_stop %s (%s)" % (
        attrs["valid_time_start"], attrs["valid_time_stop"], STORE))
    if attrs["valid_time_start"] > "1968-12-01":
        print("The store starts after December 1968: use the Copernicus CDS instead.")


def mission(args):
    out = args.out or os.path.join("Sources", "OrbitScene", "Resources", args.name + ".oscloud")
    write(schedule(MISSIONS[args.name]), out, "mission " + args.name, args.workers)


def window(args):
    segments = [(args.start, args.hourly_until, 1)]
    if args.end > args.hourly_until:
        first = parse_hour(args.hourly_until) + dt.timedelta(hours=3)
        segments.append((first.strftime("%Y-%m-%dT%H"), args.end, 3))
    write(schedule(segments), args.out, "window %s to %s, hourly to %s" % (
        args.start, args.end, args.hourly_until), args.workers)


def bilinear(a, lat, lon):
    """`a` (721 x 1440, from the north and longitude 0) at a point, NaNs
    left out."""
    r, c = (90 - lat) / 0.25, (lon % 360) / 0.25
    r0, c0 = int(r), int(c)
    fr, fc = r - r0, c - c0
    total = weight = 0.0
    for dr, dc, w in ((0, 0, (1 - fr) * (1 - fc)), (0, 1, (1 - fr) * fc),
                      (1, 0, fr * (1 - fc)), (1, 1, fr * fc)):
        v = float(a[r0 + dr, (c0 + dc) % COLUMNS])
        if not np.isnan(v):
            total, weight = total + w * v, weight + w
    return total / weight if weight > 0 else float("nan")


def pad(args):
    """ERA5 at the pad at launch, linear between the two hours around it."""
    print("vehicle  launch (UTC)       pad  ERA5 low/mid/high, base       observed")
    with open(args.csv) as f:
        rows = list(csv.DictReader(line for line in f if not line.startswith("#")))
    for row in rows:
        if not args.all and row["vehicle"] not in ("AS-205", "AS-503", "AS-506"):
            continue
        launch = dt.datetime.strptime(row["launch_utc"], "%Y-%m-%dT%H:%MZ")
        lat, lon = PADS[row["pad"]]
        h0 = launch.replace(minute=0)
        f = launch.minute / 60
        values = []
        for variable in ("low_cloud_cover", "medium_cloud_cover", "high_cloud_cover", "cloud_base_height"):
            a, b = (bilinear(single_level(variable, h), lat, lon) for h in (h0, h0 + dt.timedelta(hours=1)))
            values.append(a + f * (b - a) if not (np.isnan(a) or np.isnan(b)) else (b if f > 0.5 else a))
        print("%-8s %s %-4s %.3f %.3f %.3f, %5.0f m   %s" % (
            row["vehicle"], row["launch_utc"], row["pad"], *values, row["clouds"]))


def climatology(args):
    """Zonal-mean low, mid and high cover by month, every 5 deg, from ERA5 at
    12 UTC on the 5th, 15th and 25th of each month of the years given. A
    zonal mean at one UTC hour spans every local time, so one hour a day
    samples the diurnal cycle."""
    y0, y1 = map(int, args.years.split("-"))
    nodes = np.arange(-90, 91, 5)
    table = {v: np.zeros((12, len(nodes))) for v in ("low", "mid", "high")}
    lats = 90 - 0.25 * np.arange(ROWS)
    layers = (("low", "low_cloud_cover"), ("mid", "medium_cloud_cover"), ("high", "high_cloud_cover"))
    for month in range(1, 13):
        jobs = [(v, variable, dt.datetime(year, month, day, 12)) for year in range(y0, y1 + 1)
                for day in (5, 15, 25) for v, variable in layers]
        with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
            zonals = list(pool.map(lambda j: single_level(j[1], j[2]).astype(np.float64).mean(axis=1), jobs))
        count = len(jobs) // len(layers)
        for v in table:
            zonal = sum(z for (w, _, _), z in zip(jobs, zonals) if w == v) / count
            # Each node: the cos-latitude weighted mean of the 0.25 deg rows within 2.5 deg.
            for j, node in enumerate(nodes):
                near = np.abs(lats - node) <= 2.5
                w = np.cos(np.radians(lats[near])) + 1e-3
                table[v][month - 1, j] = (zonal[near] * w).sum() / w.sum()
        print("  month %d done (%d samples)" % (month, count), file=sys.stderr)
    print("// ERA5 %d-%d, 12 UTC on the 5th, 15th and 25th of each month; percent;" % (y0, y1))
    print("// rows January to December, columns latitude -90 to 90 every 5 deg.")
    for v in ("low", "mid", "high"):
        print("static let %s: [[UInt8]] = [" % v)
        for m in range(12):
            print("    [" + ", ".join("%d" % round(100 * x) for x in table[v][m]) + "],")
        print("]")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check").set_defaults(run=check)
    p = sub.add_parser("mission")
    p.add_argument("name", choices=sorted(MISSIONS))
    p.add_argument("--out")
    p.add_argument("--workers", type=int, default=8)
    p.set_defaults(run=mission)
    p = sub.add_parser("window")
    p.add_argument("--start", required=True, help="first hour, e.g. 1968-12-21T12")
    p.add_argument("--hourly-until", required=True, help="last hourly snapshot")
    p.add_argument("--end", required=True, help="last snapshot (3-hourly after --hourly-until)")
    p.add_argument("--out", required=True)
    p.add_argument("--workers", type=int, default=8)
    p.set_defaults(run=window)
    p = sub.add_parser("pad")
    p.add_argument("--csv", default=os.path.join("tools", "data", "tmx64796_table1_saturn.csv"))
    p.add_argument("--all", action="store_true",
                   help="every row of the table (default: the sim's AS-205, AS-503 and AS-506)")
    p.set_defaults(run=pad)
    p = sub.add_parser("climatology")
    p.add_argument("--years", default="1961-1990")
    p.add_argument("--workers", type=int, default=8)
    p.set_defaults(run=climatology)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()

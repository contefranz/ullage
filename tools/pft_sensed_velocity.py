#!/usr/bin/env python3
"""AS-506's sensed (non-gravitational) velocity from its postflight trajectory.

Usage:
    python3 tools/pft_sensed_velocity.py [tools/data/pft506_table_b2.csv]

Reads PFT Table B-II (PACSS 13 states, see the data file's header) and, for
each interval between consecutive rows, takes the sensed velocity increment

    dV_sens = (v1 - v0) - integral of g(r) dt,

with g the Earth's J2 gravity on the Fischer-1960 figure (the PFT's Earth
model) and the integral by Simpson's rule on the Hermite midpoint of the
interval. It prints, by stage window (the event rows' range times):

- the vector sum |sum dV_sens|, FER Table 10-1's measure, and the scalar
  integral of |a_ng|, the sum of |dV_sens|;
- the platform velocity: the pad phase (guidance reference release to first
  motion, the plumb line turning with the Earth) plus the flight's sum, against
  Table 10-1's postflight values at the three cutoffs.

The pad phase is computed, not read: from release to first motion the vehicle
sits on the pad, so its sensed acceleration is minus the gravity at the pad
plus its centripetal acceleration. The PFT's own pad rows give the same
velocity within its 0.1 m/s rounding.

Datasheet section 14.2 quotes the results: 3,303.57, 4,583.74 and 880.79 m/s
by window, and 9,132.67 m/s of |a_ng| from first motion to the guidance
cutoff. The vector sums depend only on the windows' ends. The integral of
|a_ng| depends on the intervals: section 14 took it on the rows that PR 12's
transcription had (every row to 162 s, then mostly 10 s apart, `SECTION_14_ROWS`),
which reproduces its 9,132.67 m/s; on every row of the table it is 0.16 m/s
more, 9,132.83 m/s, the finer intervals following the thrust's turn closer.
"""
import csv
import math
import sys

MU = 3.986032e14         # m^3/s^2, the LVDC's (GE504 Table 5-I)
J2 = 1.0823e-3           # GE504's J = 1.62345e-3 is 3/2 J2
A_E = 6378166.0          # m, Fischer 1960 equatorial radius (PFT section 2)
OMEGA = 7.2921159e-5     # rad/s, the Earth's rotation rate
PAD_LAT = 28.608422      # deg, geodetic, LC-39A (PFT section 2)
AZIMUTH = 72.058         # deg, flight azimuth (PFT section 2)

# Stage windows: range times of the PFT event rows that bound them.
FIRST_MOTION = 0.300
WINDOWS = [("S-IC", 0.300, 161.630), ("S-II", 161.630, 548.220), ("S-IVB", 548.220, 699.330)]
# The rows after 162 s that section 14's integral of |a_ng| used: those of PR
# 12's transcription (docs/data/as506/pft-table-b2/b2-oeco-to-insertion-raw.txt).
SECTION_14_ROWS = (
    162.3, 164, 166, 168, 170, 172, 180, 190, 200, 210, 220, 230, 240, 250, 260, 270, 280, 290, 300, 310,
    320, 330, 340, 350, 360, 370, 380, 390, 400, 410, 420, 430, 440, 450, 456, 458, 460, 460.62, 462, 464,
    466, 470, 480, 490, 500, 510, 520, 530, 540, 542, 544, 546, 548, 548.22, 549, 550, 552, 554, 556, 558,
    560, 570, 580, 590, 600, 610, 620, 630, 640, 650, 660, 670, 678, 680, 682, 684, 686, 688, 690, 692,
    694, 696, 698, 699.33, 700, 702, 704, 706, 708, 709.33)
# FER Table 10-1, postflight, PACSS 12 (same axes as PACSS 13).
TABLE_10_1 = {161.630: (2583.28, 2.71, 2255.10), 548.220: (3430.60, -0.96, 6759.88),
              699.330: (3192.07, 3.23, 7607.67)}


def pole():
    """The Earth's spin axis in PACSS 13: X up along the pad's normal, Z
    downrange along the azimuth, Y to its right (azimuth + 90 deg)."""
    phi, az = math.radians(PAD_LAT), math.radians(AZIMUTH)
    return (math.sin(phi), math.cos(phi) * math.cos(az + math.pi / 2), math.cos(phi) * math.cos(az))


P = pole()


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def add(a, b, s=1.0):
    return tuple(x + s * y for x, y in zip(a, b))


def scale(a, s):
    return tuple(s * x for x in a)


def norm(a):
    return math.sqrt(dot(a, a))


def gravity(r):
    """J2 gravity (m/s^2) at r (m, PACSS 13)."""
    rr = norm(r)
    z = dot(r, P) / rr
    k = 1.5 * J2 * (A_E / rr) ** 2
    radial = -MU / rr ** 3 * (1 + k * (1 - 5 * z * z))
    polar = -MU / rr ** 3 * 2 * k * z * rr
    return add(scale(r, radial), P, polar)


def read_rows(path):
    rows = []
    with open(path) as f:
        lines = [line for line in f if not line.startswith("#")]
    for rec in csv.DictReader(lines):
        t = float(rec["time"])
        r = tuple(1000.0 * float(rec[k]) for k in ("xs_km", "ys_km", "zs_km"))
        v = tuple(float(rec[k]) for k in ("dxs", "dys", "dzs"))
        rows.append((t, r, v, rec["event"]))
    return rows


def sensed_increments(rows):
    """(t0, t1, dV_sens) for each interval after first motion."""
    out = []
    for (t0, r0, v0, _), (t1, r1, v1, _) in zip(rows, rows[1:]):
        if t0 < FIRST_MOTION - 1e-9:
            continue
        h = t1 - t0
        mid = add(scale(add(r0, r1), 0.5), add(v0, v1, -1.0), h / 8)
        g = add(add(gravity(r0), gravity(r1)), gravity(mid), 4.0)
        out.append((t0, t1, add(add(v1, v0, -1.0), g, -h / 6)))
    return out


def pad_phase(rows):
    """Sensed velocity from guidance reference release to first motion: the
    pad's -g plus its centripetal acceleration, integrated as the pad turns
    with the Earth about P."""
    t_grr, r_grr = rows[0][0], rows[0][1]
    steps = 2000
    h = (FIRST_MOTION - t_grr) / steps
    total = (0.0, 0.0, 0.0)
    for i in range(steps + 1):
        t = i * h
        # rotate the GRR pad position about P by the Earth's rotation
        c, s = math.cos(OMEGA * t), math.sin(OMEGA * t)
        along = scale(P, dot(P, r_grr))
        perp = add(r_grr, along, -1.0)
        cross = (P[1] * perp[2] - P[2] * perp[1], P[2] * perp[0] - P[0] * perp[2], P[0] * perp[1] - P[1] * perp[0])
        r = add(along, add(scale(perp, c), cross, s))
        centripetal = scale(add(r, along, -1.0), -OMEGA ** 2)
        a = add(centripetal, gravity(r), -1.0)
        w = 1 if i in (0, steps) else (4 if i % 2 else 2)
        total = add(total, a, w * h / 3)
    return total


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "tools/data/pft506_table_b2.csv"
    rows = read_rows(path)
    inc = sensed_increments(rows)
    pad = pad_phase(rows)
    print(f"pad phase {rows[0][0]:.3f} to {FIRST_MOTION:.3f} s: sensed velocity "
          f"({pad[0]:.3f}, {pad[1]:.3f}, {pad[2]:.3f}) m/s")
    print()
    print(f"{'window':8} {'from':>8} {'to':>8} {'|sum dV_sens|':>14} {'sum |dV_sens|':>14}  components (X, Y, Z)")
    total_scalar = 0.0
    cumulative = pad
    for name, a, b in WINDOWS:
        vec, sca = (0.0, 0.0, 0.0), 0.0
        for t0, t1, d in inc:
            if t0 >= a - 1e-9 and t1 <= b + 1e-9:
                vec = add(vec, d)
                sca += norm(d)
        total_scalar += sca
        cumulative = add(cumulative, vec)
        print(f"{name:8} {a:8.2f} {b:8.2f} {norm(vec):14.2f} {sca:14.2f}  ({vec[0]:.2f}, {vec[1]:.2f}, {vec[2]:.2f})")
        ref = TABLE_10_1[b]
        diff = add(cumulative, ref, -1.0)
        print(f"{'':8} platform velocity at {b:.2f} s, pad + PFT: ({cumulative[0]:.2f}, {cumulative[1]:.2f}, "
              f"{cumulative[2]:.2f}); FER Table 10-1 postflight ({ref[0]:.2f}, {ref[1]:.2f}, {ref[2]:.2f}); "
              f"difference ({diff[0]:+.2f}, {diff[1]:+.2f}, {diff[2]:+.2f})")
    print(f"{'flight':8} {WINDOWS[0][1]:8.2f} {WINDOWS[-1][2]:8.2f} {'':14} {total_scalar:14.2f}")
    sparse = [r for r in rows if r[0] <= 162 + 1e-9 or any(abs(r[0] - t) < 1e-6 for t in SECTION_14_ROWS)]
    inc14 = sensed_increments(sparse)
    by_window = [sum(norm(d) for t0, t1, d in inc14 if t0 >= a - 1e-9 and t1 <= b + 1e-9) for _, a, b in WINDOWS]
    print(f"on section 14's rows ({len(sparse)} of {len(rows)}): integral of |a_ng| "
          + ", ".join(f"{name} {x:.2f}" for (name, _, _), x in zip(WINDOWS, by_window))
          + f"; flight {sum(by_window):.2f} m/s")


if __name__ == "__main__":
    main()

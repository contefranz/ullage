#!/usr/bin/env python3
"""Fit AS-506's S-IC pitch command in the form of the LVDC's pre-IGM program.

Usage:
    python3 tools/fit_as506_pitch.py [--swift] [--start-zero] [pft_table_b2.csv] [fig11_1_pitch_error.csv]

With --swift it prints only the coefficients, at full precision, as the
Swift literal that AS506PostflightData.swift holds. --start-zero adds the
constraint chi_Y(12.57 s) = 0, AS-506's program start (FER Table 2-2: T1 +
12.6 s), so the command starts from zero as the LVDC's did; it costs nothing
in the fit (rms and maximum unchanged to 0.001 deg) and is not the default.

AS-506's commanded pitch is reconstructed as the direction of its sensed
acceleration less its attitude error:

    chi_cmd = chi_thr - e

- chi_thr is the pitch of the sensed velocity increment, atan2(-Z, X) in
  PACSS 13 (negative downrange), over a 5 s boxcar of PFT Table B-II's 1 s
  intervals (tools/pft_sensed_velocity.py takes the increments). It stands
  in for the vehicle's attitude: thrust along the body axis, the engines'
  deflection and the aerodynamic forces' tilt neglected.
- e is FER Figure 11-1's measured pitch attitude error (positive nose up,
  attitude less command), averaged over the same 5 s.

Each boxcar ends on whole range seconds, [k - 2, k + 3] s, so the samples
fall at k + 0.5 s; they run from the first boxcar after the pitch program's
start (13.2 s range) to the one that ends at the tilt arrest (160.0 s). The
boxcars that overlap the attitude transient of the centre engine's cutoff,
134-138 s, are left out: there Figure 11-1's error swings to -0.57 deg while
the engines take the vehicle back (panel 4), the thrust leaves the body axis
and the reconstruction's assumption fails (kept, they would raise the fit's
maximum residual to 0.19 deg there and move the fit by up to 0.09 deg).

The fit is GE504's form (Boeing D5-15706-4 Table 4-II): chi_Y = sum F_kn t^n,
n = 0..4, t in s from T1 (0.63 s range), on four segments split at t_S1 =
35, t_S2 = 80 and t_S3 = 115 s. The fitted quantity is each segment
polynomial's own 5 s mean, so the comparison is boxcar to boxcar. It is a
least-squares fit with equality constraints:

- the segments join exactly (equal values at 35, 80 and 115 s);
- chi_Y(159.37 s) = -68.90 deg, AS-506's held pitch after the arrest (FER
  Figure 10-4, OT and LVDC; datasheet section 14.3).

It then checks that the command rate stays under the LVDC's 1 deg/s limit
from the program start to the arrest, and prints the coefficients, the
residuals and a comparison with SA-504's presettings. The coefficients are
not used by the simulator yet (datasheet section 14.5 item 1).
"""
import csv
import math
import sys

import numpy as np

import pft_sensed_velocity as pft

T1 = 0.63                      # range time of T1 (FER Table 2-1)
JOINS = [35.0, 80.0, 115.0]    # s from T1 (GE504 t_S1..t_S3)
ARREST = 159.37                # s from T1: AS-506's tilt arrest, 160.0 s range
HOLD = -68.90                  # deg, AS-506's held pitch (FER Figure 10-4)
PROGRAM_START = 13.2           # range time (FER Table 2-2: T1 + 12.6)
CECO_TRANSIENT = (134.0, 138.0)  # range time: boxcars overlapping it are left out
RATE_LIMIT = 1.0               # deg/s (GE504 section 2.1.2)
SA504 = [                      # GE504 Table 5-I F_kn (datasheet section 8.4)
    [3.19840, -0.544236, 0.0351605, -0.00116379, 0.0000113886],
    [-10.9607, 0.946620, -0.0294206, 0.000207717, -0.000000439036],
    [78.7826, -2.83749, 0.0289710, -0.000178363, 0.000000463029],
    [69.9191, -2.007490, 0.0105367, -0.0000233163, 0.0000000136702],
]
SCALE = 100.0                  # the fit works in t / 100 s for conditioning


def read_trace(path):
    t, v = [], []
    with open(path) as f:
        lines = [line for line in f if not line.startswith("#")]
    for rec in csv.DictReader(lines):
        t.append(float(rec["time"]))
        v.append(float(rec["value"]))
    return np.array(t), np.array(v)


def boxcar_samples(rows, trace_t, trace_v):
    """(centre range time, chi_thr, e) for each 5 s boxcar [k-2, k+3]: the
    sum of the rows' intervals within it (the event rows split some)."""
    inc = pft.sensed_increments(rows)
    out = []
    k = math.ceil(PROGRAM_START) + 2
    while k + 3 <= ARREST + T1 + 1e-9:
        dv = (0.0, 0.0, 0.0)
        for t0, t1, d in inc:
            if t0 >= k - 2 - 1e-9 and t1 <= k + 3 + 1e-9:
                dv = pft.add(dv, d)
        chi = math.degrees(math.atan2(-dv[2], dv[0]))
        fine = np.interp(np.linspace(k - 2, k + 3, 501), trace_t, trace_v)
        e = float((fine.sum() - 0.5 * (fine[0] + fine[-1])) / 500)   # trapezoid mean
        if k + 3 <= CECO_TRANSIENT[0] or k - 2 >= CECO_TRANSIENT[1]:
            out.append((k + 0.5, chi, e))
        k += 1
    return out


def segment(t):
    """Segment index of time t (s from T1)."""
    return sum(t >= j for j in JOINS)


def mean_row(a, b):
    """Row of the design matrix: the 5 s mean of the piecewise quartic over
    [a, b] (s from T1), in the scaled coefficients G_kn = F_kn * SCALE^n."""
    row = np.zeros(20)
    edges = [a] + [j for j in JOINS if a < j < b] + [b]
    for lo, hi in zip(edges, edges[1:]):
        k = segment(0.5 * (lo + hi))
        for n in range(5):
            row[5 * k + n] += ((hi / SCALE) ** (n + 1) - (lo / SCALE) ** (n + 1)) * SCALE / (n + 1) / (b - a)
    return row


def value_row(t, k, deriv=0):
    row = np.zeros(20)
    for n in range(deriv, 5):
        c = math.factorial(n) / math.factorial(n - deriv)
        row[5 * k + n] = c * (t / SCALE) ** (n - deriv) / SCALE ** deriv
    return row


def fit(samples, start_zero=False):
    A = np.array([mean_row(tc - 2.5 - T1, tc + 2.5 - T1) for tc, _, _ in samples])
    y = np.array([chi - e for _, chi, e in samples])
    C, d = [], []
    for i, j in enumerate(JOINS):
        C.append(value_row(j, i) - value_row(j, i + 1))
        d.append(0.0)
    C.append(value_row(ARREST, 3))
    d.append(HOLD)
    if start_zero:
        C.append(value_row(PROGRAM_START - T1, 0))
        d.append(0.0)
    C, d = np.array(C), np.array(d)
    n, m = A.shape[1], C.shape[0]
    K = np.zeros((n + m, n + m))
    K[:n, :n] = 2 * A.T @ A
    K[:n, n:] = C.T
    K[n:, :n] = C
    rhs = np.concatenate([2 * A.T @ y, d])
    g = np.linalg.solve(K, rhs)[:n]
    F = [[g[5 * k + i] / SCALE ** i for i in range(5)] for k in range(4)]
    return F, A @ g - y, y


def chi(F, t, deriv=0):
    k = segment(t)
    return sum(math.factorial(n) / math.factorial(n - deriv) * F[k][n] * t ** (n - deriv)
               for n in range(deriv, 5))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    pft_path = args[0] if args else "tools/data/pft506_table_b2.csv"
    err_path = args[1] if len(args) > 1 else "tools/data/fer506_fig11_1_pitch_error.csv"
    rows = pft.read_rows(pft_path)
    tt, vv = read_trace(err_path)
    samples = boxcar_samples(rows, tt, vv)
    F, res, y = fit(samples, start_zero="--start-zero" in sys.argv)
    if "--swift" in sys.argv:
        print("[")
        for k in range(4):
            print("    [" + ", ".join(repr(float(c)) for c in F[k]) + "],")
        print("]")
        return

    print(f"{len(samples)} boxcars, centres {samples[0][0]:.1f} to {samples[-1][0]:.1f} s range")
    print(f"residual (fit - reconstruction): rms {math.sqrt(float(np.mean(res ** 2))):.3f} deg, "
          f"max {float(np.max(np.abs(res))):.3f} deg at {samples[int(np.argmax(np.abs(res)))][0]:.1f} s")
    print()
    print("AS-506 pre-IGM pitch program, GE504 form: chi_Y = sum F_kn t^n, t in s from T1")
    print(f"{'segment':16} {'F_k0 (deg)':>14} {'F_k1 (deg/s)':>14} {'F_k2':>14} {'F_k3':>14} {'F_k4':>14}")
    names = ["1 (t < 35)", "2 (35-80)", "3 (80-115)", "4 (>= 115)"]
    for k in range(4):
        print(f"{names[k]:16} " + " ".join(f"{F[k][n]:14.7g}" for n in range(5)))
    print()
    for i, j in enumerate(JOINS):
        a, b = chi(F, j - 1e-9), chi(F, j)
        ra, rb = chi(F, j - 1e-9, 1), chi(F, j, 1)
        print(f"join at T1 + {j:5.1f} s: {a:9.4f} / {b:9.4f} deg; rate {ra:+.4f} / {rb:+.4f} deg/s")
    ts = np.arange(PROGRAM_START - T1, ARREST + 1e-9, 0.01)
    rates = [chi(F, t, 1) for t in ts]
    imax = int(np.argmax(np.abs(rates)))
    print(f"command at the program start (T1 + {PROGRAM_START - T1:.1f} s): {chi(F, PROGRAM_START - T1):+.3f} deg; "
          f"at T1 + 10.7 s, where the model starts it: {chi(F, 10.7):+.3f} deg")
    print(f"command at the arrest (T1 + {ARREST} s): {chi(F, ARREST):.3f} deg")
    print(f"largest rate from the program start to the arrest: {rates[imax]:+.3f} deg/s at T1 + {ts[imax]:.1f} s "
          f"({'within' if abs(rates[imax]) < RATE_LIMIT else 'OVER'} the {RATE_LIMIT} deg/s limit)")
    print()
    print(f"{'range t (s)':>11} {'chi_thr':>9} {'error':>8} {'command':>9} {'fit':>9} {'fit-cmd':>8} {'SA-504':>9} {'x1.025':>9}")
    for (tc, c, e), r in zip(samples, res):
        if abs(tc - round(tc / 10) * 10 - 0.5) < 1e-6 or tc == samples[-1][0]:
            s504 = chi(SA504, tc - T1)
            print(f"{tc:11.1f} {c:9.3f} {e:8.3f} {c - e:9.3f} {c - e + r:9.3f} {r:+8.3f} {s504:9.3f} {1.025 * s504:9.3f}")


if __name__ == "__main__":
    main()

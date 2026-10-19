#!/usr/bin/env python3
"""Internal checks on the Apollo spacecraft and entry CSVs in tools/data.

Each check uses only what the documents print: a table's own totals and
ratios, two tables of one document that state the same quantity, or simple
mechanics (a Kepler coast, a rocket-equation mass). They catch misread
digits and record where the printed documents disagree with themselves.
The transcription log, docs/data/apollo-spacecraft/README.md, quotes the
results.

    python3 tools/check_apollo_data.py           # prints every check, exits 1 on a failure
"""
import csv
import math
import os
import sys

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
FT = 0.3048
failures = []


def rows(name):
    with open(os.path.join(DATA, name)) as f:
        return list(csv.DictReader(line for line in f if not line.startswith("#")))


def check(label, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
    if not ok:
        failures.append(label)


def num(s):
    return float(s.replace(" ", "").replace("·", ""))


def by_param(name):
    return {(r.get("table") or r.get("section"), r["parameter"]): r for r in rows(name)}


# --------------------------------------------------------------- 68-FM-184
def fm184():
    for r in rows("68fm184_table1a_cm_trim.csv"):
        d = num(r["c_l"]) / num(r["c_d"]) - num(r["l_over_d"])
        check(f"68-FM-184 I(a) M {r['mach']}: C_L/C_D = L/D", abs(d) < 2.5e-5, f"{d:+.1e}")

    p = by_param("68fm184_table1bcd_csm.csv")
    v = lambda t, k: num(p[(t, k)]["value"])
    parts = sum(v("I(c)", k) for k in ("CM (with RCS)", "SM (with RCS)", "SLA ring", "Tanked SPS propellant"))
    check("68-FM-184 I(c): CM + SM + SLA ring + SPS propellant = CSM", parts == v("I(c)", "CSM with propellant"),
          f"{parts:.0f} lb")
    isp = v("I(b)", "SPS thrust (steady state)") / v("I(b)", "SPS propellant flow rate")
    check("68-FM-184 I(b): SPS thrust / flow = Isp", abs(isp - v("I(b)", "SPS specific impulse")) < 0.01, f"{isp:.3f} s")
    flow = v("I(b)", "SM RCS thrust (4 jet)") / v("I(b)", "SM RCS specific impulse")
    check("68-FM-184 I(b): SM RCS thrust / Isp rounds to the printed 4-jet flow",
          round(flow, 2) == v("I(b)", "SM RCS propellant flow rate (4 jet)"), f"{flow:.4f} lb/s")
    a, b = v("I(d)", "Earth equatorial radius a"), v("I(d)", "Earth polar radius b")
    mu1 = v("I(d)", "Gravity coefficient A0 (oblate earth)") * a**2
    mu2 = v("I(d)", "Gravity at sea level g") * v("I(d)", "Radius of spherical earth R_E") ** 2
    check("68-FM-184 I(d): A0 a^2 = g R_E^2 (one mu)", abs(mu1 / mu2 - 1) < 1e-7, f"mu = {mu1:.7e} ft^3/s^2")
    check("68-FM-184 I(d): Fischer 1960 flattening", abs(a / (a - b) - 298.3) < 0.01, f"1/{a / (a - b):.3f}")

    # 5.1.4: 2.6 s of four +X jets on the 32 458 lb CSM gives about 1.0 ft/s.
    dv = v("I(b)", "SM RCS thrust (4 jet)") * 2.6 / (v("I(c)", "CSM with propellant") / 32.174049)
    check("68-FM-184 5.1.4: 2.6 s of 4 jets = 1.0 ft/s", abs(dv - 1.0) < 0.05, f"{dv:.3f} ft/s")

    q = by_param("68fm184_table8i_9_deorbit_entry.csv")
    m = [[float(x) for x in q[("VIII(i)", f"REFSMMAT row {i}")]["value"].split()] for i in (1, 2, 3)]
    err = max(abs(sum(m[i][k] * m[j][k] for k in range(3)) - (i == j)) for i in range(3) for j in range(3))
    check("68-FM-184 VIII(i): REFSMMAT orthonormal", err < 2e-7, f"{err:.1e}")

    # IX: coast the entry state back 826 s (two-body, mu above) and compare the
    # radius with the deorbit altitude as read (1 043 076.5 ft).
    def radius(lat_deg, h):
        phi, e2 = math.radians(lat_deg), 1 - (b / a) ** 2
        n = a / math.sqrt(1 - e2 * math.sin(phi) ** 2)
        return math.hypot((n + h) * math.cos(phi), (n * (1 - e2) + h) * math.sin(phi))

    w = lambda t, k: float(q[(t, k)]["si"])
    r0 = radius(math.degrees(w("IX(b)", "Geodetic latitude")), w("IX(b)", "Altitude") / FT)
    g0 = w("IX(b)", "Inertial flight-path angle")
    s = [r0, 0.0, w("IX(b)", "Inertial velocity") / FT * math.sin(g0), w("IX(b)", "Inertial velocity") / FT * math.cos(g0)]
    f = lambda s: [s[2], s[3]] + [-mu1 * c / math.hypot(s[0], s[1]) ** 3 for c in s[:2]]
    h = -0.5
    for _ in range(int(w("IX(b)", "Coast time (deorbit to 400 000 ft)") / -h)):
        k1 = f(s); k2 = f([x + h / 2 * k for x, k in zip(s, k1)])
        k3 = f([x + h / 2 * k for x, k in zip(s, k2)]); k4 = f([x + h * k for x, k in zip(s, k3)])
        s = [x + h / 6 * (p1 + 2 * p2 + 2 * p3 + p4) for x, p1, p2, p3, p4 in zip(s, k1, k2, k3, k4)]
    alt = math.hypot(s[0], s[1]) - radius(math.degrees(w("IX(a)", "Geodetic latitude")), 0)
    read = w("IX(a)", "Altitude (Earth-fixed position)") / FT
    check("68-FM-184 IX: entry state coasted back 826 s reaches the deorbit altitude as read (no J2, burn ignored)",
          abs(alt - read) < 10000, f"{alt:,.0f} ft against {read:,.1f} ft")
    dip = math.degrees(math.acos(radius(11.89, 0) / radius(11.89, read)))
    check("68-FM-184 IX(a)/5.4.1: 31.7 deg below the horizon + dip = retro attitude 49.3",
          abs(31.7 + dip - 49.3) < 0.2, f"dip {dip:.2f} deg")


# -------------------------------------------------- Apollo 7 Mission Report
def a7():
    a5 = rows("a07_mr_table_a5_1.csv")
    w = [num(r["weight_lb"]) for r in a5]
    check("A7 A.5-I: the weight never increases from row to row", all(x >= y for x, y in zip(w, w[1:])))

    t21 = {r["event"]: r for r in rows("a07_mr_table_2_1.csv")}
    ordinal = ("First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth")
    drops = 0.0
    for n, o in enumerate(ordinal):
        before, after = a5[2 + 2 * n], a5[3 + 2 * n]          # SPS-n ignition row and the coast row after it
        dur = float(t21[f"{o} service propulsion cutoff"]["actual_s"]) - float(t21[f"{o} service propulsion ignition"]["actual_s"])
        d = num(before["weight_lb"]) - num(after["weight_lb"])
        drops += d
        if dur > 5:
            check(f"A7 A.5-I: SPS-{n + 1} weight drop / Table 2-I burn time near 68-FM-184's 67.49 lb/s (RCS ullage included)",
                  0.95 < d / dur / 67.49 < 1.12, f"{d:.0f} lb in {dur:.1f} s = {d / dur:.1f} lb/s")
    c = {(r["system"], r["item"], r["component"], r["substance"]): num(r["value_lb"])
         for r in rows("a07_mr_sec5_21_consumables.csv")}
    sps = c[("SPS", "consumed", "", "fuel")] + c[("SPS", "consumed", "", "oxidizer")]
    check("A7 A.5-I against 5.21: the weight drops across the eight SPS burns = SPS propellant consumed",
          abs(drops - sps) < 0.002 * sps, f"{drops:.0f} lb against {sps:.1f} lb")

    # The SM left at CM/SM separation (rows 18 - 19) against 68-FM-184's
    # preflight SM (with RCS, without SPS propellant) less the SM RCS and
    # cryogenics consumed, plus the SPS propellant remaining (5.21).
    sm = num(a5[17]["weight_lb"]) - num(a5[18]["weight_lb"])
    fm = {r["parameter"]: num(r["value"]) for r in rows("68fm184_table1bcd_csm.csv")}
    est = (fm["SM (with RCS)"] - c[("SM RCS", "consumed", "total", "fuel+oxidizer")]
           - c[("cryogenics", "consumed", "total", "hydrogen")] - c[("cryogenics", "consumed", "total", "oxygen")]
           + c[("SPS", "remaining at separation", "", "fuel")] + c[("SPS", "remaining at separation", "", "oxidizer")])
    check("A7 A.5-I SM at separation = 68-FM-184 SM - RCS and cryogenics used + SPS remaining (5.21)",
          abs(sm - est) < 25, f"{sm:.0f} lb against {est:.1f} lb")

    # 5.21: sum lines and loaded - consumed = remaining.
    for system, subs in (("SPS", ("fuel", "oxidizer")), ("SM RCS", ("fuel", "oxidizer")), ("CM RCS", ("fuel", "oxidizer")),
                         ("cryogenics", ("hydrogen", "oxygen"))):
        for s in subs:
            parts = [v for (sy, it, co, su), v in c.items() if sy == system and it == "loaded" and su == s and co != "total"]
            check(f"A7 5.21 {system} {s}: loaded parts sum to the total", abs(sum(parts) - c[(system, "loaded", "total", s)]) < 0.05)
    for s in ("fuel", "oxidizer"):
        left = c[("SPS", "loaded", "total", s)] - c[("SPS", "consumed", "", s)] - c[("SPS", "remaining at separation", "", s)]
        check(f"A7 5.21 SPS {s}: loaded - consumed = remaining", abs(left) < 0.05)
        for sysn in ("system A", "system B"):
            left = c[("CM RCS", "loaded", sysn, s)] - c[("CM RCS", "consumed", sysn, s)] - c[("CM RCS", "remaining at landing", sysn, s)]
            known = (sysn, s) == ("system B", "fuel")
            check(f"A7 5.21 CM RCS {sysn} {s}: loaded - consumed = remaining"
                  + (" (known not to close as printed: graded M)" if known else ""),
                  abs(left - (3.0 if known else 0)) < 0.05, f"{left:+.1f} lb")
    rcs = c[("SM RCS", "loaded", "total", "fuel")] + c[("SM RCS", "loaded", "total", "oxidizer")]
    left = rcs - c[("SM RCS", "consumed", "total", "fuel+oxidizer")] - c[("SM RCS", "remaining at separation", "total", "fuel+oxidizer")]
    check("A7 5.21 SM RCS: loaded - consumed = remaining", abs(left) < 0.05)

    # Table 3-III: the ft and n mi altitudes, and its times against Table 2-I.
    t33 = rows("a07_mr_table_3_3.csv")
    alts = [r for r in t33 if r["condition"] == "Altitude"]
    worst = max(abs(float(a[k + "_si"]) - float(b[k + "_si"])) / 1852
                for a, b in zip(alts[0::2], alts[1::2]) for k in ("ign_planned", "ign_actual", "cut_planned", "cut_actual") if a[k])
    check("A7 3-III: ft and n mi altitudes agree", worst < 0.03, f"worst {worst:.3f} n mi")
    mismatch = []
    for n, o in enumerate(ordinal):
        r = next(r for r in t33 if r["maneuver"] == f"{o} service propulsion maneuver" and r["condition"] == "Time")
        for col, ev in (("ign_actual", "ignition"), ("cut_actual", "cutoff")):
            if abs(float(r[col + "_si"]) - float(t21[f"{o} service propulsion {ev}"]["actual_s"])) > 0.05:
                mismatch.append(f"SPS-{n + 1} {ev}")
    check("A7 3-III against 2-I: SPS actual times agree except SPS-1 cutoff and SPS-4 ignition (printed so; graded M)",
          mismatch == ["SPS-1 cutoff", "SPS-4 ignition"], ", ".join(mismatch))

    e = {r["parameter"]: r for r in rows("a07_mr_sec5_16_entry.csv")}
    dv = num(e["Entry interface velocity, onboard computer"]["value"]) - num(e["Entry interface velocity, planned"]["value"])
    check("A7 5.16: entry velocity 2.2 ft/s above the plan", abs(dv - 2.2) < 1e-6, f"{dv:.1f} ft/s")


if __name__ == "__main__":
    for fn in (fm184, a7):
        fn()
    print(f"{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)

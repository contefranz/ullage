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


# ------------------------------------------------- Apollo 11 Mission Report
def combine(parts, product_sign):
    """Weight, CG (in) and the six inertias (slug ft^2) of rigidly joined
    parts, each a row of Table A-I. product_sign is +1 if the table's products
    are +integral(x y dm), -1 if they are -integral(x y dm)."""
    g = 32.174049
    w = sum(num(p["weight_lb"]) for p in parts)
    c = [sum(num(p["weight_lb"]) * num(p[k]) for p in parts) / w for k in ("xa_in", "ya_in", "za_in")]
    out = {"weight_lb": w, "xa_in": c[0], "ya_in": c[1], "za_in": c[2]}
    for k in ("ixx", "iyy", "izz", "ixy", "ixz", "iyz"):
        total = 0.0
        for p in parts:
            m = num(p["weight_lb"]) / g
            d = [(num(p[a]) - ci) / 12 for a, ci in zip(("xa_in", "ya_in", "za_in"), c)]
            i, j = "xyz".index(k[1]), "xyz".index(k[2])
            if i == j:
                shift = m * (sum(x * x for x in d) - d[i] ** 2)
            else:
                shift = product_sign * m * d[i] * d[j]
            total += num(p[k + "_slugft2"]) + shift
        out[k] = total
    # What the printed CGs' rounding (0.05 in) can move a product by.
    out["product_rounding"] = max(
        sum(num(p["weight_lb"]) / g * (abs(num(p[a]) - ca) + abs(num(p[b]) - cb)) / 12 * 0.05 / 12 for p in parts)
        for (a, ca), (b, cb) in (((x, c[i]), (y, c[j])) for i, x in enumerate(("xa_in", "ya_in", "za_in"))
                                 for j, y in enumerate(("xa_in", "ya_in", "za_in")) if i < j)) + 1.5
    return out


def a11():
    t = {(r["group"], r["event"]): r for r in rows("a11_mr_table_a_1.csv") if r["section"] == "spacecraft"}
    lm = {r["event"]: r for r in rows("a11_mr_table_a_1.csv") if r["section"] == "lunar module"}
    splits = (
        ("CSM + LM = total docked", [t[("Transposition and docking", "Command & service modules")],
                                     t[("Transposition and docking", "Lunar module")]], t[("", "Total docked")]),
        ("CSM + ascent stage = docked total", [t[("Docking", "Command & service modules")], t[("Docking", "Ascent stage")]],
         t[("Total after docking", "Ascent stage manned")]),
        ("SM + CM = CSM before separation", [t[("Command & service module separation / After", "Service module")],
                                             t[("Command & service module separation / After", "Command module")]],
         t[("Command & service module separation", "Before")]),
    )
    for label, parts, whole in splits:
        for sign in (+1, -1):
            c = combine(parts, sign)
            dw = c["weight_lb"] - num(whole["weight_lb"])
            dcg = max(abs(c[k] - num(whole[k])) for k in ("xa_in", "ya_in", "za_in"))
            dmom = max(abs(c[k] / num(whole[k + "_slugft2"]) - 1) for k in ("ixx", "iyy", "izz"))
            dprod = max(abs(c[k] - num(whole[k + "_slugft2"])) for k in ("ixy", "ixz", "iyz"))
            bound = c["product_rounding"]
            if sign > 0:
                check(f"A11 A-I {label}: weight, CG, moments and products (+integral x y dm)",
                      abs(dw) < 0.15 and dcg < 0.1 and dmom < 0.002 and dprod < bound,
                      f"weight {dw:+.1f} lb, CG {dcg:.2f} in, moments {dmom:.2%}, "
                      f"products {dprod:.0f} slug ft^2 (CG rounding allows {bound:.0f})")
            else:
                check(f"A11 A-I {label}: the products do not recombine as -integral x y dm",
                      dprod > 3 * bound, f"products off by {dprod:.0f} slug ft^2")

    after_as = num(t[("Total after docking", "Ascent stage unmanned")]["weight_lb"]) - num(t[("", "After ascent stage jettison")]["weight_lb"])
    check("A11 A-I: docked total unmanned - after jettison = LM jettison weight (LM section)",
          abs(after_as - num(lm["Jettison"]["weight_lb"])) < 0.05, f"{after_as:.1f} lb")
    w = [num(r["weight_lb"]) for r in lm.values()]
    check("A11 A-I: the LM section weight decreases after separation", all(x >= y for x, y in zip(w[1:], w[2:])))
    cm = [num(t[k]["weight_lb"]) for k in (("Command & service module separation / After", "Command module"),
                                          ("", "Entry"), ("", "Drogue deployment"),
                                          ("", "Main parachute deployment"), ("", "Landing"))]
    check("A11 A-I: CM weight decreases from separation to landing", all(x > y for x, y in zip(cm, cm[1:])))

    c = {(r["system"], r["item"], r["component"], r["substance"]): r for r in rows("a11_mr_sec8_11_consumables.csv")}
    v = lambda *k: num(c[k]["actual_lb"])
    for s in ("fuel", "oxidizer"):
        check(f"A11 8.11.1 SPS {s}: tanks + lines = loaded, loaded - consumed = remaining",
              v("SPS", "loaded", "in tanks", s) + v("SPS", "loaded", "in lines", s) == v("SPS", "loaded", "total", s)
              and abs(v("SPS", "loaded", "total", s) - v("SPS", "consumed", "", s) - v("SPS", "remaining at CM/SM separation", "", s)) < 0.05)
        quads = sum(v("SM RCS", "loaded", f"quad {q}", s) for q in "ABCD")
        check(f"A11 8.11.2 SM RCS {s}: quads = loaded, loaded - consumed = remaining",
              quads == v("SM RCS", "loaded", "total", s)
              and abs(quads - v("SM RCS", "consumed", "", s) - v("SM RCS", "remaining at CM/SM separation", "", s)) < 0.05)
    for sysn in ("system A", "system B", "total"):
        for s in ("fuel", "oxidizer"):
            left = (v("CM RCS", "loaded", sysn, s) - v("CM RCS", "consumed", sysn, s)
                    - v("CM RCS", "remaining at main parachute deployment", sysn, s))
            known = s == "fuel" and sysn in ("system A", "total")
            check(f"A11 8.11.2 CM RCS {sysn} {s}: loaded - consumed = remaining"
                  + (" (printed 15.0 consumed, 14.0 closes: graded M)" if known else ""),
                  abs(left - (-1.0 if known else 0.0)) < 0.05, f"{left:+.1f} lb")
    for s in ("hydrogen", "oxygen"):
        left = (v("cryogenics", "available at lift-off", "total", s) - v("cryogenics", "consumed", "total", s)
                - v("cryogenics", "remaining at CM/SM separation", "total", s))
        check(f"A11 8.11.3 {s}: available - consumed = remaining", abs(left) < 0.05)

    # The SM at separation against the SPS, SM RCS and cryogenics remaining.
    sm = num(t[("Command & service module separation / After", "Service module")]["weight_lb"])
    resid = (v("SPS", "remaining at CM/SM separation", "", "fuel") + v("SPS", "remaining at CM/SM separation", "", "oxidizer")
             + v("SM RCS", "remaining at CM/SM separation", "", "total")
             + v("cryogenics", "remaining at CM/SM separation", "total", "hydrogen")
             + v("cryogenics", "remaining at CM/SM separation", "total", "oxygen"))
    check("A11: SM at separation less its remaining propellant and cryogenics (dry SM, information)",
          8000 < sm - resid < 9500, f"{sm - resid:.0f} lb")


# ------------------------------------------------ TN D-5399, D-5276, D-7437
def technical_notes():
    t2 = rows("tnd5399_table2_apollo4_cg_mass.csv")
    ratios = [num(r["weight_lb"]) / num(r["mass_slug"]) for r in t2]
    check("TN D-5399 II: lb/slug is 32.2 on every row but the entry row (its mass is graded M)",
          all(abs(x - 32.2) < 0.05 for x in ratios[1:]) and abs(ratios[0] - 32.35) < 0.01,
          f"{min(ratios[1:]):.3f}-{max(ratios[1:]):.3f}, entry {ratios[0]:.3f}")
    times = [num(r["time_s"]) for r in t2]
    check("TN D-5399 II: times increase", all(a < b for a, b in zip(times, times[1:])))
    drop = num(t2[0]["weight_lb"]) - num(t2[-2]["weight_lb"])
    check("TN D-5399 II: entry - drogue weight = ~90 lb RCS + ~210 lb ablator (text)", drop == 300, f"{drop:.0f} lb")
    t1 = {r["event"]: num(r["time_s"]) for r in rows("tnd5399_table1_apollo4_events.csv") if r["time_s"]}
    check("TN D-5399 I and II agree on entry, both peak g and drogue times",
          [t1["Entry interface (400 000 ft)"], t1["First peak g"], t1["Second peak g"], t1["Drogue parachute deployment"]]
          == [times[0], times[1], times[2], times[-2]])

    runs = rows("tnd5276_table1_trim_points.csv")
    ld151 = [num(r["l_over_d_at_151"]) for r in runs if r["l_over_d_at_151"]]
    ld162 = [num(r["l_over_d_at_162"]) for r in runs if r["l_over_d_at_162"]]
    check("TN D-5276 I: mean L/D at 151 deg = the summary's 0.435", abs(sum(ld151) / len(ld151) - 0.435) < 0.0015,
          f"{sum(ld151) / len(ld151):.4f} over {len(ld151)} runs")
    check("TN D-5276 I: mean L/D at 162 deg within the stated +/-0.025 of the summary's 0.255",
          abs(sum(ld162) / len(ld162) - 0.255) < 0.025, f"{sum(ld162) / len(ld162):.4f} over {len(ld162)} runs")
    z = [num(r["zcg_over_d"]) for r in runs]
    hi, lo = [x for x in z if x > 0.04], [x for x in z if x < 0.04]
    check("TN D-5276 I: the two CG groups average z/d 0.046 and 0.028",
          abs(sum(hi) / len(hi) - 0.046) < 0.001 and abs(sum(lo) / len(lo) - 0.028) < 0.001,
          f"{sum(hi) / len(hi):.4f}, {sum(lo) / len(lo):.4f}")

    e = {r["parameter"]: r for r in rows("tnd7437_els.csv")}
    for stage, line_in in (("First", 264), ("Second", 780)):
        d = num(e[f"{stage}-stage reefed diameter D_R{1 if stage == 'First' else 2}"]["si"]) / 0.3048
        check(f"TN D-7437 A-15: {stage.lower()}-stage reefing line ({line_in} in) = pi x D_R",
              abs(line_in / 12 / math.pi - d) < 0.05, f"{line_in / 12 / math.pi:.2f} ft against {d:.1f} ft")
    # Sea-level descent rate on three full-open mains at Apollo 7's landing
    # weight (Mission Report A.5-I row 24): information for track E2, since the
    # printed 32 ft/s is the design figure for heavier CMs and real clusters.
    w = num(rows("a07_mr_table_a5_1.csv")[-1]["weight_lb"])
    cds = 3 * num(e["Drag area, full open (average, each)"]["value"])
    v = math.sqrt(2 * w / (2.3768846e-3 * cds))
    check("TN D-7437: three mains (3 x 4200 ft^2) at Apollo 7's 11 409 lb fall under the 32 ft/s splashdown figure (information)",
          v < 32, f"{v:.1f} ft/s at sea level")


# ------------------------------------------- AOH, 68-FM-160 and MSC-03466
def handbook_and_notes():
    a = {r["parameter"]: r for r in rows("aoh_block2_sps_rcs.csv")}
    v = lambda k: num(a[k]["value"].split(" (")[0])
    for p, s, sp, t in (("oxidizer", "Oxidizer storage tank capacity", "Oxidizer sump tank capacity", "Total oxidizer"),
                        ("fuel", "Fuel storage tank capacity", "Fuel sump tank capacity", "Total fuel")):
        check(f"AOH 2.4-42: {p} storage + sump = total", abs(v(s) + v(sp) - v(t)) < 0.005, f"{v(s) + v(sp):.2f} lb")
    ratio = v("Total oxidizer") / v("Total fuel")
    check("AOH 2.4-42: tank oxidizer/fuel = the 1.6 mixture ratio", abs(ratio - 1.6) < 0.002, f"{ratio:.4f}")
    full = v("Total oxidizer") / 1.034 + v("Total fuel") / 1.034
    check("AOH 2.4-2/2.4-42: the 22 300 lb ullage limit is 56.25-56.4 % of the tanks' 100 % (graded M)",
          0.5620 < 22300 / full < 0.5645, f"{22300 / full:.2%} of {full:,.0f} lb")
    panel = num({r["parameter"]: r for r in rows("68fm160_sla_panels.csv")}["Average panel weight"]["value"])
    check("68-FM-160: four panels against AS-506's FER 1 166 kg of panels (information)",
          True, f"{4 * panel * 0.45359237:.0f} kg against 1 166 kg")
    m = [r for r in rows("msc03466_sm_jettison.csv") if r["source"] == "Table I"]
    check("MSC-03466 Table I: five missions, Apollo 7-11", [r["item"] for r in m] == [f"Apollo {n}" for n in range(7, 12)])


if __name__ == "__main__":
    for fn in (fm184, a7, a11, technical_notes, handbook_and_notes):
        fn()
    print(f"{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)

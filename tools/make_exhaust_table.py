#!/usr/bin/env python3
"""Run NASA CEA on the decks in tools/cea and write tools/data/cea_apollo_exhaust.csv.

    python3 -I tools/make_exhaust_table.py --cea /opt/cea/bin/cea \
        --cea-version "3.3.4 (github.com/nasa/cea 2f79a64)"

NASA's Chemical Equilibrium with Applications (github.com/nasa/cea,
Apache-2.0) runs outside the repository: only its input decks
(tools/cea/*.inp) and this table are committed. Each deck holds one rocket
problem and cites its inputs; CASES below says which of its expansions and
area ratios each row takes, and the engine data the generator checks it
against. The thermodynamic library is CEA's own thermo.lib, found next to the
executable (../data) unless --data names its directory.

For each row the table gives CEA's chamber and exit state, and three derived
quantities the plume model needs:
- gamma_nozzle, the one ratio of specific heats with which the isentropic
  relations (NozzleFlow.swift) give CEA's pc/pe at the row's area ratio, and
  mach_nozzle, the exit Mach number it gives (against CEA's own, mach_exit);
- fuel_rich, the mole fraction of CO and H2 at the exit, which afterburns in air;
- y_al2o3 and y_condensed, the mass fractions of alumina and of all condensed
  species at the exit.
Where a row has a reference thrust, the generator also gives the chamber
pressure that CEA's vacuum thrust coefficient needs to deliver it through
the row's exit diameter (pc_check_psia), or, for a nozzle whose exit is not
known, the exit diameter it needs at the deck's chamber pressure
(exit_diameter_in, marked "derived").

Standard library only.
"""

import argparse
import csv
import hashlib
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DECKS = os.path.join(HERE, "cea")
OUT = os.path.join(HERE, "data", "cea_apollo_exhaust.csv")

PSI = 6894.757293168    # Pa
LBF = 4.4482216152605   # N
INCH = 0.0254           # m

# Each row: (row id, deck stem, expansion, o/f in the deck (None: its only
# one), area ratio, engine, propellants, reference vacuum thrust (lbf) or
# None, exit diameter (in) or None (derived from the thrust), note).
CASES = [
    ("F-1", "f1", "frozen", None, 16.0, "F-1 thrust chamber", "RP-1/LOX", 1_748_200,
     2 * math.sqrt(10.10 / math.pi) / INCH,
     "Betts' rated vacuum thrust (the turbine exhaust's share in it); exit from AS506.f1ExitArea, 10.10 m^2"),
    ("F-1 at 10:1", "f1", "frozen", None, 10.0, "F-1 chamber's end", "RP-1/LOX", None, None,
     "where the turbine exhaust film is injected"),
    ("J-2", "j2", "frozen", None, 27.5, "J-2", "LH2/LOX", 230_000, 14.7 * math.sqrt(27.5),
     "rated 230,000 lbf; exit from AS506's 14.7 in throat at 27.5:1"),
    ("J-2 EMR 4.34", "j2_settings", "frozen", 4.34, 27.5, "J-2, S-II low EMR", "LH2/LOX", None, None, "record only"),
    ("J-2 EMR 4.96", "j2_settings", "frozen", 4.96, 27.5, "J-2, S-IVB burn 1", "LH2/LOX", None, None, "record only"),
    ("J-2 EMR 5.0", "j2_settings", "frozen", 5.0, 27.5, "J-2, S-II start", "LH2/LOX", None, None, "record only"),
    ("SPS", "sps", "frozen", None, 62.5, "SPS (AJ10-137)", "A-50/N2O4", 21_080, 98.4,
     "68-FM-184's 21,080 lbf; the AOH's 98.4 in exit"),
    ("SPS at 6:1", "sps", "frozen", None, 6.0, "SPS ablative chamber's end", "A-50/N2O4", None, None, "record only"),
    ("SM RCS", "sm_rcs", "frozen", None, 40.0, "SM RCS (R-4D)", "MMH/N2O4", 99.8, 5.6,
     "68-FM-184's 99.8 lbf a jet; the AOH's 5.6 in exit"),
    ("CM RCS", "cm_rcs", "frozen", None, 9.0, "CM RCS (SE-8)", "MMH/N2O4", 93.0, 2.13,
     "the AOH's 93 lbf and 2.13 in exit"),
    ("APS attitude", "aps", "frozen", None, 40.0, "S-IVB APS attitude (TR-204)", "MMH/N2O4", 147.0, None,
     "AS506Data's 147 lbf; exit derived"),
    ("APS ullage", "aps", "frozen", None, 9.0, "S-IVB APS ullage (SE-7-1)", "MMH/N2O4", 72.0, None,
     "AS506Data's 72 lbf; exit derived"),
    ("Tower jettison", "tjm", "equilibrium", None, 14.0, "LES tower jettison motor (TE-380)", "TP-E-8104",
     None, 2 * math.sqrt(14.0 * 10.18 / math.pi),
     "one of its two nozzles: TN D-6295's 10.18 in^2 throat (nozzle A) at 14:1"),
    ("S-IC retro", "sic_retro", "equilibrium", None, 4.5, "S-IC retro (TE-M-424)", "TP-E-8104 (proxy)",
     87_000, None, "AS-501 FER Table 12-2's 87,000 lbf; exit derived"),
    ("S-II ullage", "sii_ullage", "equilibrium", None, 7.5, "S-II ullage motor", "82 % AP (proxy)",
     23_000, None, "MSFC-MAN-506's 23,000 lbf; exit derived"),
    ("S-II retro", "sii_retro", "equilibrium", None, 4.3, "S-II retro (TE-M-29)", "TP-E-8104 (proxy)",
     34_810, None, "MSFC-MAN-506's 34,810 lbf; exit derived"),
    ("S-IVB ullage", "sivb_ullage", "equilibrium", None, 16.0, "S-IVB ullage (TX-280)", "TP-E-8104 (proxy)",
     3_390, None, "MSFC-MAN-506's 3,390 lbf; exit derived"),
]

CONDENSED = re.compile(r"\((a|b|c|d|L|cr|I|II|III|IV)\)$")
FUEL_RICH = ("CO", "H2")


def number(text):
    try:
        return float(text)
    except ValueError:
        return float("nan")


def run_cea(cea, data, stem, mass_fractions):
    """CEA's output for deck `stem`, with mass fractions instead of mole
    fractions when asked (the deck's output line gains "massf")."""
    with tempfile.TemporaryDirectory() as work:
        deck = open(os.path.join(DECKS, stem + ".inp")).read()
        if mass_fractions:
            deck = re.sub(r"^(\s*output\b.*)$", r"\1 massf", deck, count=1, flags=re.M)
        open(os.path.join(work, "case.inp"), "w").write(deck)
        for lib in ("thermo.lib", "trans.lib"):
            shutil.copy(os.path.join(data, lib), work)
        subprocess.run([cea, "case"], cwd=work, check=True, capture_output=True)
        return open(os.path.join(work, "case.out")).read()


def blocks(output):
    """The rocket results in CEA's output: per block, its expansion, o/f,
    station rows and species fractions (each a list over the stations, the
    chamber first; frozen fractions have one column)."""
    found = []
    for section in re.split(r"THEORETICAL ROCKET PERFORMANCE ASSUMING ", output)[1:]:
        kind = "equilibrium" if section.startswith("EQUILIBRIUM") else "frozen"
        # A deck with several o/f values prints one block for each.
        for part in re.split(r"\n(?=O/F =)", section)[1:]:
            found.append(block(kind, part))
    return found


def block(kind, part):
    """One o/f's results, from its O/F line on."""
    of = number(re.search(r"O/F =\s+([\d.Ee+-]+)", part).group(1))
    rows = {}
    for key in ("Pinf/P", "P, bar", "T, K", "M, (1/n)", "Gamma_s", "Son. Vel., m/s", "Mach",
                "Ae/At", "C*, m/s", "Cf", "Ivac, m/s", "Isp, m/s"):
        m = re.search(r"^ " + re.escape(key) + r"\s+(.*)$", part, re.M)
        if m:
            rows[key] = [number(v) for v in m.group(1).split()]
    fractions = {}
    m = re.search(r"(MOLE|MASS) FRACTIONS\s*\n(.*?)\n\s*\n(PRODUCTS|NOTE|\s*$)", part, re.S)
    if m:
        for line in m.group(2).splitlines():
            cells = line.split()
            if len(cells) >= 2:
                fractions[cells[0]] = [number(v) for v in cells[1:]]
    return {"kind": kind, "of": of, "rows": rows, "fractions": fractions}


def pick(found, kind, of, area_ratio):
    """The block of `kind` (at `of` when given) and the station index of
    `area_ratio` in its rows (the chamber is station 0)."""
    for b in found:
        if b["kind"] != kind or (of is not None and abs(b["of"] - of) > 1e-6):
            continue
        ratios = b["rows"]["Ae/At"]   # from the throat on
        for i, a in enumerate(ratios):
            if abs(a - area_ratio) < 1e-3 * area_ratio:
                return b, i + 1
    raise SystemExit(f"no {kind} block at o/f {of}, area ratio {area_ratio}")


def fraction(b, species, station):
    """A species' fraction at `station` (frozen blocks: their one column)."""
    v = b["fractions"].get(species)
    if not v:
        return 0.0
    return v[min(station, len(v) - 1)] if len(v) > 1 else v[0]


def area_ratio(m, g):
    return (2 * (1 + 0.5 * (g - 1) * m * m) / (g + 1)) ** (0.5 * (g + 1) / (g - 1)) / m


def supersonic_mach(a, g):
    lo, hi = 1.0, 2.0
    while area_ratio(hi, g) < a:
        hi *= 2
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if area_ratio(mid, g) < a:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def pressure_ratio(m, g):
    return (1 + 0.5 * (g - 1) * m * m) ** (-g / (g - 1))


def nozzle_gamma(a, pc_over_pe):
    """The γ whose isentropic expansion to area ratio `a` gives pc/pe; pc/pe
    rises with γ at a fixed area ratio."""
    lo, hi = 1.01, 1.67
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if 1 / pressure_ratio(supersonic_mach(a, mid), mid) < pc_over_pe:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def deck_pressure(stem):
    m = re.search(r"p,psia=([\d.]+)", open(os.path.join(DECKS, stem + ".inp")).read())
    return float(m.group(1))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--cea", default=shutil.which("cea") or "cea", help="the CEA executable")
    p.add_argument("--data", help="directory of thermo.lib and trans.lib (default: ../data from the executable)")
    p.add_argument("--cea-version", default="unknown", help="CEA's version, recorded in the table's header")
    p.add_argument("--out", default=OUT)
    args = p.parse_args()
    data = args.data or os.path.join(os.path.dirname(os.path.realpath(args.cea)), "..", "data")
    thermo = hashlib.sha256(open(os.path.join(data, "thermo.lib"), "rb").read()).hexdigest()

    outputs = {}
    rows = []
    for (row, stem, kind, of, ae, engine, propellants, thrust, exit_in, note) in CASES:
        if stem not in outputs:
            outputs[stem] = (blocks(run_cea(args.cea, data, stem, False)),
                             blocks(run_cea(args.cea, data, stem, True)))
        mole, mass = outputs[stem]
        b, i = pick(mole, kind, of, ae)
        bm, _ = pick(mass, kind, of, ae)
        r = b["rows"]
        pc, pe = r["P, bar"][0] * 1e5, r["P, bar"][i] * 1e5
        g_exit = r["Gamma_s"][i]
        g_noz = nozzle_gamma(ae, pc / pe)
        cstar = r["C*, m/s"][i - 1]
        cf_vac = r["Ivac, m/s"][i - 1] / cstar
        condensed = sum(fraction(bm, s, i) for s in bm["fractions"] if CONDENSED.search(s))
        alumina = fraction(bm, "AL2O3(a)", i) + fraction(bm, "AL2O3(L)", i)
        pc_check = ""
        exit_note = ""
        if thrust is not None and exit_in is not None:
            throat = math.pi * (exit_in * INCH / 2) ** 2 / ae
            pc_check = f"{thrust * LBF / (cf_vac * throat) / PSI:.1f}"
        elif thrust is not None:
            throat = thrust * LBF / (cf_vac * deck_pressure(stem) * PSI)
            exit_in = 2 * math.sqrt(ae * throat / math.pi) / INCH
            exit_note = "derived"
        rows.append({
            "row": row, "deck": f"tools/cea/{stem}.inp", "engine": engine, "propellants": propellants,
            "expansion": kind, "of_ratio": f"{b['of']:.4f}", "pc_psia": f"{pc / PSI:.1f}", "area_ratio": f"{ae:g}",
            "tc_k": f"{r['T, K'][0]:.2f}", "te_k": f"{r['T, K'][i]:.2f}", "pe_pa": f"{pe:.1f}",
            "pc_over_pe": f"{pc / pe:.3f}", "mach_exit": f"{r['Mach'][i]:.4f}",
            "gamma_chamber": f"{r['Gamma_s'][0]:.4f}", "gamma_exit": f"{g_exit:.4f}",
            "gamma_nozzle": f"{g_noz:.4f}", "mach_nozzle": f"{supersonic_mach(ae, g_noz):.4f}",
            "molar_mass_exit": f"{r['M, (1/n)'][i] / 1000:.6f}", "cstar_m_s": f"{cstar:.1f}",
            "cf_vac": f"{cf_vac:.4f}", "ivac_m_s": f"{r['Ivac, m/s'][i - 1]:.1f}",
            "x_co": f"{fraction(b, 'CO', i):.5f}", "x_h2": f"{fraction(b, 'H2', i):.5f}",
            "x_h2o": f"{fraction(b, 'H2O', i):.5f}", "x_co2": f"{fraction(b, 'CO2', i):.5f}",
            "x_hcl": f"{fraction(b, 'HCL', i):.5f}",
            "fuel_rich": f"{sum(fraction(b, s, i) for s in FUEL_RICH):.5f}",
            "y_al2o3": f"{alumina:.5f}", "y_condensed": f"{condensed:.5f}",
            "thrust_vac_lbf": "" if thrust is None else f"{thrust:.1f}",
            "exit_diameter_in": "" if exit_in is None else f"{exit_in:.3f}", "exit_source": exit_note or (
                "" if exit_in is None else "given"),
            "pc_check_psia": pc_check, "note": note,
        })

    with open(args.out, "w", newline="") as f:
        f.write("# Apollo exhaust, from NASA CEA runs: tools/make_exhaust_table.py on tools/cea/*.inp.\n")
        f.write(f"# CEA {args.cea_version}; thermo.lib sha256 {thermo}.\n")
        f.write("# Liquids: frozen at the throat (nfz=2); solids: shifting equilibrium. SI units except\n")
        f.write("# pc_psia, thrust_vac_lbf and exit_diameter_in. Fractions at the exit: x_ mole, y_ mass.\n")
        f.write("# gamma_nozzle: the one gamma whose isentropic expansion gives pc_over_pe at area_ratio.\n")
        f.write("# pc_check_psia: the chamber pressure CEA's cf_vac needs for thrust_vac_lbf through the\n")
        f.write("# exit; exit_source 'derived': the exit that thrust needs at the deck's pressure.\n")
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    for r in rows:
        print(f"{r['row']:<16} pc {r['pc_psia']:>7} psia  pe {float(r['pe_pa']):9.1f} Pa  Me {r['mach_exit']}"
              f"  g_noz {r['gamma_nozzle']}  Me_noz {r['mach_nozzle']}  check {r['pc_check_psia'] or '-'}"
              f"  De {r['exit_diameter_in'] or '-'} {r['exit_source']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

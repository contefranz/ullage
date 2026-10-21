# Apollo exhaust: datasheet for the M1.6 plume and particle model

Compiled on 2026-10-21 for M1.6 track P1 (exhaust physics, docs/m16/plan.md; design in docs/m16/design-plumes-particles.md, part A). It gives every engine family of the Saturn V and the CSM the exhaust the plume renderer (P2) and the particle effects (P3-P6) draw from, and the physics they shape it with. `Sources/OrbitCore/Effects/` holds the values and the models: `ApolloExhaust.swift` (the specs), `NozzleFlow.swift`, `PlumeModel.swift`, `ParticleKinematics.swift`, `FrostShedding.swift` and `IceSublimation.swift`. None of it feeds thrust, flow or mass: the vehicle model and the §17 ascent are untouched.

**How the numbers were got.** The exhaust gas comes from NASA's CEA, built from source in the cloud session and run on the input decks in `tools/cea/`, one per engine family (§1). The engine data the decks take (chamber pressures, mixture ratios, area ratios, propellant formulations) were read from the primary documents where the session could download them (NTRS and ibiblio: Betts' F-1 paper, Marquardt's R-4D report, TN D-6295, MSFC-MAN-503, D5-15796-1, the AS-501 FER), from the repository's own transcriptions (the AOH readings, AS506Data, ApolloCSMData), and in a few places from search extracts of documents the network did not let it fetch (marked "extract").

## Conventions

- **Confidence:** H high, M medium, L low, as in docs/AS506-datasheet.md. "Derived" is arithmetic on graded values; "proxy" is a value for one item taken for another; "assumed" has no source and only has to look right.
- **Units:** SI in the code and the tables, except pressures in psia and lengths in inches where the sources give them so. 1 psia = 6,894.757 Pa; 1 lbf = 4.448222 N; 1 lb = 0.45359237 kg; g0 = 9.80665 m/s².
- **Chamber pressure** is the nozzle stagnation pressure (the 1,125 psia often quoted for the F-1 is its injector end's).
- **Source keys:**
  - Betts: E. Betts, "Waking a Giant: Bringing the Saturn F-1 Engine Back to Life", NTRS 20140011656.
  - R-3896-1: Rocketdyne, *Technical Manual, Engine Data, F-1 Rocket Engine*, 31 Mar 1967 (Internet Archive; read through a search extract only).
  - F-1 review: "Comprehensive Review of Liquid-Propellant Combustion Instabilities in F-1 Engines", J. Propulsion and Power 9(5), 1993 (extract).
  - MAN-503: *Saturn V Flight Manual SA-503*, MSFC-MAN-503, NTRS 19750063889.
  - D5-15796-1: Boeing, *Saturn V Aerothermodynamics Flight Evaluation Summary, AS-501 through AS-503*, 19 June 1969, NTRS 20160013592.
  - FER-501: *Saturn V Launch Vehicle Flight Evaluation Report AS-501, Apollo 4*, MPR-SAT-FE-68-1 (ibiblio).
  - FER: the AS-506 report, MPR-SAT-FE-69-9, as in docs/AS506-datasheet.md.
  - TN D-6295: B. J. Lee, *Qualification Evaluation of the Tower Jettison Motor for the Apollo Spacecraft Program Launch Escape System*, 1971, NTRS 19710015557.
  - A-1080: The Marquardt Corporation, *Apollo SM RCS engine final report*, vol. 1, NTRS 19690029231.
  - AOH: *Apollo Operations Handbook*, Block II, Vol. 1, SM2A-03-BLOCK II-(1), as read in docs/data/apollo-spacecraft/readings/AOH and tools/data/aoh_block2_sps_rcs.csv.
  - Purdue: Purdue AAE propulsion table for the J-2 (extract).
  - EH 8.30: enginehistory.org, *Rocket Propulsion Evolution* 8.30, the S-IVB stage (extract).

## 1. The CEA runs

| item | value |
|---|---|
| program | NASA CEA 3.3.4 (github.com/nasa/cea, commit 2f79a64, 25 Sep 2026; Apache-2.0), the re-implementation of Gordon and McBride's CEA (NASA RP-1311) |
| build | from source with CMake and gfortran 13.3 (Ubuntu 24.04), its legacy command-line program; the PyPI wheel's own executable would not start in the container |
| data | CEA's thermo.lib, compiled from its thermo.inp (sha256 `fa774657…84363`); the compiled library's sha256 is in the table's header |
| decks | `tools/cea/*.inp`, one rocket problem each, every input cited in its comments |
| driver | `python3 -I tools/make_exhaust_table.py --cea /path/to/cea --cea-version "3.3.4 (…)"` runs each deck twice (mole and mass fractions) and writes `tools/data/cea_apollo_exhaust.csv` |
| combustor | infinite-area, at the nozzle stagnation pressure |
| expansion | liquids frozen at the throat (`nfz=2`); solids in shifting equilibrium |

**Why frozen for the liquids.** At the F-1's 982 psia, o/f 2.404 and 16:1, shifting equilibrium gives an exit pressure of 7.2 psia and frozen flow 6.0 psia; the F-1 review's table gives 5.8 psia at the exit (extract, M). Beyond the exit the plume is frozen in any case, and the small hypergolic engines are nearer frozen than equilibrium. Every row also has its equilibrium expansion in CEA's output, should the choice be revisited.

**Why equilibrium for the solids.** A frozen expansion of the polysulfide propellant stops at the throat: its condensed species (Al2O3, MgO) leave their temperature ranges. With the spinel MgAl2O4 among the products (0.5 mol % in the chamber) the equilibrium expansion does not converge past the throat either, so the decks omit it and its magnesium and aluminium go to MgO, MgCl2 and Al2O3.

**One γ for the nozzle.** The plume model expands the gas with one ratio of specific heats (`NozzleFlow`). The spec's `exitGamma` is the γ with which the isentropic relations give CEA's pc/pe at the area ratio exactly (`gamma_nozzle`); the exit Mach number they give then lies within 0.1-1.6 % of CEA's (`mach_nozzle` against `mach_exit`), and CEA's local exit γ is in the table beside it. The exit temperature and molar mass are CEA's, so the exit's density, velocity and mass flow are CEA's ideal values to within the Mach number's difference.

### 1.1 The table (`tools/data/cea_apollo_exhaust.csv`)

| row | expansion | o/f | pc (psia) | ε | Tc (K) | Te (K) | pe (Pa) | Me (CEA) | γ exit | γ nozzle | Me (γ nozzle) | M (g/mol) | c* (m/s) | Cf vac | Ivac (m/s) | CO + H2 | Al2O3 | condensed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| F-1 | frozen | 2.404 | 982 | 16 | 3616 | 1469 | 41,330 | 3.695 | 1.2505 | 1.2330 | 3.730 | 23.04 | 1804 | 1.7654 | 3186 | 0.449 | 0 | 0 |
| F-1 at 10:1 | frozen | 2.404 | 982 | 10 | 3616 | 1667 | 78,190 | 3.339 | 1.2425 | 1.2300 | 3.366 | 23.04 | 1804 | 1.7154 | 3095 | 0.449 | 0 | 0 |
| J-2 | frozen | 5.500 | 763 | 27.5 | 3373 | 1194 | 15,680 | 4.089 | 1.2708 | 1.2338 | 4.147 | 12.76 | 2336 | 1.8234 | 4259 | 0.300 | 0 | 0 |
| J-2 EMR 4.34 | frozen | 4.340 | 763 | 27.5 | 3065 | 968 | 14,390 | 4.207 | 1.3025 | 1.2576 | 4.271 | 10.68 | 2404 | 1.8094 | 4349 | 0.446 | 0 | 0 |
| J-2 EMR 4.96 | frozen | 4.960 | 763 | 27.5 | 3252 | 1102 | 15,170 | 4.133 | 1.2837 | 1.2430 | 4.194 | 11.82 | 2371 | 1.8180 | 4310 | 0.366 | 0 | 0 |
| J-2 EMR 5.0 | frozen | 5.000 | 763 | 27.5 | 3263 | 1109 | 15,210 | 4.129 | 1.2826 | 1.2422 | 4.190 | 11.89 | 2369 | 1.8185 | 4307 | 0.361 | 0 | 0 |
| SPS | frozen | 1.600 | 100 | 62.5 | 3052 | 721 | 590 | 5.032 | 1.3274 | 1.2759 | 5.113 | 20.76 | 1742 | 1.8422 | 3208 | 0.231 | 0 | 0 |
| SPS at 6:1 | frozen | 1.600 | 100 | 6 | 3052 | 1514 | 15,240 | 2.997 | 1.2651 | 1.2514 | 3.026 | 20.76 | 1742 | 1.6398 | 2856 | 0.231 | 0 | 0 |
| SM RCS | frozen | 2.000 | 90 | 40 | 3121 | 893 | 1,010 | 4.552 | 1.3044 | 1.2634 | 4.622 | 22.05 | 1720 | 1.8189 | 3128 | 0.189 | 0 | 0 |
| CM RCS | frozen | 2.000 | 139 | 9 | 3166 | 1434 | 12,200 | 3.300 | 1.2636 | 1.2471 | 3.335 | 22.13 | 1727 | 1.6912 | 2921 | 0.188 | 0 | 0 |
| APS attitude | frozen | 1.600 | 100 | 40 | 3004 | 794 | 1,060 | 4.641 | 1.3233 | 1.2780 | 4.716 | 20.33 | 1737 | 1.8126 | 3149 | 0.304 | 0 | 0 |
| APS ullage | frozen | 1.600 | 100 | 9 | 3004 | 1287 | 8,460 | 3.337 | 1.2822 | 1.2612 | 3.375 | 20.33 | 1737 | 1.6882 | 2933 | 0.304 | 0 | 0 |
| Tower jettison | equilibrium | — | 1330 | 14 | 2708 | 1395 | 79,980 | 3.436 | 1.1668 | 1.1739 | 3.423 | 29.22 | 1390 | 1.8040 | 2508 | 0.135 | 0.0378 | 0.0526 |
| S-IC retro | equilibrium | — | 1650 | 4.5 | 2716 | 1725 | 443,940 | 2.661 | 1.1764 | 1.1729 | 2.663 | 28.84 | 1391 | 1.6382 | 2279 | 0.167 | 0.0378 | 0.0459 |
| S-II ullage | equilibrium | — | 999 | 7.5 | 2947 | 1802 | 139,440 | 2.954 | 1.1905 | 1.1617 | 2.986 | 30.54 | 1431 | 1.7297 | 2475 | 0.000 | 0.0243 | 0.0276 |
| S-II retro | equilibrium | — | 1761 | 4.3 | 2719 | 1741 | 504,270 | 2.628 | 1.1764 | 1.1728 | 2.631 | 28.84 | 1392 | 1.6301 | 2268 | 0.168 | 0.0378 | 0.0457 |
| S-IVB ullage | equilibrium | — | 980 | 16 | 2697 | 1360 | 49,770 | 3.517 | 1.1677 | 1.1733 | 3.506 | 29.23 | 1389 | 1.8202 | 2528 | 0.134 | 0.0378 | 0.0554 |

"CO + H2" is their mole fraction at the exit (`fuel_rich`), "Al2O3" and "condensed" mass fractions. The F-1 at 10:1 is where its turbine exhaust is injected; the J-2 settings and the SPS at 6:1 are for the record. The solids' exhaust also carries HCl (0.16-0.19 mole fraction) and water (0.37-0.47).

**Checks in the table.** Where an engine's thrust and exit are known, `pc_check_psia` is the chamber pressure CEA's vacuum thrust coefficient needs to deliver the thrust through that exit:

| engine | given pc | pc from thrust and exit | reading |
|---|---|---|---|
| F-1 (1,748,200 lbf; 10.10 m² exit at 16:1) | 982 | 1,012 | +3 %: the turbine exhaust's thrust is in the rating, and AS506Data's exit area is an effective one (M) |
| J-2 (230,000 lbf; 14.7 in throat) | 763 | 743 | −2.6 %: the real thrust coefficient's losses |
| SPS (21,080 lbf; 98.4 in exit) | 100 | 94 | −6 %: the same |
| SM RCS (99.8 lbf; 5.6 in exit) | 90 | 89.1 | agrees with Marquardt's reference engine |
| CM RCS (93 lbf; 2.13 in exit) | 139 | 138.9 | the deck's pressure is this derivation |

## 2. The engine families (`ApolloExhaust`)

Every thruster of the Apollo vehicles maps to one family by its name (`ApolloExhaust.engine(thruster:part:)`, which `ExhaustLibrary.spec(for:in:)` answers from). Each family's `ratedFlow` is the propellant flow at which its chamber pressure holds; the plume model scales the pressure with `Thruster.massFlow / ratedFlow`, a choked throat's proportionality, so the start and shutdown ramps and the J-2's mixture-ratio steps scale the plume. For the F-1 and J-2 it is the rated engine's flow; for the others the vehicle rating's own, so full output gives the spec's pressure.

| family | thrusters | family enum | pc | ε | exit radius | lip half-angle | rated flow (kg/s) | grade |
|---|---|---|---|---|---|---|---|---|
| F-1 | "S-IC engine 1"-"5" | keroseneLOX | 982 psia (Betts, H) | 16 (H) | 1.793 m, √(10.10 m²/π) (the dresser's) | 8° (assumed) | 2,602.3: 5,737 lb/s (Betts, H) | M |
| J-2 | "S-II engine 1"-"5", "S-IVB engine" | hydrogenLOX | 763 psia (Purdue, extract, M) | 27.5 (H) | 0.979 m (the dresser's) | 8° (assumed) | 245.47: 230,000 lbf at 425 s (M) | M |
| SPS | "SPS" | hypergolic | 100 psia (AOH, H) | 62.5 (AOH, H) | 1.250 m, 98.4 in across (AOH; the dresser's) | 8° (assumed) | 30.61: 21,080 lbf at 312.34 s | M |
| SM RCS (R-4D) | "SM RCS A1"-"D4" | hypergolic | 90 psia (A-1080, M) | 40 (AOH, H) | 0.0711 m, 5.6 in across (AOH; the dresser's) | 10° (assumed) | 0.164: 99.8 lbf at 276 s | M |
| CM RCS (SE-8) | "CM RCS 1A"-"6B" | hypergolic | 139 psia (derived, M) | 9 (AOH, H) | 0.0271 m, 2.13 in across (AOH, H) | 15° (assumed) | 0.153: 93 lbf at 276 s | M |
| APS attitude (TR-204) | "APS I pitch", "APS I roll/yaw ±t" and Position III's | hypergolic | 100 psia (FER-501 §7.12, H) | 40 (assumed, L) | 0.0816 m (derived from 147 lbf, L) | 15° (assumed) | 0.272 | L |
| APS ullage (SE-7-1) | "APS I ullage", "APS III ullage" | hypergolic | 100 psia (proxy, L) | 9 (assumed, L) | 0.0281 m (derived from 72 lbf, L) | 15° (assumed) | 0.113 | L |
| Tower jettison (TE-380) | "Tower jettison motor" | solidOther | 1,330 psia (TN D-6295, H) | 14 (TN D-6295, H) | 0.171 m, one of its two nozzles (TN D-6295, H) | 10° (TN D-6295, H) | 80.2 | M |
| S-IC retro (TE-M-424) | "S-IC retro motor 1"-"8" | solidOther | 1,650 psia (FER-501, H) | 4.5 (derived, L) | 0.172 m (L) | 15° (assumed) | 200.6 | L |
| S-II ullage | "S-II ullage motor 1"-"4" | solidOther | 999 psia (FER-501, H) | 7.5 (derived, L) | 0.143 m (L) | 15° (assumed) | 40.7 | L |
| S-II retro (TE-M-29) | "S-II retro motor 1"-"4" | solidOther | 1,761 psia (FER-501, H) | 4.3 (derived, L) | 0.103 m (L) | 15° (assumed) | 79.6 | L |
| S-IVB ullage (TX-280) | "S-IVB ullage motor 1", "2" | solidOther | 980 psia (FER-501, H) | 16 (derived, L) | 0.079 m (L) | 15° (assumed) | 6.85 | L |

The lip half-angles are assumptions for the plume's initial angle; the dresser's bells leave their exits at about 7.6°.

### 2.1 F-1

- **Chamber.** 982 psia nozzle stagnation (Betts' "Chamber Pressure, ns", H; the F-1 review gives 980 psia at the throat's stagnation and 1,125 psia at the injector face, extract). The thrust chamber's o/f is 2.404: the engine's 2.27 (Betts, H) less its gas generator's 167 lb/s at o/f 0.416 (R-3896-1, extract, M) out of 5,737 lb/s, (3,982.6 − 49.1) / (1,754.4 − 117.9).
- **Nozzle.** Regeneratively cooled to 10:1, then the turbine-exhaust-cooled extension to 16:1 (MAN-503 Fig. 4-6: the gas generator's gas "passes through turbopump, heat exchanger, exhaust manifold and nozzle extension", H). The exit is AS506Data's effective 10.10 m², the one the dresser draws.
- **Exit.** 41.3 kPa (6.0 psia) at Mach 3.70 (CEA, frozen); the F-1 review's table gives 5.8 psia at 16:1 (extract, M), within 3 %. At sea level n = 0.41.
- **Turbine film** (`ExhaustSpec.Film`): 167/5,737 = 2.9 % of the flow (R-3896-1, extract, M), injected at 10:1 (H), at about 887 K: the 1,138°F the turbine exhaust has after the heat exchanger (R-3896-1 and a heroicrelics.org page, extract, M). Fuel-rich (the gas generator runs at o/f 0.416), it is the dark sheath at the exit: D5-15796-1 §4.1.1 saw on AS-501 to 503 "dark fuel-rich exhaust gases … at the F-1 nozzle exit plane followed by a flame front approximately three-fourths of a nozzle diameter downstream" (H). Its composition is not in CEA (a gas generator's products are far from equilibrium).
- **Soot index** 1, the scale's definition.

### 2.2 J-2

763 psia at the rated o/f 5.5 (Purdue, extract; Wikipedia's 5,260 kPa agrees: M), 27.5:1 on SP-8120's 14.7 in throat (AS506Data, H). The rated 230,000 lbf at 425 s (M) gives the rated flow, 245.47 kg/s, the one docs/AS506-datasheet.md §1.3 lists. AS-506's S-II started at EMR 5.0 (208.7 kg/s, 0.85 of rated), ran at 5.5 to the shift and 4.34 after (184 kg/s, 0.75), and its S-IVB burn 1 at about 4.96 (215.4 kg/s, 0.88); the spec keeps the rated chemistry and the pressure follows the flow. The exit is 15.7 kPa at Mach 4.15 (one-γ). No published exit pressure was found; the vacuum thrust coefficient checks it instead (§6). The gas generator's exhaust enters the nozzle through its exhaust manifold (MAN-503 Fig. 5-6) and is not modelled as a film: hydrogen-rich and invisible.

### 2.3 SPS

Aerozine 50 (50/50 UDMH and hydrazine by weight) and N2O4 at o/f 1.6, 100 psia ("SPS Pc normal 95 to 105 %"), 6:1 at the ablative chamber's exit and 62.5:1 at the radiation-cooled extension's (AOH pp. 2.4-1, 2.4-43, H). The exit gas is at 721 K and 590 Pa: the SPS never fires in air in a mission, and in vacuum its exhaust is too cool to glow (§3.9); its visible cue is the hot extension, which P2's material track draws.

### 2.4 SM RCS (R-4D)

MMH and N2O4 at o/f 2.0, 40:1 through a 5.6 in exit (AOH p. 2.5-24, H). The chamber pressure, 90 psia, is that of Marquardt's reference engine in its final report (A-1080 Fig. 75's assumptions: 95 lbf, 290 s, 0.3276 lb/s, o/f 2.00, throat 0.5915 in²; the scan's digits are poor: M); CEA's thrust coefficient gives 89.1 psia for the AOH's 99.8 lbf through the AOH's exit, an independent agreement.

### 2.5 CM RCS (SE-8)

MMH and N2O4 at o/f 2.0, 9:1 through a 2.13 in exit (AOH p. 2.5-47, H). No chamber pressure was found: 139 psia is the one at which CEA's vacuum thrust coefficient delivers the AOH's 93 lbf through that exit (derived, M).

### 2.6 S-IVB APS

N2O4 and MMH (MAN-503 §6, H) at o/f 1.6 (EH 8.30, extract, M; AS506Data feeds 1.611, the load ratio). The attitude engines' nominal chamber pressure was 100 psia (FER-501 §7.12: "the nominal 69 N/cm² (100 psia)", H); the ullage engine's is taken the same (L). Neither engine's area ratio was found: 40:1 for the 150 lbf TR-204 and 9:1 for the 70 lbf SE-7-1, by kinship with the R-4D and the SE-8 (L), their exits then sized by their thrust at that pressure.

### 2.7 Tower jettison motor (TE-380)

TN D-6295 (H) gives the motor whole: TP-E-8104 propellant (Table I(a): ammonium perchlorate 72.00 %, aluminium 2.00, LP-33 polysulfide 18.81, p-quinone dioxime 1.39, sulfur 0.01, magnesium oxide 1.00, ferric oxide 2.00, dibutyl carbitol 2.09, diphenylguanidine 0.70 % by weight, benzyl mercaptan 0-0.09 % in place of polymer); 1,330 psia over the 1.1 s web burn; two 10° conical nozzles canted 30° to the axis, scarfed through the interstage, 4:1 where the skew begins and 14:1 at the exit plane, nozzle A's throat 10.18 in² (16 % larger than B's, to lean the resultant). The spec is one nozzle's; the model's one thruster stands for both.

CEA's library lacks four of the ingredients. The deck gives LP-33, per C5H10O2S2 repeat unit, ΔHf = −493 kJ/mol, chosen so that CEA reproduces TN D-6295 Table I(b)'s flame temperature, 4,404°F (2,702 K) at 1,000 psia; its chamber γ then comes out at 1.176, the table's own value, an independent check. GMF (0), dibutyl carbitol (−640 kJ/mol) and DPG (+140 kJ/mol) are estimates, 4 % of the mass together (L).

### 2.8 The other solids

| motor | propellant | pc | ε | exit |
|---|---|---|---|---|
| S-IC retro, TE-M-424 | "ammonium perchlorate oxidizer in a polysulfide fuel binder", a 12-point star (MAN-503 p. 4-27, H): TP-E-8104 stands in (proxy, L) | Thiokol's nominal 1,650 psia at 60°F (FER-501 §12.2.1, H; its telemetry read 1,700-1,850) | 4.5 | 13.58 in across |
| S-II ullage | ammonium perchlorate 82 % of the weight (MAN-503 p. 5-24, H); the rest TP-E-8104's other ingredients in their proportions (L) | 999 psia, the mean of AS-501's eight (FER-501 Table 12-3, H) | 7.5 | 11.27 in |
| S-II retro, TE-M-29 | not given; TP-E-8104 (proxy, L) | 1,761 psia, the mean of AS-501's four (FER-501 Table 12-4, H) | 4.3 | 8.15 in |
| S-IVB ullage, TX-280 | "polymerized solid propellant" (MAN-503 p. 6-31); TP-E-8104 (proxy, L) | 980 psia, the mean of AS-501's two (FER-501 Table 12-5, H) | 16 | 6.22 in |

No area ratio was found. Each is the one at which CEA's vacuum thrust coefficient puts the exit of a nozzle delivering the motor's thrust (87,000, 23,000, 34,810 and 3,390 lbf) at 0.9 of its case's diameter: 15.25, 12.5 and 9 in (MAN-503, H) and, for the TX-280, 7 in inferred from its 58.8 lb grain at TP-E-8104's 0.0633 lb/in³ in a 36 in motor (EH 8.30, extract: L).

**The family.** Apollo's Thiokol solids are polysulfide and ammonium perchlorate with little aluminium (the TE-380's 2 %, H; the others' formulations are not in hand), so their exhaust is 2.4-3.8 % alumina by mass and 2.8-5.5 % condensed in all, against the 30 % of an aluminised composite. The specs give them the `solidOther` family with their `aluminaFraction`, not `solidAluminized`; the design report's white-yellow Al2O3 cores would overstate them.

## 3. The plume model (`PlumeModel`)

`PlumeModel.state(spec, flowFraction:, ambient:)` returns a `PlumeState`; `PlumeModel.state(of: thruster, in: part, ambient:)` takes the flow fraction from the thruster's flow this step over its family's rated flow. Lengths are from the exit plane along the axis.

| quantity | relation | source | grade |
|---|---|---|---|
| chamber pressure | pc = pc,rated × ṁ/ṁ_rated (a choked throat) | design report A4 | H (physics) |
| exit state | Me from ε (`NozzleFlow.supersonicMach`), pe = pc p/p0(Me), Te and M the spec's; ρe = pe M/(R Te), ue = Me √(γ R Te/M), ṁ = ρe ue Ae | NACA 1135; CEA | M |
| separation | separated when pe/pa < (1.88 Me − 1)^−0.64 | Schmucker 1973, in Stark AIAA 2013-3840 | M |
| Knudsen number | Kn = λ/De, λ = kT/(√2 π σ² p), σ = 3.65 × 10⁻¹⁰ m (US 1976's air) | US 1976 | H (λ) |
| regime | off; free-molecular for Kn ≥ 1; transitional for 0.01 < Kn < 1 (the shock structure's visibility falling linearly in log Kn); otherwise separated, overexpanded (n < 1) or underexpanded | design report A4 | M (bounds L) |
| jet | Mj = Mb from pa/pc (isentropic), Dj = De √(A(Mj)/ε) | mass conservation | H |
| boundary angle | δ0 = ν(Mj) − ν(Me) + θ_lip; vacuum limit θ_lim = ν_max − ν(Me) + θ_lip, at most 180° | Prandtl-Meyer (NACA 1135) | M (overexpanded: a compression, approximated) |
| shock cells | Ls = 1.306 Dj √(Mj² − 1) for n in 0.3...5, count = core length / Ls | Pack 1950; Tam and Tanna 1982 | M |
| Mach disk | x_M = 0.69 De Me √(γ n) for n > 2; cross-check 0.67 D* √(pc/pa); radius D*(0.36 √(pc/pa) − 1.17)/2; luminosity √(pa/p0) × visibility | Lewis and Carlson 1964; Ashkenas and Sherman 1966; Addy 1981 (sonic; visual) | M; L (radius, luminosity) |
| far field | ρ = A_p ρ* (r*/r)² cos^(2/(γ−1))(πθ/2θ_lim), radial at u_lim = √(2γ/(γ−1) R T0/M), A_p from ∫ ρ u_lim dA = ṁ | Simons 1972 (AIAA J. 10(11)) | M |
| afterburning | A = fuel-rich fraction × 1 at and below 28 km's pressure (1,616 Pa), 0 at and above 40 km's (287 Pa), linear in log p between | D5-15796-1 §4.1.1: plumes "highly luminous until 25 to 28 km", "gradual graying … from 28 to 40 km", "totally gray … from 40 km" | H (the observation); L (the shape) |
| flame front | 0.75 De for an engine with a film, while it afterburns in continuum | D5-15796-1 §4.1.1 | H for the F-1 at low altitude |
| potential core | Lc = (4.2 + 1.1 Mj²) Dj √(ρj/ρa) while Kn < 1 | Lau, Morris and Fisher 1979; Thring and Newby 1953 | L |
| luminous length | the longer of the free expansion's (to where Simons' axial density has cooled the gas isentropically to 1,000 K; 0 if the exit is cooler) and, in air, the mixing jet's (Lc × (T_hot − Ta)/(1,000 K − Ta), T_hot the afterburning flame's 2,300 K or the jet's) | assumed, for P2's calibration | L |

### 3.1 Checked numbers

The F-1 at its rated flow, on AS-506's launch-day sounding (`AS506.launchDayAtmosphere()`):

| altitude | pa | n | regime | δ0 | Mach disk (Lewis-Carlson; Ashkenas-Sherman) | afterburning |
|---|---|---|---|---|---|---|
| pad | 101.6 kPa | 0.41 | overexpanded, attached (Schmucker's limit 0.317) | −3.6° | none; shock cells of 10.3 m | 0.449 (full) |
| 7-8 km | 44-38 kPa | 0.95-1.08 | pe = pa between them | 7-9° | none | full |
| 30 km | 1.29 kPa | 32 | underexpanded | 41.5° | 58 m; 44 m | 0.39 (fading) |
| 67 km (S-IC cutoff) | 8.2 Pa | 5,050 | underexpanded | 71.7° (θ_lim 118.6°) | 729 m, luminosity 0.009 | 0 |

The design report's estimates before CEA (γ 1.22-1.25) were Me about 3.7, pe about 43 kPa, n about 0.42 at the pad, pe = pa near 6.7 km on US 1976, and at 30 km n about 36, δ0 about 45° and the Mach disk about 60 m downstream; the model agrees.

The J-2 at S-II ignition (67 km, US 1976) is a continuum jet with n = 1,920, δ0 = 62°, and a Mach disk 272 m downstream whose luminosity is 0.009: in flight it shows none. At S-IVB ignition (185 km) and for the SPS in orbit the flow is free-molecular; the SPS's θ_lim is 82°. At sea level the J-2 would separate (n = 0.15 against 0.33), as a vacuum engine does.

## 4. Particles (`ParticleKinematics`)

With dv/dt = g + (v_air − v)/τ, the step over Δ, s = Δ/τ, is exact:
- v(Δ) = v_air + (v − v_air) e^−s + g Δ φ1(s);
- x(Δ) = x + v_air Δ + (v − v_air) Δ φ1(s) + g Δ² φ2(s);
- with φ1 = (1 − e^−s)/s and φ2 = (s − 1 + e^−s)/s², which are the design report's v∞ form rearranged so that no term grows with τ: in vacuum (τ infinite, s = 0) it is the parabola, without cancellation.

It is stable for any step, so time warp needs no substeps. Quadratic drag, τ = m/(½ ρ Cd A |v_rel|), is re-linearised in `dragStep` about the mean of the relative speeds at a step's start and at its end as the start's τ predicts (second order). A step longer than twice the shorter of the start's τ and the terminal one, v_t/g, is split into equal substeps, at most 64: one linearisation at the start's speed over a step much longer than τ lands on v_t²/v, and the next step back near v, never settling. `goldenCases` are six steps (a frost flake in the pad's wind, a slab at max q, a spark in vacuum, smoke over a 1,000× frame, a step far shorter than τ, a particle at rest), each the double-precision result, for P3's GPU self-test.

## 5. Frost and ice (`FrostShedding`, `IceSublimation`)

**The frost** (FER Table 20-1, read from the page images for docs/AS506-datasheet.md §17, H):

| band | at first motion | at CECO (135.20 s) | shed |
|---|---|---|---|
| S-IC | 635 kg | 340 kg | 295 kg |
| S-II | 204 kg | 0 | 204 kg |
| S-IVB | 90 kg | 0 | 90 kg |

Each band sheds 20 % of its CECO total at first motion (the ignition and release) and the rest on an exponential of 30 s, normalised to finish exactly at CECO (both numbers assumed, L, for the launch films to tune); the S-IC keeps its 340 kg to separation. `shedMass(from:to:)` gives what a frame interval sheds, so frames at any warp add up to the table. The split, 80 % fine flakes of 1-5 mm and 20 % slabs of 2-30 cm, and the 40 km above which survivors glint as "fireflies", are the design report's (L). The vehicle model is unchanged: it carries the frost on the S-IC part to its separation (AS506Data).

**The ice:**
- Vapour pressure over ice: Murphy and Koop (2005) eq. 7, ln p = 9.550426 − 5,723.265/T + 3.53068 ln T − 0.00728332 T (Pa, T > 110 K): 611.657 Pa at the triple point, within 0.3 % of IAPWS's sublimation curve (Wagner et al. 2011) from 110 to 273 K (H).
- Flux: Hertz and Knudsen's α Δρ_v √(RT/2πM) (α = 1, L), in series in air with Maxwell's diffusion D Δρ_v/r, D = 2.11 × 10⁻⁵ (T/273.15)^1.94 (101,325/p) m²/s (Pruppacher and Klett); the sounding has no humidity, so the air is dry by default.
- Temperature: the air's in air (L: no evaporative cooling); in vacuum the balance of absorbed sunlight (α 0.3, L) and Earth's infrared against emission (ε 0.97) and the latent heat carried off (2.836 MJ/kg).

Sunlit ice sublimating in vacuum holds itself near 183 K, not the 208 K radiation alone would give, and a 1 mm flake then lasts about 9 h: the Apollo 8 "fireflies". In eclipse, warmed by 240 W/m² of Earth's infrared, it sits near 174 K and lasts about 2 days. In dry air at 270 K a 1 mm flake lasts under an hour (diffusion-limited).

## 6. Tests

| test | pins | reference |
|---|---|---|
| `NozzleFlowTests` | A/A*, p/p0, T/T0, ρ/ρ0 and ν at γ 1.4, M 2 and 3 (1.6875, 0.1278, 26.38°; 4.2346, 0.02722, 49.76°), ν_max 130.45°; the inverses on both branches | NACA 1135 Table I |
| `PlumeModelTests.testF1AttachedAtSeaLevelBySchmucker` | the F-1 attached at the pad; the J-2 separated; a pad start or shutdown passing through separation | Schmucker |
| `.testF1PressureMatchedBetween5And8km` | pe = pa between 5 and 8 km on the sounding | plan |
| `.testF1AndJ2ExitStates` | the F-1's 5.8 psia within 5 %; both engines' vacuum thrust coefficients against their ratings within 5 %; Me within 2 % of CEA's | F-1 review; Betts; Purdue; SP-8120 |
| `.testF1BoundaryAndMachDiskAloft` | δ0 ≈ 42° and the Mach disk ≈ 60 m at 30 km, Ashkenas-Sherman within 30 %; the boundary near its limit at cutoff | design report A4 |
| `.testMachDiskSonicLimitAndBoundaryAngle` | Lewis-Carlson's sonic limit 0.593 D* √(p0/pa), 11.5 % under Ashkenas-Sherman's 0.67; δ0 and θ_lim from NACA 1135's ν | Lewis and Carlson; Ashkenas and Sherman |
| `.testShockCells` | a matched jet keeps De; Ls = 1.306 Dj √(Mj² − 1) | Pack; Tam and Tanna |
| `.testSimonsMassFlux` | ∫ ρ u_lim dA = ṁ within 1 % (θ_lim below and at 180°) | plan |
| `.testAfterburningFadesWithAltitude`, `.testRegimesAlongTheFlight`, `.testShutdownShrinksThePlume` | the fade from 28 to 40 km; the flame front; the J-2's faint Mach disk at 67 km, free-molecular flow above; pc, δ0 and the Mach disk shrinking along the F-1's shutdown ramp | D5-15796-1 |
| `ExhaustSpecTests` | a spec for every Apollo thruster (none for the M0 test vehicles); exit radii equal to the dressed nozzles'; the specs equal to the CEA table; the rated flows the vehicle's | plan |
| `ParticleKinematicsTests` | one step and many equal the closed form; RK4; the ballistic limit; quadratic drag against RK4 within 0.5 % and onto the terminal velocity at any step; the golden cases | analytic |
| `FrostSheddingTests` | Table 20-1's masses by CECO and its shed totals within 1 %; Murphy-Koop against IAPWS within 0.5 %; Hertz-Knudsen; the lifetimes | FER; IAPWS 2011 |

## 7. Open items

1. **The solids' propellants and nozzles** (L): only the tower jettison motor's formulation and nozzle are in hand. The retros' and ullage motors' Thiokol specifications, or a stage handbook, would replace the TP-E-8104 proxy and the case-diameter rule.
2. **The APS area ratios** (L): the TR-204's and SE-7-1's are not found.
3. **The F-1's turbine film**: its 887 K and its share come through search extracts of R-3896-1 (M); the scanned manual itself was out of the network's reach.
4. **Lip angles** (assumed) set the plume's initial angle only by a few degrees.
5. **Shapes for P2's calibration**: the afterburning's fade between 28 and 40 km, the core length and the luminous length are visual grade; the Mach disk's luminosity is a column-density ratio, not a radiance.
6. **Simons' backflow**: the far field ends at θ_lim; the boundary-layer flow beyond it (the plumes' backflow onto the vehicle) is not modelled.

## Sources

- NASA CEA: Gordon, S. and McBride, B. J., *Computer Program for Calculation of Complex Chemical Equilibrium Compositions and Applications*, NASA RP-1311 (1994-96), https://ntrs.nasa.gov/citations/19950013764 ; the re-implementation, https://github.com/nasa/cea
- Betts, E., *Waking a Giant*, https://ntrs.nasa.gov/citations/20140011656
- Rocketdyne R-3896-1, F-1 engine data, https://archive.org/details/r-3896-1-technical-manual-engine-data-f-1-rocket-engine-31-mar-1967 (search extract)
- MSFC-MAN-503, *Saturn V Flight Manual SA-503*, https://ntrs.nasa.gov/citations/19750063889
- Boeing D5-15796-1, *Saturn V Aerothermodynamics Flight Evaluation Summary AS-501 through AS-503*, https://ntrs.nasa.gov/citations/20160013592
- MPR-SAT-FE-68-1, *AS-501 Flight Evaluation Report*, https://www.ibiblio.org/apollo/Documents/lvfea-AS501-Apollo4.pdf
- Lee, B. J., NASA TN D-6295, https://ntrs.nasa.gov/citations/19710015557
- The Marquardt Corporation, A-1080, Apollo SM RCS engine final report, https://ntrs.nasa.gov/citations/19690029231
- Ames Research Staff, NACA Report 1135 (1953), https://ntrs.nasa.gov/citations/19930091059
- Stark, R., *Flow Separation in Rocket Nozzles - an Overview*, AIAA 2013-3840 (Schmucker's criterion)
- Lewis, C. H. and Carlson, D. J., *Normal Shock Location in Underexpanded Gas and Gas-Particle Jets*, AIAA J. 2(4):776, 1964
- Ashkenas, H. and Sherman, F. S., in *Rarefied Gas Dynamics* IV, 1966
- Addy, A. L., *Effects of Axisymmetric Sonic Nozzle Geometry on Mach Disk Characteristics*, AIAA J. 19(1):121, 1981
- Pack, D. C., Quart. J. Mech. Appl. Math. 3:173, 1950; Tam, C. K. W. and Tanna, H. K., J. Sound Vib. 81(3), 1982
- Simons, G. A., *Effect of Nozzle Boundary Layers on Rocket Exhaust Plumes*, AIAA J. 10(11), 1972
- Lau, J. C., Morris, P. J. and Fisher, M. J., J. Fluid Mech. 93, 1979; Thring, M. W. and Newby, M. P., Fourth Symposium on Combustion, 1953
- Murphy, D. M. and Koop, T., Q. J. R. Meteorol. Soc. 131:1539, 2005; Wagner, W., Riethmann, T., Feistel, R. and Harvey, A. H., J. Phys. Chem. Ref. Data 40, 043103, 2011
- Pruppacher, H. R. and Klett, J. D., *Microphysics of Clouds and Precipitation*, 1997
- U.S. Standard Atmosphere, 1976

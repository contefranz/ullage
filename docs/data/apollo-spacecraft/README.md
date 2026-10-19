# Apollo spacecraft and entry data: transcription log

The spacecraft and entry data that M1.5's tracks C (CSM/SM, SPS and RCS),
E1 (entry) and E2 (CM, ELS and splashdown) build on (docs/m15/plan.md, track
D). The CSVs are in `tools/data/`; this log says where each value came from,
how it was read, and how the two readers' results were reconciled.
`tools/data/README.md` covers the AS-506 launch-vehicle files only.

## Method

- The primary PDFs were downloaded to a scratch directory, never into the
  repo. The table below gives each file's URL, size and SHA-256, retrieved on
  2026-10-19.
- Every value was read from the page images: the scans' own raster images,
  extracted with `pdfimages -png` (poppler), rotated and enlarged with
  ImageMagick where a page is printed sideways or a digit is small. The PDFs'
  OCR text layers were used only to find pages, never for values.
- Two independent readers read every page: reader A (the session that wrote
  this log) and reader B (a separate agent given only the page images, with
  no access to reader A's file or to any text layer). Their raw readings are
  kept under `readings/<document>/reader-A/` and `reader-B/`.
- Disagreements were settled on an enlarged crop of the cell, then by the
  document's own arithmetic (totals, ratios, a value printed twice). Where the
  print itself is wrong, the CSV keeps the printed value and gives the
  reading in the `si` column or a note, and the grade drops to M.
- `tools/check_apollo_data.py` runs the internal checks quoted below; it must
  print `0 failure(s)`.

**Grades.** Every CSV row carries one:
- **H**: both readers read the same digits on a clean print, and every check
  that applies (a sum, a ratio, a value printed twice) closes;
- **M**: both readers agree, but the value needed interpretation (a misprint,
  a missing sign or unit), or a check does not close;
- **L**: uncertain.

The grades rate the transcription. Preflight documents (68-FM-184) describe
a plan; the Mission Reports describe the flight.

**Units.** Each CSV keeps the printed value and unit and adds the value in SI
(m, kg, s, N, Pa, rad), or gives both in the header for constants. Factors:
0.3048 m/ft, 1852 m/n mi, 0.45359237 kg/lb, 4.4482216152605 N/lbf,
14.593902937 kg/slug, 1.3558179483 kg m²/slug ft², 6894.757293 Pa/psi,
1055.05585262 J/Btu.

## Sources

| key | document | copy read | bytes | sha256 |
|---|---|---|---|---|
| 68-FM-184 | MSC Internal Note 68-FM-184, *Apollo 7 Spacecraft Operational Trajectory*, Rev. 1, Vol. I (31 Jul 1968) | https://ibiblio.org/apollo/Documents/HSI-209546.pdf | 7,862,903 | `68d0f62b3851bf08f6517600610a9141144f61a4f211abc7b7805584f4b13d1d` |
| A7 MR | MSC-PA-R-68-15, *Apollo 7 Mission Report* (Dec 1968) | https://archive.org/download/apollo-7-mission-report/apollo-7-mission-report.pdf (raster, read) | 14,156,749 | `740743e38fd97898d4f5f221a2671f366abdd943e9c8f3b4e1d59618342d13e0` |
| | same, ClearScan copy (pages found with it, no values read) | https://www.apollojournals.org/alsj/a410/A07_MissionReport.pdf | 8,768,701 | `c06d973032b9ca19eea672a96f97b195b0e0a21d1d32675b9cddb1c6f3ad529f` |
| A11 MR | MSC-00171, *Apollo 11 Mission Report* (Nov 1969) | https://ntrs.nasa.gov/api/citations/19700008096/downloads/19700008096.pdf (raster, coarse) | 15,973,944 | `3314d99654ebb2ac3e3ef0ab70a84be9519a5f071cf1362118b2b20a6f161dea` |
| | same, ClearScan of a cleaner scan (read as rendered images) | https://archive.org/download/apollo-11-mission-report/apollo-11-mission-report.pdf | 11,835,694 | `5b9d033c7b9dd604220f439cddc8a53ad08e3e9c43c83f7342d7e61ef32a1baa` |
| D-5399 | NASA TN D-5399, Hillje, *Entry Aerodynamics at Lunar Return Conditions Obtained from the Flight of Apollo 4 (AS-501)* (Oct 1969) | https://ntrs.nasa.gov/api/citations/19690029435/downloads/19690029435.pdf | 8,466,113 | `8351dea9b708f7801184469b15c19e1e9a18dd8ac9eff2899b8279675541716c` |
| D-5276 | NASA TN D-5276, DeRose, *Trim Attitude, Lift and Drag of the Apollo Command Module with Offset Center-of-Gravity Positions at Mach Numbers to 29* (Jun 1969) | https://ntrs.nasa.gov/api/citations/19690020179/downloads/19690020179.pdf | 793,607 | `8df77fb79ef04e54a7092fccbe7e0d61396fdc5b8da151423aad6f77296c86b2` |
| D-7437 | NASA TN D-7437, West, *Apollo Experience Report - Earth Landing System* (Nov 1973) | https://ntrs.nasa.gov/api/citations/19740003586/downloads/19740003586.pdf | 26,481,429 | `2ca5ab15917d848137bc4b6fa3dc9c553be9387d98eef96902a4063d79cfc91e` |
| 68-FM-160 | MSC Internal Note 68-FM-160, Williamson and Fraley, *SLA Panel Jettison Separation and Recontact Analysis* (3 Jul 1968) | https://ntrs.nasa.gov/api/citations/19700026553/downloads/19700026553.pdf | 4,349,308 | `bda6ebb846e0daa4137fb9e4322cafd89db5facffca6c8bc94123b848f765f5b` |
| MSC-03466 | MSC-03466, *Apollo 11 Mission Anomaly Report No. 3: Service Module Entry* | https://ntrs.nasa.gov/api/citations/19710017109/downloads/19710017109.pdf | 1,196,958 | `4ed78136948d3f48028b4cbf6c13982b624b186e13132e91ef38b68db5cd2285` |
| AOH 2.4 | SM2A-03-BLOCK II-(1), *Apollo Operations Handbook*, Block II, Vol. 1, §2.4 SPS (15 Apr 1969, changes to 15 Oct 1969) | https://www.apollojournals.org/afj/aoh/aoh-v1-2-04-sps.pdf | 8,364,581 | `bef220b46be9dc0955dd14843820461d6ebf7c08bd3969e9091f273e87c29cd2` |
| AOH 2.5 | same, §2.5 RCS | https://www.apollojournals.org/afj/aoh/aoh-v1-2-05-rcs.pdf | 9,065,472 | `f81b8a786590a919947ecc2f9bcc0732d0540ba84a2e047c26300fec279e5d47` |
| US76 | *U.S. Standard Atmosphere, 1976* (NOAA, NASA, USAF; NOAA-S/T 76-1562) | https://ntrs.nasa.gov/api/citations/19770009539/downloads/19770009539.pdf | 18,101,069 | `23eb6b68346d4abc6071fc598872d51c40cf8c613d1a5d1006c6261bcd09dcea` |

All copies retrieved 2026-10-19.

## Files

| file | content | status |
|---|---|---|
| `68fm184_table1a_cm_trim.csv` | Table I(a): CM trim C_L, C_D, L/D and α at 14 Mach numbers, M 0.2-29.5, and the CG they were computed for | final |
| `68fm184_table1bcd_csm.csv` | Table I(b)-(d): SPS and SM RCS performance, CSM weights, drag coefficient and area, Earth and atmosphere constants | final |
| `68fm184_table8i_9_deorbit_entry.csv` | Table VIII(i): the deorbit burn's target load (T_ig, ΔV, weight, trims, REFSMMAT); Table IX: conditions at deorbit and at 400,000 ft | final |
| `68fm184_sec5_events.csv` | §5.1.4 (CSM/S-IVB separation) and §5.4 (deorbit, preentry, entry, targeting, heating, parachute times) | final |
| `a07_mr_table_a5_1.csv` | Apollo 7 Table A.5-I: weight, CG and full inertia tensor at 24 events, lift-off to landing | final |
| `a07_mr_table_2_1.csv` | Apollo 7 Table 2-I: sequence of events, planned and actual GET | final |
| `a07_mr_table_3_3.csv` | Apollo 7 Table 3-III: ignition and cutoff states of the 13 maneuvers, planned and actual | final |
| `a07_mr_sec5_16_entry.csv` | Apollo 7 §5.16: CM/SM separation rates, entry interface, 0.05 g and 0.2 g, bank, landing points; EMS ΔV counter | final |
| `a07_mr_sec5_21_consumables.csv` | Apollo 7 §5.21: SPS, SM RCS (per quad), CM RCS (per system), cryogenics and water: loaded, consumed, remaining | final |
| `a11_mr_table_a_1.csv` | Apollo 11 Table A-I: weight, CG and full inertia tensor at 27 spacecraft events (lift-off to landing) and 10 LM events | final |
| `a11_mr_sec8_11_consumables.csv` | Apollo 11 §8.11.1-8.11.3: SPS, SM RCS (per quad), CM RCS (per system) and cryogenics, actual and preflight planned | final |
| `tnd5399_table1_apollo4_events.csv` | TN D-5399 Table I: Apollo 4 entry events (CM/SM separation to landing, AGC programs) | final |
| `tnd5399_table2_apollo4_cg_mass.csv` | TN D-5399 Table II: Apollo 4 CM CG and mass from entry to drogue deployment at 16 Mach numbers | final |
| `tnd5399_text_apollo4.csv` | TN D-5399 text: reference length and area, RCS use and dead bands, ablator loss, flight trim and L/D | final |
| `tnd5276_table1_trim_points.csv` | TN D-5276 Table I: 15 free-flight runs, Mach 10-29, trim angle, C_D and L/D at two CG offsets | final |
| `tnd7437_els.csv` | TN D-7437: the Block II ELS sequence, drogue, pilot and main parachutes (diameters, reefing, drag areas, weights, loads), descent rates | final |
| `aoh_block2_sps_rcs.csv` | AOH §2.4-2.5: SPS tanks, gimbal ranges and nulls, ullage rule, engine; SM sectors and quad positions; SM and CM RCS engine maps, tanks and engines; the CSM/LV separation sequence | final |
| `68fm160_sla_panels.csv` | 68-FM-160: SLA panel jettison requirements (rotation rate, release angle, springs, velocity and attitude), weight, area and drag coefficient | final |
| `msc03466_sm_jettison.csv` | MSC-03466: the SM jettison controller before and from Apollo 13, the slosh analysis, Table I separation velocities for Apollo 7-11 | final |
| `us76_table1_86_1000km.csv` | US 1976 Table I, 86-1,000 km: T, T_M, p and ρ, every row to 149 km, then 5-50 km steps (136 rows) | final |

## 68-FM-184 (Apollo 7 Spacecraft Operational Trajectory)

Pages read (PDF page = printed page + 8): 15 (§5.1.4), 20-22 (§5.4), 23
(Table I(a), sideways), 24-25 (Table I(b)-(d)), 110 (Table VIII(i)), 111
(Table IX). The scan is 240 dpi bilevel and clean; every digit is sharp.

**Readers.** About 190 values. Readers A and B agree on every one: the 70
cells of Table I(a), the 30 constants of Table I(b)-(d), Table VIII(i) with its
REFSMMAT, Table IX and the section numbers. Both flagged the same two
misprints in Table IX independently.

**Checks** (`tools/check_apollo_data.py`):
- Table I(a): C_L/C_D equals the printed L/D on all 14 rows within 2e-5.
- Table I(c): CM 12,384 + SM 10,604 + SLA ring 91 + SPS propellant 9,379 =
  32,458 lb, the printed CSM total.
- Table I(b): 21,080 / 67.49 = 312.34 s, the printed SPS Isp. For the SM RCS,
  399.2 / 276.0 = 1.446 lb/s, which rounds to the printed 1.45.
- Table I(d): A0 a² = g R_E² = 1.4076539e16 ft³/s². So g = 32.146546 and
  A0 = 32.146536 are one μ at two radii, not a misprint. a/(a − b) = 298.30,
  Fischer 1960.
- §5.1.4: 2.6 s of four +X jets on 32,458 lb gives 1.03 ft/s, against the
  printed 1.0 ft/s.
- Table VIII(i): the REFSMMAT is orthonormal to 4e-8. Its row 3 = row 1 ×
  row 2 confirms the sign of 0.41967032, which has a speck before it.
- Table VIII(i) T_ig 10:19:39:53.8 + the 10.2 s burn of §5.4.1 = the
  10:19:40:04 cutoff of §5.4.2.

**Misprints and how they were read:**
1. **Table IX(a) altitude is printed `10 430·765` ft** (a raised dot between
   430 and 765). Read literally, it is 10,430,765 ft (1,717 n mi) or 10,430.765
   ft; neither can be a deorbit altitude. The same digits as 1,043,076.5 ft
   (171.67 n mi) fit three independent checks:
   - The Table IX(b) entry state, coasted back 826 s on a two-body orbit,
     reaches 1,040,906 ft at 11.89° N (2,170 ft off, with J2 and the burn
     ignored).
   - The horizon dip at 1,043,076.5 ft is 17.73°. Adding the 31.7° below the
     horizon of §5.4.1 gives 49.4°, against the printed retro attitude of
     49.3°.
   - Reader B's impulsive burn of the Table VIII(i) ΔV on the IX(a) state
     reaches 400,000 ft at 25,835 ft/s and −1.74°, against the printed
     25,850.3 ft/s and −1.759°.

   The CSV keeps the printed string and gives 1,043,076.5 ft in SI, graded M.
2. **Table IX(b) entry longitude is printed `98.83` with no sign.** The table
   uses signed east longitudes elsewhere (−153, −67.0), and §5.4.3 says
   98.83° W, so the value is −98.83 (M).
3. **Odd forms, values not in doubt:**
   - Table I(a) Y_cg is printed `=-.11 in`, in a different typeface (a
     typed-in correction): −0.11 in.
   - The SM RCS Isp line has no unit (s).
   - The viscosity unit is printed `slug/fps` (slug/(ft s)).
   - §5.4.4 says Figures 10-11 run "from the 400 000-ft altitude to reentry
     interface", which in this document is the same point.

**Notes for the tracks.**
- Table I(a)'s α is the total angle from +X (apex) to the relative wind, so
  180° is heat shield forward. Lift is drawn towards the CG-offset side. The
  table has no reference area or length; use 68-FM-184's or TN D-5399's
  (129.35 ft², 12.833 ft) consistently.
- Table I(d)'s drag coefficient 2.0 on 129.5 ft² applies to the CSM, the LM
  and the docked CSM/LM alike.
- Table VIII(i)'s ΔV is in the target load's local-vertical frame (x forward,
  z down): −191.20 ft/s along track and 203.05 ft/s down, |ΔV| 278.9 ft/s,
  pitched 46.7° below the horizontal. Table IX(a)'s retro attitude is
  49.3°.
- 68-FM-184 writes g.e.t. as days:hours:minutes:seconds: 10:19:39:53.8 is
  259:39:53.8 in the Mission Report's hours.
- The 963 s from EI to landing follows from §5.4: cutoff 10:19:40:04, plus
  826 s to EI, to landing at 10:20:09:53.
- This is the preflight plan. Apollo 7 flew SPS-8 at 259:39:16.3-28.2 GET,
  from 188 n mi, not this table's 171.7 n mi (the Mission Report CSVs).

## Apollo 7 Mission Report (MSC-PA-R-68-15)

**The copy.** The apollojournals.org PDF named in the design reports is an
Acrobat ClearScan file: its pages are synthesised fonts traced from the scan,
and its text layer garbles digits. The design reports' "garbled rows" of Table
A.5-I come from that layer; the traced glyphs mostly look right. The
archive.org copy holds the raster scan itself, 240 dpi bilevel, and every
value here was read from it. Its page numbering matches the ClearScan copy.

Pages read (PDF): 29-30 (Table 2-I), 44-50 (Table 3-III, sideways), 167-169
and 171-172 (§5.16), 239-242 (§5.21), 389-390 (§A.5 and Table A.5-I,
sideways). Pages 31-33 hold Table 2-II, which was not read.

**Readers.** Readers A and B agree on every value:
- Table A.5-I: 240 cells;
- Table 2-I: 92 times;
- Table 3-III: 416 cells (13 maneuver blocks);
- §5.16 and §5.21: every number.

**The rows the design report asked to re-read** (A.5-I rows 7-9, 12, 16, 17
and 21, garbled in the text layer). On the image, both readers read:
- row 7: I_xx 17,446;
- row 8: Y 0.9, Z 6.3;
- row 9: weight 29,780, Z 6.3;
- row 12: weight 25,077, Y −0.7, Z 7.0;
- row 16: X 972.9, Z 6.9;
- row 17: I_yy 43,748;
- row 21: Z 5.9.

Two cells differ from earlier readings:
- **Row 18 I_yy is 40,971**, not the design report's 40,911.
- **Row 9's weight is 29,780**, not the text layer's 29,730. The 8 has a
  broken lower-left stroke. 29,730
  would make the spacecraft gain 1 lb across SPS-4, and the weight drops
  across the eight SPS burns sum to 7,809 lb against the 7,811.1 lb of SPS
  propellant §5.21 says was consumed (7,759 lb with 29,730).

Row 2's Y_A has a speck at baseline height before 1.2; it is not a minus sign,
which sits at mid-height.

**Checks** (`tools/check_apollo_data.py`):
- **Table A.5-I:**
  - The weight never increases down the table.
  - Each SPS burn longer than 5 s drops 64.5-73.9 lb/s of Table 2-I burn
    time, around 68-FM-184's 67.49 lb/s; the excess is RCS ullage.
  - The drops across the eight SPS burns sum to 7,809 lb, against 7,811.1 lb
    consumed (§5.21).
- **The SM at CM/SM separation.** Row 18 − row 19 = 11,089 lb. 68-FM-184's
  preflight SM, less the SM RCS and cryogenics consumed and plus the SPS
  propellant remaining (§5.21), gives 11,087.5 lb.
- **§5.21:** every sum line closes, and loaded − consumed = remaining for
  the SPS, the SM RCS and CM RCS system A. The exception is below.
- **Table 3-III:** the ft and n mi altitudes agree within 0.022 n mi. Its SPS
  times agree with Table 2-I except the two listed below.
- **§5.16:** 25,846.4 − 25,844.2 = the stated 2.2 ft/s, and −2.072 against
  −2.063 is the stated 0.009°.

**Misprints and disagreements inside the report** (values kept as printed):
1. **SPS-8 actual ignition.** Table 3-III prints 259:31:16.3; it is
   259:39:16.3 (Table 2-I, and the position matches the planned 259:39:15.9).
   The `si` column uses 259:39:16.3 (M).
2. **SPS-1 actual ignition longitude.** Table 3-III prints 107.7, east of its
   own cutoff (107.5) on an eastbound pass; probably 106.7 (M).
3. **Second phasing maneuver actual longitudes.** −119.41 to −117.10 is 2.31°
   in 17.6 s, against 1.26° planned and about 1.3° from the orbital rate. One
   of the two is probably 1° off (M; reader B's catch).
4. **SPS-5 ignition heading.** Planned 75.46 and actual 76.46 differ by
   exactly 1° while the position agrees to 0.03° (M).
5. **Times that differ between Table 2-I and Table 3-III** (M in both
   tables):
   - SPS-1 actual cutoff: 26:25:05.7 against 26:25:05.1;
   - SPS-4 actual ignition: 120:43:00.5 against 120:43:00.4.
6. **CM RCS system B fuel.** Loaded 44.4 − consumed 7.4 = 37.0, but the
   remaining fuel is printed 34.0, and the totals (88.8 − 17.6 = 71.2 against
   68.2) inherit the gap. The four rows involved are graded M.
7. **Water.** In (514 lb) and out (503 lb) differ by 11 lb, presumably what
   the crew drank; the table lists no consumption.
8. **The ClearScan text layer** prints the 0.05 g time as `259:55:31\`; the
   image reads 259:55:38.

Reader B also noted, without a misprint to resolve:
- the separation maneuver's actual altitude falls 2,247 ft in 5.4 s with a
  positive flight-path angle;
- SPS-6's actual ignition altitude is about 1,300 ft above the planned value
  and both cutoffs.

**Notes for the tracks.**
- **Mass properties.** Table A.5-I is in Apollo axes (X_A, Y_A, Z_A, station
  inches). The report does not say whether its products of inertia are
  +∫xy dm or −∫xy dm. Apollo 11's Table A-I, in the same format, proves
  +∫xy dm (below), which is very likely the convention here too.
  An SPS-maneuver row is the mass at ignition; the Coast row after it is the
  mass after the burn.
- **The CM rows for E2:**

  | event | weight (lb) |
  |---|---|
  | after separation | 12,364 |
  | entry interface | 12,356 |
  | Mach 10 | 12,277 |
  | drogue deploy | 11,936 |
  | main deploy | 11,855 |
  | landing | 11,409 |

- **As flown (Table 2-I actuals).**
  - EI at 259:53:27;
  - 0.05 g at 259:55:38 (§5.16), 131 s after EI;
  - 0.2 g at 259:56:06;
  - drogues at 260:03:23, 596 s after EI;
  - mains at 260:04:13, so 50 s on the drogues;
  - landing at 260:09:03, so 290 s on the mains and 936 s from EI to landing.

  68-FM-184's plan had 53 s, 285 s and 963 s.
- **Entry interface.** The last pre-entry plan for EI was 25,844.2 ft/s and
  −2.063°; the onboard computer gave 25,846.4 ft/s and −2.072°. That is not
  68-FM-184's preflight 25,850.3 ft/s and −1.759°: the deorbit was flown from
  188 n mi, not 171.7.
- **Bank.** The crew flew a 55° roll-left backup bank until the CMC's first
  non-zero command (−15°) at about 202,000 ft.
- **Landing.** The recovery forces put it at 27.54° N, 64.07° W, and the
  reconstruction at 27.64° N, 64.15° W.
- **The EMS ΔV counter** measured X-axis ΔV for every maneuver and cut off
  the SPS burns flown under SCS control (§5.16.4): the device track C models.

## Apollo 11 Mission Report (MSC-00171)

**The copies.**
- The NTRS scan is complete, 300 dpi bilevel, but coarse: the digits print
  as blobs, and about a dozen cells of Table A-I cannot be told apart on it
  (5 from 6 from 9, 3 from 8).
- The archive.org copy is a ClearScan rendering of a different, much cleaner
  scan of the same print. ClearScan replaces the scan with traced glyphs, so
  it was rendered with `pdftoppm` and read as an image. Its text layer was
  not used, and the archive.org description's quick values were not trusted.

Pages read (PDF): 153-156 (§8.11, pages 8-24 to 8-27) and 334-335 (§A.6 and
Table A-I, pages A-10 and A-11). The §8.11.4 water table (page 8-28) was not
read.

**Readers.** Reader A read Table A-I on both scans. Reader B read the coarse
scan first and then, without seeing reader A's values, the nine cells it had
flagged, on the clean scan. All 370 cells agree:
- **Six cells were uncertain on the coarse scan**, and the clean scan reads
  each plainly: the drogue weight (11,603.7), the landing weight (10,873.0)
  and X_A (1037.1), the entry I_xz (−400), and the docked-total and LM-row
  I_xz (−9,240 and 27).
- **The LM coelliptic-sequence weight** looks like 5,681.5 on the coarse
  scan, which cannot be right: the LM weighs 5,738.0 later at docking. The
  clean scan prints 5,881.5.
- **Two of reader B's first readings were wrong on the coarse scan:** −1,019
  and 51,456. The clean scan prints −1,018 and 51,454.

§8.11 was read on both scans by both readers: no disagreement.

**What §A.6 says.** The data come from postflight analyses of expendable
loadings and usage. The weights and CGs of the CM, the SM and the LM ascent
and descent stages were measured before flight, and the inertias were
calculated. The text says nothing about axes or signs. From the table itself:
- **CSM rows** are in CSM X_A station inches.
- **The LM section** is in the LM's own station frame (X_A about 186-255 in).
  The LM rows inside the CSM section ("Transposition and docking / Lunar
  module", "Docking / Ascent stage") are in CSM axes.
- **The products of inertia are +∫xy dm about the CG.** The table gives three
  splits: CSM + LM = total docked, CSM + ascent stage = docked total, and
  SM + CM = CSM before separation. They recombine with the parallel-axis
  theorem in weight (0.0 lb), CG (≤ 0.06 in), moments (≤ 0.06 %) and
  products (≤ 38 slug ft², inside what the 0.1 in CG rounding allows) only
  with that sign. With −∫xy dm the products miss by 500 to 18,000 slug ft²
  (reader B found this first; `tools/check_apollo_data.py` checks it).
  Apollo 7's Table A.5-I comes from the same MSC office and format, so the
  same convention is very likely there, but that table has no split to prove
  it.

**Checks** (`tools/check_apollo_data.py`):
- **Table A-I:**
  - the three parallel-axis recombinations above;
  - docked total, ascent stage unmanned (42,563.0) − after ascent stage
    jettison (37,100.5) = the LM section's jettison weight, 5,462.5 lb;
  - the CM weight falls from separation to landing.
- **§8.11:**
  - the SPS tanks + lines = loaded;
  - the SM RCS quads sum to the loaded total;
  - loaded − consumed = remaining for the SPS, the SM RCS, the CM RCS
    (except below) and the cryogenics.
- **The SM at separation:** 14,549.1 lb less its remaining SPS, RCS and
  cryogenics gives 8,425 lb dry. That is information for track C, not a
  test.

**Misprint.** The CM RCS consumed fuel is printed 15.0 lb, for system A and
for the total. But 44.8 − 30.8 = 14.0, 89.2 − 75.2 = 14.0, and the printed
consumed total of 40.8 = 14.0 + 26.8. The two cells are graded M; 14.0 is
the value every other cell implies.

**Notes for the tracks.**
- **The CM rows for E2:**

  | event | weight (lb) | CG X_A (in) | CG Z_A (in) |
  |---|---|---|---|
  | after separation | 12,107.4 | 1040.4 | 6.0 |
  | entry | 12,095.5 | 1040.5 | 5.9 |
  | drogue deploy | 11,603.7 | 1039.2 | 5.9 |
  | main deploy | 11,318.9 | 1039.1 | 5.2 |
  | landing | 10,873.0 | 1037.1 | 5.1 |

  The drop from main deploy to landing (446 lb) is far more than the 205 lb
  of CM RCS left at main deployment, so it includes other losses as well (the
  main-parachute and propellant-dump rows are not split out).
- **The CSM at transposition and docking:** 63,473.0 lb at
  (934.0, 4.0, 6.5).
- **Loads.**
  - SM RCS: 110 lb of fuel and 225 lb of oxidizer per quad (1,340 lb in
    all).
  - SPS: 40,803 lb loaded, 5,064 lb left at CM/SM separation.
  - CM RCS: 245.9 lb loaded, and system B was never used.

## TN D-5399 (Apollo 4 entry aerodynamics)

Pages read (PDF): 3 (abstract), 11-12 (symbols), 16-17 (RCS and ablator),
28 (conclusions), 31 (Table I) and 32 (Table II). The scan is a clean
300 dpi bilevel raster.

**Readers.** Readers A and B agree on every value of Tables I and II and the
text. In Table II, the 9 of 30 590 and the last 6 of 30 596 print faintly;
both readers read them, and the times rise monotonically.

**Checks** (`tools/check_apollo_data.py`):
- Tables I and II agree on the times of entry, the two peaks of g and drogue
  deployment.
- The Table II weight falls by 300 lb from entry to drogue deployment. The
  text gives about 90 lb of RCS propellant and about 210 lb of ablator.

**Misprints and inconsistencies.**
- **The entry row's mass.** Table II converts slugs to pounds at 32.2 lb per
  slug on every row but the first (the symbol list says 32.1740). The entry
  row's 369.7 slug gives 32.35. Its weight, 11,959 lb, is the value that
  checks: the 300 lb drop to drogue deployment, and the 102 lb drop to first
  peak g, which is 3.2 slug at 371.4 slug. The mass cell is graded M; use the
  weight.
- **The load-factor formula** on page 3 prints Ax twice; the third term
  should be Az (reader B).
- **Conclusion 2** gives an initial-entry Mach of about 38, while Table II
  gives 25.6 at entry interface (graded M in the text CSV).

**Notes for the tracks.**
- **Datum and CG.** X is the CM station, with its origin 1000 in below the
  tangency line of the substructure mold line (Table II footnote b), and Z
  includes the 0.3 in Y offset (footnote c).
- **Entry state.** At entry Apollo 4 weighed 11,959 lb with its CG at X 1039.58
  in, Z 6.57 in.
- **Flight trim** was about 154.5° with an L/D of 0.368 at entry, and about
  153° with 0.410 at Mach 6.
- **RCS.** The rate dead bands were ±2.0°/s in every axis.
- **Timeline** (Table I): 0.05 g came 30.5 s after EI. Drogues deployed at
  30,678.6 s and mains at 30,725.8 s, so 47.2 s on drogues; landing came at
  31,029.2 s, 303.4 s on the mains.

## TN D-5276 (CM trim with offset CG, Mach 10-29)

Pages read (PDF): 3 (summary), 5 (symbols), 9 (CG sensitivity), 14-15
(uncertainties, trim), 19 (Table I, sideways).

**Readers.** Readers A and B agree on all 15 runs of Table I.

**Checks.**
- The mean L/D of the eight runs at 151° is 0.435, as the summary says.
- The three runs at 162° average 0.247, against the summary's 0.255; that is
  within the stated ±0.025.
- The two CG groups average z/d 0.0468 and 0.0281, which the summary rounds
  to 0.046 and 0.028.

**Notes.**
- **Reference axes.** x_cg is measured from the plane tangent to the front
  face and z_cg from the reference centreline (symbols, page 5).
- **Datum adjustment.** Trim angles in the figures are adjusted to
  x_cg/d = 0.270, which changes them by less than 0.4°.
- **Sensitivity.** A change of 0.0015 in z_cg/d moves the trim by about 1°.
- **Heat-shield centreline.** Flight data correlate only when the CG is
  measured from the centreline of the blunt heat shield. For AS-202 that is
  4.65 in, against 5.23 in from the structural centreline.
- **Figure 10's ratios imply d ≈ 155.5 in,** not 154 in (reader B). The table
  values are not affected.

## TN D-7437 (earth landing system)

Pages read (PDF): 10, 12-14 (sequence, history, design loads, descent
rate), 30-35 (Block II mains, drogues, pilots and the apex-cover chute) and
51 (the Apollo 15 anomaly report's sequence).

**Readers.** Readers A and B agree on every value.

**Checks.**
- **Reefing lines.** The lines, 264 and 780 in, are π × D_R1 (7.0 ft) and
  π × D_R2 (20.7 ft). Over the 83.5 ft nominal diameter that is 8.4 % and
  24.8 %, as printed.
- **Parachute weights.** The drogue weights sum to 37.4 lb and the pilot
  weights to 5.17 lb. The main-parachute weights sum to 138.58 lb, printed
  138.5.
- **The 1.6 s** from apex-cover jettison to drogue deployment appears three
  times: in Figure 2 (+0.4 s and +2 s), in Figure 3 (14.4 s and 16 s) and in
  the text.

**Notes for track E2.**
- **Which ELS flew.** Every crewed Apollo flew the Increased Capability Block
  II system, starting with CSM 101, Apollo 7.
- **Sequence:**
  1. apex cover at 24,000 ft + 0.4 s;
  2. two 16.5 ft drogues at 24,000 ft + 2 s, reefed to 42.8 % for 10 s;
  3. drogue release and three pilot chutes at about 11,000 ft;
  4. three 83.5 ft mains, disreefed at 6 s and again at 10 s (about 9,000 ft).
- **Baroswitch pressures,** US 1976:
  - 24,000 ft = 39.3 kPa;
  - 11,000 ft = 67.0 kPa;
  - 10,000 ft = 69.7 kPa.

  The design report's 69.7 kPa is the 10,000 ft figure, while D-7437 puts
  the drogue release at about 11,000 ft. That choice is E2's.
- **Drag areas per canopy:**

  | parachute | stage | ft² |
  |---|---|---|
  | drogue | reefed | 65 |
  | drogue | full open | 114 |
  | main | first stage | 285 |
  | main | second stage | 1,080 |
  | main | full open | 4,200 |

- **Descent rates.** Splashdown is 32 ft/s on three mains and 36 ft/s on two;
  the specification is 33 ft/s at 5,000 ft. Three mains at 4,200 ft² carrying
  Apollo 7's 11,409 lb give 27.6 ft/s at sea level. The 32 ft/s is the design
  figure for the 13,000 lb CM, with cluster losses.

## Apollo Operations Handbook §2.4 and §2.5

These are grey scans, one image per page, with no text layer. Pages read:
- §2.4: pages 2.4-1, 2.4-2, 2.4-7, 2.4-14, 2.4-15 and 2.4-41 to 2.4-45;
- §2.5: pages 2.5-1, 2.5-2, 2.5-21, 2.5-23, 2.5-24 and 2.5-47.

Readers A and B agree on every value. Neither section prints a thrust or an
Isp: both refer to the CSM/LM Spacecraft Operational Data Book SNA-8-D-027,
which was not found. 68-FM-184 Table I(b) supplies them.

**Checks.**
- **Tank totals.** Oxidizer storage + sump = 25,208.41 lb and fuel storage +
  sump = 15,766.46 lb, the printed totals to the cent. Their ratio, 1.599, is
  the 1.6 mixture ratio.
- **The ullage limit.** 22,300 lb is printed as 56.4 % three times, but it is
  56.27 % of the 100 % that the tanks' 103.4 % implies (graded M; reader B).
  The two sumps together hold 22,632 lb, so the rule means "the storage tanks
  are empty".

**Notes for track C.**
- **The SM layout** (Figure 2.4-3, looking forward from the aft bulkhead: −Z
  up, +Y right):

  | sector | contents | position |
  |---|---|---|
  | 1 | none labelled | between −Z and +Y |
  | 2 | oxidizer sump | around +Y |
  | 3 | oxidizer storage | just +Y of the +Z axis |
  | 4 | EPS equipment | between +Z and −Y |
  | 5 | fuel sump | around −Y |
  | 6 | fuel storage | just −Y of the −Z axis |

  The heavy oxidizer is all on the +Y/+Z side, which is where the loaded
  CSM's CG offset points (Apollo 11 A-I: Y_A +4.0, Z_A +6.5 in).
- **The quads.** Each sits 7°15′ off its axis (§2.5-1), and all four are
  displaced the same way, counterclockwise in that view:
  - A at −Z, toward −Y;
  - B at +Y, toward −Z;
  - C at +Z, toward +Y;
  - D at −Y, toward +Z.

  Measured from +Y toward +Z, C sits at 82.75°, D at 172.75°, A at 262.75°
  and B at 352.75°. The sense is read from the figure, so these angles are
  graded M.
- **The SM RCS engine map** (Figure 2.5-1). Engine 1 of every quad is CW +roll
  and engine 2 CCW −roll. Engines 3 and 4 are +pitch and −pitch on A and C,
  +yaw and −yaw on B and D.
- **The SPS gimbal** travels ±4.5° (+0.5, −0.0) about its nulls, plus 1° of
  snubbing:
  - yaw null +1° toward +Y when thrusting, 0° otherwise;
  - pitch null +2° toward +Z when thrusting, +1.5° otherwise;
  - rate 0.12-0.132 rad/s;
  - the actuator mounting pad is offset 4° toward +Y.
- **Minimum impulse:** 0.4 s.
- **SM RCS tanks.** The 69.1 / 137.0 lb (primary) and 45.2 / 89.2 lb
  (secondary) are "combined propellant and ullage volume" capacities, not
  loads.
- **Quad loads.** Apollo 7 loaded 110.6-111.3 lb of fuel and 223.7-225.9 lb
  of oxidizer per quad, Apollo 11 110 and 225 lb (the Mission Report CSVs).

## 68-FM-160 (SLA panel jettison)

Pages read (PDF): 7 (summary), 9-10 (requirements and inputs) and 30 (F and
G missions, conclusions). Readers A and B agree on every value.

**Requirements:**
- deployment at 33.5°/s or more;
- hinge release at 45-60° from the S-IVB +X axis;
- two springs per panel, about 450 lb preload, 50 lb/in;
- at least 8 ft/s at 110 ± 20°.

**Inputs:** 593 lb per panel (20 lb of spring growth included), 239 ft²,
tumbling drag coefficient 1.7.

**Note.** Four 593 lb panels are 1,076 kg, against the 1,166 kg AS-506's FER
gives (the repo's 291.5 kg per panel). The report's Z points up, so its
panel 1 (+Z) is the top panel, our −z.

## MSC-03466 (service module entry)

Pages read (PDF): 4-8, the text and Table I. Readers A and B agree on every
value.

**The SM jettison controller before Apollo 13:**
- the four −X jets fire from separation until propellant depletion;
- the four roll jets fire from 2 s for 5.5 s.

**From Apollo 13 on:**
- −X jets on at 0 s and off at 25 s;
- roll jets on at 2 s and off at 4 s.

**Table I** (propellant at jettison, expected and derived separation ΔV):

| mission | propellant (lb) | expected ΔV (ft/s) | derived ΔV (ft/s) |
|---|---|---|---|
| Apollo 7 | 7,100 | 275 | 30 |
| Apollo 8 | 9,500 | 78 | — |
| Apollo 9 | 2,400 | 132 | 134 |
| Apollo 10 | 3,300 | 345 | 60 |
| Apollo 11 | 4,500 | 360 | — |

**Inconsistencies inside the report** (reader B):
- The text calls 8,600 lb "the propellant mass for Apollo 8", while Table I
  gives 9,500 lb.
- The text says C-band tracked Apollo 7 and 10, but Table I also gives an
  Apollo 9 value.

**Note for track C.** Table I's propellant column does not match the
Mission Reports' remaining propellant:
- Apollo 7: 7,100 lb, against 1,926 lb of SPS and 398 lb of SM RCS
  propellant at separation (§5.21);
- Apollo 11: 4,500 lb, against 5,064 lb and 780 lb (§8.11).

The report does not say what the column counts, so use the Mission Reports
for the SM's loads.

## U.S. Standard Atmosphere, 1976 (86-1,000 km)

Table I "Geometric altitude, metric units", printed pages 68-73 (PDF 83-88),
300 dpi bilevel, printed sideways.

**Rows.** Every row printed from 86 to 149 km (0.5 km steps to 100 km, then
1 km). Above 150 km the table prints a row every 1 to 5 km; the CSV keeps
every 5 km to 225 km, every 10 km to 470 km, then 480 to 1,000 km at 10 to
50 km. That is the 2-5 km below 150 km and 10-50 km above that the entry
design asks for, 136 rows in all. The columns are T, T_M, p and ρ; H,
t (°C), p in torr and the ratios are left out.

**Readers.** Readers A and B agree on all 544 cells. Reader B flagged one
damaged glyph, the last digit of T at 225 km (907.78 or 907.76). Both read
907.78, and the standard's own profile gives 907.785.

**Checks** (`tools/check_apollo_data.py`):
- **Gas law.** p = ρ (R*/M0) T_M, with R* = 8,314.32 J/(kmol K) and
  M0 = 28.9644, holds within 4e-4 on every row, the printed precision. T_M is
  the molecular-scale temperature, so the varying molecular weight above
  86 km is already in it.
- **Temperature.** T agrees within 0.005 K with the standard's analytic
  profile above 86 km:
  - isothermal at 186.8673 K to 91 km;
  - an ellipse to 110 km;
  - +12 K/km to 120 km;
  - then the exponential approach to 1,000 K.
- **The entry design's spot values** hold: ρ is 5.604e-7 kg/m³ at 100 km and
  2.222e-8 kg/m³ at 120 km, and T is 360.00 K at 120 km.

**Note for track E1.** Between rows, interpolate p and ρ log-linearly and T
linearly, or evaluate T from the profile. The speed of sound needs the local
molecular weight: M = M0 T/T_M, from the T and T_M columns.

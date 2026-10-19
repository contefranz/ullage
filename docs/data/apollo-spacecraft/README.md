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

Two cells differ from the values the design reports carried:
- **Row 18 I_yy is 40,971**, not 40,911.
- **Row 9's weight is 29,780.** The 8 has a broken lower-left stroke. 29,730
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
  +Σ m x y or −Σ m x y, so compare them qualitatively until that is settled.
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

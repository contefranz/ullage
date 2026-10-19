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
  kept under `readings/<document>/reader-A.txt` and `reader-B.txt`.
- Disagreements were settled on an enlarged crop of the cell, then by the
  document's own arithmetic (totals, ratios, a value printed twice). Where the
  print itself is wrong, the CSV keeps the printed value and gives the
  reading in the `si` column or a note, and the grade drops to M.
- `tools/check_apollo_data.py` runs the internal checks quoted below; it must
  print `0 failure(s)`.

**Grades.** Every CSV row carries one:
- **H**: both readers read the same digits and an internal check closes (a
  sum, a ratio, a second statement elsewhere in the document);
- **M**: both readers agree, but the value needed interpretation (a misprint,
  a missing sign or unit), or nothing checks it;
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

All copies retrieved 2026-10-19.

## Files

| file | content | status |
|---|---|---|
| `68fm184_table1a_cm_trim.csv` | Table I(a): CM trim C_L, C_D, L/D and α at 14 Mach numbers, M 0.2-29.5, and the CG they were computed for | final |
| `68fm184_table1bcd_csm.csv` | Table I(b)-(d): SPS and SM RCS performance, CSM weights, drag coefficient and area, Earth and atmosphere constants | final |
| `68fm184_table8i_9_deorbit_entry.csv` | Table VIII(i): the deorbit burn's target load (T_ig, ΔV, weight, trims, REFSMMAT); Table IX: conditions at deorbit and at 400,000 ft | final |
| `68fm184_sec5_events.csv` | §5.1.4 (CSM/S-IVB separation) and §5.4 (deorbit, preentry, entry, targeting, heating, parachute times) | final |

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

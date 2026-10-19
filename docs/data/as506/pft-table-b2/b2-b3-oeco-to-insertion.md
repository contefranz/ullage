# AS-506 Postflight Trajectory (PFT): reference for the S-II and S-IVB IGM flight

Source: Boeing D5-15560-6, *Apollo/Saturn V Postflight Trajectory – AS-506*, 6 Oct 1969 (`dl_docs/pft506.pdf`, 218 PDF pages; same file as `19920075301.pdf`).
"p. X / PDF n" means document page X, PDF page n. Every number below was read from rendered page images, not from the OCR text. Images are in `igm/img/pft/hi/`.
All relative paths in this file are relative to `/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad/`. The CSV is `/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad/igm/pft-trajectory.csv`.
Grades: **H** = read cleanly and cross-checked; **M** = read, but with an anomaly or a single source; **L** = rough. **inferred** marks anything that was derived or deduced rather than printed.

## 0. Summary

- The PFT is a **mass-point** trajectory. It has **no attitude data** (no commanded or actual pitch or yaw, no chi angles), **no masses** and **no guidance commands** (searched: text, all table titles, figure list). Commanded and actual attitude must come from the FER.
- It does give a complete, consistent state history every 2 s (1 s up to 162 s) from guidance reference release (GRR) to insertion (709.33 s), in three forms:
  - Table B-II: the **LVDC navigation frame (PACSS 13)**, inertial, Earth-centred, fixed at GRR: position, velocity and acceleration.
  - Table B-III: **geographic polar (PACSS 1)**: radius, latitude, longitude, Earth-fixed and space-fixed speed, heading and flight-path angle, range and altitude.
  - Table B-I: the Earth-fixed launch-site frame (PACSS 10).
- I digitised **92 rows** (161.63 → 709.33 s) of B-II and B-III. They are written to `igm/pft-trajectory.csv`.
  - Sampling: 10 s in general; 2 s around S-IC/S-II staging (to 172 s), around S-II CECO (456–466 s), around S-II/S-IVB staging (540–560 s) and from 678 s to cutoff; plus all 7 event rows.
- **Verification.** B-III was recomputed from my B-II values using only the PFT's frame definitions. Every row agrees except one known print anomaly. **VERIFIER:** that "anomaly" (684 s ZS) was a misread damaged glyph, not a print error. The value is 2784.585 km, confirmed by Table C-II (PDF 179), and it is now corrected in the CSV and in §3.3/§3.6. With it, all 92 rows agree. Agreement:
  - radius ≤ 0.8 m; latitude and longitude ≤ 0.0001°;
  - angles ≤ 0.006°; speeds ≤ 0.09 m/s; altitude ≤ 1.7 m;
  - range ≤ 66 m (a definition effect, see §2.4).
  - B-II also passes a kinematic (trapezoid) check at 2–10 s spacing, to ≤ 1.5 m (positions) and ≤ 0.5 m/s (velocities), except across thrust steps.
  - The transcription is therefore H overall.
- Derived from my transcription (**inferred**), and added to the CSV:
  - flight-path angle and heading to 0.001°. These reproduce Tables 3-III, 3-IV and 4-III to 0.001°.
  - non-gravitational ("total inertial") acceleration. This reproduces the Table 3-II maxima to 0.01 m/s².
  - the **thrust-acceleration direction**, as chi-like pitch and yaw angles in PACSS 13. This is the only attitude-like information obtainable from the PFT. Grade L–M.
- Insertion conditions (Table 4-III) were recomputed from the B-II insertion state. The recomputation identifies the frame of the "descending node": it is measured from the **launch-site meridian at GRR**, in the GRR-fixed inertial frame (§5).

## 1. Tables and figures that bear on the S-II / S-IVB (IGM) flight

| Item | Content | Frame | Units | Sampling / span | Doc page / PDF page | Use for IGM |
|---|---|---|---|---|---|---|
| Sec. 2 text | launch site, ellipsoid, azimuths | — | — | — | p. 2-1 / PDF 25 | frame set-up (§2) |
| Table 3-I | times of significant events, actual vs nominal | range time | s | events | p. 3-22 / PDF 48 | event times |
| Table 3-II | significant trajectory parameters (Mach 1, max q, max total inertial acceleration per stage, max Earth-fixed velocity per stage) | — | SI + English | events | p. 3-23 / PDF 49 | acceleration peaks |
| Table 3-III | engine cutoff conditions (S-IC CECO/OECO, S-II CECO/OECO, S-IVB 1st/2nd guidance cutoff) | geographic (space-fixed velocity, FPA, heading); cross range | km, m/s, deg | events | p. 3-24 / PDF 50 (landscape) | cutoff targets and check |
| Table 3-IV | stage separation conditions | as 3-III, plus geodetic latitude, longitude | km, m/s, deg | events | p. 3-25 / PDF 51 | staging states |
| Table 3-V | targeting parameters, actual vs nominal (S-IVB 1st guidance cutoff; TLI) | — | km, m/s, deg | events | p. 3-26 / PDF 52 (landscape) | IGM terminal conditions |
| Table 3-VI | tracking data available, powered flight | — | — | — | p. 3-27 / PDF 53 | provenance only |
| Fig. 3-1 | ground track and stations, ascent | — | — | — | p. 3-7 / PDF 33 | — |
| Fig. 3-2 / 3-3 / 3-4 | altitude / surface range / cross range vs time, ascent | geographic | km, n mi | 0–720 s | p. 3-8 / 3-9 / 3-10 / PDF 34–36 | plots; numbers are in Table B-III, except **cross range**, which is plotted only (tabulated only at events in Tables 3-III and 3-IV) |
| Fig. 3-5 | space-fixed velocity and flight-path angle, ascent | geographic | m/s, ft/s, deg | 0–720 s | p. 3-11 / PDF 37 | plot of B-III columns |
| Fig. 3-6 | total inertial acceleration, ascent | magnitude of the **non-gravitational** acceleration (inferred §2.5) | m/s², ft/s², g | 0–720 s | p. 3-12 / PDF 38 | shows CECO and the S-II **EMR shift** |
| Fig. 3-8 / 3-9 / 3-10 | the same for the second (TLI) burn | — | — | 9,700–10,250 s | PDF 40–42 | TLI only |
| Table 4-II | orbital venting acceleration polynomials | — | — | parking orbit | p. 4-7 / PDF 61 | post-insertion only |
| **Table 4-III** | **parking orbit insertion conditions** | see §5 | km, m/s, deg, min | 709.33 s | p. 4-8 / PDF 62 | insertion reference |
| Table 4-IV / 4-V | TLI / CSM separation conditions | — | — | — | PDF 63 / 64 | — |
| Sec. 5.1.3, 5.1.4, 5.2; Fig. 5-1 | consistency and uncertainty of the reconstructed trajectory | PACSS 10 components | m, m/s | ascent | p. 5-2…5-4 / PDF 68–70 | error bars (§3.4) |
| App. A | definitions of symbols and coordinate systems | — | — | — | p. A-1…A-3 / PDF 87–89 | column definitions (§2) |
| Table B-I | Earth-fixed launch-site (PACSS 10) XE, YE, ZE, DXE…, DDXE… | PACSS 10 | m, m/s, m/s² | 1 s to 162 s, then 2 s (plus event rows); −16.968 → 709.33 s | p. B-2…B-13 / PDF 92–103 | not digitised |
| **Table B-II** | **launch vehicle navigation (PACSS 13)** XS, YS, ZS, DXS…, DDXS… | PACSS 13 (LVDC nav frame) | **km**, m/s, m/s² | as B-I | p. B-14…B-25 / PDF 104–115 | **digitised** |
| **Table B-III** | **geographic polar (PACSS 1)**: GC DIST, LONG, GC LAT, VEL-AZ, VEL-EL, EF VEL, HEAD, FLT-PATH, SF VEL, RANGE, ALTITUDE | PACSS 1 | km, deg, m/s, m | as B-I | p. B-26…B-37 / PDF 116–127 | **digitised** |
| Table B-IV | geographic polar, parking orbit (709.33 → 9,278.2 s) | PACSS 1 | as B-III | — | p. B-38…B-42 / PDF 128–132 | orbit check |
| Tables B-V / B-VI / B-VII | second burn (from 9,278.2 s to CSM separation) in PACSS 10 / 13 / 1 | — | — | — | PDF 133–139 / 140–146 / 147–153 | TLI IGM (later) |
| Tables C-I … C-VII | the same as B-I … B-VII in English units | — | ft, n mi, ft/s | — | PDF 156–167 / 168–179 / 180–191 / 192–196 / 197–203 / 204–210 / 211–217 | redundant |

Page ranges of Tables B-I…B-VII were read from contact sheets of the page images; those of C-I…C-VII were confirmed the same way (H).
**Not in the PFT** (searched): commanded or actual attitude and chi angles; guidance or IGM quantities (tau, T_go, steering); masses, thrust, flow; time history of cross range; telemetered guidance velocities. Section 5.1.3 says the guidance velocities exist in PACSS 12 (the platform-accelerometer frame), but they are not tabulated.

## 2. Frames, column definitions, launch parameters

### 2.1 Launch parameters (Sec. 2, p. 2-1 / PDF 25; Table 3-I; H)

| Quantity | Value | Grade |
|---|---|---|
| Range time zero | 13:32:00 UT, 16 July 1969 (8:32:00 a.m. EST, p. 1-1) | H |
| Range time definition | "referenced to nearest integer second before IU umbilical disconnect" (App. A p. A-3) | H |
| Guidance reference release (GRR) | −16.968 s (nominal −16.987) | H |
| First motion / start of time base 1 | 0.3 s / 0.6 s | H |
| Earth model | Fischer ellipsoid 1960 (Ref. 2: NASA M-DE 8020.008B). The values a = 6,378,166 m and 1/f = 298.3 reproduce the tables (inferred, §2.4). | H (name); M (values) |
| Pad 39A geodetic latitude / longitude | 28.608422° N / 80.604133° W | H |
| Height of vehicle centre of gravity above the ellipsoid (at launch) | 59.4 m (194.9 ft) | H |
| Launch azimuth | 90.0° E of N | H |
| Flight azimuth = ST-124M platform azimuth | 72.058° E of N | H |
| Roll manoeuvre start | 13.2 s (p. 1-1) | H |

### 2.2 Coordinate systems (App. A, p. A-1…A-2 / PDF 87–88; H, wording paraphrased closely)

- **PACSS 10 (Table B-I).** XE, YE, ZE; DXE…; DDXE… Earth-fixed launch-site system.
  - Origin: the intersection of the Fischer ellipsoid (1960) with the normal to it through the launch site.
  - X: along that ellipsoid normal, positive up.
  - Z: parallel to the Earth-fixed flight azimuth defined at GRR, positive downrange.
  - Y completes a right-handed system.
- **PACSS 13 (Table B-II)**, the "Launch Vehicle Navigation Coordinate System". XS, YS, ZS; DXS…; DDXS…
  - Origin: the **centre of the Earth**.
  - X: parallel to the Fischer-ellipsoid normal through the launch site, positive up.
  - Z: parallel to the flight azimuth, positive downrange.
  - Y completes a right-handed system.
  - "The direction of the coordinate axes remains fixed in space at guidance reference release."
  - Verified: with X = geodetic up at the pad, Z = azimuth 72.058° and Y = Z × X, the pad at GRR comes out at **(6373.330, 17.086, −5.533) km**. Table B-II prints **(6373.329, 17.087, −5.533) km** with velocity (0.0, 125.9, 388.8) m/s, the Earth-rotation velocity of the pad (PDF 104; H). So **+Y = Z × X points to azimuth 162.06°** (17.94° east of south), i.e. 90° to the right of downrange: Y = cos A·East − sin A·North (inferred and verified). This matches the repo's space-fixed frame as `docs/AS506-datasheet.md` describes it: launch vertical and flight azimuth, with the tower yaw towards +Y_S at azimuth 162° (inferred from the docs; the code was not re-derived).
  - **VERIFIER (frame caveat, inferred, H):** the axis *convention* matches. `SaturnIU.startT1` builds `Mat3(columns: x, z.cross(x), z)`, so Y = Z × X as in PACSS 13. The X *direction* does not match.
    - PACSS 13 X is the **geodetic** normal at 28.608422° N. The repo's X is the **geocentric radial** of a pad on a sphere at geocentric 28.447° (datasheet §1.6, §8 row `space_fixed_frame`).
    - The two axes differ by 0.161° in the north–south plane. That is the 17.96 km offset between the pad and the PACSS 13 X axis: √(17.086² + 5.533²).
    - Comparing PFT XS/YS/ZS directly with the sim's space-fixed components therefore leaves offsets of up to about 18 km at orbital radius. Transform both to ICRF first, or rotate the PFT state by 0.161° about the local east axis.
    - The same rotation shifts the CSV's chiY_thrust by −0.05° throughout and chiZ_thrust by −0.06° to +0.06° (at most 0.074°) relative to a geocentric-X frame (`igm/scripts/pftver_framediff.py`).
- **PACSS 1 (Table B-III)**, geographic polar coordinates.
  - GC DIST: geocentric distance of the vehicle centre of gravity (cg).
  - GC LAT: geocentric latitude.
  - GD LAT: geodetic latitude (defined, but *not* a column of B-III; it appears in Tables 3-IV and 4-III).
  - LONG: longitude, positive east of Greenwich.
  - **EF VEL / VEL-AZ / VEL-EL**: Earth-fixed velocity magnitude, its azimuth (east of north, in the local horizontal plane) and its elevation above the local horizontal plane.
  - **SF VEL / HEAD / FLT-PATH**: space-fixed (inertial) velocity magnitude, heading (angle in the local horizontal plane from north to the projection of the velocity, positive east) and flight-path angle (angle between velocity and local horizontal plane, positive up).
  - **ALTITUDE**: perpendicular distance from the cg to the Fischer ellipsoid.
  - **RANGE**: surface range measured along the Fischer ellipsoid from the launch site to the subvehicle point.
  - **TIME**: range time.

### 2.3 Units of the digitised tables (from the column headers; H)

- B-II: XS, YS, ZS in **km** (3 decimals, so 1 m); DXS, DYS, DZS in m/s (0.1); DDXS, DDYS, DDZS in m/s² (0.01).
- B-III:
  - GC DIST in km (0.001); LONG in deg E and GC LAT in deg N (0.0001);
  - VEL-AZ, VEL-EL, HEAD and FLT-PATH in deg (**0.01 only**);
  - EF VEL and SF VEL in m/s (0.1);
  - RANGE and ALTITUDE in **m** (1).

### 2.4 Exact meaning of the B-III columns, established by recomputation (inferred, verified)

These are established by recomputing B-III from B-II (`igm/scripts/pft_check_geo.py`, `pft_check_defs.py`).

- **Local horizontal = geocentric.** HEAD, FLT-PATH, VEL-AZ and VEL-EL all use the plane normal to the geocentric radius vector, with north along the meridian. They agree to ≤ 0.006° with that definition. With the geodetic normal instead, VEL-AZ and VEL-EL are off by 0.03–0.06° and FLT-PATH by up to 0.045°. So FLT-PATH is the **inertial flight-path angle relative to the geocentric horizontal**, `asin(r·v/|r||v|)`, the quantity IGM targets. Grade H (inferred definition).
- **SF VEL = |(DXS, DYS, DZS)|**: inertial velocity in PACSS 13 (≤ 0.09 m/s). **EF VEL** = |v − ω×r| (≤ 0.08 m/s; ω = 7.2921158e-5 rad/s). Grade H.
- **ALTITUDE** is geodetic height above the Fischer ellipsoid (a = 6,378,166 m, 1/f = 298.3; ≤ 1.7 m). Grade H.
- **Earth rotation.** LONG and GC LAT follow from PACSS 13 by an Earth rotation of ω·(t + 16.968 s) since GRR, to ≤ 0.0001°. Grade H.
- **RANGE** matches the ellipsoidal (Vincenty) distance from the pad to the **radial (geocentric) subvehicle point** to ≤ 2 m up to 460 s. The difference then grows smoothly to −66 m at insertion (2,705 km). Using the geodetic (normal) subvehicle point instead gives −55 to −116 m. The exact PFT algorithm is unresolved. Grade M for interpreting RANGE beyond ±70 m.

### 2.5 Accelerations (inferred, verified)

- **B-II DDXS, DDYS, DDZS are kinematic inertial accelerations, gravity included.**
  - On the pad at GRR they read (−0.02, −0.01, 0.00), the centripetal acceleration.
  - In the coast after cutoff (700–709 s) they read (−8.31…−8.24, −0.11, −4.07…−4.18), which is J2 gravity to within 0.02 m/s².
- **"Total inertial acceleration"** (Table 3-II, Fig. 3-6) is the magnitude of the **non-gravitational (sensed)** acceleration: |a_B-II − g|, with μ = 3.986032e14 m³/s² and J2 = 1.0823e-3. It reproduces Table 3-II:
  - 38.61 m/s² at S-IC OECO;
  - 17.84 m/s² at S-II CECO;
  - 6.73 m/s² at S-IVB cutoff.
  - The figure also starts at 10.47 m/s² at first motion.
  - Grade H for the definition, M for the derived values.

## 3. Digitised reference time history, 161.63 → 709.33 s

### 3.1 File and columns

The file is `igm/pft-trajectory.csv`: one row per time and 92 rows, with a header row.
The raw transcriptions are in `igm/data/pft_b2.txt` and `pft_b3.txt`, with the PDF page of each row.

| Column | Source | Definition | Grade |
|---|---|---|---|
| t_s | B-II/B-III TIME | range time, s | H |
| event | B-II/B-III event lines | event-row label as printed | H |
| alt_m, sf_vel_mps, flt_path_deg, head_deg, range_m, gc_dist_km, gc_lat_deg_n, long_deg_e, ef_vel_mps, vel_az_deg, vel_el_deg | Table B-III, PDF 120–127 | as §2.2/§2.4 | H (two cells M, see §3.3). **VERIFIER:** all H; 660 s LONG is confirmed by C-III, PDF 190 |
| xs_km … zs_km, dxs_mps … dzs_mps, ddxs_mps2 … ddzs_mps2 | Table B-II, PDF 108–115 | PACSS 13; accelerations kinematic | H (one cell M). **VERIFIER:** all H; 684 s ZS is corrected and confirmed by C-II, PDF 179 |
| fpa_calc_deg, head_calc_deg | derived from B-II (**inferred**) | geocentric inertial FPA and heading, 0.001° resolution | H (they reproduce Table 3-III, 3-IV and 4-III to 0.001°) |
| crossrange_ye_km, crossrange_dye_mps | derived from B-II (**inferred**) | PACSS 10 YE and DYE, the PFT's "cross range" and "cross-range velocity" (§4.3) | H (they reproduce Tables 3-III and 3-IV to 0.1 km and 0.1 m/s) |
| a_nongrav_mps2 | derived: \|a_B-II − g_J2\| (**inferred**) | non-gravitational acceleration magnitude | M |
| chiY_thrust_deg, chiZ_thrust_deg | derived (**inferred**) | direction u of the non-gravitational acceleration in PACSS 13, expressed in the repo's chi convention. That convention, nose = (cos χZ cos χY, sin χZ, −cos χZ sin χY), is inferred from `SaturnIU`: command = frame·R_Y(χY)·R_Z(χZ)·R_X(χX); χY < 0 tilts the nose downrange.: χY = atan2(−u_Z, u_X), χZ = asin(u_Y). Blank where \|a_ng\| < 1 m/s² or in the staging transients (162.3, 164 s). | L–M |
| pdf_page_b3, pdf_page_b2, grade_printed, grade_derived, note | — | provenance | — |

The thrust-direction angles are *not* attitude. They equal the vehicle x-axis only if the thrust passes through the cg with the engines at null. Expected differences:
- engine gimbal and cg offset: a few tenths of a degree;
- acceleration resolution (0.01 m/s² of a 6–18 m/s² signal): about 0.05–0.1°;
- the PFT's numerical differentiation: noise of about 0.1–0.3°.

Treat them as a check that the simulated IGM steers the right way at the right time, not as commanded chi.

### 3.2 Verification

Scripts: `igm/scripts/pft_check_b2.py`, `pft_check_geo.py`, `pft_check_defs.py`, `pft_thrustdir.py`, `pft_elements.py`.

1. **B-III recomputed from B-II** (frame of §2.2, Earth rotation since GRR, Fischer 1960). Worst residuals over the 91 rows other than 684 s (**VERIFIER:** over all 92 rows once 684 s ZS is corrected; reproduced independently by `igm/scripts/pftver_check.py`):
   - GC DIST 0.8 m; LONG and GC LAT 0.0001°;
   - VEL-AZ and VEL-EL 0.006°; HEAD and FLT-PATH 0.005°;
   - EF VEL 0.08 m/s; SF VEL 0.09 m/s;
   - ALTITUDE 1.7 m; RANGE 66 m (definition, §2.4).
   - Every one of the 1,840 transcribed cells enters at least one of these checks. The accelerations are checked by item 2 and by the coast and Table 3-II checks of §2.5.
2. **B-II kinematics.** Trapezoid propagation x₁ = x₀ + h(v₀+v₁)/2 − h²(a₁−a₀)/12 between consecutive rows. Position residuals are ≤ 1.2 m everywhere except at the anomalies in §3.3. Velocity residuals are ≤ 0.5 m/s, except across thrust steps: S-II ignition at 164–166 s, IGM start at 200–210 s, EMR shift at 490–500 s, S-II cutoff at 548–549 s.
3. **Event rows against Tables 3-III, 3-IV and 4-III** (separately printed, read from images): every value agrees.
   - At S-IC OECO: altitude 66.1 km; range 93.6 km; SF VEL 2,764.1 m/s; FPA 19.114° (19.114 calc); heading 75.439° (75.438 calc).
   - At S-II OECO: 187.3 km; 1,618.4 km; 6,916.1 m/s; 0.619° (0.619 calc); 82.396° (82.397 calc).
   - At S-IVB cutoff: 191.1 km; 2,633.5 km; 7,791.2 m/s; 0.011° (0.011 calc); 88.414° (88.414 calc).
   - At insertion: 7,793.1 m/s; 0.012° (0.012 calc); 88.848° (88.848 calc); longitude −52.694°.

### 3.3 Anomalies (in the document, not in the transcription)

- **684.0 s, B-II ZS = 2784.595 km.** The value is clearly printed (re-read at 300 dpi). It is 10 m off its neighbours' kinematics, and B-III GC DIST and ALTITUDE at 684 s are consistent with ZS ≈ 2784.585. It is probably a PFT print error. Kept as printed and graded M. It affects GC DIST by 4 m.
  - **VERIFIER, corrected to 2784.585 km (H).** At 600 dpi (PDF 115) the second-decimal glyph is not clean. It has the open lower-left stroke that this line printer leaves on a damaged **8**.
    - The same defect makes 696 s ZS read "2869.275" (the true value, 2868.275, is in the CSV). It also makes 708 s DXS read "−3504.9" (true value −3504.8; C-II prints −11,498.8 ft/s = −3504.83 m/s).
    - Table C-II (English units, PDF 179) prints the 684 s ZS as **1,503.556 n mi = 2,784.586 km**. A value of 2784.595 would print as 1,503.561.
    - With 2784.585, the 684 s row fits B-III to −0.2 m (GC DIST) and −1.5 m (ALTITUDE), and the 682/686 s Hermite interpolation to 0.2 m. The derived columns do not change at printed precision.
    - So this is not a PFT print error. The CSV now has 2784.585, grade H.
- **660.0 s, B-III LONG.** The last digits are glyph-damaged; the value reads −56.4083. That value is confirmed by recomputation from B-II (residual 0.0000°), whereas a misreading as −56.4093 would leave 0.0010°. Graded M. **VERIFIER:** Table C-III (PDF 190) prints −56.4083 cleanly. Upgraded to H.
- **460.62 s (S-II CECO event row).**
  - XS and ZS jump about +20 m and −105 m relative to the 460.0 and 462.0 rows propagated with their velocities. The velocity jump is ≤ 0.3 m/s.
  - B-II and B-III event rows agree with each other (residual 0.6 m), so this is how the PFT computed the event state.
  - Prefer the 460.0 and 462.0 rows for position continuity at CECO.
  - **VERIFIER (inferred, M):** the offset is a **time-tag offset**, not a random jump.
    - The printed event position matches a cubic-Hermite interpolation of the 460.0 and 462.0 rows at **t = 460.601 s** (miss 2.0 m). At 460.62 s the miss is (+19.7, −0.9, −104.9) m, which is the velocity vector times −0.019 s.
    - The velocity offset (+0.13, −0.04, −0.28) m/s equals the acceleration times −0.019 s, which is (+0.17, 0.00, −0.30) m/s.
    - So the whole event-row state belongs to about 460.60 s. The other event rows (162.3, 548.22, 549.0, 699.33 s) show no such offset (≤ 0.8 m).
- **709.33 s (insertion row).**
  - The position is about 65 m (XS) and 26 m (ZS) off the 708.0 row propagated. GC DIST and ALTITUDE *drop* by 67 m in 1.33 s at FPA +0.01°.
  - **VERIFIER:** in local axes the offset is **−70.0 m radial, +6.3 m along-track and −4.6 m cross-track**, almost purely vertical. The velocity offset is (−0.23, +0.05, +0.05) m/s. C-II (PDF 179) prints the same insertion state (3162.123 / 50.665 / 1598.961 n mi).
    - The vertical offset (70 m) is smaller than the 170 m vertical spread between the powered-flight and orbital solutions that Sec. 5.1.4 quotes, so the "OCP vector" reading below is plausible but not proven (inferred, M).
  - The PFT says the ascent solution was constrained to the orbital (OCP) insertion vector, and that the powered-flight and orbital solutions at insertion differed by 70 m downrange, 170 m vertical and 130 m crossrange (Sec. 3.3.1 p. 3-5, Sec. 5.1.4 p. 5-2).
  - So the 709.33 row is the OCP insertion vector, while the 2-s rows to 708 s are the powered-flight solution (inferred).
  - The velocities are continuous to ≤ 0.2 m/s.

### 3.4 Accuracy of the reconstruction (PFT Sec. 5.2 p. 5-3, Fig. 5-1 p. 5-4 / PDF 69–70; H)

The 1-σ-like "uncertainties" of the reconstructed trajectory in PACSS 10 components (**VERIFIER:** the PFT does not call them 1-σ. Sec. 5.2 says they were estimated "based on the information of Paragraph 5.1, past experience, and engineering judgment" (PDF 69). Values re-read: all agree.):

| Point | Position | Velocity |
|---|---|---|
| S-IC OECO | ±60 m | ±0.4 m/s |
| S-II OECO | ±350 m | ±0.7 m/s |
| Insertion and parking orbit | ±500 m | ±1.0 m/s |

Fig. 5-1 shows the position uncertainty growing roughly linearly with time and the velocity uncertainty passing 0.5 m/s at about 380 s.
Other figures from Section 5:
- Guidance-velocity vs reconstruction maximum differences, ascent (Sec. 5.1.3, PACSS 12): 1.5 m/s in X, 2.8 m/s in Y, 0.7 m/s in Z.
- Spread of three orbital solutions at insertion: 60 m and 0.3 m/s downrange (Z), 275 m and 0.1 m/s vertical (X), 80 m and 0.2 m/s crossrange (Y).

### 3.5 Features of the IGM flight visible in the data (inferred, from the CSV)

- **S-IC OECO → S-II.** The derived thrust direction stays near χY ≈ −68.2° to −69.0° from 166 to 200 s, a constant attitude. Between 200 and 210 s it steps to about −61° to −63°, which is **IGM initiation**: B-II DDXS changes from −6.46 at 200 s to −5.65 at 210 s, and the trapezoid velocity residual is −2.25 m/s. It then pitches down steadily: about −72° at 320 s, −85° at 430 s, −88.9° at CECO.
  - **VERIFIER refinement (inferred, M)** from the 2-s B-II rows 198–220 s (PDF 109, read by the verifier; `igm/scripts/pftver_chi2s.py`):
    - χY_thr is −68.5 (198 s), −68.7 (200), −69.3 (202) and −69.2 (204).
    - It then rises: −68.1 (206), −65.7 (208), −63.5 (210), −62.1 (212).
    - It levels off at −61.0 to −61.4 from 214 to 220 s.
    - So the onset is **between 204 and 206 s**, the up-pitch is about 8° at about 1°/s, and it ends by about 214 s. This agrees with FER Table 10-4, which puts IGM phase 1 at 204.07 s (as transcribed in `igm/fer-guidance.md`), and with the FER's +6.5–7.6° up-pitch peaking near 212 s.
    - χZ_thr goes from −0.05° to −0.43° over the same interval.
- **S-II CECO (460.62 s).** The non-gravitational acceleration drops from 17.84 to 14.38 m/s² (ratio 0.81). A 0.5–1.5° pitch excursion follows (χY −89.3 → −87.4 → −89.3 between 466 and 490 s).
- **S-II EMR shift: between 498 and 500 s.** DDZS goes from 14.11 to 10.69 and a_ng from about 16.0 to 12.9 m/s² (B-II PDF 112; Fig. 3-6 labels it "S-II EMR SHIFT").
- **S-II OECO (548.22 s), separation (549.0).** S-IVB thrust builds up between 552 and 556 s (a_ng 0.27 → 5.06 m/s²).
- **S-IVB burn.** χY goes −96° (560 s) → −101.7° (600) → −108.9° (650) → −113.2° (678). It then stays at **−113.0° to −113.3°** from 678 s to cutoff, consistent with the IGM terminal freeze of the steering angles. χZ is +0.24° to +0.57° during the S-IVB burn.
  - **VERIFIER correction (inferred, M), plateau attribution.** The plateau does not come from the chi freeze.
    - The 2-s rows (PDF 114–115) show a nose-down step of about 2.6° between 666 and 672 s: χY_thr −110.3 (660), −110.6 (662), −110.7 (664), −110.9 (666), −111.6 (668), −112.6 (670), −113.4 (672), −113.6 (674), −113.4 (676), −113.2 (678).
    - This is FER Table 10-4's **begin terminal guidance at 665.15 s**, with its "2–2.5° nose-down step" (`igm/fer-guidance.md`). The ~1–2 s apparent lag fits the PFT's filtered, differentiated accelerations.
    - The near-constant χY from 672 s is terminal-guidance steering. FER Table 10-4 puts the **chi freeze at 691.64–699.26 s**, which is not visible as a separate feature in the PFT.
    - The PFT cutoff thrust direction is −113.0°, against the FER's LVDC cutoff attitude of −113.6° (OT −112.4°).
  - **VERIFIER correction, χZ.** χZ_thr is +0.24° to +0.57° only from 580 s to cutoff. From 554 to 570 s it is between −0.40° and +0.02° (−0.32 at 554 s, +0.02 at 556 and 558, −0.40 at 560, −0.27 at 570), during the S-IVB start and the artificial-tau period.
- **Cutoff conditions (699.33 s).**
  - From B-II (H): R = 6,563.105 km, V = 7,791.2 m/s, FPA = 0.011°, heading 88.414°.
  - After tail-off (insertion, 709.33 s): V = 7,793.06 m/s.
  - The tail-off adds about 1.9 m/s.
  - **VERIFIER:** the tail-off itself adds **about 1.7 m/s**. SF VEL is already 7,792.9 m/s at 700.0 s and stays there through 708.0 s. The last +0.2 m/s at 709.33 s comes with the insertion-row discontinuity (§3.3).

### 3.6 The digitised table

The same numbers are in the CSV. The PDF pages are given per row in the CSV. B-III rows come from PDF 120–127 and B-II rows from PDF 108–115.

**Geographic (Table B-III):**

| t (s) | event | ALT (m) | SF VEL (m/s) | FLT-PATH (deg) | HEAD (deg) | RANGE (m) | GC DIST (km) | GC LAT (deg N) | LONG (deg E) | EF VEL (m/s) | VEL-AZ | VEL-EL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 161.63 | S-IC OECO (engine solenoid) | 66119 | 2764.1 | 19.11 | 75.44 | 93579 | 6439.335 | 28.7007 | -79.6908 | 2393.3 | 72.76 | 22.22 |
| 162.00 |  | 66455 | 2772.3 | 19.06 | 75.43 | 94391 | 6439.669 | 28.7029 | -79.6828 | 2401.3 | 72.77 | 22.15 |
| 162.30 | S-IC/S-II separation command | 66726 | 2773.9 | 19.02 | 75.44 | 95050 | 6439.940 | 28.7046 | -79.6764 | 2402.7 | 72.77 | 22.10 |
| 164.00 |  | 68252 | 2769.3 | 18.74 | 75.46 | 98790 | 6441.463 | 28.7146 | -79.6398 | 2397.4 | 72.79 | 21.79 |
| 166.00 |  | 70023 | 2767.2 | 18.42 | 75.48 | 103203 | 6443.230 | 28.7263 | -79.5966 | 2394.3 | 72.82 | 21.42 |
| 168.00 |  | 71762 | 2773.8 | 18.11 | 75.49 | 107621 | 6444.966 | 28.7380 | -79.5533 | 2400.1 | 72.85 | 21.06 |
| 170.00 |  | 73478 | 2782.0 | 17.80 | 75.50 | 112062 | 6446.678 | 28.7498 | -79.5098 | 2407.4 | 72.88 | 20.69 |
| 172.00 |  | 75172 | 2791.4 | 17.50 | 75.51 | 116528 | 6448.368 | 28.7616 | -79.4660 | 2416.0 | 72.90 | 20.34 |
| 180.00 |  | 81731 | 2831.7 | 16.34 | 75.56 | 134646 | 6454.912 | 28.8094 | -79.2883 | 2453.1 | 73.01 | 18.95 |
| 190.00 |  | 89454 | 2885.8 | 14.95 | 75.62 | 157886 | 6462.616 | 28.8701 | -79.0601 | 2503.8 | 73.16 | 17.30 |
| 200.00 |  | 96668 | 2944.0 | 13.65 | 75.68 | 181802 | 6469.810 | 28.9322 | -78.8250 | 2559.0 | 73.31 | 15.75 |
| 210.00 |  | 103394 | 3005.9 | 12.45 | 75.75 | 206416 | 6476.517 | 28.9955 | -78.5826 | 2618.4 | 73.45 | 14.33 |
| 220.00 |  | 109711 | 3068.4 | 11.50 | 75.82 | 231718 | 6482.813 | 29.0600 | -78.3331 | 2678.9 | 73.60 | 13.20 |
| 230.00 |  | 115678 | 3133.5 | 10.62 | 75.90 | 257701 | 6488.759 | 29.1257 | -78.0766 | 2742.4 | 73.74 | 12.16 |
| 240.00 |  | 121306 | 3201.8 | 9.78 | 75.98 | 284387 | 6494.366 | 29.1925 | -77.8127 | 2809.1 | 73.90 | 11.17 |
| 250.00 |  | 126603 | 3273.2 | 8.99 | 76.07 | 311798 | 6499.641 | 29.2605 | -77.5413 | 2879.2 | 74.06 | 10.23 |
| 260.00 |  | 131578 | 3347.9 | 8.24 | 76.17 | 339960 | 6504.594 | 29.3297 | -77.2621 | 2952.7 | 74.22 | 9.35 |
| 270.00 |  | 136241 | 3425.9 | 7.53 | 76.27 | 368898 | 6509.235 | 29.4001 | -76.9747 | 3029.7 | 74.39 | 8.52 |
| 280.00 |  | 140601 | 3507.4 | 6.86 | 76.38 | 398641 | 6513.572 | 29.4717 | -76.6788 | 3110.3 | 74.57 | 7.74 |
| 290.00 |  | 144668 | 3592.4 | 6.23 | 76.49 | 429217 | 6517.615 | 29.5444 | -76.3742 | 3194.5 | 74.75 | 7.01 |
| 300.00 |  | 148451 | 3680.9 | 5.65 | 76.62 | 460655 | 6521.375 | 29.6183 | -76.0605 | 3282.3 | 74.93 | 6.33 |
| 310.00 |  | 151962 | 3772.9 | 5.10 | 76.74 | 492986 | 6524.861 | 29.6934 | -75.7374 | 3373.7 | 75.13 | 5.70 |
| 320.00 |  | 155210 | 3868.7 | 4.59 | 76.88 | 526242 | 6528.084 | 29.7696 | -75.4045 | 3468.9 | 75.32 | 5.12 |
| 330.00 |  | 158206 | 3968.2 | 4.12 | 77.02 | 560456 | 6531.056 | 29.8471 | -75.0613 | 3568.0 | 75.53 | 4.58 |
| 340.00 |  | 160963 | 4071.7 | 3.68 | 77.17 | 595663 | 6533.787 | 29.9256 | -74.7077 | 3671.2 | 75.74 | 4.08 |
| 350.00 |  | 163491 | 4179.3 | 3.28 | 77.33 | 631900 | 6536.290 | 30.0053 | -74.3430 | 3778.4 | 75.95 | 3.63 |
| 360.00 |  | 165804 | 4291.2 | 2.91 | 77.50 | 669205 | 6538.576 | 30.0860 | -73.9670 | 3890.0 | 76.18 | 3.22 |
| 370.00 |  | 167913 | 4407.5 | 2.58 | 77.67 | 707620 | 6540.659 | 30.1679 | -73.5790 | 4006.0 | 76.41 | 2.84 |
| 380.00 |  | 169832 | 4528.2 | 2.28 | 77.85 | 747186 | 6542.550 | 30.2508 | -73.1787 | 4126.5 | 76.64 | 2.50 |
| 390.00 |  | 171573 | 4654.2 | 2.01 | 78.04 | 787949 | 6544.265 | 30.3347 | -72.7655 | 4252.4 | 76.89 | 2.20 |
| 400.00 |  | 173153 | 4785.2 | 1.77 | 78.24 | 829958 | 6545.817 | 30.4195 | -72.3389 | 4383.2 | 77.14 | 1.93 |
| 410.00 |  | 174585 | 4921.5 | 1.55 | 78.45 | 873262 | 6547.221 | 30.5053 | -71.8983 | 4519.4 | 77.40 | 1.69 |
| 420.00 |  | 175884 | 5063.7 | 1.37 | 78.66 | 917913 | 6548.491 | 30.5920 | -71.4431 | 4661.5 | 77.67 | 1.49 |
| 430.00 |  | 177067 | 5211.9 | 1.21 | 78.89 | 963973 | 6549.646 | 30.6794 | -70.9727 | 4809.6 | 77.95 | 1.31 |
| 440.00 |  | 178152 | 5366.6 | 1.08 | 79.13 | 1011499 | 6550.702 | 30.7676 | -70.4863 | 4964.2 | 78.23 | 1.17 |
| 450.00 |  | 179159 | 5528.3 | 0.98 | 79.37 | 1060557 | 6551.679 | 30.8565 | -69.9832 | 5125.8 | 78.53 | 1.06 |
| 456.00 |  | 179734 | 5628.7 | 0.93 | 79.53 | 1090756 | 6552.237 | 30.9101 | -69.6731 | 5226.2 | 78.71 | 1.00 |
| 458.00 |  | 179922 | 5662.8 | 0.92 | 79.58 | 1100953 | 6552.418 | 30.9280 | -69.5683 | 5260.3 | 78.77 | 0.99 |
| 460.00 |  | 180108 | 5697.2 | 0.90 | 79.63 | 1111216 | 6552.599 | 30.9459 | -69.4627 | 5294.6 | 78.83 | 0.97 |
| 460.62 | S-II CECO (engine solenoid) | 180163 | 5707.5 | 0.90 | 79.65 | 1114308 | 6552.652 | 30.9513 | -69.4309 | 5305.0 | 78.85 | 0.97 |
| 462.00 |  | 180292 | 5727.7 | 0.88 | 79.68 | 1121543 | 6552.777 | 30.9638 | -69.3565 | 5325.1 | 78.89 | 0.95 |
| 464.00 |  | 180472 | 5755.6 | 0.85 | 79.74 | 1131926 | 6552.951 | 30.9818 | -69.2496 | 5353.0 | 78.96 | 0.92 |
| 466.00 |  | 180646 | 5783.7 | 0.83 | 79.79 | 1142363 | 6553.120 | 30.9997 | -69.1422 | 5381.1 | 79.02 | 0.89 |
| 470.00 |  | 180986 | 5840.2 | 0.79 | 79.90 | 1163401 | 6553.447 | 31.0355 | -68.9254 | 5437.6 | 79.14 | 0.85 |
| 480.00 |  | 181811 | 5984.4 | 0.76 | 80.18 | 1216964 | 6554.242 | 31.1249 | -68.3729 | 5581.7 | 79.46 | 0.82 |
| 490.00 |  | 182649 | 6134.1 | 0.77 | 80.47 | 1271945 | 6555.051 | 31.2139 | -67.8046 | 5731.4 | 79.79 | 0.82 |
| 500.00 |  | 183511 | 6286.2 | 0.76 | 80.78 | 1328402 | 6555.884 | 31.3024 | -67.2198 | 5883.4 | 80.14 | 0.81 |
| 510.00 |  | 184348 | 6410.0 | 0.70 | 81.10 | 1386179 | 6556.692 | 31.3898 | -66.6202 | 6007.2 | 80.49 | 0.75 |
| 520.00 |  | 185142 | 6536.4 | 0.66 | 81.42 | 1445163 | 6557.458 | 31.4757 | -66.0068 | 6133.4 | 80.86 | 0.70 |
| 530.00 |  | 185917 | 6666.8 | 0.64 | 81.76 | 1505386 | 6558.204 | 31.5600 | -65.3794 | 6263.8 | 81.23 | 0.68 |
| 540.00 |  | 186683 | 6801.8 | 0.62 | 82.11 | 1566890 | 6558.943 | 31.6426 | -64.7373 | 6398.8 | 81.61 | 0.66 |
| 542.00 |  | 186837 | 6829.3 | 0.62 | 82.18 | 1579349 | 6559.091 | 31.6588 | -64.6071 | 6426.2 | 81.68 | 0.66 |
| 544.00 |  | 186990 | 6857.0 | 0.62 | 82.25 | 1591861 | 6559.239 | 31.6750 | -64.4763 | 6453.9 | 81.76 | 0.66 |
| 546.00 |  | 187144 | 6884.9 | 0.62 | 82.32 | 1604427 | 6559.388 | 31.6911 | -64.3449 | 6481.8 | 81.84 | 0.66 |
| 548.00 |  | 187299 | 6912.9 | 0.62 | 82.39 | 1617046 | 6559.537 | 31.7072 | -64.2129 | 6509.8 | 81.91 | 0.66 |
| 548.22 | S-II OECO (engine solenoid) | 187316 | 6916.1 | 0.62 | 82.40 | 1618437 | 6559.553 | 31.7089 | -64.1983 | 6513.0 | 81.92 | 0.66 |
| 549.00 | S-II/S-IVB separation command | 187377 | 6918.8 | 0.61 | 82.43 | 1623370 | 6559.612 | 31.7152 | -64.1467 | 6515.7 | 81.95 | 0.65 |
| 550.00 |  | 187454 | 6918.9 | 0.59 | 82.46 | 1629697 | 6559.687 | 31.7231 | -64.0805 | 6515.8 | 81.99 | 0.63 |
| 552.00 |  | 187596 | 6919.2 | 0.56 | 82.54 | 1642362 | 6559.823 | 31.7389 | -63.9479 | 6516.1 | 82.07 | 0.60 |
| 554.00 |  | 187735 | 6921.7 | 0.53 | 82.61 | 1655024 | 6559.958 | 31.7545 | -63.8152 | 6518.5 | 82.15 | 0.57 |
| 556.00 |  | 187867 | 6930.6 | 0.51 | 82.69 | 1667696 | 6560.084 | 31.7700 | -63.6825 | 6527.4 | 82.23 | 0.54 |
| 558.00 |  | 187993 | 6940.7 | 0.49 | 82.76 | 1680385 | 6560.205 | 31.7853 | -63.5495 | 6537.6 | 82.31 | 0.52 |
| 560.00 |  | 188116 | 6951.2 | 0.48 | 82.83 | 1693095 | 6560.323 | 31.8006 | -63.4162 | 6548.1 | 82.39 | 0.51 |
| 570.00 |  | 188685 | 7004.9 | 0.42 | 83.20 | 1756950 | 6560.867 | 31.8747 | -62.7460 | 6601.6 | 82.78 | 0.44 |
| 580.00 |  | 189187 | 7059.6 | 0.36 | 83.57 | 1821326 | 6561.345 | 31.9454 | -62.0692 | 6656.3 | 83.18 | 0.38 |
| 590.00 |  | 189621 | 7115.3 | 0.30 | 83.95 | 1886234 | 6561.756 | 32.0127 | -61.3857 | 6712.0 | 83.59 | 0.32 |
| 600.00 |  | 189989 | 7172.1 | 0.25 | 84.34 | 1951683 | 6562.103 | 32.0763 | -60.6955 | 6768.7 | 84.00 | 0.27 |
| 610.00 |  | 190294 | 7229.8 | 0.20 | 84.73 | 2017685 | 6562.388 | 32.1362 | -59.9984 | 6826.4 | 84.42 | 0.21 |
| 620.00 |  | 190542 | 7288.7 | 0.16 | 85.13 | 2084250 | 6562.617 | 32.1922 | -59.2944 | 6885.3 | 84.84 | 0.17 |
| 630.00 |  | 190736 | 7348.5 | 0.12 | 85.53 | 2151389 | 6562.793 | 32.2443 | -58.5835 | 6945.1 | 85.27 | 0.13 |
| 640.00 |  | 190882 | 7409.3 | 0.08 | 85.93 | 2219111 | 6562.923 | 32.2922 | -57.8655 | 7005.8 | 85.70 | 0.09 |
| 650.00 |  | 190987 | 7471.0 | 0.06 | 86.34 | 2287427 | 6563.014 | 32.3360 | -57.1405 | 7067.5 | 86.13 | 0.06 |
| 660.00 |  | 191059 | 7534.0 | 0.03 | 86.75 | 2356346 | 6563.072 | 32.3755 | -56.4083 | 7130.5 | 86.57 | 0.04 |
| 670.00 |  | 191103 | 7597.8 | 0.02 | 87.17 | 2425880 | 6563.105 | 32.4105 | -55.6690 | 7194.3 | 87.01 | 0.02 |
| 678.00 |  | 191119 | 7649.8 | -0.00 | 87.50 | 2481957 | 6563.112 | 32.4353 | -55.0723 | 7246.2 | 87.37 | -0.00 |
| 680.00 |  | 191120 | 7662.8 | -0.00 | 87.59 | 2496040 | 6563.111 | 32.4410 | -54.9225 | 7259.3 | 87.45 | -0.00 |
| 682.00 |  | 191121 | 7676.0 | -0.01 | 87.67 | 2510147 | 6563.110 | 32.4465 | -54.7723 | 7272.4 | 87.54 | -0.01 |
| 684.00 |  | 191121 | 7689.1 | -0.01 | 87.76 | 2524281 | 6563.108 | 32.4519 | -54.6218 | 7285.6 | 87.63 | -0.01 |
| 686.00 |  | 191121 | 7702.3 | -0.01 | 87.84 | 2538440 | 6563.106 | 32.4570 | -54.4710 | 7298.8 | 87.72 | -0.01 |
| 688.00 |  | 191121 | 7715.5 | -0.01 | 87.93 | 2552624 | 6563.105 | 32.4620 | -54.3200 | 7312.0 | 87.81 | -0.01 |
| 690.00 |  | 191121 | 7728.8 | -0.00 | 88.01 | 2566835 | 6563.103 | 32.4668 | -54.1686 | 7325.3 | 87.90 | -0.01 |
| 692.00 |  | 191121 | 7742.1 | -0.00 | 88.10 | 2581071 | 6563.102 | 32.4714 | -54.0170 | 7338.6 | 87.99 | -0.00 |
| 694.00 |  | 191122 | 7755.5 | -0.00 | 88.18 | 2595333 | 6563.102 | 32.4757 | -53.8651 | 7351.9 | 88.09 | -0.00 |
| 696.00 |  | 191124 | 7768.8 | 0.00 | 88.27 | 2609620 | 6563.102 | 32.4799 | -53.7129 | 7365.3 | 88.18 | 0.00 |
| 698.00 |  | 191127 | 7782.2 | 0.01 | 88.36 | 2623934 | 6563.104 | 32.4839 | -53.5603 | 7378.7 | 88.27 | 0.01 |
| 699.33 | S-IVB 1st guidance cutoff | 191130 | 7791.2 | 0.01 | 88.41 | 2633468 | 6563.105 | 32.4865 | -53.4588 | 7387.6 | 88.33 | 0.01 |
| 700.00 |  | 191131 | 7792.9 | 0.01 | 88.44 | 2638273 | 6563.107 | 32.4877 | -53.4075 | 7389.3 | 88.36 | 0.01 |
| 702.00 |  | 191136 | 7792.9 | 0.01 | 88.53 | 2652621 | 6563.110 | 32.4913 | -53.2547 | 7389.4 | 88.45 | 0.01 |
| 704.00 |  | 191140 | 7792.9 | 0.01 | 88.62 | 2666968 | 6563.113 | 32.4947 | -53.1017 | 7389.4 | 88.54 | 0.01 |
| 706.00 |  | 191144 | 7792.9 | 0.01 | 88.70 | 2681316 | 6563.116 | 32.4979 | -52.9488 | 7389.4 | 88.63 | 0.01 |
| 708.00 |  | 191149 | 7792.9 | 0.01 | 88.79 | 2695664 | 6563.119 | 32.5009 | -52.7959 | 7389.4 | 88.72 | 0.01 |
| 709.33 | parking orbit insertion | 191082 | 7793.1 | 0.01 | 88.85 | 2705210 | 6563.052 | 32.5027 | -52.6941 | 7389.5 | 88.78 | 0.01 |

**Navigation frame PACSS 13 (Table B-II), with derived (inferred) columns:**

| t (s) | XS (km) | YS (km) | ZS (km) | DXS (m/s) | DYS (m/s) | DZS (m/s) | DDXS | DDYS | DDZS (m/s²) | FPA calc (deg) | HEAD calc (deg) | a_ng (m/s²) | chiY_thr (deg) | chiZ_thr (deg) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 161.63 | 6437.246 | 39.441 | 159.164 | 839.6 | 123.1 | 2630.6 | 4.15 | -0.07 | 35.83 | 19.114 | 75.438 | 38.61 | -69.11 | -0.03 |
| 162.00 | 6437.557 | 39.486 | 160.138 | 839.4 | 123.1 | 2639.3 | -4.09 | -0.03 | 13.71 | 19.064 | 75.434 | 15.01 | -68.40 | 0.06 |
| 162.30 | 6437.808 | 39.523 | 160.929 | 837.5 | 123.1 | 2641.6 | -9.44 | -0.01 | 1.23 | 19.019 | 75.436 | 1.48 | – | – |
| 164.00 | 6439.216 | 39.733 | 165.415 | 821.6 | 123.0 | 2641.8 | -9.40 | -0.01 | 0.18 | 18.744 | 75.456 | 0.48 | – | – |
| 166.00 | 6440.844 | 39.979 | 170.707 | 803.8 | 122.9 | 2645.0 | -7.46 | -0.10 | 5.31 | 18.419 | 75.477 | 5.97 | -68.95 | -0.51 |
| 168.00 | 6442.436 | 40.224 | 176.007 | 789.3 | 122.8 | 2656.3 | -7.20 | -0.05 | 5.73 | 18.112 | 75.491 | 6.46 | -68.21 | -0.02 |
| 170.00 | 6444.000 | 40.470 | 181.332 | 775.1 | 122.6 | 2669.0 | -6.83 | -0.08 | 6.84 | 17.804 | 75.501 | 7.63 | -68.78 | -0.24 |
| 172.00 | 6445.537 | 40.715 | 186.684 | 761.5 | 122.5 | 2682.7 | -6.79 | -0.10 | 6.90 | 17.505 | 75.512 | 7.71 | -68.72 | -0.38 |
| 180.00 | 6451.413 | 41.693 | 208.371 | 707.7 | 122.0 | 2739.1 | -6.66 | -0.06 | 7.12 | 16.337 | 75.556 | 7.98 | -68.65 | -0.07 |
| 190.00 | 6458.158 | 42.909 | 236.120 | 641.5 | 121.3 | 2811.0 | -6.57 | -0.06 | 7.26 | 14.952 | 75.615 | 8.17 | -68.68 | -0.06 |
| 200.00 | 6464.247 | 44.119 | 264.596 | 576.4 | 120.7 | 2884.5 | -6.46 | -0.06 | 7.47 | 13.649 | 75.682 | 8.44 | -68.74 | -0.05 |
| 210.00 | 6469.690 | 45.322 | 293.817 | 513.6 | 119.9 | 2959.3 | -5.65 | -0.11 | 7.28 | 12.452 | 75.751 | 8.62 | -63.50 | -0.37 |
| 220.00 | 6474.556 | 46.515 | 323.770 | 460.2 | 118.7 | 3031.3 | -5.22 | -0.10 | 7.23 | 11.502 | 75.820 | 8.80 | -61.09 | -0.29 |
| 230.00 | 6478.895 | 47.697 | 354.449 | 407.7 | 117.6 | 3104.7 | -5.27 | -0.11 | 7.43 | 10.621 | 75.898 | 8.99 | -62.23 | -0.33 |
| 240.00 | 6482.708 | 48.867 | 385.870 | 354.8 | 116.5 | 3179.9 | -5.30 | -0.11 | 7.62 | 9.782 | 75.981 | 9.17 | -63.18 | -0.32 |
| 250.00 | 6485.990 | 50.027 | 418.054 | 301.5 | 115.4 | 3257.3 | -5.34 | -0.10 | 7.84 | 8.986 | 76.070 | 9.38 | -64.23 | -0.24 |
| 260.00 | 6488.737 | 51.176 | 451.023 | 247.9 | 114.4 | 3336.7 | -5.38 | -0.10 | 8.05 | 8.236 | 76.167 | 9.59 | -65.21 | -0.23 |
| 270.00 | 6490.946 | 52.314 | 484.797 | 193.7 | 113.3 | 3418.5 | -5.43 | -0.11 | 8.29 | 7.525 | 76.268 | 9.83 | -66.26 | -0.27 |
| 280.00 | 6492.610 | 53.442 | 519.402 | 139.1 | 112.3 | 3502.9 | -5.49 | -0.10 | 8.55 | 6.859 | 76.377 | 10.08 | -67.37 | -0.20 |
| 290.00 | 6493.725 | 54.559 | 554.863 | 83.7 | 111.3 | 3589.7 | -5.56 | -0.09 | 8.80 | 6.231 | 76.493 | 10.32 | -68.45 | -0.13 |
| 300.00 | 6494.283 | 55.667 | 591.205 | 27.7 | 110.4 | 3679.1 | -5.63 | -0.09 | 9.07 | 5.645 | 76.616 | 10.59 | -69.51 | -0.12 |
| 310.00 | 6494.277 | 56.766 | 628.454 | -29.0 | 109.4 | 3771.2 | -5.72 | -0.10 | 9.35 | 5.099 | 76.744 | 10.87 | -70.65 | -0.16 |
| 320.00 | 6493.699 | 57.855 | 666.638 | -86.7 | 108.4 | 3866.2 | -5.80 | -0.09 | 9.65 | 4.589 | 76.879 | 11.17 | -71.70 | -0.10 |
| 330.00 | 6492.541 | 58.934 | 705.787 | -145.3 | 107.4 | 3964.1 | -5.91 | -0.09 | 9.95 | 4.117 | 77.021 | 11.47 | -72.85 | -0.09 |
| 340.00 | 6490.791 | 60.003 | 745.931 | -204.9 | 106.5 | 4065.2 | -6.02 | -0.09 | 10.26 | 3.683 | 77.172 | 11.79 | -73.95 | -0.08 |
| 350.00 | 6488.438 | 61.063 | 787.101 | -265.8 | 105.6 | 4169.5 | -6.13 | -0.08 | 10.60 | 3.281 | 77.330 | 12.14 | -75.03 | -0.02 |
| 360.00 | 6485.470 | 62.115 | 829.332 | -328.0 | 104.7 | 4277.3 | -6.27 | -0.09 | 10.96 | 2.914 | 77.495 | 12.51 | -76.21 | -0.06 |
| 370.00 | 6481.874 | 63.158 | 872.659 | -391.6 | 103.8 | 4388.8 | -6.44 | -0.10 | 11.35 | 2.581 | 77.668 | 12.90 | -77.48 | -0.10 |
| 380.00 | 6477.634 | 64.191 | 917.119 | -456.8 | 102.9 | 4503.9 | -6.62 | -0.09 | 11.76 | 2.279 | 77.849 | 13.33 | -78.74 | -0.05 |
| 390.00 | 6472.732 | 65.216 | 962.754 | -523.8 | 102.1 | 4623.5 | -6.77 | -0.07 | 12.14 | 2.009 | 78.040 | 13.73 | -79.77 | 0.04 |
| 400.00 | 6467.151 | 66.233 | 1009.604 | -592.8 | 101.2 | 4747.2 | -7.00 | -0.06 | 12.61 | 1.767 | 78.238 | 14.22 | -81.12 | 0.09 |
| 410.00 | 6460.868 | 67.241 | 1057.714 | -664.0 | 100.4 | 4875.5 | -7.24 | -0.08 | 13.02 | 1.554 | 78.445 | 14.65 | -82.40 | 0.01 |
| 420.00 | 6453.863 | 68.242 | 1107.129 | -737.5 | 99.7 | 5008.7 | -7.47 | -0.07 | 13.62 | 1.369 | 78.663 | 15.29 | -83.64 | 0.05 |
| 430.00 | 6446.109 | 69.235 | 1157.904 | -813.6 | 98.9 | 5147.1 | -7.73 | -0.08 | 14.11 | 1.212 | 78.890 | 15.82 | -84.86 | 0.02 |
| 440.00 | 6437.581 | 70.220 | 1210.089 | -892.5 | 98.2 | 5291.0 | -8.02 | -0.06 | 14.68 | 1.082 | 79.127 | 16.44 | -86.12 | 0.10 |
| 450.00 | 6428.249 | 71.199 | 1263.743 | -974.4 | 97.4 | 5440.8 | -8.35 | -0.07 | 15.29 | 0.979 | 79.373 | 17.10 | -87.44 | 0.06 |
| 456.00 | 6422.251 | 71.782 | 1296.665 | -1025.2 | 96.9 | 5533.7 | -8.57 | -0.05 | 15.67 | 0.929 | 79.525 | 17.52 | -88.26 | 0.13 |
| 458.00 | 6420.184 | 71.975 | 1307.764 | -1042.4 | 96.8 | 5565.2 | -8.63 | -0.06 | 15.80 | 0.915 | 79.578 | 17.66 | -88.48 | 0.10 |
| 460.00 | 6418.082 | 72.169 | 1318.927 | -1059.7 | 96.7 | 5596.9 | -8.75 | -0.09 | 15.92 | 0.902 | 79.631 | 17.80 | -88.89 | -0.00 |
| 460.62 | 6417.443 | 72.228 | 1322.295 | -1065.0 | 96.6 | 5606.5 | -8.76 | -0.10 | 15.96 | 0.898 | 79.646 | 17.84 | -88.93 | -0.03 |
| 462.00 | 6415.945 | 72.362 | 1330.149 | -1077.3 | 96.5 | 5624.6 | -8.81 | -0.08 | 12.49 | 0.880 | 79.684 | 14.38 | -88.88 | 0.04 |
| 464.00 | 6413.773 | 72.555 | 1341.424 | -1095.0 | 96.3 | 5649.7 | -8.88 | -0.17 | 12.54 | 0.855 | 79.738 | 14.44 | -89.18 | -0.32 |
| 466.00 | 6411.564 | 72.747 | 1352.749 | -1112.8 | 95.9 | 5674.8 | -8.90 | -0.14 | 12.60 | 0.830 | 79.790 | 14.52 | -89.27 | -0.19 |
| 470.00 | 6407.042 | 73.130 | 1375.550 | -1148.0 | 95.4 | 5725.5 | -8.65 | -0.10 | 12.76 | 0.790 | 79.899 | 14.72 | -88.34 | -0.03 |
| 480.00 | 6395.140 | 74.079 | 1433.453 | -1231.8 | 94.4 | 5855.5 | -8.36 | -0.09 | 13.21 | 0.764 | 80.180 | 15.26 | -87.39 | 0.01 |
| 490.00 | 6382.397 | 75.018 | 1492.677 | -1317.8 | 93.6 | 5990.2 | -8.84 | -0.07 | 13.72 | 0.766 | 80.472 | 15.84 | -89.30 | 0.09 |
| 500.00 | 6368.768 | 75.950 | 1553.270 | -1409.0 | 92.9 | 6125.6 | -9.36 | -0.08 | 10.69 | 0.762 | 80.776 | 12.89 | -91.55 | 0.07 |
| 510.00 | 6354.205 | 76.877 | 1615.050 | -1504.0 | 92.4 | 6230.4 | -9.61 | -0.04 | 10.51 | 0.699 | 81.095 | 12.81 | -92.78 | 0.25 |
| 520.00 | 6338.683 | 77.799 | 1677.884 | -1600.5 | 92.0 | 6336.7 | -9.75 | -0.04 | 10.76 | 0.661 | 81.425 | 13.16 | -93.43 | 0.25 |
| 530.00 | 6322.183 | 78.716 | 1741.794 | -1700.1 | 91.5 | 6445.8 | -10.15 | -0.05 | 11.04 | 0.637 | 81.762 | 13.56 | -95.14 | 0.21 |
| 540.00 | 6304.668 | 79.628 | 1806.809 | -1803.6 | 90.9 | 6557.7 | -10.52 | -0.04 | 11.33 | 0.622 | 82.106 | 13.98 | -96.62 | 0.25 |
| 542.00 | 6301.039 | 79.809 | 1819.947 | -1824.8 | 90.9 | 6580.3 | -10.60 | -0.04 | 11.39 | 0.620 | 82.177 | 14.07 | -96.93 | 0.25 |
| 544.00 | 6297.369 | 79.991 | 1833.130 | -1846.1 | 90.8 | 6603.2 | -10.66 | -0.03 | 11.45 | 0.619 | 82.248 | 14.15 | -97.16 | 0.29 |
| 546.00 | 6293.655 | 80.172 | 1846.360 | -1867.5 | 90.7 | 6626.1 | -10.73 | -0.03 | 11.50 | 0.619 | 82.319 | 14.23 | -97.43 | 0.28 |
| 548.00 | 6289.898 | 80.354 | 1859.635 | -1889.0 | 90.4 | 6649.2 | -10.80 | -0.15 | 11.56 | 0.620 | 82.389 | 14.32 | -97.69 | -0.20 |
| 548.22 | 6289.483 | 80.374 | 1861.098 | -1891.5 | 90.4 | 6651.8 | -10.81 | -0.19 | 11.56 | 0.619 | 82.397 | 14.32 | -97.73 | -0.36 |
| 549.00 | 6288.006 | 80.444 | 1866.285 | -1898.7 | 90.5 | 6652.6 | -8.86 | -0.00 | -2.43 | 0.611 | 82.427 | 0.23 | – | – |
| 550.00 | 6286.106 | 80.535 | 1872.934 | -1907.6 | 90.4 | 6650.2 | -8.86 | -0.06 | -2.42 | 0.595 | 82.464 | 0.23 | – | – |
| 552.00 | 6282.267 | 80.715 | 1886.235 | -1925.3 | 90.2 | 6645.3 | -8.87 | -0.09 | -2.40 | 0.564 | 82.538 | 0.27 | – | – |
| 554.00 | 6278.400 | 80.896 | 1899.525 | -1943.4 | 90.0 | 6642.6 | -9.34 | -0.12 | 0.60 | 0.535 | 82.612 | 3.32 | -98.19 | -0.32 |
| 556.00 | 6274.493 | 81.075 | 1912.815 | -1962.5 | 89.8 | 6646.3 | -9.55 | -0.10 | 2.31 | 0.513 | 82.686 | 5.06 | -97.82 | 0.02 |
| 558.00 | 6270.549 | 81.255 | 1926.111 | -1981.6 | 89.6 | 6651.3 | -9.50 | -0.10 | 2.59 | 0.494 | 82.759 | 5.35 | -96.92 | 0.02 |
| 560.00 | 6266.566 | 81.434 | 1939.420 | -2000.5 | 89.3 | 6656.6 | -9.40 | -0.14 | 2.68 | 0.479 | 82.832 | 5.45 | -95.81 | -0.40 |
| 570.00 | 6246.092 | 82.319 | 2006.122 | -2094.2 | 87.7 | 6683.9 | -9.42 | -0.13 | 2.73 | 0.418 | 83.197 | 5.60 | -96.18 | -0.27 |
| 580.00 | 6224.676 | 83.190 | 2073.097 | -2189.3 | 86.7 | 6711.0 | -9.60 | -0.08 | 2.67 | 0.361 | 83.571 | 5.66 | -98.28 | 0.25 |
| 590.00 | 6202.300 | 84.053 | 2140.340 | -2286.1 | 85.9 | 6737.5 | -9.75 | -0.06 | 2.64 | 0.305 | 83.952 | 5.75 | -99.99 | 0.46 |
| 600.00 | 6178.949 | 84.909 | 2207.846 | -2384.4 | 85.3 | 6763.6 | -9.89 | -0.06 | 2.57 | 0.252 | 84.339 | 5.81 | -101.65 | 0.46 |
| 610.00 | 6154.607 | 85.759 | 2275.610 | -2484.1 | 84.7 | 6789.1 | -10.02 | -0.05 | 2.53 | 0.203 | 84.730 | 5.90 | -103.11 | 0.57 |
| 620.00 | 6129.262 | 86.603 | 2343.627 | -2585.2 | 84.1 | 6814.3 | -10.16 | -0.06 | 2.49 | 0.158 | 85.126 | 5.99 | -104.64 | 0.47 |
| 630.00 | 6102.899 | 87.442 | 2411.894 | -2687.6 | 83.6 | 6838.9 | -10.30 | -0.05 | 2.43 | 0.119 | 85.527 | 6.07 | -106.18 | 0.57 |
| 640.00 | 6075.506 | 88.274 | 2480.403 | -2791.3 | 82.9 | 6862.9 | -10.42 | -0.06 | 2.36 | 0.084 | 85.931 | 6.15 | -107.53 | 0.48 |
| 650.00 | 6047.069 | 89.099 | 2549.150 | -2896.2 | 82.1 | 6886.3 | -10.55 | -0.07 | 2.32 | 0.056 | 86.339 | 6.25 | -108.87 | 0.39 |
| 660.00 | 6017.577 | 89.917 | 2618.129 | -3002.5 | 81.4 | 6909.3 | -10.69 | -0.07 | 2.26 | 0.034 | 86.751 | 6.35 | -110.31 | 0.40 |
| 670.00 | 5987.015 | 90.727 | 2687.334 | -3110.2 | 80.6 | 6931.6 | -10.92 | -0.07 | 2.15 | 0.016 | 87.168 | 6.44 | -112.63 | 0.40 |
| 678.00 | 5961.781 | 91.369 | 2742.855 | -3198.3 | 79.9 | 6948.6 | -10.98 | -0.08 | 2.12 | -0.001 | 87.504 | 6.52 | -113.24 | 0.32 |
| 680.00 | 5955.362 | 91.528 | 2756.757 | -3220.3 | 79.7 | 6952.9 | -10.99 | -0.07 | 2.12 | -0.004 | 87.588 | 6.54 | -113.33 | 0.40 |
| 682.00 | 5948.900 | 91.688 | 2770.667 | -3242.3 | 79.6 | 6957.1 | -10.98 | -0.07 | 2.12 | -0.006 | 87.673 | 6.56 | -113.26 | 0.41 |
| 684.00 | 5942.393 | 91.847 | 2784.585 (VERIFIER: was 2784.595, §3.3) | -3264.3 | 79.4 | 6961.4 | -10.98 | -0.08 | 2.12 | -0.007 | 87.758 | 6.58 | -113.26 | 0.32 |
| 686.00 | 5935.843 | 92.005 | 2798.512 | -3286.2 | 79.3 | 6965.6 | -10.97 | -0.08 | 2.12 | -0.007 | 87.844 | 6.60 | -113.19 | 0.32 |
| 688.00 | 5929.248 | 92.164 | 2812.448 | -3308.2 | 79.1 | 6969.9 | -10.96 | -0.08 | 2.12 | -0.006 | 87.929 | 6.62 | -113.12 | 0.32 |
| 690.00 | 5922.610 | 92.322 | 2826.392 | -3330.2 | 78.9 | 6974.1 | -10.96 | -0.08 | 2.12 | -0.005 | 88.014 | 6.64 | -113.12 | 0.32 |
| 692.00 | 5915.928 | 92.479 | 2840.344 | -3352.1 | 78.7 | 6978.4 | -10.95 | -0.08 | 2.12 | -0.003 | 88.099 | 6.66 | -113.05 | 0.32 |
| 694.00 | 5909.202 | 92.637 | 2854.305 | -3374.0 | 78.6 | 6982.6 | -10.95 | -0.08 | 2.12 | 0.000 | 88.185 | 6.68 | -113.06 | 0.32 |
| 696.00 | 5902.432 | 92.794 | 2868.275 | -3396.0 | 78.4 | 6986.8 | -10.95 | -0.09 | 2.12 | 0.003 | 88.271 | 6.70 | -113.07 | 0.24 |
| 698.00 | 5895.618 | 92.950 | 2882.253 | -3417.9 | 78.2 | 6991.1 | -10.95 | -0.09 | 2.12 | 0.008 | 88.357 | 6.72 | -113.08 | 0.24 |
| 699.33 | 5891.062 | 93.054 | 2891.553 | -3432.5 | 78.1 | 6993.9 | -10.94 | -0.09 | 2.12 | 0.011 | 88.414 | 6.73 | -113.01 | 0.24 |
| 700.00 | 5888.761 | 93.106 | 2896.238 | -3438.6 | 78.0 | 6992.8 | -8.31 | -0.11 | -4.07 | 0.012 | 88.443 | 0.02 | – | – |
| 702.00 | 5881.867 | 93.262 | 2910.215 | -3455.2 | 77.7 | 6984.6 | -8.28 | -0.11 | -4.09 | 0.012 | 88.529 | 0.02 | – | – |
| 704.00 | 5874.940 | 93.417 | 2924.176 | -3471.8 | 77.5 | 6976.4 | -8.27 | -0.11 | -4.12 | 0.012 | 88.616 | 0.02 | – | – |
| 706.00 | 5867.979 | 93.572 | 2938.121 | -3488.3 | 77.3 | 6968.2 | -8.26 | -0.11 | -4.14 | 0.013 | 88.703 | 0.02 | – | – |
| 708.00 | 5860.986 | 93.726 | 2952.049 | -3504.8 | 77.0 | 6959.9 | -8.25 | -0.11 | -4.17 | 0.013 | 88.790 | 0.02 | – | – |
| 709.33 | 5856.252 | 93.832 | 2961.276 | -3516.0 | 76.9 | 6954.4 | -8.24 | -0.11 | -4.18 | 0.012 | 88.848 | 0.02 | – | – |

## 4. Event tables (all read from the page images; H unless noted)

### 4.1 Table 3-I: Times of significant events (p. 3-22 / PDF 48). Range time in s.

| Event | Actual | Nominal | Act − Nom |
|---|---|---|---|
| Guidance reference release | −16.968 | −16.987 | 0.019 |
| First motion | 0.3 | 0.3 | 0.0 |
| Start of time base 1 | 0.6 | 0.7 | −0.1 |
| Mach 1 | 66.3 | 65.6 | 0.7 |
| Maximum dynamic pressure | 83.0 | 81.3 | 1.7 |
| S-IC center engine cutoff | 135.20 | 135.26 | −0.06 |
| S-IC outboard engine cutoff | 161.63 | 161.08 | 0.55 |
| S-IC/S-II separation command | 162.3 | 161.8 | 0.5 |
| S-II center engine cutoff | 460.62 | 460.08 | 0.54 |
| S-II outboard engine cutoff | 548.22 | 551.65 | −3.43 |
| S-II/S-IVB separation command | 549.0 | 552.4 | −3.4 |
| S-IVB 1st guidance cutoff | 699.33 | 699.49 | −0.16 |
| Parking orbit insertion | 709.33 | 709.49 | −0.16 |
| Begin S-IVB restart preparations | 9,278.2 | 9,277.3 | 0.9 |
| S-IVB engine reignition (STDV open) | 9,856.2 | 9,855.5 | 0.7 |
| S-IVB 2nd guidance cutoff | 10,203.03 | 10,204.06 | −1.03 |
| Translunar injection | 10,213.03 | 10,214.06 | −1.03 |
| CSM separation | 11,723 | 11,704 | 19 |
| Begin slingshot maneuver | 17,467.7 | 17,404.4 | 63.3 |

The S-II EMR shift and IGM-phase times are not in Table 3-I. They are in the FER.

### 4.2 Table 3-II: Significant trajectory parameters (p. 3-23 / PDF 49)

| Event | Parameter | Value |
|---|---|---|
| First motion | range time; total inertial acceleration | 0.3 s; 10.47 m/s² (1.07 g) |
| Mach 1 | range time; altitude | 66.3 s; 7.8 km |
| Max dynamic pressure | range time; q; altitude | 83.0 s; 3.52 N/cm² (735.2 lbf/ft²); 13.6 km |
| Max total inertial acceleration, S-IC | time; value | 161.71 s; 38.61 m/s² (3.94 g) |
| Max total inertial acceleration, S-II | time; value | 460.70 s; 17.84 m/s² (1.82 g) |
| Max total inertial acceleration, S-IVB 1st burn | time; value | 699.41 s; 6.73 m/s² (0.69 g) |
| Max total inertial acceleration, S-IVB 2nd burn | time; value | 10,203.11 s; 14.22 m/s² (1.45 g) |
| Max Earth-fixed velocity, S-IC | time; value | 162.30 s; 2,402.7 m/s |
| Max Earth-fixed velocity, S-II | time; value | 549.00 s; 6,515.7 m/s |
| Max Earth-fixed velocity, S-IVB 1st burn | time; value | 709.33 s; 7,389.5 m/s |
| Max Earth-fixed velocity, S-IVB 2nd burn | time; value | 10,203.50 s; 10,433.4 m/s |

### 4.3 Table 3-III: Engine cutoff conditions (p. 3-24 / PDF 50, landscape)

Columns: S-IC CECO, S-IC OECO, S-II CECO, S-II OECO, S-IVB 1st guidance cutoff, S-IVB 2nd guidance cutoff.
Space-fixed velocity, flight-path angle and heading are as defined in §2.2 and §2.4.

| Parameter | S-IC CECO | S-IC OECO | S-II CECO | S-II OECO | S-IVB 1st GCO | S-IVB 2nd GCO |
|---|---|---|---|---|---|---|
| Range time, s | 135.20 | 161.63 | 460.62 | 548.22 | 699.33 | 10,203.03 |
| Altitude, km | 44.0 | 66.1 | 180.2 | 187.3 | 191.1 | 320.9 |
| Surface range, km | 46.4 | 93.6 | 1,114.3 | 1,618.4 | 2,633.5 | — |
| Space-fixed velocity, m/s | 1,979.0 | 2,764.1 | 5,707.5 | 6,916.1 | 7,791.2 | 10,841.2 |
| Flight-path angle, deg | 22.957 | 19.114 | 0.897 | 0.619 | 0.011 | 6.914 |
| Heading angle, deg | 76.315 | 75.439 | 79.646 | 82.396 | 88.414 | 59.934 |
| Cross range, km | 0.2 | 0.5 | 15.0 | 27.4 | 60.9 | — |
| Cross-range velocity, m/s | 5.4 | 12.6 | 111.9 | 174.1 | 274.3 | — |
| Eccentricity | — | — | — | — | — | 0.97548 |
| C3, m²/s² | — | — | — | — | — | −1,480,682 |
| Inclination, deg | — | — | — | — | — | 31.386 |
| Descending node, deg | — | — | — | — | — | 121.849 |

Footnote: C3 = V² − 2μ/R ("twice the specific energy").
Cross range and cross-range velocity are not defined in App. A. Recomputing them from B-II shows they are the **PACSS 10 (Earth-fixed launch-site) Y components**: YE (position from the pad's ellipsoid point) and DYE (Earth-fixed velocity) (`igm/scripts/pft_crossrange.py`; inferred, H). The recomputed values:

| Event | YE (km) | DYE (m/s) |
|---|---|---|
| S-IC OECO | 0.45 | 12.6 |
| S-IC/S-II separation | 0.46 | 12.8 |
| S-II CECO | 15.01 | 111.9 |
| S-II OECO | 27.41 | 174.2 |
| S-II/S-IVB separation | 27.54 | 174.8 |
| S-IVB cutoff | 60.93 | 274.3 |

This is Earth-fixed cross range. Inertially (PACSS 13), YS goes from 17.087 km at GRR to 93.054 km at 699.33 s, mostly from the 125.9 m/s Earth-rotation component that DYS had at GRR.

### 4.4 Table 3-IV: Stage separation conditions (p. 3-25 / PDF 51)

| Parameter | S-IC/S-II separation command | S-II/S-IVB separation command |
|---|---|---|
| Range time, s | 162.3 | 549.0 |
| Altitude, km | 66.7 | 187.4 |
| Surface range, km | 95.1 | 1,623.4 |
| Space-fixed velocity, m/s | 2,773.9 | 6,918.8 |
| Flight-path angle, deg | 19.020 | 0.611 |
| Heading angle, deg | 75.436 | 82.426 |
| Cross range, km | 0.5 | 27.5 |
| Cross-range velocity, m/s | 12.8 | 174.7 |
| Geodetic latitude, deg N | 28.865 | 31.883 |
| Longitude, deg E | −79.676 | −64.147 |

### 4.5 Table 3-V: Targeting parameters (p. 3-26 / PDF 52, landscape)

| Parameter | Actual | Nominal | Act − Nom |
|---|---|---|---|
| **S-IVB 1st guidance cutoff:** range time, s | 699.33 | 699.49 | −0.16 |
| Altitude, km | 191.1 | 191.3 | −0.2 |
| Space-fixed velocity, m/s | 7,791.2 | 7,791.4 | −0.2 |
| Flight-path angle, deg | 0.011 | −0.002 | 0.013 |
| **Translunar injection:** range time, s | 10,213.03 | 10,214.06 | −1.03 |
| Eccentricity | 0.97696 | 0.97667 | 0.00029 |
| C3, m²/s² | −1,391,607 | −1,408,484 | 16,877 |
| Inclination, deg | 31.383 | 31.379 | 0.004 |
| Descending node, deg | 121.847 | 121.866 | −0.019 |

The nominal values come from the operational trajectory (Ref. 3: MSFC MFT-1-69, "AS-506 G Mission Launch Vehicle Operational Trajectory", 14 July 1969).

## 5. Parking-orbit insertion conditions and orbital elements

### 5.1 Table 4-III: Parking orbit insertion conditions (p. 4-8 / PDF 62; H)

| Parameter | Value | Recomputed from my B-II 709.33 s state (inferred) |
|---|---|---|
| Range time | 709.33 s | — |
| Altitude | 191.1 km (103.2 n mi) | B-III: 191,082 m |
| Space-fixed velocity | 7,793.1 m/s (25,567.9 ft/s) | 7,793.06 |
| Flight-path angle | 0.012° | 0.012 (geocentric) |
| Heading angle | 88.848° | 88.848 |
| Inclination | 32.521° | **32.521** |
| Descending node | 123.088° | **123.088**: angle in the equatorial plane from the **launch-site meridian at GRR** (inertially fixed at GRR), measured eastward to the descending node. Measured instead from Greenwich, the node is 42.484° in the GRR-fixed frame or 39.449° Earth-fixed at 709.33 s. |
| Eccentricity | 0.00021 | 0.00021 |
| Apogee* | 186.0 km (100.4 n mi) | 186.0 |
| Perigee* | 183.2 km (98.9 n mi) | 183.2 |
| Period | 88.18 min | 88.18 |
| Geodetic latitude | 32.672° N | — (B-III gives geocentric latitude 32.5027°) |
| Longitude | −52.694° E | B-III: −52.6941 |

\* Footnote: "Based on a spherical earth of radius 6,378.165 km (3,443.934 n mi)".

**Recomputation details** (`igm/scripts/pft_elements.py`; inferred):
- μ = 3.986032e14 m³/s². This value reproduces e, apogee, perigee and period exactly (a = 6,562.773 km).
- Insertion state in PACSS 13 (B-II, PDF 115, H): r = (5856.252, 93.832, 2961.276) km; v = (−3516.0, 76.9, 6954.4) m/s; |r| = 6,563.052 km.
- The same calculation at S-IVB cutoff (699.33 s, before tail-off) gives i = 32.521°, node 123.089°, e = 0.00054, apogee 185.2 km, perigee 178.0 km.

Other context:
- Sec. 4.1 (p. 4-1): insertion space-fixed velocity "equal to nominal"; flight-path angle 0.013° above nominal; eccentricity 0.00001 below nominal; apogee and perigee 0.5 km and 0.6 km below nominal.
- So the nominal insertion values (inferred from those differences) are: FPA −0.001°, e = 0.00022, apogee 186.5 km, perigee 183.8 km, V = 7,793.1 m/s.
- The insertion vector is the OCP fit to the C-band tracking of Bermuda (2 radars) at insertion, Carnarvon passes 1 and 2, and Patrick pass 2 (Sec. 4.3.1, p. 4-2).

### 5.2 Translunar injection (for later; Table 4-IV, PDF 63, not re-read here)

Table 3-V gives the TLI targeting parameters (§4.5). Table 4-IV gives the full TLI state; it was not digitised in this task.

## 6. What could not be found in the PFT, and where to look

- **Commanded or actual pitch and yaw attitude (chi), and attitude errors.** Not in the PFT. Use the FER (AS-506 Flight Evaluation Report): its guidance and control sections and the attitude and IGM-steering figures.
  - The derived thrust-direction angles in the CSV are the closest PFT-based proxy (L–M, inferred).
- **Masses, thrust, mass flow, tau, T_go, IGM phase times (start, EMR-shift handling, chi-tilde/terminal freeze).** Not in the PFT; use the FER and the GE.
  - The S-II EMR shift falls between 498 and 500 s from the B-II accelerations (inferred).
- **Cross-range time history.** The PFT only plots it (Fig. 3-4, PDF 36) and tabulates it at events. The CSV now carries it, recomputed from B-II as PACSS 10 YE and DYE (inferred, H). Table B-I (PDF 92–103) prints YE directly; it was not digitised.
- **Telemetered guidance (platform) velocities in PACSS 12.** Used in the reconstruction but not tabulated.

## Verifier notes

Independent check of this file and `igm/pft-trajectory.csv` against the PFT page images (Boeing D5-15560-6, `dl_docs/pft506.pdf`).
- The verifier rendered every page itself at 200–600 dpi into `igm/img/pftver/` and did not reuse the extractor's images.
- Corrections in the body and in the CSV `note` column are marked **VERIFIER:**.
- The pre-verifier versions are kept as `igm/pft-trajectory.csv.pre-verifier` and `igm/pft-trajectory.md.pre-verifier`.
- Scripts are in `igm/scripts/`: `pftver_check.py`, `pftver_dyn.py`, `pftver_chi2s.py`, `pftver_framediff.py`, `pftver_rdot.py`, `pftver_c2.py`, `pftver_patch_csv.py`, `pftver_crop.py` and `pftver_zoom.py`. All are pure computation, run with `python3 -I`, and read only the CSV and the numbers typed in from the images.

### V.1 What was checked against the page images

**Table B-II.** 82 of the 92 CSV rows were compared cell by cell (all 9 values per row):
- PDF 108: 161.63–172 s, 8 rows.
- PDF 109: 180–240 s, 7 rows.
- PDF 110: 290–320 s, 4 rows.
- PDF 111: 370–410 s, 5 rows.
- PDF 112: 440–510 s, 14 rows, including the 460.62 s event.
- PDF 113: 520–580 s, 17 rows, including the 548.22 and 549.0 s events.
- PDF 114: 610–670 s, 7 rows.
- PDF 115: all 20 rows from 678 to 709.33 s.

Every cell agrees except 684 s ZS (V.2). The pad row at GRR (PDF 104) is also correct: (6373.329, 17.087, −5.533) km; (0.0, 125.9, 388.8) m/s; (−0.02, −0.01, 0.00) m/s².

**Table B-III.** 49 rows were compared cell by cell (all 11 values per row):
- PDF 120: 161.63–172 s.
- PDF 122: 290–320 s.
- PDF 124: 460–510 s.
- PDF 126: 610–670 s.
- PDF 127: 678–709.33 s.

Every cell agrees. Column order (TIME, GC DIST, LONG, GC LAT, VEL-AZ, VEL-EL, EF VEL, HEAD, FLT-PATH, SF VEL, RANGE, ALTITUDE) and units were confirmed from the header (PDF 120).
- The pages are skewed, so on PDF 124 and 126 the right-hand columns (SF VEL, RANGE, ALTITUDE) sit about half a line above their row. The CSV pairs them correctly; this was counted row by row.

**English-unit tables, read as an independent second printing.**
- Table C-II (PDF 179): the 18 CSV rows from 678 to 709.33 s, all six position and velocity values per row (`pftver_c2.py`).
  - Converted from n mi and ft/s, they match the CSV's B-II values to ≤ 1.1 m and ≤ 0.06 m/s, which is the rounding of the two printings (0.001 n mi = 1.85 m).
  - This is a second, independent check of the cutoff and insertion states, including the corrected 684 s ZS.
- Table C-III (PDF 190): 626–666 s LONG and GC LAT.

**Event, insertion and orbit values (H).** Every value of the following was re-read and agrees with §4 and §5:
- Table 3-I (PDF 48), Table 3-II (PDF 49), Table 3-III (PDF 50), Table 3-IV (PDF 51) and Table 3-V (PDF 52).
- Table 4-III (PDF 62), all 14 parameters and the footnote "spherical earth of radius 6,378.165 km".
- Sec. 4.1 (PDF 55): the insertion differences from nominal (FPA +0.013°, e −0.00001, apogee −0.5 km, perigee −0.6 km).
- Sec. 5.1.3, 5.1.4 and 5.2 (PDF 68–69): 1.5/2.8/0.7 m/s; 70 m/0.3, 170 m/0.8 and 130 m/1.7 m/s; 60 m/0.3, 275 m/0.1 and 80 m/0.2 m/s; ±60/350/500 m and ±0.4/0.7/1.0 m/s.
- Sec. 3.3.1 (PDF 31): "The ascent phase was constrained to the insertion vector obtained from the orbital analysis of Section 4."

**Frames and columns.**
- Sec. 2 (PDF 25): pad 28.608422° N, 80.604133° W; 59.4 m; azimuths 90.0 / 72.058 / 72.058°; Fischer 1960.
- App. A (PDF 87–88): PACSS 10, PACSS 13 and PACSS 1 definitions as quoted in §2.2 (H).
- One document slip, not a transcription error: Sec. 2 lists "earth-fixed launch site, launch vehicle navigation, and geographic polar … PACSS10, PACSS1, and PACSS13, respectively". Read literally, that maps navigation to PACSS 1. App. A, the table titles and the recomputation all show that navigation is **PACSS 13** and geographic polar is **PACSS 1**, as this file says.

### V.2 Corrections made

1. **684 s, B-II ZS: 2784.595 → 2784.585 km (H).** This was a misread of a damaged "8" glyph, not a PFT print error.
   - Table C-II prints 1,503.556 n mi, which is 2,784.586 km.
   - The row now fits B-III and the kinematics to 0.2 m. The derived columns are unchanged.
   - Changed in the CSV (grade M → H), in §0, §3.1, §3.2, §3.3 and in the §3.6 table.
2. **660 s, B-III LONG: grade M → H.** C-III prints −56.4083 cleanly.
3. **460.62 s event row (inferred, M).** The ~100 m "jump" is a ~0.019 s time-tag offset: position and velocity both match the 460.6 s state, not the 460.62 s one (§3.3).
4. **709.33 s insertion row.** The discontinuity is −70 m radial, +6 m along-track and −5 m cross-track (§3.3). The "OCP vector" reading is kept, as inferred (M).
5. **IGM initiation timing (inferred, M).** From the 2-s rows, the thrust direction starts to change between 204 and 206 s, not "between 200 and 210 s". It pitches up by about 8° by 214 s. This matches FER IGM phase 1 at 204.07 s (§3.5).
6. **S-IVB attitude plateau (inferred, M).** The about 2.6° nose-down step at 666–672 s is FER **terminal guidance (665.15 s)**. The −113° plateau from 672 s is terminal-guidance steering. The FER chi freeze starts only at 691.64 s, so the original "terminal freeze from 678 s" was a misattribution (§3.5; CSV notes at 670 and 692 s).
7. **χZ range in the S-IVB burn.** It is +0.24° to +0.57° from 580 s on, not for the whole burn; it is −0.40° to +0.02° at 554–570 s (§3.5).
8. **Tail-off increment.** The tail-off adds about 1.7 m/s (7,791.2 → 7,792.9 m/s by 700 s). The other 0.2 m/s up to 7,793.1 comes with the 709.33 s row discontinuity (§3.5).
9. **Frame caveat for use in the repo (H, geometry).** PACSS 13 X is the geodetic normal. The repo's space-fixed X is the geocentric radial of a spherical-Earth pad, 0.1615° away.
   - Compare the PFT and the sim in ICRF, or rotate first. Otherwise the components differ by up to about 18 km at orbital radius.
   - The rotation also shifts chiY_thr by −0.05° and chiZ_thr by up to ±0.07° (§2.2).
10. **§3.4 wording.** The PFT does not call its uncertainties 1-σ. They are "engineering judgment" estimates.

### V.3 Independent consistency checks (all pass after correction 1)

- **B-III recomputed from the CSV's B-II columns** (`pftver_check.py`). This uses its own geometry: Bowring geodetic height and matrix frame construction; Y = cos A·E − sin A·N agrees with Z × X to 1e-16. Worst residuals over all 92 rows:

| Quantity | Worst residual |
|---|---|
| GC DIST | 0.81 m |
| LONG / GC LAT | 0.00005° |
| ALTITUDE | 1.68 m |
| SF VEL | 0.089 m/s |
| EF VEL | 0.080 m/s |
| FLT-PATH / HEAD (printed to 0.01°) | 0.005° |
| VEL-AZ / VEL-EL | 0.006° |
| fpa_calc / head_calc | 0.0005° |
| a_nongrav, chiY/chiZ_thr, YE | at rounding (0.005) |
| DYE | 0.05 m/s |

  The frame and column definitions of §2.2–2.5 hold, including the geocentric horizontal for FLT-PATH, HEAD, VEL-AZ and VEL-EL.
- **Radial rate** (`pftver_rdot.py`). ΔGC DIST agrees with the trapezoid integral of SF VEL·sin(FPA) to ≤ 3 m per interval.
  - The exceptions are 4–7 m truncation errors over 10-s steps where the FPA rate changes (200–220, 470–480 and 490–500 s), and the 709.33 s insertion row (−69 m).
- **Energy and power** (`pftver_dyn.py`). The specific energy v²/2 + U_J2 rises monotonically through the burns.
  - Its rate matches the non-gravitational power a_ng·v to ≤ 0.5 % on every steady-burn interval, which checks the B-II accelerations against the positions and velocities.
  - In the coast from 700 to 708 s it is constant to 4×10⁻⁴ MJ/kg.
- **Hermite kinematics.** Position residuals are ≤ 1.2 m on all steady intervals. Velocity residuals above 0.5 m/s occur only at thrust or attitude transients. Besides those listed in §3.2 item 2, they include:
  - 210–220 s (0.95 m/s);
  - 470–480 s (1.25 m/s, the post-CECO pitch excursion);
  - 500–510 s (1.2 m/s);
  - 549–556 s (S-IVB ullage and start, position residuals up to 6 m).
- **Orbital elements** at 709.33 s: i = 32.521°, node 123.088° from the launch meridian at GRR (42.484° from Greenwich in the GRR-fixed frame, 39.449° Earth-fixed at 709.33 s), a = 6,562.773 km, e = 0.00021, apogee/perigee 185.99/183.23 km, P = 88.184 min. At 699.33 s: e = 0.00054, apogee/perigee 185.15/178.00 km. These match §5.1 and Table 4-III.
- **Repo chi convention.** `SaturnIU`: `command = frame * R_Y(chi.y) * R_Z(chi.z) * R_X(chi.x)` with `frame = Mat3(columns: x, z.cross(x), z)`. That gives nose = (cos χZ cos χY, sin χZ, −cos χZ sin χY) and the inversion used for chiY/chiZ_thrust, as stated in §3.1 (H).

### V.4 Cautions for later digitisation (B-IV, B-V…B-VII for TLI)

- **Damaged 8s.** The line printer often drops the lower-left stroke of an "8", so it reads as "9" (sometimes "3" or "R"). Instances seen:
  - B-II 684 s ZS (corrected) and 696 s ZS ("2869.275" for 2868.275);
  - B-II 708 s DXS ("−3504.9" for −3504.8);
  - B-II 672 s YS ("90.988" for 90.888; not a CSV row);
  - B-III 708 s EF VEL ("7399.4" for 7389.4; the CSV is right);
  - C-II 698 s XS ("3193.379" for 3183.379).
  
  Resolve every 8/9 doubt against the matching C table or the kinematics.
- **The raw transcription is not corrected.** `igm/data/pft_b2.txt` still holds the 684 s ZS as first read (2784.595), and the extractor's `pft_build_csv.py` and `pft_check_*.py` read that file. Re-running `pft_build_csv.py` would overwrite the corrected CSV with the old value, so correct `pft_b2.txt` first, or re-apply `pftver_patch_csv.py`.
- **Not re-checked:** Figures 3-2…3-6 and 5-1 (PDF 34–38, 70), Table B-I/IV and the C tables beyond the rows named above. No figure values enter the CSV. The RANGE definition of §2.4 (Vincenty distance to the radial subvehicle point, a residual growing to 66 m) was not re-derived independently; it stays M.

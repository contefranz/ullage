# LC-39A datasheet (M1.6 LC)

Compiled on 2026-10-21 for M1.6's track LC (docs/m16/plan.md, "LC: the LC-39A set"). It covers the Mobile Launcher (ML) base on its pedestals; the Launch Umbilical Tower (LUT) with its nine swing arms and the hammerhead crane; the four hold-down arms and three tail service masts on the deck; and the pad's hardstand, fill, ramp, flame trench and deflector, as Apollo 8 (AS-503, 21 Dec 1968) and Apollo 11 (AS-506, 16 Jul 1969) stood on them. `Sources/OrbitScene/Site/LC39A.swift` builds the set from these rows, and `Tests/OrbitSceneTests/LC39ATests.swift` checks it (§10).

## Conventions

- **Site frame.** `RenderScene.Site`'s axes: x forward, towards the tower (north); y left (west); z up along the geodetic normal. The origin is on the vehicle's axis at the ML deck, tower level 0. Metres in the code; the sources' feet and inches first here, with SI where it helps (1 ft = 0.3048 m, 1 in = 0.0254 m).
- **Heights** are above the ML deck unless a row says otherwise. Tower "levels" are feet above the deck (A8PK: "the 320-foot level above the launcher base").
- **Vehicle azimuth θ** is the exterior datasheet's: from Position I towards Position II, I 0°, II 90°, III 180°, IV 270°. On the pad, Position I faces east and Position II north (§1).
- **Range time** is seconds from range zero (T−0). A negative time is before range zero.
- **Grades** are as in `docs/SaturnV-CSM-exterior-datasheet.md` (owner decision 10):
  - **H**: a primary document states the number, or dimensions it on a drawing, read on the page image, for the vehicle and pad in question.
  - **M**: a primary-source number that needed interpretation. That covers arithmetic on sourced values (*derived*), a value *scaled* off a drawing with a known reference, a schematic's placement, a design-stage drawing not re-checked against the as-built pad, a NASA history or web caption, or two sources a few per cent apart.
  - **L**: an *estimate*, always with how it was made, or a secondary source only.
- **How values were read.** Every number was read on the page image (`pdftoppm`, cropped and enlarged where small). The PDFs' text layers were used only to find pages. The documents stayed outside the repo, in the session's scratch folder.

## Sources

| key | document | copy read | bytes | sha256 |
|---|---|---|---|---|
| M503 | MSFC-MAN-503, *Saturn V Flight Manual SA-503* (1 Nov 1968), Section VIII "Ground Support Interface" (printed pp. 8-1 to 8-21, PDF pp. 183-207) | https://ntrs.nasa.gov/api/citations/19750063889/downloads/19750063889.pdf | 19,707,479 | `7465652b07306f45d2450f6a50bc52ee9c2a257522bbfc86c14bb9d1a006a967` |
| BALKE | H. A. Balke, *Mount Mechanisms for the Saturn V/Apollo Mobile Launcher at John F. Kennedy Space Center*, 10th Aerospace Mechanisms Symposium (1976), pp. 373-385 | https://ntrs.nasa.gov/api/citations/19760012109/downloads/19760012109.pdf | 580,238 | `f30c46c55481a7fc18206ddb3a3e1ba23866a02b338042517ebac8d6ce83a2ae` |
| HDA | J. D. Phillips and B. A. Tolson (KSC), *Holddown Arm Release Mechanism Used on Saturn Vehicles*, 9th Aerospace Mechanisms Symposium (1975), pp. 335-357 | https://ntrs.nasa.gov/api/citations/19760012107/downloads/19760012107.pdf | 779,825 | `4d1dc16a3073b7dea10ebea414c9aa81bafdbbb8b4e5e95c01ae227efcf6b033` |
| FER503 | MPR-SAT-FE-69-1, *Saturn V Launch Vehicle Flight Evaluation Report AS-503, Apollo 8 Mission* (20 Feb 1969): Table 2-2; §3.6 (printed pp. 3-8, 3-9); §11.3.1, Table 11-1, Figs. 11-1 and 11-3 | https://ntrs.nasa.gov/api/citations/19690015314/downloads/19690015314.pdf | 129,492,935 | `fe08ea2e1e623d2153fdf07207c70f2e3d9e09d1801d56f9f3c316fc152911a0` |
| FER506 | MPR-SAT-FE-69-9, *Saturn V Launch Vehicle Flight Evaluation Report AS-506, Apollo 11 Mission*: §3.6 (printed pp. 3-3, 3-4) | https://www.ibiblio.org/apollo/Documents/lvfea-AS506-Apollo11.pdf | 11,455,509 | `84b23ee1f3e8e76db20e4e6c1a5bc8b83cd9bc09950c43c43330bce753c3a9c7` |
| ERH | KSC SP-166-D, *Electrical Reference Handbook, Launch Equipment Branch Electrical Support Equipment LC-39*, Vol. I (10 Jan 1965, rev. 1 Nov 1965): §3-4 (printed p. 3-4), Fig. 3-1 (p. 3-5), Fig. 4-2 (p. 4-3) | https://ntrs.nasa.gov/api/citations/19660024575/downloads/19660024575.pdf | 17,182,230 | `79dff427a070a3eb0a56cea5ea492eaa0617fc8d6e5af6dd53110e6088447f2b` |
| TM509A | KSC TM-509A, *Apollo/Saturn V Launch Complex 39 Mobile Launcher Service Arms, Operations and Maintenance: Command Module Access Arm System, Environmental Chamber* (16 May 1969) | https://ntrs.nasa.gov/api/citations/19700007600/downloads/19700007600.pdf | 3,843,514 | `6528d26cc1baab70847f027f8361bcedb48eb8285794c21de4ac7e5f2586ac72` |
| TND4870 | J. J. Catherines, NASA TN D-4870, *Experimental Vibration Characteristics of a 1/40-Scale Dynamic Model of the Saturn V-Launch-Umbilical-Tower Configuration* (Langley, 1968): text p. 6, Fig. 2 (PDF p. 20) | https://ntrs.nasa.gov/api/citations/19690001444/downloads/19690001444.pdf | 13,815,909 | `d30c83ea6bd4c1e91e620ac39ec3dd72d408a8ad99c3fd9430f1d0a6eb783911` |
| A8PK | NASA Release 68-208, *Apollo 8 Press Kit* (6 Dec 1968), "KSC Launch Complex 39" (PDF pp. 79-83, printed -58- to -62-) | https://www.nasa.gov/wp-content/uploads/static/apollo50th/pdf/A08_PressKit.pdf | 6,162,826 | `fb5ba158821c989460f1a84c8efa85d459988529409585d78967f758b4462947` |
| A11PK | *Apollo 11 Press Kit*: countdown (PDF p. 23), "Mobile Launcher" (PDF pp. 168-169), "Flame Trench and Deflector", "Pad Areas" (PDF pp. 171-172) | https://www.nasa.gov/wp-content/uploads/static/apollo50th/pdf/A11_PressKit.pdf | 8,858,407 | `fcb1ae7a88e5251559dde0b7d51ec71f06795cf78f64491aa9594fdf9ca89334` |
| MOON | C. D. Benson and W. B. Faherty, *Moonport: A History of Apollo Launch Facilities and Operations*, NASA SP-4204 (1978): pp. 235-236, 279-288, 336, and the LC-39 summary, pp. 536-537 | https://www.nasa.gov/wp-content/uploads/2023/06/moonport.pdf | 148,266,123 | `6c43ffd261ad4922d35a9dadfdfc4e54cd0d2b2abde8f88a8aa23f3ccf16c0c2` |
| CAP65 | NASA photo caption, "Early Construction of Launch Pad 39A" (photo 2 Nov 1965) | https://www.nasa.gov/image-article/early-construction-of-launch-pad-39a | web page | — |

Read but not used for numbers: NTRS 19690001603 (the 1/40 model's analysis, a companion to TN D-4870); 19760012106 (a Centaur damper); 19700023588 (a service-arm position switch study).

**Not reached.** The Library of Congress's HAER documentation of LC-39 and the ML is blocked by the network allowlist (`www.loc.gov`: proxy 403). Both FERs refer their ground details to KSC's *Apollo/Saturn V Ground Systems Evaluation Report* for AS-503 (10 Feb 1969) and AS-506, but neither was found online. Those are where the L rows below could be raised.

---

## 1. Placement and frame

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Pad latitude, longitude | geodetic 28.6084° N, 80.6041° W, on WGS 84 | `VesselLibrary.lc39A` (AS506 datasheet §15: FER, GE504, SP-4029) | H | `placement()` takes the core's | The site never holds its own copy. |
| Tower side | the tower is north of the vehicle: M503 Fig. 8-7's plan marks "TOWER" with the north arrow, and Position II faces it | M503 Fig. 8-7, printed p. 8-9, PDF p. 190 (page image) | H | `towerAzimuth` 0 | FER503 §11.3.1 agrees: the ground wind "from the north" was "blowing away from the tower", and the liftoff camera "located due east of the mobile launcher" filmed the fin passing it. |
| Pad axis | "The longitudinal axis of the pad is oriented north-south, with the crawlerway and ramp approach from the south" | M503 p. 8-8, PDF p. 189 | H | trench and hardstand along x | MOON p. 288: "lay in a north-south direction". |
| Position I | east: the core stands the vehicle with Position I at the 90° pad azimuth, so Position II is north, facing the tower | `AS506.padAzimuth` 90° (AS506 datasheet §7.1, M); M503 Fig. 8-7 | H (II to the tower) / M (exact azimuth) | site x along the core's Position II | Test: within 1e-9 rad. |
| Hold-down post station | vehicle STA 113.31 rests on the arms' heads | M503 Fig. 8-7 detail "VEHICLE STA 113.31" | H | `holdDownPostStation` | |
| Head height | the arm's adjustable head 100.75 in above its base ("100.75 to base"), adjustable 1 in with shims | HDA Fig. 10, p. 354 | H | `holdDownHeadHeight` | The arms are bolted to the deck (M503 p. 8-8: "mounted on the ML deck"). |
| Deck station | STA 113.31 − 100.75 = STA 12.56 | *derived* | H | — | |
| Deck above the core's vehicle base | the core's base is STA −115.0 (the F-1 exit; the BCD's is −115.36): 127.56 in = 3.240 m | *derived* | H (with the core's datum) | `deckAboveVehicleBase` | |
| Site height | the core's pad elevation (26 m, the vehicle base above WGS 84) + 3.240 m = 29.24 m | *derived* | M (the core's 26 m is M) | `placement().height` | |
| Cross-check: deck above sea level | hardstand 48 ft + pedestals 22 ft + base 25 ft = 95 ft = 28.96 m | M503 p. 8-8; A8PK p. -60-; A11PK p. 172 | H | — | The core's chain gives 29.24 m, 0.28 m higher. The core's 26 m (the PFT's 59 m less 33 m to the centre of mass) therefore reads as a height above sea level. The core and the drawn Earth have no geoid, so sea level is the ellipsoid; the site follows the core. |
| Ground under the set | the drawn surface (the ellipsoid) is 29.24 m below the deck; grade (6 ft above sea level) is 2.11 m above it | *derived* | M | `ellipsoidHeight`; the fill and trench floor go 1 m below it | |

## 2. Mobile Launcher base

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Base | two-story steel box "25 feet high, 160 feet long, and 135 feet wide" | M503 p. 8-4 (PDF p. 185); A8PK p. -60-; A11PK | H | 7.62 m deep | MOON p. 536: 49 × 41 m, 7.6 m. |
| Outline | 48.87 m long overall, 0.406 m beyond the tower end's mount line; 41.15 m wide, 0.304 m beyond the side mount lines | BALKE Fig. 1, p. 378 | H | `baseNorth`, `baseSouth`, `baseHalfWidth` | 48.87 m = 160.3 ft. The far end is then 0.314 m beyond its mount line. |
| Girders | five main girders, nominally 25 ft deep: two outside girders 158 ft long between two 133 ft end girders, and an interior girder 60 ft from the tower end | BALKE p. 374 | H | not drawn separately | |
| Mount lines along the ML | 18.28 m from the tower end to the interior girder, 29.87 m on to the far end | BALKE Fig. 1 | H | `mountLinesX` (+33.49, +15.21, −14.66 m) | 48.15 m = 158 ft. |
| Mount lines across | 40.5 m (133 ft) | BALKE Fig. 1, p. 373 | H | `mountLineY` ±20.25 m | |
| Vehicle's axis | 6.09 + 27.4 = 33.49 m from the tower end's mount line | BALKE Fig. 1 (the engine chamber's centre line) | H | site origin | Puts the tower's centre (girder to girder) 24.35 m from the axis, against M503's "approximately 80 feet" (24.38 m). |
| Exhaust opening | 45 ft square; the vehicle "sits over" it | A8PK p. -60-; A11PK | H | `openingHalf` 6.858 m | MOON p. 536: 14 m. |
| Pedestals | six mount mechanisms, 6.7 m (22 ft) high, at each corner and where the interior girder meets the outside girders; 914 mm (36 in) tubular columns | BALKE pp. 373-375, Fig. 1; A8PK | H | six columns 0.914 m across | Their diagonal struts (457 mm) are not drawn. |
| Extensible columns | four, placed before fuelling to stiffen the ML against rebound; 6.55 m in from the side mount lines | BALKE p. 373, Fig. 1 | H (across) | `extensibleColumnY` ±13.7 m | Along the ML, 8.2 m either side of the axis, *scaled* off Fig. 1, which is not drawn to scale (L); diameter taken as the pedestals' (L). |
| Levels | level 0 the deck (four hold-down arms, three tail service masts, the tower); levels A and B inside | M503 p. 8-4 | H | — | |
| Hold-down arm ledges | the arms' bases reach 1.23 m over the opening's edge; a 1 m ledge carries each | *estimate* (L): the arms must stand on something there; not sourced | L | `baseShapes` | |

## 3. Launch Umbilical Tower

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Height | "an open steel structure 380 feet high" | M503 p. 8-6, PDF p. 187 | H | `towerTop` 115.82 m | TND4870 p. 6: 114 in above the platform at 1/40 (380 ft) and 130 in above the ground; its p. 4: "381 feet (116 meters)". |
| Plan | 40 ft square: centre 80 ft from the vehicle's axis, nearest column 60 ft | M503 p. 8-6 ("approximately") | H | `towerCentreX`, `towerHalf`; face at 18.288 m | TND4870 Fig. 2: 12 in at 1/40 "above its flared-out base". |
| With the crane | "extending 398 feet above the launch platform"; the whole ML "stands 445 feet high when resting on its pedestals" | A8PK p. -60-; A11PK | H | crane top 121.31 m | 22 + 25 + 398 = 445 ft. MOON p. 282: "the top of the 136-meter structure". |
| Legs | inboard legs on the interior girder, 60 ft from the end girder that carries the outboard legs | BALKE p. 374 | H | legs' feet at x 33.49 and 15.21 m | |
| Flare | the legs splay from the 40 ft body to 60 ft along the ML and about 117 ft across it at the deck, from about 80 ft up | TND4870 Fig. 2, *scaled* (12.95 px/in on a 250 dpi render; base 18.1 and 35.1 in at 1/40, flare top 22.7-25.5 in) | M (an early architectural drawing) | `legFootHalfAcross` 17.83 m, `flareTop` 24.38 m, 1.5 m legs (L) | M503 Fig. 8-8's photograph shows the flare beside the body. |
| Flare ties | at about 32 and 63 ft | TND4870 Fig. 2, *scaled* | M | `flareTies` | |
| Body below the flare top | the 40 ft body runs down to the deck, between the legs | M503 Fig. 8-8 photograph; ERH Fig. 3-1 | M | one box, deck to 380 ft | |
| Lattice | open steel lattice, 20 ft panels: the 1/40 model's horizontals every 5.99 in (19.97 ft) | TND4870 Fig. 2, *scaled* | M | drawn as a box with the `lc39a.lattice` material (relief, VM2/R2) | Plan: "prisms with lattice relief rather than individual beams". |
| Levels | 18 work and access platforms; elevators from level A to the 340 ft level | M503 p. 8-6 | H | — | |
| Colour | red oxide | *estimate* from 1968-69 colour photographs (L) | L | `latticeColor` | A stand-in until the material table has an entry. |

## 4. Swing arms

### 4.1 The arms

| arm | name | kind | level (ft) | vehicle there | radius reached | retract time | length (model) |
|---|---|---|---|---|---|---|---|
| 1 | S-IC intertank | preflight | 60 | STA 732.6, intertank (628.8-885.2) | 198 in | 8 s (spec 10.5 s to the safe angle, FER506) | 13.31 m |
| 2 | S-IC forward | preflight | 120 | STA 1452.6, forward skirt (1420.3-1541) | 198 in | 8 s | 13.31 m |
| 3 | S-II aft | preflight | 140 | STA 1692.6, S-IC/S-II interstage (1541-1760) | 198 in | — ("as required") | 13.31 m |
| 4 | S-II intermediate | in-flight | 160 | STA 1932.6, S-II | 198 in | 6.4 s max | 13.31 m |
| 5 | S-II forward | in-flight | 200 | STA 2412.6, S-II, 106 in below its top | 198 in | 7.4 s max | 13.31 m |
| 6 | S-IVB aft | in-flight | 220 | STA 2652.6, S-II/S-IVB interstage cone | 158.1 in (*derived*: 198 → 130 in over STA 2519-2746.5) | 7.7 s max | 14.48 m |
| 7 | S-IVB forward | in-flight | 260 | STA 3132.6, S-IVB forward skirt | 130 in | 8.4 s max | 15.17 m |
| 8 | Service module | in-flight | 300 | Xa 856, SM (838-993) | 77 in | 9.0 s max | 16.46 m |
| 9 | Command module access | preflight | 320 | the CM's side hatch, Xa 1043-1072 | 1.46 m at the hatch | extend 12 s from park | 17.09 m + 2.4 m room |

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Names, numbers, kinds, retract times | arms 1-9 from the bottom; preflight arms "retracted and locked against the umbilical tower prior to liftoff", in-flight arms retract at liftoff; retract times as tabled | M503 Fig. 8-8, printed p. 8-10, PDF p. 191; p. 8-8 | H | `swingArms` | |
| Levels | control distributors at levels 60, 120, 140, 160, 200, 220, 260 and 300 (§3-4) and 320 (Fig. 4-2) | ERH printed pp. 3-4, 4-3 | H (as printed); M (as the arms' heights: one distributor set per arm, taken at its arm) | `level`; the walkway's top at the level | With the deck at STA 12.56, every level falls on its arm's stage (table above). Arm 9: A8PK, A11PK "the 320-foot level above the launcher base" (H); TM509A: its portable control console "on launcher level 320" (H). |
| Arm 9's room | the environmental chamber (white room) at the arm's vehicle end, entered at the hatch; floor taken at the hatch sill, Xa 1046 = 315.8 ft above the deck, 1.28 m below level 320 | TM509A §1.2; exterior datasheet §9.2 (hatch, Xa 1043.4-1072); *derived* | M (sill) / L (room 2.4 m each way, *estimate* from TM509A Figs. 1-1, 1-2, not dimensioned) | `chamber` | |
| Hatch side | the CM's side hatch is on −Z_A, Position I (east) | exterior datasheet §9 (graded M there) | M | arm 9's room centred 2.66 m east of the axis, on the hatch | |
| Lengths | 13.7-18.3 m (45-60 ft); weights 15,900-23,600 kg | MOON p. 536 | M | from the tower face to the vehicle at each level (*derived*, L-M): the carrier's nearer corner touches the skin | The S-IC and S-II arms come out 13.31 m, 0.4 m under MOON's shortest; their hinges likely sit behind the face (L). Arm 9's truss is 17.09 m, with its room beyond. |
| Width | 2.90 m, *derived* (L-M): FER503 Table 11-1 gives 862.79 cm (339.68 in) of clearance from fin tip A to the swing arms. Fin tip A is 376.2 in out on the 45° diagonal (exterior datasheet §2.4), 6.757 m towards the tower. So the retracted arms' near face is 15.385 m from the axis, 2.90 m in front of the tower face: the width of an arm folded flat against it | FER503 Table 11-1, printed p. 11-4 | L-M | `armWidth` | MOON p. 283: "wide enough for a jeep to drive across". |
| Hinges | two per arm, each 1.2 m high and 2.1 m wide | MOON p. 336 | M | hinge at the tower face, at the arm's east edge | |
| Depth | 3.0 m at the root, 2.0 m at the tip | *estimate* (L): room for two 1.2 m hinges | L | `armDepth` | |
| Offset | the umbilical arms' centrelines 1.5 m east of the tower's, so that their carriers meet the vehicle between Positions I and II, near II, where its umbilical plates and doors are | exterior datasheet §2.6 (forward umbilical plate), §4 (S-II doors), §7 (IU doors); *estimate* (L) | L | `armOffset` | |
| Carrier | the umbilical carrier at the tip: 1.0 m long, 1.6 m square | *estimate* (L) | L | `carrier` | |
| Swing | retracted arms folded flat against the tower's face, swung 90° east about the hinge at their east edge | *estimate* (L), consistent with FER503 Table 11-1 (above) | L | `armRetractedAngle` 90° | Which way the arms swing is not sourced. A question for Franz, checked against the photographs (§12). |

### 4.2 Timeline

| event | Apollo 8 (AS-503) | Apollo 11 (AS-506) | source | grade | model |
|---|---|---|---|---|---|
| Range zero (T−0) | 1968-12-21 12:51:00 UTC (7:51:00 EST) | 1969-07-16 13:32:00 UTC | FER503 Table 2-2 and §2; core `apollo11RangeZero` | H | `Countdown.rangeZero` |
| Arm 9 to its 12° park position, "about three feet" from the spacecraft | about T−42 min | T−43 min | A8PK p. -61-; A11PK PDF pp. 23, 169 | H | 12° at 1°/s (below) |
| Arm 9 fully retracted | T−5 min | T−5 min | A8PK; A11PK | H | ends at T−5 min |
| Arm 9's rate | it extends from park in 12 s: 1°/s | 1°/s | M503 Fig. 8-8 | H (12 s) / L (taken for the retraction too: 78 s from 12° to 90°) | `accessArmRate` |
| Arm 3 | "retracted early in the count" | "retracted early in the count" | A8PK; A11PK | H (that it is early) | done by T−1 h (*estimate*, L; every scenario starts later) |
| Arm 1 command | T−30.0 s | T−30.0 s | *derived*: FER503 §3.6 (11.1 s to the safe angle, 2.69 s before arm 2's command at T−16.2 s: T−29.99 s); FER506 §3.6.2 (9.9 + 3.9 + 16.2 = 30.0 s); A8PK: "a third is released at T-30 seconds" | H | `sICIntertankCommand` |
| Arm 1 carrier withdrawal | 6.14 s ("normal ... about 4.2 seconds") | 5.06 s (0.06 s over the 5 s maximum) | FER503 §3.6; FER506 §3.6.2 | H | the arm swings after it |
| Arm 1 at its safe angle | 11.1 s after command | 9.9 s (spec 10.5 s) | FER503; FER506 | H | taken as fully retracted (L) |
| Arm 2 command | T−16.2 s | T−16.2 s | FER503, FER506 §3.6 ("SA No. 2 retract at -16.2 seconds") | H | `sICForwardCommand`. M503 plans T−20 s and A11PK says "about T-16.5"; the FERs are as flown. |
| Arm 2 swing | withdrawal 3 s, then the swing to 8 s | same | M503 Fig. 8-8 (8 s); withdrawal like arm 1's dry 3 s (FER506 §3.6.2), *estimate* | M (8 s) / L (3 s) | |
| Hold-down release | 0.27 s | 0.3 s | FER503 Table 2-2, §3.6; FER506 §3.6.1 | H | `holdDownRelease` |
| First motion | 0.33 s | 0.30 s | FER503 Table 2-2; core `apollo11FirstMotion` | H | `firstMotion` |
| In-flight arms (4-8) start | first motion + 0.16 s | first motion + 0.16 s | M503 p. 8-8: the primary liftoff switches at 3/4 in of rise; FER503 §3.6: "1-inch liftoff". About 1 m of rise in the first second (FER503 Fig. 11-1), so 2 m/s² and 1 in at 0.16 s (*derived*) | M | `liftoffSwitch` |
| In-flight arms' swing | carrier withdrawal and arm retraction start together on carrier ejection; done within 6.4-9.0 s | same | M503 p. 8-8, Fig. 8-8 ("max") | H (sequence) / M (the maxima taken as the times; the FERs: "within specifications") | |
| Hold-down links | collapse in 0.2 s from release | same | HDA p. 340: separators act in 0.13-0.18 s; *estimate* | L | `holdDownSwingTime` |
| Tail service masts | 2.62 s (TSM 1-2), 2.77 s (3-2), 2.54 s (3-4) from "umbilical plate separation" to "mast retract" | "TSM retractions were normal" (AS-503's times used) | FER503 §3.6; FER506 §3.6.1 | H (AS-503) / M (AS-506) | start at `liftoffSwitch` (M) |
| All of it | four arms retracted before liftoff, five at T−0 | | MOON p. 536; A8PK; A11PK | H | |

## 5. Hammerhead crane

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Hook | 376 ft above the deck, "traverse radius of 85 feet from the center of the tower" | A8PK p. -60-; A11PK | H | `craneReach` 25.91 m | M503 p. 8-6: 25 t to 50 ft, 10 t from 50 to 85 ft; the hook travels 468 ft; it turns 360° at 1 rev/min. |
| Top | 398 ft above the deck | A8PK; A11PK | H | `craneTop` 121.31 m | |
| Jib, counter-jib, turntable | jib 6 × 8 ft, counter-jib 25 ft, turntable 20 ft square up to the jib | *estimates* (L) from M503 Fig. 8-8's photograph and ERH Fig. 3-1 | L | `jibWidth`, `jibDepth`, `counterJib`, `turntableSide` | |
| Heading at launch | north, away from the vehicle | *estimate* (L). At liftoff fin A cleared "the top of the tower" by 11.0 m (FER503 §11.3.1, Fig. 11-3), so the jib was not over the vehicle's path; where it pointed is not sourced | L | `craneHeading` 0 | A question for Franz (§12). |

## 6. Hold-down arms

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Number and azimuths | four, 90° apart, at Positions I-IV | M503 p. 8-8, Fig. 8-7 | H | `holdDownAzimuths` | |
| Base | 9 ft 9 in (117 in) along the radius, 6 ft 4 in (76 in) across | HDA Fig. 10 | H | `holdDownBase` | A8PK: "about 6 by 9 feet at the base and 10 feet tall, weighing more than 20 tons". MOON p. 286: just under 2 m wide, not quite 3 m long, 3.35 m high, over 18 t. HDA p. 343: 20,412 kg. |
| Height | 10 ft 5 in (125 in) overall; the head's top 100.75 in | HDA Fig. 10 | H | `holdDownOverall` | |
| Head | 32 in across, cantilevered 23.75 in ahead of the base | HDA Fig. 10 | H | `holdDownHeadDiameter`, `holdDownCantilever` | |
| Head position | under the post on the lower thrust ring at the skin, 198 in from the axis | M503 p. 4-1 ("four holddown posts" on the thrust structure's lower ring); Fig. 8-7 draws the heads at the vehicle's outline | M (L for the exact radius) | `holdDownHeadRadius` | |
| Body | a sloping cast "pyramid": front face 94.75 in high, rising from an 8 in lip at the rear, 40 in behind the front | *scaled* off HDA Fig. 10 (L) | L | `holdDownBaseShapes` | |
| Upper link | its main pin "aft of and slightly above the plunger", 10 in behind the base's front and 104 in up; at release "the aft end of the upper link [rotates] through approximately 90 degrees", and a lanyard closes the protective hood | HDA pp. 336, 343, Figs. 11, 13 | H (90°) / L (pin, *scaled*; link 80 × 30 × 21 in, *estimate*) | `holdDownPin`, `holdDownReleaseAngle` | |
| Release | pneumatic separators; the arms release within 0.050 s of each other, the explosive backup at 0.180 s | M503 p. 8-8; HDA p. 340 | H | — | Controlled release: tapered pins drawn through dies over the first 6 in of rise (M503 p. 8-8). Not drawn. |

## 7. Tail service masts

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Number, names | three: TSM 1-2, 3-2 and 3-4, on level 0 | M503 p. 8-8, Fig. 8-7 | H | `tailMasts` | |
| Azimuths | TSM 1-2 13° from Position I towards II; TSM 3-2 at 168° and 3-4 at 192°, 12° either side of III | *scaled* off M503 Fig. 8-7 (plan, 300 dpi) | M | | The exterior datasheet §2.6 has the vehicle's plates "TSM 1-2 at Position I; TSM 3-2 and 3-4 either side of Position III" (H, as drawn). |
| Radius | the mast's tower centred 10.4 m from the axis | *scaled* off M503 Fig. 8-7 against the 45 ft opening (10.9 px/ft) | M | `tailMastRadius` | |
| Form | a counterbalanced lattice tower with a hood; the mast (umbilical boom) runs down to the S-IC's tail plate. At liftoff carrier withdrawal and the mast's rotation are simultaneous, and the carrier rotates into the hood | M503 p. 8-8, Fig. 8-7; MOON p. 287 ("swinging them up and away from the Saturn V") | H (form) | tower, hood, boom | |
| Size | tower 2.7 m square at the deck, 0.6 of that at its 8 m top, hood 1.4 m; boom pivot 9.5 m out, 8.4 m up; tail plate at 5.3 m out, 4.76 m up (STA 200 on the thrust structure, STA 116-345.7) | *estimates* (L) from M503 Fig. 8-7's drawing | L | `tailMastBase`, `tailMastTop`, `tailMastHood`, `tailMastPivot`, `tailPlate` | |
| Retraction | 140°, up and away into the hood | *estimate* (L) | L | `tailMastRetractAngle` | |

## 8. Pad

| item | value | source | grade | model | notes |
|---|---|---|---|---|---|
| Hardstand | top 48 ft above sea level, 42 ft above grade | M503 p. 8-8; A11PK p. 172; CAP65 | H | `hardstandHeight` −47 ft from the deck | |
| Hardstand size | "a 390-foot-by-325-foot reinforced concrete hardstand" | CAP65 | M (a NASA caption) | `hardstandHalfLength` 59.44 m, `hardstandHalfWidth` 49.53 m | Long side north-south (the pad's axis, M503: M). Centred on the vehicle (*estimate*, L): the ML (−15 to +34 m) and the mobile service structure's base on the south side (135 ft square, M503 p. 8-15) both fit. |
| Fill | sides slope 2:1 down to the ground; the halves slope to grade at the trench's ends | *estimate* (L) | L | `fillSlope` | MOON p. 236: the hardstand rests on two rows of cellular structure either side of the trench. |
| Site | an eight-sided polygon about 3,000 ft across | M503 p. 8-8; CAP65 | H | not drawn | The perimeter, ponds and facilities are outside the set. |
| Ramp | five per cent, from the south | A8PK p. -62-; MOON p. 288 ("ramp sloping 5°", an evident slip for 5 per cent) | H | `rampGrade` | |
| Ramp lanes | two 40 ft lanes either side of the trench | MOON p. 537 (the crawlerway: two 12 m lanes, a 15 m median; A8PK: a 131 ft roadway); their placement on the ramp is an *estimate* (L) | M (lane) / L (layout) | `rampLane` | The crawler straddles the pad (MOON p. 235). |
| Trench | 58 ft wide, 450 ft long, bisecting the pad north-south; "opens to grade at the north end"; floor at grade, about 6 ft above mean sea level; trench and deflector about 42 ft high | M503 p. 8-8; A11PK p. 171 | H | `trenchHalfWidth` 8.84 m, `trenchHalfLength` 68.58 m | MOON p. 537: 13 m deep, 18 m wide, 137 m long. Centred on the vehicle (*estimate*, L). |
| South end | open to grade too | *derived* (M): the deflector is two-way (MOON p. 235: "two-way, wedge-type"; M503: "wedge-type"), so half the exhaust runs south; M503 names only the north end | M | south exit | |
| Deflector | "700,000-pound mobile wedge-type flame deflector ... mounted on rails in the trench"; a second one held in reserve, parked north of the launch structure | M503 pp. 8-8, 8-15 | H | — | |
| Deflector size | 12 m high, 15 m wide, 23 m long, 635 t | MOON p. 537 | M | wedge 12 × 15 × 23 m, 1 m ridge (L) | MOON p. 235 (design): 13 m high, 15 m wide, 317 t. A11PK: "about 1.3 million pounds", covered with 4.5 in of refractory concrete. |
| Pad colours | concrete; refractory in the trench | *estimate* (L) | L | `concreteColor`, `refractoryColor` | |

## 9. Attachments for P4

All in the site frame. K0's `VisualAttachment.Kind` has no trench exit, so all four are `.vent`, named. `radius` is a half-width: the opening and the trench are rectangles.

| name | position (m) | direction | radius | from |
|---|---|---|---|---|
| ML exhaust opening | (0, 0, 0): the deck on the axis | down (−z) | 6.858 (45 ft square) | §2 |
| Flame deflector ridge | (0, 0, −15.13): 12 m above the floor | down (−z) | 7.5 (15 m wide) | §8 |
| Flame trench north exit | (+68.58, 0, −20.73): the trench's end, half-way between floor and hardstand | north (+x) | 8.84 (58 ft wide; 42 ft high) | §8 |
| Flame trench south exit | (−68.58, 0, −20.73) | south (−x) | 8.84 | §8 |

## 10. Checks (`LC39ATests`)

| check | model | reference | tolerance |
|---|---|---|---|
| site latitude, longitude, height | the core's pad; elevation + 3.240 m | `VesselLibrary.lc39A`, §1 | 1e-15 rad; 1e-12 m |
| the core's base station | −115.0 in | AS506 datasheet §4 | 1 mm |
| the deck above the core's placed vehicle base, on its axis | 3.240 m | §1 | 1 mm |
| the posts (STA 113.31) above the deck; the heads' top | 100.75 in | HDA Fig. 10 | 1 mm |
| the deck above the drawn surface; against 95 ft | 29.24 m; +0.28 m | §1 | 5 mm |
| Position II, the site's x axis, through `SceneExtractor` too | north; Position I east | M503 Fig. 8-7 | 1e-9 rad |
| arm 1: still at its command and through the withdrawal; safe angle at command + 11.1 s or 9.9 s; margin before arm 2 | 2.70 s / 3.90 s | FER503 2.69 s, FER506 3.9 s | 0.011 s |
| arm 2 | T−16.2 s to T−8.2 s | FER, M503 | 1e-12 |
| arm 9 | 12° from T−42 or T−43 min + 12 s; retracted at T−5 min | A8PK, A11PK, M503 | 1e-12 |
| arms 4-8, the masts | from first motion + 0.16 s; done within 6.4-9.0 s; masts 2.62, 2.77, 2.54 s | M503, FER503 | 1e-12 |
| at first motion | arms 1, 2, 3, 9 retracted; 4-8 extended | A8PK, A11PK | — |
| arm tips on the vehicle; retracted arms folded east, near face 8.63 m from fin tip A | §4 | FER503 Table 11-1 | 0.05 m; 0.01 m |
| deck 0; ML 48.87 × 41.15 m; hardstand −47 ft; grade −89 ft | §2, §8 | BALKE, A8PK, M503 | 1e-6 m |
| LUT top 380 ft; crane top 398 ft, reach ≥ 85 ft; arm levels | §3-§5 | M503, A8PK, ERH | 1e-9 m |
| trench exits at ±225 ft, mid-height, 29 ft half-width, north on the tower's side; the opening at the deck; the deflector's ridge | §9 | M503, MOON | 1e-9 m |

## 11. Where sources disagree

1. **The deflector's mass.** M503 gives 700,000 lb (318 t) and MOON's design history 317 t; MOON's appendix gives 635 t (1.4 million lb); A11PK says "about 1.3 million pounds". The mass is not modelled, and the size comes from MOON's appendix.
2. **Arm 2's retract command.** M503 (Nov 1968) plans T−20 s; both FERs record T−16.2 s, as flown; A11PK says "about T-16.5 seconds". The model uses the FERs'.
3. **Arm 9's park.** A8PK: "about T-42 minutes"; A11PK: T−43 min. Each launch uses its own.
4. **"About three feet."** A 12° swing about a hinge 18 m away moves the white room about 3.8 m, not the press kits' "about three feet". The 12° is kept (M503 and both press kits give it); the hinge is not sourced.
5. **The 320 ft level's height.** M503 p. 8-13: the slide wire is attached "at the 320 foot level (443 feet above ground level)", 123 ft between the two. The pad's own numbers give 89 ft from grade to the deck, so 409 ft. Not resolved, and not used.
6. **The ML's length.** 160 ft (M503, A8PK), 158 ft between Balke's mount lines, 48.87 m (160.3 ft) overall in Balke's Fig. 1. The model uses Fig. 1.
7. **The tower's height.** 380 ft (M503, TND4870's model), "381 feet (116 meters)" in TND4870's text. The model uses 380 ft.
8. **The deck's height.** 95 ft above sea level from the pad's numbers, 29.24 m (95.9 ft) from the core's elevation. The site follows the core (§1).

## 12. Not modelled, open, and questions

- **Swing direction** (§4) and **the crane's heading** (§5) are estimates. Franz: please check them against the reference photographs, e.g. S68-56050 and S69-39961 at liftoff, or any post-launch view of the LUT. The arms fold east in the model and the crane points north.
- **Damper struts** "secure the vehicle near its top" (A8PK); not found in detail; not drawn.
- **Mobile service structure.** It is moved away hours before launch, so it is not drawn. M503 p. 8-15 has its size.
- **Water systems** (deck deluge, trench nozzles), **camera sites**, **propellant facilities**, the **egress slide wire** and **blast room**: not drawn. P4 may want the deluge (A11PK: 29 deck nozzles, 50,000 gal/min for 30 s, then 20,000).
- **Raising the L rows** needs KSC's Ground Systems Evaluation Reports for AS-503 and AS-506, or HAER's ML and pad documentation (blocked here).

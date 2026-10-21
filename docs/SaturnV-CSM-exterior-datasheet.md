# Saturn V and Apollo CSM exterior datasheet (M1.6 VD1, VD3)

Compiled on 2026-10-21 for M1.6's exterior-data tracks (docs/m16/plan.md, "VD1, VD2, VD3: exterior data"): **VD1**, the Saturn V's exterior geometry (§1-§8), and **VD3**, the CSM, LES, SLA and LTA-B (§9-§13). The geometry tracks VG1-VG3 build the 3-D models from these rows; VD2's paint and markings live in `docs/data/markings/`. Every row gives a value, its source (document, printed page and PDF page, figure or table, or a NASA photo ID), a grade, and today's code value where one exists. §14 lists where this table and today's code disagree, for the VG tracks. No Swift was changed.

## Conventions

- **Stations.** STA is the Saturn V vehicle station in inches (the F-1 gimbal plane is STA 100, the F-1 exit STA −115.36; BCD). Apollo spacecraft station Xa = STA − 2756.56 (AS-501 FER Fig. B-1, `docs/AS506-datasheet.md` §13). S-II stage station XB = STA − 1564 (BCD prints both). S-IVB stage station = STA − 2545.85 (BCD prints both: S-IVB 100.00 = STA 2645.85). Height above the vehicle base, as `AS506` uses it: h = (STA + 115) × 0.0254 m.
- **Azimuth θ** is measured round the vehicle axis from Position I towards Position II: Position I 0°, II 90°, III 180°, IV 270°; fins A 45°, B 135°, C 225°, D 315°. Seen from above (from the nose), θ increases anticlockwise. In the construction frame (`ApolloAxes`) Position I is +z, II is −y, III is −z and IV is +y, so θ is right-handed about +x, and the fins are A (−y, +z), B (−y, −z), C (+y, −z), D (+y, +z), as `docs/AS506-datasheet.md` §12 has them. For the spacecraft, +Y_A is Position II and +Z_A Position III, so an angle φ from +Y_A towards +Z_A (the AOH's convention) is θ = φ + 90°.
- **Orientation on the pad.** Position II faces the launch umbilical tower; the hold-down arms stand at Positions I-IV; engine 1 is between Positions I and II, engine 2 between II and III, engine 3 between III and IV, engine 4 between IV and I (M503 Fig. 8-7, printed p. 8-9, PDF p. 190, page image, H). So engines 1-4 sit under fins A-D. The drawings agree with this sense of θ: M503 Fig. 8-7 and D5 Fig. 5-7 are views from above with I, II, III, IV anticlockwise.
- **Units.** The source's unit first, SI in brackets where it helps: 1 in = 0.0254 m, 1 ft = 0.3048 m, 1 caliber (cal) = 396 in, the Saturn V's reference diameter (ALM and TMX notes).
- **Grades.** As the plan's datasheets grade them (owner decision 10):
  - **H**: a primary document (NASA, MSFC, MSC, or the prime contractor's technical document) states the number, or dimensions it on a drawing, read on the page image, unambiguous for the vehicle in question.
  - **M**: a primary-source number that needed interpretation: arithmetic on sourced values (marked *derived*), a value scaled off a drawing with a known reference dimension (*scaled*), a schematic's placement, a design-stage drawing not re-checked against the flown vehicle, a sister vehicle's value, or two sources a few per cent apart.
  - **L**: an estimate (*estimate*, always with how it was made), a secondary source only, or a value whose print is self-contradictory.
- **How values were read.** Every number below was read on the page image (rendered with `pdftoppm`, cropped and enlarged where small). The PDFs' text layers were used only to find pages. Downloaded documents and photos stayed outside the repo.
- **Today's code** cites `ApolloShapes.swift` (`ApolloShapeData`, `ApolloDresser`), `AS506Data.swift` (`AS506`) and `ApolloCSMData.swift` (`ApolloCSM`); "—" means today's model has no such feature.

## Sources

| key | document | copy read | bytes | sha256 |
|---|---|---|---|---|
| M503 | MSFC-MAN-503, *Saturn V Flight Manual SA-503* (1 Nov 1968, changes to 25 Nov 1968) | https://ntrs.nasa.gov/api/citations/19750063889/downloads/19750063889.pdf | 19,707,479 | `7465652b07306f45d2450f6a50bc52ee9c2a257522bbfc86c14bb9d1a006a967` |
| M504 | MSFC-MAN-504, *Saturn V Flight Manual SA-504* (cross-checks only) | https://www.ibiblio.org/apollo/Documents/Saturn_V_Flight_Manual_SA_504.pdf | 19,288,378 | `90d3b9bf6ec8af842486f82b81b97eb862e9270e9e65db8c65bb34bc3d887cb1` |
| BCD | The Boeing Company, *Saturn V Apollo Flight Configuration*, sheet 1 of 2, 1 Mar 1967, ref. 104573 Apollo Saturn AS-501 (NASA image 9253429) | https://images-assets.nasa.gov/image/9253429/9253429~orig.jpg | 2,623,446 | `59763ffb44c335111dea762068449f6922a90d93b4817222f85585dddc204143` |
| TMX | NASA TM X-53770, C. E. Walker, *Results of Several Experimental Investigations of the Static Aerodynamic Characteristics for the Apollo/Saturn V Launch Vehicle* (21 Aug 1968), Fig. 2 "Model Geometry" (full-scale stations; dimensions in calibers) | https://ntrs.nasa.gov/api/citations/19690009748/downloads/19690009748.pdf | 40,456,212 | `f60fed99deaf8228fa2490e4eb68097f752d871ddbb77e9841700ec9c3670a9d` |
| D5 | Boeing D5-15796-1, *Saturn V Aerothermodynamics Flight Evaluation Summary, AS-501 through AS-503* (19 Jun 1969) | https://ntrs.nasa.gov/api/citations/20160013592/downloads/20160013592.pdf | 4,924,918 | `8f97300e55c746e5fa4634bbf3df8927b552ab327801fde8c3491dec44c7fb87` |
| TP3615 | NASA TP-3615, C. Barret, *Review of Our National Heritage of Launch Vehicles Using Aerodynamic Surfaces…* (1996): text p. 44 and its reproductions of MSFC's Saturn V Air Load Manual sheets (below) | https://ntrs.nasa.gov/api/citations/19960024281/downloads/19960024281.pdf | 2,868,630 | `c232510b41cf01bcc9db83bd69089e4666752930303d99cf65c9aeab2bf5ec5d` |
| ALM | MSFC Aero-Astrodynamics Laboratory, *Saturn V Air Load Manual*, "Vehicle Component Geometry": sheet 1.9101 *S-IC Booster Fin (75 ft²)* (2 Nov 1964, rev. 0; TP3615 Fig. 42, PDF p. 56) and sheet 1.9201 *S-IC Booster Engine Shroud* (7 Aug 1963, rev. 3; TP3615 Fig. 46, PDF p. 60). Linear dimensions in calibers, stations in inches. | in TP3615 | | |
| A8PK | NASA Release 68-208, *Apollo 8 Press Kit* (6 Dec 1968) | https://www.nasa.gov/wp-content/uploads/static/apollo50th/pdf/A08_PressKit.pdf | 6,162,826 | `fb5ba158821c989460f1a84c8efa85d459988529409585d78967f758b4462947` |
| A8MR | MSC-PA-R-69-1, *Apollo 8 Mission Report* (Feb 1969) | https://ntrs.nasa.gov/api/citations/19700033031/downloads/19700033031.pdf | 11,219,267 | `da1ad9834b9d6906931bc28717be29a01f74a6de99151d86ceb165ef37157d03` |

The engine (§8) and spacecraft (§9-§13) sources are listed in those sections.

**Which vehicle each source describes.** M503 is AS-503's (Apollo 8's) own flight manual. BCD, TMX, D5 and the ALM sheets are AS-501-era drawings and data (D5 covers AS-501 to AS-503). Where they agree with M503 they are taken for AS-503 and AS-506; where a later change is known (the S-II ullage motors, below), the row says so.

---

# VD1: the Saturn V

## 1. The stack

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Vehicle tip (LES nose) | STA 4240.79 (107.716 m); Xa 1484.23 | BCD (spacecraft column); D5 Fig. 6-1, printed p. 6-8, PDF p. 172: "STA. 4240.7" | H | `overallHeight` 363 ft from STA −115 puts it at STA 4241 (M) | TMX Fig. 2 prints the tip as "?40.792" (first digit cut off); its 10.456 cal from STA 100 gives 4240.6. |
| F-1 exit plane, the vehicle base | STA −115.36 | BCD "bottom of F-1 engine −115.36 / 2.930 m" | H | STA −115 (`docs/AS506-datasheet.md` §4) | 0.36 in lower than the model's datum. |
| Overall height | 363 ft | M503 Fig. 1-3, printed p. 1-6, PDF p. 13 | H (rounded) | 363 ft (M) | 4240.79 + 115.36 = 4356.15 in = 363.0 ft. |
| S-IC base diameter including fins | 63.0 ft | M503 Fig. 1-3 "S-IC Base (including fins) 63.0 FEET" | H (rounded) | — | The fins' tip-to-tip span on the diagonals; §2.4 derives 62.7 ft from the ALM sheets. Closes `docs/AS506-datasheet.md` §6's open fin span. |
| S-IC diameter without fins and shrouds | "33 feet in diameter, not including the fins and engine shrouds on the thrust structure" | A8PK p. -39-, PDF p. 59 | H | 396 in | |
| S-IC, S-II, interstage diameter | 33.0 ft (396 in) | M503 Fig. 1-3; TMX Fig. 2 "1.000 Reference Diameter (396" Full Scale)" | H | 396 in (M) | |
| S-IVB, IU diameter | 21.7 ft (Fig. 1-3), 21.6 ft (Fig. 6-1); 0.656 cal = 259.8 in (TMX) | M503 pp. 1-6 and 6-2; TMX Fig. 2 | H | 260 in (M) | 260 in is the nominal; the 21.6/21.7 ft are roundings. |
| Stage lengths | S-IC 138 ft; S-II 81.5 ft; S-IVB 59.3 ft (Fig. 1-3) or 59.0 ft (Fig. 6-1, with the aft interstage); IU 3.0 ft | M503 pp. 1-6, 5-1, 6-2 | H | from the stations (H) | S-IC: STA −115.36 to 1541 = 1656.4 in = 138.0 ft. |

## 2. S-IC (Boeing)

### 2.1 Exterior bands (STA)

From the base up, as BCD labels them (page image; each inch value printed with its metre value, which checks it). M503 Fig. 4-1 (printed p. 4-2, PDF p. 59) gives the section lengths: forward skirt 120.7 in, intertank 262.4 in, fuel tank 517 in, thrust structure 233.7 in.

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Engine fairing aft end (fins' and fairings' base) | STA 48.50 | BCD; ALM 1.9201; TMX Fig. 2 "Sta. 48.500" | H | — | |
| F-1 gimbal plane | STA 100.00 | BCD; ALM 1.9201; TMX Fig. 2 | H | STA 100 (M) | |
| Top of the base heat shield | STA 112.00 | BCD | H | — | D5 Table 2-I (printed p. 2-4, PDF p. 26) puts its pressure ports at "Station 112", 80-260 in from the axis. |
| Thrust structure | STA 116.00 to 345.70 (229.7 in) | BCD | H | — | M503 Fig. 4-1: 233.7 in. M503 Fig. 4-3 (p. 4-3, PDF p. 60) labels the structure's lower ring "STA 116.75". |
| Hold-down post fitting | vehicle STA 113.31, at Positions I-IV | M503 Fig. 8-7, printed p. 8-9, PDF p. 190 | H | — | Four posts on the lower thrust ring (M503 p. 4-1). |
| Fuel (RP-1) tank, exposed | STA 345.70 to 628.80 | BCD (top of thrust structure; bottom of intertank) | H | — | The tank spans STA 225.00-742.00 (bottom, top), its forward Y-ring at 605.00. |
| Intertank | STA 628.80 to 885.20 (256.4 in) | BCD | H | — | M503 Fig. 4-1: 262.4 in (6 in more, likely measured over the attachment rings): M. |
| LOX tank, exposed | STA 885.20 to 1420.30 | BCD | H | — | The tank spans STA 772.00 to its vent at 1521.00, Y-rings at 909.00 and 1404.00. |
| Forward skirt | STA 1420.30 to 1541.00 (120.7 in) | BCD; M503 Fig. 4-1 "120.7 IN" | H | — | |
| S-IC top, S-IC/S-II interstage bottom | STA 1541.00 (S-II XB −23.00) | BCD; TMX Fig. 2 | H | `sICTop` 1541 (H) | |

### 2.2 Skin and stiffeners

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Forward skirt | 7075-T6 skin panels "stiffened and strengthened by ring frames and stringers" | M503 p. 4-1, PDF p. 58 | H | — | |
| Forward skirt thermal insulation | silicone rubber insulation over the skin; AS-503's uninsulated test plates were "mounted on top of stringers" | D5 §6.1.3, printed p. 6-2, PDF p. 166 | H | — | Matters for VM2: the forward skirt's outer surface is the insulation, not bare skin. |
| Forward skirt stringer positions | stringer tops at 44°10′ from Position I towards IV (θ 315.8°) and 9°10′ from Position III towards II (θ 170.8°), STA 1491.5 and 1519 | D5 Table 6-I (cont.), PDF p. 179 | H | — | Two fixed points of the stringer pattern, 145.0° apart. |
| Intertank | corrugated 7075-T6 skin panels with circumferential ring frames | M503 p. 4-1 | H | — | |
| Thrust structure | 7075-T6 skin segments | M503 p. 4-1 | H | — | The external stiffening's form is not stated in M503. |
| Fuel and LOX tank walls | 2219-T87; smooth outside (the LOX tank is stiffened by integrally machined T stiffeners and ring baffles inside) | M503 p. 4-1 | H | — | |
| Forward skirt stringer count | **216** stringers, 1°40′ apart (5.76 in at the 198 in skin), the Positions falling midway between two stringers | *derived*: D5's two stringer tops (above) lie 145.0° apart and both 50′ off a Position modulo the pitch, which only 144 or 216 stringers satisfy; NASA photo 6761892 (AS-503's S-IC, S-IC-3, erected in the VAB, Dec 1967) measures 1.77-1.82° (N ≈ 198-204) at three rows | M | — | Photo method: grey-level profile across the skirt, shadow lines located against the skirt's silhouette (x = x_c + R sin θ), spacing taken within ±60° of the line of sight; script and rows kept in the session's scratchpad. 144 would be 2°30′, which the photo excludes. |
| Intertank corrugation count | about **108** corrugations (pitch ≈ 3.3°, ≈ 11.5 in) | *estimate*: NASA photo 6761892, two rows across the intertank, median spacing 3.29° and 3.36° (N 107-109), by the same method | L | — | No document prints it. |
| Thrust structure stiffeners | external stringers, visible on AS-503's thrust structure below the fuel tank band and between the fairings (NASA photos 6761892, 6761894); count **not determined**: the fairings hide the silhouette, and the hat sections show both edges | photos | — | — | Left for VM2. |

### 2.3 Engine fairings (shrouds)

ALM sheet 1.9201 (TP3615 Fig. 46, PDF p. 60, page image enlarged; a 1963 design sheet, rev. 3) dimensions the fairing as a half-cone. BCD's 1967 configuration repeats its end stations (48.50, 362.00), and the fin built on it (§2.4) closes on its 75 ft², so the sheet is taken as flown (H for the printed values).

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Count and placement | four, one over each outboard F-1, on the fin diagonals (θ 45°, 135°, 225°, 315°) | M503 p. 4-3; M503 Fig. 8-7; D5 Fig. 6-5 | H | — | |
| Form | a 15° half-angle cone whose axis runs parallel to the vehicle's, 0.0404 cal (16.0 in) inside the 198 in skin; in section, a semicircle on that axis with straight flanks dropping to the skin | ALM 1.9201 side view and end view | H | — | |
| Cone axis from the vehicle axis | 0.5000 − 0.0404 cal = 0.4596 cal = 182.0 in | ALM 1.9201 (*derived*) | H | `f1OutboardRadius` 182 in (L, fan wiki) | The fairing is centred on the outboard engine's gimbal radius: this sources today's 182 in (M for the engine, §8). |
| Radius at the aft end (STA 48.50) | 0.2526 cal = 100.0 in | ALM 1.9201 | H | — | |
| Half-angle | 15° | ALM 1.9201 | H | — | |
| Forward end (cone meets the skin) | STA 362.096 | ALM 1.9201 (0.7919 cal = 313.6 in from STA 48.5); BCD "top of engine fairing 362.00" | H | — | Check: 48.5 + (100 − 16)/tan 15° = 362.0. |
| Virtual apex of the cone | STA 421.808 | ALM 1.9201 (0.9427 cal = 373.3 in from STA 48.5) | H | — | 48.5 + 100/tan 15° = 421.7. |
| Material | titanium alloy below STA 115.5, aluminium alloy above | M503 p. 4-3, PDF p. 60 | H | — | |
| Air scoops | the shrouds carried scoops ("Fin Interference Due to the Shroud Scoops on Saturn V", in TMX's reference list); ALM 1.9201's side view draws two small scoops on the shroud's flank facing the viewer, one above the other, between the gimbal-plane line (STA 100) and the fin's trailing edge (STA 81.277), i.e. at about STA 85-92; which way they open is not drawn | TMX reference list, printed p. 172, PDF p. 182; ALM 1.9201 drawing (enlarged crop) | M (existence); L (placement, *scaled* from an undimensioned detail; size not dimensioned) | — | Two per flank as drawn; a pair on each side of the fin (four per fairing) if the flanks are symmetric, as the design report assumed: L. |
| Compartment venting | the S-IC compartments vented through "a series of vent ports located in the interstage and intertank areas"; the aft compartment vents into the shroud base through four ducts in the shrouds | D5 §2.2, printed p. 2-3, PDF p. 25 | H | — | The vent ports' number, size and azimuths are not given. D5 also records that AS-501's base flow deflectors were removed for AS-502 and later. |

### 2.4 Fins

ALM sheet 1.9101 *S-IC Booster Fin (75 ft²)* (TP3615 Fig. 42, PDF p. 56, page image, enlarged and rotated), TP3615's text (p. 44, PDF p. 52), and M503 p. 4-3.

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Count and placement | four, on the diagonals (fins A-D at θ 45°, 135°, 225°, 315°), each on an engine fairing's outer generatrix | M503 Fig. 4-1, p. 4-3; D5 Fig. 6-5, PDF p. 176; ALM 1.9201 | H | — | "Four fixed, titanium covered, stabilizing fins" (M503). |
| Construction | 7075-T6 aluminium, titanium covered; mechanically attached to the engine fairing assembly; four fins weighed 2,035.2 lb in all | M503 p. 4-3; TP3615 p. 44 | H | — | |
| Trailing edge | at STA 81.277, straight, perpendicular to the axis | ALM 1.9101 | H | — | |
| Tip chord | from STA 81.277 to 136.277: 0.1389 cal = 55.0 in | ALM 1.9101 (0.0877 + 0.0512 cal); TP3615 "tip chord of 55 inches" | H | — | |
| Root | along the fairing's 15° generatrix, from STA 81.277 to the root leading edge at STA 216.687 (0.3419 cal = 135.4 in axially, 140.2 in along the root) | ALM 1.9101, 1.9201 | H | — | TP3615 rounds it to "a root chord of 138 inches". |
| Span (radial extent) | 0.2601 cal = 103.0 in at the trailing edge; 0.3517 cal = 139.3 in from the root leading edge to the tip | ALM 1.9101; TP3615 "span of 139 inches" | H | — | |
| Leading-edge sweep | 30° | ALM 1.9201; TP3615 | H | — | Derived check from the stations: 30.0°. |
| Tip radius from the vehicle axis | 376.2 in (span tip to tip 62.7 ft) | *derived*: the root's trailing-edge end on the fairing's generatrix at STA 81.277 is 282 − 32.8 tan 15° = 273.2 in from the axis, plus 103.0 in | M | — | M503's "63.0 FEET" is this, rounded. |
| Planform area | 75.0 ft² per fin | *derived* from the four corners above; the sheet's title "75 FT²"; TP3615 "75 ft² each" | H | — | The derived area matching the title confirms the reading. |
| Section | a 10° included-angle wedge leading edge (the "ramp section") faired into a flat, near-constant-thickness aft section (the "flat section") over the last 0.0877 cal (34.7 in) of the chord | ALM 1.9101 section; D5 Table 6-I "Ramp Section" and "Flat Section" of the fins, PDF p. 179 | H | — | |
| Thickness | root 0.0388 cal = 15.4 in at the ramp's end, 0.0364 cal = 14.4 in at the trailing edge; tip 0.0101 cal = 4.0 in; faces taper 2°53′29″ spanwise | ALM 1.9101; ALM 1.9201 end view (half-thickness 0.00505 cal at the tip); TP3615 "outboard chord depth of 4 inches, a root chord depth of 15 inches … a wedge angle of 10°" | H | — | |
| Span stations (for strip loads) | R/D 0.698, 0.742, 0.786, 0.830, 0.874, 0.918 | ALM 1.9101 | H | — | Not geometry; recorded because they are printed on the sheet. |

### 2.5 Retrorockets (in the fairings)

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Count and placement | eight, "mounted, in pairs, in the fairings of the F-1 engine"; one pair per fairing, one motor either side of the fin | M503 p. 4-27, PDF p. 84; M503 Fig. 4-25 (p. 4-26, PDF p. 83); BCD "retro rockets (2 each 4 places)" | H | 8 at `sICRetroStation`, pairs ±2.5° about each fin (L) | |
| Motor size | 86 in long, 15-1/4 in in diameter, 504 lb with 278 lb of propellant | M503 p. 4-27 | H | — | |
| Apollo 8 press kit's count | "four other rocket motors … retro-rockets" | A8PK p. -41-, PDF p. 62 | — (press error) | — | M503 (AS-503's own manual: eight, Fig. 1-3 and p. 4-27) and BCD agree on eight; the press kit is wrong, as the design report noted. |
| Mounting | pinned to the vehicle support and pivot support fittings at 7.5° from the vehicle centreline | M503 p. 4-27 | H | `sICRetroCant` 7.5° (H) | |
| Nozzle exit | at the fairing's forward end, which "is burned and blown through by the exhausting gases" | M503 p. 4-27 | H | — | No separate exit port: the exhaust breaks through the fairing's skin. For P5's retro attachments. |
| Station of the motors | not dimensioned. The fairing's radius at STA 250 is 46 in and at STA 300 33 in (§2.3), so two 15.25 in motors side by side fit only aft of about STA 300; the motor bodies then lie about STA 200-300 | *estimate* from §2.3 and the motor size | L | `sICRetroStation` 230, `sICRetroRadius` 5.25 m (L) | Today's values are consistent with this estimate. |

### 2.6 Tunnels, vents, umbilicals and doors

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| External tunnels | two: the "GOX Line & Fuel Pressure Line Tunnel" and the "Cold Helium Line & Electrical Cable Tunnel" | TMX Fig. 2; BCD "pressurization tunnel (2 places)"; M503 Fig. 4-1 "cable tunnel" | H | — | The five LOX suction-line tunnels run inside the fuel tank (M503 Fig. 4-1). |
| Tunnel azimuths | electrical (cable) tunnel just off Position I towards fin A; pressurization tunnel just off Position III towards fin C | D5 Fig. 6-5 "View AA", printed p. 6-12, PDF p. 176 | M (schematic) | — | Read off a plan-view schematic: a few degrees off each Position; exact azimuths not dimensioned. |
| Tunnel extent | both tunnels from about STA 205 to about STA 1515 (scaled); the pressurization tunnel's forward ramp at STA 1519; electrical tunnel skin instrumented at STA 727 | *scaled* off TMX Fig. 2 (300 dpi page image; 1.599 in/px between the STA 100 and 1541 lines; ends at STA 200-215 and 1508-1516); D5 Table 6-I, PDF p. 178 ("Station 1519; Internal Pressurization Tunnel Ramp", "Station 727, Internal Electrical Tunnel Skin"); NASA photo 6761894 (AS-503's base: a tunnel's rounded aft end on the thrust structure, about STA 200 judged against the fairing's 48.5-362 span) | M (forward end); L (aft end) | — | The aft ends sit on the thrust structure between the fairings. |
| Tunnel cross-section | **not found** as a dimension; TMX Fig. 2 draws them standing about 13-20 in proud of the skin | *scaled*, TMX Fig. 2 | L | — | Only the S-II's tunnel is dimensioned (§4: 22 in wide, semicircular). |
| LOX vent | the LOX tank's vent at STA 1521.00 (top of the tank, inside the forward skirt); a vent valve and a vent-and-relief valve | BCD "LOX vent 1521.00"; M503 p. 4-12 (PDF p. 69) and Fig. 4-13 (printed p. 4-16, PDF p. 73) | H | — | The vents exhaust through the forward skirt (M503 p. 4-1: the forward skirt accommodates "the venting of the lox tank and interstage cavity"); the exterior outlets' number and form **not found**. |
| GOX line, forward skirt | STA 1511.75 | BCD | H | — | Interior. |
| Fuel vent line | STA 696.00 | BCD | H | — | |
| LOX fill and drain | STA 794.18 and 776.18 (two lines, "far side") | BCD; M503 p. 4-9 ("two fill and drain lines") | H | — | "Far side" in BCD's view, which shows Positions II and III at the base. |
| Fuel fill and drain; interconnect LOX drain | STA 130.00 | BCD | H | — | In the thrust structure. |
| Intertank access door | on the intertank, "far side" | BCD | M | — | Station not printed. |
| Forward umbilical plate | on the forward skirt, between Positions I and II, near II | M503 Fig. 4-2, p. 4-3 | M (schematic) | — | Position II faces the tower (M503 Fig. 8-7). |
| Tail umbilical plates (tail service masts) | three: TSM 1-2 at Position I; TSM 3-2 and 3-4 either side of Position III | M503 Fig. 8-7 (p. 8-9); Fig. 4-3 "umbilical plate no. 3" at Position III | H (azimuths, as drawn) | — | The masts are LC's; the S-IC carries their plates on the thrust structure. |
| Hold-down post fittings | four, at Positions I-IV, vehicle STA 113.31 | M503 Fig. 8-7 | H | — | |

### 2.7 Base heat shield and engine curtains

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Base heat shield | at the base of the stage, forward of the gimbal plane; top at STA 112.00; out to the fairings (pressure ports at 80-260 in from the axis, so it continues into the fairings) | M503 p. 4-1/4-3; BCD; D5 Table 2-I, PDF p. 26 | H | — | |
| Construction | 15-7 PH stainless-steel honeycomb, 1.00 in thick, brazed to 0.010 in steel face sheets | M503 p. 4-3 | H | — | |
| Flexible engine curtains (S-IC) | a "vehicle flexible heat-resistant curtain" attached to each F-1's interface panel, closing the gap to the heat shield | NR printed p. 3-7, PDF p. 55 (§8.1) | M | — | Extent and form not dimensioned. |

## 3. S-IC/S-II interstage

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Extent | STA 1541.00 to 1760.00; the S-II's "interstage bottom" is at 1541 | BCD; M503 Fig. 5-20 (PDF p. 110) | H | open cylinder 1541-1760 (H) | |
| First separation plane | STA 1564 (XB 0.00); the 23 in ring below it leaves with the S-IC | BCD; M503 Fig. 5-20 | H | `sICSIISeparationPlane` 1564 (M) | |
| Second separation plane | STA 1760 (XB 196.00) | BCD; M503 Fig. 5-20 | H | `sIIAftSkirt` 1760 (H) | |
| Construction | 7075 semimonocoque, external hat-section stringers, internal ring frames; skin 0.071 in | M503 p. 5-1, PDF p. 86 | H | — | |
| Stringer numbering (count clue) | "Stringer #211" at STA 1649, 82° from Position III towards IV (θ 262°) | D5 Table 6-II (concluded), PDF p. 206 | H (as printed) | — | If stringer 1 is at Position I and the count runs towards II, about 290 stringers (4.3 in pitch): *estimate*, L. The numbering's origin is not stated. |
| S-II ullage motors | **four on AS-503** (and AS-502), eight on AS-501: "four ullage motors were removed from the AS-502 and AS-503 vehicles" | M503 Fig. 1-3 ("ULLAGE 4"), p. 5-24, PDF p. 109; D5 §6.2.2, printed p. 6-5, PDF p. 169 | H | four (AS-506) | Four on AS-506 too (`AS506`, MSFC-MAN-506). |
| Ullage motor placement | parallel to the vehicle centreline, 90° apart round the interstage's aft end, nozzles just above the first separation plane, canted outward 10° | M503 p. 5-24, PDF p. 109 | H | `sIIUllageMotorCant` 10° (H) | |
| Ullage motor azimuths | at Positions I-IV (M503 Fig. 5-2 draws them at Positions I and III and between) | M503 Fig. 5-2, p. 5-3, PDF p. 88 | M (schematic) | Positions I-IV (`AS506`) | |
| Ullage motor size | about 89 in long, 12-1/2 in in diameter; 336 lb of propellant; 4130 steel case | M503 p. 5-24 | H | — | |
| Ullage fairing | a fairing round each motor, bottom at XB −0.44 (STA 1563.56); top printed "XB 176.68 / 3.725 m" | BCD "bottom ullage R.M. fairing −0.44", "top ullage rocket fairing motor 176.68 3.725" | H (bottom); L (top) | `sIIUllageMotorStation` 1608, radius 5.24 m (L) | The top's inch and metre values disagree (3.725 m = XB 146.65): one is a misprint, so the fairing's top is STA 1710.6 or 1740.7. M503 Fig. 5-22 shows a long fairing with a pointed top. |
| Ordnance fairings | at the first separation plane (STA 1568), 55° from Position III towards IV (θ 235°) and 55° from Position I towards II (θ 55°) | D5 Table 6-II, PDF p. 205 | H (azimuths and station of the instrument) | — | The separation ordnance's fairings; size not given. |
| Inner skin finish | zinc-chromate primer (design report) | — | not sourced here | — | VD2 owns finishes; left to its photo rows. |

## 4. S-II (North American)

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Aft skirt | STA 1760.00 (XB 196) to 1890.00 (XB 326.00); a "division of aft skirt" at XB 283.00 | BCD | H | — | |
| Exposed LH2 tank wall | STA 1890.00 to 2387.00 | BCD (top of aft skirt; bottom of forward skirt XB 823.00) | H | — | |
| LH2 tank external insulation | foam-filled honeycomb, about 1.6 in thick on the sidewalls, sealed with Tedlar, helium-purged | M503 p. 5-5 and Fig. 5-4, PDF p. 90 | H | — | VM2: the visible S-II wall is this insulation's surface. |
| Forward skirt | STA 2387.00 (XB 823.00) to 2519.00 (XB 955.00) | BCD | H | — | |
| Skirts' construction | 7075 cylinders "stiffened by external hat-section stringers and stabilized internally by circumferential ring frames"; skin 0.040 in (forward skirt), 0.071 in (aft skirt) | M503 p. 5-1 | H | — | |
| Systems tunnel | one, external, "from the S-II stage aft skirt area to the forward skirt", semicircular, 22 in wide, about 60 ft long; top at XB 938.50 (STA 2502.5) | M503 p. 5-4, PDF p. 89; BCD "systems tunnel 938.50" | H | — | 60 ft below STA 2502.5 is about STA 1783, at the aft skirt. |
| Systems tunnel azimuth | drawn between Positions I and II, close to I | M503 Fig. 5-2 (PDF p. 88) | M (schematic) | — | |
| LH2 feed-line fairings | five, from XB 158.00 (STA 1722) to XB 451.75 (STA 2015.75) | BCD "top of LH2 feed fairing 5 places 451.75", "bottom LH2 feed fairing 158.00" | H | — | Above the aft skirt's top (STA 1890) about 126 in of each fairing is exposed. TMX Fig. 2 and D5 Fig. 6-1 draw them. |
| LH2 feed-line fairing azimuths | engine 1's at 44° from Position I towards II (θ 44°); engine 4's at 44° from Position IV towards I (θ 314°) | D5 Table 6-II, PDF p. 205 | H (for engines 1 and 4) | — | So the outboard engines' fairings run 1° off the fin diagonals; by symmetry engine 2's and 3's near θ 134° and 224° (M, *derived*); the centre engine's not found. |
| Thrust cone | a truncated cone from about 18 ft in diameter to the 33 ft skin, ring frames and hat-section stringers; from XB 112.00 (STA 1676) to XB 223.00 (STA 1787) | M503 p. 5-1; BCD "bottom of thrust cone 112.00", "top of thrust cone 223.00" | H | grey frustum from STA 1664 (0.6 of the body radius) to 1760 | Its top is inside the aft skirt; the part below STA 1760 shows inside the interstage. |
| Heat shield | fibreglass honeycomb, supported from the thrust structure's lower portion; its aft surface at S-II station 44 (STA 1608) | M503 p. 5-1; D5 Table 4-III, PDF p. 131 (text layer) | H (construction); M (station) | — | See §8.2 for the curtains. |
| Heat-shield curtains | flexible engine curtains round each engine, probes at S-II station 48 (STA 1612), about 48 in from each outboard engine's axis | D5 Table 4-IV, PDF pp. 136-137 (§8.2) | M | — | Fitted on the pad. |
| J-2 gimbal plane | XB 100.00 (STA 1664) | BCD | H | `sIIJ2GimbalStation` 1664 (H) | |
| Outboard J-2 circle | 17.5 ft in diameter (outboard engines on the diagonals) | M503 p. 5-1, PDF p. 86 | H | `sIIOutboardCircle` 17.5 ft (M) | |
| Antennas, forward skirt | radio command antennas, 4 places, XB 923.00 (STA 2487); telemetry antennas, 4 places, XB 902.00 (STA 2466) | BCD; M503 Fig. 5-2 | H (stations); azimuths not found | — | |
| LH2 vent | XB 942.00 (STA 2506) | BCD | H | — | |
| Umbilical and access doors | umbilical and service connections and an access door on the forward skirt; an access door on the interstage, both on the side facing Position II | M503 Fig. 5-2 | M (schematic) | — | |

## 5. S-II/S-IVB interstage

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Extent | STA 2519.00 to 2746.50 (19 ft) | BCD; M503 Fig. 6-1 "19 FEET" | H | frustum 2519-2746.5 (H) | |
| Cone half-angle | 16°44′ | TMX Fig. 2 | H | 16.6° (from the 198 → 130 in radii over 227.5 in) | A 1.3 in difference in the cone's length; negligible. |
| Construction | skin/stringer aluminium | M503 p. 6-1 | H | — | |
| S-II retrorockets | four, 90° apart, "in the aft end of S-II/S-IVB interstage between stations 2519 and 2633", motor axes 3° out from the centreline, nozzles canted 9.5° | M503 p. 5-26, PDF p. 111 | H | `sIIRetroStation` 2576, `sIIRetroCant` 9.5° (H) | |
| Retro size | case 9 in in diameter and 90.68 in long; 104.68 in overall; 268.2 lb of propellant | M503 p. 5-26 | H | — | |
| Retro fairing | a fixed fairing over the motor and a jettisonable fairing over its nozzle at the forward end | M503 Fig. 5-22, p. 5-28, PDF p. 113 | H (form) | — | Fairing dimensions not given. |
| Retro azimuths | **not found** in M503, BCD, TMX or D5 | — | — | on the fin diagonals (`AS506`, D5-15481-1 Fig. 3-1, L) | |
| Access platform support fitting | STA 2664.33 | BCD | H | — | |

## 6. S-IVB (Douglas)

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Aft skirt | STA 2746.50 (S-IVB 200.65) to 2832.00 (286.15); 7.0 ft | BCD; M503 Fig. 6-1 | H | — | |
| Exposed tank wall | STA 2832.00 to 3100.56 | BCD | H | — | Waffle-milled inside, polyurethane-insulated inside (M503 p. 6-1): smooth outside. |
| Forward skirt | STA 3100.56 (S-IVB 554.70) to 3222.56 (676.70); 10.2 ft | BCD; M503 Fig. 6-1 | H | — | |
| Construction | skirts and interstage "skin/stringer type aluminum alloy airframe" | M503 p. 6-1, PDF p. 116 | H | — | |
| Tunnels | two longitudinal tunnels (wiring, pressurisation lines, propellant dispersion); aluminium covers stiffened by internal ribs, fairings only | M503 p. 6-1 | H | — | |
| Tunnel extents | a long "systems tunnel" from about STA 2783 to 3152 and a short "helium tunnel" from about STA 2984 to 3094 | *scaled* off TMX Fig. 2 (1.619 in/px between the STA 2746.5 and 3222.555 lines; ±10 in) | L | — | Both drawn on the face between the silhouette's APS modules (Positions I and III), so near Position II or IV; which one, not found. |
| APS modules | two, 180° apart on the aft skirt, at Positions I and III | M503 p. 6-20, PDF p. 135; `docs/AS506-datasheet.md` §7.3 (Positions I and III) | H | at Positions I and III (L/H) | |
| APS module form | an outer module fairing round three 150 lb engines (pitch, and roll-and-yaw ×2), one 70 lb ullage engine, helium spheres and propellant tanks | M503 Fig. 6-14, p. 6-22, PDF p. 137 | H (form) | a 1.8 m × 0.35 m radius cylinder (L) | Dimensions **not found** in M503 or the APS anomaly report (NTRS 19690016846). |
| APS module station | **not found** | — | — | 73.4 m (STA 2774.7, L) | On the aft skirt, STA 2746.5-2832 (M503 p. 6-20). |
| Ullage motors (TX-280) | two, in fairings "mounted diametrically opposite each other on the S-IVB aft skirt", canted outward; jettisoned with their fairings by spring-loaded assemblies | M503 p. 6-31/6-32, PDF pp. 146-147 | H | two | |
| Ullage motor azimuths | one between the fin D diagonal and Position IV, one between the fin B diagonal and Position II (about 15-20° off each diagonal) | D5 Fig. 5-7, printed p. 5-12, PDF p. 164 | M (schematic) | "Fin II-III and IV-I diagonals" (`AS506`, L) | Consistent with today's model. |
| Ullage motor size | 58.8 lb of propellant, 4135 steel case | M503 p. 6-31 | H | — | Case dimensions not given. |
| Telemetry antennas | two folded-sleeve dipoles, 11° from a fin plane towards fin plane 1 and 11° from fin plane 4 towards fin plane 3, 180° apart in phase; antennas' centreline at STA 3193.56 | M503 p. 6-30, PDF p. 145 (the first fin plane's number is missing in the print); BCD "antennas centerline 3193.56" | H (station); M (azimuths) | — | Read as θ 79° (11° from Position II towards I) and θ 259° (11° from IV towards III): the missing number is taken as 2, which puts the two antennas diametrically opposite; "fin plane" n is read as Position n. |
| LH2 tank vent | STA 3203.56 (S-IVB 657.70) | BCD | H | — | |
| LOX vent | STA 2759.00 (S-IVB 213.15), "far side" | BCD | H | — | |
| LOX/LH2 fill and drain | STA 2760.0 (S-IVB 214.19); an external "line fairing, LH2 fill & drain" | BCD | H (station) | — | |
| Access platform support fitting | STA 3161.56 | BCD | H | — | |
| Forward skirt exterior | the forward umbilical plate, antennas, LH2 tank flight vents and the tunnel fairings | M503 p. 6-1 | H | — | |
| J-2 gimbal | STA 2645.85 (S-IVB 100.00); thrust structure 5.2 ft | BCD; M503 Fig. 6-1 | H | `sIVBJ2GimbalStation` 2645.85 (H) | |

## 7. Instrument unit (IBM)

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Extent | STA 3222.56 to 3258.56 (36 in), 260 in in diameter | BCD; M503 Fig. 1-3 | H | open grey ring (H stations) | |
| Construction | aluminium-alloy honeycomb sandwich, three 120° segments joined by splice plates, extruded aluminium channels at the top and bottom edges | M503 p. 7-2, PDF p. 151 | H | — | |
| Doors | the access-door segment carries an umbilical door and an equipment/personnel access door, between Positions I and II, near II | M503 p. 7-2 and Fig. 7-4 sheet 1, PDF p. 153 | H (doors); M (azimuth, schematic) | — | |
| Antennas | C-band, CCS PCM omni transmit and CCS omni receive antennas in two groups (near Position IV towards I, and near Position II towards III); VHF telemetry antennas near Positions II and IV; UHF telemetry and CCS/PCM directional antennas near Position I | M503 Fig. 7-4 sheet 1 | M (schematic) | — | Sizes not given. |
| Splices | A (near Position II), B (between II and III), C (between I and IV) | M503 Fig. 7-4 sheet 1 | M | — | |

## 8. F-1 and J-2 in flight configuration

Distances along an engine are from its gimbal centre, + aft. The F-1's sides are named as seen from the exit with the engine horizontal: the turbopump at 12 o'clock, the hypergol manifold at 6, the No. 1 (gas generator) side on the left, the No. 2 (engine control valve) side on the right (R1 §1-6, PDF p. 25). Engine sources (read on page images; contractor documents for facts only):

| key | document | copy read | bytes | sha256 |
|---|---|---|---|---|
| R1 | Rocketdyne R-3896-1, *Technical Manual: Engine Data, F-1 Rocket Engine* (31 Mar 1967, changes to No. 10, 16 Jul 1971); Fig. 2-22 at Change 2, 10 Aug 1967 | https://archive.org/download/r-3896-1-technical-manual-engine-data-f-1-rocket-engine-31-mar-1967/R3896-1_(Technical_Manual-Engine_Data)_F-1_Rocket_Engine_31_Mar_1967.pdf | 9,279,507 | `fb281e25e0a36a23942299ebf738ae078dae35c4aca83d079d7524f532f2d1ec` |
| R6 | Rocketdyne R-3896-6, *Installation and Repair of Thermal Insulation, F-1 Rocket Engine* (13 Jul 1966, Change 9, 23 Mar 1972; Fig. 1-1 at Change 4, 13 Mar 1968) | https://archive.org/download/r-3896-6-technical-manual-installation-and-repair-of-thermal-insulation-f-1-rocket-engine-03-23-1/R3896-6_TECHNICAL_MANUAL_INSTALLATION_AND_REPAIR_OF_THERMAL_INSULATION_F-1_ROCKET_ENGINE_03-23-1.pdf | 13,336,815 | `b0b703f0489b7ecbacb3451a75009326bc368f13f10ae4ba2706dec457721517` |
| RJ1 | Rocketdyne R-3825-1, *J-2 Rocket Engine, Engine Data* (18 May 1967, Change 12, 18 Oct 1972) | https://archive.org/download/r-3825-1-j-2-rocket-engine-engine-data-18-may-1967-change-no.-12-18-oct-72/R-3825-1_J-2_ROCKET_ENGINE-ENGINE_DATA18_MAY_1967_CHANGE_NO.12_18-OCT-72.pdf | 11,615,261 | `d295d55f2f9b032f0a14bbf7c18cebb09bf280e8a87bfae0f42c3290c3ff5034` |
| RJ4 | Rocketdyne R-3825-4, *Illustrated Parts Breakdown, J-2 Rocket Engine* (23 Feb 1970; Fig. 56 at Change 4, 9 May 1972) | https://archive.org/download/r-3825-4-technical-manual-illustrated-parts-breakdown-j-2-rocket-engine-february-23-1970/R-3825-4_Technical_Manual_Illustrated_Parts_Breakdown_J-2_Rocket_Engine_FEBRUARY_23,1970.pdf | 11,169,728 | `0de897061b5475cf0610efadb905f0dcc87dce6a5ea23bc5f52acf5b224dc402` |
| NR | *Saturn V News Reference* (Aug 1967, changed Dec 1968): F-1 fact sheet PDF p. 47, J-2 fact sheet PDF p. 97 (a press reference: M at best) | https://archive.org/download/saturn-v-news-reference/saturn-v-news-reference_text.pdf | 10,807,793 | `d4f2397a32434bbf943d86da26747d04bed1601a56a06337c1119ca849b3fe76` |
| TMX1470 | NASA TM X-1470, Blaha, Wasko and Bresnahan, *Wind-Tunnel Investigation of Saturn S-IC Aerodynamic Engine Gimbal Forces and Base Pressures Using a Cold-Flow-Jet Simulation Technique* (NTRS 19670030895) | https://ntrs.nasa.gov/api/citations/19670030895/downloads/19670030895.pdf | 13,511,987 | `83bf4dbe75cac6d577349ae3cb3610ae428fe3bb7907a93fdad7c9806ecaf20e` |
| P64 | S. T. Peters (Rocketdyne), *Thermal Insulative Elastomers for Clustered Large Liquid Propellant Rocket Engines*, 7th SAMPE Symposium, May 1964 (NTRS 19650013319) | https://ntrs.nasa.gov/api/citations/19650013319/downloads/19650013319.pdf | 8,947,882 | `58f20b57f9be0f4b4280b72f8a4d0ae58d1b9e810581aeeaa90f6f448fbd242d` |
| TIS | MSFC S&E-ASTR-S-101-69, *Technical Information Summary, AS-506* | https://www.ibiblio.org/apollo/Documents/SE-ASTR-S-101-69-TechnicalInformationSummary-Apollo11-AS506-ApolloSaturnVSpaceVehicle.pdf | 4,166,492 | `802605552f06a004ce6857de45d52a6ed6ccd985d7538772c0a00c0dc119d43c` |

The two items that matter most predate AS-503: R1's envelope drawing (Aug 1967) and R6's cocoon figure (Mar 1968). D5 is Boeing's flight evaluation of AS-501 to AS-503, so it describes the insulation AS-503 flew.

### 8.1 F-1

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Gimbal centre to exit plane | 215.50 in (5.474 m) | R1 Fig. 2-22 "Engine Envelope Dimensions", printed p. 2-23, PDF p. 148 | H | 215.0 in (STA 100 to −115.0) | BCD's STA 100.00 and −115.36 give 215.36 in. All within 0.5 in. |
| Forward-most point | 14.50 in ahead of the gimbal centre (the turbopump inlet block's face); the main block's face 3.50 in ahead | R1 Fig. 2-22 | H | — | Overall length 230.00 in (19.17 ft), R1 §1-5's "19.2 feet". |
| Exit, outer envelope | 147.00 in diameter (3.734 m) | R1 Fig. 2-22 | H | 3.76 m envelope | Includes the extension's outer wall and bands. |
| Exit, gas side | 139.95 in (3.555 m, 9.924 m²) | *derived*: throat area 961.4 in² (R1 Fig. 3-13, printed p. 3-7, PDF p. 207, H) × 16 | H | `f1ExitArea` 10.10 m² (a performance fit) | Today's bell is drawn from `f1ExitArea`: 3.586 m across, 3 cm wider than the gas-side exit. NR's "maximum nozzle exit diameter" 11 ft 7 in (139 in) and TMX1470's 144.0 in outside diameter (p. 3, PDF p. 21) are other definitions of the same lip. |
| Throat | 34.99 in diameter (*derived* from 961.4 in²) | R1 Fig. 3-13 | H | from the 16:1 ratio | |
| Throat station | about 64-67 in aft of the gimbal | *scaled* off TMX1470 Fig. 2 (±4 %) | L | Rao bell, 30° convergent (`ApolloShapeData`) | |
| Expansion ratios | 10:1 at the end of the tube-wall chamber, 16:1 with the extension | R1 §1-4, Fig. 1-7; M504 p. 4-4 | H | 16:1 (M, recalled) | Today's grade rises to H. |
| Upper block (turbopump, LOX dome, valves, cocoon) | from 14.50 in ahead to 62.50 in aft of the gimbal; 103.24 in wide (51.62 each side); 75.75 in towards the turbopump side, 39.00 in towards the other; 12.00 in corner radii | R1 Fig. 2-22 side view and view B-B | H | — | An envelope, not a part outline. |
| Turbopump inlet block | an obround with 15.75 in end radii, centres 51.75 in apart, its centre line 50.00 in from the axis on the turbopump side | R1 Fig. 2-22 view B-B | H | — | |
| Section A-A (62.50 in aft) | a U-shape 60 in wide (30.00 in radius about the axis), 12.00 in corner radii on the turbopump side | R1 Fig. 2-22 | H (envelope) | — | Encloses the chamber below the upper block. |
| Turbine exhaust manifold | a CRES torus round the chamber's exit end, its section tapering from inlet to exit, 15 omega expansion joints; envelope corner radii 13.50 in (turbopump side) and 7.00 in (far side), so a section of about 27 in tapering to about 14 in; its aft face 150.00 in aft of the gimbal | R1 §1-18, printed p. 1-9A, PDF p. 36; Fig. 2-22 | H (construction, stations); M (section from the radii) | — | Its centre plane sits about 8 in further aft on the 6 o'clock side (*scaled*, M): the torus is tilted. |
| Nozzle extension | from the manifold's aft face (150.00 in, 125.00 in outer diameter) to the exit (215.50 in, 147.00 in): 65.5 in long, a 9.5° outer half-angle | R1 Fig. 2-22 (*derived*) | M | the bell's last part | Double-walled nickel-alloy walls on z-sections, CRES reinforcing bands round the outer wall, turbine exhaust injected through 23 rows of shingles; bolted on after the engine is in the stage (R1 §1-23, PDF p. 37, H). |
| Extension installation | the extensions and the insulation are fitted in the VAB; stages at Michoud and MSFC have neither | R1 §1-229 (PDF p. 112), §1-235 (PDF p. 113) | H | — | Photos of S-IC stages at the factory are not flight-configuration references. |
| Thermal insulation as flown (AS-501 to AS-503) | each engine enclosed in a "cocoon" of fibrous silica insulation in Inconel foil, except the nozzle extension, insulated with wire-reinforced asbestos | D5 §4, printed p. 4-3, PDF p. 65; D5 Fig. 4-15 (PDF p. 95, photo of the S-IC centre engine with its cocoon) | H | — | R1 §1-235 (PDF p. 113): the insulation is installed "to completely envelop the engine". |
| Insulation construction | foil-batt: random-fibre batting between textured Inconel foils (0.004 in inner, 0.006 in outer); asbestos blankets: 2-5 layers of Inconel-lockwire-reinforced asbestos cloth "coated on one side with aluminum", on the extension's exit end, over the LOX dome between the gimbal and the interface panel, and below the cocoon | R1 §1-105 to 1-108, PDF pp. 74-76; R6 §1-3 to 1-7, PDF p. 14 | H | — | R1/R6 put foil-batt on the extension's large areas and asbestos on its exit end; D5 says asbestos on the extension. For AS-503, D5 (the flight report) wins: M for the extension's exact covering. |
| Cocoon extent | from the thrust chamber's throat to the interface panel (the upper block) | R1 §1-106; R6 Fig. 1-1 (photo, PDF p. 15) | H | — | |
| Insulation thickness | **not found** as flown; a 1964 design figure, 0.375 (in) | P64 printed p. 17-6, PDF p. 7 | L | — | |
| Insulation mass | 1,188 lb (inboard), 1,198 lb (outboard) per engine, centred 77.5 in aft of the gimbal | R6 §4-3A, printed p. 4-2, PDF p. 84 | H | — | For mass properties, not shape. |
| Engine interface panel and curtain | the interface panel (stainless-steel casting, three sections) "provides the attachment point for the vehicle flexible heat-resistant curtain", which closes the gap to the S-IC heat shield | NR printed p. 3-7, PDF p. 55 | M | — | Sources the S-IC's engine curtains (§2.7). |
| Gimbal boot | silicone-impregnated fibreglass boot round the gimbal bearing | R1 §1-21, PDF p. 37 | H | — | |
| Pre-launch weather cover | an engine environmental cover from the throat to the extension exit, laced tight under the exit, fitted before rollout | R1 §1-235, PDF p. 113 | H | — | For rollout and pad views only (the red covers in NASA 6761894, AS-503 in the VAB). |
| Turbopump | 5 ft long, 4 ft in diameter (Mk-10) | R1 Fig. 1-16, printed p. 1-16, PDF p. 44 | H | — | |
| Turbopump axis | about 50 in from the engine axis on the 12 o'clock side, parallel to it, inlets forward | *inferred* from Fig. 2-22's inlet block | M | — | |
| Heat exchanger | 43 in diameter × 58 in long envelope; 40 in at the turbine outlet, 24 in at the manifold | R1 §1-72, printed p. 1-29, PDF p. 59 | H (size); L (position, on the turbopump side from about +62.5 to +123 in) | — | |
| Gas generator | 18 × 24 × 28 in envelope, on the No. 1 side | R1 §1-64, printed p. 1-25, PDF p. 54 | H (size) | — | Position not found. |
| Tube-wall chamber | 178 primary tubes (1-3/32 in OD Inconel-X) above the 3:1 plane, 356 secondary tubes (1 in OD) to 10:1, with reinforcing bands below the throat | R1 §1-15/1-16, printed p. 1-8, PDF p. 34 | H | — | Hidden by the insulation in flight. |
| Gimbal range | ±5.0° square pattern, 5°/s | M503 p. 4-7, PDF p. 64; M504 p. 4-7 | H | 5.0° (L, enginehistory) | TIS Fig. 25 says ±5.1°. Today's grade can rise to H. |
| Mounting and cant | outboard engines mounted parallel to the axis; they cant 2° outward on IU command once clear of the tower (AS-503: after 20 s) | A8PK printed p. -10-, PDF p. 12; D5 PDF p. 24 | H | gimbal-commanded cant (`AS506`) | No mounting cant: at lift-off the outboard F-1s are parallel. |
| Outboard radius | no printed number; 182.0 in from the fairing's axis (§2.3, M); TMX1470's model scales to 176-193 in (L) | ALM 1.9201; TMX1470 Figs. 4 and 9 | M | 182 in (L) | |
| Turbopump clocking within the cluster | **not found** | — | — | — | |

### 8.2 J-2

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Envelope | 80.75 in in diameter × 133 in long | RJ1 §1-9, printed p. 1-1, PDF p. 25 | H | 2.07 m envelope (81.5 in) | NR: 80.5 in and 11 ft 1 in. |
| Exit (inside, at the exit ring) | 77 in (1.9558 m) | RJ1 §1-16, printed p. 1-7, PDF p. 31 | H | `j2ExitArea` from 14.7 in at 27.5:1: 1.958 m | 2.6 mm apart: negligible. |
| Throat; chamber | 14.7 in throat; 18.3 in chamber; chamber body 107 in long | RJ1 §1-16 | H | 14.7 in (H) | |
| Area ratio | 27.5:1 (NR); geometric from 77/14.7: 27.44 | NR PDF p. 97; RJ1 §1-15 | H | 27.5 (H) | |
| Gimbal to exit | 116 in | `docs/AS506-datasheet.md` §13 (REF504 stations); corroborated by RJ1 Fig. 9-5 (printed p. 9-6, PDF p. 178): the exit closure's CG at +116.6 in | H | 116 in (M) | |
| Tube bundle | furnace-brazed stainless steel: 180 down tubes and 360 up tubes, held by bands | RJ1 §1-16 | H | — | VM2's "J-2 tubes(count)": 360 visible on the bell's lower part (the up tubes). |
| Fuel inlet manifold | round the chamber's middle, where the down tubes start; about 65 in aft of the gimbal and 61 in across (*scaled* off NR p. 97) | RJ1 §1-16; NR | H (description); L (station) | — | |
| Turbine exhaust manifold | tapered, round the chamber just above the fuel inlet manifold; exhaust leaves through "cat-eye" openings between the long tubes | RJ1 §1-16 | H | — | |
| Turbopumps | oxidizer 21 in diameter × 18 in; fuel 18 in diameter × 30 in (volute foam-insulated); on opposite sides of the chamber, axes about 21-22 in from the engine axis | RJ1 §1-21, §1-25 (PDF p. 35); positions *scaled* off NR p. 97 | H (sizes); L (positions) | — | |
| Heat exchanger; start tank | 14 in × 16.5 in; a 25.5 in sphere | RJ1 §1-55 (PDF p. 51), §1-63 (PDF p. 55) | H | — | |
| Gimbal bearing | about 10 in across × 6 in, on the injector dome | RJ1 §1-19, PDF p. 34 | H | — | |
| S-II engines' insulation | covers on the chamber's hat bands and stiffener rings aft of the heat shield; the main fuel valve, the electrical control assembly, the oxidizer turbine bypass valve, the oxidizer volute, valve, ducts and bleed line | RJ1 §1-140, printed p. 1-61, PDF p. 86 (Change 10, Feb 1971) | H (as of 1971) | — | Effectivity for S-II-3 and S-II-6 not checked: M for AS-503/506. |
| S-IVB engine's insulation | "the thrust chamber tubes, below the fuel inlet manifold, are insulated" (RJ4 Fig. 56: 7 rows of 14 panels, strapped) | RJ1 §1-141, PDF p. 86; RJ4 Fig. 56 sheet 4 | M | — | Whether S-IVB-503 and -506 carried it is not established. |
| S-II outboard circle; mounting | 17.5 ft diameter, outboard engines on the diagonals, mounted parallel to the stage centreline; ±7.0° gimbal pattern | M503 pp. 5-1, 5-5 (PDF pp. 86, 90) | H | 17.5 ft (M) | Today's grade can rise to H. |
| S-IVB gimbal | 7.0° square pattern | M504 p. 6-19, PDF p. 134 | H | 7.0° (M) | |
| S-II heat shield and curtains | heat shield's aft surface at S-II station 44 (STA 1608); curtain probes at S-II station 48, 56 in out on each outboard engine's azimuth and 76 in out 25° either side, so the curtains ring each outboard engine about 48 in from its axis | D5 Table 4-III (PDF p. 131, text layer), Table 4-IV (PDF p. 136, page image), Fig. 4-53 (PDF p. 135) | M | — | Fibreglass honeycomb (M503 p. 5-1). The curtains are fitted on the pad ("INSTALL S-II FLAME CURTAINS", M503 countdown chart, PDF p. 204). |

### 8.3 Colour and finish

No source read states a colour for either engine. Stated materials: the F-1's textured Inconel foil and aluminium-coated asbestos blankets (R1 §1-106/107), the extension under them nickel alloy with CRES bands (R1; NR: "high strength stainless steel"), the J-2's stainless-steel tubes (RJ1). VM2 takes tones from flight-era colour photos.

## 8a. VD1 values not found

- **Corrugation and stringer counts.** No primary source read here prints one. The S-IC forward skirt's 216 (M) and the intertank's about 108 (L) are derived above; the S-IC thrust structure, the interstages, the S-II skirts and the S-IVB skirts stay for VM2 to count on flight-era photos, each count with its photo ID (L). D5's S-II clue: stringer number 211 at θ 262° on the S-IC/S-II interstage.
- S-IC tunnel cross-sections; the S-IC LOX vent outlets' form; S-IC engine curtains.
- The S-II/S-IVB interstage retros' azimuths; the S-IVB tunnels' azimuths and extents; the APS modules' dimensions and station; the TX-280 case dimensions.
- Antenna sizes (S-II, S-IVB, IU).
- Engines (§8): the F-1 insulation's thickness as flown, any stated colour, a printed outboard radius, the throat station (L only), the LOX dome's size, the gas generator's position and the turbopumps' clocking in the cluster; the J-2 gas generator, its parts' dimensioned positions (scaled only), and whether S-IVB-503/506 carried the chamber-tube insulation.

---

# VD3: the CSM, LES, SLA and LTA-B

## Spacecraft conventions and sources

- **Stations.** Xa (in) as above. The AOH's local stations: Xc = Xa − 1000 (CM; Xc 0 = Xa 1000.000), Xs = Xa − 638 (SM; Xs 200 = Xa 838.000), XL = Xa − 1083.476 (LES; XL 0 is the LES/CM separation plane) (AOH Fig. 1-2, printed p. 1-5, PDF p. 16, H). The Mission Reports and TN D-5399 write CM stations as Xc = Xa (Xc 1000); the planes are the same.
- **Axes.** +Z_A is Position III and +Y_A Position II (`ApolloAxes`, `docs/AS506-datasheet.md` §12 from MSFC-MAN-506 Fig. 7-15; M503 Fig. 7-15, printed p. 7-17, PDF p. 166, draws the launch vehicle's yaw (Z) axis in the I-III plane). The CM's crew hatch is on −Z_A (AOH Figs. 1-4, 1-5), which is therefore Position I, the side that faces downrange and down during the heads-down ascent. Graded M: no spacecraft document read here ties ±Z_A to a launch-vehicle Position directly.
- **Vehicles.** The AOH Block II Vol. 1 (Apr 1969, changed Oct 1969) is written for CSM-104 onwards and covers CSM-101/103/107 except where a row names a difference.

| key | document | copy read | bytes | sha256 |
|---|---|---|---|---|
| AOH | SM2A-03-BLOCK II-(1), *Apollo Operations Handbook, Block II Spacecraft, Vol. 1: Spacecraft Description* (15 Apr 1969, changed 15 Oct 1969) | https://ibiblio.org/apollo/Documents/49176721-Apollo-Operations-Handbook-Block-II-Spacecraft-Volume-1.pdf | 48,809,979 | `58e7559644bdb24eb3ce3e692bb7060135a35f2909e53160c1b1b7aba076f891` |
| TRN | NAA S&ID, *Apollo Training: Structures and Mechanical Subsystems*, course A-512S (1 Apr 1966; Block I) | https://ibiblio.org/apollo/Documents/Apollo%20Training%20Structural%20and%20Mechanical%20Subsystems%200401196.pdf | 2,680,432 | `db56769e7383a2617c806d3a0faec9e09dd0fc91bbb148e0d45c63bf6440c82c` |
| FAM | SM2A-02, *Apollo Spacecraft Familiarization* (1 Dec 1966) | https://ibiblio.org/apollo/Documents/43940430-Apollo-Spacecraft-Familiarization-1-Dec-1966.pdf | 8,333,488 | `b898d091ad6cca58434919d7597b5e106be0de4140abba4d28c4719b48fba287` |
| CNR08, CNR15 | North American Rockwell, *CSM News Reference*, sections "LM & SLA Overview" (pp. 61-68) and "Launch Escape Subsystem" (pp. 137-146); facts only | https://www.apollojournals.org/alsj/CSM08_LM_%26_SLA_Overview_pp61-68.pdf ; https://www.apollojournals.org/alsj/CSM15_Launch_Escape_Subsystem_pp137-146.pdf | 830,248; 1,408,954 | `4d5c2a7f46698c63a5f3a3ca95a2b4dca2ff478c05b5208f86ab1bb77732d930`; `f2ea8d78bffd393be5cc57b5735f2818683aba257859dab0b1cf2686c5714ed3` |
| D7083 | N. A. Townsend, *Apollo Experience Report: Launch Escape Propulsion Subsystem*, NASA TN D-7083 (1973) | https://ntrs.nasa.gov/api/citations/19730010175/downloads/19730010175.pdf | 1,542,235 | `a791587760b2feb83528726e2d59c9dfbd6afe3eb14dc350ff25e0d14241eba2` |
| D5686 | W. C. Moseley Jr. and B. J. Wells, *Wind-Tunnel Investigation of the Aerodynamic Pressures on the Apollo Launch Escape Vehicle Configuration*, NASA TN D-5686 (Apr 1970) | https://ntrs.nasa.gov/api/citations/19700014969/downloads/19700014969.pdf | 4,844,144 | `9de4cfe673ff2283cbe3748db1d1fd23207d6c13a2ce75c441f9ee14ae0d2738` |
| FM160 | M. L. Williamson and C. W. Fraley, *SLA Panel Jettison Separation and Recontact Analysis*, MSC IN 68-FM-160 (3 Jul 1968) | https://ntrs.nasa.gov/api/citations/19700026553/downloads/19700026553.pdf | 4,349,308 | `bda6ebb846e0daa4137fb9e4322cafd89db5facffca6c8bc94123b848f765f5b` |
| A7MR | MSC-PA-R-68-15, *Apollo 7 Mission Report* | https://www.apollojournals.org/alsj/a410/A07_MissionReport.pdf | 8,768,701 | `c06d973032b9ca19eea672a96f97b195b0e0a21d1d32675b9cddb1c6f3ad529f` |
| FE503 | MPR-SAT-FE-69-1, *Saturn V Launch Vehicle Flight Evaluation Report AS-503 Apollo 8 Mission* (20 Feb 1969) | https://ntrs.nasa.gov/api/citations/19690015314/downloads/19690015314.pdf | 129,492,935 | `fe08ea2e1e623d2153fdf07207c70f2e3d9e09d1801d56f9f3c316fc152911a0` |
| AS08-16-2582, -2583, -2584 | Apollo 8 Hasselblad frames of the S-IVB with LTA-B after separation (AFJ high-resolution scans) | https://www.apollojournals.org/afj/ap08fj/photos/16-a/hr/as08-16-2582hr.jpg (and -2583, -2584) | 9,827,433; 10,379,757; 9,996,287 | `b8b702ed5b461a8973d35424b56040fd8ea1d27eda3c92d6a1b65d7f43e45ceb`; `f51a5ff3668b95e09f949f1ba88b92d0e441564e5dcf5fed290e28657831d182`; `a37000f3b887447ba63e6ee7dc1c84fd3b1526334dea6b38c664b5744d38ffdd` |
| AS07-03-1545 | Apollo 7 frame of the S-IVB with the SLA panels open | https://images-assets.nasa.gov/image/as07-03-1545/as07-03-1545~orig.jpg | 3,111,565 | `01e2a44519357c1aa57875166b69e4f8c6fc77e8769785f7dbb27d582b576f7a` |

## 9. Command module

*In progress.*

## 10. Service module

*In progress.*

## 11. Launch escape system and boost protective cover

### 11.1 LES stations (AOH Fig. 1-2; Xa = XL + 1083.476)

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| LES/CM separation plane (tower leg feet) | XL 0 = Xa 1083.476 | AOH Fig. 1-2, printed p. 1-5, PDF p. 16 | H | — (legs start on the CM's cone at 24 in radius) | BCD "vehicle separation" STA 3840.03 = Xa 1083.47. |
| Tower top, skirt base | XL 118.300 (Xa 1201.776) | AOH Fig. 1-2 | H | `lesMotorBottom` Xa 1207 (L) | BCD "bottom of LES skirt" Xa 1203.47 (1.7 in higher). Tower length 118.3 in; CNR15 p. 140: "10 feet". |
| Skirt top, motor case's aft end | XL 138.000 (Xa 1221.476) | AOH Fig. 1-2 | H | — | Skirt 19.7 in long. |
| LES motor's forward end, TJM's aft end | XL 283.000 (Xa 1366.476) | AOH Fig. 1-2 (station); TRN Fig. 2-2, p. 2-3, PDF p. 14 (identity, Block I) | H (station); M (what it marks) | `lesMotorTop` Xa 1430 (L) | Today's 1430 is likely BCD's "centerline launch escape motor" (Xa 1428.97), which lies in the canard section. |
| TJM forward end, canard section's aft ring | about XL 338.6 (Xa 1422.1) | *derived*: 283 + 55.62 (D7083 Table I) | M | — | |
| Canard surfaces | XL 339.6 to 386.5 (Xa 1423.1-1470.0) | TRN §2.4, p. 2-4, PDF p. 15 (Block I) | M | — | |
| Base of the 15° nose cone (ballast web) | XL 363.700 (Xa 1447.176) | AOH Fig. 1-2; BCD "base of canard nose cone" STA 4203.73 = Xa 1447.17 | H | — | |
| Q-ball base | about XL 387.5 (Xa 1471.0) | *derived*: tip − 13.275 in (CNR15 Fig. P-194) | M | `lesNoseLength` 13.37 in | |
| Tip | XL 400.762 (Xa 1484.238) | AOH Fig. 1-2; BCD STA 4240.79 | H | Xa ≈ 1484 | LES length from XL 0: 400.76 in (33.4 ft); A8PK p. -33- and CNR15 p. 137: "33 feet". |

### 11.2 Tower

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Attach points at the CM | four tower-leg wells in the forward heat shield, one stud and frangible nut per leg | AOH §1.3.1, p. 1-4 and Fig. 1-4 text p. 1-7 | H | — | |
| Base | the leg attach points form a 50.67 in (along Y) × 46.84 in (along Z) rectangle: legs 34.5 in from the axis, 42.75° from the Y axis | D5686 Table I(b), p. 6, and Fig. 2(f), p. 13 (full-scale dimensions of the T14 model) | M | `lesTowerBaseRadius` 24 in, legs at 45° (L) | CNR15 p. 140 and TRN §2.7: "about 4 feet square". Today's 24 in is half a 48 in side, not the leg radius. |
| Leg azimuths | 42°, 137°, 222°, 317° from +Y_A towards +Z_A (θ 132°, 227°, 312°, 47°) | TRN Fig. 3-3, p. 3-5, PDF p. 27 (Block I tower-support longerons) | M | 45° diagonals | Agrees with D5686's 42.75° within 1°. |
| Top | 36.06 in square at the escape motor (legs 25.5 in from the axis) | D5686 Fig. 2(f), Table I(b); CNR15 "about 3 feet square at the top" | M | `lesTowerTopRadius` 11 in (L) | |
| Leg tubes | 3.5 in OD, 0.125 in wall, 6Al-4V titanium | TRN §2.7, p. 2-14, PDF p. 20; CNR15 p. 142 ("2-1/2- and 3-1/2-inch diameter") | M | `lesTubeRadius` 1.5 in (L) | Radius 1.75 in. |
| Bracing tubes | 2.5 in OD (0.05 in wall; tube J 0.15 in, pure titanium) | TRN §2.7 | M | 1.5 in radius | Radius 1.25 in. |
| Covering | Buna-N rubber insulation over the tubes | CNR15 p. 142; AOH Fig. 2.9-7, PDF p. 413 | H (material) | — | Thickness not found. |
| Bracing pattern, each face from the top | an X-braced bay with a short horizontal at the crossing (J, about XL 88.6); a second X-braced bay ending at a full horizontal (M, about XL 59.7); a bay with one long diagonal and a half diagonal; a horizontal at XL 35.87 (P); an inverted V from P's middle to the leg joints at XL 12.85 | TRN Fig. 2-9, p. 2-15, PDF p. 20 (stations P and the leg joint printed; J and M *scaled*); AOH Fig. 1-2 shows the same pattern | M (pattern, P); L (J, M) | four plain legs | The two upper X bays are the "hour-glass" bracing adopted against motor-plume impingement (D5686 p. 3). |
| Tower mass | about 500 lb with attachments, wiring and insulation | CNR15 p. 140 | M | — | |

### 11.3 Skirt and motors

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Structural skirt | XL 118.3 to 138.0 (19.7 in); base about 53-55 in across (54.6 in on the E53 model, 52.73 in on E54), top 28.89 in (interface ring), flaring at 34-37° | AOH Fig. 1-2 (stations); D5686 Fig. 2(b), (c), Table I(c) | H (stations); M (diameters) | — | CNR15 p. 142: "31 inches in diameter". |
| Skirt construction and finish | 6Al-4V titanium, two ring frames, four longerons and skin panels; covered with Thermolag T-500 ablative 0.050 in, which "resembles a black tar" | TRN §2.6, pp. 2-13/2-14 (Block I) | M | — | A black skirt. |
| LES motor | 185.57 in long, 26.0 in case, 4,850 lb | D7083 Table I, p. 2, PDF p. 7 (page image re-read for this datasheet); CNR15 Fig. P-189 "26.0 DIA" | H | 183 in long (15 ft 3 in, recalled, L); 26 in (L) | Case XL 138-283 (Xa 1221.5-1366.5); its aft dome and nozzles hang inside the skirt and tower top, exits about XL 97 (Xa 1181) (*derived*, M). |
| LES motor nozzles | four, 90° apart, each canted 35° from the axis; exits 15 in across; 53.66 in envelope across the exits; unequal throats giving a 2.75° thrust offset | TRN §2.5.3, p. 2-13; CNR15 Fig. P-189 (35°, "15"); D7083 Table I (53.66 in), Fig. 1 (2.75°) | M (H for the envelope and offset) | — | |
| Tower jettison motor | 55.62 in long, 26 in in diameter (28.00 in envelope), 535 lb; two nozzles at 30° to the motor axis, about 4° resultant | D7083 Table I, Fig. 3 (p. 4), Fig. 1 | H | `towerJettisonTilt` 3.784° (H, TN D-6295) | The nozzles exit through a 30 in long interstage at the TJM's aft end, in the pitch (Z) plane (TRN §2.5.2, M). |
| Pitch control motor | 22.00 in long, 9 in case (10.51 in envelope), 51 lb; mounted across the LES axis in the canard section's aft compartment, nozzle flush with the skin on the −Z axis | D7083 Table I; TRN §2.4.3; FAM Fig. 3-2, p. 3-3, PDF p. 37 | H (size); M (placement) | — | Station not printed; BCD's Xa 1428.97 "centerline" is the likely axis (L). |

### 11.4 Canard section, ballast and Q-ball

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Section shape | a 26 in cylinder from the TJM's forward end (XL about 338.6) to XL 363.7, then a 15° half-angle cone to the Q-ball | AOH Fig. 1-2; CNR15 Fig. P-194; TMX Fig. 2 (nose 15°00′) | M | frustum from 26 in to the nose | A 26 in cylinder ending at XL 363.7 and a 15° cone reach 13.24 in across at XL 387.5: the Q-ball's 13.3 in base. One continuous cone. |
| Canards | two "100 degree arc segments" of the section's skin, about 4 ft long and 6 ft² each, about 1 in thick assembled, Inconel-X skins; each on two hinges | TRN §2.4, p. 2-4, PDF p. 15; CNR15 p. 139-141 | M | — | Stowed flush with the skin. Deployed (abort only, 11 s after an abort): each canard's centreline at 30° angle of attack, 160° sweep-back (TRN Fig. 2-6, PDF p. 17). |
| Canard azimuth | both on one half of the circumference, opening outward either side of one actuator | FAM Fig. 3-2 section views | L | — | Which half (+Z or −Z) not found. |
| Ballast | lead and depleted-uranium weights in the cone above XL 363 | CNR15 p. 143; TRN §2.4.2 | M | — | |
| Q-ball | 13.37 in long (CNR15 text; 13.275 in on its Fig. P-194), 13.3 in base, 15° half-angle, aluminium, eight static ports | CNR15 pp. 141, 143 | M | 13.37 × 13.3 in ("engineering history", L) | Tip radius 4 in (TRN §2.3) or 2.0 in (D5686 models): L. |

### 11.5 Boost protective cover

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Apex | Xc 135.13 (Xa 1135.13), at the tension-tie plug | AOH Fig. 2.9-8, p. 2.9-8, PDF p. 414 | H | the CM afterbody pushed out 1.5 in | The CM's structural apex is Xc 133.5 (AOH Fig. 1-2); BCD "top of boost cover" Xa 1133.47. |
| Hard/soft joint | Xc 81 (Xa 1081), a transition ring | AOH Fig. 1-4 Detail A, p. 1-7, PDF p. 18; Fig. 2.9-8 | H | — | 2.5 in below the LES/CM separation plane. |
| Aft edge | Xc 14 (Xa 1014): laminated fibreglass with a silicone sponge seal resting on the SM's fairing | AOH Fig. 1-4 Detail B | H | the BPC from the CM shoulder up | |
| Hard (upper) section | honeycomb-cored laminated fibreglass with a 0.3 in cork ablator, carried by the tower legs | AOH Fig. 1-4 Detail A; AOH §2.9.2.1, p. 2.9-5 | H | — | A8PK p. -33-: "glass, cloth and honeycomb". |
| Soft (lower) section | Teflon-impregnated glass cloth over the CM's ablator | AOH Fig. 1-4 Detail A | H | — | CNR15 p. 142: it fits "like a glove". |
| Openings | one 8 in window (over the commander's rendezvous window); a BPC hatch over the CM side hatch; ports for the CM's pitch, roll and yaw jets; a steam vent, static vents and an access door near the apex; "12 blow-out ports" | AOH Fig. 1-4, AOH p. 1-38 (hatch); CNR15 pp. 140-141 | H (window, hatch, labels); M (port count) | — | Positions as drawn on AOH Fig. 1-4 (−Z_A view). |
| Overall | about 11 ft tall, 13 ft in diameter, about 700 lb | CNR15 p. 142 | M | — | Xc 14 to 135.13 is 121.1 in (10.1 ft). |
| Stand-off from the CM | **not found** | — | — | 1.5 in (L) | The soft section lies on the ablator; the hard section stands off it by an unsourced gap. |
| Mass of the whole LES jettisoned, AS-503 | 8,890 lb (actual; 8,875 predicted) | FE503 Table 21-9, p. 21-11, PDF p. 490 | H | — | Its CG, Xa 1296.9 (*derived* from A8MR Table A.6-I's lift-off and orbit-insertion rows), agrees with `lesCenterOfMass` 1297.1 (M). |

## 12. Spacecraft-LM adapter (SLA)

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| Stations | Xa 502.000 (IU joint) to 838.000 (SM joint) | AOH Fig. 1-2; TMX Fig. 2 (STA 3258.555-3594.555); BCD | H | `iuTop`, `slaTop` | |
| Diameters | 260 in at the base, 154 in at the top; 8.97° half-angle (TMX: 8°58′) | A8PK p. -34-, PDF p. 51; CNR08 p. 65; TMX Fig. 2 | H | straight cone 260 → 154 in | |
| Panel hinge line (separation plane) | Xa 583.2 ("HINGE LINE XA = 583.2"); Xa 583.300 "separation plane" on Fig. 1-2 | AOH Figs. 2.9-6 (p. 2.9-6, PDF p. 412) and 2.9-10 (PDF p. 416); AOH Fig. 1-2; TRN §6.2.1; BCD "vehicle separation" STA 3340.05 = Xa 583.49 | H | `slaHinge` Xa 586 (M, Wikipedia) | The cone is 234.4 in across here (*derived*). |
| Panels | eight: four upper (about 21 ft) jettisoned on Apollo 8 and 11, four fixed lower (about 7 ft); each set four equal 90° panels | CNR08 pp. 66-67; TRN §6.2.1 (arc lengths 121/184 in and 184/204 in = quarter circumferences at 154, 234.4 and 260 in) | M | four upper quarter panels and one ring (H, 68-FM-160) | |
| Panel centres and seams | upper panels centred on +Y, −Y, +Z, −Z (strap-hinged at the middles of their aft edges), so the four longitudinal seams lie at 45°, 135°, 225°, 315° from +Y_A towards +Z_A (θ 135°, 225°, 315°, 45°) | TRN §6.3.6, p. 6-12, PDF p. 76 (the print repeats "−Z" where "−Y" is meant) | M | panels centred on ±Y_A, ±Z_A (68-FM-160, H) | The seams fall on the fin diagonals. |
| Panel numbering | 1 at +Z, 2 at −Z, 3 at +Y, 4 at −Y | FM160 §4.2, p. 4, PDF p. 10 | M | same | The report's own analysis convention; the Apollo 7 Mission Report names panels by axis ("the +Y panel"). |
| Hinges and jettison (Apollo 8 on) | two hinges per upper panel, disengaging at about 45°; two spring thrusters per panel; four ordnance thrusters at the top of the fixed panels; panels leave at 8 ft/s or more, at 110° ± 20° from the S-IVB's +X | CNR08 pp. 66-67; AOH Fig. 2.9-10; FM160 §3.1, p. 3, PDF p. 9; A8MR §A.3, p. A-12, PDF p. 277 (hinges redesigned, attenuators removed for Apollo 8) | H (A8MR, FM160); M | jettison as modelled (H) | |
| Apollo 7 (hinged, not jettisoned) | panels opened to about 45°; the +Y panel only to about 25-30° at first, all at about 45° by revolution 19; attenuators and retention cables held them | A7MR §11.7, p. 11-5, PDF p. 332; §8.1.3, p. 8-3 | H | — | For the CSM-101 scenario's SLA. |
| Pyrotechnic seams | 28 charge holders with two strands of detonating cord each, on the SM/SLA flange and on the splice plates joining the upper panels; splice plates 0.060 in aluminium | CNR08 p. 66; TRN §6.2.2 | M | — | Where P5's "SLA pyro seams" go. |
| Construction | 2024-T81 aluminium honeycomb sandwich, 1.7 in (CNR08, TRN), 1.75 in (A8PK) or 2 in (FAM, 1966) | as listed | M | — | |
| Cork | 0.03 in on the outer skin, new on Apollo 8 against aerodynamic heating | A8MR §A.3, p. A-12; CNR08 p. 66 | H | — | |
| Finish (photos) | outside white or light grey (cork); the upper panels' inner faces dark brown | AS07-03-1545; AS08-16-2584 | L | — | VD2 owns the colours. |
| LM attach points | four, at the joint between the upper and lower panels, on the panel-hinge axes (±Y, ±Z, Xa ≈ 583) | CNR08 p. 66; TRN §6.4, p. 6-16 | M | — | |
| Access doors | two in the upper panels, on +Z and −Z (Block I); Block II positions **not found** | TRN §6.2.2.1 | L | — | |
| Apollo 8's SLA | SLA-11A, LTA-B mated 29 Sep 1968 | FE503 Table 3-1, p. 3-3, PDF p. 82 | H | — | |
| SLA mass | 4,150 lb (A8PK), 4,050 lb (CNR08), 3,953 lb (*derived* from A8MR's mass table less LTA-B) | as listed | M | `ApolloCSM.slaPanels` + `slaRing` (AS-506 FER, H) | |

## 13. LTA-B (Apollo 8)

| item | value | source | grade | today | notes |
|---|---|---|---|---|---|
| What it was | "a structural test article … for Saturn V flight-load evaluation", instrumented for accelerations about three axes; "equivalent in weight to a lunar module … carried as ballast" | A8MR §A.5, p. A-14, PDF p. 279; A8PK p. -3- | H | the LM stand-in | What structure it was built from is **not found**. |
| Mass | 19,900 lb | A8MR §A.5 | H | — | SLA and LTA-B together 23,853 lb at Xa 590.4 (*derived* from A8MR Table A.6-I, M). |
| Mounting | at the four LM support points in the adapter; it stayed with the S-IVB | A8MR §A.3, p. A-12 | H | — | |
| Schematic | a squat drum low in the SLA with V struts to the SLA wall near the panel split; about 151-171 in wide and 126 in tall, from about Xa 509 to 635 | A8MR Fig. A.5-1, p. A-15, PDF p. 280 (*scaled*; the figure's two axes differ by 10 %) | L | — | |
| Shape in the photos | a white cylindrical drum; a broad white annular flange of segments round its forward face; an open forward face with a recessed deck crossed by a "#" grid of beams (two parallel beams each way, 3 × 3 bays, a round feature in the middle bay); hung on four V-strut pairs from the SLA's fixed-panel rim, about 90° apart; its lower part hidden in the SLA ring | AS08-16-2582 (end-on), -2583 (oblique), -2584 (side-on) | L | octagonal LM stand-in | The beam grid resembles the LM descent stage's paired main beams. |
| Diameter | about 160 in (147-171 in by method) | *estimate* from the three photos: (a) -2584 side-on, the S-IVB's 260 in silhouette against the flange ring, less 5 % perspective; (b) -2584, the ring's and SLA rim's ellipse major axes against the rim's 234.4 in; (c) -2582/-2583, the same ratio corrected for perspective | L | 2.1 m stowed radius (L) | |
| Forward face station | about Xa 630-655 (45-70 in above the hinge line) | *estimate* from -2584 (ring-to-rim offset along the axis, corrected for the ellipse's 0.565 axis ratio); A8MR Fig. A.5-1 gives about Xa 635 | L | — | |
| Particles round the stage | many bright particles in -2582 and -2583, attributed to S-IVB venting | A8MR p. 7-18, PDF p. 210 ("millions of particles created by S-IVB venting") | H (cause); L (look) | — | For P5's "fireflies" at CSM separation. |


---

## 14. Disagreements with today's code (for VG1-VG3)

Today's shapes are in `ApolloShapes.swift` and the stations in `AS506Data.swift`. "Missing" means the datasheet sources a feature today's model does not draw.

### VD1 (VG1, VG2)

1. **S-IC fins, fairings and base: missing.** Today the S-IC is one cylinder from STA 100 to 1541 plus five bells. The datasheet sources four fins (§2.4: 55.0 in tip chord at STA 81.277-136.277, root leading edge at STA 216.687, 139.3 in span, 30° sweep, 75.0 ft²), four half-cone fairings (§2.3: 100.0 in radius at STA 48.5, 15°, axes 182.0 in out, meeting the skin at STA 362.1), the base heat shield (top at STA 112.00), two tunnels near Positions I and III, and hold-down fittings at Positions I-IV (STA 113.31). The thrust structure's skin starts at STA 116.00, not at the gimbal plane: below it there are only the heat shield, the fairings, the fins and the engines.
2. **Fin span: today none; the design report's "about 63 ft (secondary, L)" is now sourced**: 63.0 ft (M503, rounded) and 62.7 ft (derived from the ALM sheets, M). `SaturnVExteriorTests` can pin the tip radius at 376.2 in with a tolerance that admits M503's 378 in.
3. **F-1 outboard radius 182 in: agrees** with the fairing's axis (ALM 1.9201, derived 182.0 in). Today's grade (L, fan wiki) can rise to M.
4. **S-IC retros: station and radius agree with the fairing geometry** (today STA 230, 5.25 m, L); the motors are 86 × 15.25 in (H), and their exhaust breaks out through the fairing's forward end, not a port.
5. **S-II thrust cone: misplaced.** Today a grey frustum from the J-2 gimbal plane (STA 1664, radius 0.6 × 198 = 118.8 in) to STA 1760 (198 in). Sourced: from XB 112 (STA 1676, about 108 in radius: "approximately 18 feet in diameter") to XB 223 (STA 1787), so its top is inside the aft skirt and its bottom 12 in higher than today's.
6. **S-II exterior: missing** the systems tunnel (22 in wide, semicircular, about 60 ft long, top at STA 2502.5), five LH2 feed-line fairings (STA 1722-2015.75; engine 1's and 4's at θ 44° and 314°), the aft/forward skirt boundaries (STA 1890, 2387) and the insulated LH2 tank wall between them.
7. **S-IC/S-II interstage: missing** the four ullage-motor fairings (Positions I-IV, bottom at STA 1563.56, top at STA 1710.6 or 1740.7: BCD's print disagrees with itself) and two ordnance fairings (θ 55° and 235°, STA 1568). Today's motors (STA 1608, 5.24 m) are consistent.
8. **S-II/S-IVB interstage: missing** the four retro fairings (fixed fairing plus a jettisonable nozzle cap; motors 104.68 in long, 9 in case, STA 2519-2633). Their azimuths are still unsourced (today's diagonals, L).
9. **S-IVB thrust structure: too long.** Today a frustum from the gimbal (STA 2645.85, 15.6 in radius) to the aft skirt's bottom (STA 2746.5, 91 in radius). M503 Fig. 6-1 (p. 6-2): an inverted truncated cone 5.2 ft (62 in) tall from the engine mount to the LOX tank's aft dome, so its large end is near STA 2708 on the dome, whose bottom hangs below the aft skirt (the LOX tank's lowest point is STA 2702, `docs/AS506-datasheet.md` §13). Below the skirt one sees the dome, the cone with its helium spheres and plumbing (M503 p. 6-1), and the J-2. The cone's large-end radius is not given.
10. **S-IVB APS modules: form only.** Today 1.8 m cylinders of 0.35 m radius at STA 2774.7. M503 Fig. 6-14 shows a long faired module with a rounded nose; no dimensions found, so VG2 keeps an L estimate (from photos, say which).
11. **S-IVB ullage fairings, tunnels, antennas: placement agrees or is new.** The TX-280 fairings near the fin D and fin B diagonals (towards Positions IV and II) agree with today's "II-III and IV-I diagonals". New: two tunnels, the telemetry antennas at STA 3193.56 (θ about 79° and 259°), the vents and fill line fairing.
12. **IU: missing** its doors (umbilical and access, between Positions I and II) and antennas; stations agree.
13. **Datum: 0.36 in.** The F-1 exit is STA −115.36 (BCD), today −115; the tip STA 4240.79 (BCD), today 4241.0 (from 363 ft). Both within a centimetre.
14. **F-1 shape: generic.** Today each F-1 is a Rao bell from the exit (radius from `f1ExitArea`, 10.10 m², 3.586 m across) to the gimbal, 215.0 in. Sourced (§8.1): gimbal to exit 215.50 in; a tube-wall chamber to 10:1, the turbine exhaust manifold torus with its aft face at 150.00 in, then the 65.5 in extension from 125.00 in to 147.00 in outer diameter (gas-side exit 139.95 in); an upper block (turbopump, dome, valves) from 14.50 in ahead to 62.50 in aft of the gimbal, 103.24 in wide; and, as flown, the whole engine wrapped in the foil cocoon and asbestos blankets. VG1 should size the exit from the geometry (3.555 m gas side, 3.734 m outer), not from the performance-fitted `f1ExitArea`.
15. **J-2 envelope: 2 cm large.** Today 2.07 m; RJ1 80.75 in (2.051 m). The exit (77 in) agrees with today's 1.958 m within 3 mm.
16. **Grades that can rise.** `f1AreaRatio` 16 (recalled, M) is H (R1, M504); the F-1 gimbal range 5.0° (L) is H (M503); `sIIOutboardCircle` 17.5 ft (M) is H (M503); `f1OutboardRadius` 182 in (L) is M (the fairing's axis).

### VD3 (VG3)

*CM and SM rows follow with §9 and §10.*

1. **SLA hinge line: 2.8 in low in the sources.** Xa 583.2 (AOH Figs. 2.9-6, 2.9-10), 583.3 (AOH Fig. 1-2), 583.49 (BCD) against today's `slaHinge` Xa 586 (Wikipedia). Use 583.2.
2. **LES tower: too narrow and too thin.** Today the legs run from 24 in out on the CM's cone to 11 in out at the motor, on the 45° diagonals, 1.5 in tubes, no bracing. Sourced: feet at XL 0 (Xa 1083.48) on a 50.67 × 46.84 in rectangle (34.5 in out, 42.75° from Y), top at XL 118.3 on a 36.06 in square (25.5 in out); legs 3.5 in, braces 2.5 in OD; two hour-glass X bays, a diagonal bay and an inverted V (§11.2).
3. **LES motors: misplaced.** Today one 26 in frustum from Xa 1207 to 1430 and a taper to the nose. Sourced: skirt Xa 1201.8-1221.5 (black ablative); LES motor case Xa 1221.5-1366.5 with four 35° nozzles (15 in exits) hanging into the skirt; TJM Xa 1366.5-1422.1 with two 30° nozzles; canard section's 26 in cylinder to Xa 1447.2, then one 15° cone through the Q-ball to the tip at Xa 1484.24 (§11.1, §11.3, §11.4). Today's top at 1430 seems to come from BCD's "centerline launch escape motor" (Xa 1428.97), which is not the motor's end.
4. **LES motor length:** 185.57 in (D7083, H) against today's recalled 15 ft 3 in.
5. **Canards and pitch control motor: missing.** Two 100° arc-segment canards, Xa 1423-1470, flush when stowed; the pitch control motor's nozzle flush on −Z_A.
6. **BPC: shape about right, ends sourced.** Aft edge Xc 14 (Xa 1014) on the SM fairing, hard/soft joint Xc 81, apex Xc 135.13. Today's shell starts at the CM shoulder's widest point and stands 1.5 in off everywhere (stand-off still unsourced, L).
7. **LTA-B: missing.** Today the Apollo 8 payload would draw the LM stand-in. Sourced: a 19,900 lb drum about 160 in across (L), forward face about Xa 630-655 (L), a segmented flange and an open "#"-beamed deck, on four V-strut pairs from the SLA rim at about Xa 583 (§13).
8. **SLA seams: agree.** Today's four quarter panels centred on ±Y_A/±Z_A put the seams on the diagonals, as TRN describes. New: the 28 pyro charge holders on the seams and the SM/SLA flange, the 0.03 in cork, and Apollo 7's 45° (+Y: 25-30°) open panels for CSM-101.

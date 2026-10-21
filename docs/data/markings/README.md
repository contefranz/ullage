# Saturn V and CSM paint and markings (M1.6 VD2)

Compiled on 2026-10-21 for M1.6 track VD2 (docs/m16/plan.md, "VD1, VD2, VD3: exterior data"; design in docs/m16/design-vehicle-look.md §4). These tables say what is painted where on AS-503 (Apollo 8), AS-506 (Apollo 11), CSM-101, CSM-103 and CSM-107, then AS-501 and AS-502. VM1 builds its paint regions and decals from them, one per row, and its tests read the probe rows. Geometry (stations of joints, fairings, fins, antennas) is VD1's and VD3's, in docs/SaturnV-CSM-exterior-datasheet.md; these tables cite it where a paint boundary sits on a joint.

## Files

| file | content |
|---|---|
| `as503.csv` | AS-503 as flown, the best-documented vehicle: two registered photos (west and east faces) and the in-flight S-IVB frames |
| `as506.csv` | AS-506 as flown: one registered photo (south-west face) and several unregistered ones; where nothing shows, rows follow AS-503 and say so |
| `as501.csv`, `as502.csv` | AS-501 and AS-502, markings rows only (owner decision 8), from unregistered photos |
| `csm.csv` | CSM-101, CSM-103 and CSM-107 (SM, CM), their SLA, BPC and LES, and Apollo 8's LTA-B |
| `photo_index.csv` | every photo cited: ID, vehicle, date, which side faces the camera, what it shows, what it was used for, where it is published |
| `digitised/*.json` | photo registrations: the reference points and measured points, in the pixel coordinates of the named copy (its sha256 is recorded) |
| `digitised/*.out.csv` | `tools/digitise_photo.py`'s output for each registration: the fitted camera, the residual of every reference, and every point's station and azimuth with its 1 px spread |

Photos are not in the repo. Each registration names its copy (URL, size, sha256), so the measurements can be repeated.

## Conventions

- **Stations** (`frame`): `STA`, the Saturn V vehicle station in inches (the F-1 gimbal plane is STA 100), or `Xa`, the Apollo spacecraft station in inches; STA = Xa + 2756.56 (VD1/VD3 datasheet).
- **Azimuth** (`az_from`, `az_to`, degrees): from Position I towards Position II, anticlockwise seen from the nose, as the datasheet's θ: Position I 0, II 90, III 180, IV 270; fins A 45, B 135, C 225, D 315. On the pad Position I faces east (downrange), II the LUT (north), III west and IV south. Seen from outside with the nose up, azimuth grows to the right. `az_from > az_to` means the range wraps through 0 (357 to 3 is 6°). For the spacecraft θ = θ_A + 90, θ_A from +Y_A towards +Z_A.
- **Kinds**:
  - `base`: an element's overall paint or finish;
  - `region`: a patch of paint, a station range by an azimuth range on the element's outer surface (`params` `face=inner` for an inner skin);
  - `decal`: lettering, a flag, a plate or a stencil inside the given box;
  - `probe`: a point (sta_from = sta_to, az_from = az_to) with the colour expected there, for VM1's evaluator tests and `orbitsnap --verify`. Probes sit at least 5° and 15 in from any boundary.
- **Paint order**: rows are listed in painting order; where two rows overlap, the later one wins (VM1's "last match wins"). On the Saturn V a row applies by station to whatever surface lies there (`element` only names it); on the spacecraft (`Xa` rows) a row applies to its own element's shapes, since the BPC and the SLA's panels cover other parts at the same stations.
- **Paint names** (`paint`): `white`, `black`, `red` (the lettering), `flag` (an EO 10834 flag), `aluminium` (bare metal), `kapton` (aluminised Kapton tape), `zinc chromate`, `dark brown`. `params` adds finish details as `key=value` pairs separated by `;`.
- **Decal parameters**: `text`, `letters=upright stacked top to bottom` (the Saturn's vertical lettering: upright capitals, one under another), `letter_h` and `letter_w` (in), `pitch` (in, top of one letter to the top of the next), `word_gap` (in, between the D and the S), `lines` (the SM's two-line lettering), `union=upper hoist` and `hoist=low azimuth` (the flag's union is at the top on the side of lower azimuth, the left as seen from outside), `hoist_in`, `fly_deg` or `fly_in`. Measured letter boxes come from the registrations; VM1's stroke font should fit them.
- **`copies`**: a row that stands for several identical items lists each one's azimuth range (`from-to`, separated by `/`); the row's own `az_from`/`az_to` are the first copy's.
- **Columns** `photos` (`;`-separated, all in `photo_index.csv`) and `sources` (documents, keys below) give the evidence, `note` how it was read.

## Grades

As the datasheets grade them (owner decision 10: boundaries within ±0.25 m in station and ±3° in azimuth of the digitised photos):

- **H**: two or more registered photos agree within that tolerance, or a primary document states it and a photo shows it.
- **M**: one registered photo; or photos read by eye that agree with a registered one; or a boundary placed on a sourced joint whose position the photos confirm.
- **L**: by symmetry or by analogy with another face or vehicle, a secondary source only, a feature not resolved in the photos, or sources that disagree. Franz rules on these at CP2 (owner decision 12).

## How the photos were registered

`tools/digitise_photo.py` fits a pinhole camera (distance, height, viewing azimuth, pan, tilt, roll, scale) to reference points on the vehicle treated as a solid of revolution (radius 198 in to STA 2519, then the S-II/S-IVB interstage's cone to 130 in), then intersects the ray through each measured pixel with that surface. The references are silhouette edges at known radius, structural joints of known station (the white separation ridges at STA 1564 and 1760, the intertank's corrugation edges at 628.8 and 885.2, the thrust structure's top at 345.7, the silhouette's corners at 2519 and 2746.5) and features of known azimuth. `--selftest` checks it on synthetic near and far cameras (0.07 in, 0.015°). Pixel positions were read with an edge finder (luminance steps, the blue-minus-red step against the sky, red-minus-blue for the red letters) on crops of the full-resolution copies.

| photo | vehicle | faces the camera | azimuth references | fit |
|---|---|---|---|---|
| S68-55424 | AS-503 | Position III (178.8°) | the Position III plate on the thrust structure; the S-IVB's APS module (Position III, MSFC-MAN-503 Fig. 6-14): structural, not paint | 2.1 px rms; joints within 0.1-3.6 in; azimuth references within 0.5 and 1.5° |
| S68-49405 | AS-503 | Position I (6.6°) | the S-IC stripe edges at 315, 0 and 45°, as S68-55424 found them at 135.6, 180.6 and 224.0° | 1.1 px rms |
| KSC-69P-397 | AS-506 | 254.9° | the S-IC stripe edges at 225, 270 and 315°, assumed as on AS-503 | 1.0 px rms |

AS-503's stripe azimuths therefore rest on structure (S68-55424), and the other two photos on the stripes. AS-506's azimuths are only as good as the assumption that its stripes are AS-503's; its flags, USA and UNITED STATES then fall exactly where AS-503's do, which supports it.

## What the tables say (summary)

- **The roll pattern is four-fold.** Each quarter from a Position to the next fin (0-45, 90-135, 180-225, 270-315°) is black on the S-IC from the base to the intertank's bottom (STA 628.8), and again from the S-IC forward skirt (1420.3) over the S-IC/S-II interstage to the S-II aft skirt's division (1847). The quarters from a fin to the next Position are white. Measured edges fall on the Position and fin lines within 1°. The intertank and LOX tank are white on AS-503 and AS-506. Fins and engine fairings straddle the stripe edges on the fin planes: each face takes the colour of the sector it faces (S68-55424: fin B's face toward 135-180° white, fin C's toward 180-225° black).
- **White ridges** at the two separation planes (1564, 1760) cross the black.
- **Caps**: on the S-II aft skirt a black band from STA 1795 to 1847 covers the white sectors as well, from the white LH2 feed-line fairing on each fin line to the next Position, so that black runs all round there except at the four white fairings. On AS-503 the cap is missing over the C sector (225-258°, all that is visible); AS-506 has one there from 246° (L, disputed).
- **White fairings**: the S-II ullage-motor fairings sit about 16 in (4-5°) anticlockwise of each fin line on the interstage, and the LH2 feed-line fairings on the fin lines on the aft skirt, both white over the black.
- **S-II/S-IVB interstage**: quadrant A (0-90°) black, B upper half black, C lower half black, D white; the split at the interstage's mid-length (STA 2632.75). The S-II retro fairing on fin A shows white in quadrant A's black, so the retros sit on the fin diagonals (VD1 found no azimuth).
- **IU band**: the whole IU and the upper part of the S-IVB's forward skirt are black all round, STA about 3155 to 3258.56 (the IU/SLA joint); AS08-16-2584 shows it in flight.
- **Lettering and flags on the Saturn V** (all red letters, A8PK's "huge red lettering"):
  - USA in each white sector of the lower S-IC, centred on it (67.5, 157.5, 247.5, 337.5°), letters upright and stacked, about 57 in tall and 44 in wide, top STA about 594, foot about 372;
  - a US flag on the LOX tank in each white sector, from 2-3° past the fin line (hoist) to the Position line (fly), STA about 1118-1199, union at the upper hoist;
  - UNITED STATES on the S-II tank centred on each black sector (22.5, 112.5, 202.5, 292.5°), letters about 31 in tall at a 35 in pitch, top about STA 2377, foot about 1921.
- **SM lettering**: CSM-101 and CSM-107 carry UNITED STATES in black on a white field with a flag below it, just under the CM/SM fairing, centred on the radial beam at θ 132.75° (between RCS quads B and C); not seen on CSM-103 (L).
- **Finishes**: SLA and BPC white; LES tower and motors white with a dark Q-ball tip (one photo); CM aluminised Kapton tape; SM bare aluminium with white radiator paint (D6863).

## Disputed and low-graded rows (for Franz at CP2)

- The S-II aft skirt cap over the C sector: none on AS-503 (503-033), from 246° on AS-506 (506-033).
- The CM/SM fairing and the lower SM band look tan with vertical ribs in the KSC photos of CSM-101 and CSM-107, against D6863's white radiator paint (101-002/003, 107-002/003).
- The LES structural skirt looks white on Apollo 11 against the Block I manual's black ablative coating (107-032).
- The interstages' inner skins: zinc chromate is the design report's, not sourced here (503-090/091).
- CSM-101's lettering azimuth (by CSM-107's) and all of CSM-103's lettering (not seen).
- The AS-501/502 intertank repaint and tone line (501-011/012, 502-011), and AS-502's flags (frost at launch).
- AS-506's rows marked "as AS-503", and the sectors no photo shows (USA A/B, UNITED STATES B, the AS-503 C-sector ullage fairing).

## Findings for other tracks

- **VD1/VG1 (S-II ullage motors)**: on AS-503 the white ullage-motor fairings sit about 4-5° anticlockwise of fins A, B and D (503-050/051/053, M), not at Positions I-IV as AS506Data.swift's comment on the S-II ullage motors and the datasheet's reading of M503 Fig. 5-2 have them. Oikofuge reports the same 16 in offset.
- **VD1/VG2 (S-II retros)**: a white retro fairing on the fin A line at STA 2583-2626 (503-064, M) confirms the diagonals.
- **VM1/LC (pad)**: Position II faces the LUT; the Saturn's Position plates sit on the thrust structure at the stripe edges, STA about 373-402.

## Not included

- The S-IC's drain labels (Oikofuge, secondary) and the interstage sway targets (2x2 checkerboards): not resolved in any photo read.
- The fin letters (seen on B and C, S68-55424) and the stage stencils (S-IC-3, S-IC-6): too small to place; noted in 503-130/506-140 only.
- The F-1 insulation, J-2 tube bundles, SPS nozzle bands and other materials: VM2's and VD1/VD3's.
- Optical properties (α, ε) of the flown coatings: in the VD3 datasheet (§9.3, §10, from D7564 and D6863).

## Sources

| key | document | copy read | sha256 |
|---|---|---|---|
| A8PK | NASA Release 68-208, *Apollo 8 Press Kit* (6 Dec 1968): printed p. -38- (PDF p. 59), the launch vehicle's paint | https://www.nasa.gov/wp-content/uploads/static/apollo50th/pdf/A08_PressKit.pdf | `fb5ba158821c989460f1a84c8efa85d459988529409585d78967f758b4462947` |
| M503 | MSFC-MAN-503, *Saturn V Flight Manual SA-503*: Fig. 6-14 (PDF p. 137, the APS module at Position I), p. 5-24 (ullage motors), p. 5-26 (retros) | https://ntrs.nasa.gov/api/citations/19750063889/downloads/19750063889.pdf | `7465652b07306f45d2450f6a50bc52ee9c2a257522bbfc86c14bb9d1a006a967` |
| BCD | Boeing, *Saturn V Apollo Flight Configuration* (1 Mar 1967), NASA image 9253429: the joints' stations | https://images-assets.nasa.gov/image/9253429/9253429~orig.jpg | `59763ffb44c335111dea762068449f6922a90d93b4817222f85585dddc204143` |
| D5 | Boeing D5-15796-1 (19 Jun 1969): feed-line fairing azimuths, ullage-motor count; cited through the VD1/VD3 datasheet | NTRS 20160013592 | (datasheet) |
| D7564, D6863, A8MR, AOH | thermal-control tape, coatings' α/ε, the SLA's cork, the SM's radiators and beams; cited through the VD1/VD3 datasheet §9-§13 | see the datasheet | (datasheet) |
| EO 10834 | Executive Order 10834 (1959): the flag's proportions | https://www.archives.gov/federal-register/codification/executive-order/10834.html | — |
| Oikofuge | Oikofuge, "The Coordinate Axes Of Apollo-Saturn: Part 1" and the Revell 1/96 Saturn V build notes (secondary: pad orientation, the pattern's rule, ullage-motor offset) | https://oikofuge.com/coordinate-axes-apollo-saturn-1/ | — |
| rocketryforum | "Saturn V roll patterns" thread (secondary: AS-501/502 repaint, AS-506 built white) | https://www.rocketryforum.com/threads/saturn-v-roll-patterns.150541/ | — |

Secondary sources are used for facts only, and every row that rests on one alone is graded L.

## Reproducing

```sh
# a photo (any of photo_index.csv's published_at), e.g. S68-55424:
curl -sLO https://images-assets.nasa.gov/image/S68-55424/S68-55424~orig.jpg
shasum -a 256 S68-55424~orig.jpg      # must match digitised/S68-55424.json's copy
python3 -I tools/digitise_photo.py docs/data/markings/digitised/S68-55424.json   # reproduces digitised/S68-55424.out.csv
python3 -I tools/digitise_photo.py --selftest
```

To add a measurement, add a point (pixel coordinates in the named copy) to a registration's `points` and rerun; to register a new photo, copy a registration and replace its references (at least two joints of known station, the limbs at two heights or more, one feature of known azimuth).

## Licensing

NASA photographs and documents are US government works in the public domain; they are cited, not copied. Contractor documents and secondary sources are used for facts only. No NASA insignia appear on the flown Saturn V or CSM markings tabled here.

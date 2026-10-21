# M1.6/M2 design: Saturn V and CSM exterior look

> Planning document for the M1.5 close-out, milestone M1.6 (graphics overhaul) and M2 (Apollo 8), written on 2026-10-20 by a design study (six design reports checked by a planner) and accepted by Franz on 2026-10-21 with all recommended defaults (US keyboard). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

GEOMETRY CORE (pure Swift, Linux-tested)
- Shape kinds and vertex data:
  - /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/VisualShape.swift:7-19 has three kinds: frustum, sphere, and a lathe `.revolution` with sweep and creases.
  - A shape carries one linear-RGB colour (:59) and an EmissiveRole (:35-40, only `heatShield`).
  - Vertex is position + normal only (:42-46): no surface coordinates, tangent or material.
  - `triangles()` (:124-150) emits a non-indexed triangle list; the lathe is :153-208.
- Dressing, in /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes.swift:
  - ApolloShapeData (:10-124) holds dimensions with H/M/L grades. Many are L estimates: the LES (:109-124), the LM envelope (:98-107), the RCS housings (:52-56) and the apex cover/tunnel (:81-87).
  - CMOuterMouldLine (:128-187) is good: TM X-1243.
  - `dressApollo` (:198-205) dresses by part name only. There are no vehicle variants, so Apollo 7's CSM-101 (ApolloCSM.swift:382) is dressed exactly like CSM-107.
  - Ten flat colours (:225-228).
- What each element is today:
  - S-IC: one plain cylinder plus five open Rao bells (:292-294). No fins, engine fairings, tunnels, heat shield or F-1 flight hardware.
  - Interstages: open frustums.
  - S-II: cylinder plus a grey thrust cone (:297-301).
  - S-IVB: cylinder plus a J-2 cone (:304-309); APS modules are plain cylinders (:350-355); ullage fairings are two frustums (:310-316).
  - IU: an open grey ring (:317).
  - SLA: a ring plus four quarter-sweep panels (:357-381).
  - LM: an octagonal stand-in (:385-396).
  - SM: a cylinder, the SPS bell, and RCS quads as 4-sided faceted boxes with 16 nozzles (:398-455).
  - CM: an emissive heat shield and a silver afterbody/tunnel (:457-476); apex cover at :479-488.
  - LES: a BPC shell, four tube legs, and motor/nose frustums (:503-531). No canards, structural skirt or cross-bracing.

RENDERER (Mac only)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Meshes.swift:15-131 (VesselMesh):
  - The whole vessel is one non-indexed buffer, rebuilt when the part list changes (signature :45-47; Renderer.swift:341-342). Every staging event re-tessellates the whole remaining stack.
  - Groups are closed (culled), open (two-sided) and per-gimballed-thruster.
- RenderTypes.swift:21-26: MeshVertex is position/normal/color float4, with the emissive role in color.w.
- Shaders.swift:186-198 mesh_fragment: Lambert from the Sun × eclipse fraction, plus earthshine, plus an ambient floor, plus the heat-shield glow.
  - No specular, no textures on vessels, no tangent space.
  - Textures exist only for user-supplied planet maps (Renderer.swift:170-194).
- Render target (Renderer.swift:62-75): LDR bgra8Unorm_srgb, depth32Float, MSAA 4×. No tonemapping.
- Vessel drawing is inline in Renderer.swift step 3 (:331-381).
- Precedent for an offscreen gallery: NavballRenderer.swift:210-257 (renderToImage) driven by ORBITSIM_NAVBALL_GALLERY (NavballView.swift:25-28).
- The scratch flight harness with screencapture (project memory) works for in-flight shots.
- Package.swift has no app test target.

DATA ALREADY IN CORE
- AS506Data.swift:869-925 holds stations and diameters:
  - Interfaces are H.
  - SLA top, SM/CM, SPS gimbal and exit, SM RCS station, LES and LM envelope are L.
  - Datasheet §6 (docs/AS506-datasheet.md:504) leaves the fin span open.
- FER Table 20-1 frost masses (AS506Data.swift:411-421): S-IC 635 → 340 kg, S-II 204 kg, S-IVB 90 kg, all gone by CECO.
- Vessel.heatLoad (Vessel.swift:136) and heatFlux already exist. They can drive post-entry char.

TESTS
- Tests/OrbitCoreTests/VisualShapeTests.swift (344 lines) checks:
  - every part is dressed;
  - nozzle links;
  - bell exit radii;
  - the CM profile;
  - hard-coded shape counts (SM `1 + 1 + 4 + 16`), which will change.

## Design

0. TARGET (what "finished" means)
The vehicle must look right at three distances, under the lighting area's sun, earthshine and environment.
- Pad and launch wide shots (the stack is about 110 m on screen):
  - true silhouette: fins, engine fairings, tunnels, LES truss and canards;
  - roll pattern, red lettering, flags;
  - pad frost.
- Staging and chase shots (10-30 m):
  - skirt corrugations and stringers;
  - ullage and retro fairings, APS modules, umbilical plates;
  - interstage interiors;
  - F-1 and J-2 engines in flight configuration.
- CSM close-up (2-10 m):
  - the CM: Kapton crinkle, windows, hatch, RCS ports;
  - the SM: RCS quads, radiators, HGA, SPS nozzle bands;
  - the LES and BPC detail.
Rule of thumb:
- Features of 5 cm or more are geometry.
- Features under 5 cm are shader relief or decals.
Explicit exclusions:
- interiors other than interstage and skirt inner skins;
- cables and individual rivets beyond procedural rows;
- the LM (a later milestone);
- the pad and LUT (another area).

1. VEHICLE VARIANTS (core)
New file Sources/OrbitCore/Vessel/ApolloVariant.swift:
```
public struct ApolloVariant: Equatable {
  launchVehicle: .as501 | .as502 | .as503 | .as506
  csm:           .csm101 | .csm103 | .csm107
  payload:       .none | .ltaB | .lm(5)
}
static let apollo8, apollo11, apollo7
```
- It goes on VesselPart as `public var appearance: ApolloVariant?`. This is a one-line seam in Components.swift, near :636.
- Parts carry it through `Vessel.separate`, so a re-dress after a split keeps CSM-103 as CSM-103.
- `dressApollo(_:)` reads it, defaulting to apollo11 for today's builders.
- Apollo 8's payload part keeps the contract name "LM", and the dresser draws LTA-B from the variant. The IU program and separation code keep working by name.
- Switches the variants drive:
  - S-II ullage fairings: 8 on AS-501/502, 4 on AS-503 to AS-509 (Apollo 8 press kit: four on the interstage, H).
  - Intertank repaint tone: AS-501/502 have a visible repaint line.
  - HGA: CSM-103 and CSM-107 have one, CSM-101 does not.
  - Docking probe: CSM-107 only. CSM-103 flew no probe (M-L; covered by the BPC at launch anyway).
  - EVA handrails and docking lights: CSM-104 and later (L, to verify).
  - LTA-B versus LM.
  - Per-vehicle markings tables.

2. GEOMETRY API (core, VisualShape.swift)

(a) Surface coordinates and tangents on every vertex
- `Vertex` gains `surface: (u, v, s, r)`:
  - u: construction-frame station in metres along the vehicle axis, which converts straight to STA;
  - v: azimuth in radians from Position I towards Position II;
  - s: profile arc length;
  - r: local radius, so v·r is arc length in metres.
- It also gains a unit `tangent` along increasing v.
- The lathe already has azimuth and profile, so emitting these is trivial.
- Off-axis shapes (fairings, tunnels, quads, engines, LES legs) set `frame = .local`, so u/v are the shape's own axis and azimuth.
- Convention: Position III is +Z_A = −z (ApolloAxes.swift:3-6), so Position I is +z. The II/IV sign is pinned by a test against the APS modules (Positions I and III) and the fins A-D on the diagonals (datasheet §4).

(b) New kinds
- `.prism(section: [(y, z)], from: x0, to: x1, taperEnds:)`, extruded along the axis: tunnels, umbilical plates, radiator bands, the SM/CM fairing.
- `.plate(outline: [(x, y)], thickness, bevel)`: fins, canards, HGA struts.
- `.torus(major, minor)`: the F-1 turbine exhaust manifold, the LES skirt ring.
- `.box`: RCS quad housings, APS module bodies, ballast blocks.

(c) Appearance per shape
- `material: SurfaceMaterial`, `paint: Paint?`, `details: [SurfaceDetail]`, `decals: [Decal]`. All are value types in a new folder, Sources/OrbitCore/Vessel/Appearance/.
- `part.attachments: [VisualAttachment(name, position, direction, kind)]`, kind being retroPort, ullageExit, lox vent, separation plane or frost-shed zone. These are the hand-off points for the particle and plume areas.

(d) Mesh form and segment counts
- `triangles()` stays, for tests.
- A new `mesh() -> (vertices, indices)` gives indexed output.
- Large cylinders go up to 128-192 segments: a 10 m S-IC at 48 segments has visible 0.66 m facets on the silhouette.

(e) Split ApolloShapes.swift so parallel sessions own disjoint files
- ApolloShapes.swift keeps the dispatcher and helpers.
- New per-element files: +SIC.swift, +SII.swift, +SIVB.swift (S-II/S-IVB interstage, S-IVB, IU), +SLA.swift (SLA, LTA-B, LM stand-in), +SM.swift, +CM.swift, +LES.swift.
- Each comes with an ApolloShapeData extension holding its dimensions with source and H/M/L grade, in the existing datasheet style.

3. GEOMETRY INVENTORY (new or reworked)
Dimensions come from data tracks VD1 and VD3; sources are in data_and_sources.

S-IC
- Four fins, as plates on the diagonals under engines 1-4 (titanium-skinned, per Stages to Saturn). The span is about 63 ft tip to tip (secondary, L): source it from MSFC-MAN-503 or TM X-53770.
- Four conical engine fairings with ogive noses:
  - each with two retro ports (FER-501: eight TE-M-424 motors in pairs; the A8 press kit's "four" is a press error);
  - each with a pair of air scoops on either side.
- Base heat shield with the lunate sub-shields inside the fairings (NASA-CR-153761 panel layout), and flexible engine curtains.
- Four hold-down post fittings.
- F-1 in flight configuration:
  - the bell to 10:1, then the turbine-exhaust-cooled extension to 16:1;
  - the exhaust manifold torus at the joint;
  - turbopump and plumbing as blocks;
  - chamber and turbopump wrapped in an insulated shroud (Inconel foil over high-silica batting, NTRS 19650013319), not museum bare bells.
- Two service tunnels along the tanks.
- LOX vent fairings at the forward skirt top; umbilical plates.
- Corrugated thrust structure, intertank and forward skirt; smooth tanks.

S-IC/S-II interstage
- 4 (or 8) ullage motor fairings straddling the separation plane; the lower ends leave with the interstage.
- Raised separation-line ridges.
- Inner skin in zinc-chromate primer, the back face of the open shape (L-M).

S-II
- Aft skirt and thrust cone, with the engine heat shield and curtains.
- One systems tunnel; umbilical plates.
- J-2s: tube-bundle chambers (shader relief), turbopump blocks, gimbal actuators.

S-II/S-IVB interstage
- Stringer-stiffened cone.
- Four retro fairings.
- Personnel access hatch.
- 2×2 sway-target checkerboards (decals).

S-IVB
- APS modules in their real faired shape, at Positions I and III, with three attitude nozzles and the ullage nozzle.
- Two jettisonable TX-280 ullage fairings.
- Tunnel(s); forward skirt with four antenna fairings.
- Aft and forward skirts with hat stringers (relief).

IU
- 36 in ring with umbilical plate, access door and small antennas.

SLA
- Panel seams and hinge line.
- Cork-on-honeycomb surface (1.75 in honeycomb, A8 press kit).
- Panels jettisoned on Apollo 8 and 11 (Apollo 7's were hinged).

LTA-B
- A boilerplate descent-stage-like structure with ballast; a few hundred triangles.
- Shape from AS08-16-2582..2584 (the S-IVB with LTA-B after TLI).

SM
- Shell: a 154 in cylinder.
- Radiators:
  - EPS radiators at the top: fin bands (PDS Apollo CSM description);
  - ECS radiator panels at the aft end (two 30 ft² panels).
- RCS quads: true housings, with four canted R-4D nozzles each and their mounts.
- Antennas: two VHF scimitars; the HGA, four 31 in (79 cm) dishes on a folding boom at the aft end, stowed and deployed.
- CM/SM fairing with the umbilical; EVA handrails and docking lights by variant.
- SPS nozzle in two material bands: columbium upper and titanium lower extension (AOH 2.4; split station to confirm).

CM
- The existing OML.
- Five windows (2 rendezvous, 2 side, 1 hatch) as inset glass with frames.
- Unified hatch outline (relief).
- Twelve RCS ports at the E2 thruster positions, as scarfed recesses.
- Docking ring and tunnel stub; the probe on CSM-107 only.
- Uprighting bags and recovery antennas, shown when floating (optional).

LES
- The truss: four legs plus cross-bracing, Buna-N-covered titanium tubes (CSM News Reference §15).
- Structural skirt over the motor nozzles.
- Launch escape motor, pitch control motor and tower jettison motor.
- Ballast/canard section with two canards (stowed; deploy is an abort-only state).
- Inconel Q-ball nose, 13.37 in long and 13.3 in across.
- BPC with its hatch and window cut-outs. The tower is 33 ft long and 4 ft across at the base (A8 press kit, H).

4. PAINT AND MARKINGS (core data, shader evaluation)

Data model
- `Paint` = base colour + `[PaintRegion(u: ClosedRange, v: ClosedRange, colour)]`. The last match wins, with wraparound azimuth.
- `Decal` = `.text(String, font: .saturn, vertical:)`, `.flag`, `.swayTarget` or `.label`, placed by (u, v), size in metres, and rotation.
- `PaintColour`: white, black, red lettering, flag red/blue/white, zinc chromate, frost.
- A reference evaluator, `Paint.sample(u:v:) -> PaintColour`, lives in core. The MSL code mirrors it.

Per-vehicle tables
- Markings+SaturnV.swift and Markings+CSM.swift are generated by hand from the VD2 markings datasheet. Every row cites NASA photo IDs and carries a grade.
- Seed hypotheses for VD2 to confirm or overturn:
  1. S-IC, from the thrust structure to just below the intertank: eight 45° stripes alternating black and white. Their phase against the fins is to be determined. On S-IC-6, drain labels sit at the top of each stripe (M).
  2. The intertank is white on every flown vehicle. AS-501/502 were repainted at KSC with a visible tone line; 503-505 were repainted at Michoud; 506 was built white (M). The black intertank band belongs to SA-500F only and must not be copied.
  3. Black stripes run continuously across the S-IC forward skirt, the S-IC/S-II interstage and the S-II aft skirt (M).
  4. The S-II/S-IVB interstage has four quadrants, each with its own asymmetric black/white horizontal split, plus sway targets (M).
  5. The S-IVB forward skirt and/or the IU are black (conflicting reports, L).
  6. The SLA and BPC are white.
  7. "UNITED STATES", "USA" and two flags on the S-IC. Positions and sizes are to be digitised. The lettering is red per the AS-503 press kit ("huge red lettering"), to confirm in colour photos.
  8. SM lettering and flag: to be determined by vehicle.

Lettering
- StrokeFont.swift holds a hand-coded stroke font of polylines and circular arcs for U, N, I, T, E, D, S and A (enough for "UNITED STATES" and "USA"), plus digits for stencils.
- Glyph proportions are fitted to the photos.
- The app bakes a single-channel SDF atlas (1024²) at load by calling the core distance function. One implementation, tested on Linux.

Flag
- USFlag.swift encodes Executive Order 10834 geometry: hoist 1, fly 1.9, union 0.5385 × 0.76, 50 stars of diameter 0.0616 in rows of 6 and 5, stripes 1/13.
- Baked at load into a 2048×1080 texture from the core function.

Frost overlay (pad and ascent)
- A coverage mask on the cryogenic regions: the S-IC LOX tank and lines, the S-II aft/LOX band, a light S-IVB band.
- Its strength is the remaining FER Table 20-1 frost mass over the initial mass, shed by CECO on the existing schedule.
- Rough white with noise break-up.
- It hands VisualAttachment shed zones to the particle area.

Post-entry char
- A char factor from Vessel.heatLoad, normalised by the Apollo 7 entry's.
- The heat shield darkens to char; the afterbody Kapton burns from silver to gold to brown streaks, on the windward side from the trim attitude.
- Driven by simulation state, so it is safe at any warp.

5. MATERIALS AND TEXTURES

SurfaceMaterial (core table)
- Each material has base colour, metalness, roughness, anisotropy, and an optional detail pattern.
- Calibrate albedo from the measured solar absorptance α where sourced (TN D-6863 Apollo 9 coating returns; TN D-7564): diffuse albedo ≈ 1 − α, then sanity-check against flight colour photos.
- Materials:
  - Saturn white and black paints;
  - red lettering;
  - bare and unpainted aluminium;
  - zinc-chromate primer;
  - cork-on-honeycomb (SLA);
  - fibreglass BPC;
  - Buna-N tower tubes;
  - Inconel nose;
  - F-1 insulation batts (dull Inconel foil);
  - F-1 nozzle extension;
  - J-2 tube chamber;
  - SPS columbium (dark silicide) and titanium bands;
  - SM aluminium finish;
  - SM radiator white (low α, high ε);
  - RCS quad housing and nozzle;
  - CM aluminised Kapton;
  - Avcoat ablator and char;
  - window glass;
  - frost.

Procedural relief, analytic in the shader
- Corrugation(count, depth, duty), hat stringers(count, width), ring frames(pitch), panel lines(grid), rivet rows, J-2 tubes(count), radiator fins.
- All are periodic in (u, v·r), built in the shader's tangent frame.
- Each fades out when fwidth exceeds half its period, so nothing aliases.

Generated maps at load (Metal compute in the app, fixed seeds, mipmapped, tileable)
- Kapton crinkle normal map: 1, 2 and 4 in tape strips (collectSPACE; confirm in TN D-7564), per-strip normal tilt and roughness jitter. The strip direction comes from Apollo 9-11 in-flight photos.
- F-1 quilted batt map.
- Cork and ablator honeycomb noise.
- Soot and streak masks: the S-IC base, retro-port scorch on interstages after firing, RCS plume staining.

Decals
- At most 8 per part.
- SDF text, flag texture, sway targets and labels, sampled in (u, v·r) decal space.

No photo-derived textures
- NASA photos are references for verification only. Their perspective, baked-in lighting and film colour make them unusable as albedo.

6. RENDERER INTEGRATION (app)

Vertex format
- Indexed, 48 bytes:
  - position float3;
  - normal and tangent as packed snorm;
  - surface u, v as float2 and s, r as half2;
  - material, paint and decal set as ushort4;
  - tint rgba8.
- The triangle count grows about 30-100×, so the non-indexed 48-byte layout would cost about 100 MB.

Per-part mesh cache
- New file VesselGeometry.swift: one GPU buffer per part identity, built once (in the background in Debug).
- A vessel's draw list is built from cached parts plus the construction offset.
- Separations no longer re-tessellate, which removes staging hitches at warp.

Vessel pass
- Extract step 3 of Renderer.swift (:331-381) into VesselPass.swift.
- It binds three buffers: the materials table, paint regions and decals, and the per-set ranges.
- It binds two textures: the decal atlas and the generated maps.

Shader split
- VesselShaders.swift: vessel_vertex/vessel_fragment and the shadow-depth vertex.
- VesselPaintShaders.swift: regions, decals, frost, char.
- VesselMaterialShaders.swift: relief, material to SurfaceSample.
- The library is compiled from the concatenated strings.

Lighting interface
- The fragment builds
```
SurfaceSample { albedo, metalness, roughness,
                anisotropy+tangent, normal, emissive, occlusion }
```
  and calls `shade_surface(sample, V, env)` from the lighting area's LightingShaders.swift.
- Until that lands, a local fallback keeps today's eclipse fraction, earthshine and ambient, and adds:
  - a GGX sun lobe;
  - an analytic Earth-disc reflection term (earthDir, lit fraction, colour);
  - a sky term in air.
- The Kapton CM and the metals need environment reflections or HDR to look right. That is a dependency, not something to fake.

Gallery and snapshot mode
- `ORBITSIM_VESSEL_GALLERY=<shots.json>`, after the navball gallery.
- Builds vessels directly by variant.
- Shot parameters:
  - camera in the vessel frame, perspective or orthographic;
  - sun direction, given or computed from the ephemeris for a UTC (Apollo 8 launch: 12:51:00 UTC, 21 Dec 1968);
  - optional Earth background;
  - debug views: albedo, normals, paint ID, station-tick overlay.
- Writes PNGs and an HTML contact sheet pairing each shot with its reference photo ID.
- `--verify` samples the albedo view at probe points from the markings CSVs and compares them with the core evaluator. It exits non-zero on mismatch.

Linux ortho gallery (test support, no Metal)
- A small software rasteriser in Tests/OrbitCoreTests/Support renders flat-lit orthographic albedo views of a vessel from the core paint evaluator.
- Views: Positions I-IV, top and bottom, close-up crops.
- Writes PNG (stored-deflate encoder) when ORBITSIM_ORTHO_DIR is set, so cloud sessions can see their geometry and paint.

7. INTERFACES TO OTHER AREAS
- Plumes: use VesselMesh.nozzles plus the new retroPort and ullageExit attachments.
- Particles: separation planes, frost-shed zones, LOX vents, the Apollo 8 "firefly" debris at S-IVB separation (seen in AS08-16-2582..2584).
- Lighting and shadows: the SurfaceSample contract, env lookup, HDR target format via the pipeline helper, and a vessel shadow-depth vertex for self-shadowing (fins on fairings, the LES on the BPC, the CM on the SM).
- Vehicle definition: AS-503 masses and propulsion, and the LTA-B mass (about 9 t per the Mission Report, to confirm), set the `appearance` variant on parts.
- Pad and LUT: out of this area.

## Phasing

STEP 0: SEAMS (serial, about 3.75-5.5 d)
V0a: core seams (Linux, 1-1.5 d)
- Contents:
  - VisualShape surface coordinates, tangents and indexed `mesh()`;
  - the new kinds (prism, plate, torus, box);
  - the Appearance type skeletons;
  - ApolloVariant, plus VesselPart.appearance and attachments (the one-line Components.swift seam);
  - the ApolloShapes and ApolloShapeData split into per-element files;
  - the Position I-IV convention test.
- No visual change.
- Merges first.

V0c: Linux ortho gallery test support (0.75-1 d)
- Can run in parallel with V0a, rasterising today's triangles; it gains paint when VM1-core lands.

V0b: app seams (Mac, 2-3 d, after V0a)
- New vertex format and indexed per-part mesh cache.
- VesselPass extracted from Renderer.swift.
- Shader split into VesselShaders, VesselPaintShaders and VesselMaterialShaders with stub hooks.
- Materials, paint and decal buffers.
- Vessel gallery mode with `--verify`.
- Look unchanged at merge (base colours only).

DATA TRACKS (docs and tools only; start on day 0 in parallel with step 0, no code contention)
VD1: Saturn V exterior geometry datasheet (2-3 d)
- Fins, fairings, scoops, retro ports, heat shield, tunnels, umbilicals.
- Corrugation and stringer counts, APS and ullage fairings, IU details.
- F-1 and J-2 flight configuration.

VD2: markings datasheet and photo digitiser (2.5-4 d)
- tools/digitise_photo.py maps pixel rows to STA from two known joints, as digitise_fer_figure.py does for FER plots.
- docs/data/markings/*.csv: one row per region, decal and probe point, with NASA photo ID and grade.
- A photo index.
- Optical properties from TN D-6863 and TN D-7564.
- Rows for AS-501, 502, 503, 506 and CSM-101, 103, 107.

VD3: CSM, LES, SLA and LTA-B exterior datasheet (1.5-2.5 d)
- Windows, hatch, RCS ports, Kapton strip layout, radiators, HGA, scimitars, lights and handrails by CSM.
- SPS bands, LES truss, canards and skirt, BPC cut-outs, LTA-B shape.
- Upgrades the L items in ApolloShapeData.

STEP 1: PARALLEL BUILD (after V0a; each owns disjoint files plus its own test file)
| Track | Files owned | Where | Days | Starts | Refines with |
|---|---|---|---|---|---|
| VG1: S-IC, S-IC/S-II interstage, F-1 flight configuration | ApolloShapes+SIC.swift | Linux | 2.5-4 | today's data | VD1 |
| VG2: S-II, S-II/S-IVB interstage, S-IVB, IU, J-2s | ApolloShapes+SII.swift, +SIVB.swift | Linux | 2-3 | today's data | VD1 |
| VG3: SLA, LTA-B, SM, CM, LES and BPC, HGA, variant switches | ApolloShapes+SLA.swift, +SM.swift, +CM.swift, +LES.swift | Linux | 3-4.5 | today's data | VD3 |
| VM1: paint, markings, lettering, flag, frost, char | Core: Appearance/Paint, Decal, StrokeFont, USFlag, Markings+*.swift. App: VesselPaintShaders.swift, decal baking in VesselTextures.swift | Linux (core), then Mac (app, after V0b) | 3-4.5 | core: immediately | VD2's tables |
| VM2: materials, relief, generated maps, Kapton, SPS bands, batts, fallback shading | Core: Appearance/SurfaceMaterial and SurfaceDetail. App: VesselMaterialShaders.swift, generated maps in VesselTextures.swift | Mac | 3-5 | after V0b | the lighting area's SurfaceSample/env contract (stub until then) |

- VesselTextures.swift is split by MARK sections between VM1 and VM2. Alternatively, use two files: DecalAtlas.swift for VM1 and DetailMaps.swift for VM2.

STEP 2: INTEGRATION AND PHOTO VERIFICATION (Mac, 2-3.5 d, after the step-1 tracks)
VI does the following:
- Fixes the vehicle shot lists:
  - Apollo 8: rollout, pad, launch light at 12:51 UTC, S-IVB plus LTA-B in orbit, the CSM in orbit and after entry.
  - Apollo 11: the same set.
  - Apollo 7: the CSM.
- Runs `--verify`.
- Runs the flight-harness in-flight shots: staging at 162 s and 549 s, LES jettison, CSM separation and HGA deploy, entry char, floating CM.
- Takes the owner review rounds and the fix list.
- Updates README, ROADMAP, CLAUDE.md and the docs/m16 design report.

DEPENDENCIES
- V0a merges before every VG and VM track. V0b merges before VM1-app, VM2 and VI.
- VD tracks feed the VG and VM tracks, which start from today's data and refine as the tables land.
- VM2's final look depends on the lighting area: BRDF, env/IBL, HDR and shadows.
- VI depends on all tracks.

WALL CLOCK
- With 3-4 sessions in parallel, about 9-14 working days.

## Data and sources

- Saturn V Flight Manual SA-503, MSFC-MAN-503 (Nov 1968; station diagrams, stage descriptions, ullage motors, umbilicals): https://www.nasa.gov/wp-content/uploads/static/history/afj/ap08fj/pdf/sa503-flightmanual.pdf ; NTRS https://ntrs.nasa.gov/citations/19750063889
- Saturn V Flight Manual SA-504: https://www.ibiblio.org/apollo/Documents/Saturn_V_Flight_Manual_SA_504.pdf (MSFC-MAN-506 is already used by the repo)
- Apollo 8 Press Kit, 6 Dec 1968 (scanned; the pdftotext layer is usable):
- - black paint for optical tracking, 'huge red lettering', the flag on the first stage
- - LES 33 ft long, 4 ft across at the base; BPC of glass cloth and honeycomb
- - SLA 28 ft, 260 to 154 in, 1.75 in honeycomb; LTA-B in the adapter
- - S-II: four solid ullage rockets on the interstage
- - URL: https://www.nasa.gov/wp-content/uploads/static/apollo50th/pdf/A08_PressKit.pdf
- Apollo 8 Mission Report MSC-PA-R-69-1 (spacecraft configuration, LTA-B): https://ntrs.nasa.gov/citations/19700033031
- NASA Apollo 8 mission page (first use of the high-gain antenna): https://www.nasa.gov/mission_pages/apollo/missions/apollo8.html
- CSM News Reference, North American Rockwell, via the ALSJ (sections 06 CM, 07 SM, 08 SLA, 15 LES, 18 Telecom): https://www.nasa.gov/wp-content/uploads/static/history/alsj/CSMNewsRef-Boothman.html
- Apollo Operations Handbook Block II Vol. 1 (already transcribed by track D: SPS, RCS; extend to windows, antennas, radiators)
- NASA PDS Apollo CSM descriptions (EPS radiators at the top, ECS radiators at the bottom; HGA of four 79-cm dishes on a folding boom at the SM aft end): https://pds-geosciences.wustl.edu/lunar/urn-nasa-pds-apollodoc/document_a14/instrument_hosts/a14c_csm.txt
- NASA TM X-1243 (CM outer mould line, in use): https://ntrs.nasa.gov/api/citations/19660028003/downloads/19660028003.pdf
- TN D-7564, Apollo Experience Report: Thermal Protection Subsystem (Pavlosky and St. Leger, 1974): Kapton tape over the Avcoat ablator (to read)
- TN D-6863, Apollo 9 thermal-control-coating degradation (Smith, 1972): solar absorptance and emittance of flown coatings, for albedo calibration: https://ntrs.nasa.gov/citations/19720018214
- F-1 engine thermal protection, Inconel foil and high-silica batting (NTRS 19650013319): https://ntrs.nasa.gov/api/citations/19650013319/downloads/19650013319.pdf
- NASA-CR-153761, S-IC stage structure description (heat-shield panel layout); Stages to Saturn SP-4206 (fins and fairings, titanium)
- Saturn V News Reference (Aug 1967, rev. Dec 1968): stage fact sheets. Digitised by UAH (copyright caution: facts only, no redistribution): https://digitalprojects.uah.edu/items/show/10478
- AS-501 FER Fig. B-1, D5-15481-1, FER-501 §4 (eight S-IC retros in pairs in the fairings): already cited in docs/AS506-datasheet.md
- FER Table 20-1 frost masses, already in AS506Data.swift:411-421 (drives the frost overlay)
- Executive Order 10834 (1959), flag proportions: https://www.archives.gov/federal-register/codification/executive-order/10834.html
- Kapton tape details (aluminised with SiO overcoat; silver out, gold underside; 1, 2 and 4 in widths; α/ε about 0.4). Secondary, to confirm against TN D-7564: http://www.collectspace.com/ubb/Forum14/HTML/000379.html
- Roll-pattern history, secondary, for VD2 to confirm in photos:
- - SA-500F's black intertank band never flew: https://en.wikipedia.org/wiki/SA-500F
- - white repainted over black intertank stripes: https://gwsbooks.blogspot.com/2015/04/saturn-vs-vanishing-stripes.html
- - intertank repaint per vehicle: https://www.rocketryforum.com/threads/saturn-v-roll-patterns.150541/
- - stripe layout: https://vintagespace.wordpress.com/2012/02/05/painting-rockets/
- - interstage stripes, ullage counts, S-II/S-IVB interstage quadrants, sway targets:
-   https://oikofuge.com/revell-1-96-saturn-v-s-ii-aft-interstage/
-   https://oikofuge.com/revell-1-96-saturn-v-s-ivb-aft-interstage/
- - S-IC drain labels, two service tunnels, fairing scoops, batted F-1s:
-   https://oikofuge.com/revell-1-96-saturn-v-s-ic-stage-part-1/
-   https://oikofuge.com/revell-1-96-saturn-v-s-ic-stage-part-2/
- S-II ullage motor count, 8 then 4 then 0, secondary: https://en.wikipedia.org/wiki/Ullage_motor ; the AS-503 press kit (four) is primary
- Photo archives (NASA, public domain):
- - NASA Image and Video Library: https://images.nasa.gov
- - ASU Apollo Image Archive: https://apollo.sese.asu.edu/
- - Apollo Flight Journal, Apollo 8: https://www.nasa.gov/history/afj/ap08fj/
- - Apollo 8 image index: https://apolloexplorer.co.uk/photo/html/index/A/Apollo_8.htm
- Specific frames:
- - S68-56050 (launch), S68-56002 and S68-56310 (pre-launch), S68-56082 (mating of spacecraft 103 to AS-503)
- - Apollo 8 rollout, 9 Oct 1968 (https://www.nasa.gov/image-detail/apollo-8-rollout/)
- - AS08-16-2582 to 2584 (S-IVB with LTA-B, firefly particles)
- - 69-H-365 (Apollo 11 S-IC), 69-HC-341 (Apollo 11 S-IVB stacking), Ap6-MSFC-6758331 (Apollo 6 aft interstage)
- Shading techniques, implemented from the papers' equations with no code copied:
- - GGX/Smith microfacets: Walter et al. 2007
- - Burley 2012, Physically-Based Shading at Disney (anisotropy)
- - Karis 2013, Real Shading in Unreal Engine 4
- - Heitz 2014, masking-shadowing
- - Green 2007, Improved Alpha-Tested Magnification for Vector Textures (SDF text)
- - standard fwidth-based band-limiting of procedural patterns

## Licensing

MIT BY CONSTRUCTION
- All geometry is procedural from published dimensions; facts are not copyrightable.
- All textures are generated at load from code.
- All lettering is a hand-coded stroke font.
- The flag is computed from Executive Order 10834, a US government work.

NASA SOURCES
- NASA documents and photos are US government works in the public domain. Credit them in docs/data/markings/README.md and in the README data sources.
- Use photos only as verification references, never as shipped textures. Keep them out of the repo, both for size and to keep the repo code-only.
- No NASA insignia, worm or meatball. Their use is restricted by 14 CFR §1221, and the flown Apollo 8 and 11 Saturn Vs carried "UNITED STATES"/"USA" and flags, not NASA logos (the earlier study's rule).
- The US flag is unrestricted.

CONTRACTOR DOCUMENTS
- The CSM News Reference (North American Rockwell) and the Saturn V News Reference (contractor-authored; the UAH scan carries a copyright caution) are read for dimensions and facts only. Do not reproduce their figures.

DO NOT USE
- NASSP / Project Apollo for Orbiter meshes and textures (GPL).
- Orbiter add-on art of unknown licence.
- KSP assets (proprietary).
- Model-kit decal sheets and instructions: Revell, Monogram, New Ware (copyright).
- David Weeks's / Real Space Models drawings: copyrighted. Reading them to cross-check a fact is defensible, but the repo must cite NASA sources for every dimension and never trace them.
- Peter Alway's Rockets of the World artwork.
- Commercial or Apple system fonts for the markings. CoreText is also unavailable on Linux, which the tests need.

LIBRARIES
- No third-party code is needed.
- If multichannel SDF were ever wanted, msdfgen is MIT (keep its notice). The hand-coded glyphs make it unnecessary.

DEV TOOLS
- tools/digitise_photo.py uses only the standard library plus, optionally, Pillow (MIT-CMU). It is not shipped.

## Performance

FRAME BUDGET AT 60 FPS (16.7 ms)
- Give the vessel pass at most 2 ms of GPU time with the whole stack filling a 2880×1800 drawable at MSAA 4× on a base M1. That leaves most of the frame to clouds, atmosphere, plumes and particles.

Estimate
- Vertex stage:
  - about 300-400k triangles, indexed: about 0.2 ms;
  - shadow-depth pass, if the lighting area adds one: about 0.2 ms more.
- Fragment stage (MSAA shades once per pixel, except at edges):
  - work per fragment:
    - paint loop: at most 24 regions;
    - 1-3 decal samples;
    - analytic relief;
    - 1-2 detail-map samples;
    - GGX;
  - about 150-300 ALU ops per fragment;
  - at full-screen coverage (rare: the stack is tall and thin), about 5 M fragments, about 0.5-0.8 ms on M1 (2.6 TFLOPS).
- Memory:
  - 48-byte indexed vertices: about 15-20 MB;
  - decal atlas plus flag: about 6 MB;
  - generated detail maps with mips: about 16 MB at 1k, 64 MB at 2k.
- CPU:
  - a per-part mesh cache, so staging and separations at any warp only rebuild draw lists (microseconds), not geometry;
  - first build of all parts: about 50-100 ms in Release, a few seconds in Debug, done in the background at scenario load.

PRECISION
- Camera-relative float is fine at 110 m (about 1e-5 m).
- Relief periods use (u, v·r) in metres: sin(2πu/0.1) at u = 110 m keeps about 5e-4 rad of phase accuracy.

TIME WARP
- Nothing in this area depends on wall-clock time.
- Frost uses the FER frost mass schedule in simulation time. Char uses Vessel.heatLoad. HGA and canard states and the SLA panels are simulation states.
- Behaviour is identical at 1× and 1000×, and it neither freezes nor flickers when paused (the same rule as Renderer.thermalLag).
- Gimballed nozzle groups already move with thrustDirection. New dynamic groups (HGA, canards) use the same mechanism.

QUALITY SETTINGS (Vehicle detail: Low / Medium / High; default High on Apple Silicon)
| Setting | Low | Medium | High |
|---|---|---|---|
| Revolution segment multiplier | 0.5× | 1× | 2× |
| Relief | off | on | on |
| Decal atlas | 512 | 1k | 2k |
| Detail maps | 512 | 1k | 2k |
| Anisotropic filtering | 4× | 8× | 16× |

- Relief fades automatically with fwidth at every setting, so distance views need no setting.
- The gallery and verification always run at High in Release.

## Verification

LINUX (swift test, OrbitCoreTests)
Keep the added runtime under about 10 s, against the existing 15-18 min suite. Reuse one tessellation per test class.

Geometry against published dimensions
- SaturnVExteriorTests.swift (new):
  - overall height 363 ft;
  - stage lengths and diameters (existing H stations);
  - four fins on the diagonals under engines 1-4;
  - fin span against VD1's sourced value (63 ft secondary until sourced);
  - four engine fairings with two retro ports each (FER-501);
  - S-II ullage fairings: 4 on AS-503/506 (A8 press kit), 8 on AS-501/502;
  - four retro fairings on the S-II/S-IVB interstage;
  - APS modules at Positions I and III;
  - tunnel counts (S-IC 2, S-II 1, S-IVB 1);
  - F-1 exit radius from exitArea (existing).
- CSMExteriorTests.swift (new):
  - LES 33 ft long and 4 ft across at the base (A8 press kit);
  - SLA 28 ft, from 260 to 154 in;
  - SM and CM at 154 in;
  - Q-ball 13.37 × 13.3 in;
  - five windows;
  - HGA present on CSM-103 and 107 and absent on 101;
  - probe on CSM-107 only;
  - HGA dish diameter 79 cm.

Silhouette (test-support orthographic rasteriser)
- The maximum radius against station at chosen azimuths matches the datasheet's diameter table and the fin span.
- Separated vessels draw where they drew on the stack (extends testShapesSurviveSeparation).

Paint
- PaintSchemeTests.swift reads docs/data/markings/*.csv probe rows (STA, azimuth, expected colour) and checks `Paint.sample`, in the ToolsData.swift style.
- Variant tests:
  - AS-503 and AS-506 differ only where the table says;
  - SA-500F features (black intertank band, S-IVB "USA") are absent.
- USFlagTests.swift checks the EO 10834 proportions, the 50 stars in alternating rows of 6 and 5, and 13 stripes.
- StrokeFontTests.swift checks the glyph set covers "UNITED STATES" and "USA", letter heights and advances against VD2's measured block lengths, and that the SDF sign is correct.

Tessellation invariants
- Closed shapes are watertight.
- Winding is counter-clockwise from outside.
- (u, v) are continuous except at the declared seam.
- Tangents are orthonormal to the normals.
- Per-part triangle budgets act as a guard.

Ortho gallery
- ORBITSIM_ORTHO_DIR=… swift test --filter OrthoGallery writes PNGs that cloud sessions open with Read.

MAC (xcodebuild build; the vessel gallery in Release)
- Shot lists live in docs/m16/shots/*.json. For each element, a perspective view matched to a reference photo plus orthographic Position I-IV views with station ticks.
- `--verify` checks GPU against CPU paint at the CSV probe points. It catches drift between the Swift reference and the MSL code.
- Lighting-matched shots use the simulation's own ephemeris:
  - Apollo 8 launch, 12:51 UTC, 21 Dec 1968, low morning sun;
  - Apollo 11 launch, 13:32 UTC, 16 Jul 1969.
  - The shading direction is then also checked against the photos.
- In-flight shots by the existing flight harness:
  - S-IC/S-II separation (open interstage, ullage fairings);
  - interstage jettison;
  - LES jettison;
  - S-II/S-IVB separation;
  - CSM separation with SLA panels and LTA-B (Apollo 8) or the LM (Apollo 11);
  - HGA deploy;
  - entry with char;
  - the floating CM.
- Frame-time capture (GPU and encode, FrameTimes) for the full stack filling the view, against the budget in `performance`.
- Owner sign-off on the screenshot set, as in the M1.5 definition of done.

REFERENCE PHOTOS (NASA, public domain; kept outside the repo)
- Collect them once into a local folder listed by docs/data/markings/photo_index.csv. The download needs the owner's approval in that session.
- Apollo 8:
  - rollout on 9 Oct 1968 (nasa.gov image-detail/apollo-8-rollout);
  - on the pad: S68-56002, S68-56310;
  - launch: S68-56050;
  - mating of spacecraft 103 to AS-503: S68-56082;
  - the S-IVB with LTA-B after TLI: AS08-16-2582 to 2584.
- Apollo 11: S-IC 69-H-365, S-IVB stacking 69-HC-341.
- Apollo 6: aft interstage, Ap6-MSFC-6758331.
- Block II CSM in flight: Apollo 9, 10 and 11 frames of Gumdrop, Charlie Brown and Columbia from the LM. VD3 picks the frames, for the Kapton, SM finish and radiators.
- Recovered CMs on the carriers, for char.
- Rule: never use museum hardware as an appearance reference. It is restored or repainted, its F-1s lack the flight insulation, and its CMs lack the Kapton.

## Files touched

- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/VisualShape.swift
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes.swift
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes+SIC.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes+SII.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes+SIVB.swift (new: S-II/S-IVB interstage, S-IVB, IU)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes+SLA.swift (new: SLA, LTA-B, LM stand-in)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes+SM.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes+CM.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes+LES.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloVariant.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Components.swift (V0a seam only: VesselPart.appearance and .attachments near :636)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/SurfaceMaterial.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/SurfaceDetail.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/Paint.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/Decal.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/StrokeFont.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/USFlag.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/Markings+SaturnV.swift (new: AS-501/502/503/506 tables)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/Markings+CSM.swift (new: CSM-101/103/107)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Appearance/Frost.swift (new: coverage from FER Table 20-1 frost masses)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/SaturnV.swift and ApolloCSM.swift (one line each to set the variant; owned by the vehicle-definition area)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/VisualShapeTests.swift (update shape counts)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/SaturnVExteriorTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/CSMExteriorTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/PaintSchemeTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/StrokeFontTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/USFlagTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/TessellationTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/Support/OrthoRaster.swift (new: silhouettes and the Linux ortho gallery, PNG writer)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Meshes.swift (VesselMesh to indexed; canopies untouched)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/VesselGeometry.swift (new: per-part GPU mesh cache)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/VesselPass.swift (new: step 3 extracted from Renderer.swift:331-381)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Renderer.swift (call VesselPass; library from concatenated shader strings)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/RenderTypes.swift (MeshVertex v2, material/paint/decal GPU structs)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Shaders.swift (remove mesh_vertex/mesh_fragment)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/VesselShaders.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/VesselPaintShaders.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/VesselMaterialShaders.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/DecalAtlas.swift (new: SDF text atlas and flag texture baked from core)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/DetailMaps.swift (new: Kapton crinkle, F-1 batts, cork, ablator and soot maps via compute)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/VesselGallery.swift (new: ORBITSIM_VESSEL_GALLERY offscreen shots, contact sheet, --verify)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Views.swift (one-line gallery hook, as for the navball gallery)
- /Users/grossetti/sw/ullage/tools/digitise_photo.py (new)
- /Users/grossetti/sw/ullage/docs/data/markings/README.md, photo_index.csv, as501.csv, as502.csv, as503.csv, as506.csv, csm.csv (new)
- /Users/grossetti/sw/ullage/docs/SaturnV-CSM-exterior-datasheet.md (new: VD1 and VD3)
- /Users/grossetti/sw/ullage/docs/m16/design-vehicle-look.md (new: this report) and docs/m16/shots/*.json
- /Users/grossetti/sw/ullage/README.md, /Users/grossetti/sw/ullage/docs/ROADMAP.md, /Users/grossetti/sw/ullage/CLAUDE.md (close-out)

## Options (owner decisions)

1. Which vehicles to build.
   - Default: Apollo 8 (AS-503, CSM-103, LTA-B) and Apollo 11 (AS-506, CSM-107, LM-5 stand-in), plus CSM-101 for the Apollo 7 scenario.
   - AS-501/502 go into the markings datasheet only.
   - Alternative: also build Apollo 4/6. That needs Block I CSM-017/020 (no tunnel, Block I hatch and SM): about +4-6 d.

2. Texture technique.
   - Default:
     - procedural in the shader (paint regions, relief);
     - decals baked at load from core functions (stroke-font SDF, EO 10834 flag);
     - generated detail maps at load;
     - no photo-derived textures.
   - Alternative: hand-painted texture atlases. They are slower to iterate, need UV unwrapping, and are no better at 1 cm.

3. Detail level.
   - Default: features of 5 cm or more as geometry, smaller ones as relief. About 250-400k triangles for the stack.
   - Alternatives:
     - a lighter about 100k-triangle stack (faster Debug builds, plainer close-ups);
     - corrugations as geometry for exact silhouettes (+0.5 d, about 2× the triangles).

4. Disputed markings, such as the colour of the lettering, the black on the IU and S-IVB forward skirt, and SM lettering.
   - Default: follow flight-era colour photos as graded in VD2, starting from the AS-503 press kit's "huge red lettering". You decide the remaining L rows from the gallery.
   - Alternative: freeze on AS-506 photos and apply them to AS-503 where no Apollo 8 photo exists.

5. CM Kapton and the metals.
   - Default: wait for the lighting area's environment reflections and HDR, with the analytic Earth-disc reflection as the fallback.
   - Alternative: a diffuse silver CM now. It is cheap, and wrong in lunar-orbit and orbital light.

6. Frost on the pad and post-entry char.
   - Default: include both, driven by the FER frost masses and Vessel.heatLoad (about 1 d together).
   - Alternative: defer both.

7. LTA-B fidelity.
   - Default: a simple boilerplate matched to AS08-16-2582..2584.
   - Alternative: draw the LM stand-in for Apollo 8 too. That is wrong, but costs nothing.

8. How the GPU checks run on the Mac.
   - Default: the gallery's `--verify` mode, run from the shell, with no change to Package.swift.
   - Alternative: a macOS-only OrbitRenderTests target. It is cleaner for regressions, but needs Package.swift and VesselPass factored free of AppModel (+0.5 d).

9. Reference-photo folder.
   - Default: you approve, once, a download of about 40-60 NASA photos into a local folder outside the repo, indexed by photo_index.csv.
   - Alternative: sessions cite photo IDs only, and you provide the images.

10. HGA and canard animation.
   - Default: the HGA deploys at CSM separation (Apollo 8 was its first use); canards stay stowed (abort-only).
   - Alternative: also animate the SLA panel hinge for Apollo 7 (+0.25 d).

## Effort

About 25-40 focused session-days for this area. With 3-4 parallel sessions, about 9-14 working days of wall clock.

| Track | Days |
|---|---|
| V0a core seams | 1-1.5 |
| V0c Linux ortho gallery | 0.75-1 |
| V0b app seams and gallery | 2-3 |
| VD1 Saturn V geometry datasheet | 2-3 |
| VD2 markings datasheet and digitiser | 2.5-4 |
| VD3 CSM/LES/SLA/LTA-B datasheet | 1.5-2.5 |
| VG1 S-IC, interstage, F-1 | 2.5-4 |
| VG2 S-II, interstage, S-IVB, IU, J-2 | 2-3 |
| VG3 SLA, LTA-B, SM, CM, LES/BPC, HGA, variants | 3-4.5 |
| VM1 paint, markings, decals, frost, char | 3-4.5 |
| VM2 materials, relief, generated maps, fallback shading | 3-5 |
| VI integration, photo verification, review rounds, docs | 2-3.5 |

What drives the range:
1. Evidence. Paint boundaries and decal positions have to be registered from 1968-69 colour photos with known azimuths. Photos specific to Apollo 8 are fewer than Apollo 11's, and secondary sources conflict.
2. The visual iteration loop on the Mac. An Xcode build plus a Release gallery run takes minutes, and the owner's review latency adds to it.
3. The lighting area. The Kapton, SM and SPS metals cannot be signed off until environment reflections and HDR exist.
4. Swift Debug performance of tessellation at 50-100× today's triangle count. It is mitigated by the per-part cache.
5. How far down the detail ladder you want to go: antennas, labels, rivet rows.

This area's estimate excludes:
- the LM;
- the lighting engine (PBR/IBL/HDR/shadows);
- the pad and LUT;
- plumes and particles.

The earlier 100-185 d figure covered all of those plus finer modelling.

## Risks

EVIDENCE
- Secondary sources (model-builder logs, forums) disagree on the roll-pattern details, the black areas of the IU and S-IVB forward skirt, and SM lettering.
- The AS-503 press kit says the lettering is red, and also gives "four" S-IC retros, which contradicts FER-501's eight. Press kits contain errors.
- 1968 colour film shifts hue.
- Mitigation: a graded markings table with photo IDs per row, owner review of the L rows, and data-driven paint, so a correction is a table edit.

PHOTO REGISTRATION
- Which Position faces the camera must be established from the fins, umbilicals and LUT side, or boundaries land in the wrong quadrant.
- Mitigation: the digitiser records an azimuth reference per photo, with a cross-check between two photos for each region.

MUSEUM CONTAMINATION
- Displayed stages and CMs are repainted, have bare F-1s and no Kapton.
- Mitigation: the reference rule bans museum hardware as an appearance source.

DUAL IMPLEMENTATION
- Paint is evaluated in Swift (tests) and MSL (render), and the two can drift.
- Mitigation: the `--verify` probes. Decals and the flag have a single implementation, baked from core.

FILE CONTENTION
- ApolloShapes.swift, Shaders.swift, Renderer.swift and RenderTypes.swift are single files today. The V0 split must land before parallel work.
- Other graphics areas (clouds, plumes, particles, lighting) also want Renderer.swift and RenderTypes.swift: agree on VesselPass and the shader-string concatenation early.
- Components.swift gets one seam line.

PERFORMANCE REGRESSIONS
- Non-indexed meshes at the new triangle counts would cost about 100 MB, and re-tessellating the whole vessel at every staging stalls at warp.
- Both are addressed in V0b; measure them before VG lands.

DEPENDENCY ON THE LIGHTING AREA
- Without environment reflections and HDR, the metals read wrong, and the vehicle can look "finished but flat".
- Mitigation: the SurfaceSample contract and a fallback.

EXISTING TESTS
- Hard-coded shape counts (VisualShapeTests, SM count) will fail and must be updated deliberately, not loosened.
- The test-suite time budget is already 15-18 min.

LOW-CONFIDENCE DIMENSIONS
- SPS exit (L), SLA hinge (M), LES dimensions (L until VD3), fin span (secondary), and the LTA-B shape (from 3 distant frames).

SCOPE CREEP
- Antennas, labels and rivets are endless. Hold the 5 cm geometry rule and the three-distance target.

LICENSING SLIPS
- The temptation to trace a model kit's decal sheet or David Weeks's drawings, or to borrow NASSP textures (see licensing).

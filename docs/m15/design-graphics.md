# M1.5 design: Graphics consolidation

> Planning document for milestone M1.5, written on 2026-10-19 by a design study (five design reports checked by a planner) and accepted by Franz with the recommended defaults (Italian keyboard confirmed). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

Renderer (Sources/OrbitSim/Rendering, about 900 lines):
- Renderer.swift:42-46 sets up the MTKView with bgra8Unorm_srgb, depth32Float and reversed-Z. It sets no sampleCount, so MSAA is off. The pipelines at :62-79 set no rasterSampleCount. Nothing calls setCullMode, so Metal's default .none applies to every mesh.
- Renderer.swift:262-288 draws each vessel in one draw call from a static mesh. The mesh is rebuilt only when the part list changes (:268-269, Meshes.swift:13-15), so nothing on a vessel can move, and nozzles cannot show gimballing. Lighting is the Sun direction plus a constant ambient of 0.08 (MeshUniforms.sunDir.w at :281-282). There is no occlusion term, so vessels stay fully lit in Earth's shadow.
- Vessels smaller than 0.5 px become points (:271-276). The orbit line (:290-309) has no markers for Ap, Pe, nodes or entry interface. The orbit and point buffers are allocated again every frame with makeBuffer (:294, :313).
- Shaders.swift:175-179 mesh_fragment is Lambert plus ambient. It does not use [[front_facing]] and has no emissive term. In the planet shader, :85-101 draws the sky at 85% opacity (so stars show through the daytime sky at the pad) and :129-136 is diffuse plus haze. There is no specular, so there is no ocean glint and no near-surface detail.
- Meshes.swift:30-82 has two primitives, a frustum with 32 segments and a sphere. Both caps are always emitted (:57-63), so every nozzle bell is a closed cone and every interstage a closed can. By derivation, triangles are counter-clockwise when seen from outside: frustum sides, both caps and the sphere all give outward normals.
- Components.swift:571-588 defines VisualShape with two kinds (frustum and sphere) and a colour. It has no open or two-sided flag, no link to a thruster and no material or emissive role.

Saturn V shapes (SaturnV.swift):
- Nozzles at :98 are closed cones running from the exit (radius from exitArea) to 0.3 of that radius at the gimbal. They are not linked to their Thruster.
- The stage cans at :165, :192, :212 and :232 are closed.
- :269-271 is the S-IVB and its J-2 cone, :297 the IU and :301 the SLA as a closed frustum.
- The LM has no shapes ("inside the SLA", :303-305).
- The CSM is one part (:307-317): an SM cylinder and a CM frustum tapering to a 0.8 m apex. It has no heat-shield curvature, no SPS bell (datasheet §4: SPS exit Xa 715, about 2.5 m across, L) and no RCS quads.
- The LES is three crude frustums (:350-352). The S-IC has no fins or engine fairings.

HUD and app:
- Views.swift:32-52 is a ZStack of MetalView and a text HUDView (:56-122). The HUD is refreshed at 10 Hz from AppModel.refreshHUD (AppModel.swift:164-169, :297-374).
- There is no navball, no MFD and no overlay hook in the renderer.
- Camera.swift:13 has three orbit-camera frames (horizon, vessel, inertial) and no cockpit or nose view.
- The marker directions the navball must agree with are already defined in Autopilot.swift:35-50 (prograde = velocity relative to the reference body, normal = r×v, radial = r, horizon level).

Core data the renderer can already read:
- Thruster.thrustDirection (Components.swift:360-365), position, direction, isDelivering (:480), thrust(ambientPressure:seaLevelPressure:) (:526), massFlow (:533), isSolid, and groups (which give RCS and APS).
- Vessel.atmosphere, airspeed, angleOfAttack and dynamicPressure (Vessel.swift:92-99), and surfaceVelocity.
- Vessel.separate (Vessel.swift:191-224) re-centres both vessels and keeps the shared construction frame, so meshes in construction coordinates stay valid after any split.

The earlier quick-win study is not in the repo (it is not in docs/ or memory). Its list is reflected below.

## Design

Definition for this phase: "consolidated graphics" means the renderer shows what the physics is doing, legibly, at the moments that matter when flying launch → orbit → CSM separation → deorbit → CM/SM separation → entry → splashdown. That covers attitude and direction markers, which engines are firing, the gimbals, sunlight and shadow, correct shapes at every separation, and entry heating, parachutes and the sea. It adds no new rendering architecture.

IN SCOPE NOW: core flying set, about 7.5 session-days

G0. Prep PR, landed before the parallel sessions start (0.25 d)
(a) Move VisualShape from Components.swift:571-588 to a new Sources/OrbitCore/Vessel/VisualShape.swift, so graphics owns that file and the mission session owns Components.swift.
(b) Add a dressing seam: `VesselLibrary.dressSaturnV(_ stack: Vessel)` in a new ApolloShapes.swift, called on one line at the end of saturnV(). It assigns shapes to parts by name ("S-IC", "S-II", "SLA", "SM", "CM", "SLA panel 1-4", "LM", "LES", ...) and links nozzles to thrusters by name. After this, SaturnV.swift's inline shape lines go away, and the mission session can split the CSM in SaturnV.swift without touching geometry.
(c) Add a renderer overlay hook in a new Rendering/OverlayPass.swift:
`@MainActor protocol OverlayPass: AnyObject { func draw(_ enc: MTLRenderCommandEncoder, _ f: FrameContext) }`
FrameContext carries device, drawableSize (px), backingScale, sampleCount, the colour and depth formats, sim, snapshot, camera, viewProjection, a shared SpriteAtlas, and a helper that builds pipeline descriptors with the right formats and sample count. Renderer gets `var overlays: [OverlayPass]`, which it calls after step 5 and before endEncoding, using noDepth and restoring the viewport and scissor. The HUD session's navball registers in MetalView.makeNSView (Views.swift:15-27).

G1. Anti-aliasing, culling and open shapes (0.5 d)
- Set view.sampleCount = 4, set rasterSampleCount on every pipeline (MTKView then allocates and resolves the MSAA colour and depth targets), and give point and line pipelines the same count.
- Add VisualShape flags capBase/capTop and twoSided. Interstages and nozzle bells become open and two-sided.
- VesselMesh keeps two index ranges, closed and open. Closed draws with setFrontFacing(.counterClockwise) and setCullMode(.back). Open draws with .none, and mesh_fragment takes `bool front [[front_facing]]` and flips n when it is a back face.
- Honest note: culling gains nothing measurable (the Saturn V is about 3k triangles). The visible win is open bells and interstages: the J-2s are seen hanging inside the interstage after the S-IC separates, and the S-IVB J-2 inside the aft interstage. MSAA's win is on the thin LES tower, nozzle rims, debris edges and the orbit line.
- MSAA does not antialias the ray-traced planet limb (the fragment writes depth per pixel). The Earth's atmosphere already hides this. A Moon-limb analytic coverage fix is a 0.25 d option.

G2. Light: eclipse factor, earthshine, ambient floor (1 d: 0.5 core, 0.5 app)
- Core: new Sources/OrbitCore/Bodies/Eclipse.swift, `Eclipse.sunlitFraction(at:sun:sunRadius:occulters:[(center, radius)]) -> Double`. It is the conical model: apparent radii of the Sun and the occulter, the overlap area of two discs, then 1 − overlap/(π a²) (Montenbruck & Gill §3.4.2). The occulters are Earth (equatorial radius) and the Moon.
- App: replace MeshUniforms.sunDir.w with `light: float4` (x = sunlit fraction, y = ambient floor of about 0.02, z = earthshine) and `earthDir: float4` (xyz = direction to the reference body's centre, w = the lit fraction of the disc seen from the vessel, 0.5·(1 + cos phase)). In the fragment: albedo·(sun·max(n·s, 0) + earthshine·0.3·max(n·e, 0)·w + ambient).
- Result: vessels darken through an 8-10 s penumbra entering the night side of a 185 km orbit, and are lit from below by the day-side Earth. The renderer computes this per vessel per frame (cheap).

G3. Surface-of-revolution primitive and the Apollo dress (2.25 d)
- Add `VisualShape.Kind.revolution(profile: [(x, r, crease)], segments: Int, sweep: ClosedRange<Double>)` with the cap and twoSided flags from G1. Meshes.swift builds it as a lathe with smooth normals, duplicated at creases. With segments = 8 it gives the LM's octagonal descent stage, and a sweep of a quarter turn gives an SLA panel.
- Add `.plate(points: [Vec3], thickness)` for the S-IC fins.
- ApolloShapes.swift dresses the Saturn V by part name:
  - F-1 and J-2 bell contours (open, exit radius = sqrt(exitArea/π), so F-1 1.79 m and J-2 0.98 m), linked to their Thruster by name.
  - Open interstages.
  - The S-IC's four fins and four engine fairings.
  - The SLA as a fixed lower ring (on the S-IVB/IU side) plus four upper panels, each a quarter-sweep frustum and a part of its own (the parts are the mission session's).
  - A crude LM: an octagonal descent stage of about 4.2 m and an ascent-stage frustum. It becomes visible when the panels go.
  - The SM: a 3.912 m cylinder from Xa 838 to 1010, the SPS bell from Xa 833 down to Xa 715 (about 2.5 m exit, open, linked to the SPS thruster) and four RCS quads at Xa about 959.
  - The CM: a spherical heat-shield cap of radius 184.8 in to the 154 in maximum diameter, a toroidal shoulder, a 33° conical afterbody to the tunnel at Xa 1137, and an optional apex-cover group. Heat-shield vertices are tagged emissive role 1 in MeshVertex.color.w, so there is no layout change.
  - The LES tower as thin frustums, plus the BPC.
- The current single CSM part is dressed with SM and CM shape sets. When the mission session splits it into "SM" and "CM" parts, the dress reassigns by name and needs no rework.

G4. Visible gimballing (0.75 d)
- Add `VisualShape.thruster: String?`. VesselMesh records dynamic groups: thruster reference, index range and pivot = part.offset − structureOrigin + thruster.position (construction frame).
- Each frame, for each group: R = the shortest-arc rotation taking thruster.direction to thruster.thrustDirection, and model_g = model · T(pivot) · R · T(−pivot), drawn with its own uniforms. Nozzles move with no exaggeration.
- The S-IC engine-1-out scenario gives the largest deflections and is the test shot.

G5. Engine plumes and RCS/APS puffs (1.5 d)
- New Rendering/Plumes.swift and a plume pipeline with additive blending and depthReadOnly.
- For every thruster with isDelivering: a camera-aligned cone impostor (a quad strip along −thrustDirection from the exit plane of the linked nozzle shape, or from the thruster position with a nominal radius for RCS/APS).
- Intensity = thrust(ambientPressure:seaLevelPressure:) / currentRating.thrustVacuum. The expansion half-angle grows as ambient pressure falls (v.atmosphere).
- Style is inferred in the app from the feed tank names and isSolid, with no core change: LOX/RP-1 bright orange with a dark fuel-rich core; LOX/LH2 nearly transparent bluish (with a visibility floor); solids white-yellow (retros, ullage motors, tower jettison); hypergolics faint orange-pink (SPS, RCS, APS).
- A distant vessel drawn as a point keeps a plume sprite.
- Vertices go through setVertexBytes (<4 KB) or a 3-frame ring buffer, not a per-frame makeBuffer.

G6. Sprite and glyph atlas, and orbit-line markers (1.25 d)
- New Rendering/SpriteAtlas.swift draws, once at startup with CoreGraphics and CoreText, the KSP-style marker glyphs (prograde, retrograde, normal, antinormal, radial in and out, target, maneuver, nose chevron) and short labels ("Ap", "Pe", "AN", "DN", "EI", digits). The navball pass and the orbit markers share it.
- A sprite pipeline draws instanced pixel-sized quads.
- Renderer.orbitStrips gains markers: Pe at ν = 0 and Ap at ν = π when bound and inside the SOI; AN and DN against the reference body's equator; EI where r = a_eq + 121.92 km (400,000 ft) on the descending branch; and the surface impact point.
- The anomaly-at-radius maths is a core function, `OrbitalElements.trueAnomalies(atRadius:)`. Whoever does the MFDs owns it (see depends_on).

G7. Navball and MFD support from the renderer (0.25 d beyond G0 and G6)
- The renderer provides the hook, the atlas and an inset helper, `FrameContext.withInset(rectInPoints) { ... }`, which sets the viewport and scissor in pixels.
- The navball itself belongs to the HUD session, in its own new files (NavballOverlay.swift, NavballShaders.swift with its own shader string and library, so Shaders.swift is not contested). It is a ray-cast sphere in a square inset, with a CoreGraphics-generated equirectangular ball texture and marker sprites for directions on the front hemisphere, drawn at 60 Hz in the same frame as the scene.
- SwiftUI draws the chrome and the readouts at the same rect, published by the HUD layout (for example AppModel.instrumentRects, which the renderer reads).
- MFDs (Orbit, Surface, later Map) are SwiftUI Text and Canvas at 2-10 Hz (Orbiter refreshes MFDs at about 1 Hz) and need nothing from Metal. Only a Map MFD would reuse the Earth texture: expose `TextureLibrary.url(for:)`, factored from Renderer.loadTextures (:116-140).

ENTRY AND RECOVERY VISUALS: about 4 d, after the mission session lands the CM/SM split, entry and recovery state

G8a. Heat-shield glow and optional plasma sheath (1 d glow, +0.75 d sheath)
- Core: new Aerothermal.swift, `stagnationHeatFlux(density:speed:noseRadius:)` (Sutton–Graves, k = 1.7415e-4 kg^0.5/m for air). If the entry session already models heating, use theirs.
- App: per-vessel emissive uniform. The glow is a blackbody-like ramp on role-1 vertices, driven by q/q_ref with a first-order thermal lag (about 5-10 s), so it does not flicker at warp.
- Sheath: an additive paraboloid shell ahead of the heat shield, along the relative wind (−surfaceVelocity), with intensity proportional to q.

G8b. Parachutes (1 d)
- Canopies are revolution profiles (open, two-sided). Mains are orange and white gores at 83.5 ft, drogues 16.5 ft. Risers are drawn as lines from the CM attach point.
- Each canopy is oriented along the relative wind from the attach point and spread for a cluster of three, with inflation scaled by reefing stage. They are dynamic mesh groups, as in G4.
- Needs a core state from the mission session (see depends_on).

G8c. Ocean surface near splashdown (1.75 d)
- In planet_fragment, when the hit point is water and the camera is below about 30 km:
  - wave normals from a sum of 4-6 directional waves (5-60 m wavelengths), faded with distance;
  - Fresnel (Schlick, n = 1.33) reflection of the sky colour;
  - a sun glint whose roughness grows with distance.
- Precision: the CPU passes, in doubles, the camera's offset in a local east-north frame from a fixed ocean origin near the splash point, modulo the wave tile. Wave phase is then evaluated camera-relative in float, so it does not shimmer.
- Water and land: an optional coarse land mask (see options). Without one, ocean detail switches on only when the focus vessel is the CM after entry, which is mid-Pacific for Apollo 11.
- The floating CM is clipped by the planet's depth, so the waterline comes for free. A 0.25 d option adds a foam ring.

OPTIONAL POLISH: about 2 d, owner's pick
- Hide the stars in the daylit sky when the camera is inside the atmosphere (0.25).
- Earth night lights from an optional Black Marble texture (0.5).
- Nose and velocity arrows on the vessel in the 3D view, using the line pipeline (0.25).
- A cockpit or nose camera frame in Camera.swift (0.5), for an Orbiter-style pitch ladder.
- Vessel labels through the atlas (0.5).

OUT OF SCOPE (the months-scale realism work)
- An HDR pipeline with tone mapping and bloom (1-2 weeks).
- PBR materials with image-based lighting (about 2 weeks).
- Shadow maps for vessel self-shadowing and vessel shadows on the pad (1-2 weeks; eclipse needs none of this).
- Precomputed atmospheric scattering (2-3 weeks).
- Real or procedural detailed models: glTF/USDZ import, LC-39A and the launch umbilical tower (3-6 weeks).
- Lunar terrain LOD (an M2 item, 3-4 weeks), volumetric clouds, sound.

Orbiter (MIT core, Src/Orbiter/hud.cpp, Mfd*.cpp) is a design reference. If any code is ported, the "Copyright (c) Martin Schweiger, MIT" notice stays in the file and in a third-party notice. Its D3D9Client (OVP/D3D9Client, LGPL) shaders must not be copied. KSP is proprietary: copy the concept, not the assets.

## OrbitCore vs app

OrbitCore: pure Swift and Foundation, no simd, built and tested on Linux.
- Vessel/VisualShape.swift (moved): the new kinds .revolution and .plate; the flags capBase, capTop and twoSided; `thruster: String?` link; emissive role.
- Vessel/ApolloShapes.swift: `dressSaturnV`, with every shape dimension as named constants carrying their sources and confidence, in the datasheet style.
- Bodies/Eclipse.swift: the sunlit fraction.
- Vessel/Aerothermal.swift: Sutton–Graves heating (G8a), unless the entry session owns heating.
- `OrbitalElements.trueAnomalies(atRadius:)`, if not provided by the MFD session.
- Everything the renderer reads is plain data or a pure function.

Sources/OrbitSim (Mac only; review carefully and build in Xcode):
- Rendering/Renderer.swift: MSAA, cull and draw ranges, light uniforms, the overlay loop, plume and sprite passes, orbit markers.
- Shaders.swift: mesh_fragment light, two-sided and emissive terms; the ocean in planet_fragment; the plume and sprite shaders, which may live in their own shader-string files.
- Meshes.swift: the lathe builder, the closed, open and dynamic ranges.
- RenderTypes.swift: the new float4 uniform members, keeping the float4-only layout rule.
- New files: OverlayPass.swift, SpriteAtlas.swift, Plumes.swift, TextureLibrary.swift.
- Camera.swift, only for the optional cockpit frame.

Plume style, glow colour ramp, thermal lag, earthshine, wave spectrum and parachute orientation are visual approximations and stay in the app. None of them feeds back into the physics.

## Data and sources

- docs/AS506-datasheet.md §4 (stations and heights: SLA top Xa 838, SM/CM Xa 1010, CM apex Xa 1137, SPS gimbal Xa 833 and exit Xa 715 with a ~2.5 m exit (L), SM RCS quads Xa ~959, LM envelope (L)); §1.5 line 168: SM length 295 in including the SPS nozzle
- AS506Data.swift:608 F-1 exit area 10.10 m² (FER Figure 5-3, derived); :659 J-2 exit area from throat diameter and area ratio; :882-886 the body, S-IVB and CSM diameters
- Apollo CM geometry (heat-shield sphere radius 184.8 in, maximum diameter 154 in, 33° afterbody, toroidal corner): NASA TM X-1243 (Bertin), https://ntrs.nasa.gov/api/citations/19660028003/downloads/19660028003.pdf, and the heat-shield curvature and afterbody study, https://ntrs.nasa.gov/api/citations/19700025216/downloads/19700025216.pdf (to transcribe)
- Apollo Earth Landing System: NASA TN D-7437 (West, 1973), https://ntrs.nasa.gov/citations/19740003586 (2 drogues 16.5 ft, 3 ringsail mains 83.5 ft, two-step reefing, about 22 mph at splashdown)
- Sutton & Graves, NASA TR R-376 (1971), stagnation-point convective heating (k ≈ 1.7415e-4 kg^0.5/m for air, to confirm from the report)
- Eclipse model: Montenbruck & Gill, Satellite Orbits (2000) §3.4.2 (conical shadow, occulted fraction); eclipse fraction cos(φ/2) = cos ρ / cos β: Wertz & Larson SMAD §5.1 and Vallado, Fundamentals of Astrodynamics
- IAU 2015 Resolution B3: nominal solar radius 695,700 km (for the Sun's apparent disc)
- Orbiter (MIT core; hud.cpp, MfdOrbit.cpp, MfdSurface.cpp, Shadow.cpp carry 'Copyright (c) Martin Schweiger, Licensed under the MIT License'); OVP/D3D9Client is LGPL: https://github.com/orbitersim/orbiter
- Optional textures (public domain): NASA Visible Earth Blue Marble Next Generation (day), NASA Black Marble (night lights); optional land mask: Natural Earth land polygons (public domain, naturalearthdata.com)
- To find: Apollo 11 Final Flight Plan (1 July 1969), parking-orbit sunrise and sunset marks, as an external check on the eclipse timing; SLA panel and fixed-ring lengths (Apollo 11 press kit)

## Tests

Core unit tests (Tests/OrbitCoreTests, run on Linux):

VisualShapeTests.swift (new):
- Every Saturn V part except the deliberately bare ones has shapes after dressSaturnV.
- Every shape with a `thruster` link resolves to a thruster in the same part.
- Every nozzle's exit radius equals sqrt(exitArea/π) from the engine data: F-1 exitArea 10.10 m² (FER Figure 5-3 derived, datasheet §4); J-2 from its throat diameter and area ratio (AS506Data.swift:659).
- Each shape lies within its part's bounding cylinder, with an explicit exemption list: the J-2 bells hang into the interstage and the BPC overlaps the CM.
- CM profile: maximum diameter 154 in, height Xa 1010→1137 = 3.226 m, heat-shield sphere radius 184.8 in, afterbody half-angle 33°. These are from TM X-1243 and NTRS 19700025216; transcribe and grade H/M/L.
- SPS exit at Xa 715, 2.5 m (datasheet §4, L).
- Parachute nominal diameters: drogue 16.5 ft, main 83.5 ft (TN D-7437).
- Lathe-builder invariants run on the profile maths in core (outward normals, CCW-from-outside ordering). The Metal buffer itself cannot be tested on Linux.

EclipseTests.swift (new):
- Limiting cases: no occulter gives 1; Sun fully behind Earth gives 0; the overlap area against the analytic two-disc formula.
- A 185 km circular orbit integrated for one revolution: the time with fraction < 0.5 matches the textbook cylindrical-shadow eclipse fraction, cos(φ/2) = cos ρ / cos β with sin ρ = R/(R+h) (SMAD §5.1; Vallado), within about 5 s. At β ≈ 0 that is 42.4% of 88.3 min.
- The 1 → 0 transition takes 6-15 s, the penumbra width implied by the Sun's 0.53° disc.
- Optional: Apollo 11's first parking-orbit sunset GET, if found in the Apollo 11 Final Flight Plan.

AerothermalTests.swift (G8a):
- The Sutton–Graves air constant against NASA TR R-376.
- A plausibility band for a 7.8 km/s entry (tens of W/cm²) and a lunar-return entry (hundreds of W/cm²) on the CM's 4.69 m nose radius.

OrbitalElements radius-crossing:
- Against a Curtis or Vallado worked example, or a closed-form check (r(ν) round-trip).

swift test must stay green (203 tests today).

App verification on the Mac (xcodebuild build and run; flight harness from memory):
Use the scratchpad harness hooked into AppModel.tick, with screencapture -l<window> on .req files, and take Release screenshots at:
- Pad at first motion (F-1 plumes, MSAA edges, the culling sanity check: if hulls vanish, flip front-facing to .clockwise).
- S-IC/S-II separation at about 162 s (retros, ullage plumes, open interstage showing the J-2s).
- Interstage jettison at about 192 s.
- LES jettison.
- S-II/S-IVB separation (the S-IVB J-2 visible inside the aft interstage).
- S-IC engine 1 out at 60 s (outboard nozzles visibly deflected).
- The parking orbit crossing the terminator (the vessel darkens over about 8-10 s and earthshine lights it from below), with orbit markers Ap, Pe, AN, DN and EI.
- The navball inset aligned with SwiftUI chrome at 1x and 2x scale.
- Then CSM separation with SLA panels and the LM, CM/SM separation, entry glow, drogues and mains, and the floating CM on the ocean.

Measure the frame time in Release and Debug with MSAA on and off; the target is no fps loss at 1x and unchanged warp numbers against the memory baseline.

## Files touched

- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Components.swift (prep PR only: remove VisualShape at :571-588)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/VisualShape.swift (new, graphics-owned)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes.swift (new, graphics-owned: dressSaturnV, CM/SM/SLA/LM/LES/parachute shapes)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/SaturnV.swift (prep PR only: one-line dressSaturnV call, delete the inline shape lines :98, :165, :192, :212, :232-233, :269-271, :297, :301, :314-317, :350-352; mission-owned afterwards)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/VesselLibrary.swift (optional: link the test rocket and capsule nozzles)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/Eclipse.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/Aerothermal.swift (new, G8a, unless the entry session owns heating)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/VisualShapeTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/EclipseTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/AerothermalTests.swift (new, G8a)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Renderer.swift
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Shaders.swift
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Meshes.swift
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/RenderTypes.swift
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/OverlayPass.swift (new: OverlayPass protocol, FrameContext, inset helper)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/SpriteAtlas.swift (new: marker and label atlas shared with the navball)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Plumes.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/TextureLibrary.swift (new: texture paths shared with a Map MFD)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Camera.swift (optional cockpit frame only)
- Not touched, owned by the HUD session: /Users/grossetti/sw/ullage/Sources/OrbitSim/Views.swift (registers the navball overlay in MetalView.makeNSView), AppModel.swift, Input.swift, new navball/MFD files
- Docs at close-out by the coordinator: /Users/grossetti/sw/ullage/README.md (features and controls), /Users/grossetti/sw/ullage/docs/ROADMAP.md (the Engine and tooling items)

## Depends on

Order:
1. The G0 prep PR merges first (the VisualShape move, the dressSaturnV seam in SaturnV.swift, the OverlayPass hook). After it, the graphics, HUD and mission sessions own disjoint files.
2. G1, G2, G4, G5 and G6 depend on nothing else.
3. G3 can dress the current single CSM part right away.

On the mission and entry session (core):
- Part names and split agreed before G3 is finished: "SM", "CM", "SLA panel 1"-"4" (staging event at CSM separation), the fixed SLA ring and "LM" staying with the S-IVB, an optional "CM apex cover", and the SPS and RCS thruster names that nozzle links and plumes use.
- For G8b, a parachute state on the vessel: name, count, attach point (construction frame), nominal diameter, riser length, inflation 0...1 by reefing stage, deployed and cut.
- For G8c, a splashed or floating status and attitude.
- If it models entry heating, the shared heat-flux function, so G8a does not duplicate it.

On the HUD/MFD session:
- It implements the navball as an OverlayPass in its own files.
- It publishes the instrument rects the renderer reads.
- It shares the marker definitions (Autopilot.swift:35-50 plus surface prograde), so the navball markers, the 3D markers and the autopilot agree.
- One of the two sessions owns `OrbitalElements.trueAnomalies(atRadius:)` and the time to EI, which the orbit markers and the Orbit MFD both use.

## Options (owner decisions)

1. How the navball is drawn. **Default:** a Metal inset pass through OverlayPass: a shaded, textured ball like KSP's at 60 Hz, synchronised with the frame, with SwiftUI chrome on top. **Alternative:** a SwiftUI Canvas vector ball in a TimelineView, simpler and self-contained in the HUD session but flatter-looking.

2. Plume realism. **Default:** physically motivated styles (J-2 and hypergolic plumes faint) with a minimum visibility floor in vacuum, so you can always tell an engine is firing. **Alternative:** KSP-style "readable" plumes. **Alternative:** strictly realistic, where a J-2 in vacuum is nearly invisible.

3. SLA panels at CSM separation. **Default:** jettisoned as four debris parts, as on Apollo 8 and later (Apollo 11), showing the LM on the S-IVB. **Alternative:** hinged open at 45° (Apollo 7). **Alternative:** left closed for now (no LM shape needed).

4. Entry visuals. **Default:** in this phase, the heat-shield glow, parachutes and basic ocean (waves, Fresnel, glint). Defer the plasma sheath (+0.75 d) and the foam ring (+0.25 d).

5. Earth textures. **Default:** stay user-supplied, plus a small `tools/fetch_textures.sh` the owner runs that fetches public-domain Blue Marble (day) and optionally Black Marble (night lights) into ~/Library/Application Support/OrbitSim/Textures. **Alternative:** bundle a 2k default texture in the app target, which adds MBs and a resources entry to Package.swift.

6. Land/sea mask for ocean detail. **Default:** none; ocean detail is on only for the CM after entry. **Alternative:** a coarse public-domain Natural Earth mask (about 0.25°, about 130 KB) via a tools/ script, which the mission session could also use to tell splashdown from a land impact.

7. MSAA sample count. **Default:** 4x, supported on all Apple GPUs. 8x is not worth it.

8. Optional polish in this phase (stars hidden in the day sky, night lights, 3D nose and velocity arrows, cockpit camera, vessel labels). **Default:** take the stars fix and the arrows (0.5 d). Defer the cockpit camera unless the HUD session wants an Orbiter-style pitch ladder.

## Effort

Focused session-days, all on a Mac session (Metal cannot compile on Linux):
- G0 prep PR: 0.25
- G1 MSAA, culling and two-sided open shapes: 0.5
- G2 eclipse, earthshine and ambient (core + tests + app): 1.0
- G3 revolution and plate primitives plus the Saturn V and Apollo dress (with sourced dimension tests): 2.25
- G4 visible gimballing: 0.75
- G5 plumes and RCS/APS puffs: 1.5
- G6 sprite and glyph atlas plus orbit markers (Ap, Pe, AN, DN, EI, impact): 1.25
- G7 navball/MFD renderer support beyond G0 and G6: 0.25

Core flying set: about 7.75 d.

Entry and recovery visuals, after the mission session's CM/SM, entry and recovery state:
- G8a heat-shield glow: 1.0 (+0.75 for the plasma sheath)
- G8b parachutes: 1.0
- G8c ocean: 1.75 (+0.25 for the foam ring)

That is about 3.75 d, or 4.75 d with the options.

Optional polish: up to about 2.0 d.

Whole area: about 11.5 d (about 14 d with every option).

Out of scope, months in total: HDR and bloom, PBR with IBL, shadow maps, precomputed scattering, real or procedural detailed models with the pad and tower, terrain LOD.

Suggested PR sequence: G0 → (G1 + G2) → (G3 + G4) → G5 → G6/G7 → G8 when its core state lands.

## Risks

- Nothing in this area compiles on Linux. Every app change needs a Mac session to build with xcodebuild and to screenshot with the flight harness; the core tests cover only shapes, eclipse and heating.
- Winding: the builders are derived to be counter-clockwise from outside, so front-facing is set to .counterClockwise. If the first screenshot shows hulls culled, flip to .clockwise. The new lathe builder must keep the same ordering, which a core test checks.
- MSAA does not antialias the ray-traced planet limb (the fragment writes depth per pixel). The Moon's limb stays aliased unless analytic coverage is added (0.25 d).
- File contention: SaturnV.swift and Components.swift are wanted by both graphics and mission. The G0 prep PR and the dress-by-part-name seam resolve this only if G0 merges before the parallel work starts and part names are agreed early. A rename in the mission session silently undresses a part; a test that every part has shapes guards against it.
- Precision: gimbal pivots and plume anchors are in camera-relative float (fine at metres). Ocean wave phase must be computed from double-precision camera offsets on the CPU, or it shimmers.
- Performance: per-frame makeBuffer (Renderer.swift:294, :313) plus new plume, sprite and marker passes. Use setVertexBytes or ring buffers, and recheck frame time against the memory baseline (22 fps at warp is the step budget's, not the renderer's).
- G8 is blocked on core state that does not exist yet (CM/SM parts, parachutes, splashdown); the interfaces listed in depends_on must be agreed first.
- Visual-only approximations (plumes, glow, earthshine, waves) are not validated against data, and must not leak into core physics or be presented as measured.
- Several shape dimensions are low confidence: SPS exit 2.5 m (L), LM stowed envelope (L), SLA panel split (21 ft / 7 ft, L), CM corner radius. Tag them in the datasheet style and source them from the documents listed.
- Licensing: Orbiter's core is MIT, so keep the notice if anything is ported. D3D9Client is LGPL (do not copy its shaders). KSP assets are proprietary. NASSP is GPL (do not use).

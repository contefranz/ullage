# M1.5 design: Navball and flight HUD

> Planning document for milestone M1.5, written on 2026-10-19 by a design study (five design reports checked by a planner) and accepted by Franz with the recommended defaults (Italian keyboard confirmed). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

What exists on main (6873da7):

App (Sources/OrbitSim)
- Views.swift:32-52 ContentView is a ZStack: MetalView (GameView, the 3-D scene), then HUDView (.allowsHitTesting(false)), then HelpView (centred). Views.swift:56-122 HUDView has four text panels: top-left (vessel, UTC, MET, warp, ref, cam); top-right (throttle, thrust acc, stage Δv, mass, IU line, failure prompt and engine-out rows, autopilot, gimbal, tank bars); bottom-left (altitude, orbital/surface/vertical speed, Mach/q, lat/lon); bottom-middle (ApA/PeA/inc/ecc/period/T→Ap/Pe); bottom-right (event log). There is no attitude display: no pitch, heading or roll, no velocity-vector or orbital-direction markers, no tapes. Views.swift:146-178 HelpView lists the keys.
- AppModel.swift:13-61 HUDState is a value struct published about every 0.1 s (tick, AppModel.swift:164-169 → refreshHUD, :297-374). refreshHUD already takes the geodetic altitude, the vertical speed along the WGS-84 normal (:323), lat/lon (:327) and the elements (:331-341). Nothing is computed per frame for instruments.
- AppModel.swift:172-231 handleKeys uses h m p . , / c v [ ] space z x t f 1-7 8 0 = - and the held keys w s a d q e i k j l u o. F then a digit fails an engine (:178-187). Free letters: b g n r y, the digit 9, and ` ; ' \ tab.
- Input.swift:26-31 InputState.key(for:) special-cases only space (49) and escape (53). Everything else is charactersIgnoringModifiers lowercased, so Shift is lost, and arrows and F-keys arrive as private-use characters (U+F700…), which no key binding can name.
- Renderer.swift:176-326 draws one pass: stars, ray-traced bodies, vessel meshes, the orbit line, far points. There is no 2-D overlay pass and no MSAA (the view setup at :42-46 leaves sampleCount at 1). Shaders.swift:52-60 sampleEquirect (Tarini's seam-free equirectangular lookup) can be reused for a navball texture.
- Camera.swift:51-56 already builds a horizon frame: geodetic vertical via CelestialBody.vertical, north from the pole. The navball needs the same construction.

Core (Sources/OrbitCore)
- Vessel.swift:35-37 attitude is a Quat (body → ICRF) and angularVelocity is in body axes, rad/s. :403-417 give elements(snapshot:), surfaceVelocity(snapshot:) and latitudeLongitude(snapshot:). :61 attitudeCommand is the IU's commanded attitude. :76 heldAttitude is internal. :97-100 angleOfAttack (total, winds included) and thrustAcceleration are telemetry.
- Autopilot.swift:9-51 AttitudeAutopilot. Its targets come from the inertial r and v: prograde v̂, normal (r×v)̂, radial ±r̂ (the geocentric radius, not perpendicular to v), and level, the horizontal velocity about the geocentric up. target(for:) (:35) is internal. DynamicsTests:209, GimbalTests:246 and SaturnVControlTests:65 rely on radialOut meaning r̂.
- CelestialBody.swift:85 vertical(at:orientation:) gives the WGS-84 normal; BodyOrientation.pole is at :26. SolarSystem.swift:11-13 SystemSnapshot position/velocity/orientation are public. Simulation.swift:62 airVelocity (winds) is internal and :74 snapshot is public.
- Simulation.swift:392 placeLanded makes −z face the azimuth. AS506FlightProgram.swift:89-96 places the Saturn with azimuth padAzimuth+180, so +z (Position I) faces east. Simulation.swift:414 placeInCircularOrbit sets x = v̂ and z = −r̂ (upright, prograde).
- SaturnIU.swift:345-354 eulerAngles(of:) gives Euler angles in the IU's space-fixed frame, not the local horizon. :806-866 commandAttitude flies the orbital attitude with +x along the horizontal velocity and +z toward the Earth (that is roll 0, pitch 0 in a local-horizon reading). The tilt is a rotation of the nose toward +z. :414 timeToNextEvent includes IGM cycles and rating-ramp cells, so it is not a display "next event". cutoffAt (the IGM's predicted cutoff) and the plan/done/pending state are private.
- Components.swift:359-364 Thruster.thrustDirection (gimbal-deflected, vessel frame) and :526 thrust(ambientPressure:seaLevelPressure:) are public, so the core can form a thrust-direction marker without changing the simulation.
- AS506PostflightData.swift:391 cutoffEvents holds FER Table 4-2's flight-path and heading angles. :65 trajectory holds the PFT Table B-II rows in PACSS 13. Tests already compute geocentric γ (AscentResidualTests.swift:591) and heading (SaturnIUTests.swift:285-288) from the radius and the pole.

Orbiter (github.com/orbitersim/orbiter) is MIT (`gh api …/license`: MIT; Src/Orbiter/hud.cpp headed "Licensed under the MIT License"). Its OVP/D3D9Client is LGPL and its planet textures are not in the repo, so avoid both. KSP is proprietary: copy no textures or icons.

## Design

1. REFERENCE FRAMES
- Local horizon at the vessel: up is the reference body's figure normal (geodetic, WGS-84 on the Earth: body.vertical(at:orientation:)), east = (pole × up)̂, north = up × east. At a pole (|pole×up| < 1e-9), north is the projection of the body-fixed +x (prime meridian) axis, as Camera.swift does. The NED triad is (north, east, −up).
  Why geodetic: it matches the HUD altitude, the camera horizon, the IU's plumb line (0.0002° from the normal) and the pad, where the Saturn's axis lies along the normal and reads exactly 90.000°. A geocentric variant (up = r̂) is also provided. Apollo's FER flight-path and heading angles use it, and the tests do too. The two differ by the deviation of the vertical, 0.1615° at LC-39A.
- Ball orientation: C = nedToInertialᵀ · attitude.matrix (body → NED). The renderer uses it per pixel and the readouts use it for Euler angles.
- Heading/pitch/roll: the aerospace 3-2-1 (yaw-pitch-roll) sequence from NED to body axes (+x nose, +y right, +z down), exactly an aircraft's.
  - θ = asin(−C[2,0]); ψ = atan2(C[1,0], C[0,0]) in [0, 360); φ = atan2(C[2,1], C[2,2]).
  - Singular branch, when hypot(C[0,0], C[1,0]) < 1e-9: φ = 0 and ψ = atan2(−C[0,1], C[1,1]). At nose-up this is the azimuth the belly (+z) faces. This convention is continuous for the Saturn: Position I faces east on the pad so the heading reads 090, the roll program brings it to 072.058, and the pitch program tilts the nose toward +z with roll 0. The IU's orbital attitude reads pitch 0, roll 0.
- Velocity frames (KSP's speed modes), enum VelocityFrame { orbit, surface, target }:
  - orbit: v.velocity relative to the reference body's centre.
  - surface: v.surfaceVelocity(snapshot:), relative to the rotating ground.
  - target (phase 2): barycentric v − v_target, with snap.velocity(body) + vessel.velocity on both sides so different reference bodies work.
  - Auto mode: surface when landed or below 40 km descending; orbit above 50 km ascending; keep the previous mode in between. N overrides until the next threshold crossing, as in KSP. On the pad the orbit mode reads 408.6 m/s at heading 090 on the horizon.
- Later reference modes for the ball (phase 3, not now): inertial/IU space-fixed, Apollo FDAI-like (SaturnIU.spaceFixed or a REFSMMAT), and LVLH (Shuttle ADI).

2. MARKERS (unit vectors in ICRF, converted to body axes with attitude.inverseRotate)
- Prograde / retrograde: ±v̂ of the selected frame. Hidden when |v| < 0.1 m/s.
- Normal / anti-normal: ±(r × v_orbit)̂.
- Radial out / in: by default exactly AttitudeAutopilot's targets (±r̂), so pressing 5 or 6 puts the nose on the marker. KSP's radial is perpendicular to prograde in the orbit plane (prograde × normal); the two differ by the flight-path angle (owner decision, below).
- Command marker (flight director, green diamond): where the active mode steers the nose. Under .attitudeHold it is (attitudeCommand?.attitude ?? heldAttitude)·x̂, i.e. the IU's IGM attitude, so the pilot can fly the IGM by hand. Under a pointing mode it is mode.target(for:), which is internal; Navball lives in OrbitCore, so no visibility change is needed. Kill rotation shows none. Until phase 2 makes the autopilot follow the speed mode, this marker is the honest one: in surface mode the yellow marker is surface prograde and the green one shows where key 1 will actually point.
- Thrust marker (orange): normalised Σ over main-group thrusters that are delivering of t.thrustDirection · t.thrust(ambientPressure: v.atmosphere.pressure, seaLevelPressure: sim.atmosphere(of: ref)?.seaLevelPressure ?? 0). It shows gimbal deflection and engine-out offsets. It uses public API only; Simulation is untouched.
- Nose / level indicator: KSP's orange "W" waterline symbol, fixed at the ball's centre (the screen projection of +x).
- Phase 2: target and anti-target markers (target mode, e.g. the spent S-IVB after CSM separation), and a maneuver marker (Δv direction in ICRF, supplied by the MFD session's burn planner).
- Off-ball pointers: when prograde or the command marker is behind the ball, draw an arrowhead on the bezel at angle atan2(−b.z, b.y). This is the idea of Orbiter's HUD OffscreenDirMarker "PG" (MIT, concept only).
- Readouts:
  - HDG/PIT/RLL in degrees, 0.1° resolution.
  - Body rates (roll, pitch, yaw) as FDAI-style rate needles, ±5°/s full scale, saturating.
  - Attitude error to the command, rotationVector(attitude⁻¹ · goal) as Autopilot.swift:305 computes it: optional error needles.
  - α and β from the air velocity in body axes (α = atan2(w,u), β = asin(v/|V|)) beside the total AoA already in telemetry.

3. PURE MATH IN ORBITCORE (Foundation only, no simd)
New folder Sources/OrbitCore/Instruments/, shared with the MFD session, which owns other file names in it.

LocalHorizon.swift:
- `public struct LocalHorizon: Equatable { public let north, east, up: Vec3; public init(up:pole:fallbackNorth:); public static func geodetic(at r: Vec3, body: CelestialBody, orientation: BodyOrientation) -> LocalHorizon; public static func geocentric(at r: Vec3, pole: Vec3) -> LocalHorizon; public var nedToInertial: Mat3; public func elevationAzimuth(of d: Vec3) -> (elevation: Double, azimuth: Double); public func direction(elevation:azimuth:) -> Vec3 }`
- `public struct HorizonAttitude: Equatable { public var heading, pitch, roll: Double; public init(heading:pitch:roll:); public init(attitude: Quat, in: LocalHorizon); public func attitude(in: LocalHorizon) -> Quat }`. The inverse builds C = Mat3.rotZ(ψ)·rotY(θ)·rotX(φ) (active rotations, Matrix3.swift) and Quat(matrix: nedToInertial·C). It is also useful for scenario placement, such as an entry-interface attitude.

Navball.swift:
- `public enum VelocityFrame`.
- `public struct NavballMarker: Equatable { public enum Kind { prograde, retrograde, normal, antinormal, radialOut, radialIn, command, thrust, target, antitarget, maneuver }; public let kind: Kind; public let body: Vec3 }`.
- `public struct AeroAngles { alpha, beta }`.
- `public struct Navball { frame; horizon; bodyToNED: Mat3; angles: HorizonAttitude; speed; verticalSpeed; altitude; rates: Vec3; markers: [NavballMarker]; attitudeError: Vec3?; aero: AeroAngles?; public init(vessel: Vessel, in sim: Simulation, snapshot: SystemSnapshot, frame: VelocityFrame, target: Vessel? = nil, maneuver: Vec3? = nil); public static func project(_ body: Vec3) -> (x: Double, y: Double, front: Bool); public static func autoFrame(previous: VelocityFrame, vessel: Vessel) -> VelocityFrame }`.
- project is orthographic on the unit ball seen along +x: x = b.y (right), y = −b.z (up), front = b.x > 0.

4. RENDERING (recommended: Metal ball in its own small MTKView, so it shares no files with the graphics session)
Sources/OrbitSim/HUD/NavballView.swift: an NSViewRepresentable hosting NavballMTKView, a subclass with hitTest → nil and acceptsFirstResponder = false, so mouse and keyboard stay with GameView. It is transparent (layer.isOpaque = false, clear alpha 0, premultiplied output), uses sampleCount 4 and draws at 60 fps on the main thread (MainActor.assumeIsolated, as Renderer does). It reads AppModel.instruments.navball, which tick computed this frame, so it is at most one frame behind the scene.

Sources/OrbitSim/HUD/NavballRenderer.swift draws two things:
(a) The ball: a full-viewport triangle; the fragment shader does:
  - r² = u²+v², discarding outside with an fwidth anti-aliased rim;
  - p_body = (√(1−r²), u, −v), then p_ned = bodyToNED · p_body;
  - el = asin(−p_ned.z), az = atan2(p_ned.y, p_ned.x);
  - sample the equirect texture with a copy of sampleEquirect;
  - shade with 0.45 + 0.55·p_body.x^0.6 plus a small specular at the upper left;
  - a dark bezel ring with an optional bank scale.
(b) Markers: instanced quads from a 64×64-cell icon atlas, then the fixed waterline symbol, then the bezel pointers. Markers fade within 5° of the limb.
It exposes `encode(into:viewport:state:)`, so a later graphics refactor can move it into Renderer's overlay pass unchanged.

Sources/OrbitSim/HUD/NavballShaders.swift: its own source string and makeLibrary(source:). Shaders.swift is not touched.

Sources/OrbitSim/HUD/NavballArtwork.swift builds the art with CoreGraphics at start-up; no assets and nothing from KSP.
- Equirect texture, 2048×1024, sRGB, mipmapped via a blit encoder:
  - sky KSP-blue with a lighter band near the horizon; ground brown, darker toward the nadir; white horizon 4 px;
  - pitch parallels every 10°, labelled every 30° on the N/E/S/W meridians, with 5° ticks within ±20°;
  - heading meridians every 10°, heavier every 30°;
  - compass-card labels N 3 6 E 12 15 S 21 24 W 30 33 just above and below the horizon;
  - zenith circle and nadir cross;
  - labels pre-stretched by 1/cos(elevation) so they look right on the sphere.
- Marker atlas, KSP-like vector symbols drawn by us:
  - prograde: yellow circle, three ticks and a dot; retrograde: the same with an X;
  - normal: magenta triangle; anti-normal: the triangle with spokes;
  - radial: cyan circle with outward/inward spokes;
  - command: green diamond; thrust: orange cross-circle; target: pink, phase 2; maneuver: blue, phase 2;
  - waterline: orange W.
- `renderToImage(state:size:) -> CGImage` writes PNGs of canned attitudes for review without flying.

Rejected alternative: a SwiftUI Canvas 2-D ADI. It is about a day cheaper, but it looks flat, labels do not foreshorten, and filling the sky and ground needs the projected horizon half-ellipse. It remains the fallback if a second MTKView misbehaves.

5. HUD LAYOUT FOR FLYING (Views.swift restructured; new SwiftUI files under Sources/OrbitSim/HUD/)
- Top bar (full width, translucent): left: vessel + status, MET/GET, UTC; centre: ALT large (geodetic, km) with vertical-speed arrow; right: warp (+"limited"), PAUSED, reference body, camera.
- Top-left: event log (existing, smaller).
- Top-right, vehicle panel:
  - IU status line;
  - the "SPACE:" next staging group, from public parts' StagingRule, or "inhibited until T3" from allowsManualStaging;
  - stage Δv, mass, TWR (thrustAcceleration / |gravity(at:pole:)|), gimbal;
  - engine-out rows and failure prompt; tank bars.
  - Phase 2 adds "NEXT <event> in mm:ss" from a new FlightProgram.nextEvent.
- Bottom centre, the InstrumentCluster, about 260 pt tall:
  - throttle gauge (vertical, commanded mainThrottle + %);
  - speed tape (80 pt, auto-ranging ticks, mode label ORB/SRF/TGT, Mach and q below);
  - NAVBALL (220 pt) with HDG above, PIT left, RLL right, rate needles on the bezel, α/β small;
  - altitude tape (80 pt) with ApA/PeA bugs, then a VSI bar (signed-sqrt scale, ±2 km/s);
  - autopilot column: KILL T, PRO 1, RETRO 2, NML 3, ANML 4, RAD+ 5, RAD− 6, LVL 7, HOLD/IU 8, with the active one lit and an "IU" badge when the program flies the attitude.
  - The tapes, needles and numbers sit in TimelineView(.animation) + Canvas, pulling AppModel.instruments every frame (not @Published), so they are smooth and in step with the ball. The numbers are rounded so they do not flicker.
- Bottom-left and bottom-right: MFD slots, about 300×300 pt each. Until the MFD session lands, the existing surface and orbit panels sit there as SurfacePanel and OrbitPanel; the MFD session replaces those two lines.
- Below 1300 pt of width only one MFD slot shows. At the minimum 900×600 the cluster is kept and the MFDs collapse.
- F2 cycles full / instruments only / off (clean screenshots).

6. APP STATE AND KEYS
New Sources/OrbitSim/HUD/InstrumentModel.swift: an @MainActor final class owning frame, override, hudVisibility, targetID and private(set) navball, with:
- update(sim:), called from AppModel.tick after camera.update;
- handle(key:sim:) -> Bool.
AppModel.swift edits are about 4 lines: `let instruments = InstrumentModel()`, the update call, `if instruments.handle(key, sim:) { continue }` at the top of the pressed-key loop, after the F-capture, and help rows.
Keys:
- N: speed mode (auto → orbit → surface → target if one is set);
- F2, with ` as a laptop alias: HUD visibility;
- Y (phase 2): cycle the target vessel.
Input.swift: a keyCode table naming f1…f12 (122,120,99,118,96,97,98,100,101,109,103,111), left/right/down/up (123-126) and tab (48), plus a held-modifiers set (shift, ctrl, option) so the MFD session can bind Shift/Ctrl combinations without editing Input.swift. Letters behave as today. The HUD reserves only n, y, F2 and `. F1, F3-F12, ; ' g r b 9 are left for the MFD and other sessions.

7. PHASE 2 (separate PR, sequenced with the entry session, which also edits Autopilot.swift)
- The autopilot follows the speed mode (KSP SAS behaviour; entry needs air-relative retrograde):
  - public var Vessel.autopilotFrame: VelocityFrame = .orbit;
  - the reference body's spin (ICRF ω) stored as telemetry in Simulation.updateTelemetry;
  - AttitudeAutopilot.target(for:) uses v − ω×r in .surface.
- FlightProgram.nextEvent(at:) -> (name: String, at: Epoch)?, defaulting to nil. SaturnIU implements it from plan.sequence, pending and cutoffAt ("S-IVB cutoff (IGM)"), filtering gain, cant and rating events.
- Target mode + Y; maneuver marker interface; FDAI error needles; an Orbiter-style scene HUD (markers projected into the 3-D view with camera.worldToView) for a later cockpit camera.

## OrbitCore vs app

OrbitCore (pure Swift + Foundation, Linux-tested):
- Instruments/LocalHorizon.swift: LocalHorizon (geodetic/geocentric NED at the vessel, elevation/azimuth of a direction) and HorizonAttitude (3-2-1 heading/pitch/roll ⇄ Quat, singular-branch convention).
- Instruments/Navball.swift: VelocityFrame, NavballMarker, AeroAngles, Navball (the ball orientation bodyToNED, readouts, rates, speed/vertical speed/altitude, the marker set incl. command and thrust markers, attitude error), the orthographic projection and the auto speed-mode hysteresis.
- Navball reads internal API (AttitudeAutopilot.target(for:), Vessel.heldAttitude, Simulation.airVelocity) from inside the module, so phase 1 needs no visibility changes and no simulation changes.
- Phase 2 core: Vessel.autopilotFrame plus the reference spin telemetry (Autopilot.swift, Vessel.swift, Simulation.swift); FlightProgram.nextEvent with the SaturnIU implementation.

Sources/OrbitSim (macOS only, verified on the Mac):
- HUD/NavballView.swift (pass-through transparent MTKView), HUD/NavballRenderer.swift (ball + marker pipelines), HUD/NavballShaders.swift (its own shader source), HUD/NavballArtwork.swift (CoreGraphics texture and marker atlas, renderToImage).
- HUD/InstrumentModel.swift (per-frame state, speed mode, keys), HUD/InstrumentCluster.swift (tapes, VSI, throttle, readouts, autopilot column; TimelineView + Canvas).
- Views.swift (layout: top bar, panels, cluster, MFD slots, help), AppModel.swift (about 4 lines of wiring), Input.swift (special-key names and modifiers).
- Renderer.swift, Shaders.swift, Meshes.swift and Camera.swift are not touched; they belong to the graphics session.

## Data and sources

- FER Table 4-2 flight-path and heading angles at the boost cutoffs: tools/data/fer506_table_4_2.csv, mirrored in Sources/OrbitCore/Vessel/AS506PostflightData.swift:391 (cutoffEvents); MPR-SAT-FE-69-9, https://www.ibiblio.org/apollo/Documents/lvfea-AS506-Apollo11.pdf p. 58
- PFT Table B-II states in PACSS 13: tools/data/pft506_table_b2.csv and AS506PostflightData.trajectory; Boeing D5-15560-6, https://www.ibiblio.org/apollo/Documents/19920075301.pdf. Checked for this brief: the geocentric prograde elevation and azimuth from the rows match Table 4-2 within 0.001° at S-IC CECO, S-IC OECO and S-II CECO
- Datasheet §15.2: liftoff inertial velocity 408.64 m/s, heading 90° (docs/AS506-datasheet.md:182); 408.636 m/s on the WGS-84 pad
- AS-506 pad and flight azimuth: AS506.padLatitude 28.6084° geodetic, padAzimuth 90°, flightAzimuth 72.058° (Sources/OrbitCore/Vessel/AS506Data.swift:60,128-129)
- D. M. Henderson, Euler angles, quaternions, and transformation matrices for space shuttle analysis, NASA CR, 1977, https://ntrs.nasa.gov/citations/19770019231; and NASA-TM-74839, https://ntrs.nasa.gov/citations/19770024290 (3-2-1 DCM written out)
- NIMA TR8350.2 WGS-84 (already cited in Ellipsoid.swift) for the deviation of the vertical: 0.1615° at 28.6084°
- Stevens, Lewis and Johnson, Aircraft Control and Simulation: aerospace 3-2-1 Euler angles and the wind-axis α/β definitions (textbook)
- Orbiter, MIT: https://github.com/orbitersim/orbiter. Src/Orbiter/hud.cpp (HUD_Orbit: prograde/retrograde markers and the off-screen 'PG' direction marker; HUD_Surface: ground-velocity marker, pitch ladder with bank, compass ribbon, radar altitude below 10 km, TAS vs GS switched at 1e-3 Pa); Src/Orbiter/Mfd*.cpp for the MFD session. OVP/D3D9Client is LGPL: avoid
- KSP navball conventions (speed modes, marker pairs, auto mode switch): https://wiki.kerbalspaceprogram.com/wiki/Navball, which was blocked by bot protection when fetched, so the conventions here are from general knowledge; KSP assets are proprietary and nothing is copied
- Project memory: orbitsim-flight-harness (scratch harness, screencapture flow, Release timings) and xcode-build-and-test-myself

## Tests

New Tests/OrbitCoreTests/NavballTests.swift (XCTest, Linux):
1. Euler convention against NASA's written-out 3-2-1 DCM (Henderson 1977, NTRS 19770019231 / TM-74839). The test writes the DCM elements out explicitly. For 50 random (ψ,θ,φ) away from the singularity, HorizonAttitude.attitude(in:).matrix matches them to 1e-12 and the round trip recovers the angles to 1e-12. A nose-up/right-roll sign check confirms θ>0 means nose above the horizon and φ>0 means right wing down.
2. Saturn on the pad (VesselLibrary.apollo11OnPad, geodetic horizon): pitch 90.000° (±1e-9°), heading 90.000° (Position I east, the 90° pad azimuth, datasheet §15) and roll 0, by the singular branch. Turning the stack to the IU's space-fixed frame (flight azimuth 72.058°) reads 72.058°, so the singular convention is continuous with the roll program.
3. Published flight data: the PFT Table B-II rows in PACSS 13, with the geocentric horizon and the pole built from the pad's 28.6084° geodetic latitude and the 72.058° azimuth. The orbit-mode prograde marker's elevation and azimuth must equal FER Table 4-2's flight-path and heading angles (AS506Postflight.cutoffEvents) within 0.002° at S-IC CECO, S-IC OECO and S-II CECO. Computed for this brief: Δγ ≤ 0.001° and Δheading ≤ 0.001°. At S-II OECO and S-IVB ECO the tolerance is 0.015° (measured 0.011°/0.008° and 0.004°/0.002°), with the Table 10-2 offsets that AscentResidualTests already documents.
4. Pad velocity (datasheet §15.2, docs/AS506-datasheet.md:182: liftoff inertial velocity 408.64 m/s, heading 90°; 408.636 m/s on the WGS-84 pad). Orbit mode reads speed 408.636 ± 0.001 m/s, prograde elevation 0 and azimuth 90.000°. Surface mode has speed 0 and no prograde marker, and autoFrame is surface.
5. Deviation of the vertical: the geodetic and geocentric horizons at LC-39A, h = 0, differ by 0.1615°, from WGS-84 tan ψ = (1−e²) tan φ (NIMA TR8350.2). The radial-out marker sits that far from the navball zenith.
6. Spherical trigonometry on a circular orbit (placeInCircularOrbit, i = 32.5°):
   - at u = 0: pitch 0, roll 0, heading 57.5° (90° − i at the ascending node);
   - at u = 45°: heading from cos A = sin i cos u / cos φ, with sin φ = sin i sin u;
   - at u = 90°: heading 90°;
   - prograde projects to (0,0,front), normal to (−1,0) (left rim, north of an eastward track) and radial out to (0,1) (top rim).
7. Marker algebra: retrograde = −prograde, normal ⟂ prograde, triad orthonormality, project/front for ±x/±y/±z, the back-hemisphere edge-pointer angle.
8. Thrust marker:
   - at null gimbal it is the stage's mean thrust axis;
   - with one J-2 deflected by a set actuator angle it matches Thruster.thrustDirection's tan-tilt formula;
   - with an S-II engine failed, the four-engine mean;
   - it is hidden with engines off.
9. Command marker and attitude error: with attitudeCommand set 5° off in pitch, attitudeError.y = ±5° (the FCC sign of Autopilot.swift:305), and the command marker projects 5° from the centre along screen y. Under .prograde, the command marker equals the prograde target.
10. Aero angles: cos α cos β = cos(Vessel.angleOfAttack) within 1e-9 in an atmospheric step with winds (launch-day atmosphere).
11. autoFrame hysteresis: climbing switches at 50 km, descending at 40 km, and landed is surface.
Phase 2 tests:
- in surface frame the prograde autopilot target equals surfaceVelocity's direction;
- the existing radial tests (DynamicsTests:209, GimbalTests:246, SaturnVControlTests:65) stay green;
- nextEvent: the IGM's predicted S-IVB cutoff comes within 1 s of 699 s on the nominal flight fixture (NominalFlight.swift).

App, on the Mac (xcodebuild build/test per the project memory), using the scratch flight harness from memory (orbitsim-flight-harness: tree exported to the scratchpad, FlightHarness.swift hooked into AppModel.tick/refreshHUD, InputState.inject, an env-var plan, .req → screencapture -l<window>, never in the user's checkout):
- Shots of the AS-506 scenario (Release, 10×/100×):
  - pad, paused: blue zenith at the centre, HDG 090;
  - r20: HDG 072, roll program done;
  - r83, max-Q: horizon rising from the bottom;
  - r161.7, OECO: the prograde marker on about the 19° ladder line at about 075.4, matching the model's 19.07°/75.37° (datasheet §17);
  - after S-IVB cutoff and the local horizontal: nose on the horizon at HDG about 088, prograde at the centre within γ, normal at the left rim, the green IU command marker on the nose.
- Log `instruments.navball` readouts beside every shot and check them against those numbers and Navball.project positions.
- LEO capsule: keys 1–7 in turn, a shot after 20 s each, with the nose (W) on the matching marker.
- On the pad, N toggles the mode: no surface prograde, orbit prograde at 090 on the horizon.
- F2 cycles, and windows of 1400×900 and 900×600 show no overlaps.
- A navball gallery via renderToImage: canned attitudes (vertical; 45°/072°; level with 30° bank; inverted) for review by eye.
- Performance: achieved warp (effectiveWarp) at 1000× in Release with the cluster on and off must not drop measurably (budget 40 ms per frame, about 22 fps).

## Files touched

- Sources/OrbitCore/Instruments/LocalHorizon.swift (new)
- Sources/OrbitCore/Instruments/Navball.swift (new)
- Tests/OrbitCoreTests/NavballTests.swift (new)
- Sources/OrbitSim/HUD/NavballView.swift (new)
- Sources/OrbitSim/HUD/NavballRenderer.swift (new)
- Sources/OrbitSim/HUD/NavballShaders.swift (new)
- Sources/OrbitSim/HUD/NavballArtwork.swift (new)
- Sources/OrbitSim/HUD/InstrumentModel.swift (new)
- Sources/OrbitSim/HUD/InstrumentCluster.swift (new)
- Sources/OrbitSim/Views.swift (layout restructure, help rows)
- Sources/OrbitSim/AppModel.swift (about 4 lines of wiring; HUDState additions for the vehicle panel)
- Sources/OrbitSim/Input.swift (F-key/arrow/tab names, held modifiers)
- README.md (controls table, HUD section)
- docs/ROADMAP.md (Engine and tooling: HUD instruments done)
- Phase 2: Sources/OrbitCore/Vessel/Autopilot.swift, Sources/OrbitCore/Vessel/Vessel.swift, Sources/OrbitCore/Simulation/Simulation.swift (autopilot velocity frame, spin telemetry)
- Phase 2: Sources/OrbitCore/Guidance/FlightProgram.swift, Sources/OrbitCore/Guidance/SaturnIU.swift (nextEvent)
- Phase 2: Tests/OrbitCoreTests/NavballTests.swift additions, Tests/OrbitCoreTests/SaturnIUTests.swift (nextEvent)

## Depends on

Phase 1 has no hard dependency and builds on main at 6873da7. The core part (LocalHorizon, Navball, tests) can run in a Linux cloud session first; the app part needs a Mac session.

Coordination with the parallel sessions:
- Graphics consolidation: no shared files. The navball has its own MTKView and shaders, and NavballRenderer.encode(into:viewport:state:) lets it move into a future overlay pass.
- MFDs (Orbiter-style): shared folder Sources/OrbitCore/Instruments/ with disjoint file names. The HUD session lands the Input.swift special-key/modifier table and the layout with two MFD slots first. The MFD session swaps the two corner panels (a two-line change in Views.swift), adds its own `let mfds = MFDModel()` beside instruments in AppModel, and takes keys from F1, F3-F12, ; ' or Shift/Ctrl combinations. The maneuver marker takes the burn planner's Δv direction (Navball init parameter `maneuver: Vec3?`).
- Separation, re-entry and splashdown: target mode shows the CSM–S-IVB separation rate. The phase 2 Autopilot.swift change (autopilot follows the surface/air frame, which entry needs for heat-shield-forward retrograde) should merge before or within the entry session's autopilot work, not in parallel. The entry session owns any aerodynamic bank (lift-vector) readout and can add it to Navball as μ about the air velocity.

## Options (owner decisions)

1. Horizon "up" for the ball and readouts. Recommended: the geodetic WGS-84 normal, which matches the HUD altitude, the camera and the pad's 90.000°. Alternative: the geocentric radius (KSP's spherical planets, the FER's γ convention). They differ by 0.16° at the Cape.
2. Radial markers and the radial autopilot. Recommended: keep ±r̂ (today's autopilot, Orbiter-like), with the markers matching the autopilot. Alternative: KSP's radial perpendicular to prograde in the orbit plane, for both; this changes the definition in Autopilot.swift and touches three radialOut tests. The two differ by the flight-path angle (about 0 in the parking orbit, about 20° late in the S-IC burn).
3. Should the autopilot follow the navball speed mode (KSP SAS), so prograde means surface prograde in surface mode? Recommended: yes, in phase 2, sequenced with the entry session. Until then the green command marker shows where 1/2 really point.
4. Speed-mode auto switch. Recommended: surface when landed or below 40 km descending, orbit above 50 km ascending, and N overrides until the next crossing. Alternative: manual only.
5. Rendering. Recommended: a Metal ball in its own transparent MTKView with a procedural texture and a marker atlas, plus SwiftUI TimelineView/Canvas for the tapes. Alternative: an all-SwiftUI Canvas 2-D ADI (about a day cheaper, flatter look).
6. Heading/roll at the vertical. Recommended: the belly (+z) convention (heading 090 on the pad, continuous through the Saturn's roll and pitch programs). Alternative: the top (−z) convention, which suits vehicles pitched toward −z, such as today's Pathfinder. Optionally the Pathfinder scenario could be placed with azimuth 252 so its belly faces downrange like the Saturn's (one line in Scenarios.swift).
7. Look. Recommended: KSP-like palette (blue/brown ball, yellow/magenta/cyan markers). Alternative: an Apollo FDAI style (white/black ball, rate and error needles), as a later toggle.
8. Keys. Recommended: N (speed mode), F2 with ` alias (HUD visibility), Y in phase 2 (target). The F-keys and ; ' stay free for MFDs.
9. Extra markers now or later. Recommended: command (flight director) and thrust markers now; target, maneuver and FDAI error needles in phase 2.

## Effort

Phase 1: about 4 focused session-days.
- Core, LocalHorizon/Navball and 11 tests: 1.0 day (Linux-capable).
- Navball Metal view, shader, CoreGraphics texture and marker atlas, renderToImage: 1.25 days.
- Instrument cluster (tapes, VSI, throttle, autopilot column), Views.swift layout, InstrumentModel, Input.swift keys: 1.0 day.
- Harness flights and screenshots, fixes, README/ROADMAP/help: 0.75 day.
Phase 2: about 1.5–2 days.
- Autopilot follows the speed frame, with tests: 0.5.
- FlightProgram.nextEvent and the SaturnIU implementation, with tests: 0.5.
- Target mode, Y key, target markers, edge pointers for more markers, maneuver-marker hook, FDAI needles: 0.5–1.
Phase 3 (later, optional): ball reference modes (inertial/IU space-fixed, LVLH) and an Orbiter-style scene HUD for a cockpit camera, about 1–1.5 days.

## Risks

- Two MTKViews: frame ordering is at most one frame of lag between the ball and the scene. The transparent layer must composite (layer.isOpaque = false, premultiplied alpha). The navball view must not take first responder or mouse events (hitTest → nil, acceptsFirstResponder false), or keyboard flying breaks; GameView re-asserts first responder only in viewDidMoveToWindow. Fallback: draw the ball through an overlay hook in Renderer, coordinated with the graphics session.
- Main-thread cost: a TimelineView + Canvas at 60 Hz plus a third sim.snapshot per frame (camera, renderer, instruments) compete with the 40 ms step budget at high warp. Measure effectiveWarp in Release with the cluster on and off. Fall back to 30 Hz for the tapes, or cache one snapshot per frame in AppModel.
- Euler readouts jump near the vertical (heading/roll at |θ| near 90°). This is inherent; the chosen convention keeps the Saturn continuous, and the ball itself has no singularity.
- Definition mismatches a KSP player will notice: radial ±r̂ vs perpendicular-to-prograde, and the autopilot flying orbit prograde while the ball shows surface prograde. The command marker makes the truth visible until owner options 2 and 3 are settled.
- The geodetic zenith and the geocentric radial differ by 0.16° at mid-latitudes; the level autopilot (geocentric) sits that far off the ball's horizon. Negligible on screen, but documented.
- Label legibility and aliasing on a 220 pt ball; the poles of an equirect texture. Mitigation: mipmaps, gradient sampling (Tarini), labels pre-stretched by 1/cos(el), MSAA 4.
- Merge conflicts: AppModel.swift, Views.swift and Input.swift are hotspots shared with the MFD session. Mitigation: InstrumentModel in its own file with roughly 4 wiring lines, the HUD session landing the Input key table and MFD slots first, and disjoint file names in Instruments/. Phase 2 Autopilot.swift edits must not run in parallel with the entry session's.
- F2 needs fn on Mac laptops, hence the ` alias.
- Licensing: Orbiter is MIT (ideas from hud.cpp, such as the off-screen direction marker and TAS/GS switching, are fine; if any code is ported, keep its MIT notice), but its OVP/D3D9Client is LGPL and its textures are not in the repo, so avoid both. KSP's art is proprietary, so all navball art is generated procedurally. NASSP (GPL) is not used.

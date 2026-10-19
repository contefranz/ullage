> Planning document for milestone M1.5, written on 2026-10-19 by a design study (five design reports checked by a planner) and accepted by Franz with the recommended defaults (US keyboard; see the correction below). Track briefs refer to it. Where code has moved on, the code wins.

> **Correction (2026-10-19): Franz's keyboard is a US (ANSI) layout, not Italian.** Keep physical key positions (`event.keyCode`) for every binding anyway: they make arrows and F-keys bindable, keep Shift-modified keys from leaking into `held`, stop keys sticking when Shift is released first, and let the MFDs use left/right Shift as Orbiter does. Drop the Italian-layout checks; verify on the US layout. The key left of 1 is the backtick (`` ` ``, keyCode 50 on ANSI). `=`, `-`, `/` and `[ ]` are unshifted keys and stay as they are.

# M1.5 plan: a flyable Apollo Earth-orbit mission, from the pad to splashdown

## Report checks (what this plan changes)

**Confirmed against main (6873da7, 203 tests)**
- `AttitudeAutopilot.target(for:)` is internal. Radial is ±r̂ (Autopilot.swift:35-50), and three tests use `.radialOut`: DynamicsTests:209, GimbalTests:246 and SaturnVControlTests:65.
- Above 86 km the atmosphere uses Vallado's exponential rows with T fixed at 186.87 K (Atmosphere.swift:137-178).
- `InputState.key(for:)` lower-cases `charactersIgnoringModifiers` (Input.swift:26-31).
- The renderer has no `sampleCount` and no `setCullMode`.
- `separate` copies only `status` and `aerodynamics` (Vessel.swift:206-209).
- The CSM is one `.fixed` part (SaturnV.swift:307-317).
- Surface contact has a single 5 m/s rule (Simulation.swift:342).
- `SaturnIU.allowsManualStaging` returns T3 (SaturnIU.swift:412).
- Orbiter is MIT: `gh api …/license` returns MIT, and Src/Orbiter/hud.cpp carries the "Licensed under the MIT License" header.

**Corrections**
1. **The two reports disagree on the CM frame.** The entry report maps +Zc to +z. Datasheet §12 (docs/AS506-datasheet.md:1618, graded H) says X_A = +x, Y_A = −y, Z_A = −z in construction axes, and the CM must be built in that frame to sit in the stack. Fix: one `ApolloAxes.construction(xa:ya:za:)` helper used by both builders. The lift side comes from the CG offset, never a hard-coded ±z, and a test pins the sign.
2. **The navball's vertical convention depends on the pilot frame.** The navball report reads the vertical case from the Saturn's belly (+z), which only works in Saturn construction axes. With the spacecraft report's crew `controlFrame` (Rx(π)), the reference must be the head (−z) instead. That also matches the M0 vehicles: `placeLanded` points −z at the azimuth, and `placeInCircularOrbit` puts −z away from the body.
   - Pad: HDG 090, PIT 90, RLL 0.
   - After the roll program: HDG 072.
   - After pitch-over: HDG 072 with roll 180. The crew flies heads-down, and roll 180 is the IU's orbital attitude too.

**Under-scoped**
- **Debris will kill time warp in orbit.** The global step is the minimum over every vessel (Simulation.swift:119-136, a 0.05/ω limit per vessel).
  - Four SLA panels tumbling at ≥33.5°/s cap every step at 0.086 s. Today's parking-orbit step is about 5.3 s, so that is about 60 times more steps.
  - The SM's −X jettison jets then force 0.02 s steps before entry interface (EI).
  - Fix: a step policy for passive vessels (track C).
- **Keys on the owner's Italian layout** (to confirm on the keyboard):
  - `=` and `/` need Shift, and `[ ]` cannot be typed at all.
  - The held set is keyed by character, so Shift+0 then releasing Shift first leaves `=` held and the throttle runs away.
  - The MFDs' "Shift goes to the MFD" rule would break throttle-up.
  - Fix: physical keyCodes for every binding (S0).
- **Two programs, one slot.** The CSM needs an ΔV counter that cuts the engine off at zero, modelled on the Entry Monitor System (EMS), and the CM needs the entry program. `Vessel.flightProgram` holds only one. Fix: `ApolloSCS` hosts `CMEntryProgram`.
- **Aerodynamic model order.** The launch models require ["S-IC","S-II","S-IVB"], ["S-II","S-IVB"] and ["S-IVB"] (AS506Data.swift:1083-1099). The CSM drag model, then the CM model, must come after them in the list.
- **Shared hot files.** Vessel.swift, Simulation.swift, Components.swift and AppModel.swift are wanted by three or four tracks each. File ownership cannot be disjoint without mechanical splits first (S0).
- **The CM RCS must not be `activeStageOnly`.** Once the SM is gone, no part carries `.main`.

**Duplicates resolved to one owner**

| Item | Owner |
|---|---|
| CM part and CM RCS | E2 |
| Sutton–Graves heating | E1 (graphics reads `heatFlux`) |
| Marker glyph art | A (`MarkerGlyphs.swift`, which G2 reuses) |
| Transcription of 68-FM-184 and the Apollo 7/11 Mission Reports | D |
| Land mask | E2 |
| Conic sampler and `trueAnomalies(atRadius:)` | B1 |
| The autopilot following the speed mode (navball phase 2, entry; both need Autopilot.swift) | Deferred: the green command marker shows the truth |

**Over-scoped, cut or deferred**
- **MFDs: 10.5 → 7.5 days.**
  - No AS-506 ascent overlay plots and no UNT units toggle.
  - No `ManeuverProgram` auto-ignition. It is replaced by the EMS-style ΔV counter cutoff, which is how the SCS really backed up the SPS.
  - No lunar MFDs.
- **Entry: Apollo 11's lunar-return entry and constant-g guidance move to M2.** A display-only landing-point predictor is added.
- **Graphics: 11.5 → 8 days.** No ocean, plasma sheath, S-IC fins or plates, night lights, cockpit camera or `OverlayPass` yet.
- **Spacecraft: the SPS sump/storage series feed waits for M2's long burns.** Storage and sump are lumped per propellant.

## Roadmap placement

**New milestone M1.5, "Apollo Earth-orbit mission, from the pad to splashdown"**, between M1 and M2. No renumbering, because CLAUDE.md refers to M3.

What it takes from elsewhere:
- From M2: the CSM SPS, CSM separation, and "command module entry aerodynamics (lift vector control), parachutes, splashdown".
- From Engine and tooling: "HUD instruments, MFD-style displays".
- From M3: the RCS quads, as thrusters only (no systems).

M2 keeps S-IVB restart and TLI, transposition and docking, the LM, lunar gravity and terrain, constant-g lunar-return entry, and the lunar MFDs.

**Definition of done**
1. **AS-506 from the pad, flown with only the HUD, navball and MFDs:**
   - the IU flies to the parking orbit;
   - Space separates the CSM: four SLA panels, and the S-IVB + IU + LM leave with the IU program;
   - key 2 turns the CSM retrograde on the SM RCS;
   - the DEORBIT MFD gives the Δv and the time of ignition (TIG);
   - Z lights the SPS, and the ΔV counter cuts it off;
   - Space twice separates CM/SM;
   - the CM holds trim lift-up to EI and is flown in bank (or bank hold);
   - the earth landing system (ELS) fires on baroswitch pressure;
   - the log reads "splashdown at x m/s" in water, and the MAP shows the splash point.
2. **Apollo 7 reference chain in `swift test`:**
   - the SPS-8 cutoff state (Mission Report Table 3-III) and EI;
   - the CM from 68-FM-184 Table IX(b) EI at 55° bank lands within about 30 n mi of 29.8° N 67.0° W;
   - the ELS phase durations fall within their bands.
3. **Regression guard:**
   - every M1 test passes, with the §17 residuals unchanged;
   - `swift test` is green on Linux;
   - `xcodebuild build test` is green on the Mac;
   - the owner has reviewed the screenshot set;
   - README, ROADMAP and CLAUDE.md are updated.

## Tracks

| Track | Branch | Where | Days |
|---|---|---|---|
| S0 Seams | `m15-seams` | Mac | 1.25 |
| D Spacecraft data | `m15-apollo-spacecraft-data` | Mac (downloads) | 2.0 |
| A Navball + flight HUD | `m15-navball-hud` | Mac (core part Linux-capable) | 4.0 |
| A2 HUD phase 2 | `m15-hud-entry-target` | Mac | 1.25 |
| B1 Navigation core | `m15-navigation-core` | Linux/cloud | 2.5 |
| B2 MFDs | `m15-mfd` | Mac | 5.0 |
| C CSM/SM, staging, SPS/RCS | `m15-csm-staging` | Linux/cloud | 5.5 |
| E1 Entry flight | `m15-cm-entry` | Linux/cloud | 6.25 |
| E2 CM vehicle, ELS, splashdown | `m15-cm-els-splashdown` | Linux/cloud | 4.0 |
| G1 Shapes and light (core) | `m15-apollo-shapes` | Linux/cloud | 2.0 |
| G2 Renderer | `m15-renderer` | Mac | 6.0 |
| I Integration and flight test | `m15-integration` | Mac | 2.5 |

### S0 — Seams (lands before any parallel work; no behaviour change except keys)

**Input.swift**
- A `PhysicalKey` taken from `event.keyCode`, covering:
  - letters, digits and punctuation by ANSI position;
  - space, esc, tab, F1–F12 and the arrows;
  - the key left of 1 (keyCode 50 on ANSI, 10 on ISO; to be verified on the Italian keyboard).
- `held: Set<PhysicalKey>`, so key-up always matches key-down.
- Modifier state with the Shift side, from the device bits 0x2 (left) and 0x4 (right).
- `takeMFDKeys() -> [(side, PhysicalKey)]`. Shifted keys never enter `held` or `pressedQueue`.
- `AppModel.handleKeys` keeps today's bindings on physical keys and goes through `Vessel.setPilotInput`.

**Mechanical splits**

| Moves from | To | Owner afterwards |
|---|---|---|
| `VisualShape` in Components.swift | Vessel/VisualShape.swift | G1 |
| SaturnV.swift's inline shape lines | Vessel/ApolloShapes.swift, `VesselLibrary.dressSaturnV(_:)` (same shapes) | G1 |
| Vessel.swift's staging section (`separate`, `jettison*`, `activeStage`) | Vessel/Staging.swift | C |
| `Simulation.stage` | Simulation/SimulationStaging.swift (a module cannot hold two Staging.swift) | C |
| `maxStep()` and `maxStep(for:)` | Simulation/StepControl.swift | C |
| `placeLanded` and `placeInCircularOrbit` | Simulation/Placement.swift | — |

Placement.swift also gains `place(_:geodeticLatitude:longitude:height:inertialSpeed:flightPathAngle:azimuth:attitude:)`.

**Declared interfaces**
- Vessel/ApolloAxes.swift.
- On `Vessel`:
  - `controlFrame` (identity) and `setPilotInput(rotation:translation:)`;
  - `sensedAcceleration`, `loadFactor`, `bankAngle: Double?`, `heatFlux`, `heatLoad` (zero until E1);
  - `impactLimits`;
  - `parachutes: [Parachute]`, with a minimal `Parachute` in Vessel/Parachute.swift (E2 fills it in);
  - `entryCommand: EntryCommand?`, with a stub in Vessel/EntryAutopilot.swift (E1 fills it in).
- An empty `Simulation.updateEntryTelemetry(_:snapshot:)` in Simulation/EntryTelemetry.swift, called from `updateTelemetry`.
- On `FlightProgram`: `hostPart` and `nextEvent(at:)`, both defaulting to nil.
- A `DeltaVCounting` protocol.
- Package.swift: `OrbitInstruments` and `OrbitInstrumentsTests` targets, as skeletons.

**Naming contract** (written into ROADMAP's M1.5 section)
- Parts: "S-IVB", "IU", "SLA ring", "SLA panel 1"–"4", "LM", "SM", "CM", "Apex cover", "Drogue parachutes", "Main parachutes".
- Events: 6 is CSM/S-IVB, 7 is CM/SM, and 30, 31, 32 are apex cover, drogues and mains.
- Thrusters: "SPS", "SM RCS A1"…, "CM RCS 1A"….

**Tests**
- PlacementTests: round trip to 1e-6.
- An ApolloAxes sign test: the LES's lean towards +Z_A comes out as −z.
- The 203 existing tests stay green.

**Done when:** xcodebuild build and test pass, a Saturn flight shows the keys unchanged on US and Italian layouts, and nothing sticks.

### D — Spacecraft data (start with S0)

Download the primary PDFs into the scratchpad (owner decision 3) and transcribe the page images with two readers into new `tools/data/*.csv` files, with a transcription log in docs/data/apollo-spacecraft/.

In priority order:
1. 68-FM-184 Tables I(a)–(d) and IX(b), and the §5.4 numbers (needed by E1 and C).
2. Apollo 7 Mission Report:
   - Table A.5-I, p. A-47;
   - Tables 2-I and 3-III;
   - §5.16 and §5.21.
3. Apollo 11 Mission Report: Table A-I with its inertias, and §8.11.1.
4. TN D-5399 Tables I and II; TN D-5276 trim points.
5. TN D-7437 ELS: reefing, timings and descent rates.
6. 68-FM-160, MSC-03466, and AOH §2.4 and §2.5.
7. US Standard Atmosphere 1976, 86–1,000 km.

TN D-6725 is low priority and only matters for M2.

**Done when:** each CSV carries its source, page and H/M/L grade, and the garbled Apollo 7 rows (7-9, 12, 16, 17, 21) are re-read against the page image.

### A — Navball and flight HUD

This is the navball report's phase 1, with these changes:
- the ball and readouts use `attitude * controlFrame` and the head (−z) vertical convention;
- the ball is drawn in its own transparent pass-through MTKView;
- A owns Sources/OrbitSim/HUD/MarkerGlyphs.swift (CoreGraphics paths, shared with G2);
- A creates Sources/OrbitSim/MFD/MFDPanelsView.swift as a stub that shows today's surface and orbit panels, and B2 takes the file over.

**Files**
- Core: Sources/OrbitCore/Instruments/LocalHorizon.swift and Navball.swift; Tests/OrbitCoreTests/NavballTests.swift.
- App: HUD/NavballView, NavballRenderer, NavballShaders, NavballArtwork, InstrumentModel, InstrumentCluster and MarkerGlyphs.
- Views.swift: layout, help and MFD slots.
- AppModel.swift: about 4 lines of wiring, plus HUDState rows for the next Space group and TWR.

**Keys:** N for the speed mode; F2, with the key left of 1 as an alias, for HUD visibility.

**Tests:** the navball report's 11. Test 2 is rewritten for crew axes:
- the pad reads 090/90/0;
- with the roll program done, the heading reads 072.058;
- pitched over, the roll reads 180.

Until C sets `controlFrame` (it is identity on main), test 2 builds the crew frame itself.

**Done when:** the harness screenshots match `Navball.project` at the pad, r20, max-Q, S-IC OECO (19.07° / 075.37°, datasheet §17) and the post-cutoff local horizontal, and in the LEO capsule keys 1–7 put the waterline symbol on each marker.

### A2 — HUD phase 2 (after C and E1)
- Entry readouts: g meter, bank, heat flux, ELS state, the 0.05 g light.
- Target mode: Y selects the S-IVB after separation; the ball shows target and anti-target markers, and the HUD range and range rate.
- A manoeuvre marker from B1's planner.
- `FlightProgram.nextEvent` implemented in SaturnIU.swift (after C merges).

**Test:** the IGM's predicted S-IVB cutoff comes within 1 s of 699 s on NominalFlight.

### B1 — Navigation core

**Files in Sources/OrbitCore/Navigation/**
- Kepler.swift: universal variables; time to a radius or anomaly.
- GroundTrack.swift:
  - rigid Earth rotation plus secular J2;
  - the subsolar point and terminator from DE421;
  - the horizon circle and a track recorder.
- DeorbitPlanner.swift:
  - impulsive Δv to a target perigee or EI γ;
  - TIG now or at an apsis;
  - burn time from the rocket equation;
  - post-burn elements.
- EntryInterface.swift: vacuum EI at 121,920 m; great-circle range and bearing.

The OrbitalElements.swift extension adds `semiMinorAxis`, `argumentOfLatitude`, true and mean longitude, `perifocalBasis`, `conicPoints(n)`, the node vectors and `trueAnomalies(atRadius:)`.

**Tests**
- Kepler:
  - Vallado's KEPLER example;
  - against RK4 two-body to within 1 m over one orbit;
  - a round trip and a hyperbolic case.
- Ground track:
  - node drift of −22.1° − 0.47° per orbit at 185 km and 32.5°;
  - against a full integration to within 0.05° over 3 orbits;
  - the subsolar point against Horizons.
- EI against a stepped vacuum coast: 0.1 s and 0.01°.
- Hohmann and retrograde Δv against textbook values.

**Done when:** all of this is green on Linux.

### B2 — MFDs

**Files**
- New `OrbitInstruments` target:
  - MFDPage.swift, MFDMode.swift, MFDController.swift, MFDFormat.swift;
  - Modes/OrbitMFD, SurfaceMFD, MapMFD, DeorbitMFD, EntryMFD.
- Tests/OrbitInstrumentsTests/: key routing, and page content for a 185 km / 32.5° orbit (`PeA 185.0k`, `Inc 32.50°`).
- Sources/OrbitSim/MFD/:
  - MFDPanelsView.swift (taken over from A's stub);
  - MFDPanelView.swift (Canvas display list, side buttons, PWR/SEL/MNU);
  - MFDModel.swift: pulls `input.takeMFDKeys()` and the sim at 4 Hz, with the map's future track at no more than 1 Hz;
  - Coastlines.swift and its resource.
- tools/make_coastlines.py (Natural Earth 1:110m).

B2 makes no edits to AppModel, Views or Input.

**Keys:** Orbiter's scheme, with left Shift driving the left MFD and right Shift the right one.

**Page notes**
- DEORBIT:
  - TIG, Δv per LVLH axis, burn time, HA/HP after the burn, predicted EI;
  - a SET button that loads the ΔV counter through `DeltaVCounting`.
- ENTRY waits for E1's telemetry and predictor.
- The HUD's bottom-centre orbit panel goes when ORBIT lands.

**Done when:** on the Mac:
- ORBIT agrees with the HUD and with §17's parking orbit;
- MAP's predicted track overlays the recorded one an orbit later;
- Shift+Z and Shift+X no longer move the vehicle;
- both Shift sides work on the Italian keyboard.

### C — CSM/SM, staging, SPS and RCS

This is the spacecraft report's design, with lumped storage and sump tanks, D's data, and these changes.

**Files**
- New: ApolloCSMData.swift and ApolloCSM.swift.
  - The SM, the SPS with its gimbal nulls, and four SM RCS quads built by `addSMRCSQuad`, all `activeStageOnly`.
  - "SLA ring" and four panels.
  - The scenario builders `apollo11InParkingOrbit` and `apollo7BeforeDeorbit`.
- Existing: SaturnV.swift, AS506Data.swift (spacecraft stations), Components.swift.
  - Components.swift changes: `StagingTrigger` for liquid engines, `Thruster.sequence`, and on parts `separationGroup`, `separationVelocity`, `separationRate` and `isCrewed`.
- Vessel/Staging.swift:
  - multi-vessel `jettison`;
  - migration of the program and control state by `hostPart`;
  - the crewed vessel keeps its id;
  - `controlFrame` is set from the crewed part.
- Simulation/SimulationStaging.swift: `stage` returns several vessels.
- Simulation/StepControl.swift: passive vessels (not the focus, not controlled, q < 1 Pa) are not held to the 0.05/ω limit and take relaxed steps while thrusting.
- SaturnIU.swift: refuses staging while the S-IVB burns, and `hostPart` "IU".
- AS506FlightProgram.swift.
- New Guidance/ApolloSCS.swift (`ApolloSCS: FlightProgram, DeltaVCounting`):
  - the EMS ΔV counter with SPS cutoff;
  - the automatic 3 s +X ullage at CSM/LV separation;
  - the two-press guard for event 7;
  - a `successor` program run once the SM leaves.

The CSM and CM aerodynamic models are appended after the AS-506 models.

**Tests** (the spacecraft report's set, minus the sump test)
- CSMDataTests, CSMMassPropertiesTests (at the rows the scenarios use), CSMSeparationTests, CSMPropulsionTests.
- Apollo7DeorbitTests to EI.
- Updates to SaturnVDataTests, MassCharacteristicsTests, SaturnVFlightTests, SaturnIUTests and StagingTests.
- A warp test: with the panels tumbling in the parking orbit, the step stays at 1 s or more.

C uses a temporary "CM" part until E2's first PR merges.

**Done when:** the §17 residuals have not moved.

### E1 — Entry flight

**Files**
- New: CapsuleAerodynamics.swift (the sphere-centre trim model with two calibrations, the subsonic anchor and the Newtonian blend).
- Existing: Aerodynamics.swift (delegation with the CoM off the axis).
- Simulation/EntryTelemetry.swift:
  - sensed g and load factor;
  - bank angle about the air velocity, towards the CG-offset side;
  - Sutton–Graves heat flux and load.
- EntryAutopilot.swift and Autopilot.swift (the `.entry` case).
- Guidance/CMEntryProgram.swift:
  - dormant while "SM" is aboard;
  - arms the CM RCS and holds trim lift-up before entry;
  - 0.05 g;
  - manual, bank-hold and rolling modes;
  - runs E2's ELS;
  - drops the launch-day sounding.
- A display-only landing-point predictor (3-DOF, 1 s steps).
- Atmosphere.swift: the 1976 tables from 86 to 1,000 km.
- Its last PR adds Guidance/ApolloMission.swift, which wires `ApolloSCS.successor = CMEntryProgram`.
- docs/CM-entry-datasheet.md.

**Tests:** the entry report's CapsuleAerodynamicsTests, UpperAtmosphereTests and EntryTests (bank geometry, DAP, 0.05 g), and the Apollo 7 deorbit-to-splashdown end-to-end test.

**Done when:**
- the trim checks pass at every row of 68-FM-184 Table I(a), against DeRose, and against Apollo 4;
- Apollo 7 peaks at 3.3 ± 0.3 g and lands within about 30 n mi of the preflight point.

### E2 — CM vehicle, ELS and splashdown

**Files**
- New: CommandModule.swift: `VesselLibrary.commandModuleParts(_:)` in `ApolloAxes`:
  - the CM structure;
  - two CM RCS systems, not `activeStageOnly`;
  - the apex cover, drogue pack and main pack, matching the Mission Report rows.

  This is E2's **first PR**, and C needs it.
- Parachute.swift: loads at the attach point with ω×r and a reefing schedule.
- EarthLandingSystem.swift: baroswitch pressures 39.3 and 69.7 kPa, and the mortar and reefing timers.
- SurfaceMask.swift, plus Resources/landmask.bin and tools/make_landmask.py.
- Existing:
  - CelestialBody.swift: `surfaceKind`;
  - Simulation.swift: parachute loads in `deriv`, water contact and impact limits, Stable I;
  - Vessel.swift: `LandedState.surface`;
  - Package.swift: the resource line.

**Tests:** ParachuteTests (descent rates; ELS by pressure; 53 ± 5 s on drogues, 285 ± 20 s on mains), SplashdownTests (land mask points; water versus land; M0 limits unchanged), and the CM mass rows.

### G1 — Shapes and light (core)

**Files**
- VisualShape.swift:
  - `.revolution(profile:segments:sweep:)`;
  - `capBase`/`capTop`/`twoSided`;
  - a `thruster` link;
  - an emissive role.
- ApolloShapes.swift:
  - bells with exit radius √(A_e/π), linked to their thrusters;
  - open interstages;
  - the SM, the SPS bell and the quads;
  - the CM's spherical heat shield, toroidal shoulder and 33° afterbody;
  - "SLA ring" and four panel sweeps;
  - a crude LM; the LES and BPC.

  Shapes are assigned by part name and cover today's "CSM" as well as the split.
- Bodies/Eclipse.swift: the conical model.

**Tests**
- VisualShapeTests: every part dressed; links resolve; sourced dimensions.
- EclipseTests: 42.4 % of 88.3 min at β ≈ 0; a 6-15 s penumbra.

### G2 — Renderer

**Files:** Renderer.swift, Shaders.swift, Meshes.swift, RenderTypes.swift, plus new Plumes.swift and SpriteAtlas.swift.

**Work**
- MSAA 4× and back-face culling on closed meshes; two-sided open shapes.
- Light uniforms: sunlit fraction, earthshine and an ambient floor.
- The lathe builder.
- Visible gimballing as dynamic mesh groups.
- Plumes: additive cone impostors, with styles from propellant and `isSolid` and a floor so they stay visible in vacuum, using `setVertexBytes` or a ring buffer instead of `makeBuffer` every frame.
- Orbit-line markers Pe, Ap, AN, DN and EI.
- Heat-shield glow from `heatFlux`, with a thermal lag.
- Parachute canopies and risers from `Vessel.parachutes`.

Ocean, plasma sheath and cockpit camera are deferred.

### I — Integration and flight test (last)

**Files:** Scenarios.swift, AppModel.swift (keys only), Views.swift (help only), README, ROADMAP, CLAUDE.md.

**Scenarios added**
- AS-506 continued into an Earth-orbit return.
- Apollo 11 in parking orbit.
- Apollo 7: deorbit and entry.
- Apollo 7 CM at EI.

**Keys:** 9 cycles the entry mode.

**Then:**
- the full harness flights and screenshots;
- performance checks;
- fixes;
- the CLAUDE.md status line and the new target's build notes.

## Dependencies and merge order

```
S0 ─┬─ A ──────────── A2 ─┐
    ├─ B1 ─┐              │
    ├─ B2 ─┴(ENTRY page)──┤
D ──┼─ E2(PR1: CM parts) ─ C ─┐
    ├─ E1 ─────────────── E1(mission wiring + Apollo 7 end-to-end) ─┤
    ├─ E2(rest) ──────────────┘                                      ├─ I
    └─ G1 ─ G2(lathe, glow and parachutes after E1/E2) ──────────────┘
```

**Merge order**
1. S0, with D in parallel (D touches no code).
2. B1, G1, A, then E2's first PR.
3. E1's aerodynamics and telemetry PR, then C.
4. E2's rest, then B2 (after A, whose MFD stub it replaces).
5. E1's wiring and Apollo 7 end-to-end PR.
6. G2, then A2, then I.

**Rules**
- File ownership is as listed. A file changes owner only after the previous owner's PR has merged: SaturnIU.swift goes from C to A2; AppModel.swift and Views.swift go from A to I.
- Before each merge, test the combined branch, main plus the PR, with `swift test`, and with `xcodebuild` for app PRs. Merge with plain `gh pr merge`, without `--delete-branch` (project memory).
- Commits are authored as the owner, with no Claude trailers (CLAUDE.md overrides the harness attribution).

## Owner decisions (defaults in bold; "accept defaults" settles them all)

**Scope**
1. **New milestone M1.5 between M1 and M2. M2 keeps TLI, docking, the LM, lunar work and lunar-return entry.**
2. Scenarios: **AS-506 continued into an Earth-orbit return (Apollo 11 with TLI no-go); "Apollo 11 in parking orbit"; "Apollo 7: deorbit and entry"; "Apollo 7 CM at entry interface"**.
3. Data: **D may download the large primary PDFs (Apollo 7 and 11 Mission Reports, 68-FM-184, TN D-7437, TN D-5399/5276, 68-FM-160, MSC-03466) into its scratchpad, never into the repo, and transcribe them with two readers.**
4. Parallelism: **up to 4 Mac and 4 cloud sessions at once.** Fewer means about 14-15 calendar days instead of about 10.5.

**Vehicle**

5. **The crew keeps the vessel (id, name, focus). The S-IVB/IU/LM side leaves with the IU program.**
6. **Apollo crew axes (`controlFrame` = Rx(π)) on every vessel that carries the CM, from the pad. The navball uses the head (−z) vertical convention.** W/S and A/D flip on the Saturn compared with M1; ascent and orbit read roll 180, heads-down.
7. SLA: **four tumbling panels, as Apollo 11 flew** (the alternative, panels staying on the S-IVB, saves 0.75 day).
8. SPS and RCS:
   - **68-FM-184's rating (21,080 lbf, 312.34 s);**
   - **storage and sump lumped per propellant;**
   - **ullage below 22,300 lb not enforced, with a HUD hint;**
   - **automatic 3 s +X at CSM separation;**
   - **Apollo 11's SM jettison logic;**
   - **a CSM phase-plane law with 0.5°/5° dead bands;**
   - **both CM RCS systems.**
9. Deorbit: **an EMS-style ΔV counter cuts the SPS off; the pilot ignites with Z at TIG. Automatic P40 waits for M3.**
10. **CM/SM separation needs two Space presses within 2 s.**

**Entry**

11. **Trim-calibrated sphere-centre aerodynamics with a Newtonian blend. The app is flight-consistent above Mach 10; the MSC tables are kept for the Apollo 7 comparison.**
12. **Manual roll, bank hold and rolling, plus a display-only landing-point predictor. Constant-g goes to M2 and predictor-corrector guidance to M3.**
13. **The 1976 atmosphere to 1,000 km. The launch-day sounding is dropped when the entry program activates.**
14. **A 0.25° Natural Earth land mask; sea level on the ellipsoid; the CM floats in Stable I at once; a CM water-impact limit of about 15 m/s (L); Sutton–Graves heating as telemetry only.**

**HUD and MFDs**

15. Keys: **physical key positions for every binding:**
    - **Orbiter's left/right Shift for the MFDs: SEL is Shift+F1 or Shift+Tab, MNU is Shift with the key left of 1, PWR is Shift+Esc;**
    - **N for the speed mode, F2 or the key left of 1 for HUD visibility, Y for the target, 9 for the entry mode.**
16. Navball:
    - **its own transparent MTKView with procedural KSP-like art;**
    - **a geodetic horizon;**
    - **radial = ±r̂, as the autopilot flies it;**
    - **the speed mode switches automatically at 40/50 km, and N overrides it;**
    - **command and thrust markers now;**
    - **the autopilot does not follow the speed mode in this phase.**
17. MFDs:
    - **a new `OrbitInstruments` target;**
    - **ORBIT, SURFACE, MAP (ground track, terminator, coastlines, secular J2), DEORBIT and ENTRY;**
    - **SI units, Orbiter's colours;**
    - **the HUD's orbit panel goes when ORBIT lands.**
18. Orbiter: **reimplement, using Orbiter only as a design reference. A ported file keeps its MIT notice and goes into a THIRD_PARTY_NOTICES.md. Never D3D9Client (LGPL), NASSP (GPL) or KSP art.**

**Graphics**

19. **MSAA 4×, open bells and interstages, eclipse and earthshine, the Apollo shapes, visible gimballing, plumes with a visibility floor, orbit-line markers, heat-shield glow and parachutes. Defer the ocean, plasma sheath, S-IC fins, night lights and cockpit camera. Planet textures stay user-supplied.**

## Verification

**Core, on Linux (`swift test`)**
- Each track's reference tests, as listed in its brief.
- All 203 existing tests, with the §17 residuals and the Space-sequence tests updated only for the new part names.
- About 280 tests are expected at the end.

**Mac**
- Each Mac track runs `xcodebuild build` and `test` itself (project memory).
- Shader errors are checked in the console.

**Flights in the scratch harness** (project memory: the tree exported to the scratchpad, `FlightHarness.swift`, `.req` files, then `screencapture -l<window>`). Release builds, with `instruments.navball` readouts logged beside each shot:

| # | Moment | What the shot should show |
|---|---|---|
| 1 | Pad, paused | HDG 090 |
| 2 | r20 | HDG 072 |
| 3 | Max-Q | |
| 4 | S-IC/S-II separation | Retros, ullage plumes, open interstage |
| 5 | S-IC OECO | Prograde at about 19.07° / 075.37° |
| 6 | S-IC engine 1 out | Deflected nozzles |
| 7 | S-IVB cutoff | Heads-down roll 180, IU command marker on the nose |
| 8 | Terminator crossing | Vessel darkens over 8-10 s; Ap, Pe, AN, DN markers |
| 9 | CSM separation | Panels and LM |
| 10 | Retrograde turn | |
| 11 | SPS burn | Gimbal trim, ΔV counter reaching zero |
| 12 | CM/SM separation | SM jettison jets |
| 13 | EI | ENTRY page lift-up |
| 14 | Peak g | Heat-shield glow |
| 15 | Drogues | |
| 16 | Mains | |
| 17 | Splashdown | Log line, MAP splash point |

Also:
- Apollo 7 CM at EI flown at 55° bank.
- Windows of 1400×900 and 900×600 with no overlaps, and the F2 cycle.

**Performance**
- `effectiveWarp` at 1000× in Release, in the parking orbit with the panels and S-IVB present: within 10 % of M1's parking orbit.
- Frame time with MSAA and the cluster on and off, against the memory baseline.

**Owner's own checks**
- On the Italian keyboard: throttle, warp, focus, both Shift sides, no stuck keys.
- Review of the navball `renderToImage` gallery and the screenshot set.

## Effort

| Track | Days |
|---|---|
| S0 | 1.25 |
| D | 2.0 |
| A + A2 | 4.0 + 1.25 |
| B1 + B2 | 2.5 + 5.0 |
| C | 5.5 |
| E1 + E2 | 6.25 + 4.0 |
| G1 + G2 | 2.0 + 6.0 |
| I | 2.5 |
| **Total** | **about 42 focused session-days** |

The five reports summed to about 44.5 days. The coordination tracks S0, D and I cost about 5.75 days, and the cuts above pay for them.

**Critical path: about 10.5 calendar days.** S0 (1.25) → C (5.5, which needs E2's CM parts by about day 4) → E1's mission wiring and Apollo 7 end-to-end test (1.0) → I (2.5). A2 runs alongside E1's wiring. G2 (S0 + 6.0) ends about day 7.25, and B2 about day 7, both off the critical path.

**Checkpoints**
- About day 5: the M1 ascent flown with the navball HUD, ORBIT/SURFACE MFDs, MSAA and plumes.
- About day 10.5: from the pad to splashdown.

**If time runs short, cut in this order:**

| Cut | Saves (days) |
|---|---|
| Visible gimballing | 0.75 |
| Earthshine | 0.25 |
| MAP coastlines | 0.5 |
| Landing-point predictor | 0.5 |
| Newtonian blend (keep a restoring-moment clamp) | 0.5 |
| SLA panels as separate vessels | 0.75 |
| Upper-atmosphere tables | 0.5 |

None of these breaks the definition of done.

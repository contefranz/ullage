# Roadmap

The goal is procedurally realistic Apollo and Space Shuttle missions on a
native macOS simulator. Each milestone should be flyable on its own.

## M0 — Physics core and viewer *(done)*

- DE421 ephemerides (1960–2030), lunar libration, Hipparcos star field
- Earth precession + sidereal rotation, J2 gravity, third-body perturbations
- US Standard Atmosphere 1976, pressure-dependent engine performance, drag
- 6-DOF rigid-body vessels made of parts with tanks, thrusters and staging
- Landed state on rotating bodies, lift-off, touchdown and crash detection
- RCS attitude autopilots (kill rotation, prograde, retrograde, normal, radial, level)
- Metal renderer: ray-traced planets with atmosphere, camera-relative meshes,
  orbit line, SwiftUI HUD

## M1 — Saturn V to Earth parking orbit *(done)*

- Saturn V stack: S-IC, S-II, S-IVB, IU, CSM, LES; real masses, F-1/J-2 performance
  *(done: AS-506 at first motion, calibrated to its Flight Evaluation Report: the F-1s'
  flow history, the S-II's three mixture-ratio settings, start and shutdown transients; its
  mass distribution sourced, the vehicle's CG and roll and pitch inertias checked against the
  report's mass characteristics at its 12 ascent events)*
- Engine gimballing and thrust vector control
  *(done: gimballed outboard F-1s and J-2s and the S-IVB J-2, attitude hold with a
  command seam for the IU, S-IVB APS)*
- IU flight program: roll/pitch program, tilt-arrest, iterative guidance mode (IGM);
  control-gain and outboard-cant schedules, APS phase-plane logic
  *(done: AS-506's flight sequence on the LVDC time bases, tower-clearance yaw, roll and
  pitch programs, tilt arrest, flight-control gain and cant schedules, APS phase-plane logic,
  orbital attitude, and IGM for the S-II and S-IVB with the EMR shift and velocity cutoff)*
- Interstage and LES jettison, ullage motors, engine-out
  *(jettisons, the S-II and S-IVB ullage motors, the S-IC and S-II retros and the LES
  tower-jettison motor done, as solid motors that separate the stages and throw the tower
  clear; engine-out done: failures scheduled on the IU, its engine-out sensing, the S-IC
  chi freeze and the IGM's S-II engine-out presettings, with the app's F key, an engine-out
  HUD row and the Apollo 13 S-II and S-IC engine-out scenarios)*
- Aerodynamic normal force and moments for the launch stack
  *(done: axial force by the Saturn V flight-evaluation method, normal force and centre of
  pressure from the design data, their moments about the centre of mass, and the launch day's
  measured atmosphere and winds)*
- Ascent residuals against AS-506's postflight trajectory
  *(done: AS-506's postflight trajectory reduced to sensed velocity by stage, its pitch
  program fitted to the postflight attitude, the S-IC's thrust history and flow, the frost
  and purge gas AS-506 shed by CECO (carried on the S-IC to its separation), the S-II's
  mixture-ratio transition and flow, and the S-IVB's thrust from its measured acceleration.
  Each stage's sensed velocity is within 1.6 m/s of the postflight trajectory's, and the
  S-IVB's velocity cutoff comes at 698.83 s against AS-506's 699.34 s, into the LVDC's
  parking orbit: datasheet §17)*
- WGS-84 Earth ellipsoid: the geodetic pad, altitude and surface contact
  *(done: geodetic altitude, latitude and vertical, the landed state and surface contact on
  the ellipsoid, which the renderer draws; LC-39A at 28.6084° geodetic: datasheet §15)*
- Nutation in Earth orientation; IAU 2006 precession
  *(done: IAU 2006 precession, IAU 2000B nutation and the equation of the equinoxes on UT1
  from the IERS C04 series; polar motion is not modelled)*
- Real launch scenario (Apollo 11, 16 July 1969, 13:32:00 UTC, LC-39A)
  *(done: the stack opens at first motion, 13:32:00.3 UTC, on LC-39A, and the HUD's MET is
  Apollo 11's GET from range zero)*

## M1.5 — Apollo Earth-orbit mission, from the pad to splashdown *(done)*

The plan and its design reports are in [docs/m15/](m15/plan.md).

- Navball and flight HUD (KSP-like), on physical key positions
  *(done: the navball in the crew's axes (pad 090/90/0, heads down in orbit at roll 180),
  orbit and surface speed modes switching at 50 km climbing and 40 km descending (N
  overrides), prograde, normal, radial, the green command marker and the thrust marker; the
  instrument cluster with throttle, speed and altitude tapes, HDG/PIT/RLL, rates, α/β and
  the autopilot column; F2 cycles full HUD, instruments only and off; every key bound by its
  physical position. Phase 2: target mode (Y, with target markers, range and range rate),
  the manoeuvre marker from DEORBIT's SET, entry readouts (a g meter, the 0.05 G light, bank,
  heating and the ELS), and the next event in an annunciator strip, with the IU's predicted
  IGM cutoffs)*
- Orbiter-style MFD displays (ORBIT, SURFACE, MAP, DEORBIT, ENTRY) in a new
  `OrbitInstruments` target, left Shift driving the left MFD and right Shift the right one
  *(done: MAP with Natural Earth coastlines, the terminator, the track flown and predicted
  (secular J2) and the predicted landing point; DEORBIT with the burn's Δv, TIG, burn time
  and EI, and a SET that loads the ΔV counter; ENTRY with an EMS-style g–V scroll, bank,
  heating, the landing point and the ELS state; the buttons take clicks too)*
- CSM separation: the four SLA panels, and the S-IVB, IU and LM leaving with the IU program
  *(done: the panels tumble away at 68-FM-160's rates, the crew keeps the vessel, and the
  CM's SCS takes over with its 3 s +X ullage; passive debris no longer holds time warp down)*
- CSM SPS and the SM and CM RCS quads, as thrusters (their systems stay in M3)
  *(done: 68-FM-184's SPS rating, gimballed about the AOH's nulls and trimmed through the CG
  by the SCS; four SM RCS quads on a 0.5°/5° phase-plane law; the CM's two RCS systems)*
- SPS deorbit burn cut off by an EMS-style ΔV counter, CM/SM separation
  *(done: Z lights the SPS and the counter cuts it off; CM/SM separation takes Space twice
  within 2 s, and the SM's jettison controller fires its jets; Apollo 7's SPS-8 cutoff and
  entry interface against Mission Report Table 3-III)*
- Command module entry aerodynamics (lift vector control), parachutes, splashdown
  *(done: trim-calibrated sphere-centre aerodynamics with a Newtonian blend, the 1976
  atmosphere to 1,000 km, sensed g, bank and Sutton–Graves heating; the CM's entry program:
  trim lift up to entry interface, 0.05 g, then manual, bank hold or rolling (key 9), with a
  display-only landing-point predictor; the earth landing system on baroswitch pressure,
  reefed drogues and mains, Space as the crew's backup; splashdown on a Natural Earth land
  mask, the CM floating at once)*
- Graphics: Apollo shapes, open engine bells and interstages, plumes, eclipse and earthshine,
  heat-shield glow, parachute canopies
  *(done: lathed shapes from the sources' dimensions, MSAA 4×, visible gimballing, plumes
  styled by propellant, the conical eclipse model and earthshine, orbit-line markers (Pe, Ap,
  AN, DN, EI), the heat shield's glow from the heat flux, and the canopies and risers)*
- Scenarios: Apollo 11 from the pad to splashdown (TLI no-go), Apollo 11 in parking orbit,
  Apollo 7's deorbit and entry, and Apollo 7's command module at entry interface *(done)*

**Definition of done**

1. AS-506 flown from the pad with only the HUD, navball and MFDs:
   - the IU flies to the parking orbit;
   - Space separates the CSM: four SLA panels, and the S-IVB + IU + LM leave with the IU program;
   - key 2 turns the CSM retrograde on the SM RCS;
   - the DEORBIT MFD gives the Δv and the time of ignition (TIG);
   - Z lights the SPS, and the ΔV counter cuts it off;
   - Space twice separates CM/SM;
   - the CM holds trim lift-up to entry interface (EI) and is flown in bank (or bank hold);
   - the earth landing system (ELS) fires on baroswitch pressure;
   - the log reads "splashdown at x m/s" in water, and the MAP shows the splash point.
2. An Apollo 7 reference chain in `swift test`:
   - the SPS-8 cutoff state (Mission Report Table 3-III) and EI;
   - the CM from 68-FM-184 Table IX(b)'s EI at 55° bank lands within about 30 n mi of
     29.8° N 67.0° W;
   - the ELS phase durations fall within their bands.

   **Accepted deviation** (Franz, 2026-10-20): the constant-55° backup lands 50–80 n mi long
   (81 n mi beyond 29.8° N 67.0° W from the planned EI, 52 n mi beyond where Apollo 7 came
   down when flown from its deorbit burn), so the tests' landing bands are 90 n mi from the
   planned EI and 60 n mi against the flight, with no tuning to close it. It is the size of
   the conventions between 68-FM-184's trajectory program and this one (0.1° of entry
   flight-path angle); revisit it with closed-loop entry guidance (constant-g in M2, the CMC's
   predictor-corrector in M3). See [docs/CM-entry-datasheet.md](CM-entry-datasheet.md) §4.4–4.5.
3. No regressions: every M1 test passes with the §17 residuals unchanged; `swift test` is green
   on Linux and `xcodebuild build test` on the Mac; the owner has reviewed the screenshot set;
   README, ROADMAP and CLAUDE.md are updated.

**Close-out** (2026-10-21, [docs/m16/plan.md](m16/plan.md) "M1.5 completion"):

- Linux: OrbitCore and OrbitInstruments build and pass on Swift 6.0.2 (338 + 26 tests),
  after three expressions were split for its type checker (#40).
- Test gate: `scripts/test.sh` runs the same tests fast (-O, parallel, the merge gate, about
  1.5 min) or full (Debug, serial, the milestone gate, about 33 min) (#39).
- Time warp: debris in the air steps by its drag and climb rate (drag share 0.5, not the
  plan's 0.02, which RK4 does not need), so 1000× holds while the SLA panels re-enter (#41).
- Recovery target: MAP marks Apollo 7's 29.8° N 67.0° W, and ENTRY gives the range and
  bearing to it, the predicted miss and its downrange part (#38).
- Owner sign-off: Franz flew the app and checked the keys on a US keyboard. His one change
  made the RCS keys pulse as in Orbiter: a tap fires 0.1 s, a hold fires on, Ctrl gives the
  14 ms minimum impulse or a tenth of the thrust (#42). main then passed 385 tests in the
  fast gate.

**Naming contract.** The names the vehicle, the programs, the displays and the tests share:

- Parts: "S-IVB", "IU", "SLA ring", "SLA panel 1"–"SLA panel 4", "LM", "SM", "CM",
  "Apex cover", "Drogue parachutes", "Main parachutes".
- Staging events: 1–5 stay the launch vehicle's; 6 is CSM/S-IVB separation, 7 CM/SM
  separation, and 30, 31 and 32 the apex cover, the drogues and the mains.
- Thrusters: "SPS", "SM RCS A1"…, "CM RCS 1A"….

## M1.6 — Graphics overhaul: the Saturn V and the CSM finished, pad to splashdown *(in progress)*

The plan and its design reports are in [docs/m16/](m16/plan.md); tracks, owners and merge
order are there.

- Render foundation: an `OrbitScene` target (pure Swift, Linux) and an `OrbitRender` target
  (macOS), a pass graph, the `orbitsnap` offscreen tool and golden images
- Renderer: HDR in photometric units with auto exposure, a Hasselblad photo mode, AgX tone
  mapping and bloom; physically based materials; image-based lighting with earthshine from
  the rendered Earth; sun shadows and baked AO
- Vehicle exteriors for AS-506 and AS-503 (with LTA-B), CSM-107, CSM-103 and CSM-101: fins,
  fairings, tunnels, ullage and retro fairings, the F-1 and J-2 in flight configuration, the
  LES and BPC, SM radiators, RCS quads and HGA, CM windows and Kapton; roll patterns,
  "UNITED STATES", "USA" and flags; pad frost and entry char
- LC-39A: the Mobile Launcher, the LUT and its swing arms, hold-down arms, the flame trench
- Earth: Hillaire's atmosphere from the ground to space; volumetric clouds from each
  mission's weather (ERA5); BMNG imagery by month on a cube-sphere tile store; ocean glint
  and splashdown waves; 1968 night lights
- Plumes and particles: exhaust physics driving ray-marched plumes per engine family; GPU
  particles for launch, staging, the spacecraft's SPS and RCS, entry and recovery
- Frame pacing and quality tiers

**Definition of done**

1. Every shot in `docs/look/shots/m16-*.json` renders through `orbitsnap` in Release at High,
   and the owner has signed off the contact sheet, each shot beside its NASA photograph.
2. The M1.5 AS-506 pad-to-splashdown flight still passes in the app at High; every staging
   burst is spawned at 1×, 10×, 100× and 1000×.
3. Performance: every pass within its budget; 60 fps at 1× at native resolution on the M3
   Pro; 1000× in coast within 10% of M1.
4. No regressions: §17 bit-identical, the Apollo 7 chain green, `swift test` green on Linux
   (with OrbitScene's tests) and `xcodebuild build test` on the Mac (with OrbitRenderTests).
5. README, ROADMAP, CLAUDE.md, THIRD_PARTY_NOTICES.md and `docs/look` updated.

## M2 — Apollo 8: the Saturn V and the CSM to lunar orbit and back

- AS-503 with LTA-B on its launch day; S-IVB restart and TLI (TB6/TB7, TLI inhibit,
  parking-orbit venting); CSM separation and the S-IVB slingshot
- A cislunar propagator and RTCC-style planners on a TRANSFER MFD; the GRGM900C lunar
  gravity field
- CSM-103 with the SPS series feed and passive thermal control; LOI-1 and LOI-2, ten lunar
  orbits with LOS/AOS, TEI
- The CMC's entry guidance (P63-P67) with constant-g as the backup; the lunar MAP and the
  lunar-return ENTRY display
- Graphics: the Moon (LOLA terrain on the tile store, LROC albedo, lunar-Lambert photometry,
  horizon shadows, earthshine), window views and Earthrise, the S-IVB LOX dump and vents,
  lunar-return plasma

**Definition of done**: Apollo 8 flown from the pad to splashdown with only the HUD and MFDs,
landing within a few n mi of 8.13° N 165.02° W; its reference chain in `swift test`; Earthrise
at GET 075:48:39 matching AS08-14-2383; Apollo 7 flown by the CMC's guidance landing within
about 10 n mi, which retires M1.5's accepted deviation; no regressions; docs updated.

## M2.5 — The Lunar Module (Apollo 9-11)

- Transposition, docking and extraction, with docking ports
- The LM's descent and ascent stages and their visuals; DOI and PDI
- Rendezvous, with ALIGN, SYNC and DOCKING MFDs
- Landing-site terrain detail (LDEM at 59 m, sites in MOON_ME), touchdown and landing gear
- Apollo 9, 10 and 11

## M3 — Apollo procedural realism

- Apollo Guidance Computer emulation running Colossus/Luminary
  (decision needed: Virtual AGC, GPL, versus our own emulator)
- DSKY, panels described as data, switch-level interaction
- CSM/LM systems: electrical, environmental, propulsion, RCS quads, IMU and alignment
- Checklists and mission procedures

## S1 — Shuttle ascent

- Stack: orbiter, ET, two SRBs (parallel staging, which needs a non-linear part tree)
- SSME throttling, SRB thrust curves, MECO, ET separation, OMS
- PASS-like ascent guidance rebuilt from public documentation

## S2 — Shuttle entry and landing

- Hypersonic-to-subsonic aerodynamic database (lift, drag, moments, control surfaces)
- Entry guidance, TAEM, approach and landing guidance
- KSC Shuttle Landing Facility runway, landing gear, drag chute, brakes

## S3 — Shuttle procedural realism

- GPC/DPS displays, keyboards, MDUs (MEDS) or CRTs
- Orbiter systems and panels

## Engine and tooling (as needed)

- Scenario save/load
- Sound
- A simulation thread, for 60 fps at full warp throughput

(Cockpit and window views moved into M2. Imported 3-D meshes are dropped: the vehicles are
procedural by construction.)

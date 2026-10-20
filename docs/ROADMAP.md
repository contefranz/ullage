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

**Naming contract.** The names the vehicle, the programs, the displays and the tests share:

- Parts: "S-IVB", "IU", "SLA ring", "SLA panel 1"–"SLA panel 4", "LM", "SM", "CM",
  "Apex cover", "Drogue parachutes", "Main parachutes".
- Staging events: 1–5 stay the launch vehicle's; 6 is CSM/S-IVB separation, 7 CM/SM
  separation, and 30, 31 and 32 the apex cover, the drogues and the mains.
- Thrusters: "SPS", "SM RCS A1"…, "CM RCS 1A"….

## M2 — Lunar mission profile

- S-IVB restart and TLI, transposition, docking and extraction (docking ports)
- LM descent and ascent stages, separation
- Lunar gravity beyond J2 (spherical-harmonic field for mascons), LOI and DOI
- Lunar terrain: LOLA elevation with a quadtree LOD, landing site coordinates in MOON_ME
- Touchdown points and landing gear model for the LM
- Lunar-return entry (constant-g guidance) and the lunar MFD displays

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

- Cockpit/virtual cockpit views
- Real 3-D meshes (glTF/USDZ import)
- Scenario save/load
- Sound

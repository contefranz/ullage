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

## M2 — Lunar mission profile

- S-IVB restart and TLI, transposition, docking and extraction (docking ports)
- CSM SPS, LM descent and ascent stages, separation
- Lunar gravity beyond J2 (spherical-harmonic field for mascons), LOI and DOI
- Lunar terrain: LOLA elevation with a quadtree LOD, landing site coordinates in MOON_ME
- Touchdown points and landing gear model for the LM
- Command module entry aerodynamics (lift vector control), parachutes, splashdown

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

- Cockpit/virtual cockpit views, HUD instruments, MFD-style displays
- Real 3-D meshes (glTF/USDZ import)
- Scenario save/load
- Sound

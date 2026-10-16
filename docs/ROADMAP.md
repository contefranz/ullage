# Roadmap

The goal is procedurally realistic Apollo and Space Shuttle missions on a
native macOS simulator. Each milestone should be flyable on its own.

## M0 — Physics core and viewer *(this release)*

- DE421 ephemerides (1960–2030), lunar libration, Hipparcos star field
- Earth precession + sidereal rotation, J2 gravity, third-body perturbations
- US Standard Atmosphere 1976, pressure-dependent engine performance, drag
- 6-DOF rigid-body vessels made of parts with tanks, thrusters and staging
- Landed state on rotating bodies, lift-off, touchdown and crash detection
- RCS attitude autopilots (kill rotation, prograde, retrograde, normal, radial, level)
- Metal renderer: ray-traced planets with atmosphere, camera-relative meshes,
  orbit line, SwiftUI HUD

## M1 — Saturn V to Earth parking orbit

- Saturn V stack: S-IC, S-II, S-IVB, IU, CSM, LES; real masses, F-1/J-2 performance
  *(done: AS-506 at first motion)*
- Engine gimballing and thrust vector control
  *(done: gimballed outboard F-1s and J-2s and the S-IVB J-2, attitude hold with a
  command seam for the IU, S-IVB APS)*
- IU flight program: roll/pitch program, tilt-arrest, iterative guidance mode (IGM);
  control-gain and outboard-cant schedules, APS phase-plane logic
  *(part 1 done: AS-506's flight sequence on the LVDC time bases, tower-clearance yaw, roll and
  pitch programs, tilt arrest, flight-control gain and cant schedules, APS phase-plane logic,
  orbital attitude; part 2, IGM for the S-II and S-IVB, to do)*
- Interstage and LES jettison, ullage motors, engine-out
- Aerodynamic normal force and moments for the launch stack
- Nutation in Earth orientation; IAU 2006 precession
- Real launch scenario (Apollo 11, 16 July 1969, 13:32:00 UTC, LC-39A)

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

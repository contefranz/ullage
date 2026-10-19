# OrbitSim

A native Apple Silicon space flight simulator in Swift and Metal, aimed at
procedurally realistic Apollo and Space Shuttle missions.

Milestones **M0** (the physics core and a Metal viewer, flown with a generic
two-stage test rocket and capsule) and **M1** (Saturn V to Earth parking orbit)
are done. M1 is Apollo 11's Saturn V stack, with its propulsion and masses
calibrated to AS-506's flight evaluation report, its engine gimballing and
thrust vector control, and its Instrument Unit flight program, which flies the
S-IC's attitude programs, the staging sequence and the iterative guidance of
the S-II and S-IVB to the parking orbit, through the launch day's measured air
and winds with the stack's sourced aerodynamics, and senses and flies through
an engine out. It stands on LC-39A on a WGS-84 Earth, and its ascent closes on
AS-506's postflight trajectory. See [docs/ROADMAP.md](docs/ROADMAP.md) for the
path to Apollo and the Shuttle; M2, the lunar mission profile, is next.

## Build and run

Requirements: macOS 14 or later, Xcode 15 or later.

```sh
git clone <this repo>
cd <repo>
open Package.swift          # opens in Xcode
```

In Xcode, choose the **OrbitSim** scheme with **My Mac** as the destination and
press Run. From a terminal, `swift run -c release OrbitSim` works too.

The physics core has its own test suite, which also runs on Linux:

```sh
swift test
```

### Planet textures (optional)

Without textures, Earth and the Moon are drawn with a 15° latitude/longitude
grid. For real imagery, put equirectangular maps (8192×4096 or smaller) in
`~/Library/Application Support/OrbitSim/Textures/` as `earth.jpg` and
`moon.jpg`. Good public-domain sources:

- Earth: NASA Visible Earth, *Blue Marble* collection
- Moon: NASA Scientific Visualization Studio, *CGI Moon Kit* (LROC colour map)

## Controls

| Key | Action |
| --- | --- |
| Z / X | Full throttle / cut engines |
| = / - (hold) | Throttle up / down |
| W S A D Q E | Pitch down / up, yaw left / right, roll left / right |
| I K J L U O | Translate up / down / left / right / forward / back |
| Space | Next staging event (on the Saturn V, only after the S-IC cutoff) |
| T | Kill rotation (toggle; damps rates only) |
| 1–7 | Prograde, retrograde, normal, anti-normal, radial out, radial in, hold level |
| 8, 0 | Hold attitude (on the Saturn V, gives the attitude back to the IU); autopilot off |
| F, then 1–5 | Fail engine n of the stage now firing (S-IC and S-II: 5 is the centre engine); Esc cancels |
| . , / | Time warp up / down / reset to 1× |
| P | Pause |
| Mouse drag, scroll | Orbit and zoom the camera |
| C / V | Cycle camera target / camera frame (horizon, vessel, inertial) |
| [ ] | Switch vessel |
| M / H | Toggle orbit line / help |

Keys are bound by their place on the keyboard (labelled above as on a US
layout), so they sit in the same place on any layout. Keys pressed with Shift
do not fly the vessel: they are kept for the MFDs to come, left Shift for the
left one and right Shift for the right one.

Scenarios are in the **Scenario** menu: the test rocket on LC-39A on
16 July 1969; Apollo 11's Saturn V (AS-506) on the same pad at first motion;
the same stack with Apollo 13's S-II centre engine out, and with S-IC engine 1
out at 60 s; a capsule in low Earth orbit; and a capsule in lunar orbit. LC-39A
is geodetic, at 28.6084° N on the WGS-84 ellipsoid, the vehicle's base 26 m
above it, so the HUD reads the Saturn's centre of mass at about 59 m. On the
Saturn V the HUD's MET is Apollo 11's ground elapsed time (GET), zero at range
zero, 13:32:00 UTC, and the event log reads it to a tenth of a second against
the flight's published times; on the test vehicles MET starts at liftoff.

The Saturn V opens paused at first motion, 13:32:00.3 UTC, with the F-1s at
full thrust: P releases it, and the Instrument Unit takes over at liftoff: the
tower-clearance yaw, the roll to the 72.058° flight azimuth, the pitch
program, the engine cutoffs, every separation and ignition on Apollo 11's
times, and the turn to the local horizontal after the S-IVB cutoff. The stages
separate on their solid motors: the retros back each spent stage away, burning
on with it, the ullage motors push the stack that stays, and the tower's
jettison motor pitches the escape tower over and throws it clear; the HUD's
IU row shows its time base and phase. Space does nothing until the S-IC has
burned out. Flying by hand or selecting another autopilot mode takes the
attitude away from the IU, which keeps sequencing the flight. Releasing the
keys (or 8, after another mode) gives it back, and the IU returns to its
program at its command rate limits: 1°/s until the S-IVB cutoff, 0.4°/s
(0.6°/s in roll) after it. From 204 s the IU's iterative guidance mode (IGM)
steers the S-II and S-IVB, commands the S-II's mixture-ratio shift and cuts the
S-IVB off on velocity, into a 100 n mi (185 km) circular parking orbit at
Apollo 11's inclination; the HUD's IU row shows the IGM's phase. The stack
flies through the air of 16 July 1969 at the Cape (its measured temperature,
pressure, density and winds to 56 km) with the Saturn V's flight-evaluated
axial force and its design normal force and centre of pressure: max Q comes at
35.3 kPa at 83.1 s, against Apollo 11's 35.2 kPa at 83.0 s. The stack is
aerodynamically unstable, and its gimballed engines hold it.

The ascent closes on AS-506's postflight trajectory: each stage's sensed
velocity is within 1.6 m/s of the reconstructed flight's (S-IC −1.26, S-II
+1.58, S-IVB −1.24 m/s), and the velocity cutoff comes at GET 00:11:38.8,
0.5 s before Apollo 11's 00:11:39.3 (datasheet §17).

F, then an engine number, fails that engine of the stage now firing; the
Saturn's IU senses it as AS-506's LVDC would. An S-IC engine out freezes the
pitch program for a time that depends on when it failed (GE504's chi freeze)
and the four F-1s burn longer; an S-II engine out stretches the IGM's second
stage. The HUD's Engine out row lists the failed engines and any failure a
scenario has scheduled. In the Apollo 13 scenario the S-II's centre engine
fails at T3 + 167 s as on AS-508, and the S-II cuts off about 33 s late and
the S-IVB about 45 s late, into the same parking orbit.

## How it works

```
Sources/OrbitCore      Pure Swift + Foundation (builds on Linux too)
  Math/                Double-precision vectors, matrices, quaternions
  Time/                TDB/UTC epochs with leap seconds, UT1 from the IERS C04 table
  Ephemeris/           JPL DE421 Chebyshev reader, lunar libration, star catalogue
  Bodies/              Bodies, the WGS-84 figure, Earth (IAU 2006/2000B, UT1) and Moon orientation,
                       J2 gravity, US Std Atmosphere 1976, soundings
  Orbit/               Osculating elements
  Vessel/              Parts, tanks, thrusters, staging, gimballed engines, TVC and RCS/APS autopilots,
                       launch-stack aerodynamics
  Guidance/            Flight programs: the Saturn V Instrument Unit (time bases, programs, sequence)
  Simulation/          RK4 rigid-body integration, time warp, landing, SOI switching
Sources/OrbitInstruments  Pure Swift + Foundation: physical keys and the keyboard state
Sources/OrbitSim       macOS app: SwiftUI shell, Metal renderer, input, HUD
Tests/OrbitCoreTests   Validation against JPL/SPICE reference values and physics checks
Tests/OrbitInstrumentsTests  Key codes and the keyboard state
tools/                 Scripts that build the bundled data files
```

Some design notes:

- **Precision.** Apple GPUs have no 64-bit floating point. All state is kept in
  doubles; the renderer subtracts the camera position in double precision and
  only then converts to float. Depth uses a reversed-Z, infinite-far
  projection. Planets are drawn as per-pixel ray-traced spheres, so they stay
  exact from orbit down to the launch pad with no tessellation error.
- **Ephemerides.** Sun, Moon, Earth and planets come from JPL DE421 (1960–2030),
  and the lunar orientation from the DE421 libration angles. The tests check
  these against JPL and SPICE reference values to sub-metre and 1e-13 level.
- **Dynamics.** Each vessel is a 6-DOF rigid body integrated with RK4 relative
  to its reference body. Gravity includes the reference body's J2 term and
  third-body perturbations from the Sun, Earth, Moon, Venus and Jupiter. Engine
  thrust varies with ambient pressure. The step size adapts to thrust,
  atmosphere, rotation rate and orbital period, so time warp stays accurate.
- **Time warp.** A frame steps for at most 40 ms of wall-clock time and makes
  up for at most 0.1 s of real time, so the app stays responsive when steps
  are expensive (0.02 s steps in powered flight). The simulation drops what a
  frame could not cover, and the HUD then shows the warp actually achieved,
  e.g. `1000×  (limited: 38×)`.
- **Earth orientation.** IAU 2006 precession and IAU 2000B nutation (ERFA's
  algorithms), with the Earth rotation angle and sidereal time on UT1 from the
  IERS C04 series. Polar motion is not modelled: at Apollo 11's range zero the
  pad lies 8 m from JPL Horizons' position (2 m with C04's polar motion added),
  where the IAU 1976 model used before was 243 m off.
- **Earth figure.** The Earth is the WGS-84 ellipsoid. Altitude, latitude and
  the local vertical are geodetic (Vermeille's closed form); the landed state,
  surface contact, the winds' horizontal and the camera's horizon follow the
  ellipsoid's normal, and the renderer ray-traces the ellipsoid itself. Gravity
  stays the J2 field: the IU's plumb line (J2 plus the centrifugal term) is
  0.0002° from the normal at the pad. The HUD's apsides are radii less the
  equatorial radius.
- **Vessel frame.** A vessel's origin follows its centre of mass as propellant
  is used. Parts keep their construction coordinates,
  `part.offset - vessel.structureOrigin` (for the Saturn V, its vehicle
  stations in metres).

## Data sources

- `ephem.bin`: extracted from JPL DE421 and `moon_pa_de421_1900-2050.bpc`
  (NASA/JPL, public domain) with `tools/make_ephemeris.py`.
- `stars.bin`: the ESA Hipparcos catalogue (ESA 1997, SP-1200), stars to
  V = 7, built with `tools/make_stars.py`.
- `ut1.txt`: UT1−UTC from the IERS EOP 20 C04 series (IERS, Paris
  Observatory), daily from 1962, built with `tools/make_ut1.py`.
- AS-506's postflight trajectory and flight evaluation report tables, which the
  tests check the ascent against, are transcribed in `docs/data/as506/` and
  `tools/data/`.

## License

MIT; see [LICENSE](LICENSE).

# OrbitSim

A native Apple Silicon space flight simulator in Swift and Metal, aimed at
procedurally realistic Apollo and Space Shuttle missions.

Milestones **M0** (the physics core and a Metal viewer, flown with a generic
two-stage test rocket and capsule), **M1** (Saturn V to Earth parking orbit)
and **M1.5** (an Apollo Earth-orbit mission, from the pad to splashdown) are
done.

- M1 is Apollo 11's Saturn V stack, with its propulsion and masses calibrated
  to AS-506's flight evaluation report, its engine gimballing and thrust vector
  control, and its Instrument Unit flight program, which flies the S-IC's
  attitude programs, the staging sequence and the iterative guidance of the
  S-II and S-IVB to the parking orbit, through the launch day's measured air and
  winds with the stack's sourced aerodynamics, and senses and flies through an
  engine out. It stands on LC-39A on a WGS-84 Earth, and its ascent closes on
  AS-506's postflight trajectory.
- M1.5 flies the Apollo spacecraft home from that orbit, as if translunar
  injection were no-go: CSM separation with the SLA panels, the SPS deorbit
  burn cut off by an EMS-style ΔV counter, CM/SM separation, the command
  module's lifting entry, its earth landing system and splashdown. It is flown
  on a KSP-style navball and Orbiter-style MFDs, and checked against Apollo 7's
  deorbit and entry.

See [docs/ROADMAP.md](docs/ROADMAP.md) for the path to Apollo and the Shuttle;
M2, the lunar mission profile, is next.

## Build and run

Requirements: macOS 14 or later, Xcode 15 or later.

```sh
git clone <this repo>
cd <repo>
open Package.swift          # opens in Xcode
```

In Xcode, choose the **OrbitSim** scheme with **My Mac** as the destination,
set it to **Release** (Product ▸ Scheme ▸ Edit Scheme…, Run, Info, Build
Configuration: Release) and press Run. Xcode's default Debug build is about 10×
slower per simulation step, so high time warp falls well short of the rate you
select. From a terminal, `swift run -c release OrbitSim` builds and runs
Release.

The physics core (`OrbitCore`) and the instrument pages and keys
(`OrbitInstruments`) have their own test suites, which also run on Linux:

```sh
scripts/test.sh             # optimised, in parallel: a few minutes
scripts/test.sh full        # the same tests in Debug, serially (plain `swift test`)
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
| Z / X | Full throttle / cut engines (on the CSM, Z lights the SPS and the ΔV counter cuts it off) |
| = / - (hold) | Throttle up / down |
| W S A D Q E | Pitch down / up, yaw left / right, roll left / right (RCS: tap for a pulse, hold to fire on) |
| I K J L U O | Translate up / down / left / right / forward / back (RCS: tap for a pulse, hold to fire on) |
| Ctrl + RCS key | Fine RCS: the tap's pulse is the jets' 14 ms minimum impulse, the hold a tenth of the thrust (docking) |
| Space | Next staging event: on the Saturn V only after the S-IC cutoff; CM/SM separation takes two presses within 2 s; on the CM once the SM has gone, the backup of the earth landing system (apex cover and drogues, then mains), below 40,000 ft |
| T | Kill rotation (toggle; damps rates only) |
| 1–7 | Prograde, retrograde, normal, anti-normal, radial out, radial in, hold level |
| 8, 0 | Hold attitude (on the Saturn V, gives the attitude back to the IU); autopilot off |
| 9 | CM entry mode: manual (Q/E roll the lift about the air velocity), bank hold (the bank flown), rolling |
| F, then 1–5 | Fail engine n of the stage now firing (S-IC and S-II: 5 is the centre engine); Esc cancels |
| . , / | Time warp up / down / reset to 1× |
| P | Pause |
| N | Navball speed mode: orbit / surface / target (automatic: surface below 40 km, orbit above 50 km; target only with a target set) |
| Y | Target: the nearest other vessel, then farther ones, then none (target markers, range and range rate) |
| F2 or ` | HUD: full / instruments only / off |
| Left/right Shift + F1 or Tab | Left/right MFD: mode select (then the mode's letter: O, S, M, D, E) |
| Left/right Shift + ` / Esc | Left/right MFD: menu / power |
| Left/right Shift + letter | The MFD's button (the buttons also take clicks) |
| Mouse drag, scroll | Orbit and zoom the camera |
| C / V | Cycle camera target / camera frame (horizon, vessel, inertial) |
| [ ] | Switch vessel |
| M / H | Toggle orbit line / help (with the scenario's summary) |

Keys are bound by their place on the keyboard (labelled above as on a US
layout), so they sit in the same place on any layout. Keys pressed with Shift
do not fly the vessel: they go to the MFDs, left Shift to the left one and
right Shift to the right one.

The RCS keys pulse, as in Orbiter: a tap fires the jets for 0.1 s of
simulation time at full thrust, so the same tap gives the same impulse at any
time warp (taps in a row add up, opposite ones cancel); a key still down
after 0.25 s fires on until it goes up. With Control down both are fine, for
docking: a tap fires for 14 ms, the Apollo RCS jets' minimum impulse, and a
hold at a tenth of the thrust. A key held on an axis wins over a tap there and
ends any pulse there, so the jets stop as soon as it goes up; an autopilot
takes over again once a pulse ends. In the CM entry's manual mode, from
0.05 g, Q and E roll the lift for as long as they are down, with no pulses.

### Scenarios

In the **Scenario** menu:

- **Pathfinder on LC-39A**: the two-stage test rocket on 16 July 1969.
- **Saturn V (AS-506) on LC-39A**: Apollo 11 at first motion, flown by its IU
  to the parking orbit.
- **Apollo 11: pad to splashdown (TLI no-go)**: the same stack, flown on from
  the parking orbit back to the Atlantic (see *The Earth-orbit mission*).
- **Apollo 11 in parking orbit**: the stack at orbit insertion, GET 00:11:49,
  at AS-506's postflight state.
- **Apollo 13: S-II centre engine out** and **S-IC engine 1 out at 60 s**:
  Apollo 11's stack with an engine failure.
- **Apollo 7: deorbit and entry**: CSM-101 at GET 259:38:00, before its
  deorbit burn, in the burn's attitude with the ΔV counter loaded; the crew's
  steps are in the help panel.
- **Apollo 7 CM at entry interface**: the command module at 68-FM-184's
  planned entry interface, holding the 55° bank the plan targets.
- **Capsule in low Earth orbit** and **Capsule in lunar orbit**: the M0 test
  capsule.

LC-39A is geodetic, at 28.6084° N on the WGS-84 ellipsoid, the vehicle's base
26 m above it, so the HUD reads the Saturn's centre of mass at about 59 m. On
the Apollo scenarios the HUD's MET is the mission's ground elapsed time (GET),
zero at range zero (Apollo 11: 13:32:00 UTC on 16 July 1969; Apollo 7: 15:02:45
UTC on 11 October 1968), and the event log reads it to a tenth of a second
against the flight's published times; on the test vehicles MET starts at
liftoff.

### The HUD

- **Top bar**: vessel and status, MET and UTC, geodetic altitude and its
  rate, time warp (with the warp achieved when a frame cannot keep up), the
  reference body and the camera.
- **Event log** (top left) and **vehicle panel** (top right): the flight
  program's line (the IU, the CSM's SCS, the CM's entry program and ELS), what
  Space does next, the stage's Δv, mass, thrust-to-weight, gimbal, engine
  failures and tanks.
- **Navball and instrument cluster** (bottom): the ball in the crew's axes,
  heads down in orbit, with the speed markers (prograde, normal, radial ±r̂ as
  the autopilot flies them, or relative to a target in target mode), the
  green command marker (the IU's attitude command, or the autopilot's target),
  the thrust marker, the target and anti-target markers, and the manoeuvre
  marker of the burn DEORBIT's SET has loaded; around it the throttle, the
  speed tape (orbit, surface or target, Mach and q), heading, pitch and roll,
  body rates, α/β in the air, the altitude tape with the apsides, the
  vertical speed and the autopilot column (HOLD IU, HOLD SCS or HOLD CM when
  a program flies the hold). Under it, an annunciator strip: the next event
  (the IU's sequence and its predicted IGM cutoffs, the SCS's burn and
  counter cutoff, the ELS) and the target's range and range rate; in an
  entry the throttle becomes a 0–10 g meter with the peak, and the strip
  shows the 0.05 G light, peak g, bank, heat flux and load and the ELS
  state.
- **Two MFDs** (bottom corners; one in narrow windows), after Orbiter:
  - ORBIT: the elements, apsides and their times, and the orbit drawn from the
    equator or the vessel's plane;
  - SURFACE: altitude, speeds, Mach, q, angles of attack and flight path,
    sensed g, position and the air;
  - MAP: Natural Earth coastlines, the night side, the track flown and the
    track predicted (J2), the horizon circle, the entry interface ahead and
    the predicted landing point;
  - DEORBIT: the burn to a target entry flight-path angle or perigee, its
    TIG, Δv (P30's local-vertical components), burn time, the orbit after it
    and the entry interface it gives; SET loads the Δv into the CSM's ΔV
    counter;
  - ENTRY: after the Entry Monitor System, g and its peak, the 0.05 g light,
    the g–V scroll, bank, heating, the landing point and range, and the ELS.

## The Earth-orbit mission

**Ascent.** The Saturn V opens paused at first motion, 13:32:00.3 UTC, with the F-1s at
full thrust: P releases it, and the Instrument Unit takes over at liftoff: the
tower-clearance yaw, the roll to the 72.058° flight azimuth, the pitch
program, the engine cutoffs, every separation and ignition on Apollo 11's
times, and the turn to the local horizontal after the S-IVB cutoff. The crew
flies heads down, so the navball reads 090 on the pad, 072 after the roll
program and roll 180 once pitched over. The stages
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

**Return from Earth orbit.** In the parking orbit:

1. **Space separates the CSM.** The four SLA panels tumble away, the S-IVB, IU
   and LM leave under the IU, and the crew keeps the vessel: the CM's
   stabilization and control system (SCS) takes over and fires the SM RCS's
   +X jets for 3 s.
2. **2 turns the CSM retrograde** on the SM RCS (the SCS's phase-plane law,
   0.5° dead band): its nose against the direction of flight, so that the SPS
   thrusts against it.
3. **The DEORBIT MFD plans the burn**: the Δv to the target entry
   flight-path angle (−1.75° by default), its time of ignition, and the entry
   interface it gives; its SET loads the Δv into the ΔV counter, puts the
   manoeuvre marker on the navball and the time to TIG in the strip.
4. **Z at TIG lights the SPS**, which the SCS trims through the centre of
   mass; the counter counts the Δv sensed along the CSM's axis and cuts the
   SPS off at zero.
5. **Space twice (within 2 s) separates the SM.** Its jettison controller
   fires its −X jets and roll jets, and the command module's entry program
   wakes: it arms the CM RCS and the earth landing system and holds the trim
   attitude lift up (the crew heads down).
6. **Entry.** At 0.05 g the program flies the entry mode: lift up by
   default, or (key 9) manual, where Q and E roll the lift about the air
   velocity, bank hold, or rolling. The cluster's g meter and strip and the
   ENTRY MFD show the load, bank and heating, the ENTRY MFD the g–V scroll
   and the predicted landing point; the heat shield glows near peak heating.
7. **Landing.** At 24,000 ft the upper baroswitch jettisons the apex cover
   and fires the drogues; at 10,000 ft the lower one deploys the three mains,
   reefed. Space is the crew's backup for each step, below 40,000 ft. The log
   reads "splashdown at x m/s" on water (a Natural Earth land mask; land
   above 5 m/s or water above 15 m/s is a crash) and the MAP shows where.

The same flow starts later in **Apollo 11 in parking orbit**, and Apollo 7's
own deorbit and entry are scenarios too. The test suite flies Apollo 7 from its
SPS-8 burn (Mission Report Table 3-III): the counter's cutoff, an entry
interface 5 s from the flight's, a 3.4 g peak and a splashdown 52 n mi beyond
where Apollo 7 came down; and from 68-FM-184's planned entry interface at the
55° backup bank: 3.4 g, 53 s on the drogues and 4.5 min on the mains, landing
81 n mi beyond the planned point. The landing miss is an accepted deviation:
see [docs/CM-entry-datasheet.md](docs/CM-entry-datasheet.md).

## How it works

```
Sources/OrbitCore      Pure Swift + Foundation (builds on Linux too)
  Math/                Double-precision vectors, matrices, quaternions
  Time/                TDB/UTC epochs with leap seconds, UT1 from the IERS C04 table
  Ephemeris/           JPL DE421 Chebyshev reader, lunar libration, star catalogue
  Bodies/              Bodies, the WGS-84 figure, Earth (IAU 2006/2000B, UT1) and Moon orientation,
                       J2 gravity, US Std Atmosphere 1976 to 1,000 km, soundings, eclipse, land mask
  Orbit/               Osculating elements
  Navigation/          Kepler propagation, ground track, entry interface, deorbit planner
  Instruments/         Local horizon and the navball (attitude, markers, speed modes)
  Vessel/              Parts, tanks, thrusters, staging, gimballed engines, TVC and RCS/APS autopilots,
                       launch-stack and capsule aerodynamics, the CSM and CM, parachutes, shapes
  Guidance/            Flight programs: the Saturn V Instrument Unit, the CSM's SCS, the CM's entry
                       program and landing-point predictor, the earth landing system
  Simulation/          RK4 rigid-body integration, time warp, landing and splashdown, entry telemetry
Sources/OrbitInstruments  Pure Swift + Foundation: physical keys, the keyboard state and the MFD
                       pages (ORBIT, SURFACE, MAP, DEORBIT, ENTRY) as display lists
Sources/OrbitSim       macOS app: SwiftUI shell, Metal renderer, input, HUD (navball), MFD panels
Tests/OrbitCoreTests   Validation against JPL/SPICE reference values, published vehicle data and
                       physics checks
Tests/OrbitInstrumentsTests  Key codes, the keyboard state, MFD key routing and page content
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
- `landmask.bin`: Natural Earth 1:10m land (public domain), a 0.25° land/water
  mask for splashdown, built with `tools/make_landmask.py` (provenance in its
  docstring).
- `coastlines.bin` (the app's MAP MFD): Natural Earth 1:110m coastlines
  (public domain), built with `tools/make_coastlines.py`.
- AS-506's postflight trajectory and flight evaluation report tables, which the
  tests check the ascent against, are transcribed in `docs/data/as506/` and
  `tools/data/`; the Apollo spacecraft's (68-FM-184, the Apollo 7 and 11
  Mission Reports, TN D-5399, TN D-5276, TN D-7437, 68-FM-160, MSC-03466, the
  AOH), in `docs/data/apollo-spacecraft/` and `tools/data/`.

## License

MIT; see [LICENSE](LICENSE).

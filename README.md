# OrbitSim

A native Apple Silicon space flight simulator in Swift and Metal, aimed at
procedurally realistic Apollo and Space Shuttle missions.

This is **milestone M0** (the physics core and a Metal viewer, flown with a
generic two-stage test rocket and capsule) plus the first two M1 items: Apollo
11's Saturn V stack, and its engine gimballing and thrust vector control. See
[docs/ROADMAP.md](docs/ROADMAP.md) for the path to Apollo and the Shuttle.

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
| Space | Next staging event |
| T | Kill rotation (toggle; damps rates only) |
| 1–7 | Prograde, retrograde, normal, anti-normal, radial out, radial in, hold level |
| 8, 0 | Hold attitude; autopilot off |
| . , / | Time warp up / down / reset to 1× |
| P | Pause |
| Mouse drag, scroll | Orbit and zoom the camera |
| C / V | Cycle camera target / camera frame (horizon, vessel, inertial) |
| [ ] | Switch vessel |
| M / H | Toggle orbit line / help |

Scenarios are in the **Scenario** menu: the test rocket on LC-39A on
16 July 1969, Apollo 11's Saturn V (AS-506) on the same pad at first motion, a
capsule in low Earth orbit, and a capsule in lunar orbit.

## How it works

```
Sources/OrbitCore      Pure Swift + Foundation (builds on Linux too)
  Math/                Double-precision vectors, matrices, quaternions
  Time/                TDB/UTC epochs with leap seconds
  Ephemeris/           JPL DE421 Chebyshev reader, lunar libration, star catalogue
  Bodies/              Bodies, Earth/Moon orientation, J2 gravity, US Std Atmosphere 1976
  Orbit/               Osculating elements
  Vessel/              Parts, tanks, thrusters, staging, gimballed engines, TVC and RCS/APS autopilots
  Simulation/          RK4 rigid-body integration, time warp, landing, SOI switching
Sources/OrbitSim       macOS app: SwiftUI shell, Metal renderer, input, HUD
Tests/OrbitCoreTests   Validation against JPL/SPICE reference values and physics checks
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
- **Earth orientation.** IAU 1976 precession plus GMST; nutation and polar
  motion are not yet modelled (errors below about 20 arcseconds).
- **Vessel frame.** A vessel's origin follows its centre of mass as propellant
  is used. Parts keep their construction coordinates,
  `part.offset - vessel.structureOrigin` (for the Saturn V, its vehicle
  stations in metres).

## Data sources

- `ephem.bin`: extracted from JPL DE421 and `moon_pa_de421_1900-2050.bpc`
  (NASA/JPL, public domain) with `tools/make_ephemeris.py`.
- `stars.bin`: the ESA Hipparcos catalogue (ESA 1997, SP-1200), stars to
  V = 7, built with `tools/make_stars.py`.

## License

MIT; see [LICENSE](LICENSE).

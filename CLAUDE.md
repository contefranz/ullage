# OrbitSim — notes for Claude Code

Native Apple Silicon space flight simulator (Swift + Metal), aiming at
procedurally realistic Apollo and Space Shuttle missions. Owner: Francesco
Grossetti (Franz). Read `README.md` for architecture and `docs/ROADMAP.md` for
milestones. M0 (physics core + Metal viewer), M1 (Saturn V to parking orbit)
and M1.5 (Apollo Earth-orbit mission, pad to splashdown) are done.
- M1: the AS-506 stack (propulsion and masses calibrated to its Flight
  Evaluation Report, datasheet §9), its gimballing/TVC, the IU flight program
  with iterative guidance to the parking orbit (§8, §10), its aerodynamics with
  the launch day's atmosphere (§11), its solid motors (§12), its mass
  characteristics (§13), the WGS-84 Earth and geodetic pad (§15), engine-out
  (§16) and the ascent residuals closed on AS-506's postflight trajectory (§14,
  §17), with Earth orientation on IAU 2006/2000B and UT1, and the Apollo 11
  scenario on its GET.
- M1.5 (plan in docs/m15/): the navball HUD and Orbiter-style MFDs on physical
  keys; CSM separation with the SLA panels, the SPS and SM/CM RCS, the SCS with
  its EMS ΔV counter; the CM's entry aerodynamics, entry program, earth landing
  system and splashdown (docs/CM-entry-datasheet.md, Apollo 7's landing miss
  being an accepted deviation); the Apollo shapes, plumes, eclipse light, glow
  and canopies; the Apollo 11 return and Apollo 7 scenarios; RCS keys that
  pulse as in Orbiter (tap, hold, Ctrl for fine).

M1.6, the graphics overhaul (plan in docs/m16/), is in progress; M2 (Apollo 8)
and M2.5 (the LM) follow. See docs/ROADMAP.md.

## Rules

- Commits and PRs: no `Co-Authored-By`, no "Generated with Claude Code", no
  other trace of Claude as co-author. Author commits as the repo owner.
- Branches: short descriptive names that say what the work is, e.g.
  `m1-saturn-v-stack` or `fix-hud-mass-column`; never `claude/...` or other
  generated names. If a session starts on a generated branch, do the work on a
  descriptively named branch instead.
- Keep `OrbitCore` and `OrbitInstruments` pure Swift + Foundation (no
  Apple-only frameworks, no `simd`): they must build and test on Linux, which
  is where cloud sessions run. The same holds for `OrbitScene` once M1.6's F0
  adds it.
- Graphics placement (M1.6): OrbitCore holds what the simulation reads;
  OrbitScene (pure Swift + Foundation, Linux) holds what only the renderer
  reads; OrbitRender (macOS) holds the Metal code. Each render pass is a Swift
  file plus its own shader file, compiled into its own MTLLibrary with
  ShaderCommon in front, so a broken shader disables one pass, not the
  renderer. Each track keeps its own `docs/look/shots/<track>.json` specs and
  look-dev goldens.
- Every physics change gets a test in `Tests/OrbitCoreTests`, preferably
  against an external reference (JPL/SPICE values, published vehicle data).
- SI units everywhere in the core (m, kg, s, rad). Inertial frame is ICRF;
  positions are relative to the vessel's reference body.
- Vessel body axes: +x forward (nose), +y right, +z down.

## Commands

```sh
swift build                 # OrbitCore and OrbitInstruments everywhere; also the app on macOS
scripts/test.sh             # merge gate: both suites, -O, in parallel (1-3 min on the Mac)
scripts/test.sh full        # milestone gate: the same tests, Debug, serially (20 min or more)
scripts/test.sh fast --filter OrbitInstrumentsTests   # the MFD pages and keys alone
swift run -c release OrbitSim   # macOS only: launch the app
```

The tests must stay green in both modes, which run the same tests. Run
`scripts/test.sh` (fast) before every merge and paste its last line, the test
count, failures and times, into the PR; run `scripts/test.sh full` when a
milestone closes, and check that its count matches. Arguments after the mode
go to `swift test`. Parallel runs show a test's output only when it fails, so
read printouts (the §17 residuals in AscentResidualTests, the parking orbit)
serially: `scripts/test.sh fast --no-parallel --filter AscentResidualTests`.

The two builds are not bit-identical. At -O, LLVM merges `sin` and `cos` of
one angle into Apple's `__sincos_stret`, whose sine is 1 ulp off for about
0.2 % of arguments. Measured at the M1.5 close-out:
- the nominal ascent moved by under 3 µm over 1,300 s, and every §17 printout
  was identical;
- the Apollo 7 entry from its deorbit burn, whose on-off RCS firings amplify
  the difference, landed about 0.3 km apart and used 1.8 lb more CM RCS
  propellant.

Pins must leave room for that.

Targets: `OrbitCore` (physics, guidance, navigation, the navball's maths);
`OrbitInstruments` (depends on OrbitCore: physical keys and the keyboard
state, the MFD pages as display lists, and the hooks that read OrbitCore's
programs, e.g. EntryProgramHooks.swift); the `OrbitSim` app (macOS only,
depends on both; its MFD coastlines are a resource of the app target). On the
Mac, `xcodebuild -scheme OrbitSim-Package -destination 'platform=macOS,arch=arm64'
build test` builds and tests all three.

In Claude Code cloud sessions the SessionStart hook
(`.claude/hooks/session-start.sh`) installs the toolchain, puts it on PATH
and builds the tests in both modes (`scripts/test.sh warm`, fast first).
Elsewhere on Linux without Swift, run
`scripts/install-swift-linux.sh` first (it fetches a full Swift 6.0 toolchain
from a GitHub release, since swift.org downloads may be blocked by the network
allowlist), then `export PATH=/opt/swift/usr/bin:$PATH`.

## What can be verified where

- Linux/cloud: `OrbitCore` and `OrbitInstruments` build and test. `Sources/OrbitSim` (SwiftUI,
  AppKit, Metal) cannot be compiled; review it carefully and ask the owner to
  build in Xcode, or hand the task to a local session on the Mac.
- Mac: everything, including the Metal shaders, which are compiled at runtime
  from `Sources/OrbitSim/Rendering/Shaders.swift` (shader errors appear in the
  Xcode console and as an on-screen message).

## Data files

`Sources/OrbitCore/Resources/ephem.bin` and `stars.bin` are generated by the
scripts in `tools/` from JPL DE421 (+ `moon_pa_de421_1900-2050.bpc`) and the
Hipparcos catalogue. These inputs are available from the
`skyfielders/python-skyfield` repository (`ci/` folder) via a sparse git clone.
`landmask.bin` (OrbitCore) and `Sources/OrbitSim/MFD/Resources/coastlines.bin`
come from Natural Earth (public domain) through `tools/make_landmask.py` and
`tools/make_coastlines.py`, whose docstrings record the source commit. The
transcribed Apollo sources are in `tools/data/` and `docs/data/`.

## Open decisions

- AGC emulation for M3: Virtual AGC (GPL, would make the project GPL) versus
  an in-house emulator. Not decided.

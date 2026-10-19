# M1.5 design: Orbiter-style MFDs

> Planning document for milestone M1.5, written on 2026-10-19 by a design study (five design reports checked by a planner) and accepted by Franz with the recommended defaults (Italian keyboard confirmed). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

OrbitSim today (main 6873da7):
- The HUD is text only. Sources/OrbitSim/Views.swift:56-144 (HUDView) has four panels: status at top left; vehicle, IU, engine-out, autopilot and tanks at top right; flight data at bottom left (96-101); and a small orbit panel at bottom centre (103-110: ApA, PeA, Inc, Ecc, Period, T to Ap/Pe). The events panel is at bottom right. ContentView (32-52) overlays the HUD on the MTKView with `.allowsHitTesting(false)`, so nothing on the HUD can be clicked.
- Sources/OrbitSim/AppModel.swift: HUDState is at 13-61 and is refreshed at 10 Hz (tick 164-169, refreshHUD 297-374). The elements come from `v.elements(snapshot:)` (332). The apsides are radii less the reference body's equatorial radius (334-335). Keys are handled at 172-231, with autopilots 1-8 and 0 at 209-217.
- Sources/OrbitSim/Input.swift:26-37 keeps no modifier side and no keyCode. `key(for:)` lower-cases `charactersIgnoringModifiers`, and keyDown puts every key in `held`. As a result Shift+Z already does what Z does (full throttle), Shift+X cuts the engines, and Shift+O translates. Orbiter-style Shift MFD shortcuts would fire flight controls until this is fixed. Characters also depend on the keyboard layout, which matters on the owner's Italian layout for ` [ ] , .
- Sources/OrbitCore/Orbit/OrbitalElements.swift:4-106 has a, e, i, RAAN, argument of periapsis, true anomaly, energy and h, plus periapsis/apoapsis radius, period, mean anomaly and time to Pe/Ap.
  - The equatorial reference plane is the body's pole of date (Vessel.swift:403-406).
  - It lacks the semi-minor axis, true and mean longitude, argument of latitude, node positions and a perifocal basis.
  - Nothing in the codebase does Kepler propagation, ground tracks, the terminator, entry-interface prediction or manoeuvre planning (grep finds none).
- Vessel telemetry is at Vessel.swift:92-100: geodetic altitude, AtmosphereState, airspeed, q, Mach, angle of attack and thrust acceleration. Other helpers are surfaceVelocity and latitudeLongitude (409-418) and mainDeltaV (424). Directions for prograde, normal and radial are inertial only (Autopilot.swift:35-50). There are no target-relative or manoeuvre directions.
- Renderer.swift:351-384 (`orbitStrips`) does its own perifocal conic sampling in the app. This belongs in core.
- Guidance/FlightProgram.swift:7-17 (the `FlightProgram` protocol: update, timeToNextEvent, status) is the existing seam a burn executor (P40-like) can use.
- `AS506Postflight` (Vessel/AS506PostflightData.swift:26ff) is internal and its PFT rows are in PACSS13. An ascent-plot overlay needs a small public accessor.
- docs/ROADMAP.md:93-99 lists "HUD instruments, MFD-style displays" only under Engine and tooling.

Orbiter (github.com/orbitersim/orbiter, checked 2026-10-19):
- **Licence.** LICENSE is MIT, (c) 2000-2026 Martin Schweiger; the GitHub API reports spdx MIT. Every MFD and HUD source carries a "Copyright (c) Martin Schweiger / Licensed under the MIT License" header: Src/Orbiter/Mfd.h/.cpp, MfdOrbit, MfdSurface, MfdMap and VectorMap, MfdHsi, MfdLanding, MfdDocking, MfdAlign, MfdSync, MfdTransfer, MfdComms, hud.cpp and Orbitersdk/samples/AscentMFD. The TransX plugin (Src/Plugin/TransX) is separately MIT/X11 (Arch, Sharpe and later contributors; Src/Plugin/TransX/Licence.txt). The user manual is MIT as well (Doc/Orbiter User Manual/LICENSE.tex).
- **Exceptions.** OVP/D3D9Client is LGPL (it also ships GPL.txt). Extern/ holds third-party libraries (Lua, Penlight, imgui fonts under SIL/FFC, zlib), and Sound/XRSound has its own licence. None of these are needed.
- **Out of bounds.** Add-on MFDs that are not in the repo (IMFD, LaunchMFD, BurnTimeCalc, and NASSP's Apollo MFDs, which are GPL).

## Design

A. ORBITER'S MFD SYSTEM (design reference)

**Instrument model**
- Each mode is a subclass of `Instrument` (Src/Orbiter/Mfd.h:57ff) with:
  - a mode id and `ModeSelKey()`;
  - `BtnLabel(bt)`, 3-character labels for up to 12 function buttons;
  - `BtnMenu()`: a description and shortcut for each button (the MNU help page);
  - `KeyBuffered`/`KeyImmediate` and `ProcessButton`;
  - `UpdateDraw(Sketchpad*)`, which redraws only every InstrUpdDT (default 0.5 s, Src/Orbiter/Config.cpp:76);
  - `ReadParams`/`WriteParams` for scenario persistence, and a static `saveprm` per mode so settings survive mode switches.
- Colours: 5 schemes, each bright and dim, from Config/MFD/Default.cfg. Green is the own ship, yellow the target, grey the reference and labels, red warnings.
- Registry: `RegisterBuiltinModes` (Mfd.cpp:198-236). Add-on and vessel-specific modes register through MFDAPI (`MFDMODESPECEX`).

**Controls**
- 6+6 function buttons beside the screen, and PWR/SEL/MNU below it.
- Keyboard: Shift+key, where left Shift drives the left MFD and right Shift the right one.
  - Shift+F1 is SEL; then Shift+mode key picks the mode.
  - Shift+` is MNU; Shift+Esc is PWR.
- Mode and button pages are added when there are more than 12 of either.
- Keys are DirectInput scan codes, so they are physical keys and do not depend on the keyboard layout.

**Built-in modes** (button labels in brackets):
- **Orbit (O)**: osculating elements for the ship (green) and the target (yellow): SMa, SMi, PeA/ApA/Alt (or PeR/ApR/Rad), Ecc, T, PeT, ApT, Vel, Inc, LAN, LPe, AgP, TrA, TrL, MnA, MnL.
  - A graph of both orbits projected on the reference, ship or target plane, with radius vectors, Pe/Ap markers, AN/DN and the line of nodes.
  - The G-field contribution of the reference body; the ECL/EQU frame.
  - [REF AR TGT NT MOD FRM PRJ DST HUD]
- **Surface (S)**: artificial horizon with pitch ladder and bank, and a heading ribbon.
  - Tapes for speed (IAS/TAS/GS/OS), altitude (ALT, or ALT-R below 10 km), VS, ACC, AOA and VACC.
  - Readouts for density, static pressure, dynamic pressure, outside air temperature and Mach, plus lon/lat and their rates.
  - [IAS TAS GS OS HUD]
- **Map (M)**: cylindrical projection with coastlines and contour lines; own and other vessels; past and predicted ground track for a few orbits, or the orbit-plane great circle.
  - The horizon (visibility) circle, the terminator and sunlit side, bases and VORs.
  - Bottom readouts: lon/lat/alt/course, and the target's distance and bearing.
  - Zoom 1-128x, track mode, a DSP options page. The ground track is a ring buffer with adaptive steps (VectorMap.cpp, Groundtrack::Update).
  - [REF TGT ZM- ZM+ TRK DSP UP DN < >]
- **HSI (H)**: two gyro-compass displays, each tied to a NAV receiver: OBS course arrow, CDI, TO/FROM, and an ILS glide slope. [L/R NAV OB- OB+]
- **VOR/VTOL (L)**: top-down reticle with the transmitter's bearing and log-scale distance, a horizontal speed vector, the VTOL cone, ALT/VSPD log bars, and DIST/DIR/HSPD. [NAV]
- **Docking (D)**: approach data from IDS, XPDR or visual acquisition.
  - Approach-path cross (log scale, 0.1-1000 m), transversal velocity arrow, attitude-alignment X, bank indicator and approach cone.
  - Readouts hD/vD, hV/vV and Y/P/B, with DST and CVEL log bars.
  - [DCK NAV VIS TGT SCL HUD]
- **Align Planes (A)**: Inc and LAN of the ship and the target, RInc and its rate; angle and time to the next AN/DN (or the closest encounter).
  - A burn table: NML+/- direction, dV, burn time and time to burn, with [BURN]/[LAUNCH] cues.
  - Orbit, ballistic and surface modes; the surface mode gives the launch window from the pad.
  - [REF AR TGT ELS MOD]
- **Sync Orbit (Y)**: both orbits with a reference axis (intersections, Ap/Pe or manual), RAnm, DLng, Dist, RVel, DTmin, RInc, and lists of time to the axis for the next n orbits of each. [TGT MOD LEN R- R+]
- **Transfer (X)**: source and target orbits about a reference body.
  - A hypothetical transfer orbit set by ejection longitude and dV, with the intercept TLi and DTi and the target's position at intercept.
  - An optional numerical multi-body trajectory.
  - [REF SRC TGT NT HTO NUM UPD STP EJ+- DV+- ST+-]
  - TransX (plugin, MIT) supersedes it.
- **COM/NAV (C)**: the NAV receiver stack (108-140 MHz), signal ID and strength, and the XPDR frequency.

**Also relevant**
- The Lua ScriptMFD "RCS Attitude" (Config/MFD/Attitude.cfg) has base modes prograde, normal, perpendicular and radial, each invertible. Pitch, yaw and roll rotations can be stacked on a base mode, and a global offset (for example an engine cant) can be added. This is the "point the nose where it's most efficient" tool the owner described.
- The SDK sample AscentMFD plots altitude against time, pitch, Vrad and Vtan.
- Orbiter's HUD (hud.cpp:1307-1427):
  - Orbit mode draws prograde/retrograde markers, a pitch ladder relative to the orbital plane and an azimuth ribbon.
  - Surface mode draws a horizon ladder and a heading tape.
  - Docking mode draws approach gates.

B. WHICH MFDs ORBITSIM NEEDS

**Phase 1: Apollo Earth-orbit mission (5 modes)**
- **ORBIT (O)**, from Orbiter's Orbit mode. It covers the parking orbit, separation (with the spent S-IVB as the target) and the deorbit result.
- **MAP (M)**, the ground track.
- **SURFACE (S)**, reworked as surface and ascent data with plots. Pad, ascent and the end of entry.
- **MANEUVER (B, for burn)**, new: an Apollo P30/P40-like deorbit PAD and burn monitor. Orbiter has no built-in equivalent.
- **ENTRY (E)**, new: modelled on the Apollo Entry Monitor System (EMS).

The keys B and E are free among Orbiter's built-in keys.

**Lunar (M2 and later)**
- **ALIGN (A)**: LOI and plane changes, and the LM lift-off window, which is Orbiter's surface mode.
- **SYNC/RENDEZVOUS (Y)**: CSI/CDH/TPI phasing.
- **DOCKING (D)**: transposition and docking, and docking in lunar orbit. It needs the docking ports from M2.
- **TRANSFER/TLI (X)**: TLI and midcourse corrections, using a numerical trajectory, because patched conics are poor between the Earth and the Moon.
- ORBIT gains the ECL frame (J2000 obliquity), the G-field contribution and an SOI flag; MAP gains the Moon.

**Skip** HSI, VOR/VTOL and COM/NAV. These are aircraft radio navigation. Revisit an HSI for the Shuttle's TAEM and approach in S2, where TACAN/MLS replace VOR/ILS.

The navball (another session) is the attitude instrument. The Surface MFD therefore drops Orbiter's 2-D horizon, and is the fallback if the navball slips.

C. MINIMAL MFD FRAMEWORK

**Page model (pure Swift, data-driven)**
- `MFDPage { title, status: [MFDText], text: [MFDText], shapes: [MFDShape] }`.
  - Text sits on a fixed 32x24 character grid: `MFDText(col, row, string, style)`.
  - Shapes are in a unit square: `.polyline([P2], style, dashed)`, `.circle(center, r, style, filled)`, `.marker(P2, kind: .ship/.target/.pe/.ap/.an/.dn/.station, label)`, `.bar(...)` and `.rect`.
  - `MFDStyle` is own, ownDim, target, targetDim, reference, label, warn or alert.
- Text pages are declared as tables, `[MFDField(label: "PeA", value: KeyPath or closure over MFDContext, format: .distance)]`. This anticipates M3's "panels described as data". Graphic parts (orbit plot, map, EMS scroll) are code.

**Modes and controller**
- `protocol MFDMode: AnyObject { static var id; static var title; static var selectKey: MFDKey; var buttons: [MFDButton(label3, key, help)] { get }; func handle(_ key: MFDKey, _ ctx: MFDContext) -> Bool; func page(_ ctx: MFDContext) -> MFDPage }`, with per-mode settings that are Codable (for a later scenario save).
- `MFDContext` holds the sim, focus vessel, snapshot, time, mission-clock zero, target list and track history.
- `MFDController` keeps two `MFDPanelState { power, modeID, showModeSelect, showButtonMenu, buttonPage, modes: [id: MFDMode] }`.
  - It routes keys and builds both pages on its own clock: about 0.25 s by default (Orbiter uses 0.5 s, the HUD 0.1 s).
  - The Map's future track is recomputed at most at 1 Hz.
  - It publishes only the pages, so the HUD does not redraw them.
- Defaults by flight phase: pad and ascent, left = SURFACE and right = ORBIT; orbit, ORBIT and MAP; deorbit, MANEUVER and MAP; entry, ENTRY and SURFACE.
  - Optionally a `Scenario.mfdModes`.

**Input**
- Fix Input.swift first. On keyDown with `.shift`, take the side from the device bits: `modifierFlags.rawValue & 0x2` is left Shift and `& 0x4` is right Shift (NX_DEVICELSHIFTKEYMASK/RSHIFT).
- Map `event.keyCode` (kVK_ANSI_* positional codes, as Orbiter's scan codes are) to `MFDKey`, and queue an `MFDKeyEvent(side, key)`. Shifted keys never enter `held` or `pressedQueue`, so Shift+Z cannot throttle up.
- SEL is Shift+F1, with Shift+Tab as an alias for Mac keyboards whose F-keys need fn. MNU is Shift+` (keyCode 50, a physical key), and PWR is Shift+Esc.
- Within a mode, Shift+letter is that mode's button. On the select page, Shift+mode key picks the mode.

**Views**
- `MFDPanelView` is a square screen with 6 SwiftUI buttons down each side showing the labels, and PWR/SEL/MNU beneath. The screen is a `Canvas` drawing the display list, with `context.draw(Text)` for the grid in a monospaced font.
- `MFDPanelsView` puts the two panels at the bottom left and right, and is the only line added to ContentView.
- Buttons must not take first responder: use `.focusable(false)` and give first responder back to GameView after each click.
- The HUD keeps its `allowsHitTesting(false)`; only the MFD frames take hits.

D. WHAT EACH PHASE-1 MFD SHOWS, AND ITS ORBITCORE SOURCES

**ORBIT**
- List from `OrbitalElements`, plus new derived properties:
  - SMa, SMi = a·sqrt(1-e^2), and PeA/ApA/Alt.
    - PeA and ApA are the radius minus the equatorial radius, as the HUD shows them. DST toggles to PeR/ApR/Rad.
    - Alt is `v.altitude` (geodetic) and is labelled as such.
  - Ecc, T, PeT, ApT, Vel, Inc, LAN, AgP, TrA, TrL = RAAN + argument of periapsis + true anomaly, MnA, MnL.
- Graph: the conic from a new `OrbitalElements.perifocalBasis` (P, Q, W in ICRF) and `conicPoints(n)`, moved out of Renderer.orbitStrips. Pe/Ap/AN/DN markers and the radius vector, projected on the equator (EQU) or the ship's plane (SHP).
- TGT is another vessel (the S-IVB after separation). Its elements are shown in yellow, with range and range rate.
- Buttons: [REF AR TGT NT MOD FRM PRJ DST UNT].
  - UNT switches between SI and Apollo units (n mi, ft/s); the core stays SI.

**MAP** (equirectangular, wrapped at ±180°, zoom and track)
- Past track: a recorder of (t, lat, lon) per vessel.
- Predicted track for N orbits (default 3): `GroundTrack.predict(r, v, mu, body, orientationNow, epochNow, duration, j2Secular: true)`.
  - It propagates with Kepler, then rotates the Earth rigidly by `EarthOrientation.rotationRate`·dt about the current pole. Re-evaluating IAU 2006/2000B at each point is too costly, and precession and nutation over hours are negligible.
  - It adds secular J2 drift of RAAN and of the argument of periapsis, about -0.47° of node per orbit at 185 km and 32.5°.
- The subsolar point and terminator come from DE421: `snapshot.orientation(earth).toBody(sun - earth)`.
- The horizon circle has angular radius acos(R/(R+h)), about 13.7° at 185 km.
- Markers: LC-39A (from Scenarios), the planned and predicted splash point, MSFN stations (later). Coastlines from Natural Earth 110 m.
- Bottom line: lat, lon, alt and course; the target's distance and bearing.

**SURFACE/ASCENT**
- Readouts and tapes:
  - geodetic altitude and h-dot (as the HUD computes them);
  - orbital, surface and air speed;
  - inertial and relative flight-path angle γ = asin(r̂·v̂);
  - heading/azimuth of the surface velocity, Mach, q, angle of attack;
  - density, pressure and temperature from `v.atmosphere`;
  - thrust and sensed acceleration in g; lat/lon and their rates;
  - downrange from the pad.
- Page 2: AscentMFD-style plots of altitude against time, γ, Vrad and Vtan, overlaid with AS-506's postflight trajectory. This needs a new public `AS506PostflightProfile` accessor in a new file that converts the PACSS13 rows to altitude, speed and γ by range time.

**MANEUVER** (deorbit PAD and burn monitor)
- Inputs (buttons):
  - TIG as GET, or "at next Ap / Pe / AN / DN / argument of latitude u";
  - Δv in LVLH (Apollo P30 axes: X along the horizontal velocity, Y opposite the orbit normal, Z down), or a target HP or γ at entry interface;
  - the engine, taken from the vessel's thrusters (SPS, or RCS +X).
- Outputs:
  - Δv total and per axis, and burn time from the rocket equation with the current mass and engine rating;
  - HA/HP after the burn;
  - time to TIG;
  - predicted entry interface (EI) at 121,920 m (400,000 ft): GET, inertial and relative velocity, γ;
  - a rough splash point;
  - during the burn, Δv to go against sensed Δv.
- It exports the ICRF burn direction for the navball's manoeuvre marker.
- Core: `ImpulsiveManeuver`, `ManeuverPlanner` (postBurnElements, deorbitTargeting, burnTime), `EntryInterface.predict`, and `ManeuverProgram: FlightProgram`. The program holds the burn attitude through `attitudeCommand`/`.attitudeHold`, ignites at TIG (`timeToNextEvent` lands a step there) and cuts off on sensed Δv, the way P40 does.

**ENTRY** (EMS-like)
- Readouts:
  - V inertial and relative, altitude, γ (relative);
  - drag deceleration in g from sensed acceleration;
  - range to go and cross-range to the target splash point (great circle);
  - bank angle of the lift vector, lift up/down (roll about the relative velocity);
  - times to 0.05 g, drogue deploy (about 7.3 km) and main chutes (about 3 km), with the values to be sourced.
- The scroll plots g against V. The predicted splash point comes from the entry session's model once it exists; until then the MFD shows vacuum EI data only.

E. PORT VERSUS REIMPLEMENT
- **Legal position.** Everything under Src/Orbiter and Src/Plugin/TransX may be translated under MIT, provided the copyright and permission notice are kept: a header in each ported Swift file, plus a THIRD_PARTY_NOTICES.md naming Orbiter (Schweiger) or TransX (Arch, Sharpe et al.).
- **Reimplement** (recommended). Orbiter is left-handed and y-up, with body axes +z forward and +y up, against OrbitSim's +x nose, +y right, +z down. Its code is tied to GDI/Sketchpad and its globals (g_psys, td). Its maths is textbook: conic projection (RotMatrix/UpdateEllipse); plane-change Δv = 2v·sin(Δi/2) with node timing; Sync's time-to-axis; the Docking geometry. Line-by-line translation would mostly import sign errors.
- **Adopt freely** (design, not code): mode names and keys, 3-letter labels, element abbreviations, the green/yellow/grey semantics, the G-contribution warning, log-scale docking bars, and the select/menu page interaction.
- **Worth porting with attribution, if wanted:**
  - the ground-track ring buffer's adaptive sampling (10° target step, dt scaled by cos(latitude), incremental refresh of future points; VectorMap.cpp, Groundtrack::Update);
  - the FloatStr/DistStr 4-significant-figure number formatting with k/M/G suffixes;
  - later, Align's surface mode and TransX's planning structure for TLI.
- **Never use** D3D9Client (LGPL/GPL), NASSP or ProjectApollo MFDs (GPL), or add-ons outside the repo.

F. WORK SPLIT (disjoint files)
1. **Core navigation session** (cloud-capable): Navigation/*.swift and the OrbitalElements extensions, with tests.
2. **MFD framework session** (Mac): Input.swift fix, OrbitInstruments target, SwiftUI panels, then ORBIT, MAP and SURFACE.
3. **After the CSM/SM/CM and SPS model lands:** MANEUVER and ENTRY pages.

## OrbitCore vs app

**OrbitCore** (pure Swift + Foundation, physics only, each item tested against references)
- New folder Sources/OrbitCore/Navigation/:
  - Kepler.swift: universal-variable propagation (Stumpff functions, Newton iteration), time to a given radius or true anomaly, and `trueAnomaly(atRadius:)`.
  - GroundTrack.swift: prediction with rigid Earth rotation and secular J2, the subsolar point and terminator, and the horizon circle.
  - Maneuver.swift: `ImpulsiveManeuver`, `ManeuverPlanner` (postBurnElements, deorbitTargeting to an HP or γ at EI, burnTime with the rocket equation), and `ManeuverProgram: FlightProgram`, the P40-like burn executor.
  - EntryInterface.swift: EI prediction at 121,920 m with γ, inertial and relative speed and GET; flight-path angle; great-circle range and bearing.
- Sources/OrbitCore/Orbit/OrbitalElements.swift, extended with: semiMinorAxis, argumentOfLatitude, trueLongitude, meanLongitude, longitudeOfPeriapsis, perifocalBasis, conicPoints(n), and node vectors.
- A public `AS506PostflightProfile` in a new file, for the ascent-plot overlay.
- Later: plane alignment, sync timing, gravity contribution and relative-motion (CW) helpers.

**New pure target `OrbitInstruments`** (recommended; Foundation only, depends on OrbitCore, builds and tests on Linux)
- MFDPage display-list types, the MFDMode protocol, MFDController (panel state, key routing, mode and menu pages), and MFDFormat (number and unit formatting, SI or Apollo units).
- The modes themselves: OrbitMFD, MapMFD, SurfaceMFD, ManeuverMFD, EntryMFD. Their `page()` output and key handling are unit-tested as data on Linux.
- Fallback if the owner rejects a third target: put this in Sources/OrbitCore/Instruments/, which is still Linux-testable. The last resort is the app, where nothing can be tested in the cloud.

**Sources/OrbitSim** (macOS only, never compiled in the cloud)
- MFD/MFDPanelView.swift: SwiftUI frame, side buttons, PWR/SEL/MNU, and a Canvas that renders MFDPage.
- MFD/MFDKeyMap.swift: keyCode to MFDKey, and the Shift-side bits.
- MFD/Coastlines.swift and its resource, built by tools/make_coastlines.py.
- Input.swift: Shift-side capture, keeping shifted keys out of the flight controls.
- AppModel.swift: owns an MFDController, feeds it key events and a context, refreshes it on its own clock, and exposes `@Published mfdPages`.
- Views.swift: one line in ContentView to add MFDPanelsView. Optionally, later, remove the HUD's bottom-centre orbit panel.

The renderer is not touched. The graphics session may switch Renderer.orbitStrips to the core conic sampler.

## Data and sources

- Orbiter repository and MIT LICENSE ((c) 2000-2026 Martin Schweiger): https://github.com/orbitersim/orbiter and https://raw.githubusercontent.com/orbitersim/orbiter/main/LICENSE (GitHub API reports spdx MIT)
- Orbiter MFD sources (MIT headers): Src/Orbiter/Mfd.h, Mfd.cpp (RegisterBuiltinModes at 198-236), MfdOrbit.cpp, MfdSurface.cpp, MfdMap.cpp, VectorMap.cpp (Groundtrack), MfdHsi.cpp, MfdLanding.cpp, MfdDocking.cpp, MfdAlign.cpp, MfdSync.cpp, MfdTransfer.cpp, MfdComms.cpp, MFDAPI.cpp; HUD in Src/Orbiter/hud.cpp (HUD_Orbit::Display at 1307-1427); default MFD refresh InstrUpdDT = 0.5 s at Src/Orbiter/Config.cpp:76
- Orbiter MFD user documentation: Doc/Orbiter User Manual/MFD.tex (MIT per Doc/Orbiter User Manual/LICENSE.tex), Html/Main/mfd_*.htm
- Orbiter extras: Config/MFD/Attitude.cfg (Lua 'RCS Attitude' script MFD), Config/MFD/Default.cfg (colours), Orbitersdk/samples/AscentMFD (MIT), Orbitersdk/include/MFDAPI.h
- TransX licence (MIT/X11; Arch, Sharpe, atomicdryad, Gatsoulis, Ender): https://github.com/orbitersim/orbiter/blob/main/Src/Plugin/TransX/Licence.txt
- Excluded: OVP/D3D9Client (LGPL.txt, GPL.txt), NASSP/ProjectApollo MFDs (GPL), add-on MFDs that are not in the repo
- Vallado, Fundamentals of Astrodynamics and Applications (4th ed.), Algorithm 8 KEPLER (universal variables) and its worked example, for propagation test vectors (to transcribe from the book); Curtis, Orbital Mechanics for Engineering Students, ch. 3 and 6 (universal variables, Hohmann)
- Natural Earth 1:110m coastline (public domain): https://www.naturalearthdata.com/downloads/110m-physical-vectors/110m-coastline/
- Apollo 7 Mission Report MSC-PA-R-68-15 (Dec 1968), for the deorbit SPS burn, entry interface conditions and splash point: https://www.nasa.gov/wp-content/uploads/static/history/alsj/a410/A07_MissionReport.pdf
- Apollo Operations Handbook, Block II Spacecraft (SM2A-03-Block II), for the Entry Monitor System (0.05 g start, g-V scroll, range to go), the SPS rating and the earth-landing-system deploy altitudes (to be sourced)
- JPL Horizons, for the subsolar point at 1969-07-16 13:32 UTC (terminator test)
- In-repo: OrbitCore/Vessel/AS506PostflightData.swift (PFT Table B-II, Boeing D5-15560-6) for the ascent overlay; docs/AS506-datasheet.md §17 for the parking orbit

## Tests

**OrbitCore tests** (Linux, `swift test`)
- KeplerTests:
  - against Vallado's KEPLER worked example (Fundamentals of Astrodynamics and Applications, Algorithm 8 and its example; transcribe the book's numbers, as they are not verified here);
  - against the simulator's own RK4 two-body propagation, with J2 = 0 and no perturbers, to within 1 m after one LEO orbit;
  - a ±Δt round trip; energy and angular momentum preserved; a hyperbolic case.
- OrbitalElementsTests: SMi, TrL, MnL and AN/DN vectors on hand-built states; conicPoints lies on r = p/(1 + e·cos ν).
- GroundTrackTests:
  - the first point equals `Vessel.latitudeLongitude`;
  - the ascending node's longitude moves per orbit by -ω_E·T + ΔΩ_J2, about -22.1° - 0.47° for 185 km at 32.5°;
  - the predicted track against a full integration converted with IAU 2006/2000B orientation at each sample, within 0.05° over 3 orbits;
  - the subsolar point at Apollo 11's epoch against JPL Horizons;
  - the horizon radius equals acos(R/(R+h)).
- EntryInterfaceTests: predicted EI time and γ against the simulator stepping through 121.92 km in vacuum (within 0.1 s and 0.01°); γ against the closed form for a given perigee.
- ManeuverTests:
  - Hohmann and retrograde Δv against textbook values (Vallado or Curtis);
  - burn time against the rocket equation;
  - `ManeuverProgram` on a toy capsule ignites at TIG within one step and cuts off within 0.1 m/s of the commanded Δv;
  - once the mission session has the CSM, Apollo 7's deorbit burn and the resulting EI and splash point against the Apollo 7 Mission Report, with tolerances set in a datasheet section.

**OrbitInstruments tests** (Linux)
- Key routing:
  - Shift+F1 opens the select page and left Shift+O sets the left panel to ORBIT;
  - right-Shift keys reach only the right panel;
  - MNU shows the button help;
  - PWR off swallows keys.
- Page content: for `placeInCircularOrbit` at 185 km and 32.5°, the ORBIT page shows "PeA 185.0k", "Inc 32.50°" and the expected period. The MAP page's polylines are split at ±180°. The UNT toggle shows n mi and ft/s.

**On the Mac**
- Build with `xcodebuild build`.
- Fly the Saturn V scenario to the parking orbit:
  - SURFACE's ascent plot sits on the AS-506 PFT overlay;
  - ORBIT's PeA/ApA/Inc agree with the HUD and the datasheet §17 parking orbit;
  - MAP's track leaves the Cape over the Atlantic, the predicted track lines up with the recorded one one orbit later, and the terminator matches the rendered Earth.
- Check that Shift+Z, Shift+X and Shift+O no longer move the vehicle, and test both Shift keys on the owner's Italian layout.
- Check 1000x warp for responsiveness, against the Debug frame budget in the harness memory.
- Take screenshots of the panels at the default window size (1400x900) and the minimum (900x600).
- After the CSM lands: separate from the S-IVB and target it in ORBIT; plan a deorbit in MANEUVER, execute it, and watch ENTRY and MAP through to splashdown.

## Files touched

- Sources/OrbitCore/Navigation/Kepler.swift (new)
- Sources/OrbitCore/Navigation/GroundTrack.swift (new)
- Sources/OrbitCore/Navigation/Maneuver.swift (new: planner + ManeuverProgram)
- Sources/OrbitCore/Navigation/EntryInterface.swift (new)
- Sources/OrbitCore/Orbit/OrbitalElements.swift (extend)
- Sources/OrbitCore/Vessel/AS506PostflightProfile.swift (new public accessor; AS506PostflightData.swift untouched)
- Sources/OrbitInstruments/MFDPage.swift (new target)
- Sources/OrbitInstruments/MFDMode.swift
- Sources/OrbitInstruments/MFDController.swift
- Sources/OrbitInstruments/MFDFormat.swift
- Sources/OrbitInstruments/Modes/OrbitMFD.swift
- Sources/OrbitInstruments/Modes/MapMFD.swift
- Sources/OrbitInstruments/Modes/SurfaceMFD.swift
- Sources/OrbitInstruments/Modes/ManeuverMFD.swift
- Sources/OrbitInstruments/Modes/EntryMFD.swift
- Sources/OrbitSim/MFD/MFDPanelView.swift (new)
- Sources/OrbitSim/MFD/MFDKeyMap.swift (new)
- Sources/OrbitSim/MFD/Coastlines.swift (new) + coastlines resource
- tools/make_coastlines.py (new)
- Sources/OrbitSim/Input.swift (shift-side capture; shared seam)
- Sources/OrbitSim/AppModel.swift (own MFDController; shared seam)
- Sources/OrbitSim/Views.swift (one line in ContentView; shared seam)
- Package.swift (OrbitInstruments target + test target)
- Tests/OrbitCoreTests/KeplerTests.swift
- Tests/OrbitCoreTests/GroundTrackTests.swift
- Tests/OrbitCoreTests/EntryInterfaceTests.swift
- Tests/OrbitCoreTests/ManeuverTests.swift
- Tests/OrbitInstrumentsTests/MFDControllerTests.swift
- Tests/OrbitInstrumentsTests/OrbitMFDTests.swift
- README.md (controls: Shift-key MFDs)
- docs/ROADMAP.md (MFD items)
- CLAUDE.md (new target, if adopted)
- THIRD_PARTY_NOTICES.md (only if Orbiter code is translated)

## Depends on

- **M1 on main (6873da7):** nothing in it blocks ORBIT, MAP or SURFACE.
- **Navball/HUD session (shared seams in Input.swift, AppModel.swift and Views.swift):**
  - Agree that the MFD session lands the Input.swift Shift-side fix first, or that the navball session adopts it.
  - Each session adds its own overlay view in a new file and one line in ContentView.
  - The navball consumes the planner's burn direction for a manoeuvre marker, and target directions later.
  - If the navball session creates a shared reference-directions helper in OrbitCore, the MFD session uses it rather than writing its own.
- **CSM/SM/CM separation and entry session:**
  - MANEUVER needs the CSM part with an SPS thruster rating and RCS, and the separation events.
  - ENTRY needs the CM part, its entry aerodynamics (L/D, trim) and the parachute events, for the predicted splash point and chute timers.
  - Until then both pages show vacuum Kepler/EI data only.
- **Graphics session:** no dependency. Renderer.swift is not touched. It may later adopt `OrbitalElements.conicPoints`.
- **M2:** docking ports (for DOCKING), S-IVB restart and TLI (for TRANSFER/TLI), and the LM (for ALIGN's surface mode and SYNC) gate the lunar MFDs.

## Options (owner decisions)

1. **Where the MFD page logic lives.** Recommended: a new pure SwiftPM target, OrbitInstruments (Foundation only, Linux-testable, keeps OrbitCore purely physics). Alternatives: Sources/OrbitCore/Instruments/, or the app only (untestable in the cloud).
2. **Rendering.** Recommended: a SwiftUI Canvas over the MTKView, driven by a display list. A Metal render-to-texture is needed only for a future virtual cockpit, and the display list keeps that path open.
3. **Keys.** Recommended: Orbiter's scheme. Left Shift drives the left MFD and right Shift the right one, on physical keyCodes, so the Italian layout works. SEL is Shift+F1 (alias Shift+Tab), MNU Shift+`, PWR Shift+Esc; the side buttons are clickable too. Alternative: Ctrl for left and Option for right, if right Shift is awkward.
4. **Phase-1 modes.** Recommended: ORBIT, MAP, SURFACE/ASCENT, MANEUVER and ENTRY. Defer ALIGN, SYNC, DOCKING and TRANSFER/TLI to M2. Skip HSI, VOR/VTOL and COM/NAV until the Shuttle (S2).
5. **Visual style.** Recommended: Orbiter's green (own), yellow (target), grey (reference), red (alerts) on black, monospaced. Alternative: an Apollo-instrument look, which is more work.
6. **Units.** Recommended: SI by default with a UNT button for Apollo units (n mi, ft, ft/s), because PADs and mission reports use them. The core always stays SI.
7. **Apsis altitude convention.** Recommended: keep the HUD's radius minus the equatorial radius and label it, with DST to show radii. Alternative: geodetic height at the apsis's latitude (Apollo's HA/HP were relative to the Fischer ellipsoid), only in MANEUVER.
8. **Coastlines.** Recommended: Natural Earth 1:110m (public domain), packed by tools/make_coastlines.py into a small app resource. Alternative: lat/lon grid only.
9. **Orbiter code.** Recommended: reimplement in Swift with Orbiter as the design reference; translate only the ground-track sampling and number formatting, with an MIT notice. Do not touch D3D9Client, NASSP or out-of-repo add-ons.
10. **The HUD's bottom-centre orbit panel.** Recommended: remove it once the ORBIT MFD lands.
11. **Burn executor ownership.** Recommended: the MFD/navigation session owns `ManeuverProgram` (Navigation/Maneuver.swift); the mission session owns the CSM vehicle and SPS data.
12. **Ground-track J2.** Recommended: include the secular J2 node and perigee drift (cheap, testable). Alternative: pure Kepler, which drifts about 0.5° per orbit.

## Effort

Phase 1 is about 10.5 focused session-days. Lunar MFDs come later.

**Phase 1 (Earth-orbit Apollo)**
- Core navigation (cloud-capable), about 3.5 days:
  - Kepler propagator, OrbitalElements extensions and conic sampler: 1.0;
  - ground track with J2, terminator, horizon and recorder: 1.0;
  - manoeuvre planner, EI predictor and ManeuverProgram executor, with tests: 1.5.
- MFD framework (OrbitInstruments target, MFDPage, controller, key routing, Input.swift Shift fix, SwiftUI panels with Canvas, buttons, SEL/MNU pages), Mac: 2.0.
- ORBIT MFD: 1.0.
- MAP MFD, including the coastline tool and data: 1.5.
- SURFACE/ASCENT with plots and the AS-506 PFT overlay: 1.0.
- MANEUVER page: 0.75.
- ENTRY page: 0.75, plus about 1 day of predictor work owned by the entry session.

**Lunar (later)**
- ALIGN: 1.0.
- SYNC/RENDEZVOUS: 1.5.
- DOCKING: 1.5, after the docking ports.
- TRANSFER/TLI with a numerical trajectory: 2-3.
- ORBIT's ECL frame, G-contribution and Moon MAP: 1.0.

## Risks

- **Shift-key conflicts.** Input.swift lower-cases shifted characters into flight keys: Shift+Z is full throttle, Shift+X cuts the engines, Shift+O/I/K/J/L/U translate. MFD shortcuts are unsafe until shifted keys are kept out of `held` and `pressedQueue`. Characters also depend on the keyboard layout (the owner is on an Italian layout), so physical keyCodes are required.
- **Telling left from right Shift.** This relies on the device-dependent modifier bits (0x2/0x4). Some external or remote keyboards may not report them; a fallback such as Ctrl/Option is needed.
- **First responder and hit testing.** SwiftUI buttons over the MTKView can take first responder and swallow key-ups; held keys could then stick, or the GameView could stop receiving keys. Use `focusable(false)`, give first responder back to the GameView, and keep the HUD's `allowsHitTesting(false)`.
- **Merge conflicts** in AppModel.swift, Views.swift and Input.swift with the navball and mission sessions. Mitigate with one-line seams and new files, and land the Input fix first.
- **SwiftUI cost.** Republishing large structs at 10 Hz in Debug builds can eat the frame budget. Publish the pages separately from HUDState, refresh MFDs at about 0.25 s, and recompute the future ground track at most at 1 Hz with the rigid-rotation shortcut, not per-point IAU evaluation.
- **Prediction accuracy.**
  - The Kepler ground track and EI ignore drag, and J2 apart from the secular terms. They are invalid while thrusting or in the atmosphere, and should show "PREDICTION INVALID" when q > 0 or the vessel is under thrust.
  - Splash prediction depends on the CM entry model from another session.
- **Licence boundaries.** Orbiter core and TransX are MIT, so ports need the notice kept. D3D9Client is LGPL/GPL, and NASSP/ProjectApollo MFDs are GPL; neither may be consulted for code. Orbiter's textures and meshes are not needed and are not assumed to be covered.
- **Frame conventions.** Orbiter is left-handed and y-up with +z forward; any translated algorithm risks sign errors against OrbitSim's +x nose, +y right, +z down. Reimplement and test against references.
- **Apollo reference values.** EI conditions, deorbit Δv, chute altitudes and MSFN station coordinates still have to be transcribed from primary documents. No numbers from secondary sources should be used in tests.

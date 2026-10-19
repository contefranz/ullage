# M1.5 design: CM entry and splashdown

> Planning document for milestone M1.5, written on 2026-10-19 by a design study (five design reports checked by a planner) and accepted by Franz with the recommended defaults (Italian keyboard confirmed). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

What exists on main (6873da7), and what is missing for an entry:

- **Atmosphere** (Sources/OrbitCore/Bodies/Atmosphere.swift)
  - `USStandardAtmosphere1976` (lines 99-178) is the 1976 standard up to 86 km.
  - From 86 to 1,000 km it switches to Vallado's exponential density table (lines 138-147, 170-177), with T held at 186.87 K and the molecular weight fixed. The ceiling is 1,000 km (line 105).
  - Compared with the 1976 tables: density is about 3% low just above the 86 km join, -5.5% at 100 km, +9.7% at 120 km (entry interface, EI, is 121.9 km) and +10% at 200 km. Above about 95 km the speed of sound is too low.
  - This is fine for drag but not documented as a test target.
- **Launch-day air** (`SoundingAtmosphere`, Atmosphere.swift:27-97) is horizontally uniform.
  - `apollo11OnPad` installs it per body (AS506FlightProgram.swift:91; Simulation.swift:47-57).
  - It never goes away, so the Cape's winds and air would also apply over a Pacific recovery area.
- **Aerodynamics** (Vessel/Aerodynamics.swift)
  - `AerodynamicModel` (lines 29-153) is the launch-stack model. It assumes the CoM is on the axis (line 44): the torque is computed as if the normal force acts on the x axis (lines 149-151). An offset-CoM trim, the whole basis of Apollo lift, cannot be represented.
  - `dragAlongWind` (lines 65-67, 130-133) gives drag only.
  - `activeAerodynamics` picks the first model whose `requiredParts` are aboard (lines 159-162). `Vessel.separate` copies `aerodynamics` to the new vessel (Vessel.swift:209).
- **Simulation** (Simulation/Simulation.swift)
  - `stepFlying.deriv` (lines 241-264) adds the model's loads, otherwise a generic drag (line 257).
  - `maxStep` already drops to 0.02 s when q > 1 Pa (line 134), from about 118 km down on an orbital entry.
  - `checkSurfaceContact` (lines 330-351) has one rule: below 5 m/s the vessel is landed, otherwise it crashed. There is no water, so a nominal splashdown at about 9.5 m/s would be logged as an impact.
- **Telemetry** (Vessel.swift:91-100): altitude, air state, airspeed, q, Mach, alpha and thrust acceleration. There is no sensed (non-gravitational) acceleration, load factor, heating or bank angle.
- **Spacecraft**
  - The CSM is a single `.fixed` part with no engines (SaturnV.swift:307-317).
  - `AS506.cm` is 12,250 lb, graded L (recalled) (AS506Data.swift:493).
  - The SM/CM interface (Xa 1010) and CM apex (Xa 1137) stations are graded L (AS506Data.swift:877-878). `csmDiameter` is 154 in (line 884).
  - `VesselLibrary.capsule` (VesselLibrary.swift:8-55) is an M0 toy with Cd 1.2.
  - There is no parachute component, no apex cover, no CM RCS, no CM mass-properties data.
- **Autopilot** (Autopilot.swift:9-50)
  - Modes point +x at inertial prograde, normal, radial and so on.
  - There is no relative-wind or bank-angle mode.
  - The rate-loop machinery (`axisCommand`, the M0 law) and the hold-with-`attitudeCommand` seam (lines 192-275) are reusable.
- **`FlightProgram` protocol** (Guidance/FlightProgram.swift:7-17): `update`, `timeToNextEvent`, `status`, `allowsManualStaging`. It is the seam an entry sequencer needs, and its status line already reaches the HUD.
- **Staging**
  - `jettison(event:)` separates parts by event and lights solids, with spring `separationSpeed` (Vessel.swift:246-269).
  - `Simulation.stage(_:event:)` logs the separation (Simulation.swift:371-384).
- **Renderer**: `VesselMesh.signature` is only the part identities (Sources/OrbitSim/Rendering/Meshes.swift:13-15), so shapes added to a part at run time (a canopy) would not be redrawn.
- **Roadmap**: M2's item "Command module entry aerodynamics (lift vector control), parachutes, splashdown" (docs/ROADMAP.md:67) is the work being pulled forward.
- **Orbiter** (github.com/orbitersim/orbiter) is MIT (checked: "Copyright (c) 2000-2026 Martin Schweiger").
  - Nothing in it is needed for entry.
  - Its MIT Jacchia-71-Gill atmosphere (Src/Celbody/Atmosphere/EarthAtmJ71G) could be reused with attribution if a solar-activity thermosphere were ever wanted.
  - The NRLMSISE-00 C port bundled beside it is third-party (Brodowski), so check its licence first.
  - No NASSP material is used.

## Design

Goal: an Apollo CM that can be put at entry interface (EI), or reach it after CM/SM separation, and flown to splashdown. It needs Apollo's trim aerodynamics, bank control by the pilot or a simple autopilot, the real ELS sequence, and a water landing. Everything is testable on Linux from EI, independently of the SM/SPS work.

**1. CM data and vessel** (new: Vessel/CMData.swift, Vessel/CommandModule.swift)

- **`enum ApolloCM` data**, graded H/M/L like `AS506`:
  - OML: D = 154 in, S = 129.35 ft² = 12.017 m², d = 12.833 ft = 3.9116 m (TN D-5399). Heat-shield sphere R ≈ 184.8 in, shoulder radius ≈ 0.05 D, afterbody cone 33°. These three are M; verify from TN D-5514 Fig 2 or Apollo Working Paper 1021.
  - Mass-properties rows per mission at Entry / Drogue deploy / Main deploy / Landing: mass, CoM (Xc, Yc, Zc), inertias. Source: the Apollo 7 and Apollo 11 mission reports, App. A.6. To transcribe; Apollo 4's EI row (TN D-5399 Table II: 11,959 lb, X 1039.58, Z 6.57 in) is already in hand.
  - CM RCS: 12 × 93 lbf, two systems.
  - ELS constants (§6).
  - Two trim tables:
    - Apollo 7: MSC IN 68-FM-184 Table I(a), at CoM X 1040.58, Y -0.11, Z 5.91 in.
    - Apollo 11: TN D-6725 Table I, 12,150 lb, L/D 0.30.
  - EI states:
    - Apollo 7: 68-FM-184 Table IX(b): 400,000 ft, 25,850.3 ft/s inertial, γ -1.759°, azimuth 83.64°, 31.03°N 98.83°W.
    - Apollo 11: Entry PAD / mission report: 36,194 ft/s, about -6.5°, target 13°19'N 169°10'W, EI at 195:03:06 GET.
- **Frame.**
  - Apollo +Xc maps to +x (apex = nose), +Yc to +y, +Zc to +z.
  - Apollo's CoM offset is toward +Z, and trim lift is on the CoM side, so lift-up flies with +z (the vessel's "down", the crew's feet) away from Earth. That is the heads-down, lift-up Apollo entry.
  - Xc 1000 is taken as the heat-shield tangent plane. DeRose's X/d = 0.270 and Apollo 7's 40.58 in (0.264 d) agree; the trim checks in §2 confirm this datum.
  - The Xc to Xa offset must be settled jointly with the CSM stream; AS506Data's L stations will be replaced.
- **Parts**, so that each ELS row's mass and CoM match the mission report:
  - "CM": structure, crew, consumables, CM RCS point tanks; `.fixed`.
  - "Apex cover": forward heat shield; event 30; a few m/s `separationSpeed`.
  - "Drogue parachutes": pack; event 31; released as debris.
  - "Main parachutes": pack; event 32; released after splashdown.
  - The packs stay at their stowed location: canopies are force and visual only, never mass at riser length.
- **CM RCS**: thrusters in rotation groups, built like `addRCS` but with CM positions and directions (L). `isEnabled = false` until the SM is gone.
- **API**:
  - `VesselLibrary.commandModuleParts(_ m: ApolloCM.Mission) -> [VesselPart]`, for the CSM stream to compose.
  - `VesselLibrary.commandModule(_:) -> Vessel` (standalone), with `aerodynamics = [cm model, requiredParts ["CM"]]`.
  - The CSM stream puts a CSM drag-only model first (["CM","SM"], Cd 2.0 on 129.5 ft², 68-FM-184 Table I(d)).
  - `VesselLibrary.apollo7AtEntryInterface(in:)` and `apollo11AtEntryInterface(in:)`. They use a new placement helper, `Simulation.place(_:geodeticLatitude:longitude:height:inertialSpeed:flightPathAngle:azimuth:attitude:)`, in a new Simulation/Placement.swift. It puts the CM at trim attitude, lift-up, with the entry program aboard.

**2. Capsule aerodynamics** (new: Vessel/CapsuleAerodynamics.swift; Aerodynamics.swift gains `var capsule: CapsuleAerodynamics?`)

- **Integration.** `AerodynamicModel.loads` delegates to `capsule` when it is set, and passes the vessel-frame position of the construction axis (`structureOrigin`, so the CoM can be off-axis). The launch-stack path is unchanged.
- **Inputs.** Total angle α from +x to the flight velocity relative to the air (Apollo's convention: 180° means heat shield forward). α' = π - α.
- **M ≥ 1.1: sphere-centre model.**
  - Pressure on the spherical heat shield acts nearly through one point on the axis.
  - Per Mach knot of a trim table, calibrated at its reference CoM (x_r, z_r) from (α_t, CL_t, CD_t):
    - C_R = hypot(CL, CD)
    - δ = atan(CL/CD)
    - θ_t = α'_t - δ (the force angle from +x)
    - k = θ_t / α'_t
    - x_cp = x_r + z_r / tan θ_t
  - At run time:
    - θ_F = k α'
    - F = C_R q S (cos θ_F along +x, sin θ_F along the crossflow direction opposite the flight velocity's)
    - F is applied at (x_cp, on the axis); the moment about the actual CoM is r × F.
  - Trim then emerges for any CoM, with lift toward the CoM-offset side.
  - Checked with the Apollo 7 Mach 10 row (C_R 1.302, k 0.168, x_cp ≈ Xc 1128 in):

    | Case | Model | Published |
    |---|---|---|
    | DeRose Z/d 0.046 at X/d 0.270 | 152.2° / L/D 0.426 | 151° / 0.435 |
    | DeRose Z/d 0.028 | 163.1° / 0.251 | 162° / 0.255 |
    | ΔZ/d = 0.0015 | -0.89° | "1°" |
    | Apollo 4 CoM (TN D-5399) | 154.8° / 0.383 | flight 154.5° / 0.368 at entry, 153° / 0.41 at M 6 |

- **Two calibrations.**
  - `.operational`: the MSC preflight tables as published, including the Mach ≥ 29.5 row (160.37°, L/D 0.296). Used to compare with 68-FM-184 and TN D-6725 trajectories.
  - `.flightConsistent` (app default): holds the Mach 10 calibration above Mach 10. Apollo 4's flight data (TN D-5399: the tunnel trim about 1.5° low, L/D 10% high at high Mach) and DeRose's Mach 10-29 free-flight data show trim is Mach-independent above Mach 6-10. That Mach 29.5 row is the wind-tunnel extrapolation they correct.
- **M < 1.1.** The sphere-centre fit degenerates (θ_t → 0 at M 0.7, negative at M 0.2-0.4).
  - Anchored linear model about the reference CoM: Cm_r = Cmα,sub (α' - α'_t), with C_R(M) from the table.
  - Transfer to the actual CoM by r × F.
  - Cmα,sub comes from TN D-4688 when transcribed; -0.1/rad placeholder (L).
- **Large angles.** For α' beyond about 40° and apex-forward, blend into a full-range Newtonian model.
  - Computed once by panel integration over the OML (cap, shoulder torus, 33° cone, apex): CA, CN, Cm vs α' at 2° steps, scaled for continuity at the blend.
  - Newtonian predicts the real apex-forward stable trim, so a mis-oriented CM is a hazard as in reality.
  - Checks: the closed-form spherical cap at α = 180° (CA = Cpmax(1 + cos²θc)/2) and Apollo Working Paper 1021's R/D 1.2 curves.
- **Damping.** No Cmq: the RCS damps, as on Apollo. An option uses the air velocity at x_cp (v + ω×r).

**3. Telemetry** (Vessel.swift fields; computed in Simulation.updateTelemetry)

- `sensedAcceleration` (body axes): aero + parachute + thrust over mass, re-evaluated at the step's end.
- `loadFactor = |a| / g0`.
- `bankAngle`, defined for vessels with a capsule model: the angle about the air-relative velocity from the local-up projection to the lift side (+z projected), positive when lift is to the right looking along the velocity.
- `heatFlux`: Sutton-Graves stagnation convective heating, 1.7415e-4 sqrt(ρ/R_n) V³ W/m², with `noseRadius` per vessel.
- `heatLoad`: integrated.

**4. Entry DAP** (new Vessel/EntryAutopilot.swift; Autopilot.swift gets one enum case `.entry = "Entry"` and a dispatch line; `Vessel.entryCommand: EntryCommand?`)

- Stability axis: ŵ, the flight velocity relative to the air, in body axes.
- Bank error e = wrap(φ_cmd - φ), with a 4° deadband (L).
- Desired rate about ŵ: clamp(K e, ±20°/s) (L).
- Desired body rate ω_d = ω_φ ŵ.
- Each axis runs M0's `axisCommand` rate loop. Components perpendicular to ŵ get a ±2°/s rate deadband (Apollo 4: ±2°/s rate deadbands), so pitch and yaw are left to the aerodynamic trim. This is Apollo's coordinated roll about the velocity vector: the roll rate gyro coupled to the yaw channel (TN D-5399).
- `.rolling(rate)` gives ballistic, zero-mean-lift flight.
- Before 0.05 g the program instead uses `.attitudeHold` with `attitudeCommand` = the trim attitude about the relative wind at the commanded bank, using the model's trim α at the current CoM. This is three-axis hold until 0.05 g, as AS-501 and the CMC flew.

**5. Entry program** (new Guidance/CMEntryProgram.swift: `final class CMEntryProgram: FlightProgram`)

- **Phases.**
  1. Dormant while an "SM" part is aboard. The CSM stream attaches the program at CSM/S-IVB separation; it needs no other coupling.
  2. Pre-entry: enables the CM RCS, holds trim lift-up.
  3. At loadFactor ≥ 0.05 g (the EMS light): switches to `.entry`.
- **Trajectory modes.**
  - `.manual`: the pilot's roll keys command the stability-axis roll rate.
  - `.bankHold(φ)`: includes lift-up 0°, lift-down 180° and ±N°.
  - `.rolling(rate)`.
  - `.constantG(target)`: TN D-6725's backup mode.
    - cos φ = clamp([(g - V²/r) / a_D + K_g (g* - n) - K_d ṅ] / (L/D)), with (L/D) the trim value.
    - Hold 4 g until subcircular, then lift-up.
  - Optional g-limiter: lift-up if the predicted peak exceeds 10 g (TN D-6725).
  - Optional (owner option 3): a landing-point predictor. A 3-DOF point mass with trim aero, integrated at 1 s steps, for a predicted splash point and a predictor-corrector constant-bank guidance with bank reversals.
- **ELS sequencing on ambient static pressure**, as the baroswitches did:
  1. Apex cover jettison at p ≥ p_US76(24,000 ft) = 39.3 kPa.
  2. Drogue mortar 1.6 s later; drogues reefed for T_dr, then disreefed.
  3. At p ≥ 69.7 kPa (10,000 ft): drogue release (debris vessel), pilot mortars, mains reefed in two stages (6 s, 10 s; L until TN D-7437 is read).
  4. CM RCS off, with optional dump.
  5. After splashdown: main release, Stable I.
- **Program interface.**
  - `allowsManualStaging` lets the pilot fire any pending ELS step (crew backup).
  - `timeToNextEvent` returns the mortar and reefing timers.
  - `status` line, for example: "ENTRY bank 55°R 3.1 g 0.05g | ELS mains reefed 2 | 41 W/cm²".
- It also drops the launch-day sounding when it activates (owner option 5).

**6. Parachutes** (new Vessel/Parachute.swift; a `VesselPart.parachutes` array or a component attached to the pack parts)

- `Parachute`: count, diameter, full-open CdS per canopy, reefing stages [(duration, area fraction)], inflation ramp time, attach point (part frame; riser confluence, offset to give the 27.5° hang angle, M), state (`stowed / deploying / reefed(n) / open / released`).
- Load: F = -Σ CdS_eff · q_a · û_a at the attach point, where û_a and q_a use the air velocity at that point including ω × r. This gives physical shuttlecock damping with no extra coefficient; the torque is r × F.
- `Simulation.deriv` sums `v.parachuteLoads(...)` next to the aero loads (one seam).
- **Calibration.**
  - Mains CdS from the published sea-level descent rate at the landing mass: 3 mains about 31-33 ft/s, L until TN D-7437 is read; 2 mains below 38 ft/s, Bellcomm via search, M.
  - Drogue CdS from the drogue-phase durations: 53 s (68-FM-184); 47.2 s on Apollo 4 (TN D-5399 Table I).
- **Visuals.** On deploy the pack part gains a canopy frustum along +x at riser length. This needs the graphics stream's signature fix.

**7. Water landing** (Simulation.checkSurfaceContact; new Bodies/SurfaceMask.swift + Resources/landmask.bin + tools/make_landmask.py)

- `CelestialBody.surfaceKind(latitude:longitude:)`: Earth uses a 0.25° land bitmask from Natural Earth (public domain), about 130 KB; other bodies are land.
- Sea level is the WGS-84 ellipsoid. Geoid ignored, documented: |N| ≤ about 100 m, at most 10 s at 9.5 m/s.
- `Vessel.impactLimits (water, land)`: default 5/5 m/s (M0 behaviour); the CM about 15 m/s water (design 2-main rate plus margin, L) and 5 m/s land.
- A water contact under the limit goes `.landed` with `LandedState.surface = .water` and logs "splashdown at 9.6 m/s". The vessel floats fixed in the rotating Earth (existing landed kinematics, 10 s steps), attitude set to Stable I (apex up).

**8. Atmosphere above 86 km** (Atmosphere.swift)

- Replace the exponential rows with the 1976 tables, 86-1,000 km:
  - T, p and ρ at 2-5 km steps to 150 km and 10-50 km above.
  - log-linear ρ and p, linear T.
  - Speed of sound from T with M0 to 120 km.
- Keep the 86 km join continuous.

**9. App** (Mac; coordinate with the HUD stream)

- **Scenarios**:
  - "Apollo 7 CM at entry interface": 1968-10-11 15:02:45 UTC + GET.
  - "Apollo 11 CM at entry interface": 1969-07-24 16:35:06 UTC.
  - Both start paused, lift-up, with the program aboard.
- **Keys** while the entry program is active:
  - Q/E: stability-axis roll, or ±15° steps of the bank hold.
  - 9: cycle Lift-up → Bank hold → Rolling → Constant g → Off.
  - Space: next ELS step.
- **HUD** (HUD stream): g-meter, bank, heat flux, ELS state, and later an EMS-style V-g trace and the predicted splash point. Until then the program status line carries this with no app change.

**10. Docs**

- docs/CM-entry-datasheet.md, with sources, chosen values and grades.
- tools/data CSVs transcribed by two readers from page images: 68-FM-184 Tables I and IX, TN D-6725 Table I, TN D-5399 Tables I and II, DeRose's trim points, then mission-report mass properties and TN D-7437's ELS.
- ROADMAP: move the M2 entry item into a "return from Earth orbit" step.
- README: controls.

## OrbitCore vs app

**OrbitCore** (pure Swift and Foundation, all tested on Linux):
- CM data and parts factory, and the EI placement helper
- `CapsuleAerodynamics`, including the Newtonian OML integration and the trim calibrations
- `AerodynamicModel` delegation with the off-axis CoM
- `Parachute` component and loads
- New telemetry: sensed acceleration, load factor, bank angle, Sutton-Graves heat flux and heat load
- `.entry` autopilot mode and entry DAP
- `CMEntryProgram`: phases, bank modes, constant g, optional predictor, ELS on baroswitch pressure, splashdown actions, status line
- Water/land mask and impact limits in `checkSurfaceContact`
- US Standard Atmosphere 1976 tables to 1,000 km
- `tools/make_landmask.py` and the transcribed `tools/data` CSVs

**Sources/OrbitSim** (macOS only, verified in Xcode):
- Two entry scenarios. Ideally in a new EntryScenarios.swift as an extension of `Scenario`, plus one line in `Scenario.all`.
- Entry key bindings in Input.swift and AppModel.handleKeys, coordinated with the HUD/MFD stream.
- Entry HUD/MFD elements: g-meter, bank, heating, ELS state, EMS-style V-g trace, predicted splash point. Owned by the HUD stream; it only reads the new Vessel telemetry and `FlightProgram.status`.
- Canopy and apex-cover visuals, which need `VesselMesh.signature` to include per-part shape revisions (Meshes.swift:13-15). Owned by the graphics stream. Optional entry plasma glow driven by `heatFlux`.

No physics lives in the app.

## Data and sources

- MSC Internal Note 68-FM-184, Apollo 7 Spacecraft Operational Trajectory Rev. 1, Vol. I (31 Jul 1968), https://ibiblio.org/apollo/Documents/HSI-209546.pdf: Table I(a) CM trim CL, CD, L/D, alpha for Mach 0.2-29.5 at CoM X 1040.58, Y -0.11, Z 5.91 in; Table I(b)-(d) SPS 21,080 lbf at 312.34 s, SM RCS, CM 12,384 lb, CSM Cd 2.0 on 129.5 ft2; Table IX deorbit and EI state (25,850.3 ft/s, -1.759 deg, 83.64 deg, 31.03N 98.83W, 826 s coast); par. 5.4: max 3.3 g, 59.8 BTU/ft2/s, 12,649 BTU/ft2, 53 s on drogues, 4 min 45 s on mains, landing 10:20:09:53 GET at 29.8N 67W, target on the 55-deg bank contour; Figs 8-15 time histories and EMS trace
- NASA TN D-6725, Graves and Harpold, Apollo Experience Report: Mission Planning for Apollo Entry (Mar 1972), https://ntrs.nasa.gov/api/citations/19720013191/downloads/19720013191.pdf: Table I Apollo 11 CM trim aero (M 0.4 to >29.5); 12,150 lb, L/D 0.30; guidance phases, 0.05 g and 0.2 g, 10-g limiter, 15-deg lateral roll; EMS; constant-g (4 g) backup and Fig. 6 equilibrium bank vs V; Apollo 11 EI target 36,194 ft/s and -6.5 deg, range 1,285 changed to 1,492 n mi
- NASA TN D-5399, Hillje, Entry Aerodynamics at Lunar Return Conditions Obtained from the Flight of Apollo 4 (Oct 1969), https://ntrs.nasa.gov/api/citations/19690029435/downloads/19690029435.pdf: S 129.35 ft2, d 12.833 ft; flight trim 154.5 deg (entry) to 153 deg (M 6), (L/D)R 0.368 to 0.41, tunnel trim about 1.5 deg low and L/D 10% high at high Mach; Table I events (EI 29,968.54 s, 0.05 g about 29,999 s, drogue 30,678.6 s, main 30,725.8 s, landing 31,029.2 s); Table II CoM and mass (X 1039.58, Z 6.57 in, 11,959 lb at EI); +/-2 deg/s RCS rate deadbands, about 90 lb RCS, about 210 lb ablator; Figs 6b (bank history) and 7 (trajectory reconstruction) for a replay test
- NASA TN D-5276, DeRose, Trim Attitude, Lift and Drag of the Apollo Command Module with Offset CG Positions at Mach Numbers to 29 (Jun 1969), https://ntrs.nasa.gov/api/citations/19690020179/downloads/19690020179.pdf: Z/d 0.046 gives 151 deg and L/D 0.435; Z/d 0.028 gives 162 deg and L/D 0.255, at X/d 0.270; Mach-independent from 10 to 29; 0.0015 Z/d is about 1 deg; CoM referred to the heat-shield centreline
- NASA TN D-5514, Moseley and Wells, Wind-Tunnel Investigation of the Aerodynamic Pressures on the Apollo CM (Oct 1969), https://ntrs.nasa.gov/api/citations/19690030960/downloads/19690030960.pdf: Cp distributions for alpha 0-180 deg, M 0.4-19; OML sketch
- NASA TN D-4688, Moseley, Graham and Hughes, Aerodynamic Stability Characteristics of the Apollo Command Module (Aug 1968), https://ntrs.nasa.gov/api/citations/19680021973/downloads/19680021973.pdf (over 10 MB, not read): full-range CA, CN, Cm and damping; TN D-3890 (1967) not found online
- Apollo Working Paper 1021, Newtonian Static Longitudinal Aerodynamic Characteristics of Bodies of Revolution with Various Heat-Shield Curvatures (1961), https://ntrs.nasa.gov/api/citations/19700025216/downloads/19700025216.pdf: Newtonian reference curves, R/D 0.8-2
- NASA TN D-7437, West, Apollo Experience Report: Earth Landing System (Nov 1973), https://ntrs.nasa.gov/citations/19740003586 (PDF over 10 MB, not read): ELS sequence, chute sizes, reefing, descent rates
- NASA History (Uri, May 2023), Apollo parachute development, https://www.nasa.gov/history/60-years-ago-apollo-parachute-development-and-testing/: 9 chutes (7 ft apex-cover chute, 2 x 16.5 ft drogues mortared 1.6 s after cover jettison at about 24,000 ft, disconnect at about 11,000 ft, 3 x 7 ft pilots, 3 x 83.5 ft mains with two-step reefing), about 22 mph at splashdown
- MSC Internal Note 65-FM-157, Hunt, Apollo Reentry Guidance and Navigation Equations and Flow Logic (Dec 1965), https://ibiblio.org/apollo/Documents/19750065842_1975065842.pdf, and the Colossus GSOP Section 5, https://ibiblio.org/apollo/Documents/Preliminary-GSOP-LunarLandingMission-Section5-CMC.pdf (not read): CMC entry guidance for M3
- Apollo 11 Mission Report MSC-00171, https://www.nasa.gov/wp-content/uploads/static/history/alsj/a11/a11mr_NoMissingPages_19700008096.pdf (over 10 MB, not read): App. A.6 mass properties at entry, drogue, main and landing; par. 7.5 entry; trajectory event table
- Apollo 7 Mission Report, https://www.nasa.gov/wp-content/uploads/static/history/alsj/a410/A07_MissionReport.pdf (not fetched; returned 404 to the fetcher): as-flown entry, mass properties
- MSC Internal Note 70-FM-30, Apollo 11 Entry Postflight Analysis (20 Feb 1970), https://www.nasa.gov/wp-content/uploads/static/history/afj/ap11fj/pdf/19740072963_as11-entry-analysis-19700220.pdf (returned 404 to the fetcher): reconstructed entry for a later residual test
- Apollo Flight Journal, Apollo 11 day 9 re-entry, https://www.nasa.gov/history/afj/ap11fj/26day9-reentry.html (not read; its contents reached here only through search-result summaries): EI 195:03:06; Entry PAD V400k 36,194 ft/s, gamma about -6.5 deg; target 13 deg 19 min N, 169 deg 10 min W
- U.S. Standard Atmosphere 1976 (NOAA/NASA/USAF), NTRS 19770009539: 86-1,000 km tables
- Sutton and Graves, NASA TR R-376 (1971): stagnation-point convective heating constant
- Natural Earth land polygons (public domain): Earth land/sea mask
- Orbiter, https://github.com/orbitersim/orbiter (MIT, Martin Schweiger): Src/Celbody/Atmosphere/EarthAtmJ71G only if a solar-activity thermosphere is wanted later; not needed for entry

## Tests

All in Tests/OrbitCoreTests and run on Linux; the reference is named in each case.

**CapsuleAerodynamicsTests**
1. **Trim tables at their reference CoMs.**
   - Every row of 68-FM-184 Table I(a), at Apollo 7's CoM, has zero pitching moment at α_t, and CL, CD at α_t to 1e-9. The check goes through `AerodynamicModel.loads` with the CoM off the axis, so the sign of lift (toward +z) and of the moment is checked as well.
   - The same for TN D-6725 Table I at Apollo 11's CoM, once the mission report is transcribed.
2. **CoM sensitivity against DeRose (TN D-5276).**
   - X/d 0.270, Z/d 0.046: 151° ± 1.5°, L/D 0.435 ± 0.02.
   - Z/d 0.028: 162° ± 1.5°, L/D 0.255 ± 0.02.
   - ΔZ/d = 0.0015 gives about 1°.
   - No Mach dependence from 10 to 29 in the flight-consistent calibration.
3. **Apollo 4 flight (TN D-5399).** With the Table II CoM and mass: α_R 154.5° ± 1° and (L/D)_R 0.368 ± 0.02 at entry; 153° and 0.41 ± 0.02 at Mach 6.
4. **Prediction for Apollo 11.** The Apollo 7-calibrated model at Apollo 11's reported CoM predicts TN D-6725's trim to ±0.5° and L/D to ±0.01 at Mach 2-10.
5. **Newtonian limit.** The spherical-cap closed form at α = 180°; Apollo Working Paper 1021's R/D 1.2 points (digitised).
6. **Static stability.** Cmα < 0 at trim for every Mach.

**UpperAtmosphereTests**
- 1976 table values at 86, 90, 100, 110, 120, 150, 200, 300, 500 and 1,000 km: ρ within 0.5%, T within 0.1 K. Examples: ρ(100 km) 5.604e-7, ρ(120 km) 2.222e-8 kg/m³, T(120 km) 360 K.
- Continuity at 86 km.

**ParachuteTests**
1. **Descent rates.** At the landing mass at sea level: 3 mains 31-33 ft/s; 2 mains below 38 ft/s; drogue rate from TN D-7437 once read.
2. **ELS sequence by pressure.** A CM falling from 30,000 ft at equilibrium:
   - cover jettison at 39.3 kPa;
   - drogue mortar 1.6 s later;
   - mains at 69.7 kPa, with reefing at 6 and 10 s;
   - drogue phase 53 ± 5 s and main phase 285 ± 20 s (68-FM-184 §5.4.4); Apollo 4's 47.2 s and 303.4 s (TN D-5399 Table I) as a second case.
3. **Oscillation** under the mains decays (the ω × r damping).
4. **Drogue release** leaves a debris vessel, and mass and momentum are conserved.

**EntryTests**
1. **Bank geometry** for lift-up, lift-down and sign.
2. **DAP response.** At Mach 20, a bank command of 55° is reached within 4° in under 5 s, at no more than 20°/s, with pitch and yaw rates within 2°/s. CM RCS propellant is checked against Apollo 4's roughly 90 lb for a whole entry (soft check).
3. **Pre-entry hold and 0.05 g.** The CM is at trim and lift-up at EI. 0.05 g arrives where 68-FM-184 Fig. 8 puts it, and about 31 s after EI for Apollo 4 (TN D-5399 Table I: EI 29,968.54 s, 0.05 g at about 29,999 s).
4. **Apollo 7 end to end** (operational calibration). From 68-FM-184 Table IX(b) at constant bank 55° (the report puts the target on the 55° bank contour):
   - peak load factor 3.3 ± 0.3 g;
   - splashdown within about 30 n mi of 29.8°N 67.0°W;
   - EI to drogue about 625 s;
   - EI to landing 963 ± 30 s. This comes from landing at 10:20:09:53 GET and deorbit cutoff at 10:19:40:04 plus the 826 s coast.
   - heating checked against 59.8 BTU/ft²·s peak and 12,649 BTU/ft² total, with a stated band after choosing R_n.
5. **Constant g.** At lunar-return EI (36,194 ft/s, -6.5°), 4 ± 0.3 g is held until about 26,000 ft/s. The commanded bank follows TN D-6725 Fig. 6's equilibrium curve.
6. **Lift-up corridor.** At -6.5° from 36,194 ft/s the peak stays under 10 g (TN D-6725 corridor).

**SplashdownTests**
- Landmask at known points: LC-39A is land; Apollo 7's actual and Apollo 11's 13°19'N 169°10'W are water.
- Water contact at the mains rate gives `.landed` with `surface .water`, a floating state and Stable I.
- Drogue-only impact, and land above the limit, give crashed.
- Default limits keep M0's tests green.

**PlacementTests**
- The EI helper reproduces the given altitude, speed, γ and azimuth to 1e-6.

**App, on the Mac**
- Fly both scenarios by hand and on each autopilot mode to splashdown.
- Check the status line, the canopies (after the graphics fix) and the log: "0.05g", apex cover, drogues, mains, "splashdown at x m/s".
- Run with xcodebuild, with screenshots.

## Files touched

- Sources/OrbitCore/Vessel/CMData.swift (new)
- Sources/OrbitCore/Vessel/CommandModule.swift (new)
- Sources/OrbitCore/Vessel/CapsuleAerodynamics.swift (new)
- Sources/OrbitCore/Vessel/Parachute.swift (new)
- Sources/OrbitCore/Vessel/EntryAutopilot.swift (new)
- Sources/OrbitCore/Guidance/CMEntryProgram.swift (new)
- Sources/OrbitCore/Simulation/Placement.swift (new: EI placement helper)
- Sources/OrbitCore/Bodies/SurfaceMask.swift (new)
- Sources/OrbitCore/Resources/landmask.bin (new)
- tools/make_landmask.py (new)
- Sources/OrbitCore/Vessel/Aerodynamics.swift (capsule delegation, axis offset)
- Sources/OrbitCore/Simulation/Simulation.swift (deriv: parachute loads seam; updateTelemetry: sensed g, bank, heat; checkSurfaceContact: water, impact limits)
- Sources/OrbitCore/Bodies/Atmosphere.swift (US76 tables 86-1000 km)
- Sources/OrbitCore/Bodies/CelestialBody.swift (surfaceKind)
- Sources/OrbitCore/Vessel/Vessel.swift (telemetry fields, entryCommand, impactLimits, LandedState.surface) - shared with the HUD stream, small additive edit
- Sources/OrbitCore/Vessel/Autopilot.swift (one enum case .entry plus dispatch) - shared with the HUD stream
- Package.swift (landmask resource)
- Tests/OrbitCoreTests/CapsuleAerodynamicsTests.swift (new)
- Tests/OrbitCoreTests/UpperAtmosphereTests.swift (new)
- Tests/OrbitCoreTests/ParachuteTests.swift (new)
- Tests/OrbitCoreTests/EntryTests.swift (new)
- Tests/OrbitCoreTests/SplashdownTests.swift (new)
- Tests/OrbitCoreTests/PlacementTests.swift (new)
- tools/data/68fm184_table1a_cm_trim.csv, 68fm184_table9_entry.csv, tnd6725_table1_a11_trim.csv, tnd5399_tables1_2.csv, tnd5276_trim_points.csv (new, plus later mission-report mass properties and TN D-7437 ELS)
- docs/CM-entry-datasheet.md (new)
- docs/ROADMAP.md, README.md, CLAUDE.md status line
- Sources/OrbitSim/EntryScenarios.swift (new) plus one line in Scenarios.swift (Scenario.all)
- Sources/OrbitSim/Input.swift and AppModel.swift (entry keys) - coordinate with the HUD stream
- Sources/OrbitSim/Rendering/Meshes.swift (shape revision in VesselMesh.signature) - graphics stream

## Depends on

**Can start now.** All the CM-at-EI work, its tests and both entry scenarios start at entry interface and need nothing from the other streams.

**Integration into the full Apollo 11 flight** needs the CSM stream to deliver:
- CSM/S-IVB separation;
- an SM part named "SM" with the SPS and SM RCS;
- a deorbit burn and CM/SM separation;
- composition of `VesselLibrary.commandModuleParts` in place of today's single "CSM" part (SaturnV.swift:307-317);
- attachment of `CMEntryProgram`, which stays dormant while "SM" is aboard;
- a CSM drag-only model ahead of the CM model in `aerodynamics`;
- the Xc to Xa station mapping, agreed jointly.

**Other streams:**
- Graphics: per-part shape revisions in `VesselMesh.signature` (Meshes.swift:13-15), so canopies and the jettisoned apex cover show.
- HUD/MFD: displays the new telemetry. The `FlightProgram` status line covers the gap.

**File ownership.**
- This stream owns Simulation.swift, Aerodynamics.swift, Atmosphere.swift and its new files.
- The additive edits to Vessel.swift (telemetry fields) and Autopilot.swift (one enum case) should land first, in one small PR, because the HUD stream may touch the same files.
- Data that needs large PDFs (Apollo 7 and Apollo 11 mission reports App. A.6, TN D-7437, TN D-4688, all over 10 MB) needs the owner's go-ahead to download.

## Options (owner decisions)

1. **Aerodynamic model fidelity.** Default: the trim-calibrated sphere-centre model from the MSC trim tables, with a Newtonian full-range blend computed on the OML. Alternative: transcribe the full-range wind-tunnel CA, CN, Cm and damping from TN D-4688 / TN D-3890 (+1-1.5 days).
2. **High-Mach calibration.** Default for the app: flight-consistent, holding the Mach 10 calibration above Mach 10 (backed by Apollo 4 flight data and DeRose's free-flight data). The MSC preflight `.operational` tables are kept for comparisons with the operational trajectories.
3. **Guidance now.** Default: manual stability-axis roll; bank hold (lift-up, lift-down, ±N°); rolling; TN D-6725's constant-g backup; optional g-limiter. Option: a 3-DOF landing-point predictor shown on the HUD, with a predictor-corrector constant-bank guidance to a target (+1 day). Defer the CMC P61-P67 to M3. Their equations (Colossus GSOP §5, MIT R-532, MSC 65-FM-157) are NASA/MIT documents, so reimplementing them raises no GPL question; only Virtual AGC's code is GPL.
4. **Atmosphere above 86 km.** Default: the 1976 tables to 1,000 km (small job). No Jacchia or NRLMSISE: Orbiter's MIT J71G is available later if orbital decay ever matters.
5. **Launch-day sounding during entry.** Default: the entry program, or the CSM stream at CSM separation, removes `sim.atmospheres[earth]`, so the standard air applies over the recovery area. Alternative: geolocated soundings, which needs a position-aware `Atmosphere` API.
6. **Land or water.** Default: a 0.25° Natural Earth land mask (+0.5 day). Cheaper: treat all Earth contacts as water away from the launch pads.
7. **Geoid.** Default: ignore it; sea level is the ellipsoid. Option: a coarse EGM96 grid.
8. **Heating.** Default: Sutton-Graves convective stagnation flux and heat load as telemetry only. No radiative heating and no ablation: mass loss comes through the mission report's mass-properties rows.
9. **Parachute dynamics.** Default: drag at the riser attach point using the air velocity there, ω × r included, and a 27.5° hang-angle attach offset. Not proposed: separate canopy bodies with elastic risers.
10. **After splashdown.** Default: Stable I directly. Option: Stable II with uprighting-bag delay (cosmetic).
11. **ELS triggering.** Default: automatic on baroswitch pressure, with manual Space backups.
12. **Reference CM.** Default: Apollo 7 first; it matches an Earth-orbit return and its 68-FM-184 data are complete. Apollo 11 data added for the lunar-return scenario. Apollo 4's flight data are a later residual test, replaying its bank history (TN D-5399 Fig. 6b) against its trajectory reconstruction (Fig. 7).
13. **Milestone placement.** Default: a new "return from Earth orbit" step after M1, pulling M2's entry item forward. The CMC remains M3.

## Effort

About 10 focused session-days for the default scope.

| Item | Days |
|---|---|
| Capsule aerodynamics, off-axis CoM integration and its reference tests | 2.0 |
| CM data and parts factory, EI placement helper, transcriptions and datasheet section | 1.5 |
| Parachute component and ELS sequencing | 1.5 |
| Entry DAP, `.entry` mode and program modes (bank, rolling, constant g) | 1.5 |
| Telemetry: g, bank, heating | 0.5 |
| 1976 atmosphere to 1,000 km | 0.5 |
| Water landing, land mask, impact limits, floating state | 1.0 |
| Apollo 7 and Apollo 11 end-to-end tests, docs and ROADMAP | 1.0 |
| App scenarios and keys, Mac verification | 0.5 |

Optional additions:
- Landing-point predictor and guidance: +1.0
- Full-range TN D-4688 transcription: +1.0 to 1.5
- Apollo 4 flight replay residual test: +1.0

Splitting across sessions:
- One stream should own Simulation.swift.
- PR 1 (about 4 days): aerodynamics, telemetry, DAP, placement. It includes the small Vessel.swift and Autopilot.swift edits.
- PR 2 (about 4 days): CM vessel, parachutes, ELS, splashdown.
- PR 3 (about 2 days): atmosphere, end-to-end tests, scenarios, docs.

## Risks

- **CoM datum and sensitivity.** Trim moves about 1° per 0.0015 d, which is 0.23 in of CoM offset.
  - The Xc 1000 datum is inferred as the heat-shield tangent plane: DeRose's X/d 0.270 and Apollo 7's 0.264 d agree.
  - DeRose also shows the CoM must be referred to the heat-shield centreline (AS-202: 4.65 against 5.23 in structural).
  - A wrong datum shifts trim by degrees, so the test suite pins it.
- **OCR and transcription.** The 68-FM-184 and TN D-6725 table values above come from OCR text layers. Re-read them from the page images with two readers, per the repo standard.
- **Unread primary data.** These are over 10 MB, so not fetched here; values from them are graded L until read:
  - mission-report mass properties and inertias at the ELS stages;
  - TN D-7437 ELS reefing ratios, durations and descent rates (sources disagree on the drogue disreef: 6, 8 or 10 s; apex cover at 24,000 or 25,000 ft; drogue disconnect at 10,000 or about 11,000 ft);
  - TN D-4688 full-range coefficients.
- **Preflight against flown.** The Apollo 7 operational trajectory is a preflight 3-DOF run under CMC guidance. A 6-DOF open-loop constant-bank comparison needs honest tolerances, and as-flown data from the mission report will differ from it.
- **Subsonic and transonic behaviour.** Trim is only anchored there, and the CM's dynamic instability (positive Cmq) is not modelled. The RCS rate damping masks this; behaviour after the RCS is disabled under the mains relies on the parachute damping.
- **Stiffness and run time.** Parachute opening shock and the riser lever arm make the dynamics stiff, and RK4 at 0.02 s must stay stable, so the drag area is ramped over the inflation time. A full Apollo 7 entry is about 48,000 steps of 0.02 s; Debug test time must stay acceptable.
- **Mis-oriented capsules.** The Newtonian blend reproduces the apex-forward stable trim, so an unprepared player can tumble into a fatal attitude. This is realistic but needs the DAP's pre-entry hold and clear HUD cues.
- **Launch-day sounding.** It is horizontally uniform and silently applies the Cape's air and winds over the recovery area unless it is dropped (option 5).
- **Interim crash logging.** Until the water landing lands, `checkSurfaceContact` logs every splashdown as an impact (5 m/s rule).
- **Parallel edits.** Vessel.swift, Autopilot.swift and Scenarios.swift are shared with the HUD and CSM streams; the CSM stream must not rebuild the CM part independently.
- **Licensing.** Avoid NASSP material, including its wiki, and use NASA, MIT and Bellcomm primary documents only. Orbiter is MIT and needs attribution if any code is reused; none is needed here.

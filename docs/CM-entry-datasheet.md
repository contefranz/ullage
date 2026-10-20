# Apollo command module entry: datasheet for OrbitSim M1.5

Compiled on 2026-10-19 for M1.5 track E1 (entry flight, from entry interface to the drogues). It covers the CM's entry aerodynamics, the atmosphere above 86 km, and the entry telemetry. `Sources/OrbitCore/Vessel/CapsuleAerodynamics.swift`, `Bodies/Atmosphere.swift` and `Simulation/EntryTelemetry.swift` hold what the simulator uses, with the same sources and grades. The design is docs/m15/design-entry-splashdown.md, as corrected by docs/m15/plan.md (where they differ, the plan wins).

**Data.** Every number from a primary document comes from track D's transcriptions in `tools/data/`: read from the page images by two independent readers, checked, and graded (log: docs/data/apollo-spacecraft/README.md). The tests compare the Swift copies with those CSVs cell by cell.

## Conventions

- **Frames.** The CM is built in Apollo axes through `ApolloAxes`: X_A = +x (towards the apex), Y_A = −y, Z_A = −z in the Saturn's construction axes (datasheet AS506 §12, H). CM stations X_c are X_A: the Mission Reports' CM CG rows and 68-FM-184's trim CoM are on one scale. X_c 1000 is the heat shield's tangent plane (TN D-5399 Table II footnote b; DeRose measures x from the front face).
- **Angles.** α is the total angle from +x to the velocity relative to the air (180° is heat shield forward, as in 68-FM-184 Table I(a)); α' = 180° − α. The crossflow direction ê is the direction of the air velocity's component across the axis.
- **Lift side.** The CM's CoM lies 5.9-6.6 in off the axis towards +Z_A, construction −z, the crew's feet. Trim lift points that way. **Lift up is therefore the crew heads down**, as Apollo flew it. Nothing in the code names ±z: the lift side is wherever the CoM is (`Vessel.liftSide`, `CapsuleAerodynamics.loads`), and `CapsuleAerodynamicsTests.testLiftFollowsTheCentreOfMass` moves the CoM to −Z_A and checks that the lift follows.
- **Units.** SI in the code; inches, pounds and feet as the sources print them here. Reference area S = π d²/4 = 129.35 ft² (12.017 m²) and diameter d = 154 in (3.9116 m) (TN D-5399, H). 68-FM-184 does not print the reference with its Table I(a); its Table I(d) gives 129.5 ft² for the CSM drag only.
- **Grades.** H = high, M = medium, L = low.
- **Sources.**
  - 68-FM-184: MSC Internal Note 68-FM-184, *Apollo 7 Spacecraft Operational Trajectory*, Rev. 1, Vol. I (31 July 1968). Table I(a), the CM's trim coefficients; Table IX, deorbit and entry interface; §5.4.
  - TN D-5399: Hillje, *Entry Aerodynamics at Lunar Return Conditions Obtained from the Flight of Apollo 4* (1969). Tables I and II, text.
  - TN D-5276: DeRose, *Trim Attitude, Lift and Drag of the Apollo Command Module with Offset Center-of-Gravity Positions at Mach Numbers to 29* (1969). Table I and text.
  - US76: *U.S. Standard Atmosphere, 1976* (NOAA-S/T 76-1562), Part 4 Table I.
  - A7MR: Apollo 7 Mission Report (MSC-PA-R-68-15), Table A.5-I.
  - TR R-376: Sutton and Graves (1971), the stagnation-point heating constant.

## 1. Atmosphere above 86 km

Up to 86 km `USStandardAtmosphere1976` is unchanged: US76's seven geopotential layers, with linear molecular-scale temperature T_M and M0 = 28.9644 kg/kmol. From 86 to 1,000 km the Vallado exponential rows (density only, T held at 186.87 K) are replaced by US76 Part 4 Table I:

| Item | Value | Source | Grade |
|---|---|---|---|
| Rows | 136: every 0.5 km to 100 km, 1 km to 150 km, 5 km to 225 km, 10 km to 500 km, then 525-1,000 km. The table prints more; the rows between lie log-linear on these | US76 via tools/data/us76_table1_86_1000km.csv | H |
| Pressure, density | log-linear between rows, as printed | US76 | H |
| Kinetic temperature | US76's own profile: 186.8673 K to 91 km; the ellipse T_c + A √(1 − ((z − 91)/a)²) (T_c 263.1905 K, A −76.3232 K, a −19.9429 km) to 110 km; +12 K/km to 120 km; then 1000 − 640 exp(−0.01875 ξ), ξ = (z − 120)(r0 + 120)/(r0 + z), r0 = 6,356.766 km. Within 0.01 K of every printed row | US76 | H |
| Speed of sound | √(γ p/ρ), γ = 1.4: US76's √(γ R* T_M/M0), continuous at 86 km. Only nominal above about 120 km, where the air is mostly atomic | US76 (definition below 86 km) | M |

**Checks** (`UpperAtmosphereTests`):
- Every transcribed row: the model's table holds the printed pressure and density; temperature within 0.01 K; speed of sound within 0.02 % of √(γ R* T_M/M0) with the printed T_M.
- The entry design's points (86, 90, 100, 110, 120, 150, 200, 300, 500 and 1,000 km): density and pressure within 0.5 %, temperature within 0.1 K. Examples: ρ(100 km) = 5.604e-7, ρ(120 km) = 2.222e-8 kg/m³, T(120 km) = 360 K; at entry interface (121.92 km) T = 382.62 K.
- At 86 km: pressure, density and speed of sound continuous within 0.05 %. The temperature steps from T_M (186.946 K) below to the kinetic 186.867 K above.
- Density and pressure fall monotonically to 1,000 km; the temperature profile is continuous at 91, 110 and 120 km.

**Against the old rows.** Vallado's densities were 3 % low just above 86 km, −5.5 % at 100 km, +9.7 % at 120 km and +33 % at 400 km (3.725e-12 against 2.803e-12). `AtmosphereTests.testUpperAtmosphereIsMonotonic` now pins US76's 400 km value.

**Effect on M1.** The full suite is green. In `AscentResidualTests` one printed value moves: the S-II sensed-velocity vector residual from separation, +4.95 to +4.94 m/s. Every other residual and event time is unchanged to the printed digit, including the 698.832 s velocity cutoff.

## 2. Aerodynamics

### 2.1 The trim table (68-FM-184 Table I(a), H)

The coefficients at trim against Mach for a CoM at X 1040.58, Y −0.11, Z 5.91 in (Y read as a typed-in correction by both readers). Their sketch puts C_L towards the CoM-offset (+Z) side and C_D along V_rel. `CapsuleAerodynamics.apollo7TrimTable` holds the 14 rows as printed.

### 2.2 The model

**Supersonic (M ≥ 1.1), sphere centre.** Pressure on the spherical heat shield acts nearly through one point on the axis. The resultant C_R q S lies θ = k α' from +x, tilted against the crossflow, and acts at the axis station x_cp. Each row, at its CoM (x_r on the axis, z_r = 5.911 in off it), gives:
- C_R = hypot(C_L, C_D);
- δ = atan(C_L/C_D), θ_t = α'_t − δ, k = θ_t/α'_t;
- x_cp = x_r + z_r / tan θ_t.

The moment about the actual CoM is r × F. Trim therefore emerges for any CoM, with the lift on its side.

**Subsonic (M < 1.1), anchored linear.** θ_t falls to zero at Mach 0.7 and below it at 0.2-0.4, so x_cp is undefined there. The same resultant and direction act. The moment about the table's CoM is Cm_α,sub (α'_p − α'_t) in the plane of that CoM and the axis, and Cm_α,sub α'_y across it. It is moved to the actual CoM by r × F. Cm_α,sub = −0.1/rad (L, a placeholder until TN D-4688 is read). At Mach 1.1 both models give the same resultant, direction and trim; only the off-trim slope changes (−0.107 to −0.100/rad).

**Large angles, Newtonian blend.** From α' 40° to 60° (smoothstep), the loads blend into a full-range modified-Newtonian model: C_p = C_p,max sin² η on every windward panel, C_p,max = 1.839. The panels are 112 strips × 180 azimuths of the outer mould line (§2.3), tabulated every 2° of α' and scaled to C_R at the blend start.

Not modelled: damping derivatives (the RCS damps rates, as on Apollo), any roll moment (the resultant passes through the axis), and the CM's subsonic dynamic instability.

**Per-row calibration** (`knots`; Cm_α per rad of α' at the row's trim, at the table's CoM):

| Mach | α'_t (°) | k | C_R | x_cp (X_c, in) | Cm_α |
|---|---|---|---|---|---|
| 0.2 | 9.20 | −0.737 | 0.858 | – | −0.100 |
| 0.4 | 12.64 | −0.241 | 0.887 | – | −0.100 |
| 0.7 | 15.32 | 0.037 | 1.021 | (1633.7) | −0.100 |
| 0.9 | 18.00 | 0.083 | 1.114 | (1267.6) | −0.100 |
| 1.1 | 24.71 | 0.088 | 1.272 | 1195.5 | −0.107 |
| 1.2 | 24.51 | 0.095 | 1.253 | 1185.6 | −0.113 |
| 1.35 | 25.64 | 0.086 | 1.399 | 1194.7 | −0.120 |
| 1.65 | 26.44 | 0.121 | 1.382 | 1146.6 | −0.115 |
| 2.0 | 26.50 | 0.152 | 1.384 | 1124.6 | −0.115 |
| 2.4 | 25.98 | 0.154 | 1.346 | 1125.0 | −0.114 |
| 3.0 | 25.50 | 0.168 | 1.314 | 1119.5 | −0.113 |
| 4.0 | 23.56 | 0.162 | 1.297 | 1129.0 | −0.121 |
| 10 | 22.91 | 0.168 | 1.302 | 1128.4 | −0.125 |
| 29.5 | 19.63 | 0.160 | 1.351 | 1148.5 | −0.151 |

Between rows the calibration is linear in Mach; beyond the end rows it is held.

**Two calibrations.**
- `.flightConsistent` (the default and the app's): the rows to Mach 10, with Mach 10 held above it. Above Mach 6-10, trim does not depend on Mach in Apollo 4's flight (TN D-5399: the tunnel trim about 1.5° low and L/D about 10 % high at high Mach) or in DeRose's free flights at Mach 10-29 (TN D-5276). The Mach 29.5 row is the wind-tunnel extrapolation they correct.
- `.operational`: every row as published, for comparison with 68-FM-184's preflight trajectories.

### 2.3 The outer mould line (`apolloOuterMouldLine`)

| Item | Value | Grade |
|---|---|---|
| Heat shield | spherical cap, radius 184.8 in (R/D 1.2), vertex at X_c 1000, to a half-angle of 23.04° (radius 72.31 in at X_c 1014.74) | M |
| Shoulder | torus of 7.7 in section radius (0.05 D), centred 69.3 in off the axis at X_c 1021.82; maximum diameter 154 in | M (diameter H) |
| Afterbody | 33° half-angle cone from the torus (75.76 in at X_c 1026.02) to 16.5 in radius at X_c 1117.26 | M |
| Tunnel and apex | cylinder of 16.5 in radius to X_c 1137 (AS506Data's apex station), closed flat | L |

**Check.** Newtonian theory alone, on this line at the table's CoM, trims at α' 22.12° with L/D 0.332. The tunnel's Mach 10 row is 22.91° and 0.345 (test: within 1° and 0.02). The integrator reproduces the spherical cap's closed form C_A = C_p,max (1 + cos² θ_c)/2 to 1e-4.

### 2.4 Checks against published trim (`CapsuleAerodynamicsTests`)

| Case | Model | Published | Test |
|---|---|---|---|
| Every row of Table I(a), at its CoM, both calibrations (to Mach 10 for flight-consistent) | moment 0, C_L and C_D to 1e-9, lift towards +Z_A | Table I(a) (H) | exact |
| Static stability at every row | Cm_α −0.100 to −0.151/rad | – | −0.3 < Cm_α < −0.05 |
| DeRose z/d 0.046 at x/d 0.270, Mach 10, 18, 29 | 152.25°, L/D 0.426 | 151°, 0.435 (±1°, ±0.025 measured) | ±1.5°, ±0.02 |
| DeRose z/d 0.028 | 163.08°, 0.251 | 162°, 0.255 | ±1.5°, ±0.02 |
| DeRose Δz/d 0.0015 | −0.90° | "about 1°" | 1 ± 0.25° |
| Apollo 4 at entry (Table II: X 1039.58, Z 6.57 in, Mach 25.6) | 154.83°, 0.383 | 154.5°, 0.368 (flight) | ±1°, ±0.02 |
| Apollo 4 at Mach 6 (X 1039.72, Z 6.45 in) | 154.79°, 0.385 | 153°, 0.410 (flight) | ±2°, ±0.03 |
| Newtonian alone (§2.3) | 22.12°, 0.332 | Table I(a) Mach 10: 22.91°, 0.345 | ±1°, ±0.02 |
| Apex forward (full model, Mach 10) | stable trim at α' 167.5° | – (TN D-4688 not read) | a stable trim beyond 120° |

**Known miss: Apollo 4 at Mach 6.** In flight, Apollo 4's trim drifted from 154.5° at entry to 153° at Mach 6. Over the same range, Apollo 7's table (calibrated at Mach 4 and 10) barely moves for Apollo 4's CoM, so the model sits 1.8° and 0.025 in L/D from the flight value there. TN D-5399's own "modified tunnel" data are 153.5° and 0.398 at Mach 6, half way between. Closing the gap would mean calibrating on Apollo 4's flight. That is left for M2's lunar-return entry (TN D-6725's Apollo 11 table), so this test's band is 2° and 0.03.

**Not done** (design report test 4): the prediction of TN D-6725's Apollo 11 trim. Track D did not transcribe TN D-6725 (it is M2's).

**Ambiguity: which centreline.** DeRose notes that flight data agree with his models once the CoM is referred to the heat shield's centreline, not the structural one (AS-202: 4.65 in against 5.23 in). This model calibrates on the 68-FM-184 table and applies it to other CoMs in the same structural axes (Apollo 4, the Mission Reports). The DeRose comparison takes his z/d as offsets from the model's axis. Read the other way, with his offsets about 0.6 in short of structural ones, the DeRose z/d 0.046 case would trim about 2° lower in α with an L/D about 0.04 higher, outside the bands.

## 3. Entry telemetry (`Simulation.updateEntryTelemetry`)

Computed at the end of every step, after the air and altitude telemetry:

| Field | Definition | Grade |
|---|---|---|
| `sensedAcceleration` | aerodynamic, parachute (track E2's `parachuteLoads`) and thrust force over mass, body axes, as an accelerometer at the CoM reads it. On the surface: the support that holds the vessel in the rotating frame, ω×(ω×r) − g | – |
| `loadFactor` | `sensedAcceleration` / g0, g0 = 9.80665 m/s² | – |
| `bankAngle` | for a vessel flying a capsule model: the angle about the air-relative velocity from the local up (the ellipsoid normal) projected across it, to the lift side (the CoM's offset from the axis, `Vessel.liftSide`) projected across it; positive with the lift right of the velocity looking along it. Nil without a capsule, or with the air velocity vertical | – |
| `heatFlux` | Sutton-Graves convective stagnation heating, 1.7415e-4 √(ρ/R_n) V³ W/m², V the air-relative speed (TR R-376, H). R_n = 1.65 m, an effective radius fitted to 68-FM-184's peak and total together (§4.4; the heat shield's own 184.8 in gives 57 % of the peak). Neither 68-FM-184 nor TN D-5399 gives the radius behind its heating. Telemetry only | constant H, R_n L |
| `heatLoad` | `heatFlux` integrated over time, by the trapezoid rule from one update to the next (`Vessel.entryTelemetryEpoch`, track E2's PR 1) | – |

**Checks** (`EntryTests`):
- Bank geometry at Apollo 7's entry interface: 0 lift up, ±180° lift down, +90° lift right, at α' 0 and 0.4 rad, all to 1e-9. A 10° turn about the air velocity reads +10°. Lift up is heads down. Table I(a)'s −0.11 in Y_A puts the lift side 1.07° left.
- Load factor: zero coasting above the air; thrust over mass in a burn (to 1e-9); WGS-84 normal gravity at rest at 28.6° N (9.79217 m/s², within 1e-4); C_D = 1.2307 and C_R q S/m at Mach 18 on the flight-consistent calibration.
- Heat flux at 70 km and 7.9 km/s matches Sutton-Graves on the 1976 density (520.5 kW/m² at 7.5 km/s), and is zero above the air. Over 20 s of flight the heat load is the trapezoid sum of the fluxes.
- Flown uncontrolled through `Simulation` from Apollo 7's entry interface, the CM holds its trim within 2° through peak deceleration. When a lift-down CM has fallen to 40 km, a lift-up one is still above 60 km. This pins the lift side in the full integration.

## 4. Entry flight (track E1's PR 2)

### 4.1 The entry autopilot (`AttitudeAutopilot.entry`, `EntryAutopilot`)

It rolls the CM about its stability axis to fly `Vessel.entryCommand` (`.bank(φ)` or `.rolling(rate:)`), and leaves pitch and yaw to the trim. This is Apollo's coordinated roll about the velocity: the roll rate gyro is coupled into yaw (TN D-5399).

| Item | Value | Source | Grade |
|---|---|---|---|
| Stability axis | the air velocity at trim, body axes: −x turned towards the CoM's side by the trim α' at the current Mach and CoM (`CapsuleAerodynamics.trimAngle`, closed form) | the model; the CMC flew a fixed trim angle | – |
| Bank | from the telemetry, about the true air velocity | §3 | – |
| Bank dead band | ±4° | design report | L |
| Roll rate | up to 20°/s, no faster than it can stop in at half its roll acceleration (M0's approach) | design report (the CMC's) | L |
| Rate dead bands | ±2°/s across the stability axis; about it inside the bank dead band | TN D-5399 (Apollo 4, all three axes) | H |
| Rate loop | M0's 0.5 s loop per body axis, on the rotation groups | – | – |

**Checks** (`EntryTests.testEntryAutopilotRollsAboutTheStabilityAxis`, E2's CM at Mach 22):
- From lift up to 55°, it is inside the dead band in under 5 s (3.9 s), rolling at 18.8°/s at most.
- The rates across the stability axis stay under 3.5°/s (3.04°/s at most: the dead band, the loop's lag and the CM's products of inertia), and α' within 1° of trim.
- It then holds 55° ± 5° in a ±2°/s limit cycle. `.rolling` flies its rate within 1.5°/s.

### 4.2 The entry program (`CMEntryProgram`)

| Phase | When | What it does |
|---|---|---|
| dormant | an "SM" part is aboard | nothing; the pilot's Space key stages as usual |
| pre-entry | from the first step without the SM | turns on the CM RCS (once: E2's ELS turns it off under the mains), arms the ELS, removes the reference body's launch-day sounding (`Simulation.atmospheres`, owner decision 13), and holds the trim attitude about the air velocity at the mode's bank (`.attitudeHold`; lift up for manual and rolling) on `holdLaw` |
| entry | sensed load factor ≥ 0.05 g (the EMS light; logged "0.05 g") | the entry autopilot flies the mode: `.bankHold(φ)`, `.rolling(rate)`, or `.manual` (`pilotRoll` −1…1 rolls at up to 20°/s; let go, it holds the bank) |
| drogues | E2's ELS has deployed them | rate damping (`.killRotation`) |
| mains, landed | E2's ELS (RCS off) | lets go |

- **`holdLaw`**, the pre-entry hold's law on the CM RCS (L): a phase plane with a 2° dead band (half the bank dead band), turning at 2°/s at most on a 2.5 s switching line, with 14 ms pulses. The turn and the pulse are the CSM's (`ApolloCSM.phasePlaneLaw`).
  - It replaces the CSM's law the CM inherits at CM/SM separation.
  - The CM's pitch and yaw jets fire alone, so a proportional law's steady trickle of thrust would also push it off its trajectory. On Apollo 7's coast to entry interface that trickle cost about 4 m/s and 5 s of entry time.
- The ELS (E2's `EarthLandingSystem`, on baroswitch pressure) runs inside the program from pre-entry on. `advanceELS` is the crew's Space-key backup, for track I to wire: awake, the program refuses manual staging.
- Status line, for example: "ENTRY bank 55°L 3.3 g | ELS drogues reefed 1 | 29.6N 65.7W".

**Checks** (`EntryTests`):
- `testEntryProgramWakesWhenTheServiceModuleLeaves`: dormant with an SM aboard (sounding kept, RCS off, Space allowed). After event 7 it wakes: sounding dropped, CM RCS on, ELS armed, hold on. From the retrograde, heads-down separation attitude it is at trim lift up within 60 s (inside the 2° dead band on each axis, bank within 4°). Manual mode rolls and holds.
- `testPointZeroFiveGAndThePredictor`: from Apollo 7's entry interface as flown (25,846.4 ft/s at −2.072°, Mission Report §5.16, H; position and azimuth from Table IX(b)), lift up. The model senses 0.05 g at 127 s and 0.2 g at 160 s after EI. The flight's computer changed programs at 132 s (post-0.05 g) and 160 s (0.2 g, final phase). The test band is ±6 s.

### 4.3 The landing-point predictor (`LandingPointPredictor`, display only)

- A point mass with the capsule's trim drag and lift at the current CoM and mass, at a constant bank (none for rolling).
- 1 s RK4 steps, the reference body's standard atmosphere rotating with it, central gravity with J2.
- It ends at the drogues' 24,000 ft. Run every 2 s before the drogues; `CMEntryProgram.prediction`.
- **Displays:** B2's ENTRY and MAP pages show it through `LandingPointPredicting`. The conformances of `CMEntryProgram` and `ApolloSCS` (which forwards its successor's) are in OrbitInstruments/EntryProgramHooks.swift, with no app change. The ENTRY page's ELS line now reads the program's landing system (`ApolloMission.landingSystem`).
- **Check:** from Table IX(b)'s EI at a constant 55°, it converges on where the 6-DOF flight passes 24,000 ft: 57 km away at EI, 28 km 300 s later, 0.7 km 450 s later (Mach 11). The tests allow 100, 50 and 5 km. The 6-DOF bank wanders in its 4° dead band, which the prediction cannot know.

### 4.4 Apollo 7 from the planned entry interface (`Apollo7EntryTests.testFromThePlannedEntryInterface`)

Setup:
- E2's Apollo 7 CM, with the operational calibration (MSC's tables, as 68-FM-184 flew them).
- Table IX(b)'s entry interface: 31.03° N, 98.83° W, 400,000 ft, 25,850.3 ft/s at −1.759° and 83.64° (geocentric horizontal, geodetic position).
- 55° bank, starting with a left roll. §5.4.4 places the target on the 55° bank contour "if L/D is between 0.42 and 0.26". The crew reverses the bank whenever the CM is more than 10 n mi off the ground track from its 0.05 g point to the target. Held to one side, 55° carries it about 95 n mi across.

| Quantity | Model | 68-FM-184 / Mission Report | Test |
|---|---|---|---|
| Peak load factor | 3.39 g | 3.3 g (§5.4.4) | ±0.3 g |
| Landing | 29.33° N, 65.54° W: 81.4 n mi beyond the target | 29.8° N, 67.0° W (§5.4.3) | 90 n mi |
| EI to splashdown | 998 s | 963 s (landing 10:20:09:53, cutoff 10:19:40:04 + 826 s) | ±40 s |
| On the drogues / mains | 53.0 s / 271.2 s | 53 s / 285 s (§5.4.4) | ±5 s / ±20 s |
| Peak heating / heat load | 57.7 BTU/ft²·s / 13,188 BTU/ft² | 59.8 / 12,649 (§5.4.4) | ±10 % (R_n fitted to both) |
| CM RCS propellant | 39.4 lb | Apollo 7 flew 49.1 lb (Mission Report §5.21) | within a factor of 2 |

**Accepted deviation (Franz, 2026-10-20).** The landing bands stay at 90 n mi from the planned entry interface and 60 n mi against the flight. The model's constant-55° backup lands 50-80 n mi long, and that is accepted as a known deviation, with no tuning to close it. Revisit it when closed-loop entry guidance arrives: constant-g in M2, the CMC's predictor-corrector in M3.

**The landing miss.** The constant-bank range is very sensitive to the entry flight-path angle: about 700 n mi per degree. The same flight entering at −1.80° lands 36 n mi from the target, and at −1.85° 7 n mi. The 70-80 n mi corresponds to 0.1° of γ, or about 0.03 of vertical L/D (15 % of it at 55°). That is the size of the conventions between 68-FM-184's trajectory program and this one:
- Fischer 1960 against WGS-84;
- a geodetic or geocentric horizontal for γ (0.02° here);
- the 1962 against the 1976 atmosphere;
- E2's Mission Report CoM (Z 6.0 in) against the table's 5.91 in (9 n mi).

How the backup is flown moves it by about 10 n mi:
- the pre-entry hold's law: 69.6 n mi with M0's law, 75.0 with `holdLaw`;
- where the crew's reversal line starts: 75.0 from entry interface, 81.4 from 0.05 g.

The flight-consistent calibration (L/D about 10 % higher at hypersonic speed) lands about 120 n mi beyond.

### 4.5 Apollo 7 as flown, from the deorbit burn (`Apollo7EntryTests.testFromTheDeorbitBurn`)

Steps:
- Track C's CSM before SPS-8 (`apollo7BeforeDeorbit`, on Mission Report Table 3-III's ignition state), flown through the crew's steps of Table 2-I: U for 15 s from 259:39:01.3, Z at 259:39:16.3, the EMS counter's cutoff, CM/SM separation at 259:43:33.8.
- CM/SM separation wakes the CM's entry program through the SCS (`ApolloMission`, §4.6).
- 55° from 0.05 g, with reversals about the line to where Apollo 7 came down.

| Quantity | Model | Mission Report | Test |
|---|---|---|---|
| Entry interface | 259:53:31.9 GET | 259:53:27 (Table 2-I) | ±6 s |
| Peak load factor | 3.38 g | the computer-flown entry; 68-FM-184 planned 3.3 g | ±0.3 g |
| Landing | 27.24° N, 63.30° W: 51.5 n mi beyond | 27.64° N, 64.15° W reconstructed (§5.16; the recovery forces' estimate 27.54° N, 64.07° W) | 60 n mi |
| EI to splashdown | 950 s | 936 s (260:09:03, Table 2-I) | ±40 s |
| On the drogues / mains | 53.0 s / 271.3 s | 53 s / 285 s planned | ±5 s / ±20 s |
| Heating | 64.5 BTU/ft²·s, 12,653 BTU/ft² | – (steeper than planned: −2.07° against −1.76°) | – |
| CM RCS propellant | 42.7 lb | 49.1 lb (§5.21) | within a factor of 2 |

**The landing.**
- **Against the flight:** the flight's computer flew lift up to 0.2 g, then its own guidance to the target. A constant-55° backup from the same entry interface lands 51.5 n mi beyond, the same way as from the planned entry interface: this model's 55° flies a little further than MSC's.
- **Against the plan:** the preflight 29.8° N, 67.0° W is about 250 n mi away. The flight entered steeper than 68-FM-184 planned (−2.072° against −1.759°, its ignition 37 s early), and its target had moved east.
- **So:** "within about 30 n mi of 29.8° N 67.0° W" can only be tested from the planned entry interface (§4.4).

### 4.6 The mission wiring (`Guidance/ApolloMission.swift`)

- `ApolloMission.spacecraftControl(separationUllage:entryMode:)` builds the CSM's SCS (track C's `ApolloSCS`) with a `CMEntryProgram` (lift up by default) as its `successor`. Track C's two SCSs use it: the Saturn V's standby one and `apolloCSM`'s.
- `entryProgram(of:)` finds the entry program flying a vessel, its own or through the SCS; `landingSystem(of:)` finds its ELS.
- `ApolloSCS` now also forwards its successor's status line once the SM has gone. Before, the HUD kept showing the SCS's last line.
- E2's standalone `commandModule(_:)` now carries `AerodynamicModel.apolloCommandModule()`. E2's ParachuteTests and SplashdownTests are unchanged and pass, including the 32/36 ft/s descent rates.

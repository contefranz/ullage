# M1.6/M2 design: Apollo 8 flight scope

> Planning document for the M1.5 close-out, milestone M1.6 (graphics overhaul) and M2 (Apollo 8), written on 2026-10-20 by a design study (six design reports checked by a planner) and accepted by Franz on 2026-10-21 with all recommended defaults (US keyboard). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

**main at 6a1851b: 365 test functions, 48 core test files.** Nothing past the parking orbit exists. Each gap is listed below with where it is in the code.

**IU (S-IVB restart and TLI)**
- The IU has five time bases only: `SaturnIU.TimeBase` is `case t1 = 1, t2, t3, t4, t5` (Sources/OrbitCore/Guidance/SaturnIU.swift:88-89).
- `detectTimeBases` (SaturnIU.swift:574-619) ends at T5, the S-IVB first cutoff.
- AS-506's program stops at the TB5 APS ullage and local-horizontal events (Guidance/AS506FlightProgram.swift:54-56; Vessel/AS506Data.swift:291-297).
- The datasheet marks TLI, TB6/TB7, the S-IVB second burn, the LOX dump and orbital venting as M2:
  - docs/AS506-datasheet.md:264 (TLI is 346.83 s, at EMR 4.5 then 5.0);
  - :283 (the S-IVB after TLI is 3,430 kg heavy because venting and the LOX dump are not modelled);
  - :848-850 (APS rows for TB6, TLI and post-TLI);
  - :1449 ("GE504's out-of-orbit path").
- `IterativeGuidance` (Guidance/IterativeGuidance.swift) implements GE504's into-orbit IGM, stages 1 to 3, with fixed terminal radius, γ, inclination and node presettings. It has no out-of-orbit precalculation.

**Gravity**
- `CelestialBody.gravity(at:pole:)` is point mass plus J2 only (Bodies/CelestialBody.swift:67-76).
- The Moon has J2 = 2.0330e-4 and its DE421 libration in the ME frame (Bodies/SolarSystem.swift:49-50).
- The perturbers are the Sun, Earth, Moon, Venus and Jupiter (:62), applied direct minus indirect in `SolarSystem.acceleration` (:96-111).
- `CelestialBody.swift:117-123` has `MoonFrames.paToME`, so the DE421 principal-axis (PA) frame is one transpose away.
- Callers of `gravity(at:pole:)`: SolarSystem:102, SaturnIU:523/850/871, LandingPointPredictor:55, EntryInterface:23, AppModel:392.

**Integration and time warp**
- The integrator is RK4. `StepControl.maxStep(for:)` (Simulation/StepControl.swift:33-95) caps a step at 60 s and T/1000 (`orbital`, :45), and at 0.02 s while thrusting.
- Passive debris gets relaxed steps.
- `checkReferenceBody` already switches the reference body on SOI crossing (Simulation/Simulation.swift:326-335; the Moon's SOI is 66,100 km).
- Warp steps go to 100,000× (Sources/OrbitSim/AppModel.swift:82).

**CSM**
- `ApolloCM.Mission` is only `.apollo7` and `.apollo11` (Vessel/CommandModule.swift:20-23).
- The SPS has two lumped tanks, "SPS oxidizer" and "SPS fuel", with storage and sump merged into one settled column (Vessel/ApolloCSM.swift:166-191). The M1.5 plan deferred the series feed to M2 (docs/m15/plan.md:61).
- The SPS is rated to 68-FM-184 (21,080 lbf, 312.34 s).
- `ApolloSCS` has the EMS ΔV counter, the trim through the CG and the phase-plane law. "Automatic P40 is M3's" (Guidance/ApolloSCS.swift:27).
- The SLA panels already jettison as on Apollo 11. Apollo 8's SLA was the first with a panel-jettison mechanism (Mission Report §2), so that model fits.

**Entry**
- `CMEntryProgram` modes are manual, bank hold and rolling, plus a display-only predictor. The header says "Constant-g guidance is M2's, the CMC's predictor-corrector M3's" (Guidance/CMEntryProgram.swift:22-35).
- The M1.5 accepted deviation (the 55° backup lands 50-80 n mi long) is waiting for closed-loop guidance (docs/ROADMAP.md:122-129; docs/CM-entry-datasheet.md:202).
- Apollo 7's CMC actually flew its own guidance (CM-entry-datasheet.md:234). A CMC-level guidance would therefore also retire that deviation.

**Navigation and MFDs**
- Navigation/ has Kepler (universal variables, hyperbolic included), GroundTrack, DeorbitPlanner and EntryInterface, all Earth-orbit tools.
- `ApolloCSM.coast` (ApolloCSM.swift:69-91) is RK4 with steps of 1 s or less: far too slow for 3-day predictions.
- MFD modes are orbit, surface, map, deorbit and entry (Sources/OrbitInstruments/MFDMode.swift:6). MAP draws Earth coastlines (Modes/MapMFD.swift:4-6).
- The M1.5 MFD study already earmarked TRANSFER/TLI ("numerical trajectory, patched conics are poor"), ALIGN, SYNC and DOCKING for M2 (docs/m15/design-orbiter-mfds.md:104-109).

**Vehicle**
- `VesselLibrary.saturnV()` is AS-506 with an LM and Apollo 11's day, azimuth 72.058°.
- No AS-503 data, no LTA-B and no 21 Dec 1968 atmosphere exist.

**Tests and roadmap**
- Pattern to copy:
  - Apollo7DeorbitTests and Apollo7EntryTests start from a published state and fly one leg.
  - NominalFlight.swift shares one expensive flight (`static let shared`) across tests.
- The full `swift test` takes about 15-18 min.
- docs/ROADMAP.md:142-149 (M2) mixes TLI, docking and extraction, the LM, DOI, LOLA terrain, landing gear, constant-g entry and the lunar MFDs.

## Design

**Milestone shape.** M2 becomes "Apollo 8: the Saturn V and the CSM to lunar orbit and back".
- It covers this work plus the graphics overhaul, which other areas cover on disjoint renderer files.
- A new M2.5, "The Lunar Module (Apollo 9-11)", takes the LM items. M3 is untouched (CLAUDE.md refers to it).

**M2's definition of done (flight side)**
1. Apollo 8 is flown from LC-39A with only the HUD, navball and MFDs:
   - the IU flies to the parking orbit, starts TB6 on its restart-preparation test and flies TLI;
   - Space separates the CSM: the panels jettison, and the LTA-B stays on the S-IVB;
   - the S-IVB's slingshot (LOX dump, APS burns) takes it past the Moon's trailing edge into solar orbit;
   - the TRANSFER MFD plans MCC-1, LOI-1, LOI-2 and TEI, whose SET loads the EMS counter and manoeuvre marker;
   - ten lunar orbits are flown, with LOS/AOS on the lunar MAP, then MCC-5 and CM/SM separation;
   - the CMC's entry guidance (P63-P67) lands the CM within a few n mi of 8.133° N 165.033° W.
2. The Apollo 8 reference chain runs in `swift test` (see verification).
3. No regressions: the §17 residuals are unchanged to the bit (Earth gravity stays J2), and the Apollo 7 tests are green.

### S8: seams (lands first; no behaviour change)
- `CelestialBody` gets `var field: GravityField?` and a new `gravity(at r: Vec3, orientation: BodyOrientation) -> Vec3`.
  - It uses the field when one is set, and the existing J2 path otherwise.
  - `SolarSystem.acceleration` switches to it. Earth results stay bit-identical.
- `SaturnIU.TimeBase` gets `t6 = 6, t7`, and `Plan` gets an optional `restart: RestartPlan?` (empty).
- `ApolloCM.Mission.apollo8` exists, with placeholder rows.
- `MFDModeID.transfer` is added (key X, label TRN; stub page).
- An empty `Navigation/ApolloFrames.swift` declares:
  - the Apollo-era frames: ECI and MCI mean of the nearest Besselian year (B1969.0), turned to ICRF with the existing IAU 2006 precession and frame bias;
  - the Fischer 1960 altitude offset.
- Naming contract additions:
  - parts: "LTA-B" (in place of "LM" on AS-503);
  - thrusters: "S-IVB LOX dump", "S-IVB LH2 vent";
  - IU log names: "TB6 restart preparation", "S-IVB reignition", "TB7 S-IVB cutoff", "TLI inhibit";
  - staging events: 6 is still CSM/S-IVB separation.

### D8: Apollo 8 data (Mac, downloads into the scratchpad only)
- Transcribe with two readers from page images, as M1.5's D did, into tools/data/*.csv. Each file carries its source, page and H/M/L grade, with a log in docs/data/apollo8/.
- Priority order:
  1. Apollo 8 Mission Report (MSC-PA-R-69-1), whose text layer is usable. Tables:
     - 3-I (events);
     - 5-II (states at every burn: lat, lon, alt, V, γ, heading; Earth and Moon reference);
     - 5-III (pericynthion after each manoeuvre);
     - 5-IV and 5-V (entry);
     - 6.11-I (SPS at LOI: 20,498 lbf, 313.0 s, MR 1.59);
     - A.6-I (mass, CG and inertia from lift-off to landing, 20 rows);
     - §5.5-5.10 and §6.9 (entry guidance phase transitions);
     - §6.11.2 (SPS loads 25,105.1 lb oxidizer and 15,730.9 lb fuel).
  2. MR Supplement 1 (trajectory reconstruction):
     - App. A BET Cartesian vectors (ECI and MCI, mean of B1969.0, in ft and ft/s); the OCR is garbled, so read the page images;
     - the entry initial vector at 146:45:52.10;
     - Table 3.2-3 (the triaxial and R2 lunar fields);
     - §3.2.2 (the rev 4 to rev 5 propagation errors with R2).
  3. AS-503 postflight trajectory (Boeing D5-15794):
     - Table 3-I (TB6 at 9,659.54 s; second guidance cutoff at 10,555.51 s);
     - Table 3-V (TLI: 346.73 km, 10,822.05 m/s, γ 7.897°, i 30.636°, DN 38.983°, e 0.97553, C3 −1,478,917 m²/s²);
     - Table 3-VI (targeting parameters, rotated and garbled: page image);
     - Table 4-II (orbital venting acceleration polynomials, 712-9,642 s);
     - Table 4-III (insertion: 694.98 s, 191.36 km, 7,792.84 m/s, i 32.509°);
     - Tables 6-I to 6-III (slingshot 41.9 m/s = LH2 vent 2.1 + LOX dump 20.4 + APS 19.4, the APS burning 758.2 s and 732.5 s; closest approach 1,262 km at 69.982 h; heliocentric a 1.4284e8 km);
     - Tables B-V to B-VII (second-burn trajectory);
     - the flight azimuth, 72.124°.
  4. AS-503 FER (MPR-SAT-FE-69-1): Tables 2-1 and 2-2 (T1-T7 events), S-IVB burn 2 and restart (O2H2 burner, repressurisation, chilldown, APS ullage), mass tables, and App. A (the launch-day sounding).
  5. GE504 §3.1.2-3.1.4 and §4.1.10:
     - Fig. 4-14 (restart preparation and opportunity logic) and Fig. 4-15 (out-of-orbit IGM precalculations);
     - Table 4-VI;
     - the TB6a/TB6b/TB6c alternates (O2H2 burner malfunction windows TB6+91.7-235 s and 235-346.6 s; TLI inhibit).
  6. R-577 GSOP §5 Rev 4 (Colossus I rev 237 is Apollo 8's program): §5.6 entry guidance, its constants and reference table.
  7. MR Supplement 2: Table 4-2 (VG residuals) and the SPS CG tracking.
  8. TN D-6725: the constant-g backup and the Apollo 11 trim table.
  9. FER-506 Table 2-2 TB6/TB7 rows (Apollo 11's TLI as a second check).
- The GRGM900C file (~50 MB) is downloaded once; only the truncated binary enters the repo, with a sha256 in the README.

### V: AS-503 vehicle at event-level fidelity (Linux)
- `Vessel/AS503Data.swift` gives AS-503 as deltas over `AS506`:
  - stage masses and loads from the FER-503 mass tables, and the F-1 and J-2 ratings;
  - S-IVB residuals, the LOX available for the dump, the IU;
  - "LTA-B" (about 19,900 lb, which fits A.6-I's 87,377 − 63,524 lb less the SLA) at the LM's stations;
  - the 21 Dec 1968 12:51:00 UTC range zero (first motion 0.33 s), azimuth 72.124°;
  - the launch-day atmosphere from FER-503 App. A, built like §11.3.
- `Guidance/AS503FlightProgram.swift`: `SaturnIU.as503()` with FER-503 Table 2-2's T1-T5 sequence and its into-orbit IGM presettings.
- `VesselLibrary.apollo8OnPad(in:)` and `apollo8InParkingOrbit(in:)` (at PFT-503 Table 4-III).
- Do not re-close the residuals as §17 did for AS-506. Test events and insertion against the FER and PFT with documented bands.

### T: IU restart, TLI, TB7 and the slingshot (Linux; owns SaturnIU.swift and IterativeGuidance.swift)
- **`Guidance/OutOfOrbitTargeting.swift`** follows GE504 Table 4-VI:
  - targeting from (C3, e, i, θN, α_D, f) or a seven-parameter update (T_RP, C3, i, θN, e, α_D, f);
  - the target plane, and the restart-preparation test that starts TB6 (ZT test, first or second opportunity);
  - each cycle, the terminal R_T, V_T and γ_T from the target ellipse at the predicted cutoff anomaly.
- **IterativeGuidance gains an out-of-orbit mode.** It runs stages 4 and 5 with the S-IVB's MRS (EMR 4.5 then 5.0) and terminal conditions supplied by the targeting each cycle. It reuses χ̃, the K terms, terminal guidance and the high-speed cutoff on V_T − ΔV_B. The T bound and NaN guard from §10.2 are kept.
- **`Guidance/SIVBRestart.swift`** is the TB6 sequence state, timed from FER-503 Table 2-2:
  - O2H2 burner on and off, LH2 and LOX repressurisation (first-order ullage-pressure states toward the FER's values), recirculation chilldown;
  - start-tank charged from burn 1, APS ullage on and off, J-2 start command (ignition at about TB6+577.6 s);
  - restart conditions checked (settled, NPSP, chilldown, start tank, no inhibit), with the TB6a/TB6b ambient-repress alternates;
  - TB6c "TLI inhibit" from a crew switch (an app key; it also serves Apollo 11's existing TLI no-go scenario).
- **TB7** starts at the TLI velocity cutoff:
  - blowdown venting, the turn to the separation attitude, inertial hold;
  - after CSM separation, the slingshot on FER-503's times: the LH2 vent, the LOX dump through the J-2 (a cold-flow "S-IVB LOX dump" thruster whose flow and exhaust speed are fitted to 20.4 m/s on the FER's residual LOX), and the two APS ullage burns at their FER durations, in the FER's slingshot attitude.
- **Parking-orbit venting.** The PFT-503 Table 4-II polynomials become an "S-IVB LH2 vent" force schedule in the IU's space-fixed frame (PACSS 12 is the platform frame the IU already fixes).
- **AS-506 TLI** comes from FER-506 Table 2-2 and the PFT-506 targeting, for a second chain and an "Apollo 11 pad to TLI" scenario.

### G: lunar gravity (Linux)
- `Bodies/GravityField.swift` declares the protocol: `acceleration(bodyFixed:)`, `gm`, `referenceRadius`, `maxDegree`, `degree(forRadius:)`.
- `Bodies/SphericalHarmonicField.swift` is the evaluator:
  - fully normalised C̄nm/S̄nm and Holmes-Featherstone's modified forward-column recursion, which is stable to high degree;
  - the gradient in spherical coordinates, then turned to Cartesian;
  - pure Swift, with no simd.
- **Data.** GRGM900C (GSFC, DE421 principal-axis frame, R = 1738.0 km, GM = 4902.79996708864 km³/s²) is truncated by `tools/make_moon_gravity.py` to degree 100, written as `Resources/moongrav.bin` (about 82 KB).
- **Frame.** The field is evaluated in PA = `MoonFrames.paToME`ᵀ · icrfToBody. The file's frame is DE421 PA, which matches the bundled libration exactly.
- **Adaptive degree** stops the term (R/r)^n·Kaula below 1e-9 m/s²: degree 60 at 110 km, about 20 at 1,000 km, J2-only beyond about 10,000 km.
- The reference acceleration CSV comes from an independent numpy evaluation in the tool.

### N: cislunar navigation and RTCC-style planners (Linux)
- **`Navigation/CislunarPropagator.swift`:**
  - adaptive DOP853 or RKF7(8), point masses for the Earth (J2), Moon (field at an adaptive degree) and Sun;
  - reads `ChebyshevEphemeris` directly for those three bodies, not a full `SystemSnapshot`;
  - root-finds events: apsides about either body, SOI crossings, the 400,000 ft EI altitude, LOS/AOS.
- **`Navigation/ManeuverTargeting.swift`:** a differential corrector (Newton with finite differences, Broyden updates, step limiting). Targets:
  - pericynthion altitude and time, or B-plane B·R/B·T (the robust choice);
  - lunar-orbit inclination;
  - the free-return EI γ;
  - EI γ with EI time or landing longitude;
  - return inclination of 40° or less.
- **`Navigation/FiniteBurn.swift`:** impulsive to finite burn. Thrust is held inertially along the impulsive ΔV, as P40's External ΔV effectively does, and TIG and direction are iterated against the integrated burn.
- **Planners:**
  - `LunarOrbitPlanner`: LOI-1 to 60 × 170 n mi with apsis placement, and LOI-2 circularisation;
  - `TransearthPlanner`: TEI at the end of rev 10 to EI γ −6.50° and the target landing longitude, then MCC-5;
  - `LunarVisibility`: LOS/AOS of the Earth's centre behind the limb.
- All of them return a `ManeuverPlan`: TIG, ΔV in LVLH, burn time, attitude, and predictions (pericynthion, lunar orbit, EI and landing).

### C8: CSM-103 for a lunar mission (Linux)
- **Mission data.** `.apollo8` in ApolloCSMData and CommandModule: the A.6-I rows, the SPS loads, the RCS loads, and the SPS rated as flown (20,498 lbf vacuum, 313.0 s, MR 1.59) with 68-FM-184's 21,080 lbf, 312.34 s kept for Apollo 7.
- **SPS series feed.** Four tanks (oxidizer storage, oxidizer sump, fuel storage, fuel sump). Storage transfers into the sump, which stays full until storage is empty; the lines empty last. This needs a feed-chain option in Components.swift's `Thruster.feed`.
- **`ApolloSCS` additions:**
  - burn-attitude hold from a `ManeuverPlan` (External ΔV, inertial);
  - a storage-empty ullage hint (Apollo 8 ran 15 s of +X before TEI);
  - a PTC mode: roll at 0.1-0.3°/s with pitch and yaw held in a wide dead band.
- Pilot ignition with Z and the EMS counter cutoff stay, as in M1.5.

### E8: lunar-return entry (Linux)
- **Decision: implement the CMC's entry guidance as equations, not emulation.** Constant-g alone cannot target Apollo 8's 1,373.9 n mi of inertial range, so it is kept as the backup.
- **`Guidance/CMCEntryGuidance.swift`** follows R-577 §5.6 for Colossus I:
  - P63: initialisation, desired range, cross-range;
  - P64: initial roll, then HUNTEST, which predicts the up-control exit and flies constant drag when the energy is too high (what Apollo 8 did);
  - P65: up-control; P66: Kepler (ballistic) phase;
  - P67: the final phase on the prestored reference table, with the F1-F3 gains;
  - lateral logic with roll reversals, the roll-command limits, termination below 1,000 ft/s.
- `Vessel/CMCEntryData.swift` holds the constants and the reference table, with page refs.
- **`CMEntryProgram` modes:**
  - `.cmc(target)` is the default when a scenario gives a target;
  - `.constantG(4.0)` is the EMS backup from TN D-6725;
  - key 9 cycles CMC, constant-g, manual, bank hold, rolling.
- **Physics checks:**
  - check `CapsuleAerodynamics` above Mach 30 against TN D-6725 Table I and Apollo 4;
  - add a Tauber-Sutton radiative term to the heating telemetry (graphics reads `heatFlux`).

### M8: MFDs and HUD (Mac, core in OrbitInstruments)
- **TRANSFER (X):**
  - pages TLI (the IU's targets, TB6 countdown, predicted cutoff and pericynthion, free-return EI γ), MCC, LOI and TEI, each with SET;
  - an Earth-Moon rotating-frame plot.
- **MAP follows the reference body.** For the Moon: grid, terminator, the sub-Earth point, LOS/AOS shading, the track flown and predicted (with the propagator), and landmarks from the USGS Gazetteer plus the Apollo 8 landmark document.
- **ORBIT:** an SOI flag.
- **ENTRY:**
  - the lunar-return g-V scroll to 37,000 ft/s;
  - the CMC phase (P63-P67), roll commanded and actual, desired versus predicted range, RTGO.
- **HUD strip:** TB6, TIG, LOS/AOS, EI.
- **Threading.** Planners run on a background queue in MFDModel, never on the render thread. Results are cached and recomputed on demand (CALC) or every 10 s.

### R: reference chain, scenarios, integration (Mac)
- Apollo8ChainTests with shared fixtures.
- Scenarios:
  - Apollo 8 pad to splashdown;
  - Apollo 8 in parking orbit;
  - Apollo 8 before LOI-1 (from the MCC-2 cutoff BET);
  - Apollo 8 in lunar orbit before TEI;
  - Apollo 8 CM at EI;
  - Apollo 11 pad to TLI.
- New keys: TLI inhibit and PTC.
- Docs: docs/Apollo8-datasheet.md, README, ROADMAP, CLAUDE.md.

### ROADMAP rewrite
- **M2, Apollo 8:**
  - AS-503 with LTA-B and its launch day;
  - S-IVB restart and TLI (T6, T7, TLI inhibit), orbital venting;
  - CSM separation with the LTA-B, the slingshot to solar orbit;
  - cislunar coast with MCC planning and PTC;
  - the GRGM900C lunar field;
  - LOI-1/LOI-2 with the SPS series feed, ten orbits with LOS/AOS, TEI;
  - lunar-return entry (CMC P63-P67, constant-g backup);
  - TRANSFER, lunar MAP and ORBIT, lunar-return ENTRY;
  - the graphics overhaul;
  - scenarios.
- **M2.5, the LM:**
  - transposition, docking and extraction (docking ports; Apollo 9 in Earth orbit);
  - LM descent and ascent stages;
  - DOI/PDI, rendezvous (ALIGN, SYNC, DOCKING MFDs);
  - LOLA terrain with the quadtree LOD, landing sites in MOON_ME, touchdown and landing gear;
  - Apollo 10 and Apollo 11.
- The M2 line "Lunar-return entry (constant-g guidance)" becomes "CMC entry guidance (P63-P67), constant-g backup".

## Phasing

**Order and dependencies**
1. **S8** lands first (1.25 d).
2. **D8** runs alongside S8 and touches no code. It delivers the PFT-503 tables by about day 2, then the MR and Supplement 1 vectors, then FER-503.
3. **After S8, in parallel:**
   - **G** (cloud, 3 d);
   - **V** (cloud, 4.5 d; needs D8's FER-503 masses by about day 3);
   - **C8** (cloud, 3.5 d; uses only the MR, whose text layer is good);
   - **E8** (cloud, 7 d; needs D8's R-577 constants by about day 3; starts on the structure and the constant-g backup);
   - **N** (cloud, 6 d). Its dependency on G is soft: it starts with the Moon's J2 and switches to the field when G merges.
4. **T** (cloud, 6.5 d) starts right after S8 on AS-506's TLI, whose FER-506 data are already in hand. It moves to AS-503 when the PFT-503 targeting (Table 3-VI) arrives. It owns SaturnIU.swift and IterativeGuidance.swift. V's AS-503 program goes in its own AS503FlightProgram.swift and uses T's `RestartPlan` after T's first PR.
5. **M8** (Mac, 5.5 d) starts with MAP for the Moon and the ENTRY extension. TRANSFER follows once N's `ManeuverPlan` API has merged (about day 7).
6. **R** (Mac, 4 d) comes last: the chain tests, scenarios, harness flights and docs.

**Merge order:** S8, then G, C8 and V, then N's API PR and T's AS-506 TLI, then E8's guidance PR, then N's planners, T's AS-503 TLI and slingshot, then M8, then R.

**Critical path: about 14-15 calendar days with 4 Mac + 4 cloud sessions** (S8 1.25 → N 6 → M8 TRANSFER 2.5 → R 4; E8 and T finish within it). The graphics overhaul runs in parallel on Rendering/* and does not touch these files.

**File ownership is disjoint**
- T: SaturnIU, IterativeGuidance, OutOfOrbitTargeting, SIVBRestart, AS506FlightProgram, AS506Data (TB6/7 rows).
- V: AS503Data, AS503FlightProgram, SaturnV.swift (variant).
- C8: ApolloCSM, ApolloCSMData, CommandModule, Components (feed chain), ApolloSCS, StepControl (optional vacuum step).
- E8: CMEntryProgram, CMCEntryGuidance, CMCEntryData, EntryAutopilot, EntryTelemetry, ApolloMission, CapsuleAerodynamics.
- G: GravityField, SphericalHarmonicField, CelestialBody, SolarSystem (after S8), Package.swift's resource line.
- N: Navigation/*.
- M8: OrbitInstruments/*, OrbitSim/MFD/*, HUD strip files (InstrumentModel, InstrumentCluster). Coordinate with the graphics sessions if they restyle the HUD.
- R: Scenarios, AppModel, Views, docs.

Rules as in M1.5: test the combined branch before each merge; plain `gh pr merge` without --delete-branch.

**If time runs short, cut in this order**
| Cut | Saves (days) |
|---|---|
| PTC mode | 0.5 |
| Radiative heating | 0.5 |
| AS-506 TLI second chain | 1 |
| LOX dump and APS slingshot (the S-IVB just coasts) | 1 |
| Lunar MAP landmarks | 0.5 |
| CMC lateral logic: fixed roll reversals at a cross-range threshold | 1 |
| AS-503 ascent (start Apollo 8 in parking orbit) | 4 |

None of these breaks the TLI-LOI-TEI-entry chain.

## Data and sources

- Apollo 8 Mission Report MSC-PA-R-69-1 (Feb 1969): https://apollojournals.org/afj/ap08fj/pdf/a08-missionreport.pdf (also https://www.nasa.gov/wp-content/uploads/static/history/afj/ap08fj/pdf/a08-missionreport.pdf). Usable text layer: Tables 3-I, 5-II, 5-III, 5-IV, 5-V, 6.11-I, A.6-I; §5.5-5.10; §6.9 (P63/P64/P67: 1,373.9 n mi desired, P64 at 32,598.8 ft/s, P67 at 24,900.8 ft/s, 6.84 g and 3.92 g peaks, 183,000 ft minimum altitude, landing 0.5-2.2 n mi from target); §6.11 (SPS 20,498 lbf, 313.0 s, MR 1.59; loads 25,105.1 lb oxidizer and 15,730.9 lb fuel)
- Apollo 8 MR Supplement 1, Trajectory Reconstruction and Postflight Analysis (Nov 1969): https://www.ibiblio.org/apollo/Documents/19740072902.pdf. App. A BET/RTCC vectors in ECI and MCI mean of B1969.0; the entry initial vector at 146:45:52.10 GET; Table 3.2-3 (R2: J2 2.07108e-4, J3 −2.1e-5, C22 2.0716e-5, C31 3.4e-5); §3.2.2 (rev 4 to rev 5 errors with R2: 9,468-11,751 ft downrange); DE19; ET−UT 38.5 s
- Apollo 8 MR Supplement 2, GN&C: https://www.ibiblio.org/apollo/Documents/19740072935.pdf (Table 4-2 VG residuals, CG tracking in LOI and TEI, entry DAP and EMS)
- Apollo 8 MR Supplement 4, SPS final flight evaluation: https://ntrs.nasa.gov/api/citations/19710002412/downloads/19710002412.pdf
- Boeing D5-15794, Apollo/Saturn V Postflight Trajectory AS-503 (19 Feb 1969): https://apollojournals.org/afj/ap08fj/pdf/as503-postflight_traj.pdf. Tables 3-I (TB6 9,659.54 s; second cutoff 10,555.51 s), 3-V (TLI conditions), 3-VI (targeting), 4-II (venting polynomials), 4-III (insertion), 6-I to 6-III (slingshot, closest approach, heliocentric orbit), B-V to B-VII; flight azimuth 72.124°
- Saturn V FER AS-503, MPR-SAT-FE-69-1 (20 Feb 1969): https://www.ibiblio.org/apollo/Documents/lvfea-AS503-Apollo8.pdf (exists, over 10 MB, not read here); NTRS record https://ntrs.nasa.gov/citations/19690015314; AFJ mirror http://klabs.org/history/history_docs/jsc_t/apollo_08_saturn_v.pdf
- Apollo 8 document index (press kit, Flight Plan vols 1-2, SA-503 Flight Manual, Mission Operations Reports, lunar landmark locations): https://apollojournals.org/afj/ap08fj/a08-documents.html, e.g. pdf/a08-presskit.pdf, pdf/a08-flightplan-v1.pdf, pdf/a08-flightplan-v2.pdf, pdf/sa503-flightmanual.pdf, pdf/lunar_landmark_locations-8-10-11-12.pdf
- GE504, Boeing D5-15706-4, Saturn V Launch Vehicle Guidance Equations SA-504: https://www.ibiblio.org/apollo/Documents/SaturnVLaunchVehicleGuidanceEquations.pdf. §3.1.2-3.1.4, §4.1.10, Figs. 4-14 and 4-15, Table 4-VI, out-of-orbit targeting Tables 5-III onward, TB6a/b/c and TB7 definitions
- FER AS-506 (TB6/TB7 for Apollo 11's TLI): https://www.ibiblio.org/apollo/Documents/lvfea-AS506-Apollo11.pdf
- R-577 GSOP Section 5 Rev 4 (Colossus I rev 237 and IA rev 249, Dec 1968): https://www.ibiblio.org/apollo/NARA-SW/R-577-sec5-rev4-start-5.2.pdf (check §5.6 is present); Colossus 249 P61-P67 listing as a specification cross-check: https://ibiblio.org/apollo/listings/Colossus249/P61-P67.agc.html
- NASA TN D-6725, Graves and Harpold, Mission Planning for Apollo Entry: https://ntrs.nasa.gov/api/citations/19720013191/downloads/19720013191.pdf (constant-g backup, corridor, Apollo 11 trim table)
- MSC IN 65-FM-157 (Hunt), Apollo Reentry Guidance equations (earlier formulation): https://ibiblio.org/apollo/Documents/19750065842_1975065842.pdf
- GRGM900C (GSFC): https://pds-geosciences.wustl.edu/grail/grail-l-lgrs-5-rdr-v1/grail_1001/shadr/gggrx_0900c_sha.tab with label .xml. DE421 principal-axis frame, R 1738.0 km, GM 4902.79996708864 km³/s², fully normalised, 406,350 records (about 50 MB). Lemoine et al. 2014, GRL, doi:10.1002/2014GL060027
- Holmes and Featherstone (2002), J. Geodesy 76:279-299: the modified forward-column recursion for high-degree normalised Legendre functions (algorithm only)
- USGS Gazetteer of Planetary Nomenclature (public domain): https://planetarynames.wr.usgs.gov/ (lunar MAP landmarks)
- Already in the repo: TN D-5399 (Apollo 4 lunar-return entry), 68-FM-184, the Apollo 7 and 11 Mission Reports, FER-506, PFT-506 (docs/data/apollo-spacecraft/README.md, tools/data/README.md)

## Licensing

Everything stays MIT by construction.

**Public-domain sources.** The NASA reports used are US Government works and are cited with credit:
- the Mission Report and its supplements;
- the FERs and PFTs (Boeing and MSFC under NASA contract);
- GE504;
- R-577 (MIT/IL under NASA contract);
- TN D-6725, TN D-5399.

The values are transcribed as data, and the equations are reimplemented in Swift.

**Data files.**
- GRGM900C is a NASA GSFC product distributed by PDS with no usage restriction. Commit only the truncated binary and a reference CSV generated by our own tool; credit Lemoine et al. 2014 in README "Data sources".
- USGS planetary nomenclature is public domain.

**Do not use:**
- NASSP (GPL): its RTCC, LVDC and CMC code are exactly this area, so do not read or port them.
- Virtual AGC's own software (GPL). The AGC listings themselves may be read only as a specification of Colossus 237/249 behaviour and constants; copy no code.
- TransX and other Orbiter add-on MFDs: do not port.
- KSP art (not relevant here).

**Apollo Flight Journal commentary** is copyrighted editorial text. Use it only to cross-check timelines, never as a data source.

## Performance

This work adds CPU cost only, no GPU. The figures are estimates for Apple Silicon in Release, to be measured.

**Lunar field**
- A degree-60 evaluation is 1,891 (n,m) terms, about 10-30 µs; a debug build is 10-30 times slower.
- In lunar orbit at 110 km the RK4 step is T/1000, about 7.1 s, with 4 evaluations per step:

| Warp | Steps per 60 Hz frame | Field cost per frame | Effect |
|---|---|---|---|
| 1,000× | about 2 | about 0.2 ms | none |
| 10,000× | about 23 | about 2 ms | fine |
| 100,000× | about 235 | about 19 ms | over the 16.7 ms frame; `stepBudget` (40 ms) caps it and the HUD shows "limited" |

- Mitigations:
  - adaptive degree by altitude, and by warp above 10,000× (20 or 30 terms; the truncation error stays under 1e-9 m/s² at Apollo altitudes for degree 60);
  - Apollo 8's ten revs (20 h) take about 7 s at 10,000×, so 100,000× in low lunar orbit is not needed.
- Translunar coast is cheap: 60 s steps and J2-only far from the Moon. At 100,000× there are about 28 steps per frame.

**Powered flight** keeps 0.02 s steps (TLI 318 s, LOI 247 s, TEI 204 s), so burns run at about 30× or less, as M1.5's 1000× is limited to 38×. An optional 0.05-0.1 s "vacuum powered" step for the SPS is acceptable only if a test shows the burn result changes by less than 0.1 m/s.

**Planners**
- A 3-day DOP853 propagation is a few hundred steps, about 10-30 ms.
- A differential correction is about 20 propagations, 0.2-0.6 s.
- They run on a background queue from MFDModel, never in the frame, are cached, and recompute on CALC or every 10 s. MFD pages keep their 4 Hz refresh.

**Snapshots.** `SystemSnapshot` already caches 8 epochs. The propagator bypasses it, reading only Earth, Moon and Sun from `ChebyshevEphemeris` and the lunar libration only when the field is on.

**Quality settings:** a "lunar field degree" setting (Auto, 30, 60, 100), default Auto.

**Tests** use the propagator for coast legs and shared fixtures for powered flights, keeping the suite's growth to about 3-5 min.

## Verification

**Linux (`swift test`): the Apollo 8 reference chain, leg by leg.** Each leg starts from a published state, as the Apollo 7 tests do, because of TLI sensitivity. Table 5-III shows that 0.34 m/s at separation moved pericynthion by about 131 n mi. Bands are set from first runs and documented, as M1.5 did.
- **L0. AS-503 ascent (shared fixture).** Event times within 1-3 s of PFT-503 Table 3-I. Insertion: speed within 3 m/s of 7,792.84 m/s, altitude within 1 km of 191.36 km, inclination within 0.02° of 32.509°.
- **L1. Parking orbit with venting.** From PFT Table 4-III, propagated with the Table 4-II venting:
  - the apogee rises 6.4 ± 1 n mi to reignition (MR §5.2);
  - the IU's restart-preparation test starts TB6 within 1 s of 9,659.54 s.
- **L2. TLI** from PFT Table B-V's TB6 state:
  - reignition within 0.5 s of 2:50:37.1;
  - cutoff within 1 s of 10,555.51 s;
  - Table 3-V at 10,565.51 s: V within 2 m/s of 10,822.05, γ within 0.05° of 7.897°, i within 0.02° of 30.636°, e within 5e-4 of 0.97553, C3 within 1 %, DN within 0.05° of 38.983°.
  - The same test for AS-506 against FER-506 (9,856.20 / 10,203.03 s).
- **L3. Slingshot** against PFT Table 6-I: LOX dump 20.4 ± 2 m/s, APS 19.4 ± 2 m/s, LH2 vent 2.1 ± 0.5 m/s. Soft check: the S-IVB/IU ends heliocentric with a = 1.4284e8 km ± 3 % (Table 6-III), which also exercises the Sun-SOI handover.
- **L4. Translunar coast** with the propagator and the sim on BET vectors (Supplement 1 App. A):
  - MCC-1 cutoff to MCC-2 ignition, a position residual (band from the first run, expected km-level);
  - from the MCC-2 cutoff, pericynthion 65.8 ± 2 n mi at 69:10:39 ± 30 s (MR Table 5-III).
- **L5. LOI-1** from MR Table 5-II's ignition state (or BET) with the as-flown SPS:
  - 246.9 ± 2 s, orbit 168.5 × 60.0 ± 1.5 n mi;
  - mass 62,827 to 46,743 lb ± 0.5 %, CG X_A 933.6 to 942.3 ± 0.3 in (A.6-I).
- **L6. LOI-2:** 9.6 s, 134.8 ft/s, giving 60.7 × 59.7 ± 0.5 n mi.
- **L7. Mascons:**
  - from LOI-2 to TEI the orbit evolves to 63.6 × 58.6 ± 1 n mi (MR §5.6);
  - propagating the rev-4 BET to rev 5 misses by less than R2's 9,468-11,751 ft downrange (Supplement 1 §3.2.2).
- **L8. TEI:** 203.7 ± 2 s, cutoff at MR Table 5-II (8,842 ft/s, γ 5.10°), mass 45,931 to 32,100 lb, CG X_A 943.6 to 949.1.
- **L9. Transearth coast** with MCC-5 (−4.8 ft/s): EI at 36,221 ± 3 ft/s, −6.50 ± 0.03°, 146:46:12.8 ± 10 s, 20.83° N 179.89° W ± 0.1° (Table 5-V).
- **L10. Entry (CMC)** from Supplement 1's 146:45:52.10 vector:
  - P64 at 32,598.8 ± 300 ft/s and 910.1 ± 10 n mi;
  - constant-drag up-control;
  - P67 at 24,900.8 ± 500 ft/s and 623.6 ± 15 n mi;
  - peaks 6.84 ± 0.3 g at about 31,841 ft/s and 3.92 ± 0.4 g at about 10,714 ft/s;
  - minimum altitude 183,000 ± 5,000 ft;
  - drogue at 146:54:48 ± 20 s;
  - landing within 5 n mi of the BET's 8.100° N 165.013° W.
- **Plus:**
  - Apollo 7 flown by CMC guidance lands within about 10 n mi of its actual splash, retiring the M1.5 accepted deviation;
  - constant-g holds 4 ± 0.3 g (TN D-6725), and the lift-up corridor stays under 10 g;
  - LunarGravityTests: against the tool's numpy reference to 1e-12; degree 2 reduces to J2 (J2 = −√5·C̄20); PA-frame sanity;
  - CislunarPropagator against the sim's RK4 over 6 h (under 10 m);
  - ManeuverTargeting convergence;
  - CSM8 mass rows: weight within 0.2 %, CG within 0.3 in, inertias within 3 %;
  - SPS series-feed draining order;
  - OrbitInstrumentsTests for the TRANSFER, lunar MAP and ENTRY pages.
- **Runtime:** shared fixtures (`static let shared`) for the AS-503 ascent, TLI and entry flights. Estimate +3-5 min on the 15-18 min suite.

**Mac**
- `xcodebuild build test`.
- Scratch-harness flights in Release, with readouts logged beside each shot:
  - TB6 countdown in the strip; the TLI burn with the IU row;
  - TRANSFER after TLI (pericynthion and free-return EI);
  - CSM separation with the LTA-B and panels; the S-IVB LOX dump;
  - MCC-1 plan, SET and burn; the "entered Moon SOI" log;
  - LOI-1 with the counter reaching zero;
  - lunar MAP for rev 1 and rev 10 with LOS/AOS; ORBIT apsides drifting;
  - TEI; EI with the lunar scroll; CMC P67 rolls; drogues; splashdown on MAP.
- Reference figures to compare by eye:
  - MR Fig. 5-4 (translunar trajectory) against the TRANSFER plot;
  - Fig. 5-5 (lunar ground tracks, revs 1 and 10) against the lunar MAP;
  - Fig. 6.9-10 (bank commanded and actual) and Fig. 6.9-12 (Apollo 8's EMS scroll) against ENTRY;
  - PFT-503 Figs. 6-1 and 6-4 (slingshot ΔV history, S-IVB and spacecraft near the Moon).
- Performance checks: effectiveWarp at 10,000× in lunar orbit with the field within 10 % of J2-only; planner latency under 1 s in Release.

## Files touched

- Sources/OrbitCore/Bodies/CelestialBody.swift (field, gravity(at:orientation:))
- Sources/OrbitCore/Bodies/SolarSystem.swift (acceleration via orientation; Moon field)
- Sources/OrbitCore/Bodies/GravityField.swift (new)
- Sources/OrbitCore/Bodies/SphericalHarmonicField.swift (new)
- Sources/OrbitCore/Resources/moongrav.bin (new, GRGM900C to degree 100)
- Package.swift (resource line)
- tools/make_moon_gravity.py (new)
- tools/data/grgm900c_reference_accel.csv (new)
- Sources/OrbitCore/Guidance/SaturnIU.swift (T6/T7, restart, TLI inhibit, TB7 slingshot)
- Sources/OrbitCore/Guidance/IterativeGuidance.swift (out-of-orbit mode, stages 4-5)
- Sources/OrbitCore/Guidance/OutOfOrbitTargeting.swift (new)
- Sources/OrbitCore/Guidance/SIVBRestart.swift (new)
- Sources/OrbitCore/Guidance/AS506FlightProgram.swift (TB6/TB7 events)
- Sources/OrbitCore/Vessel/AS506Data.swift (TB6/TB7 times, TLI presettings)
- Sources/OrbitCore/Vessel/AS503Data.swift (new)
- Sources/OrbitCore/Guidance/AS503FlightProgram.swift (new)
- Sources/OrbitCore/Vessel/SaturnV.swift (AS-503 variant, LTA-B)
- Sources/OrbitCore/Vessel/Components.swift (tank feed chain; vent force schedule)
- Sources/OrbitCore/Vessel/ApolloCSM.swift (series feed, apollo8 builders)
- Sources/OrbitCore/Vessel/ApolloCSMData.swift (Apollo 8 rows, SPS as flown)
- Sources/OrbitCore/Vessel/CommandModule.swift (Mission.apollo8)
- Sources/OrbitCore/Guidance/ApolloSCS.swift (burn-plan hold, PTC, ullage hint)
- Sources/OrbitCore/Simulation/StepControl.swift (optional vacuum powered step)
- Sources/OrbitCore/Guidance/CMCEntryGuidance.swift (new)
- Sources/OrbitCore/Vessel/CMCEntryData.swift (new)
- Sources/OrbitCore/Guidance/CMEntryProgram.swift (.cmc, .constantG modes)
- Sources/OrbitCore/Vessel/EntryAutopilot.swift
- Sources/OrbitCore/Simulation/EntryTelemetry.swift (radiative heating)
- Sources/OrbitCore/Guidance/ApolloMission.swift
- Sources/OrbitCore/Vessel/CapsuleAerodynamics.swift (only if lunar-return check fails)
- Sources/OrbitCore/Navigation/ApolloFrames.swift (new: B1969.0 mean ECI/MCI)
- Sources/OrbitCore/Navigation/CislunarPropagator.swift (new)
- Sources/OrbitCore/Navigation/ManeuverTargeting.swift (new)
- Sources/OrbitCore/Navigation/FiniteBurn.swift (new)
- Sources/OrbitCore/Navigation/LunarOrbitPlanner.swift (new)
- Sources/OrbitCore/Navigation/TransearthPlanner.swift (new)
- Sources/OrbitCore/Navigation/LunarVisibility.swift (new)
- Sources/OrbitInstruments/MFDMode.swift (.transfer)
- Sources/OrbitInstruments/Modes/TransferMFD.swift (new)
- Sources/OrbitInstruments/Modes/MapMFD.swift (Moon)
- Sources/OrbitInstruments/Modes/OrbitMFD.swift (SOI flag)
- Sources/OrbitInstruments/Modes/EntryMFD.swift (lunar scroll, CMC phase, RTGO)
- Sources/OrbitInstruments/EntryProgramHooks.swift
- Sources/OrbitInstruments/ActiveManeuver.swift
- Sources/OrbitInstruments/HUDFormat.swift
- Sources/OrbitSim/MFD/MFDModel.swift (background planners)
- Sources/OrbitSim/MFD/MFDPanelView.swift
- Sources/OrbitSim/HUD/InstrumentModel.swift and InstrumentCluster.swift (strip: TB6, TIG, LOS/AOS)
- Sources/OrbitSim/Scenarios.swift (Apollo 8 scenarios, Apollo 11 to TLI)
- Sources/OrbitSim/AppModel.swift (TLI inhibit, PTC keys)
- Sources/OrbitSim/Views.swift (help)
- Tests/OrbitCoreTests/LunarGravityTests.swift (new)
- Tests/OrbitCoreTests/TLITests.swift (new)
- Tests/OrbitCoreTests/SlingshotTests.swift (new)
- Tests/OrbitCoreTests/AS503AscentTests.swift (new)
- Tests/OrbitCoreTests/CislunarPropagatorTests.swift (new)
- Tests/OrbitCoreTests/ManeuverTargetingTests.swift (new)
- Tests/OrbitCoreTests/CSM8Tests.swift (new)
- Tests/OrbitCoreTests/CMCEntryGuidanceTests.swift (new)
- Tests/OrbitCoreTests/Apollo8ChainTests.swift and Apollo8Fixtures.swift (new)
- Tests/OrbitCoreTests/Apollo7EntryTests.swift (CMC-guided case)
- Tests/OrbitInstrumentsTests/MFDPagesTests.swift
- tools/data/a08_mr_*.csv, a08_sup1_bet_vectors.csv, pft503_*.csv, fer503_*.csv, r577_entry_*.csv (new)
- tools/check_apollo8_data.py (new)
- docs/data/apollo8/README.md (new)
- docs/Apollo8-datasheet.md (new)
- docs/m2/plan.md (new)
- docs/ROADMAP.md, README.md, CLAUDE.md

## Options (owner decisions)

Defaults are in bold; "accept defaults" settles them all.

1. **Milestones. Default: M2 is Apollo 8 (this flight work plus the graphics overhaul); a new M2.5 is the LM (Apollo 9-11); M3 is unchanged.**
   - Alternative: Apollo 8 as M2, then separate M2.5 (Apollo 9/10: docking, the LM in orbit, rendezvous) and M2.7 (Apollo 11: descent, terrain, landing gear).
2. **AS-503 fidelity. Default: an event-level AS-503 variant**, checked against FER-503/PFT-503 times and insertion with bands.
   - Alternatives: a full §17-style residual closure (+6-10 d); or Apollo 8 starting in its parking orbit from PFT-503 Table 4-III (−4 d).
3. **Entry guidance. Default: the CMC's P63-P67 equations in Swift (from R-577 §5.6 for Colossus I), with constant-g kept as the EMS backup.**
   - Constant-g alone saves about 5 d. It can only land Apollo 8 within about 50-100 n mi and cannot reproduce MR §6.9's phase transitions. It also leaves the Apollo 7 deviation open.
   - If M3 later emulates the AGC, the Swift guidance stays as the no-AGC mode and as a test oracle.
4. **Lunar field. Default: GRGM900C truncated to degree 100 in the bundle; the sim adapts the degree to altitude (60 at 110 km).**
   - Alternatives: Apollo's R2 triaxial field (historically faithful, physically worse); or degree 30 only.
5. **Burn planning. Default: RTCC-like planners on the TRANSFER MFD, with SET**, and the Apollo 8 scenarios preloaded with the flown PADs from MR Table 5-II.
   - Alternative: scripted PADs only (−3 d), with no in-sim planning.
6. **SPS ignition. Default: as in M1.5, the pilot presses Z at TIG and the EMS counter cuts off; the SCS holds the plan's inertial burn attitude.**
   - Alternative: a P40-lite automatic ignition with cross-product steering (+1.5 d), otherwise left to M3.
7. **TLI. Default: the IU's out-of-orbit IGM per GE504 with AS-503's targeting, a TLI-inhibit key (TB6c), and Apollo 11's existing TLI no-go scenario kept through the inhibit.**
   - Also AS-506's TLI as a second chain (+1 d, default yes).
8. **S-IVB after TLI. Default: model the slingshot** (LH2 vent, LOX dump, APS burns, fitted to PFT-503 Table 6-I) and the parking-orbit venting polynomials.
   - Alternative: the S-IVB coasts (−1 d).
9. **PTC autopilot mode. Default: yes** (0.5 d).
10. **Data. Default: D8 downloads the PDFs and the 50 MB GRGM900C file into the scratchpad only, never into the repo, with sha256 recorded and two readers on page images.**
11. **Tests. Default: accept +3-5 min on `swift test`, with shared fixtures.**
    - Alternative: an opt-in long-test flag for the AS-503 ascent and entry flights.
12. **Earth gravity stays J2 (default)** so that the §17 residuals stay bit-identical.
    - Revisit J3/J4 only if leg L1 misses its band.

## Effort

**About 45 focused session-days for the flight side (range 37-57). The graphics overhaul is not included.**

| Track | Days | Range | What drives the range |
|---|---|---|---|
| S8 seams | 1.25 | 1-1.5 | |
| D8 data | 3.5 | 3-5 | FER-503 is over 10 MB of poor scan; Supplement 1's App. A vectors and PFT Table 3-VI are garbled OCR and need two readers on page images; R-577 §5.6's tables |
| V AS-503 vehicle and launch day | 4.5 | 3.5-6 | How far AS-503's masses and thrust differ from the AS-506 calibration (+6-10 for a full residual closure) |
| T IU TB6/TB7, out-of-orbit IGM, restart, venting, slingshot | 6.5 | 5-8 | GE504's out-of-orbit precalculations and their convergence; the AS-506 second check |
| G lunar field, tool, tests | 3 | 2.5-4 | |
| N propagator and planners | 6 | 5-8 | Robust differential correction (B-plane versus altitude and time); finite-burn iteration |
| C8 CSM-103, series feed, burns, PTC | 3.5 | 3-4.5 | |
| E8 CMC entry guidance, constant-g, Apollo 8/7 tests | 7 | 5.5-9 | Whether R-577 §5.6 is complete in the ibiblio scan; matching the P64/P67 transition speeds |
| M8 MFDs and HUD | 5.5 | 4.5-7 | |
| R chain, scenarios, harness, docs | 4 | 3-5 | |

**Calendar:** about 14-15 days with 4 Mac and 4 cloud sessions. This is comparable to M1.5's 42 days and 10.5 calendar days, plus the graphics overhaul in parallel.

## Risks

- **Trajectory sensitivity.** A 0.34 m/s error at TLI moves pericynthion by about 130 n mi (MR Table 5-III). An end-to-end flight therefore cannot be tested against the flight; tests must go leg by leg from BET vectors, and the scenario relies on the planners' MCCs, as Apollo did.
- **Frames.**
  - The BET vectors are mean of B1969.0 (ECI/MCI).
  - Apollo-era selenographic coordinates differ from MOON_ME by a few hundred metres to about 1 km, so prefer MCI Cartesian states over Table 5-II's Moon lat/lon.
  - DE19 against DE421 is about 1 km in the Moon's position.
  - Altitudes are over Fischer 1960 (about 30 m).
  - ET − UT was 38.5 s.
- **Data quality.**
  - FER-503 was not read here (over 10 MB; klabs.org did not resolve from the sandbox; the ibiblio copy exists).
  - PFT-503 Table 3-VI and Supplement 1's App. A are garbled OCR.
  - The ibiblio R-577 §5 Rev 4 file is named "start-5.2", so check that §5.6 Entry is in it. Fallbacks: the Colossus 237/249 P61-P67 listings read as a specification only, and TN D-6725.
- **GE504 is SA-504's equation set.** AS-503's flight program may differ in detail. Use PFT-503's actual targeting, and document any departures, as datasheet §10 did.
- **The out-of-orbit IGM may diverge** (M1 had a T3 NaN case). Keep the T bound and guards.
- **Performance at high warp in lunar orbit** with a degree-60 field: see the performance notes. Adaptive degree mitigates it. RK4 at T/1000 is accurate enough (about 1e-10 relative per orbit).
- **The CMC guidance duplicates M3's AGC.** The owner has to accept it as a no-AGC mode.
- **Licence traps.** NASSP (GPL) has a full RTCC and LVDC: do not read or port it. Virtual AGC's own software is GPL: use the public-domain GSOP and listings only as specification. TransX: do not port.
- **The vent and LOX-dump models are fits to ΔV**, not to fluid physics.
- **Test runtime** grows by an estimated 3-5 min.
- **Shared-file contention.** Components.swift (feed chain, vent schedule) and SaturnIU.swift need strict ownership. AS-503's program goes in its own file.
- **MCC-1 is not fully reproducible.** It achieved 20.4 of 24.8 ft/s because of a helium bubble and short-burn timing. Leave the burn itself out of the chain and start the next leg from the BET after it.

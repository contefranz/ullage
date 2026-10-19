# M1.5 design: CSM/SM, staging, SPS and RCS

> Planning document for milestone M1.5, written on 2026-10-19 by a design study (five design reports checked by a planner) and accepted by Franz with the recommended defaults (Italian keyboard confirmed). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

Nothing happens after insertion today. There is no CM/SM split, no SPS, no SM or CM RCS, and no CSM separation. After T5 the Space key finds no staging event, because every part left on the stack is `.fixed`.

What exists, by file and line:

**Sources/OrbitCore/Vessel/SaturnV.swift**
- 299-301: one "SLA" part. Its mass is `D.sla` = 1,166 kg of panels + 626 kg of ring, from FER Tables 20-7 and 20-9. Staging `.fixed`, drawn as one frustum.
- 303-305: the "LM" part, 15,095 kg, CG at STA 3343.6, no shapes, `.fixed`.
- 307-317: one "CSM" part with dryMass = `D.csm` = 28,806 kg (FER Table 20-7). Every propellant is lumped into that dry mass: there are no tanks and no thrusters. Its CG is a mass-weighted mix of the SM and CM mid-stations, using `D.cm` = 12,250 lb (recalled, L). Staging `.fixed`.
- 319-352: the LES (event 3).
- Staging events today: 1 S-IC, 2 interstage, 3 LES, 4 S-II with the aft interstage, 5 S-IVB ullage cases.

**Sources/OrbitCore/Vessel/AS506Data.swift**
- 484-498: spacecraft masses.
- 43-47: `apolloStation`, STA = Xa + 2756.56 in (H).
- 876-885: Apollo stations, all L: Xa 838 (SLA top / SM aft), Xa 1010 (SM/CM), Xa 1137 (CM apex). Diameter 154 in.

**Datasheet (docs/AS506-datasheet.md)**
- §3 lists the SPS as 91,188.5 N, 314.5 s, MR 1.6, marked "M2". The SM RCS R-4D is 444.8 N with a placeholder Isp.
- §4 puts the SPS gimbal at Xa ≈ 833 and its exit at Xa ≈ 715, and the SM RCS quads at Xa ≈ 959. All L.
- §6 gap 6 (the Apollo 11 Mission Report mass properties) is still open.
- §12 fixes the frames: X_A = +x, Y_A = −y, Z_A = −z. So +Z_A points at Position III.

**Sources/OrbitCore/Vessel/Vessel.swift**
- 191-224: `separate(parts:name:separationSpeed:)` makes one new vessel from the leaving parts. It copies only `status` and `aerodynamics`: no flight program, autopilot, phasePlane or tvcGains. It splits a scalar `separationSpeed` along the line between the two CoMs.
- 240-269: `jettisonNextStage` and `jettison(event:)`. These light `SolidTrigger` solids: `.ownSeparation` on the leaving parts, `.event(n)` on the parts that stay. They return one vessel per event.
- 273-275: `activeStage` is the lowest part with `.main` engines.
- 287-289: `responds()` gates `activeStageOnly` thrusters, which is how the S-IVB APS is gated today.

**Sources/OrbitCore/Vessel/Components.swift**
- 242-248: `SolidTrigger` (solids only).
- 293-311: `isEnabled`, `isSolid`, `trigger`.
- 571-588: `VisualShape` has only frustum and sphere.
- 591-599: `StagingRule`.
- 603-642: `VesselPart`. `separationSpeed` is a scalar. `dryInertia` is a full Mat3, so products of inertia are already supported.
- 688-713: `addRCS`, the M0 generic 14-jet layout.

**Sources/OrbitCore/Simulation/Simulation.swift**
- 371-384: `stage()` adds one spent vessel, and asks `FlightProgram.allowsManualStaging` before acting.
- 330-351: any touchdown at 5 m/s or more is a crash.

**Sources/OrbitCore/Guidance/SaturnIU.swift**
- 412: manual staging is allowed from T3 on.
- 386: the IU's ullage sets `translationInput.x`.
- 757: the IGM cutoff sets `mainThrottle` to 0.
- The IU keeps no vessel reference; it gets the vessel through `update(v, in:)` each step. So it can safely move to another `Vessel` object.

**Sources/OrbitCore/Vessel/Autopilot.swift**
- The retrograde mode points +x along −v, which puts the CM's heat shield forward.
- The `TVCGains` gimbal law can fly a single gimballed engine.
- The phase-plane law is optional per vessel.

**App**
- AppModel.swift 172-231: the keys. Space stages, Z/X set the throttle, WASDQE rotate, IJKLUO translate, 1-8 select the attitude modes.
- Scenarios.swift: the pad, Apollo 13, S-IC engine 1 out, and the M0 capsule in Earth and lunar orbit (`VesselLibrary.capsule`, VesselLibrary.swift 42-55).

**Tests that name the CSM, SLA or LM parts**
- SaturnVDataTests.swift: 22-24 and 208.
- MassCharacteristicsTests.swift: 49-57.
- SaturnVFlightTests.swift: 172-174. The Space-key sequence ends with S-IVB, IU, SLA, LM, CSM left on the stack.
- SaturnIUTests.swift: 583 and 981.

## Design

## 1. Data: new file Sources/OrbitCore/Vessel/ApolloCSMData.swift

It defines `enum ApolloCSM`. Like `AS506`, each value keeps its source unit, its source and an H/M/L grade.

**Frames.** Build everything in Apollo axes and convert with one helper: `construction(xa:ya:za:)` returns (STA metres, −Ya, −Za). Never write a raw Y or Z.

### SPS (AJ10-137)
- Thrust, flow and transients, from 68-FM-184 Table I(b) (M):
  - 21,080 lbf (93,768 N), Isp 312.34 s, 67.49 lb/s (30.61 kg/s).
  - Buildup ΔT 0.015 s. Tail-off ΔT 0.54 s, which maps to a 1.08 s linear shutdown ramp in `EngineTransients`.
- Mixture ratio 1.6 (AOH §2.4).
- Nozzle: expansion ratio 62.5, exit 98.4 in inside diameter, 650 lb (AOH design data).
- Gimbal, as `GimbalActuator`s:
  - ±4.5° (+0.5°) about the thrusting nulls: +2° pitch towards +Z_A and +1° yaw towards +Y_A. The non-thrusting nulls are 1.5° and 0°.
  - Rate 0.12-0.132 rad/s; use 0.12.
  - Set the nulls as `bias`, inside an asymmetric `range`.
  - Gimbal point Xa ≈ 833 and exit Xa ≈ 715 (L).
- Tanks (AOH):
  - Oxidizer: storage 11,284.69 lb (5,118.6 kg, 154.47 in × 45 in inside diameter); sump 13,923.72 lb (6,315.6 kg, 153.8 in × 51 in).
  - Fuel: storage 7,058.36 lb (3,201.6 kg); sump 8,708.10 lb (3,949.9 kg).
- Ullage is mandatory at or below 22,300 lb (56.4 %) remaining. The minimum impulse is 0.4 s.

### SM RCS (16 Marquardt R-4D)
- Four quads 90° apart, rolled 7°15′ off the ±Y/±Z axes. The engines are canted about 10° away from the panel (AOH §2.5).
- Engine map, from AOH Fig. 2.5-1:
  - Quads A and C carry the ±pitch axial jets.
  - Quads B and D carry the ±yaw axial jets.
  - Every quad has a clockwise and a counter-clockwise roll jet.
- 4-jet thrust 399.2 lbf, so 443.9 N each. Isp 276.0 s, 1.45 lb/s for 4 jets (68-FM-184, M). Oxidizer/fuel 2:1 (AOH).
- Loads, from the Apollo 7 Mission Report §5.21.2: fuel 443.3 lb and oxidizer 898.4 lb in all, about 110.8 + 224.6 lb per quad. TN D-7151 gives about 1,342 lb loaded on other flights.
- Quad station Xa ≈ 959 (L).

### CM RCS (12 Rocketdyne SE-8)
- 93 lbf (413.7 N) each, in two systems of six: two pitch, two yaw and two roll jets each.
- Ten engines are in the aft compartment and two in the forward one (CSM News Reference ch. 16).
- Loads per system, from the Apollo 7 Mission Report: fuel 44.4 lb, oxidizer 87.6 lb.
- Isp: no source found. Use 276 s as a placeholder, marked as such.
- Engine positions: from Fig. 2.5-1 only (L).

### SM sectors (CSM News Reference ch. 7)
| Sector | Size | Contents |
|---|---|---|
| 1 | 50° | empty |
| 2 | 70° | oxidizer sump, one quad |
| 3 | 60° | oxidizer storage |
| 4 | 50° | O2/H2 tanks and fuel cells |
| 5 | 70° | fuel sump, one quad |
| 6 | 60° | fuel storage, one quad |

- Centre section: 44 in across, holding the helium tanks and the SPS.
- CM/SM fairing: 22 in.
- The sectors' angular placement is L. Fit it to the Mission Report CG offsets: the loaded CSM sits at Ya ≈ +4.0 in and Za ≈ +6.5 in. Oxidizer on the sector 2/3 side gives about the right magnitude.

### SLA panels (MSC IN 68-FM-160)
- Four panels, 291.5 kg each (FER: 1,166/4; 68-FM-160 assumed 593 lb).
- They deploy at 33.5°/s or more and release between 45° and 60°.
- The resultant is at least 8 ft/s at 110° ± 20° from the S-IVB +X.
- Reference area 239 ft², tumbling drag coefficient 1.7.
- Hinge at Xa ≈ 586, with the upper 21 ft as panels (L).

### Separations
- **CSM/S-IVB.** Apollo 7 fired the four +X jets for 2.6 s for 1.0 ft/s (68-FM-184 §5.1.4). The AOH sequence is +X translation, then the CSM/LV SEP button held for 2 s.
- **SM jettison controller** (MSC-03466):
  - Apollo 7-12: the four −X jets fire from separation until propellant depletion; the roll jets fire from +2.0 s for 5.5 s.
  - Apollo 13 on: −X limited to about 25 s, roll about 2 s.

### Mass rows (store them like `AS506.MassRow`, with products of inertia)
- **Apollo 7, Mission Report Table A.5-I** (p. A-47): 24 rows with weight, CG (Xa, Ya, Za) and the full inertia tensor in slug-ft². A few examples:
  - Row 17, SPS-8 ignition: 24,262 lb at (973.0, −0.9, 6.9).
  - Row 18, CM/SM separation: 23,453 lb at (977.2, −1.3, 7.1); moments 13,829 / 40,911 / 40,878.
  - Row 19, CM: 12,364 lb at (1040.8, −0.2, 6.0); moments 5,799 / 5,213 / 4,745; products 42 / −423 / 30.
  - Row 24, landing: 11,409 lb.
- **Apollo 11, Mission Report Table A-I** (weights and CGs; inertias still to be read from the page image):
  - Earth orbit insertion: 100,756.4 lb at (807.2, 2.6, 4.1).
  - CSM at transposition and docking: 63,473.0 lb at (934.0, 4.0, 6.5).
  - CM after separation: 12,107.4 lb at (1040.4, −0.2, 6.0).
  - Entry: 12,095.5 lb. Drogue: 11,603.7 lb. Main: 11,318.9 lb. Landing: 10,873.0 lb.
- **Apollo 7, 68-FM-184 Table I(c):** CM 12,384, SM with RCS 10,604, SLA ring 91, SPS 9,379, CSM 32,458 lb. CSM drag coefficient 2.0 on 129.5 ft².

## 2. Parts (in SaturnV.swift, built through a new ApolloCSM.swift)

New builder `VesselLibrary.apolloCSMParts(_ m: ApolloCSM.Mission, events:(csm: Int, sm: Int))` returns:
- **"SM"**:
  - Dry structure, SPS, helium, fuel cells, and cryogenic tanks as fixed point masses.
  - SPS oxidizer and fuel tanks, with the SPS on a bipropellant feed and `groups: [.main]`. The SPS therefore becomes the active stage once the S-IVB has gone.
  - Four SM RCS quads.
  - Radius 1.956 m, drag coefficient 2.0.
  - `staging .event(7)`.
- **"CM"**:
  - Dry mass with the crew.
  - Two CM RCS systems, each with point oxidizer and fuel tanks.
  - `isCrewed = true`, `staging .fixed`.

**The sump drains last.** The storage tank empties into the sump. Extend `PropellantTank.feedLines` to accept a settled-column geometry, so the sump behaves as the S-IC lines already do. The CSM's lateral CG then travels as it really did, and the TVC trim follows. The alternative is a series feed on a new `PropellantFeed` case.

**Dry mass, CG and inertia.**
- CM: from Apollo 7 row 19 or Apollo 11's CM row, less the CM RCS tanks.
- SM: the CSM row less the CM, with parallel-axis terms and the residual tanks removed.
- Convert slug-ft² × 1.3558179 to kg m². Products of inertia change sign on Ixy and Ixz under y = −Y, z = −Z.
- For Apollo 11, the totals must close to the FER's 28,806 kg CSM.

**SLA.** Split it into:
- "SLA ring": 626 kg, `.event(6)`.
- "SLA panel 1-4": 291.5 kg each, `.event(6)`, each in its own separation group, drawn as frustum sectors.

**Other parts.** "S-IVB", "IU" and "LM" become `.event(6)`. This is the lower side, which leaves; the crew keeps the vessel.

## 3. Thrusters

**SM RCS** — new `addSMRCSQuad(to:name:angle:station:)`.
- Two roll jets: tangential, giving one roll group plus ±Y or ±Z translation.
- Two axial jets: ±X, giving one pitch or yaw group plus `translateForward`/`translateBack`.
- Assign the groups explicitly from Fig. 2.5-1, on the dominant axis only. The torque-sign rule `addAPSModule` uses would put the 7.25°-offset jets in two groups each.
- Every jet is `activeStageOnly`. It is silent on the Saturn stack, where the S-IVB is the active stage, and live once the SM is.

**CM RCS**
- Jets with `isEnabled = false` and `trigger = .event(7)`, which arms them when the SM leaves.
- Groups derived from torque.

**SM jettison controller** — new `Thruster.sequence: FiringSequence(trigger:start:duration:)`.
- When triggered, it forces full level for its window, whatever the controls command.
- Apollo 11 values:
  - −X jets: `.ownSeparation`, start 0, until propellant depletion.
  - Roll jets: start 2.0 s, for 5.5 s.
- Automatic CSM/LV SEP ullage: the SM's +X jets on `.event(6)` (they stay), start 0, 3.0 s.

**`SolidTrigger` becomes `StagingTrigger`** (keep a typealias). Its meaning for liquid engines:
- With a sequence: start the sequence.
- Without one: set `isEnabled`.
- `Vessel.jettison(event:)` already walks the triggers.

**Tuning.** Tune the CSM's `tvcGains` for the SPS gimbal; the authority is about 18 kN·m. Control allocation then gives the gimbal pitch and yaw and the RCS roll, as on the real CSM. Optionally give the CSM a phase-plane law with SCS-like dead bands.

## 4. Staging generalisation (Vessel.swift, Components.swift)

**`VesselPart`** gains:
- `separationGroup: String?` — parts of one event with different groups become different vessels.
- `separationVelocity: Vec3?` — part frame. It overrides the scalar and conserves momentum.
- `separationRate: Vec3?` — the panels' tumble.
- `isCrewed`.
- `controlFrame: Quat?`.

**`Vessel.jettison(event:)`** returns `[Vessel]`. It separates the panels first, then the lower stack with zero separation speed. `Simulation.stage` adds them all and returns the main one; tests keep using `while let`.

**`FlightProgram`** gains `hostPart: String?`, defaulting to nil; SaturnIU returns "IU". When a host part leaves in `Vessel.separate`, these move with it:
- `flightProgram`, `autopilot`, `attitudeCommand`, `fccGains`, `phasePlane`, `tvcGains`;
- the hold and reference state, `groupPulse`, and `translationInput`.

The crewed side keeps its id, name, focus and camera, and resets to its command part's defaults: autopilot nil, `mainThrottle` 0, the CSM law. Spent names follow the existing rule: "Apollo 11 – S-IVB", "– SLA panel n", "– SM".

**`SaturnIU.allowsManualStaging`** refuses while the S-IVB is firing, unless the next event is 5 (the ullage cases).

## 5. Pilot axes

Add `Vessel.controlFrame` (pilot axes → body axes), taken from the crewed part: Rx(π) on the Saturn construction frame, which gives Apollo X_A, Y_A, Z_A. Add a core mapper `Vessel.setPilotInput(rotation:translation:)`, which maps (roll, pitch, yaw) to (roll, −pitch, −yaw) and (x, y, z) to (x, −y, −z). The app's keys call it.

Why: +Z_A is towards the crew's feet. With the frames inherited from the Saturn, W/S and A/D would be reversed for the crew. The autopilot stays in body axes. The navball session should use `attitude * controlFrame`.

## 6. Events

**Event 6: CSM/S-IVB separation.**
- The four panels fly off at about 8 ft/s and 33.5°/s or more.
- "Apollo 11 – S-IVB" leaves with the IU, the LM and the APS law.
- The SM RCS fires +X for 3 s.

**Event 7: CM/SM separation.**
- The SM leaves, the SM jettison controller fires, and the CM RCS is armed.
- The app needs two Space presses within 2 s for event 7.

## 7. Scenarios (Scenarios.swift; builders in core)

**(a) The existing AS-506 flight, continued into an Earth-orbit return** (Apollo 11 with TLI no-go). After T5, in the parking orbit:
1. Space: the CSM separates and backs away on its +X jets.
2. 2 (retrograde): turn tail first on the SM RCS.
3. Plan about 90-100 m/s retrograde with the orbit MFD (another session).
4. Z: SPS on. No ullage is needed above 22,300 lb. The gimbals trim through the CG and the RCS holds roll.
5. X: SPS off at the target Δv or perigee.
6. About 4 minutes later, Space twice: CM/SM separation.
7. 2 (retrograde) on the CM RCS, so the heat shield faces forward. Q/E or the entry session's bank hold put the lift vector up.
8. Entry, parachutes and splashdown belong to the entry/ELS session.

**(b) New "Apollo 11 in parking orbit": `VesselLibrary.apollo11InParkingOrbit(in:)`**
- Build the stack with events 1-5 removed.
- Set the S-IVB residuals at cutoff from FER Table 20-5.
- Place it at the PFT insertion state, range 709.33 s, converted from PACSS 13 to ICRF through the IU's space-fixed frame (as AscentResidualTests does).
- Put a SaturnIU in its T5/orbital state, or the APS law with a horizon hold.
- Then fly it as in (a), from step 1.

**(c) New "Apollo 7: deorbit and entry"** — CSM-101 as a CSM alone, at GET 259:38:00. Apollo 7's range zero was 1968-10-11 15:02:45 UTC.
- The state is propagated back from Mission Report Table 3-III's SPS-8 ignition state.
- Mass from Table A.5-I row 16.
- The SPS is low, so ullage is needed first.

| Step | Pilot action | GET |
|---|---|---|
| 1 | U for 15 s (ullage) | before ignition |
| 2 | Z (SPS on) | 259:39:16.3 |
| 3 | X (SPS off) | 259:39:28.2 |
| 4 | Space ×2 (CM/SM separation) | 259:43:33.8 |
| — | Entry interface | 259:53:27 |
| — | Splashdown, about 27.6° N 64.1° W | 260:09:03 |

## OrbitCore vs app

**OrbitCore** (pure Swift + Foundation, tested on Linux):
- `ApolloCSMData.swift` and `ApolloCSM.swift` (new): data, builders, `addSMRCSQuad`, CM RCS, and the scenario builders `apollo11InParkingOrbit` and `apollo7BeforeDeorbit`.
- SaturnV.swift: CSM and SLA split, and staging events 6 and 7.
- Components.swift:
  - `VesselPart.separationGroup`, `separationVelocity`, `separationRate`, `isCrewed`, `controlFrame`;
  - `StagingTrigger` for liquid engines (arm, or start a sequence), `Thruster.sequence`;
  - the sump as a column in `PropellantTank.feedLines`;
  - a frustum-sector `VisualShape` kind.
- Vessel.swift: multi-group `jettison`, program and control-state migration by host part, `controlFrame` and `setPilotInput`.
- Simulation.stage: multi-vessel results.
- FlightProgram and SaturnIU: `hostPart` and the staging guard.
- Every physics item is tested against the Apollo 7 and Apollo 11 Mission Reports, 68-FM-184, the AOH, 68-FM-160 and MSC-03466.

**Sources/OrbitSim** (macOS, verified in Xcode):
- Scenarios.swift: two new entries.
- AppModel:
  - keys go through `Vessel.setPilotInput`;
  - two Space presses for event 7;
  - the camera follows a focus change if one ever happens;
  - help text.
- HUD: rows such as "CM RCS armed" and "SM jettison", and the SPS gimbal summary. These already work through `gimbalSummary` and the tank rows.
- Meshes: the frustum-sector mesh for the panels, owned by the graphics session.

## Data and sources

- Apollo Operations Handbook Block II Vol. 1, SM2A-03-BLOCK II-(1), 15 Apr 1969 (changes 16 Jul 1969), §2.4 SPS: https://www.apollojournals.org/afj/aoh/aoh-v1-2-04-sps.pdf. Tank capacities (oxidizer 11,284.69 + 13,923.72 lb, fuel 7,058.36 + 8,708.10 lb); expansion ratio 62.5; exit 98.4 in; 650 lb; gimbal ±4.5° about the +2° pitch (+Z) and +1° yaw (+Y) thrusting nulls; 0.12-0.132 rad/s; ullage at or below 22,300 lb; mixture ratio 1.6; minimum impulse 0.4 s (pp. 2.4-1, 2.4-14/15, 2.4-41..45).
- Same handbook, §2.5 RCS: https://www.apollojournals.org/afj/aoh/aoh-v1-2-05-rcs.pdf. Quads 90° apart, offset 7°15′, canted about 10°; Fig. 2.5-1 engine map; oxidizer/fuel 2:1; tank volumes (primary 69.1 / 137.0 lb, secondary 45.2 / 89.2 lb); normal S-IVB separation sequence (p. 2.5-21); CM RCS 12 × 93 lbf, expansion ratio 9 (pp. 2.5-45..47). Neither section prints performance data: both refer to the CSM/LM Spacecraft Operational Data Book SNA-8-D-027.
- MSC IN 68-FM-184, Apollo 7 Spacecraft Operational Trajectory Rev 1 Vol I, 31 Jul 1968: https://ibiblio.org/apollo/Documents/HSI-209546.pdf. Table I(b): SPS 21,080 lbf, 312.34 s, 67.49 lb/s, buildup 0.015 s, tail-off 0.54 s; SM RCS 4-jet 399.2 lbf, 276.0 s, 1.45 lb/s. Table I(c): CM 12,384, SM 10,604, SLA ring 91, SPS 9,379, CSM 32,458 lb. Cd 2.0 on 129.5 ft². §5.1.4: separation by 2.6 s of +X for 1.0 ft/s. §5.4 and Table IX: the deorbit plan.
- Apollo 7 Mission Report MSC-PA-R-68-15: https://www.apollojournals.org/alsj/a410/A07_MissionReport.pdf. Table 2-I event times: SPS-8 259:39:16.3-28.2, CM/SM separation 259:43:33.8, entry 259:53:27, landing 260:09:03; range zero 15:02:45 GMT, 11 Oct 1968. Table 3-III ignition and cutoff states. §5.16 entry (25,846.4 ft/s; landing 27.54° N 64.07° W, reconstructed 27.64° N 64.15° W). §5.21 consumables (SPS fuel 3,710.6 + oxidizer 6,026.7 lb; SM RCS 443.3 + 898.4 lb; CM RCS 88.8 + 175.1 lb). Table A.5-I, p. A-47: full mass properties for 24 events.
- Apollo 11 Mission Report MSC-00171 (NTRS 19700008096; DjVu text at https://archive.org/details/apollo-11-mission-report). Table A-I weights and CGs are read: insertion 100,756.4 lb (807.2, 2.6, 4.1); CSM at transposition and docking 63,473.0 lb (934.0, 4.0, 6.5); CM after separation 12,107.4 lb (1040.4, −0.2, 6.0); landing 10,873.0 lb. Still to read from the page images: the inertias and the §8.11.1 propellant loads. §8.8 reports an SPS mixture ratio of 1.55.
- MSC IN 70-FM-30, Apollo 11 Entry Postflight Analysis (Mission Report Supplement 10): https://archive.org/details/apollo-11-entry-postflight-analysis. Pre-entry CM 12,148 lb; CM/SM separation at entry interface minus 13 min 49 s; hypersonic L/D 0.282.
- MSC-03466, Apollo 11 Mission Anomaly Report No. 3, Service Module Entry (NTRS 19710017109): https://archive.org/details/nasa_techdoc_19710017109. SM jettison controller: −X jets from separation to depletion, roll jets from +2 s for 5.5 s; Apollo 13 change to about 25 s of −X and 2 s of roll; slosh as the cause.
- MSC IN 68-FM-160, SLA Panel Jettison, Separation and Recontact Analysis (Jul 1968): https://ntrs.nasa.gov/api/citations/19700026553/downloads/19700026553.pdf. Panels 593 lb; deployment at 33.5°/s or more; release at 45-60°; 8 ft/s or more at 110° ± 20°; 239 ft²; Cd 1.7.
- CSM News Reference (H missions), ch. 7 Service Module: https://www.apollojournals.org/alsj/CSM07_Service_Module_Overview_pp53-60.pdf. Sector sizes and contents, centre section 44 in, fairing 22 in, SPS 152.82 in and 650 lb. Ch. 16 RCS: https://www.apollojournals.org/alsj/CSM16_Reaction_Control_Subsystem_pp147-158.pdf. 100 lbf SM and 93 lbf CM engines; 10 aft and 2 forward CM engines; only roll on the RCS while the SPS fires. Chapters 8 (SLA), 12 (ELS) and 17 (SPS) are listed on the CSMNewsRef-Boothman page and were not read.
- TN D-7151, Apollo Experience Report: CSM Reaction Control Systems (NTRS 19730017174). About 1,342 lb of SM RCS loaded; CM RCS usage. It gives no Isp.
- AS-506 FER Tables 20-7 and 20-9, already in the repo: CSM 28,806 kg, SLA panels 1,166 kg + ring 626 kg, LM 15,095 kg.
- Not found: the CM RCS (SE-8) Isp, and the CSM/LM Spacecraft Operational Data Book SNA-8-D-027 that the AOH cites for performance.
- Orbiter (github.com/orbitersim/orbiter) is MIT, though its D3D9Client is LGPL. It has no Apollo vessel and nothing to reuse here beyond the pattern of spawning vessels and grouping thrusters. NASSP (GPL) was not consulted.

## Tests

**New tests in Tests/OrbitCoreTests**

1. **CSMDataTests**
   - SPS: 21,080 lbf, 312.34 s, 67.49 lb/s; mixture ratio 1.6; tank capacities as in the AOH.
   - Gimbal: ±4.5° about the +2°/+1° nulls, 0.12 rad/s, with the thrust leaning towards +Z_A (that is −z).
   - SM RCS: each jet in exactly one rotation group and one translation group; the quads match AOH Fig. 2.5-1; jet pairs give pure torques.
   - Thrust: 4-jet +X gives 399.2 lbf at 276 s.
   - The CM RCS is disabled until event 7.
   - The SM RCS is silent on the full Saturn stack, which the IU ullage and the APS hold now test.

2. **CSMMassPropertiesTests**
   - Apollo 7 Table A.5-I rows 3-24, with the loads set from the row weights and the §5.21 consumption: weight exact by construction, CG within 0.5 in, principal moments within 3 %, products only qualitatively until their sign convention is checked.
   - Apollo 11 Table A-I:
     - Earth orbit insertion: 100,756.4 lb at Xa 807.2 (the existing spacecraft CG test, updated).
     - CSM at transposition and docking: 63,473 lb at (934.0, 4.0, 6.5).
     - CM after separation (1040.4, −0.2, 6.0) and landing.
   - The FER totals are unchanged: CSM 28,806 kg and first-motion mass 2,899,008.6 kg.

3. **CSMSeparationTests**
   - The Space sequence 1-7, with names and momentum conserved.
   - The crewed vessel keeps its id; the IU program and the APS law go with "Apollo 11 – S-IVB".
   - The IU refuses event 6 while the S-IVB is burning.
   - Apollo 7 CSM: 2.6 s of +X gives 1.0 ± 0.05 ft/s (68-FM-184).
   - SLA panels: 8 ft/s or more at 110° ± 20°, 33.5°/s or more, no recontact within 60 s (68-FM-160).
   - SM jettison (MSC-03466): −X from separation to depletion, Δv equal to Isp g0 ln(m0/m1) within 1e-6; roll from 2.0 to 7.5 s; the SM moves away along −X.
   - The CM RCS is armed and has authority.

4. **CSMPropulsionTests**
   - An SPS burn with the CG 6-7 in off the axis: the gimbal settles at the angle that puts the thrust through the CG, the attitude error stays under 0.5°, and the RCS holds roll.
   - The sump drains last, and the CG moves laterally as in the Mission Report rows.
   - Apollo 7 SPS-5: about 4,536 lb used in 67.1 s.

5. **Apollo7DeorbitTests** — the end-to-end reference.
   - Start from Table 3-III's ignition state at GET 259:39:16.3: 188.21 n mi, 25,155.3 ft/s, flight-path angle −0.988°, heading 63.20°. Mass 24,262 lb (row 17).
   - Burn 11.9 s along the planned Δv direction.
   - At cutoff: 24,966.5 ft/s ± 3 ft/s, flight-path angle −1.643° ± 0.03°, altitude 1,137,041 ft ± 2,000 ft. Mass used about 809 lb.
   - Coast to 400,000 ft: entry at 259:53:27 ± 5 s, 25,846 ft/s ± 10 ft/s, about −2.07° ± 0.05°.
   - Altitudes are over Fischer 1960, so the tolerances allow for it.

**Existing tests to update**
- SaturnVDataTests, MassCharacteristicsTests, SaturnVFlightTests (Space sequence), SaturnIUTests and StagingTests (groups): new part names.
- Rerun the whole suite. The §17 residuals must not move beyond their tolerances. The SPS and RCS are inactive on the stack, so only the spacecraft's inner CG and inertia change.

**On the Mac (owner or local session)**
- Fly scenarios (b) and (c) with the flight harness.
- Screenshots of: panels tumbling away, the CSM turning retrograde, the SPS gimbal trim in the HUD, the SM jettison, and the CM's RCS working.

## Files touched

- Sources/OrbitCore/Vessel/ApolloCSMData.swift (new)
- Sources/OrbitCore/Vessel/ApolloCSM.swift (new)
- Sources/OrbitCore/Vessel/SaturnV.swift
- Sources/OrbitCore/Vessel/AS506Data.swift
- Sources/OrbitCore/Vessel/Components.swift
- Sources/OrbitCore/Vessel/Vessel.swift
- Sources/OrbitCore/Simulation/Simulation.swift (stage only)
- Sources/OrbitCore/Guidance/FlightProgram.swift
- Sources/OrbitCore/Guidance/SaturnIU.swift (allowsManualStaging, hostPart)
- Sources/OrbitCore/Guidance/AS506FlightProgram.swift (apollo11InParkingOrbit)
- Tests/OrbitCoreTests/CSMDataTests.swift (new)
- Tests/OrbitCoreTests/CSMMassPropertiesTests.swift (new)
- Tests/OrbitCoreTests/CSMSeparationTests.swift (new)
- Tests/OrbitCoreTests/CSMPropulsionTests.swift (new)
- Tests/OrbitCoreTests/Apollo7DeorbitTests.swift (new)
- Tests/OrbitCoreTests/SaturnVDataTests.swift
- Tests/OrbitCoreTests/MassCharacteristicsTests.swift
- Tests/OrbitCoreTests/SaturnVFlightTests.swift
- Tests/OrbitCoreTests/SaturnIUTests.swift
- Tests/OrbitCoreTests/StagingTests.swift
- Sources/OrbitSim/Scenarios.swift
- Sources/OrbitSim/AppModel.swift
- Sources/OrbitSim/Views.swift (help)
- tools/data/a07_mr_table_a5_1.csv (new)
- tools/data/a11_mr_table_a_1.csv (new)
- docs/CSM-datasheet.md (new)
- docs/ROADMAP.md
- README.md

## Depends on

This builds on M1 on main (6873da7).

**Order.** Run the core session first (data, parts, staging, tests). Run the app and scenarios session after it, or in parallel with disjoint files.

**File ownership.** This work owns SaturnV.swift, the staging code in Vessel.swift and Components.swift, and Simulation.stage. Other sessions must not edit them; they use the seams below.

**Seams other sessions consume**
- **HUD/navball session:**
  - reads `Vessel.controlFrame` for the ball and the key mapping;
  - shows the crewed vessel's events.
- **Entry/ELS session:**
  - The CM's `AerodynamicModel` must not match the CSM. Today any model whose `requiredParts` are aboard wins (Aerodynamics.swift:161), so it needs `excludedParts: ["SM"]` or an exact-set match.
  - Parachutes, the apex-cover and drogue mass drops (Mission Report rows), and the CM RCS propellant dump.
  - Splashdown: today any touchdown at 5 m/s or more is a crash (Simulation.swift:342).
  - Bank-angle hold on the CM RCS defined here.
- **Graphics session:**
  - a frustum-sector mesh for the `VisualShape` kind this session adds;
  - better SM, CM, quad and nozzle shapes.
- **Orbit MFD:** deorbit planning (Δv to a target perigee or entry angle).

**Data still to read from page images.** WebFetch could not read them: the PDFs are over 10 MB or OCR-garbled.
- Apollo 11 Mission Report, Table A-I: the inertia and product columns.
- Apollo 11 Mission Report §8.11.1: SPS, SM RCS and CM RCS loads.
- Apollo 7 Table A.5-I: check the garbled digits against page A-47.

## Options (owner decisions)

1. **Scenarios.** Default: continue the AS-506 flight into an Earth-orbit return (Apollo 11 with TLI no-go), plus an "Apollo 11 in parking orbit" quick start, plus "Apollo 7: deorbit and entry" as the scenario backed by the Apollo 7 reference test. An Apollo 7-like flight from launch would need the Saturn IB, which is not modelled.

2. **Separation semantics.** Default: the crew keeps the vessel. Its id, name, focus and camera stay; the S-IVB side leaves; the IU program and its control state move with the IU part. The alternative is that the CSM leaves as a new vessel and the focus jumps to it. That conflicts with the SM leaving again at event 7, because a part can carry only one event.

3. **Pilot axes.** Default: Apollo crew axes (`controlFrame` = Rx(π)) on every vessel that carries the CM, the Saturn stack included. This flips W/S and A/D against M1's Saturn frame during ascent. Alternative: crew axes only after CSM separation.

4. **SLA panels.** Default: four separate tumbling panel vessels, as on Apollo 8 and later. Alternatives: panels left open on the S-IVB (Apollo 7), or one debris vessel.

5. **SM jettison logic.** Default: Apollo 11's (−X until depletion, roll from 2.0 s for 5.5 s). Alternative: Apollo 13 on (−X to 25 s, roll 2 s).

6. **SPS rating.** Default: 68-FM-184's 21,080 lbf at 312.34 s for both missions. Alternative: the press kit's 20,500 lbf at 314.5 s.

7. **SPS ullage below 22,300 lb.** Default: not enforced, with a HUD hint; the interlock comes in M3.

8. **CSM separation ullage.** Default: an automatic 3 s +X, standing in for holding the CSM/LV SEP button. Alternative: manual, by holding U.

9. **Guard on CM/SM separation.** Default: two Space presses within 2 s. Alternative: Shift-Space.

10. **CSM attitude law.** Default: a phase-plane law with SCS-like dead bands (0.5° narrow, 5° wide), to save SM RCS propellant. Alternative: M0's continuous law.

11. **CM RCS.** Default: both systems active, as Apollo 7 flew. Alternative: system A only.

12. **Vessel name.** Default: keep "Apollo 11". Alternative: "Columbia", the call sign.

## Effort

About 6-7 focused session-days in all.

| Work | Days |
|---|---|
| Transcribe and reconcile the data into docs/CSM-datasheet.md and tools/data CSVs (A7 Table A.5-I, A11 Table A-I from the page images, AOH, 68-FM-184, 68-FM-160, MSC-03466) | 1 |
| Core model: SM and CM parts, SPS with gimbal and sump, SM and CM RCS, SLA split | 2 |
| Staging: separation groups, vector velocity and spin, liquid triggers and sequences, program migration, controlFrame, IU guard | 1.5 |
| Tests (5 new files, updates to 5 existing ones) | 1.5 |
| Scenarios and app integration on the Mac | 1 |

This splits naturally into two sessions:
- **A, core (about 4.5 days):** data, model, staging and tests. Linux or cloud is fine.
- **B (about 2 days):** the Apollo 7 deorbit test, the parking-orbit builder and the app. B needs a Mac for the app.

## Risks

**1. Frame and sign errors.**
- Apollo Y and Z are −y and −z in the construction frame. This affects CG offsets, the gimbal nulls, the RCS groups and the products of inertia.
- The products-of-inertia sign convention in the Mission Report tables is unconfirmed.
- Mitigation: one conversion helper, tests on the signs (the CSM CG has z < 0), and products checked only qualitatively at first.

**2. M1 regressions.**
- The CSM split moves the spacecraft's inner CG and inertia. Datasheet §13.4 already has them 5-6.5 % high.
- Staging events 6 and 7 change the Space sequence.
- The SM RCS must stay silent on the stack, through `activeStageOnly`, or the IU's APS hold and ullage would fire it.
- Rerun the whole suite and the §17 residuals.

**3. Migrating the control state.** If anything the IU owns (autopilot, attitudeCommand, the APS law, ullage translation) is left behind, the S-IVB stops holding attitude after separation and the CSM inherits the IU's commands. The tests must cover both vessels.

**4. Data quality.**
- The OCR of Apollo 7 Table A.5-I has garbled digits. Rows 7-9, 12, 16, 17 and 21 must be checked against page A-47.
- Apollo 11's inertias and loads are not yet read.
- Still L or missing:
  - the CM RCS Isp (no source found);
  - the CM RCS engine positions;
  - the angular placement of the SM sectors;
  - the stations: SPS gimbal and exit, SM/CM, SLA hinge, quads.
- The fitted CG offsets cover the sector placement.

**5. Physics gaps.**
- No propellant slosh. MSC-03466 shows slosh made Apollo 11's SM tumble and recontact.
- No SM breakup.
- No consumption of cryogenics or fuel-cell reactants, worth about 500 lb over a multi-day flight; it does not matter for the scenarios.
- Splashdown counts as a crash until the entry session changes the 5 m/s rule.

**6. Parallel sessions.** Vessel.swift and Components.swift are shared seams; edits elsewhere to the control or staging code would conflict. Agree ownership up front: this work owns staging, controlFrame and VisualShape's new kind; the graphics session owns only the mesh.

**7. The Apollo 7 deorbit test.**
- Its tolerances depend on mission-era frames: the MSFN space-fixed frame and Fischer 1960 altitudes.
- The burn direction has to be reconstructed from the ignition and cutoff states.
- Set the tolerances after a first run, and justify them in the datasheet.

# Saturn V AS-506 (Apollo 11): reconciled datasheet for the OrbitSim M1 stack

Compiled on 2026-10-15 for M1 item 1 (the Saturn V stack) from web research in four categories: launch-vehicle masses and timeline, propulsion, geometry and aero, and spacecraft. Each category was independently re-verified, then reconciled here. `Sources/OrbitCore/Vessel/AS506Data.swift` holds the values the simulator uses, with the same sources and confidence grades.

**Limits.** The NASA documents could not be fetched directly; values come from search extracts of them, from arithmetic on those values, or (marked **recalled**) from memory without a check against the source. The SP-4029 S-II and S-IVB propellant-usage rows and the FER mass tables are still unread; they are the most valuable follow-up. *Update (§8, 2026-10-16): the FER was then read directly; §8.7 lists its values that bear on §1–§7. Update (§9, 2026-10-17): the model's propulsion and masses are now calibrated to the FER. §9 supersedes, for the model, the derived masses of §1.1, the S-II and S-IVB engine rows of §1.2 and §1.3 and §1.7's decision 7, all of §2, the flight rows of §3 and targets A and B of §5, which stay here as the pre-FER record. Update (§10, 2026-10-17): the IU now flies the S-II and S-IVB on iterative guidance (IGM), which commands the EMR shift and the S-IVB cutoff in place of §8's timed stand-ins. Update (§11, 2026-10-17): the launch stack now has sourced aerodynamics (axial and normal force, centre of pressure) and flies through the launch day's measured air and winds; §11 supersedes §1.6's placeholder drag. Update (§12, 2026-10-17): the retros and ullage motors are solid motors that separate the stages, and the LES's tower-jettison motor throws the tower clear; §12 supersedes §3's solid-motor rows. Update (§13, 2026-10-18): the mass distribution is sourced: each stage's dry CG and inertias from FER Table 20-10, the tank loads from the station diagram and the tank drawings, the J-2 gimbal stations, the LM's CG; liquids have no roll inertia, and the S-IC flies REF504's roll filter. §13 supersedes §4's tank extents and J-2 rows and the dry-CG remarks of §4. Update (§14, 2026-10-18): three diagnostics against AS-506's postflight trajectory place the remaining ascent residuals by stage; they answer §8.5's and §11.5's open causes and break down §10.5's cutoff delay. Update (§15, 2026-10-18): the Earth has WGS 84's figure, with geodetic altitude, latitude and vertical, and the pad stands at AS-506's geodetic latitude, 4.85 km lower than on the sphere; §15 supersedes the model fact "Spherical Earth", §1.6's pad rows and §5's frame notes, and re-baselines the flight (§15.3). Update (§16, 2026-10-18): engines can fail in flight; the IU senses an engine out, freezes the S-IC's pitch program (GE504) and stretches the S-II's stage 2 for the IGM; the nominal flight is unchanged.*

## Conventions

- **t**: range time in seconds from range zero, 1969-07-16 13:32:00 UTC. For Apollo 11, GET is the same clock.
- **h**: height in metres above the vehicle base, measured along the axis. The base is taken to be the F-1 nozzle-exit plane. Vehicle station STA (inches) converts as h = (STA + 115) × 0.0254; the +115 offset is derived in §4. Apollo spacecraft station Xa converts as STA = Xa + 2756.56 (AS-501 FER Figure B-1, §13; 2756 recalled before).
- **Units and constants**: SI throughout; 1 lb = 0.45359237 kg; 1 lbf = 4.4482216152605 N; g0 = 9.80665 m/s²; p0 = 101,325 Pa.
- **Sensed acceleration**: non-gravitational acceleration, (thrust + aero)/m, which is what an accelerometer reports. OrbitSim's `thrustAcceleration` is the thrust-only part, and drag is negligible at the events used here. SP-4029's "total inertial acceleration" is this quantity. Two checks show it: the S-IVB value of 0.69 g is below local gravity (0.944 g), and §2.4 reproduces the S-II CECO value of 1.82 g as T/m.
- **Confidence**: H = high, M = medium, L = low.
- **Source keys**:
  - GIW: SP-4029 Ground Ignition Weights (history.nasa.gov/SP-4029/Apollo_18-19_Ground_Ignition_Weights.htm).
  - PU: SP-4029 Launch Vehicle Propellant Usage. Only the S-IC rows were read, and the column meaning was inferred.
  - AP: SP-4029 Apollo 11 Ascent Phase.
  - TL: SP-4029 Apollo 11 Timeline.
  - SUM: SP-4029 Apollo 11 Summary and Earth Orbit Phase.
  - MOR: Mission Operations Report M-932-69-11, Table 3. Pre-flight values, read from OCR.
  - TIS: Technical Information Summary AS-506, S&E-ASTR-S-101-69. Pre-flight.
  - TIS-501: AS-501 Technical Information Summary.
  - FER: MPR-SAT-FE-69-9, seen only through search extraction.
  - MR: Mission Report MSC-00171.
  - Betts: NTRS 20140011656.
  - EH: enginehistory.org.
  - TDiA: This Day in Aviation.
  - AFJ: Apollo Flight Journal.
  - DLR: "Apollo 11 Reloaded".
  - SP-8120: NASA nozzle design-criteria monograph, used for the J-2 throat.

## OrbitSim model facts that drive the choices below

Read from `Sources/OrbitCore` as of M0, before the stack was built. Since then the core has gained bipropellant feeds, engine ratings that can be switched (for the EMR shift), placed tanks with a centre of mass that moves as they drain, and staging events, and since §15 a WGS-84 Earth, so the first, third, fifth, seventh and eighth points below no longer hold:

- **One tank per thruster.** `Thruster.tank` is a single tank, so LOX and fuel can only be modelled as separate tanks after a bipropellant-thruster feature exists. Until then, use one combined tank per stage; the LOX and fuel split is given for that later feature.
- **Constant mass flow.** mdot = F_vac/(Isp_vac × g0) at every pressure, and F(p) = F_vac × (1 − (1 − Isp_SL/Isp_vac) × p/p0). A stage's burn time is therefore exactly usable mass ÷ Σ mdot.
- **No EMR modes.** A thruster has fixed F_vac and Isp, so the S-II mixture-ratio shift needs either a performance mode or swapping the thrusters at t_shift.
- **No holddown.** `stepLanded` lifts the vehicle off as soon as thrust exceeds weight; holddown arms are not modelled.
- **Fixed part CoM.** A part's centre of mass (`offset`) does not move as its tanks drain, and tanks have no position. Tank stations in §4 are informational only.
- **Drag area.** `dragArea` is the maximum over parts of πr²·Cd. The drag coefficient is constant, with no Mach dependence. *(Since §11 only separated stages fly this; the stack has its own aerodynamics.)*
- **Staging.** `jettisonBottomPart` drops the part with the lowest x. Only the lowest part that has `.main` thrusters responds to the throttle. The LES is at the top, so it needs `separate(parts:)`.
- **Spherical Earth.** R = 6,378,137 m, with the US-1976 atmosphere indexed by r − R. The real pad is at a geocentric radius of 6,373.355 km, so a pad placed on the sim sphere is 4.78 km "too high" in radius (4,815 m between the model's centre of mass and the PFT's at first motion, §14). Validate radii, not published altitudes (§5). *(The Apollo 11 scenario now flies §11's launch-day sounding instead of US-1976. Since §15 the Earth is WGS 84's ellipsoid, altitude is geodetic, and the pad's centre of mass is 30 m from the PFT's radius.)*

---

## 1. Chosen values

### 1.1 Launch-vehicle masses (as flown, at S-IC ground ignition, t = −6.4 s)

| id | chosen (SI) | original | source | conf | definition / notes |
|---|---|---|---|---|---|
| vehicle_mass_ground_ignition | 2,938,314.7 kg | 6,477,875 lb | GIW | H | Exact sum of the seven GIW rows. Chosen over the FER-OCR reading of 2,941,221 kg (6,484,282 lbm). That figure is 212 lb from the MOR prediction (6,484,070 lb), so it is very likely the FER's *predicted* column. |
| sic_dry | 130,421.9 kg | 287,531 lb | GIW | H | Stage only; the interstage is excluded. Whether the 8 retro-motor propellant charges (≈ 8 × 126 kg) sit in "dry" or in "other" is not stated. |
| sic_lox_load | 1,499,479.3 kg | 3,305,786 lb | GIW, PU | H | |
| sic_rp1_load | 646,318.8 kg | 1,424,889 lb | GIW, PU | H | |
| sic_other | 2,468.5 kg | 5,442 lb | GIW | H | Not itemised: frost, GN2 and He, lubricants. |
| sic_lox_consumed (ignition → OECO) | 1,481,439.0 kg | 3,266,014 lb | PU | M | Column meaning inferred; three arithmetic checks pass (verifier). May include LOX converted to GOX pressurant, which stays on board (an estimated 2–4 t). |
| sic_rp1_consumed | 632,364.9 kg | 1,394,126 lb | PU | M | |
| sic_lox_at_oeco | 18,040.3 kg | 39,772 lb | PU | M | On board at OECO, before tail-off. |
| sic_rp1_at_oeco | 13,953.9 kg | 30,763 lb | PU | M | |
| sic_consumed_mixture_ratio | 2.3427 | derived | PU | M | Stage-level ratio, not the F-1 inlet EMR (rated 2.27). |
| sic_sii_interstage | 5,205.9 kg | 11,477 lb | GIW | H | Includes the 4 S-II ullage motors. Their propellant (4 × 152.4 kg) has to be booked here, because "S-II other" (571.5 kg) is smaller than 609.6 kg. That placement is an inference. |
| sii_dry | 36,157.7 kg | 79,714 lb | GIW | H | Both interstages excluded. |
| sii_lox_load | 371,514.8 kg | 819,050 lb | GIW | H | Load at S-IC ignition, not at S-II ignition. |
| sii_lh2_load | 71,720.2 kg | 158,116 lb | GIW | H | |
| sii_other | 571.5 kg | 1,260 lb | GIW | H | |
| sii_sivb_interstage | 3,663.2 kg | 8,076 lb | GIW | H | Leaves with the S-II at 549.0 s. Carries the 4 S-II retros (4 × 121.7 kg propellant); booking not stated. |
| sivb_dry | 11,272.7 kg | 24,852 lb | GIW | H | Aft interstage and IU excluded. |
| sivb_lox_load | 87,315.2 kg | 192,497 lb | GIW | H | |
| sivb_lh2_load | 19,780.3 kg | 43,608 lb | GIW | H | The 261,187 lb total seen once in a search read is the Apollo 12 column. |
| sivb_other | 751.1 kg | 1,656 lb | GIW | H | Probably APS propellant, He, and the 2 solid ullage motors (2 × 26.6 kg propellant). |
| iu | 1,939.1 kg | 4,275 lb | GIW | H | |
| spacecraft_at_ignition | 49,734.6 kg | 109,646 lb | GIW | H | LES (with BPC) + CM + SM + LM + SLA. The same value applies at liftoff. TDiA's "CSM" label is wrong. |
| vehicle_mass_at_release (t = 0.30) | 2,899,421.4 kg | 6,392,130 lb | derived | L | GIW total minus the MOR-predicted 85,745 lb used between ignition and liftoff. No as-flown liftoff mass was found. MOR's predicted liftoff mass is 2,902,231.4 kg (6,398,325 lb). |
| vehicle_mass_at_sic_oeco | 824,510.7 kg | 1,817,735 lb | derived (GIW − PU) | M | ±0.5%. Frost and gas losses would lower it; retained GOX would raise it. Pre-flight TIS: 828,667.9 kg. |
| vehicle_mass_at_sii_ignition | 659,626.3 kg | 1,454,227 lb | derived (GIW rows above the S-IC) | M | Upper bound: S-II and S-IVB venting before 164 s (est. 0.5–1.5 t) is not removed. Pre-flight TIS: 659,432.6 kg. |
| stack_at_sivb_ignition | 166,760.5 kg | 367,644 lb | derived: S-IVB + IU + spacecraft − LES | M | Upper bound by roughly 0.1–0.2 t of boost venting and early ullage burn. |
| vehicle_mass_at_insertion | 135,095 kg (sim model, §2) | — | derived | M-L | The FER-OCR figure is 135,669 kg; its lbm partner "229,099" is a misread of 299,099. It is 0.42% above the propellant budget and would need Isp ≈ 435–445 s. Keep it as a ±1% cross-check only. |
| MOR separation weights (pre-flight) | S-IC 164,846.8 kg; S-II with aft IS 42,701.2 kg; S-IVB after TLI 12,825.3 kg | 363,425; 94,140; 28,275 lb | MOR (OCR) | L | Definitions not stated. The S-II figure only makes sense if it includes the aft interstage (residual 6,140 lb rather than 14,220). |

### 1.2 Event timeline (range time)

| id | t (s) | source | conf | notes |
|---|---|---|---|---|
| ignition_sequence_start | −8.9 | TL, AFJ | H | |
| first_F1_ignition (engine 5) | −6.4 | PU, TL | M | TDiA gives −6.1. The 168.03 s S-IC burn is counted from −6.4. |
| all_engines_thrust_OK | −1.6 | TL | M | A secondary source gives −1.92. |
| first_motion (holddown release) | 0.30 | TL, Boeing D5-15560-6 | H | The sim releases the holddown here (§2.4). |
| liftoff (umbilical disconnect) | 0.63 | TL, MR | H | |
| tower-clearance yaw | 1.7 – 9.7 | TL | M | |
| pitch and roll program start | 13.2 | TL | H | |
| roll end | 31.1 | TL | M | Armstrong's 34 s call is a voice lag. |
| S-IC outboard engine cant | 20.6 | FER sequence table (OCR); EL | M | About 2° outboard (EL; EH 8.13; M). Ramp and axis in §7.1. |
| Mach 1 | 66.3 | TL, AP | H | |
| max Q | 83.0 | SP-4029 Ascent Data | H | |
| S-IC CECO (command) | 135.20 | TL, AP | H | The SP-4029 timeline entry at 91.5 s is an error. |
| S-IC OECO | 161.63 | SUM, MR (161.7) | H | Triggered by the LOX low-level sensors (depletion). |
| S-IC/S-II separation | 162.30 | AP | H | |
| S-II engine start command | 163.04 | TL, MR | H | |
| S-II engine start (solenoids, STDV open) | 164.00 | PU, AP durations; FER Table 2-2 | M-H | The sim starts the J-2s' ramp here; mainstage at 166.2 s (FER Table 2-2; §9.2). *Pre-FER: the sim ignited them here at full thrust.* |
| S-II aft interstage jettison | 192.3 | TL | H | |
| LET jettison | 197.9 | TL, AFJ | M-H | |
| S-II CECO | 460.62 | AP, TL | H | 460.75 in the statistical tables; 462 in the AFJ. |
| S-II EMR shift (high → low) | 491 | DLR citing FER Fig. 6-3 | L-M | Chosen over 502 s, which is the crew/MCC voice report and an upper bound. The FER says the shift was 9.5 s later than the final prediction. *Pre-FER; the FER has the command at 494.8 s and the PU valve step at 497.60 s (§9.2).* |
| S-II OECO | 548.22 | SUM, MR | H | Triggered by LOX low-level sensors, 3.5 s earlier than predicted (FER Table 2-2; the 0.55 s late is the S-IC OECO's). |
| S-II/S-IVB separation | 549.00 | AP | H | |
| S-IVB ignition | 552.20 | MR, PU | H | The SP-4029 "start command" at 549.00 is a sequence start. |
| S-IVB first cutoff | 699.33 | SUM | H | Guidance cutoff. |
| parking-orbit insertion | 709.33 | SUM | H | Defined as cutoff + 10 s. |
| TLI ignition / cutoff | 9,856.20 / 10,203.03 | PU, TL | H | 346.83 s. A "5 min 41.01 s" summary is wrong. |

### 1.3 Propulsion (source values; the sim parameters are in §3)

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| f1_thrust_sl_rated | 6,770,190 N | 1,522,000 lbf | Betts | H | Rating, not the flight value. |
| f1_thrust_vac_rated | 7,776,380 N | 1,748,200 lbf | Betts | M | |
| f1_isp_sl / vac_rated | 265.4 / 304.1 s | | Betts | H | The rated set is self-consistent only to 0.24%. |
| f1_mdot_rated | 2,602.3 kg/s | 5,737 lb/s | Betts | M | Wikipedia's component flows (3,945 + 1,738 lb/s) are not used: they appear to be the pre-uprate 1.5 Mlbf set (verifier). |
| f1_mr_rated | 2.27 | | Betts | H | The AS-506 stage consumption ratio is 2.3427 (§1.1). |
| f1_flight_thrust_vac_implied | 7,964,403 N | 1,790,469 lbf | derived: 3.94 g × 1,817,735 lb / 4 | L-M | +2.4% over the rated vacuum thrust. The F-1 delivered more than its rating late in the burn. |
| s_ic_thrust_liftoff (5 engines) | 34.02 MN | 7,648,000 lbf | TDiA, Braeunig | M | Basis unknown. The 7,552,000 lbf "from the LVFER" is probably a reduced-to-sea-level average (−0.62% vs predicted). |
| s_ic_thrust "max" | — | 9,180,000 lbf | TDiA | **rejected** | Exceeds 5 × the rated F_vac by 5% (verifier). |
| f1_effective_exit_area | 9.93 m² (rated), 9.96 m² (sim set) | | derived (F_vac − F_SL)/p0 | M | Equivalent diameter 3.556 m. 12.2–12.3 ft is the engine envelope, refuted as the gas-path exit (verifier). |
| f1_gimbal_limit | ±5° (0.0873 rad) per actuator axis, 5 °/s | | EH 8.13 | L | One secondary source. The 5.25° and 6° of other sources are read as the actuator stop and the bearing envelope (§7.1). The centre engine is fixed. |
| j2_rated_emr5.5 | 1,023,091 N, Isp_vac 425 s, 245.474 kg/s | 230,000 lbf | NTRS 20100032986, J-2X heritage paper | H (thrust), M (Isp) | Chosen over 232,250 / 228,000 / 225,000 lbf. It reproduces 1.82 g at S-II CECO (§2.4). |
| j2_emr_range (PU valve) | 4.5 (full open) … 5.5 (closed) | | EH | M | |
| s_ii_low_emr | 4.7 (pre-FER; FER 4.34, §9.2) | | TIS-501 | L | AS-506 value not found. EH's 4.3 lies below the PU hardware limit. With a 491 s shift, 4.7 closes the LOX budget (§2). |
| s_ivb_burn1_thrust | 901,223 N | 202,603 lbf | TDiA; FER Table 7-1 (STDV + 137 s, standardised) | H | EMR ≈ 5.0 (PU null); the model used Figure 7-2's 903 kN at EMR 4.85 (§9.2), and since §17 912 kN, from AS-506's measured acceleration (§17.6). FER: +0.20% thrust and +0.05% Isp versus prediction. |
| j2_isp_vac_emr5.0 | 427 s | | Braeunig (via researcher) | L-M | Gives burn-1 consumption 31,665 kg, consistent with the Δv budget (§5). Pre-FER: FER Table 7-1 gives 4,204 N·s/kg (428.7 s); the model's flow is Table 20-9's (§9.2). |
| s_ivb_tli_thrust | 894,364 N | 201,061 lbf | TDiA | M | M2 only. |
| j2_throat / area ratio | 0.37338 m / 27.5 | 14.7 in | SP-8120; Wikipedia, Purdue | H / H | The geometric exit area of 3.011 m² (Ø 1.958 m) is derived. The Wikipedia sea-level figures (486 kN, 200 s) are refuted. |
| j2_gimbal_limit (S-II outboard, S-IVB) | ±7° (0.1222 rad) per actuator axis | | EH 8.20; EH 8.30, Haynes | M | S-IVB: "7.0° square pattern" (§7.1). |
| sps | 91,188.5 N, 314.5 s, MR 1.6, ε 62.5 | 20,500 lbf | Apollo press kits; Aerojet NTRS 20100027319; TN D-7375 | M | The 314.5 s comes from 100 psia tests, where thrust was 21,500–21,900 lbf, so the pair may not describe one operating point (±2%). |
| sm_rcs | 16 × 444.8 N | 100 lbf | Apollo-era sources | H | Isp not found (§3). |
| aps (S-IVB) | 2 modules × (3 × 653.9 N attitude + 1 × 320.3 N ullage) | 147 / 72 lbf as operated (150 / 70 nominal) | APS-TN, NASM, collectSPACE | M (attitude), H (ullage) | Isp not found (§3, §7.3). Loads: AS-506's 203 lb N2O4 + 126 lb MMH per module (FER Table 7-5, §13; the AS-507 proxy 405 + 252 lb for both modules was used before), O/F 1.611; Wikipedia's 150 + 115 lb per module is rejected (§7.3). |
| solid motors | see §3 | | | | Propellant masses chosen by impulse checks: S-IC retro 278 lb (not 208); S-IVB ullage 58.7 lb (not 29.7). |

### 1.4 Geometry: stack interfaces (the full table is in §4)

| id | chosen | original | source | conf | notes |
|---|---|---|---|---|---|
| overall_height_base_to_LES_tip | 110.642 m | 363 ft | Apollo 11 press kit, Wikipedia (recalled) | M | Datum taken as the F-1 nozzle-exit plane. |
| launch_vehicle_height (base → IU top) | 85.674 m | 281 ft (3,373 in) | Saturn V News Reference (recalled) | L-M | Equal to stations −115 → 3258. |
| sic_length | 42.062 m | 138 ft | News Reference, Wikipedia | M | Nozzle exit to the S-IC/S-II plane (STA 1541). |
| sii_length (with S-IC/S-II interstage) | 24.841 m | 81.5 ft (978 in) | News Reference | M | STA 1541 → 2519. 81 ft 7 in (979 in) differs by 1 inch. |
| sic_sii_interstage_height | 5.563 m | 219 in | STA 1760 − 1541 (recalled) | L | |
| sivb_length (with S-II/S-IVB aft interstage) | 17.856 m | 703 in (58 ft 7 in) | News Reference | M (length), L (bookkeeping) | Chosen convention: **each upper-stage length includes the interstage below it**, as the S-II's does. This is consistent with the 281 ft sum. |
| sii_sivb_separation_plane | STA 2746.5 → h 72.682 m | | **recalled**, unverified | L | It makes the aft interstage 227.5 in (5.78 m) and the S-IVB proper 475.5 in. Alternative: the Skylab OWS lead (≈ 48 ft S-IVB proper) would put the plane at about STA 2646 (h 70.15 m). |
| body diameters | 10.058 m (S-IC, S-II, interstages); 6.604 m (S-IVB, IU, SLA base); 3.912 m (SLA top, SM, CM) | 396 in / 260 in / 154 in | News Reference, press kit | M | Fins and fairings excluded. |
| iu_height | 0.9144 m | 36 in | Wikipedia; STA 3222.56 → 3258.56 (AS-501 FER Figure B-1, §13: H) | M | |
| sla_height | 8.534 m | 28 ft | press kit | L-M | Matches Xa 502 → 838 (recalled). |
| s_ic_outboard_engine_radius | 4.623 m | 182 in (364 in circle) | fan wiki only | L | Geometrically plausible: the bells sit under the fairings. |
| s_ii_outboard_engine_radius | 2.667 m | 17.5 ft circle | EH | M | |

### 1.5 Spacecraft (at ignition and liftoff)

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| les (with BPC) | 4,032.4 kg | 8,890 lb | derived: 109,646 − 100,756 | L-M | An independent MOR-by-difference estimate gives 8,910 lb (within 20 lb). |
| cm | 5,556.5 kg | 12,250 lb | researcher (recalled); equals the MOR prediction | L | Whether crew and probe are included is not stated. |
| sm (loaded) | 23,243.4 kg | 51,243 lb | researcher (recalled) | L | MOR predicted 51,160. CM + SM = 28,800 kg matches the recalled "CSM 28,801 kg". SPS load is recalled as ≈ 18.4 t (≈ 40,600 lb, L) and SM RCS as ≈ 0.6 t (L). |
| lm (loaded, no crew) | 15,067.4 kg | 33,218 lb | derived by closure | L | MOR predicted 33,200 (+18 lb). |
| sla | 1,834.8 kg | 4,045 lb | MOR (predicted) | L | |
| spacecraft after LES jettison | 45,702.2 kg | 100,756 lb | Wikipedia "launch mass" (recalled) | L-M | Interpreted as CSM + LM + SLA. Closure holds to ±20 lb. |
| cm/sm diameter | 3.9116 m | 154 in | press kit | M | |
| sm length (with SPS nozzle) | 7.493 m | 295 in (24 ft 7 in) | press kit (recalled) | L | Never add it into a height sum: the nozzle sits inside the SLA. |
| cm height | 3.2258 m | 127 in | press kit (recalled) | L | 3.48 m elsewhere, probably to a different datum. |
| les length | 10.058 m | 33 ft | press kit (recalled) | L | The BPC overlaps the CM. |
| lm envelope | stowed geometry not found | (gear deployed: 6.985 m high, 9.449 m wide) | | L | The deployed figures are not the launch configuration. |

### 1.6 Aerodynamics and environment

| id | chosen | source | conf | notes |
|---|---|---|---|---|
| reference area, 33 ft body | 79.46 m² | geometry | M (geometry) | Use it as the S-IC/S-II part cross-section. Whether MSFC used this as the coefficient reference area is not known. |
| cross-sections, S-IVB / CSM | 34.25 m² / 12.02 m² | geometry | M | |
| CA(M) / Cd(M), centre of pressure, CN_α | **superseded by §11** (sourced) | — | — | Pre-§11 placeholder only, for the S-IC/S-II parts on 79.46 m², to be replaced: 0.30 (M ≤ 0.6), 0.45 (M 0.9), 0.60 (M 1.1–1.3), 0.45 (M 2), 0.35 (M 3), 0.28 (M ≥ 4). This is an unsourced engineering shape; tests must not depend on it. With today's constant-Cd model, use 0.45 on every 33 ft part, because `dragArea` takes the maximum over parts. |
| max Q | 35,200 Pa at 83.0 s, 13,567 m geodetic, V_rel 503.96 m/s | SP-4029 | H | US-1976 gives about 30,970 Pa at that state; the real July Cape atmosphere was about 14% denser (verifier). 503.96 m/s is the Earth-fixed speed; through the air, winds removed, it was 500.7 m/s, and §11's launch-day atmosphere gives 35.16 kPa there. |
| pad (LC-39A) | geodetic latitude 28.6084° N (geocentric 28.4470° N), longitude 80.6041° W; r = 6,373.355 km | FER, GE504; AP; Fischer-1960 radius derived | H / M | Since §15 the sim pad stands at the **geodetic** 28.6084° on WGS 84, its base 26 m above the ellipsoid (§15.1). On the spherical Earth before it, it stood at the geocentric 28.447° so that Earth-rotation speed and inclination geometry matched. |
| liftoff inertial velocity | 408.64 m/s (1,340.7 ft/s), heading 90° | AP | H | This is Earth rotation. The WGS-84 pad gives 408.636 m/s (§15.2); the sim sphere gave 408.95 m/s. |
| flight azimuth | 72.058° | SP-4029 ("rolled from a launch pad azimuth of 90° to a flight azimuth of 72.058°"); FER text; AFJ | H | Verified in §7.1. |

### 1.7 Where verifiers disagreed with researchers (or flagged an issue): decisions

1. **Ignition mass.** Chose GIW 6,477,875 lb over the FER-OCR 6,484,282 lbm, following the verifier's reasoning that the FER figure is a predicted column.
2. **"Total inertial acceleration".** Treated as sensed acceleration, as the verifier argued. §2.4 confirms it independently: the sim mass model gives 1.822 g at S-II CECO against the published 1.82 g.
3. **Liftoff 1.07 g.** Rejected as a thrust/mass target. Free-flight T/m is about 1.20 g; the 1.07 g reading is probably distorted by the controlled-release restraint.
4. **F-1 flight thrust.** Adopted the flight-matched flow (§3), which is +2.2% over rated. The verifier showed that 3.94 g implies about 1.79 Mlbf per engine. Rejected 9.18 Mlbf.
5. **Nozzle exits.** Refuted the 12.2 ft F-1 exit and the Wikipedia J-2 sea-level thrust and Isp; chose areas derived from thrust and geometry.
6. **J-2 per-engine basis.** Chose 230,000 lbf; the 1,161,250 lbf S-II total (5 × 232,250) is dropped.
7. **S-II EMR.** Downgraded the "5.5 s PU activation" from H to L (it is an AS-501 document). Chose low EMR 4.7 over 4.3 (below the hardware limit) and the shift at 491 s over 502 s. *Superseded by the FER (§9.2): High EMR Select at ESC + 5.5 s, the PU valve step at 497.60 s, low EMR 4.34.*
8. **Spacecraft total.** Relabelled "at ground ignition"; it is identical at liftoff. Read 100,756 lb as post-LES and including the SLA (verifier), hence LES = 8,890 lb. The CM value of 12,250 lb may be the predicted figure (verifier). Chose SM 51,243 lb over MOR's 51,160 lb because CSM = 28,800 kg matches the recalled as-flown CSM mass. The LM is set by closure.
9. **Interstage bookkeeping.** The verifier showed the researcher's labels were self-contradictory. Chose "each upper-stage length includes the interstage below it", with the S-II/S-IVB separation plane at STA 2746.5 (recalled, L). The OWS-based alternative is kept in §6.
10. **Solid-motor propellant.** S-IC retro 278 lb and S-IVB ullage 58.7 lb (verifier impulse checks). LES escape-motor thrust, burn time and propellant are mutually inconsistent (Isp ≈ 100 s). This is not needed for a nominal flight.
11. **FER insertion mass.** 135,669 kg is kept only as a ±1% cross-check. The propellant budget gives 135,095 kg.
12. **Rejected timeline entries.** SP-4029's 91.5 s S-IC CECO and 269.1 s S-II CECO entries, the "Mach 1 at 31.1 s" layout error, and "tower jettison 192.3 s" are all rejected.

---

## 2. Mass accounting for the sim

*Pre-FER record, superseded for the model by §9.1 and §9.4 (2026-10-17).*

### 2.1 Parts

Mass in kg, with lb in brackets. "Usable" means consumed between the sim ignition and the cutoff.

| part | dry_sim (what it contains) | usable oxidizer | usable fuel | part total at ignition |
|---|---|---|---|---|
| **S-IC** | **164,884.5** (363,508): dry 287,531 + LOX on board at OECO 39,772 + RP-1 at OECO 30,763 + other 5,442 | LOX **1,481,439.0** (3,266,014) | RP-1 **632,364.9** (1,394,126) | 2,278,688.4 (5,023,648) |
| **S-IC/S-II interstage** | **5,205.9** (11,477), including 4 ullage motors. Optional split: 4,596.3 structure + 609.6 solid propellant | — | — | 5,205.9 |
| **S-II + S-II/S-IVB interstage** | **44,599.6** (98,325): dry 79,714 + other 1,260 + aft interstage 8,076 (with the S-II retros) + LOX not consumed 2,214 + LH2 not consumed 7,061 | LOX **370,510.5** (816,836) | LH2 **68,517.3** (151,055) | 483,627.4 (1,066,216) |
| **S-IVB** | **16,255.6** (35,837): dry 24,852 + other 1,656 (APS propellant, He, ullage-motor propellant) + LOX 4,229 + LH2 5,100 not consumed by burn 1 or TLI (boost and orbital venting, residuals). The model moves the APS propellant, 298.46 (658: AS-506's, FER Table 7-5, §13), out of "other" into four APS tanks, leaving dry_sim 15,956.9 (35,179) (§7.3) | LOX **85,397.0** (188,268) = burn 1 26,387.7 + TLI 59,009.3 | LH2 **17,466.7** (38,508) = burn 1 5,277.5 + TLI 12,189.2 | 119,119.3 (262,613) |
| **IU** | 1,939.1 (4,275) | — | — | 1,939.1 |
| **SLA** | 1,834.8 (4,045) | — | — | 1,834.8 |
| **LM** | 15,067.4 (33,218), DPS/APS/RCS propellant included (not split) | — | — | 15,067.4 |
| **SM** | 23,243.4 (51,243), SPS ≈ 18.4 t and RCS ≈ 0.6 t included (L). Split into tanks only for M2 | — | — | 23,243.4 |
| **CM** | 5,556.5 (12,250) | — | — | 5,556.5 |
| **LES** (with BPC) | 4,032.4 (8,890) | — | — | 4,032.4 |
| **Total** | | | | **2,938,314.7 (6,477,875)** |

With today's single-tank thrusters, use one combined tank per stage:

- S-IC: 2,113,803.9 kg
- S-II: 439,027.9 kg
- S-IVB: 102,863.7 kg

When a bipropellant feature exists, the tank flow ratios are:

- S-IC LOX/RP-1: 2.3427
- S-II: 5.5, then 4.7 (per mode)
- S-IVB: 5.0 in burn 1

### 2.2 How the usable loads were set

**S-IC.** The usable load is the PU consumption from ignition to OECO, exactly. To consume it by OECO, the sim needs the following timeline and flow. The sim ignites all five F-1s at full thrust at **t = −2.625 s** and holds the vehicle down until 0.30 s. That fixes the propellant used before release at 38,893.3 kg (85,745 lb), the MOR-predicted ignition-to-liftoff consumption; no as-flown figure was found. CECO is commanded at 135.20 s, and OECO falls at depletion at 161.63 s.

Per-engine flow follows from the burn's engine-seconds:

- Engine-seconds: 5 × (135.20 + 2.625) + 4 × (161.63 − 135.20) = 794.845 s.
- mdot = 2,113,803.9 / 794.845 = **2,659.39 kg/s per engine** (5,863.0 lb/s), +2.2% over the rated 2,602.3 kg/s.
- Check: 2,659.39 × 794.845 = 2,113,803 kg. ✓

Holding at the rated flow instead would need an equivalent full-flow start at −6.1 s, which would consume about 83 t before release: more than twice the predicted 38.9 t. The flight-average flow being above rating is consistent with 3.94 g at OECO (§1.3).

Without a holddown feature, start the sim at 0.30 s instead, with the S-IC tank at 2,074,910.6 kg and the vehicle at 2,899,421.4 kg. Check (a) then fails by exactly 38,893.3 kg, by design.

**S-II.** The SP-4029 S-II rows are unread, so the usable load is the consumption of the chosen engine model:

- 5 × J-2 at EMR 5.5 (245.474 kg/s each) from 164.00 to 460.62 s: 364,061.8 kg.
- 4 × EMR 5.5 from 460.62 to 491.00 s: 29,829.9 kg.
- 4 × EMR 4.7 (197.204 kg/s each) from 491.00 to 548.22 s: 45,136.1 kg.
- **Total 439,027.9 kg.**

This leaves 1,004.3 kg (2,214 lb) of LOX unconsumed, which matches a LOX-depletion cutoff (residual plus boil-off plus GOX). It leaves 3,202.8 kg (7,061 lb) of LH2, which covers boost venting, GH2 pressurant still on board, and the liquid residual.

The pair (491 s, EMR 4.7) is not unique. (502 s, EMR 4.55) also closes the LOX budget, with LOX left 2,937 lb and the same Δv within 1%. Treat t_shift and EMR_low as one tuning knob that must keep LOX depletion at 548.22 s.

**S-IVB.**

- Burn 1: 147.13 s × 215.221 kg/s = **31,665.3 kg** (69,810 lb) at EMR 5.0.
- TLI (M2): 346.83 s, the first 115 s at EMR 4.5 and the rest at 5.0 (TIS summary, L) = 71,198.1 kg (156,965 lb).
- The tank holds burn 1 + TLI. Burn-1 cutoff is commanded by guidance, so the tank only has to hold at least 31.7 t for M1.

### 2.3 Checks

**(a) Sum equals the published ground-ignition mass.**

- Parts sum = 6,477,875 lb = 2,938,314.7 kg; the error is **0**, by construction.
- Stage rows are preserved: S-IC 2,278,688.4 kg; S-II + aft interstage 483,627.4 = 479,964.2 + 3,663.2; S-IVB 119,119.3.

**(b) Stage mass at separation.**

| part | sim at separation | published / estimate | residual | cause |
|---|---|---|---|---|
| S-IC (t 162.3) | 164,884.5 kg | MOR pre-flight 164,846.8 | +37.7 kg (+0.02%) | Agreement to this precision is partly coincidence. The real stage is lighter by tail-off propellant (est. 1.5–3 t) and frost, and heavier by retained GOX (est. 2–4 t). Treat as ±1.5%. |
| S-IC/S-II interstage (192.3) | 5,205.9 | ≈ 4,596 (ullage propellant burnt) | +609.6 kg | Disappears if the 4 ullage motors are modelled as solid thrusters (§3). |
| S-II + aft interstage (549.0) | 44,599.6 | MOR pre-flight 42,701.2 | +1,898 kg (+4.4%) | The sim cannot vent: pre-ignition boil-off (≈ 0.7 t) and the LH2 margin stay in "dry". This lowers the sim's S-II OECO acceleration by about 0.9%. |
| LES (197.9) | 4,032.4 | 4,032.4 / 4,041.5 (two derivations) | ≤ 9 kg | |
| S-IVB + IU + spacecraft at insertion (709.3) | 135,095 | FER-OCR 135,669 | −574 kg (−0.42%) | Within the FER read's uncertainty. The Δv budget favours the sim value (§5). |
| S-IVB after TLI (M2) | 16,255.6 | MOR pre-flight 12,825.3 | +3,430 kg | Orbital LH2 venting and the post-TLI LOX dump are not modelled; this matters for M2 only. |

**(c) Usable propellant equals consumption from ignition to cutoff.**

- **S-IC:** exact against PU (2,113,803.9 kg), given the −2.625 s sim ignition.
- **S-II:** exact against the model, which depletes at 548.22 s. The real consumption is unverified (±1%) until the PU S-II row is read.
- **S-IVB burn 1:** 31,665.3 kg (model). The FER-OCR insertion mass would imply 31,091 kg (−1.8%); that would need Isp ≈ 435–445 s, which is not physical. The model value is kept.

### 2.4 Sim event masses and sensed accelerations (vehicle definition plus the §3 engines)

| t (s) | event | mass (kg) | sensed accel, sim | published |
|---|---|---|---|---|
| −2.625 | S-IC ignition (sim, full thrust, held down) | 2,938,314.7 | — | ignition mass (GIW) |
| 0.30 | release | 2,899,421.4 | 1.217 g (sea level) | about 1.196 g from 7.648 Mlbf (secondary); SP-4029 "1.07 g" not usable |
| 135.20 | S-IC CECO | 1,105,661.6 | 3.657 g before, 2.926 g after | — |
| 161.63 | S-IC OECO (depletion) | 824,510.7 | 3.923 g | 3.94 g |
| 162.30 / 164.00 | S-IC separation / S-II ignition | 659,626.3 | 0.791 g | TIS predicted 659,432.6 kg |
| 192.3 | interstage jettison | 624,891.8 → 619,685.9 | | |
| 197.9 | LES jettison | → 608,780.2 | | |
| 460.62 | S-II CECO | 286,326.2 | **1.822 g** before, 1.457 g after | **1.82 g** |
| 491.0 | EMR shift | 256,496.2 | 1.627 → 1.317 g | — |
| 548.22 | S-II OECO (LOX depletion) | 211,360.1 | 1.598 g | about 1.7 g (AFJ, unquantified) |
| 549.0 / 552.2 | S-II separation / S-IVB ignition | 166,760.5 | 0.551 g | — |
| 699.33 | S-IVB cutoff, then insertion | 135,095.1 | 0.680 g | 0.69 g (one search read); FER-OCR insertion 135,669 kg |

### 2.5 Residual errors and their size

1. **S-IC thrust profile.** The flow is constant while the real flow rose by about 2% during the burn. Sim thrust is about +1.7% high at liftoff (7.78 vs 7.65 Mlbf) and −0.4% low at OECO (3.923 vs 3.94 g). The fix is an optional flow ramp: liftoff flow 2,614 kg/s rising linearly to 2,671 kg/s at OECO, which reproduces 7.648 Mlbf and 3.94 g and comes within 0.7% of the total consumption.
2. **Tail-off.** The sim cuts off instantly. Published thrust impulse after cutoff:
   - S-IC: 11.9 m/s (Δv_sf = +9.75 m/s to separation, with gravity −2.1 m/s).
   - S-II: 2.76 m/s.
   - S-IVB: 1.94 m/s.

   Each is about 0.30 s of full thrust. Either accept these deficits or add a linear 0.6 s ramp-down (½ impulse) drawing on the "dry" residuals.
3. **Venting and boil-off** are not modelled: about 0.7 t for the S-II and S-IVB before ignition, and LH2 in orbit (M2).
4. **Solid motors** are not modelled by default:
   - S-II ullage: +2.3 m/s at 162–166 s.
   - S-IVB ullage: about +0.7 m/s.
   - S-IC and S-II retros: separation only.
5. **J-2 start transients.** The sim starts at full thrust at 164.00 s and 552.20 s, ignoring the 163.04 s command and the S-II's first 5.5 s at EMR 5.0. The effect is a few m/s.

---

## 3. Engine performance (self-consistent sets)

*The "flight" rows and the solid-motor choices below are the pre-FER record; the model's engines are in §9.2 (2026-10-17) and its solid motors in §12. The rated rows still serve as references.*

For the F(p) model, Isp_SL is chosen so that F_vac − F_SL = p0 × Ae_eff. "Flight" rows are what the sim should use.

| engine / mode | role in sim | F_vac (N) | F_SL (N) | Isp_vac (s) | Isp_SL (s) | mdot (kg/s) | MR | ox / fuel (kg/s) | basis | conf |
|---|---|---|---|---|---|---|---|---|---|---|
| F-1 rated | reference only | 7,776,380 | 6,770,190 | 304.1 | 265.4 | 2,602.3 (SL) / 2,607.6 (vac) | 2.27 | — | Betts | H/M |
| **F-1 AS-506 flight-matched** | S-IC × 5; centre fixed, cut at 135.20; outboard deplete at 161.63 | **7,930,844** | **6,921,559** | **304.1** | **265.4** | **2,659.39** | 2.3427 | 1,863.81 / 795.58 | flow from PU consumption; rated Isp; Ae_eff 9.96 m² | M |
| **J-2 S-II, high EMR 5.5** | S-II 164.00–491.0 (5 engines, then 4 after 460.62) | **1,023,091** | 717,992 | **425.0** | 298.3 | **245.474** | 5.5 | 207.708 / 37.765 | rated; reproduces 1.82 g at CECO | M |
| **J-2 S-II, low EMR 4.7** | S-II 491.0–548.22 (4 engines) | **828,102** | 523,003 | **428.2** | 270.4 | **197.204** | 4.7 | 162.607 / 34.597 | derived: F linear in MR through (5.5, 230,000) and (5.0, 202,603) lbf; Isp +4 s per unit of MR decrease | L |
| **J-2 S-IVB burn 1, EMR 5.0** | S-IVB 552.20–699.33 | **901,223** | 596,124 | **427.0** | 282.4 | **215.221** | 5.0 | 179.350 / 35.870 | thrust TDiA (FER slice); Isp Braeunig | M-L |
| J-2 EMR 4.5 | TLI first ≈ 115 s (M2) | 779,355 | 474,256 | 429.0 | 261.1 | 185.25 | 4.5 | 151.57 / 33.68 | same model | L |
| J-2 TLI (reference) | M2 check | 894,364 | — | — | — | — | ≈ 5.0 | — | TDiA | M |
| SPS (AJ10-137) | M2 | 91,188.5 | — (vacuum only; set Isp_SL = Isp_vac) | 314.5 | — | 29.566 | 1.6 | 18.195 / 11.372 | press kit plus Aerojet; pair ±2% | M |
| SM RCS (R-4D) × 16 | attitude | 444.8 | — | ≈ 290 (placeholder; generic R-4D 312) | — | 0.1564 | ≈ 2.0 (L) | | | thrust H, Isp L |
| S-IVB APS attitude × 6 | coast attitude, burn roll | 653.9 | — | 245 (effective; AS-201 flight averages) | — | 0.2722 | 1.611 (load ratio) | | 147 lbf as operated (APS-TN) | thrust M, Isp L |
| S-IVB APS ullage × 2 | restart ullage (M2) | 320.3 | — | ≈ 290 (placeholder) | — | 0.1126 | 1.611 (load ratio) | | 72 lbf as operated (APS-TN) | thrust H, Isp L |

**J-2 sea-level Isp.** The J-2 Isp_SL values come from the geometric exit area of 3.011 m² (full-flowing bell). They only matter as a ratio in F(p) and are irrelevant above 66 km, where p is about 8 Pa.

**Solid motors** (constant-thrust approximation; Isp_eff = F·t/m_prop):

| motor | count | F each (N) | burn (s) | propellant each (kg) | Isp_eff (s) | on part | conf |
|---|---|---|---|---|---|---|---|
| S-IC retro (TE-M-424) | 8 | 390,999 (87,900 lbf) | 0.60 (0.60–0.667) | 126.1 (278 lb) | 190 | S-IC (fires aft at separation) | M thrust, L propellant |
| S-II ullage | 4 (AS-506) | 100,975 (22,700 lbf) | 3.7 | 152.4 (336 lb) | 250 | S-IC/S-II interstage, from ≈ 162.3 s | M / L |
| S-II retro (TE-M-29) | 4 | 154,843 (34,810 lbf) | 1.52 | 121.7 (268.2 lb) | 197 | aft interstage, at 549.0 s | H / L |
| S-IVB ullage (TX-280) | 2 | 15,080 (3,390 lbf; 3,390–3,460) | ≈ 4 | 26.6 (58.7 lb) | 231 | S-IVB; cases jettisoned about 12 s after ignition | M / L |
| LES tower jettison | 1 | 140,119 (31,500 lbf) | 1.1 | — | — | LES, at 197.9 s (nominal flight) | H / M |
| LES escape motor | 1 | 689,474 (155,000 lbf, TN D-7083) or 653,889 (147,000) | ≈ 3.2 | inconsistent (4,700 lb would give Isp ≈ 100 s) | — | abort only | L |
| LES pitch control | 1 | 10,676 (2,400 lbf) | 0.5 (0.5–0.62) | — | — | abort only | M |

**Where rated and flight-reconstructed values differ, and what the sim should use:**

- **F-1.** The flight-matched set is +2.2% in flow and thrust over the rating. Use it: it is the only constant-flow set that makes OECO fall at depletion at 161.63 s with the published consumption and the 3.94 g check. The 7,552,000 lbf "LVFER" figure (basis unknown) and the rated 7,610,000 lbf are both below the sim's 7.78 Mlbf at liftoff; this is the known +1.7% early-burn bias (§2.5).
- **J-2 S-II, high EMR.** Rated and flight are taken as equal. The FER gives a consumption rate −0.4% and an MR −0.1% against prediction; the absolute values were not retrieved.
- **J-2 S-II, low EMR.** No flight value exists in the inputs. Use the derived value and tune it together with t_shift.
- **J-2 S-IVB.** 202,603 lbf is a flight value at EMR 5.0, below the 230,000 lbf rating only because of EMR. Use it.

---

## 4. Geometry: heights above the vehicle base along the axis

**Datum derivation.** The S-IC is 138 ft = 1,656 in long and ends at the separation plane, STA 1541 (recalled from MSFC-MAN-503), so the base is at STA −115. The F-1 gimbal at STA 100 (CSS, M; §7.1), which CSS also places 100 in above station 0, then sits 215 in (17.9 ft) above the nozzle exit, consistent with a 19 ft engine. The LES tip at 363 ft is Xa ≈ 1485. Vehicle station = Xa + 2756 follows from SLA base Xa 502 = IU top STA 3258 (recalled). *(§13: the IU spans STA 3222.56–3258.56, so STA = Xa + 2756.56 (AS-501 FER Figure B-1, H); the Xa-derived heights below, computed with 2756, are 14 mm low. The S-IC/S-II separation plane is STA 1564 (FER-501 §12.2.3, MSFC-MAN-506), at the top of the small interstage ring above the S-IC's STA 1541.)*

**Interfaces**

| feature | station | h (m) | conf |
|---|---|---|---|
| F-1 nozzle-exit plane = vehicle base | STA −115 | 0.000 | L-M |
| F-1 gimbal plane; S-IC body (thrust-structure) aft end | STA 100 | 5.461 | M (CSS, §7.1) |
| S-IC top (forward skirt) | 1541 | 42.062 | M-L |
| S-IC/S-II separation plane (§13) | 1564 | 42.647 | M |
| second plane (S-II aft skirt base, interstage top) | 1760 | 47.625 | L |
| S-II forward skirt top = aft interstage base | 2519 | 66.904 | L-M |
| S-II/S-IVB separation plane (aft interstage top) | 2746.5 (MSFC-MAN-506 Figure 5-19, §13) | 72.682 | H |
| S-IVB/IU | 3222.56 (§13) | 84.773 | H |
| IU/SLA | 3258.56 (Xa 502, §13) | 85.688 | H |
| SLA top = SM aft bulkhead | Xa 838 | 94.209 | L |
| SM/CM (CM heat-shield base) | Xa 1010 | 98.577 | L |
| CM apex | Xa 1137 | 101.803 | L |
| LES tip | — | 110.642 | M |

**Parts as bounding cylinders** (radius used for inertia and drag)

| part | bottom | top | length | diameter (bottom → top) | r_sim | notes |
|---|---|---|---|---|---|---|
| S-IC | 0.000 | 42.062 | 42.062 | 10.058 | 5.029 | Fins and fairings excluded. Below 5.46 m there are only engines, fairings and fins. |
| S-IC/S-II interstage | 42.062 | 47.625 | 5.563 | 10.058 | 5.029 | The S-II J-2 bells hang into it, down to 42.24 (STA 1548, §13). |
| S-II + aft interstage | 47.625 | 72.682 | 25.057 | 10.058 → 6.604 (frustum from 66.904 to 72.682) | 5.029 | |
| S-IVB | 72.682 | 84.760 | 12.078 | 6.604 | 3.302 | J-2 exit at 67.17 (STA 2529.5, §13), inside the aft interstage. |
| IU | 84.760 | 85.674 | 0.914 | 6.604 | 3.302 | |
| SLA | 85.674 | 94.209 | 8.535 | 6.604 → 3.912 | 3.302 | |
| LM (inside SLA) | ≈ 85.9 | ≈ 90.9 | ≈ 5.0 | stowed envelope ≈ 4.2 | ≈ 2.1 | Estimate (L). Its top must clear the SPS exit at about 91.08. |
| SM | 94.209 | 98.577 | 4.368 | 3.912 | 1.956 | Includes the CM/SM fairing. |
| CM | 98.577 | 101.803 | 3.226 | 3.912 → ≈ 0.8 | 1.956 | |
| LES (with BPC) | 100.584 | 110.642 | 10.058 | BPC ≈ 3.9 at base; tower and motor ≈ 0.66 | ≈ 0.5 | The BPC overlaps the CM by 1.22 m. |

Set each part's `offset.x` to its CoM in the vessel frame. Midpoints are acceptable for M1. Estimated loaded CoM of the S-IC part is about 25 m, dry about 14 m (L). Because the sim keeps part CoM fixed, the vehicle CoM will not travel as it really does. Do not write CG tests yet. *(Superseded by §13: the dry CGs and inertias are FER Table 20-10's, the tanks drain as columns, and the vehicle's CG and inertias are tested at the table's events.)* *Superseded by §13: the stage dry CGs and inertias are FER Table 20-10's, and the vehicle's CG and inertia are tested against it.*

**Engines** (positions are heights; radial offsets from the axis)

| engine | gimbal h | exit h | radial offset | exit diameter | conf |
|---|---|---|---|---|---|
| F-1 centre (fixed) | 5.461 | 0.000 | 0 | 3.556 effective (3.76 envelope) | L / M |
| F-1 outboard × 4 (±5°) | 5.461 | 0.000 | 4.623 (182 in) | 3.556 | L (radius from fan wiki). Engines 1–4 sit under fins A–D, on the diagonals 45° from the pitch plane (M, §7.1); the S-II numbering is the same. The 20.6 s outboard cant (≈ 2°, M) costs only 0.06% of thrust, but it shortens the outboard moment arms by 21–34% (§7.1). |
| J-2 S-II centre (fixed) and outboard × 4 (±7°) | 45.19 (STA 1664.0; was ≈ 48.4, §13) | 42.24 (STA 1548; was ≈ 45.0) | 0 / 2.667 | 1.958 (derived; 2.07 envelope) | H / M; M radius |
| J-2 S-IVB | 70.13 (STA 2645.85; was ≈ 71.7, §13) | 67.17 (STA 2529.5; was ≈ 68.3) | 0 | 1.958 | H / M |
| SPS | ≈ 94.08 (Xa 833) | ≈ 91.08 (Xa 715) | 0 | ≈ 2.5 (recalled) | L |
| SM RCS quads × 4 | ≈ 97.3 (Xa ≈ 959) | — | ≈ 2.1 | — | L |
| S-IVB APS modules × 2 (180° apart) | ≈ 73.4 (aft skirt) | — | ≈ 3.5 | — | L |

**Tanks.** *Superseded by §13, which sources the stations and the loaded centroids.* Estimated from loads, a 10.06 m or 6.60 m diameter and assumed dome shapes; ±1.5 m; not from a station diagram.

- S-IC RP-1: cylinder 10.6 → 17.3; dome apexes 8.1 and 19.8.
- S-IC intertank: about 17.3 → 23.8.
- S-IC LOX: cylinder 23.8 → 38.0; dome apexes 21.3 and 40.5.
- S-II LOX: ellipsoid 47.9 → 54.2, equator 51.1.
- S-II LH2: from the common-bulkhead rim at 51.1 (bulkhead apex 54.2) to the forward dome apex at about 66.7; cylinder top about 63.6.
- S-IVB LOX: about 72.5 → 76.5.
- S-IVB LH2: about 76.5 → 84.0.

---

## 5. Validation targets for tests

**Reference frames for validation:**

- AP altitudes are above the Fischer-1960 ellipsoid (a = 6,378.166 km, f = 1/298.3). The parking-orbit apogee and perigee are above a sphere of radius 6,378.166 km. Sim altitude is geodetic above WGS 84 (§15), whose surface lies 30 m below Fischer's at the Cape; tests convert published altitudes with `Ellipsoid.fischer1960`. *(Before §15 sim altitude was r − 6,378,137 m on a spherical Earth with the pad 4.8 km high, so radii, not altitudes, were compared.)*
- Velocities are **space-fixed (inertial)**, which matches the ICRF state.
- The "sim expectation" column comes from the §2/§3 definition.

*Targets A and B are the pre-FER record; the model is now tested against the FER's event masses and accelerations (§9.4, §9.6). Target C still holds; its separation row's sim value is the recalibrated model's with §11's aerodynamics. The explanations of the Mach 1, max Q and S-IC OECO rows predate §11: the tests now hold Mach 1 within 1 s, and max Q within 2 % and 1 s (§11.6).*

**A. Vehicle definition (static; exact)**

| target | value | tolerance | why |
|---|---|---|---|
| total mass at ignition | 2,938,314.7 kg | ±1 kg | Bookkeeping identity. |
| S-IC, S-II (with aft interstage) and S-IVB part totals | 2,278,688.4 / 483,627.4 / 119,119.3 kg | ±1 kg | GIW rows. |
| stack above the S-IC (S-II ignition mass) | 659,626.3 kg | ±0.1% against TIS predicted 659,432.6 | Upper bound; venting not modelled. |
| S-IVB + IU + spacecraft − LES | 166,760.5 kg | ±0.3% | Venting and ullage. |
| sim burn time = usable / Σmdot | S-IC OECO 161.63 s; S-II OECO 548.22 s | ±0.05 s (analytic) | Checks that the tanks and flows are consistent. |

**B. Run targets: engines and masses** (independent of guidance)

| target | published | sim expectation | tolerance | why |
|---|---|---|---|---|
| S-IC OECO by depletion | 161.63 s | 161.63 | ±0.2 s | Integrator step is 0.02 s; consumption is the same everywhere. |
| mass at OECO | 824,510.7 kg (derived) | 824,510.7 | ±0.5% | Real GOX, frost and gas uncertainty. |
| sensed acceleration at OECO | 3.94 g (38.64 m/s²) | 3.923 g | ±0.05 g | Constant-flow model is −0.4% here; 3.94 is rounded. |
| sensed acceleration at release | ≈ 1.196 g (derived from 7.648 Mlbf; not the published 1.07) | 1.217 g | ±0.03 g | +1.7% early-burn bias; release-mechanism transients. |
| S-II OECO by LOX depletion | 548.22 s | 548.22 | ±0.3 s | |
| S-II burn duration from 164.00 | 384.22 s | 384.22 | ±0.3 s | The sim ignites at 164.00, not at the 163.04 command. |
| sensed acceleration at S-II CECO | 1.82 g | 1.822 g | ±0.03 g | Rounding plus mass and venting uncertainty. |
| sensed acceleration at S-IVB cutoff | 0.69 g (single read) | 0.680 g | ±0.02 g | Inconsistent with 202,603 lbf at 0.5–1.3%. |
| S-IVB burn-1 duration (guidance cutoff) | 147.13 s | ≈ 147 | ±4 s | 1% of mass, Isp or Δv costs about 1.5 s. No tail-off or ullage motors in the sim. |
| mass at insertion | 135,669 kg (FER OCR) | 135,095 | ±1% | FER read is L; budget derived. |
| burn-1 Δv (rocket equation) | ≈ 883.6 m/s needed (874.3 observed + gravity 7.1 + steering ≈ 4.5 − tail-off 1.9 − ullage 0.7 + coast 0.3) | 881.8 m/s | ±10 m/s | Consistency check of S-IVB stack mass, flow and Isp. |
| CECO → OECO Δv on S-II | ∫a dt ≈ 1,250 m/s (1,208.6 observed + gravity 10.7 + steering ≈ 30) | 1,271 m/s | ±40 m/s | Steering loss is only estimated. The sim is about 1.7% high, either because the S-II real mass was higher (venting) or because of the EMR guess. |

**C. Trajectory targets** (depend on the pitch program and guidance; only for M1 with a guidance model)

| event (t) | quantity | published | tolerance | why |
|---|---|---|---|---|
| pad (0) | inertial velocity | 408.64 m/s | ±0.5 m/s | The WGS-84 pad gives 408.636 m/s, tested within ±0.05 (§15.2); the sphere gave 408.95 m/s. |
| Mach 1 (66.3) | time | 66.3 s | ±3 s | US-1976 versus July sound speed (Mach 1.04 in US-1976 at the published state). |
| max Q (83.0) | time; value | 83.0 s; 35,200 Pa | ±5 s; 28–36 kPa | US-1976 under-predicts by about 12%; sim Cd is a placeholder. |
| S-IC CECO (135.2) | V_inertial; altitude | 1,979.0 m/s; 44.0 km (geodetic) | ±50 m/s; ±2.5 km | Pitch-program dependent. |
| S-IC OECO (161.63) | V_inertial; r; γ_inertial | 2,764.1 m/s; 6,439.33 km; 19.11° | ±40 m/s; ±2.5 km; ±1.5° | Drag (placeholder Cd), pitch program, the model's low-altitude climb (§9.5). |
| S-IC/S-II separation (162.30) | V_inertial | 2,773.9 m/s | sim 2,761.1 m/s; ±40 | The F-1 decay and the S-II ullage motors add 10.7 m/s from OECO (FER 9.8; §9.4). |
| S-II CECO (460.62) | V_inertial; r; γ | 5,707.5 m/s; 6,552.65 km; 0.897° | ±50 m/s; ±3 km; ±0.5° | Guidance. |
| S-II OECO (548.22) | V_inertial; r; γ | 6,916.2 m/s; 6,559.55 km; 0.619° | ±50 m/s; ±3 km; ±0.5° | Guidance; the published value is 22.8 m/s below the AS-506 nominal. |
| insertion (709.33) | V_inertial; r; γ | 7,793.1 m/s; 6,563.05 km; 0.012° | ±3 m/s; ±1.5 km; ±0.05° | Guidance closes the loop. The table's altitude noise is about 0.05 n mi. |
| parking orbit | a; e; r_apo / r_peri; i; period | 6,562.87 km; 0.00021; 6,564.26 / 6,561.49 km (the published 100.4 / 98.9 n mi; sim altitudes 186.12 / 183.35 km); 32.521°; 88.186 min (5,291.2 s) | ±2 km; e ≤ 0.001; ±2 km; ±0.05°; ±6 s | Pad at geodetic 28.6084° on WGS 84 (§15; before it, geocentric 28.447° on the sphere); the J2/μ model shifts the period by about 0.5 s. |

---

## 6. Remaining conflicts, gaps, and values tests must not depend on

**Unresolved conflicts**

- **S-II/S-IVB separation-plane station.** ~~STA 2746.5 (recalled; aft interstage 5.78 m) versus about 2646 (Skylab OWS ≈ 48 ft lead). Which stage length contains the aft interstage is not documented in the inputs.~~ *Resolved (§13): STA 2746.5 (Fig. B-1, REF504 Fig. 3-1, MSFC-MAN-506 Fig. 5-19); about STA 2646 is the S-IVB J-2's gimbal plane, 2645.85, and the S-IVB's length includes the aft interstage (MSFC-MAN-504 Fig. 6-1).*
- **S-II EMR shift and low EMR.** (491 s, 4.7) versus (502 s, ≈ 4.55); AS-501's 4.7, EH's 4.3 and the 4.5 hardware limit. *Resolved by the FER (§8.7): commanded at 494.8 s, shifted at 498.0 s, average low EMR 4.34; applied in §9.2.*
- **F-1 liftoff thrust.** 7,648,000 versus 7,552,000 lbf (bases unknown). The 9,180,000 / 9,088,419 lbf "max" figures are physically implausible for this engine model.
- **First-engine ignition.** −6.4 versus −6.1 s. All-engines-running at −1.6 versus −1.92 s.
- **Spacecraft breakdown.** CM predicted versus as-flown, SM 51,243 versus 51,160, LM 33,218 (by closure) versus 33,200, SLA predicted only.
- **LES escape motor.** 147,000 versus 155,000 lbf; propellant 4,700 lb against the burn time.
- **Other figures.** SPS thrust/Isp pair; APS loads (O/F 1.30, superseded by the FER-507 proxy in §7.3); R-4D Isp; S-IVB ullage thrust 3,390–3,460 lbf; S-IC retro 0.6–0.667 s. *The last two resolved in §12.*
- **S-IVB acceleration at cutoff.** 0.69 g against T/m of 0.680 g. FER insertion mass 135,669 kg against the 135,095 kg budget. *Resolved by the FER (§9.4, §9.5): 135,102 kg at the end of the first thrust decay (Table 20-5), and Table 4-1's 6.73 m/s² exceeds the FER's own thrust over mass.*

**Gaps (next research turn, highest value first)**

1. SP-4029 Propellant Usage, S-II and S-IVB rows: consumption, at-cutoff amounts, mixture ratio. These would replace the §2.2 S-II and S-IVB model loads.
2. FER mass characteristics: the flight-sequence mass summary (masses at CECO, OECO, S-II ignition, jettisons, S-IVB ignition and cutoff), CG and inertias, and the event table (EMR shift, tilt arrest). *Read (§8, §9.1, §9.4): Tables 2-2, 20-1, 20-3, 20-5, 20-7, 20-9; CG and inertias (Table 20-10) not used yet.* *Table 20-10 used in §13.*
3. As-flown liftoff mass, or the ignition-to-release consumption. The sim's −2.625 s ignition depends on the predicted 85,745 lb. *Resolved (§9.1): 2,899,008 kg at first motion and 39,307 kg of thrust buildup (FER Tables 20-1, 20-9); the sim starts at first motion.*
4. MSFC-MAN-503 station diagram: datum, S-IVB separation plane, tank stations, gimbal planes, nozzle protrusions, fin span. *Read in §13 from AS-501 FER Figure B-1 and its corroborating sources; the fin span is still open.*
5. Saturn V aerodynamics: CA(M) with its reference area, centre of pressure, CN_α. *Resolved in §11.*
6. Apollo 11 Mission Report mass properties: CM, SM, LM, SLA, LES as flown; SPS and RCS loads.
7. F-1 thrust-vs-time (FER) to calibrate the optional flow ramp. J-2 flight Isp at each EMR.

**Sim features the datasheet assumes or recommends** (not data, but needed to hit the targets)

- Holddown until 0.30 s.
- Bipropellant tanks, or keep combined tanks.
- Thruster performance modes (EMR shift).
- Optional tail-off ramp.
- Solid-motor thrusters.
- Scheduled jettison of a non-bottom part (LES).
- Venting.
- Radius-based validation, or an oblate surface height for the pad.

**Low-confidence values a test must not depend on**

- SP-4029 liftoff "1.07 g".
- Any S-IC "max thrust" figure.
- EMR shift time and low-EMR performance (use them only through the 548.22 s depletion test).
- S-II and S-IVB separation masses and the LH2/LOX split of S-II and S-IVB residuals.
- Pre-release consumption of 85,745 lb (predicted).
- MOR separation weights.
- FER insertion mass (±1% only).
- All tank stations, part CoMs, gimbal heights, the S-IVB separation-plane height, the LM envelope, and Xa-based spacecraft heights. *Since §13 the interfaces, gimbal planes and stage dry CGs are sourced (H/M) and the vehicle's CG is tested against FER Table 20-10; the tanks' shapes as they drain and the spacecraft's inner layout remain L.*
- Spacecraft breakdown (only the 49,734.6 kg total is H).
- LES motor data, SPS/RCS/APS Isp, APS loads.
- The placeholder Cd(M), superseded by §11.
- F-1 outboard radius, and the cant ramp and axis (§7.5).
- Solid-motor propellant masses.

---

## 7. Thrust vector control, flight control and the S-IVB APS

Compiled on 2026-10-16 for the M1 item "engine gimballing and TVC" from three research categories, each independently re-verified: TVC hardware, flight-control laws, and the S-IVB APS. The conventions are those of the header (t is range time, h is height above the vehicle base, STA converts as h = (STA + 115) × 0.0254, SI units, H/M/L grades).

**Limits.** As before, no NASA document could be fetched; every value comes from search extracts. No AS-506 Flight Evaluation Report (FER) control-performance or APS-consumption number was retrieved, so §7.4 has no FER targets. Rows marked **derived** are arithmetic on sourced values. Rows marked **sim** come from the current `VesselLibrary.saturnV()` model, evaluated in a probe run on 2026-10-16. They inherit that model's L-graded geometry: gimbal heights, tank extents and CoM placement.

**Status.** M1 item 2 implemented the §7.1 actuator model, the §7.2 command seam and the §7.3 APS; the gain schedules, cant schedule and APS phase-plane logic are left to the IU item. Where this section says "today", "the builder" or "the current model", and in the rows marked **sim** and the test names of §7.4, it describes the model before item 2. Item 2 moved the APS propellant into point tanks at r = 3.5 m, which shifts the S-IVB inertias by under 0.4% (insertion Ixx 5.877e5 kg m², S-IVB ignition Iyy 1.312e7 kg m²), and renamed `testKillRotationDampsAKickWithTheStandIns` to `testKillRotationDampsAKickWithGimbals`.

**New source keys**

- TN5869: Haeussermann, NASA TN D-5869 (1970), *Description and Performance of the Saturn Launch Vehicle's Navigation, Guidance, and Control System*, Table 3 and text.
- EL: *The Enduring Legacy of Saturn V Launch Vehicle Flight Control*, NASA MSFC, IAC-19-D6.2 (NTRS 20200002830).
- MBC: Saturn V manual backup control study (NTRS 19690018640).
- CSS: Project Apollo Coordinate System Standards (NTRS 19700076120).
- APS-TN: Coates and Donald, *Investigation of SA-501 S-IVB APS Flight Anomalies* (NTRS 19690016846).
- FER-507: AS-507 (Apollo 12) Flight Evaluation Report (Scribd OCR copy).
- AS201: *Results of the First Saturn IB Launch Vehicle Test Flight, AS-201*.
- GE504: *Saturn V Launch Vehicle Guidance Equations, SA-504* (IBM).
- MAN503: Saturn V Flight Manual SA-503, MSFC-MAN-503 (degraded OCR).
- SP4029: SP-4029 (Apollo by the Numbers), Apollo 11 timeline and summary text.
- H&P: *Hydraulics & Pneumatics* (1963), two Saturn V gimbal articles.
- SAE650304: Kalange and Alcott, *Saturn V S-IC Stage Engine Gimbal Actuation System* (abstract).
- TMX53532: NASA TM X-53532, *Propellant Feed Ducting and Engine Gimbal Lines*.
- Bramlet: *Saturn V Launch Vehicle Program* (NTRS 19720063751).
- Haynes: *NASA Saturn V 1967–1973 Owners' Workshop Manual*.
- HR: heroicrelics.org (F-1 gimbal bearing; S-IC positions).
- Oik: Oikofuge, *Coordinate Axes of Apollo-Saturn*, Parts 1 and 2.
- NASM: National Air and Space Museum APS object records.
- EDS: *AGC and Manual Control of the Saturn V* (slides) and NTRS 20190033307.
- EH pages: RPE 8.10 (S-IC), 8.13 (*F-1, One Second*), 8.20 (S-II), 8.30 (S-IVB).

### 7.1 Gimbal hardware per stage

**Engines that gimbal, ranges and rates**

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| sic_gimballed_engines | engines 1–4 (outboard); engine 5 fixed | 4 of 5 | MSFC-0600318 caption, TIS-501, Bramlet, MBC, H&P | H | Unchanged from §1.3. |
| sic_actuators | 8: two per outboard engine, one in the vehicle pitch plane and one in the yaw plane | "swiveled in the pitch and yaw planes by separate hydraulic actuators" | MBC; EH 8.10; H&P | M | The axes are parallel to the vehicle Y and Z axes, **not** radial and tangential, even though the engines sit on the 45° diagonals. Roll comes from combining the pitch and yaw actuators (MBC; TIS-501: "the 8 hydraulic actuators of the S-IC and S-II stages ... provide control in all axes"). |
| f1_gimbal_limit (control) | ±0.08727 rad per actuator axis | ±5° "thrust vector change from center" | EH 8.13 only | **L** | Downgraded from the §1.3 "M / L": there is one secondary source and no primary. The per-axis reading follows from the actuator arrangement (MBC). The square corner is 7.05° (derived). |
| f1_actuator_stop | ±0.09163 rad per axis | 5.25° "full travel" | EH 8.10, Apollo11Space (one source) | L | Read as the actuator stroke limit just outside the control limit. Stroke 11 in (0.2794 m); actuator about 300 lb (136.1 kg) and about 5 ft long. Inventory only. |
| f1_gimbal_envelope | ±0.10472 rad per axis (design / bearing) | 6° | apollomaniacs ("about engine X and Z axes"); HR ("6° any direction from center", from Rocketdyne R-3896-11) | M value, L definition | See the reconciliation below. Never a control limit. |
| f1_feedline_label | 0.14835 rad | "8°30′" | TMX53532 Fig. 19 (garbled OCR) | L | Equals the corner of a ±6° square: cos θ = cos² 6° gives 8.48° (derived). |
| f1_gimbal_rate | 0.08727 rad/s | 5°/s maximum | EH 8.13 | L | Loaded or no-load is not stated. "5.25° in about 1 s" (EH 8.10) gives 5.25°/s null-to-stop or 10.5°/s stop-to-stop. |
| sic_hydraulics | 13.79 MPa, RP-1 from the F-1 turbopump ("fueldraulic") | 2,000 psi (design, 1963) | H&P; SAE650304 (fluid source only) | L | Ground supply RJ-1, lowered to 1,500 psi (10.34 MPa) just before launch. Not needed by the sim. |
| sii_gimballed_engines | engines 1–4 (outboard); engine 5 fixed | 4 of 5 | EH 8.20; Bramlet; Haynes | H | Each outboard engine has its own closed hydraulic system: an engine-driven pump, an accumulator, and two perpendicular servoactuators in the stage pitch and yaw planes. |
| sii_j2_gimbal_limit | ±0.12217 rad per axis (pitch, yaw) | ±7° "in the pitch and yaw planes" | EH 8.20 (citing the Saturn V News Reference); Haynes for the J-2 in general | M | Downgraded from the researcher's H, since only EH was verified. Square corner 9.85–9.88° (derived). |
| sii_j2_gimbal_rate | 0.13963 rad/s | 8°/s | EH 8.20 | M-L | Single source; loaded or no-load not stated. |
| sii_hydraulics | 24.13 MPa | 3,500 psi closed system; main pump 8 gpm | EH 8.20; RR Auction (S-II engineering course) | M | Actuators locked until after S-IC/S-II separation, when a switch-selector command opens the accumulator lockup valves. Until then the S-II engines are at null. |
| sivb_j2_gimbal_limit | ±0.12217 rad per axis (pitch, yaw) | "7.0° square pattern"; "up to 7° from the stage's centreline" | EH 8.30; Haynes | M | **Fills the §1.3 gap** ("S-IVB range not found"). Square corner 9.85–9.88° (derived). Two linear actuators, an engine-driven main pump, an electric auxiliary pump, and an accumulator/reservoir. The original Douglas actuators were replaced by stiffer Moog units (EH). |
| sivb_j2_gimbal_rate | not found | — | — | — | **Placeholder for the sim: 8°/s (0.1396 rad/s), not data.** Do not cite it as the S-IVB value. |
| sivb_j2_boost_null | J-2 held at null from liftoff through S-II flight and S-II/S-IVB separation | — | EH 8.30 | M | The S-IVB TVC becomes active at S-IVB ignition (552.20). |
| actuator_dynamics | not found | quadratic s² + 5.35 s + 2547 (ω 50.5 rad/s, ζ 0.053) | NTRS 19700003412 (garbled) | L | The damping is too low for a servo bandwidth; SAE650304 mentions "damping of load resonance", so this is probably an engine/structure load resonance. **Do not use.** The actuators are mechanical-feedback hydraulic servos with dynamic-pressure-feedback load stabilisation (EL; SAE650304). |
| gimballed_inertia | not found | — | R-3896-1 has a "Weight, CG, Moment of Inertia" section, unread | — | Tail-wags-dog terms (engine first and second moments about the gimbal) cannot be modelled. |

**F-1 range reconciliation (L).** Read every value per actuator axis and the set nests consistently:

| level | per axis | square corner |
|---|---|---|
| control limit | 5.00° | 7.05° |
| actuator stop | 5.25° | 7.40° |
| bearing and feed-line design envelope | 6.00° | 8.45–8.48° |

The last corner is TM X-53532's 8°30′ label. If the 6° were instead a cone ("any direction", HR), a ±5° square command would hit it at the corners (7.05° > 6°). That reading leaves the 8°30′ label unexplained, so the square reading is preferred. **For the sim:** clamp each actuator at ±5° (F-1) or ±7° (J-2) and add no radial clamp. A 6° radial clamp would bind only when both axes exceed 4.24°, which never happens in nominal flight.

**Gimbal points**

| id | chosen | original | source | conf | notes |
|---|---|---|---|---|---|
| f1_gimbal_plane | h 5.461 m | STA 100; "structural body axes origin 100 in below the gimbal reference plane" | CSS (primary, search extract); §4 (recalled) | **M** | Upgraded from L. This also confirms station 0 = 100 in below the gimbal plane, consistent with the §4 datum. |
| sii_j2_gimbal | h 45.19 m (STA 1664.0; ≈ 48.4 ± 1.0 m before §13) | "GIMBAL STA 1664.000" | REF504 Figure 3-1 (§13) | H | Found in §13. The lever arm to the CoM is 13.6 m at S-II ignition and 28.8 m at OECO. |
| sivb_j2_gimbal | h 70.13 m (STA 2645.85; ≈ 71.7 ± 1.0 m before §13) | "GIMBAL STA 2645.853" | REF504 Figure 3-1 (§13) | H | Found in §13. It lies below the S-IVB part's aft end (72.68 m), inside the aft interstage, as on the real vehicle (`AS506.sIVBJ2GimbalStation`). The lever arm is 10.0 m at ignition and 11.0 m at cutoff. |

**Outboard cant (S-IC)**

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| sic_cant_angle | 0.03491 rad, nozzle exits outboard (thrust lines inward) | "approximately 2 degrees" outboard | EL; EH 8.13 ("two degrees outboard of center") | **M** | Upgrades §1.2's recalled ≈ 2° (L). Electronic: a ramp generator in the Flight Control Computer (FCC) adds a bias to the outboard actuator commands. No mechanical mounting cant. |
| sic_cant_axis | radial on each diagonal engine, i.e. 2°/√2 = 1.414° on each actuator | — | inference | L | The alternative, 2° on each actuator, gives 2.83° radial. EL's wording ("vectored ... outboard approximately 2 degrees") favours the thrust-vector (radial) angle. |
| sic_cant_start | t 20.6 s (TB1 + 20.0 s; sim time 20.3) | "20 seconds following liftoff"; FER event 20.6 / 20.0 | EL; FER sequence table (OCR) | **M** | Upgrades §1.2 from L. 0.63 s liftoff + 20.0 = 20.63. AS-508 FER lists the same event. |
| sic_cant_ramp | not found | "ramp generator" | EL | — | **Placeholder for the sim: 0.2°/s radial (complete at 30.6 s), not data.** Assumed held to OECO. |
| sic_cant_at_liftoff | none (engines at null plus control) | — | inference from EL | L | No source says the engines were canted on the pad. |
| sii_cant | none found | — | — | — | Do not model one. |

Effects of the cant (derived):

- **Axial thrust.** Each outboard engine loses 1 − cos 2° = 0.061% of axial thrust. The ideal Δv lost between 20.6 s and OECO is about 1.8 m/s. §4 called this "ignorable", which is true for Δv but not for torque.
- **Torque.** The cant moves each outboard thrust line closer to the CoM. The moment arm is (r − L tan 2°) cos 2°, with r = 4.623 m (L) and L the gimbal-to-CoM distance in the sim:

  | t (s) | L (m) | moment arm (m) | change |
  |---|---|---|---|
  | 20.6 | 27.7 | 3.65 | −21% |
  | 83 | 30.0 | 3.57 | −23% |
  | 130 | 36.4 | 3.35 | −28% |
  | 161.6 | 45.6 | 3.03 | −34% |

  This is the engine-out disturbance torque. EL gives the purpose as reducing sensitivity to thrust-vector misalignment (paraphrase); an engine-out rationale is physically plausible but unsourced.
- **Travel.** On the radial reading, the cant uses 1.41° of each actuator's ±5°, so control travel toward the cant side falls to 3.59°.

**Engine clocking and the pitch plane**

| id | chosen | source | conf | notes |
|---|---|---|---|---|
| engine_numbering | Engine *n* sits under fin *n* (1 = A, 2 = B, 3 = C, 4 = D); 5 is the centre. Opposite pairs are 1–3 and 2–4. | Oik (citing TN D-5399 diagrams); collectSPACE (SA-500F photo); HR (from R-3896-1) | M-H | The S-II numbering is "basically the same" (HR). Ignition order 5, 1–3, 2–4 at about 0.3 s intervals (secondary). |
| positions | I–IV lie midway between fins (Position II between fins A and B). Letters and numerals run anticlockwise seen from above. | Oik; HR | M | |
| pad_orientation | Tower to the north. Position I faces east (downrange for the 90° pad azimuth), II north (tower), III west, IV south (Mobile Service Structure side). | Oik; Popular Science; MSS geometry | M | Photographs from the press site show the tower on the north side. |
| saturn_axes | +X along the axis toward the nose; +Z toward Position I; +Y toward Position IV (right-handed). Roll is about X, pitch about Y, yaw about Z. The pitch plane is X–Z (I–III) and the yaw plane X–Y (II–IV). | CSS; Astrionics System Handbook; Oik | M | Popular Science's pitch-axis naming contradicts CSS and is rejected. |
| orbitsim_mapping | Saturn (X, Y, Z) = OrbitSim (x, y, z), one to one. After pitch-over, Position I (+z) faces the ground. | derived (both researchers and the verifier) | M | Same handedness. The roll program is a **positive** roll about +x of 17.942° (Position I from azimuth 90° to 72.058°). The tilt toward downrange is a rotation about **−y** (nose toward +z), i.e. negative in `RotationCommand.pitch`. The tower-clearance yaw is toward +y (south, away from the tower), positive yaw. |
| flight_azimuth | 72.058° | SP4029 ("rolled from a launch pad azimuth of 90° to a flight azimuth of 72.058°"); FER text; AFJ | **H** | Upgrades §1.6 from "recalled, L". |

Engine positions in the vessel frame (y, z), with d = r/√2: d = 3.269 m for the F-1 (r 4.623 m, L) and 1.886 m for the S-II J-2 (r 2.667 m, M).

| engine | fin | between positions | on the pad | (y, z) | `cluster(...)` before item 2 |
|---|---|---|---|---|---|
| 1 | A | I–II | NE | (−d, +d) | (+d, −d): **swapped with 3** |
| 2 | B | II–III | NW | (−d, −d) | matches |
| 3 | C | III–IV | SW | (+d, −d) | (−d, +d): **swapped with 1** |
| 4 | D | IV–I | SE | (+d, +d) | matches |
| 5 | — | centre | — | (0, 0) | matches |

The swap matters only for engine-out tests and display. Separately, the flight tests call `placeLanded(..., azimuth: 72)`, which points −z downrange and so puts Position III downrange. For Saturn-consistent signs, place the stack with azimuth 270 (+z, Position I, east on the pad) and command the +17.942° roll program. Alternatively, use 252.058 for the post-roll orientation. Tests that are symmetric in engine number are unaffected.

**Recommended sim actuator model (not data).** For each gimballed engine, use two projected deflection angles:

- δp: the thrust vector projected on the x–z plane;
- δy: the thrust vector projected on the x–y plane.

The thrust direction (force on the vehicle) is normalise(1, −tan δy, tan δp). Positive δp gives a positive (nose toward −z) pitch torque and positive δy a positive yaw torque.

Each axis is a rate-limited position servo: |δ̇| ≤ the rate above, |δ| ≤ the per-axis limit, with the limit applied to the command plus the cant bias. No servo lag, no load resonance, no engine inertia. The control bandwidth is 0.08–0.17 Hz (§7.2), far below any plausible servo bandwidth, so the lag is immaterial to every §7.4 target.

### 7.2 Flight-control laws

**Control law and gains**

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| fcc_law | β = −(a0·e + a1·ω) per axis | β_c = a0·H0(s)·ψ + a1·H1(s)·ψ̇ | EL; TN5869; Astrionics System Handbook | H (form) | e is the attitude error from the LVDC: the small-angle rotation from commanded to actual attitude, in body axes. ω is the body rate from the IU rate gyros. Proportional-derivative only: no integral term. H0 and H1 are bending filters (first bending mode ≈ 1 Hz, EL, L). Omit them, since the sim has no bending. |
| accelerometer_feedback | g2 = 0 | "deleted from the Saturn V" | EL; TN5869 | H | Accelerometer load relief flew on Saturn IB only. |
| gain_switching | discrete steps at preset times (switch-selector commands from time-base sequencing; no sensing) | — | EL; TN5869 | H (mechanism) | The AS-506 switch times were not found. |
| sic_gains_0_105 | a0 0.9, a1 0.69 s | deg/deg, deg/(deg/s) | TN5869 Table 3 | M (reading), L (AS-506) | TN5869 calls them "typical". The time reference is presumably liftoff. |
| sic_gains_105_130 | a0 0.45, a1 0.44 s | | TN5869 | M (reading), L (AS-506) | Conflicts with EL's "single switchpoint" at 100 s. |
| sic_gains_130_cutoff | a0 0.32, a1 0.30 s | | TN5869 Table 3 (page image, §8) | H (reading), L (AS-506) | Corrected in §8: an earlier extract had the pair swapped (0.30 / 0.32). |
| sii_gains | 0–60 s: 1.12 / 1.9 s; 60–190 s: 0.65 / 1.1 s; 190 s–cutoff: 0.44 / 0.74 s | (a0, a1) | TN5869 Table 3 "Second Stage Propulsion Period" (page image, §8) | H (reading), L (AS-506) | The IU switches them at T3 + 61.4 and T3 + 191.4 s (SA-507 ICD, §8). |
| sivb_gains_burn1 | a0 0.81, a1 0.97 s | | TN5869 Table 3 (page image, footnote "Throughout S-IVB first burn and to 260 seconds of second burn"); REF504 Table 3-IV (0–600 s, §8) | L | The page image settles the stage assignment that the garbled text extract left open. It still conflicts with TN5869's third-stage control frequency of 0.2–0.5 Hz (see the check below), so the IU leaves the S-IVB J-2 on the vehicle's own law (§8.6). |
| sivb_gains_burn2 | 0–260 s: a0 0.81, a1 0.97 s (the burn-1 pair); 260 s–cutoff: a0 0.81, a1 0.70 s | | TN5869 Table 3 (page image) | L | M2 only. An earlier text extract read 0.70 / 0.81 for the first 260 s. |
| roll_gains | S-IC (both bands): a0 0.245, a1 0.15 s; S-II (all three bands): a0 0.25, a1 0.20 s; S-IVB "not simulated" | (a0, a1) | Boeing D5-15481-1, *Saturn V AS-504 Launch Vehicle Reference Trajectory* Vol. I (1967), Table 3-IV (§8) | L (AS-504 1967 values) | The only roll gains found. Its §3.5 adds an S-IC roll attitude-gain filter 2.35/(s + 2.35), modelled since §13. With FER Table 20-10's roll inertia and the filter the roll program peaks at 1.24°/s, against AS-506's 1.38°/s, which carries an oscillation the model lacks (§13.3); the earlier match came from a roll inertia 9.5 times too large. |
| lvdc_minor_loop | 0.04 s (25 Hz) | about 25 times per second; 40 ms interrupt | TN5869; Wikipedia LVDC | M-H | Attitude-error update rate. The FCC itself is analogue, so rates are continuous. |
| bending_mode_1 | ≈ 6.3 rad/s | ≈ 1 Hz | EL | L | Context only. |

**Consistency of the gains with the sim (derived, no aero).**

- Control effectiveness is c = N·F·L/I. N·F is the gimballed thrust: 4 outboard engines, or the single S-IVB J-2. L is the gimbal-to-CoM distance and I the pitch inertia, both taken from the sim.
- The closed-loop rigid-body response then has ωn = √(a0·c), ζ = a1·c/(2ωn), and a steady ramp-tracking lag of (a1/a0) × rate.

| point (t) | c (s⁻²) | gains | f_n (Hz) | ζ | lag (s) | α at full deflection (°/s²) |
|---|---|---|---|---|---|---|
| S-IC release (0.30) | 0.784 | 0.9 / 0.69 | 0.134 | 0.32 | 0.77 | 3.9 |
| S-IC max Q (83.0) | 1.086 | 0.9 / 0.69 | 0.157 | 0.38 | 0.77 | 5.4 |
| S-IC 105, band 1 → 2 | 1.270 | 0.9 → 0.45 | 0.170 → 0.120 | 0.41 → 0.37 | 0.77 → 0.98 | 6.3 |
| S-IC 130, band 2 → 3 | 1.690 | 0.45 → 0.32 | 0.139 → 0.117 | 0.43 → 0.34 | 0.98 → 0.94 | 8.4 |
| S-IC OECO (161.6) | 3.369 | 0.32 / 0.30 | 0.165 | 0.49 | 0.94 | 16.8 |
| S-II ignition (164.0) | 0.366 | 1.12 / 1.9 | 0.102 | 0.54 | 1.70 | 2.6 |
| S-II +60 s, band 2 | 0.427 | 0.65 / 1.1 | 0.084 | 0.45 | 1.69 | 3.0 |
| S-II CECO (460.6) | 1.188 | 0.44 / 0.74 | 0.115 | 0.61 | 1.68 | 8.3 |
| S-II OECO (548.0) | 2.675 | 0.44 / 0.74 | 0.173 | 0.91 | 1.68 | 18.7 |
| S-IVB ignition (552.2) | 0.636 | 0.81 / 0.97 | 0.114 | 0.43 | 1.20 | 4.4 |
| S-IVB cutoff (699.3) | 0.770 | 0.81 / 0.97 | 0.126 | 0.47 | 1.20 | 5.4 |

*These figures and the inputs below predate §13's mass characteristics (the J-2 gimbals within ±1 m, the stages' CGs at their parts' middles, the liquid in the roll inertia); §13.3 gives the S-IC's and the S-IVB APS's anew.*

Sim inputs used for the table:

| quantity | values |
|---|---|
| Iyy (kg m²) | 9.758e8 at release, 4.294e8 at S-IC OECO, 1.321e8 at S-II ignition, 3.42e7 at S-II OECO, 1.311e7 at S-IVB ignition, 1.201e7 at insertion |
| CoM height (m) | 33.08 at release, 51.07 at S-IC OECO, 60.20 at S-II ignition, 76.06 at S-II OECO, 80.94 at S-IVB ignition, 81.96 at insertion |

Findings:

1. **S-IC.** TN5869's schedule keeps the sim between 0.11 and 0.17 Hz, consistent with TN5869's "≈ 0.15 Hz" first-stage frequency. The steps at 105 s and 130 s are what hold it there. This supports the TN5869 gains, the sim inertia and the 5.461 m gimbal plane together (L-M).
2. **S-IVB.** The 0.81/0.97 pair gives 0.11–0.13 Hz. Reaching 0.2 Hz would need a0 ≈ 2.0–2.5, and 0.5 Hz would need a0 ≈ 13–16. Either the pair is not the S-IVB burn-1 gain, or TN5869's 0.2–0.5 Hz covers TLI, where c rises as the stage empties. Unresolved (§7.5). *(Before §13's mass characteristics.)*
3. **Rate demand.** At these frequencies, actuator rates in response to 1° errors are below 1°/s, far from the 5–8°/s limits. Rate limits matter only for staging transients and engine-out.

**Limits and command constraints**

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| fcc_output_limits | the §7.1 per-axis actuator limits | — | §7.1 | L (F-1), M (J-2) | No separate FCC command limit was found. |
| guidance_rate_limit_pitch_yaw | 0.017453 rad/s | "guidance-command angle rate shall not exceed one degree per second in pitch and yaw" | GE504 | M | SA-504 document. Applies to the tilt program and upper-stage guidance. IU item. |
| roll_program_rate | 0.017494 rad/s (derived) | 17.942° in 17.9 s, 13.2 → 31.1 s | SP4029, TL (inputs H/M); derived | M | Consistent with a 1°/s rate-limited roll command, but not proof of a roll limit. Model it as a +1°/s ramp from 13.2 s until 17.942° is reached at 31.14 s. |
| guidance_yaw_cmd_limit | 0.7854 rad | "shall not exceed 45" (unit assumed) | GE504 (truncated) | L | IU item. |
| powered_attitude_error_limits | not found | — | — | — | The LVDC/LVDA ladder limits in powered flight are a gap. Do not invent a clip for the boost stages. |
| aps_deadband | ±0.017453 rad, each axis | ±1° (2° effective band) | EH 8.30; ASTP SA-210 report (Saturn IB) | M | Whether it also applies to roll-only control during J-2 burns is not stated. |
| aps_error_limits | ±0.04363 rad pitch/yaw; ±0.06109 rad roll | ±2.5° / ±3.5° | EH 8.30 | M | They clip the error entering the APS phase-plane logic, which bounds the manoeuvre rate. |
| aps_switching_line | K = 5 s | the typical dead-band lines cross ±1° at zero rate and ±0.2°/s at zero error | Astrionics System Handbook §3.4, Figures 3.4-5 and 3.4-6 (§13) | M | Fire when e_clip + K·ω exceeds the deadband. K = 5 s was a placeholder until §13 found it to be the handbook's typical slope. This gives manoeuvre rates of about 0.3°/s in pitch/yaw and 0.5°/s in roll. No hysteresis. |
| aps_min_impulse | 33.36 N·s | 7.5 lbf·s minimum impulse bit, required | APS-TN | M-H | 51 ms at 147 lbf (derived). The "≈ 70 ms" minimum pulse (EH 8.30, L) is a command width. With the 0.02 s integrator, use a 0.06 s minimum on-time at full thrust: 39.2 N·s, 18% above the requirement. |
| eds_roll_overrate | 0.3491 rad/s | 20°/s | EDS (two sources) | M | Abort-monitor limit, not a control parameter. |
| eds_pitch_yaw_overrate | 0.0524–0.0698 rad/s early in boost | 3, 4 or 5°/s; about 9°/s later | EDS | L | Sources disagree. Use only as a sanity bound. |

**Roll distribution**

- **S-IC and S-II: differential outboard deflection** (MBC; Bramlet; TIS-501). The FCC summing equations were not found. A derived mixing that decouples the axes exactly, for engine i at (yi, zi) with r = √(yi² + zi²):
  - δp,i = βp + (yi/r)·βr − (zi/r)·κ
  - δy,i = βy + (zi/r)·βr + (yi/r)·κ
  - Here βr is the tangential (roll) deflection, κ the radial outboard cant, and engine 5 stays at 0.
  - Torques: τy = 4·F·L·βp, τz = 4·F·L·βy, τx = 4·F·r·βr. The cant adds no net torque.
  - On the diagonals each roll and cant term splits 1/√2 per actuator. Whether the real roll gain is defined per actuator or tangentially only rescales the roll gain by √2.
- **S-IVB.** The J-2 gives pitch and yaw only. Roll comes from the APS in roll-only mode during burns (APS-TN; EH 8.30).

**What the TVC item should implement now**

1. **Remove the stand-ins.** Delete the TVC stand-ins on the S-IC, S-II and S-IVB (`addTVCStandIns`, `AS506.*StandInThrust`).
2. **Gimballed thrusters.**
   - Give each gimballed thruster two projected deflection axes with limits and rate limits as in §7.1, applied about the gimbal point (`Thruster.position`). Centre engines stay fixed.
   - S-II engines are held at null until S-IC/S-II separation (162.30), and the S-IVB J-2 until S-IVB ignition (552.20).
3. **FCC.**
   - PD law with g2 = 0 and no bending filters.
   - Attitude error sampled and held at 25 Hz (every second 0.02 s step); body rates continuous.
   - Gains as data per stage with discrete switch times: S-IC from liftoff (0.63), S-II from 164.0, S-IVB from ignition.
   - Roll gains as a labelled placeholder.
4. **Mixing as above** for the S-IC and S-II.
5. **S-IC cant.** Ramp in the bias at 20.6 s (placeholder ramp rate) and hold it to OECO.
6. **APS (§7.3).** Thrusters, tanks, roll-only mode during J-2 burns, and three-axis phase-plane control in coast (deadband, error clip, K, minimum on-time; K is the Astrionics System Handbook's typical value since §13).
7. **Command source.** An interface that takes a commanded attitude (or attitude and rate) from a simple source: hold the current attitude, or a test-supplied profile. The IU item then plugs into it.

**What to leave for the IU item**

- The time-tilt pitch program, the roll program and the tower-clearance yaw (1.7–9.7 s, toward +y; its angle is not in the inputs, recalled ≈ 1.25°, L).
- Tilt arrest and IGM.
- The 1°/s guidance command-rate limit and the 45° yaw-command limit.
- Time bases, and switch-selector timing of the gain switches and the cant. Range-time triggers are fine for now.
- APS mode switching by time base (TB5/TB6) and the ullage-burn sequencing.
- The EDS overrate monitor (abort item).

### 7.3 S-IVB APS

**Layout and engines**

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| aps_modules | 2 self-contained modules, 180° apart on the aft skirt | — | APS-TN; EH 8.30; NASM | H | Each module has its own oxidizer, fuel and helium. Spaceline's "80 degrees" is a typo. |
| aps_module_positions | Positions I (+z) and III (−z) | — | inferred from the role split; recalled from MAN503 | L | One radial pitch engine and two tangential roll/yaw engines per module only work with the modules in the pitch plane (I–III). |
| aps_module_location | h ≈ 73.4 m; nozzle radius ≈ 3.5 m | — | §4 estimate | L | Unchanged. The S-IVB skin radius is 3.302 m. |
| aps_attitude_engines | 3 per module (TRW TR-204), 6 in all | — | APS-TN; EH 8.30; NASM | H | |
| aps_attitude_thrust | **653.9 N** each | 147 lbf "operate at" (150 lbf nominal) | APS-TN (two extracts) | M | **Replaces** the §1.3 and §3 value of 667.2 N (150 lbf nominal); the difference is 2.0%. Vacuum basis implied. |
| aps_roles | per module: 1 pitch + 2 roll/yaw | "two control roll and yaw, while one controlled pitch" | APS-TN; EH 8.30 | M | Wikipedia's "2 roll/pitch + 1 yaw" is rejected. AS-501 data hint that engines 1 and 3 of a module are roll/yaw, 2 is pitch and 4 is ullage (L). |
| aps_ullage_engines | 1 per module (Rocketdyne SE-7-1), 2 in all | — | APS-TN; EH; NASM | H | Thrust along +x (nozzle aft). Separate from the 2 solid TX-280 motors fired at S-II/S-IVB separation. |
| aps_ullage_thrust | 320.3 N each | 72 lbf "operated at" (70 lbf nominal) | APS-TN; NASM; collectSPACE | **H** | Upgraded from M. 70 lbf (EH, Wikipedia, MAN503) is the rounded rating. |
| aps_min_pulse | ≈ 0.07 s command | "about 70 ms" | EH 8.30 | L | See aps_min_impulse (§7.2). |
| aps_engine_life | 300 s cumulative per attitude engine (design) | 5 min | NASM | L | Design duty limit. |
| tr204_mass | 12.0 kg each | 26.5 lb; 15.5 in long, 6.5 in nozzle | RR Auction | L | Ablative silica-phenolic chamber; quad-redundant valves. |

**Thruster directions in the vessel frame (inferred, L)**

Module I is at (x_a, 0, +r) and module III at (x_a, 0, −r), with r ≈ 3.5 m and x_a at h ≈ 73.4 m. Forces are on the vehicle.

| module | engine | force direction | OrbitSim groups | torque |
|---|---|---|---|---|
| I | pitch | −z (exhaust radially out) | pitchDown | −F·L_a about y |
| III | pitch | +z | pitchUp | +F·L_a about y |
| I | roll/yaw a | −y | rollRight, yawRight | +F·r about x; +F·L_a about z |
| I | roll/yaw b | +y | rollLeft, yawLeft | −F·r; −F·L_a |
| III | roll/yaw a | +y | rollRight, yawLeft | +F·r; −F·L_a |
| III | roll/yaw b | −y | rollLeft, yawRight | −F·r; +F·L_a |
| I, III | ullage | +x | (APS ullage; not a rotation group) | none |

L_a is the CoM height minus 73.4 m. Pure roll fires I-a with III-a; pure yaw fires the two same-direction engines; pitch fires a single engine. Nozzle cant angles were not found, so the directions are purely radial and tangential.

Authority at insertion in the sim (L_a 8.56 m, Iyy 1.201e7, Ixx 5.856e5 kg m²):

| axis | engines | torque (N·m) | angular acceleration (°/s²) |
|---|---|---|---|
| pitch | 1 | 5,600 | 0.027 |
| yaw | 2 | 11,200 | 0.053 |
| roll | 2 | 4,577 | 0.45 (0.35 at S-IVB ignition) |

**Propellants and pressurant**

| id | chosen (SI) | original | source | conf | notes |
|---|---|---|---|---|---|
| aps_n2o4_total | 184.16 kg | 406.0 lbm, both modules | FER Table 7-5, AS-506 (§13) | H | Was FER-507's 405 lbm (183.70 kg), an AS-507 proxy, before §13. |
| aps_mmh_total | 114.31 kg | 252 lbm | FER Table 7-5, AS-506 (§13) | H | The same as FER-507's. |
| aps_per_module | N2O4 92.079 kg + MMH 57.153 kg | 203.0 + 126.0 lbm | FER Table 7-5, AS-506 (§13; the AS-507 proxy 202.5 + 126 lbm, an equal split, before) | H | |
| aps_load_ratio | 1.611 | 203 / 126 | derived | M | The loaded ratio. Use it as the feed mixture ratio, so that both tanks deplete together. The engine operating MR was not found. |
| aps_wikipedia_load | **rejected** | 150 lb N2O4 + 115 lb MMH per module (O/F 1.30) | Wikipedia | — | Twice it (530 lb) contradicts the FER's 658 lb (Table 7-5). |
| aps_helium | 21.37 MPa gauge bottle; regulator 1.351 MPa (196 psia), backup 1.379 MPa (200 psia) | 3,100 psig; 196 / 200 psia | APS-TN | M-L | FER-507 tank ullage pressures of 188–194 psia support the regulator value. Helium mass and bottle volume not found: keep them in dry mass. |
| aps_module_dry_mass | not found | — | — | — | Stays in the S-IVB stage dry mass. |
| aps_isp_attitude | **245 s effective** (2,403 m/s) | AS-201 flight averages 237 and 250 s (pulse losses included) | AS201 | L | **Replaces the 290 s placeholder** for the TR-204, since the sim's pulses deliver full thrust for their duration. AS-201 is a Saturn IB with a different APS and no ullage engines. No steady-state or pulse Isp was found for the TR-204. |
| aps_isp_ullage | 290 s (placeholder) | — | none | L | Steady burns. Unsourced; kept from §3. |

**How the APS propellant relates to "sivb_other" (1,656 lb, 751.1 kg).**

- **What is in the row.** AS-506's 658 lb of APS propellant (FER Table 7-5) plus the 117.4 lb (53.25 kg) of TX-280 solid propellant leaves 880.6 lb (399.4 kg) for helium (APS and stage), solid-motor cases and other items. The row is therefore not contradicted.
- **What to move.** Take 658 lb (298.46 kg) out of the S-IVB part's dry mass into four point tanks: per module, N2O4 92.079 kg and MMH 57.153 kg, at Positions I and III, h 73.4 m, r 3.5 m.
  - The S-IVB dry mass becomes 24,852 + 1,656 − 658 = **25,850 lb (11,725.4 kg)**.
  - §2.1's S-IVB dry_sim becomes 35,837 − 658 = **35,179 lb (15,956.9 kg)**.
  - The part total stays 119,119.3 kg and the ignition total 2,938,314.7 kg.
- **TX-280 propellant.** Leave the 117.4 lb in dry mass until the ullage-motor item models the TX-280s as solid thrusters on the S-IVB (§3). *Done in §12: the FER's 53 kg of grain and 61 kg of cases are on their own part.*
- **Usable versus loaded.** Not known. Set unusable to 0 (L).

**When each function is active**

| phase | t (s) | J-2 TVC | APS attitude | APS ullage | source / conf |
|---|---|---|---|---|---|
| S-IC and S-II boost | 0.30 – 549.0 | J-2 at null | inactive (roll by the S-IC/S-II engines) | off | EH 8.30 / M |
| S-II/S-IVB separation | 549.0 – 552.2 | null | roll (assumed from separation; not stated) | off; TX-280 solids fire | L |
| S-IVB burn 1 | 552.20 – 699.33 | pitch, yaw | **roll only** | off | APS-TN ("roll control during J-2 powered phases"); EH / H |
| first cutoff (TB5) | 699.33 | off | pitch and yaw enabled: three axes | on for **88 s** (to 787.3); AS-506: 86.7 s, T5 + 0.3 to T5 + 87.0 (FER Table 2-2, §8.3) | MAN503; EH ("1:28 minutes") / L-M (nominal SA-503 sequence); FER / H for AS-506 |
| parking orbit | 787 – ≈ 9,779 | — | three axes, ±1° deadband | off | EH / M |
| before restart (TB6) | ≈ 9,779 – 9,856.2 | — | three axes | on ≈ 77 s (fact sheet) or "≈ 1 minute" (EH) | L |
| TLI (M2) | 9,856.20 – 10,203.03 | pitch, yaw | roll only (pitch and yaw drop out at restart) | off | EH / M |
| post-TLI (M2) | — | — | three axes: transposition and docking hold, LM extraction | slingshot disposal burn (with LOX dump and LH2 vent) | FER summary; SP4029 lead (≈ 280 s burn, unverified) / L |

### 7.4 Validation targets for tests

**What the sim can reproduce once the TVC item is done.**

- Masses, inertias and the CoM, from the current model.
- Gimballed thrust, the FCC law and the APS.
- **Not** aerodynamic normal force or moments (separate M1 item).
- **Not** winds, thrust misalignment, CoM offsets, slosh or bending.
- **Not** guidance (IU item).

Every published control-performance figure (FER maximum deflections, attitude errors and rates at max Q and staging) is driven by those missing effects, so tests must not use them yet.

**A. Hardware, mixing and cant (static or one step; exact)**

| target | value | tolerance | depends on |
|---|---|---|---|
| per-axis clamp | F-1 ±0.08727 rad (outboard only); J-2 ±0.12217 rad (S-II outboard, S-IVB); centre engines never move | exact | §7.1 data (F-1 L, J-2 M) |
| rate limit | 5°/s F-1; 8°/s S-II; 8°/s S-IVB placeholder | per step | data L / M-L / placeholder |
| decoupling | unit βp, βy or βr gives torque only about its axis | off-axis below 1e-6 of on-axis | mixing geometry |
| torque per deflection | τy = 4·F·L·sin β (S-IC, S-II), F·L·sin β (S-IVB), with the sim's own F, L and I. Sim α at full deflection: 3.9 / 2.6 / 4.4 °/s² at release / S-II ignition / S-IVB ignition (before §13) | 0.5% against the formula | formula only: L depends on L-graded gimbal heights, so never compare with a published inertia |
| cant geometry | after the ramp, each outboard thrust line is 2.000° inward (radial), the net lateral force and torque are 0, axial thrust is × 0.99939, and the start is at 20.6 s | 1e-6; start ± one step | cant axis definition (L); ramp shape is a placeholder, so test only the end state |
| null holds | S-II engines at 0 until 162.30; S-IVB J-2 at 0 until 552.20 | exact | EH (M) |

**B. Closed-loop behaviour (sim, no aero)**

| target | published | sim expectation | tolerance | depends on |
|---|---|---|---|---|
| S-IC rigid-body control frequency | ≈ 0.15 Hz (TN5869) | 0.134 Hz at release, 0.157 at max Q, 0.11–0.17 across bands | 0.10–0.20 Hz | TN5869 gains (L), sim L and I (L). Aero would lower it near max Q, so the band applies only to the no-aero sim. |
| step response, S-IC at about 5 s | — | ωn 0.84 rad/s, ζ 0.32: first peak 3.95 s, overshoot 35% for a 0.5° attitude-command step | ±10% on time; ±5 points on overshoot | self-consistency of law, gains and mass properties. Keep the step at or below 0.5°: the command jumps by a0 × step (0.45°), so the 5°/s rate limit binds for under 0.1 s and the position limit never. |
| ramp-tracking lag | — | (a1/a0) × rate: 0.77° at 1°/s (S-IC band 1), 1.70° (S-II band 1), 1.20° (S-IVB) | ±0.05° once settled | self-consistency. It holds exactly only with no disturbance torques, which is the case in the sim. |
| kick damping | — | a 0.29°/s pitch and yaw kick after liftoff decays to below 0.015°/s within about 3 envelope time constants: 1/(ζωn) = 3.7 s, so about 11 s | factor 1.5 | same; replaces the stand-in test `testKillRotationDampsAKickWithTheStandIns` |
| deflection in nominal no-wind flight | FER values unusable | below 1° except during command-rate changes and staging | sanity | no aero or misalignment, so any large deflection is a bug |
| S-IVB control frequency | 0.2–0.5 Hz (TN5869) | 0.11–0.13 Hz with 0.81/0.97 (before §13) | **do not test** | §7.5 conflict |

**C. Commanded manoeuvres** (the test supplies the command profile until the IU item exists)

| target | published | sim expectation | tolerance | depends on |
|---|---|---|---|---|
| roll program | roll from 90° to 72.058° azimuth, 13.2 → 31.1 s (SP4029, TL: H/M); +1°/s ramp, derived | superseded by §8.6 and §8.8: the IU flies it with D5-15481-1's roll gains (lag 0.61° late in the ramp, peaks against FER Table 11-2) | see §8.8 | the roll gains (L) |
| roll direction and sign | Position I swings from east toward north | positive rotation about +x | exact | §7.1 mapping (M); needs Saturn-consistent placement (azimuth 270) |
| no EDS overrate in nominal flight | roll 20°/s (M); pitch/yaw 3–5°/s (L) | peaks about 1°/s | below 3°/s pitch/yaw and 20°/s roll | sanity only |

**D. APS (coast and S-IVB burn)**

| target | published | sim expectation | tolerance | depends on |
|---|---|---|---|---|
| thruster geometry | roles: APS-TN, EH (M) | each engine's torque has the sign of its group; roll pairs give no yaw and yaw pairs no roll | exact | inferred directions (L) |
| roll authority | — | 2 × 653.9 N × r = 4,577 N·m at r = 3.5 m | formula | r (L) |
| TB5 ullage burn | 88 s, 2 × 72 lbf (MAN503, EH; APS-TN); AS-506 flew 86.7 s (FER Table 2-2, §8.7) | Δv = 0.4173 m/s at the sim's 135,093 kg (0.4155 at the FER-OCR 135,669); propellant = 2·F·88/(Isp·g0) = 19.8 kg at 290 s; both × 86.7/88 for AS-506's burn, which the IU flies | ±0.5% on Δv; propellant formula only | thrust (H), duration (H for AS-506). Never test the Isp. |
| effect on the parking orbit | — | the 88 s burn raises a by ≈ 0.70 km and the period by ≈ 0.85 s after insertion | — | Compare §5's parking-orbit targets at insertion (709.33 s), or allow for this. It is within §5's ±2 km and ±6 s. |
| coast attitude hold | ±1° deadband (EH, M) | with a 0.1°/s disturbance, error stays within ±(1° + one minimum-impulse overshoot); roll Δω per minimum-impulse pair 0.078°/s with FER Table 20-10's roll inertia (0.026–0.027°/s before §13) | ±1.1° | deadband (M); switching line M (§13); minimum on-time derived |
| roll-only mode during the S-IVB burn | APS-TN (H) | a roll-rate kick is removed by the APS; APS pitch and yaw thrusters stay off; the J-2 carries pitch and yaw | exact on the inhibits | phase logic only |
| propellant bookkeeping | FER Table 7-5, AS-506 (§13) | APS tanks 298.46 kg; S-IVB part total unchanged at 119,119.3 kg; ignition total unchanged | ±1 kg | §7.3 accounting |

**E. Deferred** (they need the AS-506 FER read, plus aero normal force, winds, guidance and possibly slosh)

- FER control tables:
  - "Maximum Control Parameters" during S-IC burn, S-II burn, S-IVB first burn and S-IVB second burn: attitude errors, rates and average engine deflections per axis, at liftoff, Mach 1 to max Q, CECO, OECO and staging.
  - "S-IC Engine Deflection Response to Propellant Slosh".
  - Pitch- and yaw-plane winds and angle of attack.
  - The pitch-arrest time.
  - The S-IC/S-II and S-II/S-IVB separation transients.
- FER APS data: "S-IVB APS Propellants Remaining Versus Range Time" (modules 1 and 2), and APS ullage start and stop times (TB5, TB6). FER-507 Table 7-4 is the AS-507 equivalent.
- Pitch (tilt) program rates: not found; the IU item will test them against the 1°/s command limit.

### 7.5 Remaining conflicts, gaps, and values tests must not depend on

**Changes to §1–§6 that this section implies**

- **§1.2.** Outboard cant at 20.6 s: L → M, angle ≈ 2° (M).
- **§1.3.**
  - f1_gimbal_limit: "M / L" → L, defined per actuator axis.
  - j2_gimbal_limit: the S-IVB value is now found (±7° per axis, M).
  - aps: attitude engines 653.9 N (147 lbf, M); ullage 320.3 N (H).
  - APS loads: AS-506's 203/126 lbm per module (FER Table 7-5, since §13), O/F 1.611.
- **§1.6.** Flight azimuth 72.058°: recalled L → H.
- **§2.1.** S-IVB dry_sim 35,179 lb plus APS tanks 658 lb (AS-506's, §13).
- **§3.** APS rows:
  - attitude 653.9 N at 245 s effective Isp (0.2722 kg/s);
  - ullage 320.3 N at 290 s (0.1126 kg/s), unchanged;
  - feed MR 1.611 (AS-506's loads, §13).
- **§4.**
  - F-1 gimbal plane STA 100: L → M.
  - Outboard azimuths: engines 1–4 under fins A–D, 45° from the pitch plane (M). The builder's engines 1 and 3 were swapped (fixed in item 2).
- **§6.** Remove "flight azimuth (recalled)" and "F-1 outboard azimuth" from the must-not-depend list. The F-1 outboard radius stays L.

**Unresolved conflicts**

- **F-1 gimbal range:**
  - ±5° (EH 8.13) versus 5.25° "full travel" (EH 8.10) versus 6° (a cone per HR, per axis per apollomaniacs) versus 8°30′ (TM X-53532).
  - The per-axis nesting in §7.1 is an interpretation (L). ±5.15° appears in no source.
- **F-1 gimbal rate:** 5°/s versus 5.25°/s or 10.5°/s implied by "5.25° in 1 s". Loaded or no-load is unknown for every stage.
- **S-IC gain switches:** TN5869 has two switches (105 s, 130 s); EL says one switchpoint at 100 s. TN5869 calls its values "typical", not AS-506. *The SA-507 flight sequence ICD and the AS-508 timeline put FCC switch points 1 and 2 at T1 + 105.0 and 130.0 s (§8).*
- **S-II gain rows:** ~~the stage assignment is inferred from band edges.~~ *Resolved (§8): TN5869 Table 3 labels them "Second Stage Propulsion Period".*
- **S-IVB gains:** the 0.81/0.97 pair gives 0.11–0.13 Hz in the sim against TN5869's 0.2–0.5 Hz third-stage frequency. Either the pair or the frequency definition is misread. The S-IVB gimbal height (L, ±1 m) changes this by only ±5%. *(§13: the gimbal station is now sourced, H.)* *(Figures before §13's mass characteristics, which move the S-IVB's lever arm and inertia.)*
- **Cant axis:** 2° radial (1.41° per actuator) versus 2° per actuator (2.83° radial).
- **Cant purpose:** misalignment sensitivity (EL paraphrase) versus engine-out load relief (plausible, unsourced). The ramp rate and the hold-to-OECO are unknown.
- **APS:**
  - Engine roles: TN and EH versus Wikipedia.
  - Module Positions I and III: inferred.
  - Thrust 147 versus 150 lbf (operating versus nominal) and 72 versus 70 lbf (resolved the same way).
  - Loads: the FER (AS-506's Table 7-5 since §13) versus Wikipedia (rejected).
  - Isp: 290 s placeholder versus the AS-201 237/250 s averages.
  - Minimum impulse: the 7.5 lbf·s requirement versus 70 ms × full thrust (46 N·s).
  - Pre-restart ullage: 77 s versus "≈ 1 minute".
- **EDS pitch/yaw overrate:** 3, 4 or 5°/s (≈ 9°/s later).
- **Sim placement:** the flight tests' azimuth 72 (−z downrange) puts Position III downrange. This is harmless for symmetric tests but wrong for engine-out, APS-module and yaw-direction tests.
- **S-IVB J-2 gimbal height:** ~~71.7 m (L) lies below the S-IVB part's aft end at 72.68 m (§4; L).~~ *Resolved (§13): STA 2645.85, h 70.13 m (REF504 Figure 3-1, H), inside the aft interstage as on the real vehicle.*

**Gaps (next research turn, highest value first)**

1. AS-506 FER control-system section (the tables listed in §7.4 E), the FCC gain-switch and cant times in the sequence-of-events table, and the APS consumption figures.
2. MSFC-MAN-503/506 flight-control and APS sections:
   - FCC summing (mixing) equations and roll gains;
   - S-IVB burn gains;
   - APS phase-plane hysteresis and minimum pulse (the switching line is the Astrionics System Handbook's typical one, §13);
   - powered-flight attitude-error limits;
   - APS module positions, stations and nozzle cant;
   - ~~J-2 gimbal stations (S-II and S-IVB).~~ *Found (§13): REF504 Figure 3-1.*
3. A clean read of TN5869 Table 3 (all stages and time references).
4. Primary F-1 gimbal limit, rate and pattern: SAE650304, TMX53532 Fig. 19, R-3896-1. S-IVB J-2 gimbal rate.
5. Actuator bandwidth and dynamic-pressure-feedback parameters. Gimballed mass and inertia about the gimbal for the F-1 and J-2 (tail-wags-dog).
6. Cant ramp duration and axis definition.
7. TR-204 and SE-7-1 steady-state and pulse-mode Isp, and the operating mixture ratio. APS helium mass, module dry mass, and usable versus loaded propellant. ~~AS-506 APS loads per module.~~ *Found (§13): FER Table 7-5.*
8. Pitch-program rates and the tilt-arrest time (IU item).

**Values a test must not depend on**

- Every gain (TN5869 S-IC M as a reading but L for AS-506; S-II and S-IVB L); the roll gains (D5-15481-1, L); switch times.
- F-1 gimbal limit (±5°, L) and rate (L); S-II rate (M-L); the S-IVB rate placeholder; any actuator dynamics.
- Cant ramp rate and axis definition. The 2° angle and 20.6 s start (M) may be used only for the end state and the start time.
- J-2 gimbal heights (S-II and S-IVB), and therefore every absolute torque, control frequency or angular acceleration. Test formulas against the sim's own mass properties, not published inertias. *(§13: the J-2 gimbal stations are now sourced (H), and the vehicle's CG and inertias are tested against FER Table 20-10.)* *Since §13 the gimbal stations are H and the vehicle's CG and inertias are tested against FER Table 20-10.*
- APS module positions, radius, height, nozzle directions and cant. APS Isp (both values). APS switching-line K (M since §13) and minimum on-time. Per-module loads (equal split assumed) and the AS-507 proxy totals. *(§13: the per-module loads are now AS-506's, FER Table 7-5, H.)*
- APS pre-restart ullage duration; the slingshot burn duration (lead only).
- EDS pitch/yaw overrate thresholds, except as a loose sanity bound.
- TN5869's S-IVB 0.2–0.5 Hz control frequency.
- Any FER control-performance or APS-consumption value until the FER is read and the sim has aero normal force, winds and guidance.

---

## 8. IU flight program (M1 item 3, part 1: open loop)

Compiled on 2026-10-16 for the first half of the IU item: the flight sequence on the LVDC's time bases, the S-IC's open-loop attitude programs, the flight-control gain and cant schedules, the APS switching logic and orbital attitude. Iterative guidance (IGM) for the S-II and S-IVB is part 2 (§10). `Sources/OrbitCore/Vessel/AS506Data.swift` ("IU flight program") holds the values, and `SaturnIU.as506()` the sequence.

**Sources read directly** (for the first time in this datasheet; the network allowlist now includes ibiblio.org):

- FER: *Saturn V Launch Vehicle Flight Evaluation Report AS-506, Apollo 11 Mission*, MPR-SAT-FE-69-9 (ibiblio.org/apollo/Documents/lvfea-AS506-Apollo11.pdf, 280 pp). Table 2-1 (time bases), Table 2-2 (event times, actual and from the time base), Table 4-1 and 4-2 (trajectory events), Table 5-1 and Figure 5-3 (S-IC propulsion), §6 (S-II propellant utilisation), §10 and §11 (guidance, control). Read as text, with the tables checked against the page images.
- GE504: Boeing D5-15706-4, *Saturn V Launch Vehicle Guidance Equations, SA-504* (15 July 1967; ibiblio.org/apollo/Documents/SaturnVLaunchVehicleGuidanceEquations.pdf). Figure 1-1 (coordinate systems), §2.1.2 (command constraints), §4.1.2 and Table 4-II (pre-IGM guidance), §4.1.11 (orbital guidance), Table 5-I (presettings, read from the page images), Table 2-1 (SA-504 reference sequence).
- MAN506: MSFC-MAN-506, *Saturn V Flight Manual SA-506* (ibiblio.org/apollo/Documents/Saturn_V_Flight_Manual_SA-506.pdf). Figure 2-1 (AS-506 predicted critical events, 16 July 1969 window, 72° azimuth), Figure 2-2 (commanded pitch angle), §2 "Liftoff Clearance" (the yaw manoeuvre), §7 (IU flight program).
- ICD507: 40M33627B, *Definition of Saturn SA-507 Flight Sequence Program* (5 Dec 1967; ibiblio). FCC switch points; read from the page images.
- TN5869 Table 3, read from the page image of NASA TN D-5869 (ibiblio.org/apollo/Documents/tn_d-5869_1970023342.pdf).
- REF504: Boeing D5-15481-1, *Saturn V AS-504 Launch Vehicle Reference Trajectory*, Vol. I (15 May 1967; ibiblio), Table 3-IV (control gains, roll included) and §3.5 (filters).
- ASH: IBM, *Astrionics System Handbook, Saturn Launch Vehicles*, MSFC No. IV-4-401-1 (changed 15 November 1969; ibiblio.org/apollo/Documents/AstrionicsSystemsHandbook_Nov69.pdf). §3.1 and Table 3.1-3 (attitude constants: error limits and command rate limits by flight phase). Generic Saturn V, so M for AS-506.
- MAN503: MSFC-MAN-503, *Saturn V Flight Manual SA-503*, Figure 2-1. Context only.
- PFT: Boeing D5-15560-6, *Apollo/Saturn V Postflight Trajectory AS-506* (ibiblio.org/apollo/Documents/19920075301.pdf): Table B-II gives AS-506's postflight (reconstructed) trajectory in the LVDC's navigation frame, PACSS 13, every 1 s to 162 s and every 2 s after; it reproduces FER Table 10-2's postflight rows, not the LVDC's. Used for IGM (§10).

AS-506's own guidance presettings (its *Operational Trajectory* and *Flight Sequence Program* ICD 40M33626B, cited by the FER) were not found. GE504's SA-504 presettings stand in for the pitch polynomial and the program-start test, graded M as a proxy; MAN506 confirms the yaw command and suggests that AS-506's commanded pitch followed SA-504's polynomial (§8.4), which §14.1 refutes.

### 8.1 Frames and command conventions

| id | value | source | conf | notes |
|---|---|---|---|---|
| space_fixed_frame | X_S up (opposite local gravity at GRR), Z_S along the flight azimuth, Y_S completing a right-handed set; fixed at guidance reference release | GE504 Fig. 1-1 | H | Earth-centred, non-rotating. The model takes the plumb line at the pad at T1, opposite its J2 gravity plus the Earth's centrifugal term, and turns it back by the Earth's rotation over T1 − GRR = 17.60 s (0.065° in the vertical). On the model's WGS-84 Earth the stack stands along the normal at the geodetic 28.6084° and the plumb line is at 28.6082°, 0.161° north of the radial: AS-506's geodetic vertical, which X_S was, to the 0.0002° of J4 the model's gravity leaves out (§15). On the spherical Earth before §15, with the pad at the geocentric 28.447°, the plumb line was at 28.608° too. |
| euler_sequence | chi_Y (pitch), then chi_Z (yaw), then chi_X (roll), about the vehicle-fixed axes; positive counterclockwise | GE504 §5.1 symbol list | H | With Saturn (X, Y, Z) = OrbitSim (x, y, z) (§7.1), the pitch polynomial is negative downrange and the tower yaw positive towards +Y_S (azimuth 162°, away from the tower to the north). |
| initial_roll | chi_X = A_Z − 90° = −17.942° | GE504 Table 4-I | H | The model measures it from the stack's attitude at T1 (Position I east). |
| command_rate_limit | 1.0 deg/s on each of chi_X, chi_Y, chi_Z | GE504 §2.1.2, Table 5-I | H (SA-504), M (AS-506) | The AS-506 roll, 17.94° from T1 + 12.6 to T1 + 30.5 s (FER), is flown at this limit. |
| yaw_command_limit | 45° | GE504 §2.1.2 | H | Not reached in the S-IC programs; applied to the IGM's yaw command (§10), which stays within about 1°. |

### 8.2 Time bases (FER Table 2-1)

| base | range time (s) | started by | model |
|---|---|---|---|
| T0 | −16.97 | guidance reference release | fixes the space-fixed frame (T1 − 17.60 s) |
| T1 | 0.63 | IU umbilical disconnect | first motion + 0.33 s |
| T2 | 135.27 | S-IC CECO sensed by the LVDC | the step after the centre engine is cut (135.22) |
| T3 | 161.66 | S-IC OECO sensed | at LOX depletion, 161.64 (§9) |
| T4 | 548.24 | S-II OECO sensed | at LOX depletion, 548.24: the J-2s start at T3 + 2.4 = 164.04 s; from a 164.00 s start the S-II depletes at 548.16 s (§9.4) |
| T5 | 699.57 | S-IVB velocity cutoff sensed | the step after the IGM's velocity cutoff (§10): the cutoff at 702.74 (3.4 s after AS-506's 699.34), T5 at 702.76 (3.2 s after AS-506's) |

The model senses each cutoff one or two integration steps (0.02–0.04 s) after it; the LVDC took 0.03–0.23 s. When a time base starts, the IU drops the earlier bases' pending events, as the LVDC moved to the new base's switch-selector table.

### 8.3 Flight sequence used by the model

Offsets are vehicle time from the time base, from FER Table 2-2 unless marked; the last column is the FER's actual range time.

| event | base + offset (s) | FER range time (s) | notes |
|---|---|---|---|
| S-IC flight-control gains, band 1 | T1 + 0 | — | §7.2 schedule (TN5869, L); roll a0 0.245, a1 0.15 s throughout the S-IC (REF504, L) |
| tower-clearance yaw on | T1 + 1.0 | 1.7 | chi_Z = 1.25° at 1°/s, "starting at 1.39 seconds from first motion" (MAN506); GE504 the same |
| yaw command back to zero | T1 + 8.75 (GE504) | 9.7 (end of manoeuvre) | "ramped back to zero degrees 9 seconds later" (MAN506): at 1°/s the manoeuvre ends at T1 + 10.0, the FER's predicted end; the FER's actual T1 + 9.0 is "accurate to a major computation cycle". |
| roll and pitch programs | rise of 137 m, or T1 + 13.0 | 13.2 (T1 + 12.6; FER predicted 13.1, MAN506 11.9) | GE504 §4.1.2. The model reaches 137 m at T1 + 10.7 (§8.5). |
| S-IC outboard cant | T1 + 20.0 | 20.6 | 2° radial, 0.2°/s ramp (§7.1; ramp is a placeholder) |
| S-IC gains, bands 2 and 3 | T1 + 105.0, T1 + 130.0 | — | FCC switch points 1 and 2 (ICD507, M); band 3 is a0 0.32, a1 0.30 (TN5869 page image) |
| S-IC CECO | T1 + 134.56 | 135.20 | commanded by the IU (FER §5.1) |
| tilt arrest | T1 + 159.37 | 160.0 (T2 + 24.7; predicted T2 + 25.5; MAN506 T2 + 25.0) | SA-504's preset was 153.0 s. Part of the pitch program on T1, so it holds through T2. |
| S-IC OECO | LOX depletion | 161.63 | propellant model; the IU sets the throttle to 0 at T3 so the S-II does not light at separation |
| S-II ullage motors on | T3 + 0.5 | 162.1 | the four solids on the interstage, 3.75 s each (§9.2, §12) |
| S-IC retros | with the S-IC/S-II separation | — | lit by the separation, 0.05 s after it (§12) |
| S-IC/S-II separation | T3 + 0.7 | (command) 162.3 | |
| S-II ignition and gains, band 1 | T3 + 2.4 | 164.0 | engine solenoid activation: the J-2s' start ramp reaches mainstage at 166.2 s (§9.2); roll a0 0.25, a1 0.20 s throughout the S-II (REF504, L) |
| S-II ullage motors off | T3 + 4.4 | 166.1 | the FER's "burn termination" (thrust at 75 %); a log entry only: the model's solids have burned out at 3.75 s |
| S-II high EMR select | T3 + 6.9 | 168.5 | ESC + 5.5 s: the PU system takes the J-2s from their start setting (EMR 5.0) to high EMR (§9.2) |
| aft interstage jettison | T3 + 30.7 | 192.3 | |
| LET jettison | T3 + 36.2 | 197.9 | |
| IGM phase 1 | T3 + 42.4 | 204.1 (204.07, Table 10-4) | the IGM steers from here (§10) |
| S-II gains, bands 2 and 3 | T3 + 61.4, T3 + 191.4 | — | FCC switch points 3 and 4 (ICD507, page images; M) |
| S-II CECO | T3 + 299.0 | 460.6 | |
| EMR shift command | IGM (§10) | 494.8 (494.83, Table 10-4) | the IGM commands it when the S-II's characteristic velocity reaches its preset, and enters phase 2: 494.76 s in the model |
| S-II low EMR | shift command + 2.8 | 497.60 (PU valve step, FER Table 6-2; low EMR by 498.0) | §9.2; the FER's interval from the command (494.8) to the valve step; 497.56 s in the model |
| S-II OECO | LOX depletion | 548.22 | propellant model: 548.24 in flight (§8.2) |
| S-IVB ullage motors on | T4 + 0.7 | 548.9 | the two TX-280s, 3.87 s (§12) |
| S-II/S-IVB separation | T4 + 0.8 | (command) 549.0 | lights the four S-II retros, 0.04 s after it (§12) |
| IGM phase 3 (steering frozen) | IGM, first cycle after T4 | 548.2 (Table 10-4) | §10 |
| S-IVB ignition | T4 + 4.0 | 552.2 | STDV open; the start ramp reaches mainstage at 554.7 s (§9.2); the S-IVB J-2 flies the vehicle's own gains law (§7.2: TN5869's S-IVB pair is inconsistent) |
| IGM steering on the S-IVB | IGM, at 90 % thrust | 555.6 (555.57, Table 10-4: artificial tau) | §10 |
| S-IVB ullage case jettison | T4 + 12.8 | 561.0 | the TX-280s' 61 kg of cases (staging event 5, §12) |
| terminal guidance, chi freeze | IGM | 665.2, 691.6 (Table 10-4) | §10: 668.16 and 695.36 s in the model |
| S-IVB velocity cutoff | IGM (§10) | 699.34 | the model's 702.74 s, 3.4 s after AS-506's (§10.4) |
| APS ullage on | T5 + 0.3 | 699.8 | both engines; No. 2 0.1 s later on the vehicle |
| local horizontal | T5 + 19.8 | 719.3 | GE504 §4.1.11: +X along the local horizontal in the direction of motion, +Z towards the Earth |
| APS ullage off | T5 + 87.0 | 786.5 | |

The IU stages by part: an event whose part or engine has gone (a pilot's Space press) does nothing and is logged "(nothing to do: gone)". The S-II dropped by hand starts T4 early, which leaves the S-II's remaining events (gain switches, centre engine cutoff) behind; the IGM's start is kept, and the IGM then steers the S-IVB. T5 stops the IGM however the S-IVB was cut. Engines decay over their shutdown ramp after a cutoff (§9.2); the IU senses the cutoff itself, not the end of the decay. The IU refuses manual staging before T3, when Space would drop the S-IC on the pad, or full and burning in flight.

### 8.4 Pre-IGM pitch program

GE504 Table 4-II: chi_Y = Σ F_kn t^n (n = 0…4; t in s from T1) on four segments split at t_S1 = 35, t_S2 = 80, t_S3 = 115 s. Table 5-I (page images):

| segment | F_k0 (deg) | F_k1 (deg/s) | F_k2 (deg/s²) | F_k3 (deg/s³) | F_k4 (deg/s⁴) |
|---|---|---|---|---|---|
| 1 (t < 35) | 3.19840 | −0.544236 | 0.0351605 | −0.00116379 | 0.0000113886 |
| 2 (35–80) | −10.9607 | 0.946620 | −0.0294206 | 0.000207717 | −0.000000439036 |
| 3 (80–115) | 78.7826 | −2.83749 | 0.0289710 | −0.000178363 | 0.000000463029 |
| 4 (≥ 115) | 69.9191 | −2.007490 | 0.0105367 | −0.0000233163 | 0.0000000136702 |

Checks: the segments join within 0.04° (5.59/5.62° at 35 s, 35.16° at 80 s, 54.67° at 115 s); the command is −0.04° at 12 s, where the program starts; no segment exceeds 1°/s; it reaches −66.59° at SA-504's 153.0 s arrest. Other GE504 pre-IGM presettings: engine-out freeze B11 −0.62, B12 40.9 s, B21 −0.3611, B22 29.25 s, t_1 13.0 s (start backup), t_2 25, t_3 36, t_4 45, t_5 81 s; ΔtLET 35.1 s. *The engine-out freeze is modelled since §16.*

**AS-506's commanded pitch.** MAN506 Figure 2-2 plots AS-506's typical commanded pitch for the July window; read to about 1°, it seems to follow SA-504's polynomial (time from first motion, which is T1 − 0.4 s in MAN506; *§14.1 shows that AS-506's own command did not*):

| time from first motion | MAN506 Fig. 2-2 | SA-504 polynomial |
|---|---|---|
| 1 min | −20° | −20.6° |
| 2 min | −56° | −56.5° |
| tilt arrest (plateau) | −67.5° | −68.0° (at T1 + 159.37) |

**AS-506's own command (§17).** Since §17 the IU flies AS-506's command, reconstructed from its flight in GE504's form (`AS506.pitchCoefficients`: four quartics split at 35, 80 and 115 s, exact joins, −68.90° at the 159.37 s arrest; rms 0.057° against the reconstruction; §17.1), and no longer SA-504's polynomial above. The scale that stood in for it (`pitchScale` 1.025, fitted on the OECO flight-path angle; 1.03 before §9) is deleted; §14.1 showed that AS-506's command was not a scale of SA-504's. Nothing in the table is fitted (fixed 0.02 s steps, `testSICAscentMatchesApollo11`):

| | quantity | FER (Table 4-2) | model | before §17 (×1.025) | tolerance (§5) |
|---|---|---|---|---|---|
| CECO, 135.2 s | altitude (geodetic since §15) | 44.0 km | 44.23 | 44.00 | ±2.5 km |
| | space-fixed velocity | 1,979.0 m/s | 1,977.36 | 1,966.50 | ±50 |
| | flight-path angle | 22.957° | 23.247 | 23.124 | ±1.5° |
| | heading | 76.315° | 76.261 | 76.276 | ±0.5° |
| OECO, 161.63 s | altitude | 66.1 km | 66.61 | 66.04 | ±2.5 km |
| | space-fixed velocity | 2,764.1 m/s | 2,759.45 | 2,749.24 | ±40 |
| | flight-path angle | 19.114° | 19.407 | 19.068 (fitted) | ±0.35° (§17.3 item 1) |
| | heading | 75.439° | 75.368 | 75.370 | ±0.5° |
| | Mach 1 time | 66.3 s | 66.28 | 66.78 | ±1 s (§11) |
| | max Q | 35.2 kPa at 83.0 s | 35.27 at 83.06 | 34.79 at 83.32 | ±2 %, ±1 s (§11) |

The headings come within 0.08° of AS-506's (the test allows §5's 0.5°; `testIGMFliesApollo11ToItsParkingOrbit` pins X_S itself) and so check the space-fixed frame, flight azimuth and roll program independently of the pitch program: with X_S on the radial instead of the plumb line (§8.1) they were 0.13–0.23° high. The S-IC is now 1.6 and 4.7 m/s below AS-506's speed at CECO and OECO (it was 11–14 m/s, §9.5), and 0.29° steep at OECO: AS-506's command flown without AS-506's late trim (§17.3 item 1). Unscaled, SA-504's polynomial left it 1.3° steep (20.37°) and 1.8 km high.

**Altitudes.** Since §15 the model's altitude is geodetic on WGS 84 and compares directly with the FER's over the Fischer ellipsoid, 30 m apart at the Cape. (On the sphere before §15 the S-IC states were compared as altitude above the pad.)

### 8.5 Known deviations of the S-IC ascent

- **The roll and pitch programs start earlier than AS-506's.** The model reaches GE504's 137 m rise at T1 + 10.7 s and starts them there; AS-506 started them at T1 + 12.6 s (range 13.2 s), when the PFT has it about 200 m up. The model's climb itself matches the PFT: 105 m against 105 m at 10 s, 473 against 478 m at 20 s, and within 60 m to 100 s (§11.4). So AS-506's start test was not 137 m as the model applies it, or measured the rise differently (inferred); its preset was not found (§8.9 item 1). Thrust is close: the model's stage thrust at liftoff is 34.1 MN at the standard 101.3 kPa, against about 34.35 MN in FER Figure 5-3 at the pad's 100.6 kPa, and its acceleration matches Figure 4-3 within 0.8 % wherever drag is negligible (§9.4). *§14.2 counts that shortfall, 0.4–0.8 % in the first 20 s, in the S-IC's F/m deficit; since §17 the F-1's thrust is Figure 5-3's at AS-506's measured level, 34.34 MN at first motion.* The model has no controlled-release mechanism: the release rods held the vehicle until about 0.6 s after first motion (FER Figure 9-1), hence the FER's 1.07 g there. The program-start time is therefore not a test target. Max Q and Mach 1, which were 7 s and 0.8 s early on the US-1976 atmosphere with a constant drag coefficient, now come within 0.4 s of AS-506's (§11).
- **The pitch polynomial was SA-504's, scaled 2.5 % to compensate.** MAN506 Fig. 2-2, read to about 1°, suggested AS-506's commanded pitch matched it unscaled; §14.1 showed it did not. *Resolved in §17: the IU flies AS-506's command reconstructed from its flight (§8.4), which leaves the S-IC 0.29° steep at OECO without AS-506's late trim (§17.3 item 1).*

### 8.6 Flight control and APS logic as implemented

- **FCC law** (§7.2): β = a0·e − a1·ω on each gimbal-flown axis, in the IU's hold, with TN5869's gain schedule on the S-IC and S-II switched at the IU's switch points (§8.3), and REF504's roll pair (S-IC 0.245 / 0.15 s, S-II 0.25 / 0.20 s; L). β is each engine's deflection: per actuator in pitch and yaw, tangential in roll (§7.2: if REF504's roll β is per actuator, a diagonal engine deflects √2 times it). Since §13 the S-IC also flies REF504's roll attitude-gain filter 2.35/(s + 2.35) (L), stepped exactly at any step; its pitch and yaw filter 0.4(s + 0.095)/(s + 0.038) is not flown (§13.3). Checks (since §13, with FER Table 20-10's roll inertia): in the roll program the model peaks at a 0.81° roll error and a 1.24°/s roll rate, 1.3 and 2.0 s after the program start, against AS-506's 0.92° and 1.38°/s at 0.6 and 1.2 s (FER Table 11-2), whose measured rate carries a ±0.10–0.15°/s oscillation the model lacks (Figure 11-3). Before §13 the model peaked at 1.18° and 1.39°/s 2 and 3 s after the start, a match that came from a roll inertia 9.5 times too large. Late in the ramp the law tracks it 0.59° behind (a1/a0 = 0.61°) at 1.00°/s, and Position I settles on 72.058°. A 0.5° pitch step at liftoff mass in vacuum (c = 0.947 s⁻², so ωn = 0.923 rad/s and ζ = 0.354, with the S-IC's feed lines; 0.955 s⁻² without them) overshoots 30% at 3.6 s, as §7.4 B's formulas predict (0.887 s⁻², 32% at 3.7 s before §13).
- **Pilot hand-back**: manual input or another autopilot mode takes the attitude from the IU, which keeps sequencing. When the hold flies again (input released, or key 8 after another mode), the IU restarts its command from the vehicle's attitude and returns to its program within its command rate limits: 1°/s per angle until the S-IVB cutoff, ASH's coast limits (below) from T5 on. 13° off the program at 60 s, the stack turns back at 1.3°/s at most, where the FCC law on the whole error swung it at up to 7.7°/s near max Q. Under the FCC law the IU keeps restarting its command from the attitude until the body rate is under twice its command limit (2°/s), so the law first only damps what the pilot left: since §13's roll inertia a 0.6–1 s full roll tap in the S-IC burn spins the stack at 45–120°/s, and a command restarted from that spin let the error wrap past half a turn into pitch and yaw, where the saturated gimbals left no roll torque and the stack could tumble near max Q. Now the spin stops within 5 s and the nose stays within 1.1° of an untouched flight's.
- **S-IVB burn**: the vehicle's own self-tuned gimbal law (`tvcGains`) flies the J-2, because TN5869's S-IVB pair contradicts its stated control frequency (§7.5).
- **APS phase plane** (§7.2): ±1° dead band; error clipped at 2.5° in pitch and yaw and 3.5° in roll; switching line e − 5 s × ω (the Astrionics System Handbook's typical slope, M, §13); 0.06 s minimum on-time; full-thrust pulses, no hysteresis. It flies the APS in every autopilot mode except kill rotation, and in the IU's hold; in the pointing modes, which set no roll attitude, roll keeps M0's rate damping (proportional levels, as in kill rotation). The law decides once a step, so the simulation ends a coasting step where an axis is predicted to reach its switching line, and a pulse step where the minimum on-time ends: the law then works the same at any frame rate and time warp. Measured: manoeuvres at 0.30°/s in pitch and 0.51°/s in roll; pulses of exactly 0.06 s with the app's 1/60 s frames; holding in free space after a slew, since §13's roll inertia a minimum-impulse limit cycle in roll plus a few pitch and yaw pulses, 2.82 kg/h over 1,000 s at 1× and at 10,000× (2.66 kg/h over 7,333 s at 10,000×; the runs need not agree pulse for pulse, §13.4 item 8) (AS-506 used 4.71 kg/h holding the local horizontal, FER Table 7-5; before §13, with the liquids spinning in roll, 0.13 and 0.18 kg/h; 47 kg/h at 10,000× with coast steps of up to 60 s before the step ends at the switching line); on the light S-IVB after TLI, Prograde uses 0.3 kg of APS propellant an hour, where M0's law emptied both modules (298.5 kg) within the hour.
- **Orbital attitude**: after T5 + 19.8 s the IU commands the local horizontal (+x along the horizontal velocity, +z down), turning at the orbital rate; the APS holds it within 1.9° (dead band plus 5 s × the 0.07°/s orbital rate on each axis). The FER's mission description has the vehicle "aligned with the local horizontal" from about 10 s after insertion through the parking orbit; GE504's SA-504 landmark-sighting manoeuvres (a 180° roll and 20° nose-down from insertion + 45 min) do not appear in it and are not modelled. The command moves there within the LVDC's coast rate limits, 0.4°/s in pitch and yaw and 0.6°/s in roll (ASH §3.1, Table 3.1-3, "Coast"; M), which the model applies from the S-IVB cutoff (T5) on; SA-504's presettings had 1.0°/s (GE504). FER Figure 11-12 (digitised during the research pass: L-M) supports the ASH value: AS-506's pitch error grew at 0.33–0.37°/s from 721 to 727 s, before the vehicle had turned, and reached the 2.5° clip at about 729 s, where a 1.0°/s limit would have saturated within about 3 s. The model's pitch error grows at 0.34°/s over the same seconds after its own T5 (T5 + 21.4 to 27.4 s). The vehicle then turned at about 0.2°/s and the manoeuvre was about 6° in all; from the IGM's cutoff attitude the model's slew is 6.1° (6.0° in pitch), at the APS's clip-limited 0.30°/s.
- **S-IVB burn roll**: AS-506 held a roll error of about −1° through the first burn (FER Figure 11-11), the APS working against a steady 61.4 N·m roll torque (FER §11.4.1). The model has no such torque, so its roll stays inside the dead band.

### 8.7 FER values that touch §1–§7 (applied in §9)

The propulsion and mass model of §1–§3 was calibrated without the FER. These values from it drove the recalibration of §9 (2026-10-17), which uses Table 20-9's 39,307 kg for the thrust buildup to holddown release (the propellant tables' 39,374 kg is the propellant used, not the vehicle's mass change). The first-motion acceleration stays unmodelled (§9.5).

| item | FER value | datasheet now | effect |
|---|---|---|---|
| propellant used from ignition to holddown release | 39,374 kg (86,803 lb), predicted 38,913 kg (§5.2) | 85,745 lb predicted (§1.1, L) | +1,058 lb at first motion |
| S-IC loads at holddown release | LOX 1,468,594 kg, fuel 637,830 kg (§5.2) | derived from GIW less the predicted pre-release burn | direct check of `sICLOXAtFirstMotion`, `sICRP1AtFirstMotion` |
| F-1 performance at 35–38 s, standard sea level | thrust 6,674–6,783 kN (1,500–1,525 klbf), Isp 2,584–2,599 N·s/kg (263.5–265.0 s), flow 2,569–2,613 kg/s, MR 2.241–2.279 per engine (Table 5-1) | flight-matched 6.92 MN sea-level thrust, 2,659 kg/s (§3) | flow rises through the burn (Figure 5-3: stage flow about 13,100 kg/s at liftoff, thrust 34 MN rising to about 40 MN by 130 s) |
| S-II EMR | high 5.50 from ESC + 5.5 s; IU shift command at ESC + 331.8 s (494.8 s) on a preset characteristic velocity; shift 498.0 s; low EMR 4.34 average (predicted 4.33) (§6, Table 2-2) | shift 491 s to 4.7 (§1.2, §3; L-M) | resolves the §6 conflict; needs the S-II recalibrated to hold the 548.22 s depletion |
| S-II thrust at low EMR | 3,059,402 N (687,781 lbf) for four engines at EMR 4.29 (§6) | 186,165 lbf per engine at 4.7 (derived) | |
| first-motion total acceleration | 1.07 g actual, 1.08 g nominal (Table 4-1) | rejected as low confidence (§6) | genuine at first motion (controlled release); the model gives 1.20 g (§9.4) |
| S-IC/S-II separation | 162.3 s, 2,773.9 m/s, 66.7 km, γ 19.020° (Table 4-3) | AP values (H) | consistent |
| max angle of attack near max Q | 1.6° pitch, 1.4° yaw; engine deflections 0.2° and 0.3° from wind shear (§11.2) | — | targets for the aerodynamics item |
| TB5 APS ullage | No. 1 on at T5 + 0.3, off at T5 + 87.0 (No. 2 0.1 s later each), 86.7 s (Table 2-2) | 88 s (§7.3, §7.4 D; MAN503) | the IU flies 86.7 s; §7.4 D's Δv and propellant scale by 86.7/88 |

### 8.8 Validation targets and tests (`SaturnIUTests`)

| test | checks | depends on |
|---|---|---|
| `testOnThePad` | geodetic pad on WGS 84, checked against SP-4029's geocentric latitude, the PFT's radius and the 408.64 m/s inertial velocity (§15.2); nose up along the normal, Position I east, IU idle until liftoff; Space refused | §1.6, §7.1 (M), §15 (H) |
| `testPitchPolynomialTranscription` | GE504 segments join, start near 0, rates under 1°/s, −66.59° at 153 s; unscaled within 2° of MAN506 Fig. 2-2; the IU flies AS-506's fitted program, arrested on −68.90° at T1 + 159.37 s (§17.4) | GE504 (H for SA-504), MAN506 (figure reading) |
| `testTowerYawAndRollProgram` | yaw to 1.25° at ≤ 1°/s and away from the tower; start at 137 m; roll peaks 1.38 ± 0.2°/s and 0.92 ± 0.2° (FER Table 11-2; the model's start is more damped, §13.4 item 9); lag a1/a0 = 0.61° late in the ramp; Position I on 72.058° | GE504, FER (H), REF504 (roll gains L) |
| `testSICAscentMatchesApollo11` | the §8.4 table (the OECO angle within 0.35°); Mach 1, max Q, the q history, the climb within 150 m and the Earth-fixed speed within 0.5 % against the PFT, and the peak axial force (§11.6); thrust acceleration within 1 % of FER Figure 4-3 at 10.3, 147.4, 152.3 and 158.8 s, where drag is under 0.3 % of thrust | FER Table 4-1/4-2 (H), Figure 4-3 (M), PFT (H); AS-506's reconstructed command (M, §17) |
| `testOutboardCantSchedule` | cant from T1 + 20.0 s to 2° radial | FER (H), EL (M) |
| `testFlightControlStepResponse` | ωn and overshoot of the FCC law | TN5869 (L), model mass properties |
| `testFlightSequenceFollowsTheApollo11Timeline` | every IU event against FER Tables 2-1, 2-2 and 10-4 (S-II gain switches against ICD507), within 0.1 s from T3 on (T3 within 0.05 s), the S-II ullage motors and EMR steps included; the IGM's events within a cycle (1.7 s): the shift command and PU valve step of AS-506's (the step exactly 2.8 s after the command), phase 3 of the model's own T4, terminal guidance and the chi freeze timed from the model's cutoff as the FER's from AS-506's; the velocity cutoff within 1 s of AS-506's (6 s before §17); staging by part; S-II at low EMR; ullage 86.7 s; a slew of 3–10° to the local horizontal (AS-506 about 6°); the local-horizontal command within ASH's orbital rate limits, reaching 0.4°/s in pitch, and the pitch error growing at 0.35 ± 0.05°/s from T5 + 21.4 to T5 + 27.4 s (FER Figure 11-12, 721 to 727 s: 0.33–0.37); local horizontal held within 1.9°; a hand-back in orbit restarts the command from the attitude and returns within the limits | FER (H; Figure 11-12 digitised, L-M), ICD507 (M), ASH (M) |
| `testIGMFliesApollo11ToItsParkingOrbit` | §10.6 | FER §10 |
| `testCoastCommandRateFromTheSIVBCutoff` | after the S-IVB cutoff and before the turn to the local horizontal, a hand-back returns at the coast limits (0.6°/s in roll), not 1°/s | ASH (M) |
| `testIUStagesByPartAfterAManualSpacePress` | Space refused before T3; from T3 a pilot's Space press and attitude takeover leave the sequence intact | — |
| `testEarlierTimeBaseEventsDropWhenTheNextStarts` | the S-II dropped by hand starts T4, and the S-II's pending events never fire into the S-IVB; the IGM still starts and steers the S-IVB | — |
| `testAttitudeHandBackReturnsAtTheCommandRate` | handed back 13° off the program, the stack returns at 1.3°/s at most and rejoins the program | GE504 command rate limit |
| `testRollTapHandBackInTheSICBurn` | 0.6 and 1 s full roll taps at 40 and 60 s: the spin damped below 1°/s within 6 s, the nose within 2° of an untouched flight's, tracking within 1.5° 25 s on | the model (regression) |
| `testIUStartedInFlightWaitsForTheProgramStart` | an IU attached in flight takes its rise from there: programs at the 13 s backup | GE504 |
| `testAPSPhasePlaneSlewsAndHolds`, `testAPSDoesNotDrainHoldingPrograde` | §8.6 APS figures | EH 8.30 (M); K (Astrionics System Handbook, M) and the derived minimum on-time |
| `testAPSHoldAtTimeWarp`, `testAPSPulseLastsTheMinimumOnTimeAtAnyFrameRate` | the phase plane's propellant use at 1× and 10,000× within the limit-cycle bound and AS-506's rate; a single minimum pulse lasts exactly 0.06 s and gives the same rate at any frame rate | — |
| `testAPSDampsRollInThePointingModes` | a 0.15°/s roll in Prograde dies out (under the phase plane's 0.2°/s threshold) | — |
| `testStepsEndOnFlightProgramEvents` | the simulation ends a step on a program's event at any warp, flying or on the pad | — |

### 8.9 Remaining gaps (IU)

1. AS-506's own pre-IGM presettings (pitch polynomial, t_AR, start test): its July 1969 Operational Trajectory or the SA-506 Flight Sequence Program ICD (40M33626B).
2. PFT Table B-II/B-III: the S-IC time history, to check the whole ascent rather than two points (the tables are scanned and must be read from the page images).
3. *Resolved in §10:* IGM, with presettings from the model's vehicle and AS-506's flight (AS-506's own presettings are still missing, §10.7).
4. *Resolved in §10:* the S-II EMR shift by characteristic velocity.
5. AS-506's roll gains and the definition of the roll β (per actuator or tangential, §7.2; the Astrionics System Handbook sends the roll signals to all eight servo amplifiers, which would make it per actuator and raise the roll authority √2), and the FCC filters (REF504 §3.5: the S-IC roll filter is flown since §13, the pitch and yaw filter is not). With FER Table 20-10's roll inertia (§13) the roll program's peaks come 1.3 and 2.0 s after its start, against AS-506's 0.6 and 1.2 s after its logged 13.2 s start; AS-506's measured rate carries a ±0.10–0.15°/s oscillation at about 0.25 Hz through the ramp (FER Figure 11-3) that neither MSFC's post-flight simulation nor the model has.
6. *Resolved in §16:* GE504 Table 4-II's pre-IGM engine-out tilt freeze (B11, B12, B21, B22) for an S-IC engine out in the pitch program, with SA-504's presettings; AS-506's own are still missing.

**Values tests must not depend on**: the fitted pitch program beyond its 0.15° from AS-506's reconstructed command; the cant ramp rate; every gain (§7.5), beyond the roll-program peaks checked against the FER; APS K and minimum on-time; the program-start time (§8.5).

---

## 9. Propulsion and masses from the FER (M1 propulsion recalibration)

Compiled on 2026-10-17 to apply §8.7. Values come from the FER (MPR-SAT-FE-69-9) unless marked: SP-4029's ground-ignition rows (which the FER confirms), the S-II start setting's EMR and Isp and the ullage motors' thrust and burn time (MSFC-MAN-506 or assumed, §9.2), and the S-IVB's model-derived unusable masses. The FER was read directly with its tables checked against the page images, and its figures digitised from them (M): Tables 2-1 and 2-2 (events), Table 4-1 and Figure 4-3 (accelerations), Tables 5-1 and 5-2 and Figure 5-3 (S-IC), Tables 6-1 and 6-2, Figure 6-3 and §6.2–6.5 (S-II), Tables 7-1 and 7-3, Figure 7-2 and §7.2–7.4 (S-IVB), and the mass tables 20-1, 20-3, 20-5, 20-7 and 20-9. `AS506Data.swift` holds the values with the same sources and grades. For the model this section supersedes the derived masses of §1.1, the S-II and S-IVB engine rows of §1.2 and §1.3, all of §2, the flight rows of §3, and targets A and B of §5.

### 9.1 Mass model

- **First motion.** Simulation time 0 is holddown release (0.30 s) with the FER's vehicle, 2,899,008 kg (Table 20-1). The 39,307 kg burned in thrust buildup (Table 20-9) is history. The S-IC is the FER's at release: stage 2,239,381 kg, LOX 1,468,594 kg of liquid (Table 5-2) plus the 235 kg of GOX in its ullage (Table 20-1), RP-1 637,830 kg (Table 5-2). The S-II, both interstages' totals, the S-IVB and the IU keep SP-4029's ground-ignition rows (the FER's tables agree to the pound), and the spacecraft is the FER's: LES 4,042, CSM 28,806, LM 15,095 and SLA 1,166 + 626 kg (Tables 20-7 and 20-9), 49,735 kg in all, SP-4029's 109,646 lb. Together they give Table 20-1's 2,899,008 kg to the kilogram, a check across the two sources. *Since §12 the aft interstage is the FER's 3,180 + 484 kg (1.7 lb over SP-4029's row) and carries the S-IVB's 23 kg aft frame, and the S-IVB's TX-280s are on a part of their own: the total is 0.8 kg higher, 2,899,008.6 kg.*
- **Tanks.** A tank holds the propellant aboard at first motion and keeps the gas made from it in flight (the S-IC's GOX, the S-II's GOX and GH2), which stays in the ullage, so what leaves a tank is what its engines burned. Its unusable mass is the liquid at cutoff plus that gas: S-IC LOX 18,041 + 3,611 = 21,652 kg (Tables 5-2, 20-1), S-II LOX 1,603 + 2,147 = 3,750 kg (Table 20-3). LOX depletion ends both burns, as the low-level sensors did. The fuel left is an output: the S-IC's RP-1 should be 13,954 kg (Table 5-2) and the S-II's LH2 2,695 + 658 = 3,353 kg (Table 20-3); the mixture ratios are fitted to them (§9.3). The S-IVB's tanks keep their §2 loads and the unusable masses derived for the pre-FER engine (at burn 1's EMR 4.85 the usable LOX would last 478 s and the LH2 474 s; burn 1 ends after 147 s, and TLI is M2's).
- **S-IC/S-II interstage.** Three items (Table 20-9): the 614 kg ring that leaves with the S-IC at first-plane separation (booked in the S-IC part), the large interstage, 3,982 kg, jettisoned at 192.3 s, and its four ullage motors' 610 kg of propellant (one tank for the four grains, which burn together).
- **Frost and purge gas.** The S-II's frost (204 kg) and insulation purge gas (54 kg) and the S-IVB's frost (90 kg), all shed by CECO (Table 20-1), are booked on the S-IC part since §17, at their stages' CG stations, and leave with the S-IC; the S-IC's own (frost 295 kg, N2 purge gas 16 kg by CECO) are in its first-motion mass and leave with it too. While the S-IC is aboard the vehicle is therefore 661–785 kg above the FER's; after its separation the stack is the FER's within 34 kg at every event (§9.4). *Before §17 they rode to the upper stages' cutoffs, which left the S-II stack 250–380 kg and the S-IVB stack 75–125 kg heavy.*
- **Not modelled.** Venting and boil-off before ignition, and the S-IVB's fuel-lead loss (23 kg).

### 9.2 Engines

| engine | model | basis | conf |
|---|---|---|---|
| F-1 | One rating at first motion carried along two schedules (§17.1): Figure 5-3's stage thrust, plus n p A_e at the launch day's pressure on AS-506's path, times `sICThrustScale` 1.0022 (fitted to the PFT); and its site flow and mixture ratio, each with a five-engine and a four-engine scale (fitted to Table 5-2's tanks at CECO and to the OECO residuals). Per engine at first motion: 7,908,340 N in vacuum, 2,631.4 kg/s (306.5 s), exit area 10.10 m². | Figure 5-3 (M; thrust 0.017 MN a pixel, flow ±15–25 kg/s, MR ±0.002); the PFT's S-IC acceleration (H) for the level; the exit area gives the figure's liftoff Isp, about 2,594 N·s/kg at 100.6 kPa. *Before §17: one flow schedule, the thrust its flow times 2,980.5 N·s/kg (7,847,657 N at first motion), scales 0.99896 and 0.99965.* | M |
| F-1 shutdown | Linear decay over 0.66 s from the cutoff (0.33 s of full thrust); its propellant comes from below the unusable mass. | §5.4: 10,612,096 N·s for the four outboard engines from OECO to separation, 2,659,605 N·s for the centre engine. The decay burned 908 kg per engine (Table 20-9). | H (impulse), L (shape) |
| J-2, S-II start | 878,288 N, 4,195 N·s/kg, EMR 5.0, from engine start to High EMR Select at ESC + 5.5 s (168.5 s). | §6.2: 861,496–895,080 N per engine at start; EMR at PU null (MAN506, L); Isp assumed between the S-IVB's and the S-II's (L). | M thrust, L Isp |
| J-2, S-II high EMR | 1,028,303 N, 4,164.9 N·s/kg (424.7 s before the flow scale), EMR 5.49765 (fitted) to the PU valve step. | Table 6-1, the five engines' mean at ESC + 61 s (engine EMR 5.564); Figure 6-3: stage EMR 5.55 falling to 5.45. | H |
| EMR shift | A linear ramp from high to low EMR (thrust, flow, mixture ratio and exit area) over 2.4 s from the PU valve step, 2.8 s after the IGM's shift command; the low EMR's decline starts there (§17.6). | The PFT's effective thrust step, 498.7–498.9 s (§14.2), 1.2 s after AS-506's valve step at 497.60 s (Table 6-2): the ramp's middle. | H (PFT), L (shape) |
| J-2, S-II low EMR | 772,750 N an engine at the valve step, declining 694 N/s for the stage (0.022 % a second) to 3,055,900 N for four at OECO and held after; 4,190 N·s/kg; EMR 4.34. | Figure 6-3's stage thrust, a line through its traced samples from 499.5 to 538 s (2.7 kN rms), 0.10 % and 0.02 % below §6.3's 3,082,769 N at ESC + 351 s and 3,059,402 N at ESC + 381 s; Figure 6-3: 4,181–4,190 N·s/kg; §6.5: average EMR 4.34 (predicted 4.33). *768,000 N held constant before §17.* AS-506 ran 7–8 % below §3's 828 kN at EMR 4.7. | M (shape), H (level) |
| S-II flows | All three settings' flows × 0.996784 (fitted, §9.3; 0.99749 before §17). | Within the FER's flow reconstruction, which matched acceptance Isp: 0.8 kg/s (0.32 %) below Table 6-1's 246.9 kg/s at high EMR. | — |
| J-2, S-II transients | Start: nothing for 1.09 s after the solenoids (164.0 s), then a linear rise over 1.11 s to mainstage at 166.2 s. Shutdown: linear over 0.38 s. | 582 kg burned between 164.0 and 166.2 s (Table 20-9), 0.56 s of full flow; OECO cutoff impulse 581,916 N·s to 5 % thrust (§6.4), from 2,783,479 N after a LOX-starvation decay the model does not have: 0.19 s of the model's 3,056,000 N at OECO. The centre engine's decay then burns 47 kg (Table 20-9: 49 kg). | H (data), L (shape) |
| J-2, S-IVB burn 1 | 912,000 N, 215.37 kg/s (431.8 s), EMR 4.85. | The thrust AS-506's measured acceleration needs (the PFT over 560–690 s from AS-506's T4 state, on the model's mass, the FER's within 34 kg; Table 4-1's 6.73 m/s² at cutoff agrees; §17.6). Table 20-9: 31,152 kg in 144.64 s of mainstage, venting included; Table 20-5: LOX 25,873 kg and LH2 5,339 kg used (the engine's own EMR was about 4.96). *903,000 N (Figure 7-2: 902–906 kN in flight; Table 7-1's standardised 901,223 N) before §17: the alternative.* | M thrust, H flow and ratio |
| J-2, S-IVB transients | Start: nothing for 0.6 s after STDV open (552.2 s), then a linear rise over 1.9 s to mainstage (554.7 s). Shutdown: linear over 0.42 s. | §7.2: 857,243 N·s from STDV open to STDV + 2.5 s, 0.95 s of full thrust at Figure 7-2's level; §7.4: 188,302 N·s at cutoff, 0.21 s. The FER reconstructs both at Figure 7-2's level: at the measured level the shapes give 1.0 % more. | H (data), L (shape) |
| S-II ullage motors | Four solids, 23,000 lbf for 3.75 s each and 152.5 kg of propellant each (Isp_eff 256.5 s), on the interstage; lit by the IU at T3 + 0.5 s, burned out 3.75 s later (solid motors since §12, canted 10°). | MAN506 (thrust, burn time; M); Table 20-9 (610 kg in all; 309 kg left at S-II engine start; H); Table 2-2 (times; H). | M |

**How the engines work in the core** (`Components.swift`, `PropulsionModelTests` A6–A9). A `PerformanceSchedule` scales an engine's rating, thrust and flow by factors and sets its mixture ratio, piecewise linear on the engine's burn clock, which runs from its start; the exit area stays. `EngineTransients` add a start delay with a linear rise and a linear shutdown. Ramps are sampled at the middle of each step. A cutoff commanded before a step starts the decay with that step; an engine whose tank runs dry within a step runs to its end, then decays. Every engine's step is fixed before any draws, so engines sharing a tank that runs dry within a step are treated alike. A cut engine runs its decay to the end before a new command can start it, and the simulation keeps 0.02 s steps from a start command, through the delay, so the ramps are the same at any time warp. The IU senses an engine's cutoff, not the end of its decay, and the HUD's stage Δv follows the schedule and ignores the ramps.

**Rating ramps** (2026-10-18, `PropulsionModelTests` A10). A change of rating can take time: the IU's `.rating(part:_:ramp:)` action, through `Thruster.setRating(_:ramp:)`, moves vacuum thrust, mass flow, mixture ratio and nozzle exit area linearly from the rating in effect to the new one over `ramp` s. The ramp runs in equal cells of at most 0.02 s, each at the value of its middle, and the IU ends steps on the cells' ends, so each step lies within one cell: the ramp's impulse, (F0 + F1)/2 over its length, its propellant and the propellant's split are the same at any step size and warp. The exceptions are the epoch's resolution (1.2e-7 s in 1969) and the simulation's 1 ms minimum step, which can stretch a step that starts just before a cell's end past it, so that it runs at most 1 ms at the earlier cell's value. Since §17 the S-II's shift ramps over 2.4 s, its middle on AS-506's effective step (§14.5 item 5: about 1.2 s after the valve step), and the action can also bring a performance schedule whose times run from the event (`.rating(part:_:ramp:schedule:)`, `PerformanceSchedule.delayed(by:)`, `PropulsionModelTests` A11): the low EMR's decline then starts at the shift, wherever the IGM commands it.

### 9.3 Fitted values

| value | fitted to | result |
|---|---|---|
| `sICThrustScale` 1.0022 (§17.1) | the PFT's S-IC integral of \|a_ng\|, with the frost and purge gas shed by CECO taken off | −1.26 m/s with them aboard to separation (§17.2) |
| `sICFlowScale` (0.999385, 0.996609), five and four engines (§17.1) | the tanks at CECO, LOX 216,633 + 2,809 kg and RP-1 99,059 kg (Tables 5-2, 20-1), and LOX depletion at 161.63 s | 161.64 s (T3 161.65 in flight; FER 161.66) |
| `sICMixtureRatioScale` (0.999840, 0.998441) | RP-1 at CECO, 99,059 kg, and at OECO, 13,954 kg | to the kilogram |
| `sIIFlowScale` 0.996784 (§17.6) | LOX depletion at 548.22 s in the IU flight, the start, the EMR ramp and the decays included | 548.220 s (T4 548.23; FER 548.24); 548.16 s in the propellant model's timeline from a 164.00 s start |
| `sIIHighMixtureRatio` 5.49765 (§17.6) | LH2 at OECO, 3,353 kg | 3,353.0 kg in the IU flight; 3,355.7 kg in the timeline |
| `sIVBJ2ThrustVacuum` 912 kN (§17.6) | the PFT's S-IVB integral of \|a_ng\| over 560–690 s, from AS-506's T4 state | 0.00 m/s at 912,060 N |
| `igmShiftVelocity` 3,908 m/s (§17.6) | the middle of AS-506's window on the PFT, 3,894–3,921 m/s | the shift command on the model's 494.76 s cycle |

`pitchScale` (1.025, fitted on the OECO flight-path angle) is deleted (§17.1). The flow scales move the figures they adjust by 0.02–0.34 % (the F-1's) and 0.32 % (the J-2s'), inside their reading accuracy.

### 9.4 Results against the FER

**Event masses**, with the propellant model alone at the FER's event times (`testEventTimelineThroughThePropellantModel`; regenerated after §17):

| range time (s) | event | model (kg) | FER (kg) | difference |
|---|---|---|---|---|
| 0.30 | first motion | 2,899,009 | 2,899,008 (Table 20-1) | +1 |
| 135.20 | S-IC CECO | 1,110,851 | 1,110,189 (20-1) | +662 (+0.06 %) |
| 161.64 | S-IC OECO (FER 161.63) | 827,956 | 827,292 (20-1) | +664 (+0.08 %) |
| 162.30 | S-IC/S-II separation | 824,410 | 823,625 (20-1) | +785 (+0.10 %) |
| 164.00 | S-II engine start | 658,366 | 658,363 (20-9) | +3 |
| 166.20 | S-II mainstage | 657,477 | 657,459 (20-9) | +18 |
| 548.16 | S-II OECO (FER 548.22) | 213,902 | 213,888 (20-3) | +14 |
| 549.00 | S-II/S-IVB separation | 213,763 | 213,757 (20-3) | +6 |
| 552.20 | S-IVB ignition | 166,593 | 166,571 (20-9) | +22 |
| 554.70 | S-IVB mainstage | 166,381 | 166,396 (20-9) | −15 |
| 699.34 | S-IVB cutoff | 135,169 | 135,182 (20-5) | −13 |
| 699.54 | end of thrust decay | 135,136 | 135,102 (20-5) | +34 |

The S-IC's propellant is the FER's at CECO and OECO (§17.1). While it is aboard it carries the 661 kg of frost and purge gas AS-506 had shed by CECO (§9.1), and from OECO to separation it burns 121 kg less than the FER's 3,667 kg. After its separation the stack is the FER's within 34 kg. *Before §17: CECO +1,422 kg (the flow's), the upper stages 150–360 kg and the S-IVB stack 75–125 kg heavy.* Also: S-II ullage propellant left at S-II engine start 311 kg (FER 309); the S-II's LOX depletes at 548.16 s in this timeline, which starts the J-2s at the FER's 164.00 s (548.22 s in the IU flight, whose T3 starts them at 164.05 s), with 3,356 kg of LH2.

**Accelerations.** Thrust over mass, in vacuum, against Table 4-1's stage maxima (total inertial acceleration; drag is negligible there) and Figure 4-3 (M, ±1 %); "flight" rows are from the IU's trajectory, with ambient pressure (`testSICAscentMatchesApollo11`, fixed 0.02 s steps); the rest from the timeline above:

| point | model | FER | difference |
|---|---|---|---|
| liftoff (flight, 101.2 kPa) | stage thrust 34.34 MN; 11.85 m/s² (1.21 g) | about 34.35 MN at 100.6 kPa (Figure 5-3); "approximately 1.2 g" (§9.2.1) | 0.0 % |
| 10.3 s (flight) | 12.48 m/s² | 12.41 (Figure 4-3) | +0.6 % |
| S-IC CECO | stage thrust 40.12 MN | 40.05 MN (Figure 5-3) | +0.2 % (the PFT's level, §17.1) |
| 147.4, 152.3, 158.8 s (flight) | 32.47, 34.42, 37.35 | 32.23, 34.31, 37.23 (Figure 4-3) | +0.7, +0.3, +0.3 % |
| S-IC OECO | 38.58 | 38.61 (Table 4-1) | −0.1 % |
| S-II, 180 s | 8.02 | 7.75 (Figure 4-3) | +3.5 % (§9.5) |
| S-II, 300 and 400 s | 10.60, 14.19 | 10.60, 14.01 (Figure 4-3) | 0.0, +1.3 % |
| S-II CECO | 17.88 | 17.84 (Table 4-1) | +0.2 % |
| S-II, 503.6 s (low EMR) | 12.53 | 12.69 (Figure 4-3) | −1.3 % (§9.5) |
| S-II OECO | 14.29 | 14.3 (Figure 4-3) | −0.1 % |
| S-IVB, 557.1 s | 5.50 | 5.29 (Figure 4-3) | +4.0 % (§9.5) |
| S-IVB, 627.4 s | 6.05 | 5.98 (Figure 4-3) | +1.2 % (§9.5) |
| S-IVB cutoff | 6.75 | 6.73 (Table 4-1); 6.69 (Figure 4-3) | +0.3 %; +0.9 % (§9.5) |

**Trajectory** (the IU flight, §8.4, §10.4): CECO and OECO within §5 C's tolerances, the S-IC 1.6 and 4.7 m/s slow (11–14 m/s before §17). The S-IC's decay and the S-II ullage motors add 10.7 m/s from OECO to separation (FER Tables 4-2 and 4-3: 2,764.1 to 2,773.9 m/s, 9.8 m/s).

### 9.5 Known deviations

1. **The S-IC was 11–14 m/s (0.5 %) slow at CECO and OECO,** although its thrust, flow and masses matched the FER and its acceleration matched Figure 4-3 within 0.8 % wherever drag is negligible. *§14 placed it: of OECO's 14.0 m/s, 7.0 was the pitch history and 7.0 an 8.1 m/s F/m deficit (0.2–0.35 % low against the PFT, 0.4–0.8 % in the first 20 s) less 1.1 m/s from the higher pad; not drag. §17 closed it: AS-506's own command and Figure 5-3's thrust at the PFT's level leave 1.6 and 4.7 m/s at CECO and OECO, and the S-IC's integral of \|a_ng\| 1.26 m/s short, the frost it carries.*
2. **Early S-II acceleration is 2–4 % above Figure 4-3** from about 170 to 200 s (+3.4 % at 180 s). This is an inconsistency inside the FER, not a model error: Figure 6-3's stage thrust is flat at 5.138–5.160 MN from ESC + 4 s, the model's 5 × 1,028,303 N, and over the FER's own mass (Table 20-9 at mainstage less Figure 6-3's flow) it gives 8.03 m/s² at 180 s, where Figure 4-3 reads 7.75. The model's mass is within 0.06 % at mainstage and its CECO maximum within 0.2 % of Table 4-1. *§14.2: against the PFT the model agrees at 172–200 s (8.09 against 8.07 m/s² at 180–190 s) but runs 3–6.5 % above it at 166–172 s, which is not explained.*
3. **The S-II's low-EMR thrust was held at its 768 kN average** (§6.3) while Figure 6-3's declines through the phase. *Resolved in §17: the model follows Figure 6-3's line, 3.091 MN for the four engines at the valve step to 3.056 MN at OECO. Against Figure 4-3 it is 1.3 % low at 503.6 s (1.9 % before), Figure 4-3 being above the FER's thrust over mass; the PFT, too, runs up to 1 % above the line in the first 10 s after the step (§17.9 item 2).*
4. **The S-IVB's thrust in its first seconds of mainstage** was below Figure 7-2's steady value: Figure 4-3 times the FER's mass gives about 878 kN at 557 s, against 904.5 kN where Figure 7-2 starts (567 s). The model, at a constant 912 kN since §17, is 4.0 % above Figure 4-3 at 557 s; against the PFT it is +3.1 % at 556–560 s and within 0.08 % from 560 s (§17.7).
5. **Table 4-1's S-IVB maximum, 6.73 m/s²,** is more than Figure 7-2's thrust over Table 20-5's mass allows (6.68–6.70 m/s²). *Resolved in §17 on the measured side: the model's thrust follows AS-506's measured acceleration (the PFT, which Table 4-1 agrees with), 6.75 m/s² at cutoff; Figure 7-2, Table 7-1 and Figure 4-3 (5.98 at 627.4 s, 1.2 % below the model) are the thrust reconstruction's side, 1.0 % lower (§17.9 item 4).*
6. **Upper-stage masses were 150–360 kg high** (§9.1's unmodelled items; since §12 the S-IVB stack 75–125 kg). *Resolved in §17: within 34 kg after the S-IC's separation.*
7. **Other solid motors** (the S-IC and S-II retros, the S-IVB's TX-280 ullage motors) are not modelled. The S-II ullage motors are on/off thrusters on the translate-forward group, so a pilot can stop and restart them, and the U key fires them on the pad. *Resolved in §12: all are solid motors, which no control reaches.*
8. **The ramp shapes are linear,** fitted only to the FER's impulses and propellant.

### 9.6 Tests

| test | checks | depends on |
|---|---|---|
| `PropulsionModelTests` A6–A9 | schedule on the burn clock; start ramp; shutdown ramp after a cutoff and after depletion; a relight waits for the decay to end; scheduled stage Δv | mechanism only |
| `PropulsionModelTests` A10 (`testRatingRampImpulseIsIndependentOfStepAndWarp`) | a rating ramp through a minimal IU plan, in fixed 0.02 s and 0.007 s steps and the app's frames at 1×, 10× and 1,000×: its impulse (F0 + F1)/2 over it, its propellant and their split the same in every run, within 1e-6 and a cell's change for 1 ms per step the 1 ms minimum stretches; steps that ignore the cells' ends err by over 1e-4 | mechanism only |
| `SaturnVDataTests.testFirstMotionMassesMatchTheFER` (B3) | 2,899,008 kg at first motion to 1 kg, the ground-ignition 6,477,875 lb, every part, and the FER's interstage and spacecraft items against SP-4029's rows | FER Tables 20-1, 20-7, 20-9 (H); GIW (H) |
| `testEngineRatings` (B1, B2) | the F-1's flight rating and its schedule against Figure 5-3 at liftoff, CECO and 160 s; against Betts' rating; the J-2 settings; the S-II's high EMR against the J-2 rating and Table 6-1's flow; the S-IVB's thrust and Isp against Table 7-1 | FER (H tables, M figures), Betts, NTRS 20100032986 |
| `testTransientImpulsesMatchTheFER` (B2) | every start and shutdown ramp's impulse (or the S-II start's propellant), run through the engines, within 1 % of the FER's (the S-IVB's at the measured level, 1.0 % above them, §17) | FER §5.4, §6.4, §7.2, §7.4, Table 20-9 (H) |
| `testSICDrawStopsOnLOXDepletion` (A1) | depletion at exactly the unusable mass at 161.63 s with 13,954 kg of RP-1; the outboard decay's 3,634 kg ±5 % | FER (fitted, and H) |
| `testSIIMixtureRatioShift` (A2) | the J-2 start ramp; rating changes mid-burn change thrust, flow and split without a restart | FER (H) |
| `testEventTimelineThroughThePropellantModel` (B4) | §9.4's event masses (±0.1 % with the S-IC aboard, ±50 kg after; ±0.1–0.25 % before §17), the Table 4-1 maxima (±0.3 %, the S-IVB's since §17), Figure 4-3 at S-II OECO, the fitted depletions and residuals, the ullage propellant; the EMR shift applied as the IU applies it (ramp and decline) | FER |
| `testSIILowEMRFollowsFigure6_3` (§17) | the low EMR's line against Figure 6-3's samples (0.1 % rms, 0.25 % max) and §6.3's two thrusts (0.15 %, 0.05 %); constant Isp along the decline; the ramp's middle at 498.8 s; the figure's own step at 496.8 s | FER Figure 6-3 (M), §6.3 (H), PFT (§14.2) |
| `SaturnVFlightTests.testLiftsOffOnFirstStep` (C2) | the liftoff thrust mechanism; 34.35 MN ±1 % and 1.2 g | Figure 5-3 (M), §9.2.1 |
| `testVerticalSICFlight` (C3) | depletion at 161.63 s, RP-1, the OECO mass 664 kg above the FER's (bookkeeping), 38.61 m/s² ±0.3 % | FER |
| `testGimbalsSteerThroughTheTailOff`, `testStartRampAtTimeWarp` | the gimbals steer a decaying engine however it was cut; a start ramp gives the same Δv at 1×, 100× and 1,000× (the step cap holds from the start command) | mechanism only |
| `SaturnIUTests.testSICAscentMatchesApollo11`, `testFlightSequenceFollowsTheApollo11Timeline` | §8.8 | FER |
| `SaturnVControlTests.testTB5UllageBurn` | after burn 1's 147.13 s and decay, within 0.3 % of 135,102 kg | FER Table 20-5 |

**Values tests must not depend on**: the ramp shapes; the S-II start setting's Isp and EMR; the ullage motors' thrust history; Figure 4-3 and 5-3 readings beyond about 1 %; the fitted scales beyond the depletions and residuals they were fitted to.

---

## 10. Iterative guidance (M1 item 3, part 2: IGM)

Compiled on 2026-10-17 for the second half of the IU item: the LVDC's iterative guidance mode from its start at T3 + 42.4 s through the S-II and the S-IVB's first burn to the velocity cutoff. `Sources/OrbitCore/Guidance/IterativeGuidance.swift` holds the equations, `AS506Data.swift` ("Iterative guidance") the presettings, and `SaturnIU` the navigation inputs, the stage discretes, the EMR shift and the cutoff.

**Sources** (read directly, tables and equations checked against the page images):

- GE504 Figure 1-1 (the space-fixed frame), §3.1, §4.1.3–4.1.8, Figures 4-1, 4-5, 4-8, 4-9, 4-11 and 4-12, Tables 4-I, 4-III, 4-IV and 4-V (the into-orbit equations), Table 5-I (SA-504's presettings). H for SA-504.
- FER §6.1 and §6.5 (the EMR shift), §10 (Tables 10-2 to 10-5, Figures 10-3 and 10-4, the latter digitised: M on isolated stretches, L where the curves overlap or step), §11.3, Tables 2-2 and 4-5. AS-506's phase times, attitude commands, cutoff and insertion states.
- PFT Table B-II: AS-506's postflight (reconstructed) state every 2 s in PACSS 13, the LVDC's navigation frame, for the point-mass test's state at 200 s. Recomputing the PFT's and the FER's insertion elements from these states and FER Table 10-2's identifies the frame and the node definitions below (H).
- MAN506 §7, ASH §2.3 and Decher: descriptive, consistent with GE504 (M).
- The AS-512 LVDC material on Virtual AGC (an abridged flight-program listing that keeps only the mathematical utilities, the preflight program descriptions, a repeatable-flight-test time history) holds no IGM code or presettings.

AS-506's own IGM presettings (its operational trajectory and flight-sequence ICD 40M33626B) were not found. The model's are therefore derived as the LVDC's were, from the predicted vehicle, here the model's own (§10.3), with thresholds from SA-504 or inferred from AS-506's flight.

### 10.1 Frames, targets and inputs

| id | value | source | conf | notes |
|---|---|---|---|---|
| space-fixed frame | X_S, Y_S, Z_S of §8.1 (PACSS 13): X_S up at GRR, Z_S along the 72.058° azimuth | GE504 Fig. 1-1; FER, PFT | H | X_S is the plumb line at the pad: 28.6082° on the model's WGS-84 Earth (28.608° on the sphere before §15), as AS-506's geodetic vertical (§8.1). The IGM's [A] (Table 4-I) takes the latitude of X_S from the Earth's pole in the IU's frame. |
| [G] = [B][A] | X_4 along the descending node, Z_4 90° on in the orbit plane, Y_4 against the orbit normal | GE504 Table 4-I | H | [B] from i and θ_N. |
| R_T | 6,563,365 m: 100 n mi above the 6,378,165 m sphere | GE504 Table 5-I (SA-504's −μ/C3); MAN506 and TIS "100 n mi" | H | AS-506's LVDC cut off at 6,563,335 m (FER Table 10-2). |
| V_T, γ_T | √(μ/R_T) (circular: e = 0, C3 = −μ/R_T), 0° | GE504 Table 5-I | H | 7,793.02 m/s with the model's μ, 3.986004418 × 10¹⁴ m³/s² (SA-504: 3.986032 × 10¹⁴). |
| i | 32.531° | FER Tables 4-5 and 10-5, nominal | H (nominal), inferred (as the target) | The LVDC's insertion state gives 32.532° (Table 10-5), so the targets were within 0.002° of the nominal elements. SA-504's polynomial at 72.058°: 32.534° (with A_ZO = 72° and A_ZS = 36°, which GE504 does not print; inferred from the polynomials' geometry). |
| θ_N | 123.100°, eastward in the equator from the launch meridian fixed at GRR | FER Tables 4-5 and 10-5, nominal | H (nominal), inferred (definition and target) | The definition reproduces Table 4-5's actual 123.088° from the postflight state to 0.001°; LVDC 123.102°. SA-504's polynomial (as for i): 123.118°. |
| navigation | the model's state, rotated into the space-fixed frame, and its J2 gravity | — | — | Perfect navigation; the LVDC integrated its platform's velocity increments with its own gravity model. |
| F/m | the mean thrust acceleration over the last cycle (the cycle's sensed Δv over its length) | GE504 Fig. 4-5 (m/F) | H | τ = Vex/(F/m) once a stage's tau is measured. |
| BNVC | the S-II's characteristic velocity: thrust acceleration integrated from S-II engine start to T4 | FER §10.2.1 | H (definition) | AS-506's LVDC summed the platform increments and lost about 92 m/s through scaling (FER Figure 10-3: 91.8 m/s at 494.8 s). The model's sum is exact; its preset absorbs the difference (§10.3). |
| stage discretes | S-II cutoff: T4. S-IVB ignition: the J-2 at 90 % of its vacuum thrust (554.56 s) | GE504 §3.1.1 ("S-IVB stage ignition (90-percent thrust)") | H | |

### 10.2 What is implemented, and the departures from GE504

GE504's into-orbit path, every 1.7 s cycle (Fig. 4-1; the IU ends a step on the next cycle, so the cycles keep 1.7 s at any time warp): the time update (Fig. 4-12); the stage logic (Fig. 4-5) with T2 held at 0 once it runs out, the coast freeze (GATE) and the artificial tau mode (Table 4-III); the chi-tilde logic (Fig. 4-8, Table 4-IV): the stage integrals L, J, S, Q, P, U of Vex/(τ − t) and their "12" and Y/P combinations, range angle 1 with the ROV bias, the terminal frame [K] = [φ_T][G], the velocity to be gained with the gravity averaged between the vehicle and the target, ΔL3 and ΔT3 in two passes with the T′ update between them, χ̃_p and χ̃_y; the K1–K4 terms for the radius and the plane (Fig. 4-9, Table 4-IV p5); the steering angles χ″ = χ̃ − K + K·t (t = 2 s) rotated into the space-fixed frame (Table 4-IV p6); terminal guidance (K = 0) from T_T′ ≤ ε2; the high-speed loop and chi freeze from T_T′ ≤ ε4 with V + V_TC ≥ V_T (Fig. 4-11), then the cutoff at V_T − ΔV_B. The commands go through the IU's 1°/s rate limit (§8.1), as the pre-IGM ones do.

| item | GE504 (SA-504) | model | basis |
|---|---|---|---|
| end of stage 1 and the EMR shift | an MRS discrete (timed in SA-504's sequence), then a 50 s transition folding the flow change into τ2 and T2 | the IGM computes T1 = τ1(1 − exp(−(V_C − BNVC)/Vex1)), the burn time left to the preset characteristic velocity V_C, and when T1 ≤ 0 it commands the shift itself and enters stage 2; the IU steps the PU valve 2.8 s later | FER §6.1 ("upon attainment of a preprogramed stage characteristic velocity as sensed by the LVDC"), §10.2.1 ("entered when a time-to-go quantity T1i becomes zero or negative"); the FER does not give T1i's formula (inferred); the 2.8 s is the FER's 494.8 to 497.60 s |
| tau after the shift | the preset τ2 until the transition ends | artificial tau for C0′ = 9 s from τ2N, the preset τ2, then measured | FER Table 10-4: artificial tau 494.83–504.16 s |
| G_T | not computed on the unrotated into-orbit path | −μ/R_T² along ξ, computed with the targeting | GE504 omits it there (the averaged gravity needs it) |
| arctangents | one-argument tan⁻¹ of ratios as printed (two-quadrant): tan⁻¹(Z4/X4), tan⁻¹(Δξ̇/Δζ̇), tan⁻¹(−X_S3/X_S1) | atan2 for range angle 1 (atan2(Z4, X4)), χ̃_p and the commanded pitch χ_Y | X4 < 0 through the whole ascent (AS-506: −119° at the pad, −92° at insertion), so a two-quadrant tan⁻¹ puts φ_T 180° off; the commanded pitch passes −90° in the S-II; for χ̃_p a safeguard (Δζ̇ > 0 in a normal ascent) |
| cutoff | T_GO from a quadratic fit to the last three speeds (Table 4-V) | from the speed's present rate (thrust acceleration along the velocity plus gravity), the simulation ending a step on the predicted cutoff | with the app's steps (`Simulation.advance`) the cutoff lands on V_T − ΔV_B within 0.01 m/s (§10.4: under 0.0001 m/s); fixed 0.02 s steps that ignore the IU's event time overshoot it by up to 0.13 m/s |
| phase 3 | from the T4 interrupt | from the first IGM cycle after T4 (up to 1.7 s late; the steering is frozen through the coast either way) | the stage logic runs on the cycle |
| IGM start | TB3 + T_LET (40.671 s) | T3 + 42.4 s, AS-506's | FER Tables 2-2 and 10-4 |
| S-II engine out | Fig. 4-6: on the engine-out discrete, T1, T2 and τ2 times 5/4 | T2, τ2 and τ2N times the engines the stage 2 presettings assume over those left (4/3 for an outboard J-2, 1 for the centre engine); T1 from the characteristic velocity; T2 no longer reset at the shift (§16) | AS-506's planned S-II CECO leaves four engines in stage 2; AS-506's own "expanded IGM" was not found (§16.3 item 2) |
| T3 bound | none: L3′ = Vex3 ln(τ3/(τ3 − T3′)) and ΔT3 = ΔL3(τ3 − T3′)/Vex3, with T3′ = T3 between the two passes (Table 4-IV); Fig 4-5 holds T1, T2 and Tc at 0 once they run out, but not T3 | T3′ at each pass, and the T3 returned, held 1 s inside the logarithm's domain, [1 s, τ3 − 1 s]; a ΔT3 that would take T3 out of it puts T3 on the bound, with ΔL3 = L3(T3) − L3′ so that L3 is the closed form's there (before: T3′ ≤ τ3 − 1 s at the first pass only) | an S-IVB that cannot reach the target (the S-II dropped by hand before IGM start, the app's manual staging) makes the linearised ΔT3 overshoot τ3: unbounded, T3 went to −1,016 s on the IU flight's first cycle and NaN by its fifth on 912 kN, the yaw command on its 45° limit (on 903 kN it happened to converge); bounded, it lands within 5 s of τ3, settles in a few cycles and counts down with the clock (§10.6). The lower end keeps L_Y′ > 0 when no S-II is left in it (T3′ = 0 divides by zero). A flight that reaches the target never meets the bounds: the nominal, Apollo 13 analogue and S-IC engine-out flights are unchanged to the bit. How the LVDC's scaled arithmetic behaved here is not known |
| not modelled | steering misalignment correction (SMC), direct staging, rotated terminal conditions, range angle 2 (ε1), terminal-condition updates (ε3) | — | AS-506 ran SMC from 221.5 s (FER Table 10-4); it corrects a thrust misalignment the model does not have. ε1 and ε3 never apply into orbit with SA-504's values. |

### 10.3 Presettings

| symbol | model | SA-504 (GE504 Table 5-I) | basis | conf |
|---|---|---|---|---|
| Δt (cycle) | 1.7 s | 1.7 s | GE504 | H (SA-504), M (AS-506) |
| IGM start | T3 + 42.4 s | TB3 + 40.671 s | FER Table 2-2 | H |
| Vex1, Vex2, Vex3 | 4,178.3, 4,203.5, 4,234.6 m/s | 4,169.23, 4,204.26, 4,170.57 m/s | the model's S-II high and low EMR and S-IVB settings, thrust over flow (§9.2); the low EMR's decline keeps its Isp. Before §17: 4,175.4, 4,200.5, 4,192.8 | model |
| τ2, τ3 | 345.5 s, 773.5 s | 309.23 s, 665.86 s | the model's mass at the shift command over four low-EMR J-2s' flow at the valve step (254,002 kg over 735.34 kg/s, 345.42 s; 347.5 s before §17); at S-IVB 90 % thrust over the J-2's flow (166,588 kg, 773.5 s when set); rounded to 0.5 s. The mass there is now 166,414 kg (772.7 s); the presetting is kept, as the IGM measures τ from F/m once the S-IVB thrusts | model |
| T2, Tc, T3′ | 53.4, 6.3, 144.8 s | 99.886, 4.718, 120.565 s | AS-506's shift command to S-II OECO (494.8 to 548.22 s), T4 to 90 % thrust in the model (548.24 to 554.5 s), and 554.5 to 699.34 s | inferred from the FER |
| V_C (shift) | 3,908 m/s | — (a discrete) | AS-506's own window (§17.6): its IGM commanded the shift at 494.8 s, 171 cycles after its start, so its preset lay between the S-II's characteristic velocity a cycle before and at the command, 3,894–3,921 m/s on the PFT; the middle. The model reaches it at 493.75 s and commands on its 494.76 s cycle. (3,906 m/s, fitted to that cycle, before §17.) The LVDC's own preset, in its scaled terms, is not known | PFT (H), the middle of a window |
| C0′ | 9.0 s after the shift, 6.0 s after S-IVB ignition | none, 25 s | FER Table 10-4: 9.33 and 6.86 s, from cycle starts | L |
| ROV, t | 1.5, 2.0 s | the same | GE504 | M |
| ε2 | 35 s | 10 s | FER Table 10-4: terminal guidance 34.19 s before the cutoff command, on the reading that the FER's "terminal guidance" ("begin chi bar steering", Figure 10-4) is GE504's K = 0 mode, whose dropped K terms match the 2–2.5° nose-down step at 665 s in Figure 10-4 | L (inferred) |
| ε4, V_TC | 8 s, 300 m/s | the same | GE504; AS-506's chi freeze came 7.70 s before its cutoff (FER Table 10-4) | H (SA-504), M |
| ΔV_B | 1.46 m/s | 2.0275 m/s | the model's own gain from the cutoff command to insertion, measured: the J-2's thrust decay (§9.2) and the APS ullage burn, so it inserts at V_T (1.45 m/s at §10's 903 kN). AS-506's LVDC gained 1.85 m/s over the same 10 s (FER Table 10-2: 7,791.43 to 7,793.28 m/s), vents included. | model |
| R_T, γ_T, i, θ_N, μ | §10.1 | 6,563,365 m, 0, polynomials in azimuth, 3.986032 × 10¹⁴ | §10.1 | H |

### 10.4 Results against AS-506

The IU flying the whole ascent as `testIGMFliesApollo11ToItsParkingOrbit` does (fixed 0.02 s steps, and the app's steps in the high-speed loop); the IGM's events come on its cycles, as the FER's (Table 10-4: "for the start of the computation cycle"). Regenerated after §17; the values before it are in brackets:

| event | model (s) | AS-506 (s; FER Tables 2-2 and 10-4) |
|---|---|---|
| IGM phase 1 | 204.04 | 204.07 |
| EMR shift command, IGM phase 2 | 494.76 | 494.83 |
| PU valve step (the ramp's start; its middle 498.76) | 497.56 | 497.60 (effective step 498.7–498.9, PFT) |
| T4 | 548.24 | 548.24 |
| IGM phase 3 (steering frozen) | 549.16 | 548.2 |
| S-IVB steering (artificial tau) | 555.96 | 555.57 |
| terminal guidance | 664.76 (cutoff − 34.16) | 665.15 (cutoff − 34.19) |
| chi freeze | 691.96 (cutoff − 6.96) | 691.64 (cutoff − 7.70) |
| velocity cutoff command | 698.92 (702.74) | 699.34 |
| T5 | 698.94 (702.76) | 699.57 |

| state | quantity | model | AS-506 LVDC (FER Table 10-2) |
|---|---|---|---|
| S-II OECO (T4) | radius | 6,560,356 m (6,560,304) | 6,559,961 m |
| | speed | 6,916.22 m/s (6,900.38) | 6,915.96 m/s |
| | flight-path angle | 0.684° (0.698°) | 0.614° |
| velocity cutoff | radius | 6,563,330 m | 6,563,335 m |
| | speed | 7,791.557 m/s (V_T − ΔV_B) | 7,791.43 m/s |
| | flight-path angle | −0.0009° | −0.0015° |
| | commanded pitch | −111.7° | OT −112.4°, LVDC −113.6° (Figure 10-4) |
| insertion (cutoff + 10 s) | speed | 7,793.01 m/s | 7,793.28 m/s |
| | inclination | 32.531° | 32.532° (nominal 32.531°, actual 32.521°) |
| | descending node | 123.0975° | 123.102° (nominal 123.100°, actual 123.088°) |
| | apogee × perigee above 6,378,165 m | 185.2 × 185.1 km | 186.0 × 185.2 km (actual 186.0 × 183.2) |
| | eccentricity | 0.000008 | 0.00006 (Table 10-5: 0.00007) |
| | period | 88.19 min | 88.20 min |

Commanded attitude against FER Figure 10-4 (degrees; operational trajectory, OT, and the LVDC's own):

| t (s) | pitch, model | OT | LVDC | yaw, model | OT | LVDC |
|---|---|---|---|---|---|---|
| 212 | −62.6 | −62.5 | −61.3 | −0.27 | −0.08 | −0.36 |
| 240 | −65.1 | −65.1 | −64.1 | −0.23 | 0.18 | −0.27 |
| 300 | −70.5 | −70.8 | −70.0 | −0.14 | 0.36 | −0.11 |
| 400 | −81.1 | −81.6 | −81.6 | 0.00 | 0.55 | 0.09 |
| 450 | −86.7 | −87.5 | −86.5 | 0.07 | 0.59 | 0.21 |
| 500 | −92.0 | −91.0 | −92.5 | 0.13 | 0.44 | about 0.6 |
| 548 | −97.4 | −96.5 | −97.8 | 0.17 | 0.51 | 0.61 |
| 580 | −101.6 | −100.7 | −99.1 | 0.21 | 0.60 | 1.02 |
| 600 | −103.6 | −103.4 | −102.8 | 0.22 | 0.79 | 1.30 |
| 650 | −108.7 | −108.7 | −108.7 | 0.29 | 0.77 | 1.28 |
| 680 | −111.7 | −112.6 | −113.8 | 0.48 | 0.81 | 1.24 |

The pitch follows the OT within 1.1° throughout, including the pitch-up at IGM start from the tilt arrest's attitude (to −62.6° at 212 s; AS-506's peaked at −62.5° on the OT and −61.3° on the LVDC). The yaw follows AS-506's LVDC within 0.15° to 450 s, where the OT ran 0.3–0.5° above the LVDC and 0.4–0.6° above the model; from 500 s it stays below both curves, by up to 1.1° against the LVDC (at 600 s) and 0.6° against the OT. After the cutoff the IU's slew to the local horizontal is 6.1°, as AS-506's was about 6° (§8.6). History of the cutoff: 704.07 s before §11's aerodynamics, 702.87 s before §12's motors, 702.75 s before §13's mass characteristics, 702.74 s on §14's sphere, 704.98 s on §15's WGS-84 pad, 701.52 s after §17's S-IC (`NominalFlight`'s steps), 698.92 s now (698.83 s in `NominalFlight`'s).

**Point mass from AS-506's state.** `IterativeGuidanceTests` flies a point mass with this section's S-II and S-IVB performance (768 kN at low EMR, 903 kN on the S-IVB: it tests the guidance and was not refitted in §17) from AS-506's postflight (PFT) state at 200 s (6,464,247; 44,119; 264,596 m and 576.4; 120.7; 2,884.5 m/s in PACSS 13; mass 608,178 kg, estimated), with its own V_C (3,652 m/s: its characteristic velocity is summed from 200 s), ΔV_B (1.6 m/s, no decay) and τ2 (347.0 s, from its mass); the rest are §10.3's. It cuts off at V_T − ΔV_B within 0.01 m/s, 49 m from R_T, at γ 0.0007° and 0.001° from the target plane, about where AS-506 did.

### 10.5 Known deviations

1. **The cutoff was 3.4 s after AS-506's,** from a longer S-IVB burn. *Resolved in §17: 0.42 s before it (698.92 s; 698.83 s in `NominalFlight`'s steps), the residuals closed stage by stage (§17.7).* Before: 150.5 s from STDV open against 147.1 s. The model reaches S-II OECO 15.6 m/s slower than AS-506 (the S-IC's 11–14 m/s deficit, §9.5, and a few m/s more in the S-II), about 2.3 s of S-IVB burn at its final 6.7 m/s²; the other 1.1 s is not broken down (the model's S-IVB is 88–113 kg heavier, §12, and its OECO state 341 m higher at a 0.08° steeper flight-path angle). AS-506's own burn was 3.4 s longer than predicted, its S-II having cut off 3.5 s early and 22.8 m/s below nominal (FER §7, Table 4-2; the link is inferred). *§14.3–§14.4 break the 3.40 s down by sequential state injection: the S-IVB 1.52 s (its F/m 0.9–1.0 % below the PFT's acceleration), the S-II 1.00–1.08 s (at its EMR transition and in the low-EMR phase), the S-IC handover 0.80–0.88 s net of the spherical pad, which hides 0.9–1.9 s of it. Only the S-IVB's share is robust: the split between the S-IC and the S-II depends on the measure, and the S-II's own split is untested (§14.4, not established 4–5).*
2. **Yaw from 450 s** stays below AS-506's, by up to 1.1° against the LVDC (at 600 s) and 0.6° against the OT; before that it follows the LVDC within 0.1°. *§14.3: against AS-506's thrust direction (PFT) the model's yaw is within 0.23° at 240–680 s outside staging; the gap is between Figure 10-4's LVDC command and AS-506's thrust direction, which differ by 0.5–0.9° after 450 s (perhaps the LVDC's steering misalignment correction).* With X_S on the radial instead of the plumb line (before the review of 2026-10-17), the S-IC left 6 m/s more crossrange velocity at IGM start and the early yaw was 0.6° below the LVDC's.
3. **The chi freeze comes 7.0 s before the cutoff** (7.4 s before §17), against AS-506's 7.70 s: the ε4 test runs on the 1.7 s cycle, so the freeze falls 6.3–8 s before the cutoff.
4. **Terminal guidance as ε2 = 35 s** rests on reading the FER's "begin chi bar steering" as GE504's K = 0 mode (§10.3).
5. **The model's presettings are its own vehicle's,** not AS-506's (§10.3); V_C is the middle of AS-506's own window (§17.6).
6. **Phase 3 starts on the first cycle after T4,** 0.9 s after it here; the steering is frozen through the coast either way.
7. **Perfect navigation and an exact BNVC;** no SMC or direct staging. *An S-II engine out scales the stage 2 presettings since §16.*
8. **The model inserts at circular speed,** where AS-506's vents left the LVDC 0.22 m/s above it (186.0 × 185.2 km).

### 10.6 Tests

| test | checks | depends on |
|---|---|---|
| `IterativeGuidanceTests.testStageIntegralsAreTheThrustMoments` | Table 4-IV's closed forms of L, J, S, Q, P, U against Simpson integrals of the thrust acceleration's moments (1 part in 10¹⁰) | GE504 (H) |
| `testT2HoldsAtZeroWhenTheSIIBurnsLonger` | an S-II burning 15 s past T2 leaves T2 at 0 in stage 2, T1 at 0 and Tc unchanged | GE504 Fig. 4-5 (H) |
| `testIGMFliesAPointMassFromAS506StateToTheTargetOrbit` | from the PFT state at 200 s: the cutoff at V_T − ΔV_B (0.01 m/s), R_T (100 m), γ_T (0.005°), i and θ_N (0.002°); the shift command (494.8 ± 3 s), S-II OECO (548.2 ± 3 s) and cutoff (699.34 ± 4 s); terminal guidance and the chi freeze at their times to go (±2 s); the steering frozen on every cycle from the S-II cutoff to the S-IVB's 90 % thrust, and on no other before the high-speed loop; the pitch within 3° of Figure 10-4's LVDC at 240, 400, 548 and 680 s | PFT Table B-II (H); FER Tables 2-2, 4-5, 10-4 (H), Figure 10-4 (M) |
| `SaturnIUTests.testIGMFliesApollo11ToItsParkingOrbit` | X_S at the plumb line's 28.6084° (±0.001°); the commands within 2° in pitch and 0.8° in yaw of the OT at 212–680 s, and −112.4 ± 2° at the cutoff; the command unchanged through the coast; S-II OECO within 1 km, 5 m/s and 0.15° of the LVDC's state (30 m/s and 0.15° before §15, 35 m/s and 0.25° between §15 and §17); the cutoff on V_T − ΔV_B within 0.01 m/s (the app's steps in the high-speed loop), and within 50 m, 0.25 m/s and 0.005° of the LVDC's; at insertion i 32.532 ± 0.003°, θ_N 123.102 ± 0.006°, apogee 186.0 ± 1 km, perigee 185.2 ± 0.5 km, e < 0.0002, period 88.20 ± 0.02 min | FER Tables 10-2 and 10-5 (H), Figure 10-4 (M) |
| `testFlightSequenceFollowsTheApollo11Timeline` | §8.8: the IGM's events against FER Tables 2-2 and 10-4 within a cycle (phase 3 within a cycle of the model's own T4), the PU valve step exactly 2.8 s after the shift command, phase 3 a whole number of 1.7 s cycles after it, the slew after the cutoff | FER |
| `testIGMCyclesStay1Point7SecondsApartAtTimeWarp` | stepped as the app does at 10× warp, the IGM cycles 1.7 s apart (±0.0001 s) | GE504 Table 5-I (Δt) |
| `testEarlierTimeBaseEventsDropWhenTheNextStarts` | with the S-II dropped by hand at 200 s, the IGM still starts and steers the S-IVB; at 260 s its T3 within its bounds and the commands in the plane (yaw within 3°) and lofted (pitch between −15° and −114°); the whole log from T4, with no terminal guidance (the entry was left out before the T3 bound) | §10.2 |
| `IterativeGuidanceTests.testIGMStaysFiniteWhenTheSIVBCannotReachTheTarget` | the point mass with the S-II dropped at 200, 201.5 and 210 s, on 903 and 912 kN, to 700 s: T3 on the first coast cycle within 5 s of τ3, then counting down with the clock within 0.5 s a cycle (0.22 s) from 10 s after the S-IVB's 90 % thrust; every cycle's T3 in [1 s, τ3 − 1 s], every command finite, the yaw within 3° (1.9°) and the pitch between −15° and −114° (−21° to −94°); no terminal guidance or high-speed loop. Unbounded, the 201.5 s drop ran T3 from 151 s to −162 s, −1.3 × 10⁴ s and on, the yaw on its 45° limit | §10.2 (model) |
| `IterativeGuidanceTests.testT3RunOutByTheClockRestartsFromItsBound` | an S-IVB cycle late by T3 + 300 s, T3 + 1 ns and T3 exactly: T3 restarts from the 1 s bound, finite, with finite commands (unbounded: T3 −1.2 × 10⁴ s, 6 × 10²⁵ s and NaN) | §10.2 (model) |
| `testSIVBCutoffBeforeTheIGMStartLeavesNoIGM` | with the S-II dropped at 163 s and the S-IVB cut at 180 s, T5 drops the IGM's start: no IGM afterwards | — |

### 10.7 Remaining gaps

1. AS-506's own IGM presettings (operational trajectory, ICD 40M33626B), and its formula for T1i from BNVC.
2. SMC and direct staging (*the S-II engine-out logic: §16, as GE504's; AS-506's expanded IGM is still missing*); navigation errors and the LVDC's gravity model and BNVC scaling.
3. The S-IVB second burn (TLI) is M2: GE504's out-of-orbit path and AS-506's restart presettings.
4. The model's 15.6 m/s speed deficit at S-II OECO, mostly the S-IC's (§9.5, §11.5): about 2.3 s of the cutoff's 3.4 s delay; the other 1.1 s is not broken down (§10.5). *Broken down in §14, closed in §17: +0.26 m/s at S-II OECO.*

**Values tests must not depend on**: V_C beyond the shift command's time; C0′; ε2; ΔV_B beyond insertion at circular speed; the yaw beyond 0.8° of the OT; the point mass's burn times beyond a few seconds.

---

## 11. Aerodynamics and the launch-day atmosphere (M1 item: aerodynamics)

Compiled on 2026-10-17 for the launch stack's aerodynamics. `Sources/OrbitCore/Vessel/Aerodynamics.swift` holds the model (`AerodynamicModel`). `AS506Data.swift` holds the data under "Aerodynamics" and "Launch-day atmosphere". The day's air is a `SoundingAtmosphere` (`Atmosphere.swift`). The simulation carries it in `Simulation.atmospheres`, because the solar system is shared between scenarios; `VesselLibrary.apollo11OnPad(in:)` installs it.

**Sources.** Figures were read from page images and digitised against fitted gridlines (M unless marked). Each was checked independently by a second reader.

- **D5:** Boeing D5-15796-1, *Saturn V Aerothermodynamics Flight Evaluation Summary, AS-501 through AS-503* (19 June 1969; NTRS 20160013592).
  - §2.3: the axial-force method and its statements (H).
  - Fig. 2-8: the forebody coefficient, AS-502/503 curve (the vehicle without base flow deflectors, as AS-506).
  - Fig. 2-7: the S-IC base pressure differential flown on AS-503, against altitude and, for the first seconds, against time.
- **REF504** §3.1 and Figs. 3-1 to 3-4: the design curves for C_A, C_Nα and the centre of pressure. Those of the S-IC flight configuration come from TM X-53517 (1966), those of the S-II flight configuration from R-AERO-AD-66-14 (March 1966). Also its S-IVB free-molecular drag (H).
- **TM X-53770:** C. E. Walker, *Results of Several Experimental Investigations of the Static Aerodynamic Characteristics for the Apollo/Saturn V Launch Vehicle* (21 August 1968; NTRS 19690009748).
  - Wind-tunnel C_Nα and centre of pressure (Fig. 22(a)). They overlay the design curves within its ±6 % and ±0.2 caliber bands up to about M 5.5. At M 6–7.8 they put the centre of pressure 0.23–0.33 caliber further forward and C_Nα up to 6.6 % lower; q is under about 2 kPa there.
  - Power-off axial coefficients (Fig. 28).
  - The reference: 396 in, moments about STA 100, the S-IC gimbal station (H).
- **TM X-53587** (aborted vehicle, 1967): the power-on/off difference and the 1966 liftoff base-force formula, for comparison only.
- **FER Appendix A:**
  - Table A-1, surface observations (H).
  - Figs. A-1 to A-4, winds: speed, direction and the pitch and yaw components, every 0.5–1 km to 56 km.
  - Figs. A-6 and A-7, deviations of temperature, pressure and density from PRA-63.
  - Tables A-4 and A-5, wind extremes (H).
  - FER Table 4-1 and Fig. 4-4: Mach 1, max Q and the q and Mach histories.
- **PRA-63:** NASA TM X-53139, *A Reference Atmosphere for Patrick AFB, Florida, Annual (1963 Revision)*, Table III: T, p, ρ and speed of sound every 250 m (H).
- **TM X-64796** (1973): the AS-506 surface and wind values again, and density extremes of −0.2 % at 8.25 km and +4.4 % at 14.25 km (H).
- **PFT** Table B-III (H): altitude and Earth-fixed velocity every second; with Fig. 3-7, q and Mach.
- **MAN506** Figs. 2-4 and 2-5: the predicted axial force and q, for comparison.

Not found online: TM X-53517 itself; TM X-53599 (range-safety aerodynamics, with full-stack power-on/off C_A); the R-AERO-AD memos; and an AS-506 aerothermodynamic evaluation (Boeing D5-15556-6, if it exists).

### 11.1 The model

| item | model | source | conf |
|---|---|---|---|
| reference | D = 396 in (10.058 m), S = π D²/4 = 79.46 m²; centre of pressure in calibers forward of the stage gimbal station: STA 100 for the S-IC configuration (H), STA 1664 for the S-II (the S-II gimbal, inferred) | TM X-53770, REF504 | H; S-II origin L |
| axial force, S-IC configuration | F_A = C_Af(M) q S + F_Ab. With the F-1s running, F_Ab = −0.798 (P_b − P∞) S, with P_b − P∞ against altitude; "base pressures … are more a function of altitude than Mach number" (D5 §2.3). With them off, F_Ab = C_Ab(M) q S. Both terms act along −x: the forebody term scales with cos α, the powered base term does not. | D5 Figs. 2-7 and 2-8; TM X-53770 Fig. 28 (power-off: a wind-tunnel model with base flow deflectors at a twentieth of flight Reynolds number, L for flight) | M |
| base differential, below 1 km | −260 Pa at liftoff (the CoM 33 m up on the pad), −236 Pa by 10 s (the CoM at about 138 m); then interpolated to −1,030 Pa at 1 km. D5 says the base pressure follows range time up to about 1 km. | D5 Fig. 2-7 time panel (M); interpolation (L) | M–L |
| normal force | C_N = C_Nα(M) sin α \|cos α\|, at X_cp(M); plus η C_dc A_p (sin²α − sin²4°) q beyond 4° at the planform centroid of the parts' bounding cylinders (η C_dc = 0.8: a generic slender body, Jorgensen, NASA TR R-474). TM X-53770 finds C_N linear to about ±2–4°. | REF504 Figs. 3-3 and 3-4 (= TM X-53517); crossflow L | M; crossflow L |
| moment | the normal force's moment about the centre of mass; the axial force acts on the axis. No damping derivative; roll is symmetric. | — | — |
| configurations | the first model whose parts are all aboard: S-IC configuration (S-IC, S-II, S-IVB), then S-II configuration (S-II, S-IVB), then S-IVB. A jettisoned stage keeps the generic drag (`bodyDragCoefficient` 0.45 on its largest cross-section, along the airflow). | REF504 §3.1 | — |
| S-II configuration | C_A 0.283 at M 5 falling to 0.227 at M 8 (held below M 5); C_Nα 0.0500 per degree; X_cp 2.858–3.402 calibers forward of STA 1664. REF504's curve is "with LES"; nothing was found for after the LET jettison (q under 0.1 kPa by then). | REF504 Figs. 3-2 to 3-4 | M |
| S-IVB | C_D 2.8024 on 33.47 m², along the relative wind, no lift, no moment ("about 0.2 pound" of drag in parking orbit) | REF504 §3.1 (H; from R-AERO-AD-66-54) | H |
| air | velocity relative to the rotating atmosphere and the wind; Mach from the local speed of sound; tables held beyond their ends (M 8) | — | — |

**Stability.** The centre of pressure lies forward of the centre of mass except near M 0.9–1.0 (about 63–66 s on AS-506), where it is level with the CoM or up to 0.1 caliber aft of it. At liftoff it is 3.50 calibers forward of the gimbal, 0.75 caliber (7.5 m) ahead of REF504's centre of gravity (Fig. 3-15). The stack is therefore aerodynamically unstable, and the F-1 gimbals hold it. At max Q the aerodynamic moment is about 150 MN·m per radian of angle of attack, about 0.16° of outboard-engine deflection per degree to trim (control research notes, inferred).

### 11.2 Coefficients (tabulated in full in `AS506Data.swift`)

| M | C_Af (D5 Fig. 2-8) | C_Nα per degree (REF504 Fig. 3-3) | X_cp, calibers (REF504 Fig. 3-4) | C_A, REF504 design total (comparison) |
|---|---|---|---|---|
| 0–0.3 | 0.141 | 0.0773–0.0785 | 3.50–3.44 | 1.14 → 0.348 |
| 0.5 | 0.142 | 0.0818 | 3.334 | 0.383 |
| 0.8 | 0.203 | 0.0934 | 3.002 | 0.526 |
| 0.95 | 0.343 | 0.0998 | **2.795** (most aft) | — |
| 1.0 | 0.397 | 0.0999 | 2.842 | 0.695 |
| 1.25 | **0.562** (peak) | 0.0917 (interpolated) | 3.39 (interpolated) | 0.79 (interpolated) |
| 2.0 | 0.430 | 0.0744 | 4.352 | 0.500 |
| 3.0 | 0.361 | 0.0712 | 4.453 | 0.329 |
| 5.0 | 0.229 | 0.0699 | 4.441 | 0.154 |
| 8.0 | 0.147 | 0.0802 | 5.10 | −0.155 |

Base differential P_b − P∞, AS-503 (D5 Fig. 2-7, M; L at 6.5–10 km): −1.03 kPa at 1 km; minimum −3.60 kPa near 6 km (drag up to 228 kN); zero at 9.6 km; peak +4.15 kPa at 17 km (a forward push of 263 kN); +0.73 kPa at 35 km; zero by 50 km.

**Comparison.** Along AS-506's trajectory the flight-evaluated total axial coefficient (forebody plus base) is:

| point | total C_A |
|---|---|
| subsonic | 0.29–0.34 |
| M 1.1–1.3 | 0.51–0.53 |
| max Q | 0.40 |

This agrees with MAN506's predicted AS-506 force: C_A of 0.40 at max Q, and a peak of 1.48 MN against 1.36 MN. The 1966 design curve that REF504 flew is 45–61 % higher between M 0.7 and M 2.7 (the flight values are 31–38 % lower). REF504 also adds a separate 56.5 kN liftoff base force, zero after 4 s, on top of C_A q S; AS-503's measured base pressure gives about 16.5 kN (inferred, research notes).

### 11.3 Launch-day atmosphere (16 July 1969, 13:32 UT)

- **Thermodynamic state.** PRA-63 × (1 + FER deviation) at 0–56 km, every 1–2 km plus the Mach-1 and max-Q altitudes, 7.8 and 13.6 km. The speed of sound is PRA-63's × √(1 + ΔT). Pressure and density interpolate log-linearly between levels.
- **Above 56 km.** The FER merged its measured data into the U.S. Standard Atmosphere. The model fades each quantity's ratio to US-1976, and the wind, out linearly over 56–66 km (inferred).
- **Winds.** The measured profile from FER Figs. A-3 and A-4: W_x along the 72.058° flight azimuth and W_z towards its right. They are turned to east and north and applied horizontally uniform, as one sounding.

| altitude | launch day vs US-1976 (density) | note |
|---|---|---|
| surface | 0.946 | 101,905 Pa and 302.0 K against the 102,030 Pa and 302.6 K measured (Table A-1) |
| 3–9 km | 0.98–1.01 | about standard near Mach 1 |
| 12–20 km | 1.08–1.17 | **max Q (13.6 km): 1.151**; q at AS-506's max-Q state (500.7 m/s air-relative) comes out 35.16 kPa against Table 4-1's 35.2 |
| 20–40 km | 1.03–1.09 | |
| 44–56 km | 1.14–1.17 | |

| wind feature | value |
|---|---|
| surface | 3.3 m/s from 175° (pad pole, 18.3 m) |
| below 7 km | 3–9 m/s from 170–220°: a tail wind of 1–7 m/s and 3–6 m/s from the right |
| high-q peak | 9.5 m/s from 296° at 11.3 km (Figs. A-1 and A-2; Table A-4: 9.6 m/s from 297° at 11.40 km). In the model W_x is 6.6 m/s and W_z 6.7 m/s, 9.4 m/s from 298°; the W_x peak of 7.1 m/s at 11.15–11.2 km falls between its levels. |
| above 16 km | easterlies, rising to about 60 m/s at 50–56 km: head winds of 6–58 m/s (14–58 m/s from 20 km) |

### 11.4 Results against AS-506 (`testSICAscentMatchesApollo11`, the IU flight)

*This table is §11's, with `pitchScale`. Since §17 the IU flies AS-506's own command with the F-1's thrust at the PFT's level: Mach 1 at 66.28 s, max Q 35.27 kPa at 83.06 s, CECO 1,977.36 m/s, 23.247°, OECO 66.61 km, 2,759.45 m/s, 19.407°, S-II OECO 6,916.22 m/s and the cutoff at 698.92 s (§8.4, §10.4, §17.2).*

| quantity | model (with pitchScale 1.025) | AS-506 | before §11 (US-1976, constant C_D) |
|---|---|---|---|
| Mach 1 | 66.7 s, 7.84 km above the pad | 66.3 s, 7.8 km (Table 4-1) | 65.5 s |
| max Q | **34.9 kPa at 83.3 s**, 13.6 km above the pad | **35.2 kPa at 83.0 s**, 13.6 km | 32.1 kPa at 76.4 s |
| q at 40, 60, 80, 90, 100, 120 s (kPa) | 8.55, 22.2, 34.2, 32.2, 23.4, 8.67 | 8.71, 22.9, 34.3, 32.4, 23.6, 8.7 (Fig. 4-4) | — |
| peak axial force | 1.38 MN at 72 s | 1.36 MN at 75 s (D5's method on the PFT trajectory, inferred); 1.48 MN at 71–72 s (MAN506, predicted) | — |
| climb above the pad at 10, 20, 40, 60, 80, 100 s (m) | 105, 473, 2,277, 6,039, 12,287, 21,259 | 105, 478, 2,305, 6,094, 12,345, 21,282 (PFT) | — |
| Earth-fixed speed at 40, 83, 100, 135.2 s (m/s) | 134.7, 499.2, 761.5, 1,610.9 | 136.5, 504.0, 768.0, 1,621.8 (PFT) | — |
| CECO: space-fixed speed, γ, heading | 1,967.7 m/s, 23.15°, 76.28° | 1,979.0, 22.957°, 76.315° | 1,962.9, 23.16°, 76.37° |
| OECO: altitude, space-fixed speed, γ, heading | 66.07 km, 2,750.5 m/s, 19.10° (fitted), 75.37° | 66.1 km, 2,764.1, 19.114°, 75.439° | 66.1, 2,745.1, 19.09°, 75.44° |
| S-II OECO speed | 6,900.7 m/s (6,900.36 with §12's motors, 6,900.38 with §13) | 6,915.96 (Table 10-2) | 6,892.8 |
| S-IVB velocity cutoff | 702.87 s (702.75 with §12, 702.74 with §13) | 699.34 s | 704.07 s |

- **Max Q** was 9 % low and 7 s early before, and Mach 1 0.8 s early. That came from the US-1976 atmosphere, up to 15 % thinner than the day's air at 12–20 km. Flying AS-506's own trajectory through US-1976 gives 32.3 kPa at 76–77 s (research notes, inferred), the model's old value.
- **The climb** matches the PFT within 60 m and the speed within 1.4 %. The S-IC is now 11–14 m/s slow at CECO and OECO, against 16–19 m/s before.
- **Angle of attack.**
  - In the first 40 s the low-level winds (3–6 m/s against an airspeed under 140 m/s) give a total of 15° at 5 s and 10° at 10 s (9.5° in yaw), 3.6° in yaw at 30 s and 2° at 40 s, while q is under 9 kPa.
  - It peaks at 1.8° at 53 s and stays under 1.3° from 60 s; near max Q it is about 0.5°.
  - AS-506's Q-ball reached 1.82° in pitch at 117.1 s and 1.42° in yaw at 73.0 s (FER Table 11-2).

### 11.5 Known deviations

1. **The pitch program needed a 2.5 % scale.** Unscaled, the S-IC ended 1.3° steep (OECO γ 20.37°) and 1.8 km high. Neither the aerodynamics nor the climb was the cause: what the scale compensated was mostly AS-506's different command, partly its unmodelled late trim (§14.1). *Resolved in §17: the IU flies AS-506's command; OECO is 0.29° steep without the late trim.*
2. **The S-IC remained 11–14 m/s slow** at CECO and OECO (*1.6 and 4.7 m/s since §17*), and 0.7–1.3 % slow in Earth-fixed speed from 40 s. The S-IC's thrust and flow match the FER (§9). *§14.2 places it: half the pitch history, half an F/m deficit against the PFT; drag is not the source, and the missing controlled release is worth +0.28 m/s to the model.* The candidates considered before:
   - the design C_Nα and centre of pressure;
   - the forebody C_Af at flight Reynolds number, of which D5's curve is a prediction;
   - the controlled release;
   - the base differential below 1 km.
3. **Angle-of-attack history.** The model's α near max Q is smaller than AS-506's Q-ball values. The FCC has no integral term and the model has neither the Q-ball nor AS-506's wind biasing, so attitude and winds combine differently.
4. **No aerodynamic damping, no fins' roll effects, no Mach-dependent base flow on the S-II and S-IVB.** Their q is under 0.6 kPa.
5. **The sounding is horizontally uniform.** It holds the day's air over the 100 km downrange to 56 km, and fades to US-1976 above.
6. **Separated stages** fly the generic drag.

### 11.6 Tests

| test | checks | depends on |
|---|---|---|
| `AerodynamicsTests.testTablesCarryTheirSources` | table values at their sources' printed or read points | D5, REF504 (M) |
| `testAxialForceAlongTheAS506Trajectory` | the model's F_A at the PFT's (h, M, q) against D5's method: 207, 596, 1,362, 1,111 and 828 kN at 40, 60, 75, 83 and 90 s, within 1.5 %; base drag below 9.6 km and thrust above; the power-off base coefficient | D5 (M), PFT (H) |
| `testNormalForceAndMoment` | C_Nα sin α cos α q S against the crossflow, in pitch, in yaw and at 45° between them; the moment at the centre of pressure in the unstable sense; the viscous crossflow beyond 4° and broadside | REF504 (M) |
| `testConfigurationsAndCentreOfPressure` | the configuration follows the parts aboard; a jettisoned S-IC flies the generic drag; X_cp at STA 100 + 3.50 calibers, 0.75 caliber ahead of the stack's CoM at liftoff | REF504 (M) |
| `testLaunchDayAtmosphere` | surface p and T against Table A-1; q = 35.16 kPa at AS-506's max-Q state; 15 % above US-1976 there; the 11.3 km wind's speed and direction; the fade into US-1976 above 56 km | FER App. A, PRA-63 (H) |
| `testSIVBDragAlongTheWind` | the S-IVB's drag lies along the relative wind at any attitude, with no moment | REF504 (H) |
| `testSimulationAppliesTheLoads` | one integration step at 12 km, in pitch, in yaw and at 45°: the rate gained is I⁻¹ τ h and the Δv differs from the generic-drag run by the model's force, within 2 % | the model |
| `SaturnIUTests.testSICAscentMatchesApollo11` | Mach 1 within 1 s; max Q within 2 % and 1 s; q every 10 s from 40 to 120 s within 5 % of Fig. 4-4; climb within 100 m and speed within 2 % of the PFT every 20 s; peak axial force 1.37 ± 0.08 MN at 73.5 ± 3 s; and the §8.4 states | FER, PFT (H), D5 |

`testVerticalSICFlight` and `testEngineOutTrim` fly with the aerodynamic model off. Each is a thrust-only check: a symmetry check with no control, and a thrust moment balance. The tower-yaw test allows 0.1° in yaw, because the FCC holds the day's wind with a steady error.

**Values tests must not depend on**:
- the crossflow term;
- the power-off base coefficient;
- the base differential below 1 km;
- the S-II configuration's coefficients;
- the sounding above 56 km.

---

## 12. Solid motors and separation (M1 item: retros, ullage and tower-jettison motors)

Compiled on 2026-10-17. `Thruster.isSolid` (`Components.swift`) is a solid motor: once lit by `ignite()` it burns its grain to the end at full output, and no throttle, control group, cutoff or `isEnabled` change stops it. A motor that is disabled before it is lit is a dud, and keeps its grain: each motor burns its own. Steps end where a lit solid's grain runs out, at the flow of every motor it feeds and inside the 1 ms minimum step too (`Simulation.maxStep`), so the impulse does not depend on the step or the time warp. `Vessel.jettison(event:)` lights the solids that staging triggers (`SolidTrigger`):
- the leaving parts' retros and the LES's tower-jettison motor, which burn on with the spent stage or the tower;
- the ullage motors of the stack that stays.

A part's `separationSpeed` (default 1 m/s, the old placeholder) is 0 where motors do the work. The IU's `.ignite` action lights the ullage motors at AS-506's times. `AS506Data.swift` holds the data under "Retro and S-IVB ullage motors".

**Frames.** The Apollo spacecraft axes are the Saturn's construction axes turned 180° about x: X_A = +x, Y_A = −y, Z_A = −z, so +Z_A points at Position III (MSFC-MAN-506 Fig. 7-15, H). In construction coordinates +z is Position I and +y Position IV; the fins lie on the diagonals A (−y, +z), B (−y, −z), C (+y, −z) and D (+y, +z) (FER-501 Table 12-2, NASA CR-61390 Fig. 4.1-2, H).

**Sources.**
- **FER** (AS-506):
  - Table 2-2: items 26, 27 and 30 (S-II ullage ignition 162.1 s, separation command 162.3 s, ullage burn end 166.1 s), 35 (LET jettison 197.9 s, T3 + 36.2), 45 (S-IVB ullage motor ignition, 548.9 s, T4 + 0.7), 46 (separation command "to fire separation devices and retro motors", 549.0 s) and 52 (S-IVB ullage case jettison, 561.0 s) (H).
  - Table 20-1: retro motor propellant, 1,027 kg (H).
  - Tables 20-5 and 20-9 (H):
    - the S-II/S-IVB interstage: 3,180 kg dry and 484 kg of retro propellant;
    - the S-IVB aft frame (22 kg) and detonation package (1 kg), which leave with the S-II;
    - the TX-280s' 53 kg of propellant: 10 kg left at STDV open, 1 kg at mainstage;
    - their cases with fairings, 61 kg;
    - the LES at jettison, 4,042 kg.
  - §12: separations "similar to those observed on previous flights" (qualitative).
- **FER-501** (AS-501, MPR-SAT-FE-68-1):
  - Table 12-1, event times: the S-IC retros' ignition 0.05 s after the separation signal, the S-II retros' 0.04 s after the S-II/S-IVB command, the S-IVB ullage motors' 0.09 s before it (H).
  - Table 12-2: the S-IC retro nominal at 60°F, 386,995 N (87,000 lbf) for 0.640 s, with 3σ bands; its nominal effective impulse, 246,876 N s, is 0.3 % under F t_b (the model delivers F t_b, 247.7 kN s); the flight average was 408,133 N, but the chamber-pressure telemetry read high (H). It and Figure 12-1's legend place the pairs: one motor of each fin's pair towards each adjacent Position.
  - Figure 12-1: the S-IC retros' thrust, timed from the separation signal: about nil to 0.09 s, 75 % at 0.15–0.17 s, full by about 0.18 s (M, read from the plot). D5-15796-1 Table 5-I has AS-501's physical separation 0.15 s after the signal.
  - Figure 12-9: the S-II retros full within about 0.025 s of lighting (M).
  - Tables 12-4 and 12-5, Figure 12-10: S-II retro and TX-280 flight values; the TX-280s at the fin II-III and IV-I diagonals (Table 12-5's "POS III-IV" header contradicts the figure and "diametrically opposite", and is taken as a typo) (H/M).
  - Figures 12-3, 12-4, 12-12 and 12-15: measured separation distances and speeds (M).
- **FER-505**, Table 2-2: the S-IC retros' "effective burn initiation" (75 % thrust) at T3 + 0.8, 0.1 s after the T3 + 0.7 command (M).
- **MSFC-MAN-506:**
  - §4: eight TE-M-424 retros in pairs in the four engine fairings, 7.5° from the axis; seven (one out) must separate the S-IC by 6 ft within 1 s (H). Its 75,800 lbf for 0.541 s is a minimum at 120°F and implies an Isp_eff of 145 s on the 128 kg grain, so the model takes AS-501's nominal.
  - §5: four S-II ullage motors 90° apart, nozzles just above STA 1564, canted 10°; four TE-M-29 retros between STA 2519 and 2633, nozzles 9.5° from the axis (H).
  - §6 and Fig. 1-3: TX-280 thrust and burn time; the motors are "canted outward ... to reduce effects of exhaust impingement, and to reduce the resulting moment if one rocket fails", with no angle (H).
- **S-IVB Data Summary Handbook** (Saturn IB S-IVB-200, Osterhout, 1965) p. 98: the TX-280's "exit nozzles canted 35 deg from stage centerline", taken for the S-IVB-500 (M, proxy).
- **Boeing D5-15481-1** (AS-504 reference trajectory) Figure 3-1: draws the S-II retro fairings off the Positions, on the fin diagonals (L).
- **Tower-jettison motor:**
  - NASA TN D-6295 (B. J. Lee, 1971), the motor's qualification (H): Table VIII(b), 70°F, sea level: 31,660 lbf average over the web burn, 36,734 lbf s total impulse, 0.046 s from firing current to 100 psia, 90 % thrust at 0.111 s; Table X: 205.2 lb of propellant; p. 19 and Table X: the two nozzles' resultant 3.784° off the motor axis (mean of 20 motors), crossing it 20.84 in aft of the forward attachment ring (datum D, M). Its scarfed nozzles exit flush with the skin, so the sea-level thrust is about the vacuum thrust.
  - Apollo Operations Handbook SM2A-03-Block II-(1) §2.9.4.8.4: in a normal jettison the frangible nuts on the tower legs and the motor fire together; no spring, and neither the launch escape motor, the pitch-control motor nor the canards (H). §2.9.5.7.4: the resultant "is in the pitch plane in the +Z direction" (H); read as the force on the LES leaning towards +Z_A, the only reading that, with the escape motor's specified −Z lean, puts that motor's thrust line near the CM/LES CG (M).
  - NASA TN D-7083: the lateral-separation manoeuvre "ensured a minimum miss distance of 150 feet" (H). No flight's tower trajectory was found.
  - Apollo 11 and 12 Mission Reports, Table A-I: the LES's CG (Xa 1297.1 ± 1.2 in, effectively on the axis) and pitch inertia (about 37,500 kg m² about its CG), as differences of the lift-off and orbit rows (M).
- **PFT** (Boeing D5-15560-6) Tables 6-I and 6-II: the spent stages' predicted trajectories (M, simulations).

### 12.1 The model

| item | model | source | conf |
|---|---|---|---|
| solid motor | constant effective thrust F for the effective burn time t_b on its share of the FER's grain, so Isp_eff = F t_b / (m g0) and the grain empties at t_b; a start transient may delay and ramp the thrust (the grain burns with it, so the impulse is unchanged); each motor has its own grain, the set's grains sharing its name (one HUD row) | — | — |
| geometry | each set symmetric, the nozzles canted outward (the force inward): no side force and no torque from a full set | MAN506 | H (cants but the TX-280's); L (stations, radii, the S-IC retros' spacing, which Positions hold the S-II motors) |
| S-IC retros | 8, a pair 2.5° either side of each fin diagonal (L), STA 230 (L), radius 5.25 m (L, against the skin in the fairings); lit by the S-IC's separation (IU at T3 + 0.7), 0.09 s delay and a 0.08 s linear rise (75 % at +0.15 s, full at +0.17 s) | FER-501 Fig. 12-1, D5-15796-1, FER-505 Table 2-2 | H/M |
| S-II ullage motors | 4 at Positions I–IV (L), STA 1608, radius 5.24 m (L); lit by the IU at T3 + 0.5 or by the S-IC's separation | MAN506, FER Table 2-2 | M |
| S-II retros | 4 on the fin diagonals (L), STA 2576, at the body radius; lit by the S-II's separation (IU at T4 + 0.8), 0.04 s delay, 0.025 s rise | MAN506, FER-501 Table 12-1, Fig. 12-9, D5-15481-1 | H/M/L |
| S-IVB ullage motors | 2 at the fin II-III and IV-I diagonals, h 73.4 m (L), radius 3.45 m (L), cant 35° (M, Saturn IB proxy), on the part "S-IVB ullage rockets" (61 kg of cases); lit by the IU at T4 + 0.7 or by the S-II's separation; the cases are jettisoned at T4 + 12.8 (staging event 5) | FER Tables 2-2, 20-9; FER-501 Fig. 12-10; S-IVB handbook | H/M/L |
| LES tower-jettison motor | one equivalent thruster on the axis at Xa 1395.9 (where the resultant crosses it, M), its force 3.784° off the axis towards Position III (−z; sign M); its 93.08 kg grain at Xa 1408.5 (L); lit by the LES's separation (IU at T3 + 36.2), 0.046 s delay and a 0.065 s rise; the whole LES's 4,042 kg, CG at Xa 1297.1 and roll and pitch inertia 1,100 and 37,500 kg m² (M; its dry part's are what is left without the grain): the thrust crosses the axis 2.51 m ahead of the CG and pitches the nose to −z | TN D-6295, AOH, MAN506 Fig. 7-15, FER Table 20-9, A11/A12 MR | H/M/L |
| separation springs | none for the S-IC, the S-II, the aft interstage and the LES (`separationSpeed` 0); the 1 m/s placeholder stays for the S-IC/S-II interstage and the ullage cases | AOH (LES) | H (LES); L |
| masses | the S-IC's retro grains (1,027 kg) out of its dry mass; the aft interstage the FER's 3,180 + 484 kg plus the S-IVB aft frame and detonation package (23 kg); the S-IVB less its TX-280 grains (53 kg), cases (61 kg) and aft frame; the LES's 4,042 kg including the TJM's grain; the first-motion total 0.8 kg higher (the FER's 3,664 kg aft interstage against SP-4029's 8,076 lb = 3,663.2 kg): 2,899,008.6 kg | FER Tables 20-1, 20-9 | H |

### 12.2 Motors

| motor | count | F each (N) | t_b (s) | propellant (kg, all) | Isp_eff (s) | cant | conf |
|---|---|---|---|---|---|---|---|
| S-IC retro (TE-M-424) | 8 | 386,995 (87,000 lbf) | 0.640 | 1,027 | 196.7 | 7.5° | H (spec; AS-501 flew 0.637 s) |
| S-II ullage | 4 | 102,309 (23,000 lbf) | 3.75 | 610 | 256.5 | 10° | M |
| S-II retro (TE-M-29) | 4 | 154,843 (34,810 lbf) | 1.52 | 484 | 198.3 | 9.5° | H |
| S-IVB ullage (TX-280) | 2 | 15,080 (3,390 lbf) | 3.87 | 53 | 224.6 | 35° (M, proxy) | H |
| LES tower jettison (TJM) | 1 | 140,830 (31,660 lbf) | 1.160 (36,734 lbf s) | 93.08 (205.2 lb) | 179.0 | 3.784° lean | H |

These supersede §3's solid-motor rows and resolve three §6 conflicts:
- **S-IVB ullage thrust.** 3,390 lbf; the 3,460 lbf figure is the Saturn IB S-IVB-200's TX-280-10.
- **S-IC retro burn.** The nominal effective 0.640 s; 0.603–0.677 s is its 3σ band.
- **Tower jettison.** TN D-6295's 31,660 lbf web-burn average and 36,734 lbf s total, in place of §3's 31,500 lbf for 1.1 s.

### 12.3 Results (`NominalFlight`, the IU flight stepped as the app steps it)

Regenerated after §17 (the frost on the S-IC to its separation, the S-II and S-IVB refits); the rows for the LES and the S-IC/S-II separation moved by under 1 %.

| quantity | model | reference |
|---|---|---|
| S-IC/S-II: constant parting acceleration through 0.41 and 1.55 m of travel | 18.95 m/s² | 18.3 m/s² (AS-501, the same reduction of FER-501 Figures 12-3/12-4) |
| its effective start after the signal | 0.121 s | 0.158 s (AS-501) |
| parting speed at 1.55 m | 8.0 m/s | about 8 m/s (AS-501) |
| S-IC retro deceleration of the spent S-IC | 18.6 m/s² | about 17 m/s² for about 0.6 s (AS-501) |
| tower jettison | 197.85 s | 197.9 s (FER Table 2-2) |
| LES sensed Δv (its thrust acceleration over the burn) | 40.89 m/s | 40.90 m/s: TN D-6295's impulse and grain on the FER's 4,042 kg |
| the LES at burnout (+1.3 s) | 8.35 m/s to −z, pitching nose to −z at 42.3°/s, 26.9° turned | 8.3 m/s, 41°/s, 24° (a planar integration of the same data, L) |
| the tower's lead on the stack's nose | at most 67.4 m beyond its start, at +4.7 s | about 67 m at about 5 s (planar, L) |
| when the stack's nose (CM apex) passes the tower | +8.82 s, the tower 66.0 m (217 ft) to −z | at least 150 ft, 45.7 m (TN D-7083); planar: about 63 m when the S-II passes the tower's start, at about 8.5 s (L) |
| S-II/S-IVB: 5.51 m of travel (the S-IVB J-2 clear) | 0.97 s, 12.2 m/s | 1.044 s, about 11 m/s (AS-501) |
| S-II retro deceleration of the spent S-II | 13.0 m/s² (12.9 before §17: the S-II's frost now leaves with the S-IC) | 11–13.5 m/s² (AS-501) |
| S-IVB ullage acceleration (549.2–552.2 s) | 0.148 m/s² | 2 × 3,390 lbf × cos 35° / 166,634 kg = 0.148 |
| TX-280 grain at STDV open, at mainstage | 8.4 kg, 0 | 10 kg, 1 kg (FER Table 20-9) |
| S-IVB stack at first ESC, STDV open, mainstage | +1, +23, −7 kg (+91, +113, +88 before §17) | FER Table 20-9 (the S-IVB's frost, 90 kg, leaves with the S-IC since §17; its 23 kg fuel-lead loss is not modelled) |
| spent S-IC apex (over Fischer 1960, §15) | 116.2 km at 270.1 s | 115.0 km at 269.1 s (PFT) |
| spent S-II apex (over Fischer 1960) | 189.8 km at 589.2 s | 188.8 km at 587.0 s (PFT) |
| spent stages' impact | S-IC 453 s, S-II 1,109 s | S-IC 503.5–577.8 s (0°–90° angle of attack; tumbling 543.7 s), S-II 1,179.9–1,252.7 s (PFT) |

The planar integration (TN D-6295's thrust curve or its constant equivalent, the LES's mass, CG and inertia above, the stack accelerating at 8.5 m/s²) was done separately from the simulation to check it; it shares the data, so it is not independent evidence.

**Effect on the flight** (the fixed-step IU flight of §8.4 and §10.4):
- The S-IVB stack is about 67 kg lighter at ignition (the 23 kg aft frame has left with the S-II and 44 kg of TX-280 grain has burned), 76 kg at mainstage and 137 kg after the case jettison, and the IGM senses the ullage burn's 0.57 m/s (0.70 m/s with the motors uncanted). The velocity cutoff moves from 702.87 to 702.75 s, and S-II OECO from 6,900.7 to 6,900.36 m/s, since the stack no longer gets the 1 m/s placeholder's share at the S-IC separation.
- The orbit is unchanged: 185.17 × 185.09 km.
- The shared recorded flight (`NominalFlight`) steps as `advance` does, ending steps on events and burnouts, and cut off at 702.63 s (698.83 s since §17).

### 12.4 Known deviations

1. **The S-IC separation starts 0.04 s earlier than AS-501's.**
   - With the retros' thrust building up as on AS-501 (Figure 12-1), the model's effective start is 0.121 s against 0.158 s.
   - The rest is within the reading of FER-501's figures. Another candidate is the F-1s' tail-off: the model's is a linear ramp that ends at 162.29 s (§9.2, shape L), so nothing pushes the S-IC once the retros fire; the real decay's tail would.
   - The parting acceleration itself matches.
2. **Spent stages fly the generic drag.** That is `bodyDragCoefficient` 0.45 on the largest cross-section, along the airflow. Their apexes match the PFT, but they fall too fast: the S-IC strikes 55–130 s before the PFT's predictions. A tumbling-stage drag model is a separate item.
3. **Unsourced or proxy geometry.**
   - What is missing:
     - the S-IC retros' station, radius, pair spacing and the direction of their 7.5° cant;
     - the TX-280s' cant (the Saturn IB's), station and radius;
     - which Positions hold the S-II ullage motors and retros (the retros' diagonals come from one schematic);
     - the TJM's place in the tower (its grain point, L), where its thrust line crosses the axis (M: it depends on which plane TN D-6295's datum D is), and the sign of its lean (M, inferred from the AOH).
   - It is harmless while every motor of a set fires: the forces cancel. A one-motor-out case's side force and torque depend on it.
   - The TJM's crossing point sets the tower's pitch rate: the other reading of datum D (98.8 against 104.2 in ahead of the CG) and the CG's up to 1.6 in off the axis (towards +Z_A) change the rate by up to +25 %.
4. **Constant thrust.** No thrust curves are used: AS-501's Figures 12-1, 12-9 and 12-10, including the TX-280's low tail to about 9 s, or TN D-6295's Table VI(b). Only the starts are shaped.
5. **The TJM is one equivalent thruster.** The real motor has two scarfed nozzles of unequal throats in the pitch plane, whose resultant the model applies on the axis. Its thrust is the 70°F sea-level value; the grain's temperature at jettison is not known.
6. **Geometry found on the way, outside the motors**: the S-IC's dry CG, the J-2 gimbal stations and the Apollo station offset were corrected in §13, with the rest of the mass distribution.

### 12.5 Tests

| test | checks | depends on |
|---|---|---|
| `SolidMotorTests.testSolidBurnsItsGrainOutWhateverTheControls` | a lit solid's Δv, Isp g0 ln(m0/m1), to 1e-7 m/s at 1x and 1000x warp (a step past burnout would add 1e-3); in the main, retro and translate groups, the throttles and translation commands drive its level but neither fire nor stop it, nor does `isEnabled` | the model |
| `testASharedGrainEndsTheStepAtBurnout` | two motors on one grain: the Δv the same at 1x and 1000x; the step ends where the grain runs out at both motors' flow, inside the 1 ms minimum step too | the model |
| `testDudsAndLiquidEnginesDoNotLight` | duds, empty grains and liquid engines do not light | the model |
| `testStagingLightsRetrosAndUllageMotors` | staging lights the leaving retros and the staying ullage motors of its event, and nothing else (not a retro that stays, an ullage motor of another event, or one that leaves); no spring kick; each burns into its own vessel (rocket equation within 1e-4); a dud stays unlit | the model |
| `SaturnVDataTests.testNamesFeedsAndStagingRules` | the parts, tanks and staging events; each solid on its own grain, triggered, out of every control group, each set adding to a pure axial force; the TJM lit by the LES's separation, on the axis, 3.784° off it towards −z, 98.8 in ahead of the whole LES's CG, about which its inertia is 1,100 and 37,500 kg m²; no separation springs on the S-IC, S-II, aft interstage and LES | MAN506 (layout), TN D-6295, AOH |
| `testFirstMotionMassesMatchTheFER` | the FER's aft interstage (3,180 + 484 kg) against SP-4029's 8,076 lb within 2 lb (1.7 over); the S-IVB with its ullage rockets and aft frame equal to SP-4029's 262,613 lb | FER, SP-4029 (H) |
| `testEventTimelineThroughThePropellantModel` | the event masses with the motors lit at their FER times; the S-IVB rows within 0.1 %; 10 ± 3 kg of TX-280 grain at STDV open, about 0 at mainstage; the 61 kg cases jettisoned | FER Tables 20-5, 20-9 (H) |
| `SaturnVSeparationTests.testSICRetrosSeparateTheStages` | the parting acceleration within 1.5 m/s² of AS-501's, its effective start within 0.05 s of AS-501's 0.158 s; 8 ± 1.5 m/s at 1.55 m; the stack's rates under 0.2°/s | FER-501 (M) |
| `testSevenSICRetrosStillSeparateInASecond` | with one retro a dud, 1.83 m of travel within 1 s; the dud keeps its 128 kg grain | MAN506 (H) |
| `testTowerJettisonMotorThrowsTheTowerClear` | the jettison at 197.9 ± 0.1 s, the LES at 4,042 kg with its full grain; its sensed Δv within 0.02 m/s of 40.9 m/s and the grain empty by +1.3 s; there 8.3 ± 0.5 m/s to −z and 41 ± 3°/s nose to −z; the tower over 45.7 m to −z when the stack's nose passes it | FER, TN D-6295, TN D-7083 (H); the planar integration (L) |
| `testSIIRetrosSeparateTheStages` | no spring (no parting before the retros light); 5.51 m within 0.15 s of 1.044 s, at 11 ± 2 m/s; the S-II's deceleration within AS-501's 11–13.5 m/s²; the S-IVB's rates under 0.2°/s to 552.2 s | FER-501 (M) |
| `testSIVBUllageMotorsBurnAndAreJettisoned` | ignition at 548.9 s and case jettison at 561.0 s within 0.1 s; 2 × 3,390 lbf × cos 35° / 166,634 kg within 0.005 m/s² while the ullage motors burn alone; the grain left at STDV open and mainstage | FER (H); the cant (M) |
| `testSpentStagesClimbAsPredicted` | the S-IC's apex within 3 s and 1.5 km (above the pad), the S-II's within 5 s and 1.5 km (radius) | PFT (M) |
| `SaturnIUTests` (timeline, time-base drop), `SaturnVFlightTests.testSpaceKeyStagingSequence` | the IU's two new events; five Space presses, the last the ullage cases | FER Table 2-2 (H) |

**Values tests must not depend on**:
- the motors' stations and radii, and the S-IC retros' pair spacing;
- the retros' rise times (the S-IC's only through AS-501's start ± 0.05 s);
- the TJM's crossing point and grain point (only through the wide bands on the tower's rate and side speed);
- the spent stages' descent and impact.

---

## 13. Mass characteristics and stage geometry (M1 item: residual diagnostics, part 1)

Compiled on 2026-10-18. Until now the model's mass distribution was estimated (L): each stage's dry CG at its part's middle, the propellant extents from loads and assumed domes, the J-2 gimbals within ±1 m. This section sources it and checks the whole vehicle against AS-506's FER Table 20-10, which gives the mass, CG and inertias of each stage and of the vehicle at 18 events (and three of the spacecraft's). The corrections were made before the residual diagnostics of §14, because the control lever arms and inertias set the attitude dynamics those diagnostics compare.

**Sources.**
- **FER Table 20-10**, "Mass Characteristics Comparison" (PDF pages 245–248; pages 246 and 247 printed upside down): 28 items, predicted and actual, with mass, longitudinal CG (STA), radial CG and roll, pitch and yaw moments of inertia. Two readers transcribed it independently at 400 dpi (800 dpi for doubtful cells): every cell of all 56 rows agreed (H).
- **AS-501 FER** (MPR-SAT-FE-68-1) Appendix B Figure B-1 (PDF page 512), the station diagram (H):
  - F-1 gimbal plane STA 100.00;
  - S-IC LOX tank 772.00 (bottom) with Y-rings at 909.00 and 1404.00; RP-1 tank 225.00–742.00 with a Y-ring at 605.00;
  - S-II stations XB = STA − 1564.00 and S-IVB stations = STA − 2545.85 (M, from printed pairs);
  - S-IVB aft skirt 2746.50–2832.00; IU 3222.56–3258.56.
- **Boeing D5-15481-1** ("REF504") Figure 3-1: "GIMBAL STA 1664.000" (S-II) and "GIMBAL STA 2645.853" (S-IVB) (H).
- **MSFC-MAN-506** (Saturn V Flight Manual SA-506):
  - the S-IC LOX tank's 769 in (Figure 4-1) (H);
  - the S-IVB LOX tank, 2,830 ft³ with 108 ft³ of ullage, and LH2 tank, 10,400 ft³ with 300 ft³ (H);
  - the S-IC residuals at OECO by location (Figure 2-22: 29,346 lb of LOX in the suction lines) (H).
- **S-II technicians' manual 2644-D**: bulkheads "a/b = 1.5 MOD", XB stations 152, 284, 416, 823 and 955, the 98 % fill sensors (H; stations M).
- **TN D-3968** Figure 2: the S-IVB-203's tanks, the same design as the S-IVB-500's: R 130 in hemispherical domes and common bulkhead, 41.0 in from the aft dome's equator to the cusp (M).
- **Corroborating** (2026-10-18):
  - Boeing's *Saturn V Apollo Flight Configuration* diagram (MSFC, 1 March 1967; NASA image 9253429) gives Figure B-1's stations: the S-II's station 100 as "gimbal plane" and the S-IVB's as "top J-2 engine", the S-IC's forward skirt top at 1541.00, its tank stations, and the "bottom of F-1 engine" at −115.36, the model's datum (H).
  - MSFC-MAN-504: Figure 4-1 (fuel tank 517 in, LOX tank 769 in); Figure 5-1 (the S-II's 81-1/2 ft from STA 1541 to 2519; LOX tank 22 ft and 12,745.5 cu ft; LH2 tank 37,737 cu ft); Figure 6-1 (the S-IVB's 59.0 ft with its 19 ft aft interstage; its 44.0 ft tank); §6 (hemispherical domes; the forward skirt starts at the junction of sidewall and forward dome; the aft skirt is bolted to the tank); the S-IC's 345,000 and 216,000 gal tanks (H).
  - MSFC-MAN-506 Figure 5-19: separation planes at STA 1564, 1760 and 2746.5 (H).
  - The J-2 side view in the Saturn V News Reference's fact sheet is to scale (its length from the fuel inlet duct's top, 11 ft 1 in, and its width match within 2 %): 116 ± 3 in from gimbal to exit, as FER-501 §12 gives (M).
- **FER Table 20-1**, the S-IC's mass at holddown arm release: 1,446,726 kg of LOX and 631,847 kg of RP-1 in the tanks, and 21,868 and 5,983 kg below them, in the suction lines and engines (H). TIS-506 Figure 24's 44,100 lb of LOX and 6,450 lb of RP-1 in the lines at liftoff, used before, disagree with it.
- **FER Table 7-5**: AS-506's APS loads (203.00 lb N₂O₄, 126.00 lb MMH per module) and propellant use (H).
- **Astrionics System Handbook** (MSFC IV-4-401-1) §3.4, Figures 3.4-5 and 3.4-6: the "typical" S-IVB APS dead bands (M).
- **REF504** §3.5: the flight control computer's filters (L as AS-506 data: from the SA-503 design release, Boeing FCD-H-027, 1966).

### 13.1 The model

| item | model | source | conf |
|---|---|---|---|
| stage dry CG and inertia | each part's dry CG and roll, pitch and yaw inertia composed from its Table 20-10 row (actual), plus or minus what the model carries elsewhere: the S-IC with the small interstage ring at its middle (STA 1552.5) and the body radius; the S-IC/S-II interstage less the ring and the S-II ullage grains; the aft interstage less the S-II retro grains and with the S-IVB's aft frame at the separation plane; the S-IVB less the aft frame and the ullage motors' cases. The rest of each part's dry mass (frost, purges, gases: 1,273 kg on the S-IC, 571 kg on the S-II, 399 kg on the S-IVB) sits at the row's CG | FER Table 20-10 | H (rows); L (the remainders' places) |
| liquids in roll | a settled column has a solid cylinder's inertia in pitch and yaw but none in roll: the walls do not spin a liquid up about its axis | FER Table 20-10, whose roll inertias are the dry structures' (3.70e6 kg m² at holddown against 3.58e6 for the dry rows) | H (convention) |
| tank loads | each a settled column in a cylinder of the stage's radius, its full-load centroid at the loaded liquid's centroid (ullage gas on top): S-IC LOX STA 1130.2 (the tank's 1139.9 at a 4.7 % ullage, and FER Table 20-1's 21,868 kg below it at about 486, L), RP-1 470.6 (the tank's 473.1, and the 5,983 kg below it at about 212, L), S-II LOX 1836.2 (ellipsoid 1716–1980, ullage 10–12 %, L), S-II LH2 2196.0 (1848–2519 over the common bulkhead, ullage 2.6–5.2 %, L), S-IVB LOX 2788.05 (lens 2702–2880, M), S-IVB LH2 3007.97 (2791–3230.56, M). The S-IC's line propellant that stays to OECO, 16,761 kg of LOX at about 419 and 5,946 kg of RP-1 at 212 (FER Table 20-1; stations L), is held below the column in feed lines, which the engines empty last (`PropellantTank.feedLines`); the column holds the rest about the centroid that keeps the whole load's (2026-10-18) | Fig. B-1, MSFC-MAN-506, 2644-D, TN D-3968, FER Table 20-1 | M/L |
| LM | CG STA 3343.6: Table 20-10's predicted "CSM separated" (33,093 kg at 3101.6) less its predicted "spacecraft separated" (17,980 kg at 2898.2), which leaves exactly the FER's predicted LM, 15,113 kg. The actual rows leave 15,436 kg at 3330.8: they also carry 341 kg the S-IVB lost (venting, APS) between the two events, which put back at the S-IVB gives 3343.6 again. The same table's "CSM docked" less "CSM separated" is the CSM, 28,806 kg, the model's mass, at a CG consistent with the model's | FER Table 20-10 | M |
| J-2 gimbals and exits | S-II STA 1664.0 (gimbals) and 1548 (exits, 16 in below the STA 1564 separation plane); S-IVB STA 2645.85 and 2529.5 (exit 217 in below the STA 2746.5 plane): the S-IVB's J-2 hangs inside the aft interstage | REF504 Fig. 3-1, FER-501 §12 | H / M |
| Apollo stations | STA = Xa + 2756.56 in; IU STA 3222.56–3258.56 | Fig. B-1, AOH Fig. 1-1 | H |
| APS loads | 203.0 lb N₂O₄ and 126.0 lb MMH per module, feed ratio 1.611 (was AS-507's 202.5 / 126 lb) | FER Table 7-5 | H |
| S-IC roll filter | 2.35/(s + 2.35) on the roll attitude error, ahead of a0 (§13.3) | REF504 §3.5 | L |

These supersede §4's tank extents and stage estimates, §4's dry-CG remark, the J-2 rows of §4's engine table, §7's inertia, authority and step-response figures (§7.2's consistency table, §7.4 B), which predate it, and §12.4 item 6.

### 13.2 Results against FER Table 20-10 (`MassCharacteristicsTests`)

The FER's 12 ascent events driven through the propellant model (the S-II's start sequence command at 163.04 s, FER Table 2-2); the vehicle's mass, CG and roll and pitch inertias about its CG.

| event | CG STA, model (FER) | roll inertia 10⁶ kg m², model (FER) | pitch inertia, model (FER) | before this section: CG, roll, pitch |
|---|---|---|---|---|
| 1st flight stage, holddown arm release | 1193.4 (1192.0) | 3.618 (3.703) | 920.3 (914.3) | −5.7 in, ×9.5, +6.9 % |
| 1st flight stage, OECO signal | 1828.6 (1828.9) | 3.618 (3.689) | 446.0 (440.5) | +60.8 in, ×2.5, −1.7 % |
| 1st flight stage, separation | 1833.6 (1835.1) | 3.618 (3.686) | 442.7 (435.7) | +60.0 in, ×2.5, −1.5 % |
| 2nd flight stage, start sequence | 2199.9 (2199.0) | 0.980 (0.985) | 140.9 (135.5) | +56.7 in, ×7.0, −2.6 % |
| 2nd flight stage, mainstage | 2200.5 (2199.5) | 0.967 (0.974) | 140.7 (135.4) | +56.6 in, ×7.1, −2.6 % |
| 2nd flight stage, cutoff signal | 2796.6 (2795.8) | 0.864 (0.871) | 46.4 (44.9) | +68.8 in, +57 %, −19.4 % |
| 2nd flight stage, separation | 2797.3 (2796.4) | 0.864 (0.871) | 46.3 (44.8) | +68.9 in, +57 %, −19.5 % |
| 3rd flight stage, 1st start sequence | 3040.6 (3036.6) | 0.202 (0.198) | 14.28 (13.42) | +34.8 in, ×3.8, −2.0 % |
| 3rd flight stage, 1st ignition | 3040.7 (3036.4) | 0.202 (0.198) | 14.28 (13.41) | +35.1 in, ×3.8, −2.0 % |
| 3rd flight stage, 1st mainstage | 3040.8 (3036.5) | 0.201 (0.198) | 14.28 (13.41) | +35.2 in, ×3.8, −2.1 % |
| 3rd flight stage, 1st cutoff signal | 3080.1 (3072.7) | 0.201 (0.197) | 13.21 (12.59) | +38.1 in, ×3.0, −4.3 % |
| 3rd flight stage, 1st end of thrust decay | 3080.1 (3072.9) | 0.201 (0.197) | 13.20 (12.59) | +38.0 in, ×3.0, −4.3 % |

- **CG:** within −1.5 to +7.4 in at every event (+0.9 to +8.2 in before the S-IC's feed lines, §13.4 item 3), where it was up to 69 in (1.7 m) high through the S-II burn. Of that error, about a third was the dry CGs (the S-II's 247 in and the S-IVB's 128 in high at their parts' middles) and the rest the propellant extents: the S-IC loads 50–55 in low, the S-II LOX 47 in and the S-IVB loads 27–31 in high.
- **Roll inertia:** within −2.3 to +2.1 %, where it was up to 9.5 times too large.
- **Pitch inertia:** within +0.7 to +6.5 % (−1.3 to +6.5 % before the S-IC's feed lines, which sit low).
- **Spacecraft** (SLA, LM, CSM, LES at liftoff): CG STA 3616.2 against the row's 3608.6 (3622.8 with the LM's old estimated CG, 3612.3 with the LM from the actual rows); pitch inertia 1.69e6 against 1.55e6 kg m². The row is 1,109 kg short of the modules (§13.4 item 2); placed anywhere in the spacecraft, that item moves its CG by 8–11 in.
- **Masses** are §9.4's (within 0.2 %).

### 13.3 Consequences for the attitude dynamics

The ascent itself barely moves: the velocity cutoff comes at 702.74 s instead of 702.75, S-II OECO at 6,900.38 m/s instead of 6,900.36, and the S-IC's CECO and OECO states, max Q, Mach 1 and the parking orbit are unchanged to the figures quoted in §8.4, §10.4 and §11.4. The attitude loops change.

- **S-IC roll.** At liftoff the roll inertia is 3.62e6 kg m², not 35.3e6.
  - On REF504's roll gains (a0 0.245, a1 0.15 s) the roll loop is then near critically damped: ζ 0.90, against 0.29 before. Without a filter the roll program's start does not overshoot: the rate peaks at 1.00°/s.
  - The model's former match to AS-506's 1.38°/s peak (§8.6) came from the wrong inertia.
  - A pilot's full roll tap of 0.6–1 s now spins the stack at 45–120°/s. The IU restarts its command only once the rate is under 2°/s (§8.6): restarting it at once let the error wrap past half a turn into pitch and yaw and could tumble the stack near max Q.
  - REF504's roll attitude-gain filter, 2.35/(s + 2.35), pairs with those gains (same document) and restores the overshoot:

    | | peak roll error | peak roll rate | end-of-roll rate undershoot |
    |---|---|---|---|
    | model, with the filter | 0.81° at +1.3 s | 1.24°/s at +2.0 s | −0.24°/s |
    | model, without | 0.59° (no peak) | 1.00°/s | 0 |
    | AS-506 (FER Table 11-2, Figure 11-3) | 0.92° at +0.6 s | 1.38°/s at +1.2 s | about −0.62°/s measured, −0.28°/s in MSFC's post-flight simulation |

  - AS-506's measured roll rate carries an oscillation of ±0.10–0.15°/s at about 0.25 Hz through the whole ramp (Figure 11-3, M), which MSFC's own simulation in the same figure does not have, nor does this rigid-body model. The test checks the peak rate against AS-506's 1.38°/s within 0.2°/s, and the peak error against its 0.92° within 0.2°; both reject the unfiltered loop. The model's start is more damped than AS-506's (§13.4 item 9).
  - The filter is stepped exactly for an input that moves linearly between samples, so it gives the same response at 0.01, 0.02 and 1/60 s steps and under time warp.
- **S-IC pitch and yaw.** At liftoff mass a 0.5° pitch step now has c 0.947 s⁻², ωn 0.923 rad/s and ζ 0.354 (0.955, 0.927 and 0.355 before the S-IC's feed lines, which sit low and add 0.8 % of pitch inertia): 30 % overshoot at 3.6 s, against 0.887 s⁻², 0.893 rad/s, ζ 0.343 and 32 % at 3.7 s before.
  - REF504's S-IC pitch and yaw attitude filter, 0.4(s + 0.095)/(s + 0.038), is not flown. It belongs to REF504's pitch and yaw gains, not to TN D-5869's, which the model flies.
  - With either gain set it moves the 20–100 s pitch error away from FER Figure 11-1 (rms 0.123° against 0.091° with the model's gains; 0.151° against 0.084° with REF504's).
  - Its effect on the tower-clearance yaw is mixed: closer in peak size and return rate, but the peak comes at 9.1 s against AS-506's 6.9 s (Figure 11-2).
  - Not flying it is an open choice (§13.4 item 7).
- **The S-IVB's APS in orbit.** The orbiting stack's roll inertia is 2.01e5 kg m² (Table 20-10: 1.97e5), not about 6e5.
  - One 0.06 s minimum pulse of the two roll engines (4,577 N m) now changes the roll rate by 0.078°/s, where it changed it by 0.026–0.027°/s before.
  - Undisturbed, the hold is a minimum-impulse limit cycle in roll: the rate alternates across the dead band, one pulse per crossing of 2δ − KΔω = 1.61°. At worst that is 87 pulses an hour, 2.85 kg/h. The model holds at 2.82 kg/h over 1,000 s (2.66 kg/h over 7,333 s at 10,000×): the limit cycle and a few pitch and yaw pulses. It was 0.13–0.18 kg/h before.
  - AS-506 used 4.71 kg/h holding the local horizontal in its parking orbit, disturbances included: 11.11 kg from the end of the first ullage burn, 786.5 s (FER Table 2-2), to T6, 9,278.24 s (FER Tables 7-5 and 2-1).
  - A pilot's roll by hand now turns the stack three times faster: 5 s give 6.5°/s, and the APS stops it about 33° off.
  - The switching-line slope K = 5 s, a placeholder until now, is the Astrionics System Handbook's typical value: its dead-band lines cross ±1° at zero rate and ±0.2°/s at zero error (grade M).
- **Gyroscopic coupling.** With the smaller roll inertia, the free body's own roll, Ixx ω̇x = (Iyy − Izz) ωy ωz, shows in a nose reversal during the S-IVB burn.
  - Pitch and yaw inertia differ by 4.66e3 kg m² (the APS propellant at Positions I and III, and the IU's pitch and yaw rows).
  - That gives 0.003°/s of roll in the first 5 s and about 0.04°/s over the 98 s reversal; the APS trims it from about 59 s.

### 13.4 Known deviations

1. **The S-IVB stack's pitch inertia is 5–6.5 % high, and its CG 4–7.4 in high.** The spacecraft's own pitch inertia is 1.69e6 kg m² against the FER's 1.55e6, and its CG 7.6 in high. Its inner layout (LM, CSM and LES positions, their own inertias) is partly estimated.
2. **Spacecraft mass.** Table 20-10's "spacecraft, total" is 48,626 kg, 1,109 kg less than the FER's modules (Tables 20-7 and 20-9) and SP-4029's 109,646 lb. Those modules and the stages sum to the first-motion mass within 1 kg, so the row must book an item elsewhere; which item was not identified.
3. **Residual LOX.** ~~At S-IC OECO the CG is 8.2 in high. The model's residual LOX lies at the bottom of its column, while most of AS-506's (29,346 lb, MSFC-MAN-506 Figure 2-22) was in the suction lines below the tank. Modelling a line volume would need a second geometry per tank.~~ *Resolved on 2026-10-18: the S-IC's tanks hold the 16,761 kg of LOX and 5,946 kg of RP-1 that stay in the lines to OECO (FER Table 20-1) in feed lines below the column, which the engines empty last (§13.1). The OECO CG is now 0.3 in low and the separation's 1.5 in; the tank masses, depletion and residuals are unchanged. The lines' stations are L, worth about 2 in of CG per 100 in.*
4. **Radial CGs are not modelled.**
   - Table 20-10 gives offsets of 2.3 to 14.1 in for the stage rows (S-IC 2.3, S-IC/S-II interstage 6.2, S-II 7.4, S-IVB 8.6, IU 14.1, spacecraft 4.3 in), without directions.
   - At the vehicle level they are 0.15 in at liftoff, 1.5 to 1.9 in through the S-IVB's first burn, and 3.9 in after its second (TLI).
   - The real vehicle trimmed the torques they cause with its gimbals.
5. **Drained tanks.** Each load is a column in a cylinder of the stage's radius. Its centroid is right when the tank is full, but it drains towards the column's aft end rather than into the domes (the S-II LOX ellipsoid, the S-IVB lens).
6. **Ullages.** The S-IC and S-II ullage fractions are estimated (L), within the ranges in §13.1.
7. **Open choices in the FCC.** The S-IC pitch and yaw filter is not flown (§13.3). Whether the roll β is per actuator (the Astrionics System Handbook sends the roll signals to all eight servo amplifiers, which would raise the roll authority √2) is still open (§8.9 item 5).
8. **APS switching-line prediction.** The prediction that ends a coasting step at a switching line leaves out the error's kinematic drift (−ω × e / 2).
   - At 10,000× warp a crossing can therefore come one coasting step late, and the pulse timing then drifts by up to about one pulse.
   - On the nominal hold the 1× and 10,000× runs use the same propellant to 1,000 s, but that is chance: with the S-IVB's roll inertia 0.04 % larger they part within the 1,000 s, and adding the drift term alone does not make them agree. The test therefore checks each run on its own.
   - The effect is harmless: every run stays within the limit cycle plus a few pulses, and the error within the dead band.
9. **S-IC roll-program start.** The model's start is more damped than AS-506's: its roll rate peaks at 1.24°/s against 1.38°/s, and dips to 0.94°/s against about 0.56°/s 2 s later (FER Figure 11-3). AS-506's rate also carries a ±0.10–0.15°/s oscillation through the ramp that neither MSFC's simulation nor the model has. The cause is not traced: REF504's roll gains and filter are SA-503 design data (L). The test checks the peak against 1.38°/s within 0.2°/s; whether to look further is open.

### 13.5 Tests

| test | checks | depends on |
|---|---|---|
| `MassCharacteristicsTests.testMassCharacteristicsMatchTheFER` | at the 12 events of §13.2: mass within 0.2 %, CG within 8 in, roll inertia within 3 %, pitch inertia within 7 % | FER Table 20-10 (H) |
| `testSpacecraftCenterOfMass` | the spacecraft's CG within 10 in of STA 3608.6 (the row is 1,109 kg short of the modules); its mass the FER's modules | FER Tables 20-7, 20-9, 20-10 (H) |
| `MassPropertiesTests.testSettledColumnCentroidAndInertia` | a column's centroid; no roll inertia, a cylinder's pitch and yaw inertia | the model |
| `MassPropertiesTests.testFeedLinesEmptyLast` | a column's feed lines stay full while it empties, then drain; the tank's mass unchanged; on the axis, no roll inertia | the model |
| `MassCharacteristicsTests.testTankGeometryHoldsThePublishedVolumes` | §13.1's tank geometry (Fig. B-1's stations, a/b 1.5 S-II bulkheads, R 130 in S-IVB domes, the 44.0 ft S-IVB tank) holds MSFC-MAN-504/506's volumes within 3–6 %; the S-IVB cylinder starts at the aft skirt's top | MSFC-MAN-504, MSFC-MAN-506 (H) |
| `SaturnVDataTests.testJ2GimbalsAtThePublishedStations` | the J-2 thrusters at STA 1664 and 2645.85, the nozzles' exits at 1548 and 2529.5 (116 ± 3 in below, inside the interstages), the interstage and S-II ends at 1541, 1760, 2519 and 2746.5, and the S-II aero reference at the gimbal plane | REF504 Fig. 3-1, Fig. B-1, NASA image 9253429, FER-501 §12 (H/M) |
| `SaturnIUTests.testTowerYawAndRollProgram` | roll peaks against Table 11-2: rate 1.38 ± 0.2°/s, error 0.92 ± 0.2°, both rejecting the unfiltered loop (1.00°/s, 0.59°); the ramp lag | FER (H), REF504 (L) |
| `testRollTapHandBackInTheSICBurn` | 0.6 and 1 s full roll taps at 40 and 60 s: the spin damped within 6 s, the nose within 2° of an untouched flight's, tracking within 1.5° 25 s on (two of the four runs fail without the hand-back's settling) | the model (regression) |
| `testFCCFiltersAreExactAtAnyStep`, `testFCCFilterStateAcrossGainSwitches` | the filters against their closed forms at any step; the same roll-step response at 0.01, 0.02 and 1/60 s; the state carried across a gain switch that keeps it, dropped when the gains have none or the reference resets | the model, REF504 §3.5 (L) |
| `testFlightControlStepResponse` | c 0.947 s⁻², ωn 0.923 rad/s and the step's peak against the second-order formulas | self-consistency |
| `testAPSHoldAtTimeWarp` | at 1× and 10,000× over 1,000 s and at 10,000× over 7,333 s: each run's rate under the worst limit cycle plus three pulses and under AS-506's 4.71 kg/h; the error inside the dead band plus one pulse | FER Table 7-5 (H), the model |
| `testFlightSequenceFollowsTheApollo11Timeline`, `testCoastCommandRateFromTheSIVBCutoff` | hand rolls of 5 and 3 s, sized for the FER roll inertia, return within the IU's coast rate limits | the model |
| `SaturnVControlTests` S11, S12, S13 | the hold's swing bounded by 0.48 α computed from the model (unwrapped); the three-axis capture's swing unwrapped; the nose reversal's gyroscopic roll under 0.005°/s in 5 s | self-consistency |
| `SaturnVDataTests.testNamesFeedsAndStagingRules` | the APS loads and feed ratio | FER Table 7-5 (H) |

**Values tests must not depend on**:
- where the dry remainders, the S-IC line propellant and the ullage gas sit;
- the tank shapes as they drain;
- the radial CGs, which are not modelled.

---

## 14. Ascent residual diagnostics (M1 item: residual diagnostics, part 2: E1–E3)

Compiled on 2026-10-18. Three diagnostics ran as temporary probes on commit 1903de1, after §13's mass characteristics (FER Table 20-10), the sourced J-2 stations and the S-IC roll filter. The probes were then removed, so no production code, test or data value changed. A second reader checked each diagnostic with separate scripts on the same raw data and recomputed the frames and the key numbers. Only numbers that passed that check are given here. Where the check corrected a number, the corrected value is used.

Two terms are used throughout:
- **a_ng** is the sensed (non-gravitational) acceleration.
- **χ_thr** is the pitch direction of a_ng in the space-fixed frame (PACSS 13, §8.1). It is negative downrange.

**Purpose.** Four residuals remained after §13:

1. **`pitchScale` 1.025** (§8.4). It is fitted on the OECO flight-path angle, and what it compensates was "not identified" (§8.5, §11.5 item 1).
2. **The S-IC's speed deficit.** At AS-506's event times it is 12.0 m/s at CECO and 14.0 m/s at OECO (§9.5 item 1, §11.5 item 2).
3. **The late velocity cutoff:** 702.74 s against 699.34 s. §10.5 item 1 puts 2.3 s of the 3.40 s on the S-II OECO speed deficit and leaves 1.1 s unexplained.
4. **The IGM yaw.** From 450 s it is up to 1.1° below FER Figure 10-4's LVDC command (§10.5 item 2).

Each diagnostic asks one question:
- **E1:** does the model's S-IC attitude error match AS-506's, and how much of the OECO residual is pitch history?
- **E2:** where does the sensed-velocity deficit build up, by stage and by term?
- **E3:** with AS-506's state injected at T3 and T4, how much of the cutoff delay belongs to the upper stages and how much to the S-IC handover?

**Data used.**

| data | use | source | conf |
|---|---|---|---|
| AS-506's postflight state every 1 s to 162 s and every 2 s to 709.33 s, PACSS 13 | states at events. Sensed velocity = ΔV less a J2 gravity integral (Fischer constants), and its direction χ_thr | PFT Table B-II | H (printed state); M (S-IC χ_thr, a 5-s boxcar of filtered derivatives); L–M (upper-stage directions) |
| pitch attitude error, S-IC | E1's gate; the command reconstruction | FER Figure 11-1 panel 2, two dense digitisations that agree within 0.03° | M (±0.015–0.1°) |
| pitch attitude, S-IC | cross-check of attitude against χ_thr | Figure 11-1 panel 1, read on a 0 to −80° axis (the axis labels conflict) | L–M (±0.4°) |
| average engine position, S-IC | the late trim | Figure 11-1 panel 4 | M; sign convention inferred |
| misalignments, the error at OECO, α, α·q | E1 | FER §11.2.2, Tables 11-1 and 11-2 | H |
| platform sensed velocity at the three cutoffs, LVDC ("guidance") and postflight | E2, E3 | FER Table 10-1 (PACSS 12) | H |
| states at CECO, OECO, S-II OECO and the velocity cutoff | E1–E3 | FER Tables 4-2 and 10-2 | H |
| pad phase: sensed velocity from guidance reference release to first motion (17.268 s) | added to the PFT's sensed velocity | derived from the plumb line turning with the Earth: AS-506 169.088 m/s along X_S, the model 168.831 | H (PFT plus pad matches Table 10-1 postflight within 0.05, 0.13 and 0.13 m/s per axis at the three cutoffs) |
| AS-506's held pitch after the tilt arrest, −68.90° | E3 | FER Figure 10-4 (OT and LVDC) | M |
| masses and thrust | E2, E3 | FER Tables 4-1, 20-1, 20-3, 20-5, 20-9 (H); Figures 5-3, 6-3, 7-2 (M) | H/M |
| FCC ratios a1/a0 0.767, 0.978, 0.9375, switched at T1 + 105 and 130 s | the ramp lag | TN5869 Table 3 | L (AS-506) |

**Frames** were checked independently:
- The model's X_S, its plumb line, lies within 0.001° of AS-506's geodetic vertical.
- The frame's definition reproduces the PFT's pad position.
- PACSS 12 shares PACSS 13's axes: the PFT's S-II and S-IVB increments match Table 10-1's postflight values within 0.1 m/s.

**The model's sensed acceleration** is Δv/h less the simulator's own gravity, averaged over the step. It was checked against the thrust and aerodynamic forces summed directly. The two agree within 0.011° in pitch (E1) and within 0.11 m/s over 540 s (E3).

### 14.1 E1: S-IC attitude, attitude error and thrust direction

**Method.** The IU flight was flown in 0.02 s steps with five pre-IGM programs:
- **(a)** the default, 1.025 × SA-504;
- **(b)** SA-504 unscaled;
- **(c)** AS-506's command, reconstructed as the PFT's χ_thr less Figure 11-1's error. It was fitted in GE504's form: four quartics split at 35, 80 and 115 s, rms 0.049° and max 0.115° over 14–160 s, with exact joins;
- **(d2)** a program iterated until the model's χ_thr matched the PFT's. It is a model compensation up to 0.67° away from (c), not AS-506 data;
- **(e1, e2)** run c with a 0.11° pitch thrust misalignment on all five F-1s, as a step at 105.6 s (e1) or from 10 s (e2).

Each run logged the command, attitude, error, χ_thr, α and the state every second. The model's error was compared with Figure 11-1 panel 2 and its χ_thr with the PFT's, both as 5-s means. States are taken at AS-506's event times, 135.20 and 161.63 s. §8.4 takes the test's first step at or after those times, so the deficits here are 0.4–0.7 m/s larger than §8.4's.

**Pitch thrust direction, model − AS-506 (PFT χ_thr).** Window means, with the rms in brackets, in degrees; + is nose up (less downrange):

| run | 15–40 s | 40–85 s | 85–112 s | 112–122 s | 122–161 s |
|---|---|---|---|---|---|
| a, ×1.025 | +0.28 (0.33) | +0.60 (0.60) | +0.29 (0.31) | −0.36 (0.44) | −0.27 (0.39) |
| b, ×1.000 | +0.35 | +1.14 | +1.47 | +1.03 | +1.31 |
| c, AS-506 command | −0.04 (0.09) | −0.05 (0.17) | +0.57 (0.57) | +0.06 (0.24) | +0.44 (0.48) |
| d2, PFT χ_thr matched | rms ≤ 0.07 in every window | | | | |

In yaw, model − PFT is −0.09° mean and 0.16° rms over 20–160 s in every run.

**CECO and OECO.** Model − AS-506 is in brackets. Climb is radius less the 4.815 km pad offset.

| run | CECO speed (m/s) | CECO γ (deg) | OECO speed (m/s) | OECO γ (deg) | OECO climb, model − AS-506 (km) |
|---|---|---|---|---|---|
| AS-506 (FER Table 4-2) | 1,979.0 | 22.957 | 2,764.1 | 19.114 | — |
| a | 1,967.03 (−11.97) | 23.157 (+0.200) | 2,750.10 (−14.00) | 19.099 (−0.015, fitted) | +0.05 |
| b | 1,954.65 (−24.35) | 24.249 (+1.292) | 2,732.52 (−31.58) | 20.371 (+1.257) | +1.84 |
| c | 1,971.95 (−7.05) | 23.231 (+0.274) | 2,753.61 (−10.49) | 19.420 (+0.306) | +0.17 |
| d2 | 1,974.08 (−4.92) | 22.915 (−0.042) | 2,757.13 (−6.97) | 19.088 (−0.026) | −0.32 |

**Findings.**

1. **The model's FCC lag matches AS-506's up to 100 s.** Over 20–100 s the 5-s means of the error are +0.424° for the model (run a) and +0.438° for AS-506, with an rms difference of 0.075°. Both are a1/a0 × rate. AS-506's wind-shear excursions of ±0.1–0.24° at 65–90 s are part of that rms.
2. **After 105 s the lag does not match.**
   - Over 105–160 s the model's error averages +0.314° and AS-506's −0.024° (rms difference 0.423°).
   - Over 140–161.6 s AS-506 held a pitch engine trim of about 0.1°. Panel 4 gives −0.101°, and the FCC law applied to panels 2 and 3 gives −0.103°. The error was −0.3° at OECO (FER §11.2.2).
   - The model's engines sit at 0 ± 0.01° after 110 s.
   - Before 140 s the comparison mixes the trim with high-altitude winds, separated flow, CECO and the arrest (FER §11.2.2). AS-506's α reached 1.82° at 117.1 s (Table 11-2); the model's was 0.01° in run a and 0.61° in run c.
3. **The trim's cause and onset are open.**
   - FER Table 11-1 gives 0.11° as the maximum *equivalent* pitch misalignment. That figure lumps thrust imbalance, CG offset and control misalignments. The table also lists a 0.12° pitch stacking/pad misalignment and a −0.06° centre-engine cant.
   - Applied from 10 s (e2), the 0.11° spoils the 20–100 s error: mean difference −0.12°, rms 0.15°.
   - Applied as a step at the 105.6 s gain switch (e1), it brings 140–160 s to −0.04° (rms 0.076°). That onset has no source, so e1 is a fit, not a test.
4. **AS-506 did not fly a scaled SA-504 polynomial.**
   - Its reconstructed command lies 0.6–1.5° further downrange than SA-504's from 40 to 160 s. The ratio to SA-504 falls from 1.13 at 40 s to 1.01 at 160 s, so it is not a scale.
   - Against ×1.025 it is 0.7–0.9° further downrange at 40–80 s, equal at 100 s, and 0.3–1.1° less downrange at 120–160 s.
   - Run a reaches the OECO flight-path angle by balancing errors. Its thrust is 0.60° nose-up of AS-506's at 40–85 s and 0.27–0.36° nose-down after 112 s.
5. **AS-506's command alone does not close the S-IC.**
   - Flown by the model (run c), it leaves −10.5 m/s and +0.31° at OECO.
   - Its thrust sits 0.57° nose-up of AS-506's at 85–112 s, and 0.44° nose-up at 122–161 s, partly the trim the model lacks.
   - Matching the thrust direction instead (d2) closes the flight-path angle (−0.03°) but leaves −7.0 m/s.
6. **Half of the OECO speed deficit is pitch history.** Run a − d2 is −7.03 m/s, +0.011° and +0.37 km at OECO, and −7.05 m/s, +0.24° and +0.30 km at CECO. The other half, d2 − AS-506, is −6.97 m/s, −0.03° and −0.32 km. The second reader's budget splits it as:
   - sensed-acceleration magnitude deficit, projected on the velocity: −6.1 m/s;
   - angle between thrust and velocity, from d2's early flight-path deficit: −3.6 m/s. That deficit is −0.13 to −0.19° at 20–60 s, and the magnitude deficit accounts for it within about 0.01°;
   - smaller gravity loss on that flatter path: +2.1 m/s;
   - weaker gravity on the higher pad: +0.8 m/s;
   - already present at 10 s: +0.52 m/s, about +0.31 of it the higher pad's extra Earth-rotation speed;
   - the 1-s grid: −0.7 m/s.

   The pad is worth about +1.1 m/s, so the vehicle's own share is about −8.1 m/s. E2 measures the same figure (§14.2).

### 14.2 E2: sensed-velocity budget

**Method.**
- **Model.** The default flight was flown from first motion in 0.02 s steps, with the app's steps in the IGM's high-speed loop. Each step's RK4 was replicated with the simulator's own functions, so its Δv splits exactly into gravity, thrust/m and aero/m (to 4e-8 m/s per step).
- **AS-506.** Its sensed velocity is each PFT interval's ΔV less that interval's J2 gravity integral. ∫|a_ng| is the sum of the intervals' |sensed ΔV|.
- **Comparison.** Both sides are compared over the same range times through AS-506's cutoff at 699.33 s. They are compared as vectors (FER Table 10-1's measure) and as scalars.
- **Check.** The second reader integrated the model on the PFT's own interval grid and got the same per-stage deficits within 0.1 m/s.

**Per stage, at the same range times (m/s):**

| window | \|ΔV_sens\| (vector), model | AS-506 (PFT) | FER Table 10-1, guidance / postflight | model − AS-506, vector | model − AS-506, scalar ∫\|a_ng\| | speed at the window's end, model − AS-506 |
|---|---|---|---|---|---|---|
| S-IC, 0.30–161.63 s | 3,289.36 | 3,303.57 | 3,303.54 (postflight less the pad) | −14.21 | −8.09 (−0.23 %) | −13.98 |
| S-II, 161.63–548.22 s | 4,586.88 | 4,583.74 | 4,583.2 / 4,583.8 | +3.13 | −6.64 (−0.14 %) | −16.27 |
| S-IVB, 548.22–699.33 s | 874.72 | 880.79 | 880.8 / 880.7 | −6.07 | −8.37 (−0.95 %) | −22.41 |
| whole flight | | | | | −23.11 (−0.25 %) | −22.41 |

**Findings.**

1. **The deficit is in all three stages: 23.1 m/s of ∫|a_ng|, 0.25 %, through 699.33 s.** At its own cutoff (702.74 s) the model's ∫|a_ng| equals AS-506's at 699.33 s: 9,132.40 against 9,132.67 m/s. The extra 3.4 s of S-IVB burn makes up the shortfall.
2. **S-IC: F/m runs 0.2–0.35 % low, and 0.4–0.8 % low in the first 20 s.**
   - The ∫|a_ng| deficit builds up as −1.52 m/s at 1–20 s, −1.75 at 20–60 s, −0.48 at 60–100 s, −2.49 at 100–135.2 s and −2.33 at 140–161.63 s.
   - It gains +0.28 at 0.3–1 s, where the model has no controlled release, and +0.19 across CECO.
   - The model's liftoff stage thrust is 34.11 MN against Figure 5-3's 34.35 MN.
   - The model's mass excess (+0.09 to +0.13 %) accounts for roughly 3 m/s (estimate). Only F/m is constrained.
3. **Drag is not the source.**
   - The deficit rate is smallest at 60–100 s (+0.01 to −0.09 %), which is where the model's drag peaks (−17.5 m/s over the window).
   - If the deficit ran there at its neighbours' −0.25 %, the model's aerodynamic deceleration at max q would be about 1.5 m/s (about 9 %) below AS-506's. The thrust-related S-IC deficit would then be about 9.6 m/s rather than 8.1.
   - A thrust error that varies with time would explain the same pattern.
4. **Only the misalignment part of the S-IC's shape loss is attitude.**
   - Misalignment between thrust and velocity costs 3.4 m/s, built up at 20–80 s. The model's a_ng is tilted 0.3–0.7° less downrange than AS-506's at 20–90 s: E1's pitch-program lag.
   - The 2.9 m/s of extra gravity loss is not shape. Flying slower at the same altitude costs 4.1 m/s, and weaker gravity at the higher radius gives back 0.8 m/s. The climb itself, within ±75 m of AS-506's, is worth under 0.4 m/s.
5. **S-II: the loss sits at and after the EMR shift.**
   - **490–500 s:** −5.07 m/s (−3.2 %). A single thrust step fitted to the PFT falls at 498.7–498.9 s. The model steps at 497.56 s and the FER's valve step is at 497.60 s, so AS-506's effective drop came about 1.2 s later.
   - **500–548.22 s:** −4.99 m/s, falling from −1.87 % to about 0 by 540 s. The model holds 3.072 MN for four engines. Figure 6-3 gives 3.093 MN after the step, 3.083 MN at 515 s and 3.054 MN at cutoff (§9.5 item 3), which explains part of it.
   - **200–460.62 s:** −1.15 m/s (−0.04 %). Through 490 s every 10-s window is within ±0.27 %, except around S-II CECO (−0.66 % / +0.38 %).
   - **In the model's favour:**
     - +0.84 m/s from the F-1 decay at 161.63–162.30 s. The model gives 12.81 m/s, the PFT 11.98, and FER §5.4's impulse about 12.85.
     - +2.74 m/s at 166–200 s. The model is 3–6.5 % above the PFT at 166–172 s (unexplained) and agrees with it at 180–190 s (8.09 against 8.07 m/s²).
6. **Vector increments hide scalar deficits.**
   - The S-II's |ΔV_sens| is 3.1 m/s above the PFT's while its ∫|a_ng| is 6.6 m/s below, because the model steers more coherently.
   - The S-IC's vector deficit (−14.2 m/s) is 6.1 m/s larger than its scalar one.
7. **S-IVB: F/m runs about 1 % low from 560 s.**
   - ∫|a_ng| is −0.80 to −1.56 % in every window from 560 s (mean −1.05 %), −8.88 m/s over 560–699.33 s.
   - The start, 548.22–560 s, nets +0.50 m/s. The model is 3–9 % above the PFT early in mainstage (§9.5 item 4).
   - At the FER's mass, AS-506's acceleration implies about 912 kN, against the model's 903 kN from Figure 7-2. The mass excess explains 0.6 m/s.
8. **The spherical pad flatters the model.**
   - The model's centre of mass starts 4,815 m further from the Earth's centre than the PFT's point.
   - The IGM aims at a geocentric radius, so the model climbs 4,606 m less. Its radius stays above AS-506's: +4,865 m at 161.63 s, +747 m at 548.22 s, +227 m at 699.33 s.
   - The head start is 47.2 kJ/kg of potential energy, plus 0.15 kJ/kg of kinetic. At cutoff that is about 6.1 m/s, or 0.9 s of S-IVB burn.
   - In the S-II the model's gravity loss is 10.3 m/s lower than AS-506's, nearly all of it from the 4,126 m less climb. Its steering costs 5.9 m/s more.
   - Over the whole flight the shape terms net +0.3 m/s for the model, the sum of two terms of about 12 m/s each with opposite signs. The IGM does not win the S-IC's shape loss back.

### 14.3 E3: state injection at T3 and T4

**Method.**
- **Injection.** AS-506's PFT state was rotated from PACSS 13 into the model's frame and injected at the model's own cutoff instants: 161.64 s for the S-IC and 548.24 s for the S-II. It was first propagated 0.01 or 0.02 s with gravity only, so that the model's own tail-off follows.
- **Injection check.** It covers radius, speed, flight-path angle, geocentric latitude and longitude, Earth-fixed speed, azimuth, elevation and heading. What remains is the propagation, 21 m and 128 m east.
- **Runs.** Nine flights were run. Each sequential run differs from the one before it in one thing, and their differences add up exactly to the default flight's 3.40 s.
- **R3** also holds AS-506's −68.90° after the arrest and raises the air by 4,913 m to AS-506's altitude.

**Cutoff time, one change at a time:**

| run | AS-506's in the run | model cutoff (s) | share of the delay (s) |
|---|---|---|---|
| R0 | nothing (the default flight) | 702.74 | |
| R8 | position at T3 | 704.67 | −1.93 (the higher pad) |
| R2 | position and velocity at T3 (+13.60 m/s) | 701.80 | +2.87 (the S-IC's velocity) |
| R3 | and the hold, −68.90° | 701.62 | +0.18 (the hold) |
| R4 | state at T4 | 700.86 | +0.76 (the S-II phase) |
| AS-506 (FER Table 10-2) | | 699.34 | +1.52 (the S-IVB phase) |

Side runs:
- R1 (R3 with the model's air): 701.63 s, 0.01 s.
- R7 (R3 with the PFT's actual target plane, 32.5209°/123.0890°): 701.61 s, 0.01 s.
- R6 (R4 with that plane): 700.78 s, 0.08 s.
- R5 (R4 with S-IVB thrust and Isp × 1.007, same flow): 699.92 s, 0.94 s.

**Upper stages flown from AS-506's state:**

| quantity | S-II from T3 (R3), model | S-II, AS-506 | S-IVB from T4 (R6), model | S-IVB, AS-506 |
|---|---|---|---|---|
| \|ΔV_sens\| (vector), m/s | 4,583.18 | 4,583.8 (postflight) | 880.97 | 880.7 (postflight) |
| ∫\|a_ng\| (scalar), m/s | 4,652.50 | at least 4,659.25 (PFT) | 877.2–877.3 (AS-506's 151.1 s window) | 885.63 (PFT) |
| vector / scalar | 0.9851 | 0.9838 | — | 0.9945 |
| at the stage's cutoff | 8.7 m/s slow, γ +0.130°, radius +129 m (against the PFT at 548.24 s) | — | cutoff at 700.78 s; +0.37 m/s and +201 m against AS-506's PFT state | cutoff at 699.34 s |

**Corrections from the second reader.**
- **R0 → R8 is not a pure radius step.** It also carries 0.012° of the 0.015° flight-path-angle difference and AS-506's −1.26 km downrange and −0.21 km crossrange offsets. R8 → R2 changes the speed by 13.60 m/s and γ by only 0.002°.
- **The T3 injection is biased late.** The gravity-only 0.01 s drops 0.38 m/s while AS-506 was still at full thrust, which makes the cutoff about 0.08 s later.
- **The S-II phase starts with a credit that belongs to the S-IC handover.**
  - From 161.63 to 164.00 s the model's tail-off, separation and S-II ullage motors give 1.1–1.5 m/s more than AS-506's 12.72 m/s.
  - Against that, the model's later S-II start costs −0.7 m/s at 164–166 s, and the S-II gains +2.4 m/s at 166–180 s.
  - The credit is worth 0.24–0.32 s. Moving it gives the split: **S-IC handover 0.80–0.88 s** (net of the pad), **S-II 1.00–1.08 s**, **S-IVB 1.52 s**.

**Findings.**

1. **Most of the delay belongs to the upper stages.**
   - From AS-506's S-IC cutoff state and hold, the model cuts off at 701.62 s, 2.28 s late.
   - From AS-506's S-II cutoff state, it cuts off at 700.86 s, 1.52 s late.
2. **The S-IVB is the largest single item, 1.52 s.**
   - **It delivers AS-506's sensed vector, but later.** Flown from AS-506's T4 state, it delivers 880.97 against 880.7 m/s, with a mean direction of −105.76° against −105.78°, but about 1.5 s later.
   - **The scalar is short.** In AS-506's window its ∫|a_ng| is 8.4–8.5 m/s (0.95 %) short. Per PFT row its acceleration runs 0.74–1.10 % low from 570 s, and its speed falls behind at 0.070 m/s per second.
   - **The cause is F/m.**
     - Mass is about 0.5 m/s (0.07 s): the stack's 83–113 kg excess.
     - The target plane is 0.08 s (R6).
     - The cutoff state is about 0.09 s.
   - **The FER conflicts with itself here.** The model's 903 kN follows Figure 7-2 over Table 20-5's mass. That ratio is itself 0.5–0.6 % below the measured 6.73 m/s² (Table 4-1, PFT; §9.5 item 5).
   - **Sensitivity.** R5's 0.7 % more thrust and Isp moves the cutoff 0.94 s earlier.
3. **The S-II reaches OECO 8.7 m/s slow and 0.13° steep, even from AS-506's state.**
   - **Direction.** Its mean thrust direction lies 0.20° nearer X_S than AS-506's (+15.9 m/s along X_S), which accounts for −7.8 of the −8.7 m/s.
   - **Pitch.** It pitches 1.0–1.5° further downrange than the PFT at 210–240 s and 0.8–1.4° less at 420–460 s.
   - **Vector match.** Its vector increment is within 0.6 m/s of Table 10-1's postflight value only because it steers straighter than AS-506 (about 6 m/s) and gains at the handover.
   - **Scalar shortfall.** Its scalar ∫|a_ng| is about 6.8 m/s short. That shortfall is in the data: per PFT row its acceleration is −4.5 % at 500 s, −1.0 % at 510 s, −0.6 % at 520 s and −0.4 % at 530 s (−7.6 m/s by trapezoid). These are E2's EMR-shift and low-EMR windows.
   - **Characteristic velocity.** At T4 it is 4,638.4 m/s, against about 4,646 m/s for AS-506 (PFT, 164 to 548.22 s).
4. **The hold costs 0.18 s.** ×1.025 holds −69.66°; AS-506 held −68.90°. The PFT's thrust direction is −68.65° at 180 s and −68.74° at 200 s, so AS-506's plateau is known to about 0.3°.
5. **The pad's worth depends on how it is measured:** 1.93 s in this sequence, 0.9 s as E2's energy head start. Sequential attribution depends on the order of the steps. Either way, the spherical pad currently hides 0.9–1.9 s of the S-IC's velocity deficit.
6. **IGM yaw.**
   - **From AS-506's T3 state (R3),** the model's thrust yaw is within −0.21 to +0.07° of the PFT's at 210–540 s, and within −0.15 to +0.34° at 580–699 s. Through staging, at 548–560 s, it differs by +0.6 to +0.7°.
   - **In the default flight,** §10.4's commanded yaw is within 0.23° of the PFT's thrust yaw at 240, 300, 400, 500, 580, 600 and 680 s.
   - **Figure 10-4's LVDC yaw** agrees with the PFT within 0.05° at 212–400 s, then sits 0.5–0.9° above it after 450 s. The §10.5 gap is therefore between Figure 10-4's command and AS-506's thrust direction, not between the model and AS-506.
   - **The cause of that offset is not established.** The candidates are the LVDC's steering-misalignment correction, active from 221.5 s (§10.2), and the figure's digitisation.

### 14.4 What the diagnostics establish and what they do not

**Established:**

1. **The model's S-IC flight control lags its command as AS-506's did, up to 100 s,** on TN5869's typical gains. A program taken from AS-506's data will therefore be flown as AS-506 flew it up to 85 s; at 85–112 s AS-506's command itself is uncertain by about 0.5° (not established, item 2).
2. **`pitchScale` compensates mostly AS-506's different pitch command, partly the unmodelled late trim; not an F/m or drag deficit.**
   - AS-506's command was not a scaled SA-504 polynomial.
   - Run a's OECO flight-path angle balances a 0.6° nose-up error at 40–85 s against a 0.3° nose-down error after 112 s.
   - The pitch history costs 7.0 m/s at OECO.
3. **The S-IC's 14.0 m/s at OECO splits into two halves.**
   - 7.0 m/s is pitch history.
   - 7.0 m/s is the rest: an 8.1 m/s F/m deficit less 1.1 m/s from the higher pad.
   - Drag does not cause it.
4. **The model's ∫|a_ng| is short in every stage:** 8.1, 6.6 and 8.4 m/s, 23.1 m/s (0.25 %) in all. The cutoff's 3.40 s is the burn time that makes this up.
5. **The S-IVB's share is the same by every measure:** 1.25–1.52 s, mostly its F/m, 0.9–1.0 % below the PFT's acceleration.
6. **The S-II's own shortfall sits at the EMR shift and in the low-EMR phase.** At the shift, AS-506's effective thrust step came about 1.2 s later than the model's.
7. **The spherical pad hides 0.9–1.9 s of the S-IC deficit.**
8. **The IGM's yaw follows AS-506's thrust direction within about 0.35° outside staging.**

**Cutoff delay by stage, three ways (s):**

| measure | S-IC | S-II | S-IVB | pad | total |
|---|---|---|---|---|---|
| E2, speed budget (∫\|a_ng\| ÷ 6.7 m/s²) | 1.2 | 1.0 | 1.25 | −0.1 (with shape) | 3.35 |
| E2, work budget (second reader; two methods agree within 0.4 kJ/kg) | 0.75 | 2.18 | 1.28 | −0.91 | 3.30, +0.1 end state |
| E3, sequential injection, corrected | 0.80–0.88 (pad included) | 1.00–1.08 | 1.52 | in the S-IC | 3.40 |

**Not established:**

1. **The late trim's cause and onset.** FER Table 11-1's 0.12° stacking misalignment also biases the command reconstruction, which assumes that attitude equals χ_thr.
2. **AS-506's command at 85–112 s to better than about 0.5°.**
   - Runs a and c fly the same attitude at max Q: −41.64° and −41.68° at 90 s.
   - Run c's closer α·q (4.88 deg·N/cm² at 89.2 s, against AS-506's 4.93 at 91.4 s) comes from its flight-path angle, not from a different attitude. At 90 s run c is at 28.97°, AS-506 at 29.00° and run a at 29.43°.
3. **Thrust against mass, or thrust against drag.** The PFT gives only (thrust + aero)/m. Where the FER contradicts itself, the model follows the thrust side:
   - S-IVB: Figure 7-2 over Table 20-5's mass, against Table 4-1, the PFT and Table 10-1;
   - S-II low EMR: Figure 6-3;
   - S-IC tail-off: §5.4's impulse against the PFT, 0.9 m/s apart;
   - early S-II: Figure 4-3 at 180 s.
4. **The split of the delay between the S-IC and the S-II.** It depends on the measure (table above). Only the S-IVB's share and the per-stage ∫|a_ng| deficits are robust.
5. **How the S-II's 1.00–1.08 s divides** between the EMR transition, the low-EMR thrust and the IGM's steering. No run tested the EMR step's timing, and AS-506's IGM presettings are unknown (§10.7).
6. **Two unexplained items:**
   - the S-II's 3–6.5 % excess at 166–172 s;
   - the S-IC's −3.5 m/s crossrange velocity at OECO. The model's a_ng points about 3 mrad (0.17°) further towards −Y_S at 20–60 s.
7. **The cutoff with a WGS-84 pad.** That pad also changes the S-IC's gravity (about 0.15 % stronger) and its Earth-rotation speed (about 0.3 m/s less), and any S-IC compensation would be refitted. R8's 704.67 s is not a projection of it.
8. **The point-mass test's cutoff time.** The probe printed it but no file kept it. The test also shares the model's S-II and S-IVB constants and IGM, so it is not independent evidence.

**Caveats.**
- AS-506's gravity is J2 only, which is worth about 0.05 m/s over the ascent.
- The PFT's cumulative totals are good to about 0.1 m/s. Its windows near events are less certain.
- The PFT rows at 460.62 s and 709.33 s are inconsistent in position by 105 m and 65 m.
- The T3 injection is biased about 0.08 s late.

**After the closure (§17, 2026-10-19).** Where the findings above stand after §17's single re-baseline (`NominalFlight`'s steps unless marked):
- **Established 2 and 3** (`pitchScale`; the S-IC's 14.0 m/s at OECO). `pitchScale` is gone: the IU flies AS-506's reconstructed command, and Figure 5-3's thrust at the PFT's level closes the F/m half. OECO is 4.7 m/s slow and 0.29° steep: the late trim, left unmodelled by decision.
- **Established 4** (every stage short). The integrals of \|a_ng\| against the PFT are −1.26 m/s for the S-IC (the frost and purge gas it now carries to separation), +1.58 for the S-II and −1.24 for the S-IVB; from AS-506's T3 state the S-II is −0.04 m/s from separation to OECO, from its T4 state the S-IVB +0.61 m/s over AS-506's 151.11 s.
- **Established 5** (the S-IVB's F/m). Its thrust follows AS-506's measured acceleration, 912 kN at 431.8 s: "not established" item 3 decided on the measured side (§17.6, §17.9 item 4).
- **Established 6** (the S-II at its EMR shift). The shift ramps over 2.4 s with its middle on the PFT's effective step: the 490–500 s window is −0.02 m/s, from −5.1.
- **Established 7** (the spherical pad). WGS 84 since §15.
- **Not established 3.** Decided: the measured side for the S-IC's level (§17.1) and the S-IVB (§17.6); Figure 6-3 for the S-II's low EMR, with the PFT running up to 1 % above its line in the first 10 s after the step (§17.9 item 2).
- **Not established 5.** Itemised from AS-506's T3 state: +2.3 m/s in the S-II's first 40 s, −0.02 at the shift, −3.7 in the low-EMR phase.
- **Not established 7.** The cutoff on the WGS-84 pad: 698.83 s (698.92 s in fixed 0.02 s steps).
- **Not established 8.** The point-mass test's cutoff is still not printed; its vehicle keeps §10's constants (§10.4).

The cutoff against AS-506's 699.34 s after §17: +0.13 s from AS-506's T4 state (the S-IVB alone), −0.28 s from its T3 state (the S-II and the S-IVB), −0.51 s in the default flight (§17.7, §17.8).

### 14.5 Recommendations for the next item

*Carried out in §17: items 1–2 in its S-IC part (17.1–17.5), items 4–6 in the rest (17.6–17.10); item 3 stands, the late trim left unmodelled.*

The next item replaces `pitchScale` with AS-506's pitch program and adds the unmodelled mass items. Each recommendation names the finding behind it.

1. **Fit the pre-IGM program to AS-506's reconstructed command in GE504's form** (E1 findings 4–5).
   - Four quartics split at 35, 80 and 115 s already fit it to 0.049° rms (0.115° max) with exact joins, so a different segment split is not needed.
   - Take the plateau after the arrest from AS-506. ×1.025's −69.66° against Figure 10-4's −68.90° costs 0.18 s (E3 finding 4).
2. **Fit the command, not the thrust direction, and make OECO γ a check** (E1 findings 5–6).
   - Matching the thrust direction (d2) closes γ to −0.03°, but it departs up to 0.67° from AS-506's command. That is a smaller compensation of the same kind as `pitchScale`.
   - The command (c) leaves +0.31° and −10.5 m/s at OECO. Record these as a known deviation tied to the 85–112 s offset and the late trim.
3. **Do not add a pitch thrust misalignment until its onset is sourced** (E1 finding 3). Applied from liftoff it spoils the 20–100 s error; applied at the gain switch it is a fit. Record AS-506's late trim as a known deviation: about 0.1° of engine deflection and −0.3° of error at OECO.
4. **Shed the unmodelled masses (§9.1), but expect them to close about a third of the 23.1 m/s at most** (E2 findings 2 and 7, E3 finding 2). §9.1's items are the S-II and S-IVB frost (204 and 91 kg) and the S-II purge gas (54 kg).
   - **S-IVB:** its 83–113 kg excess is 0.5 m/s, or 0.07 s.
   - **S-II:** its 351–370 kg excess is about 5 m/s of ∫|a_ng| (estimate), which the model's slightly higher S-II thrust happens to offset (E2). Removing it raises the S-II's F/m by 0.05 % at start and 0.17 % at OECO, within the ±0.27 % scatter of the 200–490 s windows.
   - **S-IC:** roughly 3 m/s (estimate).
5. **Size the impulse items before setting tolerances, largest first** (E2 findings 2, 5 and 7; E3 findings 2–3):
   - **S-IVB F/m:** −8.4 m/s, about 1.25 s. This is a choice between the FER's thrust reconstruction (Figure 7-2, Table 20-5) and its measured acceleration (Table 4-1, the PFT, the platform). Record the choice. R5 shows that 0.7 % is worth 0.94 s.
   - **S-IC F/m:** −8.1 m/s. It is 0.4–0.8 % low in the first 20 s (liftoff thrust 34.11 against 34.35 MN) and 0.2–0.35 % low after that.
   - **S-II:**
     - AS-506's effective EMR step came about 1.2 s after the valve step, which costs −5.1 m/s. *The core can now ramp a rating (§9.2, "Rating ramps"); the ramp's length is still to size.*
     - Figure 6-3's declining low-EMR thrust, in place of a constant 3.072 MN, explains part of −5.0 m/s.
   - **In the model's favour, to keep in view:**
     - the F-1 tail-off through S-II start: +1.1 to +1.5 m/s against the PFT;
     - the S-II's first seconds: +3 to +6.5 % at 166–172 s.
6. **Tolerances for 'closed'** (all findings):
   - **CECO and OECO.**
     - ±5 m/s cannot be met by the pitch program alone. OECO is −10.5 m/s with AS-506's command and −7.0 m/s with the thrust direction matched, because the S-IC's 8.1 m/s F/m deficit (less 1.1 m/s from the pad) remains.
     - Run c misses ±0.3° in γ by 0.01° at OECO.
     - Set the speed tolerance after the F/m items, or itemise the remainder.
   - **Attitude.**
     - Test the 20–100 s error to about ±0.25° on 10-s means: the model matches AS-506 to 0.075° rms, with wind-shear excursions up to 0.24°.
     - Do not test the error after 105 s while the trim is unmodelled.
     - Hold the command and thrust direction no tighter than 0.5° at 85–112 s, where run c is 0.57° off.
   - **Sensed velocity.**
     - Test each stage's scalar ∫|a_ng| against the PFT, not only Table 10-1's vector magnitude. The vector test would pass today's S-II (+3.1 m/s) while its ∫|a_ng| is 6.6 m/s short.
     - The data support tolerances of about 1 m/s. The PFT totals are good to 0.1 m/s, and the postflight reconstruction to 0.13 m/s. The LVDC's S-II and S-IVB increments are within 0.6 m/s of the PFT's.
   - **Cutoff.**
     - Apply ±1 s first to the injected runs, which depend on neither the S-IC nor the pad. Today they are +2.28 s from T3 and +1.52 s from T4.
     - On the spherical pad, a full-flight cutoff within ±1 s would rest partly on the pad's 0.9–1.9 s head start. Set the full-flight tolerance after the WGS-84 pad.
   - **Yaw.** Compare with the PFT's thrust direction. From AS-506's state the model stays within 0.35° outside 548–560 s.
   - **Point mass.** Record the point-mass test's cutoff time in its output (§14.4).

---

## 15. Earth figure and pad (M1 item: WGS-84 Earth ellipsoid)

Compiled on 2026-10-18. Until now the model's Earth was a sphere of the equatorial radius, 6,378,137 m, with altitude r − R. To keep the Earth's rotation speed and the inclination geometry right, the pad stood at LC-39A's geocentric latitude, which put it 4.8 km further from the centre than the real pad (§1.6, §5, §14). The Earth now has WGS 84's figure: altitude, latitude and the local vertical are geodetic, and the pad stands where AS-506 stood. The section also takes the core half of the "real launch scenario" item: range zero, and first motion at 13:32:00.3 UTC in the tests as in the app.

**Sources.**
- **NIMA TR8350.2** (WGS 84, 3rd ed., 2000): a = 6,378,137 m and 1/f = 298.257223563 (Table 3.1); b = 6,356,752.3142 m and e² = 6.69437999014 × 10⁻³ (Table 3.3); Somigliana's normal gravity, γe = 9.7803253359 and γp = 9.8321849378 m/s² (eq. 4-1, Table 3.4) (H).
- **IOGP Publication 373-7-2** (Geomatics Guidance Note 7, part 2), §4.1.1: the geographic/geocentric conversion (EPSG 9602) and its worked example on WGS 84 (H).
- **Vermeille**, "An analytical method to transform geocentric into geodetic coordinates", J. Geod. 85:105–117 (2011): the closed form, valid everywhere, inside the evolute included (H).
- **Fischer 1960** (a = 6,378,166 m, 1/f = 298.3): the ellipsoid of Apollo's trajectory altitudes (§5) (H).
- **FER** §10 and **GE504**: AS-506's space-fixed X_S was the geodetic vertical at the launch site, 28.6084° (GE504's sin φ_L = 0.478814) (H); **SP-4029** Ascent Phase: the pad at geocentric 28.4470° N, 80.6041° W, and the liftoff inertial velocity, 408.64 m/s (1,340.7 ft/s) (H).
- **PFT Table B-III** (AS-506 postflight trajectory): 59 m altitude at first motion; Table B-II: radius 6,373,355 m (H).

### 15.1 The model

| item | model | source | conf |
|---|---|---|---|
| figure | `Ellipsoid`: a, f; `bodyFixed(lat, lon, h)`; the closed-form `geodetic(position)`; the surface `normal`. `CelestialBody.figure` is a sphere of `radius` unless given; the Earth's is `.wgs84`. `radius` stays J2's reference radius, a | TR8350.2 | H |
| `geodetic` | Vermeille's k = 1 − e² + h/N, the root of p/(k + e²)² + q/k² = 1, from the positive root of u²(u − 3r) = e⁴pq/2: Cardano outside the evolute, the trigonometric form inside it, k in its cancellation-free form. Inside the evolute (the 43 km about the centre where several normals cross) it returns the nearest surface point; at the centre a pole, h = −b. A sphere (f = 0) returns the geocentric latitude and r − R | Vermeille 2011 | H |
| altitude | geodetic: the atmosphere and winds (the launch-day sounding is indexed by it), the aerodynamics' base pressure, the telemetry and the HUD, the surface contact | — | — |
| vertical | the normal through the point: the lift-off test (thrust against weight along it), the winds' horizontal, a landed vessel's axis, the surface contact's placement, the camera's horizon frame and its 2 m floor | — | — |
| latitude, longitude | geodetic (`Vessel.latitudeLongitude`, the HUD) | — | — |
| orbits | apsides stay radii less a; the IGM's targets are radii (§10.1) | — | — |
| pad | geodetic 28.6084° N, 80.6041° W, the base 26 m above the ellipsoid, the axis along the normal | FER, GE504, SP-4029; PFT (derived, M) | H / M |
| range zero | 1969-07-16 13:32:00 UTC (`AS506.rangeZero`); first motion, range 0.30 s (`VesselLibrary.apollo11FirstMotion`), opens the app's scenario and the tests' `Simulation.forTests`, and range time is read off range zero | SP-4029 | H |
| renderer | the planet is ray-traced as an ellipsoid: in body axes stretched along z by a/b it is the sphere of radius a, and the ray keeps its parameter t; |o|² − a² comes from the CPU in double. The texture and the grid take the normal's (geodetic) latitude | — | — |

**The pad's elevation.** The PFT's 59 m at first motion less the model's 33 m from the base to its centre of mass gives 26 m, taken above WGS 84. The PFT's altitudes are over the Fischer ellipsoid, whose surface is 30 m higher at the Cape: read so, the base is at 56 m and the centre of mass exactly at the PFT's radius, 6,373,355 m. The two readings differ by 0.55 m/s at CECO and OECO, 1.16 m/s at S-II OECO and 0.18 s at the velocity cutoff (56 m earlier). 26 m was chosen; which point of the vehicle the PFT's state refers to was not established.

### 15.2 Checks (`EllipsoidTests`, `SaturnIUTests.testOnThePad`)

| check | model | reference | tolerance |
|---|---|---|---|
| IOGP §4.1.1: 53°48'33.820" N, 2°07'46.380" E, h 73.000 m | X 3,771,793.968, Y 140,253.342, Z 5,124,304.349 m, both ways | IOGP 373-7-2 | 1 mm |
| b, e² | 6,356,752.3142 m; 6.69437999014 × 10⁻³ | TR8350.2 Table 3.3 | 0.1 mm; 10⁻¹⁴ |
| Somigliana against the model's GM, J2 and the centrifugal term, on the ellipsoid | within 8.2 × 10⁻⁶ to 75°, 1.2 × 10⁻⁵ at the poles (the model has no J4: 5 J4 = 1.2 × 10⁻⁵ there); direction within 0.0004° | TR8350.2 | 10⁻⁵ to 75°, 1.3 × 10⁻⁵ beyond; 0.001° |
| the pad's centre of mass, geocentric latitude | 28.4469° | SP-4029 28.4470° | 0.0002° |
| the pad's centre of mass, radius | 6,373,325 m | PFT 6,373,355 m | 40 m |
| the pad's inertial velocity, east | 408.636 m/s (the sphere: 408.946) | SP-4029 408.64 m/s | 0.05 m/s |
| the plumb line (X_S) at T1 | 28.6082° (the normal: 28.6084°; the difference is J4's) | FER, GE504 28.6084° | 0.001° |

### 15.3 Results (the IU flight, 0.02 s steps)

Before: main at e473acc, on the sphere, the tests starting at 13:32:00.0. After: this section, starting at first motion. Both flown with steps of at most 0.02 s ending on the IU's events, as `NominalFlight` steps.

| event | quantity | sphere (before) | WGS 84 (after) | AS-506 |
|---|---|---|---|---|
| first motion | centre-of-mass radius; inertial speed | 6,378,170 m; 408.946 m/s | 6,373,325 m; 408.636 m/s | 6,373,355 m (PFT); 408.64 m/s |
| CECO, 135.19 s | r; v; γ; altitude | 6,422,141 m; 1,966.71 m/s; 23.158°; 44.00 km over the sphere | 6,417,204 m; 1,965.54 m/s; 23.129°; 43.98 km geodetic | v 1,979.0 m/s; γ 22.957°; 44.0 km over Fischer (FER Tables 4-1, 4-2) |
| OECO, 161.65 s | r; v; γ; altitude | 6,444,216 m; 2,750.71 m/s; 19.097°; 66.08 km | 6,439,238 m; 2,749.50 m/s; 19.067°; 66.05 km | r 6,439.33 km; v 2,764.1 m/s; γ 19.114°; 66.1 km |
| S-II OECO, 548.25 s | r; v; γ | 6,560,310 m; 6,900.77 m/s; 0.697° | 6,559,085 m; 6,885.84 m/s; 0.813° | 6,559,961 m; 6,915.96 m/s; 0.614° (FER Table 10-2) |
| velocity cutoff | t; r; v; γ | 702.632 s; 6,563,329 m; 7,791.567 m/s; −0.0009° | 704.977 s; 6,563,330 m; 7,791.567 m/s; −0.0007° | 699.33 s (SP-4029); LVDC 6,563,335 m, 7,791.43 m/s, −0.0015° |
| insertion, cutoff + 10 s | r; v; γ | 6,563,329 m; 7,793.021 m/s; −0.0002° | 6,563,330 m; 7,793.027 m/s; −0.0002° | 6,563,335 m (LVDC) |
| orbit | i; θ_N; over the 6,378,165 m sphere | 32.5309°; 123.0975°; 185.171 × 185.098 km | 32.5309°; 123.0975°; 185.175 × 185.120 km | 32.532°; 123.102°; 186.0 × 185.2 km (LVDC) |

**What moved and why.**
1. **The S-IC flies from 4.85 km lower.** OECO's radius is now 92 m from the FER's 6,439.33 km, where it was 4.9 km above it. Altitudes over the ellipsoid compare directly with the FER's over Fischer, about 30 m apart at the Cape. The stronger gravity (0.15 %) and the 0.31 m/s less Earth rotation cost 1.2 m/s by OECO and 0.03° of flight-path angle: at its OECO the model is now 14.6 m/s below the FER's speed, against 13.4 m/s on the sphere (the S-IC's deficit, §9.5, §14.4 item 3).
2. **The S-II arrives at OECO 1,225 m lower and 14.9 m/s slower, 0.12° steeper.** The IGM has the same target radius and the S-II must climb the 4.85 km the pad no longer gives it. The S-II OECO speed is now 30.1 m/s below AS-506's, against 15.2 before.
3. **The velocity cutoff comes 2.35 s later, at 704.98 s:** 5.65 s after AS-506's, against 3.30 s on the sphere. §14 put 0.9–1.9 s of the old delay's S-IC share on the spherical pad's head start (§14.4 item 7; the work budget's −0.91 s); the head start is gone, so the whole stage deficit now shows. Closing it is §17's.
4. **The orbit is unchanged within 22 m** (perigee), and the plane within 0.0001°: the IGM closes the loop.
5. **In the app**, the scenario flown from the pad at 1,000× (Release, the 40 ms frame budget, about 160× achieved): the velocity cutoff at 704.977 s, as in 0.02 s steps, and a 186.26 × 185.16 km orbit over the 6,378,165 m sphere, i 32.531°, as the sphere's warp flights gave (about 186.2 × 185.15 km, the time warp's spread). At first motion the stack stands upright with its base 26 m above the drawn ellipsoid (neither the mobile launcher nor the terrain is drawn); the HUD shows 28.608°, −80.604°, 59.2 m and 408.6 m/s.

### 15.4 Known deviations

1. **The geoid is not modelled.** Heights are above the ellipsoid. At the Cape the geoid lies about 28 m below WGS 84 (EGM96; recalled), so the model reads the sounding, which is by height above sea level, about 28 m too low: its air is about 0.3 % too dense at the pad, and less above.
2. **Fischer 1960 against WGS 84.** Published altitudes are over Fischer 1960 with its own datum. The tests convert through `Ellipsoid.fischer1960` on WGS 84's centre and axes; the datum shift (tens of metres) is not modelled.
3. **The pad's elevation, 26 m, rests on reading the PFT's 59 m as above WGS 84** (§15.1); 56 m is the other reading.
4. **The gravity field is J2 only.** The plumb line at the pad is 0.0002° from the normal: J4's share.
5. **The pre-IGM pitch program was not refitted** (`pitchScale` 1.025, §8.4), and the §8.4 and §10.4 tables were not regenerated: they were the sphere's. *Done in §17: AS-506's command, and the tables regenerated.*

### 15.5 Tests

| test | checks | depends on |
|---|---|---|
| `EllipsoidTests.testWGS84DerivedConstants` | b and e² | TR8350.2 (H) |
| `testIOGPGeocentricExample` | the worked example both ways, to 1 mm | IOGP 373-7-2 (H) |
| `testRoundTrips` | geodetic → body-fixed → geodetic from 6,000 km below the surface to 10⁹ m, at every 7.5° of latitude, poles included | self-consistency |
| `testEdgeCases` | the centre (a pole, h = −b), the poles, the axis inside and outside the evolute, the equatorial plane inside it, a sphere, a vanishing flattening | Vermeille 2011 |
| `testNormal` | the normal is the gradient of the ellipsoid's equation; heights are along it | geometry |
| `testSomiglianaNormalGravity` | §15.2 | TR8350.2 (H) |
| `SaturnIUTests.testOnThePad` | the geodetic pad, its elevation, the axis along the normal; §15.2's three cross-checks; first motion at 13:32:00.3 UTC | FER, GE504, SP-4029, PFT (H) |
| `DynamicsTests.testVesselOnPadRotatesWithEarth`, `SaturnVFlightTests.testStandsOnPad` | a landed vessel keeps its geodetic place, height and axis along the normal; it turns at (N + h) cos φ from the axis | geometry |

Pins widened by this section, each marked "see §17" in its test (the final pins are in §17.10); nothing else was loosened, and `pitchScale` and the §8.4 and §10.4 tables were left for §17:

| test | pin | before | now | model, in the test |
|---|---|---|---|---|
| `SaturnIUTests.testIGMFliesApollo11ToItsParkingOrbit` | S-II OECO speed against AS-506's 6,915.96 m/s | ±30 m/s | ±35 m/s | 6,885.4 m/s |
| same | S-II OECO flight-path angle against 0.614° | ±0.15° | ±0.25° | 0.814° |
| `SaturnVSeparationTests.testSpentStagesClimbAsPredicted` | the spent S-II's apex time against the PFT's 587.0 s | ±5 s | ±10 s | 595.0 s |

Two tests changed what they measure, not their tolerances:
- `testSICAscentMatchesApollo11` takes the climb from the pad's geodetic altitude (the sphere's r − R would carry the 4.8 km), and its CECO and OECO altitudes, now geodetic, compare with the FER's directly: 43.98 and 66.05 km against 44.0 and 66.1 km.
- `testSpentStagesClimbAsPredicted` compares the apexes as heights over Fischer 1960 (`Ellipsoid.fischer1960`) instead of as climbs above the pad: the S-IC 113.6 km at 267.5 s (PFT 115.0 km at 269.1 s), the S-II 189.1 km (188.8 km), both within 1.5 km.

---

## 16. Engine out (M1 item: engine-out)

Compiled on 2026-10-18. An engine of the S-IC or the S-II can now fail in flight, and the IU reacts as AS-506's flight program did, as far as its documents show: it senses the engine out, freezes the S-IC's pitch program for a time set by the failure time, and stretches the S-II's predicted burn for the IGM. The failure comes from a schedule on the IU (`SaturnIU.scheduleFailure`), which is public so that the app can add a failure key and scenarios without changing the core. With no failure scheduled every new branch stays idle, and the nominal flight is unchanged to the bit (16.2). `SaturnIU.swift` holds the logic, `IterativeGuidance.swift` the S-II reaction, `AS506EngineOut.swift` the values, and `Thruster.fail()` the failure itself.

**Sources** (read directly; tables and figures from the page images):

- **GE504** (Boeing D5-15706-4). Table 4-II, "S-IC engine out" (the T_EO1 latch and t_FAIL), "Freeze time calculation", the pre-IGM χ_Y steering on t_c − Δt_f, and "S-II IGM engine out"; Figure 3-4, the SA-504 reduced-loads chi-freeze schedule; Figure 4-4, the pre-IGM logic; Figures 4-5 and 4-6, the IGM stage logic and its engine-out presettings (T1, T2 and τ2 times 5/4); Table 5-I's presettings (B11 −0.62, B12 40.9 s, B21 −0.3611, B22 29.25 s, t_2 25, t_3 36, t_4 45, t_5 81 s). H for SA-504, M for AS-506.
- **MAN506** (MSFC-MAN-506). Page 2-17: the chi-freeze schedule "is incorporated into the vehicle guidance program as an alternate" for the loss of thrust of an S-IC engine (H: AS-506's program had it). §2 and §3: the IU's switching logic reads the thrust OK pressure switches of each engine, whose engine status lights come on below 90 % of rated thrust on an F-1 and 65 % on a J-2; the EDS automatic abort on two or more S-IC engines below 90 %, armed from liftoff until the crew turns it off at 2 min. Figure 3-7, the abort limits: on the S-IC a single engine failure continues the mission and two are an abort; on the S-II one continues, two are an abort if control is lost (rates over 9°/s), and three or more an abort if before S-IVB capability (H).
- **AS-506 FER** Table B-4: the flight program flew an "expanded S-II IGM guidance", which adjusts automatically for performance far off nominal and has an inherent capability for more than one S-II engine out (H).
- **AS-508 FER** (MPR-SAT-FE-70-2; Apollo 13). Table 2-2: S-II engine 5 cut off at 330.65 s, T3 + 167.00 s, 132.36 s before its planned cutoff; the IGM's EMR shift command 32.2 s later than predicted, S-II OECO 34.53 s later, the S-IVB velocity cutoff 44.06 s later. §6.1: the delays are mainly the early cutoff's, and to a smaller degree the engines' performance (S-II thrust 0.19 % and flow 0.25 % below prediction) and the upper stages' heavier loads. Table 4-5: insertion near nominal (0.2 km, −0.5 m/s, its navigation's errors included). §9: the expanded IGM's reaction to a thrust loss did not depend on the engine-out discrete, which only set a telemetry bit; AS-505's IGM, the last without it, reacted on the discrete after sampling the acceleration for three cycles (H).
- **AS-502 FER** (MPR-SAT-FE-68-3; Apollo 6) §11: S-II engines 2 and 3 cut off at 412.92 and 414.18 s (the thrust OK switches' dropout); the pitch attitude error reached 13.4° at a rate of 2.8°/s, with up to 5.95° of engine deflection (H). A sanity bound on the control transient, not a calibration target.

AS-506's own engine-out presettings were not found: GE504's SA-504 values stand in, as they do for the pitch program (§8.4).

### 16.1 The model

| item | model | basis | conf |
|---|---|---|---|
| failure | `Thruster.fail()`: latched, apart from `isEnabled` (a flight program's cutoff, which it can undo). From the next step the engine is no longer commanded and falls along its shutdown ramp as on a cutoff; nothing restarts it. A failed solid not yet lit is a dud. `isAvailable` is `isEnabled` and not failed | — | — |
| failure schedule | `SaturnIU.scheduleFailure(of:at:)`: an engine by name, at a range time (T1 at 0.63 s), a time-base offset or an epoch. Each failure is applied at the start of the step at its time, and `timeToNextEvent` ends a step there, so it lands on its time at any warp (to the simulation's 1 ms minimum step) | — | — |
| engine-out discrete | the IU senses an engine out, once, when a main engine it did not cut off itself (its own cutoffs are kept apart) delivers under its stage's thrust OK level with the main throttle open: 90 % of rated thrust on the S-IC, from T1 + 6 s until T3; 65 % on the S-II, from mainstage (an S-II engine at 65 %) until T4. The F-1's 0.66 s decay passes 90 % 0.066 s after the cutoff, the J-2's 0.38 s decay 65 % after 0.133 s; the model senses it on the step that samples less | MAN506 §2, §3 (thrust OK levels: M as the LVDC's); T1 + 6 s from the planning study's reading of GE504 (L, not re-read) | M / L |
| T2 | starts on the IU's own centre engine cutoff, no longer when the centre engine is merely not enabled: an early failure of S-IC engine 5 would have started T2 at once, dropping T1's gain switches at T1 + 105 and 130 s, the cant and the timed cutoff | FER Table 2-1 (T2: the CECO sensed) | H |
| stage cutoff | an engine that has failed counts as out in the time bases' burnout and firing tests, so losing every engine of a stage starts the next time base at that step | — | — |
| S-IC chi freeze | on the first S-IC engine out (T_EO1), at t_FAIL s from T1: Δt_f = 36 s from 25 s for t_FAIL ≤ 25 s; 40.9 − 0.62 t_FAIL from the failure to 45 s; 29.25 − 0.3611 t_FAIL to 81 s; none after. The pitch program holds its value through the freeze, then runs Δt_f s behind (`TiltProgram.pitch(at:bias:arrest:)`), on from where it held. The tilt arrest moves out to t_AR + (t_AR − t_FAIL)/4 (from 159.37 s), and not for a failure after the arrest, when the LVDC already holds the command | GE504 Table 4-II, Figure 3-4 | H (SA-504), M (AS-506) |
| S-II IGM | on the S-II discrete the IGM scales the remaining T2, τ2 and τ2N by k = the engines its stage 2 presettings assume over those of them left: GE504 Figure 4-6's 5/4 generalised to AS-506's planned S-II CECO, whose presettings are the four outboard engines'. k is 4/3 for an outboard J-2 (2 for two), 1 for the centre engine. T1 comes from the characteristic velocity (§10.2) and needs no factor. T2 is no longer reset to its presetting at the shift, which keeps the scaling; in a nominal flight T2 does not count down in stage 1, so that changes nothing | GE504 Figs 4-5, 4-6; FER Table B-4 | M (proxy, 16.3 item 2) |
| timed cutoffs | the S-IC's centre engine cutoff at T1 + 134.56 s and the S-II's at T3 + 299 s stand with an engine out, and the log says so ("(with S-IC engine 1 out)", "(engine already out)") | not found for AS-506 | L |
| aborts | logged only: two S-IC engines out (the EDS automatic abort before 120 s range time, an abort limit after), two S-II engines out (abort if control is lost), three (abort limit) | MAN506 Figure 3-7, §3 | H (rules) |
| log and HUD | each failure, each engine-out sensed, the freeze and the IGM factor go in the IU's log; the status line ends ", engine out: S-II engine 5" (", engines out: ..." for more) while the engine is aboard, and reads "chi freeze (engine out)" during the freeze | — | — |

### 16.2 Results

**Nominal flight unchanged.** The IU flight with no failure (`NominalFlight`'s steps, and the IU tests' fixed 0.02 s steps) gives bit-identical final states, event times and logs before and after this section:

| | event-ending steps | fixed 0.02 s steps |
|---|---|---|
| CECO, T2 | 135.190, 135.210 s | 135.190, 135.220 s |
| OECO (T3) | 161.650 s | 161.640 s |
| S-II OECO (T4) | 548.251 s | 548.240 s |
| S-IVB velocity cutoff | 702.632352 s | 702.743239 s |
| insertion (cutoff + 10 s): r, v, γ | 6,563,329.11 m, 7,793.0206 m/s, −0.000190° | 6,563,328.73 m, 7,793.0176 m/s, −0.000194° |
| i, θ_N | 32.530889°, 123.097451° | 32.530888°, 123.097439° |

**Apollo 13 analogue** (`EngineOutTests.testApollo13AnalogueMatchesAS508`): S-II engine 5 failed at T3 + 167.0 s (AS-508's time from T3), against the nominal flight. The IU senses it 0.13 s on; the IGM's factor stays 1. The same deltas came from today's IGM with the engine cut by hand (before this section's logic), so they are the vehicle's and the IGM's own response, not the new scaling's.

| | nominal | engine 5 out | model Δ | AS-508 Δ (FER Table 2-2) |
|---|---|---|---|---|
| EMR shift command | 494.75 s | 527.05 s | +32.30 s | +32.2 s |
| S-II OECO (T4) | 548.25 s | 581.53 s | +33.28 s | +34.53 s |
| S-IVB velocity cutoff | 702.63 s | 747.82 s | +45.19 s | +44.06 s |
| insertion r, v | 6,563,329.1 m, 7,793.020 m/s | 6,563,331.3 m, 7,793.048 m/s | +2.2 m, +0.03 m/s | near nominal (Table 4-5) |

*After §17's refits (§17.7) the deltas are +32.30, +33.28 and +44.73 s (nominal shift 494.75 s, failed 527.05 s); main before §17 gave +32.30, +33.28 and +44.88 s.* The S-II's OECO comes 1.25 s earlier than AS-508's: AS-508's own S-II flowed 0.25 % below prediction, about 1.1 s over its 429 s burn, which the model's delta does not contain. The model's S-IVB then burns 11.9 s longer than nominal against AS-508's 9.5 s, so its velocity cutoff ends 1.1 s later than AS-508's delta.

**S-IC engine out** (`testSICEngineOutReachesOrbit`, `testChiFreezeHoldsAndResumesWithoutAStep`, `testEarlyCentreEngineFailureKeepsT1Events`): every case keeps its timed centre engine cutoff, reaches the IGM's velocity cutoff on V_T − ΔV_B within 0.01 m/s and inserts within 50 m and 0.003–0.006° of the nominal flight's radius and plane.

| failure (s from T1) | sensed | chi freeze | tilt arrest | T3 | T4 | velocity cutoff | insertion speed against nominal | S-IVB LOX, LH2 left |
|---|---|---|---|---|---|---|---|---|
| none | — | — | 159.37 | 161.65 | 548.25 | 702.63 | — | — |
| engine 1 (outboard) at 30 | 30.06 | 22.26 s from 30.06 | 191.70 | 204.85 | 591.45 | 879.82 | +0.40 m/s | 34.9 t, 7.0 t |
| engine 5 (centre) at 60 | 60.06 | 7.56 s from 60.06 | 184.20 | 180.17 | 566.77 | 755.15 | +0.09 m/s | 52.7 t, 10.7 t |
| engine 3 (outboard) at 90 | 90.06 | none | 176.70 | 185.17 | 571.77 | 760.22 | +0.07 m/s | 52.7 t, 10.7 t |

Range times are 0.63 s later than times from T1. The IU's pitch command is the program's exactly through the freeze and after it, below the 1°/s limit, except where that limit takes two steps over the polynomial's own joins of up to 0.04° (§8.4), as in the nominal flight. The arrest extended past T3 keeps the pitch program running into the S-II burn until the IGM starts, as GE504 Figure 4-4 does. With the centre engine out early, T1's gain switches at 105 and 130 s and its timed cutoff at 134.56 s stand, and T2 starts on that cutoff.

**S-II outboard engine out** (`testSIIOutboardEngineOutStretchesStage2`): engine 2 at T3 + 10 s. The IU sets k = 4/3 and the IGM starts with T2 and τ2 at 4/3 of their presettings. The attitude error peaks at 5.1° and the pitch and yaw rate at 1.27°/s, inside Apollo 6's two-engine-out 13.4° and 2.8°/s. On the point mass of §10.4 (`IterativeGuidanceTests.testIGMFliesAPointMassWithAnOutboardSIIEngineOut`), an outboard J-2 out at 328.6 s moves the shift command to 550.2 s; there the IGM's T2 is 71.2 s against the 70.8 s the three engines then burn (without the factor it would be 53.4 s), and the cutoff still lands within 100 m, 0.005° and 0.002° of the target.

**Losing every engine of a stage** (`testLosingEveryEngineOfAStageStartsTheNextTimeBase`): all five J-2s failed at T3 + 20 s start T4 at that step, and the S-IVB's sequence follows.

### 16.3 Known deviations

1. **AS-506's own engine-out presettings were not found.** The freeze schedule, the arrest extension and the IGM's stage 2 presettings are SA-504's (GE504), M for AS-506. MAN506 confirms only that AS-506's program had a chi freeze.
2. **The S-II reaction is GE504's discrete-triggered scaling, not AS-506's expanded IGM.** AS-506 flew an "expanded S-II IGM" (FER Table B-4) that adjusted its stage 2 predictions from the measured performance, so that by AS-508 the engine-out discrete only set a telemetry bit (AS-508 FER §9). Its equations were not found. The model scales T2, τ2 and τ2N on the discrete, as GE504 Figure 4-6 does (AS-505's way, without its three-cycle check of the acceleration), with the factor generalised to AS-506's planned S-II CECO. For the centre engine both reduce to no change in the presettings (k = 1), which is the Apollo 13 case.
3. **Thrust OK levels and sensing start.** The 90 % (F-1) and 65 % (J-2) levels are MAN506's for the EDS engine status lights, taken for the LVDC's engine-out discrete (M). The brief this section was built from had 65 % for both; the difference moves the S-IC's sensing 0.18 s earlier. The S-IC's sensing from T1 + 6 s is the planning study's reading of GE504, not re-read (L). The model samples the discrete every step, the LVDC every computation cycle.
4. **Fixed FCC mixing is not modelled (deferred).** The model's control allocation re-mixes the gimbals still firing every step (`ControlAllocation`, Gimbal.swift); the Saturn's flight control computer mixed the actuator commands in fixed proportions. After an engine out the model's control is therefore somewhat better than AS-506's would have been.
5. **Aborts are logged, not flown,** and the S-IVB's engine-out reactions are not modelled: a failed S-IVB J-2 starts T5 as any S-IVB cutoff does.
6. **Hard cutoffs only.** There is no partial thrust loss: Apollo 6's engine 2 ran at reduced thrust from 319 s until it cut off at 412.9 s.
7. **The timed centre engine cutoffs stand with an outboard engine out.** Whether AS-506's program inhibited the S-II CECO with an outboard engine already out (leaving three, or two with two out) is not known; the S-IC's cutoff at T1 + 134.56 s limited the vehicle's acceleration and is kept.
8. **ΔV_B is the nominal decay's.** A long S-IVB burn after an early S-IC engine out leaves a lighter S-IVB at cutoff, which the J-2's decay takes 0.40 m/s past circular speed for the failure at 30 s (134 s more S-IVB burn, about 29 t lighter). The LVDC's ΔV_B was a presetting too.
9. **A stage that loses every engine starts the next time base at the failure step,** not on its propellant-depletion sensors.
10. **At exactly 25 s** the model follows Table 4-II (36 s from 25 s); Figure 3-4 puts 25 s itself in the next row (25.4 s from 25 s).

### 16.4 Tests (`EngineOutTests`, and `IterativeGuidanceTests` for the point mass)

The four full flights (the Apollo 13 analogue and the three S-IC cases) are flown once and shared by the tests that read them, as `NominalFlight` is.

| test | checks | depends on |
|---|---|---|
| `testFailureIsLatchedAndDistinctFromACutoff` | a failure stops the engine along the same shutdown ramp as a cutoff (900 N on the first step of a 1 kN engine with a 0.5 s ramp); a cut engine restarts when enabled again, a failed one does not; a failed solid is a dud | — |
| `testChiFreezeScheduleIsGE504Figure34` | Table 5-I's presettings; Figure 3-4's freeze durations (36 s from 25 s, 25.4 s just after 25 s, 22.3 at 30, 13.0 at 45, 7.584 at 60, 0.0009 at 81, none at 90), the lines joining at 45 s and reaching 0 at 81 s; the arrest extension, none after the arrest; the biased pitch program, bit for bit the program at bias 0 | GE504 (H) |
| `testFailureLandsOnItsTimeAtTenTimesWarp` | stepped as the app steps at 10×, a step starts on each failure (in range time and on a time base) and the log has it there; each sensed 0.066 ± 0.021 s on; the second S-IC engine out logs the EDS automatic abort; the status line names both | MAN506 (90 %) |
| `testChiFreezeHoldsAndResumesWithoutAStep` | engine 1 at 30 s: sensed within a step of 30.066 s; freeze 40.9 − 0.62 t from there; arrest t_AR + (t_AR − t)/4; the command the program's through the freeze and after it (outside the polynomial's joins), below 1°/s, and continuous across the resumption | GE504 (H) |
| `testEarlyCentreEngineFailureKeepsT1Events` | engine 5 at 60 s: T1's gains at 0, 105 and 130 s; the timed cutoff at 134.56 s logged "(engine already out)"; T2 within a step (and the 1 ms minimum step) after it; freeze 29.25 − 0.3611 t | GE504 (H) |
| `testSICEngineOutReachesOrbit` | the three S-IC cases: the velocity cutoff on V_T − ΔV_B (0.01 m/s); insertion r 50 m, v 0.6 m/s, γ 0.005°, i 0.003°, θ_N 0.006° from the nominal flight; the S-IVB keeps over 25 t of LOX and 5 t of LH2; the outboard cases' CECO logged with the engine out; no freeze at 90 s | — |
| `testApollo13AnalogueMatchesAS508` | the EMR shift command +32.2 s ± a cycle (1.7 s), S-II OECO +34.53 ± 2 s, the velocity cutoff +44.06 ± 2 s against the nominal flight (AS-508's flow alone is 1.1 s); k = 1; the cutoff on V_T − ΔV_B; insertion within 50 m, 0.25 m/s, 0.005°, 0.003°, 0.006° of the nominal flight's | AS-508 FER Table 2-2, §6.1, Table 4-5 (H) |
| `testSIIOutboardEngineOutStretchesStage2` | engine 2 at T3 + 10 s: k = 4/3; the IGM starts with T2 and τ2 at 4/3 of their presettings; attitude error under 13.4° and rate under 2.8°/s | GE504 Fig 4-6 (H); AS-502 FER (sanity bound) |
| `testLosingEveryEngineOfAStageStartsTheNextTimeBase` | all five J-2s failed at T3 + 20 s start T4 there; the S-II separates | — |
| `IterativeGuidanceTests.testIGMFliesAPointMassWithAnOutboardSIIEngineOut` | an outboard J-2 out at 328.6 s: T2 and τ2 times 4/3; T2 at the shift within 3 s of the three engines' burn (a quarter short without the factor); the same shift command either way; the cutoff on target (100 m, 0.005°, 0.002°) | GE504 Fig 4-6 (H) |

**Values tests must not depend on**: the thrust OK levels beyond the sensing step; the sensing start; the S-IVB's propellant margins after an engine out (its unusable masses are the model's, L); the S-IC cases' event times, which rest on the SA-504 freeze.

---

## 17. Residual closure (M1 item: ascent residuals)

Compiled on 2026-10-19. §14 placed the ascent's residuals by stage; this section closes them, stage by stage, within itemised tolerances rather than to zero. The S-IC's part is 17.1–17.5. 17.6–17.11 book the frost and purge gas, close the S-II and the S-IVB, and re-baseline the whole flight once: the final pins, and the tables of §8.4, §9.4, §10.4 and §12.3 regenerated.

Three changes, each in `AS506Data.swift`:
1. **The pitch program is AS-506's own command,** reconstructed from its flight, in place of SA-504's polynomial times `pitchScale` (deleted).
2. **The F-1's thrust has its own history,** FER Figure 5-3's stage thrust, separate from the flow, at the level AS-506's measured acceleration needs (`sICThrustScale`, fitted).
3. **The F-1's flow and mixture ratio are refitted** to the S-IC's tanks at CECO as well as at OECO.

**Sources.**
- **PFT** Table B-II (H), and FER Figure 11-1's attitude error (digitised, M), through `tools/fit_as506_pitch.py` (§14.1; PR #17).
- **FER Figure 5-3** (M): the stage thrust, digitised in `tools/data/fer506_fig5_3_sic_thrust.csv` (0.017 MN and 0.16 s a pixel).
- **FER Table 5-2** (H): the reconstructed propellant at CECO, LOX 216,633 kg and RP-1 99,059 kg, and at OECO, 18,041 and 13,954 kg.
- **FER Table 20-1** (H), read from the page images (document page 20-2): the S-IC at CECO, 2,809 kg of GOX in the LOX tank's ullage; frost 635 kg at release and 340 kg at CECO; N2 purge gas 36 and 20 kg; the S-II 479,964 and 479,706 kg; the S-IVB 119,119 and 119,029 kg; the vehicle 2,899,008 and 1,110,189 kg.
- **FER Table 4-1** and the PFT's 161.63 s row (H): AS-506's sensed acceleration at OECO, 38.61 m/s².
- **FER §4.2.1** (H): the PFT's first 20 s were established by integrating the IU's accelerometer data. **§5.3** and **Table 5-1**: the engines' sea-level Isp at 35–38 s, 2,594 N·s/kg on average (H).

### 17.1 The model (S-IC)

| item | model | basis | conf |
|---|---|---|---|
| pitch program | `AS506.pitchCoefficients`: `fit_as506_pitch.py`'s default fit in GE504's form, four quartics split at 35, 80 and 115 s, exact joins, −68.90° at the 159.37 s arrest; rms 0.057°, max 0.147° against the reconstructed command; rates ≤ 0.74°/s. GE504's coefficients stay as `sa504PitchCoefficients` (transcription test). An S-IC engine out runs the program behind (§16) as before, to T1 + 179 s at the latest, where the last quartic is at −77.2° and −0.67°/s | PFT (H), Fig. 11-1 (M), Fig. 10-4 hold (M); assumes attitude along the sensed acceleration (§14.4) | M |
| F-1 thrust (shape) | `sICThrustHistory`: Figure 5-3's site thrust plus n p A_e (A_e 10.10 m²) at the launch-day pressure on AS-506's altitude over the Fischer ellipsoid (PFT), which is the altitude the model flies as its geodetic height (59 m on the pad, §15), so the model's site thrust is the figure's along AS-506's path. Least-squares piecewise-linear knots every 5 s: five engines to 134 s, four from 137 to 160.5 s, the first four-engine knot at the five engines' thrust per engine; 0.035 % rms (0.18 % max) and 0.05 % (0.13 %) against the figure's samples. The last knot, past the figure's undigitised hook after 160.5 s, is AS-506's sensed acceleration at OECO (38.61 m/s²) over the FER's 827,292 kg | Fig. 5-3 (M); PFT and Table 4-1 at OECO (H) | M |
| F-1 thrust (level) | `sICThrustScale` 1.0022 on the whole history, fitted to the nearest 0.0001 on the PFT's S-IC ∫\|a_ng\| with the 661 kg of frost and purge gas AS-506 had shed by CECO taken off (linearly to CECO, 1.3 m/s; 17.3 item 3) | PFT (H), the FER's masses (H), §11's aerodynamics (M) | M (fitted) |
| F-1 flow and mixture ratio | `sICFlowHistory` (Figure 5-3, unchanged) with two scales each: five engines 0.999385 and 0.999840, four engines 0.996609 and 0.998441 (were 0.99896 and 0.99965 on the whole burn). Fitted so the tanks hold Table 5-2's 216,633 kg of LOX (with Table 20-1's 2,809 kg of GOX) and 99,059 kg of RP-1 at 135.20 s, and LOX runs out at 161.63 s with 13,954 kg of RP-1 | Tables 5-2, 20-1 (H) | H (targets), fitted |
| F-1 rating at first motion | 7,908,340 N vacuum per engine (39.455 MN × 1.0022 for the stage), 2,631.4 kg/s, so 306.5 s; over the burn thrust over flow is 304.1–306.5 s, 304.7 s on the burn's impulse over its propellant (Betts' rated 304.1 s). It was 7,847,657 N, the figure's flow times a constant 2,980.5 N·s/kg (304.2 s on the scaled flow) | the two histories | — |

**Why the level is fitted.** With Figure 5-3's thrust as printed, the FER's propellant and §11's aerodynamics, the model's S-IC gains 10.3 m/s (0.28 %) less ∫\|a_ng\| than the PFT, 8.9 m/s with the frost and purge gas shed. A force budget along the model's flight (thrust, aerodynamic force along it, mass) against the PFT's sensed acceleration in 5 s windows gives the thrust AS-506's acceleration needs on the FER's mass (Table 20-1, frost shed). Where drag is under 1 % of thrust, it is 0.3–0.6 % above the figure at 1–20 s (the PFT's accelerometer-integrated span), 0.1–0.3 % at 100–130 s and 0.1–0.5 % at 140–160 s; at 60–100 s, where drag is up to 4 % of thrust, it is −0.2 to +0.2 %, within the aerodynamics' uncertainty. The figure is a reconstruction from engine data (§5.3), and its own panels disagree by 0.6 % at liftoff: its thrust is 0.6 % above its flow times its specific impulse there (§9.2). The PFT, not the figure, sets the level; this is the S-IC's counterpart of the S-IVB's thrust from the measured acceleration (17.5). At `sICThrustScale` 1 the figure stands as printed.

**What stays.** The program start at T1 + 10.7 s (§8.5: AS-506's at T1 + 12.6 s); the fit is +0.37° there against +0.08° at AS-506's start. The late pitch trim (§14.1 finding 2) stays unmodelled. The frost and purge gas stay aboard (17.5).

### 17.2 Results (S-IC)

**The default flight against AS-506** (`AscentResidualTests.testModelResidualsAgainstThePFT`, `NominalFlight`'s steps; model − AS-506 at AS-506's event times, against PFT Table B-II):

| quantity | main (5bcfdd5) | + pitch, Figure 5-3, flow (40791cb) | + level (this section) |
|---|---|---|---|
| CECO, 135.20 s: speed; γ; radius | −13.29 m/s; +0.169°; −49 m | −8.51; +0.213; −147 | −2.42; +0.291; +179 |
| OECO, 161.63 s: speed; γ; radius | −15.28 m/s; −0.045°; −114 m | −12.85; +0.223; −19 | −5.07; +0.294; +448 |
| S-IC ∫\|a_ng\|, 0.30–161.63 s | −7.92 m/s | −10.26 | **−1.26** |
| by window: 0.3–1, 1–20, 20–60, 60–100, 100–135.2, 135.2–140, 140–161.63 s | +0.29, −1.43, −1.61, −0.42, −2.63, +0.24, −2.35 | +0.33, −1.14, −1.12, −2.00, −3.07, −0.01, −3.26 | +0.35, −0.54, +0.49, +0.34, −0.55, +0.32, −1.67 |
| S-IC \|ΔV_sens\| (vector) | −14.11 m/s | −5.76 | +2.59 |
| thrust pitch, 15–40, 40–85, 85–112, 112–122, 122–159 s | +0.32, +0.63, +0.32, −0.34, −0.24° | −0.02, −0.04, +0.59, +0.07, +0.40 | −0.03, −0.07, +0.54, +0.05, +0.40 |
| S-II OECO, 548.22 s: speed; γ; radius | −30.69 m/s; +0.194°; −472 m | −21.55; +0.121; +330 | −8.49; +0.079; +723 |
| first S-IVB cutoff, 699.33 s: speed | −37.44 m/s | −27.69 | −14.21 |

**Against FER Table 4-2** (`testSICAscentMatchesApollo11`, fixed 0.02 s steps):

| | FER | main | this section |
|---|---|---|---|
| CECO: altitude; speed; γ; heading | 44.0 km; 1,979.0 m/s; 22.957°; 76.315° | 44.00; 1,966.50; 23.124; 76.276 | 44.23; 1,977.36; 23.247; 76.261 |
| OECO: altitude; speed; γ; heading | 66.1 km; 2,764.1 m/s; 19.114°; 75.439° | 66.04; 2,749.24; 19.068; 75.370 | 66.61; 2,759.45; 19.407; 75.368 |
| Mach 1; max Q | 66.3 s; 35.2 kPa at 83.0 s | 66.78 s; 34.79 kPa at 83.32 s | 66.28 s; 35.27 kPa at 83.06 s |
| climb against the PFT at 20, 40, 60, 80, 100, 120 s | — | −7, −36, −72, −87, −63, −16 m | +2, +2, +6, +12, +41, +125 m |

**The whole flight** (`NominalFlight`'s steps):

| | AS-506 | main | this section |
|---|---|---|---|
| CECO; T3 | 135.20 s; 161.66 s (OECO 161.63) | 135.19; 161.65 | 135.19; 161.65 |
| T4 | 548.24 s (OECO 548.22) | 548.251 | 548.251 |
| S-II OECO (T4): r; v; γ | 6,559,961 m; 6,915.96 m/s; 0.614° (Table 10-2) | 6,559,087; 6,886.11; 0.813 | 6,560,281; 6,908.32; 0.698 |
| velocity cutoff | 699.34 s | 704.977 s | **701.517 s** |
| insertion (cutoff + 10 s): r; v; γ | 6,563,335 m (LVDC) | 6,563,330.1; 7,793.027; −0.0002° | 6,563,332.5; 7,793.018; −0.0002° |
| orbit: i; θ_N; over the 6,378,165 m sphere | 32.532°; 123.102°; 186.0 × 185.2 km (LVDC) | 32.5309; 123.0975; 185.175 × 185.120 km | 32.5309; 123.0975; 185.174 × 185.098 km |

The stage injections are unchanged in kind: from AS-506's T3 state the model's S-II reaches T4 8.97 m/s slow and 0.132° steep (it was −10.03 m/s and +0.149°; the hold after the arrest is now AS-506's −68.90° rather than ×1.025's −69.66°), and from AS-506's T4 state the S-IVB still cuts off at 700.90 s, 1.56 s late.

**What each change bought** (the S-IC flown to 162 s in fixed 0.02 s steps; model − PFT):

| state | ∫\|a_ng\| (m/s) | vector (m/s) | CECO speed; γ | OECO speed; γ; radius |
|---|---|---|---|---|
| main | −7.91 | −14.11 | −13.17; +0.169° | −15.28; −0.045°; −114 m |
| AS-506's pitch program | −8.83 | −4.28 | −7.97; +0.215° | −11.29; +0.228°; −47 m |
| and Figure 5-3's thrust as printed (the old flow, the last knot on the figure's trend) | −11.37 | −6.83 | −9.17; +0.207° | −13.90; +0.216°; −54 m |
| and the flow refitted, the last knot on OECO's acceleration (40791cb) | −10.25 | −5.76 | −8.40; +0.214° | −12.85; +0.223°; −19 m |
| and the level, ×1.0022 (this section) | −1.26 | +2.59 | −2.31; +0.292° | −5.07; +0.294°; +448 m |

1. **The pitch program** takes the S-IC's thrust direction onto AS-506's to 85 s (−0.02 to −0.07° against +0.32 to +0.63°) and closes 9.8 m/s of the vector deficit. It costs 0.9 m/s of ∫\|a_ng\| (more drag at 60–135 s on the flatter early path) and makes OECO 0.27° steeper (§14.1 finding 5). With the hold at −68.90° it brings the velocity cutoff 1.8 s earlier (703.20 s).
2. **Figure 5-3's thrust as printed** costs 2.5 m/s: it is 0.46 % above the old thrust at liftoff but 0.1–0.3 % below it at 70–110 s and 137–155 s. It also removes the specific impulse's constant (303.4–306.5 s over the burn now).
3. **The flow refit** burns the 761 kg the tanks held over Table 5-2's at CECO in the five-engine phase (0.04 % more flow) and 0.24 % less flow after CECO: +1.1 m/s, with the last knot's move to OECO's acceleration. The CECO mass is now 1,110,850.6 kg, 661 kg above Table 20-1's: exactly the frost and purge gas.
4. **The level** buys 9.0 m/s (4.1 m/s per 0.1 %). It leaves the windows within 0.6 m/s but for 140–161.63 s (−1.67 m/s, −0.20 %: the figure's four-engine thrust runs low against the PFT, 17.3 item 2) and moves the cutoff 2.0 s earlier.

**Against the targets.** The S-IC's ∫\|a_ng\| is within 1.3 m/s of the PFT's (target 1–2 m/s); 1.3 m/s of it is the frost, and the fit puts it at +0.06 m/s once the frost is shed. CECO is commanded at 135.19 s (AS-506 135.20 s) and the LOX runs out in the step that ends at 161.65 s (OECO 161.63 s, T3 161.66 s): both within a few hundredths of a second. The velocity cutoff is 2.18 s late, from 5.64 s; 1.56 s of it is the S-IVB's (from AS-506's T4 state) and the rest the S-II's and the S-IC's handover (17.5).

### 17.3 Known deviations (S-IC)

1. **OECO is 0.29° steep and 5.1 m/s slow, though the ∫\|a_ng\| is closed.** AS-506's command flown by the model leaves its thrust 0.54° nose-up of AS-506's at 85–112 s and 0.40° at 122–159 s (§14.1 finding 5): the reconstruction's 0.5° uncertainty at 85–112 s and AS-506's late trim, about 0.1° of engine deflection and −0.3° of error at OECO, which the model does not fly (§14.4, §14.5 item 3; left unmodelled by decision). The steeper path climbs 448 m more by OECO and turns more of the thrust against gravity. The vector \|ΔV_sens\| is 2.6 m/s above AS-506's, the scalar 1.3 m/s below it: the model steers more coherently (§14.2 finding 6).
2. **The thrust's level is a fit to the PFT, its shape the figure's.** Against the PFT, after the level, the windows are −0.54 m/s at 1–20 s (−0.23 %) and −1.67 m/s at 140–161.63 s (−0.20 %), and +0.3 to +0.5 m/s at 20–100 s. The figure's own level is 0.22 % below AS-506's measured acceleration; whether the figure, the FER's masses or the aerodynamics carry the difference is not established (§14.4 "not established" item 3).
3. **The frost and purge gas are not shed by CECO.** *Since 17.6 the upper stages' ride on the S-IC part and leave at its separation; the S-IC's ∫\|a_ng\| keeps its 1.3 m/s.* At CECO the vehicle is 661 kg above Table 20-1's (S-IC frost 295 kg and N2 purge gas 16 kg, S-II frost 204 kg and purge gas 54 kg, S-IVB frost 90 kg), and the S-IC's ∫\|a_ng\| is 1.3 m/s short until they are. The level was fitted as if they were shed linearly to CECO; shed at liftoff instead, they would be worth about 0.4 m/s more.
4. **The specific impulse runs from 304.1 to 306.5 s** over the burn, because thrust and flow come from two panels of the figure read independently (their ratio wanders by ±0.5 %) and the flow's two scales step it by 0.27 % at CECO.
5. **The program starts 1.9 s early** (§8.5), on the fit's +0.37°.
6. **Past the arrest** (S-IC engine out only) the fit's last quartic steepens where SA-504's flattened: at T1 + 179 s, the latest a moved arrest reaches, it is 3.9° further downrange than SA-504's × 1.025. The engine-out flights still insert within §16's tolerances.

### 17.4 Tests

| test | checks | depends on |
|---|---|---|
| `SaturnIUTests.testPitchPolynomialTranscription` | GE504's coefficients as before (`sa504PitchCoefficients`); the IU flies `pitchCoefficients`, arrested at T1 + 159.37 s on −68.90° | GE504 (H) |
| `AscentResidualTests.testFittedPitchProgramAgainstTheReconstruction` | the flown program against the reconstructed command: rms 0.057°, max < 0.15°, exact joins, the hold, rates < 0.75°/s, 0.75–1.8° downrange of SA-504's, 1.12 and 1.01 times it at 40 and 158 s | PFT (H), Fig. 11-1 (M) |
| `SaturnVDataTests.testF1ThrustFollowsFigure5_3` (new) | the schedule's site thrust at AS-506's altitude and pressure against the figure's samples: five engines 0.04 % rms, 0.18 % max; four engines 0.05 %, 0.13 %; impulse over each span 0.01 %; 34.34 MN at first motion (101.2 kPa); OECO on 38.61 m/s² over 827,292 kg | Fig. 5-3 (M), PFT, Table 4-1, Table 20-1 (H) |
| `SaturnVDataTests.testEngineRatings` | the F-1's rating at first motion; thrust over flow within 0.8 % of Betts' 304.1 s over the burn and within 0.3 % on the impulse | Betts (H/M) |
| `SaturnVDataTests.testSICDrawStopsOnLOXDepletion` | the tanks at CECO, 216,633 + 2,809 kg and 99,059 kg (1 kg); the vehicle then 661 ± 3 kg above 1,110,189 kg; depletion at 161.63 s with 13,954 kg of RP-1 as before | Tables 5-2, 20-1 (H; fitted) |
| `AscentResidualTests.testSICSensedVelocityAgainstThePFT` (new) | the S-IC's ∫\|a_ng\| against the PFT: −1.3 ± 1 m/s over the burn (the level's fit, frost aboard), each of §14.2's windows within 2 m/s (not fitted). Provisional tolerances | PFT (H) |
| `SaturnVFlightTests.testLiftsOffOnFirstStep` | 5 (F_vac − p A_e) at first motion with the new rating; 34.35 MN ± 1 % and 1.2 g as before | Fig. 5-3 (M), §9.2.1 |
| `SaturnIUTests.testTowerYawAndRollProgram` | the programs start on the first step that sees a 137 m rise (it checked the step's phase, 137.15 ± 0.15 m, which the faster liftoff moved) | GE504 §4.1.2 |

Pins that moved, each marked "see §17" in its test (the final pins are in 17.10); nothing else was loosened:

| test | pin | before | now | model, in the test |
|---|---|---|---|---|
| `SaturnIUTests.testSICAscentMatchesApollo11` | climb against the PFT every 20 s | ±100 m | ±150 m | +125 m at 120 s (−137 m at 100 s in 40791cb) |
| same | OECO flight-path angle against 19.114° | ±0.2° (fitted then) | ±0.35° | 19.407° |
| `SaturnIUTests.testFlightControlStepResponse` | c and ω_n follow the first-motion thrust (self-consistency) | 0.947 s⁻², 0.923 rad/s | 0.955 s⁻², 0.927 rad/s | — |

The harness (`testModelResidualsAgainstThePFT`) now also prints the model's event times, its orbit after the cutoff, and the S-IC's ∫\|a_ng\| by window; nothing in it is asserted.

### 17.5 For the rest of the closure

*Done in 17.6–17.11.*

- **Superseded by this section,** for the re-baseline to update in place: §8.4's "model compensation" (`pitchScale`) and its table; §8.5's second item; §9.2's F-1 row and §9.3's `sICFlowScale`, `sICMixtureRatioScale` and `pitchScale` rows; §9.4's CECO mass (now 1,110,851 kg); §11.5 item 1; §14.5 items 1 and 5 (the S-IC's F/m); §15.4 item 5.
- **The frost and purge gas** (17.3 item 3): booked on the S-IC part they close the S-IC's last 1.3 m/s and take the CECO mass to Table 20-1's within a kilogram, with no refit of the flow or the level (both were fitted with them taken off).
- **The S-IVB:** 1.56 s of the remaining 2.18 s cutoff delay, from AS-506's T4 state (§14.3, §14.5 item 5: its thrust from the measured acceleration). This section's S-IC level is the same kind of choice.
- **The S-II:** from AS-506's T3 state it reaches T4 8.97 m/s slow and 0.132° steep (∫\|a_ng\| −7.41 m/s), the EMR ramp's and the low-EMR thrust's (§14.2 finding 5, §9.2 "Rating ramps").
- **OECO's γ** (17.3 item 1) hands the S-II 0.29° of extra climb angle and 448 m of height, which the IGM absorbs; a sourced late trim would close it.

### 17.6 The model (masses, S-II, S-IVB)

**Sources** (besides 17's):
- **FER Table 20-1** (H; page images, document page 20-2): the S-II stage 479,964 kg at first motion and 479,706 kg at CECO (frost 204 kg, purge gas 54 kg); the S-IVB stage 119,119 and 119,029 kg (frost 90 kg).
- **FER Figure 6-3** (M): the S-II's stage thrust and EMR from 486 s to OECO, digitised in `tools/data/fer506_fig6_3_sii_thrust.csv` and `fer506_fig6_3_sii_emr.csv` (0.0036 MN and 0.47 s a pixel); **§6.3** (H): 3,082,769 N for four engines at ESC + 351 s and 3,059,402 N at ESC + 381 s (ESC 163.04 s); **Table 6-2** (H): the PU valve step at 497.60 s.
- **FER Table 10-4** (H): IGM phase 1 at 204.1 s, the EMR shift command at 494.8 s, on the computation cycle.
- **FER Tables 4-1, 7-1, 20-5, 20-9 and Figure 7-2** (H; M for the figure): the S-IVB's acceleration at cutoff, standardised engine, consumption and flow, and thrust reconstruction.
- **PFT Table B-II** (H), through the harness of PR 17 (`AscentResidualTests`, `InjectedFlight`); **AS-508 FER Table 2-2** (H) for the Apollo 13 analogue.

| item | model | basis | conf |
|---|---|---|---|
| frost and purge gas | the S-II's 204 + 54 kg and the S-IVB's 90 kg booked on the S-IC part (`sIIFrostAndPurge`, `sIVBFrost`), at the S-II's and S-IVB's dry CG stations (STA 1892.3, 2856.7) on the skin, so the stack's CG does not move; they leave with the S-IC at 162.3 s. The S-IC's own were already in its first-motion mass | Table 20-1: all shed by CECO; the model sheds none before the S-IC's separation | H (masses), model (when) |
| EMR shift | a linear ramp from high to low EMR (`sIIMixtureRatioRamp`), 2 × (498.8 − 497.60) = 2.4 s from the PU valve step, which follows the IGM's command by AS-506's 2.8 s; in the model the valve step is at 497.56 s, the ramp's middle at 498.76 s | the PFT's single-step fit, 498.7–498.9 s (§14.2), 1.2 s after the valve step; Figure 6-3's own step, impulse for impulse, is at 496.8 s | H (the step's time), L (shape) |
| low EMR | 3,091,000 N for the stage at the valve step, falling 694 N/s (0.022 % a second) to 3,055,900 N at OECO and held after (`sIILowMixtureRatioThrust`, `sIILowMixtureRatioDecline`, thrust and flow together); 772,750 N an engine at the step (768,000 N before), 4,190 N·s/kg, EMR 4.34 | Figure 6-3's traced samples, 499.5–538 s: a least-squares line, 2.7 kN rms; 0.10 % and 0.02 % below §6.3's two values. The figure's last 8 s, traced 0.016 MN under the line where its solid curve meets the dashed prediction, are left out | M (shape), H (level) |
| the decline's start | the IU's `.rating` action brings it (`schedule:`), its times from the action (`PerformanceSchedule.delayed(by:)`): an S-II engine out that delays the shift delays the decline with it | — | — |
| `sIIFlowScale` | 0.996784 (0.99749 before) | LOX depletion at 548.22 s in the IU flight, which moves −623 s per unit | fitted |
| `sIIHighMixtureRatio` | 5.49765 (5.5006) | LH2 at depletion, 3,353 kg (Table 20-3), which moves 11,567 kg per unit | fitted |
| `igmShiftVelocity` | 3,908 m/s (3,906, fitted on the model's cycle) | the middle of AS-506's window: its IGM commanded the shift at 494.8 s, 171.000 cycles of 1.7 s after its start, so its preset lay between the S-II's characteristic velocity a cycle before (493.1 s) and at the command, 3,894.1 and 3,921.4 m/s on the PFT (its ∫\|a_ng\| from engine start, 164.0 s) | H (window), L (the middle) |
| `igmTau2`; Vex2 | 345.5 s (347.5); 4,203.5 m/s (4,200.5), derived | the stack at the command, 254,002 kg, over four low-EMR J-2s at the valve step, 735.34 kg/s; Vex2 is the low EMR's Isp, which the decline keeps | model |
| S-IVB thrust | 912 kN (903 kN) at Table 20-9's 215.37 kg/s: 431.8 s (427.6 s) | the PFT's ∫\|a_ng\| over 560–690 s, flown from AS-506's T4 state on the model's mass, linear in the thrust (0.86 m/s per kN), met at 912,060 N; Table 4-1's 6.73 m/s² at cutoff agrees | M (fitted to the PFT, H) |
| S-IVB transients | shapes kept, so their impulses are 1.0 % above FER §7.2's and §7.4's, which the FER reconstructs at Figure 7-2's level | — | L |
| ΔV_B | 1.46 m/s (1.45) | the model's own gain to cutoff + 10 s, measured, so it inserts at V_T | model |

**The order.** The masses were booked first, ahead of the S-II's refits, because the IGM's shift and τ2 depend on the S-II's mass: the 348 kg the upper stages carried were worth 4.5 m/s of the S-II's sensed velocity (Ve (1/m_OECO − 1/m_start), 0.013 m/s a kilogram) and 0.5 m/s of the S-IVB's. The S-II's refits then came one at a time: the flow, the high EMR, the shift velocity, τ2. Booked after them, the frost would have moved the shift's and τ2's fits.

**Why the S-IVB's thrust follows the measured acceleration.** Flown from AS-506's T4 state on Figure 7-2's 903 kN, the S-IVB gained 0.91–1.07 % less sensed velocity than the PFT in every mainstage window, on a mass that is now the FER's within 34 kg, and cut off 1.46 s late. The FER disagrees with itself here (§9.5 item 5): Table 4-1's 6.73 m/s² at cutoff and the PFT are on the measured side; Figure 7-2, Table 7-1's standardised 901,223 N and Figure 4-3 (5.98 m/s² at 627.4 s, 1.2 % below the model) are the thrust reconstruction's, 1.0 % lower. 912 kN at Table 20-9's flow is an Isp of 431.8 s, high for a J-2: Table 7-1's standardised engine has 4,204 N·s/kg (428.7 s) on its own flow, and the J-2's rating at EMR 5.5 is 425 s. The alternative is Figure 7-2's 903 kN: from AS-506's T4 state its cutoff is 1.46 s late, inside ±1.5 s but outside the ±1 s closure. It is the same kind of choice as the S-IC's level (17.1).

### 17.7 Results (masses, S-II, S-IVB)

**Before and after** (`NominalFlight`'s steps; the injected flights start from AS-506's PFT state at the model's T3 or T4; model − PFT where marked):

| quantity | AS-506 | main (3aea6a7, after 17.1–17.5) | this section |
|---|---|---|---|
| CECO; OECO (T3) | 135.20 s; 161.66 s | 135.19; 161.65 | 135.19; 161.65 |
| EMR shift command; PU valve step | 494.8; 497.60 s (effective step 498.7–498.9) | 494.75; 497.55, a step | 494.75; 497.55, ramp to 499.95 (middle 498.75) |
| S-II OECO (T4) | 548.24 s | 548.25 | 548.23 |
| S-II OECO state: r; v; γ | 6,559,961 m; 6,915.96 m/s; 0.614° (Table 10-2) | 6,560,281; 6,908.32; 0.698 | 6,560,361; 6,916.33; 0.683 |
| velocity cutoff | 699.34 s | 701.517 | **698.832** |
| insertion (cutoff + 10 s): r; v; γ | 6,563,335 m; 7,793.28 m/s (LVDC, vents included) | 6,563,332.5; 7,793.017; −0.0002° | 6,563,329.9; 7,793.017; −0.0002° |
| orbit: i; θ_N; apogee × perigee over 6,378,165 m | 32.532°; 123.102°; 186.0 × 185.2 km (LVDC) | 32.5309; 123.0975; 185.17 × 185.10 km | 32.5309; 123.0975; 185.17 × 185.09 km |
| ∫\|a_ng\|, S-IC; S-II; S-IVB (the harness's stage windows) | 3,587.79; 4,659.38; 885.66 m/s | −1.26; −6.32; −8.21 | **−1.26; +1.58; −1.24** |
| \|ΔV_sens\| vector, S-IC; S-II; S-IVB | 3,303.57; 4,583.74; 880.79 m/s | +2.59; +2.97; −5.79 | +2.59; +9.57; +1.20 |
| from AS-506's T3 state: the S-II's ∫\|a_ng\| (161.67–548.22 s); at T4 speed; γ | — | −7.85; −8.97 m/s; +0.132° | **+0.05**; −0.72; +0.117° |
| from AS-506's T3 state: velocity cutoff | 699.34 s | 701.737 | **699.055** |
| from AS-506's T4 state: the S-IVB's ∫\|a_ng\| over 151.11 s; velocity cutoff | — | −8.63; 700.898 | **+0.61; 699.469** |
| Apollo 13 analogue: shift; S-II OECO; cutoff | +32.2; +34.53; +44.06 s (AS-508) | +32.30; +33.28; +44.88 | +32.30; +33.28; +44.73 |

In the IU tests' fixed 0.02 s steps the cutoff is at 698.92 s and the orbit 185.170 × 185.071 km (§10.4).

**What each change bought** (one commit each, in this order; m/s and s):

| change | S-II ∫\|a_ng\| from AS-506's T3 state | at T4 from T3: speed; γ | cutoff from T3; from T4 | default flight: S-II ∫\|a_ng\|; cutoff |
|---|---|---|---|---|
| main | −7.85 | −8.97; +0.132° | 701.737; 700.898 | −6.32; 701.517 |
| the frost and purge gas on the S-IC | −3.30 | −3.82; +0.129° | 700.866; 700.818 | −1.76; 700.646 |
| the EMR ramp and Figure 6-3's decline | −1.19 | −4.52; +0.116° (T4 at 547.77 s) | 700.484; 700.292 | +0.34; 700.264 |
| `sIIFlowScale` 0.996709 | −0.25 | −1.05; +0.127° | 700.424; 700.799 | +1.29; 700.203 |
| `sIIHighMixtureRatio` 5.49765 (flow 0.996784) | +0.05 | −0.73; +0.126° | 700.375; 700.799 | +1.58; 700.154 |
| `igmShiftVelocity` 3,908 | +0.05 | as above | 700.375; 700.799 | +1.58; 700.153 |
| `igmTau2` 345.5 | +0.05 | −0.69; +0.126° | 700.374; 700.798 | +1.58; 700.152 |
| S-IVB 912 kN (ΔV_B 1.46) | +0.05 | −0.72; +0.117° | 699.055; 699.469 | +1.58; 698.832 |

1. **The frost** gave the S-II 4.5 m/s and the S-IVB 0.5 m/s; the S-IC is unchanged, as it still carries it.
2. **The ramp** moved 5.0 m/s back into 496–500 s (−5.51 → −0.49 m/s). It burns about 300 kg more at high flow before 500 s, so LOX depleted 0.49 s early until the flow was refitted. **The decline** alone is worth +0.3 m/s (the line is 0.6 % above 768 kN at the step and 0.5 % below it at OECO): it moves 0.6 m/s from the end of the phase to its start.
3. **The flow and EMR** refits close the S-II's propellant budget again: −0.000782 on the flow puts the depletion at 548.220 s with 33 kg too much LH2; −0.00295 on the EMR burns it, and slows the LOX by 0.047 s, which +0.000075 on the flow takes back (their joint solution).
4. **The shift velocity** moves nothing in the nominal flight (the same cycle); the window's top, 3,921 m/s, would have slipped the Apollo 13 analogue's shift a cycle, +34.0 s.
5. **τ2** changes the IGM's stage 2 prediction for its first 9 s: 18 m lower at S-II OECO, the cutoff 1 ms earlier.
6. **The S-IVB's thrust** takes its windows from −0.91 to −1.07 % to within ±0.08 %, and its cutoff 1.33 s earlier.

The S-II from AS-506's T3 state by window (model − PFT, ∫\|a_ng\|, m/s; main in brackets): 161.63–162.3 s +0.09; 162.3–164 +0.27; 164–166 −0.60; 166–172 +1.83; 172–200 +1.06; 200–300 +1.00 (+0.53); 300–400 −0.63 (−1.17); 400–460 −0.57 (−0.91); 460–470 +0.46; 470–490 +0.90; 490–496 +0.46; 496–500 −0.48 (−5.59); 500–510 −1.62 (−2.38); 510–520 −0.49; 520–530 −0.59; 530–540 −0.61; 540–548.22 −0.43 (−0.13). The S-IVB from AS-506's T4 state: 548.22–556 s −0.23 (−0.46); 556–560 +0.66 (+0.43); 560–600 +0.17 (−2.20); 600–640 −0.01 (−2.52); 640–680 −0.20 (−2.87); 680–690 −0.02 (−0.71).

The event masses after the S-IC's separation are the FER's within 34 kg (§9.4); the S-IVB stack at its first start command, STDV open and mainstage +1, +23 and −7 kg (§12.3).

### 17.8 Against the targets

"Closed" means within these tolerances, not zero residuals:

| measure | tolerance | model |
|---|---|---|
| each stage's ∫\|a_ng\| against the PFT | 1–2 m/s | S-IC −1.26, S-II +1.58, S-IVB −1.24 m/s in the default flight; the S-II −0.04 m/s from AS-506's T3 state (separation to OECO), the S-IVB +0.61 m/s from its T4 state |
| velocity cutoff from AS-506's T3 state; from its T4 state | ±1 s | −0.28 s; +0.13 s |
| velocity cutoff in the default flight, against 699.34 s | ±1 s | −0.51 s (698.83 s; 698.92 s in fixed 0.02 s steps, −0.42 s) |
| insertion on the LVDC's parking orbit | §10.6's: apogee 186.0 ± 1 km, perigee 185.2 ± 0.5 km, i 32.532 ± 0.003°, θ_N 123.102 ± 0.006°, e < 0.0002, period 88.20 ± 0.02 min | 185.170 × 185.071 km, 32.5309°, 123.0975°, 0.000008, 88.19 min |
| Apollo 13 analogue (`EngineOutTests`) | AS-508: shift +32.2 ± 1.7 s, S-II OECO +34.53 ± 2 s, cutoff +44.06 ± 2 s | +32.30, +33.28, +44.73 s |

The late trim stays unmodelled (17.3 item 1).

### 17.9 Known deviations (masses, S-II, S-IVB)

1. **The frost and purge gas leave with the S-IC, not by CECO.** The S-IC's ∫\|a_ng\| is 1.3 m/s short with them aboard (17.3 item 3); the vehicle is 662–785 kg over the FER's from CECO to the S-IC's separation, and the FER's within 34 kg after it.
2. **The S-II's low-EMR phase is 3.7 m/s short of the PFT** from AS-506's T3 state, 1.6 m/s of it in the first 10 s after the step (500–510 s). On the model's mass the PFT's acceleration implies 3.12–3.13 MN at 502–504 s, 1.0–1.3 % above Figure 6-3's line, and 0.3–0.4 % above it from 514 s, where §6.3's text agrees with the line within 0.1 %. Whether the PFT's reconstruction spreads the step into those seconds or the thrust stayed higher after it is not established. A longer ramp, its middle later than the PFT's single-step fit, would take part of it.
3. **The S-II's first 40 s are 2.3 m/s above the PFT** (+1.8 m/s at 166–172 s, 3–6.5 %; §14.4 not established 6), and its four-engine high EMR 0.9 m/s above at 460–496 s: Table 6-1's 1,028,303 N an engine is 0.85 % above Figure 6-3's 4.078 MN at 486–494 s, and 0.3–0.4 % above the PFT's acceleration on the model's mass. Not refitted: from AS-506's T3 state the S-II's whole burn is −0.04 m/s, its windows within ±1.9 m/s.
4. **The S-IVB's Isp, 431.8 s, is high for a J-2** (17.6). The FER's thrust reconstruction is 1.0 % lower; with it, from AS-506's T4 state, the cutoff is 1.46 s late. The S-IVB's first seconds of mainstage (556–560 s) run 3.1 % above the PFT (the start transient's shape, L), and its windows trend from +0.08 % to −0.08 % over 560–690 s.
5. **S-II OECO is 0.07° steep and 395 m high** in the IU flight; from AS-506's T3 state the S-II arrives 0.117° steep, its thrust running about 0.2° nearer the vertical than AS-506's (§14.3 finding 3). The IGM takes it out by insertion.
6. **The low EMR's decline runs from the shift.** In an engine-out flight that moves the shift (the Apollo 13 analogue: 32.3 s later) the decline moves with it. Whether AS-506's decline followed the shift or the propellant's depletion is not known.
7. **The IGM's T3 iteration diverges when the S-IVB cannot reach orbit.** With the S-II dropped by hand before IGM start (`testEarlierTimeBaseEventsDropWhenTheNextStarts`), on 912 kN its T3 becomes NaN in the S-IVB's first cycles and the steering is not meaningful (on 903 kN it happened to converge, to 480 s); the vehicle's state stays finite. The nominal and engine-out flights are not affected; the test leaves the terminal-guidance entry out. A guard in the T3 iteration is a separate item. *Resolved (§10.2, "T3 bound"): T3 is held 1 s inside (0, τ3); the S-IVB lit at 204 s is steered in the plane, lofted, and burns to depletion at 680 s (5.5 km/s, 183 km up); the test asserts the IGM's whole log again. The nominal and engine-out flights are unchanged to the bit.*
8. **ΔV_B and τ2 are the model's own;** τ3 (773.5 s; the model's mass gives 772.7 s) was not reset, as the IGM measures it.
9. **The point-mass IGM test** (§10.4) keeps §10's engines.

### 17.10 Tests

| test | checks | depends on |
|---|---|---|
| `PropulsionModelTests.testRatingChangeStartsItsScheduleThere` (A11, new) | a rating change's schedule runs from the event on the burn clock, at the rating's Isp and EMR; a later change without one keeps it | mechanism only |
| `SaturnVDataTests.testSIILowEMRFollowsFigure6_3` (new) | the low EMR's line against Figure 6-3 (0.1 % rms, 0.25 % max) and §6.3 (0.15 %, 0.05 %); constant Isp along it; the ramp's middle at 498.8 s; the figure's step at 496.8 ± 0.15 s; its EMR within 0.05 of 4.34 | FER Figure 6-3 (M), §6.3 (H), PFT |
| `AscentResidualTests.testShiftVelocityIsInAS506sWindow` (new) | 171 cycles from IGM start to the shift; the window 3,894.1–3,921.4 m/s on the PFT; the preset its middle | PFT, FER Table 10-4 (H) |
| `AscentResidualTests.testSIISensedVelocityAgainstThePFT` (new) | 17.8's S-II rows, and by window from AS-506's T3 state: the shift (490–500 s) within 1 m/s, the low-EMR phase −3.7 ± 1 m/s, the first 40 s +2.3 ± 1 m/s; at T4 speed within 1.5 m/s and γ within 0.15° | PFT (H) |
| `AscentResidualTests.testSIVBSensedVelocityAgainstThePFT` (new) | 17.8's S-IVB rows; each mainstage window from AS-506's T4 state within 0.25 % | PFT (H) |
| `AscentResidualTests.testVelocityCutoffWithinASecondOfAS506` (new) | 17.8's three cutoffs | FER Table 2-2 (H) |
| `AscentResidualTests.testSICSensedVelocityAgainstThePFT` | −1.3 ± 0.5 m/s (the frost), the windows within 2 m/s; final | PFT (H) |
| `AscentResidualTests.testStageInjectionAtT3AndT4` | the two shared injected flights (`InjectedFlight.fromT3`, `.fromT4`) put AS-506's state in place; prints the residuals | PFT (H) |
| `SaturnVDataTests.testFirstMotionMassesMatchTheFER`, `SaturnVFlightTests.testSpaceKeyStagingSequence` | the frost booked on the S-IC part | Table 20-1 (H) |
| `SaturnVDataTests.testEngineRatings` | the refitted ratings; the S-II high EMR's flow 0.32 % below Table 6-1's and its Isp 1.1 s above the J-2's 425 s; the S-IVB's thrust 1.2 % above Table 7-1's and 1.0 % above Figure 7-2's, its Isp 431.8 s, 0.7 % above Table 7-1's | FER, NTRS 20100032986 |
| `EngineOutTests.testApollo13AnalogueMatchesAS508` | unchanged; 17.8's deltas | AS-508 FER (H) |

Pins changed, each "see §17" marker replaced (none remains):

| test | pin | before | now | model |
|---|---|---|---|---|
| `SaturnIUTests.testFlightSequenceFollowsTheApollo11Timeline` | velocity cutoff against 699.34 s | ±6 s | ±1 s | 698.92 s |
| `SaturnIUTests.testIGMFliesApollo11ToItsParkingOrbit` | S-II OECO speed against 6,915.96 m/s | ±35 m/s (§15) | ±5 m/s | 6,916.22 m/s |
| same | S-II OECO flight-path angle against 0.614° | ±0.25° (§15) | ±0.15° | 0.684° |
| `SaturnIUTests.testSICAscentMatchesApollo11` | climb against the PFT every 20 s | ±150 m (17.4) | ±150 m, final | +2 to +125 m |
| same | Earth-fixed speed against the PFT | ±2 % | ±0.5 % | within 0.26 % |
| same | OECO flight-path angle against 19.114° | ±0.35° (17.4) | ±0.35°, final | 19.407° |
| `SaturnVSeparationTests.testSpentStagesClimbAsPredicted` | spent S-II apex time against 587.0 s | ±10 s (§15) | ±5 s | 589.2 s |
| `AscentResidualTests.testSICSensedVelocityAgainstThePFT` | the S-IC's ∫\|a_ng\| | −1.3 ± 1 m/s, provisional | −1.3 ± 0.5 m/s | −1.26 m/s |
| `SaturnVDataTests.testEventTimelineThroughThePropellantModel` | event masses | ±0.1–0.2 % | ±0.1 % with the S-IC aboard, ±50 kg after | +662 to +785 kg; −15 to +34 kg |
| same | S-IVB cutoff acceleration | Figure 4-3's 6.69 ± 0.5 % | Table 4-1's 6.73 ± 0.3 % | 6.75 m/s² |
| `MassCharacteristicsTests.testMassCharacteristicsMatchTheFER` | event masses | ±0.2 % | ±0.1 % with the S-IC aboard, ±50 kg after | +662, +783 kg; −27 to +34 kg |
| `SaturnVDataTests.testEngineRatings` | the S-II high EMR's Isp against 425 s; its flow against Table 6-1's 246.9 kg/s | ±1 s; ±0.3 % | ±1.5 s; ±0.4 % | 426.1 s; −0.32 % |
| `SaturnVDataTests.testTransientImpulsesMatchTheFER` | the S-IVB's start and cutoff impulses | the FER's ±1 % | the FER's × 912/903, ±1 % | — |

**Values tests must not depend on**: the ramp's shape (its middle is the datum); the decline beyond Figure 6-3's reading (about 0.6 %); the S-IVB's Isp as an engine property; ΔV_B beyond insertion at V_T; the shift velocity beyond its window.

### 17.11 Passages updated in place

§8.4 (AS-506's command and its table), §8.5 item 2, §8.8; §9.1, §9.2 (the engines, rating ramps), §9.3, §9.4 (regenerated), §9.5 items 1 and 3–6, §9.6; §10.3, §10.4 (regenerated), §10.5 items 1, 3 and 5, §10.6, §10.7 item 4; §11.4 (a pointer), §11.5 items 1–2; §12.3 (regenerated); §14.4 (after the closure), §14.5; §15.4 item 5; §16.2 (the Apollo 13 deltas). The README, the ROADMAP and CLAUDE.md are left to the M1 close-out.

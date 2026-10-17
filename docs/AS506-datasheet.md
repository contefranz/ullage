# Saturn V AS-506 (Apollo 11): reconciled datasheet for the OrbitSim M1 stack

Compiled on 2026-10-15 for M1 item 1 (the Saturn V stack) from web research in four categories: launch-vehicle masses and timeline, propulsion, geometry and aero, and spacecraft. Each category was independently re-verified, then reconciled here. `Sources/OrbitCore/Vessel/AS506Data.swift` holds the values the simulator uses, with the same sources and confidence grades.

**Limits.** The NASA documents could not be fetched directly; values come from search extracts of them, from arithmetic on those values, or (marked **recalled**) from memory without a check against the source. The SP-4029 S-II and S-IVB propellant-usage rows and the FER mass tables are still unread; they are the most valuable follow-up. *Update (§8, 2026-10-16): the FER was then read directly; §8.7 lists its values that bear on §1–§7. Update (§9, 2026-10-17): the model's propulsion and masses are now calibrated to the FER. §9 supersedes, for the model, the derived masses of §1.1, the S-II and S-IVB engine rows of §1.2 and §1.3 and §1.7's decision 7, all of §2, the flight rows of §3 and targets A and B of §5, which stay here as the pre-FER record. Update (§10, 2026-10-17): the IU now flies the S-II and S-IVB on iterative guidance (IGM), which commands the EMR shift and the S-IVB cutoff in place of §8's timed stand-ins. Update (§11, 2026-10-17): the launch stack now has sourced aerodynamics (axial and normal force, centre of pressure) and flies through the launch day's measured air and winds; §11 supersedes §1.6's placeholder drag.*

## Conventions

- **t**: range time in seconds from range zero, 1969-07-16 13:32:00 UTC. For Apollo 11, GET is the same clock.
- **h**: height in metres above the vehicle base, measured along the axis. The base is taken to be the F-1 nozzle-exit plane. Vehicle station STA (inches) converts as h = (STA + 115) × 0.0254; the +115 offset is derived in §4. Apollo spacecraft station Xa converts as STA = Xa + 2756.
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

Read from `Sources/OrbitCore` as of M0, before the stack was built. Since then the core has gained bipropellant feeds, engine ratings that can be switched (for the EMR shift), placed tanks with a centre of mass that moves as they drain, and staging events, so the first, third, fifth and seventh points below no longer hold:

- **One tank per thruster.** `Thruster.tank` is a single tank, so LOX and fuel can only be modelled as separate tanks after a bipropellant-thruster feature exists. Until then, use one combined tank per stage; the LOX and fuel split is given for that later feature.
- **Constant mass flow.** mdot = F_vac/(Isp_vac × g0) at every pressure, and F(p) = F_vac × (1 − (1 − Isp_SL/Isp_vac) × p/p0). A stage's burn time is therefore exactly usable mass ÷ Σ mdot.
- **No EMR modes.** A thruster has fixed F_vac and Isp, so the S-II mixture-ratio shift needs either a performance mode or swapping the thrusters at t_shift.
- **No holddown.** `stepLanded` lifts the vehicle off as soon as thrust exceeds weight; holddown arms are not modelled.
- **Fixed part CoM.** A part's centre of mass (`offset`) does not move as its tanks drain, and tanks have no position. Tank stations in §4 are informational only.
- **Drag area.** `dragArea` is the maximum over parts of πr²·Cd. The drag coefficient is constant, with no Mach dependence. *(Since §11 only separated stages fly this; the stack has its own aerodynamics.)*
- **Staging.** `jettisonBottomPart` drops the part with the lowest x. Only the lowest part that has `.main` thrusters responds to the throttle. The LES is at the top, so it needs `separate(parts:)`.
- **Spherical Earth.** R = 6,378,137 m, with the US-1976 atmosphere indexed by r − R. The real pad is at a geocentric radius of 6,373.355 km, so a pad placed on the sim sphere is 4.78 km "too high" in radius. Validate radii, not published altitudes (§5). *(The Apollo 11 scenario now flies §11's launch-day sounding instead of US-1976.)*

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
| s_ivb_burn1_thrust | 901,223 N | 202,603 lbf | TDiA; FER Table 7-1 (STDV + 137 s, standardised) | H | EMR ≈ 5.0 (PU null); the model uses Figure 7-2's 903 kN at EMR 4.85 (§9.2). FER: +0.20% thrust and +0.05% Isp versus prediction. |
| j2_isp_vac_emr5.0 | 427 s | | Braeunig (via researcher) | L-M | Gives burn-1 consumption 31,665 kg, consistent with the Δv budget (§5). Pre-FER: FER Table 7-1 gives 4,204 N·s/kg (428.7 s); the model's flow is Table 20-9's (§9.2). |
| s_ivb_tli_thrust | 894,364 N | 201,061 lbf | TDiA | M | M2 only. |
| j2_throat / area ratio | 0.37338 m / 27.5 | 14.7 in | SP-8120; Wikipedia, Purdue | H / H | The geometric exit area of 3.011 m² (Ø 1.958 m) is derived. The Wikipedia sea-level figures (486 kN, 200 s) are refuted. |
| j2_gimbal_limit (S-II outboard, S-IVB) | ±7° (0.1222 rad) per actuator axis | | EH 8.20; EH 8.30, Haynes | M | S-IVB: "7.0° square pattern" (§7.1). |
| sps | 91,188.5 N, 314.5 s, MR 1.6, ε 62.5 | 20,500 lbf | Apollo press kits; Aerojet NTRS 20100027319; TN D-7375 | M | The 314.5 s comes from 100 psia tests, where thrust was 21,500–21,900 lbf, so the pair may not describe one operating point (±2%). |
| sm_rcs | 16 × 444.8 N | 100 lbf | Apollo-era sources | H | Isp not found (§3). |
| aps (S-IVB) | 2 modules × (3 × 653.9 N attitude + 1 × 320.3 N ullage) | 147 / 72 lbf as operated (150 / 70 nominal) | APS-TN, NASM, collectSPACE | M (attitude), H (ullage) | Isp not found (§3, §7.3). Loads: the AS-507 proxy 405 lb N2O4 + 252 lb MMH for both modules (FER-507), O/F 1.607; Wikipedia's 150 + 115 lb per module is rejected (§7.3). |
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
| iu_height | 0.9144 m | 36 in | Wikipedia; STA 3222 → 3258 | M | |
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
| pad (LC-39A) | geocentric latitude 28.4470° N, longitude 80.6041° W; r = 6,373.355 km | AP; Fischer-1960 radius derived | H / M | Place the sim pad at **geocentric** 28.447° so that Earth-rotation speed and inclination geometry match. |
| liftoff inertial velocity | 408.64 m/s (1,340.7 ft/s), heading 90° | AP | H | This is Earth rotation. The sim sphere gives 408.94 m/s. |
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
| **S-IVB** | **16,255.6** (35,837): dry 24,852 + other 1,656 (APS propellant, He, ullage-motor propellant) + LOX 4,229 + LH2 5,100 not consumed by burn 1 or TLI (boost and orbital venting, residuals). The model moves the APS propellant, 298.0 (657), out of "other" into four APS tanks, leaving dry_sim 15,957.4 (35,180) (§7.3) | LOX **85,397.0** (188,268) = burn 1 26,387.7 + TLI 59,009.3 | LH2 **17,466.7** (38,508) = burn 1 5,277.5 + TLI 12,189.2 | 119,119.3 (262,613) |
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

*The "flight" rows and the solid-motor choices below are the pre-FER record; the model's engines are in §9.2 (2026-10-17). The rated rows still serve as references.*

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
| S-IVB APS attitude × 6 | coast attitude, burn roll | 653.9 | — | 245 (effective; AS-201 flight averages) | — | 0.2722 | 1.607 (load ratio) | | 147 lbf as operated (APS-TN) | thrust M, Isp L |
| S-IVB APS ullage × 2 | restart ullage (M2) | 320.3 | — | ≈ 290 (placeholder) | — | 0.1126 | 1.607 (load ratio) | | 72 lbf as operated (APS-TN) | thrust H, Isp L |

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

**Datum derivation.** The S-IC is 138 ft = 1,656 in long and ends at the separation plane, STA 1541 (recalled from MSFC-MAN-503), so the base is at STA −115. The F-1 gimbal at STA 100 (CSS, M; §7.1), which CSS also places 100 in above station 0, then sits 215 in (17.9 ft) above the nozzle exit, consistent with a 19 ft engine. The LES tip at 363 ft is Xa ≈ 1485. Vehicle station = Xa + 2756 follows from SLA base Xa 502 = IU top STA 3258 (recalled).

**Interfaces**

| feature | station | h (m) | conf |
|---|---|---|---|
| F-1 nozzle-exit plane = vehicle base | STA −115 | 0.000 | L-M |
| F-1 gimbal plane; S-IC body (thrust-structure) aft end | STA 100 | 5.461 | M (CSS, §7.1) |
| S-IC/S-II separation plane (S-IC top) | 1541 | 42.062 | M-L |
| second plane (S-II aft skirt base, interstage top) | 1760 | 47.625 | L |
| S-II forward skirt top = aft interstage base | 2519 | 66.904 | L-M |
| S-II/S-IVB separation plane (aft interstage top) | 2746.5 (recalled) | 72.682 | L (alternative ≈ 70.15) |
| S-IVB/IU | 3222 (alternative 3223) | 84.760 | L-M |
| IU/SLA | 3258 (Xa 502) | 85.674 | M-L |
| SLA top = SM aft bulkhead | Xa 838 | 94.209 | L |
| SM/CM (CM heat-shield base) | Xa 1010 | 98.577 | L |
| CM apex | Xa 1137 | 101.803 | L |
| LES tip | — | 110.642 | M |

**Parts as bounding cylinders** (radius used for inertia and drag)

| part | bottom | top | length | diameter (bottom → top) | r_sim | notes |
|---|---|---|---|---|---|---|
| S-IC | 0.000 | 42.062 | 42.062 | 10.058 | 5.029 | Fins and fairings excluded. Below 5.46 m there are only engines, fairings and fins. |
| S-IC/S-II interstage | 42.062 | 47.625 | 5.563 | 10.058 | 5.029 | The S-II J-2 bells hang into it, down to about 45.0. |
| S-II + aft interstage | 47.625 | 72.682 | 25.057 | 10.058 → 6.604 (frustum from 66.904 to 72.682) | 5.029 | |
| S-IVB | 72.682 | 84.760 | 12.078 | 6.604 | 3.302 | J-2 exit at about 68.3, inside the aft interstage. |
| IU | 84.760 | 85.674 | 0.914 | 6.604 | 3.302 | |
| SLA | 85.674 | 94.209 | 8.535 | 6.604 → 3.912 | 3.302 | |
| LM (inside SLA) | ≈ 85.9 | ≈ 90.9 | ≈ 5.0 | stowed envelope ≈ 4.2 | ≈ 2.1 | Estimate (L). Its top must clear the SPS exit at about 91.08. |
| SM | 94.209 | 98.577 | 4.368 | 3.912 | 1.956 | Includes the CM/SM fairing. |
| CM | 98.577 | 101.803 | 3.226 | 3.912 → ≈ 0.8 | 1.956 | |
| LES (with BPC) | 100.584 | 110.642 | 10.058 | BPC ≈ 3.9 at base; tower and motor ≈ 0.66 | ≈ 0.5 | The BPC overlaps the CM by 1.22 m. |

Set each part's `offset.x` to its CoM in the vessel frame. Midpoints are acceptable for M1. Estimated loaded CoM of the S-IC part is about 25 m, dry about 14 m (L). Because the sim keeps part CoM fixed, the vehicle CoM will not travel as it really does. Do not write CG tests yet.

**Engines** (positions are heights; radial offsets from the axis)

| engine | gimbal h | exit h | radial offset | exit diameter | conf |
|---|---|---|---|---|---|
| F-1 centre (fixed) | 5.461 | 0.000 | 0 | 3.556 effective (3.76 envelope) | L / M |
| F-1 outboard × 4 (±5°) | 5.461 | 0.000 | 4.623 (182 in) | 3.556 | L (radius from fan wiki). Engines 1–4 sit under fins A–D, on the diagonals 45° from the pitch plane (M, §7.1); the S-II numbering is the same. The 20.6 s outboard cant (≈ 2°, M) costs only 0.06% of thrust, but it shortens the outboard moment arms by 21–34% (§7.1). |
| J-2 S-II centre (fixed) and outboard × 4 (±7°) | ≈ 48.4 ± 1.0 | ≈ 45.0 ± 1.0 | 0 / 2.667 | 1.958 (derived; 2.07 envelope) | L / M radius |
| J-2 S-IVB | ≈ 71.7 ± 1.0 | ≈ 68.3 ± 1.0 | 0 | 1.958 | L |
| SPS | ≈ 94.08 (Xa 833) | ≈ 91.08 (Xa 715) | 0 | ≈ 2.5 (recalled) | L |
| SM RCS quads × 4 | ≈ 97.3 (Xa ≈ 959) | — | ≈ 2.1 | — | L |
| S-IVB APS modules × 2 (180° apart) | ≈ 73.4 (aft skirt) | — | ≈ 3.5 | — | L |

**Tanks.** Estimated from loads, a 10.06 m or 6.60 m diameter and assumed dome shapes; ±1.5 m; not from a station diagram; not used by the current model.

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

- Compare **geocentric radius**, not altitude. AP altitudes are above the Fischer-1960 ellipsoid (a = 6,378.166 km, f = 1/298.3). The parking-orbit apogee and perigee are above a sphere of radius 6,378.166 km. Sim altitude is r − 6,378,137 m.
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
| pad (0) | inertial velocity | 408.64 m/s | ±0.5 m/s | The sim sphere gives 408.94 m/s. |
| Mach 1 (66.3) | time | 66.3 s | ±3 s | US-1976 versus July sound speed (Mach 1.04 in US-1976 at the published state). |
| max Q (83.0) | time; value | 83.0 s; 35,200 Pa | ±5 s; 28–36 kPa | US-1976 under-predicts by about 12%; sim Cd is a placeholder. |
| S-IC CECO (135.2) | V_inertial; altitude | 1,979.0 m/s; 44.0 km (geodetic) | ±50 m/s; ±2.5 km | Pitch-program dependent. |
| S-IC OECO (161.63) | V_inertial; r; γ_inertial | 2,764.1 m/s; 6,439.33 km; 19.11° | ±40 m/s; ±2.5 km; ±1.5° | Drag (placeholder Cd), pitch program, the model's low-altitude climb (§9.5). |
| S-IC/S-II separation (162.30) | V_inertial | 2,773.9 m/s | sim 2,761.1 m/s; ±40 | The F-1 decay and the S-II ullage motors add 10.7 m/s from OECO (FER 9.8; §9.4). |
| S-II CECO (460.62) | V_inertial; r; γ | 5,707.5 m/s; 6,552.65 km; 0.897° | ±50 m/s; ±3 km; ±0.5° | Guidance. |
| S-II OECO (548.22) | V_inertial; r; γ | 6,916.2 m/s; 6,559.55 km; 0.619° | ±50 m/s; ±3 km; ±0.5° | Guidance; the published value is 22.8 m/s below the AS-506 nominal. |
| insertion (709.33) | V_inertial; r; γ | 7,793.1 m/s; 6,563.05 km; 0.012° | ±3 m/s; ±1.5 km; ±0.05° | Guidance closes the loop. The table's altitude noise is about 0.05 n mi. |
| parking orbit | a; e; r_apo / r_peri; i; period | 6,562.87 km; 0.00021; 6,564.26 / 6,561.49 km (the published 100.4 / 98.9 n mi; sim altitudes 186.12 / 183.35 km); 32.521°; 88.186 min (5,291.2 s) | ±2 km; e ≤ 0.001; ±2 km; ±0.05°; ±6 s | Pad at geocentric 28.447°; the J2/μ model shifts the period by about 0.5 s. |

---

## 6. Remaining conflicts, gaps, and values tests must not depend on

**Unresolved conflicts**

- **S-II/S-IVB separation-plane station.** STA 2746.5 (recalled; aft interstage 5.78 m) versus about 2646 (Skylab OWS ≈ 48 ft lead). Which stage length contains the aft interstage is not documented in the inputs.
- **S-II EMR shift and low EMR.** (491 s, 4.7) versus (502 s, ≈ 4.55); AS-501's 4.7, EH's 4.3 and the 4.5 hardware limit. *Resolved by the FER (§8.7): commanded at 494.8 s, shifted at 498.0 s, average low EMR 4.34; applied in §9.2.*
- **F-1 liftoff thrust.** 7,648,000 versus 7,552,000 lbf (bases unknown). The 9,180,000 / 9,088,419 lbf "max" figures are physically implausible for this engine model.
- **First-engine ignition.** −6.4 versus −6.1 s. All-engines-running at −1.6 versus −1.92 s.
- **Spacecraft breakdown.** CM predicted versus as-flown, SM 51,243 versus 51,160, LM 33,218 (by closure) versus 33,200, SLA predicted only.
- **LES escape motor.** 147,000 versus 155,000 lbf; propellant 4,700 lb against the burn time.
- **Other figures.** SPS thrust/Isp pair; APS loads (O/F 1.30, superseded by the FER-507 proxy in §7.3); R-4D Isp; S-IVB ullage thrust 3,390–3,460 lbf; S-IC retro 0.6–0.667 s.
- **S-IVB acceleration at cutoff.** 0.69 g against T/m of 0.680 g. FER insertion mass 135,669 kg against the 135,095 kg budget. *Resolved by the FER (§9.4, §9.5): 135,102 kg at the end of the first thrust decay (Table 20-5), and Table 4-1's 6.73 m/s² exceeds the FER's own thrust over mass.*

**Gaps (next research turn, highest value first)**

1. SP-4029 Propellant Usage, S-II and S-IVB rows: consumption, at-cutoff amounts, mixture ratio. These would replace the §2.2 S-II and S-IVB model loads.
2. FER mass characteristics: the flight-sequence mass summary (masses at CECO, OECO, S-II ignition, jettisons, S-IVB ignition and cutoff), CG and inertias, and the event table (EMR shift, tilt arrest). *Read (§8, §9.1, §9.4): Tables 2-2, 20-1, 20-3, 20-5, 20-7, 20-9; CG and inertias (Table 20-10) not used yet.*
3. As-flown liftoff mass, or the ignition-to-release consumption. The sim's −2.625 s ignition depends on the predicted 85,745 lb. *Resolved (§9.1): 2,899,008 kg at first motion and 39,307 kg of thrust buildup (FER Tables 20-1, 20-9); the sim starts at first motion.*
4. MSFC-MAN-503 station diagram: datum, S-IVB separation plane, tank stations, gimbal planes, nozzle protrusions, fin span.
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
- All tank stations, part CoMs, gimbal heights, the S-IVB separation-plane height, the LM envelope, and Xa-based spacecraft heights.
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
| sii_j2_gimbal | h ≈ 48.4 ± 1.0 m | — | §4 estimate | L | Not found. In the sim the lever arm to the CoM is 11.8 m at S-II ignition and 27.7 m at OECO, so ±1 m changes control effectiveness by ±8% falling to ±4%. |
| sivb_j2_gimbal | h ≈ 71.7 ± 1.0 m | — | §4 estimate | L | Not found. It lies below the S-IVB part's own aft end (72.68 m); this is still unresolved (see `AS506.sIVBJ2GimbalHeight`). In the sim the lever arm is 9.2 m at ignition and 10.3 m at cutoff, so ±1 m changes effectiveness by about ±10%. |

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
| roll_gains | S-IC (both bands): a0 0.245, a1 0.15 s; S-II (all three bands): a0 0.25, a1 0.20 s; S-IVB "not simulated" | (a0, a1) | Boeing D5-15481-1, *Saturn V AS-504 Launch Vehicle Reference Trajectory* Vol. I (1967), Table 3-IV (§8) | L (AS-504 1967 values) | The only roll gains found. Its §3.5 adds an S-IC roll attitude-gain filter 2.35/(s + 2.35) (not modelled). Flown by the model, they reproduce AS-506's peak roll rate in the roll program (§8.6). |
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

Sim inputs used for the table:

| quantity | values |
|---|---|
| Iyy (kg m²) | 9.758e8 at release, 4.294e8 at S-IC OECO, 1.321e8 at S-II ignition, 3.42e7 at S-II OECO, 1.311e7 at S-IVB ignition, 1.201e7 at insertion |
| CoM height (m) | 33.08 at release, 51.07 at S-IC OECO, 60.20 at S-II ignition, 76.06 at S-II OECO, 80.94 at S-IVB ignition, 81.96 at insertion |

Findings:

1. **S-IC.** TN5869's schedule keeps the sim between 0.11 and 0.17 Hz, consistent with TN5869's "≈ 0.15 Hz" first-stage frequency. The steps at 105 s and 130 s are what hold it there. This supports the TN5869 gains, the sim inertia and the 5.461 m gimbal plane together (L-M).
2. **S-IVB.** The 0.81/0.97 pair gives 0.11–0.13 Hz. Reaching 0.2 Hz would need a0 ≈ 2.0–2.5, and 0.5 Hz would need a0 ≈ 13–16. Either the pair is not the S-IVB burn-1 gain, or TN5869's 0.2–0.5 Hz covers TLI, where c rises as the stage empties. Unresolved (§7.5).
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
| aps_switching_line | not found | — | — | — | **Placeholder: fire when e_clip + K·ω exceeds the deadband, with K = 5 s (not data).** This gives manoeuvre rates of about 0.3°/s in pitch/yaw and 0.5°/s in roll. No hysteresis. |
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
6. **APS (§7.3).** Thrusters, tanks, roll-only mode during J-2 burns, and three-axis phase-plane control in coast (deadband, error clip, placeholder K, minimum on-time).
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
| aps_n2o4_total | 183.70 kg | 405 lbm, both modules, at liftoff | FER-507 (verbatim, re-checked) | M as an AS-506 proxy | **AS-507, not AS-506.** The AS-506 FER APS section is unread. |
| aps_mmh_total | 114.31 kg | 252 lbm | FER-507 | M as proxy | |
| aps_per_module | N2O4 91.852 kg + MMH 57.153 kg | 202.5 + 126 lbm | derived (equal split assumed) | L | |
| aps_load_ratio | 1.607 | 405 / 252 | derived | M | The loaded ratio. Use it as the feed mixture ratio, so that both tanks deplete together. The engine operating MR was not found. |
| aps_wikipedia_load | **rejected** | 150 lb N2O4 + 115 lb MMH per module (O/F 1.30) | Wikipedia | — | Twice it (530 lb) contradicts FER-507's 657 lb at liftoff. |
| aps_helium | 21.37 MPa gauge bottle; regulator 1.351 MPa (196 psia), backup 1.379 MPa (200 psia) | 3,100 psig; 196 / 200 psia | APS-TN | M-L | FER-507 tank ullage pressures of 188–194 psia support the regulator value. Helium mass and bottle volume not found: keep them in dry mass. |
| aps_module_dry_mass | not found | — | — | — | Stays in the S-IVB stage dry mass. |
| aps_isp_attitude | **245 s effective** (2,403 m/s) | AS-201 flight averages 237 and 250 s (pulse losses included) | AS201 | L | **Replaces the 290 s placeholder** for the TR-204, since the sim's pulses deliver full thrust for their duration. AS-201 is a Saturn IB with a different APS and no ullage engines. No steady-state or pulse Isp was found for the TR-204. |
| aps_isp_ullage | 290 s (placeholder) | — | none | L | Steady burns. Unsourced; kept from §3. |

**How the APS propellant relates to "sivb_other" (1,656 lb, 751.1 kg).**

- **What is in the row.** FER-507's 657 lb of APS propellant plus the 117.4 lb (53.25 kg) of TX-280 solid propellant leaves 881.6 lb (399.9 kg) for helium (APS and stage), solid-motor cases and other items. The row is therefore not contradicted.
- **What to move.** Take 657 lb (298.01 kg) out of the S-IVB part's dry mass into four point tanks: per module, N2O4 91.852 kg and MMH 57.153 kg, at Positions I and III, h 73.4 m, r 3.5 m.
  - The S-IVB dry mass becomes 24,852 + 1,656 − 657 = **25,851 lb (11,725.8 kg)**.
  - §2.1's S-IVB dry_sim becomes 35,837 − 657 = **35,180 lb (15,957.4 kg)**.
  - The part total stays 119,119.3 kg and the ignition total 2,938,314.7 kg.
- **TX-280 propellant.** Leave the 117.4 lb in dry mass until the ullage-motor item models the TX-280s as solid thrusters on the S-IVB (§3).
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
| torque per deflection | τy = 4·F·L·sin β (S-IC, S-II), F·L·sin β (S-IVB), with the sim's own F, L and I. Sim α at full deflection: 3.9 / 2.6 / 4.4 °/s² at release / S-II ignition / S-IVB ignition | 0.5% against the formula | formula only: L depends on L-graded gimbal heights, so never compare with a published inertia |
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
| S-IVB control frequency | 0.2–0.5 Hz (TN5869) | 0.11–0.13 Hz with 0.81/0.97 | **do not test** | §7.5 conflict |

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
| coast attitude hold | ±1° deadband (EH, M) | with a 0.1°/s disturbance, error stays within ±(1° + one minimum-impulse overshoot); roll Δω per minimum-impulse pair 0.023°/s | ±1.1° | deadband (M); switching line and minimum on-time are placeholders |
| roll-only mode during the S-IVB burn | APS-TN (H) | a roll-rate kick is removed by the APS; APS pitch and yaw thrusters stay off; the J-2 carries pitch and yaw | exact on the inhibits | phase logic only |
| propellant bookkeeping | FER-507 proxy | APS tanks 298.01 kg; S-IVB part total unchanged at 119,119.3 kg; ignition total unchanged | ±1 kg | §7.3 accounting |

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
  - APS loads: AS-507 proxy 405/252 lbm, O/F 1.607.
- **§1.6.** Flight azimuth 72.058°: recalled L → H.
- **§2.1.** S-IVB dry_sim 35,180 lb plus APS tanks 657 lb.
- **§3.** APS rows:
  - attitude 653.9 N at 245 s effective Isp (0.2722 kg/s);
  - ullage 320.3 N at 290 s (0.1126 kg/s), unchanged;
  - feed MR 1.607.
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
- **S-IVB gains:** the 0.81/0.97 pair gives 0.11–0.13 Hz in the sim against TN5869's 0.2–0.5 Hz third-stage frequency. Either the pair or the frequency definition is misread. The S-IVB gimbal height (L, ±1 m) changes this by only ±5%.
- **Cant axis:** 2° radial (1.41° per actuator) versus 2° per actuator (2.83° radial).
- **Cant purpose:** misalignment sensitivity (EL paraphrase) versus engine-out load relief (plausible, unsourced). The ramp rate and the hold-to-OECO are unknown.
- **APS:**
  - Engine roles: TN and EH versus Wikipedia.
  - Module Positions I and III: inferred.
  - Thrust 147 versus 150 lbf (operating versus nominal) and 72 versus 70 lbf (resolved the same way).
  - Loads: FER-507 versus Wikipedia (rejected).
  - Isp: 290 s placeholder versus the AS-201 237/250 s averages.
  - Minimum impulse: the 7.5 lbf·s requirement versus 70 ms × full thrust (46 N·s).
  - Pre-restart ullage: 77 s versus "≈ 1 minute".
- **EDS pitch/yaw overrate:** 3, 4 or 5°/s (≈ 9°/s later).
- **Sim placement:** the flight tests' azimuth 72 (−z downrange) puts Position III downrange. This is harmless for symmetric tests but wrong for engine-out, APS-module and yaw-direction tests.
- **S-IVB J-2 gimbal height:** 71.7 m (L) lies below the S-IVB part's aft end at 72.68 m (§4; L).

**Gaps (next research turn, highest value first)**

1. AS-506 FER control-system section (the tables listed in §7.4 E), the FCC gain-switch and cant times in the sequence-of-events table, and the APS consumption figures.
2. MSFC-MAN-503/506 flight-control and APS sections:
   - FCC summing (mixing) equations and roll gains;
   - S-IVB burn gains;
   - APS phase-plane switching line, hysteresis and minimum pulse;
   - powered-flight attitude-error limits;
   - APS module positions, stations and nozzle cant;
   - J-2 gimbal stations (S-II and S-IVB).
3. A clean read of TN5869 Table 3 (all stages and time references).
4. Primary F-1 gimbal limit, rate and pattern: SAE650304, TMX53532 Fig. 19, R-3896-1. S-IVB J-2 gimbal rate.
5. Actuator bandwidth and dynamic-pressure-feedback parameters. Gimballed mass and inertia about the gimbal for the F-1 and J-2 (tail-wags-dog).
6. Cant ramp duration and axis definition.
7. TR-204 and SE-7-1 steady-state and pulse-mode Isp, and the operating mixture ratio. APS helium mass, module dry mass, and usable versus loaded propellant. AS-506 APS loads per module.
8. Pitch-program rates and the tilt-arrest time (IU item).

**Values a test must not depend on**

- Every gain (TN5869 S-IC M as a reading but L for AS-506; S-II and S-IVB L); the roll gains (D5-15481-1, L); switch times.
- F-1 gimbal limit (±5°, L) and rate (L); S-II rate (M-L); the S-IVB rate placeholder; any actuator dynamics.
- Cant ramp rate and axis definition. The 2° angle and 20.6 s start (M) may be used only for the end state and the start time.
- J-2 gimbal heights (S-II and S-IVB), and therefore every absolute torque, control frequency or angular acceleration. Test formulas against the sim's own mass properties, not published inertias.
- APS module positions, radius, height, nozzle directions and cant. APS Isp (both values). APS switching-line K and minimum on-time. Per-module loads (equal split assumed) and the AS-507 proxy totals.
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

AS-506's own guidance presettings (its *Operational Trajectory* and *Flight Sequence Program* ICD 40M33626B, cited by the FER) were not found. GE504's SA-504 presettings stand in for the pitch polynomial and the program-start test, graded M as a proxy; MAN506 confirms the yaw command and that AS-506's commanded pitch follows SA-504's polynomial (§8.4).

### 8.1 Frames and command conventions

| id | value | source | conf | notes |
|---|---|---|---|---|
| space_fixed_frame | X_S up (opposite local gravity at GRR), Z_S along the flight azimuth, Y_S completing a right-handed set; fixed at guidance reference release | GE504 Fig. 1-1 | H | Earth-centred, non-rotating. The model takes the plumb line at the pad at T1, opposite its J2 gravity plus the Earth's centrifugal term, and turns it back by the Earth's rotation over T1 − GRR = 17.60 s (0.065° in the vertical). On the model's spherical Earth, with the pad at the geocentric latitude 28.447°, the plumb line is at 28.608°, 0.161° north of the radial: AS-506's geodetic vertical, which X_S was. |
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
| T5 | 699.57 | S-IVB velocity cutoff sensed | the step after the IGM's velocity cutoff (§10): the cutoff at 702.87 (3.5 s after AS-506's 699.34), T5 at 702.89 (3.3 s after AS-506's) |

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
| S-II ullage motors on | T3 + 0.5 | 162.1 | the four solids on the interstage, 3.75 s each (§9.2) |
| S-IC/S-II separation | T3 + 0.7 | (command) 162.3 | |
| S-II ignition and gains, band 1 | T3 + 2.4 | 164.0 | engine solenoid activation: the J-2s' start ramp reaches mainstage at 166.2 s (§9.2); roll a0 0.25, a1 0.20 s throughout the S-II (REF504, L) |
| S-II ullage motors off | T3 + 4.4 | 166.1 | the FER's "burn termination" (thrust at 75 %); the model's motors have burned out at 3.75 s |
| S-II high EMR select | T3 + 6.9 | 168.5 | ESC + 5.5 s: the PU system takes the J-2s from their start setting (EMR 5.0) to high EMR (§9.2) |
| aft interstage jettison | T3 + 30.7 | 192.3 | |
| LET jettison | T3 + 36.2 | 197.9 | |
| IGM phase 1 | T3 + 42.4 | 204.1 (204.07, Table 10-4) | the IGM steers from here (§10) |
| S-II gains, bands 2 and 3 | T3 + 61.4, T3 + 191.4 | — | FCC switch points 3 and 4 (ICD507, page images; M) |
| S-II CECO | T3 + 299.0 | 460.6 | |
| EMR shift command | IGM (§10) | 494.8 (494.83, Table 10-4) | the IGM commands it when the S-II's characteristic velocity reaches its preset, and enters phase 2: 494.76 s in the model |
| S-II low EMR | shift command + 2.8 | 497.60 (PU valve step, FER Table 6-2; low EMR by 498.0) | §9.2; the FER's interval from the command (494.8) to the valve step; 497.56 s in the model |
| S-II OECO | LOX depletion | 548.22 | propellant model: 548.24 in flight (§8.2) |
| S-II/S-IVB separation | T4 + 0.8 | (command) 549.0 | |
| IGM phase 3 (steering frozen) | IGM, first cycle after T4 | 548.2 (Table 10-4) | §10 |
| S-IVB ignition | T4 + 4.0 | 552.2 | STDV open; the start ramp reaches mainstage at 554.7 s (§9.2); the S-IVB J-2 flies the vehicle's own gains law (§7.2: TN5869's S-IVB pair is inconsistent) |
| IGM steering on the S-IVB | IGM, at 90 % thrust | 555.6 (555.57, Table 10-4: artificial tau) | §10 |
| terminal guidance, chi freeze | IGM | 665.2, 691.6 (Table 10-4) | §10: 668.16 and 695.36 s in the model |
| S-IVB velocity cutoff | IGM (§10) | 699.34 | the model's 702.87 s, 3.5 s after AS-506's (§10.4) |
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

Checks: the segments join within 0.04° (5.59/5.62° at 35 s, 35.16° at 80 s, 54.67° at 115 s); the command is −0.04° at 12 s, where the program starts; no segment exceeds 1°/s; it reaches −66.59° at SA-504's 153.0 s arrest. Other GE504 pre-IGM presettings: engine-out freeze B11 −0.62, B12 40.9 s, B21 −0.3611, B22 29.25 s, t_1 13.0 s (start backup), t_2 25, t_3 36, t_4 45, t_5 81 s; ΔtLET 35.1 s. The engine-out freeze logic is not modelled (§8.9 item 6).

**AS-506's commanded pitch.** MAN506 Figure 2-2 plots AS-506's typical commanded pitch for the July window; read to about 1°, it follows SA-504's polynomial (time from first motion, which is T1 − 0.4 s in MAN506):

| time from first motion | MAN506 Fig. 2-2 | SA-504 polynomial |
|---|---|---|
| 1 min | −20° | −20.6° |
| 2 min | −56° | −56.5° |
| tilt arrest (plateau) | −67.5° | −68.0° (at T1 + 159.37) |

**Model compensation (fitted, not data).** Flown by this model with AS-506's 160.0 s arrest, the polynomial leaves the S-IC 1.3° steeper and 1.8 km higher at OECO than AS-506 flew, even with the S-IC's thrust, flow and masses matching the FER (§9) and with the sourced aerodynamics and launch-day air of §11. The model's climb matches the PFT's (§11.4), so the cause is not identified (§8.5). So that the S-II starts from AS-506's state, the IU multiplies the polynomial by 1.025 (`AS506.pitchScale`, fitted to the nearest 0.005 on the OECO flight-path angle), 1.7° more pitch at the arrest than AS-506 commanded. Before the recalibration of §9 it was 1.03. It gives:

| | quantity | FER (Table 4-2) | model, ×1.00 | model, ×1.025 | tolerance (§5) |
|---|---|---|---|---|---|
| CECO, 135.2 s | altitude above the pad | 44.0 km | 44.8 | 44.0 | ±2.5 km |
| | space-fixed velocity | 1,979.0 m/s | 1,955.3 | 1,967.7 | ±50 |
| | flight-path angle | 22.957° | 24.24 | 23.15 | ±1.5° |
| | heading | 76.315° | 76.33 | 76.28 | ±0.5° |
| OECO, 161.63 s | altitude above the pad | 66.1 km | 67.9 | 66.1 | ±2.5 km |
| | space-fixed velocity | 2,764.1 m/s | 2,732.9 | 2,750.5 | ±40 |
| | flight-path angle | 19.114° | 20.37 | 19.10 (fitted) | — |
| | heading | 75.439° | 75.40 | 75.37 | ±0.5° |
| | Mach 1 time | 66.3 s | 66.8 | 66.7 | ±1 s (§11) |
| | max Q | 35.2 kPa at 83.0 s | 34.5 at 83.2 | 34.9 at 83.3 | ±2 %, ±1 s (§11) |

Only the OECO flight-path angle was fitted; everything else in the table is a check. The headings come within 0.07° of AS-506's (the test allows §5's 0.5°; `testIGMFliesApollo11ToItsParkingOrbit` pins X_S itself) and so check the space-fixed frame, flight azimuth and roll program independently of the pitch program: with X_S on the radial instead of the plumb line (§8.1) they were 0.13–0.23° high. The S-IC's velocity runs 11–14 m/s (0.5 %) below AS-506's (§9.5, §11.5). Before §11 (US-1976, constant drag) the ×1.025 column read 1,962.9 and 2,745.1 m/s, Mach 1 at 65.5 s and max Q 32.1 kPa at 76.4 s.

**Compare altitude above the pad during the ascent.** The model's pad sits on a sphere of R = 6,378,137 m, 4.78 km further from the Earth's centre than the real pad (§1.6), and the atmosphere is indexed by r − R. The S-IC states are therefore compared as altitude above the pad (the FER's geodetic altitudes; the ellipsoid's curvature over 94 km downrange changes them by under 0.1 km). Radius stays the measure for the orbit (§5).

### 8.5 Known deviations of the S-IC ascent

- **The roll and pitch programs start earlier than AS-506's.** The model reaches GE504's 137 m rise at T1 + 10.7 s and starts them there; AS-506 started them at T1 + 12.6 s (range 13.2 s), when the PFT has it about 200 m up. The model's climb itself matches the PFT: 105 m against 105 m at 10 s, 473 against 478 m at 20 s, and within 60 m to 100 s (§11.4). So AS-506's start test was not 137 m as the model applies it, or measured the rise differently (inferred); its preset was not found (§8.9 item 1). Thrust matches too: the model's stage thrust at liftoff is 34.1 MN at the standard 101.3 kPa, against about 34.35 MN in FER Figure 5-3 at the pad's 100.6 kPa, and its acceleration matches Figure 4-3 within 0.8 % wherever drag is negligible (§9.4). The model has no controlled-release mechanism: the release rods held the vehicle until about 0.6 s after first motion (FER Figure 9-1), hence the FER's 1.07 g there. The program-start time is therefore not a test target. Max Q and Mach 1, which were 7 s and 0.8 s early on the US-1976 atmosphere with a constant drag coefficient, now come within 0.4 s of AS-506's (§11).
- **The pitch polynomial is SA-504's, scaled 2.5 % to compensate.** AS-506's commanded pitch matches it unscaled (MAN506 Fig. 2-2); replace both the polynomial and the scale with AS-506's presettings if its operational trajectory turns up. The scale survived the propulsion recalibration (it went from 3 % to 2.5 %) and the sourced aerodynamics of §11 (unscaled, OECO is 1.3° steep with or without them), and the climb matches the PFT, so what it compensates is not identified (§11.5).

### 8.6 Flight control and APS logic as implemented

- **FCC law** (§7.2): β = a0·e − a1·ω on each gimbal-flown axis, in the IU's hold, with TN5869's gain schedule on the S-IC and S-II switched at the IU's switch points (§8.3), and REF504's roll pair (S-IC 0.245 / 0.15 s, S-II 0.25 / 0.20 s; L). β is each engine's deflection: per actuator in pitch and yaw, tangential in roll (§7.2: if REF504's roll β is per actuator, a diagonal engine deflects √2 times it). REF504's filters (S-IC pitch and yaw attitude gain 0.4(s + 0.095)/(s + 0.038), S-IC roll 2.35/(s + 2.35)) are not modelled. Checks: in the roll program the model peaks at a 1.18° roll error and 1.39°/s roll rate, against AS-506's 0.92° and 1.38°/s (FER Table 11-2); with the pitch pair in roll (the earlier placeholder) the rate peaked at 1.03°/s. The peaks come 2 and 3 s after the program start, against AS-506's 0.6 and 1.2 s, so the model's roll loop is slower than AS-506's. Late in the ramp the law tracks it 0.60° behind (a1/a0 = 0.61°) at 1.00°/s, and Position I settles on 72.058°. A 0.5° pitch step at liftoff mass in vacuum (c = 0.887 s⁻², so ωn = 0.893 rad/s and ζ = 0.343) overshoots 32% at 3.7 s, as §7.4 B's formulas predict.
- **Pilot hand-back**: manual input or another autopilot mode takes the attitude from the IU, which keeps sequencing. When the hold flies again (input released, or key 8 after another mode), the IU restarts its command from the vehicle's attitude and returns to its program within its command rate limits: 1°/s per angle until the S-IVB cutoff, ASH's coast limits (below) from T5 on. 13° off the program at 60 s, the stack turns back at 1.3°/s at most, where the FCC law on the whole error swung it at up to 7.7°/s near max Q.
- **S-IVB burn**: the vehicle's own self-tuned gimbal law (`tvcGains`) flies the J-2, because TN5869's S-IVB pair contradicts its stated control frequency (§7.5).
- **APS phase plane** (§7.2): ±1° dead band; error clipped at 2.5° in pitch and yaw and 3.5° in roll; switching line e − 5 s × ω (placeholder slope); 0.06 s minimum on-time; full-thrust pulses, no hysteresis. It flies the APS in every autopilot mode except kill rotation, and in the IU's hold; in the pointing modes, which set no roll attitude, roll keeps M0's rate damping (proportional levels, as in kill rotation). The law decides once a step, so the simulation ends a coasting step where an axis is predicted to reach its switching line, and a pulse step where the minimum on-time ends: the law then works the same at any frame rate and time warp. Measured: manoeuvres at 0.30°/s in pitch and 0.51°/s in roll; pulses of exactly 0.06 s with the app's 1/60 s frames; holding in free space after a slew, well under 1 kg/h at both 1× and 10,000× (0.13 and 0.18 kg/h in `testAPSHoldAtTimeWarp`; 47 kg/h at 10,000× with coast steps of up to 60 s). The rate is set by the roll rate the slew leaves, which a 0.2 % change in roll inertia moved: with the pre-FER spacecraft masses it was 0.91 and 0.87 kg/h, 14 roll pulses in the 900 s at 1× against 2 now; on the light S-IVB after TLI, Prograde uses 0.2 kg of APS propellant an hour, where M0's law emptied both modules (298 kg) within the hour.
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
| `testOnThePad` | geocentric pad, nose up, Position I east, IU idle until liftoff; Space refused | §1.6, §7.1 (M) |
| `testPitchPolynomialTranscription` | GE504 segments join, start near 0, rates under 1°/s, −66.59° at 153 s; unscaled within 2° of MAN506 Fig. 2-2; the IU's = 1.025 × SA-504 to 159.37 s | GE504 (H for SA-504), MAN506 (figure reading) |
| `testTowerYawAndRollProgram` | yaw to 1.25° at ≤ 1°/s and away from the tower; start at 137 m; roll peaks 1.38 ± 0.1°/s and 0.92 ± 0.35° (FER Table 11-2); lag a1/a0 = 0.61° late in the ramp; Position I on 72.058° | GE504, FER (H), REF504 (roll gains L) |
| `testSICAscentMatchesApollo11` | the §8.4 table, except the fitted angle (±0.2°); Mach 1, max Q, the q history, the climb and Earth-fixed speed against the PFT and the peak axial force (§11.6); thrust acceleration within 1 % of FER Figure 4-3 at 10.3, 147.4, 152.3 and 158.8 s, where drag is under 0.3 % of thrust | FER Table 4-1/4-2 (H), Figure 4-3 (M), PFT (H); `pitchScale` (fitted) |
| `testOutboardCantSchedule` | cant from T1 + 20.0 s to 2° radial | FER (H), EL (M) |
| `testFlightControlStepResponse` | ωn and overshoot of the FCC law | TN5869 (L), model mass properties |
| `testFlightSequenceFollowsTheApollo11Timeline` | every IU event against FER Tables 2-1, 2-2 and 10-4 (S-II gain switches against ICD507), within 0.1 s from T3 on (T3 within 0.05 s), the S-II ullage motors and EMR steps included; the IGM's events within a cycle (1.7 s): the shift command and PU valve step of AS-506's (the step exactly 2.8 s after the command), phase 3 of the model's own T4, terminal guidance and the chi freeze timed from the model's cutoff as the FER's from AS-506's; the velocity cutoff within 6 s of AS-506's; staging by part; S-II at low EMR; ullage 86.7 s; a slew of 3–10° to the local horizontal (AS-506 about 6°); the local-horizontal command within ASH's orbital rate limits, reaching 0.4°/s in pitch, and the pitch error growing at 0.35 ± 0.05°/s from T5 + 21.4 to T5 + 27.4 s (FER Figure 11-12, 721 to 727 s: 0.33–0.37); local horizontal held within 1.9°; a hand-back in orbit restarts the command from the attitude and returns within the limits | FER (H; Figure 11-12 digitised, L-M), ICD507 (M), ASH (M) |
| `testIGMFliesApollo11ToItsParkingOrbit` | §10.6 | FER §10 |
| `testCoastCommandRateFromTheSIVBCutoff` | after the S-IVB cutoff and before the turn to the local horizontal, a hand-back returns at the coast limits (0.6°/s in roll), not 1°/s | ASH (M) |
| `testIUStagesByPartAfterAManualSpacePress` | Space refused before T3; from T3 a pilot's Space press and attitude takeover leave the sequence intact | — |
| `testEarlierTimeBaseEventsDropWhenTheNextStarts` | the S-II dropped by hand starts T4, and the S-II's pending events never fire into the S-IVB; the IGM still starts and steers the S-IVB | — |
| `testAttitudeHandBackReturnsAtTheCommandRate` | handed back 13° off the program, the stack returns at 1.3°/s at most and rejoins the program | GE504 command rate limit |
| `testIUStartedInFlightWaitsForTheProgramStart` | an IU attached in flight takes its rise from there: programs at the 13 s backup | GE504 |
| `testAPSPhasePlaneSlewsAndHolds`, `testAPSDoesNotDrainHoldingPrograde` | §8.6 APS figures | EH 8.30 (M); placeholders K and minimum on-time |
| `testAPSHoldAtTimeWarp`, `testAPSPulseLastsTheMinimumOnTimeAtAnyFrameRate` | the phase plane's propellant use is the same at 1× and 10,000×; a single minimum pulse lasts exactly 0.06 s and gives the same rate at any frame rate | — |
| `testAPSDampsRollInThePointingModes` | a 0.15°/s roll in Prograde dies out (under the phase plane's 0.2°/s threshold) | — |
| `testStepsEndOnFlightProgramEvents` | the simulation ends a step on a program's event at any warp, flying or on the pad | — |

### 8.9 Remaining gaps (IU)

1. AS-506's own pre-IGM presettings (pitch polynomial, t_AR, start test): its July 1969 Operational Trajectory or the SA-506 Flight Sequence Program ICD (40M33626B).
2. PFT Table B-II/B-III: the S-IC time history, to check the whole ascent rather than two points (the tables are scanned and must be read from the page images).
3. *Resolved in §10:* IGM, with presettings from the model's vehicle and AS-506's flight (AS-506's own presettings are still missing, §10.7).
4. *Resolved in §10:* the S-II EMR shift by characteristic velocity.
5. AS-506's roll gains and the definition of the roll β (per actuator or tangential, §7.2), and the FCC filters (REF504 §3.5). The model's roll loop peaks 2–3 s after the program start where AS-506's peaked within 1.2 s (§8.6), which points at the roll authority, the roll inertia or the gains.
6. GE504 Table 4-II's pre-IGM engine-out tilt freeze (B11, B12, B21, B22) for an S-IC engine out in the pitch program.

**Values tests must not depend on**: `pitchScale` beyond the OECO angle it was fitted to; the cant ramp rate; every gain (§7.5), beyond the roll-program peaks checked against the FER; APS K and minimum on-time; the program-start time (§8.5).

---

## 9. Propulsion and masses from the FER (M1 propulsion recalibration)

Compiled on 2026-10-17 to apply §8.7. Values come from the FER (MPR-SAT-FE-69-9) unless marked: SP-4029's ground-ignition rows (which the FER confirms), the S-II start setting's EMR and Isp and the ullage motors' thrust and burn time (MSFC-MAN-506 or assumed, §9.2), and the S-IVB's model-derived unusable masses. The FER was read directly with its tables checked against the page images, and its figures digitised from them (M): Tables 2-1 and 2-2 (events), Table 4-1 and Figure 4-3 (accelerations), Tables 5-1 and 5-2 and Figure 5-3 (S-IC), Tables 6-1 and 6-2, Figure 6-3 and §6.2–6.5 (S-II), Tables 7-1 and 7-3, Figure 7-2 and §7.2–7.4 (S-IVB), and the mass tables 20-1, 20-3, 20-5, 20-7 and 20-9. `AS506Data.swift` holds the values with the same sources and grades. For the model this section supersedes the derived masses of §1.1, the S-II and S-IVB engine rows of §1.2 and §1.3, all of §2, the flight rows of §3, and targets A and B of §5.

### 9.1 Mass model

- **First motion.** Simulation time 0 is holddown release (0.30 s) with the FER's vehicle, 2,899,008 kg (Table 20-1). The 39,307 kg burned in thrust buildup (Table 20-9) is history. The S-IC is the FER's at release: stage 2,239,381 kg, LOX 1,468,594 kg of liquid (Table 5-2) plus the 235 kg of GOX in its ullage (Table 20-1), RP-1 637,830 kg (Table 5-2). The S-II, both interstages' totals, the S-IVB and the IU keep SP-4029's ground-ignition rows (the FER's tables agree to the pound), and the spacecraft is the FER's: LES 4,042, CSM 28,806, LM 15,095 and SLA 1,166 + 626 kg (Tables 20-7 and 20-9), 49,735 kg in all, SP-4029's 109,646 lb. Together they give Table 20-1's 2,899,008 kg to the kilogram, a check across the two sources.
- **Tanks.** A tank holds the propellant aboard at first motion and keeps the gas made from it in flight (the S-IC's GOX, the S-II's GOX and GH2), which stays in the ullage, so what leaves a tank is what its engines burned. Its unusable mass is the liquid at cutoff plus that gas: S-IC LOX 18,041 + 3,611 = 21,652 kg (Tables 5-2, 20-1), S-II LOX 1,603 + 2,147 = 3,750 kg (Table 20-3). LOX depletion ends both burns, as the low-level sensors did. The fuel left is an output: the S-IC's RP-1 should be 13,954 kg (Table 5-2) and the S-II's LH2 2,695 + 658 = 3,353 kg (Table 20-3); the mixture ratios are fitted to them (§9.3). The S-IVB's tanks keep their §2 loads and the unusable masses derived for the pre-FER engine (at burn 1's EMR 4.85 the usable LOX would last 478 s and the LH2 474 s; burn 1 ends after 147 s, and TLI is M2's).
- **S-IC/S-II interstage.** Three items (Table 20-9): the 614 kg ring that leaves with the S-IC at first-plane separation (booked in the S-IC part), the large interstage, 3,982 kg, jettisoned at 192.3 s, and its four ullage motors' 610 kg of propellant (one tank for the four grains, which burn together).
- **Not modelled.** The S-II's and S-IVB's frost (204 and 91 kg) and the S-II insulation purge gas (54 kg), shed in the S-IC burn; venting and boil-off before ignition; the S-IVB aft frame and detonation package (23 kg, with the S-II); the S-IVB's TX-280 ullage motors and their 61 kg of cases (jettisoned at 561 s); the S-IC's frost (295 kg) and purges. They leave the model's upper stages 150–360 kg heavier than the FER's at each event (§9.4).

### 9.2 Engines

| engine | model | basis | conf |
|---|---|---|---|
| F-1 | One rating at first motion carried along a schedule of the stage's site flow and mixture ratio (29 knots, 0.3–161.63 s; the flow rises about 2 % through the burn). Per engine: vacuum thrust = flow/5 × 2,980.5 N·s/kg (7,847,657 N at first motion), flow × 0.99896, mixture ratio × 0.99965 (both fitted, §9.3), exit area 10.10 m². | Figure 5-3 (stage flow, MR; ±15–25 kg/s and ±0.002); 2,980.5 N·s/kg is the stage's site Isp at 140–160 s, where p is tens of Pa; the exit area gives the figure's liftoff Isp, about 2,594 N·s/kg at 100.6 kPa, on the figure's flow. The thrust then follows the figure within 0.4 % at CECO and at 160 s, and is 0.6 % low at liftoff, where the figure's thrust is 0.6 % above its flow times Isp. | M |
| F-1 shutdown | Linear decay over 0.66 s from the cutoff (0.33 s of full thrust); its propellant comes from below the unusable mass. | §5.4: 10,612,096 N·s for the four outboard engines from OECO to separation, 2,659,605 N·s for the centre engine. The decay burned 908 kg per engine (Table 20-9). | H (impulse), L (shape) |
| J-2, S-II start | 878,288 N, 4,195 N·s/kg, EMR 5.0, from engine start to High EMR Select at ESC + 5.5 s (168.5 s). | §6.2: 861,496–895,080 N per engine at start; EMR at PU null (MAN506, L); Isp assumed between the S-IVB's and the S-II's (L). | M thrust, L Isp |
| J-2, S-II high EMR | 1,028,303 N, 4,164.9 N·s/kg (424.7 s), EMR 5.5006 (fitted) to the PU valve step. | Table 6-1, the five engines' mean at ESC + 61 s (engine EMR 5.564); Figure 6-3: stage EMR 5.55 falling to 5.45. | H |
| J-2, S-II low EMR | 768,000 N, 4,190 N·s/kg, EMR 4.34, from the PU valve step at 497.60 s to OECO. | §6.3: 3,082,769 N for four at ESC + 351 s and 3,059,402 N at ESC + 381 s; Figure 6-3: 4,181–4,190 N·s/kg; §6.5: average EMR 4.34 (predicted 4.33). AS-506 ran 7–8 % below §3's 828 kN at EMR 4.7. | H |
| S-II flows | All three settings' flows × 0.99749 (fitted, §9.3). | Within the FER's flow reconstruction, which matched acceptance Isp. | — |
| J-2, S-II transients | Start: nothing for 1.09 s after the solenoids (164.0 s), then a linear rise over 1.11 s to mainstage at 166.2 s. Shutdown: linear over 0.38 s. | 582 kg burned between 164.0 and 166.2 s (Table 20-9), 0.56 s of full flow; OECO cutoff impulse 581,916 N·s to 5 % thrust (§6.4), from 2,783,479 N after a LOX-starvation decay the model does not have: 0.19 s of the model's 3,072,000 N. The centre engine's decay then burns 47 kg (Table 20-9: 49 kg). | H (data), L (shape) |
| J-2, S-IVB burn 1 | 903,000 N, 215.37 kg/s (427.5 s), EMR 4.85. | Figure 7-2: 902–906 kN in flight (Table 7-1's standardised 901,223 N); Table 20-9: 31,152 kg in 144.64 s of mainstage, venting included; Table 20-5: LOX 25,873 kg and LH2 5,339 kg used (the engine's own EMR was about 4.96). | M thrust, H flow and ratio |
| J-2, S-IVB transients | Start: nothing for 0.6 s after STDV open (552.2 s), then a linear rise over 1.9 s to mainstage (554.7 s). Shutdown: linear over 0.42 s. | §7.2: 857,243 N·s from STDV open to STDV + 2.5 s, 0.95 s of full thrust; §7.4: 188,302 N·s at cutoff, 0.21 s. | H (data), L (shape) |
| S-II ullage motors | Four solids, 23,000 lbf for 3.75 s each and 152.5 kg of propellant each (Isp_eff 256.5 s), on the interstage; lit by the IU at T3 + 0.5 s, off at T3 + 4.4 s. | MAN506 (thrust, burn time; M); Table 20-9 (610 kg in all; 309 kg left at S-II engine start; H); Table 2-2 (times; H). | M |

**How the engines work in the core** (`Components.swift`, `PropulsionModelTests` A6–A9). A `PerformanceSchedule` scales an engine's rating, thrust and flow by factors and sets its mixture ratio, piecewise linear on the engine's burn clock, which runs from its start; the exit area stays. `EngineTransients` add a start delay with a linear rise and a linear shutdown. Ramps are sampled at the middle of each step. A cutoff commanded before a step starts the decay with that step; an engine whose tank runs dry within a step runs to its end, then decays. Every engine's step is fixed before any draws, so engines sharing a tank that runs dry within a step are treated alike. A cut engine runs its decay to the end before a new command can start it, and the simulation keeps 0.02 s steps from a start command, through the delay, so the ramps are the same at any time warp. The IU senses an engine's cutoff, not the end of its decay, and the HUD's stage Δv follows the schedule and ignores the ramps.

### 9.3 Fitted values

| value | fitted to | result |
|---|---|---|
| `sICFlowScale` 0.99896 | LOX depletion at 161.63 s from the first-motion loads, the centre engine's decay included | 161.64 s (T3 at 161.64 in flight; FER 161.66) |
| `sICMixtureRatioScale` 0.99965 | RP-1 at OECO, 13,954 kg | 13,955 kg |
| `sIIFlowScale` 0.99749 | LOX depletion at 548.22 s, start and decays included | 548.16 s from a 164.00 s start; T4 at 548.24 in flight (FER 548.24) |
| `sIIHighMixtureRatio` 5.5006 | LH2 at OECO, 3,353 kg | 3,354 kg |
| `pitchScale` 1.025 (§8.4) | OECO flight-path angle, 19.114° | 19.09° |

The flow scales move the figures they adjust by 0.10 % and 0.25 %, inside their reading accuracy.

### 9.4 Results against the FER

**Event masses**, with the propellant model alone at the FER's event times (`testEventTimelineThroughThePropellantModel`):

| range time (s) | event | model (kg) | FER (kg) | difference |
|---|---|---|---|---|
| 0.30 | first motion | 2,899,008 | 2,899,008 (Table 20-1) | 0 |
| 135.20 | S-IC CECO | 1,111,611 | 1,110,189 (20-1) | +1,422 (+0.13 %) |
| 161.64 | S-IC OECO (FER 161.63) | 827,956 | 827,292 (20-1) | +664 (+0.08 %) |
| 162.30 | S-IC/S-II separation | 824,402 | 823,625 (20-1) | +777 (+0.09 %) |
| 164.00 | S-II engine start | 658,713 | 658,363 (20-9) | +350 (+0.05 %) |
| 166.20 | S-II mainstage | 657,823 | 657,459 (20-9) | +364 (+0.06 %) |
| 548.16 | S-II OECO (FER 548.22) | 214,248 | 213,888 (20-3) | +360 (+0.17 %) |
| 549.00 | S-II/S-IVB separation | 214,109 | 213,757 (20-3) | +352 (+0.16 %) |
| 552.20 | S-IVB ignition | 166,751 | 166,571 (20-9) | +180 (+0.11 %) |
| 554.70 | S-IVB mainstage | 166,547 | 166,396 (20-9) | +151 (+0.09 %) |
| 699.34 | S-IVB cutoff | 135,396 | 135,182 (20-5) | +214 (+0.16 %) |
| 699.54 | end of thrust decay | 135,363 | 135,102 (20-5) | +261 (+0.19 %) |

The S-IC's propellant is the FER's, so from OECO on the differences are the upper stages' unmodelled losses (§9.1); the S-IC's own +314 kg at OECO is frost and purges, and the CECO difference is within Figure 5-3's flow reading. Also: S-II ullage propellant left at S-II engine start 311 kg (FER 309); the outboard F-1s' decay to separation 3,531 kg (FER 3,634, −2.8 %); the residuals as fitted (§9.3).

**Accelerations.** Thrust over mass, in vacuum, against Table 4-1's stage maxima (total inertial acceleration; drag is negligible there) and Figure 4-3 (M, ±1 %); "flight" rows are from the IU's trajectory, with ambient pressure:

| point | model | FER | difference |
|---|---|---|---|
| liftoff (flight, 101.3 kPa) | stage thrust 34.1 MN; 11.78 m/s² (1.20 g) | about 34.35 MN at 100.6 kPa (Figure 5-3); "approximately 1.2 g" (§9.2.1) | −0.6 % |
| 10.3 s (flight) | 12.44 m/s² | 12.41 (Figure 4-3) | +0.2 % |
| S-IC CECO | stage thrust 40.03 MN | 40.05 MN (Figure 5-3) | −0.1 % |
| 147.4, 152.3, 158.8 s (flight) | 32.48, 34.39, 37.21 | 32.23, 34.31, 37.23 (Figure 4-3) | +0.8, +0.2, −0.0 % |
| S-IC OECO | 38.55 | 38.61 (Table 4-1) | −0.2 % |
| S-II, 180 s | 8.02 | 7.75 (Figure 4-3) | +3.4 % (§9.5) |
| S-II, 300 and 400 s | 10.59, 14.19 | 10.60, 14.01 (Figure 4-3) | −0.1, +1.3 % |
| S-II CECO | 17.87 | 17.84 (Table 4-1) | +0.2 % |
| S-II, 503.6 s (low EMR) | 12.45 | 12.69 (Figure 4-3) | −1.9 % (§9.5) |
| S-II OECO | 14.34 | 14.3 (Figure 4-3) | +0.3 % |
| S-IVB, 557.1 s | 5.44 | 5.29 (Figure 4-3) | +2.8 % (§9.5) |
| S-IVB, 627.4 s | 5.98 | 5.98 (Figure 4-3) | 0.0 % |
| S-IVB cutoff | 6.67 | 6.69 (Figure 4-3); 6.73 (Table 4-1) | −0.3 %; −0.9 % (§9.5) |

**Trajectory** (the IU flight, §8.4): CECO and OECO within §5 C's tolerances, the S-IC 11–14 m/s slow (§9.5; 16–19 m/s before the aerodynamics of §11). The S-IC's decay and the S-II ullage motors add 10.7 m/s from OECO to separation (FER Tables 4-2 and 4-3: 2,764.1 to 2,773.9 m/s, 9.8 m/s).

### 9.5 Known deviations

1. **The S-IC is 11–14 m/s (0.5 %) slow at CECO and OECO,** although its thrust, flow and masses match the FER and its acceleration matches Figure 4-3 within 0.8 % wherever drag is negligible. With a constant drag coefficient on the US-1976 atmosphere it was 16–19 m/s; §11's sourced aerodynamics and launch-day air recovered about 5 m/s, and the climb now matches the PFT. The candidates for the rest are in §11.5. `pitchScale` absorbs the attitude; the speed stays within §5 C's ±40–50 m/s.
2. **Early S-II acceleration is 2–4 % above Figure 4-3** from about 170 to 200 s (+3.4 % at 180 s). This is an inconsistency inside the FER, not a model error: Figure 6-3's stage thrust is flat at 5.138–5.160 MN from ESC + 4 s, the model's 5 × 1,028,303 N, and over the FER's own mass (Table 20-9 at mainstage less Figure 6-3's flow) it gives 8.03 m/s² at 180 s, where Figure 4-3 reads 7.75. The model's mass is within 0.06 % at mainstage and its CECO maximum within 0.2 % of Table 4-1.
3. **The S-II's low-EMR thrust is held at its 768 kN average** (§6.3), while Figure 6-3's declines through the phase from 3.093 MN for the four engines just after the step (ESC + 338 s; §6.3: 3,082,769 N at ESC + 351 s) to 3.054 MN at OECO: the model is 0.7 % low after the step and 0.6 % high at OECO. Against Figure 4-3 it is 1.9 % low at 503.6 s, the other 1.2 % being Figure 4-3 above the FER's thrust over mass.
4. **The S-IVB's thrust in its first seconds of mainstage** was below Figure 7-2's steady value: Figure 4-3 times the FER's mass gives about 878 kN at 557 s, against 904.5 kN where Figure 7-2 starts (567 s). The model, at 903 kN throughout, is 2.8 % above Figure 4-3 at 557 s and matches it from about 600 s.
5. **Table 4-1's S-IVB maximum, 6.73 m/s²,** is more than Figure 7-2's thrust over Table 20-5's mass allows (6.68–6.70 m/s²). The model gives 6.67 and is tested against Figure 4-3's 6.69.
6. **Upper-stage masses are 150–360 kg high** (§9.1's unmodelled items).
7. **Other solid motors** (the S-IC and S-II retros, the S-IVB's TX-280 ullage motors) are not modelled. The S-II ullage motors are on/off thrusters on the translate-forward group, so a pilot can stop and restart them, and the U key fires them on the pad.
8. **The ramp shapes are linear,** fitted only to the FER's impulses and propellant.

### 9.6 Tests

| test | checks | depends on |
|---|---|---|
| `PropulsionModelTests` A6–A9 | schedule on the burn clock; start ramp; shutdown ramp after a cutoff and after depletion; a relight waits for the decay to end; scheduled stage Δv | mechanism only |
| `SaturnVDataTests.testFirstMotionMassesMatchTheFER` (B3) | 2,899,008 kg at first motion to 1 kg, the ground-ignition 6,477,875 lb, every part, and the FER's interstage and spacecraft items against SP-4029's rows | FER Tables 20-1, 20-7, 20-9 (H); GIW (H) |
| `testEngineRatings` (B1, B2) | the F-1's flight rating and its schedule against Figure 5-3 at liftoff, CECO and 160 s; against Betts' rating; the J-2 settings; the S-II's high EMR against the J-2 rating and Table 6-1's flow; the S-IVB's thrust and Isp against Table 7-1 | FER (H tables, M figures), Betts, NTRS 20100032986 |
| `testTransientImpulsesMatchTheFER` (B2) | every start and shutdown ramp's impulse (or the S-II start's propellant), run through the engines, within 1 % of the FER's | FER §5.4, §6.4, §7.2, §7.4, Table 20-9 (H) |
| `testSICDrawStopsOnLOXDepletion` (A1) | depletion at exactly the unusable mass at 161.63 s with 13,954 kg of RP-1; the outboard decay's 3,634 kg ±5 % | FER (fitted, and H) |
| `testSIIMixtureRatioShift` (A2) | the J-2 start ramp; rating changes mid-burn change thrust, flow and split without a restart | FER (H) |
| `testEventTimelineThroughThePropellantModel` (B4) | §9.4's event masses (±0.1–0.25 %), the Table 4-1 maxima (±0.3 %), Figure 4-3 at S-II OECO and S-IVB cutoff, the fitted depletions and residuals, the ullage propellant | FER |
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
| space-fixed frame | X_S, Y_S, Z_S of §8.1 (PACSS 13): X_S up at GRR, Z_S along the 72.058° azimuth | GE504 Fig. 1-1; FER, PFT | H | X_S is the plumb line at the pad: 28.608° on the model's Earth, as AS-506's geodetic vertical (§8.1). The IGM's [A] (Table 4-I) takes the latitude of X_S from the Earth's pole in the IU's frame. |
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
| not modelled | steering misalignment correction (SMC), S-II engine-out (the 5/4 factors), direct staging, rotated terminal conditions, range angle 2 (ε1), terminal-condition updates (ε3) | — | AS-506 ran SMC from 221.5 s (FER Table 10-4); it corrects a thrust misalignment the model does not have. ε1 and ε3 never apply into orbit with SA-504's values. |

### 10.3 Presettings

| symbol | model | SA-504 (GE504 Table 5-I) | basis | conf |
|---|---|---|---|---|
| Δt (cycle) | 1.7 s | 1.7 s | GE504 | H (SA-504), M (AS-506) |
| IGM start | T3 + 42.4 s | TB3 + 40.671 s | FER Table 2-2 | H |
| Vex1, Vex2, Vex3 | 4,175.4, 4,200.5, 4,192.8 m/s | 4,169.23, 4,204.26, 4,170.57 m/s | the model's S-II high and low EMR and S-IVB settings, thrust over flow (§9.2) | model |
| τ2, τ3 | 347.5 s, 773.5 s | 309.23 s, 665.86 s | the model's mass at the shift command over four low-EMR J-2s' flow (254,050 kg, 347.4 s); at S-IVB 90 % thrust over the J-2's flow (166,588 kg, 773.5 s); rounded to 0.5 s | model |
| T2, Tc, T3′ | 53.4, 6.3, 144.8 s | 99.886, 4.718, 120.565 s | AS-506's shift command to S-II OECO (494.8 to 548.22 s), T4 to 90 % thrust in the model (548.24 to 554.5 s), and 554.5 to 699.34 s | inferred from the FER |
| V_C (shift) | 3,906 m/s | — (a discrete) | fitted to a cycle: the command on the model's cycle that holds AS-506's 494.83 s (494.76 s; the cycles fall on a grid set by the IGM start, so the fit cannot place it closer); it absorbs AS-506's scaling error and the model's S-II differences | fitted |
| C0′ | 9.0 s after the shift, 6.0 s after S-IVB ignition | none, 25 s | FER Table 10-4: 9.33 and 6.86 s, from cycle starts | L |
| ROV, t | 1.5, 2.0 s | the same | GE504 | M |
| ε2 | 35 s | 10 s | FER Table 10-4: terminal guidance 34.19 s before the cutoff command, on the reading that the FER's "terminal guidance" ("begin chi bar steering", Figure 10-4) is GE504's K = 0 mode, whose dropped K terms match the 2–2.5° nose-down step at 665 s in Figure 10-4 | L (inferred) |
| ε4, V_TC | 8 s, 300 m/s | the same | GE504; AS-506's chi freeze came 7.70 s before its cutoff (FER Table 10-4) | H (SA-504), M |
| ΔV_B | 1.45 m/s | 2.0275 m/s | the model's own gain from the cutoff command to insertion, 1.40 m/s from the J-2's thrust decay (§9.2) and 0.05 m/s from the APS ullage burn, so it inserts at circular speed. AS-506's LVDC gained 1.85 m/s over the same 10 s (FER Table 10-2: 7,791.43 to 7,793.28 m/s), vents included. | model |
| R_T, γ_T, i, θ_N, μ | §10.1 | 6,563,365 m, 0, polynomials in azimuth, 3.986032 × 10¹⁴ | §10.1 | H |

### 10.4 Results against AS-506

The IU flying the whole ascent as `testIGMFliesApollo11ToItsParkingOrbit` does (fixed 0.02 s steps, and the app's steps in the high-speed loop); the IGM's events come on its cycles, as the FER's (Table 10-4: "for the start of the computation cycle"):

| event | model (s) | AS-506 (s; FER Tables 2-2 and 10-4) |
|---|---|---|
| IGM phase 1 | 204.04 | 204.07 |
| EMR shift command, IGM phase 2 | 494.76 (fitted) | 494.83 |
| PU valve step | 497.56 | 497.60 |
| T4 | 548.24 | 548.24 |
| IGM phase 3 (steering frozen) | 549.16 | 548.2 |
| S-IVB steering (artificial tau) | 555.96 | 555.57 |
| terminal guidance | 668.16 (cutoff − 34.71) | 665.15 (cutoff − 34.19) |
| chi freeze | 695.36 (cutoff − 7.51) | 691.64 (cutoff − 7.70) |
| velocity cutoff command | 702.87 | 699.34 |
| T5 | 702.89 | 699.57 |

| state | quantity | model | AS-506 LVDC (FER Table 10-2) |
|---|---|---|---|
| S-II OECO (T4) | radius | 6,560,306 m | 6,559,961 m |
| | speed | 6,900.7 m/s | 6,915.96 m/s |
| | flight-path angle | 0.697° | 0.614° |
| velocity cutoff | radius | 6,563,330 m | 6,563,335 m |
| | speed | 7,791.567 m/s (V_T − ΔV_B) | 7,791.43 m/s |
| | flight-path angle | −0.0009° | −0.0015° |
| | commanded pitch | −111.7° | OT −112.4°, LVDC −113.6° (Figure 10-4) |
| insertion (cutoff + 10 s) | speed | 7,793.02 m/s | 7,793.28 m/s |
| | inclination | 32.531° | 32.532° (nominal 32.531°, actual 32.521°) |
| | descending node | 123.097° | 123.102° (nominal 123.100°, actual 123.088°) |
| | apogee × perigee above 6,378,165 m | 185.2 × 185.1 km | 186.0 × 185.2 km (actual 186.0 × 183.2) |
| | eccentricity | 0.000007 | 0.00006 (Table 10-5: 0.00007) |
| | period | 88.20 min | 88.20 min |

Commanded attitude against FER Figure 10-4 (degrees; operational trajectory, OT, and the LVDC's own):

| t (s) | pitch, model | OT | LVDC | yaw, model | OT | LVDC |
|---|---|---|---|---|---|---|
| 212 | −62.3 | −62.5 | −61.3 | −0.29 | −0.08 | −0.36 |
| 240 | −64.7 | −65.1 | −64.1 | −0.25 | 0.18 | −0.27 |
| 300 | −70.1 | −70.8 | −70.0 | −0.16 | 0.36 | −0.11 |
| 400 | −80.7 | −81.6 | −81.6 | −0.01 | 0.55 | 0.09 |
| 450 | −86.3 | −87.5 | −86.5 | 0.07 | 0.59 | 0.21 |
| 500 | −91.3 | −91.0 | −92.5 | 0.12 | 0.44 | about 0.6 |
| 548 | −97.0 | −96.5 | −97.8 | 0.18 | 0.51 | 0.61 |
| 580 | −101.2 | −100.7 | −99.1 | 0.22 | 0.60 | 1.02 |
| 600 | −103.2 | −103.4 | −102.8 | 0.23 | 0.79 | 1.30 |
| 650 | −108.3 | −108.7 | −108.7 | 0.30 | 0.77 | 1.28 |
| 680 | −111.7 | −112.6 | −113.8 | 0.51 | 0.81 | 1.24 |

The pitch follows the OT within 1.3° throughout, including the pitch-up at IGM start from the tilt arrest's attitude (to −62.3° at 212 s; AS-506's peaked at −62.5° on the OT and −61.3° on the LVDC). The yaw follows AS-506's LVDC within 0.1° to 400 s, where the OT ran 0.3–0.5° above the LVDC and 0.2–0.6° above the model; from 450 s it stays below both curves, by up to 1.1° against the LVDC (at 600 s) and 0.6° against the OT. After the cutoff the IU's slew to the local horizontal is 6.1°, as AS-506's was about 6° (§8.6). These are with §11's aerodynamics and launch-day air; before them the cutoff came at 704.07 s and S-II OECO 23.1 m/s slow.

**Point mass from AS-506's state.** `IterativeGuidanceTests` flies a point mass with the model's S-II and S-IVB performance from AS-506's postflight (PFT) state at 200 s (6,464,247; 44,119; 264,596 m and 576.4; 120.7; 2,884.5 m/s in PACSS 13; mass 608,178 kg, estimated), with its own V_C (3,652 m/s: its characteristic velocity is summed from 200 s), ΔV_B (1.6 m/s, no decay) and τ2 (347.0 s, from its mass); the rest are §10.3's. It cuts off at V_T − ΔV_B within 0.01 m/s, 49 m from R_T, at γ 0.0007° and 0.001° from the target plane, about where AS-506 did.

### 10.5 Known deviations

1. **The cutoff is 3.5 s after AS-506's,** from a longer S-IVB burn: 150.6 s from STDV open against 147.1 s. The model reaches S-II OECO 15.3 m/s slower than AS-506 (the S-IC's 11–14 m/s deficit, §9.5, and a few m/s more in the S-II), about 2.3 s of S-IVB burn at its final 6.7 m/s²; the other 1.2 s is not broken down (the model's S-IVB is 150–360 kg heavier, §9.5, and its OECO state 345 m higher at a 0.08° steeper flight-path angle). AS-506's own burn was 3.4 s longer than predicted, its S-II having cut off 3.5 s early and 22.8 m/s below nominal (FER §7, Table 4-2; the link is inferred).
2. **Yaw from 450 s** stays below AS-506's, by up to 1.1° against the LVDC (at 600 s) and 0.6° against the OT; before that it follows the LVDC within 0.1°. Not broken down. With X_S on the radial instead of the plumb line (before the review of 2026-10-17), the S-IC left 6 m/s more crossrange velocity at IGM start and the early yaw was 0.6° below the LVDC's.
3. **The chi freeze comes 7.5 s before the cutoff,** against AS-506's 7.70 s: the ε4 test runs on the 1.7 s cycle, so the freeze falls 6.3–8 s before the cutoff.
4. **Terminal guidance as ε2 = 35 s** rests on reading the FER's "begin chi bar steering" as GE504's K = 0 mode (§10.3).
5. **The model's presettings are its own vehicle's,** not AS-506's (§10.3), and V_C is fitted to the shift command's time.
6. **Phase 3 starts on the first cycle after T4,** 0.9 s after it here; the steering is frozen through the coast either way.
7. **Perfect navigation and an exact BNVC;** no SMC, engine-out or direct staging.
8. **The model inserts at circular speed,** where AS-506's vents left the LVDC 0.22 m/s above it (186.0 × 185.2 km).

### 10.6 Tests

| test | checks | depends on |
|---|---|---|
| `IterativeGuidanceTests.testStageIntegralsAreTheThrustMoments` | Table 4-IV's closed forms of L, J, S, Q, P, U against Simpson integrals of the thrust acceleration's moments (1 part in 10¹⁰) | GE504 (H) |
| `testT2HoldsAtZeroWhenTheSIIBurnsLonger` | an S-II burning 15 s past T2 leaves T2 at 0 in stage 2, T1 at 0 and Tc unchanged | GE504 Fig. 4-5 (H) |
| `testIGMFliesAPointMassFromAS506StateToTheTargetOrbit` | from the PFT state at 200 s: the cutoff at V_T − ΔV_B (0.01 m/s), R_T (100 m), γ_T (0.005°), i and θ_N (0.002°); the shift command (494.8 ± 3 s), S-II OECO (548.2 ± 3 s) and cutoff (699.34 ± 4 s); terminal guidance and the chi freeze at their times to go (±2 s); the steering frozen on every cycle from the S-II cutoff to the S-IVB's 90 % thrust, and on no other before the high-speed loop; the pitch within 3° of Figure 10-4's LVDC at 240, 400, 548 and 680 s | PFT Table B-II (H); FER Tables 2-2, 4-5, 10-4 (H), Figure 10-4 (M) |
| `SaturnIUTests.testIGMFliesApollo11ToItsParkingOrbit` | X_S at the plumb line's 28.6084° (±0.001°); the commands within 2° in pitch and 0.8° in yaw of the OT at 212–680 s, and −112.4 ± 2° at the cutoff; the command unchanged through the coast; S-II OECO within 1 km, 30 m/s and 0.15° of the LVDC's state; the cutoff on V_T − ΔV_B within 0.01 m/s (the app's steps in the high-speed loop), and within 50 m, 0.25 m/s and 0.005° of the LVDC's; at insertion i 32.532 ± 0.003°, θ_N 123.102 ± 0.006°, apogee 186.0 ± 1 km, perigee 185.2 ± 0.5 km, e < 0.0002, period 88.20 ± 0.02 min | FER Tables 10-2 and 10-5 (H), Figure 10-4 (M) |
| `testFlightSequenceFollowsTheApollo11Timeline` | §8.8: the IGM's events against FER Tables 2-2 and 10-4 within a cycle (phase 3 within a cycle of the model's own T4), the PU valve step exactly 2.8 s after the shift command, phase 3 a whole number of 1.7 s cycles after it, the slew after the cutoff | FER |
| `testIGMCyclesStay1Point7SecondsApartAtTimeWarp` | stepped as the app does at 10× warp, the IGM cycles 1.7 s apart (±0.0001 s) | GE504 Table 5-I (Δt) |
| `testEarlierTimeBaseEventsDropWhenTheNextStarts` | with the S-II dropped by hand, the IGM still starts and steers the S-IVB | — |
| `testSIVBCutoffBeforeTheIGMStartLeavesNoIGM` | with the S-II dropped at 163 s and the S-IVB cut at 180 s, T5 drops the IGM's start: no IGM afterwards | — |

### 10.7 Remaining gaps

1. AS-506's own IGM presettings (operational trajectory, ICD 40M33626B), and its formula for T1i from BNVC.
2. SMC, the S-II engine-out logic and direct staging; navigation errors and the LVDC's gravity model and BNVC scaling.
3. The S-IVB second burn (TLI) is M2: GE504's out-of-orbit path and AS-506's restart presettings.
4. The model's 15.3 m/s speed deficit at S-II OECO, mostly the S-IC's (§9.5, §11.5): about 2.3 s of the cutoff's 3.5 s delay; the other 1.2 s is not broken down (§10.5).

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
| S-II OECO speed | 6,900.7 m/s | 6,915.96 (Table 10-2) | 6,892.8 |
| S-IVB velocity cutoff | 702.87 s | 699.34 s | 704.07 s |

- **Max Q** was 9 % low and 7 s early before, and Mach 1 0.8 s early. That came from the US-1976 atmosphere, up to 15 % thinner than the day's air at 12–20 km. Flying AS-506's own trajectory through US-1976 gives 32.3 kPa at 76–77 s (research notes, inferred), the model's old value.
- **The climb** matches the PFT within 60 m and the speed within 1.4 %. The S-IC is now 11–14 m/s slow at CECO and OECO, against 16–19 m/s before.
- **Angle of attack.**
  - In the first 40 s the low-level winds (3–6 m/s against an airspeed under 140 m/s) give a total of 15° at 5 s and 10° at 10 s (9.5° in yaw), 3.6° in yaw at 30 s and 2° at 40 s, while q is under 9 kPa.
  - It peaks at 1.8° at 53 s and stays under 1.3° from 60 s; near max Q it is about 0.5°.
  - AS-506's Q-ball reached 1.82° in pitch at 117.1 s and 1.42° in yaw at 73.0 s (FER Table 11-2).

### 11.5 Known deviations

1. **The pitch program still needs its 2.5 % scale.** Unscaled, the S-IC ends 1.3° steep (OECO γ 20.37°) and 1.8 km high. Neither the aerodynamics nor the climb is the cause: the model's climb matches the PFT. What the scale compensates is not known (§8.5).
2. **The S-IC remains 11–14 m/s slow** at CECO and OECO, and 0.7–1.3 % slow in Earth-fixed speed from 40 s. The S-IC's thrust and flow match the FER (§9). Candidates:
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

# Saturn V AS-506 (Apollo 11): reconciled datasheet for the OrbitSim M1 stack

Compiled on 2026-10-15 for M1 item 1 (the Saturn V stack) from web research in four categories: launch-vehicle masses and timeline, propulsion, geometry and aero, and spacecraft. Each category was independently re-verified, then reconciled here. `Sources/OrbitCore/Vessel/AS506Data.swift` holds the values the simulator uses, with the same sources and confidence grades.

**Limits.** The NASA documents could not be fetched directly; values come from search extracts of them, from arithmetic on those values, or (marked **recalled**) from memory without a check against the source. The SP-4029 S-II and S-IVB propellant-usage rows and the FER mass tables are still unread; they are the most valuable follow-up.

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
- **Drag area.** `dragArea` is the maximum over parts of πr²·Cd. The drag coefficient is constant, with no Mach dependence.
- **Staging.** `jettisonBottomPart` drops the part with the lowest x. Only the lowest part that has `.main` thrusters responds to the throttle. The LES is at the top, so it needs `separate(parts:)`.
- **Spherical Earth.** R = 6,378,137 m, with the US-1976 atmosphere indexed by r − R. The real pad is at a geocentric radius of 6,373.355 km, so a pad placed on the sim sphere is 4.78 km "too high" in radius. Validate radii, not published altitudes (§5).

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
| S-IC outboard engine cant | 20.6 | FER (garbled) | L | Cant angle not found; recalled ≈ 2°, unverified. |
| Mach 1 | 66.3 | TL, AP | H | |
| max Q | 83.0 | SP-4029 Ascent Data | H | |
| S-IC CECO (command) | 135.20 | TL, AP | H | The SP-4029 timeline entry at 91.5 s is an error. |
| S-IC OECO | 161.63 | SUM, MR (161.7) | H | Triggered by the LOX low-level sensors (depletion). |
| S-IC/S-II separation | 162.30 | AP | H | |
| S-II engine start command | 163.04 | TL, MR | H | |
| S-II burn reference start (≈ mainstage) | 164.00 | PU, AP durations | M | **The sim ignites the J-2s here at full thrust.** |
| S-II aft interstage jettison | 192.3 | TL | H | |
| LET jettison | 197.9 | TL, AFJ | M-H | |
| S-II CECO | 460.62 | AP, TL | H | 460.75 in the statistical tables; 462 in the AFJ. |
| S-II EMR shift (high → low) | 491 | DLR citing FER Fig. 6-3 | L-M | Chosen over 502 s, which is the crew/MCC voice report and an upper bound. The FER says the shift was 9.5 s later than the final prediction. |
| S-II OECO | 548.22 | SUM, MR | H | Triggered by LOX low-level sensors, 0.55 s late (FER). |
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
| f1_gimbal_limit | ±5° (0.0873 rad), 5 °/s | | EH | M / L | Other sources give 5.25° and 6°. The centre engine is fixed. |
| j2_rated_emr5.5 | 1,023,091 N, Isp_vac 425 s, 245.474 kg/s | 230,000 lbf | NTRS 20100032986, J-2X heritage paper | H (thrust), M (Isp) | Chosen over 232,250 / 228,000 / 225,000 lbf. It reproduces 1.82 g at S-II CECO (§2.4). |
| j2_emr_range (PU valve) | 4.5 (full open) … 5.5 (closed) | | EH | M | |
| s_ii_low_emr | 4.7 | | TIS-501 | L | AS-506 value not found. EH's 4.3 lies below the PU hardware limit. With a 491 s shift, 4.7 closes the LOX budget (§2). |
| s_ivb_burn1_thrust | 901,223 N | 202,603 lbf | TDiA (presumably the FER, ESC+137 s) | M | EMR ≈ 5.0 (PU null). FER: +0.20% thrust and +0.05% Isp versus prediction. |
| j2_isp_vac_emr5.0 | 427 s | | Braeunig (via researcher) | L-M | Gives burn-1 consumption 31,665 kg, consistent with the Δv budget (§5). |
| s_ivb_tli_thrust | 894,364 N | 201,061 lbf | TDiA | M | M2 only. |
| j2_throat / area ratio | 0.37338 m / 27.5 | 14.7 in | SP-8120; Wikipedia, Purdue | H / H | The geometric exit area of 3.011 m² (Ø 1.958 m) is derived. The Wikipedia sea-level figures (486 kN, 200 s) are refuted. |
| j2_gimbal_limit (S-II outboard) | ±7° (0.1222 rad) | | EH | M | S-IVB range not found. |
| sps | 91,188.5 N, 314.5 s, MR 1.6, ε 62.5 | 20,500 lbf | Apollo press kits; Aerojet NTRS 20100027319; TN D-7375 | M | The 314.5 s comes from 100 psia tests, where thrust was 21,500–21,900 lbf, so the pair may not describe one operating point (±2%). |
| sm_rcs | 16 × 444.8 N | 100 lbf | Apollo-era sources | H | Isp not found (§3). |
| aps (S-IVB) | 2 modules × (3 × 667.2 N attitude + 1 × 320.3 N ullage) | 150 / 72 lbf | NASM, Wikipedia, collectSPACE | H | Isp not found. Loads per module of 150 lb N2O4 and 115 lb MMH (L) give O/F 1.30, which is suspect. |
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
| CA(M) / Cd(M), centre of pressure, CN_α | **none sourced** | — | — | Placeholder only, for the S-IC/S-II parts on 79.46 m², to be replaced: 0.30 (M ≤ 0.6), 0.45 (M 0.9), 0.60 (M 1.1–1.3), 0.45 (M 2), 0.35 (M 3), 0.28 (M ≥ 4). This is an unsourced engineering shape; tests must not depend on it. With today's constant-Cd model, use 0.45 on every 33 ft part, because `dragArea` takes the maximum over parts. |
| max Q | 35,200 Pa at 83.0 s, 13,567 m geodetic, V_rel 503.96 m/s | SP-4029 | H | US-1976 gives about 30,970 Pa at that state; the real July Cape atmosphere was about 14% denser (verifier). |
| pad (LC-39A) | geocentric latitude 28.4470° N, longitude 80.6041° W; r = 6,373.355 km | AP; Fischer-1960 radius derived | H / M | Place the sim pad at **geocentric** 28.447° so that Earth-rotation speed and inclination geometry match. |
| liftoff inertial velocity | 408.64 m/s (1,340.7 ft/s), heading 90° | AP | H | This is Earth rotation. The sim sphere gives 408.94 m/s. |
| flight azimuth | 72.058° | **recalled** (AFJ / SP-4029) | L | Unverified this run. Test inclination rather than azimuth. |

### 1.7 Where verifiers disagreed with researchers (or flagged an issue): decisions

1. **Ignition mass.** Chose GIW 6,477,875 lb over the FER-OCR 6,484,282 lbm, following the verifier's reasoning that the FER figure is a predicted column.
2. **"Total inertial acceleration".** Treated as sensed acceleration, as the verifier argued. §2.4 confirms it independently: the sim mass model gives 1.822 g at S-II CECO against the published 1.82 g.
3. **Liftoff 1.07 g.** Rejected as a thrust/mass target. Free-flight T/m is about 1.20 g; the 1.07 g reading is probably distorted by the controlled-release restraint.
4. **F-1 flight thrust.** Adopted the flight-matched flow (§3), which is +2.2% over rated. The verifier showed that 3.94 g implies about 1.79 Mlbf per engine. Rejected 9.18 Mlbf.
5. **Nozzle exits.** Refuted the 12.2 ft F-1 exit and the Wikipedia J-2 sea-level thrust and Isp; chose areas derived from thrust and geometry.
6. **J-2 per-engine basis.** Chose 230,000 lbf; the 1,161,250 lbf S-II total (5 × 232,250) is dropped.
7. **S-II EMR.** Downgraded the "5.5 s PU activation" from H to L (it is an AS-501 document). Chose low EMR 4.7 over 4.3 (below the hardware limit) and the shift at 491 s over 502 s.
8. **Spacecraft total.** Relabelled "at ground ignition"; it is identical at liftoff. Read 100,756 lb as post-LES and including the SLA (verifier), hence LES = 8,890 lb. The CM value of 12,250 lb may be the predicted figure (verifier). Chose SM 51,243 lb over MOR's 51,160 lb because CSM = 28,800 kg matches the recalled as-flown CSM mass. The LM is set by closure.
9. **Interstage bookkeeping.** The verifier showed the researcher's labels were self-contradictory. Chose "each upper-stage length includes the interstage below it", with the S-II/S-IVB separation plane at STA 2746.5 (recalled, L). The OWS-based alternative is kept in §6.
10. **Solid-motor propellant.** S-IC retro 278 lb and S-IVB ullage 58.7 lb (verifier impulse checks). LES escape-motor thrust, burn time and propellant are mutually inconsistent (Isp ≈ 100 s). This is not needed for a nominal flight.
11. **FER insertion mass.** 135,669 kg is kept only as a ±1% cross-check. The propellant budget gives 135,095 kg.
12. **Rejected timeline entries.** SP-4029's 91.5 s S-IC CECO and 269.1 s S-II CECO entries, the "Mach 1 at 31.1 s" layout error, and "tower jettison 192.3 s" are all rejected.

---

## 2. Mass accounting for the sim

### 2.1 Parts

Mass in kg, with lb in brackets. "Usable" means consumed between the sim ignition and the cutoff.

| part | dry_sim (what it contains) | usable oxidizer | usable fuel | part total at ignition |
|---|---|---|---|---|
| **S-IC** | **164,884.5** (363,508): dry 287,531 + LOX on board at OECO 39,772 + RP-1 at OECO 30,763 + other 5,442 | LOX **1,481,439.0** (3,266,014) | RP-1 **632,364.9** (1,394,126) | 2,278,688.4 (5,023,648) |
| **S-IC/S-II interstage** | **5,205.9** (11,477), including 4 ullage motors. Optional split: 4,596.3 structure + 609.6 solid propellant | — | — | 5,205.9 |
| **S-II + S-II/S-IVB interstage** | **44,599.6** (98,325): dry 79,714 + other 1,260 + aft interstage 8,076 (with the S-II retros) + LOX not consumed 2,214 + LH2 not consumed 7,061 | LOX **370,510.5** (816,836) | LH2 **68,517.3** (151,055) | 483,627.4 (1,066,216) |
| **S-IVB** | **16,255.6** (35,837): dry 24,852 + other 1,656 (APS propellant, He, ullage-motor propellant) + LOX 4,229 + LH2 5,100 not consumed by burn 1 or TLI (boost and orbital venting, residuals) | LOX **85,397.0** (188,268) = burn 1 26,387.7 + TLI 59,009.3 | LH2 **17,466.7** (38,508) = burn 1 5,277.5 + TLI 12,189.2 | 119,119.3 (262,613) |
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
| S-IVB APS attitude × 6 | coast attitude, burn roll | 667.2 | — | ≈ 290 (placeholder) | — | 0.2346 | — | | | thrust H, Isp L |
| S-IVB APS ullage × 2 | restart ullage (M2) | 320.3 | — | ≈ 290 (placeholder) | — | 0.1126 | — | | | thrust H, Isp L |

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

**Datum derivation.** The S-IC is 138 ft = 1,656 in long and ends at the separation plane, STA 1541 (recalled from MSFC-MAN-503), so the base is at STA −115. The recalled F-1 gimbal at STA 100 then sits 215 in (17.9 ft) above the nozzle exit, consistent with a 19 ft engine. The LES tip at 363 ft is Xa ≈ 1485. Vehicle station = Xa + 2756 follows from SLA base Xa 502 = IU top STA 3258 (recalled).

**Interfaces**

| feature | station | h (m) | conf |
|---|---|---|---|
| F-1 nozzle-exit plane = vehicle base | STA −115 | 0.000 | L-M |
| F-1 gimbal plane; S-IC body (thrust-structure) aft end | STA 100 | 5.461 | L |
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
| F-1 outboard × 4 (±5°) | 5.461 | 0.000 | 4.623 (182 in) | 3.556 | L (radius from fan wiki). Azimuth relative to the pitch plane unknown; use a symmetric layout. The 20.6 s outboard cant (≈ 2°, L) costs 0.06% of thrust and can be ignored. |
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
| S-IC OECO (161.63) | V_inertial; r; γ_inertial | 2,764.1 m/s; 6,439.33 km; 19.11° | ±40 m/s; ±2.5 km; ±1.5° | Drag (placeholder Cd), pitch program, +1.7% early thrust. |
| S-IC/S-II separation (162.30) | V_inertial | 2,773.9 m/s | sim expected ≈ 2,762 m/s; ±40 | No tail-off in the sim: −11.9 m/s is expected. |
| S-II CECO (460.62) | V_inertial; r; γ | 5,707.5 m/s; 6,552.65 km; 0.897° | ±50 m/s; ±3 km; ±0.5° | Guidance. |
| S-II OECO (548.22) | V_inertial; r; γ | 6,916.2 m/s; 6,559.55 km; 0.619° | ±50 m/s; ±3 km; ±0.5° | Guidance; the published value is 22.8 m/s below the AS-506 nominal. |
| insertion (709.33) | V_inertial; r; γ | 7,793.1 m/s; 6,563.05 km; 0.012° | ±3 m/s; ±1.5 km; ±0.05° | Guidance closes the loop. The table's altitude noise is about 0.05 n mi. |
| parking orbit | a; e; r_apo / r_peri; i; period | 6,562.87 km; 0.00021; 6,564.26 / 6,561.49 km (the published 100.4 / 98.9 n mi; sim altitudes 186.12 / 183.35 km); 32.521°; 88.186 min (5,291.2 s) | ±2 km; e ≤ 0.001; ±2 km; ±0.05°; ±6 s | Pad at geocentric 28.447°; the J2/μ model shifts the period by about 0.5 s. |

---

## 6. Remaining conflicts, gaps, and values tests must not depend on

**Unresolved conflicts**

- **S-II/S-IVB separation-plane station.** STA 2746.5 (recalled; aft interstage 5.78 m) versus about 2646 (Skylab OWS ≈ 48 ft lead). Which stage length contains the aft interstage is not documented in the inputs.
- **S-II EMR shift and low EMR.** (491 s, 4.7) versus (502 s, ≈ 4.55); AS-501's 4.7, EH's 4.3 and the 4.5 hardware limit.
- **F-1 liftoff thrust.** 7,648,000 versus 7,552,000 lbf (bases unknown). The 9,180,000 / 9,088,419 lbf "max" figures are physically implausible for this engine model.
- **First-engine ignition.** −6.4 versus −6.1 s. All-engines-running at −1.6 versus −1.92 s.
- **Spacecraft breakdown.** CM predicted versus as-flown, SM 51,243 versus 51,160, LM 33,218 (by closure) versus 33,200, SLA predicted only.
- **LES escape motor.** 147,000 versus 155,000 lbf; propellant 4,700 lb against the burn time.
- **Other figures.** SPS thrust/Isp pair; APS loads (O/F 1.30); R-4D Isp; S-IVB ullage thrust 3,390–3,460 lbf; S-IC retro 0.6–0.667 s.
- **S-IVB acceleration at cutoff.** 0.69 g against T/m of 0.680 g. FER insertion mass 135,669 kg against the 135,095 kg budget.

**Gaps (next research turn, highest value first)**

1. SP-4029 Propellant Usage, S-II and S-IVB rows: consumption, at-cutoff amounts, mixture ratio. These would replace the §2.2 S-II and S-IVB model loads.
2. FER mass characteristics: the flight-sequence mass summary (masses at CECO, OECO, S-II ignition, jettisons, S-IVB ignition and cutoff), CG and inertias, and the event table (EMR shift, tilt arrest).
3. As-flown liftoff mass, or the ignition-to-release consumption. The sim's −2.625 s ignition depends on the predicted 85,745 lb.
4. MSFC-MAN-503 station diagram: datum, S-IVB separation plane, tank stations, gimbal planes, nozzle protrusions, fin span.
5. Saturn V aerodynamics: CA(M) with its reference area, centre of pressure, CN_α.
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
- The placeholder Cd(M), and the max-Q value (atmosphere-dependent).
- F-1 outboard radius, azimuth and cant.
- Flight azimuth 72.058° (recalled).
- Solid-motor propellant masses.

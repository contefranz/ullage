import Foundation

/// Apollo 11's launch vehicle and spacecraft, AS-506, as published. Every value
/// is in its source's unit (lb, lbf, in, ft, s) with its source on the line;
/// `VesselLibrary.saturnV` converts them once. Values were reconciled in the
/// M1 datasheet, docs/AS506-datasheet.md (2026-10-15), from:
///
/// - SP-4029 (Apollo by the Numbers): Ground Ignition Weights, Launch Vehicle
///   Propellant Usage (S-IC rows), Apollo 11 Timeline, Ascent Phase, Summary.
/// - Mission Operations Report M-932-69-11, Table 3 (pre-flight predictions).
/// - AS-506 and AS-501 Technical Information Summaries (pre-flight).
/// - Apollo 11 Mission Report MSC-00171; Apollo Flight Journal.
/// - Betts, NTRS 20140011656 (F-1 ratings); NTRS 20100032986 (J-2 heritage);
///   NASA SP-8120 (J-2 throat); enginehistory.org; This Day in Aviation;
///   Braeunig; DLR "Apollo 11 Reloaded"; Saturn V News Reference; Apollo 11
///   press kit.
/// - Gimbals and the S-IVB APS (datasheet §7, 2026-10-16): enginehistory.org
///   RPE pages 8.10-8.30 (EH); Haynes Saturn V manual; Project Apollo
///   Coordinate System Standards (CSS); Coates and Donald, SA-501 S-IVB APS
///   flight anomalies, NTRS 19690016846 (APS-TN); AS-507 Flight Evaluation
///   Report (FER-507); AS-201 flight results; National Air and Space Museum.
///
/// Confidence as graded by the datasheet: (H) high, (M) medium, (L) low.
/// "Derived" is arithmetic on published values, "estimate" is the datasheet's
/// own estimate, "recalled" was not checked against the source.
enum AS506 {
    // MARK: Units and frames

    static let inch = 0.0254                 // m
    static let foot = 0.3048                 // m
    static let pound = 0.45359237            // kg
    static let poundForce = 4.4482216152605  // N
    static let degree = Double.pi / 180      // rad

    /// Construction x (m) of Saturn V vehicle station `sta` (in). The
    /// construction frame of `VesselLibrary.saturnV` is the station frame in metres.
    static func station(_ sta: Double) -> Double { sta * inch }

    /// Apollo spacecraft stations convert as STA = Xa + 2756 in. Derived from
    /// SLA base Xa 502 = IU top STA 3258, both recalled (L).
    static let apolloStationOffset = 2_756.0
    static func apolloStation(_ xa: Double) -> Double { station(xa + apolloStationOffset) }

    /// Station of the F-1 nozzle-exit plane, the vehicle base: derived from the
    /// 138 ft S-IC ending at STA 1541 (L-M).
    static let baseStation = -115.0
    /// Construction x (m) of a datasheet height `h` (m above the base).
    static func height(_ h: Double) -> Double { h + station(baseStation) }

    // MARK: Launch site

    /// LC-39A at its geocentric latitude, where the datasheet puts the pad on
    /// the spherical sim Earth so that the Earth-rotation speed and the
    /// inclination for a given azimuth match (the geodetic 28.608° gives about
    /// 0.13° more inclination at 72°). Its parking-orbit targets assume this pad.
    static let padLatitude = 28.4470               // deg, geocentric; SP-4029 Ascent Phase (H)
    static let padLongitude = -80.6041             // deg; SP-4029 Ascent Phase (H)

    // MARK: Timeline (range time, s, from 1969-07-16 13:32:00 UTC)

    /// Hold-down release. Simulation time 0 of `saturnV()` is this instant.
    static let firstMotion = 0.30              // SP-4029 Apollo 11 Timeline; Boeing D5-15560-6 (H)
    static let sICCenterCutoff = 135.20        // SP-4029 Apollo 11 Timeline and Ascent Phase (H)
    static let sICOutboardCutoff = 161.63      // SP-4029 Apollo 11 Summary; Mission Report (H). LOX depletion
    static let sICSeparation = 162.30          // SP-4029 Apollo 11 Ascent Phase (H)
    /// Burn reference start, about mainstage; the model lights the J-2s here at
    /// full thrust (the start command was at 163.04 s).
    static let sIIIgnition = 164.00            // SP-4029 Propellant Usage and Ascent Phase durations (M)
    static let interstageJettison = 192.3      // SP-4029 Apollo 11 Timeline (H)
    static let lesJettison = 197.9             // SP-4029 Apollo 11 Timeline; Apollo Flight Journal (M-H)
    static let sIICenterCutoff = 460.62        // SP-4029 Apollo 11 Ascent Phase and Timeline (H)
    /// High to low EMR. With `sIILowMixtureRatio` it is one tuning knob that
    /// puts the S-II LOX depletion at 548.22 s (502 s with EMR ≈ 4.55 also
    /// fits). Source: DLR "Apollo 11 Reloaded", citing the Flight Evaluation
    /// Report Fig. 6-3 (L-M).
    static let sIIMixtureRatioShift = 491.0
    static let sIIOutboardCutoff = 548.22      // SP-4029 Apollo 11 Summary; Mission Report (H). LOX depletion
    static let sIISeparation = 549.00          // SP-4029 Apollo 11 Ascent Phase (H)
    static let sIVBIgnition = 552.20           // Mission Report; SP-4029 Propellant Usage (H)
    static let sIVBCutoff = 699.33             // SP-4029 Apollo 11 Summary (H). Guidance cutoff

    // MARK: IU flight program (datasheet §8)
    //
    // AS-506's own flight sequence comes from its Flight Evaluation Report,
    // MPR-SAT-FE-69-9 (FER): Table 2-1 (time bases) and Table 2-2 (event
    // times, actual and from the time base, H). The guidance presettings it
    // does not give (the pitch polynomial, the tower-clearance yaw command,
    // the program-start test) are SA-504's, from Boeing D5-15706-4, "Saturn V
    // Launch Vehicle Guidance Equations, SA-504" (15 July 1967; GE504),
    // standing in for AS-506 until its own are found (M as a proxy).

    /// Guidance reference release: the ST-124 platform goes inertial, fixing
    /// the space-fixed frame (launch vertical, flight azimuth).
    static let guidanceReferenceRelease = -16.97 // range time; FER Table 2-1 (T1 - 17.6, Table 2-2) (H)
    /// Umbilical disconnect: the liftoff signal that starts time base 1.
    static let liftoff = 0.63                  // FER Table 2-1 (H)
    /// Position I on the pad faces east; the roll program turns it to the
    /// flight azimuth (datasheet §7.1). GE504: initial roll command A_Z - 90°.
    static let padAzimuth = 90.0               // deg; Oikofuge; Popular Science (M)
    static let flightAzimuth = 72.058          // deg; SP-4029 ("rolled from a launch pad azimuth of 90°"), FER (H)
    /// Tower-clearance yaw, away from the tower: GE504 Table 4-II commands
    /// chi_Z = 1.25° from T1 + 1.0 s to T1 + 8.75 s, which at the 1°/s limit
    /// ends the manoeuvre at T1 + 10.0 s, the FER's prediction (actual T1 +
    /// 9.0, "accurate to a major computation cycle").
    static let towerYawOn = 1.0                // s from T1; FER Table 2-2 (H); GE504
    static let towerYawOff = 8.75              // s from T1; GE504 Table 4-II (M as AS-506 proxy)
    static let towerYawAngle = 1.25            // deg; GE504 Table 4-II (M as AS-506 proxy)
    /// The roll and pitch programs start once the vehicle has risen 137 m,
    /// with a 13.0 s time backup (GE504 §4.1.2, Table 5-I t_1). On AS-506
    /// they began at T1 + 12.6 s (FER Table 2-2; predicted T1 + 13.1).
    static let programStartRise = 137.0        // m; GE504 (M as AS-506 proxy)
    static let programStartBackup = 13.0       // s from T1; GE504 (M as AS-506 proxy)
    /// Guidance-command rate limit, each of pitch, yaw and roll: GE504 §2.1.2
    /// and Table 5-I (chi-dot XL, YL, ZL = 1.0 deg/s). The AS-506 roll, 17.94°
    /// from T1 + 12.6 s to T1 + 30.5 s (FER), is the limit flown.
    static let commandRateLimit = 1.0          // deg/s; GE504 (H for SA-504, M for AS-506)
    /// Pre-IGM pitch polynomial chi_Y = sum F_kn t^n, t in s from T1, on
    /// segments split at t_S1..3: SA-504's presettings (GE504 Table 5-I, read
    /// from the page images). The segments join to within 0.04°.
    static let pitchSegmentBoundaries = [35.0, 80.0, 115.0]   // s; GE504 t_S1, t_S2, t_S3
    static let pitchCoefficients: [[Double]] = [               // deg, deg/s, ..., deg/s^4; GE504 F_kn
        [3.19840, -0.544236, 0.0351605, -0.00116379, 0.0000113886],
        [-10.9607, 0.946620, -0.0294206, 0.000207717, -0.000000439036],
        [78.7826, -2.83749, 0.0289710, -0.000178363, 0.000000463029],
        [69.9191, -2.007490, 0.0105367, -0.0000233163, 0.0000000136702],
    ]
    /// Tilt arrest, s from T1: AS-506's at range 160.0 s (FER Table 2-2, T2 +
    /// 24.7 s; predicted T2 + 25.5). SA-504's preset was 153.0 s (GE504).
    static let tiltArrest = 160.0 - liftoff    // FER (H for the time, to a computation cycle)
    /// AS-506's own polynomial (its July operational trajectory) was not
    /// found. SA-504's, flown by this model, leaves the S-IC 1.6° steeper and
    /// 3.7 km higher at OECO than AS-506 flew; 3 % more tilt, fitted to the
    /// nearest 0.01 on AS-506's OECO flight-path angle (19.114°, FER Table
    /// 4-2), brings OECO to within 0.1°, and CECO's angle, altitude and
    /// velocity, OECO's altitude and velocity, and both headings, which are
    /// not fitted, within the datasheet's tolerances (datasheet §8).
    static let pitchScale = 1.03               // fitted (see above)
    static var tiltProgram: TiltProgram {
        TiltProgram(boundaries: pitchSegmentBoundaries,
                    coefficients: pitchCoefficients.map { $0.map { $0 * pitchScale } }, arrest: tiltArrest)
    }
    /// Outboard F-1 cant at T1 + 20.0 s (FER Table 2-2, H), about 2° radially
    /// (EL, EH 8.13: M); the ramp rate was not found.
    static let cantOn = 20.0                   // s from T1; FER Table 2-2 (H)
    static let cantAngle = 2.0                 // deg radial; EL; EH 8.13 (M angle, L axis)
    static let cantRampRate = 0.2              // deg/s, PLACEHOLDER
    /// Flight control computer gains (a0 deg/deg, a1 s) by time from liftoff
    /// (S-IC) and from S-II ignition (S-II): TN D-5869 Table 3, "typical" (L for AS-506).
    static let sICGains: [(start: Double, a0: Double, a1: Double)] = [(0, 0.9, 0.69), (105, 0.45, 0.44),
                                                                       (130, 0.30, 0.32)]
    static let sIIGains: [(start: Double, a0: Double, a1: Double)] = [(0, 1.12, 1.9), (60, 0.65, 1.1),
                                                                       (190, 0.44, 0.74)]
    /// S-IC centre engine cutoff, commanded by the IU at T1 + 134.56 s (range
    /// 135.20, FER Table 2-2 and §5.1, H); the LVDC senses it and starts T2.
    static let sICCenterCutoffTime = 134.56    // s from T1; FER (H)
    /// From T3, S-IC outboard cutoff sensed: separation command, S-II engine
    /// solenoid activation (where the model lights the J-2s at full thrust;
    /// range 164.0), aft interstage and LET jettison, and S-II centre engine
    /// cutoff (FER Table 2-2, time from base, H).
    static let sICSeparationTime = 0.7         // s from T3; FER (H)
    static let sIIIgnitionTime = 2.4           // s from T3; FER (H)
    static let interstageJettisonTime = 30.7   // s from T3; FER (H)
    static let lesJettisonTime = 36.2          // s from T3; FER (H)
    static let sIICenterCutoffTime = 299.0     // s from T3; FER (H)
    /// The S-II mixture-ratio shift. On AS-506 the IU commanded it at ESC +
    /// 331.8 s (range 494.8) on reaching a preset characteristic velocity, and
    /// the engines reached the low EMR, 4.34 on average, at 498.0 s (FER §6.8
    /// and Table 2-2). The propulsion model shifts at `sIIMixtureRatioShift`
    /// to its 4.7 setting, which matches its 548.22 s depletion; the IU uses
    /// that time until the S-II model is recalibrated to the FER.
    static let sIIMixtureRatioShiftTime = sIIMixtureRatioShift - sICOutboardCutoff  // s from T3
    /// From T4, S-II outboard cutoff sensed: separation command and S-IVB
    /// ignition (STDV open, range 552.2; FER Table 2-2, H). The S-IVB velocity
    /// cutoff command came at 699.34 s, T4 + 151.1, and the LVDC sensed it
    /// and started T5 0.23 s later (FER); until IGM is modelled the IU cuts
    /// off at that time and senses it on the next step.
    static let sIISeparationTime = 0.8         // s from T4; FER (H)
    static let sIVBIgnitionTime = 4.0          // s from T4; FER (H)
    static let sIVBCutoffTime = 699.34 - sIIOutboardCutoff  // s from T4; FER (H)
    /// From T5, S-IVB cutoff sensed: APS ullage engines on and off (No. 1;
    /// No. 2 follows 0.1 s later), and the manoeuvre to the local horizontal
    /// (FER Table 2-2, H). T2, T3 and T4 also start on the LVDC sensing a
    /// cutoff: T2 at 135.27, 0.07 s after the centre engine's (FER Table 2-1).
    static let tb5UllageOn = 0.3               // s from T5; FER (H)
    static let tb5UllageOff = 87.0             // s from T5; FER (H)
    static let orbitalGuidanceStart = 19.8     // s from T5; FER "begin maneuver to local horizontal" (H)

    // MARK: Masses (lb)
    //
    // Tanks hold the main propellant aboard at first motion. Dry masses hold
    // everything else that leaves with the part, including pressurants, frost,
    // solid motors with their propellant, and all spacecraft propellants.

    static let groundIgnitionMass = 6_477_875.0  // SP-4029 Ground Ignition Weights (H): sum of the rows below
    /// Propellant used between S-IC ignition and first motion, taken from the
    /// S-IC tanks at `sICMixtureRatio`. No as-flown value was found.
    static let preReleaseConsumption = 85_745.0  // Mission Operations Report M-932-69-11, Table 3, predicted (L)

    /// S-IC stage: structure, fins and fairings, 5 F-1 (dry), 8 retro motors
    /// (whether their propellant is here or in `sICOther` is not stated).
    static let sICDry = 287_531.0                // SP-4029 Ground Ignition Weights (H)
    /// Not itemised: frost, GN2 and helium, lubricants.
    static let sICOther = 5_442.0                // SP-4029 Ground Ignition Weights (H)
    static let sICLOXLoad = 3_305_786.0          // SP-4029 Ground Ignition Weights and Propellant Usage (H)
    static let sICRP1Load = 1_424_889.0          // SP-4029 Ground Ignition Weights and Propellant Usage (H)
    /// Ignition to OECO. The meaning of the column was inferred (M).
    static let sICLOXConsumed = 3_266_014.0      // SP-4029 Propellant Usage (M)
    static let sICRP1Consumed = 1_394_126.0      // SP-4029 Propellant Usage, ignition to OECO (M)
    /// LOX on board at OECO, before tail-off: the unusable LOX, so LOX depletion
    /// ends the burn, as the low-level sensors did.
    static let sICLOXAtCutoff = 39_772.0         // SP-4029 Propellant Usage (M)
    /// RP-1 on board at OECO. Not used by the model: its RP-1 residual is an output.
    static let sICRP1AtCutoff = 30_763.0         // SP-4029 Propellant Usage (M)
    /// Stage consumption ratio LOX/RP-1, used as the F-1's engine-overall
    /// mixture ratio at the tanks (the rated inlet EMR is 2.27).
    static let sICMixtureRatio = 2.3427          // derived (M): 3,266,014 / 1,394,126 lb consumed, rounded
    static let sICLOXAtFirstMotion = sICLOXLoad - preReleaseConsumption * sICMixtureRatio / (1 + sICMixtureRatio)
    static let sICRP1AtFirstMotion = sICRP1Load - preReleaseConsumption / (1 + sICMixtureRatio)

    /// S-IC/S-II interstage with the 4 S-II ullage motors (their propellant,
    /// 4 x 336 lb, is booked here by inference).
    static let sICSIIInterstage = 11_477.0       // SP-4029 Ground Ignition Weights (H)

    /// S-II stage: structure, 5 J-2 (dry); both interstages excluded.
    static let sIIDry = 79_714.0                 // SP-4029 Ground Ignition Weights (H)
    /// Not itemised (pressurants, ...).
    static let sIIOther = 1_260.0                // SP-4029 Ground Ignition Weights (H)
    /// Loads at S-IC ignition; boil-off and venting before S-II ignition are not modelled.
    static let sIILOXLoad = 819_050.0            // SP-4029 Ground Ignition Weights (H)
    static let sIILH2Load = 158_116.0            // SP-4029 Ground Ignition Weights (H)
    /// LOX the engine model leaves at its 548.22 s depletion cutoff (residual,
    /// boil-off, GOX). The S-II LH2 residual is a model output.
    static let sIILOXUnusable = 2_214.0          // derived from the model (L)

    /// S-II/S-IVB (aft) interstage with the 4 S-II retro motors (cases and
    /// propellant; booking not stated). It leaves with the S-II.
    static let sIISIVBInterstage = 8_076.0       // SP-4029 Ground Ignition Weights (H)

    /// S-IVB stage: structure, aft skirt, J-2 (dry); aft interstage and IU excluded.
    static let sIVBDry = 24_852.0                // SP-4029 Ground Ignition Weights (H)
    /// Not itemised. It holds the APS propellant, which the builder moves into
    /// the APS tanks (2 x (`apsOxidizerLoad` + `apsFuelLoad`) = 657 lb); the
    /// other 999 lb are helium, the TX-280 ullage-motor propellant (117.4 lb),
    /// motor cases and the rest (datasheet §7.3).
    static let sIVBOther = 1_656.0               // SP-4029 Ground Ignition Weights (H)
    static let sIVBLOXLoad = 192_497.0           // SP-4029 Ground Ignition Weights (H)
    static let sIVBLH2Load = 43_608.0            // SP-4029 Ground Ignition Weights (H)
    /// Propellant not consumed by burn 1 and TLI (residuals plus boost and
    /// orbital venting), from the engine model. Venting is not modelled, so
    /// both overstate the residual. At EMR 5.0 the usable LOX lasts 476 s and
    /// the usable LH2 487 s; burn 1 ends on guidance after 147 s.
    static let sIVBLOXUnusable = 4_229.0         // derived from the model (L)
    static let sIVBLH2Unusable = 5_100.0         // derived from the model (L)

    static let iu = 4_275.0                      // SP-4029 Ground Ignition Weights (H)

    /// Spacecraft at ignition and liftoff: LES (with BPC), CM, SM, LM and SLA.
    /// Only this total is high confidence; the split below is not.
    static let spacecraft = 109_646.0            // SP-4029 Ground Ignition Weights (H)
    /// Tower; escape, jettison and pitch-control motors with propellant; boost
    /// protective cover. Derived: 109,646 lb less the 100,756 lb spacecraft
    /// after LES jettison (Wikipedia, recalled).
    static let les = 8_890.0                     // derived (L-M)
    /// Command module; whether crew and probe are included is not stated.
    static let cm = 12_250.0                     // recalled; equals the Mission Operations Report prediction (L)
    /// Service module, loaded: SPS propellant ≈ 40,600 lb and RCS ≈ 1,300 lb (recalled, L) included.
    static let sm = 51_243.0                     // recalled (L); Mission Operations Report predicted 51,160
    /// Lunar module, loaded, no crew: DPS, APS and RCS propellants included.
    /// The Mission Operations Report predicted 33,200 lb.
    static let lm = 33_218.0                     // derived by closure of `spacecraft` (L)
    /// Spacecraft-LM adapter with its 4 panels.
    static let sla = 4_045.0                     // Mission Operations Report M-932-69-11, predicted (L)

    // MARK: Engines

    // F-1 as rated: reference only (engine-data tests). The rated set is
    // self-consistent only to 0.24 %.
    static let f1RatedThrustSeaLevel = 1_522_000.0   // lbf, Betts, NTRS 20140011656 (H)
    static let f1RatedThrustVacuum = 1_748_200.0     // lbf, Betts (M)
    static let f1RatedIspSeaLevel = 265.4            // s, Betts (H)
    static let f1RatedIspVacuum = 304.1              // s, Betts (H)
    static let f1RatedMassFlow = 5_737.0             // lb/s, Betts (M)
    static let f1RatedMixtureRatio = 2.27            // Betts (H)
    /// Rated F-1 as a fixed nozzle whose exit area, (F_vac - F_sl) / p0 =
    /// 9.93 m^2 (derived), keeps the rated sea-level thrust; Isp_sl comes out at 264.8 s.
    static let f1Rated = EngineRating.fixedNozzle(
        name: "F-1 rated", thrustVacuum: f1RatedThrustVacuum * poundForce, ispVacuum: f1RatedIspVacuum,
        exitArea: (f1RatedThrustVacuum - f1RatedThrustSeaLevel) * poundForce / standardAtmosphere,
        mixtureRatio: f1RatedMixtureRatio)

    /// AS-506 flight-matched F-1, the one the vehicle uses (M). Its flow,
    /// 2,659.39 kg/s (+2.2 % over rated), consumes `sICLOXConsumed` +
    /// `sICRP1Consumed` over the burn's 794.845 engine-seconds: 5 engines from
    /// an equivalent full-flow start at -2.625 s (which uses exactly
    /// `preReleaseConsumption` before first motion) to CECO, then 4 to OECO.
    static let f1ThrustVacuum = 7_930_844.0          // N, derived: 2,659.39 kg/s x 304.1 s x g0
    /// Effective exit area that keeps the rated 265.4 s sea-level Isp.
    static let f1ExitArea = 9.96                     // m^2, derived (M); equivalent diameter 3.56 m
    static let f1 = EngineRating.fixedNozzle(name: "F-1 (AS-506 flight-matched)", thrustVacuum: f1ThrustVacuum,
                                             ispVacuum: f1RatedIspVacuum, exitArea: f1ExitArea,
                                             mixtureRatio: sICMixtureRatio)
    /// Outboard engines only, each with a pitch-plane and a yaw-plane actuator
    /// (square pattern); the centre engine is fixed. Single secondary source.
    /// It is the control limit: the actuator stop (5.25°) and the bearing
    /// envelope (6°) lie outside it (datasheet §7.1).
    static let f1GimbalRange = 5.0                   // deg per actuator, control limit, EH 8.13 (L)
    static let f1GimbalRate = 5.0                    // deg/s, EH 8.13 (L); loaded or no-load not stated

    // J-2: one nozzle for every setting, with the geometric exit area 3.011 m^2.
    static let j2ThroatDiameter = 14.7               // in, NASA SP-8120 (H)
    static let j2AreaRatio = 27.5                    // Wikipedia; Purdue (H)
    static let j2ExitArea = Double.pi / 4 * (j2ThroatDiameter * inch) * (j2ThroatDiameter * inch) * j2AreaRatio

    /// S-II ignition setting (PU valve closed). Chosen over the published 232,250,
    /// 228,000 and 225,000 lbf because it reproduces 1.82 g at S-II CECO.
    static let sIIJ2ThrustVacuum = 230_000.0         // lbf, NTRS 20100032986 (H)
    static let sIIJ2IspVacuum = 425.0                // s, NTRS 20100032986 (M)
    static let sIIHighMixtureRatio = 5.5             // enginehistory.org (M)
    static let sIIJ2 = EngineRating.fixedNozzle(name: "J-2 EMR 5.5", thrustVacuum: sIIJ2ThrustVacuum * poundForce,
                                                ispVacuum: sIIJ2IspVacuum, exitArea: j2ExitArea,
                                                mixtureRatio: sIIHighMixtureRatio)

    /// S-IVB burn 1 (PU null). Thrust is the flight value, below the S-II's
    /// only because of the lower EMR.
    static let sIVBJ2ThrustVacuum = 202_603.0        // lbf, This Day in Aviation, from the Flight Evaluation Report (M)
    static let sIVBJ2IspVacuum = 427.0               // s, Braeunig (L-M)
    static let sIVBMixtureRatio = 5.0                // PU null (M)
    static let sIVBJ2Burn1 = EngineRating.fixedNozzle(name: "J-2 EMR 5.0",
                                                      thrustVacuum: sIVBJ2ThrustVacuum * poundForce,
                                                      ispVacuum: sIVBJ2IspVacuum, exitArea: j2ExitArea,
                                                      mixtureRatio: sIVBMixtureRatio)

    /// S-II after the EMR shift (L). The AS-506 value was not found; 4.7 is
    /// AS-501's. Thrust is linear in EMR through the two settings above
    /// (186,165 lbf) and Isp gains 4 s per unit of EMR decrease (428.2 s).
    /// For the IU item to assign at `sIIMixtureRatioShift`; the builder does not use it.
    static let sIILowMixtureRatio = 4.7              // AS-501 Technical Information Summary (L)
    static let sIIJ2LowEMR = EngineRating.fixedNozzle(
        name: "J-2 EMR 4.7",
        thrustVacuum: (sIVBJ2ThrustVacuum + (sIILowMixtureRatio - sIVBMixtureRatio)
                       * (sIIJ2ThrustVacuum - sIVBJ2ThrustVacuum) / (sIIHighMixtureRatio - sIVBMixtureRatio))
                      * poundForce,
        ispVacuum: sIIJ2IspVacuum + 4 * (sIIHighMixtureRatio - sIILowMixtureRatio), exitArea: j2ExitArea,
        mixtureRatio: sIILowMixtureRatio)
    /// Outboard J-2s only, pitch-plane and yaw-plane actuators like the F-1's.
    static let sIIJ2GimbalRange = 7.0                // deg per actuator, EH 8.20 (M)
    static let sIIJ2GimbalRate = 8.0                 // deg/s, EH 8.20 (M-L)
    static let sIVBJ2GimbalRange = 7.0               // deg per actuator, "7.0° square pattern", EH 8.30; Haynes (M)
    /// Not found: the S-II value as a placeholder, not data.
    static let sIVBJ2GimbalRate = 8.0                // deg/s, PLACEHOLDER

    // MARK: Geometry
    //
    // Stations (in) and heights (m above the base) from the M1 datasheet's §4,
    // mostly recalled from the Saturn V Flight Manual MSFC-MAN-503 and the
    // Saturn V News Reference: low confidence unless marked.

    static let sICTop = 1_541.0                      // STA, S-IC/S-II separation plane (M-L)
    static let sIIAftSkirt = 1_760.0                 // STA, second plane: interstage top (L)
    static let sIITop = 2_519.0                      // STA, S-II forward skirt top (L-M)
    /// S-II/S-IVB separation plane, recalled (L); an alternative reading puts it near STA 2646.
    static let sIVBAftSkirt = 2_746.5                // STA (L)
    static let sIVBTop = 3_222.0                     // STA, S-IVB/IU (L-M)
    static let iuTop = 3_258.0                       // STA, IU/SLA = Xa 502 (M-L)
    static let slaTop = 838.0                        // Xa, SLA top = SM aft bulkhead (L)
    static let smTop = 1_010.0                       // Xa, SM/CM (L)
    static let cmApex = 1_137.0                      // Xa (L)
    static let overallHeight = 363.0                 // ft, base to LES tip, Apollo 11 press kit (M)
    static let lesLength = 33.0                      // ft, Apollo 11 press kit, recalled (L); the BPC overlaps the CM

    static let bodyDiameter = 396.0                  // in (33 ft): S-IC, S-II, interstages; Saturn V News Reference (M)
    static let sIVBDiameter = 260.0                  // in: S-IVB, IU, SLA base; Saturn V News Reference (M)
    static let csmDiameter = 154.0                   // in: SLA top, SM, CM; press kit (M)
    static let cmApexDiameter = 0.8                  // m, estimate (L)
    static let lesRadius = 0.5                       // m, estimate (L): tower and motor ≈ 0.66 m across

    /// F-1 gimbal plane, the aft end of the S-IC thrust structure.
    static let f1GimbalStation = 100.0               // STA, Project Apollo Coordinate System Standards (M)
    static let f1OutboardRadius = 182.0              // in, fan wiki only (L); the bells sit under the fairings
    static let sIIJ2GimbalHeight = 48.4              // m, estimate ±1 m (L)
    static let sIIJ2ExitHeight = 45.0                // m, estimate ±1 m (L)
    static let sIIOutboardCircle = 17.5              // ft, diameter of the outboard J-2 circle, enginehistory.org (M)
    /// About 1 m below the S-IVB part's own aft end (`sIVBAftSkirt`, h 72.68),
    /// as is the LOX extent's aft apex (72.5): the estimates disagree within
    /// their ±1 m, and the alternative separation plane (STA ≈ 2646, h 70.15)
    /// would resolve it. Still unresolved: the J-2's lever arm runs from this
    /// point, and ±1 m changes its pitch and yaw authority by about ±11 %.
    static let sIVBJ2GimbalHeight = 71.7             // m, estimate ±1 m (L)
    static let sIVBJ2ExitHeight = 68.3               // m, estimate ±1 m (L)

    /// LM stowed in the SLA: stowed geometry was not found.
    static let lmBottomHeight = 85.9                 // m, estimate (L)
    static let lmTopHeight = 90.9                    // m, estimate (L): clears the SPS exit at ≈ 91.08
    static let lmRadius = 2.1                        // m, estimate (L)

    /// Dry CoM of the S-IC (the engines dominate it). No other dry CG was found.
    static let sICDryCoMHeight = 14.0                // m, estimate (L)

    // Propellant extents, m above the base (aft and forward dome apexes, or
    // the common-bulkhead rim for the S-II LH2): estimates from the loads and
    // diameters with assumed domes, ±1.5 m (L). The model puts each load's
    // centroid at the middle of its extent.
    static let sICRP1Extent = (aft: 8.1, forward: 19.8)
    static let sICLOXExtent = (aft: 21.3, forward: 40.5)
    static let sIILOXExtent = (aft: 47.9, forward: 54.2)
    static let sIILH2Extent = (aft: 51.1, forward: 66.7)
    static let sIVBLOXExtent = (aft: 72.5, forward: 76.5)
    static let sIVBLH2Extent = (aft: 76.5, forward: 84.0)

    // Nominal liquid densities, kg/m^3 (they only set the column heights).
    static let loxDensity = 1_141.0
    static let rp1Density = 820.0
    static let lh2Density = 70.8

    // MARK: Aerodynamics

    /// Constant drag coefficient on the 33 ft parts, a placeholder: no Saturn V
    /// drag data was sourced. Tests must not depend on it.
    static let bodyDragCoefficient = 0.45

    // MARK: S-IVB Auxiliary Propulsion System (datasheet §7.3)

    /// Two self-contained modules on the aft skirt, 180° apart, at Positions I
    /// (+z) and III (-z): inferred from the engine roles, which only work with
    /// the modules in the pitch plane (L).
    static let apsModuleHeight = 73.4                // m above the base, estimate (L)
    static let apsModuleRadius = 3.5                 // m, nozzle radius, estimate (L)
    /// Three TR-204 attitude engines per module: one pitch, two roll/yaw.
    static let apsAttitudeThrust = 147.0             // lbf, "operate at" (150 nominal), APS-TN (M)
    /// Effective Isp with pulse losses: the sim's pulses run at full thrust.
    static let apsAttitudeIsp = 245.0                // s, AS-201 flight averages 237 and 250 s (L)
    /// One SE-7-1 ullage engine per module, thrust along +x.
    static let apsUllageThrust = 72.0                // lbf, "operated at" (70 nominal), APS-TN; NASM (H)
    static let apsUllageIsp = 290.0                  // s, PLACEHOLDER (not found)
    /// Per module: the AS-507 loads at liftoff (AS-506 not found) split
    /// equally between the modules. They leave `sIVBOther`, so the S-IVB part
    /// total is unchanged.
    static let apsOxidizerLoad = 202.5               // lb N2O4, FER-507 405 lb / 2 (M as a proxy; split L)
    static let apsFuelLoad = 126.0                   // lb MMH, FER-507 252 lb / 2 (M as a proxy; split L)
    /// Feed mixture ratio: the load ratio, 1.607, so both tanks empty together
    /// (the engines' operating ratio was not found).
    static let apsMixtureRatio = apsOxidizerLoad / apsFuelLoad   // derived (M): FER-507 load ratio 405 / 252 lb = 1.607

    /// APS control logic (datasheet §7.2): an attitude dead band on each
    /// axis, error limits that bound the manoeuvre rate, a rate term and a
    /// minimum pulse.
    static let apsDeadband = 1.0                     // deg each axis (2° effective band), EH 8.30; ASTP SA-210 (M)
    static let apsErrorLimitPitchYaw = 2.5           // deg, EH 8.30 (M)
    static let apsErrorLimitRoll = 3.5               // deg, EH 8.30 (M)
    /// Switching line e - K w: PLACEHOLDER (not found). With the limits it
    /// gives manoeuvre rates of about 0.3°/s in pitch and yaw, 0.5°/s in roll.
    static let apsRateGain = 5.0                     // s, PLACEHOLDER
    /// Minimum on-time at full thrust: the 7.5 lbf s minimum impulse bit
    /// (APS-TN, M-H) is 51 ms at 147 lbf; three 0.02 s steps give 39.2 N s.
    static let apsMinimumOnTime = 0.06               // s, derived
    static var apsLaw: PhasePlaneLaw {
        PhasePlaneLaw(deadband: apsDeadband * degree,
                      errorLimit: Vec3(apsErrorLimitRoll, apsErrorLimitPitchYaw, apsErrorLimitPitchYaw) * degree,
                      rateGain: apsRateGain, minimumOnTime: apsMinimumOnTime)
    }
}

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
    /// High to low EMR: the IU's command on a characteristic-velocity
    /// criterion (IGM phase 2) at 494.8 s, the switch selector at 496.0 s,
    /// the PU valve step at 497.60 s and the low EMR reached by 498.0 s (FER
    /// Tables 2-2, 2-3, 6-2). 9.5 s later than the final prediction.
    static let sIIMixtureRatioShiftCommand = 494.8   // FER Table 2-2 (H)
    static let sIIMixtureRatioShift = 497.60         // FER Table 6-2, "PU valve step" (H)
    static let sIIOutboardCutoff = 548.22      // SP-4029 Apollo 11 Summary; Mission Report (H). LOX depletion
    static let sIISeparation = 549.00          // SP-4029 Apollo 11 Ascent Phase (H)
    static let sIVBIgnition = 552.20           // Mission Report; SP-4029 Propellant Usage (H)
    static let sIVBCutoff = 699.33             // SP-4029 Apollo 11 Summary (H). Guidance cutoff

    // MARK: IU flight program (datasheet §8)
    //
    // AS-506's own flight sequence comes from its Flight Evaluation Report,
    // MPR-SAT-FE-69-9 (FER): Table 2-1 (time bases) and Table 2-2 (event
    // times, actual and from the time base, H), and from its flight manual,
    // MSFC-MAN-506 (MAN506): Figure 2-1 (predicted sequence, 16 July 1969
    // window, 72° azimuth) and Figure 2-2 (commanded pitch). The guidance
    // presettings neither gives (the pitch polynomial, the program-start
    // test) are SA-504's, from Boeing D5-15706-4, "Saturn V Launch Vehicle
    // Guidance Equations, SA-504" (15 July 1967; GE504), standing in for
    // AS-506's (M as a proxy).

    /// Guidance reference release: the ST-124 platform goes inertial, fixing
    /// the space-fixed frame (launch vertical, flight azimuth).
    static let guidanceReferenceRelease = -16.97 // range time; FER Table 2-1 (T1 - 17.6, Table 2-2) (H)
    /// Umbilical disconnect: the liftoff signal that starts time base 1.
    static let liftoff = 0.63                  // FER Table 2-1 (H)
    /// Position I on the pad faces east; the roll program turns it to the
    /// flight azimuth (datasheet §7.1). GE504: initial roll command A_Z - 90°.
    static let padAzimuth = 90.0               // deg; Oikofuge; Popular Science (M)
    static let flightAzimuth = 72.058          // deg; SP-4029 ("rolled from a launch pad azimuth of 90°"), FER (H)
    /// Tower-clearance yaw, away from the tower: "ramped to 1.25 degrees at
    /// the rate of 1.0 degrees per second starting at 1.39 seconds from first
    /// motion and ... ramped back to zero degrees 9 seconds later" (MAN506
    /// §2, Liftoff Clearance). GE504 Table 4-II commands the same chi_Z =
    /// 1.25° from T1 + 1.0 s to T1 + 8.75 s, so the manoeuvre ends at T1 +
    /// 10.0 s, the FER's prediction (actual T1 + 9.0, "accurate to a major
    /// computation cycle").
    static let towerYawOn = 1.0                // s from T1; FER Table 2-2; MAN506 (H)
    static let towerYawOff = 8.75              // s from T1; GE504 Table 4-II; MAN506 (H)
    static let towerYawAngle = 1.25            // deg; MAN506; GE504 (H)
    /// The roll and pitch programs start once the vehicle has risen 137 m,
    /// with a 13.0 s time backup (GE504 §4.1.2, Table 5-I t_1). On AS-506
    /// they began at T1 + 12.6 s (FER Table 2-2; predicted T1 + 13.1).
    static let programStartRise = 137.0        // m; GE504 (M as AS-506 proxy)
    static let programStartBackup = 13.0       // s from T1; GE504 (M as AS-506 proxy)
    /// Guidance-command rate limit, each of pitch, yaw and roll: GE504 §2.1.2
    /// and Table 5-I (chi-dot XL, YL, ZL = 1.0 deg/s). The AS-506 roll, 17.94°
    /// from T1 + 12.6 s to T1 + 30.5 s (FER), is the limit flown.
    static let commandRateLimit = 1.0          // deg/s; GE504 (H for SA-504, M for AS-506)
    /// From the S-IVB cutoff the LVDC limits the command rate to 0.4°/s in
    /// pitch and yaw and 0.6°/s in roll: IBM's Astrionics System Handbook
    /// (MSFC IV-4-401-1, changed 15 Nov 1969) §3.1 and Table 3.1-3, "Coast"
    /// (generic Saturn V: M). AS-506's pitch error grew at 0.33-0.37°/s at the start of the
    /// manoeuvre to the local horizontal (FER Figure 11-12, digitised), as
    /// this limit gives; SA-504's presettings had 1.0°/s (GE504).
    static let coastRateLimit = (roll: 0.6, pitch: 0.4, yaw: 0.4)   // deg/s; ASH (M)
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
    /// AS-506's commanded pitch (MAN506 Figure 2-2) follows SA-504's
    /// polynomial to within the figure's reading accuracy, about 1°: -20° a
    /// minute after first motion, -56° at two minutes and -67.5° at the
    /// arrest, against -20.6, -56.5 and -68.0°. Flown by this model, that
    /// program leaves the S-IC 1.3° steeper and 1.8 km higher at OECO than
    /// AS-506 flew, even with the S-IC's thrust, flow and masses matching the
    /// FER (datasheet §8.5). The IU here therefore tilts 2.5 % more: a
    /// compensation for the model, not AS-506 data, fitted to the nearest
    /// 0.005 on AS-506's OECO flight-path angle (19.114°, FER Table 4-2).
    /// CECO's angle, altitude and velocity, OECO's altitude and velocity, and
    /// both headings, which are not fitted, then fall within the datasheet's
    /// tolerances. (It was 3 % before the propulsion was recalibrated.)
    static let pitchScale = 1.025              // fitted model compensation (see above)
    static var tiltProgram: TiltProgram {
        TiltProgram(boundaries: pitchSegmentBoundaries,
                    coefficients: pitchCoefficients.map { $0.map { $0 * pitchScale } }, arrest: tiltArrest)
    }
    /// Outboard F-1 cant at T1 + 20.0 s (FER Table 2-2, H), about 2° radially
    /// (EL, EH 8.13: M); the ramp rate was not found.
    static let cantOn = 20.0                   // s from T1; FER Table 2-2 (H)
    static let cantAngle = 2.0                 // deg radial; EL; EH 8.13 (M angle, L axis)
    static let cantRampRate = 0.2              // deg/s, PLACEHOLDER
    /// Flight control computer gains (a0 deg/deg, a1 s): TN D-5869 Table 3,
    /// "typical" Saturn V values, read from the page image (L for AS-506).
    /// They switch at the IU's switch points: S-IC at T1 + 105.0 and 130.0 s,
    /// S-II at T3 + 61.4 and 191.4 s (SA-507 flight sequence ICD 40M33627B,
    /// also the AS-508 timeline; M for AS-506), the S-II's first band from its
    /// ignition.
    static let sICGains: [(start: Double, a0: Double, a1: Double)] = [(0, 0.9, 0.69), (105, 0.45, 0.44),
                                                                       (130, 0.32, 0.30)]   // s from T1
    static let sIIGains: [(start: Double, a0: Double, a1: Double)] = [(2.4, 1.12, 1.9), (61.4, 0.65, 1.1),
                                                                       (191.4, 0.44, 0.74)]   // s from T3
    /// Roll gains (a0, a1), the same in every band of a stage: Boeing
    /// D5-15481-1 (AS-504 reference trajectory, 1967) Table 3-IV, the only
    /// roll values found (L for AS-506). The S-IVB's single J-2 cannot roll:
    /// its APS does.
    static let sICRollGains = (a0: 0.245, a1: 0.15)    // D5-15481-1 (L)
    static let sIIRollGains = (a0: 0.25, a1: 0.20)     // D5-15481-1 (L)
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
    /// IGM phase 1 initiated (204.1 s range; FER Table 2-2). Not modelled yet:
    /// the IU logs it and holds the attitude of the tilt arrest.
    static let igmStartTime = 42.4             // s from T3; FER (H)
    static let sIICenterCutoffTime = 299.0     // s from T3; FER (H)
    /// FER's T3 (S-IC OECO sensed), the base of the S-II's sequence.
    static let timeBase3 = 161.66              // range time, FER Table 2-1 (H)
    /// S-II ullage motors lit, and their burn ended (thrust down to 75 %).
    static let sIIUllageIgnitionTime = 0.5     // s from T3; FER Table 2-2 (H)
    static let sIIUllageEndTime = 4.4          // s from T3; FER Table 2-2 (H)
    /// High EMR Select (S-II PU system activated): ESC + 5.5 s, 168.5 s.
    static let sIIHighMixtureRatioTime = 6.9   // s from T3; FER Table 2-2 and §6.5 (H)
    /// The EMR shift command (IGM phase 2, artificial tau) and the PU valve
    /// step that the model takes as the shift to low EMR. On AS-506 the IU
    /// commanded it on reaching a preset characteristic velocity (FER §6.5,
    /// §10.2.1); the model keeps the flight's times until IGM exists.
    static let sIIMixtureRatioShiftCommandTime = sIIMixtureRatioShiftCommand - timeBase3   // s from T3
    static let sIIMixtureRatioShiftTime = sIIMixtureRatioShift - timeBase3                 // s from T3
    /// From T4, S-II outboard cutoff sensed: separation command and S-IVB
    /// ignition (STDV open, range 552.2; FER Table 2-2, H). The S-IVB velocity
    /// cutoff command came at 699.34 s, T4 + 151.10 (T4 at 548.24, FER Table
    /// 2-1), and the LVDC sensed it and started T5 0.23 s later (FER); until
    /// IGM is modelled the IU cuts off that long after its own T4 and senses
    /// it on the next step.
    static let sIISeparationTime = 0.8         // s from T4; FER (H)
    static let sIVBIgnitionTime = 4.0          // s from T4; FER (H)
    static let sIVBCutoffTime = 699.34 - 548.24  // s from T4; FER Tables 2-1 and 2-2 (H)
    /// From T5, S-IVB cutoff sensed: APS ullage engines on and off (No. 1;
    /// No. 2 follows 0.1 s later), and the manoeuvre to the local horizontal
    /// (FER Table 2-2, H). T2, T3 and T4 also start on the LVDC sensing a
    /// cutoff: T2 at 135.27, 0.07 s after the centre engine's (FER Table 2-1).
    static let tb5UllageOn = 0.3               // s from T5; FER (H)
    static let tb5UllageOff = 87.0             // s from T5; FER (H)
    static let orbitalGuidanceStart = 19.8     // s from T5; FER "begin maneuver to local horizontal" (H)

    // MARK: Masses
    //
    // Ground-ignition masses are SP-4029's Ground Ignition Weights (lb), which
    // the FER's mass tables confirm to the pound. The rest are the FER's (kg):
    // its propellant tables (5-2, 6-2, 7-3) and its flight sequence mass
    // tables (20-1, 20-3, 20-5, 20-9), actual values (H).
    //
    // A tank holds the propellant aboard at first motion, and keeps the gas
    // made from it in flight (the S-IC's GOX and the S-II's GOX and GH2
    // pressurant, which stay in the ullage): what leaves a tank is what its
    // engines burned. Dry masses hold everything else that leaves with the
    // part: structure, the other gases, frost, solid motors with their
    // propellant, and all spacecraft propellants.

    static let groundIgnitionMass = 6_477_875.0  // lb, SP-4029 Ground Ignition Weights (H); FER Table 20-1: 2,938,315 kg
    /// Vehicle mass used between S-IC ignition (-6.4 s) and first motion:
    /// "S-IC thrust buildup" in FER Table 20-9 (predicted 38,893 kg). The
    /// model starts at first motion with the S-IC tanks at their FER loads.
    static let preReleaseMass = 39_307.0         // kg, FER Table 20-9 (H)
    static let firstMotionMass = 2_899_008.0     // kg, FER Tables 20-1 and 20-9 (H)

    /// S-IC stage: structure, fins and fairings, 5 F-1 (dry), 8 retro motors
    /// (whether their propellant is here or in `sICOther` is not stated).
    static let sICDry = 287_531.0                // lb, SP-4029 Ground Ignition Weights (H); FER 130,422 kg
    /// Not itemised: frost, GN2 and helium, lubricants.
    static let sICOther = 5_442.0                // lb, SP-4029 Ground Ignition Weights (H)
    static let sICLOXLoad = 3_305_786.0          // lb, SP-4029 Ground Ignition Weights; FER Table 5-2 (H)
    static let sICRP1Load = 1_424_889.0          // lb, SP-4029 Ground Ignition Weights; FER Table 5-2 (H)
    /// The S-IC stage at holddown release (first motion), and its tanks then:
    /// liquid LOX 1,468,594 kg (FER Table 5-2) and the 235 kg of GOX already
    /// in its ullage (Table 20-1); liquid RP-1 (Table 5-2). The rest of the
    /// stage is the part's dry mass.
    static let sICAtFirstMotion = 2_239_381.0    // kg, FER Table 20-1 (H)
    static let sICLOXAtFirstMotion = 1_468_594.0 + 235.0   // kg, FER Tables 5-2 and 20-1 (H)
    static let sICRP1AtFirstMotion = 637_830.0   // kg, FER Table 5-2 (H)
    /// LOX aboard at OECO, before tail-off: liquid 18,041 kg (Table 5-2) and
    /// GOX 3,611 kg (Table 20-1). It is the tank's unusable mass, so LOX
    /// depletion ends the burn, as the low-level sensors did.
    static let sICLOXAtCutoff = 18_041.0 + 3_611.0   // kg, FER Tables 5-2 and 20-1 (H)
    /// RP-1 aboard at OECO. Not set in the model, whose residual is an output
    /// (the mixture-ratio scale is fitted to it).
    static let sICRP1AtCutoff = 13_954.0         // kg, FER Table 5-2 (H)

    /// The S-IC/S-II interstage (11,477 lb, SP-4029) is three items (FER
    /// Tables 20-3 and 20-9): a small ring that leaves with the S-IC at
    /// first-plane separation, the large interstage jettisoned at 192.3 s,
    /// and the propellant of its four S-II ullage motors.
    static let sICSIIInterstage = 11_477.0       // lb, SP-4029 Ground Ignition Weights (H)
    static let sICSIIInterstageSmall = 614.0     // kg, FER Tables 20-3, 20-9 (H)
    static let sICSIIInterstageLarge = 3_982.0   // kg, FER Tables 20-3, 20-9 (H)
    static let sIIUllageMotorPropellant = 610.0  // kg, four motors, FER Tables 20-3, 20-9 (H)

    /// S-II stage: structure, 5 J-2 (dry); both interstages excluded.
    static let sIIDry = 79_714.0                 // SP-4029 Ground Ignition Weights (H)
    /// Not itemised (pressurants, ...).
    static let sIIOther = 1_260.0                // SP-4029 Ground Ignition Weights (H)
    /// Loads at S-IC ignition; boil-off and venting before S-II ignition are not modelled.
    static let sIILOXLoad = 819_050.0            // SP-4029 Ground Ignition Weights (H)
    static let sIILH2Load = 158_116.0            // SP-4029 Ground Ignition Weights (H)
    /// LOX aboard at OECO, before tail-off: liquid 1,603 kg (816 in the tank,
    /// 787 below it) and the 2,147 kg of GOX made in flight (2,335 at OECO
    /// less 188 at ignition), FER Table 20-3. The tank's unusable mass: LOX
    /// depletion ends the burn at 548.22 s.
    static let sIILOXAtCutoff = 816.0 + 787.0 + (2_335.0 - 188.0)   // kg, FER Table 20-3 (H)
    /// LH2 aboard at OECO: liquid 2,695 kg and 658 kg of GH2 made in flight
    /// (Table 20-3). Not set in the model, whose residual is an output (the
    /// high mixture ratio is fitted to it).
    static let sIILH2AtCutoff = 2_572.0 + 123.0 + (735.0 - 77.0)    // kg, FER Table 20-3 (H)

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

    static let iu = 4_275.0                      // lb, SP-4029 Ground Ignition Weights (H); FER 1,939 kg

    /// Spacecraft at ignition and liftoff: LES (with BPC), CSM, LM and SLA.
    static let spacecraft = 109_646.0            // lb, SP-4029 Ground Ignition Weights (H); FER 49,735 kg
    /// Tower; escape, jettison and pitch-control motors with propellant; boost
    /// protective cover.
    static let les = 4_042.0                     // kg, FER Tables 20-3, 20-9 (H)
    /// Command and service modules, loaded (SPS and RCS propellants).
    static let csm = 28_806.0                    // kg, FER Table 20-7 (H)
    /// Command module; whether crew and probe are included is not stated.
    /// The service module is the rest of `csm`.
    static let cm = 12_250.0                     // lb, recalled; equals the Mission Operations Report prediction (L)
    /// Lunar module, loaded, no crew: DPS, APS and RCS propellants included.
    static let lm = 15_095.0                     // kg, FER Table 20-7 (H)
    /// Spacecraft-LM adapter: the 4 panels (1,166 kg) and the ring that stays
    /// on the S-IVB (626 kg).
    static let sla = 1_166.0 + 626.0             // kg, FER Tables 20-7, 20-9 (H)

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

    /// AS-506's F-1s as flown (FER §5), the ones the vehicle uses. The
    /// stage's site flow and mixture ratio from first motion to OECO (FER
    /// Figure 5-3, reconstructed, digitised: M, ±15-25 kg/s and ±0.002): range
    /// time (s), stage flow (kg/s), engines firing, LOX/RP-1 ratio. The flow
    /// rose about 2 % through the burn as the acceleration head grew, and the
    /// four outboard engines ran slightly lower just after CECO. Integrated,
    /// the flow comes within 0.06 % of the FER's propellant tables.
    static let sICFlowHistory: [(t: Double, flow: Double, engines: Double, mixtureRatio: Double)] = [
        (0.3, 13165, 5, 2.2835), (1, 13200, 5, 2.2910), (2, 13225, 5, 2.2917), (2.5, 13236, 5, 2.2920),
        (5, 13236, 5, 2.2940), (10, 13236, 5, 2.2970), (15, 13233, 5, 2.2985), (20, 13222, 5, 2.3000),
        (30, 13202, 5, 2.3030), (40, 13195, 5, 2.3080), (50, 13191, 5, 2.3130), (60, 13193, 5, 2.3140),
        (70, 13212, 5, 2.3160), (80, 13235, 5, 2.3220), (90, 13271, 5, 2.3280), (100, 13313, 5, 2.3330),
        (110, 13356, 5, 2.3380), (120, 13392, 5, 2.3430), (130, 13420, 5, 2.3490), (135.2, 13432, 5, 2.3510),
        (135.25, 10740, 4, 2.3230), (136.5, 10740, 4, 2.3231), (140, 10678, 4, 2.3235), (145, 10682, 4, 2.3240),
        (150, 10703, 4, 2.3260), (155, 10725, 4, 2.3320), (158, 10728, 4, 2.3344), (160, 10718, 4, 2.3360),
        (161.63, 10712, 4, 2.3360),
    ]
    /// Scales on that flow and ratio that close the FER's propellant budget
    /// exactly: the tanks burn from their first-motion loads to the OECO
    /// residuals, with LOX depletion at 161.63 s (fitted to the model's own
    /// burn, centre-engine tail-off included; within the figure's reading).
    static let sICFlowScale = 0.99896                // fitted (model)
    static let sICMixtureRatioScale = 0.99965        // fitted (model)
    /// Vacuum specific impulse: the stage's site Isp at 140-160 s, where the
    /// ambient pressure is a few tens of Pa (FER Figure 5-3: 2,980.5 N s/kg,
    /// against Betts' rated 304.1 s). Thrust follows the flow at this Isp.
    static let f1IspVacuum = 2_980.5 / 9.80665       // s (303.93), FER Figure 5-3 (M)
    /// Exit area that gives the stage's site Isp at liftoff, 2,597 N s/kg at
    /// 100.6 kPa (FER Figure 5-3): 10.10 m^2, against 9.93 m^2 from the
    /// rating. With the Isp above it fits the figure's thrust within 0.4 %
    /// through the burn.
    static let f1ExitArea = 10.10                    // m^2, derived from FER Figure 5-3 (M)
    /// The F-1 rating at first motion, per engine; its schedule
    /// (`f1Schedule`) carries it along `sICFlowHistory`.
    static var f1: EngineRating {
        let h = sICFlowHistory[0], mdot = h.flow / h.engines
        return EngineRating.fixedNozzle(name: "F-1 (AS-506 flight)",
                                        thrustVacuum: mdot * f1IspVacuum * 9.80665,
                                        ispVacuum: f1IspVacuum / sICFlowScale, exitArea: f1ExitArea,
                                        mixtureRatio: h.mixtureRatio * sICMixtureRatioScale)
    }
    /// `sICFlowHistory` on the engine's burn clock (zero at first motion),
    /// per engine and relative to `f1`: thrust and flow scale together.
    static var f1Schedule: PerformanceSchedule {
        let h0 = sICFlowHistory[0], ref = h0.flow / h0.engines
        return PerformanceSchedule(sICFlowHistory.map { h in
            let k = h.flow / h.engines / ref
            return .init(time: h.t - firstMotion, thrustFactor: k, flowFactor: k,
                         mixtureRatio: h.mixtureRatio * sICMixtureRatioScale)
        })
    }
    /// Tail-off: each F-1 delivered about 0.33 s of full thrust after its
    /// cutoff signal (FER §5.4: 10,612,096 N s for the four outboard engines
    /// to separation, 2,659,605 N s for the centre engine), a linear decay
    /// over 0.66 s. Its 908 kg per engine (Table 20-9) comes from the residual.
    static let f1Transients = EngineTransients(shutdown: 0.66)   // FER §5.4, Table 20-9 (H impulse; shape L)
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

    /// AS-506's S-II J-2s at their three settings (FER §6), per engine. The
    /// flows carry a scale that closes the FER's S-II budget: from the
    /// ignition loads to the OECO residuals with LOX depletion at 548.22 s
    /// (fitted to the model's burn, start and tail-off included; -0.25 %,
    /// within the FER's flow reconstruction, which matches acceptance Isp).
    static let sIIFlowScale = 0.99749                // fitted (model)
    /// Start: the PU valve at null until High EMR Select, ESC + 5.5 s. Thrust
    /// 861,496 to 895,080 N per engine (FER §6.2); EMR about 5.0 (MSFC-MAN-506,
    /// L) and Isp assumed between the S-IVB's and the S-II's (L).
    static let sIIJ2Start = EngineRating.fixedNozzle(
        name: "J-2 S-II start (EMR 5.0)", thrustVacuum: 878_288, ispVacuum: 4_195 / 9.80665 / sIIFlowScale,
        exitArea: j2ExitArea, mixtureRatio: 5.0)
    /// High EMR, from High EMR Select to the EMR shift: thrust, flow and Isp
    /// the mean of the five engines at ESC + 61 s (FER Table 6-1: 1,028,303
    /// N, 246.9 kg/s, 4,164.9 N s/kg = 424.7 s, engine EMR 5.564). The
    /// mixture ratio is fitted to the FER's LH2 residual at OECO; it is the
    /// stage ratio's mean over this phase (Figure 6-3: 5.55 falling to 5.45).
    static let sIIHighMixtureRatio = 5.5006          // fitted (model); FER Figure 6-3 (M)
    static let sIIJ2 = EngineRating.fixedNozzle(
        name: "J-2 S-II high EMR", thrustVacuum: 1_028_303, ispVacuum: 4_164.9 / 9.80665 / sIIFlowScale,
        exitArea: j2ExitArea, mixtureRatio: sIIHighMixtureRatio)
    /// Low EMR, from the PU valve step to OECO: the four engines delivered
    /// 3,082,769 N at ESC + 351 s and 3,059,402 N at ESC + 381 s (FER §6.3),
    /// 768,000 N each on average, at about 183 kg/s (Figure 6-3: 4,181-4,190
    /// N s/kg), and an average EMR of 4.34 (§6.5; predicted 4.33). AS-506 ran
    /// 7-8 % below the 828 kN the datasheet had assumed at EMR 4.7.
    static let sIILowMixtureRatio = 4.34             // FER §6.5 (H)
    static let sIIJ2LowEMR = EngineRating.fixedNozzle(
        name: "J-2 S-II low EMR", thrustVacuum: 768_000, ispVacuum: 4_190 / 9.80665 / sIIFlowScale,
        exitArea: j2ExitArea, mixtureRatio: sIILowMixtureRatio)
    /// Start and tail-off. Between STDV open (164.0 s) and mainstage (166.2
    /// s) the stage burned 582 kg (FER Table 20-9), 0.56 s of full flow: a
    /// linear rise over the last 1.11 s of those 2.2 s. The OECO cutoff
    /// impulse to 5 % thrust was 581,916 N s at 2,783,479 N (§6.4), 0.21 s of
    /// full thrust: a decay over 0.42 s.
    static let sIIJ2Transients = EngineTransients(startDelay: 1.09, startRise: 1.11, shutdown: 0.42)   // FER (shape L)

    /// S-IVB burn 1 (PU null): the flight values of FER Figure 7-2 (thrust
    /// 902-906 kN; the standardised Table 7-1 value is 901,223 N), the
    /// mainstage flow of Table 20-9 (31,152 kg in 144.64 s, venting included)
    /// and the tanks' consumption ratio (Table 20-5: LOX 25,873 kg, LH2 5,339
    /// kg; the engine's own EMR was about 4.96).
    static let sIVBJ2ThrustVacuum = 903_000.0        // N, FER Figure 7-2 (M)
    static let sIVBJ2MassFlow = 215.37               // kg/s, FER Table 20-9 (H)
    static let sIVBMixtureRatio = 4.85               // FER Table 20-5 (H)
    static let sIVBJ2Burn1 = EngineRating.fixedNozzle(
        name: "J-2 S-IVB burn 1", thrustVacuum: sIVBJ2ThrustVacuum,
        ispVacuum: sIVBJ2ThrustVacuum / (sIVBJ2MassFlow * 9.80665), exitArea: j2ExitArea,
        mixtureRatio: sIVBMixtureRatio)
    /// Start: 857,243 N s from STDV open to STDV + 2.5 s (FER §7.2), 0.95 s of
    /// full thrust: a rise over 1.9 s after a 0.6 s delay. Cutoff: 188,302 N
    /// s (§7.4), 0.21 s: a decay over 0.42 s.
    static let sIVBJ2Transients = EngineTransients(startDelay: 0.6, startRise: 1.9, shutdown: 0.42)   // FER (shape L)

    /// The four S-II ullage motors on the S-IC/S-II interstage: 23,000 lbf
    /// for 3.75 s each (MSFC-MAN-506), 152.5 kg of propellant each (FER: 610
    /// kg in all), so an effective Isp of 256.5 s. Lit at 162.1 s, they
    /// burned 33 kg by separation and 300 kg by S-II ignition (Table 20-9).
    static let sIIUllageMotorThrust = 23_000.0       // lbf, MSFC-MAN-506 (M)
    static let sIIUllageMotorBurnTime = 3.75         // s, MSFC-MAN-506 (M)
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

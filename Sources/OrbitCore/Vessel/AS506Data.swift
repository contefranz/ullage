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
/// - Stations, corroborating (datasheet §13): Boeing's Saturn V/Apollo flight
///   configuration diagram (MSFC, 1 March 1967; NASA image 9253429);
///   MSFC-MAN-504 Figs 4-1, 5-1 and 6-1 and §6; MSFC-MAN-506 Fig 5-19; the
///   J-2 drawing in the Saturn V News Reference's fact sheet.
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

    /// Apollo spacecraft stations convert as STA = Xa + 2756.56 in: the SLA
    /// base, Xa 502, is the IU top, STA 3258.56 (AS-501 FER Fig. B-1; AOH
    /// Fig. 1-1), H.
    static let apolloStationOffset = 2_756.56
    static func apolloStation(_ xa: Double) -> Double { station(xa + apolloStationOffset) }

    /// Station of the F-1 nozzle-exit plane, the vehicle base: derived from the
    /// 138 ft S-IC ending at STA 1541 (L-M).
    static let baseStation = -115.0
    /// Construction x (m) of a datasheet height `h` (m above the base).
    static func height(_ h: Double) -> Double { h + station(baseStation) }

    // MARK: Launch site (datasheet §15)

    /// LC-39A: AS-506's launch-site latitude, geodetic, as its space-fixed
    /// frame's vertical was (FER §10: PACSS 13; GE504's sin φ_L 0.478814),
    /// on the WGS-84 Earth.
    static let padLatitude = 28.6084               // deg, geodetic; FER; GE504 (H)
    /// The same pad as SP-4029 gives it, geocentric: kept to check the two
    /// against each other on the ellipsoid (they agree to 0.0001°).
    static let padGeocentricLatitude = 28.4470     // deg, geocentric; SP-4029 Ascent Phase (H)
    static let padLongitude = -80.6041             // deg; SP-4029 Ascent Phase (H)
    /// The vehicle base's height above the ellipsoid: the postflight
    /// trajectory's 59 m at first motion (PFT Table B-III) less the model's
    /// 33 m from the base to the centre of mass, taken above WGS 84. The
    /// PFT's altitudes are over the Fischer ellipsoid, 30 m higher here; read
    /// so, the base is at 56 m and the centre of mass at the PFT's radius,
    /// 6,373,355 m, which moves the cutoffs by about 1 m/s (datasheet §15).
    static let padElevation = 26.0                 // m, derived (M)

    // MARK: Timeline (range time, s, from 1969-07-16 13:32:00 UTC)

    /// Range zero, 1969-07-16 13:32:00 UTC: range time 0 (SP-4029 Apollo 11 Timeline, H).
    static let rangeZero = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)

    /// Hold-down release. Simulation time 0 of `saturnV()` is this instant.
    static let firstMotion = 0.30              // SP-4029 Apollo 11 Timeline; Boeing D5-15560-6 (H)
    static let sICCenterCutoff = 135.20        // SP-4029 Apollo 11 Timeline and Ascent Phase (H)
    static let sICOutboardCutoff = 161.63      // SP-4029 Apollo 11 Summary; Mission Report (H). LOX depletion
    static let sICSeparation = 162.30          // SP-4029 Apollo 11 Ascent Phase (H)
    /// S-II engine start sequence command (FER Table 2-2); Table 20-10's
    /// "2nd flight stage at start sequence command" event.
    static let sIIStartCommand = 163.04        // FER Table 2-2 (H)
    /// S-II engine start (solenoid activation, STDV open), after the start
    /// command `sIIStartCommand`. The J-2s' start transient (`sIIJ2Transients`)
    /// gives nothing for 1.09 s and full thrust from mainstage, 166.2 s (FER Table 2-2).
    static let sIIIgnition = 164.00            // SP-4029 Propellant Usage and Ascent Phase durations; FER Table 2-2 (H)
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
    /// segments split at t_S1..3 (GE504 Table 4-II's form and splits).
    static let pitchSegmentBoundaries = [35.0, 80.0, 115.0]   // s; GE504 t_S1, t_S2, t_S3
    /// SA-504's presettings (GE504 Table 5-I, read from the page images; H
    /// for SA-504). The segments join to within 0.04°. AS-506's commanded
    /// pitch (MAN506 Figure 2-2) seemed to follow them to within the figure's
    /// reading accuracy, about 1°, but AS-506's own command, reconstructed
    /// from its flight, was not a scale of them (datasheet §14.1, §17). Kept
    /// for reference; the IU flies `pitchCoefficients`.
    static let sa504PitchCoefficients: [[Double]] = [          // deg, deg/s, ..., deg/s^4; GE504 F_kn
        [3.19840, -0.544236, 0.0351605, -0.00116379, 0.0000113886],
        [-10.9607, 0.946620, -0.0294206, 0.000207717, -0.000000439036],
        [78.7826, -2.83749, 0.0289710, -0.000178363, 0.000000463029],
        [69.9191, -2.007490, 0.0105367, -0.0000233163, 0.0000000136702],
    ]
    /// AS-506's pre-IGM pitch program, reconstructed from its flight in
    /// GE504's form: tools/fit_as506_pitch.py's least-squares fit (default
    /// options) to its command, the pitch of the postflight trajectory's
    /// sensed acceleration (PFT Table B-II, H) less FER Figure 11-1's
    /// measured attitude error (digitised, M), on 5 s boxcars from the
    /// program start to the arrest (those over the centre engine cutoff's
    /// transient, 134-138 s, left out). The segments join exactly and the
    /// command reaches AS-506's held -68.90° at the arrest (FER Figure 10-4,
    /// OT and LVDC, M). Rms 0.057°, maximum 0.147°; rates within 0.75°/s.
    /// AS-506's presettings themselves were not found: the fit assumes the
    /// attitude lay along the sensed acceleration (engine deflection, the
    /// late trim and the 0.12° stacking misalignment neglected; datasheet
    /// §14.4), so it is M. It is +0.08° at AS-506's program start (T1 + 12.6
    /// s) and +0.37° at the model's (T1 + 10.7 s, datasheet §8.5). Only an
    /// S-IC engine out runs it past the arrest (`TiltProgram.pitch(at:bias:
    /// arrest:)`), to T1 + 179 s at the latest (a failure at T1 + 81 s);
    /// there its last quartic is at -77.2° and -0.67°/s, where the SA-504
    /// polynomial the IU flew before (times 1.025) had flattened to -73.3°
    /// and -0.2°/s.
    static let pitchCoefficients: [[Double]] = [               // deg, deg/s, ..., deg/s^4; fitted (M)
        [2.1092631223198826, -0.1936626337735124, 0.005057915299567872, -0.00020518344184194986, 5.913540388168162e-07],
        [-18.34599804968528, 1.5870316763666779, -0.05055899177115696, 0.0004905277226633409, -1.7856186888329139e-06],
        [-412.0495000334753, 16.736762388740786, -0.2636063201496652, 0.0017592250103918839, -4.33310562000257e-06],
        [-550.1015769044409, 16.312579677308413, -0.19204984522638613, 0.0009685058696828931, -1.7997602934715665e-06],
    ]
    /// AS-506's pitch held after the arrest, deg (FER Figure 10-4, OT and
    /// LVDC; M): the fit's value at `tiltArrest`.
    static let heldPitch = -68.90
    /// Tilt arrest, s from T1: AS-506's at range 160.0 s (FER Table 2-2, T2 +
    /// 24.7 s; predicted T2 + 25.5). SA-504's preset was 153.0 s (GE504).
    static let tiltArrest = 160.0 - liftoff    // FER (H for the time, to a computation cycle)
    static var tiltProgram: TiltProgram {
        TiltProgram(boundaries: pitchSegmentBoundaries, coefficients: pitchCoefficients, arrest: tiltArrest)
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
    /// The S-IC roll attitude-gain filter 2.35/(s + 2.35): the flight control
    /// computer's shaping of the roll attitude error ahead of a0 (beta = a0 F
    /// e + a1 w), a 0.43 s lag with static gain 1, so a steady error is held
    /// as before. D5-15481-1 §3.5 (pp. 3-5, 3-6, read from the page images),
    /// from the SA-503 flight control design release (Boeing FCD-H-027,
    /// 1966): L for AS-506. It pairs with the roll gains above, which are the
    /// same document's. With FER Table 20-10's roll inertia the roll loop on
    /// them is near critically damped without it (zeta 0.90 at the roll
    /// program's start); with it the start overshoots, 1.24°/s, and the end
    /// undershoots, -0.24°/s, as FER Figure 11-3's post-flight simulation
    /// does (-0.28°/s; datasheet §8.6). REF504's other filters are 1 (the
    /// rate channels, the S-II), except the S-IC's pitch and yaw
    /// attitude-gain filter 0.4(s + 0.095)/(s + 0.038), which the model does
    /// not fly: it belongs to REF504's pitch and yaw gains, not to TN
    /// D-5869's that the model flies, and REF504's gains with it move the
    /// S-IC pitch error from 20 to 100 s away from FER Figure 11-1 (rms 0.151°
    /// against 0.084° unfiltered); with the model's gains it moves it away
    /// too (0.123° against 0.091°), and its effect on the tower-clearance yaw
    /// is mixed (closer in peak size and return rate, later in its peak, 9.1
    /// against AS-506's 6.9 s, FER Figure 11-2). An open choice (datasheet §8.9).
    static let sICRollAttitudeFilter = FCCFilter(gain: 2.35, pole: 2.35)   // D5-15481-1 §3.5 (L)
    /// S-IC centre engine cutoff, commanded by the IU at T1 + 134.56 s (range
    /// 135.20, FER Table 2-2 and §5.1, H); the LVDC senses it and starts T2.
    static let sICCenterCutoffTime = 134.56    // s from T1; FER (H)
    /// From T3, S-IC outboard cutoff sensed: separation command, S-II engine
    /// solenoid activation (range 164.0, where the J-2s' start transient
    /// begins: mainstage at 166.2 s), aft interstage and LET jettison, and
    /// S-II centre engine cutoff (FER Table 2-2, time from base, H).
    static let sICSeparationTime = 0.7         // s from T3; FER (H)
    static let sIIIgnitionTime = 2.4           // s from T3; FER (H)
    static let interstageJettisonTime = 30.7   // s from T3; FER (H)
    static let lesJettisonTime = 36.2          // s from T3; FER (H)
    /// IGM phase 1 initiated (204.1 s range; FER Table 2-2): iterative
    /// guidance from here to the S-IVB cutoff (see "Iterative guidance").
    static let igmStartTime = 42.4             // s from T3; FER (H)
    static let sIICenterCutoffTime = 299.0     // s from T3; FER (H)
    /// FER's T3 (S-IC OECO sensed), the base of the S-II's sequence.
    static let timeBase3 = 161.66              // range time, FER Table 2-1 (H)
    /// S-II ullage motors lit, and their burn ended (thrust down to 75 %).
    static let sIIUllageIgnitionTime = 0.5     // s from T3; FER Table 2-2 (H)
    static let sIIUllageEndTime = 4.4          // s from T3; FER Table 2-2 (H)
    /// High EMR Select (S-II PU system activated): ESC + 5.5 s, 168.5 s.
    static let sIIHighMixtureRatioTime = 6.9   // s from T3; FER Table 2-2 and §6.5 (H)
    /// The PU valve step, the model's shift to low EMR, follows the IGM's
    /// EMR shift command by as long as on AS-506 (494.8 to 497.60 s).
    static let sIIMixtureRatioShiftDelay = sIIMixtureRatioShift - sIIMixtureRatioShiftCommand   // s
    /// From T4, S-II outboard cutoff sensed: separation command and S-IVB
    /// ignition (STDV open, range 552.2; FER Table 2-2, H). The IGM cuts the
    /// S-IVB off on velocity: on AS-506 at 699.34 s, T4 + 151.10 (T4 at
    /// 548.24, FER Table 2-1), sensed 0.23 s later (T5).
    static let sIISeparationTime = 0.8         // s from T4; FER (H)
    static let sIVBIgnitionTime = 4.0          // s from T4; FER (H)
    /// S-IVB ullage (TX-280) motors lit 0.1 s before the separation command
    /// (548.9 s), and their cases jettisoned (561.0 s): FER Table 2-2 items
    /// 45 and 52.
    static let sIVBUllageIgnitionTime = 0.7    // s from T4; FER (H)
    static let sIVBUllageJettisonTime = 12.8   // s from T4; FER (H)
    static let sIVBCutoffTime = 699.34 - 548.24  // s from T4; FER Tables 2-1 and 2-2 (H), for reference
    /// From T5, S-IVB cutoff sensed: APS ullage engines on and off (No. 1;
    /// No. 2 follows 0.1 s later), and the manoeuvre to the local horizontal
    /// (FER Table 2-2, H). T2, T3 and T4 also start on the LVDC sensing a
    /// cutoff: T2 at 135.27, 0.07 s after the centre engine's (FER Table 2-1).
    static let tb5UllageOn = 0.3               // s from T5; FER (H)
    static let tb5UllageOff = 87.0             // s from T5; FER (H)
    static let orbitalGuidanceStart = 19.8     // s from T5; FER "begin maneuver to local horizontal" (H)

    // MARK: Iterative guidance (datasheet §10)
    //
    // The IGM's equations are SA-504's (GE504 §4); AS-506's own presettings
    // were not found. The stage performance presets are therefore the
    // model's own vehicle, as the LVDC's were the predicted vehicle's; the
    // thresholds are SA-504's (GE504 Table 5-I, H for SA-504, M as a proxy)
    // unless AS-506's flight shows its own (FER Tables 2-2 and 10-4, the
    // "inferred" ones); the targets are AS-506's nominal parking orbit.

    /// GE504's nominal IGM computation cycle (Table 5-I Δt).
    static let igmCycle = 1.7                  // s; GE504 (H for SA-504)
    /// τ2 at the EMR shift command and τ3 at S-IVB 90 % thrust: the model's
    /// stack mass then over the flow of four low-EMR J-2s and of the S-IVB
    /// J-2 (from the model's flight before the solid motors, rounded to
    /// 0.5 s; τ3 would now be 773.1 s, and the IGM measures it once the
    /// S-IVB thrusts).
    static let igmTau2 = 347.5                 // s, model
    static let igmTau3 = 773.5                 // s, model
    /// T2 from the shift command to S-II OECO, Tc from S-II cutoff (T4) to
    /// S-IVB 90 % thrust, and the first T3′ estimate: AS-506's (494.8 to
    /// 548.22 s; 548.24 to 554.5 s; 554.5 to 699.34 s, rounded).
    static let igmStage2Time = 53.4            // s, FER Table 2-2 (H), inferred preset
    static let igmCoastTime = 6.3              // s, FER Table 2-2 and the model's start ramp (inferred)
    static let igmStage3Time = 144.8           // s, FER Table 2-2 (inferred preset)
    /// The S-II characteristic velocity (sensed velocity gained from engine
    /// start) at which the IGM commands the EMR shift (T1 = 0): fitted so the
    /// model commands it on the cycle at AS-506's 494.8 s. AS-506's own
    /// preset is not known; its LVDC's sum ran about 92 m/s low through a
    /// scaling error (FER §10.2.1), which the fit absorbs.
    static let igmShiftVelocity = 3_906.0      // m/s, fitted (model)
    /// Artificial tau after the EMR shift command and after S-IVB ignition:
    /// AS-506 ran them for 9.33 s and 6.86 s (FER Table 10-4); with 1.7 s
    /// cycles these durations fit both (SA-504: none after the shift, 25 s
    /// after ignition).
    static let igmArtificialTau = (stage2: 9.0, stage3: 6.0)   // s, FER Table 10-4 (inferred, L)
    static let igmRangeAngleBias = 1.5         // ROV; GE504 Table 5-I
    static let igmLead = 2.0                   // s, t; GE504 Table 5-I
    /// Terminal guidance (the K terms dropped) from this total time-to-go:
    /// AS-506's began 34.19 s before its cutoff (FER Table 10-4, "begin chi
    /// bar steering"; SA-504's ε2 was 10 s).
    static let igmTerminalGuidanceTime = 35.0  // s, FER Table 10-4 (inferred, L)
    /// The high-speed cutoff loop and chi freeze from this total time-to-go
    /// (ε4) with V + V_TC ≥ V_T: AS-506's froze 7.70 s before cutoff (FER
    /// Table 10-4), consistent with SA-504's 8 s.
    static let igmCutoffLoopTime = 8.0         // s, GE504 Table 5-I (H); FER consistent
    static let igmCutoffLoopMargin = 300.0     // m/s, V_TC; GE504 Table 5-I
    /// ΔV_B, the velocity the vehicle still gains after the cutoff command
    /// (GE504: "thrust decay at shutdown and the expected post-cutoff vents";
    /// SA-504's was 2.0275 m/s). AS-506's LVDC cut off at 7,791.43 m/s and
    /// inserted at 7,793.28 m/s 10 s later, a 1.85 m/s gain (FER Table
    /// 10-2). The model, which has no vents, gains 1.45 m/s: 1.40 from the
    /// J-2's thrust decay and 0.05 from the APS ullage burn. That is its bias,
    /// so it inserts at circular speed.
    static let igmCutoffVelocityBias = 1.45    // m/s, the model's (FER Table 10-2: 1.85 on AS-506)
    /// The target: a 100 n mi circular orbit above the 6,378,165 m sphere
    /// (GE504's SA-504 R_T; AS-506's LVDC cut off 30 m below it, FER Table
    /// 10-2), in AS-506's nominal plane (FER Tables 4-5 and 10-5: i and the
    /// descending node from the launch meridian at guidance reference
    /// release, eastwards).
    static let igmTerminalRadius = 6_563_365.0 // m; GE504 Table 5-I; MAN506, TIS "100 n mi" (H)
    static let igmInclination = 32.531         // deg; FER Table 4-5, nominal (H)
    static let igmDescendingNode = 123.100     // deg; FER Table 4-5, nominal (H)
    /// The presettings, with the exhaust velocities of the model's J-2
    /// settings (thrust over flow) and μ of `gm`.
    static func igmPresettings(gm: Double) -> IGMPresettings {
        IGMPresettings(exhaustVelocity: (sIIJ2.thrustVacuum / sIIJ2.massFlow,
                                         sIIJ2LowEMR.thrustVacuum / sIIJ2LowEMR.massFlow,
                                         sIVBJ2Burn1.thrustVacuum / sIVBJ2Burn1.massFlow),
                       tau2: igmTau2, tau3: igmTau3, stage2Time: igmStage2Time, coastTime: igmCoastTime,
                       stage3Time: igmStage3Time, shiftVelocity: igmShiftVelocity,
                       artificialTau: igmArtificialTau, rangeAngleBias: igmRangeAngleBias, lead: igmLead,
                       terminalGuidanceTime: igmTerminalGuidanceTime, cutoffLoopTime: igmCutoffLoopTime,
                       cutoffLoopVelocityMargin: igmCutoffLoopMargin, cutoffVelocityBias: igmCutoffVelocityBias,
                       terminalRadius: igmTerminalRadius, terminalFlightPathAngle: 0,
                       inclination: igmInclination * degree, descendingNode: igmDescendingNode * degree, mu: gm)
    }

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
    /// propellant). It leaves with the S-II. The model uses the FER's split,
    /// `sIISIVBInterstageDry` and `sIIRetroPropellant` (3,180 + 484 kg).
    static let sIISIVBInterstage = 8_076.0       // SP-4029 Ground Ignition Weights (H)

    /// S-IVB stage: structure, aft skirt, J-2 (dry); aft interstage and IU excluded.
    static let sIVBDry = 24_852.0                // SP-4029 Ground Ignition Weights (H)
    /// Not itemised. It holds the APS propellant, which the builder moves into
    /// the APS tanks (2 x (`apsOxidizerLoad` + `apsFuelLoad`) = 658 lb); the
    /// other 998 lb are helium, the TX-280 ullage motors (53 kg of grain and
    /// 61 kg of cases, which the builder moves to their own part), the aft
    /// frame that leaves with the S-II (23 kg) and the rest (datasheet §7.3, §12).
    static let sIVBOther = 1_656.0               // SP-4029 Ground Ignition Weights (H)
    static let sIVBLOXLoad = 192_497.0           // SP-4029 Ground Ignition Weights (H)
    static let sIVBLH2Load = 43_608.0            // SP-4029 Ground Ignition Weights (H)
    /// Propellant not consumed by burn 1 and TLI (residuals plus boost and
    /// orbital venting), derived from the pre-FER engine model (EMR 5.0) and
    /// not re-derived. Venting is not modelled, so both overstate the
    /// residual. At burn 1's EMR 4.85 and 215.37 kg/s the usable LOX would
    /// last 478 s and the usable LH2 474 s; burn 1 ends on guidance after 147 s.
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
    /// Scales on that flow and ratio, five engines and four apart, that close
    /// the FER's propellant budget exactly (fitted to the model's own burn,
    /// the centre engine's tail-off included; within the figure's reading):
    /// - to CECO, from the first-motion loads to the tanks' reconstructed
    ///   contents at 135.20 s, LOX 216,633 kg and RP-1 99,059 kg of liquid
    ///   (FER Table 5-2) with 2,809 kg of GOX (Table 20-1), H;
    /// - from CECO to the OECO residuals, with LOX depletion at 161.63 s.
    /// The vehicle at CECO is then 661 kg above Table 20-1's 1,110,189 kg:
    /// the frost and purge gas shed by then (S-IC frost 295 kg and N2 purge
    /// 16 kg, S-II frost 204 and purge 54 kg, S-IVB frost 90 kg; Table 20-1),
    /// which the model does not shed. Before, one scale on the whole burn
    /// (0.99896, 0.99965) left the tanks 761 kg too full at CECO.
    static let sICFlowScale = (fiveEngines: 0.999385, fourEngines: 0.996609)          // fitted (model)
    static let sICMixtureRatioScale = (fiveEngines: 0.999840, fourEngines: 0.998441)  // fitted (model)
    /// The stage's thrust over the same burn (FER Figure 5-3, reconstructed,
    /// digitised: M, 0.017 MN a pixel), as vacuum thrust: range time (s),
    /// stage thrust (N), engines firing. The figure gives the site thrust;
    /// to it is added the engines' pressure loss, n p A_e (`f1ExitArea`), at
    /// the launch-day pressure (`launchDayAtmosphere()`) at AS-506's altitude
    /// over the Fischer ellipsoid (PFT Table B-II, H), the altitude the
    /// model's centre of mass flies as its geodetic height (59 m on the pad;
    /// datasheet §15), so the model's site thrust is the figure's (times
    /// `sICThrustScale`) along AS-506's path. The knots are the least-squares
    /// piecewise-linear fit to the figure's 0.5 s samples: five engines to
    /// 134 s, four from 137 to 160.5 s (the centre engine's decay between
    /// left out), the first four-engine knot at the five engines' thrust per
    /// engine. They fit the samples within 0.035 % rms and 0.18 % at most
    /// (`SaturnVDataTests.testF1ThrustFollowsFigure5_3`). After 160.5 s the
    /// figure hooks down to OECO, a stretch its digitisation did not follow
    /// (its visual reader: 0.2-0.3 MN below the trace there), so the last
    /// knot is AS-506's sensed acceleration at OECO, 38.61 m/s^2 (FER Table
    /// 4-1, and the PFT's 161.63 s row: H), over the FER's mass then, 827,292
    /// kg (Table 20-1), at the figure's level. In vacuum the thrust dips 0.4 %
    /// to 55 s and rises 1.9 % from there to CECO, while the flow rises 1.8 %
    /// (`sICFlowHistory`): the specific impulse, thrust over flow, wanders by
    /// ±0.5 % about 2,980 N s/kg, the two panels' reading and reconstruction
    /// errors together.
    static let sICThrustHistory: [(t: Double, thrust: Double, engines: Double)] = [
        (0.3, 39_454_900, 5), (2.5, 39_474_300, 5), (5, 39_457_700, 5), (10, 39_501_100, 5),
        (15, 39_501_000, 5), (20, 39_428_600, 5), (25, 39_402_100, 5), (30, 39_422_000, 5),
        (35, 39_400_200, 5), (40, 39_374_900, 5), (45, 39_332_000, 5), (50, 39_305_300, 5),
        (55, 39_287_600, 5), (60, 39_340_400, 5), (65, 39_319_700, 5), (70, 39_338_500, 5),
        (75, 39_342_500, 5), (80, 39_391_800, 5), (85, 39_419_900, 5), (90, 39_465_600, 5),
        (95, 39_534_800, 5), (100, 39_592_300, 5), (105, 39_669_900, 5), (110, 39_752_700, 5),
        (115, 39_840_900, 5), (120, 39_904_500, 5), (125, 39_938_600, 5), (130, 39_983_200, 5),
        (135.2, 40_036_700, 5),
        (135.25, 32_029_400, 4), (137, 31_906_500, 4), (140, 31_703_200, 4), (145, 31_718_000, 4),
        (150, 31_820_500, 4), (155, 31_943_600, 4), (160.5, 32_023_700, 4),
        (161.63, 38.61 * 827_292 / sICThrustScale, 4),
    ]
    /// The level of that thrust, from AS-506's measured acceleration: the
    /// figure's thrust, on the FER's propellant (Tables 5-2 and 20-1) and
    /// with the sourced aerodynamics (datasheet §11), gives 10.3 m/s (0.28
    /// %) less sensed velocity over the S-IC burn (the integral of |a_ng|)
    /// than the postflight trajectory (PFT Table B-II, H; its first 20 s
    /// integrate the IU's own accelerometers, FER §4.2.1), 8.9 m/s with the
    /// frost and purge gas AS-506 shed by CECO taken off. Where drag is under
    /// 1 % of thrust the PFT's acceleration needs 0.3-0.6 % more thrust than
    /// the figure in the first 20 s, 0.1-0.3 % at 100-130 s and 0.1-0.5 % at
    /// 140-160 s; the figure is a reconstruction from engine data, and its
    /// thrust and flow panels disagree with its own Isp panel by 0.6 % at
    /// liftoff. The scale is fitted to the nearest 0.0001 on the PFT's S-IC
    /// integral of |a_ng| with the 661 kg of frost and purge gas AS-506 shed
    /// by CECO taken off (linearly to CECO; worth 1.3 m/s), which the model
    /// does not shed yet (datasheet §17): until it does, the model's S-IC is
    /// 1.3 m/s short. At 1 the figure's thrust stands as printed.
    static let sICThrustScale = 1.0022               // fitted (model) to the PFT (H): M
    /// Exit area that gives the stage's site Isp at liftoff on the figure's
    /// flow, about 2,594 N s/kg at 100.6 kPa (FER Figure 5-3), from its
    /// vacuum Isp, 2,980.5 N s/kg at 140-160 s, where the ambient pressure is
    /// a few tens of Pa: 10.10 m^2, against 9.93 m^2 from the rating. FER
    /// Table 5-1's sea-level Isp, 2,594 N s/kg (the five engines reduced to
    /// standard conditions at 35-38 s), agrees.
    static let f1ExitArea = 10.10                    // m^2, derived from FER Figure 5-3 (M)
    /// The F-1 rating at first motion, per engine; its schedule
    /// (`f1Schedule`) carries it along `sICThrustHistory` and `sICFlowHistory`.
    static var f1: EngineRating {
        let h = sICFlowHistory[0], f = sICThrustHistory[0]
        let thrust = f.thrust / f.engines * sICThrustScale, mdot = h.flow / h.engines * sICFlowScale.fiveEngines
        return EngineRating.fixedNozzle(name: "F-1 (AS-506 flight)", thrustVacuum: thrust,
                                        ispVacuum: thrust / (mdot * standardGravity), exitArea: f1ExitArea,
                                        mixtureRatio: h.mixtureRatio * sICMixtureRatioScale.fiveEngines)
    }
    /// The two histories on the engine's burn clock (zero at first motion),
    /// per engine and relative to `f1`, on every knot of either: thrust and
    /// flow are separate factors, and the flow and mixture ratio carry their
    /// scales for the engines firing.
    static var f1Schedule: PerformanceSchedule {
        let thrust = sICThrustHistory.map { (t: $0.t, value: $0.thrust / $0.engines) }
        let flow = sICFlowHistory.map { h in
            (t: h.t, value: h.flow / h.engines * (h.engines == 5 ? sICFlowScale.fiveEngines : sICFlowScale.fourEngines))
        }
        let ratio = sICFlowHistory.map { h in
            (t: h.t, value: h.mixtureRatio * (h.engines == 5 ? sICMixtureRatioScale.fiveEngines
                                                              : sICMixtureRatioScale.fourEngines))
        }
        let times = Set(thrust.map(\.t) + flow.map(\.t)).sorted()
        return PerformanceSchedule(times.map { t in
            .init(time: t - firstMotion, thrustFactor: interpolate(thrust, at: t) / thrust[0].value,
                  flowFactor: interpolate(flow, at: t) / flow[0].value, mixtureRatio: interpolate(ratio, at: t))
        })
    }
    /// Linear between knots, held beyond the ends.
    private static func interpolate(_ knots: [(t: Double, value: Double)], at t: Double) -> Double {
        guard let i = knots.firstIndex(where: { $0.t >= t }) else { return knots[knots.count - 1].value }
        guard i > 0 else { return knots[0].value }
        let a = knots[i - 1], b = knots[i]
        return a.value + (b.value - a.value) * (t - a.t) / (b.t - a.t)
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
    /// impulse to 5 % thrust was 581,916 N s (§6.4), from 2,783,479 N after
    /// the LOX starvation that the model does not have: 0.19 s of the
    /// model's 3,072,000 N, a decay over 0.38 s.
    static let sIIJ2Transients = EngineTransients(startDelay: 1.09, startRise: 1.11, shutdown: 0.38)   // FER (shape L)

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
    /// 90° apart at Positions I-IV, nozzles just above STA 1564 (23 in above
    /// the model's S-IC/S-II plane, `sICTop`), canted 10° outward
    /// (MSFC-MAN-506 §5): the motors' middle about STA 1608.
    static let sIIUllageMotorCant = 10.0             // deg, MSFC-MAN-506 (H)
    static let sIIUllageMotorStation = 1_608.0       // STA, MSFC-MAN-506 Fig 5-19 (M)
    static let sIIUllageMotorRadius = 5.24           // m, in fairings outside the 198 in skin (L)

    // MARK: Retro and S-IVB ullage motors (datasheet §12)
    //
    // Solids at a constant effective thrust for an effective burn time, so
    // Isp_eff = F t / (m g0) on the FER's propellant. Every set fires in
    // symmetric pairs, each nozzle canted outward (the force inward), so
    // they add no side force or torque. The retros fire with their stage's
    // separation and burn on with the spent stage; the ullage motors push
    // the stack that stays. The LES tower-jettison motor fires with the
    // tower's separation, its thrust tilted off the axis to throw it clear.

    /// S-IC retros: eight TE-M-424s in pairs in the four engine fairings
    /// (one towards each adjacent Position), 7.5° from the axis. Nominal at
    /// 60°F per the AS-501 FER (87,000 lbf for 0.640 s, F t_b 247.7 kN s;
    /// its nominal effective impulse is 246.9 kN s; AS-501 flew 0.637 s).
    /// MSFC-MAN-506's 75,800 lbf for 0.541 s is a minimum at 120°F and
    /// implies an Isp_eff of 145 s on the 128 kg grain.
    static let sICRetroThrust = 386_995.0            // N each, AS-501 FER Table 12-2 (H as spec)
    static let sICRetroBurnTime = 0.640              // s, AS-501 FER Table 12-2 (H as spec)
    static let sICRetroPropellant = 1_027.0          // kg, eight motors, AS-506 FER Table 20-1 (H)
    static let sICRetroCant = 7.5                    // deg, MSFC-MAN-506 §4 (H)
    /// AS-501's thrust (FER-501 Figure 12-1, timed from the separation
    /// signal) is about nil to 0.09 s, 75 % at 0.15-0.17 s and full by about
    /// 0.18 s; the stages separated physically 0.15 s after the signal
    /// (D5-15796-1 Table 5-I); AS-505's 75 % came within 0.05-0.15 s
    /// (T3 + 0.8 against the T3 + 0.7 command, FER-505 Table 2-2).
    static let sICRetroStart = EngineTransients(startDelay: 0.09, startRise: 0.08)   // FER-501 Fig 12-1 (M)
    /// In the fairings, against the skin, side by side about each fin
    /// (about 2.5° either side); the station is inferred from the fairing's
    /// taper, nozzles at its forward end (STA 260-300).
    static let sICRetroStation = 230.0               // STA (L)
    static let sICRetroRadius = 5.25                 // m (L)
    static let sICRetroPairOffset = 2.5              // deg about each fin diagonal (L)
    /// S-II retros: four TE-M-29s, 90° apart in the aft end of the S-II/S-IVB
    /// interstage (STA 2519-2633), nozzles 9.5° from the axis, in fairings
    /// on the fin diagonals as D5-15481-1 Figure 3-1 draws them (L).
    static let sIIRetroThrust = 34_810.0             // lbf each, MSFC-MAN-506 Fig 1-3 (H)
    static let sIIRetroBurnTime = 1.52               // s, MSFC-MAN-506 Fig 1-3 (H)
    static let sIIRetroPropellant = 484.0            // kg, four motors, AS-506 FER Table 20-9 (H)
    static let sIIRetroCant = 9.5                    // deg, MSFC-MAN-506 §5 (H)
    /// Lit 0.04 s after the separation command (AS-501: 520.57 against
    /// 520.53 s), full within about 0.025 s (FER-501 Figure 12-9).
    static let sIIRetroStart = EngineTransients(startDelay: 0.04, startRise: 0.025)   // FER-501 Table 12-1 (H), Fig 12-9 (M)
    static let sIIRetroStation = 2_576.0             // STA, middle of 2519-2633, MSFC-MAN-506 §5 (M)
    /// The S-II/S-IVB interstage without its retros' propellant, and the
    /// S-IVB aft frame and detonation package that leave with it.
    static let sIISIVBInterstageDry = 3_180.0        // kg, AS-506 FER Table 20-9 (H)
    static let sIVBAftFrame = 22.0 + 1.0             // kg, AS-506 FER Table 20-9 (H)
    /// S-IVB ullage motors: two TX-280s in fairings on the aft skirt, at the
    /// Fin II-III and IV-I diagonals, lit at 548.9 s; their cases and
    /// fairings are jettisoned at 561.0 s. AS-506 burned 43 kg of the 53 kg
    /// by STDV open (552.2 s) and all but 1 kg by mainstage (FER Table 20-9).
    static let sIVBUllageMotorThrust = 3_390.0       // lbf each, MSFC-MAN-506 Fig 1-3 (H)
    static let sIVBUllageMotorBurnTime = 3.87        // s, MSFC-MAN-506 (H)
    static let sIVBUllageMotorPropellant = 53.0      // kg, two motors, AS-506 FER Tables 20-5, 20-9 (H)
    static let sIVBUllageMotorCases = 61.0           // kg, with fairings, AS-506 FER Table 20-9 (H)
    /// "Canted outward ... to reduce effects of exhaust impingement, and to
    /// reduce the resulting moment if one rocket fails" (MSFC-MAN-506 §6);
    /// 35° on the Saturn IB's S-IVB-200 (Data Summary Handbook), taken here.
    static let sIVBUllageMotorCant = 35.0            // deg, S-IVB Data Summary Handbook p 98 (M, proxy)
    static let sIVBUllageMotorHeight = 73.4          // m, on the aft skirt, STA 2746.5-2832 (L)
    static let sIVBUllageMotorRadius = 3.45          // m, outside the 130 in skin (L)

    /// LES tower-jettison motor: lit with the tower's separation (frangible
    /// nuts and motor on the same circuit; no spring, and no other motor or
    /// the canards in a normal jettison: AOH 2.9.4.8.4). TN D-6295 (70°F,
    /// sea level, about vacuum for its flush scarfed nozzles): 31,660 lbf
    /// over the web burn, 36,734 lbf s in all, so 1.160 s at that thrust;
    /// 205.2 lb of grain; lit 0.046 s after the firing current and at 90 %
    /// by 0.111 s (taken as a linear rise to full over the 0.065 s). Its two
    /// nozzles' resultant leans 3.784° towards +Z_A, Position III (-z;
    /// MSFC-MAN-506 Fig 7-15), crossing the axis at Xa 1395.9, which pitches
    /// the tower over and throws it clear.
    static let towerJettisonThrust = 31_660.0        // lbf, TN D-6295 Table VIII(b) (H)
    static let towerJettisonBurnTime = 36_734.0 / 31_660.0   // s, total impulse over thrust, TN D-6295 (H)
    static let towerJettisonPropellant = 205.2 * pound   // kg, TN D-6295 Table X (H)
    static let towerJettisonStart = EngineTransients(startDelay: 0.046, startRise: 0.065)   // TN D-6295 Table VIII(b) (H)
    static let towerJettisonTilt = 3.784             // deg towards -z, TN D-6295 p 19, AOH 2.9.5.7.4 (H; sign M)
    static let towerJettisonThrustPoint = 1_395.9    // Xa, where the thrust line crosses the axis, TN D-6295 Table X (M)
    static let towerJettisonGrainPoint = 1_408.5     // Xa, the motor's middle (L)
    /// The whole LES's CG and inertia (with the BPC and the TJM's grain),
    /// from the Apollo 11 and 12 Mission Reports' mass tables (lift-off less
    /// orbit), M.
    static let lesCenterOfMass = 1_297.1             // Xa (M)
    static let lesInertia = (roll: 1_100.0, pitch: 37_500.0)   // kg m², about its CG (M)
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
    // Saturn V News Reference, unless marked; the interfaces from the S-IC
    // top to the IU and the J-2 gimbals are sourced (§13).

    static let sICTop = 1_541.0                      // STA, S-IC forward skirt top; NASA image 9253429, MSFC-MAN-504 Fig 5-1 (H)
    /// The S-IC/S-II separation plane: the small interstage ring between it
    /// and the S-IC top leaves with the S-IC (the model's S-IC part ends at
    /// the S-IC top and carries the ring's mass).
    static let sICSIISeparationPlane = 1_564.0       // STA, FER-501 §12.2.3 (M)
    static let sIIAftSkirt = 1_760.0                 // STA, second plane: interstage top; MSFC-MAN-506 Fig 5-19, NASA image 9253429 (H)
    static let sIITop = 2_519.0                      // STA, S-II forward skirt top; NASA image 9253429, MSFC-MAN-504 Fig 5-1 (H)
    /// S-II/S-IVB separation plane, the S-IVB aft skirt's bottom (MSFC-MAN-506
    /// Fig. 5-19: "S-II/S-IVB separation plane, station no. 2746.5").
    static let sIVBAftSkirt = 2_746.5                // STA, AS-501 FER Fig. B-1, D5-15481-1 Fig. 3-1 (H)
    static let sIVBTop = 3_222.56                    // STA, S-IVB/IU, AS-501 FER Fig. B-1, D5-15481-1 Fig. 3-1 (H)
    static let iuTop = 3_258.56                      // STA, IU/SLA = Xa 502, same sources (H)
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
    /// The S-II J-2s' gimbal plane is S-II station XB 100 (XB 196 = STA 1760);
    /// their exits hang 16 in below the S-IC/S-II separation plane, STA 1564
    /// (FER-501 §12.2.3), 116 in below the gimbals as on the S-IVB.
    static let sIIJ2GimbalStation = 1_664.0          // STA, D5-15481-1 Fig. 3-1 "GIMBAL STA 1664.000" (H)
    static let sIIJ2ExitStation = 1_548.0            // STA (M)
    static let sIIOutboardCircle = 17.5              // ft, diameter of the outboard J-2 circle, enginehistory.org (M)
    /// The S-IVB J-2's gimbal is S-IVB station 100, 100.65 in below the
    /// S-II/S-IVB separation plane (the aft skirt's bottom, STA 2746.5): the
    /// engine hangs inside the aft interstage. Its exit is where the bell
    /// had to travel 217 in to clear that plane (FER-501 §12.4.3).
    static let sIVBJ2GimbalStation = 2_645.85        // STA, D5-15481-1 Fig. 3-1 "GIMBAL STA 2645.853", AS-501 FER Fig. B-1 (H)
    static let sIVBJ2ExitStation = 2_529.5           // STA (M)

    /// LM stowed in the SLA: stowed geometry was not found.
    static let lmBottomHeight = 85.9                 // m, estimate (L)
    static let lmTopHeight = 90.9                    // m, estimate (L): clears the SPS exit at ≈ 91.08
    static let lmRadius = 2.1                        // m, estimate (L)
    /// The LM's CG in the SLA: FER Table 20-10's predicted "CSM separated"
    /// (33,093 kg at STA 3101.6) less its predicted "spacecraft separated"
    /// (17,980 kg at STA 2898.2) leaves exactly the FER's predicted LM,
    /// 15,113 kg, at STA 3343.6. The actual rows leave 15,436 kg at 3330.8:
    /// they also carry 341 kg the S-IVB lost (venting, APS) between the two
    /// events, which put back at the S-IVB gives 3343.6 again. (The same table's
    /// "CSM docked" less "CSM separated" is the CSM, 28,806 kg, the model's
    /// mass.)
    static let lmCenterOfMass = 3_343.6              // STA, derived from FER Table 20-10 (M)

    // MARK: Mass characteristics (FER Table 20-10, datasheet §13)

    /// A row of FER Table 20-10, "Mass Characteristics Comparison" (actual):
    /// mass (kg), longitudinal CG (STA, in), and the roll, pitch and yaw
    /// moments of inertia about that CG (kg m²). Read twice independently,
    /// every cell agreeing (H).
    struct MassRow {
        let mass: Double, station: Double, roll: Double, pitch: Double, yaw: Double
    }
    static let sICStageDry = MassRow(mass: 130_422, station: 368.8, roll: 2.591e6, pitch: 16.578e6, yaw: 16.496e6)
    /// With the small ring and the S-II ullage motors.
    static let sICSIIInterstageTotal = MassRow(mass: 5_255, station: 1_638.8, roll: 0.134e6, pitch: 0.080e6,
                                               yaw: 0.081e6)
    static let sIIStageDry = MassRow(mass: 36_158, station: 1_892.3, roll: 0.597e6, pitch: 1.997e6, yaw: 2.009e6)
    /// With the S-II retros.
    static let sIISIVBInterstageTotal = MassRow(mass: 3_650, station: 2_595.9, roll: 0.065e6, pitch: 0.043e6,
                                                yaw: 0.044e6)
    /// With the S-IVB's aft frame and its ullage motors' cases.
    static let sIVBStageDry = MassRow(mass: 11_273, station: 2_856.7, roll: 0.081e6, pitch: 0.296e6, yaw: 0.296e6)
    static let instrumentUnit = MassRow(mass: 1_940, station: 3_244.7, roll: 0.019e6, pitch: 0.010e6, yaw: 0.009e6)

    // Where each tank holds its load at first motion: the liquid's centroid
    // (STA, in), the ullage gas on top, from the tanks' geometry (datasheet
    // §13): AS-501 FER Fig. B-1 (stations), MSFC-MAN-506 (S-IC tank heights,
    // S-IVB volumes and ullages), the S-II technicians' manual (bulkheads,
    // a/b 1.5), TN D-3968 (S-IVB domes and common bulkhead, R 130 in). The
    // model's column keeps that centroid when full and drains towards its
    // aft end. The S-IC's include the propellant below the tanks, in the
    // suction lines and engines (FER Table 20-1 at holddown: 21,868 kg of
    // LOX and 5,983 kg of RP-1 of the 1,468,594 and 637,830 kg).
    static let sICLOXCentroid = 1_130.2          // the tank's 1,139.9 (ullage ~4.7 %, L) and the lines' at ~486 (L)
    static let sICRP1Centroid = 470.6            // the tank's 473.1 (aft Y-ring and ullage inferred, L) and the lines' at ~212 (L)
    /// The part of each S-IC load in its suction lines and engines that stays
    /// there to OECO, held below the tank proper, which the engines empty
    /// first (`PropellantTank.feedLines`): of the 21,868 kg of LOX and 5,983
    /// kg of RP-1 below the tanks at holddown, 16,761 and 5,946 kg at OECO
    /// (FER Table 20-1). The LOX lines' whole contents at about STA 486 run
    /// from the tank's bottom (772) down to about 200; drained from the top,
    /// the 16,761 kg left fill them to 638, whose middle is 419 (L). The RP-1
    /// barely drains (L). The whole loads' centroids above are unchanged.
    static let sICLOXLines = (mass: 16_761.0, station: 419.2)   // kg, FER Table 20-1 (H); STA (L)
    static let sICRP1Lines = (mass: 5_946.0, station: 212.0)    // kg, FER Table 20-1 (H); STA (L)
    static let sIILOXCentroid = 1_836.2          // ellipsoid 1716-1980, ullage 10-12 % (L)
    static let sIILH2Centroid = 2_196.0          // 1848-2519 over the common bulkhead, ullage 2.6-5.2 % (L)
    static let sIVBLOXCentroid = 2_788.05        // lens 2702-2880, ullage 108 of 2,830 ft³ (M)
    static let sIVBLH2Centroid = 3_007.97        // 2791-3230.56, ullage 300 of 10,400 ft³ (M)

    // Nominal liquid densities, kg/m^3 (they only set the column heights).
    static let loxDensity = 1_141.0
    static let rp1Density = 820.0
    static let lh2Density = 70.8

    // MARK: Aerodynamics (datasheet §11)
    //
    // The launch stack's static aerodynamics by configuration. Axial force in
    // the form the Saturn V flight evaluation used (Boeing D5-15796-1, June
    // 1969, for AS-502 and later, without base flow deflectors, as AS-506):
    // a forebody coefficient on q S plus a base force from the measured base
    // pressure differential, which follows altitude rather than Mach. Normal
    // force and centre of pressure: the TM X-53517 design curves (1966) as
    // REF504 Figs 3-3 and 3-4 print them, which the 1968 wind-tunnel summary
    // TM X-53770 (Fig 22(a)) matches within its ±6 % and ±0.2 caliber design
    // bands up to about M 5.5; at M 6-7.8 its fairing puts the centre of
    // pressure 0.23-0.33 caliber further forward and C_Nα up to 6.6 % lower
    // (q under about 2 kPa there). Figures were digitised from page images (M).

    /// Constant drag coefficient on the 33 ft parts, for a separated stage
    /// flying on its own (no data was sourced for those). Tests must not
    /// depend on it.
    static let bodyDragCoefficient = 0.45

    /// Reference diameter and area (396 in; π D²/4 = 855.3 ft²).
    static let aeroReferenceDiameter = 396.0 * inch     // m; TM X-53770, REF504 Figs 3-2 to 3-4 (H)
    static let aeroReferenceArea = Double.pi * aeroReferenceDiameter * aeroReferenceDiameter / 4
    /// Forebody axial-force coefficient against Mach: D5-15796-1 Fig 2-8, the
    /// AS-502/503 curve (no base flow deflectors).
    static let forebodyAxialCoefficient = LinearTable([
        (0, 0.141), (0.3, 0.141), (0.4, 0.142), (0.5, 0.142), (0.55, 0.150), (0.6, 0.153), (0.65, 0.159),
        (0.7, 0.166), (0.75, 0.179), (0.8, 0.203), (0.85, 0.243), (0.9, 0.285), (0.95, 0.343), (1.0, 0.397),
        (1.05, 0.436), (1.1, 0.477), (1.15, 0.537), (1.2, 0.559), (1.25, 0.562), (1.3, 0.558), (1.4, 0.534),
        (1.5, 0.505), (1.6, 0.490), (1.75, 0.465), (2.0, 0.430), (2.25, 0.407), (2.5, 0.388), (2.75, 0.373),
        (3.0, 0.361), (3.25, 0.352), (3.5, 0.341), (3.75, 0.325), (4.0, 0.302), (4.25, 0.277), (4.5, 0.257),
        (4.75, 0.242), (5.0, 0.229), (5.5, 0.207), (6.0, 0.189), (6.5, 0.175), (7.0, 0.163), (7.5, 0.154),
        (8.0, 0.147),
    ])   // D5-15796-1 Fig 2-8 (M)
    /// Base force F_Ab = -0.798 (P_b - P∞) S with the F-1s running.
    static let baseAreaFactor = 0.798                    // D5-15796-1 §2.3 (H)
    /// S-IC base pressure differential P_b - P∞ (Pa) against altitude (m),
    /// flown on AS-503, the first flight with the outboard cant: D5-15796-1
    /// Fig 2-7, altitude panel from 1 km (M; L at 6.5-10 km). Below 1 km the
    /// base pressure follows range time (§2.3): about -260 Pa at liftoff and
    /// -236 Pa by 10 s (time panel, M), placed at the model's altitudes of
    /// the centre of mass then (33 m on the pad; 138 m after the 105 m
    /// climb to 10 s, PFT); from there to 1 km the table interpolates (L).
    static let baseDifferential = LinearTable([
        (33, -260), (138, -236), (1_000, -1_030), (1_500, -1_190), (2_000, -1_430), (3_000, -2_140),
        (4_000, -2_910), (4_500, -3_190), (5_000, -3_470), (5_900, -3_600), (6_500, -3_510), (7_000, -3_350),
        (7_500, -3_100), (8_000, -2_400), (8_500, -1_800), (9_000, -1_100), (9_600, 0), (10_000, 600),
        (11_000, 1_780), (12_000, 2_490), (13_000, 3_180), (14_000, 3_620), (15_000, 3_920), (16_000, 4_080),
        (17_000, 4_150), (18_000, 4_080), (20_000, 3_790), (22_000, 3_370), (25_000, 2_870), (28_000, 2_000),
        (30_000, 1_550), (32_000, 1_140), (35_000, 730), (40_000, 330), (45_000, 180), (50_000, 0),
        (55_000, -40), (60_000, 0),
    ])
    /// Base axial-force coefficient with the F-1s off: TM X-53770 Fig 28,
    /// power-off (sting) wind-tunnel C_Ab, configuration 1 (M; L for flight:
    /// a model with base flow deflectors at a twentieth of flight Reynolds
    /// number). It flies only when the S-IC is aboard and not burning.
    static let unpoweredBaseCoefficient = LinearTable([
        (0.5, 0.47), (0.7, 0.45), (0.8, 0.43), (0.9, 0.47), (1.0, 0.65), (1.1, 0.64), (1.2, 0.58), (1.3, 0.53),
        (1.5, 0.42), (2.0, 0.28), (2.5, 0.18), (3.0, 0.125), (3.5, 0.09), (4.0, 0.075), (5.0, 0.045),
        (6.0, 0.03), (7.0, 0.02), (7.8, 0.015),
    ])
    /// Normal-force-coefficient slope (per degree) against Mach, S-IC flight
    /// configuration (the full stack with LES): REF504 Fig 3-3 (M).
    static let normalForceSlopePerDegree = LinearTable([
        (0, 0.0773), (0.1, 0.0774), (0.2, 0.0777), (0.3, 0.0785), (0.4, 0.0798), (0.5, 0.0818), (0.6, 0.0847),
        (0.7, 0.0886), (0.8, 0.0934), (0.9, 0.0987), (0.95, 0.0998), (0.98, 0.1000), (1.0, 0.0999),
        (1.05, 0.0994), (1.1, 0.0981), (1.2, 0.0939), (1.3, 0.0894), (1.4, 0.0855), (1.5, 0.0822),
        (1.75, 0.0774), (2.0, 0.0744), (2.25, 0.0727), (2.5, 0.0717), (2.75, 0.0713), (3.0, 0.0712),
        (3.5, 0.0711), (4.0, 0.0712), (4.5, 0.0710), (4.75, 0.0703), (5.0, 0.0699), (5.25, 0.0698),
        (5.5, 0.0701), (5.75, 0.0712), (6.0, 0.0731), (6.25, 0.0754), (6.5, 0.0780), (6.75, 0.0797),
        (7.0, 0.0802), (8.0, 0.0802),
    ])
    /// Centre of pressure, calibers forward of the S-IC gimbal station (STA
    /// 100), S-IC flight configuration: REF504 Fig 3-4 (M).
    static let centerOfPressureCalibers = LinearTable([
        (0, 3.50), (0.1, 3.494), (0.2, 3.481), (0.3, 3.442), (0.4, 3.396), (0.5, 3.334), (0.6, 3.250),
        (0.7, 3.140), (0.8, 3.002), (0.9, 2.838), (0.95, 2.795), (1.0, 2.842), (1.1, 3.052), (1.2, 3.284),
        (1.3, 3.503), (1.4, 3.702), (1.5, 3.88), (1.6, 4.020), (1.75, 4.197), (2.0, 4.352), (2.25, 4.414),
        (2.5, 4.432), (2.75, 4.447), (3.0, 4.453), (3.5, 4.46), (4.0, 4.449), (4.5, 4.445), (5.0, 4.441),
        (5.25, 4.451), (5.5, 4.486), (5.75, 4.545), (6.0, 4.673), (6.25, 4.844), (6.5, 4.980), (6.75, 5.066),
        (7.0, 5.088), (7.5, 5.092), (7.9, 5.101),
    ])
    static let sICGimbalStation = 100.0                  // in; TM X-53770, REF504 Fig 3-1 (H)
    /// S-II flight configuration (with LES; REF504 has nothing after the LET
    /// jettison, where q is under 0.1 kPa): REF504 Figs 3-2 to 3-4 (M), from
    /// M 5 (C_A) and M 4 (C_Nα, X_cp); held below. C_Nα is 0.0500 per degree
    /// throughout. No base term: the S-II flies above 60 km.
    static let sIIAxialCoefficient = LinearTable([
        (5.0, 0.283), (5.25, 0.279), (5.5, 0.277), (5.75, 0.274), (6.0, 0.270), (6.25, 0.265), (6.5, 0.260),
        (6.75, 0.255), (7.0, 0.251), (7.25, 0.245), (7.5, 0.240), (7.75, 0.234), (8.0, 0.227),
    ])
    static let sIINormalForceSlopePerDegree = 0.0500
    static let sIICenterOfPressureCalibers = LinearTable([
        (4.0, 2.858), (4.5, 2.858), (5.0, 2.864), (5.25, 2.917), (5.5, 3.025), (5.75, 3.175), (6.0, 3.299),
        (6.25, 3.364), (6.5, 3.385), (6.75, 3.396), (7.0, 3.401), (7.5, 3.402), (8.0, 3.397),
    ])
    static let sIIGimbalStation = 1_664.0                // in; REF504 Fig 3-1 (H): the S-II gimbal plane (sIIJ2GimbalStation)
    /// S-IVB stage flight: a constant free-molecular-flow drag coefficient on
    /// 33.47 m², along the relative wind, no lift (REF504 §3.1, from
    /// R-AERO-AD-66-54).
    static let sIVBDragCoefficient = 2.8024              // REF504 §3.1 (H)
    static let sIVBDragArea = 33.47                      // m², REF504 §3.1 (H)
    /// Viscous crossflow beyond the linear range, for large angles of attack
    /// only: η C_dc of a slender body (η about 0.65, C_dc 1.2; Jorgensen, NASA
    /// TR R-474, 1977; L, generic), from 4°, where TM X-53770 finds C_N
    /// linear to about ±2-4°.
    static let crossflow = (coefficient: 0.8, linearAngle: 4.0 * degree)

    /// The Saturn V's aerodynamic models, full stack first.
    static var aerodynamics: [AerodynamicModel] {
        let perDegree = 1 / degree
        return [
            AerodynamicModel(
                name: "Apollo/Saturn V, S-IC flight configuration",
                requiredParts: ["S-IC", "S-II", "S-IVB"], referenceArea: aeroReferenceArea,
                referenceDiameter: aeroReferenceDiameter, referenceStation: station(sICGimbalStation),
                forebodyAxial: forebodyAxialCoefficient,
                base: .init(areaFactor: baseAreaFactor, poweredDifferential: baseDifferential, enginesPart: "S-IC",
                            unpoweredCoefficient: unpoweredBaseCoefficient),
                normalForceSlope: LinearTable(normalForceSlopePerDegree.points.map { ($0.x, $0.y * perDegree) }),
                centerOfPressure: centerOfPressureCalibers, crossflow: crossflow),
            AerodynamicModel(
                name: "Apollo/Saturn V, S-II flight configuration",
                requiredParts: ["S-II", "S-IVB"], referenceArea: aeroReferenceArea,
                referenceDiameter: aeroReferenceDiameter, referenceStation: station(sIIGimbalStation),
                forebodyAxial: sIIAxialCoefficient,
                normalForceSlope: LinearTable([(0, sIINormalForceSlopePerDegree * perDegree)]),
                centerOfPressure: sIICenterOfPressureCalibers, crossflow: crossflow),
            AerodynamicModel(
                name: "S-IVB stage, free-molecular flow",
                requiredParts: ["S-IVB"], referenceArea: sIVBDragArea, referenceDiameter: aeroReferenceDiameter,
                referenceStation: 0, forebodyAxial: LinearTable([(0, sIVBDragCoefficient)]), dragAlongWind: true),
        ]
    }

    // MARK: Launch-day atmosphere (datasheet §11)
    //
    // 16 July 1969 at Cape Kennedy, from the FER's Appendix A: temperature,
    // pressure and density as deviations from the Patrick AFB 1963 Reference
    // Atmosphere (PRA-63, NASA TM X-53139, Table III, read from the page
    // images: H), digitised from FER Figs A-6 and A-7 (M), and the
    // Jimsphere/rawinsonde winds of Figs A-3 and A-4 (M), to 56 km; above it
    // the FER merged the measured data into the U.S. Standard Atmosphere, and
    // the model fades the day's ratios and winds out over 10 km into US-1976.

    /// PRA-63 kinetic temperature (K), pressure (Pa), density (kg/m³) and
    /// speed of sound (m/s) by geometric altitude (km), and the FER's
    /// deviations (%) of temperature, pressure and density. The 7.8 and
    /// 13.6 km rows (Mach 1 and max Q) interpolate PRA-63's 250 m rows.
    static let launchDaySounding: [(km: Double, t: Double, p: Double, rho: Double, a: Double,
                                    dT: Double, dP: Double, dRho: Double)] = [
        (0, 296.68, 101_701.5, 1.1835, 346.9, 1.80, 0.20, -2.10),
        (1, 290.59, 90_603.4, 1.0793, 342.8, 1.86, 0.57, -1.49),
        (2, 285.33, 80_521.2, 0.97903, 339.3, 1.23, 0.84, -0.59),
        (3, 280.25, 71_395.1, 0.88526, 336.0, 0.79, 0.95, 0.22),
        (4, 274.92, 63_151.7, 0.79916, 332.6, 0.54, 1.04, 0.64),
        (5, 269.09, 55_714.3, 0.72084, 329.0, 0.36, 1.19, 0.90),
        (6, 262.68, 49_008.9, 0.64983, 324.9, 0.65, 1.33, 0.62),
        (7, 255.72, 42_968.0, 0.58535, 320.6, 1.16, 1.53, 0.33),
        (7.8, 249.84, 38_572.6, 0.53787, 316.9, 1.80, 1.73, -0.12),
        (8, 248.34, 37_532.0, 0.52652, 315.9, 1.85, 1.76, -0.17),
        (9, 240.73, 32_649.9, 0.47249, 311.0, 1.95, 2.15, -0.14),
        (10, 233.14, 28_277.6, 0.42255, 306.1, 2.29, 2.40, 0.05),
        (11, 225.68, 24_373.1, 0.37638, 301.2, 2.12, 2.76, 0.65),
        (12, 218.82, 20_909.3, 0.33302, 296.5, 1.81, 3.16, 1.31),
        (13, 212.89, 17_861.1, 0.29232, 292.5, 0.60, 3.35, 2.65),
        (13.6, 209.90, 16_219.0, 0.26917, 290.4, -0.56, 3.33, 3.79),
        (14, 208.16, 15_199.0, 0.25433, 289.2, -0.69, 3.30, 4.10),
        (15, 204.83, 12_892.9, 0.2192, 286.9, -0.33, 3.20, 3.62),
        (16, 203.04, 10_911.8, 0.18718, 285.7, -0.03, 3.25, 3.21),
        (17, 202.86, 9_225.3, 0.15846, 285.5, 1.23, 3.45, 2.19),
        (18, 205.30, 7_809.7, 0.13239, 287.2, 0.98, 3.70, 2.81),
        (19, 207.79, 6_626.0, 0.11096, 289.0, 0.87, 3.78, 3.13),
        (20, 210.35, 5_631.6, 0.093194, 290.8, 0.39, 3.85, 3.65),
        (21, 212.91, 4_794.9, 0.078448, 292.5, -0.17, 4.18, 4.28),
        (22, 215.37, 4_089.9, 0.066193, 294.2, 0.01, 4.22, 4.30),
        (24, 219.81, 2_991.9, 0.047479, 297.2, 0.83, 4.35, 3.37),
        (26, 223.45, 2_203.8, 0.034382, 299.7, 2.10, 4.76, 2.50),
        (28, 226.44, 1_632.7, 0.025119, 301.7, 2.21, 5.41, 3.22),
        (30, 230.79, 1_214.6, 0.018334, 304.5, 0.55, 5.80, 5.31),
        (32, 235.32, 909.1, 0.013458, 307.5, 0.44, 5.85, 5.34),
        (34, 240.07, 684.3, 0.0099301, 310.6, 1.19, 6.20, 4.81),
        (36, 245.04, 518.1, 0.0073654, 313.8, 2.00, 6.71, 4.49),
        (38, 250.16, 394.5, 0.0054934, 317.1, 2.10, 7.30, 5.00),
        (40, 255.31, 302.1, 0.004122, 320.3, 2.50, 7.81, 5.15),
        (42, 260.28, 232.6, 0.0031135, 323.4, 2.13, 8.49, 6.25),
        (44, 264.82, 180.0, 0.0023685, 326.2, 0.63, 8.96, 8.38),
        (46, 268.59, 139.9, 0.0018152, 328.5, -1.32, 8.74, 10.20),
        (48, 271.19, 109.1, 0.0014016, 330.1, -1.21, 8.39, 9.48),
        (50, 270.61, 85.2, 0.0010966, 329.8, -0.67, 8.20, 8.75),
        (52, 267.31, 66.4, 0.00086527, 327.8, -0.53, 7.82, 8.33),
        (54, 263.13, 51.6, 0.00068253, 325.2, 0.59, 7.83, 7.17),
        (56, 258.26, 39.9, 0.00053757, 322.2, 0.41, 8.20, 7.60),
    ]
    /// Winds aloft by geometric altitude (km): W_x, the tail wind along the
    /// 72.058° flight azimuth, and W_z, positive towards the right of it
    /// (m/s): FER Figs A-3 and A-4 (M), and at the surface Table A-1's
    /// 3.3 m/s from 175° on the pad's 18.3 m pole (H). Where the curve lay on
    /// a gridline (41-43, 47, 56 km), W_x is recomputed from Figs A-1/A-2.
    static let launchDayWinds: [(km: Double, wx: Double, wz: Double)] = [
        (0, 0.7, -3.2), (0.1, -0.4, -2.5), (0.5, 0.7, -3.8), (1, 1.3, -4.0), (1.5, 2.2, -4.9), (2, 2.5, -3.0),
        (2.5, 2.7, -4.0), (3, 2.9, -5.0), (3.5, 3.7, -4.6), (4, 3.8, -4.5), (4.5, 5.0, -5.8), (5, 6.2, -4.8),
        (5.5, 7.1, -5.2), (6, 6.9, -4.6), (6.5, 5.4, -3.2), (7, 3.3, 0.1), (7.5, 2.4, 0.0), (8, 5.6, 0.1),
        (8.5, 6.1, -0.8), (9, 4.1, 1.6), (9.5, 2.1, 2.0), (10, 2.0, 5.8), (10.5, 3.0, 4.7), (11, 6.4, 4.7),
        (11.3, 6.6, 6.7), (11.5, 5.7, 5.8), (12, 5.6, 6.1), (12.5, 5.5, 3.7), (13, 5.1, 3.6), (13.5, 5.4, 1.7),
        (14, 5.7, 1.5), (14.5, 1.6, 5.2), (15, 0.0, 3.1), (15.5, -2.0, 5.9), (16, -7.1, 0.9), (16.5, -6.3, -3.4),
        (17, -7.0, -5.4), (17.5, -8.3, -4.0), (18, -10.8, -1.9), (18.5, -13.2, -3.1), (19, -11.1, -4.0),
        (19.5, -12.8, -3.9), (20, -13.9, -3.3), (21, -16.8, -6.5), (22, -19.9, -6.5), (23, -19.4, -8.4),
        (24, -18.5, -8.7), (25, -16.6, -7.0), (26, -16.1, -5.0), (27, -18.9, -3.5), (28, -22.7, -4.4),
        (29, -25.6, -6.0), (30, -26.2, -9.9), (31, -24.8, -12.9), (32, -23.6, -16.5), (33, -22.5, -16.3),
        (34, -23.7, -14.0), (35, -27.7, -10.6), (36, -29.6, -8.5), (37, -33.1, -6.0), (38, -36.5, -3.8),
        (39, -39.2, -5.5), (40, -40.7, -8.2), (41, -40.4, -11.2), (42, -40.1, -12.6), (43, -39.9, -15.4),
        (44, -39.8, -18.0), (45, -42.8, -20.2), (46, -46.1, -18.8), (47, -49.9, -20.1), (48, -52.7, -20.8),
        (49, -54.4, -23.0), (50, -53.9, -25.1), (51, -55.0, -23.7), (52, -56.9, -21.5), (53, -57.9, -18.8),
        (54, -56.5, -19.8), (55, -55.5, -21.1), (56, -56.5, -23.9),
    ]

    /// The launch-day atmosphere: PRA-63 times the FER's deviations (the
    /// speed of sound with the root of the temperature's), and the winds
    /// turned from the flight azimuth's axes to east and north.
    static func launchDayAtmosphere() -> SoundingAtmosphere {
        let levels = launchDaySounding.map { r in
            SoundingAtmosphere.Level(altitude: r.km * 1_000, state: AtmosphereState(
                temperature: r.t * (1 + r.dT / 100), pressure: r.p * (1 + r.dP / 100),
                density: r.rho * (1 + r.dRho / 100), speedOfSound: r.a * (1 + r.dT / 100).squareRoot()))
        }
        let az = flightAzimuth * degree
        let winds = launchDayWinds.map { w in
            (altitude: w.km * 1_000, east: w.wx * sin(az) + w.wz * cos(az), north: w.wx * cos(az) - w.wz * sin(az))
        }
        return SoundingAtmosphere(levels: levels, winds: winds)
    }

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
    /// Per module: AS-506's loads (FER Table 7-5, read from the page image;
    /// AS-507 loaded 405 and 252 lb in all). They leave `sIVBOther`, so the
    /// S-IVB part total is unchanged.
    static let apsOxidizerLoad = 203.0               // lb N2O4, FER Table 7-5 (H)
    static let apsFuelLoad = 126.0                   // lb MMH, FER Table 7-5 (H)
    /// Feed mixture ratio: the load ratio, 1.611, so both tanks empty together
    /// (the engines' operating ratio was not found).
    static let apsMixtureRatio = apsOxidizerLoad / apsFuelLoad   // derived (M): 203 / 126 lb = 1.611

    /// APS control logic (datasheet §7.2): an attitude dead band on each
    /// axis, error limits that bound the manoeuvre rate, a rate term and a
    /// minimum pulse.
    static let apsDeadband = 1.0                     // deg each axis (2° effective band), EH 8.30; ASTP SA-210; MAN503 p. 6-22 (M)
    static let apsErrorLimitPitchYaw = 2.5           // deg, EH 8.30; MAN503 p. 6-22 (M)
    static let apsErrorLimitRoll = 3.5               // deg, EH 8.30; MAN503 p. 6-22 (M)
    /// Switching line e - K w: the Astrionics System Handbook's typical S-IVB
    /// APS dead bands (MSFC IV-4-401-1 §3.4, Figures 3.4-5 roll and 3.4-6
    /// coast, p. 3.4-6) cross ±1° at zero rate and ±0.2°/s at zero error, so
    /// K = 1° / 0.2°/s; Figure 3.4-5's roll lines level off beyond the 3.5°
    /// clip, at 0.52 and 0.92°/s. "Typical", not AS-506's own (M). With the
    /// limits it gives manoeuvre rates of 0.3°/s in pitch and yaw, 0.5°/s in
    /// roll. Not modelled: Figure 3.4-6's intermittent-firing band (pulses
    /// from the dead band line out to 1.6° on e - K w, full thrust beyond).
    static let apsRateGain = 5.0                     // s, ASH Figures 3.4-5 and 3.4-6 (M)
    /// Minimum on-time at full thrust: the 7.5 lbf s minimum impulse bit
    /// (APS-TN, M-H) is 51 ms at 147 lbf; three 0.02 s steps give 39.2 N s.
    static let apsMinimumOnTime = 0.06               // s, derived
    static var apsLaw: PhasePlaneLaw {
        PhasePlaneLaw(deadband: apsDeadband * degree,
                      errorLimit: Vec3(apsErrorLimitRoll, apsErrorLimitPitchYaw, apsErrorLimitPitchYaw) * degree,
                      rateGain: apsRateGain, minimumOnTime: apsMinimumOnTime)
    }
}

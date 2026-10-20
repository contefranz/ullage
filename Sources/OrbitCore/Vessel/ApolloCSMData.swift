import Foundation

/// The Apollo Block II command and service module (CSM) after orbit
/// insertion, as Apollo 7 and Apollo 11 flew it: the service module (SM) and
/// its service propulsion system (SPS) and SM RCS, the spacecraft-LM adapter
/// (SLA), the separations, and the Mission Reports' mass rows the model is
/// built and checked on. The command module is `ApolloCM`'s.
///
/// Values keep their source unit and a grade, as `AS506`'s do: (H) high, (M)
/// medium, (L) low. The transcriptions are track D's, read from the page
/// images by two readers (tools/data: 68fm184_table1bcd_csm.csv,
/// 68fm184_sec5_events.csv, aoh_block2_sps_rcs.csv, 68fm160_sla_panels.csv,
/// msc03466_sm_jettison.csv, a07_mr_table_a5_1.csv, a07_mr_table_3_3.csv,
/// a07_mr_sec5_21_consumables.csv, a11_mr_table_a_1.csv,
/// a11_mr_sec8_11_consumables.csv; the log is
/// docs/data/apollo-spacecraft/README.md).
///
/// Everything is placed in Apollo axes through `ApolloAxes` (X_A towards the
/// apex, station inches; +Y_A and +Z_A are the Saturn's -y and -z). Angles
/// round the axis run from +Y_A towards +Z_A, as AOH Fig. 2.4-3 draws them.
public enum ApolloCSM {
    public typealias Mission = ApolloCM.Mission

    // MARK: Units

    static let inch = AS506.inch
    static let pound = AS506.pound
    static let poundForce = AS506.poundForce
    static let degree = AS506.degree
    static let foot = AS506.foot

    // MARK: Service module structure

    /// The SM's bounding cylinder: the SLA top (the SM's aft end) to the
    /// SM/CM interface (`AS506.slaTop`, `AS506.smTop`, L) and the 154 in
    /// diameter (`AS506.csmDiameter`, M).
    static let smBottom = AS506.slaTop
    static let smTop = AS506.smTop
    /// The CSM's drag in orbit: 68-FM-184 Table I(d)'s coefficient 2.0 on
    /// 129.5 ft² (H), as the SM's own drag once alone.
    static let csmDragCoefficient = 2.0
    static let csmDragArea = 129.5                       // ft² (H)

    // MARK: SPS (AJ10-137)

    /// 68-FM-184 Table I(b), from its reference 22 (H): steady thrust,
    /// vacuum Isp and flow (21,080 / 312.34 = 67.49 lb/s), and the build-up
    /// and tail-off "delta T". The model takes the delta Ts as the lengths of
    /// linear ramps, so the tail-off gives 0.27 s of full thrust after the
    /// cutoff signal (M): Apollo 7 fits it. SPS-5 (67.1 s) and SPS-8 (11.9
    /// s) dropped the CSM's weight by 4,530 and 809 lb (Mission Report
    /// Table A.5-I), 1 and 6 lb more than their steady flow, and SPS-8's
    /// entry interface comes within 2 s of the flight's (`Apollo7DeorbitTests`);
    /// as 0.54 s of full thrust the tail-off would burn 36 lb more and put
    /// entry interface 13 s early.
    static let spsThrust = 21_080.0                      // lbf (H)
    static let spsIsp = 312.34                           // s (H)
    static let spsFlow = 67.49                           // lb/s (H)
    static let spsBuildupDelay = 0.015                   // s (H; a ramp: M)
    static let spsTailoffDelay = 0.54                    // s (H; a ramp: M)
    /// Oxidizer/fuel: AOH p. 2.4-1's 1.6 (Apollo 7 burned 4,812.4 / 2,998.7
    /// = 1.605, Mission Report §5.21).
    static let spsMixtureRatio = 1.6                     // (H)
    /// Nozzle extension exit, inside diameter, and expansion ratio (AOH p.
    /// 2.4-43, H).
    static let spsExitDiameter = 98.4                    // in (H)
    static let spsExpansionRatio = 62.5                  // (H)
    /// Gimbal travel about the thrusting nulls, ±4.5° (+0.5°, -0.0°) in pitch
    /// and yaw; the nulls under thrust lean the thrust 2° towards +Z_A (pitch,
    /// about Y) and 1° towards +Y_A (yaw, about Z), for the offset centre of
    /// mass; not thrusting they are 1.5° and 0° (AOH pp. 2.4-14, 2.4-15,
    /// 2.4-44, H). Actuator rate 0.12-0.132 rad/s; the lower bound (H).
    static let spsGimbalTravel = 4.5                     // deg (H)
    static let spsPitchNull = 2.0                        // deg, thrust towards +Z_A (H)
    static let spsYawNull = 1.0                          // deg, thrust towards +Y_A (H)
    static let spsGimbalRate = 0.12                      // rad/s (H)
    /// Ullage is mandatory at or below 22,300 lb of SPS propellant (AOH p.
    /// 2.4-2, M): not enforced; the HUD hints at it.
    static let spsUllageThreshold = 22_300.0             // lb (M)

    /// The four tanks, lumped per propellant (the storage tank feeds the
    /// sump in series; the model drains them together): capacities (AOH p.
    /// 2.4-42, H), their heights and inside diameters (H), and where they
    /// stand. The SM's six sectors (CSM News Reference ch. 7: 50°, 70°, 60°,
    /// 50°, 70°, 60°, M) put the oxidizer sump round +Y_A (sector 2), the
    /// oxidizer storage between +Y_A and +Z_A just short of +Z_A (sector 3),
    /// the fuel sump round -Y_A (sector 5) and the fuel storage between -Y_A
    /// and -Z_A (sector 6), as AOH Fig. 2.4-3 draws them (M): their middles
    /// at 0°, 65°, 180° and 245°, the tanks' axes 49 in out between the 44 in
    /// centre section and the 154 in skin (L).
    static let oxidizerStorage = 11_284.69               // lb (H)
    static let oxidizerSump = 13_923.72                  // lb (H)
    static let fuelStorage = 7_058.36                    // lb (H)
    static let fuelSump = 8_708.10                       // lb (H)
    static let storageHeight = 154.47, sumpHeight = 153.8           // in (H)
    static let storageDiameter = 45.0, sumpDiameter = 51.0          // in (H)
    static let oxidizerSumpAngle = 0.0, oxidizerStorageAngle = 65.0  // deg (L)
    static let fuelSumpAngle = 180.0, fuelStorageAngle = 245.0       // deg (L)
    static let tankRadius = 49.0                         // in (L)
    /// The propellant's aft end, fitted to Apollo 7's CG travel over its SPS
    /// burns (Table A.5-I rows 7-17 within 0.4 in at Xa 834, 2.3 in at Xa
    /// 845; M): a little below the SLA top, where the tanks' lower domes
    /// sit in the aft bulkhead.
    static let tankBottom = 834.0                        // Xa (M)
    /// The propellant in the lines, below the tanks (Mission Reports'
    /// loadings, H), between the sumps and the engine (L).
    static let lineStation = 838.0, lineRadius = 24.5    // Xa, in (L)

    /// SPS gimbal and nozzle exit stations (datasheet §4, L).
    static var spsGimbalStation: Double { AS506.spsGimbalStation }
    static var spsExitStation: Double { AS506.spsExitStation }

    /// The SPS loading, (oxidizer, fuel) in lb, lines included, and what the
    /// lines hold: Apollo 7 Mission Report §5.21 (oxidizer 5,903 + 123.7,
    /// fuel 3,632 + 78.6) and Apollo 11 Mission Report §8.11 (24,967 + 124,
    /// 15,633 + 79), H. Apollo 7 loaded about a quarter of the tanks'
    /// capacity: its load fits the sumps, which a series feed drains last,
    /// so its tanks are the sumps alone (L).
    static func spsLoad(_ m: Mission) -> (oxidizer: Double, fuel: Double, oxidizerLines: Double, fuelLines: Double) {
        switch m {
        case .apollo7: return (6_026.7, 3_710.6, 123.7, 78.6)
        case .apollo11: return (25_091, 15_712, 124, 79)
        }
    }

    // MARK: SM RCS (16 Marquardt R-4D)

    /// 68-FM-184 Table I(b), reference 23: 399.2 lbf from four jets (99.8
    /// lbf each, H) at 276.0 s (M), 1.45 lb/s. These are the effective
    /// values along X_A: the engines' 10° cant away from their panel (AOH
    /// p. 2.5-1) is not modelled.
    static let rcsFourJetThrust = 399.2                  // lbf (H)
    static let rcsIsp = 276.0                            // s (M)
    /// Oxidizer/fuel 2:1 (AOH §2.5; Apollo 7 loaded 898.4 / 443.3 = 2.03, M).
    static let rcsMixtureRatio = 2.0
    /// The quads, 90° apart and turned 7°15′ from the ±Y_A/±Z_A axes,
    /// counterclockwise looking forward (AOH p. 2.5-1, H; Fig. 2.4-3, M):
    /// A at -Z_A towards -Y_A, B at +Y_A towards -Z_A, C at +Z_A towards
    /// +Y_A, D at -Y_A towards +Z_A.
    static let quadAngles: [(name: String, angle: Double)] = [
        ("A", 262.75), ("B", 352.75), ("C", 82.75), ("D", 172.75),
    ]
    /// Quad station (datasheet §4, L), the engines' radius on the quad
    /// housings outside the 154 in skin, and the quads' tanks inside it (L).
    static var quadStation: Double { AS506.smRCSQuadStation }
    static let quadRadius = 84.0                         // in (L)
    static let quadTankRadius = 66.0                     // in (L)
    /// Loads per quad (fuel, oxidizer), lb: Apollo 7 Mission Report §5.21
    /// and Apollo 11 Mission Report §8.11 (H).
    static func rcsLoads(_ m: Mission) -> [(fuel: Double, oxidizer: Double)] {
        switch m {
        case .apollo7: return [(111.3, 223.7), (110.6, 223.7), (110.8, 225.9), (110.6, 225.1)]
        case .apollo11: return [(110, 225), (110, 225), (110, 225), (110, 225)]
        }
    }

    // MARK: Spacecraft-LM adapter (SLA)

    /// AS-506's SLA (FER Tables 20-7 and 20-9, H): four panels of 1,166 kg in
    /// all, and the ring that stays on the S-IVB, 626 kg. 68-FM-160's panels
    /// weigh 593 lb, springs included (H); the FER's are AS-506's own.
    static let slaPanels = 1_166.0                       // kg (H)
    static let slaRing = 626.0                           // kg (H)
    /// The panels' hinge line: the lower 7 ft of the 28 ft SLA is the ring,
    /// the upper 21 ft the panels (L).
    static var slaHinge: Double { AS506.slaHingeStation }
    /// MSC IN 68-FM-160 (H): panels 1-4 at +Z_A, -Z_A, +Y_A and -Y_A; turning
    /// at 33.5°/s or more as they deploy; leaving at 8 ft/s or more, at 110° ±
    /// 20° from the S-IVB's +X; tumbling drag coefficient 1.7 on 239 ft².
    static let panelAngles = [90.0, 270.0, 0.0, 180.0]  // deg, panels 1-4
    static let panelRate = 33.5                          // deg/s (H)
    static let panelSpeed = 8.0                          // ft/s (H)
    static let panelDirection = 110.0                    // deg from +X (H)
    static let panelArea = 239.0                         // ft² (H)
    static let panelDragCoefficient = 1.7                // (H)

    // MARK: Separations

    /// CSM/LV separation: the automatic +X ullage that stands in for the
    /// crew's +X translation through the CSM/LV SEP push (AOH p. 2.5-21:
    /// +X, then the button held 2 s); 3 s by owner decision. Apollo 7 fired
    /// its four +X jets for 2.6 s for 1.0 ft/s (68-FM-184 §5.1.4, H).
    static let separationUllage = 3.0                    // s
    /// The SM jettison controller before Apollo 13 (MSC-03466 p. 1, H): the
    /// four -X jets from separation to propellant depletion, the four roll
    /// jets from 2 s for 5.5 s.
    static let jettisonRollStart = 2.0                   // s (H)
    static let jettisonRollDuration = 5.5                // s (H)
    /// CM/SM separation needs a second Space press within this many seconds
    /// (owner decision 10).
    static let separationGuard = 2.0                     // s

    // MARK: Attitude control

    /// The SCS's attitude dead bands, narrow and wide (the CMC's DAP options,
    /// owner decision 8): a phase-plane law on the SM RCS that turns at 2°/s
    /// at most (the DAP's fastest manoeuvre rate but one; L), on a 2.5 s
    /// switching line (L), with the R-4D's 14 ms minimum pulse (L).
    static let narrowDeadband = 0.5                      // deg
    static let wideDeadband = 5.0                        // deg
    static let manoeuvreRate = 2.0                       // deg/s (L)
    static let rateGain = 2.5                            // s (L)
    static let minimumPulse = 0.014                      // s (L)

    /// The attitude law on the axes the SPS gimbal flies (pitch and yaw
    /// while it burns; the SM RCS flies roll): M0's gimbal law at its
    /// defaults, which the SPS's 0.65 s stop-to-stop actuators can follow.
    static let spsTVCGains = TVCGains()

    static func phasePlaneLaw(deadband: Double) -> PhasePlaneLaw {
        let limit = (deadband + manoeuvreRate * rateGain) * degree
        return PhasePlaneLaw(deadband: deadband * degree, errorLimit: Vec3(limit, limit, limit),
                             rateGain: rateGain, minimumOnTime: minimumPulse)
    }

    // MARK: Apollo 7's deorbit (Mission Report Tables 2-I and 3-III, §5.16)

    /// Apollo 7's range zero, 1968-10-11 15:02:45 UTC: GET 0 (Table 2-I, H).
    public static let apollo7RangeZero = Epoch(utcYear: 1968, month: 10, day: 11, hour: 15, minute: 2, second: 45)

    /// A trajectory state as Table 3-III lists it: GET (s), geodetic latitude
    /// and longitude (deg, east positive), altitude above the reference
    /// ellipsoid (ft; MSC's Fischer 1960), and the space-fixed speed (ft/s),
    /// flight-path angle and heading east of north (deg).
    struct TrajectoryState {
        let groundElapsedTime: Double
        let latitude, longitude, altitude: Double
        let speed, flightPathAngle, heading: Double
    }
    /// SPS-8, the deorbit burn, as flown (Table 3-III, H; the ignition's
    /// time is misprinted 259:31:16.3 there and is Table 2-I's 259:39:16.3).
    static let apollo7SPS8Ignition = TrajectoryState(groundElapsedTime: 934_756.3, latitude: 13.83, longitude: -148.65,
                                                     altitude: 1_143_579, speed: 25_155.3, flightPathAngle: -0.988,
                                                     heading: 63.20)
    static let apollo7SPS8Cutoff = TrajectoryState(groundElapsedTime: 934_768.2, latitude: 14.19, longitude: -147.98,
                                                   altitude: 1_137_041, speed: 24_966.5, flightPathAngle: -1.643,
                                                   heading: 63.38)
    /// CM/SM separation, 259:43:33.8 (Table 2-I, H).
    static let apollo7CMSMSeparation = 935_013.8         // GET s (H)
    /// Entry interface, 400,000 ft, at 259:53:27 (Table 2-I, H), at the
    /// onboard computer's 25,846.4 ft/s and -2.072° (§5.16, H).
    static let apollo7EntryInterface = (groundElapsedTime: 935_607.0, altitude: 400_000.0, speed: 25_846.4,
                                        flightPathAngle: -2.072)
    /// The EMS counter's load for SPS-8: the Δv along X_A the model's SPS
    /// gives from Z at the flight's ignition to its cutoff signal 11.9 s
    /// later (`Apollo7DeorbitTests`), so the counter cuts it off when the
    /// flight's did. Table 3-III's states imply 104.8 m/s in all, tail-off
    /// and gravity's share included.
    static let apollo7SPS8CounterLoad = 102.8            // m/s

    // MARK: Mass rows

    typealias MassRow = ApolloCM.MassRow

    /// Apollo 7 Mission Report Table A.5-I, p. A-47 (H): the spacecraft at
    /// each event (rows 3-17: an SPS row is the ignition, the "Coast" row
    /// after it the cutoff).
    static let apollo7Rows: [Int: MassRow] = [
        3: MassRow(weight: 32_356, xa: 950.4, ya: 1.4, za: 6.0,
                   ixx: 18_129, iyy: 56_210, izz: 59_982, ixy: -1_747, ixz: 595, iyz: -32),
        7: MassRow(weight: 30_671, xa: 953.0, ya: 1.1, za: 6.2,
                   ixx: 17_446, iyy: 55_085, izz: 58_219, ixy: -1_578, ixz: 559, iyz: -90),
        8: MassRow(weight: 30_050, xa: 954.4, ya: 0.9, za: 6.3,
                   ixx: 17_096, iyy: 54_373, izz: 57_175, ixy: -1_475, ixz: 511, iyz: -127),
        9: MassRow(weight: 29_780, xa: 954.5, ya: 1.0, za: 6.3,
                   ixx: 17_057, iyy: 54_309, izz: 57_123, ixy: -1_495, ixz: 531, iyz: -110),
        10: MassRow(weight: 29_731, xa: 954.7, ya: 1.0, za: 6.3,
                    ixx: 17_032, iyy: 54_253, izz: 57_044, ixy: -1_487, ixz: 527, iyz: -113),
        11: MassRow(weight: 29_607, xa: 954.7, ya: 1.1, za: 6.1,
                    ixx: 16_978, iyy: 54_159, izz: 56_973, ixy: -1_500, ixz: 531, iyz: -90),
        12: MassRow(weight: 25_077, xa: 969.7, ya: -0.7, za: 7.0,
                    ixx: 14_632, iyy: 45_675, izz: 46_274, ixy: -505, ixz: 77, iyz: -330),
        13: MassRow(weight: 24_975, xa: 969.9, ya: -0.7, za: 6.8,
                    ixx: 14_599, iyy: 45_594, izz: 46_202, ixy: -532, ixz: 111, iyz: -314),
        14: MassRow(weight: 24_927, xa: 970.1, ya: -0.7, za: 6.9,
                    ixx: 14_574, iyy: 45_459, izz: 46_044, ixy: -518, ixz: 105, iyz: -316),
        15: MassRow(weight: 24_864, xa: 970.2, ya: -0.6, za: 6.8,
                    ixx: 14_556, iyy: 45_412, izz: 46_000, ixy: -535, ixz: 128, iyz: -308),
        16: MassRow(weight: 24_295, xa: 972.9, ya: -0.9, za: 6.9,
                    ixx: 14_268, iyy: 43_773, izz: 44_090, ixy: -368, ixz: 54, iyz: -336),
        17: MassRow(weight: 24_262, xa: 973.0, ya: -0.9, za: 6.9,
                    ixx: 14_262, iyy: 43_748, izz: 44_062, ixy: -383, ixz: 77, iyz: -331),
        18: MassRow(weight: 23_453, xa: 977.2, ya: -1.3, za: 7.1,
                    ixx: 13_829, iyy: 40_971, izz: 40_878, ixy: -110, ixz: -45, iyz: -373),
    ]
    /// The Apollo 7 burns' weight drops, ignition row less the next row (lb):
    /// SPS-1 to SPS-8 at rows 3, 5, 7, 9, 11, 13, 15 and 17, summing to 7,809
    /// lb against the 7,811.1 lb the Mission Report's §5.21 says the SPS
    /// burned; SPS-8's includes the 4 min coast to CM/SM separation.
    static let apollo7BurnDrops: [Int: Double] = [3: 645, 5: 538, 7: 621, 9: 49, 11: 4_530, 13: 48, 15: 569, 17: 809]
    /// What Apollo 7 had left at CM/SM separation (Mission Report §5.21, H):
    /// SPS oxidizer and fuel, lb; and the SM RCS's 397.9 lb, split here as
    /// loaded, 2.03:1.
    static let apollo7SPSAtSeparation = (oxidizer: 1_214.3, fuel: 711.9)
    static let apollo7RCSAtSeparation = 397.9

    /// Apollo 11 Mission Report Table A-I, p. A-11 (H).
    static let apollo11Insertion = MassRow(weight: 100_756.4, xa: 807.2, ya: 2.6, za: 4.1,
                                           ixx: 67_108, iyy: 713_136, izz: 715_672,
                                           ixy: 4_745, ixz: 11_341, iyz: 3_318)
    static let apollo11Docking = MassRow(weight: 63_473.0, xa: 934.0, ya: 4.0, za: 6.5,
                                         ixx: 34_445, iyy: 76_781, izz: 79_530,
                                         ixy: -1_789, ixz: -126, iyz: 3_148)
    /// The FER's CSM at launch, 28,806 kg (63,506.3 lb), is 33.3 lb more than
    /// Table A-I's CSM at transposition and docking: the model books it as
    /// the SM RCS propellant used by then (L), so the CSM it builds is the
    /// FER's at launch and the table's at docking.
    static let apollo11RCSUsedByDocking = AS506.csm / AS506.pound - 63_473.0
}

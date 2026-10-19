import Foundation

/// The Apollo Block II command module (CM) as Apollo 7 and Apollo 11 flew it:
/// the Mission Reports' mass rows, the CM RCS, and the stowed parts of the
/// earth landing system (ELS).
///
/// Values keep their source unit and a grade, as `AS506`'s do: (H) high, (M)
/// medium, (L) low. The transcriptions are track D's, read from the page
/// images by two readers (tools/data: a07_mr_table_a5_1.csv,
/// a11_mr_table_a_1.csv, a07_mr_sec5_21_consumables.csv,
/// a11_mr_sec8_11_consumables.csv, tnd7437_els.csv, aoh_block2_sps_rcs.csv;
/// the log is docs/data/apollo-spacecraft/README.md).
///
/// Everything is placed in Apollo axes through `ApolloAxes`: X_A along the
/// axis towards the apex, station inches, which are also the CM's Xc
/// stations (the Mission Reports' CM CG and 68-FM-184's trim CoM, X 1040.58,
/// are on one scale). Xc 1000 is the heat shield's tangent plane (TN D-5399
/// Table II footnote b; TN D-5276).
public enum ApolloCM {
    public enum Mission: String, CaseIterable {
        case apollo7 = "Apollo 7"
        case apollo11 = "Apollo 11"
    }

    /// Contact speeds the CM survives: about 15 m/s on water, the design
    /// descent on two mains (36 ft/s, TN D-7437 Fig. 2) with a margin (L),
    /// and M0's 5 m/s on land.
    public static let impactLimits = ImpactLimits(water: 15, land: 5)

    // MARK: Units

    static let inch = AS506.inch
    static let pound = AS506.pound
    static let poundForce = AS506.poundForce
    static let slugFoot2 = 1.3558179483              // kg m^2 per slug ft^2

    // MARK: Mass rows

    /// The events of the Mission Reports' CM rows, in flight order.
    enum Event: CaseIterable {
        case separation, entryInterface, mach10, drogueDeploy, mainDeploy, landing
    }

    /// A Mission Report mass-properties row of the CM: weight (lb), CG
    /// (X_A, Y_A, Z_A, in), and the moments and products of inertia about the
    /// CG in Apollo axes (slug ft^2). The products are +∫xy dm about the CG:
    /// Apollo 11's Table A-I recombines its splits by the parallel-axis
    /// theorem only with that sign, and Apollo 7's table comes from the same
    /// office in the same format.
    struct MassRow {
        let weight: Double
        let xa, ya, za: Double
        let ixx, iyy, izz, ixy, ixz, iyz: Double

        /// Mass, kg.
        var mass: Double { weight * pound }
        /// CG in construction axes, m.
        var centerOfMass: Vec3 { ApolloAxes.construction(xa: xa, ya: ya, za: za) }
        /// Inertia tensor about the CG in construction axes, kg m^2. A
        /// tensor's off-diagonals are -∫xy dm, and y = -Y_A, z = -Z_A flip
        /// the signs of the xy and xz products, so the tensor holds +I_xy,
        /// +I_xz and -I_yz.
        var inertia: Mat3 {
            Mat3(rows: Vec3(ixx, ixy, ixz), Vec3(ixy, iyy, -iyz), Vec3(ixz, -iyz, izz)) * slugFoot2
        }
    }

    /// Apollo 7 Mission Report (MSC-PA-R-68-15) Table A.5-I, p. A-47, rows
    /// 19-24 (H).
    static let apollo7Rows: [Event: MassRow] = [
        .separation: MassRow(weight: 12_364, xa: 1_040.8, ya: -0.2, za: 6.0,
                             ixx: 5_799, iyy: 5_213, izz: 4_745, ixy: 42, ixz: -423, iyz: 30),
        .entryInterface: MassRow(weight: 12_356, xa: 1_040.8, ya: -0.2, za: 6.0,
                                 ixx: 5_795, iyy: 5_208, izz: 4_744, ixy: 41, ixz: -421, iyz: 30),
        .mach10: MassRow(weight: 12_277, xa: 1_041.0, ya: -0.2, za: 5.9,
                         ixx: 5_735, iyy: 5_144, izz: 4_687, ixy: 42, ixz: -417, iyz: 30),
        .drogueDeploy: MassRow(weight: 11_936, xa: 1_039.7, ya: -0.1, za: 5.9,
                               ixx: 5_649, iyy: 4_901, izz: 4_467, ixy: 42, ixz: -392, iyz: 32),
        .mainDeploy: MassRow(weight: 11_855, xa: 1_039.4, ya: -0.1, za: 6.1,
                             ixx: 5_633, iyy: 4_841, izz: 4_424, ixy: 42, ixz: -366, iyz: 32),
        .landing: MassRow(weight: 11_409, xa: 1_037.4, ya: -0.1, za: 6.1,
                          ixx: 5_567, iyy: 4_567, izz: 4_131, ixy: 40, ixz: -371, iyz: 33),
    ]

    /// Apollo 11 Mission Report (MSC-00171) Table A-I, p. A-11: the command
    /// module after CM/SM separation, then entry to landing (H). It has no
    /// Mach 10 row.
    static let apollo11Rows: [Event: MassRow] = [
        .separation: MassRow(weight: 12_107.4, xa: 1_040.4, ya: -0.2, za: 6.0,
                             ixx: 6_260, iyy: 5_470, izz: 4_995, ixy: 55, ixz: -403, iyz: -47),
        .entryInterface: MassRow(weight: 12_095.5, xa: 1_040.5, ya: -0.2, za: 5.9,
                                 ixx: 6_253, iyy: 5_463, izz: 4_994, ixy: 55, ixz: -400, iyz: -47),
        .drogueDeploy: MassRow(weight: 11_603.7, xa: 1_039.2, ya: -0.2, za: 5.9,
                               ixx: 6_066, iyy: 5_133, izz: 4_690, ixy: 56, ixz: -375, iyz: -48),
        .mainDeploy: MassRow(weight: 11_318.9, xa: 1_039.1, ya: -0.1, za: 5.2,
                             ixx: 5_933, iyy: 4_947, izz: 4_631, ixy: 50, ixz: -312, iyz: -28),
        .landing: MassRow(weight: 10_873.0, xa: 1_037.1, ya: -0.1, za: 5.1,
                          ixx: 5_866, iyy: 4_670, izz: 4_336, ixy: 45, ixz: -322, iyz: -27),
    ]

    static func row(_ mission: Mission, _ event: Event) -> MassRow? {
        switch mission {
        case .apollo7: return apollo7Rows[event]
        case .apollo11: return apollo11Rows[event]
        }
    }

    // What the rows say about the ELS items, from the drop in weight, CG and
    // inertia between two rows (the parallel-axis theorem backwards):
    // - main deploy -> landing removes 446.0 lb (Apollo 7) and 445.9 lb
    //   (Apollo 11) at X_A 1090.6 and 1087.9, Z_A 6.1 and 7.6, with an own
    //   I_xx of 66.0 and 66.4 slug ft^2: the main parachutes, released after
    //   splashdown. The landing rows are the CM afloat without them.
    // - drogue deploy -> main deploy removes 81 lb at X_A 1083.6, Z_A -23
    //   (Apollo 7), the drogues and a few pounds of propellant and ablator;
    //   Apollo 11's 284.8 lb drop holds about 210 lb more that the table does
    //   not split out.
    // - Mach 10 -> drogue deploy removes 341 lb at X_A 1086.5 (Apollo 7), and
    //   entry -> drogue deploy 491.8 lb at 1071.2 (Apollo 11): the apex cover
    //   and the ablator and RCS propellant used. Apollo 7's EI -> Mach 10 drop,
    //   79 lb at X_A 1009.7, puts the latter on the aft heat shield.
    // The Block II ELS flew unchanged from Apollo 7 on (TN D-7437 p. 7), so
    // both missions carry the same items. The CM's structure is each
    // mission's separation row less the items and the CM RCS propellant.

    /// One stowed item: weight (lb), CG (X_A, Y_A, Z_A, in), and the moments
    /// of inertia about its own CG (slug ft^2, Apollo axes, no products).
    struct Item {
        let weight: Double
        let xa, ya, za: Double
        let ixx, iyy, izz: Double

        var mass: Double { weight * pound }
        var centerOfMass: Vec3 { ApolloAxes.construction(xa: xa, ya: ya, za: za) }
        var inertia: Mat3 { .diagonal(Vec3(ixx, iyy, izz) * slugFoot2) }
    }

    /// The forward heat shield. Its weight is not printed: 260 lb is what the
    /// two drogue-deploy rows' forward CG shifts leave once the ablator and
    /// propellant are put at X_A 1010 (Apollo 7 gives 250 lb, Apollo 11
    /// about 265-285), with the cover's centroid at X_A 1115 and its inertia
    /// a conical shell's, mean radius 28 in and 40 in high (L).
    static let apexCover = Item(weight: 260, xa: 1_115, ya: 0, za: 0, ixx: 44, iyy: 30, izz: 30)
    /// Two 16.5 ft conical-ribbon drogues, 37.4 lb each (TN D-7437 Fig.
    /// A-16, H), where Apollo 7's drogue-deploy -> main-deploy drop puts
    /// them, with the own inertia it gives (L: the drop is 81 lb, and its CG
    /// is good to about 15 in in Z_A).
    static let droguePack = Item(weight: 2 * 37.4, xa: 1_084, ya: 0, za: -23, ixx: 1, iyy: 10, izz: 10)
    /// Three 83.5 ft ringsail mains with their pilot chutes and bags: the
    /// main deploy -> landing drop, the two missions' mean (446.0 and 445.9
    /// lb; X_A 1089.25, Z_A 6.85), against 3 x 138.5 lb mains and 3 x 5.17
    /// lb pilots in TN D-7437 (M). Its inertia is a ring's about the
    /// tunnel, radius 26.3 in from both rows' I_xx (M).
    static let mainPack: Item = {
        let w = 446.0, r2 = (26.3 / 12) * (26.3 / 12), slug = w / (standardGravity / 0.3048)
        return Item(weight: w, xa: 1_089.25, ya: 0, za: 6.85,
                    ixx: slug * r2, iyy: slug * r2 / 2, izz: slug * r2 / 2)
    }()

    // MARK: Earth landing system

    /// Staging events of the ELS items (the naming contract): the apex
    /// cover's jettison, the drogues' release, the mains' release.
    public static let apexCoverEvent = 30, droguesEvent = 31, mainsEvent = 32

    static let foot = AS506.foot
    /// Two 16.5 ft conical-ribbon drogues: 114 ft^2 each fully open, 65 ft^2
    /// reefed (42.8 % of the diameter) for 10 s (TN D-7437 Fig. A-16 and p.
    /// A-11, H). Their risers meet the CM on its axis at the forward deck,
    /// X_A 1100 (L). They inflate in about 1 s (L).
    static func drogueParachutes() -> Parachute {
        let ft2 = foot * foot
        let c = Parachute(name: "Drogue parachutes", count: 2, diameter: 16.5 * foot, dragArea: 114 * ft2,
                          attachPoint: ApolloAxes.construction(xa: 1_100))
        c.reefing = [.init(dragArea: 65 * ft2, duration: 10)]
        c.inflationTime = 1
        return c
    }

    /// Three 83.5 ft ringsail mains: 285 ft^2 each in the first reefing
    /// stage for 6 s, 1,080 ft^2 in the second to 10 s, 4,200 ft^2 fully
    /// open (TN D-7437 Fig. A-15, H; "average" areas). The cluster's
    /// interference is calibrated on TN D-7437 Fig. 2's design splashdowns
    /// at the 13,000 lb recovery weight, with the CM's own drag: 32 ft/s on
    /// three mains needs 83.9 % of their area; 36 ft/s on two needs all of it
    /// (M). They inflate in about 2 s per stage (L). The risers' attachment
    /// is off the axis on the -Z_A side so that the CM hangs 27.5° from the
    /// vertical (the design report's hang angle, M; the side, L) about its
    /// main-deploy CG: X_A 1100, Z_A -25.4.
    static func mainParachutes() -> Parachute {
        let ft2 = foot * foot
        let c = Parachute(name: "Main parachutes", count: 3, diameter: 83.5 * foot, dragArea: 4_200 * ft2,
                          attachPoint: ApolloAxes.construction(xa: 1_100, za: -25.4))
        c.reefing = [.init(dragArea: 285 * ft2, duration: 6), .init(dragArea: 1_080 * ft2, duration: 4)]
        c.inflationTime = 2
        c.clusterEfficiency = [3: mainClusterEfficiency, 2: 1]
        return c
    }
    static let mainClusterEfficiency = 0.839
    /// The hang angle under the mains, rad.
    static let mainHangAngle = 27.5 * AS506.degree

    // MARK: Structure

    /// The CM's bounding cylinder: the heat shield's tangent plane, the apex
    /// (`AS506.cmApex`, L) and the 154 in diameter (`AS506.csmDiameter`, M).
    static let baseStation = 1_000.0
    static let apexStation = AS506.cmApex
    static let diameter = AS506.csmDiameter
    /// Subsonic drag coefficient on the 12.02 m^2 base area: 68-FM-184 Table
    /// I(a)'s C_D at Mach 0.4, 0.854 (H), the regime of the descent under
    /// the parachutes. It only acts without an aerodynamic model.
    static let subsonicDragCoefficient = 0.854

    // MARK: CM RCS

    /// Twelve Rocketdyne SE-8 engines of 93 lbf (AOH p. 2.5-47, H), in two
    /// systems of six: a CW and a CCW roll, a +pitch and a -pitch, a +yaw
    /// and a -yaw engine each (AOH Fig. 2.5-1: engines 11-16 and 21-26).
    static let rcsThrust = 93.0                        // lbf (H)
    /// No source gives the SE-8's Isp: the SM's R-4D rating, 68-FM-184 Table
    /// I(b)'s 276.0 s, is a placeholder (L).
    static let rcsIsp = 276.0                          // s (L)
    /// Oxidizer/fuel, as the SM RCS (AOH §2.5, M); Apollo 7 loaded 1.97.
    static let rcsMixtureRatio = 2.0
    /// Loads per system (fuel, oxidizer), lb: Apollo 7 Mission Report §5.21,
    /// Apollo 11 Mission Report §8.11 (H). Apollo 11's system B fired no
    /// propellant.
    static func rcsLoads(_ mission: Mission) -> [(fuel: Double, oxidizer: Double)] {
        switch mission {
        case .apollo7: return [(44.4, 87.6), (44.4, 87.5)]
        case .apollo11: return [(44.8, 78.4), (44.4, 78.3)]
        }
    }
    /// Each system's tanks in the aft compartment, lumped at one point:
    /// system A at +Y_A, system B at -Y_A, X_A 1025, 60 in out (L).
    static let rcsTankStation = 1_025.0, rcsTankRadius = 60.0
    /// The aft engines fire through the 33° afterbody just above the
    /// shoulder (X_A 1020, 72 in out) and the -pitch pair from the forward
    /// compartment (X_A 1100, 24 in out), all as Fig. 2.5-1 places them: the
    /// +pitch pair on the -Z_A side, the yaw engines on ±Y_A, system A's roll
    /// pair on +Y_A and system B's on -Y_A (L). Pitch and yaw engines push
    /// along the wall's inward normal; roll engines push tangentially.
    static let rcsAftStation = 1_020.0, rcsAftRadius = 72.0
    static let rcsForwardStation = 1_100.0, rcsForwardRadius = 24.0
    static let afterbodyHalfAngle = 33.0                // deg, TN D-5399 (M)
}

extension VesselLibrary {
    /// The Apollo command module's parts in the Saturn V construction frame,
    /// built in Apollo axes (`ApolloAxes`), for a CSM or a launch stack to
    /// compose. Together they are the CM at `mission`'s Mission Report row
    /// "after CM/SM separation" (weight, CG and inertia tensor):
    /// - "CM": the structure and crew, with the CM RCS (two systems, their
    ///   propellant in point tanks), `.fixed`. The jets are not
    ///   `activeStageOnly`, since once the SM is gone no part carries `.main`;
    ///   they are disabled (`isEnabled` false) until staging event 7, CM/SM
    ///   separation (`trigger`), arms them;
    /// - "Apex cover": the forward heat shield, event 30;
    /// - "Drogue parachutes": the drogue pack, event 31 (its release);
    /// - "Main parachutes": the main pack, event 32 (its release after
    ///   splashdown).
    ///
    /// The packs carry their stowed `Parachute`s, which `EarthLandingSystem`
    /// deploys, and stay at their stowed station after deployment: canopies
    /// are force and visuals only.
    public static func commandModuleParts(_ mission: ApolloCM.Mission) -> [VesselPart] {
        typealias C = ApolloCM
        guard let row = C.row(mission, .separation) else { preconditionFailure("no separation row") }

        /// A part on the axis spanning stations `bottom...top` (X_A, in).
        func part(_ name: String, _ bottom: Double, _ top: Double, radius: Double,
                  staging: StagingRule) -> VesselPart {
            let mid = ApolloAxes.construction(xa: (bottom + top) / 2)
            return VesselPart(name: name, dryMass: 0, offset: mid, length: (top - bottom) * C.inch,
                              radius: radius * C.inch, staging: staging)
        }
        func place(_ item: C.Item, in p: VesselPart) {
            p.dryMass = item.mass
            p.dryCenterOfMass = item.centerOfMass - p.offset
            p.dryInertia = item.inertia
        }

        let cover = part("Apex cover", 1_090, C.apexStation, radius: 34, staging: .event(C.apexCoverEvent))
        place(C.apexCover, in: cover)
        cover.separationSpeed = 3                       // m/s, thrusters and its chute (L)
        let drogues = part("Drogue parachutes", 1_074, 1_094, radius: 30, staging: .event(C.droguesEvent))
        place(C.droguePack, in: drogues)
        drogues.separationSpeed = 0                     // cut loose
        let mains = part("Main parachutes", 1_074, 1_104, radius: 30, staging: .event(C.mainsEvent))
        place(C.mainPack, in: mains)
        mains.separationSpeed = 0
        for (p, chute) in [(drogues, C.drogueParachutes()), (mains, C.mainParachutes())] {
            chute.attachPoint = chute.attachPoint - p.offset
            p.parachutes = [chute]
        }

        let cm = part("CM", C.baseStation, C.apexStation, radius: C.diameter / 2, staging: .fixed)
        cm.dragCoefficient = C.subsonicDragCoefficient
        addCommandModuleRCS(to: cm, loads: C.rcsLoads(mission), controlPoint: row.centerOfMass - cm.offset)

        // The structure: the row less the items and the RCS propellant.
        var elements: [(mass: Double, com: Vec3, inertia: Mat3)] =
            [cover, drogues, mains].map { ($0.dryMass, $0.offset + $0.dryCenterOfMass, $0.dryInertia ?? .zero) }
        elements += cm.tanks.map { ($0.mass, cm.offset + ($0.centroid ?? .zero), Mat3.zero) }
        let mass = row.mass - elements.reduce(0) { $0 + $1.mass }
        let com = (row.centerOfMass * row.mass - elements.reduce(Vec3.zero) { $0 + $1.com * $1.mass }) / mass
        var inertia = row.inertia + .parallelAxis(mass: row.mass, offset: row.centerOfMass - com)
        for e in elements { inertia = inertia + (e.inertia + .parallelAxis(mass: e.mass, offset: e.com - com)) * -1 }
        cm.dryMass = mass
        cm.dryCenterOfMass = com - cm.offset
        cm.dryInertia = inertia

        return [cm, cover, drogues, mains]
    }

    /// The command module alone, at `mission`'s "after CM/SM separation" row,
    /// as it flies once the SM has gone: its RCS armed, the crew's control
    /// frame (`ApolloAxes.rotation`) and the CM's impact limits. Place it
    /// with `Simulation.place`.
    public static func commandModule(_ mission: ApolloCM.Mission, name: String? = nil) -> Vessel {
        let parts = commandModuleParts(mission)
        for t in parts.flatMap(\.thrusters) { t.isEnabled = true }
        let cm = Vessel(name: name ?? mission.rawValue, parts: parts, reference: placeholderBody)
        cm.controlFrame = ApolloAxes.rotation
        cm.impactLimits = ApolloCM.impactLimits
        return cm
    }

    /// The CM RCS on `part`: per system, its fuel and oxidizer point tanks
    /// and six jets named "CM RCS 1A"-"CM RCS 6A" (system A, AOH engines
    /// 11-16) and "CM RCS 1B"-"CM RCS 6B" (system B, engines 21-26), the
    /// digit following the AOH's: 1 CW +roll, 2 CCW -roll, 3 +pitch, 4
    /// -pitch, 5 +yaw, 6 -yaw. Each jet's rotation group follows its torque
    /// about `controlPoint` (part frame, the CM's CG), on its dominant axis;
    /// the CM RCS flies no translation.
    static func addCommandModuleRCS(to part: VesselPart, loads: [(fuel: Double, oxidizer: Double)],
                                    controlPoint c: Vec3) {
        typealias C = ApolloCM
        let rating = EngineRating(name: "SE-8", thrustVacuum: C.rcsThrust * C.poundForce, ispVacuum: C.rcsIsp,
                                  mixtureRatio: C.rcsMixtureRatio)
        let wall = C.afterbodyHalfAngle * AS506.degree
        func local(_ xa: Double, _ ya: Double, _ za: Double) -> Vec3 {
            ApolloAxes.construction(xa: xa, ya: ya, za: za) - part.offset
        }
        /// Force through the afterbody wall at a point whose outward radial
        /// direction is (ya, za): inwards along the wall's normal.
        func throughWall(_ ya: Double, _ za: Double) -> Vec3 {
            ApolloAxes.direction(xa: -sin(wall), ya: -ya * cos(wall), za: -za * cos(wall))
        }
        var jets: [(name: String, position: Vec3, direction: Vec3, system: Int)] = []
        for (i, system) in ["A", "B"].enumerated() {
            let side = i == 0 ? 1.0 : -1.0            // the roll pair's side: +Y_A for A, -Y_A for B
            let aft = C.rcsAftStation, r = C.rcsAftRadius
            jets += [
                ("CM RCS 1\(system)", local(aft, side * r, 0), ApolloAxes.direction(xa: 0, ya: 0, za: side), i),
                ("CM RCS 2\(system)", local(aft, side * r, 0), ApolloAxes.direction(xa: 0, ya: 0, za: -side), i),
                ("CM RCS 3\(system)", local(aft, 0, -r), throughWall(0, -1), i),
                ("CM RCS 4\(system)", local(C.rcsForwardStation, 0, -C.rcsForwardRadius), throughWall(0, -1), i),
                ("CM RCS 5\(system)", local(aft, r, 0), throughWall(1, 0), i),
                ("CM RCS 6\(system)", local(aft, -r, 0), throughWall(-1, 0), i),
            ]
        }
        var feeds: [PropellantFeed] = []
        for (i, load) in loads.enumerated() {
            let system = i == 0 ? "A" : "B", side = i == 0 ? 1.0 : -1.0
            let at = local(C.rcsTankStation, side * C.rcsTankRadius, 0)
            let ox = PropellantTank(name: "CM RCS \(system) oxidizer", capacity: load.oxidizer * C.pound,
                                    geometry: .point(at))
            let fuel = PropellantTank(name: "CM RCS \(system) fuel", capacity: load.fuel * C.pound,
                                      geometry: .point(at))
            part.tanks += [ox, fuel]
            feeds.append(.bipropellant(oxidizer: ox, fuel: fuel))
        }
        for jet in jets {
            let torque = (jet.position - c).cross(jet.direction)
            let groups: Set<ThrusterGroup>
            if abs(torque.x) >= abs(torque.y) && abs(torque.x) >= abs(torque.z) {
                groups = [torque.x > 0 ? .rollRight : .rollLeft]
            } else if abs(torque.y) >= abs(torque.z) {
                groups = [torque.y > 0 ? .pitchUp : .pitchDown]
            } else {
                groups = [torque.z > 0 ? .yawRight : .yawLeft]
            }
            let t = Thruster(name: jet.name, position: jet.position, direction: jet.direction, rating: rating,
                             feed: feeds[jet.system], groups: groups)
            t.isEnabled = false
            t.trigger = .event(7)
            part.thrusters.append(t)
        }
    }
}

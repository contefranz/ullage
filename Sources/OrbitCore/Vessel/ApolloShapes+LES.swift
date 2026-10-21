import Foundation

// The launch escape system and the boost protective cover (track VG3).

extension ApolloShapeData {
    // MARK: LES stations (datasheet §11.1)
    //
    // XL (in) from the LES/CM separation plane, Xa = XL + 1083.476 (AOH Fig.
    // 1-2, H). Azimuths θ_A in degrees from +Y_A towards +Z_A.

    static let lesSeparationPlane = 1_083.476        // Xa, XL 0: the tower legs' feet, AOH Fig. 1-2 (H)
    static let lesTowerTop = 118.3                   // XL: the skirt's base, AOH Fig. 1-2 (H)
    static let lesSkirtTop = 138.0                   // XL: the LES motor case's aft end, AOH Fig. 1-2 (H)
    static let lesMotorTop = 283.0                   // XL: the LES motor's forward end, the TJM's aft end (H)
    static let lesTJMTop = 338.6                     // XL: 283 + the TJM's 55.62 in (D7083 Table I), the canard section's aft ring (M)
    static let lesNoseConeBase = 363.7               // XL: the 15° cone's base, AOH Fig. 1-2; BCD (H)
    static let lesQBallBase = 387.5                  // XL: the tip less 13.275 in, CNR15 Fig. P-194 (M)
    static let lesTip = 400.762                      // XL, AOH Fig. 1-2; BCD STA 4240.79 (H)
    /// The LES motor, the TJM and the canard section are 26 in across; the
    /// nose one 15° cone from XL 363.7 through the Q-ball (13.24 in across
    /// its base, CNR15's 13.3 in), ending on the 4 in tip radius TRN §2.3
    /// gives (L): the sphere tangent to that cone at the tip's station has
    /// it (derived).
    static let lesBodyDiameter = 26.0                // in, D7083 Table I; CNR15 Fig. P-189 (H)
    static let lesNoseHalfAngle = 15.0               // deg, TMX Fig. 2 (M)

    // MARK: Tower (datasheet §11.2)

    /// The legs run from their feet on a 50.67 in (along Y) by 46.84 in
    /// (along Z) rectangle at XL 0, 34.5 in out and 42.75° from Y, to a
    /// 36.06 in square at the skirt (D5686 Table I(b), Fig. 2(f), M).
    static let towerFootY = 25.335                   // in, half of 50.67 (M)
    static let towerFootZ = 23.42                    // in, half of 46.84 (M)
    static let towerTopHalf = 18.03                  // in, half of 36.06 (M)
    /// The legs and the horizontal P are 3.5 in tubes (TRN's F and P); the
    /// other bracing 2.5 in (I, J, L, M, O, Q) (TRN §2.7, M), all in Buna-N.
    static let towerLegRadius = 1.75                 // in (M)
    static let towerBraceRadius = 1.25               // in (M)
    /// Each face from the top (TRN Fig. 2-9, M): the hour-glass, its two X
    /// bays converging on the short horizontal J and spreading again to the
    /// full horizontal M, which keeps the face's middle clear for the
    /// motor's plume (D5686 p. 3); a bay with one long diagonal and a half
    /// diagonal; the horizontal P; an inverted V from P's middle to the
    /// legs' joints. P's and the joints' stations are printed (M), J's and
    /// M's scaled (L); J's length is not (L).
    static let towerBraceJ = 88.6                    // XL, scaled (L)
    static let towerBraceM = 59.7                    // XL, scaled (L)
    static let towerBraceP = 35.87                   // XL (M)
    static let towerLegJoint = 12.85                 // XL (M)
    static let towerWaist = 1.0 / 3                  // J's share of the face's width, estimate (L)

    // MARK: Skirt and motors (datasheet §11.3)

    /// The structural skirt, XL 118.3-138.0, flaring from its 28.89 in
    /// interface ring to about 54 in at its base (D5686: 54.6 and 52.73 in
    /// on the two models, M), its Thermolag ablative "a black tar" (TRN
    /// §2.6, Block I, M; VD2 sees it white, a question for Franz).
    static let skirtBaseDiameter = 54.0              // in (M)
    static let skirtTopDiameter = 28.89              // in (M)
    /// The LES motor: 185.57 in long, so its four nozzles' exits are at XL
    /// 97.43, 15 in across, canted 35° and 53.66 in across them (D7083,
    /// CNR15, M-H); its aft dome hangs in the skirt (L). The nozzles look
    /// out through the faces' middles, where the hour-glass leaves room (L).
    static let lesMotorLength = 185.57               // in, D7083 Table I (H)
    static let lesNozzleCant = 35.0                  // deg, TRN §2.5.3; CNR15 Fig. P-189 (M)
    static let lesNozzleExitDiameter = 15.0          // in, CNR15 Fig. P-189 (M)
    static let lesNozzleEnvelope = 53.66             // in across the exits, D7083 Table I (H)
    static let lesNozzleAzimuths = [0.0, 90.0, 180.0, 270.0]   // deg θ_A, estimate (L)
    static let lesMotorDome = 13.0                   // in, the aft dome's depth, estimate (L)
    /// The tower jettison motor's two nozzles, at 30° to its axis in the
    /// pitch (Z) plane (D7083 Fig. 3, H), exit through a 30 in interstage at
    /// its aft end (TRN §2.5.2, M) to its 28.00 in envelope (D7083, H).
    static let tjmNozzleCant = 30.0                  // deg (H)
    static let tjmEnvelope = 28.0                    // in (H)
    static let tjmNozzleStation = 298.0              // XL, the interstage's middle, estimate (L)
    static let tjmNozzleExitRadius = 3.0             // in, estimate (L)
    static let tjmNozzleAzimuths = [90.0, 270.0]     // deg θ_A, ±Z_A (M)
    /// The pitch control motor, 22.00 in long with an 8.8 in case, across
    /// the axis in the canard section's aft compartment, its nozzle flush
    /// with the skin on -Z_A (D7083 Table I, Fig. 2, H; TRN §2.4.3, FAM Fig.
    /// 3-2, M); its station is likely BCD's "centerline" (L).
    static let pitchMotorStation = 1_428.97          // Xa (L)
    static let pitchMotorLength = 22.0               // in (H)
    static let pitchMotorCaseDiameter = 8.8          // in (H)
    static let pitchMotorNozzleLength = 4.0          // in, estimate (L)
    static let pitchMotorExitRadius = 2.6            // in, estimate (L)

    // MARK: Canards (datasheet §11.4)

    /// Two "100 degree arc segments" of the section's skin, stowed flush,
    /// XL 339.6-386.5 (TRN §2.4, Block I, M), side by side on one half
    /// either side of their actuator: which half is not found (L, here
    /// +Z_A, away from the pitch motor's nozzle).
    static let canardArc = 100.0                     // deg (M)
    static let canardBottom = 339.6                  // XL (M)
    static let canardTop = 386.5                     // XL (M)
    static let canardCentre = 90.0                   // deg θ_A, estimate (L)
    static let canardGap = 10.0                      // deg about the actuator, estimate (L)
    static let canardRelief = 0.12                   // in above the skin (visual)

    // MARK: Boost protective cover (datasheet §11.5)

    /// From its aft edge on the SM's fairing (Xc 14) up the CM's shoulder
    /// and cone: the soft section of glass cloth to the transition ring at
    /// Xc 81, then the hard fibreglass section to the apex at the tension-tie
    /// plug, Xc 135.13 (AOH Figs. 1-4, 2.9-8, H), which rounds off the cone
    /// on a sphere tangent to it. The stand-offs are not found (L): the soft
    /// section clears the CM's window frames.
    static let bpcAftEdge = 1_014.0                  // Xa (H)
    static let bpcJoint = 1_081.0                    // Xa (H)
    static let bpcApex = 1_135.13                    // Xa (H)
    static let bpcSoftStandOff = 1.0                 // in, estimate (L)
    static let bpcHardStandOff = 1.5                 // in, estimate (L)
    /// One 8 in window over the commander's rendezvous window (window 2), a
    /// hatch over the CM's, and the blow-out ports over the CM's RCS ports
    /// (AOH Fig. 1-4, p. 1-38; CNR15 pp. 140-141, H-M).
    static let bpcWindowDiameter = 8.0               // in (H)
    static let bpcWindow = 2                         // the CM window it is over (H)
}

extension MaterialKey {
    // The LES's and BPC's finishes (track VG3).
    public static let apolloBPC: MaterialKey = "apollo.bpc.hard"
    public static let apolloBPCSoft: MaterialKey = "apollo.bpc.soft"
    public static let apolloLESTower: MaterialKey = "apollo.les.tower"
    public static let apolloLESSkirt: MaterialKey = "apollo.les.skirt"
    public static let apolloLESCanard: MaterialKey = "apollo.les.canard"
    public static let apolloQBall: MaterialKey = "apollo.les.qball"
}

extension ApolloDresser {
    static let bpcHard = Finish(colour: (0.9, 0.9, 0.88), material: .apolloBPC)
    static let bpcSoft = Finish(colour: (0.88, 0.88, 0.86), material: .apolloBPCSoft)
    static let lesTower = Finish(colour: (0.88, 0.88, 0.86), material: .apolloLESTower)
    static let lesSkirt = Finish(colour: (0.15, 0.15, 0.15), material: .apolloLESSkirt)
    static let lesCanard = Finish(colour: (0.85, 0.85, 0.83), material: .apolloLESCanard)
    static let qBall = Finish(colour: (0.55, 0.55, 0.57), material: .apolloQBall)

    func lesShapes() -> [VisualShape]? {
        switch part.name {
        case "LES":
            return les()
        default:
            return nil
        }
    }

    func lesAttachments() -> [VisualAttachment] { [] }

    /// The BPC over the CM, the truss tower, the skirt, the motors and
    /// their nozzles, the canard section with its canards, and the Q-ball.
    func les() -> [VisualShape] { bpc() + lesTower() + lesMotors() + lesNose() }

    /// Construction x (m) of LES station `xl` (in).
    func lesX(_ xl: Double) -> Double { xa(S.lesSeparationPlane + xl) }

    // MARK: BPC

    /// The BPC's soft and hard sections, two-sided shells, and its window,
    /// hatch and blow-out ports.
    func bpc() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias M = CMOuterMouldLine
        let inch = D.inch, soft = S.bpcSoftStandOff, hard = S.bpcHardStandOff, face = Vec3(cm(0), 0, 0)
        let joint = S.bpcJoint - S.cmFace, apex = S.bpcApex - S.cmFace
        let shoulder = M.heatShield.filter { $0.nx >= -1e-9 }.map { P($0.x + soft * $0.nx, $0.r + soft * $0.nr) }
        let lower = M.cone(at: joint, off: soft), upper = M.cone(at: joint, off: hard)
        let softProfile = [P(S.bpcAftEdge - S.cmFace, S.cmMaxRadius + 0.1)] + shoulder + [P(lower.x, lower.r)]
        // The hard section's cone ends on the sphere through the apex
        // tangent to it.
        let vertex = M.coneVertex + hard / sin(M.theta)
        let radius = (vertex - apex) * sin(M.theta) / (1 - sin(M.theta)), centre = apex - radius
        let arc = (0...6).map { i -> P in
            let b = (Double.pi / 2 - M.theta) * Double(6 - i) / 6
            return P(centre + radius * cos(b), radius * sin(b))
        }
        let hardProfile = [P(joint, lower.r), P(joint, upper.r, crease: true)] + arc
        func shell(_ profile: [P], _ finish: Finish) -> VisualShape {
            var s = revolution(profile.map { P($0.x * inch, $0.r * inch, crease: $0.crease) }, at: face, finish)
            s.capBase = false
            s.capTop = false
            s.twoSided = true
            return s
        }
        var shapes = [shell(softProfile, A.bpcSoft), shell(hardProfile, A.bpcHard)]

        if let window = S.cmWindows.first(where: { $0.number == S.bpcWindow }) {
            let f = cmConeFrame(x: window.xa - S.cmFace, theta: window.theta * SpacecraftFrame.degree, off: soft)
            let r = S.bpcWindowDiameter / 2 * inch
            shapes.append(scPatch(at: f.at, normal: f.normal, across: f.across, up: f.up,
                                  outline: A.ellipse(r, r, count: 16), depth: 0.5 * inch, height: 0.1 * inch,
                                  A.cmWindow))
        }
        shapes.append(cmHatch(off: soft + S.cmHatchRelief, A.bpcSoft))
        return shapes + cmRCSPorts(forward: false, off: soft) + cmRCSPorts(forward: true, off: hard)
    }

    // MARK: Tower

    /// A point of leg `k` (0-3, counter-clockwise from the +Y_A +Z_A leg)
    /// at LES station `xl` (in), construction.
    func towerLeg(_ k: Int, at xl: Double) -> Vec3 {
        let signs: [(Double, Double)] = [(1, 1), (-1, 1), (-1, -1), (1, -1)], f = xl / S.lesTowerTop
        let ya = S.towerFootY + (S.towerTopHalf - S.towerFootY) * f
        let za = S.towerFootZ + (S.towerTopHalf - S.towerFootZ) * f
        return ApolloAxes.construction(xa: S.lesSeparationPlane + xl, ya: signs[k].0 * ya, za: signs[k].1 * za)
    }

    /// The four legs, then each face's bracing (between leg `k` and the
    /// next counter-clockwise), all tubes.
    func lesTower() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, leg = S.towerLegRadius * inch, brace = S.towerBraceRadius * inch
        var shapes = (0..<4).map { scTube(towerLeg($0, at: 0), towerLeg($0, at: S.lesTowerTop), radius: leg, A.lesTower) }
        let top = S.lesTowerTop, j = S.towerBraceJ, m = S.towerBraceM, p = S.towerBraceP, w = S.towerWaist
        for k in 0..<4 {
            /// The face's point at station `xl`, `f` across it (-1 at leg k,
            /// +1 at the next).
            func at(_ xl: Double, _ f: Double) -> Vec3 {
                let a = towerLeg(k, at: xl), b = towerLeg((k + 1) % 4, at: xl)
                return a + (b - a) * ((f + 1) / 2)
            }
            let long = (at(m, -1), at(p, 1))
            let members: [(Vec3, Vec3, Double)] = [
                (at(top, -1), at(j, -w), brace), (at(top, 1), at(j, w), brace),   // the hour-glass's upper bay
                (at(j, -w), at(j, w), brace),                                      // J, its waist
                (at(j, -w), at(m, -1), brace), (at(j, w), at(m, 1), brace),        // its lower bay
                (at(m, -1), at(m, 1), brace),                                      // M
                (long.0, long.1, brace), (at(m, 1), (long.0 + long.1) / 2, brace), // the long and half diagonals
                (at(p, -1), at(p, 1), leg),                                        // P
                (at(p, 0), at(S.towerLegJoint, -1), brace), (at(p, 0), at(S.towerLegJoint, 1), brace),   // the V
            ]
            shapes += members.map { scTube($0.0, $0.1, radius: $0.2, A.lesTower) }
        }
        return shapes
    }

    // MARK: Motors

    /// The skirt; the LES motor (its aft dome in the skirt, its four
    /// nozzles hanging in the tower's top bay); the TJM with its two nozzles
    /// and their ports in its interstage; the pitch control motor across the
    /// canard section, its nozzle's exit on -Z_A.
    func lesMotors() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias F = SpacecraftFrame
        let inch = D.inch, body = S.lesBodyDiameter / 2
        let skirtLength = (S.lesSkirtTop - S.lesTowerTop) * inch
        var skirt = revolution([P(0, S.skirtBaseDiameter / 2 * inch), P(skirtLength, S.skirtTopDiameter / 2 * inch, crease: true),
                                P(skirtLength, body * inch)], at: Vec3(lesX(S.lesTowerTop), 0, 0), A.lesSkirt)
        skirt.capBase = false
        skirt.capTop = false
        skirt.twoSided = true

        let dome = S.lesMotorDome, caseLength = S.lesMotorTop - S.lesSkirtTop
        let domeProfile = (0...6).map { i -> P in
            let a = Double.pi / 2 * Double(i) / 6
            return P(dome * (1 - cos(a)), body * sin(a))
        }
        let motor = revolution((domeProfile + [P(dome + caseLength, body, crease: true)]).map {
            P($0.x * inch, $0.r * inch, crease: $0.crease)
        }, at: Vec3(lesX(S.lesSkirtTop - dome), 0, 0), A.white)
        var shapes = [skirt, motor]

        // The LES motor's nozzles, each from its exit back into the dome.
        let cant = S.lesNozzleCant * F.degree, exitRadius = S.lesNozzleExitDiameter / 2
        let centre = S.lesNozzleEnvelope / 2 - exitRadius * cos(cant)
        let exitStation = lesX(S.lesMotorTop - S.lesMotorLength)
        let nozzle = [P(0, exitRadius), P(8, 5.0), P(16, 3.0), P(22, 2.6, crease: true), P(26, 3.2, crease: true),
                      P(34, 3.2)].map { P($0.x * inch, $0.r * inch, crease: $0.crease) }
        for azimuth in S.lesNozzleAzimuths {
            let out = F.radial(F.theta(apollo: azimuth))
            let exhaust: Vec3 = Vec3.unitX * -cos(cant) + out * sin(cant)
            shapes.append(lesNozzle(nozzle, exit: Vec3(exitStation, 0, 0) + out * (centre * inch), exhaust: exhaust))
        }

        // The TJM, closed, and its nozzles' exits reaching its envelope
        // through ports in its interstage.
        let tjmLength = (S.lesTJMTop - S.lesMotorTop) * inch
        shapes.append(revolution([P(0, 0), P(0, body * inch, crease: true), P(tjmLength, body * inch, crease: true),
                                  P(tjmLength, 0)], at: Vec3(lesX(S.lesMotorTop), 0, 0), A.white))
        let tjmCant = S.tjmNozzleCant * F.degree, er = S.tjmNozzleExitRadius
        let tjmCentre = S.tjmEnvelope / 2 - er * cos(tjmCant)
        let tjmNozzle = [P(0, er), P(3, 0.67 * er), P(6, 0.47 * er)].map { P($0.x * inch, $0.r * inch) }
        for azimuth in S.tjmNozzleAzimuths {
            let theta = F.theta(apollo: azimuth), out = F.radial(theta)
            let exhaust: Vec3 = Vec3.unitX * -cos(tjmCant) + out * sin(tjmCant)
            let skin = Vec3(lesX(S.tjmNozzleStation), 0, 0) + out * (body * inch)
            shapes.append(scPatch(at: skin, normal: out, across: F.tangent(theta), up: .unitX,
                                  outline: A.ellipse((er + 0.5) * inch, (er + 1) * inch), depth: 0.5 * inch,
                                  height: 0.08 * inch, A.cmRCSPort))
            shapes.append(lesNozzle(tjmNozzle, exit: Vec3(lesX(S.tjmNozzleStation), 0, 0) + out * (tjmCentre * inch),
                                   exhaust: exhaust))
        }

        // The pitch control motor along Z_A: its case, then its nozzle out
        // to the skin on -Z_A, where its exit shows.
        let near = S.pitchMotorNozzleLength - body, far = S.pitchMotorLength - body
        let caseA = ApolloAxes.construction(xa: S.pitchMotorStation, za: near)
        let caseB = ApolloAxes.construction(xa: S.pitchMotorStation, za: far)
        let exit = ApolloAxes.construction(xa: S.pitchMotorStation, za: -body)
        shapes.append(scTube(caseB, caseA, radius: S.pitchMotorCaseDiameter / 2 * inch, segments: 16, A.white))
        let pcmNozzle = [P(0, S.pitchMotorExitRadius), P(S.pitchMotorNozzleLength, 0.6 * S.pitchMotorExitRadius)]
            .map { P($0.x * inch, $0.r * inch) }
        let minusZ = ApolloAxes.direction(xa: 0, ya: 0, za: -1)
        shapes.append(lesNozzle(pcmNozzle, exit: exit, exhaust: minusZ))
        let r = S.pitchMotorExitRadius * inch
        shapes.append(scPatch(at: exit, normal: minusZ, across: F.tangent(0), up: .unitX,
                              outline: A.ellipse(r, r, count: 16), depth: 0.5 * inch, height: 0.08 * inch, A.cmRCSPort))
        return shapes
    }

    /// An open, two-sided nozzle of `profile` (m, from the exit back along
    /// the nozzle) whose exit is at construction point `exit`, its exhaust
    /// leaving along `exhaust`.
    func lesNozzle(_ profile: [P], exit: Vec3, exhaust: Vec3) -> VisualShape {
        var s = finished(.revolution(profile, from: local(exit), axis: -exhaust, segments: 24,
                                     color: ApolloDresser.dark.colour), ApolloDresser.dark, vehicleFrame: false)
        s.capBase = false
        s.capTop = false
        s.twoSided = true
        return s
    }

    // MARK: Canard section and nose

    /// The canard section, its 26 in cylinder and the 15° cone to the
    /// Q-ball; the two stowed canards on it; the Q-ball to its rounded tip.
    func lesNose() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias F = SpacecraftFrame
        let inch = D.inch, body = S.lesBodyDiameter / 2, slope = tan(S.lesNoseHalfAngle * F.degree)
        /// The nose cone's radius at `xl`.
        func cone(_ xl: Double) -> Double { body - (xl - S.lesNoseConeBase) * slope }
        let base = S.lesTJMTop, shoulder = S.lesNoseConeBase - base, end = S.lesQBallBase - base
        let section = revolution([P(0, 0), P(0, body, crease: true), P(shoulder, body, crease: true),
                                  P(end, cone(S.lesQBallBase), crease: true), P(end, 0)]
            .map { P($0.x * inch, $0.r * inch, crease: $0.crease) }, at: Vec3(lesX(base), 0, 0), A.white)

        // The canards: patches of the skin just proud of it, with lips.
        let lift = S.canardRelief, sink = 0.05
        let lo = S.canardBottom - base, hi = S.canardTop - base, lean = lift / cos(S.lesNoseHalfAngle * F.degree)
        let patch = [P(lo, body - sink), P(lo, body + lift), P(shoulder, body + lift), P(hi, cone(S.canardTop) + lean),
                     P(hi, cone(S.canardTop) - sink)].map { P($0.x * inch, $0.r * inch, crease: true) }
        let centre = F.theta(apollo: S.canardCentre), half = S.canardGap / 2 * F.degree, arc = S.canardArc * F.degree
        let canards = [(centre - half - arc)...(centre - half), (centre + half)...(centre + half + arc)].map { sweep in
            var s = revolution(patch, at: Vec3(lesX(base), 0, 0), reference: F.radial(0), sweep: sweep, A.lesCanard)
            s.capBase = false
            s.capTop = false
            return s
        }

        // The Q-ball: the cone on to the sphere tangent to it at the tip.
        let sinA = sin(S.lesNoseHalfAngle * F.degree)
        let vertex = S.lesNoseConeBase + body / slope
        let tipRadius = (vertex - S.lesTip) * sinA / (1 - sinA), sphere = S.lesTip - tipRadius
        let tip = (0...5).map { i -> P in
            let b = (Double.pi / 2 - S.lesNoseHalfAngle * F.degree) * Double(5 - i) / 5
            return P(sphere + tipRadius * cos(b) - S.lesQBallBase, tipRadius * sin(b))
        }
        let qBall = revolution(([P(0, 0), P(0, cone(S.lesQBallBase), crease: true)] + tip)
            .map { P($0.x * inch, $0.r * inch, crease: $0.crease) }, at: Vec3(lesX(S.lesQBallBase), 0, 0), A.qBall)
        return [section] + canards + [qBall]
    }
}

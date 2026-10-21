import Foundation

// The launch escape system and the boost protective cover (track VG3).

extension ApolloShapeData {
    // MARK: LES and BPC, crude
    //
    // Down from the tip (`AS506.overallHeight`, Xa ≈ 1484): the Q-ball nose
    // cone, the canard and ballast section, the motors (tower jettison and
    // pitch control motors above the launch escape motor, 26 in across) and
    // the truss tower to the CM.

    static let lesNoseLength = 13.37                 // in, Q-ball nose cone, 13.3 in across; engineering history (L)
    static let lesNoseRadius = 6.65                  // in (L)
    static let lesMotorTop = 1_430.0                 // Xa, estimate (L): the TJM's grain, Xa 1408.5 (`AS506`), below it
    static let lesMotorBottom = 1_207.0              // Xa: the launch escape motor, 15 ft 3 in, recalled (L)
    static let lesMotorRadius = 13.0                 // in, 26 in across, recalled (L); `AS506.lesRadius` ≈ 0.66 m across
    static let lesTowerBaseRadius = 24.0             // in: about 4 ft across at the base, recalled (L)
    static let lesTowerTopRadius = 11.0              // in, estimate (L)
    static let lesTubeRadius = 1.5                   // in, estimate (L)
}

extension ApolloDresser {
    func lesShapes() -> [VisualShape]? {
        switch part.name {
        case "LES":
            return les()
        default:
            return nil
        }
    }

    func lesAttachments() -> [VisualAttachment] { [] }

    /// The BPC over the CM's afterbody, the truss tower, the motors, the
    /// canards and the nose.
    func les() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias M = CMOuterMouldLine
        let inch = D.inch, off = S.bpcStandOff
        // From the shoulder's widest point up, pushed out along the normals.
        let shell = (M.heatShield.filter { $0.nx >= -1e-9 } + M.afterbody.dropFirst())
            .map { P(($0.x + off * $0.nx) * inch, ($0.r + off * $0.nr) * inch) }
        var bpc = revolution(shell, at: Vec3(cm(0), 0, 0), A.white)
        bpc.capBase = false
        bpc.twoSided = true

        let motorBottom = xa(S.lesMotorBottom), motorTop = xa(S.lesMotorTop), noseBase = A.lesTip - S.lesNoseLength * inch
        let motorR = S.lesMotorRadius * inch, noseR = S.lesNoseRadius * inch
        // Legs from the CM's surface at the base radius to the motor's skirt, on the diagonals.
        let baseX = M.coneStation(atRadius: S.lesTowerBaseRadius)
        let legs = (0..<4).map { i -> VisualShape in
            let a = (Double(i) + 0.5) * Double.pi / 2
            let d = Vec3(0, cos(a), sin(a))
            let from = Vec3(cm(baseX), 0, 0) + d * (S.lesTowerBaseRadius * inch)
            let to = Vec3(motorBottom, 0, 0) + d * (S.lesTowerTopRadius * inch)
            return finished(VisualShape.frustum(from: local(from), length: (to - from).length,
                                                baseRadius: S.lesTubeRadius * inch, topRadius: S.lesTubeRadius * inch,
                                                axis: to - from, color: A.grey.colour), A.grey)
        }
        return [bpc] + legs + [
            frustum(motorBottom, motorTop, motorR, motorR, A.white),
            frustum(motorTop, noseBase, motorR, noseR, A.white),
            frustum(noseBase, A.lesTip, noseR, 0.15 * noseR, A.grey),
        ]
    }
}

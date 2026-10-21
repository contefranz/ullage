import Foundation

// The command module, its apex cover and parachute packs (track VG3).

extension ApolloShapeData {
    // MARK: Command module outer mould line
    //
    // NASA TM X-1243 (Bertin, 1966) Fig. 1: a spherical heat shield, a
    // toroidal shoulder at the maximum radius, a 33° conical afterbody and a
    // spherical apex. Fig. 1(b) is the 0.045-scale AEDC model: 3.46 in
    // maximum radius, 8.32 in heat-shield radius, 0.35 in shoulder, 0.41 in
    // apex (184.9, 7.78 and 9.1 in full scale). Fig. 1(a) is the 0.02-scale
    // JPL model, 2.55 in long (127.5 in full scale) with a 15.4 in apex.

    static let cmMaxRadius = 77.0                    // in, TM X-1243 symbols: "77 inches for full-scale command module" (H)
    static let cmHeatShieldRadius = 184.8            // in, design-entry (M); TM X-1243 Fig. 1(b) 8.32 in at 0.045 scale = 184.9 (H)
    static let cmShoulderRadius = 7.8                // in, TM X-1243 Fig. 1(b): 0.35 in at 0.045 scale (M)
    static let cmConeHalfAngle = 33.0                // deg, TM X-1243 Fig. 1 (H)
    /// From the heat shield's face to the apex: 10 ft 7 in.
    static let cmHeight = 127.0                      // in, CSM News Reference (M); TM X-1243 Fig. 1(a) 127.5 in
    /// The heat shield's face. TN D-5399 Table II note (b) puts CM station
    /// 1000 at "the tangency line of the CM substructure mold line", and
    /// Apollo 7's CM CG, Xa 1040.8 (Mission Report Table A.5-I rows 19-20),
    /// at TN D-5276's x_cg/d of 0.27-0.28 from the face puts the face at
    /// Xa 998-999: the ablator's thickness below the substructure. (The M1
    /// datasheet's Xa 1010, L, is the SM's top, which the heat shield sinks
    /// into.)
    static let cmFace = 1_000.0                      // Xa, TN D-5399 Table II (M)
    /// The forward heat shield (apex cover) above its base, and the docking
    /// tunnel under it.
    static let apexCoverBase = 88.0                  // in above the face, estimate (L)
    static let tunnelRadius = 16.5                   // in, estimate (L)
    static let tunnelTop = 120.0                     // in above the face, estimate (L)
    /// The boost protective cover's stand-off from the CM's surface.
    static let bpcStandOff = 1.5                     // in, estimate (L)
}

/// The CM's outer mould line (`ApolloShapeData`), as profile points with
/// their outward normals, in inches above the heat shield's face.
enum CMOuterMouldLine {
    typealias S = ApolloShapeData
    static let theta = S.cmConeHalfAngle * Double.pi / 180
    /// The shoulder torus's section centre.
    static let shoulderCentre: (x: Double, r: Double) = {
        let rho = S.cmMaxRadius - S.cmShoulderRadius, d = S.cmHeatShieldRadius - S.cmShoulderRadius
        return (S.cmHeatShieldRadius - (d * d - rho * rho).squareRoot(), rho)
    }()
    /// Normal angles (from -x towards +r) where the heat shield meets the
    /// shoulder and the shoulder meets the cone.
    static let heatShieldEdge = asin(shoulderCentre.r / (S.cmHeatShieldRadius - S.cmShoulderRadius))
    static let coneStart = Double.pi / 2 + theta
    /// The apex sphere that ends the cone at `cmHeight`: derived (L), 18.9 in
    /// against TM X-1243's 15.4 in and 9.1 in models.
    static let apexRadius: Double = {
        let c = shoulderCentre, start = (x: c.x + S.cmShoulderRadius * sin(theta), r: c.r + S.cmShoulderRadius * cos(theta))
        let vertex = start.x + start.r / tan(theta)
        return (vertex - S.cmHeight) / (1 / sin(theta) - 1)
    }()

    struct Point { var x: Double; var r: Double; var nx: Double; var nr: Double }

    /// The heat shield: the spherical cap and the shoulder, from the face to
    /// the cone.
    static var heatShield: [Point] {
        let cap = (0...8).map { i -> Point in
            let a = heatShieldEdge * Double(i) / 8
            return Point(x: S.cmHeatShieldRadius * (1 - cos(a)), r: S.cmHeatShieldRadius * sin(a), nx: -cos(a), nr: sin(a))
        }
        // About 6° steps, through the maximum radius at 90°. The typed
        // parameters keep Swift 6.0's type checker on Linux within its limits.
        let halfPi = Double.pi / 2
        let rising = (1...11).map { (i: Int) -> Double in heatShieldEdge + (halfPi - heatShieldEdge) * Double(i) / 11 }
        let falling = (1...5).map { (i: Int) -> Double in halfPi + (coneStart - halfPi) * Double(i) / 5 }
        let shoulder = (rising + falling).map { a -> Point in
            Point(x: shoulderCentre.x - S.cmShoulderRadius * cos(a), r: shoulderCentre.r + S.cmShoulderRadius * sin(a),
                  nx: -cos(a), nr: sin(a))
        }
        return cap + shoulder
    }

    /// The afterbody: the cone and the apex sphere, from the shoulder to the
    /// apex.
    static var afterbody: [Point] {
        let centre = S.cmHeight - apexRadius
        return [heatShield[heatShield.count - 1]] + (0...6).map { i -> Point in
            let a = coneStart + (Double.pi - coneStart) * Double(i) / 6
            return Point(x: centre - apexRadius * cos(a), r: apexRadius * sin(a), nx: -cos(a), nr: sin(a))
        }
    }

    /// Radius of the afterbody cone at `x` (in above the face), and where
    /// the cone has radius `r`.
    static func coneRadius(at x: Double) -> Double {
        let start = heatShield[heatShield.count - 1]
        return start.r - (x - start.x) * tan(theta)
    }
    static func coneStation(atRadius r: Double) -> Double {
        let start = heatShield[heatShield.count - 1]
        return start.x + (start.r - r) / tan(theta)
    }
}

extension ApolloDresser {
    func cmShapes() -> [VisualShape]? {
        typealias A = ApolloDresser
        switch part.name {
        case "CM":
            return commandModule()
        case "Apex cover":
            return [apexCover()]
        case "Drogue parachutes":
            // Two mortars beside the tunnel.
            return [90.0, 270.0].map { stowed(at: $0, radius: 4.5, height: 12, A.grey) }
        case "Main parachutes":
            // Three packs round the tunnel.
            return [30.0, 150.0, 210.0].map { stowed(at: $0, radius: 5, height: 10, A.canvas) }
        default:
            return nil
        }
    }

    func cmAttachments() -> [VisualAttachment] { [] }

    /// The heat shield (emissive) and the afterbody; without the apex when
    /// the apex cover is a part of its own, showing the forward deck and the
    /// docking tunnel.
    func commandModule() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias M = CMOuterMouldLine
        let face = Vec3(cm(0), 0, 0), inch = D.inch
        var heatShield = revolution(M.heatShield.map { P($0.x * inch, $0.r * inch) }, at: face, A.ablator)
        heatShield.capTop = false
        heatShield.emissive = .heatShield
        var afterbody: VisualShape
        if apexCovered {
            let base = S.apexCoverBase, r = M.coneRadius(at: base)
            afterbody = revolution([P(M.afterbody[0].x, M.afterbody[0].r), P(base, r, crease: true),
                                    P(base, S.tunnelRadius, crease: true), P(S.tunnelTop, S.tunnelRadius, crease: true),
                                    P(S.tunnelTop, 0)].map { P($0.x * inch, $0.r * inch, crease: $0.crease) },
                                   at: face, A.silver)
        } else {
            afterbody = revolution(M.afterbody.map { P($0.x * inch, $0.r * inch) }, at: face, A.silver)
        }
        afterbody.capBase = false
        return [heatShield, afterbody]
    }

    /// The forward heat shield: the OML above `apexCoverBase`, open below.
    func apexCover() -> VisualShape {
        typealias M = CMOuterMouldLine
        let base = S.apexCoverBase, inch = D.inch
        let profile = [P(base * inch, M.coneRadius(at: base) * inch)]
            + M.afterbody.filter { $0.x > base }.map { P($0.x * inch, $0.r * inch) }
        var s = revolution(profile, at: Vec3(cm(0), 0, 0), ApolloDresser.silver)
        s.capBase = false
        s.twoSided = true
        return s
    }

    /// A stowed parachute item in the forward compartment, at `azimuth`
    /// (deg from +Y_A towards +Z_A).
    func stowed(at azimuth: Double, radius: Double, height: Double, _ finish: Finish) -> VisualShape {
        let a = azimuth * Double.pi / 180, inch = D.inch
        let d = ApolloAxes.direction(xa: 0, ya: cos(a), za: sin(a)) * ((S.tunnelRadius + radius + 1) * inch)
        return frustum(cm(S.apexCoverBase), cm(S.apexCoverBase + height), radius * inch, radius * inch, finish,
                       y: d.y, z: d.z)
    }
}

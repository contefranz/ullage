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
    //
    // The Block II CM has no such apex: its forward heat shield ends at the
    // docking interface, with the docking ring in its opening (datasheet
    // §9.1, §14 item 10). The idealised cone stays: placed on the face at Xa
    // 998 it is 19.8 in from the axis there, the real CM about 16.5 in (M),
    // so the forward heat shield's top keeps a 3.3 in ledge round the
    // docking ring. TM X-1243's afterbody lies a little outside the real
    // one: no 33° cone tangent to a 77 in shoulder at Xa 1020 passes through
    // the real apex (the structural cone's Xa 1133.5 and the ablator).

    static let cmMaxRadius = 77.0                    // in, TM X-1243 symbols: "77 inches for full-scale command module" (H)
    static let cmHeatShieldRadius = 184.8            // in, design-entry (M); TM X-1243 Fig. 1(b) 8.32 in at 0.045 scale = 184.9 (H)
    static let cmShoulderRadius = 7.8                // in, TM X-1243 Fig. 1(b): 0.35 in at 0.045 scale (M)
    static let cmConeHalfAngle = 33.0                // deg, TM X-1243 Fig. 1 (H)
    /// From the heat shield's face to TM X-1243's apex: 10 ft 7 in, the
    /// 1965-66 aero shape's (NR06 p. 39), which only the idealised OML's
    /// apex sphere uses.
    static let cmHeight = 127.0                      // in, CSM News Reference (M); TM X-1243 Fig. 1(a) 127.5 in
    /// The heat shield's face: Xa 1000 is the substructure's aft end, "1000
    /// inches below the tangency line of the CM substructure mold line"
    /// (TN D-5399 Table II note b; DB3's "heat shield bond line"), and the
    /// ablator adds 1.8 in on the axis (D5399 Fig. 9(f)), at most about 2.7
    /// in. Visual only: the entry aerodynamics keep their own datum
    /// (docs/CM-entry-datasheet.md, `ApolloCM.baseStation`).
    static let cmFace = 998.0                        // Xa, datasheet §9.1 (M)
    /// The forward heat shield (the apex cover) from the forward/crew
    /// compartment joint to the docking interface, where the docking ring
    /// sits in its opening over the 28 in tunnel.
    static let forwardHeatShieldBase = 1_081.13      // Xa, D7564 Fig. 6; D5399 Fig. 9(b) (H)
    static let dockingInterface = 1_110.25           // Xa, DB3 Figs. 2-2, 2-10, 2-11 (H)
    static let tunnelRadius = 16.5                   // in: the docking ring's outside and the shield's opening (M)
    static let tunnelClearRadius = 14.0              // in: the 28 in minimum clear tunnel, D6854 (H)
    static let forwardHatchDepth = 15.0              // in under the interface, estimate (L)
    static let dockingRingHeight = 3.0               // in, estimate (L)
    /// The boost protective cover's stand-off from the CM's surface, as the
    /// parachutes' clearance uses it.
    static let bpcStandOff = 1.5                     // in, estimate (L)

    // MARK: Windows, hatch and RCS (datasheet §9.2, §9.3)
    //
    // θ in degrees from Position I (the hatch, -Z_A) towards Position II.

    /// Five windows, numbered 1 (left) to 5 (right): the hatch window 3 on
    /// -Z_A, the triangular rendezvous windows 2 and 4 about 34° either
    /// side, the square side windows 1 and 5 about 56° (D7439 Fig. 1,
    /// scaled ±10°, L). Sizes from NR06 (M). The hatch and rendezvous
    /// windows lie between Xa 1043.4 and 1081.13 (D7564 Fig. 6, M); their
    /// and the side windows' stations in that band are estimates (L). The
    /// frames are 1.25 in wide (L).
    enum WindowShape { case square(Double), triangle(base: Double, height: Double), round(Double) }
    static let cmWindows: [(number: Int, theta: Double, xa: Double, shape: WindowShape)] = [
        (1, 304, 1_058, .square(13)), (2, 326, 1_070, .triangle(base: 13, height: 8)), (3, 0, 1_062.3, .round(9)),
        (4, 34, 1_070, .triangle(base: 13, height: 8)), (5, 56, 1_058, .square(13)),
    ]
    static let cmWindowFrame = 1.25                  // in, estimate (L)
    /// The unified side hatch, 29 in high (up the cone) and 34 in wide, on
    /// -Z_A over the centre couch (NR06 p. 45, M; AOH Figs. 1-4, 1-5, H),
    /// in the window band.
    static let cmHatchWidth = 34.0                   // in (M)
    static let cmHatchHeight = 29.0                  // in (M)
    static let cmHatchCentre = 1_062.3               // Xa, the band's middle (L)
    static let cmHatchRelief = 0.12                  // in above the skin (visual)
    /// The twelve RCS engines' ports in pairs (AOH Figs. 1-4, 1-5, 2.5-1):
    /// the -pitch pair on -Z_A just above the forward heat shield's base,
    /// the +pitch pair below the hatch, the yaw pairs near ±Y_A turned 30°
    /// towards -Z_A and the roll pairs on the arcs either side of -Z_A, all
    /// aft ones in the band under Xa 1043.4 (M placement; azimuths,
    /// stations and sizes not found, L). Roll ports are scarfed along the
    /// surface.
    enum RCSPort { case pitch, yaw, roll }
    static let cmRCSPorts: [(kind: RCSPort, theta: Double, xa: Double)] = [
        (.pitch, 0, 1_086), (.pitch, 0, 1_033), (.yaw, 60, 1_033), (.yaw, 300, 1_033), (.roll, 30, 1_033),
        (.roll, 330, 1_033),
    ]
    static let cmRCSPortSpacing = 6.0                // in between a pair's ports, estimate (L)
    static let cmRCSPortRadius = 1.6                 // in: the 2.13 in exit in its recess, estimate (L)
    static let cmRCSRollPort = (across: 2.4, up: 1.3)   // in, the scarfed ports' semi-axes, estimate (L)
    /// The docking probe, on CSM-107 only (A11PK): its size is not found;
    /// about 20 in of it above the interface, under the BPC's apex (L).
    static let probeLength = 20.0                    // in above the interface, estimate (L)
    static let probeBodyRadius = 9.0                 // in, estimate (L)
    static let probeShaftRadius = 1.75               // in, estimate (L)
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
    /// The apex sphere that ends the idealised cone at `cmHeight`: derived
    /// (L), 18.9 in against TM X-1243's 15.4 in and 9.1 in models.
    static let apexRadius: Double = {
        let c = shoulderCentre, start = (x: c.x + S.cmShoulderRadius * sin(theta), r: c.r + S.cmShoulderRadius * cos(theta))
        let vertex = start.x + start.r / tan(theta)
        return (vertex - S.cmHeight) / (1 / sin(theta) - 1)
    }()
    /// The docking interface above the face.
    static var top: Double { S.dockingInterface - S.cmFace }

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

    /// The idealised afterbody: the cone and TM X-1243's apex sphere, from
    /// the shoulder to the apex.
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
    /// The cone's theoretical vertex above the face.
    static var coneVertex: Double { coneStation(atRadius: 0) }

    /// The point at `x` (in above the face) of the cone pushed out by `off`
    /// (in) along its normal, (x, r).
    static func cone(at x: Double, off: Double) -> (x: Double, r: Double) {
        (x, coneRadius(at: x - off * sin(theta)) + off * cos(theta))
    }
}

extension MaterialKey {
    // The command module's finishes (track VG3).
    public static let apolloCMWindow: MaterialKey = "apollo.cm.window"
    public static let apolloCMWindowFrame: MaterialKey = "apollo.cm.windowFrame"
    public static let apolloCMRCSPort: MaterialKey = "apollo.cm.rcsPort"
    public static let apolloDockingRing: MaterialKey = "apollo.cm.dockingRing"
    public static let apolloDockingProbe: MaterialKey = "apollo.cm.probe"
}

extension ApolloDresser {
    static let cmWindow = Finish(colour: (0.08, 0.09, 0.1), material: .apolloCMWindow)
    static let cmWindowFrame = Finish(colour: (0.35, 0.35, 0.37), material: .apolloCMWindowFrame)
    static let cmRCSPort = Finish(colour: (0.12, 0.11, 0.1), material: .apolloCMRCSPort)
    static let dockingRing = Finish(colour: (0.7, 0.7, 0.72), material: .apolloDockingRing)
    static let dockingProbe = Finish(colour: (0.6, 0.6, 0.62), material: .apolloDockingProbe)

    func cmShapes() -> [VisualShape]? {
        typealias A = ApolloDresser
        switch part.name {
        case "CM":
            return commandModule()
        case "Apex cover":
            return [apexCover()] + cmRCSPorts(forward: true)
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

    /// The heat shield (emissive) and the afterbody up to the docking
    /// interface, with the forward heat shield's opening, the tunnel and
    /// the forward hatch; when the apex cover is a part of its own, the
    /// afterbody stops at the forward heat shield's base and shows the
    /// forward deck and the tunnel. Then the docking ring, the hatch, the
    /// windows, the RCS ports (the -pitch pair on the cover when it is a
    /// part) and, on CSM-107, the probe. The whole CM wears the Kapton tape
    /// (D7564: "over the entire external surface of the ablator", H).
    func commandModule() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias M = CMOuterMouldLine
        let face = Vec3(cm(0), 0, 0), inch = D.inch
        var heatShield = revolution(M.heatShield.map { P($0.x * inch, $0.r * inch) }, at: face, A.silver)
        heatShield.capTop = false
        heatShield.emissive = .heatShield
        let top = M.top, hatch = M.top - S.forwardHatchDepth
        let bore = [P(top, S.tunnelClearRadius, crease: true), P(hatch, S.tunnelClearRadius, crease: true), P(hatch, 0)]
        let upper: [P]
        if apexCovered {
            let base = S.forwardHeatShieldBase - S.cmFace
            upper = [P(base, M.coneRadius(at: base), crease: true), P(base, S.tunnelRadius, crease: true),
                     P(top, S.tunnelRadius, crease: true)]
        } else {
            upper = [P(top, M.coneRadius(at: top), crease: true)]
        }
        let start = M.heatShield[M.heatShield.count - 1]
        var afterbody = revolution(([P(start.x, start.r)] + upper + bore).map { P($0.x * inch, $0.r * inch, crease: $0.crease) },
                                   at: face, A.silver)
        afterbody.capBase = false
        var shapes = [heatShield, afterbody, dockingRing(), cmHatch()] + cmWindows()
        shapes += cmRCSPorts(forward: false) + (apexCovered ? [] : cmRCSPorts(forward: true))
        if variant.csm == .csm107 { shapes.append(dockingProbe()) }
        return shapes
    }

    /// The forward heat shield: the OML from the forward heat shield's base
    /// to its opening round the docking ring, open below.
    func apexCover() -> VisualShape {
        typealias M = CMOuterMouldLine
        let base = S.forwardHeatShieldBase - S.cmFace, inch = D.inch
        let profile = [P(0, M.coneRadius(at: base)), P(M.top - base, M.coneRadius(at: M.top), crease: true),
                       P(M.top - base, S.tunnelRadius)]
        var s = revolution(profile.map { P($0.x * inch, $0.r * inch, crease: $0.crease) },
                           at: Vec3(cm(base), 0, 0), ApolloDresser.silver)
        s.capBase = false
        s.capTop = false
        s.twoSided = true
        return s
    }

    /// The docking ring at the interface, standing a little proud of the
    /// shield's opening and the tunnel.
    func dockingRing() -> VisualShape {
        let inch = D.inch, h = S.dockingRingHeight, lip = 0.05
        let ro = S.tunnelRadius + lip, ri = S.tunnelClearRadius - lip
        let profile = [P(0, ro), P(h + lip, ro), P(h + lip, ri), P(0, ri), P(0, ro)]
        var s = revolution(profile.map { P($0.x * inch, $0.r * inch, crease: true) },
                           at: Vec3(cm(CMOuterMouldLine.top - h), 0, 0), ApolloDresser.dockingRing)
        s.capBase = false
        s.capTop = false
        return s
    }

    /// The docking probe (CSM-107): its body in the tunnel, a tapering neck
    /// and the shaft to its head.
    func dockingProbe() -> VisualShape {
        let inch = D.inch, body = S.probeBodyRadius, shaft = S.probeShaftRadius, l = S.probeLength
        let profile = [P(0, 0), P(0, body, crease: true), P(7, body, crease: true), P(9, 0.55 * body),
                       P(10, shaft, crease: true), P(l + 4, shaft, crease: true), P(l + 5, 0.7 * shaft), P(l + 6, 0)]
        return revolution(profile.map { P($0.x * inch, $0.r * inch, crease: $0.crease) },
                          at: Vec3(cm(CMOuterMouldLine.top - 6), 0, 0), segments: 32, ApolloDresser.dockingProbe)
    }

    // MARK: Surface features

    /// The frame of the cone at `x` (in above the face) and vehicle azimuth
    /// `theta` (rad), pushed out by `off` (in): the construction point, the
    /// outward normal, and the directions round and up the cone.
    func cmConeFrame(x: Double, theta: Double, off: Double = 0) -> (at: Vec3, normal: Vec3, across: Vec3, up: Vec3) {
        typealias F = SpacecraftGeometry
        typealias M = CMOuterMouldLine
        let p = M.cone(at: x, off: off), out = F.radial(theta), c = M.theta
        let at = Vec3(cm(p.x), 0, 0) + out * (p.r * D.inch)
        let normal: Vec3 = Vec3.unitX * sin(c) + out * cos(c)
        let up: Vec3 = Vec3.unitX * cos(c) - out * sin(c)
        return (at, normal, F.tangent(theta), up)
    }

    /// The unified hatch: a panel of the cone standing `off` (in) proud of
    /// it, 34 in round at its middle and 29 in up the cone, its edges sunk.
    func cmHatch(off: Double = ApolloShapeData.cmHatchRelief, _ finish: Finish = ApolloDresser.silver) -> VisualShape {
        typealias M = CMOuterMouldLine
        let inch = D.inch, mid = S.cmHatchCentre - S.cmFace, half = S.cmHatchHeight / 2 * cos(M.theta)
        let lo = M.cone(at: mid - half, off: off), hi = M.cone(at: mid + half, off: off), sink = 0.25
        let width = S.cmHatchWidth / M.coneRadius(at: mid) / 2
        let profile = [P(0, lo.r - sink), P(0, lo.r), P(hi.x - lo.x, hi.r), P(hi.x - lo.x, hi.r - sink)]
        var s = revolution(profile.map { P($0.x * inch, $0.r * inch, crease: true) }, at: Vec3(cm(lo.x), 0, 0),
                           reference: SpacecraftGeometry.radial(0), sweep: -width...width, finish)
        s.capBase = false
        s.capTop = false
        return s
    }

    /// The five windows: each pane sunk a little in its frame, the frame's
    /// sides one prism each (a ring for the round hatch window).
    func cmWindows() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, w = S.cmWindowFrame * inch
        var shapes: [VisualShape] = []
        for window in S.cmWindows {
            let f = cmConeFrame(x: window.xa - S.cmFace, theta: window.theta * SpacecraftGeometry.degree)
            let pane: [(Double, Double)]
            switch window.shape {
            case let .square(side):
                let h = side / 2 * inch
                pane = [(-h, -h), (h, -h), (h, h), (-h, h)]
            case let .triangle(base, height):
                // About its centroid, so the prism's axis is its fan's centre.
                let b = base / 2 * inch, h = height * inch
                pane = [(-b, -h / 3), (b, -h / 3), (0, 2 * h / 3)]
            case let .round(diameter):
                pane = SpacecraftGeometry.ellipse(diameter / 2 * inch, diameter / 2 * inch, count: 16)
            }
            shapes.append(scPatch(at: f.at, normal: f.normal, across: f.across, up: f.up, outline: pane,
                                  depth: 0.9 * inch, height: 0.25 * inch, A.cmWindow))
            if case let .round(diameter) = window.shape {
                shapes.append(finished(.torus(centre: local(f.at + f.normal * (0.25 * inch)), axis: f.normal,
                                              majorRadius: diameter / 2 * inch + w / 2, minorRadius: w / 2, segments: 24,
                                              minorSegments: 8, color: A.cmWindowFrame.colour), A.cmWindowFrame))
            } else {
                let outer = SpacecraftGeometry.offsetPolygon(pane, by: w)
                for i in pane.indices {
                    let j = (i + 1) % pane.count
                    shapes.append(scPatch(at: f.at, normal: f.normal, across: f.across, up: f.up,
                                          outline: [pane[i], outer[i], outer[j], pane[j]], depth: 0.9 * inch,
                                          height: 0.45 * inch, A.cmWindowFrame))
                }
            }
        }
        return shapes
    }

    /// The RCS ports of the forward compartment (the -pitch pair) or the
    /// aft: dark recesses in the tape, each pair side by side round the CM,
    /// on its surface pushed out by `off` (in; the BPC's blow-out ports).
    func cmRCSPorts(forward: Bool, off: Double = 0) -> [VisualShape] {
        let inch = D.inch, pair = S.cmRCSPortSpacing / 2 * inch, deg = SpacecraftGeometry.degree
        var shapes: [VisualShape] = []
        for port in S.cmRCSPorts where (port.xa > S.forwardHeatShieldBase) == forward {
            let outline: [(Double, Double)]
            switch port.kind {
            case .pitch, .yaw:
                outline = SpacecraftGeometry.ellipse(S.cmRCSPortRadius * inch, S.cmRCSPortRadius * inch)
            case .roll:
                outline = SpacecraftGeometry.ellipse(S.cmRCSRollPort.across * inch, S.cmRCSRollPort.up * inch)
            }
            let f = cmConeFrame(x: port.xa - S.cmFace, theta: port.theta * deg, off: off)
            for side in [-1.0, 1.0] {
                shapes.append(scPatch(at: f.at + f.across * (side * pair), normal: f.normal, across: f.across, up: f.up,
                                      outline: outline, depth: 0.6 * inch, height: 0.1 * inch, ApolloDresser.cmRCSPort))
            }
        }
        return shapes
    }

    /// A stowed parachute item in the forward compartment, at `azimuth`
    /// (deg from +Y_A towards +Z_A).
    func stowed(at azimuth: Double, radius: Double, height: Double, _ finish: Finish) -> VisualShape {
        let a = azimuth * Double.pi / 180, inch = D.inch, base = S.forwardHeatShieldBase - S.cmFace
        let d = ApolloAxes.direction(xa: 0, ya: cos(a), za: sin(a)) * ((S.tunnelRadius + radius + 1) * inch)
        return frustum(cm(base), cm(base + height), radius * inch, radius * inch, finish, y: d.y, z: d.z)
    }
}

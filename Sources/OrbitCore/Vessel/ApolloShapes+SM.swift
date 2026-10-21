import Foundation

// The service module: its shell and fairing, radiators, SM RCS quads, VHF
// scimitars, high-gain antenna and SPS (track VG3); and the geometry the
// spacecraft's files share (`SpacecraftGeometry`, the `sc` helpers).

extension ApolloShapeData {
    // MARK: Service module (datasheet §10)
    //
    // Stations in Xa (in), azimuths θ_A in degrees from +Y_A towards +Z_A
    // (the AOH's), radii in inches from the axis.

    /// The cylinder runs from the aft bulkhead to the forward bulkhead, 154
    /// in across (`AS506.csmDiameter`); the CM/SM fairing above it carries
    /// the CM's heat shield and the BPC's aft edge.
    static let smAftBulkhead = 838.0                 // Xa, AOH Fig. 1-2, DB3 Fig. 2-2 (H)
    static let smForwardBulkhead = 993.0             // Xa (Xs 355), DB3 Fig. 2-2, AOH Fig. 1-2 (H)
    static let smFairingTop = 1_014.72               // Xa, DB3 Fig. 2-10 (H)
    /// The fairing's sixteen pieces: eight EPS radiators alternating with
    /// eight honeycomb panels (NR07 p. 55, M), taken as equal 22.5° pieces
    /// with the first radiator from +Y_A: widths and azimuths not found (L).
    static let smFairingPieces = 16
    static let smFairingPhase = 0.0                  // deg θ_A, estimate (L)
    /// The ECS radiators, panel 1 in bays 2-3 and panel 2 in bays 5-6
    /// between the radial beams (AOH §2.7, DB3 Fig. 2-6, H), on the SM's
    /// lower part: the station is not found, VD2's 838-880 band (csm.csv
    /// 101-003, L) gives the 41 in that 50 ft² of 130° arc needs (M).
    static let ecsRadiators: [ClosedRange<Double>] = [332.75...462.75, 152.75...282.75]   // deg θ_A (H)
    static let ecsRadiatorBottom = 838.5             // Xa, estimate (L)
    static let ecsRadiatorTop = 880.0                // Xa, VD2 (L)
    static let radiatorStandOff = 0.25               // in above the skin, estimate (L)

    // MARK: SM RCS (DB3 Fig. 2-5)

    /// Four packages 90° apart, each 7°15′ off its axis, counter-clockwise
    /// looking forward: A at -Z_A, B at +Y_A, C at +Z_A, D at -Y_A.
    static let rcsQuadStation = 958.97               // Xa, DB3 Fig. 2-5; BCD STA 3715.45 (H)
    static let rcsQuads: [(name: String, azimuth: Double)] = [("A", 262.75), ("B", 352.75), ("C", 82.75),
                                                              ("D", 172.75)]   // deg θ_A, DB3 Fig. 2-5 (H)
    /// The housing: its outer face 6.56 in off the skin, about 13.5 in long
    /// at the skin, its fore and aft faces square to the canted engines.
    /// Its width round the SM is not given: as its length (L).
    static let rcsHousingFace = 83.56                // in from the axis, DB3 Fig. 2-5 (H)
    static let rcsHousingHalfLength = 6.75           // in at the skin, DB3 Fig. 2-5 (M)
    static let rcsHousingHalfWidth = 6.75            // in, estimate (L)
    /// The R-4Ds: the fore and aft (pitch or yaw) engines' thrust lines meet
    /// 82.36 in from the axis, canted 10° away from the panel; the roll
    /// engines' meet at 83.00 in, square to the radius.
    static let rcsAxialThrustLine = 82.36            // in, DB3 Fig. 2-5 (H)
    static let rcsRollThrustLine = 83.0              // in, DB3 Fig. 2-5 (H)
    static let rcsCant = 10.0                        // deg, DB3 Fig. 2-5 (H)
    static let rcsExitDiameter = 5.6                 // in, R-4D, AOH p. 2.5-24 (H)
    /// From the thrust lines' meeting point to an exit: the 13.4 in engine
    /// (AOH p. 2.5-24, H) with its injector an inch behind that point (L).
    static let rcsExitDistance = 12.4                // in, estimate (L)
    static let rcsBellLength = 6.5                   // in of the bell showing, estimate (L)

    // MARK: Antennas (datasheet §10)

    /// The two VHF scimitars, 180° apart near ±Y_A: azimuths scaled off AOH
    /// Fig. 2.8-28; station from the AOH sketch and size from one of the two
    /// disagreeing sources (19 × 9 × 1 in), all L.
    static let scimitarAzimuths = [24.0, 204.0]      // deg θ_A, scaled (L)
    static let scimitarStation = 926.0               // Xa, the blade's middle, AOH sketch (L)
    static let scimitarLength = 19.0                 // in (L)
    static let scimitarHeight = 9.0                  // in off the skin (L)
    static let scimitarThickness = 1.0               // in (L)
    /// The high-gain antenna, on CSM-103 and CSM-107 only (A8MR p. 6-25;
    /// A11PK p. 90): four 31 in dishes round an 11 in square horn, its root
    /// at the aft bulkhead's edge at θ_A 127.75° (AOH Figs. 2.8-28, 2.8-30,
    /// H). Stowed it lies folded aft along the SPS nozzle; deployed, at
    /// right angles to X, the array's centre about 38 in outboard of the
    /// skin (TRW Fig. 2-2, M). The boom's length is not found (49-58 in on
    /// the TRW sketch, L): a 52 in boom hinged 14 in inboard of the skin
    /// puts the array 38 in out. Deployed, the dishes look aft.
    static let hgaAzimuth = 127.75                   // deg θ_A (H)
    static let hgaDishDiameter = 31.0                // in, A11PK p. 90 (H)
    static let hgaHornWidth = 11.0                   // in, A11PK p. 90 (H)
    static let hgaDishDepth = 5.0                    // in, estimate (L)
    static let hgaHornLength = 8.0                   // in, estimate (L)
    static let hgaOutboard = 38.0                    // in, the deployed array's centre off the skin, TRW (M)
    static let hgaBoomLength = 52.0                  // in, TRW sketch 49-58 (L)
    static let hgaHinge = 836.0                      // Xa, just aft of the aft bulkhead, estimate (L)
    static let hgaBoomRadius = 1.5                   // in, estimate (L)

    // MARK: SPS (AJ10-137)

    /// The nozzle extension's exit (inside diameter) and the gimbal plane:
    /// the bell from the gimbal to the exit is 111.9 in of the engine's
    /// 159.944 in (AOH 2.4-43, H). The bell is the dresser's generic one
    /// over the whole engine, so its throat and chamber sit in the SM above
    /// the gimbal plane, where it is cut off (its throat at Xa 849): the 6:1
    /// chamber exit falls 1.8 in below the gimbal, and all that shows under
    /// the SM is the nozzle extension, 28.8 in across at the top (shape L).
    static let spsExitDiameter = 98.4                // in, AOH Vol. 1 2.4-43 (H; track D's aoh_block2_sps_rcs.csv)
    static let spsAreaRatio = 62.5                   // AOH Vol. 1 2.4-43 (H)
    static let spsLength = 159.944                   // in, overall, AOH Vol. 1 2.4-43 (H)
    static let spsGimbal = 833.2                     // Xa, DB3 Figs. 2-2, 2-10 (H)
    static let spsExit = 721.3                       // Xa, the aft-most point, DB3 Fig. 2-10 (H)
    /// The extension's two materials: radiation-cooled columbium from the
    /// ablative chamber's 6:1 exit, titanium below (AOH §2.4, NR17, M). The
    /// joint's station is not found: halfway down the extension's length
    /// (L), where its external stiffener is drawn too (L).
    static let spsChamberAreaRatio = 6.0             // AOH 2.4-43 (H)
    static let spsJoint = 760.0                      // Xa, estimate (L)
    static let spsBandStandOff = 0.08                // in, the columbium band over the bell (visual)
    static let spsStiffenerRadius = 0.75             // in, estimate (L)
}

extension MaterialKey {
    // The service module's finishes (track VG3), beside the dresser's.
    public static let apolloSMRadiator: MaterialKey = "apollo.sm.radiator"
    public static let apolloSMRCSHousing: MaterialKey = "apollo.sm.rcsHousing"
    public static let apolloSMScimitar: MaterialKey = "apollo.sm.scimitar"
    public static let apolloHighGainAntenna: MaterialKey = "apollo.sm.hga"
    public static let apolloSPSColumbium: MaterialKey = "apollo.sps.columbium"
}

/// The spacecraft files' shared geometry: directions about the vehicle's
/// axis in the construction frame, a bell's contour, small outlines. The
/// vehicle azimuth θ runs from Position I (+z)
/// towards Position II (-y), right-handed about +x; the AOH's θ_A runs from
/// +Y_A (Position II) towards +Z_A (Position III), so θ = θ_A + 90°
/// (datasheet conventions).
enum SpacecraftGeometry {
    static let degree = Double.pi / 180

    /// The unit vector away from the axis at vehicle azimuth `theta` (rad).
    static func radial(_ theta: Double) -> Vec3 { Vec3(0, -sin(theta), cos(theta)) }

    /// The unit vector along increasing azimuth at `theta` (rad).
    static func tangent(_ theta: Double) -> Vec3 { Vec3(0, -cos(theta), -sin(theta)) }

    /// The vehicle azimuth (rad) of the AOH's θ_A `thetaA` (deg).
    static func theta(apollo thetaA: Double) -> Double { (thetaA + 90) * degree }

    /// +Y_A: the reference that makes a revolution's sweep θ_A.
    static let apolloReference = Vec3(0, -1, 0)
}

extension SpacecraftGeometry {
    /// The radius of a bell's divergent `contour` (from the exit up, the
    /// radius falling) at `x` along it.
    static func contourRadius(_ contour: [VisualShape.ProfilePoint], at x: Double) -> Double {
        for (a, b) in zip(contour, contour.dropFirst()) where x >= a.x && x <= b.x {
            return a.r + (b.r - a.r) * (x - a.x) / (b.x - a.x)
        }
        return x < contour[0].x ? contour[0].r : contour[contour.count - 1].r
    }

    /// Where a bell's divergent `contour` has radius `r`.
    static func contourStation(_ contour: [VisualShape.ProfilePoint], radius r: Double) -> Double {
        for (a, b) in zip(contour, contour.dropFirst()) where r <= a.r && r >= b.r {
            return a.x + (b.x - a.x) * (a.r - r) / (a.r - b.r)
        }
        return r > contour[0].r ? contour[0].x : contour[contour.count - 1].x
    }

    /// `count` points round an ellipse of semi-axes `a` (across) and `b`
    /// (up), counter-clockwise.
    static func ellipse(_ a: Double, _ b: Double, count: Int = 12) -> [(Double, Double)] {
        (0..<count).map { i -> (Double, Double) in
            let t = 2 * Double.pi * Double(i) / Double(count)
            return (a * cos(t), b * sin(t))
        }
    }

    /// The convex counter-clockwise polygon `p` grown by `d` on every side.
    static func offsetPolygon(_ p: [(Double, Double)], by d: Double) -> [(Double, Double)] {
        let n = p.count
        // Each edge's line moved out along its outward normal (to the right
        // of a counter-clockwise edge).
        let lines = (0..<n).map { i -> (point: (Double, Double), dir: (Double, Double)) in
            let a = p[i], b = p[(i + 1) % n], l = ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot()
            let dir = ((b.0 - a.0) / l, (b.1 - a.1) / l)
            return ((a.0 + dir.1 * d, a.1 - dir.0 * d), dir)
        }
        // Vertex i where the moved lines of edges i - 1 and i meet.
        return (0..<n).map { i -> (Double, Double) in
            let e = lines[(i + n - 1) % n], f = lines[i]
            let det = e.dir.0 * f.dir.1 - e.dir.1 * f.dir.0
            let dx = f.point.0 - e.point.0, dy = f.point.1 - e.point.1
            let t = (dx * f.dir.1 - dy * f.dir.0) / det
            return (e.point.0 + e.dir.0 * t, e.point.1 + e.dir.1 * t)
        }
    }
}

extension ApolloDresser {
    static let smRadiator = Finish(colour: (0.88, 0.88, 0.86), material: .apolloSMRadiator)
    static let smRCSHousing = Finish(colour: (0.86, 0.86, 0.84), material: .apolloSMRCSHousing)
    static let smScimitar = Finish(colour: (0.8, 0.8, 0.8), material: .apolloSMScimitar)
    static let hgaWhite = Finish(colour: (0.88, 0.88, 0.86), material: .apolloHighGainAntenna)
    static let spsColumbium = Finish(colour: (0.3, 0.3, 0.33), material: .apolloSPSColumbium)

    func smShapes() -> [VisualShape]? {
        switch part.name {
        case "CSM":
            return serviceModule() + commandModule()
        case "SM":
            return serviceModule()
        default:
            return nil
        }
    }

    func smAttachments() -> [VisualAttachment] { [] }

    /// The shell, the fairing and radiators, the scimitars, the RCS quads,
    /// the HGA (CSM-103 and CSM-107) and the SPS.
    func serviceModule() -> [VisualShape] {
        let inch = D.inch, r = ApolloDresser.csmRadius
        let height = (S.smForwardBulkhead - S.smAftBulkhead) * inch
        // 64 facets: 9 mm from the true circle at the SM's radius.
        let shell = revolution([P(0, r, crease: true), P(height, r, crease: true)],
                               at: Vec3(xa(S.smAftBulkhead), 0, 0), segments: 64, ApolloDresser.aluminium)
        var shapes = [shell] + smFairing() + ecsRadiators() + scimitars() + rcsQuads()
        if variant.csm != .csm101 { shapes += highGainAntenna(deployed: part.centeredUntilEvent == nil) }
        return shapes + sps()
    }

    /// The CM/SM fairing, open at the top round the CM's heat shield: its
    /// pieces, EPS radiators alternating with honeycomb panels.
    func smFairing() -> [VisualShape] {
        let inch = D.inch, r = ApolloDresser.csmRadius, deg = SpacecraftGeometry.degree
        let height = (S.smFairingTop - S.smForwardBulkhead) * inch
        let width = 360.0 / Double(S.smFairingPieces)
        return (0..<S.smFairingPieces).map { i -> VisualShape in
            let start = (S.smFairingPhase + width * Double(i)) * deg
            let finish = i % 2 == 0 ? ApolloDresser.smRadiator : ApolloDresser.aluminium
            var s = revolution([P(0, r), P(height, r)], at: Vec3(xa(S.smForwardBulkhead), 0, 0),
                               reference: SpacecraftGeometry.apolloReference, segments: 64,
                               sweep: start...(start + width * deg), finish)
            s.capBase = false
            s.capTop = false
            s.twoSided = true
            return s
        }
    }

    /// The two ECS radiator panels, standing just off the skin with their
    /// edges showing.
    func ecsRadiators() -> [VisualShape] {
        let inch = D.inch, r = ApolloDresser.csmRadius, deg = SpacecraftGeometry.degree
        let h = S.radiatorStandOff * inch, height = (S.ecsRadiatorTop - S.ecsRadiatorBottom) * inch
        let profile = [P(0, r - h, crease: true), P(0, r + h, crease: true), P(height, r + h, crease: true),
                       P(height, r - h, crease: true)]
        return S.ecsRadiators.map { bays -> VisualShape in
            var s = revolution(profile, at: Vec3(xa(S.ecsRadiatorBottom), 0, 0),
                               reference: SpacecraftGeometry.apolloReference, segments: 64,
                               sweep: (bays.lowerBound * deg)...(bays.upperBound * deg), ApolloDresser.smRadiator)
            s.capBase = false
            s.capTop = false
            return s
        }
    }

    /// The VHF scimitars: thin swept blades standing off the skin, their
    /// roots sunk a little into it.
    func scimitars() -> [VisualShape] {
        let inch = D.inch, skin = ApolloDresser.csmRadius
        let l = S.scimitarLength, h = S.scimitarHeight
        // Root along the skin, the leading edge sweeping forward to the tip
        // and the trailing edge curving back to the root (L).
        // The outline keeps clear of the plate's own axis (b = 0), half an
        // inch under the skin, so its azimuth has no seam.
        let outline: [(Double, Double)] = [(0, 0.25), (0.37 * l, 0.25), (0.58 * l, 0.28 * h), (0.79 * l, 0.67 * h),
                                           (l, h), (0.76 * l, 0.91 * h), (0.47 * l, 0.7 * h), (0.21 * l, 0.4 * h)]
        let section = outline.map { VisualShape.SectionPoint($0.0 * inch, ($0.1 + 0.5) * inch) }
        return S.scimitarAzimuths.map { azimuth -> VisualShape in
            let theta = SpacecraftGeometry.theta(apollo: azimuth), out = SpacecraftGeometry.radial(theta)
            let root = Vec3(xa(S.scimitarStation - l / 2), 0, 0) + out * (skin - 0.5 * inch)
            return finished(.plate(section, at: local(root), axis: .unitX, reference: out,
                                   thickness: S.scimitarThickness * inch,
                                   color: ApolloDresser.smScimitar.colour), ApolloDresser.smScimitar)
        }
    }

    // MARK: SM RCS

    /// One R-4D nozzle of the SM RCS layout: its quad, its exit's centre
    /// (construction) and the way its exhaust leaves.
    struct RCSNozzle {
        var quad: String
        var exit: Vec3
        var exhaust: Vec3
    }

    /// The sixteen engines as DB3 Fig. 2-5 places them: on each quad the
    /// fore and aft engines along ±X canted 10° outwards, their thrust lines
    /// meeting 82.36 in from the axis, and the two roll engines either way
    /// round, theirs meeting at 83.00 in.
    static func rcsLayout() -> [RCSNozzle] {
        typealias F = SpacecraftGeometry
        let inch = D.inch, cant = S.rcsCant * F.degree, reach = S.rcsExitDistance * inch
        let station = D.apolloStation(S.rcsQuadStation)
        var nozzles: [RCSNozzle] = []
        for quad in S.rcsQuads {
            let theta = F.theta(apollo: quad.azimuth), out = F.radial(theta), along = F.tangent(theta)
            let axial = Vec3(station, 0, 0) + out * (S.rcsAxialThrustLine * inch)
            let roll = Vec3(station, 0, 0) + out * (S.rcsRollThrustLine * inch)
            for sign in [1.0, -1.0] {
                let exhaust: Vec3 = Vec3.unitX * (sign * cos(cant)) + out * sin(cant)
                nozzles.append(RCSNozzle(quad: quad.name, exit: axial + exhaust * reach, exhaust: exhaust))
            }
            for sign in [1.0, -1.0] {
                let exhaust = along * sign
                nozzles.append(RCSNozzle(quad: quad.name, exit: roll + exhaust * reach, exhaust: exhaust))
            }
        }
        return nozzles
    }

    /// The four SM RCS packages: each housing and its four nozzles, linked
    /// to the part's "SM RCS" thrusters where it has them: each thruster
    /// takes the nozzle of its quad (the letter after "SM RCS ") whose
    /// exhaust best opposes its thrust. A thruster left without one gets a
    /// nozzle of its own at its position.
    func rcsQuads() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias F = SpacecraftGeometry
        let inch = D.inch, skin = A.csmRadius
        let exitRadius = S.rcsExitDiameter / 2 * inch, bell = S.rcsBellLength * inch
        /// A nozzle's bell, open, from its exit back towards its throat.
        func nozzle(exit: Vec3, exhaust: Vec3, thruster: String?) -> VisualShape {
            let profile = [P(0, exitRadius), P(0.45 * bell, 0.68 * exitRadius), P(bell, 0.36 * exitRadius)]
            var s = finished(VisualShape.revolution(profile, from: local(exit), axis: -exhaust, segments: 16,
                                                    color: A.dark.colour), A.dark, vehicleFrame: false)
            s.capBase = false
            s.capTop = false
            s.twoSided = true
            s.thruster = thruster
            return s
        }

        var shapes: [VisualShape] = []
        let face = (S.rcsHousingFace - S.csmSkinRadius) * inch, l0 = S.rcsHousingHalfLength * inch
        let l1 = l0 - face * tan(S.rcsCant * F.degree), w = S.rcsHousingHalfWidth * inch
        // The prism's axis an inch under the skin, clear of its section.
        let under = 1.0 * inch, sink = under - 0.4 * inch
        let section = [(-l0, sink), (l0, sink), (l1, under + face), (-l1, under + face)]
            .map { VisualShape.SectionPoint($0.0, $0.1, crease: true) }
        for quad in S.rcsQuads {
            let theta = F.theta(apollo: quad.azimuth), out = F.radial(theta), along = F.tangent(theta)
            let base = Vec3(xa(S.rcsQuadStation), 0, 0) + out * skin - out * under - along * w
            shapes.append(finished(.prism(section, from: local(base), length: 2 * w, axis: along,
                                          reference: .unitX, color: A.smRCSHousing.colour), A.smRCSHousing))
        }

        let layout = ApolloDresser.rcsLayout()
        var links = [String?](repeating: nil, count: layout.count)
        var extra: [VisualShape] = []
        for t in part.thrusters.filter({ $0.name.hasPrefix("SM RCS ") }).sorted(by: { $0.name < $1.name }) {
            let quad = String(t.name.dropFirst("SM RCS ".count).prefix(1))
            let free = layout.indices.filter { links[$0] == nil && layout[$0].quad == quad }
            if let best = free.min(by: { layout[$0].exhaust.dot(t.direction) < layout[$1].exhaust.dot(t.direction) }) {
                links[best] = t.name
            } else {
                extra.append(nozzle(exit: t.position + construction - t.direction * bell, exhaust: -t.direction,
                                    thruster: t.name))
            }
        }
        for (n, link) in zip(layout, links) { shapes.append(nozzle(exit: n.exit, exhaust: n.exhaust, thruster: link)) }
        return shapes + extra
    }

    // MARK: High-gain antenna

    /// The HGA's boom and array (four dishes and the horn), stowed folded
    /// aft beside the SPS nozzle or deployed out at right angles to X. The
    /// deploy turns the stowed boom and array a right angle about the
    /// hinge's tangential axis, taking -X to the radial direction.
    func highGainAntenna(deployed: Bool) -> [VisualShape] {
        typealias A = ApolloDresser
        typealias F = SpacecraftGeometry
        let inch = D.inch, theta = F.theta(apollo: S.hgaAzimuth)
        let out = F.radial(theta), along = F.tangent(theta)
        let hingeRadius = S.csmSkinRadius + S.hgaOutboard - S.hgaBoomLength
        let hinge = Vec3(xa(S.hgaHinge), 0, 0) + out * (hingeRadius * inch)
        // Stowed, from the hinge: the array's centre a boom's length aft and
        // 4 in out, its dishes looking in at the nozzle.
        let lift = S.hgaHornLength / 2
        let centreOffset: Vec3 = Vec3.unitX * (-S.hgaBoomLength * inch) + out * ((lift + S.hgaDishDepth / 2) * inch)
        var boresight = -out, u = Vec3.unitX, offset = centreOffset
        if deployed {
            // -X -> out, out -> +X.
            func turn(_ v: Vec3) -> Vec3 { out * (-v.x) + Vec3.unitX * v.dot(out) + along * v.dot(along) }
            boresight = turn(boresight)
            u = turn(u)
            offset = turn(offset)
        }
        let centre = hinge + offset, v = along
        let back = centre - boresight * (lift * inch)
        let rDish = S.hgaDishDiameter / 2, spread = (S.hgaHornWidth / 2 * 2.0.squareRoot() + rDish) / 2.0.squareRoot()
        let dish = (0...4).map { i -> P in
            let f = Double(i) / 4
            return P(S.hgaDishDepth * f * f * inch, rDish * f * inch)
        }
        var shapes = [scTube(hinge, back, radius: S.hgaBoomRadius * inch, A.hgaWhite)]
        for (su, sv) in [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] {
            let at: Vec3 = centre + u * (su * spread * inch) + v * (sv * spread * inch)
                - boresight * (S.hgaDishDepth / 2 * inch)
            var s = finished(VisualShape.revolution(dish, from: local(at), axis: boresight, segments: 24,
                                                    color: A.hgaWhite.colour), A.hgaWhite)
            s.capBase = false
            s.capTop = false
            s.twoSided = true
            shapes.append(s)
        }
        let horn = S.hgaHornWidth * inch
        shapes.append(finished(.box(from: local(centre - boresight * (lift * inch)), length: 2 * lift * inch,
                                    width: horn, height: horn, axis: boresight, reference: u,
                                    color: A.hgaWhite.colour), A.hgaWhite))
        return shapes
    }

    // MARK: SPS

    /// The SPS nozzle, linked to the "SPS" thruster when the part has one so
    /// all of it turns with the gimbal: the stiffener ring and the columbium
    /// band over the upper extension, then the whole bell from the exit to
    /// the gimbal. The bell comes last of them: the scene takes a linked
    /// revolution's first profile point as its thruster's nozzle exit
    /// (OrbitScene's `VesselGeometry`), and the last one it finds wins.
    func sps() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, exit = xa(S.spsExit), re = S.spsExitDiameter / 2 * inch
        let link = part.thrusters.contains { $0.name == "SPS" } ? "SPS" : nil
        // The divergent contour is the bell's first eleven points.
        let contour = Array(A.bell(exitRadius: re, areaRatio: S.spsAreaRatio, length: S.spsLength * inch).prefix(11))
        let gimbal = xa(S.spsGimbal) - exit
        let profile = contour.filter { $0.x < gimbal - 1e-9 } + [P(gimbal, SpacecraftGeometry.contourRadius(contour, at: gimbal))]
        var bell = finished(.revolution(profile, from: local(Vec3(exit, 0, 0)), color: A.nozzleExtension.colour),
                            A.nozzleExtension, vehicleFrame: false)
        bell.capBase = false
        bell.twoSided = true
        bell.thruster = link

        let chamber = re / (S.spsAreaRatio / S.spsChamberAreaRatio).squareRoot()
        let top = min(SpacecraftGeometry.contourStation(contour, radius: chamber), gimbal), joint = xa(S.spsJoint) - exit
        let lift = S.spsBandStandOff * inch
        let band = [P(joint, SpacecraftGeometry.contourRadius(contour, at: joint) + lift)]
            + contour.filter { $0.x > joint && $0.x < top }.map { P($0.x, $0.r + lift) }
            + [P(top, SpacecraftGeometry.contourRadius(contour, at: top) + lift)]
        var columbium = finished(.revolution(band, from: local(Vec3(exit, 0, 0)), color: A.spsColumbium.colour),
                                 A.spsColumbium, vehicleFrame: false)
        columbium.capBase = false
        columbium.capTop = false
        columbium.thruster = link
        let minor = S.spsStiffenerRadius * inch
        var stiffener = finished(.torus(centre: local(Vec3(exit + joint, 0, 0)),
                                        majorRadius: SpacecraftGeometry.contourRadius(contour, at: joint) + minor, minorRadius: minor,
                                        segments: 48, minorSegments: 8, color: A.nozzleExtension.colour),
                                 A.nozzleExtension, vehicleFrame: false)
        stiffener.thruster = link
        return [stiffener, columbium, bell]
    }

    // MARK: Spacecraft helpers

    /// A closed tube of `radius` (m) from construction point `a` to `b`.
    func scTube(_ a: Vec3, _ b: Vec3, radius: Double, segments: Int = 12, _ finish: Finish) -> VisualShape {
        revolution([P(0, radius, crease: true), P((b - a).length, radius, crease: true)], at: a, axis: b - a,
                   segments: segments, finish)
    }

    /// A closed prism standing on a surface at construction point `at`: its
    /// section `outline` (m), each point along `across` and `up` (both
    /// perpendicular to `normal`), from `depth` under the point to `height`
    /// over it along the outward `normal` (m).
    func scPatch(at: Vec3, normal: Vec3, across: Vec3, up: Vec3, outline: [(Double, Double)], depth: Double,
                 height: Double, _ finish: Finish) -> VisualShape {
        // The prism's b runs along normal × across: up or against it.
        let sign: Double = normal.cross(across).dot(up) < 0 ? -1 : 1
        let section = outline.map { VisualShape.SectionPoint($0.0, sign * $0.1, crease: true) }
        return finished(.prism(section, from: local(at - normal * depth), length: depth + height, axis: normal,
                               reference: across, color: finish.colour), finish)
    }

}

extension ApolloShapeData {
    /// The SM's skin radius, half `AS506.csmDiameter`'s 154 in.
    static var csmSkinRadius: Double { AS506.csmDiameter / 2 }
}

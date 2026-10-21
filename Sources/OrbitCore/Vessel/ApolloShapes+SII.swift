import Foundation

// The S-II and the J-2 it shares with the S-IVB (track VG2). The S-II
// ullage motors' fairings and exits stand on the S-IC/S-II interstage and
// are VG1's (ApolloShapes+SIC.swift).
//
// Values are the exterior datasheet's (docs/SaturnV-CSM-exterior-
// datasheet.md §3, §4, §8.2), with its source keys and grades. "Scaled"
// values were read for this track off MSFC-MAN-503 (M503) Fig. 5-2 and TM
// X-53770 (TMX) Fig. 2 (full-scale stations, 1.21 in/px at 400 dpi), both
// drawn facing Position II; they are L.

extension ApolloShapeData {
    // MARK: S-II

    /// Facets round the 33 ft body (0.16 m each).
    static let bodySegments = 192

    /// The skin: the aft skirt, the LH2 tank's insulated wall and the
    /// forward skirt, all at the body's 396 in.
    static let sIIAftSkirtTop = 1_890.0              // STA, BCD (H)
    static let sIIForwardSkirtBottom = 2_387.0       // STA, BCD (H)
    /// The thrust cone, "approximately 18 feet in diameter" at its bottom,
    /// meets the skin inside the aft skirt.
    static let sIIThrustConeBottom = 1_676.0         // STA (XB 112.00), BCD (H)
    static let sIIThrustConeTop = 1_787.0            // STA (XB 223.00), BCD (H)
    static let sIIThrustConeBottomDiameter = 216.0   // in, M503 p. 5-1 (H)
    /// The LOX tank's aft bulkhead and the LH2 tank's forward bulkhead:
    /// ellipsoids of a/b 1.5 whose equators are at XB 284 and 823, so the
    /// aft one's bottom (XB 152) shows inside the thrust cone and the
    /// forward one's top reaches the forward skirt's. Drawn 2 in inside the
    /// skin.
    static let sIIBulkheadAspect = 1.5               // a/b, 2644-D (H)
    static let sIILOXBulkheadEquator = 1_848.0       // STA (XB 284), 2644-D (M)
    static let sIILH2BulkheadEquator = 2_387.0       // STA (XB 823), 2644-D (M)
    /// The fibreglass-honeycomb heat shield, its aft face at S-II station
    /// 44, and a flexible curtain round each engine, its probes at S-II
    /// station 48 about 48 in from the engine's axis: the curtain's outer
    /// edge is there, 4 in above the shield's aft face, and rises to it
    /// from the shield's forward face round the hole. The shield's edge is
    /// an estimate just outside the outboard curtains (105 + 48 in); the
    /// curtains' sag from that edge to the engine is another.
    static let sIIHeatShieldStation = 1_608.0        // STA, D5 Table 4-III (M)
    static let sIIHeatShieldRadius = 160.0           // in, estimate (L)
    static let sIIHeatShieldThickness = 2.0          // in, estimate (L)
    static let sIICurtainStation = 1_612.0           // STA (S-II station 48), D5 Table 4-IV (M)
    static let sIICurtainRadius = 48.0               // in from each engine's axis, D5 Table 4-IV (M)
    static let sIICurtainSag = 6.0                   // in, estimate (L)
    /// The systems tunnel: semicircular, 22 in wide, about 60 ft long from
    /// the aft skirt to its top on the forward skirt. M503 Fig. 5-2 draws it
    /// between Positions I and II, close to I (M): scaled at about 34° there
    /// and 30° in TMX Fig. 2. Its ends taper (M503 Fig. 5-2), over an
    /// estimated foot.
    static let sIITunnelWidth = 22.0                 // in, M503 p. 5-4 (H)
    static let sIITunnelTop = 2_502.5                // STA (XB 938.50), BCD (H)
    static let sIITunnelLength = 720.0               // in, "about 60 ft", M503 p. 5-4 (H)
    static let sIITunnelAzimuth = 32.0               // deg, scaled (L)
    static let sIITunnelTaper = 12.0                 // in, estimate (L)
    /// Five LH2 feed-line fairings, BCD's XB 158.00 to 451.75. Their lower
    /// 38 in fall on the interstage's span, below the aft skirt: the S-II's
    /// run from that joint, STA 1760, and taper at the top over an
    /// estimated 2 ft. Engine 1's at 44° and engine 4's at 314° (D5 Table
    /// 6-II, H), 2's and 3's by symmetry (M), the centre engine's scaled at
    /// about 97° in TMX Fig. 2 (L). The section is an estimate between TMX
    /// Fig. 2's (about 20-27 in across) and VD2's white strips at the cap
    /// (31-46 in; 503-055 to 503-058).
    static let sIIFeedFairingTop = 2_015.75          // STA (XB 451.75), BCD (H)
    static let sIIFeedFairingAzimuths = [44.0, 134.0, 224.0, 314.0, 97.0]   // deg, D5 (H, M); TMX (L)
    static let sIIFeedFairingWidth = 30.0            // in, estimate (L)
    static let sIIFeedFairingDepth = 12.0            // in, estimate (L)
    static let sIIFeedFairingTaper = 24.0            // in, estimate (L)
    /// Forward-skirt antennas, four radio command and four telemetry: their
    /// stations are BCD's (H). M503 Fig. 5-2 draws one of each about 9° past
    /// Position II towards III, the command antenna above; the others are
    /// taken 90° apart, and the sizes are scaled off the figure (L).
    static let sIICommandAntennaStation = 2_487.0    // STA (XB 923.00), BCD (H)
    static let sIITelemetryAntennaStation = 2_466.0  // STA (XB 902.00), BCD (H)
    static let sIIAntennaAzimuth = 99.0              // deg, scaled (L)
    static let sIICommandAntenna = (tall: 11.0, wide: 8.0, proud: 2.0)      // in, scaled (L)
    static let sIITelemetryAntenna = (tall: 14.0, wide: 14.0, proud: 2.0)   // in, scaled (L)

    // MARK: J-2

    /// The engine as RJ1 gives it: an 80.75 in envelope, its exit 77 in
    /// across inside the exit ring (the bell keeps the rating's √(A_e/π),
    /// 1.3 mm more in radius), a 14.7 in throat (`AS506.j2ThroatDiameter`)
    /// and an 18.3 in chamber on a 107 in chamber body, below the dome and
    /// gimbal bearing; gimbal to exit 116 ± 3 in (`AS506`, M). The bell's
    /// contour is the dresser's Rao-style one (L); the tube wall's
    /// thickness and the exit ring's height are estimates from the 360 up
    /// tubes round the exit, 0.67 in apart.
    static let j2EnvelopeDiameter = 80.75            // in, RJ1 §1-9 (H)
    static let j2ExitDiameter = 77.0                 // in, RJ1 §1-16 (H)
    static let j2ChamberDiameter = 18.3              // in, RJ1 §1-16 (H)
    static let j2ChamberBodyLength = 107.0           // in, RJ1 §1-16 (H)
    static let j2TubeWall = 0.75                     // in, estimate (L)
    static let j2ExitRingHeight = 3.0                // in, estimate (L)
    static let j2GimbalBearing = (diameter: 10.0, height: 6.0)   // in, RJ1 §1-19 (H)
    /// The fuel inlet manifold round the chamber's middle and the tapered
    /// turbine exhaust manifold just above it (RJ1 §1-16, H as form).
    static let j2FuelManifoldStation = 65.0          // in aft of the gimbal, scaled off NR p. 97 (L)
    static let j2FuelManifoldDiameter = 61.0         // in, scaled off NR p. 97 (L)
    static let j2TurbineManifold = (offset: 7.5, proud: 2.5)   // in above the fuel manifold, off the wall, estimate (L)
    /// The turbopumps, on opposite sides of the chamber, axes parallel to
    /// it, 21-22 in from it: their sizes RJ1 §1-21 and §1-25 (H), their
    /// places scaled off NR p. 97 (L), high enough to clear the bell. Their
    /// clocking is not known: across the outboard engines' radius here.
    static let j2FuelPump = (diameter: 18.0, length: 30.0, offset: 22.0, top: 0.0)       // in; top below the gimbal
    static let j2OxidizerPump = (diameter: 21.0, length: 18.0, offset: 21.0, top: 6.0)   // in; top below the gimbal
}

extension ApolloDresser {
    func sIIShapes() -> [VisualShape]? {
        switch part.name {
        case "S-II":
            return sIIStructure() + sIIBase() + j2Engines(exit: D.station(D.sIIJ2ExitStation))
        default:
            return nil
        }
    }

    func sIIAttachments() -> [VisualAttachment] { [] }

    /// The skin, open at both ends, with the bulkheads seen through them,
    /// the thrust cone, the systems tunnel, the feed-line fairings and the
    /// forward skirt's antennas.
    func sIIStructure() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, r = A.body
        var skin = revolution([P(D.station(D.sIIAftSkirt), r), P(D.station(S.sIIAftSkirtTop), r),
                               P(D.station(S.sIIForwardSkirtBottom), r), P(D.station(D.sIITop), r)],
                              at: .zero, segments: S.bodySegments, A.white)
        upperStageOpen(&skin)

        let tank = r - 2 * inch, b = r / S.sIIBulkheadAspect
        let aftBulkhead = revolution(upperStageDome(equator: D.station(S.sIILOXBulkheadEquator), radius: tank,
                                                    height: -b),
                                     at: .zero, segments: 96, A.grey)
        let forwardBulkhead = revolution(upperStageDome(equator: D.station(S.sIILH2BulkheadEquator), radius: tank,
                                                        height: b),
                                         at: .zero, segments: 96, A.grey)
        var cone = revolution([P(D.station(S.sIIThrustConeBottom), S.sIIThrustConeBottomDiameter / 2 * inch),
                               P(D.station(S.sIIThrustConeTop), r)], at: .zero, segments: 96, A.grey)
        upperStageOpen(&cone)

        let tunnelTop = D.station(S.sIITunnelTop)
        let tunnel = upperStageFairing(skinDirection(S.sIITunnelAzimuth), skin: r,
                                       from: tunnelTop - S.sIITunnelLength * inch, to: tunnelTop,
                                       width: S.sIITunnelWidth * inch, depth: S.sIITunnelWidth / 2 * inch,
                                       taperBottom: S.sIITunnelTaper * inch, taperTop: S.sIITunnelTaper * inch,
                                       A.white)
        let feedFairings = S.sIIFeedFairingAzimuths.map { theta in
            upperStageFairing(skinDirection(theta), skin: r, from: D.station(D.sIIAftSkirt),
                              to: D.station(S.sIIFeedFairingTop), width: S.sIIFeedFairingWidth * inch,
                              depth: S.sIIFeedFairingDepth * inch, taperTop: S.sIIFeedFairingTaper * inch, A.white)
        }
        var antennas: [VisualShape] = []
        for k in 0..<4 {
            let direction = skinDirection(S.sIIAntennaAzimuth + 90 * Double(k))
            let command = S.sIICommandAntenna, telemetry = S.sIITelemetryAntenna
            antennas.append(upperStageBox(direction, skin: r, at: D.station(S.sIICommandAntennaStation),
                                          tall: command.tall * inch, wide: command.wide * inch,
                                          proud: command.proud * inch, A.white))
            antennas.append(upperStageBox(direction, skin: r, at: D.station(S.sIITelemetryAntennaStation),
                                          tall: telemetry.tall * inch, wide: telemetry.wide * inch,
                                          proud: telemetry.proud * inch, A.white))
        }
        return [skin, aftBulkhead, forwardBulkhead, cone, tunnel] + feedFairings + antennas
    }

    /// The heat shield, its aft face at S-II station 44, with a hole of 48
    /// in radius round each engine's axis, and a curtain round each hole:
    /// up its edge from the shield's forward face to S-II station 48, where
    /// D5 probes it, then sagging to its engine. The shield is eight plates,
    /// one per octant between a Position and a fin line, each with half an
    /// outboard hole and an eighth of the centre one cut out of it.
    func sIIBase() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, aft = D.station(S.sIIHeatShieldStation)
        let thickness = S.sIIHeatShieldThickness * inch, edge = S.sIIHeatShieldRadius * inch
        let hole = S.sIICurtainRadius * inch, outboard = D.sIIOutboardCircle / 2 * D.foot
        /// A point `r` out at `angle` (rad) in the shield's plane: a towards
        /// Position I, b towards Position II.
        func at(_ r: Double, _ angle: Double) -> VisualShape.SectionPoint { .init(r * cos(angle), r * sin(angle)) }
        let shield = (0..<8).map { k -> VisualShape in
            let a0 = Double.pi / 4 * Double(k), a1 = a0 + Double.pi / 4
            let engine = k % 2 == 0 ? a1 : a0, other = k % 2 == 0 ? a0 : a1
            let e = (cos(engine), sin(engine)), t = (-sin(engine), cos(engine))
            // Half the engine's hole, bulging into the octant, from its
            // outer edge to its inner one.
            let side = other > engine ? 1.0 : -1.0
            let halfHole = (0...8).map { j -> VisualShape.SectionPoint in
                let psi = Double.pi * Double(j) / 8, c = outboard + hole * cos(psi), s = side * hole * sin(psi)
                return .init(c * e.0 + s * t.0, c * e.1 + s * t.1, crease: j == 0 || j == 8)
            }
            let rim = (0...6).map { j in at(edge, other + (engine - other) * Double(j) / 6) }
            let centre = (0...4).map { j in at(hole, engine + (other - engine) * Double(j) / 4) }
            // Round the octant: out along the other line, the rim, in along
            // the engine's line round its hole, the centre hole's arc.
            var outline = rim
            outline += halfHole
            outline += centre
            for i in [0, rim.count - 1, rim.count + halfHole.count, outline.count - 1] { outline[i].crease = true }
            var s = finished(.plate(outline, at: local(Vec3(aft + thickness / 2, 0, 0)), axis: .unitZ,
                                    reference: -Vec3.unitY, thickness: thickness, color: A.heatShield.colour),
                             A.heatShield)
            s.surfaceFrame = .vehicle(partOrigin: construction)
            return s
        }
        let probes = D.station(S.sIICurtainStation), forwardFace = aft + thickness
        let curtains = part.thrusters.filter { $0.groups.contains(.main) }.map { t -> VisualShape in
            let exit = D.station(D.sIIJ2ExitStation), gimbal = t.position.x + construction.x
            let profile = ApolloDresser.j2Profile(exitRadius: (D.j2ExitArea / Double.pi).squareRoot(),
                                                  length: gimbal - exit)
            let sag = S.sIICurtainSag * inch
            let engine = ApolloDresser.outerRadius(of: profile, at: probes - sag - exit)
            let axis = t.position + construction
            var curtain = revolution([P(forwardFace - probes, hole, crease: true), P(0, hole, crease: true),
                                      P(-sag, engine + 0.5 * inch)],
                                     at: Vec3(probes, axis.y, axis.z), segments: 48, A.canvas)
            upperStageOpen(&curtain)
            return curtain
        }
        return shield + curtains
    }

    // MARK: J-2

    /// The part's J-2s, one per main-group thruster, from construction x
    /// `exit` to its gimbal: the engine's surface of revolution, linked to
    /// the thruster, and its two turbopumps, which are not (they keep still
    /// while the engine gimbals, at most 7°: 3-5 in at their places).
    func j2Engines(exit: Double) -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, exitRadius = (D.j2ExitArea / Double.pi).squareRoot()
        return part.thrusters.filter { $0.groups.contains(.main) }.flatMap { t -> [VisualShape] in
            let gimbal = t.position.x + construction.x
            var engine = finished(.revolution(A.j2Profile(exitRadius: exitRadius, length: gimbal - exit),
                                              from: Vec3(exit - construction.x, t.position.y, t.position.z),
                                              color: A.dark.colour), A.dark, vehicleFrame: false)
            engine.capBase = false
            engine.capTop = false
            engine.twoSided = true
            engine.thruster = t.name
            // Across the engine's radius from the vehicle's axis, or across
            // Positions II-IV on the axis.
            let radial = Vec3(0, t.position.y, t.position.z)
            let across = radial.length > 1e-9 ? Vec3.unitX.cross(radial.normalized) : Vec3(0, 1, 0)
            var pumps: [VisualShape] = []
            for (pump, side) in [(S.j2FuelPump, 1.0), (S.j2OxidizerPump, -1.0)] {
                let centre = t.position + across * (side * pump.offset * inch)
                pumps.append(finished(.frustum(from: centre - Vec3.unitX * ((pump.top + pump.length) * inch),
                                               length: pump.length * inch, baseRadius: pump.diameter / 2 * inch,
                                               topRadius: pump.diameter / 2 * inch, color: A.grey.colour),
                                      A.grey, vehicleFrame: false))
            }
            return [engine] + pumps
        }
    }

    /// A J-2 from its exit plane (x = 0) to the gimbal at `length` (m), one
    /// closed loop starting at the gas-side exit `re` (the first point, so
    /// the exit reads as a bell's): out over the exit ring to the 80.75 in
    /// envelope, up the tube wall over the fuel inlet and turbine exhaust
    /// manifolds and the chamber, over the dome and gimbal bearing to the
    /// axis, then down the injector face, the chamber and the bell's inside
    /// back to the exit. Its outside faces out on the wall and in on the
    /// bell.
    static func j2Profile(exitRadius re: Double, length: Double) -> [P] {
        let inch = AS506.inch, deg = Double.pi / 180
        let rt = AS506.j2ThroatDiameter / 2 * inch, rc = S.j2ChamberDiameter / 2 * inch
        let wall = S.j2TubeWall * inch, spread = re - rt
        let throat = S.bellFraction * spread / tan(S.bellConeHalfAngle * deg)
        let chamber = throat + (rc - rt) / tan(S.convergentHalfAngle * deg)
        let injector = S.j2ChamberBodyLength * inch
        /// The bell's gas-side radius at `x` from the exit, up to the throat.
        func bell(_ x: Double) -> Double {
            let t = 1 - x / throat
            return rt + spread * (1.6 * t - 0.6 * t * t)
        }
        func outer(_ x: Double) -> Double { bell(x) + wall }

        let envelope = S.j2EnvelopeDiameter / 2 * inch, ring = S.j2ExitRingHeight * inch
        var p = [P(0, re, crease: true), P(0, envelope, crease: true), P(ring, envelope, crease: true),
                 P(ring, outer(ring), crease: true)]
        /// A half-round band off the wall from `x0` to `x1`, cresting at
        /// `crest(x)` over the wall at `x`.
        func band(_ x0: Double, _ x1: Double, crest: (Double) -> Double) {
            p.append(P(x0, outer(x0), crease: true))
            for k in 1..<6 {
                let a = Double.pi * Double(k) / 6, x = x0 + (x1 - x0) * (1 - cos(a)) / 2
                p.append(P(x, outer(x) + (crest(x) - outer(x)) * sin(a)))
            }
            p.append(P(x1, outer(x1), crease: true))
        }
        let fuel = length - S.j2FuelManifoldStation * inch, half = 3.5 * inch
        let turbine = fuel + S.j2TurbineManifold.offset * inch, turbineHalf = 3 * inch
        for x in stride(from: ring + 6 * inch, to: fuel - half - 2 * inch, by: 8 * inch) { p.append(P(x, outer(x))) }
        band(fuel - half, fuel + half) { _ in S.j2FuelManifoldDiameter / 2 * inch }
        band(turbine - turbineHalf, turbine + turbineHalf) { x in outer(x) + S.j2TurbineManifold.proud * inch }
        for x in stride(from: turbine + turbineHalf + 6 * inch, to: throat - 2 * inch, by: 8 * inch) {
            p.append(P(x, outer(x)))
        }
        let bearing = S.j2GimbalBearing.diameter / 2 * inch, dome = length - S.j2GimbalBearing.height * inch
        p += [P(throat, rt + wall), P(chamber, rc + wall, crease: true), P(injector, rc + wall),
              P((injector + dome) / 2, (rc + wall + bearing) / 2 + inch), P(dome, bearing + inch, crease: true),
              P(dome, bearing, crease: true), P(length, bearing, crease: true), P(length, 0, crease: true),
              P(injector, 0, crease: true), P(injector, rc, crease: true), P(chamber, rc, crease: true)]
        for k in 0...16 {
            let t = Double(k) / 16
            p.append(P(throat * (1 - t), rt + spread * (1.6 * t - 0.6 * t * t)))
        }
        return p
    }

    /// The radius of a J-2 profile's outer wall at `x` from its exit: the
    /// largest radius at `x` on the loop up to its top.
    static func outerRadius(of profile: [P], at x: Double) -> Double {
        var r = 0.0
        for (a, b) in zip(profile, profile.dropFirst()) where (a.x - x) * (b.x - x) <= 0 && a.x != b.x {
            let f = (x - a.x) / (b.x - a.x)
            r = max(r, a.r + f * (b.r - a.r))
        }
        return r
    }

    // MARK: Helpers for the upper stages

    /// The unit (y, z) of azimuth `theta` (deg, from Position I towards II)
    /// in construction axes, exact on the Positions.
    func skinDirection(_ theta: Double) -> (y: Double, z: Double) {
        let a = theta * Double.pi / 180
        let y = -sin(a), z = cos(a)
        return (abs(y) < 1e-12 ? 0 : y, abs(z) < 1e-12 ? 0 : z)
    }

    /// Both ends open, both faces drawn.
    func upperStageOpen(_ s: inout VisualShape) {
        s.capBase = false
        s.capTop = false
        s.twoSided = true
    }

    /// A tank bulkhead's half-ellipsoid from its equator at construction x
    /// `equator`, of `radius`, to its pole `height` (m) along the axis
    /// (negative: an aft bulkhead), the outside away from the tank.
    func upperStageDome(equator: Double, radius: Double, height: Double) -> [P] {
        (0...12).map { k -> P in
            let a = Double.pi / 2 * Double(12 - k) / 12   // the pole first
            let x = equator + height * sin(a)
            return P(x, radius * cos(a))
        }.sorted { $0.x < $1.x }
    }

    /// A fairing, tunnel or panel on a skin of radius `skin` (m) at the unit
    /// direction `d` (y, z), from construction x `from` to `to`: `width`
    /// across, its face `depth` proud, shaped across by `face` (1 at the
    /// middle, from t = -1 to 1; a half-ellipse unless given) and following
    /// the skin's curve; its base 1 in under the skin. Each end tapers to a
    /// point on the skin over `taperBottom` and `taperTop` (m), as an ogive
    /// or, with `roundTop`, the top as a quarter ellipse; or is cut square.
    /// Measured in the vehicle's frame.
    func upperStageFairing(_ d: (y: Double, z: Double), skin: Double, from: Double, to: Double, width: Double,
                           depth: Double, taperBottom: Double = 0, taperTop: Double = 0, roundTop: Bool = false,
                           face: (Double) -> Double = { t in (1 - t * t).squareRoot() },
                           _ finish: Finish) -> VisualShape {
        let half = width / 2, bury = D.inch
        /// How far the skin falls away from its tangent `b` across.
        func sag(_ b: Double) -> Double { skin - (skin * skin - b * b).squareRoot() }
        var section: [VisualShape.SectionPoint] = []
        for k in 0...12 {
            let t = Double(k) / 6 - 1, b = t * half
            section.append(.init(depth * face(t) - sag(b), b, crease: k == 0 || k == 12))
        }
        let base = -bury - sag(half)
        section += [.init(base, half, crease: true), .init(base, -half, crease: true)]

        /// The section's scale `f` of the way from a tip to the full section:
        /// an ogive's, or a quarter ellipse's.
        func ogive(_ f: Double) -> Double { 1 - (1 - f) * (1 - f) }
        func round(_ f: Double) -> Double { (1 - (1 - f) * (1 - f)).squareRoot() }
        let length = to - from, steps = 6
        var stations: [VisualShape.PrismStation] = []
        if taperBottom > 0 {
            for k in 0..<steps {
                let f = Double(k) / Double(steps), s = ogive(f)
                stations.append(.init(taperBottom * f, width: s, height: s))
            }
        }
        stations += [.init(taperBottom), .init(length - taperTop)]
        if taperTop > 0 {
            for k in (0..<steps).reversed() {
                let f = Double(k) / Double(steps), s = roundTop ? round(f) : ogive(f)
                stations.append(.init(length - taperTop * f, width: s, height: s))
            }
        }
        let radial = Vec3(0, d.y, d.z)
        var s = finished(.prism(section, from: local(Vec3(from, 0, 0) + radial * skin), reference: radial,
                                stations: stations, color: finish.colour), finish)
        s.surfaceFrame = .vehicle(partOrigin: construction)
        return s
    }

    /// A box standing `proud` (m) off a skin of radius `skin` in the unit
    /// direction `d` (y, z), centred on construction x `at`: `tall` along
    /// the vehicle's axis, `wide` across, its foot 1/2 in under the skin.
    /// Measured in the vehicle's frame.
    func upperStageBox(_ d: (y: Double, z: Double), skin: Double, at x: Double, tall: Double, wide: Double,
                       proud: Double, _ finish: Finish) -> VisualShape {
        let radial = Vec3(0, d.y, d.z), bury = 0.5 * D.inch
        var s = finished(.box(from: local(Vec3(x, 0, 0) + radial * (skin - bury)), length: proud + bury,
                              width: tall, height: wide, axis: radial, reference: .unitX, color: finish.colour),
                         finish)
        s.surfaceFrame = .vehicle(partOrigin: construction)
        return s
    }
}

extension ApolloDresser {
    /// The S-II's fibreglass-honeycomb heat shield (no colour sourced).
    static let heatShield = Finish(colour: (0.55, 0.5, 0.42), material: .apolloSIIHeatShield)
}

extension MaterialKey {
    /// The S-II's base heat shield: fibreglass honeycomb (M503 p. 5-1).
    public static let apolloSIIHeatShield: MaterialKey = "apollo.sii.heatshield"
}

import XCTest
@testable import OrbitCore

/// The S-IC, the S-IC/S-II interstage and the F-1 as dressed, against
/// docs/SaturnV-CSM-exterior-datasheet.md §1-§3 and §8.1 (VD1). The
/// datasheet's values are written out here, not read from
/// `ApolloShapeData`, and most checks measure the tessellated shapes: the
/// silhouette at a station (`reach`) or the vertices themselves.
///
/// `reach` stands in for L0's silhouette helpers (Tests/OrbitSceneTests/
/// Support), which were not on main when this was written: swap it for
/// theirs when they land.
final class SICExteriorTests: XCTestCase {
    static let inch = 0.0254
    let inch = SICExteriorTests.inch
    /// The dressed AS-506 stack, built once for the class.
    static let stack = VesselLibrary.saturnV()
    /// Parts each F-1 is drawn in, all linked to its thruster: cocoon,
    /// turbopump, inlet block, gas generator, heat exchanger, manifold,
    /// extension and gas side.
    static let f1Parts = 8

    /// How far out (m) and how low (construction x, m) a shape of the part
    /// named `part` may reach on the stack: the fin tips (376.25 in, §2.4)
    /// and the F-1 exits (215.50 in below the gimbals at STA 100, §8.1) on
    /// the S-IC, the ullage fairings (22 in proud) on its interstage; nil
    /// for the other parts.
    static func envelope(_ part: String) -> (radius: Double, base: Double)? {
        switch part {
        case "S-IC": return (376.3 * inch, (100 - 215.5) * inch)
        case "S-IC/S-II interstage": return ((198 + 22) * inch, 1541 * inch)
        default: return nil
        }
    }

    // MARK: Helpers

    func part(_ name: String, of v: Vessel = SICExteriorTests.stack) -> VesselPart {
        v.parts.first { $0.name == name }!
    }

    /// The construction-frame triangles of the shapes of `p` that `include` picks.
    func triangles(_ p: VesselPart, of v: Vessel = SICExteriorTests.stack,
                   _ include: (VisualShape) -> Bool = { _ in true }) -> [VisualShape.Vertex] {
        let offset = p.offset - v.structureOrigin
        return p.shapes.filter(include).flatMap { $0.triangles(offset: offset) }
    }

    /// Construction unit vector at vehicle azimuth `deg`: Position I (+z)
    /// at 0, Position II (-y) at 90.
    func outward(_ deg: Double) -> Vec3 { Vec3(0, -sin(deg * Double.pi / 180), cos(deg * Double.pi / 180)) }

    /// Vehicle azimuth (deg) of the construction point `c`.
    func azimuth(_ c: Vec3) -> Double { VisualShape.vehicleAzimuth(y: c.y, z: c.z) * 180 / Double.pi }

    /// `a` - `b` (deg) within half a turn.
    func turn(_ a: Double, _ b: Double) -> Double { remainder(a - b, 360) }

    /// Where the triangles' edges cross the plane x = STA `sta` (construction,
    /// m); only the edges parallel to the vehicle's axis if `ribs`, which
    /// in a prism of constant section give its section's points.
    func crossings(_ t: [VisualShape.Vertex], at sta: Double, ribs: Bool = false) -> [Vec3] {
        let x = sta * inch
        var points: [Vec3] = []
        for i in stride(from: 0, to: t.count, by: 3) {
            for k in 0..<3 {
                let p = t[i + k].position, q = t[i + (k + 1) % 3].position
                let dp = p.x - x, dq = q.x - x
                guard dp * dq <= 0, !ribs || Vec3(0, q.y - p.y, q.z - p.z).length < 1e-12 else { continue }
                let f = dp == dq ? 0 : dp / (dp - dq)
                points.append(p + (q - p) * f)
            }
        }
        return points
    }

    /// The silhouette at STA `sta`: how far (in) the triangles reach along
    /// the unit `direction` across the axis in the plane x = STA; nil if
    /// none crosses it.
    func reach(_ t: [VisualShape.Vertex], at sta: Double, along direction: Vec3) -> Double? {
        crossings(t, at: sta).map { $0.dot(direction) / inch }.max()
    }

    /// The distance (in) of construction point `c` from the line parallel
    /// to the vehicle's axis through `axis`.
    func off(_ c: Vec3, from axis: Vec3) -> Double { Vec3(0, c.y - axis.y, c.z - axis.z).length / inch }

    /// `v` turned `angle` (deg) about the vehicle's axis, towards larger azimuth.
    func turned(_ v: Vec3, _ angle: Double) -> Vec3 {
        let c = cos(angle * Double.pi / 180), s = sin(angle * Double.pi / 180)
        return Vec3(v.x, v.y * c - v.z * s, v.z * c + v.y * s)
    }

    /// The ALM sheets' caliber (in).
    let cal = 396.0

    /// The datasheet's fairing (§2.3): its outer generatrix (in from the
    /// axis) at STA `sta`, a 15° cone of 0.2526 cal (100.0 in) at STA 48.5
    /// on an axis 0.4596 cal (182.0 in) out.
    func fairingGeneratrix(_ sta: Double) -> Double {
        (0.4596 + 0.2526) * cal - (sta - 48.5) * tan(15 * Double.pi / 180)
    }

    /// The fairing's cone's radius (in) about its own axis at STA `sta`.
    func fairingRadius(_ sta: Double) -> Double { fairingGeneratrix(sta) - 0.4596 * cal }

    /// The fins' tip (in from the axis): 0.2601 cal (103.0 in) of span out
    /// from the fairing at the trailing edge, STA 81.277 (§2.4: 376.2 in).
    var tipRadius: Double { fairingGeneratrix(81.277) + 0.2601 * cal }

    // MARK: Fins (§2.4)

    // Four fins on the diagonals: the tip's 55 in chord from STA 81.277 to
    // 136.277 at 376.2 in, 103.0 in of span at the trailing edge, the 30°
    // leading edge, 75.0 ft² outside the fairing, and the span tip to tip
    // M503's 63.0 ft (62.7 derived, ALM sheets).
    func testFinsOnTheDiagonals() {
        let sIC = part("S-IC")
        for fin in [45.0, 135.0, 225.0, 315.0] {
            // The structure out on this diagonal: the fin and its fairing.
            let d = outward(fin)
            let all = triangles(sIC) { $0.thruster == nil }
            let t = stride(from: 0, to: all.count, by: 3).filter { i in
                (0..<3).contains { all[i + $0].position.dot(d) > 200 * inch }
            }.flatMap { all[$0..<$0 + 3] }
            let tip = reach(t, at: 81.5, along: d)!
            XCTAssertEqual(tip, tipRadius, accuracy: 0.01, "fin at \(fin)")
            XCTAssertEqual(tip, 376.2, accuracy: 0.05)
            XCTAssertEqual(2 * tip / 12, 62.7, accuracy: 0.01)
            XCTAssertEqual((2 * tip / 12).rounded(), 63, "M503 Fig. 1-3: 63.0 ft")
            XCTAssertEqual(reach(t, at: 136.2, along: d)!, tip, accuracy: 0.01, "the tip chord")
            // The trailing edge's root on the fairing: 103.0 in of span.
            XCTAssertEqual(reach(t, at: 81.2, along: d)!, fairingGeneratrix(81.2), accuracy: 0.01)
            XCTAssertEqual(tip - fairingGeneratrix(81.277), 103.0, accuracy: 0.01)
            // The leading edge, 30° swept, to the root at STA 216.687.
            let leading = tipRadius - (180 - 136.277) / tan(30 * Double.pi / 180)
            XCTAssertEqual(reach(t, at: 180, along: d)!, leading, accuracy: 0.01)
            XCTAssertEqual(reach(t, at: 217, along: d)!, fairingGeneratrix(217), accuracy: 0.01)
            // The planform outside the fairing, by strips.
            var area = 0.0
            let steps = 200, from = 81.277, to = 216.687
            for k in 0..<steps {
                let sta = from + (to - from) * (Double(k) + 0.5) / Double(steps)
                area += (reach(t, at: sta, along: d)! - fairingGeneratrix(sta)) * (to - from) / Double(steps)
            }
            XCTAssertEqual(area / 144, 75.0, accuracy: 0.1, "ALM 1.9101: 75 ft²")
        }
    }

    // The section: 14.4 in thick at the root's trailing edge, 15.4 in at
    // the ramp's end (0.0388 cal), 4.0 in at the tip; flat over the aft
    // 34.7 in; a 10° wedge ahead of it at the root (10.3° on these
    // thicknesses and chords), sharp at the leading edge.
    func testFinSection() throws {
        let sIC = part("S-IC")
        let fin = outward(45), across = Vec3.unitX.cross(fin)
        let offset = sIC.offset - Self.stack.structureOrigin
        let shapes = sIC.shapes.filter { s in
            guard case .prism = s.kind, s.axis.dot(fin) > 0.999 else { return false }
            return true
        }
        XCTAssertEqual(shapes.count, 2, "the flat section and the ramp")
        let vertices = shapes.flatMap { $0.mesh(offset: offset).vertices }
        /// Half the thickness (in) at radius `r` (in) and STA `sta`, from
        /// the vertices on the fin's edges.
        func half(_ r: Double, _ sta: Double) -> Double {
            let near = vertices.filter { abs($0.position.x / inch - sta) < 0.01 }
            let rs = near.map { $0.position.dot(fin) / inch }
            let hs = near.map { abs($0.position.dot(across)) / inch }
            // The edge's two ends, from the root station to the tip.
            let root = rs.min()!, tip = rs.max()!
            let h0 = zip(rs, hs).filter { abs($0.0 - root) < 0.01 }.map(\.1).max()!
            let h1 = zip(rs, hs).filter { abs($0.0 - tip) < 0.01 }.map(\.1).max()!
            return h0 + (h1 - h0) * (r - root) / (tip - root)
        }
        XCTAssertEqual(2 * half(fairingGeneratrix(81.277), 81.277), 0.0364 * cal, accuracy: 0.01)
        XCTAssertEqual(2 * half(fairingGeneratrix(81.277 + 0.0877 * cal), 81.277 + 0.0877 * cal), 0.0388 * cal,
                       accuracy: 0.05, "the ramp's end")
        XCTAssertEqual(2 * half(tipRadius, 81.277), 0.0101 * cal, accuracy: 0.01)
        XCTAssertEqual(half(330, 81.277), half(330, 81.277 + 0.0877 * cal), accuracy: 1e-6, "the flat section")
        // The leading edge is sharp; the wedge at the exposed root, along
        // the chord from the ramp's end to the 30° leading edge.
        let ramp = 81.277 + 0.0877 * cal
        let leading = vertices.filter { $0.position.x / inch > ramp + 1 }
        XCTAssertEqual(leading.map { abs($0.position.dot(across)) }.max()!, 0, accuracy: 1e-9)
        let root = fairingGeneratrix(ramp)
        let chord = 136.277 + (tipRadius - root) * tan(30 * Double.pi / 180) - ramp
        XCTAssertEqual(2 * atan(half(root, ramp) / chord) * 180 / Double.pi, 10, accuracy: 0.5)
    }

    // Below the lunate panel (STA 112) the fairing is open round the engine,
    // so the fin's flat section starts on the fairing: its root runs half
    // an inch inside the generatrix from the trailing edge to the ramp's
    // end (STA 81.277 to 115.977), nothing of the fin inside the cone
    // deeper than that, and the root's corners, on the fin's faces, under
    // the cone (no slit).
    func testFinRootsOnTheFairings() {
        let sIC = part("S-IC"), offset = sIC.offset - Self.stack.structureOrigin
        for fin in [45.0, 135.0, 225.0, 315.0] {
            let d = outward(fin), axis = d * (182 * inch)
            let t = sIC.shapes.filter { s in
                guard case .prism = s.kind, s.axis.dot(d) > 0.999 else { return false }
                return true
            }.flatMap { $0.triangles(offset: offset) }
            for sta in stride(from: 81.3, through: 111.9, by: 0.5) {
                let points = crossings(t, at: sta)
                XCTAssertFalse(points.isEmpty, "fin at \(fin), STA \(sta)")
                let inside = points.map { fairingRadius(sta) - off($0, from: axis) }
                XCTAssertLessThanOrEqual(inside.max()!, 0.5 + 1e-6, "fin at \(fin), STA \(sta)")
                // The root's corners: the crossings nearest the vehicle's axis.
                let root = points.map { $0.dot(d) }.min()!
                let corners = points.filter { $0.dot(d) < root + 1e-9 }
                XCTAssertGreaterThanOrEqual(corners.count, 2)
                for c in corners { XCTAssertGreaterThan(fairingRadius(sta) - off(c, from: axis), 0, "STA \(sta)") }
            }
        }
    }

    // MARK: Engine fairings and retros (§2.3, §2.5)

    // Four half-cones on the diagonals: 100 in at STA 48.5 on an axis
    // 182 in out, 15°, meeting the 198 in skin at STA 362.1.
    func testEngineFairings() {
        let sIC = part("S-IC"), t = triangles(sIC)
        for fin in [45.0, 135.0, 225.0, 315.0] {
            let d = outward(fin)
            XCTAssertEqual(reach(t, at: 48.6, along: d)!, fairingGeneratrix(48.6), accuracy: 0.01)
            XCTAssertEqual(reach(t, at: 300, along: d)!, fairingGeneratrix(300), accuracy: 0.01)
            XCTAssertEqual(fairingGeneratrix(362.096), 198, accuracy: 0.01)
            XCTAssertEqual(reach(t, at: 362.0, along: d)!, 198, accuracy: 0.05)
            XCTAssertEqual(reach(t, at: 400, along: d)!, 198, accuracy: 1e-6, "the skin alone")
        }
        // Nothing hangs lower than the fairings' aft ends but the engines.
        let structure = triangles(sIC) { $0.thruster == nil && $0.material != .apolloSICCurtain }
        XCTAssertEqual(structure.map(\.position.x).min()! / inch, 48.5, accuracy: 0.1, "the flanks' half-thickness")
    }

    // Eight TE-M-424s in pairs in the fairings, one either side of each fin
    // (M503 p. 4-27); their exhaust breaks out through the fairing's skin
    // near its forward end, 7.5° off the axis: the ports are there, on each
    // motor's exhaust line at least half its 86 in ahead of its grain.
    func testRetroPorts() {
        let sIC = part("S-IC"), offset = sIC.offset - Self.stack.structureOrigin
        let ports = sIC.attachments.filter { $0.kind == .retroPort }
        XCTAssertEqual(ports.count, 8)
        for fin in [45.0, 135.0, 225.0, 315.0] {
            let sides = ports.map { turn(azimuth($0.position + offset), fin) }.filter { abs($0) < 10 }
            XCTAssertEqual(sides.filter { $0 < 0 }.count, 1, "fin at \(fin)")
            XCTAssertEqual(sides.filter { $0 > 0 }.count, 1, "fin at \(fin)")
        }
        for port in ports {
            let motor = sIC.thrusters.first { $0.name == port.thruster }!
            let c = port.position + offset, sta = c.x / inch
            let fin = (((azimuth(c) - 45) / 90).rounded() * 90 + 45)
            let axis = outward(fin) * (182 * inch)
            let off = Vec3(0, c.y - axis.y, c.z - axis.z).length / inch
            XCTAssertEqual(off, fairingGeneratrix(sta) - 182, accuracy: 0.01, "on the fairing's skin")
            XCTAssertGreaterThan(sta, 250)
            XCTAssertLessThan(sta, 362.096)
            let run = port.position - motor.position, along = run.dot(port.direction)
            XCTAssertEqual((run - port.direction * along).length, 0, accuracy: 1e-9, "on the exhaust line")
            XCTAssertGreaterThan(along / inch, 86.0 / 2)
            XCTAssertEqual((port.direction + motor.direction).length, 0, accuracy: 1e-12)
            XCTAssertEqual(acos(port.direction.x) * 180 / Double.pi, 7.5, accuracy: 1e-9)
            XCTAssertEqual(port.radius / inch, 15.25 / 2, accuracy: 1e-9)
        }
    }

    // MARK: Prisms on the skins

    // The prisms standing on the 198 in skin (the tunnels, the LOX vent
    // fairings, the ullage and ordnance fairings) sink their feet under it
    // along its arc: deeper than the 144-gon's facets fall inside its circle
    // (0.047 in), so no gap shows under a flank, and nowhere, ramps and
    // tapers included, deeper than the interstage's 0.071 in wall, so no
    // base shows inside it or inside the open forward skirt. The scoops do
    // the same on their fairing's cone, whose facets fall 0.027 in inside it.
    func testPrismsSinkIntoTheirSkin() {
        let sIC = part("S-IC"), interstage = part("S-IC/S-II interstage")
        func alongTheAxis(_ s: VisualShape) -> Bool {
            guard case .prism = s.kind, s.thruster == nil else { return false }   // not the F-1s' inlet blocks
            return abs(s.axis.x) > 1 - 1e-12
        }
        // Each with a station where its section is full.
        let skin = sIC.shapes.filter(alongTheAxis).map { (sIC, $0) }
            + interstage.shapes.filter(alongTheAxis).map { (interstage, $0) }
        XCTAssertEqual(skin.count, 2 + 2 + 4 + 2, "tunnels, vents, ullage and ordnance fairings")
        /// Planes (STA) across `t`: every quarter inch over its 40 in ends,
        /// where it ramps or tapers, every 10 in between.
        func planes(_ t: [VisualShape.Vertex]) -> [Double] {
            let x = t.map { $0.position.x / inch }, low = x.min()!, high = x.max()!
            return stride(from: low, through: high, by: 0.25).filter { $0 < low + 40 || $0 > high - 40 }
                + Array(stride(from: low + 40, to: high - 40, by: 10))
        }
        for (p, s) in skin {
            let t = s.triangles(offset: p.offset - Self.stack.structureOrigin)
            let low = t.map(\.position.x).min()! / inch, high = t.map(\.position.x).max()! / inch
            var deepest = 0.0
            for sta in planes(t) {
                for c in crossings(t, at: sta) { deepest = max(deepest, 198 - Vec3(0, c.y, c.z).length / inch) }
            }
            XCTAssertLessThan(deepest, 0.071 - 0.005, "\(p.name) from STA \(low)")
            // A third of the way up, where each is full: the section's base.
            let sta = low + (high - low) / 3
            let base = crossings(t, at: sta, ribs: true).map { 198 - Vec3(0, $0.y, $0.z).length / inch }.filter { $0 > 0 }
            XCTAssertGreaterThanOrEqual(base.count, 3, "\(p.name) at STA \(sta)")
            for b in base {
                XCTAssertGreaterThan(b, 0.047, "\(p.name) at STA \(sta)")
                XCTAssertLessThan(b, 0.071, "\(p.name) at STA \(sta)")
            }
        }

        let offset = sIC.offset - Self.stack.structureOrigin
        let scoops = sIC.shapes.filter { s in
            guard case .prism = s.kind else { return false }
            return abs(s.axis.x - cos(15 * Double.pi / 180)) < 1e-9
        }
        XCTAssertEqual(scoops.count, 16)
        for s in scoops {
            let t = s.triangles(offset: offset)
            let c = s.origin + offset, fin = ((azimuth(c) - 45) / 90).rounded() * 90 + 45
            let axis = outward(fin) * (182 * inch)
            var deepest = 0.0
            for sta in planes(t) {
                for c in crossings(t, at: sta) { deepest = max(deepest, fairingRadius(sta) - off(c, from: axis)) }
            }
            XCTAssertLessThan(deepest, 0.071 - 0.005)
            // The open forward end, full: the ring furthest along the scoop.
            let along = t.map { ($0.position - c).dot(s.axis) }, front = along.max()!
            let base = zip(t, along).filter { abs($0.1 - front) < 1e-9 }.map(\.0)
                .map { fairingRadius($0.position.x / inch) - off($0.position, from: axis) }.filter { $0 > 0 }
            XCTAssertGreaterThanOrEqual(base.count, 3)
            for b in base {
                XCTAssertGreaterThan(b, 0.027)
                XCTAssertLessThan(b, 0.071)
            }
        }
    }

    // MARK: Positions I-IV (§2.6, §2.7)

    // The hold-down fittings at Positions I-IV, bearing at STA 113.31; the
    // cable tunnel just off Position I towards fin A and the
    // pressurization tunnel just off III towards fin C, from the thrust
    // structure to the forward skirt, the latter's ramp at STA 1519 (D5);
    // engines 1-4 under fins A-D (`PositionConventionTests`).
    func testPositionConvention() {
        let sIC = part("S-IC"), offset = sIC.offset - Self.stack.structureOrigin
        let fittings = sIC.shapes.filter { s in
            guard case .box = s.kind, s.thruster == nil else { return false }
            return true
        }
        XCTAssertEqual(fittings.count, 4)
        for (fitting, position) in zip(fittings, [0.0, 90, 180, 270]) {
            XCTAssertEqual(turn(azimuth(fitting.origin + offset), position), 0, accuracy: 1e-9)
            let low = fitting.triangles(offset: offset).map(\.position.x).min()!
            XCTAssertEqual(low / inch, 113.31, accuracy: 1e-9)
        }
        let tunnels = sIC.shapes.filter { s in
            guard case .prism = s.kind else { return false }
            return s.length / inch > 1000
        }
        XCTAssertEqual(tunnels.count, 2)
        for (tunnel, (position, fin, forward)) in zip(tunnels, [(0.0, 45.0, 1515.0), (180, 225, 1519)]) {
            let off = turn(azimuth(tunnel.origin + offset), position)
            XCTAssertGreaterThan(off, 0)
            XCTAssertLessThan(off, 15, "just off the Position, towards fin at \(fin)")
            let x = tunnel.triangles(offset: offset).map(\.position.x)
            XCTAssertEqual(x.min()! / inch, 205, accuracy: 1e-9)
            XCTAssertEqual(x.max()! / inch, forward, accuracy: 1e-9)
            XCTAssertEqual(tunnel.material, .apolloWhitePaint)
        }
        for n in 1...4 {
            let nozzle = sIC.shapes.last { $0.thruster == "S-IC engine \(n)" }!
            XCTAssertEqual(turn(azimuth(nozzle.origin + offset), Double(2 * n - 1) * 45), 0, accuracy: 1e-9)
        }
    }

    // MARK: Base and skin (§2.1, §2.7)

    // The heat shield's 1 in honeycomb with its top at STA 112, reaching
    // into the fairings past D5's pressure ports at 260 in; one curtain an
    // engine below it; the skin's bands at BCD's joints, at 198 in; the
    // S-IC drawn 138 ft long from its F-1 exits.
    func testBaseAndSkin() {
        let sIC = part("S-IC"), offset = sIC.offset - Self.stack.structureOrigin
        let shield = triangles(sIC) { $0.material == .apolloSICHeatShield }
        XCTAssertEqual(shield.map(\.position.x).min()! / inch, 111, accuracy: 1e-9)
        let lunates = triangles(sIC) { s in
            guard case .plate = s.kind else { return false }
            return s.material == .apolloSICHeatShield
        }
        XCTAssertEqual(lunates.map(\.position.x).max()! / inch, 112, accuracy: 1e-9)
        for fin in [45.0, 135.0, 225.0, 315.0] {
            XCTAssertGreaterThan(reach(shield, at: 111.5, along: outward(fin))!, 260)
        }

        let curtains = sIC.shapes.filter { $0.material == .apolloSICCurtain }
        XCTAssertEqual(curtains.count, 5)
        XCTAssertTrue(curtains.allSatisfy { $0.thruster == nil && $0.twoSided })

        // The bands about the axis: their ends at BCD's joints.
        var joints = Set<Double>()
        for s in sIC.shapes {
            guard case let .revolution(profile, _, _) = s.kind, case .vehicle = s.surfaceFrame,
                  s.material == .apolloWhitePaint, profile.allSatisfy({ abs($0.r / inch - 198) < 1e-9 }) else { continue }
            for p in [profile.first!, profile.last!] {
                joints.insert(((p.x + s.origin.x + offset.x) / inch * 100).rounded() / 100)
            }
        }
        XCTAssertEqual(joints.sorted(), [116, 345.7, 628.8, 885.2, 1420.3, 1541, 1564])
        let x = triangles(sIC).map(\.position.x)
        XCTAssertEqual(x.min()! / inch, -115.5, accuracy: 1e-9)
        XCTAssertEqual(((1541 - x.min()! / inch) / 12 * 10).rounded() / 10, 138.0, "M503 Fig. 1-3")
    }

    // MARK: F-1 (§8.1)

    // Each F-1 in flight configuration, linked to its thruster: 215.50 in
    // from gimbal to exit; 139.95 in across the gas side there (16:1 on
    // R1's 961.4 in² throat), 147.00 in outside; 10:1 at the extension's
    // joint, 125.00 in outside, under the manifold's aft face at 150.00 in;
    // nothing ahead of 14.50 in, inside R1's upper block (51.62 in either
    // side, 75.75 in towards the turbopump, 39.00 in away) above 62.50 in;
    // and nothing in the nozzle but its gas side.
    func testF1FlightConfiguration() throws {
        let sIC = part("S-IC"), offset = sIC.offset - Self.stack.structureOrigin
        let engines = sIC.thrusters.filter { $0.groups.contains(.main) }
        XCTAssertEqual(engines.count, 5)
        let throat = (961.4 / Double.pi).squareRoot()
        XCTAssertEqual(2 * throat * 16.0.squareRoot(), 139.95, accuracy: 0.01)
        for e in engines {
            let linked = sIC.shapes.filter { $0.thruster == e.name }
            XCTAssertEqual(linked.count, Self.f1Parts, e.name)
            XCTAssertTrue(linked.allSatisfy { $0.surfaceFrame == .local }, e.name)
            // The renderer's nozzle: the last revolution linked (VesselGeometry.exit).
            let nozzle = try XCTUnwrap(linked.last { s in
                if case .revolution = s.kind { return true }
                if case .frustum = s.kind { return true }
                return false
            })
            guard case let .revolution(gas, _, _) = nozzle.kind else { return XCTFail(e.name) }
            XCTAssertEqual(nozzle.material, .apolloEngineBell)
            XCTAssertEqual(gas[0].x / inch, 215.5, accuracy: 1e-9)
            XCTAssertEqual(2 * gas[0].r / inch, 139.95, accuracy: 0.01)
            XCTAssertEqual(nozzle.axis, -Vec3.unitX)
            XCTAssertEqual((nozzle.origin - e.position).length, 0, accuracy: 1e-12)
            XCTAssertFalse(nozzle.capBase)
            let joint = try XCTUnwrap(gas.first { abs($0.x / inch - 150) < 1e-9 })
            XCTAssertEqual(joint.r / inch, throat * 10.0.squareRoot(), accuracy: 1e-9)
            XCTAssertEqual(2 * gas.map(\.r).filter { $0 > 0 }.min()! / inch, 34.99, accuracy: 0.01)
            /// The gas side's radius (in) at `x` in aft of the gimbal.
            func gasRadius(_ x: Double) -> Double {
                let p = gas.map { (x: $0.x / inch, r: $0.r / inch) }
                for (a, b) in zip(p, p.dropFirst()) where (a.x - x) * (b.x - x) <= 0 && a.x != b.x {
                    return a.r + (b.r - a.r) * (x - a.x) / (b.x - a.x)
                }
                return 0
            }

            let gimbal = e.position + offset
            let yz = Vec3(0, gimbal.y, gimbal.z)
            let pump = yz.length > 1e-6 ? yz.normalized : Vec3.unitZ, right = Vec3.unitX.cross(pump)
            var exitReach = 0.0, jointReach = 0.0, faceAft = -Double.infinity
            for s in linked {
                for v in s.triangles(offset: offset) {
                    let d = v.position - gimbal, aft = -d.x / inch
                    let radial = Vec3(0, d.y, d.z).length / inch
                    XCTAssertGreaterThanOrEqual(aft, -14.5 - 1e-9, e.name)
                    XCTAssertLessThanOrEqual(aft, 215.5 + 1e-9, e.name)
                    if aft < 62.5 {
                        let along = d.dot(pump) / inch, across = d.dot(right) / inch
                        XCTAssertLessThanOrEqual(abs(across), 51.62 + 1e-9, e.name)
                        XCTAssertLessThanOrEqual(along, 75.75 + 1e-9, e.name)
                        XCTAssertGreaterThanOrEqual(along, -39.0 - 1e-9, e.name)
                    } else {
                        XCTAssertLessThanOrEqual(radial, 147.0 / 2 + 1e-9, e.name)
                    }
                    if s.material != .apolloEngineBell && aft > 65.5 {
                        XCTAssertGreaterThan(radial + 1e-9, gasRadius(aft), "\(e.name): in the nozzle")
                    }
                    if abs(aft - 215.5) < 1e-9 { exitReach = max(exitReach, radial) }
                    if s.material == .apolloF1Extension && abs(aft - 150) < 1e-9 { jointReach = max(jointReach, radial) }
                    if case .torus = s.kind { faceAft = max(faceAft, aft) }
                }
            }
            XCTAssertEqual(2 * exitReach, 147.0, accuracy: 1e-9, e.name)
            XCTAssertEqual(2 * jointReach, 125.0, accuracy: 1e-9, e.name)
            XCTAssertEqual(faceAft, 150, accuracy: 1e-9, e.name)
            XCTAssertEqual(Set(linked.map(\.material)),
                           [.apolloF1Insulation, .apolloF1Extension, .apolloEngineBell], e.name)

            // The curtain round the upper block, from STA 96 to the shield's
            // face (111): no part of the engine crosses it, which leaves
            // more than an inch between them all round; on the outboard
            // engines it stays inside the fairing's cone.
            let curtain = try XCTUnwrap(sIC.shapes.first { s in
                s.material == .apolloSICCurtain && off(s.origin + offset, from: gimbal) < 1e-9
            }, e.name)
            let sleeve = curtain.triangles(offset: offset), engine = linked.flatMap { $0.triangles(offset: offset) }
            let height = sleeve.map { $0.position.x / inch }
            XCTAssertEqual(height.min()!, 96, accuracy: 1e-9)
            XCTAssertEqual(height.max()!, 111, accuracy: 1e-9)
            for sta in stride(from: 96.0, through: 111.0, by: 0.5) {
                let inner = crossings(sleeve, at: sta).map { off($0, from: gimbal) }.min()!
                let block = crossings(engine, at: sta).map { off($0, from: gimbal) }.max()!
                XCTAssertLessThan(block, inner - 1, "\(e.name) at STA \(sta)")
                if yz.length > 1e-6 {
                    let outer = crossings(sleeve, at: sta).map { off($0, from: gimbal) }.max()!
                    XCTAssertLessThan(outer, fairingRadius(sta) - 1, "\(e.name) at STA \(sta)")
                }
            }
        }
        // All five exits in one plane, 215.50 in below the gimbal plane.
        let exits = engines.map { e in sIC.shapes.last { $0.thruster == e.name }!.origin.x + offset.x - 215.5 * inch }
        for x in exits { XCTAssertEqual(x / inch, 100 - 215.5, accuracy: 1e-9) }
    }

    // MARK: S-IC/S-II interstage (§3)

    // The interstage from the separation plane (STA 1564) to 1760, the
    // 23 in ring below the plane drawn on the S-IC, which it leaves with;
    // both in zinc-chromate primer inside, facing in; the separation
    // ridges; the two ordnance fairings at θ 55° and 235° over STA 1568.
    func testInterstage() {
        let sIC = part("S-IC"), interstage = part("S-IC/S-II interstage")
        let x = triangles(interstage) { s in
            if case .revolution = s.kind { return true }
            return false
        }.map(\.position.x)
        XCTAssertEqual(x.min()! / inch, 1564, accuracy: 1e-9)
        XCTAssertEqual(x.max()! / inch, 1760, accuracy: 1e-9)
        for p in [sIC, interstage] {
            let primer = triangles(p) { $0.material == .apolloInterstagePrimer }
            XCTAssertFalse(primer.isEmpty, p.name)
            let wall = primer.filter { abs($0.normal.x) < 1e-9 }
            XCTAssertFalse(wall.isEmpty)
            for v in wall {
                XCTAssertLessThan(v.normal.dot(Vec3(0, v.position.y, v.position.z)), 0, "facing in")
                XCTAssertEqual(Vec3(0, v.position.y, v.position.z).length / inch, 198 - 0.071, accuracy: 1e-9)
            }
        }
        let ring = triangles(sIC) { $0.material == .apolloInterstagePrimer }.map(\.position.x)
        XCTAssertEqual(ring.min()! / inch, 1541, accuracy: 1e-9)
        XCTAssertEqual(ring.max()! / inch, 1564, accuracy: 1e-9)
        // Ridges 1 in proud at both planes, 4 in wide across the first.
        let all = triangles(sIC) + triangles(interstage)
        XCTAssertEqual(reach(all, at: 1563, along: outward(20))!, 199, accuracy: 1e-6)
        XCTAssertEqual(reach(all, at: 1565, along: outward(20))!, 199, accuracy: 1e-6)
        XCTAssertEqual(reach(all, at: 1759, along: outward(20))!, 199, accuracy: 1e-6)
        XCTAssertEqual(reach(all, at: 1600, along: outward(20))!, 198, accuracy: 1e-6)
        let ordnance = triangles(interstage) { s in
            guard case .prism = s.kind else { return false }
            return s.length / inch < 50
        }
        for theta in [55.0, 235.0] {
            XCTAssertGreaterThan(reach(ordnance, at: 1568, along: outward(theta))!, 200)
        }
    }

    // The S-II ullage motors' fairings: four on AS-503 and AS-506 (M503
    // Fig. 1-3; MSFC-MAN-506), eight on AS-501 (D5 §6.2.2); each from STA
    // 1563.56 (BCD) to a point at 1710.68 (BCD's XB 146.68, its truncated
    // 3.725 m), 24 in across and 22 in proud, 4.0° anticlockwise of fins
    // A-D, where the AS-503 photos show them (VD2's rows 503-050 to 053),
    // round an 89 × 12.5 in motor at the physics' radius. The motors stay
    // where the physics has them, at Positions I-IV, STA 1608 (§17). Each
    // exit sits on its fairing's foot, inside its section, on its motor's
    // exhaust line turned about the vehicle's axis to the fairing, 10° out.
    func testUllageFairings() throws {
        func fairings(_ v: Vessel) -> [VisualShape] {
            part("S-IC/S-II interstage", of: v).shapes.filter { s in
                guard case .prism = s.kind else { return false }
                return s.length / inch > 100
            }
        }
        XCTAssertEqual(fairings(Self.stack).count, 4)
        for (vehicle, count) in [(ApolloVariant.LaunchVehicle.as501, 8), (.as502, 4), (.as503, 4)] {
            let v = VesselLibrary.saturnV()
            for p in v.parts { p.appearance = ApolloVariant(launchVehicle: vehicle, csm: .csm103, payload: .ltaB) }
            VesselLibrary.dressApollo(v)
            XCTAssertEqual(fairings(v).count, count, vehicle.rawValue)
        }

        let interstage = part("S-IC/S-II interstage"), offset = interstage.offset - Self.stack.structureOrigin
        let motors = interstage.thrusters.filter(\.isSolid)
        XCTAssertEqual(motors.map(\.name), (1...4).map { "S-II ullage motor \($0)" })
        for (n, motor) in motors.enumerated() {
            let m = motor.position + offset
            XCTAssertEqual(turn(azimuth(m), Double(n) * 90), 0, accuracy: 1e-9, motor.name)
            XCTAssertEqual(Vec3(0, m.y, m.z).length, 5.24, accuracy: 1e-12, motor.name)
            XCTAssertEqual(m.x / inch, 1608, accuracy: 1e-9, motor.name)
        }
        let exits = interstage.attachments.filter { $0.kind == .ullageExit }
        XCTAssertEqual(exits.compactMap(\.thruster), motors.map(\.name))
        for (n, (fairing, exit)) in zip(fairings(Self.stack), exits).enumerated() {
            let theta = 45 + 90 * Double(n) + 4.0, d = outward(theta), across = Vec3.unitX.cross(d)
            let t = fairing.triangles(offset: offset), x = t.map(\.position.x)
            XCTAssertEqual(x.min()! / inch, 1563.56, accuracy: 1e-9)
            XCTAssertEqual(x.max()! / inch, 1710.68, accuracy: 1e-9)
            XCTAssertEqual(turn(azimuth(fairing.origin + offset), theta), 0, accuracy: 1e-9)
            XCTAssertEqual(reach(t, at: 1600, along: d)!, 198 + 22, accuracy: 1e-6)
            let side = crossings(t, at: 1600).map { $0.dot(across) / inch }
            XCTAssertEqual(side.max()! - side.min()!, 24, accuracy: 1e-6)
            XCTAssertEqual(side.max()! + side.min()!, 0, accuracy: 1e-6)
            // The motor's case, parallel to the axis, from the plane up 89 in.
            let motor = try XCTUnwrap(interstage.thrusters.first { $0.name == exit.thruster })
            let m = motor.position + offset
            let caseOut = Vec3(0, m.y, m.z).length / inch + 12.5 / 2
            for sta: Double in [1566, 1610, 1564 + 89] {
                XCTAssertGreaterThan(reach(t, at: sta, along: d)!, caseOut + 1, "STA \(sta)")
            }

            // The exit on the fairing's foot, inside its section.
            let c = exit.position + offset
            XCTAssertEqual(c.x / inch, 1563.56, accuracy: 1e-9)
            XCTAssertEqual(c.dot(across), 0, accuracy: 1e-12)
            let foot = crossings(t, at: 1563.56).map { $0.dot(d) / inch }
            XCTAssertGreaterThan(c.dot(d) / inch - exit.radius / inch, foot.min()!)
            XCTAssertLessThan(c.dot(d) / inch + exit.radius / inch, foot.max()!)
            XCTAssertLessThan(exit.radius / inch, 24.0 / 2)
            // On the motor's exhaust line, turned to the fairing.
            let phi = theta - azimuth(m)
            let start = turned(m, phi), exhaust = turned(-motor.direction, phi)
            let run = c - start
            XCTAssertEqual((run - exhaust * run.dot(exhaust)).length, 0, accuracy: 1e-9)
            XCTAssertGreaterThan(run.dot(exhaust), 0)
            XCTAssertEqual((exit.direction - exhaust).length, 0, accuracy: 1e-12)
            XCTAssertEqual(acos(-exit.direction.x) * 180 / Double.pi, 10, accuracy: 1e-9)
            XCTAssertGreaterThan(exit.direction.dot(d), 0, "canted out")
        }
    }

    // MARK: Separations

    // The S-IC leaves with its ring, fairings and engines where they were
    // drawn on the stack, dressed again or not; the interstage keeps its
    // shapes on the S-II until it goes.
    func testSeparationsKeepTheShapes() throws {
        let v = VesselLibrary.saturnV()
        let sIC = part("S-IC", of: v), interstage = part("S-IC/S-II interstage", of: v)
        let before = triangles(sIC, of: v).map(\.position), above = triangles(interstage, of: v).map(\.position)
        let spent = try XCTUnwrap(v.jettison(event: 1))
        for redress in [false, true] {
            if redress { VesselLibrary.dressApollo(spent) }
            let after = triangles(sIC, of: spent).map(\.position)
            XCTAssertEqual(before.count, after.count)
            XCTAssertEqual(zip(before, after).map { ($0 - $1).length }.max()!, 0, accuracy: 1e-9)
        }
        VesselLibrary.dressApollo(v)
        let kept = triangles(interstage, of: v).map(\.position)
        XCTAssertEqual(zip(above, kept).map { ($0 - $1).length }.max()!, 0, accuracy: 1e-9)
        XCTAssertEqual(kept.map(\.x).min()! / inch, 1563.56, accuracy: 1e-9, "the ullage fairings' feet")
    }

    // The S-IC's other attachments: its LOX vents and the LOX tank's frost
    // band, STA 885.2 to 1420.3 at 198 in (BCD).
    func testVentsAndFrost() {
        let sIC = part("S-IC"), offset = sIC.offset - Self.stack.structureOrigin
        let frost = sIC.attachments.filter { $0.kind == .frostZone }
        XCTAssertEqual(frost.count, 1)
        XCTAssertEqual((frost[0].position.x + offset.x) / inch, 885.2, accuracy: 1e-9)
        XCTAssertEqual(frost[0].length / inch, 1420.3 - 885.2, accuracy: 1e-9)
        XCTAssertEqual(frost[0].radius / inch, 198, accuracy: 1e-9)
        XCTAssertEqual(frost[0].direction, .unitX)
        let vents = sIC.attachments.filter { $0.kind == .vent }
        XCTAssertEqual(vents.count, 2)
        for vent in vents {
            XCTAssertLessThan(vent.direction.x, 0, "blowing aft")
            XCTAssertGreaterThan((vent.position.x + offset.x) / inch, 1420.3, "on the forward skirt")
        }
    }
}

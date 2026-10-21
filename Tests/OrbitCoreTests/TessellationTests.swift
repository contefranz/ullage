import XCTest
@testable import OrbitCore

/// `VisualShape.mesh` for every kind and every dressed part: closed shapes
/// are watertight and enclose their volume, triangles wind counter-clockwise
/// from outside, normals and tangents are orthonormal, (u, v) are
/// continuous but for the seams, and the tangent frame follows the surface
/// coordinates.
final class TessellationTests: XCTestCase {
    typealias P = VisualShape.ProfilePoint
    typealias Q = VisualShape.SectionPoint
    let white = (1.0, 1.0, 1.0)

    /// One shape of each new kind, and the old ones, off the axes.
    func catalogue() -> [(String, VisualShape)] {
        let origin = Vec3(1, 2, 3), axis = Vec3(0.2, 1, 1)
        let tunnel = [Q(0.3, 0, crease: true)] + (1..<8).map { k -> Q in
            let t = Double.pi * Double(k) / 8
            return Q(0.3 * cos(t), 0.3 * sin(t))
        } + [Q(-0.3, 0, crease: true)]
        let fin = [Q(0, 0.5, crease: true), Q(3, 0.5, crease: true), Q(2, 2, crease: true), Q(0.5, 2, crease: true)]
        let ell = [Q(0, 0.5), Q(2, 0.5), Q(2, 1), Q(0.5, 1), Q(0.5, 2.5), Q(0, 2.5)].map { Q($0.a, $0.b, crease: true) }
        var faceted = VisualShape.revolution([P(0, 1), P(1, 1)], from: origin, axis: axis, segments: 8,
                                             sweep: Double.pi / 8...(Double.pi / 8 + 2 * Double.pi), color: white)
        faceted.faceted = true
        return [
            ("frustum", .frustum(from: origin, length: 2, baseRadius: 1, topRadius: 0.5, axis: axis, color: white)),
            ("sphere", VisualShape(kind: .sphere(radius: 0.7), origin: origin, axis: axis, length: 1.4, color: white)),
            ("revolution", .revolution([P(0, 0), P(0.5, 1), P(1.5, 1, crease: true), P(2, 0.3), P(2.2, 0)],
                                       from: origin, axis: axis, segments: 24, color: white)),
            ("faceted revolution", faceted),
            ("box", .box(from: origin, length: 2, width: 1, height: 0.5, axis: axis, color: white)),
            ("tunnel prism", .prism(tunnel, from: origin, length: 4, axis: axis, color: white)),
            ("tapered prism", .prism(tunnel, from: origin, axis: axis,
                                     stations: [.init(0, width: 0, height: 0), .init(0.5), .init(3.5),
                                                .init(4, width: 0.5, height: 0.5)], color: white)),
            ("reversed prism", .prism(tunnel.reversed(), from: origin, axis: axis,
                                      stations: [.init(4), .init(0)], color: white)),
            ("fin plate", .plate(fin, at: origin, axis: axis, thickness: 0.1, bevel: 0.02, color: white)),
            ("L plate", .plate(ell, at: origin, axis: axis, thickness: 0.1, color: white)),
            ("torus", .torus(centre: origin, axis: axis, majorRadius: 1, minorRadius: 0.2, color: white)),
        ]
    }

    /// Every shape of every dressed vehicle, with its part's construction offset.
    func dressed() -> [(String, VisualShape, Vec3)] {
        let stack = VesselLibrary.saturnV()
        var vessels = [stack, VesselLibrary.apolloCSM(.apollo7)]
        for e in [1, 2, 3, 4, 6, 30] { vessels += stack.jettisonAll(event: e) }
        for v in vessels { VesselLibrary.dressApollo(v) }
        return vessels.flatMap { v in
            v.parts.flatMap { p in
                p.shapes.enumerated().map { ("\(p.name) shape \($0.offset)", $0.element, p.offset - v.structureOrigin) }
            }
        }
    }

    /// Closed: drawn one-sided with both ends shut.
    func isClosed(_ s: VisualShape) -> Bool {
        guard !s.twoSided, s.capBase, s.capTop else { return false }
        if case let .revolution(_, _, sweep) = s.kind { return sweep.upperBound - sweep.lowerBound >= 2 * Double.pi - 1e-9 }
        return true
    }

    /// A surface of revolution's azimuth step: v changes by no more within
    /// a triangle, but for a seam; nil for the other kinds.
    func columnWidth(_ s: VisualShape) -> Double? {
        switch s.kind {
        case .frustum: return 2 * Double.pi / 32
        case .sphere: return 2 * Double.pi / 24
        case let .torus(_, _, segments, _): return 2 * Double.pi / Double(segments)
        case let .revolution(_, segments, sweep):
            let width = sweep.upperBound - sweep.lowerBound
            return width / (Double(segments) * width / (2 * Double.pi) - 1e-9).rounded(.up)
        case .prism, .box, .plate: return nil
        }
    }

    /// Whether an edge of the triangle passes the shape's own axis, where
    /// its azimuth turns half round (a tunnel's base).
    func crossesAxis(_ t: ArraySlice<VisualShape.Vertex>, of s: VisualShape) -> Bool {
        let side = s.axis.cross(s.reference)
        let p = t.map { v -> (Double, Double) in
            let d = v.position - s.origin
            return (d.dot(s.reference), d.dot(side))
        }
        for k in 0..<3 {
            let a = p[k], b = p[(k + 1) % 3], ea = b.0 - a.0, eb = b.1 - a.1, l2 = ea * ea + eb * eb
            let f = l2 > 0 ? max(0, min(1, -(a.0 * ea + a.1 * eb) / l2)) : 0
            let x = a.0 + f * ea, y = a.1 + f * eb
            if (x * x + y * y).squareRoot() < 1e-6 { return true }
        }
        return false
    }

    /// Gradient in the triangle's plane of the values `f` at its corners.
    func gradient(_ t: ArraySlice<VisualShape.Vertex>, _ f: (VisualShape.Vertex) -> Double) -> Vec3 {
        let p = t.map(\.position), e1 = p[1] - p[0], e2 = p[2] - p[0], n = e1.cross(e2)
        let v = t.map(f)
        return (e2.cross(n) * (v[1] - v[0]) + n.cross(e1) * (v[2] - v[0])) / n.lengthSquared
    }

    // Each triangle's corners are counter-clockwise seen from where their
    // normals point, every normal and tangent is a unit vector, the two
    // perpendicular, the sign ±1; no triangle straddles a seam of v; the
    // indexed mesh is the triangle list.
    func testFramesAndWinding() {
        for (name, s, offset) in catalogue().map({ ($0.0, $0.1, Vec3.zero) }) + dressed() {
            let m = s.mesh(offset: offset)
            XCTAssertEqual(m.indices.count % 3, 0, name)
            XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.vertices.count }, name)
            XCTAssertEqual(m.triangles, s.triangles(offset: offset), name)
            for v in m.vertices {
                XCTAssertEqual(v.normal.length, 1, accuracy: 1e-9, name)
                XCTAssertEqual(v.tangent.length, 1, accuracy: 1e-9, name)
                XCTAssertEqual(v.normal.dot(v.tangent), 0, accuracy: 1e-9, name)
                XCTAssertEqual(abs(v.tangentSign), 1, name)
            }
            let t = m.triangles
            for i in stride(from: 0, to: t.count, by: 3) {
                // A sphere's pole is a ring of 1e-16 m: its triangles have no area.
                let face = (t[i + 1].position - t[i].position).cross(t[i + 2].position - t[i].position)
                guard face.length > 1e-12 else { continue }
                for k in i..<i + 3 { XCTAssertGreaterThan(face.dot(t[k].normal), 0, name) }
                let vs = t[i..<i + 3].map(\.surface.v)
                if let column = columnWidth(s) {
                    XCTAssertLessThanOrEqual(vs.max()! - vs.min()!, column + 1e-9, name)
                } else if !crossesAxis(t[i..<i + 3], of: s) {
                    XCTAssertLessThan(vs.max()! - vs.min()!, Double.pi, name)
                }
            }
        }
    }

    // Closed shapes are watertight: every edge is shared by two triangles,
    // once each way (seams, creases and caps duplicate vertices, not
    // positions); and they enclose a positive volume, the solid's for the
    // exact ones.
    func testClosedShapesAreWatertight() {
        func key(_ p: Vec3) -> [Int64] { [p.x, p.y, p.z].map { Int64(($0 * 1e7).rounded()) } }
        for (name, s, offset) in catalogue().map({ ($0.0, $0.1, Vec3.zero) }) + dressed() where isClosed(s) {
            let t = s.triangles(offset: offset)
            var edges: [[Int64]: Int] = [:]
            for i in stride(from: 0, to: t.count, by: 3) {
                let face = (t[i + 1].position - t[i].position).cross(t[i + 2].position - t[i].position)
                guard face.length > 1e-12 else { continue }
                for k in 0..<3 {
                    edges[key(t[i + k].position) + key(t[i + (k + 1) % 3].position), default: 0] += 1
                }
            }
            for (edge, n) in edges {
                let reverse = Array(edge[3...] + edge[..<3])
                XCTAssertEqual(n, 1, "\(name): an edge used twice the same way")
                XCTAssertEqual(edges[reverse], 1, "\(name): an open edge")
            }
            XCTAssertGreaterThan(volume(t), 0, name)
        }
        let shapes = Dictionary(uniqueKeysWithValues: catalogue())
        XCTAssertEqual(volume(shapes["box"]!.triangles()), 2 * 1 * 0.5, accuracy: 1e-12)
        // The tunnel's half 16-gon, 4 m long.
        let wedge: Double = 0.5 * 0.3 * 0.3 * sin(Double.pi / 8)
        let half: Double = 8 * wedge
        XCTAssertEqual(volume(shapes["tunnel prism"]!.triangles()), 4 * half, accuracy: 1e-12)
        XCTAssertEqual(volume(shapes["reversed prism"]!.triangles()), 4 * half, accuracy: 1e-12)
        // The L's area times its thickness.
        let ell: Double = 1 + 0.75
        XCTAssertEqual(volume(shapes["L plate"]!.triangles()), ell * 0.1, accuracy: 1e-12)
        // Pappus: the minor 16-gon's area turned round its centroid's circle,
        // on the major 48-gon's mean radius.
        let minorWedge: Double = 0.5 * 0.04 * sin(Double.pi / 8)
        let section: Double = 16 * minorWedge
        XCTAssertEqual(volume(shapes["torus"]!.triangles()) / (2 * Double.pi * section), 1, accuracy: 0.01)
    }

    // The caps go with the stations as given, whichever way they run along
    // the axis, as a revolution's go with its profile's ends: without its
    // top, a prism built from x = 4 down to 0 is open at x = 0 and closed at
    // x = 4, facing +axis; built upwards, the other way round.
    func testPrismCapsFollowTheStations() {
        let section = [Q(-0.5, -0.5), Q(0.5, -0.5), Q(0.5, 0.5), Q(-0.5, 0.5)]
        for (stations, closedAt) in [([4.0, 0.0], 4.0), ([0.0, 4.0], 0.0)] {
            var s = VisualShape.prism(section, from: .zero, axis: .unitX,
                                      stations: stations.map { VisualShape.PrismStation($0) }, color: white)
            s.capTop = false
            let ends = s.mesh().vertices.filter { abs(abs($0.normal.x) - 1) < 1e-12 }
            XCTAssertFalse(ends.isEmpty, "\(stations)")
            for v in ends {
                XCTAssertEqual(v.position.x, closedAt, "\(stations)")
                XCTAssertEqual(v.normal.x, closedAt == 4 ? 1 : -1, "\(stations)")
            }
            s.capTop = true
            s.capBase = false
            XCTAssertTrue(s.mesh().vertices.filter { abs(abs($0.normal.x) - 1) < 1e-12 }
                .allSatisfy { $0.position.x == 4 - closedAt }, "\(stations)")
        }
    }

    /// Signed volume enclosed by triangles (divergence theorem).
    func volume(_ t: [VisualShape.Vertex]) -> Double {
        stride(from: 0, to: t.count, by: 3).reduce(0) {
            $0 + t[$1].position.dot(t[$1 + 1].position.cross(t[$1 + 2].position)) / 6
        }
    }

    // On surfaces of revolution the tangent runs with v and the bitangent
    // with s; on prisms, boxes and plates the tangent runs with s round the
    // section and the bitangent along the sweep, +axis for a prism.
    func testTangentFrameFollowsTheCoordinates() {
        for (name, s) in catalogue() {
            let t = s.triangles()
            let lathe: Bool
            switch s.kind {
            case .frustum, .sphere, .revolution, .torus: lathe = true
            case .prism, .box, .plate: lathe = false
            }
            for i in stride(from: 0, to: t.count, by: 3) {
                let tri = t[i..<i + 3]
                let face = (t[i + 1].position - t[i].position).cross(t[i + 2].position - t[i].position)
                guard face.length > 1e-12 else { continue }
                let gv = gradient(tri, \.surface.v), gs = gradient(tri, \.surface.s), gu = gradient(tri, \.surface.u)
                let side = tri.allSatisfy { abs($0.normal.dot(s.axis)) < 0.999 }
                for v in tri {
                    let b = v.normal.cross(v.tangent) * v.tangentSign
                    if lathe {
                        if gv.length > 1e-6 && !s.faceted { XCTAssertGreaterThan(v.tangent.dot(gv), 0, name) }
                        if gs.length > 1e-6 && side && !s.faceted { XCTAssertGreaterThan(b.dot(gs), 0, name) }
                    } else if case .plate = s.kind {
                        continue
                    } else if side, gs.length > 1e-6, gu.length > 1e-6 {
                        XCTAssertGreaterThan(v.tangent.dot(gs), 0, name)
                        XCTAssertGreaterThan(b.dot(gu), 0, name)
                    }
                }
            }
        }
    }

    // Surface coordinates: about the shape's own axis in its local frame, u
    // along it from the origin, r from it, v its azimuth from `reference`;
    // s along the profile, on over the caps. In the vehicle's frame, u is
    // construction x, r and v about the vehicle's axis.
    func testSurfaceCoordinates() {
        func wrapped(_ a: Double) -> Double { remainder(a, 2 * Double.pi) }
        let frustum = catalogue()[0].1
        for v in frustum.mesh().vertices {
            let d = v.position - frustum.origin, u = d.dot(frustum.axis), radial = d - frustum.axis * u
            XCTAssertEqual(v.surface.u, u, accuracy: 1e-12)
            XCTAssertEqual(v.surface.r, radial.length, accuracy: 1e-12)
            if radial.length > 1e-9 {
                let a = atan2(radial.dot(frustum.axis.cross(frustum.reference)), radial.dot(frustum.reference))
                XCTAssertEqual(wrapped(v.surface.v - a), 0, accuracy: 1e-12)
            }
        }
        // s: 0 round the base, the slant length round the top; the caps'
        // centres at -r0 and slant + r1.
        let slant: Double = 4.25.squareRoot()
        let byS = Set(frustum.mesh().vertices.map { ($0.surface.s * 1e9).rounded() })
        let ends: [Double] = [0, slant, -1, slant + 0.5]
        XCTAssertEqual(byS, Set(ends.map { ($0 * 1e9).rounded() }))

        for (name, s, offset) in dressed() {
            guard case let .vehicle(o) = s.surfaceFrame else { continue }
            XCTAssertEqual(o, offset, name)
            for v in s.mesh().vertices {
                let c = v.position + o, r = (c.y * c.y + c.z * c.z).squareRoot()
                XCTAssertEqual(v.surface.u, c.x, accuracy: 1e-9, name)
                XCTAssertEqual(v.surface.r, r, accuracy: 1e-9, name)
                if r > 1e-6 { XCTAssertEqual(wrapped(v.surface.v - atan2(-c.y, c.z)), 0, accuracy: 1e-9, name) }
            }
        }
    }

    // The dresser gives every shape a material, and measures the shapes
    // about the vehicle's axis in its frame; engines and nozzles keep their
    // own. The indexed mesh shares the vertices of smooth surfaces.
    func testDressedMaterialsAndFrames() {
        var vehicleFrame = 0
        for (name, s, _) in dressed() {
            XCTAssertNotEqual(s.material, .unspecified, name)
            if s.thruster != nil { XCTAssertEqual(s.surfaceFrame, .local, name) }
            if case .vehicle = s.surfaceFrame { vehicleFrame += 1 }
        }
        XCTAssertGreaterThan(vehicleFrame, 20)
        let sphere = catalogue()[1].1.mesh()
        XCTAssertLessThan(sphere.vertices.count, sphere.indices.count / 2)
    }
}

import XCTest
@testable import OrbitCore

/// The cube sphere's mapping and its tile addressing (M1.6 Earth and Moon
/// design §3): round trips, the tangent warp's distortion, and neighbours
/// across face edges and at the cube's corners.
final class CubeSphereTests: XCTestCase {
    let deg = Double.pi / 180

    /// Directions spread over the sphere, the axes and the cube's edges and
    /// corners among them.
    func sampleDirections() -> [Vec3] {
        var out: [Vec3] = []
        for i in 0 ..< 400 {
            // A Fibonacci spiral, evenly spread.
            let z = 1 - (Double(i) + 0.5) / 200, r = (1 - z * z).squareRoot()
            let phi = Double(i) * 2.399963229728653
            out.append(Vec3(r * cos(phi), r * sin(phi), z))
        }
        for x in [-1.0, 0, 1] { for y in [-1.0, 0, 1] { for z in [-1.0, 0, 1] where x != 0 || y != 0 || z != 0 {
            out.append(Vec3(x, y, z).normalized)
        } } }
        return out
    }

    // MARK: Mapping

    /// The face axes are right-handed, and each face's normal is the
    /// direction at its centre.
    func testFaceFrames() {
        for f in CubeSphere.Face.allCases {
            XCTAssertEqual(f.uAxis.cross(f.vAxis), f.normal, "\(f)")
            XCTAssertEqual(CubeSphere.direction(face: f, u: 0.5, v: 0.5), f.normal, "\(f)")
        }
        // The equatorial faces' u points east, v north.
        XCTAssertEqual(CubeSphere.Face.posY.uAxis, Vec3(-1, 0, 0))
        XCTAssertEqual(CubeSphere.Face.negY.vAxis, .unitZ)
    }

    /// Direction → face coordinates → direction, to 1e-15, everywhere
    /// including the edges and corners; and face coordinates → direction →
    /// face coordinates on each face's interior, to 1e-14.
    func testRoundTrips() {
        for d in sampleDirections() {
            let p = CubeSphere.faceCoordinates(d)
            let back = CubeSphere.direction(face: p.face, u: p.u, v: p.v)
            XCTAssertLessThan((back - d).length, 1e-15, "\(d)")
            XCTAssertTrue((0 ... 1).contains(p.u) && (0 ... 1).contains(p.v))
        }
        for f in CubeSphere.Face.allCases {
            for u in stride(from: 0.003, through: 0.997, by: 0.0313) {
                for v in stride(from: 0.001, through: 0.999, by: 0.0471) {
                    let p = CubeSphere.faceCoordinates(CubeSphere.direction(face: f, u: u, v: v))
                    XCTAssertEqual(p.face, f)
                    XCTAssertEqual(p.u, u, accuracy: 1e-14)
                    XCTAssertEqual(p.v, v, accuracy: 1e-14)
                }
            }
        }
        // Scale does not matter.
        let p = CubeSphere.faceCoordinates(Vec3(-3e8, 1e8, 2e8))
        let q = CubeSphere.faceCoordinates(Vec3(-3, 1, 2).normalized)
        XCTAssertEqual(p.face, .negX)
        XCTAssertEqual(p.u, q.u, accuracy: 1e-15)
        XCTAssertEqual(p.v, q.v, accuracy: 1e-15)
    }

    /// The warp: the arc along a face's centre line is uniform in u (45° at
    /// u = 1, 22.5° at u = 3/4), and directions past the face's edge
    /// continue its projection into the neighbouring face.
    func testWarpAndBorders() {
        let c = CubeSphere.Face.posX.normal
        XCTAssertEqual(angleBetween(c, CubeSphere.direction(face: .posX, u: 1, v: 0.5)), 45 * deg, accuracy: 1e-15)
        XCTAssertEqual(angleBetween(c, CubeSphere.direction(face: .posX, u: 0.75, v: 0.5)), 22.5 * deg,
                       accuracy: 1e-15)
        XCTAssertEqual(CubeSphere.warp(CubeSphere.unwarp(0.3)), 0.3, accuracy: 1e-16)
        // u = 1.25 on +x is 67.5° east, on +y at u = 0.25.
        let past = CubeSphere.direction(face: .posX, u: 1.25, v: 0.5)
        XCTAssertEqual(atan2(past.y, past.x), 67.5 * deg, accuracy: 1e-14)
        let p = CubeSphere.faceCoordinates(past)
        XCTAssertEqual(p.face, .posY)
        XCTAssertEqual(p.u, 0.25, accuracy: 1e-14)
        XCTAssertEqual(p.v, 0.5, accuracy: 1e-14)
    }

    /// The areal distortion stays within the design's bound: the tiles of a
    /// level cover the sphere's 4π sr, and the largest is at most √2 (1.414,
    /// the design's "about 1.4x") times the smallest, approaching it as
    /// tiles shrink (1.380 at level 5). At the face centre a tile covers its nominal
    /// (tileAngle)², at an edge midpoint 1/√2 of it.
    func testArealDistortion() {
        let level = 5, n = 1 << level
        var total = 0.0, largest = 0.0, smallest = Double.infinity
        for f in CubeSphere.Face.allCases {
            for y in 0 ..< n { for x in 0 ..< n {
                let a = TileKey(face: f, level: level, x: x, y: y).solidAngle
                total += a; largest = max(largest, a); smallest = min(smallest, a)
            } }
        }
        XCTAssertEqual(total, 4 * Double.pi, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(largest / smallest, CubeSphere.areaRatio)
        XCTAssertGreaterThan(largest / smallest, 1.37)
        XCTAssertEqual(CubeSphere.areaRatio, 1.4142135623730951)
        // Area elements at level 12, against the nominal tile.
        let nominal = pow(CubeSphere.tileAngle(level: 12), 2)
        let centre = TileKey(face: .posZ, level: 12, x: 2047, y: 2047).solidAngle
        let edge = TileKey(face: .posZ, level: 12, x: 4095, y: 2047).solidAngle
        XCTAssertEqual(centre / nominal, 1, accuracy: 1e-5)
        XCTAssertEqual(edge / nominal, 1 / CubeSphere.areaRatio, accuracy: 1e-3)
    }

    /// The linear distortion: arcs per step of u or v, from the mapping's
    /// Jacobian over a face, lie between 2/3 and 2/√3 of the centre line's.
    func testLinearDistortion() {
        var largest = 0.0, smallest = Double.infinity
        let h = 1e-6, nominal = Double.pi / 2
        for i in 0 ... 40 { for j in 0 ... 40 {
            let u = Double(i) / 40, v = Double(j) / 40
            let du = (CubeSphere.direction(face: .negY, u: u + h, v: v)
                - CubeSphere.direction(face: .negY, u: u - h, v: v)) / (2 * h * nominal)
            let dv = (CubeSphere.direction(face: .negY, u: u, v: v + h)
                - CubeSphere.direction(face: .negY, u: u, v: v - h)) / (2 * h * nominal)
            // Singular values of the 3×2 Jacobian [du dv].
            let e = du.dot(du), g = dv.dot(dv), f = du.dot(dv)
            let mean = (e + g) / 2, spread = ((e - g) * (e - g) / 4 + f * f).squareRoot()
            largest = max(largest, (mean + spread).squareRoot())
            smallest = min(smallest, (mean - spread).squareRoot())
        } }
        XCTAssertEqual(largest, CubeSphere.maxLinearScale, accuracy: 1e-6)
        XCTAssertEqual(smallest, CubeSphere.minLinearScale, accuracy: 1e-6)
    }

    // MARK: Figure directions

    /// On WGS 84 a geodetic latitude's figure direction lands on the
    /// surface point `Ellipsoid.bodyFixed` gives (itself pinned to IOGP's
    /// worked example in EllipsoidTests), to 0.1 mm, and maps back.
    func testFigureDirections() {
        let e = Ellipsoid.wgs84
        for latDeg in stride(from: -90.0, through: 90.0, by: 6.5) {
            let lat = latDeg * deg, lon = (latDeg * 3.1 - 100) * deg
            let d = e.figureDirection(latitude: lat, longitude: lon)
            let p = e.bodyFixed(latitude: lat, longitude: lon, height: 0)
            XCTAssertEqual(d.length, 1, accuracy: 1e-15)
            XCTAssertLessThan((e.surfacePoint(figureDirection: d) - p).length, 1e-4, "\(latDeg)°")
            XCTAssertLessThan((e.figureDirection(of: p) - d).length, 1e-15)
            let g = e.geodeticCoordinates(figureDirection: d)
            XCTAssertEqual(g.latitude, lat, accuracy: 1e-15)
            if abs(latDeg) < 90 { XCTAssertEqual(remainder(g.longitude - lon, 2 * Double.pi), 0, accuracy: 1e-15) }
        }
        // On a sphere the figure direction is the geocentric one.
        let moon = Ellipsoid.sphere(1_737_400)
        let d = moon.figureDirection(latitude: 0.3, longitude: -1.2)
        XCTAssertLessThan((moon.surfacePoint(figureDirection: d) - moon.bodyFixed(latitude: 0.3, longitude: -1.2,
                                                                                 height: 0)).length, 1e-8)
    }

    // MARK: Tile addressing

    /// Identifiers round-trip, order by face, level and row, and reject
    /// what addresses no tile.
    func testIdentifiers() {
        let keys = [TileKey(face: .posX, level: 0, x: 0, y: 0), TileKey(face: .negZ, level: 27, x: (1 << 27) - 1, y: 5),
                    TileKey(face: .negY, level: 9, x: 300, y: 511), TileKey(face: .posZ, level: 1, x: 1, y: 0)]
        for k in keys { XCTAssertEqual(TileKey(id: k.id), k) }
        XCTAssertLessThan(TileKey(face: .posX, level: 3, x: 7, y: 7), TileKey(face: .posY, level: 0, x: 0, y: 0))
        XCTAssertLessThan(TileKey(face: .posY, level: 2, x: 3, y: 3), TileKey(face: .posY, level: 3, x: 0, y: 0))
        XCTAssertLessThan(TileKey(face: .posY, level: 3, x: 7, y: 0), TileKey(face: .posY, level: 3, x: 0, y: 1))
        XCTAssertNil(TileKey(id: 6 << 60))                         // no seventh face
        XCTAssertNil(TileKey(id: 1 << 55 | 2))                     // x past the level
        XCTAssertNil(TileKey(id: 28 << 55))                        // too deep
        XCTAssertNil(TileKey(id: 1 << 54))                         // the unused bit
    }

    /// Parents, children and containment agree with face coordinates.
    func testHierarchy() {
        let k = TileKey(face: .negX, level: 6, x: 37, y: 12)
        XCTAssertEqual(k.children.count, 4)
        for c in k.children {
            XCTAssertEqual(c.parent, k)
            XCTAssertTrue(k.contains(c))
            XCTAssertFalse(c.contains(k))
            let b = c.bounds
            XCTAssertEqual(TileKey.containing(face: .negX, u: (b.u0 + b.u1) / 2, v: (b.v0 + b.v1) / 2, level: 6), k)
        }
        XCTAssertEqual(k.ancestor(atLevel: 0), .root(.negX))
        XCTAssertEqual(k.ancestor(atLevel: 4), TileKey(face: .negX, level: 4, x: 9, y: 3))
        XCTAssertNil(TileKey.root(.posY).parent)
        XCTAssertFalse(k.contains(TileKey(face: .posX, level: 7, x: 74, y: 24)))
        // The children tile their parent's solid angle.
        XCTAssertEqual(k.children.map(\.solidAngle).reduce(0, +), k.solidAngle, accuracy: 1e-15)
        XCTAssertEqual(CubeSphere.tileCount(level: 3), 384)
        let local = k.localCoordinates(u: (37 + 0.25) / 64, v: (12 + 0.75) / 64)
        XCTAssertEqual(local.u, 0.25, accuracy: 1e-12)
        XCTAssertEqual(local.v, 0.75, accuracy: 1e-12)
    }

    /// Every tile's four neighbours, levels 0 to 4: the relation is
    /// symmetric, edge to edge, the shared edge's two corner directions are
    /// the same seen from both tiles, and neighbours never share a face's
    /// interior with the tile (they are distinct from it and each other).
    func testNeighboursAcrossEdges() {
        for level in 0 ... 4 {
            let n = 1 << level
            for f in CubeSphere.Face.allCases { for y in 0 ..< n { for x in 0 ..< n {
                let k = TileKey(face: f, level: level, x: x, y: y)
                var seen: Set<TileKey> = [k]
                for edge in TileKey.Edge.allCases {
                    let (m, back) = k.neighborAndEdge(edge)
                    XCTAssertEqual(m.level, level)
                    XCTAssertEqual(m.neighbor(back), k, "\(k) \(edge)")
                    XCTAssertTrue(seen.insert(m).inserted, "\(k) \(edge)")
                    let a = edgeCorners(k, edge), b = edgeCorners(m, back)
                    // The shared edge runs the other way round from the neighbour.
                    XCTAssertLessThan((a.0 - b.1).length, 1e-15, "\(k) \(edge)")
                    XCTAssertLessThan((a.1 - b.0).length, 1e-15, "\(k) \(edge)")
                }
            } } }
        }
        // At level 0 a face's neighbours are the four faces around it.
        for f in CubeSphere.Face.allCases {
            let around = TileKey.Edge.allCases.map { TileKey.root(f).neighbor($0).face }
            XCTAssertFalse(around.contains(f))
            XCTAssertFalse(around.contains { $0.normal == -f.normal })
            XCTAssertEqual(Set(around).count, 4)
        }
        // The equator runs east from +x to +y; +x's top is the north face's bottom.
        XCTAssertEqual(TileKey.root(.posX).neighbor(.maxU), .root(.posY))
        XCTAssertEqual(TileKey(face: .posX, level: 2, x: 1, y: 3).neighborAndEdge(.maxV).key,
                       TileKey(face: .posZ, level: 2, x: 1, y: 0))
    }

    /// The endpoints of a tile's edge, counter-clockwise seen from outside.
    func edgeCorners(_ k: TileKey, _ edge: TileKey.Edge) -> (Vec3, Vec3) {
        let c = k.corners
        switch edge {
        case .minV: return (c[0], c[1])
        case .maxU: return (c[1], c[2])
        case .maxV: return (c[2], c[3])
        case .minU: return (c[3], c[0])
        }
    }

    /// At each of the cube's eight corners three tiles meet, at every level:
    /// the corner tile's two neighbours off the face are each other's
    /// neighbours, and all three hold the corner direction.
    func testCubeCorners() {
        for level in [0, 1, 3, 9] {
            let last = (1 << level) - 1
            var corners: [Vec3: Set<TileKey>] = [:]
            for f in CubeSphere.Face.allCases {
                for (cu, cv) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
                    let k = TileKey(face: f, level: level, x: cu < 0 ? 0 : last, y: cv < 0 ? 0 : last)
                    let eu: TileKey.Edge = cu < 0 ? .minU : .maxU, ev: TileKey.Edge = cv < 0 ? .minV : .maxV
                    let a = k.neighbor(eu), b = k.neighbor(ev)
                    XCTAssertNotEqual(a.face, f)
                    XCTAssertNotEqual(b.face, f)
                    XCTAssertTrue(TileKey.Edge.allCases.contains { a.neighbor($0) == b }, "\(k)")
                    // The cube corner, as an exact integer direction.
                    let p = CubeSphere.cubePoint(face: f, a: cu, b: cv)
                    corners[p, default: []].formUnion([k, a, b])
                    for t in [k, a, b] {
                        XCTAssertTrue(t.corners.contains { ($0 - p.normalized).length < 1e-15 }, "\(t)")
                    }
                }
            }
            XCTAssertEqual(corners.count, 8)
            for (_, tiles) in corners { XCTAssertEqual(tiles.count, 3, "level \(level)") }
        }
    }

    /// Directions on face edges and corners go to one tile, deterministically,
    /// whose square holds them; just inside each face they go to that face.
    func testContainingAtEdgesAndCorners() {
        let corner = Vec3(1, 1, 1).normalized
        let k = TileKey.containing(corner, level: 7)
        XCTAssertEqual(k, TileKey(face: .posX, level: 7, x: 127, y: 127))
        for f in [CubeSphere.Face.posX, .posY, .posZ] {
            let inside = (corner + f.normal * 1e-9).normalized
            XCTAssertEqual(TileKey.containing(inside, level: 7).face, f)
        }
        XCTAssertEqual(TileKey.containing(Vec3(1, 1, 0), level: 3), TileKey(face: .posX, level: 3, x: 7, y: 4))
        XCTAssertEqual(TileKey.containing(Vec3(0, 0, -1), level: 0), .root(.negZ))
        XCTAssertEqual(TileKey.containing(face: .posY, u: 1, v: 0, level: 4), TileKey(face: .posY, level: 4, x: 15, y: 0))
        // Every sample direction lies in its tile's square.
        for d in sampleDirections() {
            let p = CubeSphere.faceCoordinates(d)
            let b = TileKey.containing(d, level: 11).bounds
            XCTAssertTrue(p.u >= b.u0 && p.u <= b.u1 && p.v >= b.v0 && p.v <= b.v1)
        }
    }
}

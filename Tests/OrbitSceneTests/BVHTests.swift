import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The AO baker's triangle BVH against a brute-force loop over every
/// triangle.
final class BVHTests: XCTestCase {
    /// Möller-Trumbore on each triangle, both faces, the nearest distance
    /// in (0, tMax], in the same arithmetic as the tree's.
    func bruteForce(_ o: Vec3, _ d: Vec3, _ tMax: Double, _ p: [Vec3], _ idx: [UInt32]) -> (Double, Int)? {
        var best: (Double, Int)?
        for t in 0..<(idx.count / 3) {
            let a = p[Int(idx[3 * t])], e1 = p[Int(idx[3 * t + 1])] - a, e2 = p[Int(idx[3 * t + 2])] - a
            let q = d.cross(e2), det = e1.dot(q)
            guard det != 0 else { continue }
            let invDet = 1 / det
            let s = o - a, u = s.dot(q) * invDet
            guard u >= 0, u <= 1 else { continue }
            let r = s.cross(e1), v = d.dot(r) * invDet
            guard v >= 0, u + v <= 1 else { continue }
            let distance = e2.dot(r) * invDet
            if distance > 0, distance <= (best?.0 ?? tMax) { best = (distance, t) }
        }
        return best
    }

    /// A seeded cloud of small triangles in a 10 m box.
    func randomSoup(_ count: Int, seed: UInt64) -> ([Vec3], [UInt32]) {
        var rng = AmbientOcclusion.SplitMix64(state: seed)
        func r(_ scale: Double) -> Double { (rng.unit() - 0.5) * scale }
        var p: [Vec3] = [], idx: [UInt32] = []
        for _ in 0..<count {
            let c = Vec3(r(10), r(10), r(10))
            for _ in 0..<3 {
                idx.append(UInt32(p.count))
                p.append(c + Vec3(r(1.5), r(1.5), r(1.5)))
            }
        }
        return (p, idx)
    }

    func testMatchesBruteForceOnRandomTriangles() {
        let (p, idx) = randomSoup(600, seed: 42)
        let bvh = TriangleBVH(positions: p, indices: idx)
        XCTAssertEqual(bvh.triangleCount, 600)
        XCTAssertEqual(Set(bvh.order).count, 600, "every triangle once")
        var rng = AmbientOcclusion.SplitMix64(state: 7)
        var hits = 0
        for _ in 0..<3000 {
            let o = Vec3((rng.unit() - 0.5) * 14, (rng.unit() - 0.5) * 14, (rng.unit() - 0.5) * 14)
            let d = Vec3(rng.unit() - 0.5, rng.unit() - 0.5, rng.unit() - 0.5).normalized
            let reach = 1 + 6 * rng.unit()
            let expected = bruteForce(o, d, reach, p, idx)
            let got = bvh.intersect(origin: o, direction: d, maxDistance: reach)
            XCTAssertEqual(got?.distance ?? -1, expected?.0 ?? -1, accuracy: 1e-12)
            XCTAssertEqual(got?.triangle, expected?.1)
            XCTAssertEqual(bvh.occluded(origin: o, direction: d, maxDistance: reach), expected != nil)
            if expected != nil { hits += 1 }
        }
        XCTAssertGreaterThan(hits, 300, "the rays test hits as well as misses")
    }

    /// Rays along the axes (zero direction components) against a mesh with
    /// faces in the axis planes, from both sides.
    func testAxisAlignedRaysHitBothFaces() {
        let box = VisualShape.box(from: .zero, length: 2, width: 2, height: 2, color: (1, 1, 1)).mesh()
        let bvh = TriangleBVH(positions: box.vertices.map(\.position), indices: box.indices)
        // The box spans x 0...2, y and z -1...1.
        let axes = [Vec3.unitX, .unitY, .unitZ]
        for axis in axes {
            for sign in [-1.0, 1.0] {
                let d = axis * sign
                // From outside: the near face, 1 m away.
                let outside = bvh.intersect(origin: Vec3(1, 0, 0) - d * 2, direction: d)
                XCTAssertEqual(try XCTUnwrap(outside).distance, 1, accuracy: 1e-12)
                // From inside: the far face's back, 1 m away.
                let inside = bvh.intersect(origin: Vec3(1, 0.3, -0.2), direction: d)
                XCTAssertNotNil(inside)
                XCTAssertTrue(bvh.occluded(origin: Vec3(1, 0.3, -0.2), direction: d, maxDistance: 2))
                XCTAssertFalse(bvh.occluded(origin: Vec3(1, 0.3, -0.2), direction: d, maxDistance: 0.5))
            }
        }
        XCTAssertNil(bvh.intersect(origin: Vec3(1, 3, 0), direction: .unitX), "a ray past the box")
    }

    func testEmptyTreeHitsNothing() {
        let bvh = TriangleBVH(positions: [], indices: [])
        XCTAssertEqual(bvh.triangleCount, 0)
        XCTAssertFalse(bvh.occluded(origin: .zero, direction: .unitX, maxDistance: 10))
        XCTAssertNil(bvh.intersect(origin: .zero, direction: .unitX))
    }

    /// Triangles whose centres coincide (a fan's) still build into a tree
    /// that finds them.
    func testCoincidentCentresBuild() {
        var p: [Vec3] = [], idx: [UInt32] = []
        for k in 0..<100 {
            let a = 2 * Double.pi * Double(k) / 100
            for v in [Vec3(0, cos(a), sin(a)), Vec3(0, -cos(a), -sin(a)), Vec3(0.3, 0, 0)] {
                idx.append(UInt32(p.count))
                p.append(v)
            }
        }
        let bvh = TriangleBVH(positions: p, indices: idx)
        XCTAssertEqual(bvh.triangleCount, 100)
        var rng = AmbientOcclusion.SplitMix64(state: 3)
        var hits = 0
        for _ in 0..<500 {
            let o = Vec3(rng.unit() - 0.5, rng.unit() * 2 - 1, rng.unit() * 2 - 1)
            let d = Vec3(rng.unit() - 0.5, rng.unit() - 0.5, rng.unit() - 0.5).normalized
            let expected = bruteForce(o, d, .infinity, p, idx)
            XCTAssertEqual(bvh.intersect(origin: o, direction: d)?.triangle, expected?.1)
            if expected != nil { hits += 1 }
        }
        XCTAssertGreaterThan(hits, 50)
    }
}

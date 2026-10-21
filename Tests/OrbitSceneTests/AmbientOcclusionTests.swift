import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// Track R5's AO baker: view factors against Howell's catalogue, the open
/// and enclosed limits, subdivision, determinism, the background baker, and
/// the bake time of today's Saturn V.
final class AmbientOcclusionTests: XCTestCase {
    static let white = (1.0, 1.0, 1.0)

    /// Howell, A Catalog of Radiation Heat Transfer Configuration Factors,
    /// B-12 (Chung and Sumitra 1972): a planar element to a circular disc
    /// of radius r in a parallel plane at h, the element's normal through
    /// the disc's centre: F = 1/(1 + H²), H = h/r.
    /// http://www.thermalradiation.net/sectionb/B-12.html
    static func elementToDisc(radius r: Double, distance h: Double) -> Double {
        let H = h / r
        return 1 / (1 + H * H)
    }

    /// Howell's C-41: a disc of radius r1 to a parallel coaxial disc of
    /// radius r2 at h: R = r/h, X = 1 + (1 + R2²)/R1²,
    /// F = (X - √(X² - 4(R2/R1)²))/2.
    /// http://www.thermalradiation.net/sectionc/C-41.html
    static func discToDisc(_ r1: Double, _ r2: Double, distance h: Double) -> Double {
        let R1 = r1 / h, R2 = r2 / h
        let X = 1 + (1 + R2 * R2) / (R1 * R1)
        let ratio = R2 / R1
        return (X - (X * X - 4 * ratio * ratio).squareRoot()) / 2
    }

    /// A cup along +x: a cylinder of `radius` and `depth` with its floor
    /// (x = 0) closed and its top open, two-sided, so that its inside has
    /// values (the back's).
    func cup(radius: Double, depth: Double) -> VisualShape {
        var s = VisualShape.revolution([.init(0, radius, crease: true), .init(depth, radius, crease: true)],
                                       from: .zero, segments: 128, color: Self.white)
        s.capTop = false
        s.twoSided = true
        return s
    }

    /// `shape` subdivided and baked alone.
    func bake(_ shape: VisualShape, _ settings: AmbientOcclusionSettings = AmbientOcclusionSettings())
        -> (mesh: VisualShape.Mesh, values: AmbientOcclusion.Values) {
        let mesh = AmbientOcclusion.subdivide(shape.mesh(), maxEdge: settings.maxEdge)
        let surface = AmbientOcclusion.Surface(mesh: mesh, twoSided: shape.twoSided)
        return (mesh, AmbientOcclusion.bake([surface], settings: settings)[0])
    }

    func settings(rays: Int) -> AmbientOcclusionSettings {
        var s = AmbientOcclusionSettings()
        s.raysPerVertex = rays
        return s
    }

    // MARK: View factors

    /// The centre of a cup's floor sees the sky through the cup's mouth, a
    /// coaxial disc: its AO is Howell's B-12. The rays' radial coordinate
    /// (sin² of the angle off the normal) is stratified, one ray per 1/N, so
    /// for a disc about the normal the count is right to within one ray.
    /// The floor's mean AO, weighted by area, is the floor's view factor to
    /// the mouth, Howell's C-41, to within the mesh's resolution (0.5 m on a
    /// 1 m radius; -0.004 at depth 1 when measured). Every point of the walls
    /// is within the 3 m reach, so every ray that does not leave by the mouth
    /// counts.
    func testCupFloorMatchesHowellsCoaxialDiscs() throws {
        for depth in [1.0, 2.0] {
            let shape = cup(radius: 1, depth: depth)
            let expected = Self.elementToDisc(radius: 1, distance: depth)
            // The baked cup, 32 rays per vertex.
            let (mesh, values) = bake(shape)
            // The floor's centre: one vertex per fan triangle, welded.
            let centre = mesh.vertices.indices.filter {
                mesh.vertices[$0].position.length < 1e-12 && mesh.vertices[$0].normal.x < -0.99
            }
            XCTAssertEqual(centre.count, 128)
            XCTAssertEqual(Set(centre.map { values.back[$0] }).count, 1, "coincident vertices share a value")
            XCTAssertEqual(Double(values.back[centre[0]]), expected, accuracy: 1.0 / 32 + 1e-3, "depth \(depth)")
            XCTAssertEqual(values.front[centre[0]], 1, "the floor's underside sees everything")
            // The same point, 1,024 rays.
            let occluders = AmbientOcclusion.occluders([AmbientOcclusion.Surface(mesh: shape.mesh())])
            let fine = AmbientOcclusion.occlusion(at: Vec3(1e-3, 0, 0), normal: .unitX, occluders: occluders,
                                                  settings: settings(rays: 1024))
            XCTAssertEqual(fine, expected, accuracy: 1.0 / 1024 + 1e-3, "depth \(depth)")

            // Area-weighted mean over the floor (the base cap, normal -x).
            var weighted = 0.0, area = 0.0
            for t in stride(from: 0, to: mesh.indices.count, by: 3) {
                let i = (0..<3).map { Int(mesh.indices[t + $0]) }
                guard i.allSatisfy({ mesh.vertices[$0].normal.x < -0.99 }) else { continue }
                let p = i.map { mesh.vertices[$0].position }
                let a = 0.5 * (p[1] - p[0]).cross(p[2] - p[0]).length
                weighted += a * i.reduce(0.0) { $0 + Double(values.back[$1]) } / 3
                area += a
            }
            XCTAssertEqual(area, Double.pi, accuracy: 0.01, "the floor is the unit disc, near enough")
            let floorToMouth = Self.discToDisc(1, 1, distance: depth)
            XCTAssertEqual(weighted / area, floorToMouth, accuracy: 0.01, "depth \(depth)")
        }
    }

    /// Inside an open tube, a point on the axis facing along it sees the
    /// sky through the tube's end, again a coaxial disc (B-12).
    func testInsideAnOpenTube() {
        var tube = VisualShape.revolution([.init(0, 1, crease: true), .init(6, 1, crease: true)], from: .zero,
                                          segments: 128, color: Self.white)
        tube.capBase = false
        tube.capTop = false
        tube.twoSided = true
        let occluders = AmbientOcclusion.occluders([AmbientOcclusion.Surface(mesh: tube.mesh())])
        for distance in [1.0, 2.0] {
            let ao = AmbientOcclusion.occlusion(at: Vec3(6 - distance, 0, 0), normal: .unitX, occluders: occluders,
                                                settings: settings(rays: 4096))
            XCTAssertEqual(ao, Self.elementToDisc(radius: 1, distance: distance), accuracy: 0.005)
        }
        // Halfway down, facing the wall, only the rays within ψ0 = asin(1/3)
        // of the axis go the 3 m reach without meeting the wall (the ends
        // are 3 m off). Their cosine-weighted share about the normal is
        // (2/π)∫cos φ dφ ∫sin²ψ dψ over both ends: (4/π)(ψ0/2 - sin 2ψ0/4).
        let middle = AmbientOcclusion.occlusion(at: Vec3(3, 0, 0), normal: .unitY, occluders: occluders,
                                                settings: settings(rays: 4096))
        let psi0 = asin(1.0 / 3)
        XCTAssertEqual(middle, 4 / Double.pi * (psi0 / 2 - sin(2 * psi0) / 4), accuracy: 0.003)
    }

    // MARK: The limits

    /// An open plane (a 20 m square slab) and a free sphere, convex: every
    /// vertex sees the whole sky above it, exactly, edges and corners
    /// included.
    func testOpenPlaneAndFreeSphereAreUnoccluded() {
        let slab = VisualShape.box(from: .zero, length: 0.1, width: 20, height: 20, color: Self.white)
        let sphere = VisualShape(kind: .sphere(radius: 2), origin: .zero, axis: .unitX, length: 4, color: Self.white)
        for shape in [slab, sphere] {
            let (mesh, values) = bake(shape)
            XCTAssertGreaterThan(mesh.vertices.count, shape.mesh().vertices.count, "subdivided")
            XCTAssertEqual(values.front.min(), 1)
            XCTAssertTrue(values.back.isEmpty, "one-sided")
        }
    }

    /// The inside of a closed box (1 m, within the reach from everywhere)
    /// sees nothing: its back faces are black, corners and edges too, and so
    /// is a point inside it; its outside sees everything.
    func testClosedBoxInteriorIsFullyOccluded() {
        var box = VisualShape.box(from: Vec3(-0.5, 0, 0), length: 1, width: 1, height: 1, color: Self.white)
        box.twoSided = true
        let (mesh, values) = bake(box, settings(rays: 256))
        XCTAssertEqual(values.back.count, mesh.vertices.count)
        XCTAssertEqual(values.back.max(), 0)
        XCTAssertEqual(values.front.min(), 1)
        let occluders = AmbientOcclusion.occluders([AmbientOcclusion.Surface(mesh: box.mesh())])
        for normal in [Vec3.unitX, Vec3(0.3, -0.5, 0.8).normalized] {
            XCTAssertEqual(AmbientOcclusion.occlusion(at: Vec3(0.1, 0.2, -0.3), normal: normal, occluders: occluders,
                                                      settings: settings(rays: 1024)), 0)
        }
    }

    // MARK: Subdivision

    /// Every edge ends no longer than the limit; the surface is the same
    /// (area, original vertices unmoved), still closed with no
    /// T-junctions (every edge, by position, shared by two triangles), and
    /// the new vertices' normals and tangents are unit and perpendicular.
    func testSubdivisionBoundsEdgesAndKeepsTheSurfaceClosed() {
        var faceted = VisualShape.box(from: .zero, length: 3.3, width: 1.7, height: 0.9, color: Self.white)
        faceted.faceted = true
        let shapes = [
            VisualShape.frustum(from: .zero, length: 42, baseRadius: 5.05, topRadius: 5.05, color: Self.white),
            VisualShape.frustum(from: .zero, length: 9, baseRadius: 3.3, topRadius: 1.9, color: Self.white),
            VisualShape(kind: .sphere(radius: 2.5), origin: .zero, axis: .unitX, length: 5, color: Self.white),
            VisualShape.torus(centre: .zero, majorRadius: 5, minorRadius: 0.4, color: Self.white),
            faceted,
        ]
        let maxEdge = 0.5
        for shape in shapes {
            let original = shape.mesh()
            let sub = AmbientOcclusion.subdivide(original, maxEdge: maxEdge)
            XCTAssertEqual(Array(sub.vertices.prefix(original.vertices.count)), original.vertices)
            XCTAssertGreaterThan(sub.triangleCount, original.triangleCount)
            XCTAssertEqual(area(sub), area(original), accuracy: 1e-9 * area(original))
            XCTAssertTrue(isClosed(original), "\(shape.kind)")
            XCTAssertTrue(isClosed(sub), "\(shape.kind): no T-junctions")
            var longest = 0.0
            for t in stride(from: 0, to: sub.indices.count, by: 3) {
                let p = (0..<3).map { sub.vertices[Int(sub.indices[t + $0])].position }
                longest = max(longest, (p[1] - p[0]).length, (p[2] - p[1]).length, (p[0] - p[2]).length)
            }
            XCTAssertLessThanOrEqual(longest, maxEdge * (1 + 1e-12))
            XCTAssertGreaterThan(longest, maxEdge / 2, "edges are halved no further than needed")
            for v in sub.vertices.dropFirst(original.vertices.count) {
                XCTAssertEqual(v.normal.length, 1, accuracy: 1e-12)
                XCTAssertEqual(v.tangent.length, 1, accuracy: 1e-12)
                XCTAssertEqual(v.normal.dot(v.tangent), 0, accuracy: 1e-12)
            }
        }
    }

    func area(_ m: VisualShape.Mesh) -> Double {
        stride(from: 0, to: m.indices.count, by: 3).reduce(0) { sum, t in
            let p = (0..<3).map { m.vertices[Int(m.indices[t + $0])].position }
            return sum + 0.5 * (p[1] - p[0]).cross(p[2] - p[0]).length
        }
    }

    /// Whether every edge, its ends taken by position (to 1 nm, so seams
    /// and creases count as one), belongs to exactly two triangles of
    /// non-zero area (a sphere's +x pole has a ring of empty ones).
    func isClosed(_ m: VisualShape.Mesh) -> Bool {
        func key(_ p: Vec3) -> [Int64] { [p.x, p.y, p.z].map { Int64(($0 * 1e9).rounded()) } }
        var uses: [[Int64]: Int] = [:]
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let p = (0..<3).map { m.vertices[Int(m.indices[t + $0])].position }
            guard (p[1] - p[0]).cross(p[2] - p[0]).length > 1e-12 else { continue }
            let k = p.map(key)
            for (a, b) in [(k[0], k[1]), (k[1], k[2]), (k[2], k[0])] {
                let lexicallyFirst = a.lexicographicallyPrecedes(b)
                uses[lexicallyFirst ? a + b : b + a, default: 0] += 1
            }
        }
        return uses.values.allSatisfy { $0 == 2 }
    }

    // MARK: Determinism

    /// One seed, one result, however the vertices are shared out among the
    /// threads; another seed, another pattern of noise about the same
    /// values. A capsule, and a two-sided cup out of its reach for back
    /// faces.
    func testDeterministicForAFixedSeed() {
        let geometry = VesselGeometry(of: VesselLibrary.capsule())
        let first = AmbientOcclusion.bake(geometry), second = AmbientOcclusion.bake(geometry)
        let values = { (b: BakedAmbientOcclusion) in b.parts.flatMap { $0.shapes.flatMap { $0.front + $0.back } } }
        XCTAssertEqual(values(first), values(second))
        XCTAssertGreaterThan(Set(values(first)).count, 5, "a range of values, not only 0 and 1")

        var surfaces = first.parts.flatMap { part in
            part.shapes.map { AmbientOcclusion.Surface(mesh: $0.mesh, offset: part.offset, twoSided: !$0.back.isEmpty) }
        }
        let cup = cup(radius: 1, depth: 1.5)
        surfaces.append(AmbientOcclusion.Surface(mesh: AmbientOcclusion.subdivide(cup.mesh(), maxEdge: 0.5),
                                                 offset: Vec3(0, 10, 0), twoSided: true))
        let occluders = AmbientOcclusion.occluders(surfaces)
        let settings = AmbientOcclusionSettings()
        let byChunk = [1, 7, 64, 1 << 20].map {
            AmbientOcclusion.bake(surfaces, occluders: occluders, settings: settings, chunk: $0)
        }
        for other in byChunk.dropFirst() { XCTAssertEqual(other, byChunk[0]) }
        XCTAssertEqual(byChunk[0].dropLast().flatMap { $0.front + $0.back }, values(first))
        XCTAssertFalse(byChunk[0].last!.back.isEmpty)

        var reseeded = settings
        reseeded.seed = 2
        let all = byChunk[0].flatMap { $0.front + $0.back }
        let other = AmbientOcclusion.bake(surfaces, occluders: occluders, settings: reseeded).flatMap { $0.front + $0.back }
        XCTAssertNotEqual(other, all)
        let mean = { (v: [Float]) in Double(v.reduce(0, +)) / Double(v.count) }
        XCTAssertEqual(mean(other), mean(all), accuracy: 0.01)
    }

    // MARK: The hook

    func testPackingIsExact() {
        XCTAssertEqual(AmbientOcclusion.unoccluded, 1_048_575)
        for f in stride(from: 0, through: 1023, by: 31) {
            for b in stride(from: 0, through: 1023, by: 29) {
                let front = Float(f) / 1023, back = Float(b) / 1023
                let w = AmbientOcclusion.pack(front: front, back: back)
                XCTAssertEqual(w, Float(b * 1024 + f))
                let u = AmbientOcclusion.unpack(w)
                XCTAssertEqual(u.front, front)
                XCTAssertEqual(u.back, back)
            }
        }
        XCTAssertEqual(AmbientOcclusion.unpack(AmbientOcclusion.pack(front: 2, back: -1)).front, 1, "clamped")
    }

    /// The bake follows `VesselGeometry`: per part and shape, the shape's
    /// subdivided mesh and a value per vertex, a back only when two-sided.
    func testVesselBakeFollowsItsGeometry() {
        let geometry = VesselGeometry(of: VesselLibrary.testRocket())
        let baked = AmbientOcclusion.bake(geometry, settings: settings(rays: 4))
        XCTAssertEqual(baked.signature, geometry.signature)
        XCTAssertEqual(baked.parts.map(\.id), geometry.parts.map(\.id))
        for (part, source) in zip(baked.parts, geometry.parts) {
            XCTAssertEqual(part.shapes.count, source.shapes.count)
            XCTAssertEqual(part.offset, source.offset)
            for (shape, visual) in zip(part.shapes, source.shapes) {
                XCTAssertEqual(shape.mesh, AmbientOcclusion.subdivide(visual.mesh(), maxEdge: 0.5))
                XCTAssertEqual(shape.front.count, shape.mesh.vertices.count)
                XCTAssertEqual(shape.back.count, visual.twoSided ? shape.mesh.vertices.count : 0)
                let i = shape.mesh.vertices.count / 2
                XCTAssertEqual(AmbientOcclusion.unpack(shape.packed(vertex: i)).front, shape.front[i], accuracy: 0.5 / 1023)
            }
        }
    }

    // MARK: The background baker

    func testBakerBakesOncePerSignatureAndFadesIn() {
        // Two capsules, alive throughout: two vessels, two signatures (as a
        // separation makes).
        let before = VesselLibrary.capsule(), after = VesselLibrary.capsule()
        defer { withExtendedLifetime((before, after)) {} }
        let baker = AmbientOcclusionBaker()
        let first = baker.lookup(VesselGeometry(of: before), now: 0)
        XCTAssertNil(first.baked, "the first ask queues a bake")
        XCTAssertEqual(first.fade, 0)
        baker.waitUntilIdle()
        XCTAssertEqual(baker.bakeCount, 1)

        // Fades in over 0.5 s of the renderer's clock from when it is first
        // handed out.
        let shown = baker.lookup(VesselGeometry(of: before), now: 10)
        XCTAssertNotNil(shown.baked)
        XCTAssertEqual(shown.fade, 0)
        XCTAssertEqual(baker.lookup(VesselGeometry(of: before), now: 10.25).fade, 0.5, accuracy: 1e-12)
        XCTAssertEqual(baker.lookup(VesselGeometry(of: before), now: 11).fade, 1)
        for _ in 0..<10 { _ = baker.lookup(VesselGeometry(of: before), now: 12) }
        baker.waitUntilIdle()
        XCTAssertEqual(baker.bakeCount, 1, "baked once, reused")

        // Another signature (a separation gives one) is baked anew.
        XCTAssertTrue(baker.lookup(VesselGeometry(of: after), now: 12).baked == nil)
        baker.waitUntilIdle()
        XCTAssertEqual(baker.bakeCount, 2)
        XCTAssertEqual(baker.count, 2)

        // bakeNow serves the cache and shows it at once.
        let afterBake = baker.bakeNow(VesselGeometry(of: after))
        XCTAssertEqual(baker.bakeCount, 2)
        XCTAssertEqual(afterBake?.signature, VesselGeometry(of: after).signature)
        XCTAssertEqual(baker.lookup(VesselGeometry(of: after), now: 12).fade, 1)

        // New settings empty the cache; off, nothing is baked.
        var settings = baker.settings
        settings.raysPerVertex = 8
        baker.settings = settings
        XCTAssertEqual(baker.count, 0)
        settings.enabled = false
        baker.settings = settings
        let off = baker.lookup(VesselGeometry(of: before), now: 13)
        XCTAssertNil(off.baked)
        XCTAssertEqual(off.fade, 0)
        XCTAssertNil(baker.bakeNow(VesselGeometry(of: before)))
        baker.waitUntilIdle()
        XCTAssertEqual(baker.count, 0)
    }

    func testBakerKeepsTheMostRecentlyUsed() {
        let baker = AmbientOcclusionBaker(capacity: 1)
        // Both vessels alive throughout: a part freed and another allocated
        // in its place would have its identifier (and here its geometry
        // too, which the cache would then rightly serve).
        let vessels = (VesselLibrary.capsule(), VesselLibrary.capsule())
        withExtendedLifetime(vessels) {
            let first = VesselGeometry(of: vessels.0), second = VesselGeometry(of: vessels.1)
            baker.bakeNow(first)
            baker.bakeNow(second)
            XCTAssertEqual(baker.count, 1)
            XCTAssertNotNil(baker.lookup(second, now: 0).baked)
            XCTAssertTrue(baker.lookup(first, now: 0).baked == nil, "dropped, and queued again")
            baker.waitUntilIdle()
            XCTAssertEqual(baker.bakeCount, 3)
        }
    }

    // MARK: Settings

    func testSettingsDecodeWithDefaults() throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(AmbientOcclusionSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AmbientOcclusionSettings())
        XCTAssertEqual(empty.raysPerVertex, 32)
        XCTAssertEqual(empty.maxDistance, 3)
        XCTAssertEqual(empty.maxEdge, 0.5)
        XCTAssertEqual(empty.fadeDuration, 0.5)
        let some = try decoder.decode(RenderSettings.self,
                                      from: Data(#"{"ambientOcclusion": {"raysPerVertex": 8, "seed": 9}}"#.utf8))
        XCTAssertEqual(some.ambientOcclusion.raysPerVertex, 8)
        XCTAssertEqual(some.ambientOcclusion.seed, 9)
        XCTAssertEqual(some.ambientOcclusion.maxDistance, 3)
        let back = try decoder.decode(RenderSettings.self, from: JSONEncoder().encode(some))
        XCTAssertEqual(back, some)
    }

    // MARK: Today's Saturn V

    /// The whole AS-506 stack bakes in a few seconds at -O on a 4-core cloud
    /// machine (about 1.4 s for 162,000 vertices after subdivision, about
    /// 5.7 million rays, when measured), within a budget that leaves room for
    /// the parallel test run's load and the vehicle-look tracks' added
    /// geometry. The unoptimised build is about 20 times slower; it casts 4
    /// rays per vertex and has a looser budget. The values are sane: inside
    /// a bell is darker than outside, the hull is mostly open, and shapes
    /// buried in others are black.
    func testSaturnVBakesWithinBudget() {
        var settings = AmbientOcclusionSettings()
        #if DEBUG
        settings.raysPerVertex = 4
        let budget = 120.0
        #else
        let budget = 20.0
        #endif
        let vessel = VesselLibrary.saturnV()
        let geometry = VesselGeometry(of: vessel)
        let baked = AmbientOcclusion.bake(geometry, settings: settings)
        let raw = geometry.parts.reduce(0) { $0 + $1.shapes.reduce(0) { $0 + $1.mesh().vertices.count } }
        print(String(format: "Saturn V AO: %d vertices (%d before subdivision), %d triangles, %d rays each, %.2f s",
                     baked.vertexCount, raw, baked.triangleCount, settings.raysPerVertex, baked.seconds))
        XCTAssertLessThan(baked.seconds, budget)
        XCTAssertGreaterThan(baked.vertexCount, 4 * raw, "long panels are subdivided")

        var all: [Float] = [], bellsInside: [Float] = [], bellsOutside: [Float] = [], hull: [Float] = []
        for (p, part) in baked.parts.enumerated() {
            for (s, shape) in part.shapes.enumerated() {
                all += shape.front + shape.back
                let visual = geometry.parts[p].shapes[s]
                if visual.thruster != nil && visual.twoSided {
                    bellsInside += shape.back
                    bellsOutside += shape.front
                }
                // The S-IC's sides between 10 m and 30 m up.
                guard vessel.parts[p].name == "S-IC" else { continue }
                for (i, v) in shape.mesh.vertices.enumerated() {
                    let x = v.position.x + part.offset.x
                    if abs(v.normal.x) < 0.1 && x > 10 && x < 30 { hull.append(shape.front[i]) }
                }
            }
        }
        let mean = { (v: [Float]) in Double(v.reduce(0, +)) / Double(max(v.count, 1)) }
        XCTAssertTrue(all.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(bellsInside.count, 1000)
        XCTAssertLessThan(mean(bellsInside), mean(bellsOutside) - 0.3)
        XCTAssertGreaterThan(hull.count, 1000)
        XCTAssertGreaterThan(mean(hull), 0.85)
        XCTAssertTrue(all.contains(0), "caps between stages are buried")
    }
}

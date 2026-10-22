import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// Track R5's AO baker: view factors against Howell's catalogue, the open
/// and enclosed limits, subdivision, determinism, the background baker, and
/// the Saturn V's bake against the plan's budget.
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

    typealias Sides = (front: Float, back: Float)

    /// The rasteriser's interpolation of a varying between two vertices
    /// (perspective-correct weights are a convex pair too).
    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    /// The packed value is a code, not a level: decoded per vertex and the
    /// pair interpolated, a fragment gets the interpolation of the baked
    /// values to within the packing's half level; interpolated packed and
    /// decoded in the fragment, it gets a sawtooth. Edges first: one-sided
    /// from 1.0 to 0.97, a bell's two-sided pair (front 1, back 0.30 and
    /// 0.35), and one-sided from 0.9 to 1.0 swept end to end.
    func testShaderDecodesPerVertexNotTheInterpolatedPackedValue() {
        let half: Float = 0.5 / 1023
        // The documented route, between vertices with packed values a and
        // b, at t from a: each vertex decoded on its own (`unpack`), the
        // pair interpolated, the side picked in the fragment.
        func right(_ a: Float, _ b: Float, _ t: Float, frontFacing: Bool) -> Float {
            let u = AmbientOcclusion.unpack(a), v = AmbientOcclusion.unpack(b)
            let pair: Sides = (Self.lerp(u.front, v.front, t), Self.lerp(u.back, v.back, t))
            return AmbientOcclusion.fragment(pair, frontFacing: frontFacing, fade: 1)
        }
        // What the hook's first notes did: the packed value interpolated,
        // then decoded in the fragment function.
        func wrong(_ a: Float, _ b: Float, _ t: Float, frontFacing: Bool) -> Float {
            AmbientOcclusion.fragment(AmbientOcclusion.unpack(Self.lerp(a, b, t)), frontFacing: frontFacing, fade: 1)
        }

        let open = AmbientOcclusion.pack(front: 1, back: 1), dimmer = AmbientOcclusion.pack(front: 0.97, back: 0.97)
        XCTAssertEqual(right(open, dimmer, 0.25, frontFacing: true), 0.9925, accuracy: half)
        XCTAssertEqual(wrong(open, dimmer, 0.25, frontFacing: true), 247.25 / 1023, accuracy: 1e-6, "not 0.99")

        let a = AmbientOcclusion.pack(front: 1, back: 0.30), b = AmbientOcclusion.pack(front: 1, back: 0.35)
        XCTAssertEqual(right(a, b, 0.5, frontFacing: true), 1)
        XCTAssertEqual(right(a, b, 0.5, frontFacing: false), 0.325, accuracy: half)
        XCTAssertEqual(wrong(a, b, 0.5, frontFacing: true), 511.0 / 1023, accuracy: 1e-6, "an open outside at half")

        let dim = AmbientOcclusion.pack(front: 0.9, back: 0.9)
        var worstRight: Float = 0, worstWrong: Float = 0
        for k in 0...4096 {
            let t = Float(k) / 4096
            let truth = Self.lerp(0.9, 1, t)
            worstRight = max(worstRight, abs(right(dim, open, t, frontFacing: true) - truth))
            worstWrong = max(worstWrong, abs(wrong(dim, open, t, frontFacing: true) - truth))
        }
        XCTAssertLessThanOrEqual(worstRight, half + 1e-6)
        XCTAssertGreaterThan(worstWrong, 0.9)

        // Over the triangles of a baked capsule (one-sided shapes) and cup
        // (two-sided), at barycentric weights inside each: the documented
        // pipeline gives the weighted baked values of the face seen, to
        // within half a level; the packed route does not.
        let capsule = AmbientOcclusion.bake(VesselGeometry(of: VesselLibrary.capsule()), settings: settings(rays: 8))
        let bell = bake(cup(radius: 1, depth: 1.5), settings(rays: 8))
        let shapes = capsule.parts.flatMap(\.shapes)
            + [BakedAmbientOcclusion.Shape(mesh: bell.mesh, front: bell.values.front, back: bell.values.back)]
        XCTAssertTrue(shapes.contains { $0.back.isEmpty } && shapes.contains { !$0.back.isEmpty })
        let weights: [(Float, Float, Float)] = [(0.2, 0.3, 0.5), (0.6, 0.3, 0.1), (1.0 / 3, 1.0 / 3, 1.0 / 3)]
        var fragments = 0, wrongFragments = 0, worstPair: Float = 0, worstPacked: Float = 0
        for shape in shapes {
            for t in stride(from: 0, to: shape.mesh.indices.count, by: 3) {
                let i = (0..<3).map { Int(shape.mesh.indices[t + $0]) }
                let w = i.map { shape.packed(vertex: $0) }
                let pairs = w.map(AmbientOcclusion.unpack)
                for (l0, l1, l2) in weights {
                    for frontFacing in [true, false] {
                        let seen = i.map { shape.occlusion(vertex: $0, backFace: !frontFacing) }
                        let truth: Float = l0 * seen[0] + l1 * seen[1] + l2 * seen[2]
                        let pair: Sides = (l0 * pairs[0].front + l1 * pairs[1].front + l2 * pairs[2].front,
                                           l0 * pairs[0].back + l1 * pairs[1].back + l2 * pairs[2].back)
                        let ao = AmbientOcclusion.fragment(pair, frontFacing: frontFacing, fade: 1)
                        worstPair = max(worstPair, abs(ao - truth))
                        let packed: Float = l0 * w[0] + l1 * w[1] + l2 * w[2]
                        let decoded = AmbientOcclusion.fragment(AmbientOcclusion.unpack(packed),
                                                                frontFacing: frontFacing, fade: 1)
                        worstPacked = max(worstPacked, abs(decoded - truth))
                        fragments += 1
                        if abs(decoded - truth) > 0.05 { wrongFragments += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(fragments, 10000)
        XCTAssertLessThanOrEqual(worstPair, half + 1e-6)
        XCTAssertGreaterThan(worstPacked, 0.5)
        XCTAssertGreaterThan(wrongFragments, fragments / 20, "\(wrongFragments) of \(fragments) off by over 0.05")

        // Faded in: mix(1, ao, fade).
        XCTAssertEqual(AmbientOcclusion.fragment((0.2, 0.6), frontFacing: true, fade: 0), 1)
        XCTAssertEqual(AmbientOcclusion.fragment((0.2, 0.6), frontFacing: false, fade: 0.5), 0.8, accuracy: 1e-6)
        XCTAssertEqual(AmbientOcclusion.fragment((0.2, 0.6), frontFacing: true, fade: 1), 0.2, accuracy: 1e-6)
    }

    /// The type's shader notes keep that pipeline: the decode (`floor`, the
    /// 1024) sits in the vertex function, ahead of the fragment function,
    /// which takes the face from [[front_facing]] and only reads the
    /// interpolated pair (`in.ao`).
    func testShaderNotesDecodeInTheVertexFunction() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OrbitScene/Look/AmbientOcclusion.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(url.path) not found")
        }
        // The indented code block of the doc comment above `enum AmbientOcclusion`.
        let lines = text.components(separatedBy: "\n")
        let end = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("public enum AmbientOcclusion") })
        let snippet = lines[..<end].filter { $0.hasPrefix("///     ") }.map { String($0.dropFirst(8)) }
        let fragment = try XCTUnwrap(snippet.firstIndex { $0.contains("[[front_facing]]") },
                                     "the fragment function takes the face from [[front_facing]]")
        let vertexPart = snippet[..<fragment], fragmentPart = snippet[fragment...]
        XCTAssertTrue(vertexPart.contains { $0.contains("vertex function") })
        XCTAssertTrue(vertexPart.contains { $0.contains("floor(") }, "decoded in the vertex function")
        XCTAssertFalse(fragmentPart.contains { $0.contains("floor(") || $0.contains("1024") },
                       "the fragment function never decodes")
        XCTAssertTrue(fragmentPart.contains { $0.contains("in.ao") }, "it reads the interpolated pair")
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

    // MARK: The Saturn V

    /// The whole AS-506 stack, as the vehicle-look tracks dress it, bakes
    /// within the plan's budget into facets of at most 0.5 m, with sane
    /// values.
    ///
    /// **Budget.** The plan bakes in the background whenever a vessel's mesh
    /// signature changes and fades the result in (renderer-core §9, plan
    /// R5), outside the first frame's 2 s, and lets the new Linux tests add
    /// under 60 s to the suite (plan, Linux test budget). The bake's cost
    /// grows with the vertices after subdivision, which the vehicle-look
    /// tracks set, so the budget is per vertex: 100 µs, which keeps a stack
    /// at the plan's density (up to 400,000 triangles, owner decision 10;
    /// some 600,000 vertices once subdivided) within those 60 s in either
    /// build, the parallel run's load included. The Debug build casts 4 rays
    /// per vertex, not 32. Measured on the M3 Pro: this stack's 505,411
    /// vertices (106,377 before subdivision) take 3.3 µs each at -O (1.7 s)
    /// and 23 µs in Debug (12 s, most of it the BVH's build).
    ///
    /// **Values.** Every value is in 0...1; shapes buried in others (the
    /// caps between stages) are black; the S-IC's sides are mostly open.
    ///
    /// **Bells.** A bell in the open is darker inside than outside, and its
    /// inside obeys reciprocity.
    /// - The bells in the open are the nozzles (each thruster's last linked
    ///   shape with an exit, as `VesselGeometry` takes them) whose exhaust
    ///   leaves into the open: a ray from the exit's centre along it meets
    ///   nothing within the reach. Of the stack's main engines these are the
    ///   S-IC's F-1s; the J-2s fire into the domes below them and the SPS
    ///   into the SLA.
    /// - A bell's inside is the side of its nozzle that faces the axis, the
    ///   front of the F-1's gas side and the back of a two-sided bell (the
    ///   SM's RCS jets, the S-IVB's ullage motors). Its outside is a
    ///   two-sided nozzle's other side and the outward faces of the
    ///   thruster's other linked shapes about the same axis (the F-1's
    ///   extension, cocoon and manifold). Means are weighted by area, so
    ///   that the meshes' density does not count.
    /// - Reciprocity: the inside sees out only through the bell's openings
    ///   (its exit, and its far end when that is open), and
    ///   A_inside·F(inside → opening) = A_opening·F(opening → inside) ≤
    ///   A_opening. So when the reach spans the bell the inside's mean is at
    ///   most A_openings/A_inside (the RCS jets, the ullage motors). The exit
    ///   of a bell closed at its far end sees only the inside, so F(inside →
    ///   exit) = A_exit/A_inside exactly, and with nothing past the exit
    ///   plane every ray that leaves is open: the mean is at least that (the
    ///   F-1s, closed at their injectors at the bottom of the stack; the 3 m
    ///   reach adds the rays that end on the wall beyond it).
    func testSaturnVBakesWithinBudget() throws {
        var settings = AmbientOcclusionSettings()
        #if DEBUG
        settings.raysPerVertex = 4
        #endif
        let perVertex = 100e-6
        let vessel = VesselLibrary.saturnV()
        let geometry = VesselGeometry(of: vessel)
        let baked = AmbientOcclusion.bake(geometry, settings: settings)
        let raw = geometry.parts.map { part in part.shapes.map { $0.mesh() } }
        let rawVertices = raw.joined().reduce(0) { $0 + $1.vertices.count }
        print(String(format: "Saturn V AO: %d vertices (%d before subdivision), %d triangles, %d rays each, "
                     + "%.2f s, %.1f µs per vertex", baked.vertexCount, rawVertices, baked.triangleCount,
                     settings.raysPerVertex, baked.seconds, baked.seconds / Double(baked.vertexCount) * 1e6))
        XCTAssertLessThan(baked.seconds / Double(baked.vertexCount), perVertex)

        // Long panels are subdivided: no edge over the plan's 0.5 m.
        XCTAssertGreaterThan(baked.vertexCount, rawVertices)
        var longest = 0.0   // squared
        for part in baked.parts {
            for shape in part.shapes {
                let v = shape.mesh.vertices, ix = shape.mesh.indices
                for t in stride(from: 0, to: ix.count - 2, by: 3) {
                    let a = v[Int(ix[t])].position, b = v[Int(ix[t + 1])].position, c = v[Int(ix[t + 2])].position
                    let edges = max((b - a).lengthSquared, max((c - b).lengthSquared, (a - c).lengthSquared))
                    longest = max(longest, edges)
                }
            }
        }
        XCTAssertLessThanOrEqual(longest.squareRoot(), settings.maxEdge * (1 + 1e-12))

        var all: [Float] = [], hull: [Float] = []
        for (p, part) in baked.parts.enumerated() {
            for (s, shape) in part.shapes.enumerated() {
                all += shape.front + shape.back
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
        XCTAssertGreaterThan(hull.count, 1000)
        XCTAssertGreaterThan(mean(hull), 0.85)
        XCTAssertTrue(all.contains(0), "caps between stages are buried")

        // The bells in the open, found against the unsubdivided stack.
        let surfaces = zip(geometry.parts, raw).flatMap { part, meshes in
            meshes.map { AmbientOcclusion.Surface(mesh: $0, offset: part.offset) }
        }
        let occluders = AmbientOcclusion.occluders(surfaces)
        var mains: [String] = [], closedAtTheBottom: Set<String> = [], spanned = 0
        var mainBells = Bell(), twoSided = Bell()
        for (p, part) in geometry.parts.enumerated() {
            for thruster in vessel.parts[p].thrusters {
                let linked = part.shapes.indices.filter { part.shapes[$0].thruster == thruster.name }
                guard let n = linked.last(where: { VesselGeometry.exit(of: part.shapes[$0]) != nil }),
                      let exit = VesselGeometry.exit(of: part.shapes[n]) else { continue }
                let exhaust = -thruster.direction, centre = exit.centre + part.offset
                let start = centre + exhaust * AmbientOcclusion.surfaceOffset
                guard !occluders.occluded(origin: start, direction: exhaust, maxDistance: settings.maxDistance) else {
                    continue
                }
                let name = "\(vessel.parts[p].name) \(thruster.name)", nozzle = part.shapes[n]
                let bell = Self.bell(nozzle: n, linked: linked, part: part, baked: baked.parts[p])
                XCTAssertGreaterThan(abs(bell.facing), 0.5, "\(name): a bell, its sides facing in and out")
                XCTAssertGreaterThan(bell.inside.area, 0, name)
                if thruster.groups.contains(.main) {
                    mains.append(thruster.name)
                    mainBells.add(bell)
                    XCTAssertLessThan(bell.inside.mean, bell.outside.mean, name)
                }
                if nozzle.twoSided { twoSided.add(bell) }

                // Reciprocity, within the rays' noise and their start 1 mm
                // off the wall (a 7 cm RCS exit is 1.4 % wider seen from
                // there), and the exit's facets (64 of them make 0.2 % less
                // than π r²).
                let size = try XCTUnwrap(Self.openings(nozzle), name)
                if size.chord < settings.maxDistance {
                    spanned += 1
                    XCTAssertLessThanOrEqual(bell.inside.mean, (size.exit + size.far) / bell.inside.area + 0.02, name)
                }
                let pastExit = {
                    zip(geometry.parts, raw).contains { part, meshes in
                        meshes.contains { mesh in
                            mesh.vertices.contains { ($0.position + part.offset - centre).dot(exhaust) > 1e-6 }
                        }
                    }
                }
                if size.far == 0 && !pastExit() {
                    closedAtTheBottom.insert(thruster.name)
                    XCTAssertGreaterThanOrEqual(bell.inside.mean, size.exit / bell.inside.area - 0.01, name)
                }
            }
        }
        print(String(format: "Bells in the open: main engines inside %.3f, outside %.3f; "
                     + "two-sided inside %.3f, outside %.3f", mainBells.inside.mean, mainBells.outside.mean,
                     twoSided.inside.mean, twoSided.outside.mean))
        let sIC = vessel.parts.first { $0.name == "S-IC" }!.thrusters.filter { $0.groups.contains(.main) }
        XCTAssertEqual(mains, sIC.map(\.name), "the main engines in the open")
        XCTAssertTrue(Set(sIC.map(\.name)).isSubset(of: closedAtTheBottom),
                      "the F-1s close at their injectors, at the bottom of the stack")
        XCTAssertGreaterThan(spanned, 0)
        XCTAssertGreaterThan(twoSided.inside.area, 0)
        XCTAssertLessThan(twoSided.inside.mean, twoSided.outside.mean, "two-sided bells in the open")
    }

    /// Area-weighted AO.
    struct Faces {
        var sum = 0.0, area = 0.0
        var mean: Double { sum / area }

        mutating func add(_ value: Float, area a: Double) {
            sum += Double(value) * a
            area += a
        }

        mutating func add(_ other: Faces) {
            sum += other.sum
            area += other.area
        }
    }

    /// A bell's inside and outside, or several bells' pooled, and how its
    /// nozzle's front faces: the area-weighted mean cosine between its
    /// normals and the outward radial (-1 all in, 1 all out).
    struct Bell {
        var inside = Faces(), outside = Faces(), facing = 0.0

        mutating func add(_ bell: Bell) {
            inside.add(bell.inside)
            outside.add(bell.outside)
        }
    }

    /// The bell of nozzle `n`, a shape of `part`, among its thruster's
    /// `linked` shapes: inside, the nozzle's side that faces its axis;
    /// outside, its other side if it is two-sided and the outward faces of
    /// the other linked shapes about the same axis. Each vertex weighs a
    /// third of its triangles' area.
    static func bell(nozzle n: Int, linked: [Int], part: VesselGeometry.Part,
                     baked: BakedAmbientOcclusion.Part) -> Bell {
        let nozzle = part.shapes[n]
        func radial(_ x: Vec3) -> Vec3 {
            let d = x - nozzle.origin
            return d - nozzle.axis * d.dot(nozzle.axis)
        }
        func weights(_ mesh: VisualShape.Mesh) -> [Double] {
            var area = [Double](repeating: 0, count: mesh.vertices.count)
            for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
                let i = Int(mesh.indices[t]), j = Int(mesh.indices[t + 1]), k = Int(mesh.indices[t + 2])
                let a = mesh.vertices[i].position, b = mesh.vertices[j].position, c = mesh.vertices[k].position
                let third = (b - a).cross(c - a).length / 6
                area[i] += third
                area[j] += third
                area[k] += third
            }
            return area
        }
        var bell = Bell()
        // The nozzle: which side faces the axis.
        let values = baked.shapes[n], area = weights(values.mesh)
        var cosine = 0.0, total = 0.0
        for (i, v) in values.mesh.vertices.enumerated() {
            let r = radial(v.position)
            guard r.length > 1e-9 else { continue }
            cosine += area[i] * v.normal.dot(r) / r.length
            total += area[i]
        }
        bell.facing = cosine / total
        let (inside, outside) = bell.facing < 0 ? (values.front, values.back) : (values.back, values.front)
        for i in area.indices {
            if !inside.isEmpty { bell.inside.add(inside[i], area: area[i]) }
            if !outside.isEmpty { bell.outside.add(outside[i], area: area[i]) }
        }
        // The other linked shapes about its axis: their outward faces.
        for s in linked where s != n {
            let shape = part.shapes[s]
            guard shape.axis.cross(nozzle.axis).length < 1e-9, radial(shape.origin).length < 1e-6 else { continue }
            let values = baked.shapes[s], area = weights(values.mesh)
            for (i, v) in values.mesh.vertices.enumerated() {
                let r = radial(v.position)
                guard r.length > 1e-9 else { continue }
                let out = v.normal.dot(r)
                if out > 0 { bell.outside.add(values.front[i], area: area[i]) }
                if out < 0 && !values.back.isEmpty { bell.outside.add(values.back[i], area: area[i]) }
            }
        }
        return bell
    }

    /// A nozzle's openings and size: the area of its exit, of its far end
    /// when that is open (m²), and the longest chord across it (m).
    static func openings(_ s: VisualShape) -> (exit: Double, far: Double, chord: Double)? {
        guard !s.capBase else { return nil }
        switch s.kind {
        case let .revolution(profile, _, _):
            guard let first = profile.first, let last = profile.last else { return nil }
            let x = profile.map(\.x), r = profile.map(\.r).max() ?? 0
            let depth = (x.max() ?? 0) - (x.min() ?? 0)
            return (Double.pi * first.r * first.r, s.capTop ? 0 : Double.pi * last.r * last.r,
                    (depth * depth + 4 * r * r).squareRoot())
        case let .frustum(base, top):
            let r = max(base, top)
            return (Double.pi * base * base, s.capTop ? 0 : Double.pi * top * top,
                    (s.length * s.length + 4 * r * r).squareRoot())
        default:
            return nil
        }
    }
}

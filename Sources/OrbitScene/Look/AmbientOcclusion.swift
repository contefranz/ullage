import Foundation
import OrbitCore

/// Baked per-vertex ambient occlusion for vessels (track R5).
///
/// - Facets are first subdivided until no edge is longer than
///   `AmbientOcclusionSettings.maxEdge` (`subdivide`), so that long panels
///   carry enough vertices.
/// - From each vertex, `raysPerVertex` cosine-weighted rays go out to
///   `maxDistance` against a `TriangleBVH` over all the vessel's meshes. The
///   vertex's AO is the fraction that hit nothing: 1 in the open, 0 when
///   enclosed. For a cosine-weighted pattern that fraction estimates the
///   view factor from the vertex to the open sky.
/// - Two-sided shapes (bells, interstages, panels) get a second value for
///   their back face, from rays about the reversed normal.
/// - Vertices at one point with one normal (seams, a cap's centre) are
///   welded and share one value, so seams do not show.
/// - Every vertex's rays come from one stratified pattern (Hammersley),
///   shifted per vertex from `seed`: one seed gives one result whatever the
///   number of threads.
///
/// `bake(_:settings:)` bakes a vessel synchronously, spread over the cores
/// with `DispatchQueue.concurrentPerform`; `AmbientOcclusionBaker` runs it in
/// the background once per mesh signature, caches the result and gives the
/// renderer a fade-in value.
///
/// **The hook for the vessel pass (R2).** For each part and shape of
/// `VesselGeometry`, `BakedAmbientOcclusion.Shape` carries the shape's
/// subdivided mesh (part frame, as `VisualShape.mesh()`) and, per vertex of
/// it, `front` (and `back` for a two-sided shape). `packed(vertex:)` puts
/// both in one Float for vertex v2's position.w; a shader unpacks it with
///
///     float back  = floor(w * (1.0 / 1024.0));
///     float front = w - back * 1024.0;
///     float ao    = (frontFacing ? front : back) * (1.0 / 1023.0);
///     ao          = mix(1.0, ao, fade);   // AmbientOcclusionBaker.Lookup.fade
///
/// and multiplies the indirect light (IBL, earthshine, sky) by it, not the
/// Sun's. Until a bake is ready, `AmbientOcclusion.unoccluded` stands in.
public enum AmbientOcclusion {
    /// Rays start this far off the surface (m), along the vertex's normal.
    static let surfaceOffset = 1e-3
    /// ... and at most this far (m) towards the middle of its facets, so a
    /// vertex in a corner does not start its rays on the neighbouring face.
    static let inwardOffset = 5e-4
    /// Vertices closer than this (m) with normals within about 2.5° are one.
    static let weldTolerance = 1e-6
    static let weldNormalCosine = 0.999

    // MARK: Packing

    /// The levels each side is stored in.
    static let levels: Float = 1023

    /// `front` and `back` (0...1) in one Float, exactly: an integer below
    /// 2^20, the back face's level times 1024 plus the front's. See the
    /// type's notes for the shader's side.
    public static func pack(front: Float, back: Float) -> Float {
        let f = (min(max(front, 0), 1) * levels).rounded()
        let b = (min(max(back, 0), 1) * levels).rounded()
        return b * 1024 + f
    }

    public static func unpack(_ w: Float) -> (front: Float, back: Float) {
        let b = (w / 1024).rounded(.down)
        return ((w - b * 1024) / levels, b / levels)
    }

    /// The packed value of an unoccluded vertex, for meshes not yet baked.
    public static let unoccluded = pack(front: 1, back: 1)

    // MARK: Subdivision

    /// `mesh` with every edge longer than `maxEdge` (m) bisected, again and
    /// again, until none is: each triangle is split across its longest edge
    /// at its midpoint. An edge is split if and only if it is longer than
    /// `maxEdge`, always at its midpoint, so the triangles on both sides of
    /// an edge (and coincident edges of other vertices: creases, facets) end
    /// with the same points along it, and the mesh has no T-junctions. New
    /// vertices interpolate their edge's linearly (position, surface
    /// coordinates) and normalised (normal, tangent), as the rasteriser
    /// would: the subdivided mesh draws as the original. The original
    /// vertices keep their indices; the new ones follow.
    public static func subdivide(_ mesh: VisualShape.Mesh, maxEdge: Double) -> VisualShape.Mesh {
        guard maxEdge > 0, maxEdge.isFinite else { return mesh }
        let limit = maxEdge * maxEdge
        var out = VisualShape.Mesh()
        out.vertices = mesh.vertices
        out.indices.reserveCapacity(mesh.indices.count)
        var midpoints: [UInt64: UInt32] = [:]

        func midpoint(_ i: UInt32, _ j: UInt32) -> UInt32 {
            let (lo, hi) = i < j ? (i, j) : (j, i)
            let key = UInt64(lo) << 32 | UInt64(hi)
            if let m = midpoints[key] { return m }
            let a = out.vertices[Int(lo)], b = out.vertices[Int(hi)]
            var v = a
            v.position = (a.position + b.position) * 0.5
            let n = a.normal + b.normal
            v.normal = n.length > 1e-12 ? n.normalized : a.normal
            var t = a.tangent + b.tangent
            t = t - v.normal * v.normal.dot(t)
            v.tangent = t.length > 1e-12 ? t.normalized : perpendicular(to: v.normal)
            let sa = a.surface, sb = b.surface
            v.surface = VisualShape.SurfaceCoordinates(u: 0.5 * (sa.u + sb.u), v: 0.5 * (sa.v + sb.v),
                                                       r: 0.5 * (sa.r + sb.r), s: 0.5 * (sa.s + sb.s))
            let m = UInt32(out.vertices.count)
            out.vertices.append(v)
            midpoints[key] = m
            return m
        }

        // Longest-edge bisection only ever shortens a triangle's longest
        // edge; the depth limit is a guard against degenerate input.
        let maxDepth = 64
        var work: [(UInt32, UInt32, UInt32, Int)] = []
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            work.append((mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2], 0))
            while let item = work.popLast() {
                let (a, b, c, depth) = item
                let pa = out.vertices[Int(a)].position, pb = out.vertices[Int(b)].position
                let pc = out.vertices[Int(c)].position
                let ab = (pb - pa).lengthSquared, bc = (pc - pb).lengthSquared, ca = (pa - pc).lengthSquared
                guard max(ab, max(bc, ca)) > limit, depth < maxDepth else {
                    out.indices += [a, b, c]
                    continue
                }
                // (x, y) the longest edge, z opposite, in the same winding.
                let (x, y, z) = ab >= bc && ab >= ca ? (a, b, c) : (bc >= ca ? (b, c, a) : (c, a, b))
                let m = midpoint(x, y)
                work.append((m, y, z, depth + 1))
                work.append((x, m, z, depth + 1))
            }
        }
        return out
    }

    static func perpendicular(to n: Vec3) -> Vec3 {
        let helper = abs(n.x) < 0.9 ? Vec3.unitX : Vec3.unitY
        return n.cross(helper).normalized
    }

    // MARK: Baking surfaces

    /// A mesh to bake, placed at `offset` (m) in the frame of the bake; its
    /// back face gets a value too if it is `twoSided`.
    public struct Surface {
        public var mesh: VisualShape.Mesh
        public var offset: Vec3
        public var twoSided: Bool

        public init(mesh: VisualShape.Mesh, offset: Vec3 = .zero, twoSided: Bool = false) {
            self.mesh = mesh
            self.offset = offset
            self.twoSided = twoSided
        }
    }

    /// A surface's AO, per vertex of its mesh: `front` on the side its
    /// normals point to, `back` on the other for a two-sided surface (empty
    /// otherwise). 1 is unoccluded.
    public struct Values: Equatable {
        public var front: [Float]
        public var back: [Float]
    }

    /// The AO of `surfaces`, occluded by one another, as they are (no
    /// subdivision).
    public static func bake(_ surfaces: [Surface], settings: AmbientOcclusionSettings) -> [Values] {
        bake(surfaces, occluders: occluders(surfaces), settings: settings)
    }

    /// A tree over the triangles of `surfaces`, placed.
    public static func occluders(_ surfaces: [Surface]) -> TriangleBVH {
        var positions: [Vec3] = [], indices: [UInt32] = []
        for s in surfaces {
            let base = UInt32(positions.count)
            positions += s.mesh.vertices.map { $0.position + s.offset }
            indices += s.mesh.indices.map { $0 + base }
        }
        return TriangleBVH(positions: positions, indices: indices)
    }

    /// The AO of `surfaces` against `occluders`; `chunk` vertices go to each
    /// concurrent iteration (the result does not depend on it).
    public static func bake(_ surfaces: [Surface], occluders: TriangleBVH,
                            settings: AmbientOcclusionSettings, chunk: Int = 64) -> [Values] {
        let receivers = Receivers(surfaces)
        let count = receivers.position.count
        var front = [Float](repeating: 1, count: count), back = front
        let pattern = RayPattern(rays: settings.raysPerVertex, maxDistance: settings.maxDistance)
        let chunk = max(1, chunk)
        let iterations = (count + chunk - 1) / chunk
        if pattern.rays > 0 && iterations > 0 {
            front.withUnsafeMutableBufferPointer { f in
                back.withUnsafeMutableBufferPointer { b in
                    DispatchQueue.concurrentPerform(iterations: iterations) { k in
                        occluders.withTraversal { traversal in
                            for g in (k * chunk)..<min(count, (k + 1) * chunk) {
                                let ray = receivers.rays(g)
                                f[g] = pattern.open(from: ray.front, about: ray.axis,
                                                    stream: stream(settings.seed, g, 0), traversal)
                                if receivers.twoSided[g] {
                                    b[g] = pattern.open(from: ray.back, about: -ray.axis,
                                                        stream: stream(settings.seed, g, 1), traversal)
                                }
                            }
                        }
                    }
                }
            }
        }
        return surfaces.indices.map { s in
            let groups = receivers.group[s]
            return Values(front: groups.map { front[Int($0)] },
                          back: surfaces[s].twoSided ? groups.map { back[Int($0)] } : [])
        }
    }

    /// The unoccluded fraction at `point` (placed off any surface; rays
    /// start there) about `normal`, against `occluders`; `stream` picks the
    /// pattern's shift.
    public static func occlusion(at point: Vec3, normal: Vec3, occluders: TriangleBVH,
                                 settings: AmbientOcclusionSettings, stream index: UInt64 = 0) -> Double {
        let pattern = RayPattern(rays: settings.raysPerVertex, maxDistance: settings.maxDistance)
        guard pattern.rays > 0 else { return 1 }
        return Double(occluders.withTraversal {
            pattern.open(from: point, about: normal.normalized, stream: stream(settings.seed, Int(index), 0), $0)
        })
    }

    /// The random stream of vertex group `g`'s side `side`.
    static func stream(_ seed: UInt64, _ g: Int, _ side: UInt64) -> UInt64 {
        seed &+ (UInt64(g) &* 2 &+ side) &* 0x9E37_79B9_7F4A_7C15
    }

    /// The vertices of a bake, welded into groups: per group, where its rays
    /// start and the axis they spread about.
    struct Receivers {
        /// Per surface, per vertex: its group.
        var group: [[Int32]] = []
        /// Per group: the first member's position and normal (placed).
        var position: [Vec3] = []
        var normal: [Vec3] = []
        /// Per group: the sum of its facets' area vectors and of their
        /// centroids, and how many.
        var facets: [Vec3] = []
        var centroids: [Vec3] = []
        var facetCount: [Int] = []
        var twoSided: [Bool] = []

        struct Cell: Hashable {
            let x: Int64, y: Int64, z: Int64
        }

        init(_ surfaces: [Surface]) {
            let tolerance = AmbientOcclusion.weldTolerance, size = 100 * tolerance
            var cells: [Cell: [Int32]] = [:]
            func cellIndices(_ x: Double) -> ClosedRange<Int64> {
                Int64(((x - tolerance) / size).rounded(.down))...Int64(((x + tolerance) / size).rounded(.down))
            }
            for s in surfaces {
                var groups: [Int32] = []
                groups.reserveCapacity(s.mesh.vertices.count)
                for v in s.mesh.vertices {
                    let p = v.position + s.offset
                    var found: Int32?
                    search: for x in cellIndices(p.x) {
                        for y in cellIndices(p.y) {
                            for z in cellIndices(p.z) {
                                for g in cells[Cell(x: x, y: y, z: z)] ?? [] {
                                    let i = Int(g)
                                    let close = (position[i] - p).lengthSquared <= tolerance * tolerance
                                    if close && normal[i].dot(v.normal) >= AmbientOcclusion.weldNormalCosine {
                                        found = g
                                        break search
                                    }
                                }
                            }
                        }
                    }
                    if let found {
                        groups.append(found)
                        if s.twoSided { twoSided[Int(found)] = true }
                        continue
                    }
                    let g = Int32(position.count)
                    let key = Cell(x: Int64((p.x / size).rounded(.down)), y: Int64((p.y / size).rounded(.down)),
                                   z: Int64((p.z / size).rounded(.down)))
                    cells[key, default: []].append(g)
                    position.append(p)
                    normal.append(v.normal)
                    twoSided.append(s.twoSided)
                    groups.append(g)
                }
                group.append(groups)
            }
            facets = [Vec3](repeating: .zero, count: position.count)
            centroids = facets
            facetCount = [Int](repeating: 0, count: position.count)
            for (s, surface) in surfaces.enumerated() {
                let indices = surface.mesh.indices, vertices = surface.mesh.vertices
                for t in stride(from: 0, to: indices.count - 2, by: 3) {
                    let i = (Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2]))
                    let a = vertices[i.0].position, b = vertices[i.1].position, c = vertices[i.2].position
                    let area = (b - a).cross(c - a)
                    let centroid = (a + b + c) / 3 + surface.offset
                    for k in [i.0, i.1, i.2] {
                        let g = Int(group[s][k])
                        facets[g] += area
                        centroids[g] += centroid
                        facetCount[g] += 1
                    }
                }
            }
        }

        /// Group `g`'s ray origins, front and back, and the axis of its
        /// front hemisphere: the mean of its facets' normals (a facet's
        /// plane is what a ray must clear), or the vertex normal for a vertex
        /// without facets. The origins sit `surfaceOffset` off the surface
        /// and up to `inwardOffset` towards the middle of the facets, so that
        /// a vertex in a corner does not start on the neighbouring face.
        func rays(_ g: Int) -> (front: Vec3, back: Vec3, axis: Vec3) {
            let n = normal[g], area = facets[g]
            let axis = area.length > 1e-18 && area.dot(n) > 0 ? area.normalized : n
            var inward = Vec3.zero
            if facetCount[g] > 0 {
                var c = centroids[g] / Double(facetCount[g]) - position[g]
                c = c - axis * c.dot(axis)
                let l = c.length
                if l > 1e-12 { inward = c * (min(AmbientOcclusion.inwardOffset, 0.25 * l) / l) }
            }
            let up = axis * AmbientOcclusion.surfaceOffset
            return (position[g] + inward + up, position[g] + inward - up, axis)
        }
    }

    /// The rays' pattern: a Hammersley set of `rays` points mapped to
    /// cosine-weighted directions (Malley's method: uniform on the disc,
    /// lifted to the hemisphere), shifted per vertex (Cranley-Patterson
    /// rotation).
    struct RayPattern {
        let rays: Int
        let maxDistance: Double
        /// Per ray: the radial and the angular coordinate in the unit square.
        let points: [(Double, Double)]

        init(rays: Int, maxDistance: Double) {
            let n = max(0, rays)
            self.rays = n
            self.maxDistance = maxDistance
            points = (0..<n).map { k in ((Double(k) + 0.5) / Double(n), Self.radicalInverse(UInt32(k))) }
        }

        /// Van der Corput's base-2 radical inverse.
        static func radicalInverse(_ k: UInt32) -> Double {
            var bits = k
            bits = (bits << 16) | (bits >> 16)
            bits = ((bits & 0x5555_5555) << 1) | ((bits & 0xAAAA_AAAA) >> 1)
            bits = ((bits & 0x3333_3333) << 2) | ((bits & 0xCCCC_CCCC) >> 2)
            bits = ((bits & 0x0F0F_0F0F) << 4) | ((bits & 0xF0F0_F0F0) >> 4)
            bits = ((bits & 0x00FF_00FF) << 8) | ((bits & 0xFF00_FF00) >> 8)
            return Double(bits) * 0x1p-32
        }

        /// The fraction of the rays from `origin` about the unit `axis` that
        /// hit nothing within `maxDistance`.
        func open(from origin: Vec3, about axis: Vec3, stream: UInt64,
                  _ traversal: TriangleBVH.Traversal) -> Float {
            var rng = SplitMix64(state: stream)
            let shift = (rng.unit(), rng.unit())
            let (t, b) = Self.basis(axis)
            var open = 0
            for (u, v) in points {
                var r2 = u + shift.0, phi = v + shift.1
                r2 -= r2.rounded(.down)
                phi -= phi.rounded(.down)
                phi *= 2 * Double.pi
                let r = r2.squareRoot(), z = (1 - r2).squareRoot()
                let across: Vec3 = t * (r * cos(phi)) + b * (r * sin(phi))
                let d: Vec3 = across + axis * z
                if !traversal.occluded(origin, d, maxDistance) { open += 1 }
            }
            return Float(open) / Float(rays)
        }

        /// Two unit vectors completing `n` to a right-handed frame (Duff et
        /// al. 2017).
        static func basis(_ n: Vec3) -> (Vec3, Vec3) {
            let sign: Double = n.z >= 0 ? 1 : -1
            let a = -1 / (sign + n.z)
            let b = n.x * n.y * a
            let t = Vec3(1 + sign * n.x * n.x * a, sign * b, -sign * n.x)
            return (t, Vec3(b, sign + n.y * n.y * a, -n.y))
        }
    }

    /// Steele, Lea and Flood's SplitMix64.
    struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }
    }

    // MARK: Vessels

    /// `geometry`'s AO, baked now on the calling thread (and the cores, by
    /// `concurrentPerform`): every shape subdivided, then baked against all
    /// the vessel's shapes, nozzles at their null gimbal.
    public static func bake(_ geometry: VesselGeometry,
                            settings: AmbientOcclusionSettings = AmbientOcclusionSettings()) -> BakedAmbientOcclusion {
        let start = DispatchTime.now().uptimeNanoseconds
        var shapes: [(part: Int, shape: VisualShape)] = []
        for (p, part) in geometry.parts.enumerated() {
            shapes += part.shapes.map { (p, $0) }
        }
        var meshes = [VisualShape.Mesh](repeating: VisualShape.Mesh(), count: shapes.count)
        meshes.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: shapes.count) { i in
                out[i] = subdivide(shapes[i].shape.mesh(), maxEdge: settings.maxEdge)
            }
        }
        let surfaces = shapes.indices.map { i in
            Surface(mesh: meshes[i], offset: geometry.parts[shapes[i].part].offset,
                    twoSided: shapes[i].shape.twoSided)
        }
        let values = bake(surfaces, settings: settings)
        var parts = geometry.parts.map { BakedAmbientOcclusion.Part(id: $0.id, offset: $0.offset, shapes: []) }
        for (i, s) in shapes.enumerated() {
            parts[s.part].shapes.append(BakedAmbientOcclusion.Shape(mesh: meshes[i], front: values[i].front,
                                                                    back: values[i].back))
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-9
        return BakedAmbientOcclusion(signature: geometry.signature, settings: settings, parts: parts,
                                     seconds: seconds)
    }
}

/// A vessel's baked AO: per part and shape of its `VesselGeometry`, in the
/// same order, the subdivided mesh the values belong to. See
/// `AmbientOcclusion` for how the vessel pass binds it.
public struct BakedAmbientOcclusion {
    public struct Shape {
        /// The shape's `mesh()` (part frame), subdivided to the settings'
        /// `maxEdge`.
        public let mesh: VisualShape.Mesh
        /// Per vertex of `mesh`: the unoccluded fraction on the side its
        /// normal points to (1 open, 0 enclosed).
        public let front: [Float]
        /// Per vertex, on the other side: for a two-sided shape; empty
        /// otherwise.
        public let back: [Float]

        /// Vertex `i`'s value for the face seen: the back for a two-sided
        /// shape seen from behind, else the front.
        public func occlusion(vertex i: Int, backFace: Bool = false) -> Float {
            backFace && !back.isEmpty ? back[i] : front[i]
        }

        /// Vertex `i`'s front and back in one Float, for position.w
        /// (`AmbientOcclusion.pack`); a one-sided shape repeats its front.
        public func packed(vertex i: Int) -> Float {
            AmbientOcclusion.pack(front: front[i], back: back.isEmpty ? front[i] : back[i])
        }
    }

    public struct Part {
        public let id: ObjectIdentifier
        /// The part's origin in the construction frame (m), as baked.
        public let offset: Vec3
        public var shapes: [Shape]
    }

    public let signature: VesselGeometry.Signature
    public let settings: AmbientOcclusionSettings
    public let parts: [Part]
    /// How long the bake took (s, wall clock).
    public let seconds: Double

    public var vertexCount: Int { parts.reduce(0) { $0 + $1.shapes.reduce(0) { $0 + $1.mesh.vertices.count } } }
    public var triangleCount: Int { parts.reduce(0) { $0 + $1.shapes.reduce(0) { $0 + $1.mesh.triangleCount } } }
}

/// Bakes vessels' AO in the background, once per mesh signature, and keeps
/// the results for the renderer.
///
/// Each frame the renderer asks `lookup(_:now:)` for each vessel it draws.
/// The first ask for a signature queues a bake (one at a time, each spread
/// over the cores) and returns no values; once the bake is done the lookup
/// returns them with a `fade` rising from 0 to 1 over `fadeDuration` of the
/// renderer's clock (`now`), which the shader mixes AO in by. A separation
/// changes the vessel's signature, so the new stack and the stage that left
/// it are baked anew; a signature seen again (the same parts and shapes) is
/// served from the cache, which keeps the `capacity` most recently used.
/// Snapshots that must not depend on timing call `bakeNow`, whose result
/// lookups return at once fully faded in.
///
/// Thread-safe: lookups may come from any thread.
public final class AmbientOcclusionBaker: @unchecked Sendable {
    public struct Lookup {
        /// The vessel's AO, or nil while it is baking (or baking is off).
        public let baked: BakedAmbientOcclusion?
        /// How far AO is faded in, 0...1: draw mix(1, ao, fade).
        public let fade: Double
    }

    /// The cache's key: the signature, with the parts' offsets and the
    /// shapes' placements as a guard against a part's identifier being
    /// reused by a new object after the old one is gone.
    struct Key: Hashable {
        let parts: [ObjectIdentifier]
        let shapes: [Int]
        let placement: [Double]

        init(_ g: VesselGeometry) {
            parts = g.signature.parts
            shapes = g.signature.shapes
            var placement: [Double] = []
            for part in g.parts {
                placement += [part.offset.x, part.offset.y, part.offset.z]
                for s in part.shapes {
                    placement += [s.origin.x, s.origin.y, s.origin.z, s.axis.x, s.axis.y, s.axis.z, s.length]
                }
            }
            self.placement = placement
        }
    }

    struct Entry {
        var baked: BakedAmbientOcclusion?
        /// The renderer's clock when it first got the values.
        var shown: Double?
        var lastUsed: Int
    }

    public let capacity: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "OrbitScene.AmbientOcclusionBaker", qos: .utility)
    private var entries: [Key: Entry] = [:]
    private var _settings: AmbientOcclusionSettings
    /// Bumped when the settings change, so a bake under the old ones is
    /// dropped when it ends.
    private var generation = 0
    private var uses = 0
    private var _bakeCount = 0

    public init(settings: AmbientOcclusionSettings = AmbientOcclusionSettings(), capacity: Int = 32) {
        _settings = settings
        self.capacity = max(1, capacity)
    }

    /// Changing the settings empties the cache.
    public var settings: AmbientOcclusionSettings {
        get { locked { _settings } }
        set {
            locked {
                guard newValue != _settings else { return }
                _settings = newValue
                generation += 1
                entries = [:]
            }
        }
    }

    /// Bakes finished so far (the cache's misses).
    public var bakeCount: Int { locked { _bakeCount } }

    /// Signatures cached or baking.
    public var count: Int { locked { entries.count } }

    /// `geometry`'s AO if it is baked, with its fade at `now` (s, the
    /// renderer's clock); otherwise nil, and a bake is queued if none is.
    public func lookup(_ geometry: VesselGeometry, now: Double) -> Lookup {
        let key = Key(geometry)
        lock.lock()
        defer { lock.unlock() }
        guard _settings.enabled else { return Lookup(baked: nil, fade: 0) }
        uses += 1
        if var entry = entries[key] {
            entry.lastUsed = uses
            if entry.baked != nil && entry.shown == nil { entry.shown = now }
            entries[key] = entry
            guard let baked = entry.baked, let shown = entry.shown else { return Lookup(baked: nil, fade: 0) }
            return Lookup(baked: baked, fade: fade(since: shown, now: now))
        }
        entries[key] = Entry(baked: nil, shown: nil, lastUsed: uses)
        let settings = _settings, generation = self.generation
        queue.async { [weak self] in
            guard let self, self.isWanted(key, generation) else { return }
            let baked = AmbientOcclusion.bake(geometry, settings: settings)
            self.store(baked, key, generation, shown: nil)
        }
        return Lookup(baked: nil, fade: 0)
    }

    /// `geometry`'s AO, baked now on this thread unless it is cached; its
    /// lookups from now on are fully faded in. Nil when baking is off.
    @discardableResult
    public func bakeNow(_ geometry: VesselGeometry) -> BakedAmbientOcclusion? {
        let key = Key(geometry)
        let (settings, generation, cached) = locked { () -> (AmbientOcclusionSettings, Int, BakedAmbientOcclusion?) in
            (_settings, self.generation, entries[key]?.baked)
        }
        guard settings.enabled else { return nil }
        let baked = cached ?? AmbientOcclusion.bake(geometry, settings: settings)
        store(baked, key, generation, shown: -Double.infinity)
        return baked
    }

    /// Waits for the bakes queued so far to end.
    public func waitUntilIdle() {
        queue.sync {}
    }

    /// Empties the cache (a bake under way is dropped when it ends).
    public func removeAll() {
        locked {
            generation += 1
            entries = [:]
        }
    }

    func fade(since shown: Double, now: Double) -> Double {
        let duration = _settings.fadeDuration
        guard duration > 0 else { return 1 }
        return min(max((now - shown) / duration, 0), 1)
    }

    private func isWanted(_ key: Key, _ generation: Int) -> Bool {
        locked { generation == self.generation && entries[key] != nil && entries[key]?.baked == nil }
    }

    private func store(_ baked: BakedAmbientOcclusion, _ key: Key, _ generation: Int, shown: Double?) {
        locked {
            guard generation == self.generation else { return }
            uses += 1
            var entry = entries[key] ?? Entry(baked: nil, shown: nil, lastUsed: uses)
            if entry.baked == nil { _bakeCount += 1 }
            entry.baked = baked
            entry.shown = shown ?? entry.shown
            entry.lastUsed = uses
            entries[key] = entry
            // Drop the least recently used finished bakes over capacity.
            var done = entries.filter { $0.value.baked != nil }
            while done.count > capacity, let oldest = done.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                entries[oldest.key] = nil
                done[oldest.key] = nil
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

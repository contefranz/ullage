import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

// The vessels' geometry on the GPU (track R2): one indexed mesh per part,
// in the part's own frame, built the first time the part is seen and kept
// while it lives, so that a separation rebuilds the vessels' draw lists
// (`VesselMesh`), never their geometry. Vertices are vertex v2
// (ShaderCommon's `VertexV2`).
//
// Ambient occlusion (R5) arrives per vessel, in the background, on meshes
// subdivided for it (`BakedAmbientOcclusion`). The first bake that covers a
// part replaces its mesh by the subdivided one, converted off the main
// thread; every bake gives each part an AO stream, one packed value per
// vertex, which the vertex function decodes (`AmbientOcclusion.unpack`).
// A part keeps the stream of the bake before, which the new one fades in
// over, so a separation does not flash its stages unoccluded.

// MARK: - Materials

/// Vertex v2's material ids: one entry per finish (material key, colour and
/// emissive role) seen, its shading from `MaterialDefaults` (fragment
/// buffer 0). Entry 0 is a grey dielectric for finishes beyond 255.
@MainActor
public final class VesselMaterialTable {
    public static let capacity = 256

    struct Key: Hashable {
        let material: String
        let r: Float, g: Float, b: Float
        let emissive: Int
    }

    let buffer: MTLBuffer
    private var ids: [Key: UInt8] = [:]
    public private(set) var count = 1

    init?(device: MTLDevice) {
        guard let b = device.makeBuffer(length: Self.capacity * MemoryLayout<VesselMaterialGPU>.stride,
                                        options: .storageModeShared) else { return nil }
        buffer = b
        let grey = VesselMaterialGPU(albedo: SIMD4(0.5, 0.5, 0.5, 0), params: SIMD4(0.6, 0.04, 0, 0))
        b.contents().bindMemory(to: VesselMaterialGPU.self, capacity: Self.capacity)[0] = grey
    }

    /// The id of `material` in `color` with `emissive`, added the first
    /// time. Entries only ever append, so frames in flight never see one
    /// change.
    public func id(_ material: MaterialKey, color: (Double, Double, Double), emissive: Int = 0) -> UInt8 {
        let key = Key(material: material.rawValue, r: Float(color.0), g: Float(color.1), b: Float(color.2),
                      emissive: emissive)
        if let id = ids[key] { return id }
        guard count < Self.capacity else { return 0 }
        let e = MaterialDefaults.entry(for: material)
        let entry = VesselMaterialGPU(albedo: SIMD4(key.r, key.g, key.b, Float(e.metalness)),
                                      params: SIMD4(Float(e.roughness), Float(e.reflectance), Float(emissive),
                                                    Float(e.model.rawValue)))
        buffer.contents().bindMemory(to: VesselMaterialGPU.self, capacity: Self.capacity)[count] = entry
        let id = UInt8(count)
        ids[key] = id
        count += 1
        return id
    }

    /// The id of `shape`'s finish.
    public func id(_ shape: VisualShape) -> UInt8 {
        id(shape.material, color: shape.color, emissive: shape.emissive.rawValue)
    }
}

/// VesselShaders' `VesselMaterial`.
struct VesselMaterialGPU {
    var albedo: SIMD4<Float>
    var params: SIMD4<Float>
}

/// VesselShaders' `VesselPaint`: `PaintStandIn`'s colours by id (entry 0 unused).
struct VesselPaintGPU {
    var albedo: SIMD4<Float>
    var params: SIMD4<Float>

    static let count = 16

    static func table() -> [VesselPaintGPU] {
        var out = [VesselPaintGPU](repeating: VesselPaintGPU(albedo: .zero, params: .zero), count: count)
        for c in PaintStandIn.colours {
            let i = Int(PaintStandIn.id(c))
            guard i < count else { continue }
            let s = PaintStandIn.sample(c)
            out[i] = VesselPaintGPU(albedo: SIMD4(s.albedo.r, s.albedo.g, s.albedo.b, s.metalness),
                                    params: SIMD4(s.roughness, 0, 0, 0))
        }
        return out
    }
}

// MARK: - Part meshes

/// A part's (or a site element's) shapes as one indexed mesh, in its own
/// frame, with the draws it needs: closed shapes with back faces culled,
/// open ones from both sides, thin tubes through the wire pipeline, and one
/// draw per shape a gimballed thruster turns.
final class PartMesh {
    struct Draw {
        /// Index range (in indices, not bytes).
        var indices: Range<Int>
        var culled: Bool
        var wire: Bool
        /// The gimballed thruster that turns it, and its position (part frame).
        var thruster: RenderScene.ThrusterKey?
        var pivot: Vec3
    }

    /// A shape's place: how it draws, and its finish's id.
    struct ShapeInfo {
        var culled: Bool
        var wire: Bool
        var thruster: RenderScene.ThrusterKey?
        var pivot: Vec3
        var material: UInt8
    }

    let vertices: MTLBuffer
    let indices: MTLBuffer
    let vertexCount: Int
    let indexCount: Int
    let draws: [Draw]
    /// The shapes in buffer order, and each one's vertex range.
    let order: [Int]
    let shapeVertices: [Range<Int>]
    /// Built from R5's subdivided meshes, which its AO streams follow.
    let isSubdivided: Bool

    init(vertices: MTLBuffer, indices: MTLBuffer, vertexCount: Int, indexCount: Int, draws: [Draw], order: [Int],
         shapeVertices: [Range<Int>], isSubdivided: Bool) {
        self.vertices = vertices
        self.indices = indices
        self.vertexCount = vertexCount
        self.indexCount = indexCount
        self.draws = draws
        self.order = order
        self.shapeVertices = shapeVertices
        self.isSubdivided = isSubdivided
    }

    /// Whether `shape` is a thin tube: a frustum at most 10 cm in radius
    /// and at least eight radii long (the LES truss, struts, booms).
    static func isWire(_ shape: VisualShape) -> Bool {
        guard case let .frustum(base, top) = shape.kind else { return false }
        let r = max(base, top)
        return r > 0 && r <= 0.1 && shape.length >= 8 * r
    }

    /// The order the shapes go in the buffers: static closed, open and
    /// wire shapes, each kind in one draw, then each gimballed shape.
    static func order(_ info: [ShapeInfo]) -> [Int] {
        let staticKinds = info.indices.filter { info[$0].thruster == nil }
        let closed = staticKinds.filter { info[$0].culled && !info[$0].wire }
        let open = staticKinds.filter { !info[$0].culled && !info[$0].wire }
        let wires = staticKinds.filter { info[$0].wire }
        return closed + open + wires + info.indices.filter { info[$0].thruster != nil }
    }

    /// Builds the mesh of `meshes` (part frame, one per shape) with each
    /// vertex's paint id (`paint`, per shape, empty for none). Thread-safe:
    /// it touches no shared state.
    static func build(meshes: [VisualShape.Mesh], info: [ShapeInfo], paint: [[UInt8]], subdivided: Bool,
                      device: MTLDevice) -> PartMesh? {
        let order = order(info)
        var vertices: [VertexV2] = [], indices: [UInt32] = [], ranges = [Range<Int>](repeating: 0..<0, count: info.count)
        var draws: [Draw] = []
        vertices.reserveCapacity(meshes.reduce(0) { $0 + $1.vertices.count })
        indices.reserveCapacity(meshes.reduce(0) { $0 + $1.indices.count })
        for s in order {
            let mesh = meshes[s], base = UInt32(vertices.count), start = indices.count
            let ids = paint[s]
            for (k, v) in mesh.vertices.enumerated() {
                let packed = SurfaceIDs(material: info[s].material, paint: k < ids.count ? ids[k] : 0, decal: 0).packed
                vertices.append(VertexV2(positionAO: SIMD4(v.position, AmbientOcclusion.unoccluded),
                                         normalIDs: SIMD4(v.normal, packed),
                                         tangent: SIMD4(v.tangent, Float(v.tangentSign)),
                                         surface: SIMD4(Float(v.surface.u), Float(v.surface.v), Float(v.surface.r),
                                                        Float(v.surface.s))))
            }
            ranges[s] = Int(base)..<vertices.count
            indices += mesh.indices.map { $0 + base }
            guard indices.count > start else { continue }
            let i = info[s]
            if i.thruster == nil, let last = draws.last, last.thruster == nil, last.culled == i.culled,
               last.wire == i.wire, last.indices.upperBound == start {
                draws[draws.count - 1].indices = last.indices.lowerBound..<indices.count
            } else {
                draws.append(Draw(indices: start..<indices.count, culled: i.culled, wire: i.wire, thruster: i.thruster,
                                  pivot: i.pivot))
            }
        }
        guard !vertices.isEmpty, !indices.isEmpty,
              let vb = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<VertexV2>.stride,
                                         options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
        else { return nil }
        return PartMesh(vertices: vb, indices: ib, vertexCount: vertices.count, indexCount: indices.count, draws: draws,
                        order: order, shapeVertices: ranges, isSubdivided: subdivided)
    }

    /// One packed AO value per vertex of this (subdivided) mesh, from the
    /// bake's part `baked`, nil when the bake's meshes are not this one's.
    func ambientOcclusion(_ baked: BakedAmbientOcclusion.Part, device: MTLDevice) -> MTLBuffer? {
        guard isSubdivided, baked.shapes.count == shapeVertices.count else { return nil }
        var values = [Float](repeating: AmbientOcclusion.unoccluded, count: vertexCount)
        for (s, range) in shapeVertices.enumerated() {
            let shape = baked.shapes[s]
            guard shape.mesh.vertices.count == range.count else { return nil }
            for k in 0..<range.count { values[range.lowerBound + k] = shape.packed(vertex: k) }
        }
        return device.makeBuffer(bytes: values, length: max(values.count, 1) * 4, options: .storageModeShared)
    }
}

/// A part in the cache: its mesh (replaced once by the subdivided one) and
/// its AO streams.
@MainActor
final class PartEntry {
    let key: PartKey
    let part: VesselGeometry.Part
    let info: [PartMesh.ShapeInfo]
    var mesh: PartMesh
    /// The current bake's stream and the one before it, and which bake.
    var aoNow: MTLBuffer?
    var aoBefore: MTLBuffer?
    var aoBake: AOBakeID?
    /// When the current stream arrived (the renderer's clock, s), which its
    /// fade-in counts from.
    var aoArrived = -Double.infinity
    /// A subdivided mesh is being built.
    var refining = false

    init(key: PartKey, part: VesselGeometry.Part, info: [PartMesh.ShapeInfo], mesh: PartMesh) {
        self.key = key
        self.part = part
        self.info = info
        self.mesh = mesh
    }
}

/// Which bake an AO stream came from.
struct AOBakeID: Equatable {
    let signature: VesselGeometry.Signature
    let settings: AmbientOcclusionSettings
}

/// A part's identity in the cache: the object, guarded by what it draws (a
/// new part at a freed part's address is not taken for it).
struct PartKey: Hashable {
    let id: ObjectIdentifier
    let name: String
    let variant: ApolloVariant?
    let shapes: [Double]
    let materials: [String]

    init(_ p: VesselGeometry.Part) {
        id = p.id
        name = p.name
        variant = p.appearance
        var shapes: [Double] = []
        for s in p.shapes {
            shapes += [s.origin.x, s.origin.y, s.origin.z, s.axis.x, s.axis.y, s.axis.z, s.length,
                       s.color.0, s.color.1, s.color.2, s.twoSided ? 1 : 0]
        }
        self.shapes = shapes
        materials = p.shapes.map(\.material.rawValue)
    }
}

/// A vessel's draw list: its parts' cached meshes and where each sits in
/// the construction frame.
public struct VesselMesh {
    public let signature: VesselGeometry.Signature
    let parts: [PartEntry]
    let offsets: [Vec3]
}

/// The vessels' meshes: parts kept while they live, draw lists rebuilt
/// when a vessel's parts change (`VesselGeometry.Signature`).
@MainActor
public final class VesselMeshCache {
    private var meshes: [UUID: VesselMesh] = [:]
    private var parts: [PartKey: PartEntry] = [:]
    private(set) var materials: VesselMaterialTable?
    private var device: MTLDevice?
    /// Parts built since the cache was made (what a separation must not grow).
    public private(set) var partsBuilt = 0
    /// Subdivided meshes finished off the main thread, waiting to be swapped in.
    private let finished = FinishedMeshes()
    private let queue = DispatchQueue(label: "OrbitRender.VesselMeshCache", qos: .utility)

    public init() {}

    public func mesh(_ id: UUID) -> VesselMesh? { meshes[id] }

    /// The cache's part entries now, for the tests.
    var partCount: Int { parts.count }

    /// Builds the draw lists of new or changed vessels (their parts' meshes
    /// only for parts not seen before) and drops those of vessels and parts
    /// gone. Swaps in the subdivided meshes finished since.
    func update(_ scene: RenderScene, device: MTLDevice) {
        if self.device == nil {
            self.device = device
            materials = VesselMaterialTable(device: device)
        }
        for (entry, mesh) in finished.drain() where !entry.mesh.isSubdivided {
            entry.mesh = mesh
            entry.refining = false
        }
        var live = Set<UUID>(), changed = false
        for v in scene.vessels {
            live.insert(v.id)
            if meshes[v.id]?.signature != v.geometry.signature {
                meshes[v.id] = drawList(v.geometry, device: device)
                changed = true
            }
        }
        if meshes.keys.contains(where: { !live.contains($0) }) {
            meshes = meshes.filter { live.contains($0.key) }
            changed = true
        }
        if changed {
            var used = Set<PartKey>()
            for m in meshes.values { for p in m.parts { used.insert(p.key) } }
            parts = parts.filter { used.contains($0.key) }
        }
    }

    private func drawList(_ g: VesselGeometry, device: MTLDevice) -> VesselMesh? {
        var entries: [PartEntry] = [], offsets: [Vec3] = []
        for part in g.parts {
            let key = PartKey(part)
            if let e = parts[key] {
                entries.append(e)
                offsets.append(part.offset)
                continue
            }
            guard let e = build(part, key: key, device: device) else { continue }
            parts[key] = e
            entries.append(e)
            offsets.append(part.offset)
        }
        guard !entries.isEmpty else { return nil }
        return VesselMesh(signature: g.signature, parts: entries, offsets: offsets)
    }

    /// The part's shapes as they are tessellated (`VisualShape.mesh()`).
    private func build(_ part: VesselGeometry.Part, key: PartKey, device: MTLDevice) -> PartEntry? {
        guard let materials else { return nil }
        let info = part.shapes.map { s -> PartMesh.ShapeInfo in
            let mount = s.thruster.flatMap { name in part.thrusters.first { $0.name == name } }
            let gimbal = mount.flatMap { $0.isGimballed ? $0 : nil }
            return PartMesh.ShapeInfo(culled: !s.twoSided, wire: PartMesh.isWire(s), thruster: gimbal?.key,
                                      pivot: gimbal?.position ?? .zero, material: materials.id(s))
        }
        let meshes = part.shapes.map { $0.mesh() }
        let paint = Self.paint(part, meshes: meshes)
        guard let mesh = PartMesh.build(meshes: meshes, info: info, paint: paint, subdivided: false, device: device)
        else { return nil }
        partsBuilt += 1
        return PartEntry(key: key, part: part, info: info, mesh: mesh)
    }

    /// Each vertex's paint id from VM1's evaluator, per shape.
    nonisolated static func paint(_ part: VesselGeometry.Part, meshes: [VisualShape.Mesh]) -> [[UInt8]] {
        let variant = part.appearance ?? .apollo11
        return zip(part.shapes, meshes).map { shape, mesh in
            PaintStandIn.ids(part: part.name, shape: shape, mesh: mesh, partOffset: part.offset, variant: variant)
        }
    }

    // MARK: Ambient occlusion

    /// Gives the parts of `mesh` the streams of `baked`, `mesh`'s vessel's
    /// bake, arriving at `now` (the renderer's clock, s). A part still on
    /// its first mesh is refined first from the bake's subdivided meshes:
    /// off the main thread (it draws its old stream until then), or now
    /// when `synchronously` (snapshots), its stream then fully faded in.
    func apply(_ baked: BakedAmbientOcclusion, to mesh: VesselMesh, now: Double, synchronously: Bool = false) {
        guard let device else { return }
        let id = AOBakeID(signature: baked.signature, settings: baked.settings)
        let bakedParts = Dictionary(baked.parts.map { ($0.id, $0) }) { a, _ in a }
        for entry in mesh.parts {
            guard entry.aoBake != id, let bakedPart = bakedParts[entry.part.id] else { continue }
            if !entry.mesh.isSubdivided {
                let part = entry.part, info = entry.info, meshes = bakedPart.shapes.map(\.mesh)
                if synchronously {
                    guard let m = PartMesh.build(meshes: meshes, info: info, paint: Self.paint(part, meshes: meshes),
                                                 subdivided: true, device: device) else { continue }
                    entry.mesh = m
                    entry.refining = false
                } else {
                    guard !entry.refining else { continue }
                    entry.refining = true
                    let job = RefineJob(entry: entry, part: part, info: info, meshes: meshes, device: device,
                                        finished: finished)
                    queue.async { job.run() }
                    continue
                }
            }
            guard let stream = entry.mesh.ambientOcclusion(bakedPart, device: device) else { continue }
            entry.aoBefore = entry.aoNow
            entry.aoNow = stream
            entry.aoBake = id
            entry.aoArrived = synchronously ? -Double.infinity : now
        }
    }
}

/// A part's subdivided mesh to build off the main thread. Its values are
/// copies the main thread no longer touches; the device is thread-safe.
struct RefineJob: @unchecked Sendable {
    let entry: PartEntry
    let part: VesselGeometry.Part
    let info: [PartMesh.ShapeInfo]
    let meshes: [VisualShape.Mesh]
    let device: MTLDevice
    let finished: FinishedMeshes

    func run() {
        let paint = VesselMeshCache.paint(part, meshes: meshes)
        if let m = PartMesh.build(meshes: meshes, info: info, paint: paint, subdivided: true, device: device) {
            finished.add(entry, m)
        }
    }
}

/// Meshes built off the main thread, handed back to it.
final class FinishedMeshes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(PartEntry, PartMesh)] = []

    func add(_ entry: PartEntry, _ mesh: PartMesh) {
        lock.withLock { items.append((entry, mesh)) }
    }

    func drain() -> [(PartEntry, PartMesh)] {
        lock.withLock {
            defer { items = [] }
            return items
        }
    }
}

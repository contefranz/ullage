import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The Sun's shadow maps (P0): the detail map about the camera target, one
/// per vessel cluster and one per site, as `ShadowFitting.plan` fits them.
///
/// - **The atlas**: a depth16Unorm 2D array, a layer per map
///   (`Binding.shadowAtlas`), each drawn in a render pass of its own: only
///   the layers in use are cleared and stored, each with the GPU's fast
///   clear: about 0.06 ms a 4096² layer on an M3 Pro. (One layered pass
///   over the array's slices loses the fast clear: 0.5-0.6 ms for two.)
/// - **Its memory**: 32 MB a 4096² layer; the atlas grows to the most
///   layers a frame has used and keeps them. The detail map, 2048² at High,
///   fills a corner of its layer (`shadowMaps[i].w`, its share of the side).
/// - **Casters**: the vessels' parts as the vessel pass places them, with
///   their gimballed nozzles, as positions alone from each part's own mesh
///   (`CasterMesh`, not R5's subdivided one), and the sites' elements as the
///   countdown moves them (`SiteMeshes`). Open shapes are drawn two-sided;
///   a closed shape's faces turned from the Sun are culled, which changes
///   no depth (its Sun-side faces are nearer) and halves the pad's fill.
///   Depth is clamped, so casters nearer the Sun than a map still cast.
/// - It fills the shadow members of `LightingUniforms`, which ShadowCommon's
///   `orbit_sunShadow` reads.
/// - Redrawn every frame, so no warp makes the shadows stale.
///
/// Track R4 owns this pass.
@MainActor
public final class ShadowPass: RenderPass {
    public let name = "Shadows"
    public let stage = PassStage.prepare
    public let order = 20
    public var writes: Set<ResourceID> { [.shadowAtlas] }

    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var atlas: MTLTexture?
    /// Each vessel's casters, by its mesh's signature, and each part's,
    /// made from the part's mesh when the pass first sees it.
    private var vesselCasters: [UUID: VesselCaster] = [:]
    private var partCasters: [ObjectIdentifier: PartCaster] = [:]
    /// This frame's maps, in the order of the atlas's layers; the debug
    /// view tints by their level.
    public private(set) var maps: [ShadowMapFit] = []
    /// This frame's atlas and its uniforms, once encoded (for the look
    /// metrics' probe).
    public private(set) var lastAtlas: MTLTexture?
    public private(set) var lastLighting = LightingUniforms()

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.shadow)
        guard let vertex = library.makeFunction(name: "shadow_caster_vertex") else {
            throw ShaderLibrary.Failure.missingFunction("shadow_caster_vertex")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "Shadow casters"
        d.vertexFunction = vertex
        d.depthAttachmentPixelFormat = .depth16Unorm
        pipeline = try s.device.makeRenderPipelineState(descriptor: d)
        let z = MTLDepthStencilDescriptor()
        z.depthCompareFunction = .greaterEqual
        z.isDepthWriteEnabled = true
        depthState = s.device.makeDepthStencilState(descriptor: z)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        maps = []
        lastAtlas = nil
        f.lighting.shadowParams = .zero
        let settings = f.settings.shadow
        guard settings.enabled, let pipeline, let depthState else { return }
        let scene = f.scene
        let sites = scene.sites.isEmpty ? nil : SiteMeshes.shared(f.device)

        // The casters: each vessel with a mesh, each site.
        var casters: [ShadowCaster] = []
        var draws: [Caster] = []
        for v in scene.vessels {
            guard let mesh = f.meshes.mesh(v.id), let caster = vesselCaster(v, mesh, device: f.device) else { continue }
            casters.append(ShadowCaster(kind: .vessel(v.id),
                                        centre: v.position + v.attitude.rotate(v.structureOrigin + caster.centre),
                                        radius: caster.radius))
            draws.append(.vessel(v, caster))
        }
        if vesselCasters.count > scene.vessels.count + 16 {
            let live = Set(scene.vessels.map(\.id))
            vesselCasters = vesselCasters.filter { live.contains($0.key) }
            partCasters = partCasters.filter { $0.value.part != nil }
        }
        if let sites {
            let countdown = SiteMeshes.countdown(at: scene.clock.simTime)
            let rangeTime = countdown.rangeTime(at: scene.clock.simTime)
            for site in scene.sites where site.name == SiteMeshes.name {
                casters.append(ShadowCaster(kind: .site(site.name), centre: site.origin + site.orientation * sites.centre,
                                            radius: sites.radius))
                draws.append(.site(site, sites, rangeTime, countdown))
            }
        }
        var target: ShadowView.Target?
        if case .vessel(let id) = scene.camera.target, let v = scene.vessel(id),
           let i = casters.firstIndex(where: { $0.kind == .vessel(id) }) {
            target = ShadowView.Target(caster: i, point: v.position)
        }
        let view = ShadowView(casters: casters, sun: scene.sun.position, target: target, fovY: scene.camera.fovY,
                              pixelsPerRadian: scene.camera.pixelsPerRadian)
        let size = settings.mapSize
        let plan = ShadowFitting.plan(view, settings: settings)
        guard !plan.isEmpty, let atlas = atlas(layers: plan.count, size: size, device: f.device) else { return }

        // A render pass per map: only the layers in use are cleared and
        // stored, each with the GPU's fast clear. A smaller map (the detail
        // and site maps, 2048² at High) is drawn into a target of its own
        // size and copied into its layer's top-left corner: a render pass
        // costs by its target's size, about 0.2-0.3 ms at 4096² with casters
        // in it against 0.06 ms at 2048², whatever the viewport.
        for (layer, map) in plan.enumerated() {
            let side = min(map.resolution, size)
            var scratch: MTLTexture?
            if side < size {
                let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth16Unorm, width: side, height: side,
                                                                  mipmapped: false)
                sd.usage = .renderTarget
                sd.storageMode = .private
                scratch = f.pool.texture(sd)
            }
            let d = MTLRenderPassDescriptor()
            if let scratch {
                d.depthAttachment.texture = scratch
            } else {
                d.depthAttachment.texture = atlas
                d.depthAttachment.slice = layer
            }
            d.depthAttachment.loadAction = .clear
            d.depthAttachment.clearDepth = 0
            d.depthAttachment.storeAction = .store
            guard let enc = f.makeRenderEncoder(d) else { continue }
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setFrontFacing(.counterClockwise)
            enc.setDepthClipMode(.clamp)
            var one: UInt32 = 1
            enc.setVertexBytes(&one, length: MemoryLayout<UInt32>.size, index: 2)
            for j in map.casters { draws[j].draw(into: enc, map: map) }
            enc.endEncoding()
            if let scratch, let blit = f.makeBlitEncoder() {
                blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: side, height: side, depth: 1), to: atlas, destinationSlice: layer,
                          destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
        }

        var matrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: LightingUniforms.maxShadowMaps)
        var infos = [SIMD4<Float>](repeating: .zero, count: LightingUniforms.maxShadowMaps)
        for (i, map) in plan.enumerated() {
            matrices[i] = simd_float4x4(rowMajor: map.matrix)
            // w: the share of its layer's side the map fills, from the top left.
            infos[i] = SIMD4(Float(i), Float(map.texel), Float(map.depthRange),
                             Float(min(map.resolution, size)) / Float(size))
        }
        f.lighting.shadowMatrices = (matrices[0], matrices[1], matrices[2], matrices[3])
        f.lighting.shadowMaps = (infos[0], infos[1], infos[2], infos[3])
        f.lighting.shadowParams = SIMD4(Float(plan.count), Float(settings.filterSamples), Float(settings.normalOffset),
                                        Float(settings.slopeBias))
        f.slotTextures[Binding.shadowAtlas] = atlas
        f.textures[.shadowAtlas] = atlas
        maps = plan
        lastAtlas = atlas
        lastLighting = f.lighting
    }

    /// The atlas with at least `layers` layers of `size`², kept from frame
    /// to frame (it only grows): 32 MB a layer at 4096².
    private func atlas(layers: Int, size: Int, device: MTLDevice) -> MTLTexture? {
        if let atlas, atlas.width == size, atlas.arrayLength >= layers { return atlas }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .depth16Unorm
        d.width = size
        d.height = size
        d.arrayLength = max(layers, atlas?.width == size ? atlas!.arrayLength : 0)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        atlas = device.makeTexture(descriptor: d)
        atlas?.label = "Shadow atlas"
        return atlas
    }

    /// The vessel's casters, made once per mesh signature.
    private func vesselCaster(_ v: RenderScene.Vessel, _ mesh: VesselMesh, device: MTLDevice) -> VesselCaster? {
        if let c = vesselCasters[v.id], c.signature == mesh.signature { return c }
        let c = VesselCaster(mesh) { partCaster($0, device: device) }
        vesselCasters[v.id] = c
        return c
    }

    /// A part's caster, from its mesh as first seen (a part is shared by
    /// the vessels whose parts are alike, and outlives separations).
    private func partCaster(_ entry: PartEntry, device: MTLDevice) -> CasterMesh? {
        let key = ObjectIdentifier(entry)
        if let c = partCasters[key], c.part === entry { return c.mesh }
        guard let mesh = CasterMesh(entry.mesh, device: device) else { return nil }
        partCasters[key] = PartCaster(part: entry, mesh: mesh)
        return mesh
    }

    /// A part's caster, kept while its part lives.
    private final class PartCaster {
        weak var part: PartEntry?
        let mesh: CasterMesh
        init(part: PartEntry, mesh: CasterMesh) {
            self.part = part
            self.mesh = mesh
        }
    }

    /// The triangles the maps draw of the vessel `id`, once a frame has
    /// drawn it (for tests).
    func casterTriangles(of id: UUID) -> Int? {
        vesselCasters[id].map { $0.parts.map(\.mesh.triangleCount).reduce(0, +) }
    }

    /// What a caster draws.
    @MainActor
    private enum Caster {
        case vessel(RenderScene.Vessel, VesselCaster)
        case site(RenderScene.Site, SiteMeshes, Double, LC39A.Countdown)

        /// Draws it into `map`'s layer: closed shapes with the faces turned
        /// from the Sun culled, open ones two-sided.
        func draw(into enc: MTLRenderCommandEncoder, map: ShadowMapFit) {
            func clip(_ rotation: Mat3, _ translation: Vec3) {
                var m = simd_float4x4(rowMajor: map.matrix(rotation: rotation, translation: translation))
                enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            }
            switch self {
            case let .vessel(v, caster):
                for (mesh, offset) in caster.parts {
                    mesh.draw(into: enc, place: {
                        VesselPlacement.frame(v, offset: offset, thruster: $0.thruster, pivot: $0.pivot)
                    }, clip: clip)
                }
            case let .site(site, meshes, t, countdown):
                for element in meshes.elements {
                    let (rotation, translation) = element.placement(in: site, at: t, countdown)
                    // Only the elements that reach the map.
                    let c = translation + rotation * element.mesh.centre - map.centre
                    let reach = map.halfWidth + element.mesh.radius
                    guard abs(map.basis.r0.dot(c)) <= reach, abs(map.basis.r1.dot(c)) <= reach else { continue }
                    element.mesh.draw(into: enc, place: { _ in (rotation, translation) }, clip: clip)
                }
            }
        }
    }
}

/// DebugView.sunShadow (F9): the Sun's visible share from the shadow maps on
/// every surface, grey from umbra to lit, tinted by the map that served it:
/// blue the detail map, white the camera target's cluster, green and amber
/// the others; a face turned from the Sun dark blue, a surface no map holds
/// pale red. Every surface comes from the resolved scene depth, its normal
/// from the depth's slope. Track R4 owns this pass.
@MainActor
public final class ShadowDebugPass: RenderPass {
    public let name = "Sun-shadow view"
    public let stage = PassStage.post
    public let order = 1_001
    public var reads: Set<ResourceID> { [.sceneDepth, .shadowAtlas] }

    private let shadows: ShadowPass
    private var deferred: MTLRenderPipelineState?
    private var always: MTLDepthStencilState?
    private var output = MTLPixelFormat.invalid

    /// The tints, by the level of the map that served a pixel.
    static let detailTint = SIMD4<Float>(0.74, 0.86, 1, 0)
    static let clusterTints = [SIMD4<Float>(1, 1, 1, 0), SIMD4<Float>(0.82, 1, 0.76, 0), SIMD4<Float>(1, 0.9, 0.7, 0)]

    public init(shadows: ShadowPass) {
        self.shadows = shadows
    }

    public func isActive(in f: FrameContext) -> Bool { f.settings.debug.view == .sunShadow }

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.shadow)
        output = s.formats.output
        deferred = try PipelineBuilder.make(library, vertex: "shadow_debug_fullscreen", fragment: "shadow_debug_deferred",
                                            blend: .opaque, color: output, depth: .depth32Float, sampleCount: 1,
                                            device: s.device)
        let z = MTLDepthStencilDescriptor()
        z.depthCompareFunction = .always
        z.isDepthWriteEnabled = true
        always = s.device.makeDepthStencilState(descriptor: z)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard let deferred, let always, let depth = f.textures[.sceneDepth] else { return }
        let zd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: f.size.width,
                                                          height: f.size.height, mipmapped: false)
        zd.usage = .renderTarget
        zd.storageMode = .private
        guard let ownDepth = f.pool.texture(zd) else { return }
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = f.output
        d.colorAttachments[0].loadAction = .dontCare
        d.colorAttachments[0].storeAction = .store
        d.depthAttachment.texture = ownDepth
        d.depthAttachment.loadAction = .clear
        d.depthAttachment.clearDepth = 0
        d.depthAttachment.storeAction = .dontCare
        guard let enc = f.makeRenderEncoder(d) else { return }

        var tints = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 0), count: LightingUniforms.maxShadowMaps)
        var others = 0
        for (i, map) in shadows.maps.enumerated() {
            if map.level == .detail {
                tints[i] = Self.detailTint
            } else {
                tints[i] = Self.clusterTints[min(others, Self.clusterTints.count - 1)]
                others += 1
            }
        }
        enc.setFragmentBytes(&tints, length: MemoryLayout<SIMD4<Float>>.stride * tints.count, index: 0)

        // What the scene drew, from its depth.
        enc.setRenderPipelineState(deferred)
        enc.setDepthStencilState(always)
        enc.setFragmentTexture(depth, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

/// A vessel's part or a site's element as a caster, in its own frame: its
/// positions alone (float4, a quarter of a VertexV2's fetch), the
/// triangles' indices, and its draws: closed shapes with the faces turned
/// from the Sun culled, open ones two-sided, each gimballed shape alone.
@MainActor
final class CasterMesh {
    struct Draw {
        /// Index range (in indices, not bytes).
        var indices: Range<Int>
        var culled: Bool
        /// The gimballed thruster that turns it, and its position (part frame).
        var thruster: RenderScene.ThrusterKey?
        var pivot: Vec3
    }

    let positions: MTLBuffer
    let indices: MTLBuffer
    let draws: [Draw]
    /// A sphere holding every vertex, its own frame (m).
    let centre: Vec3
    let radius: Double

    /// A vessel part's, from its mesh as the vessel pass draws it: the
    /// shapes' own meshes until R5's subdivided one swaps in. Those only
    /// bisect the shapes' edges, so the surface the vessel pass shades
    /// stays the one that casts, at a sixth of the triangles (the Saturn V's
    /// 898k). The indices are the mesh's own buffer.
    init?(_ mesh: PartMesh, device: MTLDevice) {
        let stride = MemoryLayout<VertexV2>.stride / MemoryLayout<SIMD4<Float>>.stride
        let n = mesh.vertexCount
        guard n > 0, mesh.vertices.length >= n * MemoryLayout<VertexV2>.stride else { return nil }
        let source = mesh.vertices.contents().bindMemory(to: SIMD4<Float>.self, capacity: n * stride)
        let points = (0..<n).map { i -> SIMD4<Float> in
            var p = source[i * stride]
            p.w = 1
            return p
        }
        guard let positions = device.makeBuffer(bytes: points, length: n * MemoryLayout<SIMD4<Float>>.stride,
                                                options: .storageModeShared) else { return nil }
        positions.label = "Shadow caster positions"
        self.positions = positions
        indices = mesh.indices
        draws = mesh.draws.map { Draw(indices: $0.indices, culled: $0.culled, thruster: $0.thruster, pivot: $0.pivot) }
        centre = mesh.bounds.centre
        radius = mesh.bounds.radius
    }

    /// A site element's, from its shapes' meshes: the closed shapes first,
    /// then the open ones.
    init?(shapes: [VisualShape], label: String, device: MTLDevice) {
        var points: [SIMD4<Float>] = [], indices: [UInt32] = [], draws: [Draw] = []
        for s in shapes.filter({ !$0.twoSided }) + shapes.filter(\.twoSided) {
            let m = s.mesh(), base = UInt32(points.count), start = indices.count
            points += m.vertices.map { SIMD4(Float($0.position.x), Float($0.position.y), Float($0.position.z), 1) }
            indices += m.indices.map { $0 + base }
            guard indices.count > start else { continue }
            let culled = !s.twoSided
            if let last = draws.last, last.culled == culled {
                draws[draws.count - 1].indices = last.indices.lowerBound..<indices.count
            } else {
                draws.append(Draw(indices: start..<indices.count, culled: culled, thruster: nil, pivot: .zero))
            }
        }
        guard !indices.isEmpty,
              let s = ShadowFitting.boundingSphere(points.lazy.map { Vec3(Double($0.x), Double($0.y), Double($0.z)) }),
              let p = device.makeBuffer(bytes: points, length: points.count * MemoryLayout<SIMD4<Float>>.stride,
                                        options: .storageModeShared),
              let i = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride,
                                        options: .storageModeShared) else { return nil }
        p.label = label
        i.label = label
        positions = p
        self.indices = i
        self.draws = draws
        centre = s.centre
        radius = s.radius
    }

    var triangleCount: Int { draws.map(\.indices.count).reduce(0, +) / 3 }

    /// Draws it with `clip(rotation, translation)` setting the clip matrix
    /// of its frame, `place` giving each draw's frame (camera-relative).
    func draw(into enc: MTLRenderCommandEncoder, place: (Draw) -> (Mat3, Vec3),
              clip: (Mat3, Vec3) -> Void) {
        enc.setVertexBuffer(positions, offset: 0, index: 0)
        var last: (Mat3, Vec3)?
        for d in draws {
            let frame = place(d)
            if last.map({ $0.0 != frame.0 || $0.1 != frame.1 }) ?? true {
                clip(frame.0, frame.1)
                last = frame
            }
            enc.setCullMode(d.culled ? .back : .none)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indices.count, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: d.indices.lowerBound * MemoryLayout<UInt32>.stride)
        }
    }
}

/// A vessel's casters: its parts' at their offsets in the construction
/// frame, and their sphere there, widened by 2% and 0.25 m for the
/// nozzles' gimballing.
@MainActor
struct VesselCaster {
    let signature: VesselGeometry.Signature
    let parts: [(mesh: CasterMesh, offset: Vec3)]
    let centre: Vec3
    let radius: Double

    init?(_ mesh: VesselMesh, caster: (PartEntry) -> CasterMesh?) {
        var parts: [(mesh: CasterMesh, offset: Vec3)] = []
        for (entry, offset) in zip(mesh.parts, mesh.offsets) {
            if let c = caster(entry) { parts.append((c, offset)) }
        }
        guard let s = ShadowFitting.enclosing(parts.map { ($0.offset + $0.mesh.centre, $0.mesh.radius) }) else {
            return nil
        }
        signature = mesh.signature
        self.parts = parts
        centre = s.centre
        radius = s.radius * 1.02 + 0.25
    }
}

/// A vessel's draws placed for the frame, as the vessel pass places them:
/// the construction frame on the vessel, each part at its offset, each
/// gimballed nozzle turned about its pivot with the thrust.
enum VesselPlacement {
    static func frame(_ v: RenderScene.Vessel, offset: Vec3, thruster: RenderScene.ThrusterKey?,
                      pivot: Vec3) -> (Mat3, Vec3) {
        let attitude = v.attitude.matrix
        let translation = v.position + v.attitude.rotate(v.structureOrigin)
        if let key = thruster, let t = v.thrusters[key] {
            let r = Mat3.rotation(from: t.direction, to: t.thrustDirection)
            return (attitude * r, translation + attitude * (offset + pivot - r * pivot))
        }
        return (attitude, translation + attitude * offset)
    }
}

/// LC-39A's elements as casters, tessellated once per device. Each element
/// is in its own frame, the site's axes about its pivot (`LC39A.Element`).
@MainActor
final class SiteMeshes {
    struct Element {
        let element: LC39A.Element
        let mesh: CasterMesh

        /// Its frame to camera-relative world at range time `t`: rotation
        /// and translation.
        func placement(in site: RenderScene.Site, at t: Double, _ c: LC39A.Countdown) -> (Mat3, Vec3) {
            let (r, pivot) = element.transform(at: t, c)
            return (site.orientation * r, site.origin + site.orientation * pivot)
        }
    }

    /// The site these are (`SitePlacement.name`).
    static let name = LC39A.placement().name

    let elements: [Element]
    /// The site's sphere, site frame, over every pose of its moving elements.
    let centre: Vec3
    let radius: Double

    private static var cache: [ObjectIdentifier: SiteMeshes] = [:]

    static func shared(_ device: MTLDevice) -> SiteMeshes? {
        let key = ObjectIdentifier(device)
        if let m = cache[key] { return m }
        let m = SiteMeshes(device: device)
        if let m { cache[key] = m }
        return m
    }

    /// The countdown the site stands in at `epoch`: the launch nearest it,
    /// Apollo 8's or Apollo 11's. Until the scene carries the site's state,
    /// the swing arms follow it.
    static func countdown(at epoch: Epoch) -> LC39A.Countdown {
        [LC39A.Countdown.apollo8, .apollo11].min { abs($0.rangeTime(at: epoch)) < abs($1.rangeTime(at: epoch)) }!
    }

    private init?(device: MTLDevice) {
        var elements: [Element] = [], spheres: [(centre: Vec3, radius: Double)] = []
        for e in LC39A.elements {
            guard let mesh = CasterMesh(shapes: e.shapes, label: e.name, device: device) else { continue }
            elements.append(Element(element: e, mesh: mesh))
            // A moving element sweeps a sphere about its pivot.
            if case .fixed = e.motion {
                spheres.append((e.pivot + mesh.centre, mesh.radius))
            } else {
                spheres.append((e.pivot, mesh.centre.length + mesh.radius))
            }
        }
        guard let all = ShadowFitting.enclosing(spheres) else { return nil }
        self.elements = elements
        centre = all.centre
        radius = all.radius
    }
}

extension simd_float4x4 {
    /// From a row-major 4×4 in double (`ShadowMapFit.matrix`).
    init(rowMajor m: [Double]) {
        func column(_ c: Int) -> SIMD4<Float> {
            SIMD4(Float(m[c]), Float(m[4 + c]), Float(m[8 + c]), Float(m[12 + c]))
        }
        self.init(columns: (column(0), column(1), column(2), column(3)))
    }
}

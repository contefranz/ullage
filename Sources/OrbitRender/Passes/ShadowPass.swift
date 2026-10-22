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
///   layers a frame has used and keeps them.
/// - **Casters**: the vessels' meshes with their gimballed nozzles, as
///   positions alone (`CasterMesh`), and the sites' elements as the
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
    private var casterMeshes: [UUID: CasterMesh] = [:]
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
            guard let mesh = f.meshes.mesh(v.id), let caster = casterMesh(v, mesh, device: f.device) else { continue }
            casters.append(ShadowCaster(kind: .vessel(v.id),
                                        centre: v.position + v.attitude.rotate(v.structureOrigin + caster.centre),
                                        radius: caster.radius))
            draws.append(.vessel(v, caster))
        }
        if casterMeshes.count > scene.vessels.count + 16 {
            let live = Set(scene.vessels.map(\.id))
            casterMeshes = casterMeshes.filter { live.contains($0.key) }
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

        // A render pass per layer: only the layers in use are cleared and
        // stored, each with the GPU's fast clear.
        for (layer, map) in plan.enumerated() {
            let d = MTLRenderPassDescriptor()
            d.depthAttachment.texture = atlas
            d.depthAttachment.slice = layer
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
        }

        var matrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: LightingUniforms.maxShadowMaps)
        var infos = [SIMD4<Float>](repeating: .zero, count: LightingUniforms.maxShadowMaps)
        for (i, map) in plan.enumerated() {
            matrices[i] = simd_float4x4(rowMajor: map.matrix)
            infos[i] = SIMD4(Float(i), Float(map.texel), Float(map.depthRange), 1)
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

    /// The vessel's caster mesh, made from its mesh once per signature.
    private func casterMesh(_ v: RenderScene.Vessel, _ mesh: VesselMesh, device: MTLDevice) -> CasterMesh? {
        if let c = casterMeshes[v.id], c.signature == mesh.signature { return c }
        let c = CasterMesh(mesh, device: device)
        casterMeshes[v.id] = c
        return c
    }

    /// What a caster draws.
    private enum Caster {
        case vessel(RenderScene.Vessel, CasterMesh)
        case site(RenderScene.Site, SiteMeshes, Double, LC39A.Countdown)

        /// Draws it into `map`'s layer: closed shapes with the faces turned
        /// from the Sun culled, open ones two-sided.
        func draw(into enc: MTLRenderCommandEncoder, map: ShadowMapFit) {
            func clip(_ rotation: Mat3, _ translation: Vec3) {
                var m = simd_float4x4(rowMajor: map.matrix(rotation: rotation, translation: translation))
                enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            }
            switch self {
            case let .vessel(v, mesh):
                enc.setVertexBuffer(mesh.positions, offset: 0, index: 0)
                for (i, (rotation, translation, range)) in VesselPlacement.groups(v, mesh.groups).enumerated() {
                    enc.setCullMode(mesh.groups[i].culled ? .back : .none)
                    clip(rotation, translation)
                    enc.drawPrimitives(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count)
                }
            case let .site(site, meshes, t, countdown):
                for element in meshes.elements {
                    let (rotation, translation) = element.placement(in: site, at: t, countdown)
                    // Only the elements that reach the map.
                    let c = translation + rotation * element.centre - map.centre
                    let reach = map.halfWidth + element.radius
                    guard abs(map.basis.r0.dot(c)) <= reach, abs(map.basis.r1.dot(c)) <= reach else { continue }
                    clip(rotation, translation)
                    enc.setVertexBuffer(element.positions, offset: 0, index: 0)
                    for (range, culled) in [(0..<element.closedCount, true),
                                            (element.closedCount..<element.vertexCount, false)] where !range.isEmpty {
                        enc.setCullMode(culled ? .back : .none)
                        enc.drawPrimitives(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count)
                    }
                }
            }
        }
    }
}

/// DebugView.sunShadow (F9): the Sun's visible share from the shadow maps on
/// every surface, grey from umbra to lit, tinted by the map that served it:
/// blue the detail map, white the camera target's cluster, green and amber
/// the others; a face turned from the Sun dark blue, a surface no map holds
/// pale red. The planet and the vessels come from the resolved scene depth;
/// the sites, which no pass draws yet, are drawn here with their own
/// normals. It proves ShadowCommon's receivers until R2 and E2 sample it in
/// shading. Track R4 owns this pass.
@MainActor
public final class ShadowDebugPass: RenderPass {
    public let name = "Sun-shadow view"
    public let stage = PassStage.post
    public let order = 1_001
    public var reads: Set<ResourceID> { [.sceneDepth, .shadowAtlas] }

    private let shadows: ShadowPass
    private var deferred: MTLRenderPipelineState?
    private var site: MTLRenderPipelineState?
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
        site = try PipelineBuilder.make(library, vertex: "shadow_debug_site_vertex", fragment: "shadow_debug_site",
                                        blend: .opaque, color: output, depth: .depth32Float, sampleCount: 1,
                                        device: s.device)
        let z = MTLDepthStencilDescriptor()
        z.depthCompareFunction = .always
        z.isDepthWriteEnabled = true
        always = s.device.makeDepthStencilState(descriptor: z)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard let deferred, let site, let always, let depth = f.textures[.sceneDepth] else { return }
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

        // What P1 drew, from its depth (which it writes again, for the sites).
        enc.setRenderPipelineState(deferred)
        enc.setDepthStencilState(always)
        enc.setFragmentTexture(depth, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // The sites.
        if !f.scene.sites.isEmpty, let meshes = SiteMeshes.shared(f.device) {
            enc.setRenderPipelineState(site)
            enc.setDepthStencilState(f.states.depthWrite)
            enc.setCullMode(.none)
            enc.setFrontFacing(.counterClockwise)
            var stride = UInt32(MemoryLayout<MeshVertex>.stride / MemoryLayout<SIMD4<Float>>.stride)
            enc.setVertexBytes(&stride, length: MemoryLayout<UInt32>.size, index: 2)
            let countdown = SiteMeshes.countdown(at: f.scene.clock.simTime)
            let t = countdown.rangeTime(at: f.scene.clock.simTime)
            for s in f.scene.sites where s.name == SiteMeshes.name {
                for element in meshes.elements {
                    let (rotation, translation) = element.placement(in: s, at: t, countdown)
                    var u = ShadowSiteUniforms(viewProjection: f.viewProjection,
                                               model: simd_float4x4(rotation: rotation, translation: translation))
                    enc.setVertexBuffer(element.buffer, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<ShadowSiteUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: element.vertexCount)
                }
            }
        }
        enc.endEncoding()
    }
}

/// ShadowShaders' `ShadowSiteUniforms`.
struct ShadowSiteUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
}

/// A vessel's mesh groups placed for the frame, as the vessel pass places
/// them: the construction frame on the vessel, each gimballed nozzle turned
/// about its pivot with the thrust.
enum VesselPlacement {
    static func groups(_ v: RenderScene.Vessel, _ groups: [VesselMesh.Group]) -> [(Mat3, Vec3, Range<Int>)] {
        let attitude = v.attitude.matrix
        let translation = v.position + v.attitude.rotate(v.structureOrigin)
        return groups.map { g in
            if let key = g.thruster, let t = v.thrusters[key] {
                let r = Mat3.rotation(from: t.direction, to: t.thrustDirection)
                return (attitude * r, translation + attitude * (g.pivot - r * g.pivot), g.range)
            }
            return (attitude, translation, g.range)
        }
    }
}

/// A vessel's mesh as a caster: its positions alone (a quarter of the
/// vertex fetch of the mesh's), in the mesh's groups, and its sphere in the
/// construction frame, widened by 2% and 0.25 m for the nozzles'
/// gimballing.
final class CasterMesh {
    let positions: MTLBuffer
    let groups: [VesselMesh.Group]
    let signature: VesselGeometry.Signature
    let centre: Vec3
    let radius: Double

    init?(_ mesh: VesselMesh, device: MTLDevice) {
        let count = mesh.groups.map(\.range.upperBound).max() ?? 0
        let stride = MemoryLayout<MeshVertex>.stride / MemoryLayout<SIMD4<Float>>.stride
        guard count > 0, mesh.buffer.length >= count * MemoryLayout<MeshVertex>.stride else { return nil }
        let source = mesh.buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count * stride)
        let points = (0..<count).map { source[$0 * stride] }
        guard let s = ShadowFitting.boundingSphere(points.lazy.map { Vec3(Double($0.x), Double($0.y), Double($0.z)) }),
              let positions = device.makeBuffer(bytes: points, length: count * MemoryLayout<SIMD4<Float>>.stride,
                                                options: .storageModeShared) else { return nil }
        positions.label = "Shadow caster positions"
        self.positions = positions
        groups = mesh.groups
        signature = mesh.signature
        centre = s.centre
        radius = s.radius * 1.02 + 0.25
    }
}

/// LC-39A's elements as meshes (MeshVertex), tessellated once per device:
/// the shadow pass's casters and the sun-shadow view's receivers until the
/// vessel pass (R2) draws sites. Each element is in its own frame, the
/// site's axes about its pivot (`LC39A.Element`).
@MainActor
final class SiteMeshes {
    struct Element {
        let element: LC39A.Element
        /// MeshVertex, for the sun-shadow view; and its positions alone, for the maps.
        let buffer: MTLBuffer
        let positions: MTLBuffer
        let vertexCount: Int
        /// The closed shapes' vertices come first (drawn with back faces
        /// culled into the maps), then the open, two-sided ones'.
        let closedCount: Int
        /// Its own sphere, element frame.
        let centre: Vec3
        let radius: Double

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
            let closed = e.shapes.filter { !$0.twoSided }.flatMap { VesselMesh.vertices($0, offset: .zero) }
            let verts = closed + e.shapes.filter(\.twoSided).flatMap { VesselMesh.vertices($0, offset: .zero) }
            let points = verts.map(\.position)
            guard !verts.isEmpty,
                  let s = ShadowFitting.boundingSphere(points.map { Vec3(Double($0.x), Double($0.y), Double($0.z)) }),
                  let buffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<MeshVertex>.stride,
                                                 options: .storageModeShared),
                  let positions = device.makeBuffer(bytes: points, length: points.count * MemoryLayout<SIMD4<Float>>.stride,
                                                    options: .storageModeShared) else { continue }
            buffer.label = e.name
            positions.label = e.name
            elements.append(Element(element: e, buffer: buffer, positions: positions, vertexCount: verts.count,
                                    closedCount: closed.count, centre: s.centre, radius: s.radius))
            // A moving element sweeps a sphere about its pivot.
            if case .fixed = e.motion {
                spheres.append((e.pivot + s.centre, s.radius))
            } else {
                spheres.append((e.pivot, s.centre.length + s.radius))
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

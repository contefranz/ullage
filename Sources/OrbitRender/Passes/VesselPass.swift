import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The vessels, their gimballed nozzles, parachute canopies and risers, and
/// the body-fixed sites (LC-39A), physically shaded (P1). Track R2 owns this
/// pass and its shader module.
///
/// - **Geometry:** each vessel's draw list from the per-part mesh cache
///   (`VesselMeshCache`), so a separation draws the same part meshes in new
///   lists; the site's elements, meshed once, placed by the countdown.
/// - **Shading:** LightingCommon's BRDF with the DFG table (texture 22,
///   which it also leaves in the frame's slots for later encoders), the
///   Sun's disc, up to 8 plume lights (`LightingUniforms`'s when P2 writes
///   them, else `PlumeLights` from the emitters), and the environment:
///   R3's probe when there is one, else the stand-in (`StandInLighting`).
/// - **Ambient occlusion:** R5's bakes (`AmbientOcclusionBaker`), in the
///   background as the app draws, or before the frame
///   (`ShadingSettings.waitForAmbientOcclusion`) for snapshots.
/// - **Output:** radiance times the pre-exposure (R1's, or the stand-in's EV
///   15 until it lands), Karis-encoded into a float scene target.
@MainActor
public final class VesselPass: RenderPass {
    public let name = "Vessels"
    public let stage = PassStage.opaque
    public let order = 20
    public var writes: Set<ResourceID> { [.dfgLUT] }

    private var opaque: MTLRenderPipelineState?
    private var wire: MTLRenderPipelineState?
    private(set) var dfg: MTLTexture?
    private var dummy: MTLBuffer?
    private var paints: [VesselPaintGPU] = VesselPaintGPU.table()
    private var canopies: (main: PartMesh, drogue: PartMesh)?
    private var site: [PartMesh?]?
    /// R5's baker: each vessel's AO, once per mesh signature.
    public let ambientOcclusion = AmbientOcclusionBaker()

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.vessel)
        opaque = try Self.pipeline(library, wire: false, setup: s)
        wire = try Self.pipeline(library, wire: true, setup: s)
        dfg = Self.dfgTexture(device: s.device)
        dummy = s.device.makeBuffer(length: 256, options: .storageModeShared)
    }

    /// Whether `format` holds HDR values (the vessel shader then Karis-encodes them).
    static func isFloat(_ format: MTLPixelFormat) -> Bool {
        [.rgba16Float, .rgba32Float, .rg11b10Float, .rgb9e5Float, .r16Float, .rg16Float].contains(format)
    }

    static func pipeline(_ library: MTLLibrary, wire: Bool, setup s: PassSetup) throws -> MTLRenderPipelineState {
        let constants = MTLFunctionConstantValues()
        var hdr = isFloat(s.formats.color)
        constants.setConstantValue(&hdr, type: .bool, index: 0)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = try library.makeFunction(name: "vessel_vertex", constantValues: constants)
        d.fragmentFunction = try library.makeFunction(name: "vessel_fragment", constantValues: constants)
        d.colorAttachments[0].pixelFormat = s.formats.color
        d.depthAttachmentPixelFormat = s.formats.depth
        d.rasterSampleCount = s.formats.sampleCount
        if wire {
            // Persson's wires blend at their coverage (alpha to coverage
            // would drop a thin tube's last samples and break it up).
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .sourceAlpha
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        d.label = wire ? "Vessels (wires)" : "Vessels"
        return try s.device.makeRenderPipelineState(descriptor: d)
    }

    /// `BRDF.dfgTable` as a texture the linear sampler filters: rg32Float
    /// where the GPU filters 32-bit floats, else rg16Float.
    static func dfgTexture(device: MTLDevice) -> MTLTexture? {
        let table = BRDF.dfgTable
        let wide = device.supports32BitFloatFiltering
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: wide ? .rg32Float : .rg16Float,
                                                         width: table.size, height: table.size, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let region = MTLRegionMake2D(0, 0, table.size, table.size)
        if wide {
            table.values.withUnsafeBytes {
                t.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: table.size * 8)
            }
        } else {
            let half = table.values.map { Float16($0) }
            half.withUnsafeBytes {
                t.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: table.size * 4)
            }
        }
        return t
    }

    // MARK: Frame

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let opaque, let wire, let dfg, let dummy,
              let materials = f.meshes.materials else { return }
        let settings = f.settings.shading
        ambientOcclusion.settings = f.settings.ambientOcclusion
        f.slotTextures[Binding.dfgLUT] = dfg
        enc.setFragmentTexture(dfg, index: Binding.dfgLUT)
        enc.setFragmentBuffer(materials.buffer, offset: 0, index: 0)
        enc.setFragmentBytes(&paints, length: MemoryLayout<VesselPaintGPU>.stride * paints.count, index: 3)
        enc.setDepthStencilState(f.states.depthWrite)
        enc.setFrontFacing(.counterClockwise)
        var lights = Self.localLights(f, maximum: max(0, min(settings.plumeLights, LightingUniforms.maxLocalLights)))
        let lightCount = lights.count
        if lights.isEmpty { lights = [LocalLight()] }
        enc.setFragmentBytes(&lights, length: MemoryLayout<LocalLight>.stride * lights.count, index: 5)
        let shading = SIMD4<Float>(Float(Self.preExposure(f.frame)), Float(lightCount),
                                   settings.specularAntiAliasing ? 1 : 0, settings.multipleScattering ? 1 : 0)
        let draw = Drawing(encoder: enc, opaque: opaque, wire: wire, dummy: dummy,
                           wireRadius: Float(settings.wireMinimumRadius))

        for v in f.scene.vessels {
            guard let mesh = f.mesh(of: v) else { continue }
            applyAmbientOcclusion(of: v, mesh: mesh, f: f, settings: settings)
            draw.setObject(Self.object(StandInLighting.vessel(v, in: f.scene), scene: f.scene, settings: settings,
                                       shading: shading))
            let attitude = v.attitude.matrix
            let translation = v.position + v.attitude.rotate(v.structureOrigin)
            for (entry, offset) in zip(mesh.parts, mesh.offsets) {
                let aoSettings = f.settings.ambientOcclusion
                let ao = aoSettings.enabled
                    ? (entry.aoNow, entry.aoBefore, Self.fade(entry, now: f.scene.clock.realTime,
                                                             duration: aoSettings.fadeDuration))
                    : (nil, nil, 0)
                draw.part(entry.mesh, ao: ao) { d in
                    guard let key = d.thruster, let t = v.thrusters[key] else {
                        return simd_float4x4(rotation: attitude, translation: translation + attitude * offset)
                    }
                    // The nozzle turns about its gimbal point with the thrust.
                    let r = Mat3.rotation(from: t.direction, to: t.thrustDirection)
                    return simd_float4x4(rotation: attitude * r,
                                         translation: translation + attitude * (offset + d.pivot - r * d.pivot))
                }
            }
            drawCanopies(of: v, f: f, draw: draw, materials: materials)
        }
        drawSites(f, draw: draw, materials: materials, shading: shading, settings: settings)
        draw.drawWires(depth: f.states.depthReadOnly, then: f.states.depthWrite)
        enc.setCullMode(.none)
    }

    /// Gives `v`'s parts its bake's AO streams: baked now when the settings
    /// wait for it (snapshots), else once the baker has it and its fade has
    /// begun, so a frame whose clock stands still (a snapshot's) never
    /// changes its meshes from one render to the next.
    private func applyAmbientOcclusion(of v: RenderScene.Vessel, mesh: VesselMesh, f: FrameContext,
                                       settings: ShadingSettings) {
        let now = f.scene.clock.realTime
        if settings.waitForAmbientOcclusion {
            if let baked = ambientOcclusion.bakeNow(v.geometry) {
                f.meshes.apply(baked, to: mesh, now: now, synchronously: true)
            }
            return
        }
        let lookup = ambientOcclusion.lookup(v.geometry, now: now)
        if let baked = lookup.baked, lookup.fade > 0 { f.meshes.apply(baked, to: mesh, now: now) }
    }

    /// How far a part's current AO stream has faded in at `now`.
    static func fade(_ entry: PartEntry, now: Double, duration: Double) -> Float {
        guard entry.aoNow != nil else { return 0 }
        guard duration > 0, entry.aoArrived.isFinite else { return 1 }
        return Float(min(max((now - entry.aoArrived) / duration, 0), 1))
    }

    /// The pre-exposure: R1's, or the stand-in's until R1 sets one.
    static func preExposure(_ frame: FrameUniforms) -> Double {
        frame.exposure == SIMD4<Float>(1, 0, 1, 0) ? StandInLighting.preExposure : Double(frame.exposure.x)
    }

    /// The plume lights: P2's, when it writes them into the lighting
    /// uniforms, else `PlumeLights` from the scene's emitters.
    static func localLights(_ f: FrameContext, maximum: Int) -> [LocalLight] {
        guard maximum > 0 else { return [] }
        let written = Int(f.lighting.lightCount.x)
        if written > 0 {
            return withUnsafeBytes(of: f.lighting.lights) { raw in
                Array(raw.bindMemory(to: LocalLight.self).prefix(min(written, maximum)))
            }
        }
        return PlumeLights.lights(f.scene, maximum: maximum).map { l in
            var g = LocalLight()
            g.positionRadius = SIMD4(l.centre, Float(l.radius))
            g.axisLength = SIMD4(l.axis, Float(l.length))
            g.intensity = SIMD4(l.intensity.r, l.intensity.g, l.intensity.b, Float(l.range))
            return g
        }
    }

    static func object(_ l: ObjectLighting, scene: RenderScene, settings: ShadingSettings,
                       shading: SIMD4<Float>) -> VesselObjectGPU {
        let rho = scene.sun.angularRadius
        return VesselObjectGPU(sun: SIMD4(l.toSun, Float(l.sunlit)),
                               sunDisc: SIMD4(Float(cos(rho)), Float(sin(rho)), settings.sunDiscAreaLight ? 1 : 0, 0),
                               body: SIMD4(l.earthDirection, Float(l.earthSinSigma2)),
                               bodyRadiance: SIMD4(SIMD3(l.earthRadiance), 0),
                               sky: SIMD4(repeating: Float(l.sky)), floor: SIMD4(repeating: Float(l.floor)),
                               glow: SIMD4(SIMD3(l.glow), 0), flow: SIMD4(l.flowDirection, 0), shading: shading)
    }

    // MARK: Canopies and risers

    /// Risers' radius, m (L): drawn as thin tubes, so the wire pipeline keeps
    /// them visible at any distance.
    static let riserRadius = 0.02

    private func drawCanopies(of v: RenderScene.Vessel, f: FrameContext, draw: Drawing,
                              materials: VesselMaterialTable) {
        let mine = f.scene.canopies.filter { $0.vesselID == v.id }
        guard !mine.isEmpty else { return }
        if canopies == nil { canopies = Self.canopyMeshes(device: f.device, materials: materials) }
        if let canopies {
            for c in mine {
                let m = simd_float4x4(columns: (SIMD4(c.axis * c.sx, 0), SIMD4(c.side * c.sr, 0),
                                                SIMD4(c.other * c.sr, 0), SIMD4(c.skirt, 1)))
                let n = simd_float4x4(columns: (SIMD4(c.axis / c.sx, 0), SIMD4(c.side / c.sr, 0),
                                                SIMD4(c.other / c.sr, 0), SIMD4(0, 0, 0, 1)))
                draw.part(c.isMain ? canopies.main : canopies.drogue, ao: (nil, nil, 0), normalMatrix: n) { _ in m }
            }
        }
        let risers = mine.flatMap(\.risers)
        let canvas = materials.id(.apolloCanvas, color: (0.82, 0.8, 0.74))
        if let tubes = Self.tubes(risers, radius: Self.riserRadius, material: canvas, device: f.device, arena: f.arena) {
            draw.tubes(tubes)
        }
    }

    /// The parachute canopies: one open, two-sided dome per kind, of unit
    /// diameter with its skirt at x = 0 and its vent towards +x
    /// (`CanopyGeometry.depth`), in gores of orange and white canvas; the
    /// pass scales and places it per canopy. Visual only: the profile is a
    /// generic inflated dome, not the ringsail's or the ribbon's.
    static func canopyMeshes(device: MTLDevice, materials: VesselMaterialTable) -> (main: PartMesh, drogue: PartMesh)? {
        typealias P = VisualShape.ProfilePoint
        let depth = CanopyGeometry.depth
        let profile = [P(0, 0.5), P(0.12, 0.49), P(0.22, 0.46), P(0.31, 0.4), P(0.37, 0.32), P(0.41, 0.2),
                       P(0.42, 0.06)].map { P($0.x * depth / 0.42, $0.r) }
        let orange = (0.89, 0.17, 0.012), white = (0.9, 0.9, 0.88)
        func mesh(gores: Int, colours: [(Double, Double, Double)]) -> PartMesh? {
            let width = 2 * Double.pi / Double(gores)
            var shapes: [VisualShape] = []
            for g in 0..<gores {
                var s = VisualShape.revolution(profile, from: .zero, axis: .unitX, segments: 4 * gores,
                                               sweep: Double(g) * width...Double(g + 1) * width,
                                               color: colours[g % colours.count])
                s.capBase = false
                s.capTop = false
                s.twoSided = true
                s.material = .apolloCanvas
                shapes.append(s)
            }
            let info = shapes.map { PartMesh.ShapeInfo(culled: false, wire: false, thruster: nil, pivot: .zero,
                                                       material: materials.id($0)) }
            return PartMesh.build(meshes: shapes.map { $0.mesh() }, info: info, paint: shapes.map { _ in [] },
                                  subdivided: false, device: device)
        }
        guard let main = mesh(gores: 12, colours: [orange, white]),
              let drogue = mesh(gores: 8, colours: [white, orange]) else { return nil }
        return (main, drogue)
    }

    /// Camera-relative segments as six-sided open tubes of `radius`, in the
    /// frame's arena: their vertices, indices and index count.
    static func tubes(_ segments: [(Vec3, Vec3)], radius: Double, material: UInt8, device: MTLDevice,
                      arena: FrameArena) -> (vertices: (MTLBuffer, Int), indices: (MTLBuffer, Int), count: Int)? {
        guard !segments.isEmpty else { return nil }
        let sides = 6
        var vertices: [VertexV2] = [], indices: [UInt32] = []
        let ids = SurfaceIDs(material: material).packed
        for (a, b) in segments {
            guard (b - a).length > 1e-6 else { continue }
            let axis = (b - a).normalized
            let u = VisualShape.defaultReference(for: axis), w = axis.cross(u)
            let base = UInt32(vertices.count)
            for k in 0..<sides {
                let phi = 2 * Double.pi * Double(k) / Double(sides)
                let n = u * cos(phi) + w * sin(phi)
                let t = axis.cross(n)
                for (end, s) in [(a, 0.0), (b, (b - a).length)] {
                    vertices.append(VertexV2(positionAO: SIMD4(end + n * radius, AmbientOcclusion.unoccluded),
                                             normalIDs: SIMD4(n, ids), tangent: SIMD4(t, 1),
                                             surface: SIMD4(Float(s), Float(phi), Float(radius), Float(s))))
                }
            }
            for k in 0..<sides {
                let i0 = base + UInt32(2 * k), i1 = base + UInt32(2 * ((k + 1) % sides))
                indices += [i0, i1, i0 + 1, i1, i1 + 1, i0 + 1]
            }
        }
        guard !indices.isEmpty, let vb = arena.push(vertices), let ib = arena.push(indices) else { return nil }
        return ((vb.buffer, vb.offset), (ib.buffer, ib.offset), indices.count)
    }

    // MARK: Sites

    /// Sites farther than this from the camera are not drawn (m).
    static let siteRange = 100_000.0

    private func drawSites(_ f: FrameContext, draw: Drawing, materials: VesselMaterialTable, shading: SIMD4<Float>,
                           settings: ShadingSettings) {
        let near = f.scene.sites.filter { $0.name == "LC-39A" && $0.origin.length < Self.siteRange }
        guard !near.isEmpty else { return }
        if site == nil { site = Self.siteMeshes(device: f.device, materials: materials) }
        guard let site else { return }
        let countdown = Self.countdown(at: f.scene.clock.simTime)
        let t = countdown.rangeTime(at: f.scene.clock.simTime)
        for s in near {
            draw.setObject(Self.object(StandInLighting.site(s, in: f.scene), scene: f.scene, settings: settings,
                                       shading: shading))
            for (element, mesh) in zip(LC39A.elements, site) {
                guard let mesh else { continue }
                let (r, o) = element.transform(at: t, countdown)
                let model = simd_float4x4(rotation: s.orientation * r, translation: s.origin + s.orientation * o)
                draw.part(mesh, ao: (nil, nil, 0)) { _ in model }
            }
        }
    }

    /// LC-39A's elements, each meshed once in its own frame.
    static func siteMeshes(device: MTLDevice, materials: VesselMaterialTable) -> [PartMesh?] {
        LC39A.elements.map { e in
            let info = e.shapes.map {
                PartMesh.ShapeInfo(culled: !$0.twoSided, wire: PartMesh.isWire($0), thruster: nil, pivot: .zero,
                                   material: materials.id($0))
            }
            return PartMesh.build(meshes: e.shapes.map { $0.mesh() }, info: info, paint: e.shapes.map { _ in [] },
                                  subdivided: false, device: device)
        }
    }

    /// The countdown of the launch nearest `epoch`: Apollo 8's or Apollo 11's.
    static func countdown(at epoch: Epoch) -> LC39A.Countdown {
        [LC39A.Countdown.apollo8, .apollo11].min { abs($0.rangeTime(at: epoch)) < abs($1.rangeTime(at: epoch)) }!
    }
}

/// Draws part meshes with the pass's pipelines and states. Thin tubes wait
/// until the opaque geometry is down (`drawWires`): they blend over it,
/// depth-tested, without writing depth.
@MainActor
final class Drawing {
    let encoder: MTLRenderCommandEncoder
    let opaque: MTLRenderPipelineState
    let wire: MTLRenderPipelineState
    let dummy: MTLBuffer
    let wireRadius: Float
    /// The vessel's or site's lighting the draws now use (fragment buffer 2).
    private var object: VesselObjectGPU?
    private var wires: [Wire] = []

    struct Wire {
        var vertices: (MTLBuffer, Int)
        var ao: (MTLBuffer, MTLBuffer)
        var indices: (MTLBuffer, Int)
        var count: Int
        var culled: Bool
        var uniforms: VesselDrawGPU
        var object: VesselObjectGPU
    }

    init(encoder: MTLRenderCommandEncoder, opaque: MTLRenderPipelineState, wire: MTLRenderPipelineState,
         dummy: MTLBuffer, wireRadius: Float) {
        self.encoder = encoder
        self.opaque = opaque
        self.wire = wire
        self.dummy = dummy
        self.wireRadius = wireRadius
    }

    func setObject(_ o: VesselObjectGPU) {
        object = o
        var copy = o
        encoder.setFragmentBytes(&copy, length: MemoryLayout<VesselObjectGPU>.stride, index: 2)
    }

    /// Every draw of `mesh`, each placed by `model` (part frame to
    /// camera-relative world), with its AO streams and their fade.
    func part(_ mesh: PartMesh, ao: (now: MTLBuffer?, before: MTLBuffer?, fade: Float),
              normalMatrix: simd_float4x4? = nil, model: (PartMesh.Draw) -> simd_float4x4) {
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        encoder.setVertexBuffer(ao.now ?? dummy, offset: 0, index: 3)
        encoder.setVertexBuffer(ao.before ?? dummy, offset: 0, index: 4)
        encoder.setRenderPipelineState(opaque)
        for d in mesh.draws {
            let m = model(d)
            let isWire = d.wire && wireRadius > 0
            var u = VesselDrawGPU(model: m, normalMatrix: normalMatrix ?? Self.rotation(of: m),
                                  ao: SIMD4(ao.fade, ao.now == nil ? 0 : 1, ao.before == nil ? 0 : 1, 0),
                                  wire: SIMD4(isWire ? 1 : 0, wireRadius, 1, 0))
            if isWire, let object {
                wires.append(Wire(vertices: (mesh.vertices, 0), ao: (ao.now ?? dummy, ao.before ?? dummy),
                                  indices: (mesh.indices, d.indices.lowerBound * 4), count: d.indices.count,
                                  culled: d.culled, uniforms: u, object: object))
                continue
            }
            encoder.setCullMode(d.culled ? .back : .none)
            encoder.setVertexBytes(&u, length: MemoryLayout<VesselDrawGPU>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<VesselDrawGPU>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: d.indices.count, indexType: .uint32,
                                          indexBuffer: mesh.indices, indexBufferOffset: d.indices.lowerBound * 4)
        }
    }

    /// Camera-relative tubes (`VesselPass.tubes`), as wires.
    func tubes(_ t: (vertices: (MTLBuffer, Int), indices: (MTLBuffer, Int), count: Int)) {
        let u = VesselDrawGPU(model: matrix_identity_float4x4, normalMatrix: matrix_identity_float4x4,
                              ao: SIMD4(0, 0, 0, 0), wire: SIMD4(wireRadius > 0 ? 1 : 0, wireRadius, 1, 0))
        guard let object else { return }
        let w = Wire(vertices: t.vertices, ao: (dummy, dummy), indices: t.indices, count: t.count, culled: true,
                     uniforms: u, object: object)
        if wireRadius > 0 { wires.append(w) } else { draw(w, pipeline: opaque) }
    }

    /// The wires held back, blended over what is drawn; then the opaque
    /// state again for the passes after.
    func drawWires(depth: MTLDepthStencilState, then opaqueDepth: MTLDepthStencilState) {
        guard !wires.isEmpty else { return }
        encoder.setDepthStencilState(depth)
        for w in wires { draw(w, pipeline: wire) }
        encoder.setDepthStencilState(opaqueDepth)
        wires = []
    }

    private func draw(_ w: Wire, pipeline: MTLRenderPipelineState) {
        var u = w.uniforms, o = w.object
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(w.culled ? .back : .none)
        encoder.setVertexBuffer(w.vertices.0, offset: w.vertices.1, index: 0)
        encoder.setVertexBuffer(w.ao.0, offset: 0, index: 3)
        encoder.setVertexBuffer(w.ao.1, offset: 0, index: 4)
        encoder.setVertexBytes(&u, length: MemoryLayout<VesselDrawGPU>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VesselDrawGPU>.stride, index: 1)
        encoder.setFragmentBytes(&o, length: MemoryLayout<VesselObjectGPU>.stride, index: 2)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: w.count, indexType: .uint32,
                                      indexBuffer: w.indices.0, indexBufferOffset: w.indices.1)
    }

    /// The rotation of a rigid model matrix, for its normals.
    static func rotation(of m: simd_float4x4) -> simd_float4x4 {
        var r = m
        r.columns.3 = SIMD4(0, 0, 0, 1)
        return r
    }
}

// Swift mirrors of VesselShaders' structs.

/// `VesselDraw`.
struct VesselDrawGPU {
    var model: simd_float4x4
    var normalMatrix: simd_float4x4
    /// x: fade from the previous AO to the current, y: 1 with a current
    /// stream, z: 1 with a previous one.
    var ao: SIMD4<Float>
    /// x: 1 for a thin tube, y: its smallest radius (px), z: the model's scale.
    var wire: SIMD4<Float>
}

/// `VesselObject`.
struct VesselObjectGPU {
    var sun: SIMD4<Float>
    var sunDisc: SIMD4<Float>
    var body: SIMD4<Float>
    var bodyRadiance: SIMD4<Float>
    var sky: SIMD4<Float>
    var floor: SIMD4<Float>
    var glow: SIMD4<Float>
    var flow: SIMD4<Float>
    var shading: SIMD4<Float>
}

import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// What every pass of a frame sees: the scene, the camera's matrices, the
/// shared uniforms (which P0 passes may still change), the targets, the
/// frame's arena and the vessels' meshes.
@MainActor
public final class FrameContext {
    public let scene: RenderScene
    public let device: MTLDevice
    public let commandBuffer: MTLCommandBuffer
    /// The texture the frame ends in (the drawable, or an offscreen target).
    public let output: MTLTexture
    public let size: RenderSize
    public let settings: RenderSettings
    /// Vertex and uniform data for this frame, reused three frames on.
    let arena: FrameArena
    public let pool: TexturePool
    public let history: HistoryTargets
    public let states: CommonStates

    /// World to view (rotation only), the reversed-Z infinite projection,
    /// and their product, which takes camera-relative world to clip.
    public let view: simd_float4x4
    public let projection: simd_float4x4
    public let viewProjection: simd_float4x4
    /// x: pixels per point (the point and line pipelines' scale).
    public let pointParams: SIMD4<Float>

    /// Buffer 30. Filled before P0.
    public var frame: FrameUniforms
    /// Buffer 29. P0 passes write theirs (shadows, probe, plume lights).
    public var lighting = LightingUniforms()
    /// Buffer 28. The atmosphere pass writes it in P0.
    public var atmosphere = AtmosphereUniforms()
    /// Textures for the reserved slots (`Binding`), set by P0 passes; the
    /// render stages see a fallback in each slot nobody filled.
    public var slotTextures: [Int: MTLTexture] = [:]
    /// Textures passes hand each other this frame (`ResourceID`).
    public var textures: [ResourceID: MTLTexture] = [:]

    let meshes: VesselMeshCache
    /// The vessels drawn as their meshes, and those drawn as points.
    private let meshVessels: Set<UUID>
    private let pointVessels: Set<UUID>
    private let fallbacks: FallbackTextures
    private var shared: (frame: (MTLBuffer, Int), lighting: (MTLBuffer, Int), atmosphere: (MTLBuffer, Int))?

    init(scene: RenderScene, device: MTLDevice, commandBuffer: MTLCommandBuffer, output: MTLTexture,
         settings: RenderSettings, arena: FrameArena, pool: TexturePool, history: HistoryTargets, states: CommonStates,
         meshes: VesselMeshCache, fallbacks: FallbackTextures, previousViewProjection: simd_float4x4?) {
        self.scene = scene
        self.device = device
        self.commandBuffer = commandBuffer
        self.output = output
        size = RenderSize(width: output.width, height: output.height)
        self.settings = settings
        self.arena = arena
        self.pool = pool
        self.history = history
        self.states = states
        self.meshes = meshes
        self.fallbacks = fallbacks

        let cam = scene.camera
        projection = .reversedInfinitePerspective(fovY: Float(cam.fovY), aspect: Float(cam.aspect), near: Float(cam.near))
        view = simd_float4x4(rotation: cam.worldToView)
        viewProjection = projection * view
        pointParams = SIMD4<Float>(Float(cam.viewport.pointScale), 0, 0, 0)
        // Kept out of this initializer: with them inline, Apple Swift 6.4
        // (swiftlang-6.4.0.34.1) emits invalid IR for it at -O with
        // -enable-testing (the fast test gate's build), and the LLVM verifier
        // aborts the build ("Instruction does not dominate all uses").
        (meshVessels, pointVessels) = Self.visibility(scene, meshes: meshes)
        frame = Self.frameUniforms(scene, settings: settings, view: view, projection: projection,
                                   previousViewProjection: previousViewProjection)
    }

    /// The vessels drawn as their meshes, and those drawn as points: as a
    /// point when it covers under half a pixel, not at all without a mesh.
    static func visibility(_ scene: RenderScene, meshes: VesselMeshCache) -> (mesh: Set<UUID>, point: Set<UUID>) {
        var mesh = Set<UUID>(), point = Set<UUID>()
        for v in scene.vessels where meshes.mesh(v.id) != nil {
            if v.pixelSize(scene.camera) < 0.5 { point.insert(v.id) } else { mesh.insert(v.id) }
        }
        return (mesh, point)
    }

    /// The frame's shared uniforms, before P0.
    static func frameUniforms(_ scene: RenderScene, settings: RenderSettings, view: simd_float4x4,
                              projection: simd_float4x4, previousViewProjection: simd_float4x4?) -> FrameUniforms {
        let cam = scene.camera, viewProjection = projection * view
        var f = FrameUniforms()
        f.viewProjection = viewProjection
        f.view = view
        f.projection = projection
        f.viewToWorld = simd_float4x4(rotation: cam.worldToView.transposed)
        f.previousViewProjection = scene.clock.temporalReset ? viewProjection : previousViewProjection ?? viewProjection
        let w = Float(cam.viewport.width), h = Float(cam.viewport.height)
        f.viewport = SIMD4(w, h, 1 / max(w, 1), 1 / max(h, 1))
        f.camera = SIMD4(Float(cam.near), Float(tan(cam.fovY / 2)), Float(cam.aspect), Float(cam.renderScale))
        let clock = scene.clock
        f.time = SIMD4(Float(clock.shaderRealTime), Float(clock.realDt), Float(clock.shaderSimTime), Float(clock.simDt))
        f.frame = SIMD4(Float(clock.frameIndex % (1 << 24)), Float(clock.warp), clock.paused ? 1 : 0,
                        clock.temporalReset ? 1 : 0)
        f.sunDirection = SIMD4(scene.sun.direction, Float(scene.sun.angularRadius))
        let lux = Float(scene.sun.illuminance)
        f.sunIlluminance = SIMD4(lux, lux, lux, lux)
        f.noiseOrigin = noiseOrigin(scene)
        f.debug = SIMD4(Float(DebugView.allCases.firstIndex(of: settings.debug.view) ?? 0),
                        settings.debug.showPassTimings ? 1 : 0, 0, 0)
        f.pointScale = SIMD4(Float(cam.viewport.pointScale), 0, 0, 0)
        return f
    }

    /// The side of the planet-fixed noise tile, m (2^15).
    public static let noiseTile = 32_768.0

    /// The camera's position fixed to the body nearest it, modulo the noise
    /// tile, in double before it becomes float.
    static func noiseOrigin(_ scene: RenderScene) -> SIMD4<Float> {
        guard let body = scene.bodies.min(by: { $0.distance < $1.distance }) else { return .zero }
        let p = body.orientation.toBody(-body.position)
        func wrap(_ x: Double) -> Float { Float(x - (x / noiseTile).rounded(.down) * noiseTile) }
        return SIMD4(wrap(p.x), wrap(p.y), wrap(p.z), Float(noiseTile))
    }

    // MARK: Vessels

    /// The mesh `v` is drawn with this frame, nil when it is a point or has none.
    public func mesh(of v: RenderScene.Vessel) -> VesselMesh? {
        meshVessels.contains(v.id) ? meshes.mesh(v.id) : nil
    }

    /// Whether the vessel `id` is drawn as its mesh (its plumes, canopies
    /// and risers with it).
    public func drawsMesh(_ id: UUID) -> Bool { meshVessels.contains(id) }

    /// Whether it is too small and drawn as a point.
    public func drawsPoint(_ id: UUID) -> Bool { pointVessels.contains(id) }

    /// Whether `body` covers too few pixels to draw as a disc (1.5 px in radius).
    public func drawsPoint(_ body: RenderScene.Body) -> Bool {
        body.angularRadius * scene.camera.pixelsPerRadian < 1.5
    }

    // MARK: Shared bindings

    /// Copies the shared uniforms into the arena; the frame graph does it
    /// after P0 (and again if a later stage changed them).
    func uploadShared() {
        guard let f = arena.push(value: frame), let l = arena.push(value: lighting),
              let a = arena.push(value: atmosphere) else { return }
        shared = ((f.buffer, f.offset), (l.buffer, l.offset), (a.buffer, a.offset))
    }

    /// Binds the shared uniforms, the reserved texture slots and the shared
    /// samplers on a render encoder the graph opened.
    func bindShared(_ enc: MTLRenderCommandEncoder) {
        guard let shared else { return }
        for (index, b) in [(Binding.frameBuffer, shared.frame), (Binding.lightingBuffer, shared.lighting),
                           (Binding.atmosphereBuffer, shared.atmosphere)] {
            enc.setVertexBuffer(b.0, offset: b.1, index: index)
            enc.setFragmentBuffer(b.0, offset: b.1, index: index)
        }
        for (slot, fallback) in fallbacks.bySlot {
            enc.setFragmentTexture(slotTextures[slot] ?? fallback, index: slot)
        }
        enc.setFragmentSamplerState(states.linearClamp, index: Binding.linearClampSampler)
        enc.setFragmentSamplerState(states.shadowCompare, index: Binding.shadowCompareSampler)
    }

    /// The same for a compute encoder of a pass's own.
    public func bindShared(_ enc: MTLComputeCommandEncoder) {
        guard let shared else { return }
        enc.setBuffer(shared.frame.0, offset: shared.frame.1, index: Binding.frameBuffer)
        enc.setBuffer(shared.lighting.0, offset: shared.lighting.1, index: Binding.lightingBuffer)
        enc.setBuffer(shared.atmosphere.0, offset: shared.atmosphere.1, index: Binding.atmosphereBuffer)
        for (slot, fallback) in fallbacks.bySlot {
            enc.setTexture(slotTextures[slot] ?? fallback, index: slot)
        }
        enc.setSamplerState(states.linearClamp, index: Binding.linearClampSampler)
        enc.setSamplerState(states.shadowCompare, index: Binding.shadowCompareSampler)
    }

    /// Binds the frame uniforms alone, for a pass's own compute encoder in P0
    /// (the lighting and atmosphere uniforms are not final until P0 ends).
    public func bindFrameUniforms(_ enc: MTLComputeCommandEncoder) {
        if let f = arena.push(value: frame) { enc.setBuffer(f.buffer, offset: f.offset, index: Binding.frameBuffer) }
    }
}

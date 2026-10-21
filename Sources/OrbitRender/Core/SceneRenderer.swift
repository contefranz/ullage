import Foundation
import Metal
import QuartzCore
import simd
import OrbitCore
import OrbitScene

/// Draws a `RenderScene` into a texture, the window's drawable or an
/// offscreen target, through the frame graph's passes. Every position is
/// camera-relative and computed in double precision until it becomes float,
/// because Apple GPUs have no 64-bit floating point.
@MainActor
public final class SceneRenderer {
    /// Multisample anti-aliasing: 4 samples, which every Apple GPU supports.
    public nonisolated static let defaultSampleCount = 4
    /// Frames the CPU may write ahead of the GPU: one arena each.
    public nonisolated static let framesInFlight = 3

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let shaders: ShaderLibrary
    public let graph: FrameGraph
    /// The output's pixel format (the drawable's).
    public let outputFormat: MTLPixelFormat
    public var settings = RenderSettings()
    /// CPU encoding and GPU times, smoothed (s).
    public let times = FrameTimes()

    let states: CommonStates
    let meshes = VesselMeshCache()
    private let pool: TexturePool
    private let history: HistoryTargets
    private let fallbacks: FallbackTextures
    private var arenas: [FrameArena] = []
    private var arenaIndex = 0
    private let inFlight = DispatchSemaphore(value: SceneRenderer.framesInFlight)
    private var size: RenderSize?
    private var previousViewProjection: simd_float4x4?

    public enum Failure: Error { case noDevice, noResources }

    /// The renderer with the default passes (`defaultPasses`) on the
    /// default target plan: 4× MSAA in `outputFormat`.
    public convenience init(device: MTLDevice? = nil, outputFormat: MTLPixelFormat = .bgra8Unorm_srgb,
                            sampleCount: Int = SceneRenderer.defaultSampleCount,
                            loadsUserTextures: Bool = true) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        let samples = device.supportsTextureSampleCount(sampleCount) ? sampleCount : 1
        try self.init(device: device, outputFormat: outputFormat,
                      passes: Self.defaultPasses(loadsUserTextures: loadsUserTextures),
                      plan: DirectTargetPlan(colorFormat: outputFormat, sampleCount: samples))
    }

    public init(device: MTLDevice, outputFormat: MTLPixelFormat, passes: [RenderPass], plan: SceneTargetPlan) throws {
        guard let queue = device.makeCommandQueue(), let states = CommonStates(device: device),
              let fallbacks = FallbackTextures(device: device) else { throw Failure.noResources }
        self.device = device
        self.queue = queue
        self.outputFormat = outputFormat
        self.states = states
        self.fallbacks = fallbacks
        shaders = ShaderLibrary(device: device)
        pool = TexturePool(device: device)
        history = HistoryTargets(device: device)
        graph = FrameGraph(passes: passes, plan: plan)
        arenas = (0..<Self.framesInFlight).compactMap { _ in FrameArena(device: device, capacity: 1 << 18) }
        guard arenas.count == Self.framesInFlight else { throw Failure.noResources }
        fallbacks.clear(on: queue)
        graph.setUp(device: device, shaders: shaders, states: states)
    }

    /// Every slot P0-P5, in order: today's stars, planets, vessels, orbit
    /// line, plumes, far points and markers, and each track's stub.
    public static func defaultPasses(loadsUserTextures: Bool = true) -> [RenderPass] {
        [
            // P0
            AtmosphereLUTPass(), CloudPass(), ShadowPass(), EnvironmentProbePass(), ParticleSimulationPass(),
            // P1
            StarPass(), PlanetPass(loadsUserTextures: loadsUserTextures), VesselPass(),
            // P2
            AtmosphereCompositePass(),
            // P3
            OrbitLinePass(), PlumePass(), FarPointPass(), HalfResTransparentPass(), ParticleDrawPass(), EntryPass(),
            // P4
            PostPass(),
            // P5
            MarkerPass(),
        ]
    }

    /// Passes that could not be set up, and shader modules that failed, with why.
    public var failures: [String: String] {
        graph.failures.merging(shaders.errors.mapValues { "shader module: \($0)" }) { a, _ in a }
    }

    /// The star catalogue the star pass draws.
    public func setStars(_ stars: [Star]) {
        (graph.passes.first { $0 is StarPass } as? StarPass)?.setStars(stars)
    }

    /// Encodes `scene` into `output` and commits, presenting `drawable` if
    /// given. Waits first while three frames are in flight. `completion`
    /// runs on Metal's thread when the GPU is done.
    @discardableResult
    public func render(_ scene: RenderScene, to output: MTLTexture, present drawable: MTLDrawable? = nil,
                       completion: (@Sendable (MTLCommandBuffer) -> Void)? = nil) -> MTLCommandBuffer? {
        // Wait for the GPU to finish with the oldest frame's arena.
        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return nil
        }
        let encodeStart = CACurrentMediaTime()
        let semaphore = inFlight, times = self.times
        cb.addCompletedHandler { cb in
            times.addGPU(cb.gpuEndTime - cb.gpuStartTime)
            semaphore.signal()
            completion?(cb)
        }
        let arena = arenas[arenaIndex]
        arenaIndex = (arenaIndex + 1) % arenas.count
        arena.reset()

        let size = RenderSize(width: output.width, height: output.height)
        if size != self.size {
            self.size = size
            pool.purge()
            history.purge()
            graph.resize(size, device: device)
        }
        pool.beginFrame()
        if scene.clock.temporalReset { history.invalidate() }
        meshes.update(scene, device: device)

        let f = FrameContext(scene: scene, device: device, commandBuffer: cb, output: output, settings: settings,
                             arena: arena, pool: pool, history: history, states: states, meshes: meshes,
                             fallbacks: fallbacks, previousViewProjection: previousViewProjection)
        graph.encode(f)
        history.endFrame()
        previousViewProjection = f.viewProjection

        if let drawable { cb.present(drawable) }
        cb.commit()
        times.addEncode(CACurrentMediaTime() - encodeStart)
        return cb
    }
}

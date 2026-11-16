import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The environment probe (P0, track R3): each frame a radiance cube at the
/// camera target and the maps the surfaces light with.
///
/// 1. **Radiance** (`ProbeSettings.faceSize`², rgba16Float, cd/m², not
///    pre-exposed, NaN-free below 6e4): six 90° faces, each drawn through
///    the planets' probe entry point (`PlanetPass.encodeProbe`: the ground,
///    E1's albedo tiles, its haze), A2's sky (`AtmosphereCompositePass.
///    encodeProbe`) and C2's far cloud layers (`CloudPass.encodeProbe`).
///    The Sun is not in it: it stays the analytic light. Or an analytic
///    look-dev environment (`ProbeSettings.environment`). Then its mips.
/// 2. **Specular** (texture slot 20): mip 0 the radiance, mip k ≥ 1 GGX-
///    prefiltered at perceptual roughness k/(mips − 1) by filtered importance
///    sampling (`EnvironmentProbe.prefilterReference` is its limit).
/// 3. **Irradiance** (slot 21, 16², E/π in cd/m²): brute-force cosine
///    convolution of the 32² downsample.
/// 4. **SH9** of the same downsample, E/π coefficients, copied into this
///    frame's `LightingUniforms.sh9` once the shared uniforms are uploaded
///    (`FrameContext.copyIntoLighting`), for the plumes and particles
///    (`.sphericalHarmonics` header).
/// 5. `LightingUniforms.probe` (centre, mip count) and `ambient` (the night
///    floor as E/π relative to the exposure, the light's scale).
///
/// The faces are drawn two a frame in turn while nothing moves enough to
/// make one stale, and all six on any jump, new settings, a warp above 10×
/// (the Earth turning under the vessel at 1000× is never stale), a centre
/// moved over 1 km or a Sun turned over 0.05° (`fullUpdate`); the derived
/// maps every frame. Their dispatches run concurrently; a one-command blit
/// ends the pass, so the driver does not merge its compute with the next
/// pass's. The lighting uniforms then live in a buffer of their own
/// (`FrameArena.pushSeparately`): the SH9 copy into the arena made every
/// later encoder wait for C2's march (6.2 ms on the pad).
@MainActor
public final class EnvironmentProbePass: RenderPass {
    public let name = "Environment probe"
    public let stage = PassStage.prepare
    /// After A2's tables, C2's clouds and R4's shadows (and E1's tiles, order 5).
    public let order = 30
    public var reads: Set<ResourceID> { [] }
    public var writes: Set<ResourceID> { [.environment] }

    /// The irradiance cube's side.
    public static let irradianceSize = 16
    /// The side of the downsample irradiance and SH9 are taken from.
    public static let sourceSize = 32
    /// The prefilter's lod bias (Křivánek and Colbert's +1 blurs a wide lobe
    /// well past the reference) and the source mips it never reads (a 2²
    /// face's box average is no lobe).
    static let lodBias = 0.5
    static let coarsestSourceSkipped = 2

    /// GGX samples per texel at specular mip `mip`: `prefilterSamples`
    /// doubling each mip (the lobe widens and the texels thin out), at most
    /// eight times.
    static func prefilterSamples(mip: Int, settings: ProbeSettings) -> Int {
        max(settings.prefilterSamples, 1) << min(max(mip - 1, 0), 3)
    }

    /// Steps of the ground's haze marched in the probe's faces from above the air.
    public static let groundSteps = 8
    /// Steps of the air marched in front of the clouds in the faces.
    public static let cloudHazeSteps = 6
    /// Faces drawn a frame while nothing moves enough to make a face stale
    /// (`fullUpdate`): the six in three frames.
    public static let facesPerFrame = 2
    /// Above this warp every face is drawn every frame.
    public static let roundRobinMaximumWarp = 10.0
    /// Beyond this distance from the camera the probe stays at the camera:
    /// A2's sky is the camera's.
    public static let maximumTargetDistance = 50_000.0

    private weak var planets: PlanetPass?
    private weak var vessels: VesselPass?
    private weak var sky: AtmosphereCompositePass?
    private weak var clouds: CloudPass?

    private var device: MTLDevice?
    private var pipelines: (lookDev: MTLComputePipelineState, prefilter: MTLComputePipelineState,
                            irradiance: MTLComputePipelineState, sh9: MTLComputePipelineState)?
    private var fallback2D: MTLTexture?
    private var mergeBreak: MTLBuffer?
    private var sh9Buffer: MTLBuffer?
    private var sourceTexels: MTLBuffer?

    /// The probe's textures, for one face size and mip count.
    struct Maps {
        let size: Int
        let mips: Int
        let radiance: MTLTexture
        let radianceFaces: MTLTexture
        let source: MTLTexture
        let specular: MTLTexture
        let specularLevels: [MTLTexture]
        let irradiance: MTLTexture
        let irradianceFaces: MTLTexture
        let depth: MTLTexture
    }
    private(set) var maps: Maps?
    /// What the last frame drew, for the tests.
    public private(set) var lastFrame = Report()

    public struct Report: Equatable {
        public var drawn = false
        public var environment = ProbeEnvironment.scene
        /// The probe's centre, camera-relative (m).
        public var center = Vec3.zero
        public var faceSize = 0
        public var mips = 0
        public var nightFloor: Float = 0
        /// Faces drawn this frame: 6 on a full update, else `facesPerFrame`.
        public var facesDrawn = 0
    }

    /// What the faces were last drawn for.
    struct FaceState {
        var frameIndex: Int
        var center: Vec3
        var toSun: Vec3
        var settings: ProbeSettings
        var size: Int
    }
    private var lastFaces: FaceState?
    private var faceCursor = 0

    /// Whether every face is drawn this frame: the first, or after a
    /// temporal reset (a jump, a new target, a warp change), a frame that
    /// does not follow the last one drawn, new settings or maps, a warp above
    /// `roundRobinMaximumWarp` (the Earth turns under the vessel), the centre
    /// moved more than 1 km or the Sun more than 0.05° since last frame. At
    /// 1× a face is then at most two frames old: 400 m of LEO, 0.0002° of Sun.
    static func fullUpdate(_ now: FaceState, after last: FaceState?, clock: RenderScene.Clock) -> Bool {
        guard let last else { return true }
        return clock.temporalReset || now.frameIndex != last.frameIndex + 1 || now.settings != last.settings
            || now.size != last.size || clock.warp > roundRobinMaximumWarp
            || (now.center - last.center).length > 1_000
            || now.toSun.dot(last.toSun) < cos(0.05 * Double.pi / 180)
    }

    public init() {}

    /// The passes the faces are drawn through: the first planet pass, A2's
    /// composite, C2's clouds and R2's vessel pass (for the pad) among
    /// `passes` (the renderer connects its graph's own; none of them, and the
    /// faces hold only the black sky).
    public func connect(_ passes: [RenderPass]) {
        planets = passes.lazy.compactMap { $0 as? PlanetPass }.first
        vessels = passes.lazy.compactMap { $0 as? VesselPass }.first
        sky = passes.lazy.compactMap { $0 as? AtmosphereCompositePass }.first
        clouds = passes.lazy.compactMap { $0 as? CloudPass }.first
    }

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.probe)
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw ShaderLibrary.Failure.missingFunction(name) }
            return try s.device.makeComputePipelineState(function: f)
        }
        pipelines = (try compute("probe_lookDev"), try compute("probe_prefilter"), try compute("probe_irradiance"),
                     try compute("probe_sh9"))
        device = s.device
        maps = nil
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        fallback2D = s.device.makeTexture(descriptor: d)
        var zero = [UInt16](repeating: 0, count: 4)
        fallback2D?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 8)
        mergeBreak = s.device.makeBuffer(length: 16, options: .storageModePrivate)
        sh9Buffer = s.device.makeBuffer(length: 9 * 16, options: .storageModePrivate)
        sh9Buffer?.label = "Probe SH9"
        // The downsample's texel directions and solid angles.
        let texels = EnvironmentProbe.texels(size: Self.sourceSize).map {
            SIMD4<Float>(Float($0.direction.x), Float($0.direction.y), Float($0.direction.z), Float($0.solidAngle))
        }
        sourceTexels = texels.withUnsafeBytes {
            s.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
    }

    public func isActive(in f: FrameContext) -> Bool { f.settings.probe.enabled }

    // MARK: The frame

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        lastFrame = Report()
        let settings = f.settings.probe
        guard let device, let pipelines, let sh9Buffer, let sourceTexels,
              let maps = maps(size: settings.resolvedFaceSize, mips: settings.resolvedSpecularMips, device: device)
        else { return }
        let center = Self.center(f.scene)

        // 1. The radiance: every face when anything may have made one stale,
        // else two a frame in turn.
        let state = FaceState(frameIndex: f.scene.clock.frameIndex, center: center, toSun: f.scene.sun.direction,
                              settings: settings, size: maps.size)
        let full = Self.fullUpdate(state, after: lastFaces, clock: f.scene.clock)
        switch settings.environment {
        case .scene:
            let faces = full ? EnvironmentProbe.Face.allCases
                : (0..<Self.facesPerFrame).compactMap { EnvironmentProbe.Face(rawValue: (faceCursor + $0) % 6) }
            if !full { faceCursor = (faceCursor + Self.facesPerFrame) % 6 }
            drawFaces(f, maps: maps, center: center, settings: settings, faces: faces)
            lastFrame.facesDrawn = faces.count
        case .furnace, .earthBelow, .earthUniform:
            guard let enc = f.makeComputeEncoder() else { return }
            var u = Self.lookDevUniforms(settings, scene: f.scene)
            enc.setComputePipelineState(pipelines.lookDev)
            enc.setTexture(maps.radianceFaces, index: 0)
            enc.setBytes(&u, length: MemoryLayout<ProbeLookDevUniforms>.stride, index: 0)
            Self.dispatch(enc, pipelines.lookDev, width: maps.size, height: maps.size, depth: 6)
            enc.endEncoding()
        }

        // 2. Its mips, and the specular cube's mirror level.
        guard let blit = f.makeBlitEncoder() else { return }
        blit.generateMipmaps(for: maps.radiance)
        blit.copy(from: maps.radiance, sourceSlice: 0, sourceLevel: 0, to: maps.specular, destinationSlice: 0,
                  destinationLevel: 0, sliceCount: 6, levelCount: 1)
        blit.endEncoding()

        // 3. The prefiltered mips, the irradiance and SH9, which depend on
        // none of each other: their dispatches run concurrently.
        let concurrent = MTLComputePassDescriptor()
        concurrent.dispatchType = .concurrent
        f.profile?.attach(concurrent, pass: name)
        guard let enc = f.commandBuffer.makeComputeCommandEncoder(descriptor: concurrent) else { return }
        enc.label = name
        enc.setComputePipelineState(pipelines.prefilter)
        enc.setTexture(maps.radiance, index: 0)
        for (k, level) in maps.specularLevels.enumerated() {
            let mip = k + 1
            let alpha = BRDF.alpha(roughness: EnvironmentProbe.roughness(mip: mip, count: maps.mips))
            var u = (SIMD4<Float>(Float(alpha), Float(Self.prefilterSamples(mip: mip, settings: settings)),
                                  Float(maps.size), Float(maps.radiance.mipmapLevelCount)),
                     SIMD4<Float>(Float(Self.lodBias), Float(maps.radiance.mipmapLevelCount - 1 - Self.coarsestSourceSkipped),
                                  0, 0))
            enc.setTexture(level, index: 1)
            enc.setBytes(&u, length: 32, index: 0)
            // 32 lanes to a texel.
            enc.dispatchThreads(MTLSize(width: 32 * level.width, height: level.height, depth: 6),
                                threadsPerThreadgroup: MTLSize(width: 32, height: min(level.height, 8), depth: 1))
        }
        enc.setComputePipelineState(pipelines.irradiance)
        enc.setTexture(maps.source, index: 0)
        enc.setTexture(maps.irradianceFaces, index: 1)
        enc.setBuffer(sourceTexels, offset: 0, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: Self.irradianceSize, depth: 6),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.setComputePipelineState(pipelines.sh9)
        enc.setBuffer(sh9Buffer, offset: 0, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(256, pipelines.sh9.maxTotalThreadsPerThreadgroup),
                                                                height: 1, depth: 1))
        enc.endEncoding()
        // The next pass's compute must not merge with this one.
        if let mergeBreak, let fence = f.makeBlitEncoder() {
            fence.fill(buffer: mergeBreak, range: 0..<16, value: 0)
            fence.endEncoding()
        }

        // 4. Published.
        f.slotTextures[Binding.environmentSpecular] = maps.specular
        f.slotTextures[Binding.environmentIrradiance] = maps.irradiance
        f.textures[.environment] = maps.specular
        let floor = Float(EnvironmentProbe.nightFloor(share: max(settings.nightFloor, 0),
                                                      preExposure: Double(f.frame.exposure.x)))
        f.lighting.probe = SIMD4(center, Float(maps.mips))
        f.lighting.ambient = SIMD4(floor, floor, floor, Float(max(settings.intensity, 0)))
        if let member = MemoryLayout<LightingUniforms>.offset(of: \.sh9) {
            f.copyIntoLighting(from: sh9Buffer, offset: 0, member: member, length: 9 * 16)
        }
        let facesDrawn = settings.environment == .scene ? lastFrame.facesDrawn : 6
        lastFrame = Report(drawn: true, environment: settings.environment, center: center, faceSize: maps.size,
                           mips: maps.mips, nightFloor: floor, facesDrawn: facesDrawn)
        lastFaces = state
    }

    /// The probe's centre, camera-relative: the camera target's when it is a
    /// vessel within `maximumTargetDistance`, else the camera's.
    static func center(_ scene: RenderScene) -> Vec3 {
        guard case .vessel(let id) = scene.camera.target, let v = scene.vessels.first(where: { $0.id == id }),
              v.position.length <= maximumTargetDistance else { return .zero }
        return v.position
    }

    /// The six faces of the scene, each its own render pass: the planets
    /// (depth written), the sky behind them, the clouds over both.
    private func drawFaces(_ f: FrameContext, maps: Maps, center: Vec3, settings: ProbeSettings,
                           faces: [EnvironmentProbe.Face]) {
        let formats = SceneFormats(color: maps.radiance.pixelFormat, depth: maps.depth.pixelFormat, sampleCount: 1,
                                   output: maps.radiance.pixelFormat)
        // The frame's uniforms in cd/m²: pre-exposure 1.
        var frame = f.frame
        frame.exposure.x = 1
        var atmosphere = f.atmosphere
        let near = max(f.scene.camera.near, 0.25)
        for face in faces {
            let pass = MTLRenderPassDescriptor()
            let c = pass.colorAttachments[0]!
            c.texture = maps.radiance
            c.slice = face.rawValue
            c.level = 0
            c.loadAction = .clear
            c.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            c.storeAction = .store
            pass.depthAttachment.texture = maps.depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .dontCare
            guard let enc = f.makeRenderEncoder(pass) else { continue }
            enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Binding.frameBuffer)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: Binding.frameBuffer)
            enc.setFragmentBytes(&atmosphere, length: MemoryLayout<AtmosphereUniforms>.stride,
                                 index: Binding.atmosphereBuffer)
            for slot in [Binding.transmittanceLUT, Binding.multipleScatteringLUT, Binding.skyViewLUT,
                         Binding.cloudShadow] {
                enc.setFragmentTexture(f.slotTextures[slot] ?? fallback2D, index: slot)
            }
            enc.setFragmentSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
            let b = EnvironmentProbe.basis(face)
            let viewToWorld = simd_float4x4(columns: (SIMD4<Float>(b.right, 0), SIMD4<Float>(b.up, 0),
                                                      SIMD4<Float>(-b.forward, 0), SIMD4<Float>(0, 0, 0, 1)))
            planets?.encodeProbe(f, on: enc, formats: formats, viewToWorld: viewToWorld, center: center,
                                 faceSize: maps.size, groundSteps: Self.groundSteps, near: near)
            sky?.encodeProbe(f, on: enc, formats: formats, viewToWorld: viewToWorld, tanHalfFov: 1,
                             faceSize: maps.size, preExposure: 1, depth: 0)
            if settings.clouds {
                clouds?.encodeProbe(f, on: enc, formats: formats, viewToWorld: viewToWorld, faceSize: maps.size,
                                    hazeSteps: Self.cloudHazeSteps)
            }
            // The pad last: opaque over the sky and the clouds, in front of the ground.
            if settings.sites {
                let projection = simd_float4x4.reversedInfinitePerspective(fovY: Float.pi / 2, aspect: 1, near: Float(near))
                vessels?.encodeProbe(f, on: enc, formats: formats, viewProjection: projection * viewToWorld.transpose,
                                     center: center, faceSize: maps.size)
            }
            enc.endEncoding()
        }
    }

    // MARK: Textures

    private func maps(size: Int, mips: Int, device: MTLDevice) -> Maps? {
        if let maps, maps.size == size, maps.mips == mips { return maps }
        let full = Int(log2(Double(size))) + 1
        func cube(_ n: Int, levels: Int, usage: MTLTextureUsage, label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: n, mipmapped: levels > 1)
            d.mipmapLevelCount = levels
            d.usage = usage
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        func faces(_ t: MTLTexture, level: Int) -> MTLTexture? {
            t.makeTextureView(pixelFormat: t.pixelFormat, textureType: .type2DArray, levels: level..<(level + 1),
                              slices: 0..<6)
        }
        let sourceLevel = max(0, Int(log2(Double(size))) - Int(log2(Double(Self.sourceSize))))
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size,
                                                          mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .memoryless
        guard let radiance = cube(size, levels: full, usage: [.renderTarget, .shaderRead, .shaderWrite],
                                  label: "Probe radiance"),
              let radianceFaces = faces(radiance, level: 0), let source = faces(radiance, level: sourceLevel),
              let specular = cube(size, levels: mips, usage: [.shaderRead, .shaderWrite], label: "Probe specular"),
              let irradiance = cube(Self.irradianceSize, levels: 1, usage: [.shaderRead, .shaderWrite],
                                    label: "Probe irradiance"),
              let irradianceFaces = faces(irradiance, level: 0),
              let depth = device.makeTexture(descriptor: dd) else { return nil }
        let levels = (1..<mips).compactMap { faces(specular, level: $0) }
        guard levels.count == mips - 1 else { return nil }
        maps = Maps(size: size, mips: mips, radiance: radiance, radianceFaces: radianceFaces, source: source,
                    specular: specular, specularLevels: levels, irradiance: irradiance, irradianceFaces: irradianceFaces,
                    depth: depth)
        return maps
    }

    static func lookDevUniforms(_ s: ProbeSettings, scene: RenderScene) -> ProbeLookDevUniforms {
        let env: EnvironmentProbe.LookDevEnvironment
        switch s.environment {
        case .earthBelow:
            env = .earthBelow(toSun: scene.sun.direction, sunLux: scene.sun.illuminance)
        case .earthUniform:
            env = .earthUniform(sunLux: scene.sun.illuminance)
        default:
            env = .furnace(s.furnaceRadiance)
        }
        func v(_ c: Spectrum3) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), 0) }
        return ProbeLookDevUniforms(kind: SIMD4(Float(env.kind.rawValue), 0, 0, 0), radiance: v(env.radiance),
                                    body: SIMD4(env.bodyDirection, Float(env.bodySinSigma2)),
                                    reflectance: v(env.reflectance), toSun: SIMD4(env.toSun, 0),
                                    sun: v(env.sunIlluminance))
    }

    static func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, width: Int, height: Int,
                         depth: Int) {
        let w = min(p.threadExecutionWidth, 16), h = max(min(p.maxTotalThreadsPerThreadgroup / w, 16), 1)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: depth),
                            threadsPerThreadgroup: MTLSize(width: min(w, width), height: min(h, height), depth: 1))
    }
}

/// Swift mirror of ProbeShaders' `ProbeLookDev`.
struct ProbeLookDevUniforms {
    var kind: SIMD4<Float>
    var radiance: SIMD4<Float>
    var body: SIMD4<Float>
    var reflectance: SIMD4<Float>
    var toSun: SIMD4<Float>
    var sun: SIMD4<Float>
}

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
///    encodeProbe`), C2's far cloud layers (`CloudPass.encodeProbe`) and
///    the pad (`VesselPass.encodeProbe`), all seen from the probe's centre:
///    the sky and the ground's haze from the camera's sky-view LUT where A2
///    allows (both inside the air, within 2 km and 300 m of altitude:
///    `AtmosphereCompositePass.probeReadsSkyView`), else marched from the
///    centre; switching between the two redraws every face.
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
/// The faces are redrawn by how stale they could be (`update`, measured in
/// the nearest body's fixed frame, so a camera orbiting its target moves
/// nothing): `facesPerFrame` (2) in turn while steady; three a frame while
/// the centre moves over the ground, or the Sun turns, by more than half a
/// texel a frame as seen from the centre (LEO from about 11×, and the
/// extractor's turn-only resets at 1e4× and up); all six on a new target,
/// warp, settings, nearest body or centre (target or camera), a switch of
/// the sky between the camera's LUT and the centre's march, or a skipped
/// frame. While paused they finish their turn and stop, but redraw on motion
/// and when E1's tiles stream in (`FaceSchedule`). The derived maps on every
/// frame that draws a face; their dispatches run concurrently; a
/// one-command blit ends the pass, so the driver does not merge its compute
/// with the next pass's. The lighting uniforms then live in a buffer of
/// their own (`FrameArena.pushSeparately`): the SH9 copy into the arena made
/// every later encoder wait for C2's march (6.2 ms on the pad).
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
    /// Faces drawn a frame while the probe moves fast (`Update.moving`):
    /// each face at most one frame old.
    public nonisolated static let movingFacesPerFrame = 3
    /// Beyond this distance from the camera the probe stays at the camera:
    /// a target that far is a few pixels across, and the camera's
    /// surroundings light what is near it.
    public static let maximumTargetDistance = 50_000.0

    private weak var planets: PlanetPass?
    private weak var vessels: VesselPass?
    private weak var sky: AtmosphereCompositePass?
    private weak var clouds: CloudPass?

    private var device: MTLDevice?
    private var pipelines: (lookDev: MTLComputePipelineState, prefilter: MTLComputePipelineState,
                            irradiance: MTLComputePipelineState, sh9: MTLComputePipelineState,
                            clean: MTLComputePipelineState)?
    private var fallback2D: MTLTexture?
    private var mergeBreak: MTLBuffer?
    private var sh9Buffer: MTLBuffer?
    private var sourceTexels: MTLBuffer?

    /// The probe's textures, for one face size and mip count.
    struct Maps {
        let size: Int
        let mips: Int
        let radiance: MTLTexture
        /// The radiance's mip read as the 32² source (irradiance, SH9).
        let sourceMip: Int
        let specular: MTLTexture
        let irradiance: MTLTexture
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
        /// The faces drawn this frame (`EnvironmentProbe.Face` raw values), as
        /// `FaceSchedule` picks them: all six on a full update, three in turn
        /// while moving, `facesPerFrame` in turn while steady; paused, the
        /// turn since the last change and then none, but motion, full updates
        /// and tiles streaming in still draw.
        public var faces: [Int] = []
        /// Whether the derived maps were rebuilt (not while paused and current).
        public var derived = false
        /// Whether the sky and the planet's haze were marched from the centre
        /// (else read from the camera's sky-view LUT).
        public var skyFromCentre = false
        public var facesDrawn: Int { faces.count }
    }

    /// Where the faces were drawn from, in the frame their content lives in.
    struct FaceState {
        var frameIndex: Int
        /// The nearest body's id (0 for none) and the probe's centre in its
        /// body-fixed axes relative to it (m), or barycentric without a body.
        var body: Int
        var anchor: Vec3
        /// The centre's height over that body's figure (m, geodetic: on the
        /// pad about 55 m, not the 16 km over the polar radius), the scale its
        /// motion is seen at; 1 km without a body.
        var height: Double
        /// The Sun's direction in the same axes.
        var toSun: Vec3
        var settings: RenderSettings
        var target: CameraTarget
        var warp: Double
        /// Whether the centre is the target vessel (else the camera).
        var onTarget: Bool
        /// E1's resident albedo tiles (−1 without the store).
        var tiles: Int
        /// Whether the sky and the planet's haze are marched from the centre
        /// rather than read from the camera's sky-view LUT
        /// (`AtmosphereCompositePass.probeReadsSkyView`).
        var skyFromCentre: Bool

        init(_ scene: RenderScene, center: Vec3, settings: RenderSettings, tiles: Int = -1, skyFromCentre: Bool = false) {
            frameIndex = scene.clock.frameIndex
            self.settings = settings
            target = scene.camera.target
            warp = scene.clock.warp
            onTarget = center != .zero
            self.tiles = tiles
            self.skyFromCentre = skyFromCentre
            if let b = scene.bodies.filter({ !$0.isSun }).min(by: {
                ($0.position - center).length < ($1.position - center).length }) {
                body = b.id
                anchor = b.orientation.toBody(center - b.position)
                height = max(b.figure.geodetic(anchor).height, 1)
                toSun = b.orientation.toBody(scene.sun.direction)
            } else {
                body = 0
                anchor = scene.camera.position + center
                height = 1_000
                toSun = scene.sun.direction
            }
        }
    }

    enum Update { case full, moving, steady }
    private var lastFaces: FaceState?
    private var schedule = FaceSchedule()

    /// A new sequence (`SceneRenderer.startOver`): the next frame draws every
    /// face, as a fresh pass's first does. Else a shot whose frame index
    /// follows the last shot's, with the same body, target and settings,
    /// would redraw some faces and keep the last shot's sky in the others.
    public func startOver() {
        lastFaces = nil
        schedule = FaceSchedule()
    }

    /// How this frame's faces are drawn:
    /// - `full`, every face: the first frame, a frame that does not follow
    ///   the last one drawn, new render settings, another nearest body, a new
    ///   camera target or warp, the centre switched between the target and
    ///   the camera, or its sky between the camera's LUT and its own march.
    /// - `moving`, `movingFacesPerFrame` in turn (each face one frame old):
    ///   the centre moved over the nearest body's ground, or the Sun turned in
    ///   its frame, by more than half a texel of the face (`size`) as seen
    ///   from the centre since last frame (LEO from about 11× warp); or the
    ///   extractor's temporal reset for the body turning alone (same target,
    ///   same warp: every frame from 1e4×, where half a cube a frame behind
    ///   is no worse than the frame's own strobe).
    /// - `steady`, `ProbeSettings.facesPerFrame` in turn: a face is then at
    ///   most two frames old and a texel off.
    /// Measured where the faces' content lives, so a camera orbiting its
    /// target moves nothing.
    static func update(_ now: FaceState, after last: FaceState?, clock: RenderScene.Clock, size: Int) -> Update {
        guard let last, now.frameIndex == last.frameIndex + 1, now.settings == last.settings, now.body == last.body,
              now.target == last.target, now.warp == last.warp, now.onTarget == last.onTarget,
              now.skyFromCentre == last.skyFromCentre else { return .full }
        if clock.temporalReset { return .moving }
        let halfTexel = 1 / Double(max(size, 1))
        let shift = (now.anchor - last.anchor).length / max(min(now.height, last.height), 1)
        let turn = acos(min(max(now.toSun.dot(last.toSun), -1), 1))
        return shift > halfTexel || turn > halfTexel ? .moving : .steady
    }

    /// Which faces a frame draws, in turn.
    struct FaceSchedule {
        var cursor = 0
        /// While paused: the faces drawn since the pause or the last change.
        var pausedFaces: Set<Int> = []

        /// `steady` faces a frame, `movingFacesPerFrame` while moving, all six
        /// on a full update. While paused, steady frames finish the turn
        /// since the last change and then draw nothing; motion and a full
        /// update draw as running, and tiles streaming in (`tilesChanged`)
        /// start the turn again.
        mutating func next(_ update: Update, paused: Bool, steady: Int, tilesChanged: Bool) -> [Int] {
            let perFrame = update == .moving ? max(steady, movingFacesPerFrame) : min(max(steady, 1), 6)
            if update == .full || perFrame >= 6 {
                pausedFaces = paused ? Set(0..<6) : []
                return Array(0..<6)
            }
            if paused, update == .moving || tilesChanged { pausedFaces = [] }
            if paused, pausedFaces.count == 6 { return [] }
            let drawn = (0..<perFrame).map { (cursor + $0) % 6 }
            cursor = (cursor + perFrame) % 6
            pausedFaces = paused ? pausedFaces.union(drawn) : []
            return drawn
        }
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
                     try compute("probe_sh9"), try compute("probe_cleanFaces"))
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

        // 1. The radiance: the faces `update` and `FaceSchedule` pick (all on
        // a full update, three while moving, `facesPerFrame` while steady;
        // paused, the turn since the last change, then none until motion, a
        // full update or new tiles).
        let tiles = planets?.tiles?.layer(.albedo)?.residency.residentCount ?? -1
        let skyFromCentre = !(sky?.probeReadsSkyView(f, center: center) ?? false)
        let state = FaceState(f.scene, center: center, settings: f.settings, tiles: tiles, skyFromCentre: skyFromCentre)
        let update = Self.update(state, after: lastFaces, clock: f.scene.clock, size: maps.size)
        let tilesChanged = lastFaces.map { $0.tiles != tiles } ?? false
        lastFaces = state
        var drawn: [Int] = []
        switch settings.environment {
        case .scene:
            drawn = schedule.next(update, paused: f.scene.clock.paused, steady: settings.facesPerFrame,
                                  tilesChanged: tilesChanged)
            if !drawn.isEmpty {
                drawFaces(f, maps: maps, center: center, settings: settings, skyFromCentre: skyFromCentre,
                          faces: drawn.compactMap { EnvironmentProbe.Face(rawValue: $0) })
                // Blends of terms each below 6e4 can store +inf: clean the
                // faces before their mips and the derived maps read them.
                if let enc = f.makeComputeEncoder() {
                    enc.setComputePipelineState(pipelines.clean)
                    enc.setTexture(maps.radiance, index: 0)
                    enc.setTexture(maps.radiance, index: 1)
                    Self.dispatch(enc, pipelines.clean, width: maps.size, height: maps.size, depth: 6)
                    enc.endEncoding()
                }
            }
        case .furnace, .earthBelow, .earthUniform:
            drawn = Array(0..<6)
            guard let enc = f.makeComputeEncoder() else { return }
            var u = Self.lookDevUniforms(settings, scene: f.scene)
            enc.setComputePipelineState(pipelines.lookDev)
            enc.setTexture(maps.radiance, index: 0)
            enc.setBytes(&u, length: MemoryLayout<ProbeLookDevUniforms>.stride, index: 0)
            Self.dispatch(enc, pipelines.lookDev, width: maps.size, height: maps.size, depth: 6)
            enc.endEncoding()
        }

        // The derived maps are current while no face was drawn.
        if !drawn.isEmpty { encodeDerivedMaps(f, maps: maps, settings: settings, pipelines: pipelines,
                                              sourceTexels: sourceTexels, sh9Buffer: sh9Buffer) }
        publish(f, maps: maps, settings: settings, center: center, sh9Buffer: sh9Buffer)
        lastFrame = Report(drawn: true, environment: settings.environment, center: center, faceSize: maps.size,
                           mips: maps.mips, nightFloor: f.lighting.ambient.x, faces: drawn, derived: !drawn.isEmpty,
                           skyFromCentre: state.skyFromCentre)
    }

    /// The radiance's mips, the specular cube, the irradiance and SH9.
    private func encodeDerivedMaps(_ f: FrameContext, maps: Maps, settings: ProbeSettings,
                                   pipelines: (lookDev: MTLComputePipelineState, prefilter: MTLComputePipelineState,
                                               irradiance: MTLComputePipelineState, sh9: MTLComputePipelineState,
                                               clean: MTLComputePipelineState),
                                   sourceTexels: MTLBuffer, sh9Buffer: MTLBuffer) {
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
        enc.setTexture(maps.specular, index: 1)
        for mip in 1..<maps.mips {
            let alpha = BRDF.alpha(roughness: EnvironmentProbe.roughness(mip: mip, count: maps.mips))
            var u = (SIMD4<Float>(Float(alpha), Float(Self.prefilterSamples(mip: mip, settings: settings)),
                                  Float(maps.size), Float(maps.radiance.mipmapLevelCount)),
                     SIMD4<Float>(Float(Self.lodBias), Float(maps.radiance.mipmapLevelCount - 1 - Self.coarsestSourceSkipped),
                                  Float(mip), 0))
            let n = max(maps.size >> mip, 1)
            enc.setBytes(&u, length: 32, index: 0)
            // 32 lanes to a texel.
            enc.dispatchThreads(MTLSize(width: 32 * n, height: n, depth: 6),
                                threadsPerThreadgroup: MTLSize(width: 32, height: min(n, 8), depth: 1))
        }
        var sourceMip = UInt32(maps.sourceMip)
        enc.setComputePipelineState(pipelines.irradiance)
        enc.setTexture(maps.radiance, index: 0)
        enc.setTexture(maps.irradiance, index: 1)
        enc.setBuffer(sourceTexels, offset: 0, index: 0)
        enc.setBytes(&sourceMip, length: 4, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: Self.irradianceSize, depth: 6),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.setComputePipelineState(pipelines.sh9)
        enc.setBuffer(sh9Buffer, offset: 0, index: 1)
        enc.setBytes(&sourceMip, length: 4, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(256, pipelines.sh9.maxTotalThreadsPerThreadgroup),
                                                                height: 1, depth: 1))
        enc.endEncoding()
        // The next pass's compute must not merge with this one.
        if let mergeBreak, let fence = f.makeBlitEncoder() {
            fence.fill(buffer: mergeBreak, range: 0..<16, value: 0)
            fence.endEncoding()
        }
    }

    /// 4. The maps in their slots, the probe's uniforms, SH9 into buffer 29.
    private func publish(_ f: FrameContext, maps: Maps, settings: ProbeSettings, center: Vec3, sh9Buffer: MTLBuffer) {
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
    private func drawFaces(_ f: FrameContext, maps: Maps, center: Vec3, settings: ProbeSettings, skyFromCentre: Bool,
                           faces: [EnvironmentProbe.Face]) {
        let formats = SceneFormats(color: maps.radiance.pixelFormat, depth: maps.depth.pixelFormat, sampleCount: 1,
                                   output: maps.radiance.pixelFormat)
        // The frame's uniforms in cd/m²: pre-exposure 1.
        var frame = f.frame
        frame.exposure.x = 1
        var atmosphere = f.atmosphere
        // C2's cloud shadow map takes camera-relative points; the faces' are
        // relative to the centre (LC-39A's draw shifts its own the same way).
        atmosphere.cloudShadowMatrix = f.atmosphere.cloudShadowMatrix * VesselPass.probeShift(center: center)
        // Where A2's sky is marched from the centre, the planet's haze is
        // too: its in-air path reads the camera's sky-view LUT, which the
        // camera's altitude in `radii.z` selects.
        if skyFromCentre { atmosphere.radii.z = atmosphere.radii.y - atmosphere.radii.x + 1 }
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
                         Binding.cloudShadow, Binding.cloudSky] {
                enc.setFragmentTexture(f.slotTextures[slot] ?? fallback2D, index: slot)
            }
            enc.setFragmentSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
            let b = EnvironmentProbe.basis(face)
            let viewToWorld = simd_float4x4(columns: (SIMD4<Float>(b.right, 0), SIMD4<Float>(b.up, 0),
                                                      SIMD4<Float>(-b.forward, 0), SIMD4<Float>(0, 0, 0, 1)))
            planets?.encodeProbe(f, on: enc, formats: formats, viewToWorld: viewToWorld, center: center,
                                 faceSize: maps.size, groundSteps: Self.groundSteps, near: near)
            sky?.encodeProbe(f, on: enc, formats: formats, viewToWorld: viewToWorld, tanHalfFov: 1,
                             faceSize: maps.size, preExposure: 1, depth: 0, center: center)
            if settings.clouds {
                clouds?.encodeProbe(f, on: enc, formats: formats, viewToWorld: viewToWorld, faceSize: maps.size,
                                    hazeSteps: Self.cloudHazeSteps, center: center)
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
        let sourceLevel = max(0, Int(log2(Double(size))) - Int(log2(Double(Self.sourceSize))))
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size,
                                                          mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .memoryless
        guard let radiance = cube(size, levels: full, usage: [.renderTarget, .shaderRead, .shaderWrite],
                                  label: "Probe radiance"),
              let specular = cube(size, levels: mips, usage: [.shaderRead, .shaderWrite], label: "Probe specular"),
              let irradiance = cube(Self.irradianceSize, levels: 1, usage: [.shaderRead, .shaderWrite],
                                    label: "Probe irradiance"),
              let depth = device.makeTexture(descriptor: dd) else { return nil }
        maps = Maps(size: size, mips: mips, radiance: radiance, sourceMip: sourceLevel, specular: specular,
                    irradiance: irradiance, depth: depth)
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

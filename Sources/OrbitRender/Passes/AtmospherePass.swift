import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

// Track A2: the atmosphere (docs/look/atmosphere.md). P0 uploads A1's tables
// once, then each frame fills `AtmosphereUniforms` (buffer 28) and renders
// the sky-view LUT and the aerial-perspective froxels; P2 draws the sky over
// what lies behind the air. The planet pass lights the Earth's ground
// through the same tables (AtmosphereCommon).

extension ResourceID {
    /// A1's sky-irradiance table (64 × 16, rgba32Float, per unit solar
    /// irradiance): bind it at a pass's own index (the planet module's 1).
    public static let atmosphereIrradiance = ResourceID("atmosphereIrradiance", persistent: true)
    /// A1's medium profile (1024 × 1, rgba32Float): the air's density over
    /// the ground's against altitude (the atmosphere module's and the planet
    /// module's texture 2... see each module).
    public static let atmosphereProfile = ResourceID("atmosphereProfile", persistent: true)
    /// The sky-view LUT (rgba32Float, cd/m²), also in texture slot 29.
    public static let skyView = ResourceID("skyView")
    /// From above the air, the haze over the ground for each pixel's ray at
    /// a reduced resolution: in-scattered luminance (rgba32Float, cd/m²)
    /// and the transmittance (rgba16Float), to the ground
    /// (`atmosphere_spaceGround`).
    public static let spaceGroundScatter = ResourceID("spaceGroundScatter")
    public static let spaceGroundTransmittance = ResourceID("spaceGroundTransmittance")
}

/// The atmosphere's LUTs and aerial-perspective froxels (P0).
///
/// - Once, and when the optics change: A1's transmittance (texture slot
///   25), multiple-scattering (28), irradiance and profile tables, uploaded
///   as they are (rgba32Float).
/// - Each frame: `FrameContext.atmosphere` (`AtmosphereUniforms`, buffer
///   28: the planet, the medium, the transmitted Sun and the sky's
///   irradiance at the camera, the froxels' slices); inside the atmosphere
///   the sky-view LUT (slot 29); and the froxels (slot 30).
@MainActor
public final class AtmosphereLUTPass: RenderPass {
    public let name = "Atmosphere LUTs"
    public let stage = PassStage.prepare
    public let order = 0
    public var writes: Set<ResourceID> {
        [.atmosphereLUTs, .aerialPerspective, .atmosphereIrradiance, .atmosphereProfile, .skyView, .spaceGroundScatter,
         .spaceGroundTransmittance]
    }

    /// What the composite (and R3's probe) take from this frame's P0.
    struct State {
        let frame: AtmosphereFrame
        let uniforms: AtmospherePassUniforms
        let profile: MTLTexture
        /// A1's tables, for a frame seen from elsewhere (R3's probe centre).
        let lut: AtmosphereLUT
    }

    /// This frame's state, handed to the passes after P0 (the frame is held
    /// weakly, so a later frame never sees it).
    private struct Handoff {
        weak var frame: FrameContext?
        let state: State
    }
    private static var handoff: Handoff?

    static func state(for f: FrameContext) -> State? {
        guard let h = handoff, h.frame === f else { return nil }
        return h.state
    }

    private struct Tables {
        let key: AtmosphereTables.Key
        let lut: AtmosphereLUT
        let transmittance: MTLTexture
        let multipleScattering: MTLTexture
        let irradiance: MTLTexture
        let profile: MTLTexture
    }

    private var device: MTLDevice?
    private var skyViewPipeline: MTLComputePipelineState?
    private var froxelPipeline: MTLComputePipelineState?
    private var spaceGroundPipeline: MTLComputePipelineState?
    private var spaceGround: (scatter: MTLTexture, transmittance: MTLTexture)?
    private var tables: Tables?
    private var skyView: MTLTexture?
    private var froxels: MTLTexture?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.atmosphere)
        guard let sky = library.makeFunction(name: "atmosphere_skyView"),
              let froxel = library.makeFunction(name: "atmosphere_froxels"),
              let ground = library.makeFunction(name: "atmosphere_spaceGround") else {
            throw ShaderLibrary.Failure.missingFunction("atmosphere_skyView / atmosphere_froxels / atmosphere_spaceGround")
        }
        skyViewPipeline = try s.device.makeComputePipelineState(function: sky)
        froxelPipeline = try s.device.makeComputePipelineState(function: froxel)
        spaceGroundPipeline = try s.device.makeComputePipelineState(function: ground)
        device = s.device
        // Start A1's tables now, so they are ready by the first frame.
        AtmosphereTables.shared.request(AtmosphereTables.Key(AtmosphereSettings()))
    }

    public func isActive(in f: FrameContext) -> Bool {
        f.settings.atmosphere.enabled && f.scene.bodies.contains { $0.id == AtmosphereFrame.planetID }
    }

    /// The tables' build time, s, for the settings given (0 until built).
    public static func tableBuildSeconds(_ s: AtmosphereSettings = AtmosphereSettings()) -> Double {
        AtmosphereTables.shared.buildSeconds(AtmosphereTables.Key(s))
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        Self.handoff = nil
        let settings = f.settings.atmosphere
        guard let device, let skyViewPipeline, let froxelPipeline, let spaceGroundPipeline,
              let t = uploadedTables(AtmosphereTables.Key(settings), wait: settings.waitForTables, device: device),
              let frame = AtmosphereFrame(scene: f.scene, tables: t.lut, froxelSlices: settings.froxelSlices,
                                          froxelExponent: settings.froxelExponent) else { return }
        Self.fill(&f.atmosphere, frame: frame, tables: t.lut)
        let uniforms = Self.passUniforms(frame, settings: settings, sun: f.scene.sun)
        f.slotTextures[Binding.transmittanceLUT] = t.transmittance
        f.slotTextures[Binding.multipleScatteringLUT] = t.multipleScattering
        f.textures[.atmosphereLUTs] = t.transmittance
        f.textures[.atmosphereIrradiance] = t.irradiance
        f.textures[.atmosphereProfile] = t.profile

        guard let enc = f.makeComputeEncoder() else { return }
        var u = uniforms
        var atmosphere = f.atmosphere
        enc.setBytes(&u, length: MemoryLayout<AtmospherePassUniforms>.stride, index: 0)
        enc.setBytes(&atmosphere, length: MemoryLayout<AtmosphereUniforms>.stride, index: Binding.atmosphereBuffer)
        enc.setTexture(t.transmittance, index: Binding.transmittanceLUT)
        enc.setTexture(t.multipleScattering, index: Binding.multipleScatteringLUT)
        enc.setTexture(t.profile, index: 1)
        enc.setSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
        if frame.isInside, let sky = target2D(&skyView, width: settings.skyViewWidth, height: settings.skyViewHeight,
                                               device: device) {
            enc.setComputePipelineState(skyViewPipeline)
            enc.setTexture(sky, index: 0)
            Self.dispatch(enc, skyViewPipeline, width: sky.width, height: sky.height)
            f.slotTextures[Binding.skyViewLUT] = sky
            f.textures[.skyView] = sky
        }
        var view = Self.view(f.frame, depth: 0, preExposure: f.frame.exposure.x)
        enc.setBytes(&view, length: MemoryLayout<AtmosphereView>.stride, index: 1)
        if !frame.isInside, let ground = spaceGroundTargets(f.size, divisor: settings.spaceGroundDivisor,
                                                            device: device) {
            enc.setComputePipelineState(spaceGroundPipeline)
            enc.setTexture(ground.scatter, index: 0)
            enc.setTexture(ground.transmittance, index: 2)
            Self.dispatch(enc, spaceGroundPipeline, width: ground.scatter.width, height: ground.scatter.height)
            f.textures[.spaceGroundScatter] = ground.scatter
            f.textures[.spaceGroundTransmittance] = ground.transmittance
        }
        // Froxels reach 2,000 km at most: beyond, nothing near the camera is in the air.
        if frame.cameraAltitude < FroxelSlices.maximumFar, let volume = target3D(settings, device: device) {
            enc.setComputePipelineState(froxelPipeline)
            enc.setTexture(volume, index: 0)
            Self.dispatch(enc, froxelPipeline, width: volume.width, height: volume.height, depth: volume.depth)
            f.slotTextures[Binding.aerialPerspective] = volume
            f.textures[.aerialPerspective] = volume
        } else {
            f.atmosphere.aerialPerspective = .zero
        }
        enc.endEncoding()
        Self.handoff = Handoff(frame: f, state: State(frame: frame, uniforms: uniforms, profile: t.profile, lut: t.lut))
    }

    // MARK: The uniforms

    /// `AtmosphereUniforms`' A2 members (C2's cloud members are left as they are).
    static func fill(_ a: inout AtmosphereUniforms, frame: AtmosphereFrame, tables: AtmosphereLUT) {
        let c = tables.coefficients
        a.worldToBody = simd_float4x4(rotation: frame.planet.orientation.icrfToBody)
        a.planetCenter = SIMD4(frame.planet.position, Float(frame.bottomRadius))
        a.radii = SIMD4(Float(frame.bottomRadius), Float(frame.topRadius), Float(frame.cameraAltitude), 1)
        a.rayleighScattering = SIMD4(c.rayleighScatteringAtGround, Float(c.rayleighScaleHeight))
        a.mieScattering = SIMD4(c.aerosolScatteringAtGround, Float(c.aerosolScaleHeight))
        a.mieExtinction = SIMD4(c.aerosolExtinctionAtGround, Float(c.aerosolAsymmetry))
        a.ozoneAbsorption = SIMD4(c.ozoneAbsorptionAtPeak, Float(c.ozonePeakAltitude))
        a.ozoneLayer = SIMD4(Float(c.ozoneHalfWidth), 0, 0, 0)
        a.groundAlbedo = SIMD4(tables.groundAlbedo, 0)
        let sun = frame.sunTransmitted, sky = frame.skyIrradiance
        a.sunTransmitted = SIMD4(Float(sun.color.r), Float(sun.color.g), Float(sun.color.b), Float(sun.illuminance))
        a.skyIrradiance = SIMD4(Float(sky.r), Float(sky.g), Float(sky.b), 0)
        a.aerialPerspective = SIMD4(Float(frame.froxels.count), Float(frame.froxels.far),
                                    Float(frame.froxels.exponent), 0)
    }

    static func passUniforms(_ frame: AtmosphereFrame, settings: AtmosphereSettings,
                             sun: RenderScene.Sun) -> AtmospherePassUniforms {
        let m = frame.worldToFigure, solar = frame.solarScale
        let worldToFigure = simd_float4x4(columns: (
            SIMD4<Float>(Float(m[0, 0]), Float(m[1, 0]), Float(m[2, 0]), 0),
            SIMD4<Float>(Float(m[0, 1]), Float(m[1, 1]), Float(m[2, 1]), 0),
            SIMD4<Float>(Float(m[0, 2]), Float(m[1, 2]), Float(m[2, 2]), 0),
            SIMD4<Float>(0, 0, 0, 1)))
        return AtmospherePassUniforms(
            worldToFigure: worldToFigure,
            camera: SIMD4(frame.camera, Float(frame.cameraRadius)),
            sun: SIMD4(frame.sun, Float(sun.angularRadius)),
            up: SIMD4(frame.up, Float(frame.cosSunZenith)),
            sunAzimuth: SIMD4(frame.sunAzimuth, frame.isInside ? 1 : 0),
            sunWorld: SIMD4(sun.direction, 0),
            solar: SIMD4(Float(solar.r), Float(solar.g), Float(solar.b), 0),
            steps: SIMD4(Float(settings.skyViewSteps), Float(settings.limbSteps), Float(settings.groundSteps),
                         Float(settings.froxelSteps)))
    }

    /// The camera's view for the froxels and the composite.
    static func view(_ frame: FrameUniforms, depth: Float, preExposure: Float) -> AtmosphereView {
        AtmosphereView(viewToWorld: frame.viewToWorld,
                       projection: SIMD4(frame.camera.y * frame.camera.z, frame.camera.y, depth, preExposure),
                       viewport: frame.viewport)
    }

    // MARK: Textures

    private func uploadedTables(_ key: AtmosphereTables.Key, wait: Bool, device: MTLDevice) -> Tables? {
        if let tables, tables.key == key { return tables }
        guard let lut = AtmosphereTables.shared.tables(key, wait: wait),
              let transmittance = Self.upload(lut.transmittance, device: device),
              let multiple = Self.upload(lut.multipleScattering, device: device),
              let irradiance = Self.upload(lut.irradiance, device: device),
              let profile = Self.upload(lut.profile, device: device) else { return tables }
        tables = Tables(key: key, lut: lut, transmittance: transmittance, multipleScattering: multiple,
                        irradiance: irradiance, profile: profile)
        return tables
    }

    static func upload(_ table: AtmosphereLUT.Table, device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: table.width,
                                                         height: table.height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        table.texels.withUnsafeBytes { bytes in
            t.replace(region: MTLRegionMake2D(0, 0, table.width, table.height), mipmapLevel: 0,
                      withBytes: bytes.baseAddress!, bytesPerRow: table.width * 16)
        }
        t.label = "Atmosphere table \(table.width)x\(table.height)"
        return t
    }

    private func target2D(_ t: inout MTLTexture?, width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        if let t, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: max(width, 2),
                                                         height: max(height, 2), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        t = device.makeTexture(descriptor: d)
        t?.label = "Sky view"
        return t
    }

    private func target3D(_ s: AtmosphereSettings, device: MTLDevice) -> MTLTexture? {
        let n = max(s.froxelSize, 2), slices = max(s.froxelSlices, 2)
        if let froxels, froxels.width == n, froxels.depth == slices { return froxels }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        // Not half float: toward a low Sun the aerosol's forward lobe passes
        // 65,504 cd/m² (docs/look/atmosphere.md, "Storage").
        d.pixelFormat = .rgba32Float
        d.width = n
        d.height = n
        d.depth = slices
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        froxels = device.makeTexture(descriptor: d)
        froxels?.label = "Aerial perspective"
        return froxels
    }

    static func dispatch(_ enc: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int,
                         height: Int, depth: Int = 1) {
        let w = min(pipeline.threadExecutionWidth, 32), h = max(min(pipeline.maxTotalThreadsPerThreadgroup / w, 8), 1)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: depth),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    /// The reduced-resolution targets of the ground's haze from space.
    private func spaceGroundTargets(_ size: RenderSize, divisor: Int,
                                    device: MTLDevice) -> (scatter: MTLTexture, transmittance: MTLTexture)? {
        let k = max(divisor, 1)
        let w = max((size.width + k - 1) / k, 2), h = max((size.height + k - 1) / k, 2)
        if let g = spaceGround, g.scatter.width == w, g.scatter.height == h { return g }
        func make(_ label: String, _ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        // The haze in float: at the silhouette under a Sun a few degrees
        // above the limb it passes half float's 65,504 cd/m²; the
        // transmittance (0-1) fits half float.
        guard let scatter = make("Ground haze from space", .rgba32Float),
              let t = make("Ground transmittance from space", .rgba16Float) else {
            return nil
        }
        spaceGround = (scatter, t)
        return spaceGround
    }
}

/// The sky, drawn over what lies behind the air (P2): a full-screen
/// triangle just beyond the far side of the atmosphere's shell, depth-tested
/// (reversed-Z, greater-equal, read-only), so it covers the stars, the
/// Sun's disc and far bodies and leaves the planet (which the planet pass
/// lights and hazes through the same tables) and everything in front of it.
/// Dual-source blending makes the scene radiance + transmittance × scene,
/// per channel: the Sun's disc is reddened at the horizon, and the stars
/// fade into the day sky.
///
/// R3's probe draws the same sky through `encodeProbe`.
@MainActor
public final class AtmosphereCompositePass: RenderPass {
    public let name = "Atmosphere composite"
    public let stage = PassStage.composite
    public let order = 0
    public var reads: Set<ResourceID> { [.atmosphereLUTs, .atmosphereProfile] }

    private var device: MTLDevice?
    private var library: MTLLibrary?
    private var pipeline: MTLRenderPipelineState?
    private var probePipelines: [String: MTLRenderPipelineState] = [:]
    /// This frame's uniforms from the probe's centre, made once a frame
    /// (the frame held weakly, as A2's handoff is: a later frame at the same
    /// address never sees them).
    private struct ProbeCache {
        weak var frame: FrameContext?
        let center: Vec3
        let uniforms: AtmospherePassUniforms
    }
    private var probeCache: ProbeCache?

    /// The probe reads the camera's sky-view LUT within this distance of the
    /// camera (m) and `probeSkyViewHeight` of its altitude, both inside the
    /// air (`probeReadsSkyView`); beyond, it marches from its centre.
    public nonisolated static let probeSkyViewRange = 2_000.0
    /// The altitude difference (m) within which the camera's LUT stands for
    /// the centre's: a 2 km range straight up is another sky.
    public nonisolated static let probeSkyViewHeight = 300.0

    /// Whether a probe reads the camera's sky-view LUT: the camera inside the
    /// air (A2 draws the LUT only then), the centre inside it too, within
    /// `probeSkyViewRange` of the camera and `probeSkyViewHeight` of its
    /// altitude, where the LUT's height and Sun are as good as the centre's.
    /// Otherwise its sky, and the planet's haze, are marched from the centre.
    public nonisolated static func probeReadsSkyView(cameraInside: Bool, centreInside: Bool, distance: Double,
                                                     heightDifference: Double) -> Bool {
        cameraInside && centreInside && distance <= probeSkyViewRange && abs(heightDifference) <= probeSkyViewHeight
    }

    /// The pass uniforms as from `center` (camera-relative, m): the camera's
    /// own at the camera; else A2's frame for the centre (its figure
    /// position, zenith, Sun), reading the sky-view LUT only where
    /// `probeReadsSkyView` allows (`sunAzimuth.w`).
    func probeUniforms(_ f: FrameContext, state: AtmosphereLUTPass.State, center: Vec3) -> AtmospherePassUniforms {
        guard center != .zero else { return state.uniforms }
        if let c = probeCache, c.frame === f, c.center == center { return c.uniforms }
        var shifted = f.scene
        for i in shifted.bodies.indices { shifted.bodies[i].position = shifted.bodies[i].position - center }
        let settings = f.settings.atmosphere
        guard let frame = AtmosphereFrame(scene: shifted, tables: state.lut, froxelSlices: settings.froxelSlices,
                                          froxelExponent: settings.froxelExponent) else { return state.uniforms }
        var u = AtmosphereLUTPass.passUniforms(frame, settings: settings, sun: f.scene.sun)
        let lut = Self.probeReadsSkyView(cameraInside: state.frame.isInside, centreInside: frame.isInside,
                                         distance: center.length,
                                         heightDifference: frame.cameraAltitude - state.frame.cameraAltitude)
        u.sunAzimuth.w = lut ? 1 : 0
        probeCache = ProbeCache(frame: f, center: center, uniforms: u)
        return u
    }

    /// Whether R3's probe at `center` reads the camera's sky-view LUT this
    /// frame (`probeReadsSkyView`); false without this frame's atmosphere.
    public func probeReadsSkyView(_ f: FrameContext, center: Vec3) -> Bool {
        guard let state = AtmosphereLUTPass.state(for: f) else { return false }
        return probeUniforms(f, state: state, center: center).sunAzimuth.w > 0.5
    }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.atmosphere)
        self.library = library
        device = s.device
        pipeline = try Self.pipeline(library, color: s.formats.color, depth: s.formats.depth,
                                     sampleCount: s.formats.sampleCount, device: s.device)
    }

    public func isActive(in f: FrameContext) -> Bool {
        f.settings.atmosphere.enabled && f.scene.bodies.contains { $0.id == AtmosphereFrame.planetID }
    }

    static func pipeline(_ library: MTLLibrary, color: MTLPixelFormat, depth: MTLPixelFormat, sampleCount: Int,
                         device: MTLDevice) throws -> MTLRenderPipelineState {
        guard let v = library.makeFunction(name: "atmosphere_vertex"),
              let fn = library.makeFunction(name: "atmosphere_fragment") else {
            throw ShaderLibrary.Failure.missingFunction("atmosphere_vertex / atmosphere_fragment")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "Atmosphere composite"
        d.vertexFunction = v
        d.fragmentFunction = fn
        d.rasterSampleCount = sampleCount
        d.depthAttachmentPixelFormat = depth
        let c = d.colorAttachments[0]!
        c.pixelFormat = color
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.sourceRGBBlendFactor = .one
        c.destinationRGBBlendFactor = .source1Color
        c.alphaBlendOperation = .add
        c.sourceAlphaBlendFactor = .zero
        c.destinationAlphaBlendFactor = .one
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// The composite's depth, reversed-Z: near over the distance to the far
    /// side of the shell (the camera's distance to the centre plus the top's
    /// radius, which bounds every chord through the air).
    static func depth(_ state: AtmosphereLUTPass.State, near: Double) -> Float {
        Float(near / (state.frame.planet.distance + state.frame.topRadius))
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, let state = AtmosphereLUTPass.state(for: f) else { return }
        var u = state.uniforms
        var view = AtmosphereLUTPass.view(f.frame, depth: Self.depth(state, near: f.scene.camera.near),
                                          preExposure: f.frame.exposure.x)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        enc.setVertexBytes(&view, length: MemoryLayout<AtmosphereView>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<AtmospherePassUniforms>.stride, index: 0)
        enc.setFragmentBytes(&view, length: MemoryLayout<AtmosphereView>.stride, index: 1)
        enc.setFragmentTexture(state.profile, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// R3's probe entry point: the sky as seen from `center` (camera-
    /// relative, m: the probe's centre), drawn over one face of a radiance
    /// cube on `encoder`, whose attachments have `formats`: radiance +
    /// transmittance × what the face holds (the planet's probe face, the
    /// stars), times `preExposure` (1 for cd/m²): from the camera's sky-view
    /// LUT where `probeReadsSkyView` allows, else marched from the centre
    /// itself (`probeUniforms`).
    /// `viewToWorld` is the face's rotation and `tanHalfFov` its tan(fov/2)
    /// (1 for a 90° face); `depth` the reversed-Z depth the sky is drawn at
    /// (0 behind everything; with no depth attachment it is not tested).
    /// Returns false when this frame has no atmosphere (no Earth, or the
    /// tables are not ready): the face keeps what it had.
    @discardableResult
    public func encodeProbe(_ f: FrameContext, on encoder: MTLRenderCommandEncoder, formats: SceneFormats,
                            viewToWorld: simd_float4x4, tanHalfFov: Float, faceSize: Int, preExposure: Float = 1,
                            depth: Float = 0, center: Vec3 = .zero) -> Bool {
        guard let state = AtmosphereLUTPass.state(for: f), let library, let device else { return false }
        let p: MTLRenderPipelineState
        let key = "\(formats.color.rawValue) \(formats.depth.rawValue) \(formats.sampleCount)"
        if let cached = probePipelines[key] {
            p = cached
        } else {
            guard let made = try? Self.pipeline(library, color: formats.color, depth: formats.depth,
                                                sampleCount: formats.sampleCount, device: device) else { return false }
            probePipelines[key] = made
            p = made
        }
        var u = probeUniforms(f, state: state, center: center)
        let size = Float(max(faceSize, 1))
        var view = AtmosphereView(viewToWorld: viewToWorld, projection: SIMD4(tanHalfFov, tanHalfFov, depth, preExposure),
                                  viewport: SIMD4(size, size, 1 / size, 1 / size))
        encoder.setRenderPipelineState(p)
        if formats.depth != .invalid { encoder.setDepthStencilState(f.states.depthReadOnly) }
        encoder.setVertexBytes(&view, length: MemoryLayout<AtmosphereView>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<AtmospherePassUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&view, length: MemoryLayout<AtmosphereView>.stride, index: 1)
        encoder.setFragmentTexture(state.profile, index: 1)
        if let t = f.slotTextures[Binding.transmittanceLUT] {
            encoder.setFragmentTexture(t, index: Binding.transmittanceLUT)
        }
        if let t = f.slotTextures[Binding.multipleScatteringLUT] {
            encoder.setFragmentTexture(t, index: Binding.multipleScatteringLUT)
        }
        if let t = f.slotTextures[Binding.skyViewLUT] { encoder.setFragmentTexture(t, index: Binding.skyViewLUT) }
        encoder.setFragmentSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }
}

// Swift mirrors of AtmosphereShaders' structs.

/// The atmosphere module's own uniforms (buffer 0).
struct AtmospherePassUniforms {
    var worldToFigure: simd_float4x4
    var camera: SIMD4<Float>
    var sun: SIMD4<Float>
    var up: SIMD4<Float>
    var sunAzimuth: SIMD4<Float>
    var sunWorld: SIMD4<Float>
    var solar: SIMD4<Float>
    var steps: SIMD4<Float>
}

/// The view the composite and the froxels see (buffer 1).
struct AtmosphereView {
    var viewToWorld: simd_float4x4
    var projection: SIMD4<Float>
    var viewport: SIMD4<Float>
}

extension SIMD4 where Scalar == Float {
    init(_ s: Spectrum3, _ w: Float) {
        self.init(Float(s.r), Float(s.g), Float(s.b), w)
    }
}

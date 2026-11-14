import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// Volumetric clouds (track C2), in P0 on the command buffer:
/// 1. the noise volumes, once;
/// 2. the weather map: C1's weather assembled at ERA5's grid points
///    (`cloud_weather`, CloudWeatherMap's mirror);
/// 3. the cloud shadow map along the Sun around the camera (slot 24, with
///    `AtmosphereUniforms.cloudShadowMatrix` and `cloudLayer`);
/// 4. the march at R6's half resolution, one texel in four a frame with
///    checkerboard reprojection when allowed (`CloudReprojection`), every
///    texel otherwise; each texel the near or orbit march, or the far
///    surface layer by its footprint, and the cirrus;
/// 5. the temporal resolve, into `.cloudLayer` (premultiplied radiance,
///    pre-exposed, 1 − T) and `.cloudDepth` (front, mean, entry: linear
///    depths), which plumes and particles may read.
/// Then, as R6's first half-resolution effect, it copies the resolved clouds
/// into the clouds layer, cut at the scene's depth (`encodeHalfRes`).
@MainActor
public final class CloudPass: RenderPass, HalfResEffect {
    public let name = "Clouds"
    public let stage = PassStage.prepare
    public let order = 10
    public var writes: Set<ResourceID> { [.cloudLayer, .cloudDepth, .cloudShadow] }

    /// The march target's history (persistent).
    static let historyColor = ResourceID("cloudHistoryColor", persistent: true)
    static let historyDepth = ResourceID("cloudHistoryDepth", persistent: true)

    /// The shape noise's period (m), the mid layer's, the detail's and the
    /// curl's: each divides the noise tile (FrameContext.noiseTile).
    public static let shapePeriod = 16_384.0, midPeriod = 32_768.0, detailPeriod = 2_048.0, curlPeriod = 8_192.0
    /// The shell the clouds live in, m above the ground, and the reference
    /// heights of the far layers and the cirrus.
    /// A cirrus deck's depth within the 8-12 km band, m: lidar climatologies
    /// give about 1.8 km at mid-latitudes (the band's 4 km made the 2D layer
    /// twice too thick).
    public static let cirrusThickness = 1_800.0
    public static let shellTop = 13_000.0, lowReference = 2_000.0, midReference = 4_500.0, cirrusHeight = 10_000.0
    /// The shadow map's channels: the optical depth above these heights (m).
    public static let shadowLevels: [Float] = [0, 2_000, 6_000, 10_000]
    /// Frame pixels per march texel: 2 (R6's half resolution) in the near
    /// field, 4 from 20 km up, where the march's clouds are a few pixels
    /// across. (Back to 2 above 3,000 km, the march switched on again over
    /// most of the Earth's disc as the far layer had taken it.)
    public static func marchScale(altitude: Double) -> Int { altitude >= 20_000 ? 4 : 2 }

    /// The angle of the pixel footprint the hand-over to the far layer is
    /// judged by: R6's half-resolution texel whatever the march's scale, so
    /// the hand-over does not move when the scale changes.
    public static func handOverPixelAngle(fovY: Double, viewportHeight: Double) -> Double {
        2 * tan(fovY / 2) / max(viewportHeight, 1) * 2
    }

    /// The Earth's least radius on screen for clouds, pixels.
    static let minimumRadius = 4.0

    private var pipelines: (march: MTLComputePipelineState, resolve: MTLComputePipelineState,
                            weather: MTLComputePipelineState, shadow: MTLComputePipelineState,
                            shape: MTLComputePipelineState, detail: MTLComputePipelineState,
                            curl: MTLComputePipelineState)?
    private var slotPipeline: MTLRenderPipelineState?
    private(set) var noise: CloudNoiseVolumes?
    private var tables: CloudTables?
    private var air: CloudAir?
    /// This frame's air tables (A2's, or A2's uploaded here).
    private var frameAir: CloudAir.Tables?
    private var samplers: (wrap: MTLSamplerState, weather: MTLSamplerState)?
    private(set) var weatherMap: (a: MTLTexture, b: MTLTexture)?
    private var snapshots: [Int: MTLTexture] = [:]
    /// The mission `snapshots` hold, and textures of another's to refill.
    private var snapshotsMission: String?
    private var spareSnapshots: [MTLTexture] = []
    private var placeholder: MTLTexture?
    private var weathers: [String: CloudWeather] = [:]
    private var lastWeather: WeatherKey?
    private(set) var shadowTexture: MTLTexture?
    /// The weather to draw instead of the settings' (the tests' fields).
    var weatherOverride: CloudWeather?
    /// The override's name, as the mission's (another name: another field).
    var weatherOverrideName = "override"

    private var previous: CloudFrame?
    private(set) var advection = CloudAdvection(tile: FrameContext.noiseTile)
    private(set) var cirrus = CirrusFrames()
    /// The last frame's epoch, to tell a jump in time from a frame's step.
    private var lastEpoch: Epoch?
    /// This frame's resolved clouds and uniforms, for the slots' copy; nil
    /// when nothing drew.
    private var resolved: (color: MTLTexture, depth: MTLTexture)?
    private var uniformsForSlot = CloudUniforms()
    /// What the last frame did, for tests and the timings' report.
    public private(set) var lastFrame = Report()

    public struct Report: Equatable {
        public var drawn = false
        public var reprojected = false
        public var motionPixels = 0.0
        public var mission: String?
        public var regimes = (near: 0.0, orbit: 0.0, far: 0.0)
        /// The frame's geometry, the Sun's light (pre-exposed lux) and the
        /// march target's scale, for the tests' references.
        public var frame: CloudFrame?
        public var epoch: Epoch?
        public var sunLight = SIMD4<Float>.zero
        public var scale = 2
        /// The pixel angle the hand-over to the far layer uses.
        public var footprintAngle = 0.0

        public static func == (a: Report, b: Report) -> Bool {
            a.drawn == b.drawn && a.reprojected == b.reprojected && a.motionPixels == b.motionPixels
                && a.mission == b.mission
        }
    }

    public init() {}

    // MARK: Set-up

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.cloud)
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw ShaderLibrary.Failure.missingFunction(name) }
            return try s.device.makeComputePipelineState(function: f)
        }
        if ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST"] != nil {
            for n in ["cloud_march_kernel", "cloud_resolve", "cloud_weather", "cloud_shadow"] {
                let p = try compute(n)
                print("pipeline \(n): max threads \(p.maxTotalThreadsPerThreadgroup), width \(p.threadExecutionWidth), " +
                      "static threadgroup memory \(p.staticThreadgroupMemoryLength)")
            }
        }
        pipelines = (try compute("cloud_march_kernel"), try compute("cloud_resolve"), try compute("cloud_weather"),
                     try compute("cloud_shadow"), try compute("cloud_noise_shape"), try compute("cloud_noise_detail"),
                     try compute("cloud_noise_curl"))
        noise = CloudNoiseVolumes(device: s.device)
        tables = CloudTables(device: s.device)
        air = CloudAir(device: s.device)
        air?.request(AtmosphereSettings())
        let w = MTLSamplerDescriptor()
        w.minFilter = .linear
        w.magFilter = .linear
        w.mipFilter = .linear
        w.sAddressMode = .repeat
        w.tAddressMode = .repeat
        w.rAddressMode = .repeat
        let m = MTLSamplerDescriptor()
        m.minFilter = .linear
        m.magFilter = .linear
        m.sAddressMode = .repeat
        m.tAddressMode = .clampToEdge
        guard let wrap = s.device.makeSamplerState(descriptor: w), let weather = s.device.makeSamplerState(descriptor: m)
        else { throw ShaderLibrary.Failure.missingFunction("cloud samplers") }
        samplers = (wrap, weather)
        func map(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: CloudWeatherMap.columns,
                                                             height: CloudWeatherMap.rows, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = s.device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        if let a = map(.rgba16Float, "Cloud weather A"), let b = map(.rg16Float, "Cloud weather B") { weatherMap = (a, b) }
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: 1, height: 1, mipmapped: false)
        pd.usage = .shaderRead
        placeholder = s.device.makeTexture(descriptor: pd)
        guard noise != nil, tables != nil, weatherMap != nil, placeholder != nil else {
            throw ShaderLibrary.Failure.missingFunction("cloud textures")
        }
    }

    public func setUpHalfRes(_ s: HalfResSetup) throws {
        slotPipeline = try s.pipeline(try s.shaders.library(.cloud), vertex: "cloud_slot_vertex",
                                      fragment: "cloud_slot_fragment", layer: .clouds)
    }

    // MARK: Whether it draws

    /// The Earth, when the clouds draw this frame: enabled, the Earth on
    /// screen and large enough, not under R6's black look-dev backdrop
    /// (unless the cloud slab is the shot).
    func earth(_ f: FrameContext) -> RenderScene.Body? {
        let c = f.settings.cloud
        guard c.enabled, c.weather != "clear" || c.lookDev != nil, pipelines != nil,
              !f.settings.transparency.testBackdrop || c.lookDev != nil,
              let earth = CloudFrame.earth(in: f.scene) else { return nil }
        let cam = f.scene.camera
        let radius = earth.angularRadius * cam.pixelsPerRadian
        guard radius >= Self.minimumRadius || earth.distance < earth.radius * 1.01 else { return nil }
        // On screen: the cloud shell's cone against the view's.
        let forward = Vec3(-cam.worldToView.r2.x, -cam.worldToView.r2.y, -cam.worldToView.r2.z)
        let d = earth.position.length
        let shell = earth.figure.equatorialRadius + Self.shellTop
        if d > shell {
            let toEarth = earth.position / d
            let halfView = atan(tan(cam.fovY / 2) * (1 + cam.aspect))
            let angle = acos(min(max(toEarth.dot(forward), -1), 1))
            if angle - asin(min(shell / d, 1)) > halfView { return nil }
        }
        return earth
    }

    public func isActive(in f: FrameContext) -> Bool { earth(f) != nil }

    /// Asked before P0 has run (R6 plans its frame first): the same test
    /// as `isActive`, not this frame's results.
    public func halfResLayers(in f: FrameContext) -> HalfResLayers {
        slotPipeline != nil && earth(f) != nil ? .clouds : []
    }

    // MARK: P0

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        resolved = nil
        lastFrame = Report()
        frameAir = nil
        guard case .commandBuffer(let cb) = e, let earth = earth(f), let p = pipelines, let noise, let tables,
              let samplers, let weatherMap, let airTables = air?.tables(f) else { return }
        frameAir = airTables
        noise.generate(on: cb, pipelines: (p.shape, p.detail, p.curl))
        let settings = f.settings.cloud
        let frame = CloudFrame(earth: earth)
        // The wind's drift starts over with a scene (the extractor's first
        // frame, or a jump in time: another scenario), never on a warp
        // change, a camera cut or a fast turn (temporal resets), which would
        // move every cloud back by its whole drift.
        let clock = f.scene.clock
        let jump = lastEpoch.map { abs(clock.simTime - $0 - clock.simDt) > 60 } ?? true
        if clock.frameIndex <= 1 || jump {
            advection = CloudAdvection(tile: FrameContext.noiseTile)
            cirrus = CirrusFrames()
        }
        lastEpoch = clock.simTime

        // The weather.
        let (weather, mission) = weatherFor(settings, epoch: f.scene.clock.simTime)
        let params = CloudWeatherMap.parameters(weather, at: f.scene.clock.simTime)
        let sample = weather.sample(latitude: frame.latitude, longitude: frame.longitude, at: f.scene.clock.simTime)
        let dt = f.scene.clock.paused ? 0 : f.scene.clock.simDt
        advection.advance(frame, winds: [sample.lowWind ?? sample.surfaceWind, sample.midWind, sample.highWind], dt: dt)
        cirrus.update(frame, streak: Self.streak(frame, wind: sample.highWind), wind: sample.highWind, dt: dt,
                      realDt: f.scene.clock.realDt, period: Self.shapePeriod)
        guard let enc = f.makeComputeEncoder() else { return }
        // P0: the frame uniforms alone (the shared ones are uploaded after it).
        f.bindFrameUniforms(enc)
        enc.setSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
        // The weather map again only when it has changed: another mission
        // or snapshots, or a weight moved by 1/500.
        let key = WeatherKey(mission: mission, params: params)
        if !settings.skip.contains("weather"), lastWeather.map({ !$0.close(to: key) }) ?? true {
            lastWeather = key
            encodeWeather(enc, f, weather: weather, mission: mission, params: params, map: weatherMap, pipeline: p.weather)
        }

        // The uniforms.
        // The march target: R6's half resolution in the near field, half
        // that again above it (the orbit and far regimes), where the clouds
        // are smaller on the screen than the near field's.
        let regimes = CloudFrame.regimes(altitude: frame.altitude)
        let scale = Self.marchScale(altitude: frame.altitude)
        let size = EffectSlots.targetSize(width: f.size.width, height: f.size.height, scale: scale)
        let marchSize = RenderSize(width: size.width, height: size.height)
        var u = uniforms(f, frame: frame, settings: settings, sample: sample, regimes: regimes, size: marchSize,
                         scale: scale, hasField: params.snapshots != nil, airTop: airTables.top)

        // The shadow map.
        let shadowN = settings.shadowTexels
        if shadowN > 0, !settings.skip.contains("shadow"), frame.altitude < 2_000_000,
           encodeShadow(enc, f, frame: frame, u: &u, texels: shadowN, pipeline: p.shadow, noise: noise, map: weatherMap,
                        samplers: samplers) {
            f.slotTextures[Binding.cloudShadow] = shadowTexture
            if let t = shadowTexture { f.textures[.cloudShadow] = t }
        }

        // The march and the resolve.
        let colorD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: marchSize.width,
                                                              height: marchSize.height, mipmapped: false)
        colorD.usage = [.shaderRead, .shaderWrite]
        colorD.storageMode = .private
        // Depths as log2 of the linear depth, half floats (cloud_encodeDepth).
        let depthD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: marchSize.width,
                                                              height: marchSize.height, mipmapped: false)
        depthD.usage = [.shaderRead, .shaderWrite]
        depthD.storageMode = .private
        guard let hc = f.history.pair(Self.historyColor, descriptor: colorD),
              let hd = f.history.pair(Self.historyDepth, descriptor: depthD),
              let freshColor = f.pool.texture(colorD), let freshDepth = f.pool.texture(depthD) else {
            enc.endEncoding()
            return
        }
        let reprojection = reprojectionMatrix(f, frame: frame)
        let motion = motionPixels(f, frame: frame, reprojection: reprojection)
        let historyValid = hc.valid && hd.valid && previous != nil && !f.scene.clock.temporalReset
        // Far away the surface layer takes every texel: no march, nothing to reproject.
        let marches = regimes.far < 0.999 || settings.regime == "march"
        let reprojects = marches && settings.reprojection && historyValid
            && CloudReprojection.allowed(warp: f.scene.clock.warp, temporalReset: f.scene.clock.temporalReset,
                                         motionPixels: motion)
        let k = f.scene.clock.frameIndex & 3
        let checker: SIMD2<Float> = [SIMD2(0, 0), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 1)][k]
        u.checker = SIMD4(checker.x, checker.y, reprojects ? 1 : 0, Float(f.scene.clock.frameIndex % 64))

        var slots = EffectSlotUniforms(size: f.size, scale: scale, layers: .clouds, settings: f.settings.transparency,
                                       reference: 1)
        enc.setComputePipelineState(p.march)
        enc.setTexture(freshColor, index: 0)
        enc.setTexture(freshDepth, index: 1)
        bindField(enc, noise: noise, tables: tables, air: airTables, map: weatherMap, samplers: samplers)
        enc.setBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        enc.setBytes(&slots, length: MemoryLayout<EffectSlotUniforms>.stride, index: 1)
        let threads = reprojects ? MTLSize(width: (marchSize.width + 1) / 2, height: (marchSize.height + 1) / 2, depth: 1)
                                 : MTLSize(width: marchSize.width, height: marchSize.height, depth: 1)
        if marches, !settings.skip.contains("march") {
            enc.dispatchThreads(threads, threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }

        var r = CloudResolveUniforms()
        r.reprojection = reprojection
        r.target = SIMD4(Float(marchSize.width), Float(marchSize.height), Float(scale), Float(scale))
        r.checker = SIMD4(checker.x, checker.y, reprojects ? 1 : 0, marches ? (historyValid ? 1 : 0) : -1)
        enc.setComputePipelineState(p.resolve)
        enc.setTexture(freshColor, index: 10)
        enc.setTexture(freshDepth, index: 11)
        enc.setTexture(hc.previous, index: 12)
        enc.setTexture(hd.previous, index: 13)
        enc.setTexture(hc.current, index: 14)
        enc.setTexture(hd.current, index: 15)
        enc.setBytes(&r, length: MemoryLayout<CloudResolveUniforms>.stride, index: 1)
        if !settings.skip.contains("resolve") {
            enc.dispatchThreads(MTLSize(width: marchSize.width, height: marchSize.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        enc.endEncoding()

        resolved = (hc.current, hd.current)
        uniformsForSlot = u
        f.textures[.cloudLayer] = hc.current
        f.textures[.cloudDepth] = hd.current
        previous = frame
        lastFrame = Report(drawn: true, reprojected: reprojects, motionPixels: motion, mission: mission,
                           regimes: regimes, frame: frame, epoch: f.scene.clock.simTime, sunLight: u.sunLight,
                           scale: scale, footprintAngle: Double(u.footprint.x))
    }

    // MARK: The slot

    public func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder) {
        guard let resolved, let slotPipeline, let noise, let tables, let frameAir, let weatherMap, let samplers
        else { return }
        // A2's haze over the ground from space, for the clouds beyond its
        // froxels' reach (y: 1 when bound).
        let space = f.textures[.spaceGroundScatter].flatMap { s in f.textures[.spaceGroundTransmittance].map { (s, $0) } }
        var scale = SIMD4<Float>(resolved.color.width == slots.size.width && resolved.color.height == slots.size.height
                                 ? 1 : 0, space == nil ? 0 : 1, 0, 0)
        var u = uniformsForSlot
        enc.setRenderPipelineState(slotPipeline)
        enc.setDepthStencilState(slots.noDepth)
        enc.setFragmentBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        enc.setFragmentBytes(&scale, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.setFragmentTexture(resolved.color, index: 0)
        enc.setFragmentTexture(resolved.depth, index: 1)
        enc.setFragmentTexture(noise.shape, index: 2)
        enc.setFragmentTexture(noise.detail, index: 3)
        enc.setFragmentTexture(noise.curl, index: 4)
        enc.setFragmentTexture(weatherMap.a, index: 5)
        enc.setFragmentTexture(weatherMap.b, index: 6)
        enc.setFragmentTexture(tables.slab, index: 7)
        enc.setFragmentTexture(frameAir.transmittance, index: 8)
        enc.setFragmentTexture(frameAir.irradiance, index: 9)
        enc.setFragmentTexture(space?.0 ?? frameAir.irradiance, index: 10)
        enc.setFragmentTexture(space?.1 ?? frameAir.irradiance, index: 11)
        enc.setFragmentSamplerState(samplers.wrap, index: 0)
        enc.setFragmentSamplerState(samplers.weather, index: 1)
        enc.setFragmentSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: Parts

    /// The weather for the settings and the epoch, and the mission it is.
    private func weatherFor(_ s: CloudSettings, epoch: Epoch) -> (CloudWeather, String?) {
        if let weatherOverride { return (weatherOverride, weatherOverrideName) }
        let name: String?
        switch s.weather {
        case "auto": name = CloudWeatherMap.mission(at: epoch)
        case "climatology", "clear": name = nil
        default: name = s.weather
        }
        guard let name else { return (CloudWeather(), nil) }
        if let w = weathers[name] { return (w, name) }
        let w = CloudWeather.mission(name)
        weathers[name] = w
        return (w, name)
    }

    private func encodeWeather(_ enc: MTLComputeCommandEncoder, _ f: FrameContext, weather: CloudWeather, mission: String?,
                               params: CloudWeatherMap.Parameters, map: (a: MTLTexture, b: MTLTexture),
                               pipeline: MTLComputePipelineState) {
        var textures: (MTLTexture, MTLTexture)?
        // Snapshot i of another mission is another sky: its textures are
        // refilled, never read as this mission's.
        if mission != snapshotsMission {
            spareSnapshots += snapshots.values
            snapshots = [:]
            snapshotsMission = mission
        }
        if let s = params.snapshots, let field = weather.field {
            // The two snapshots' textures: kept if loaded, else filled from
            // one no longer needed (each taken once), or new.
            let wanted = [s.first, s.second]
            var free = snapshots.filter { !wanted.contains($0.key) }.map(\.value) + spareSnapshots
            var keep: [Int: MTLTexture] = [:]
            for i in wanted where keep[i] == nil {
                if let t = snapshots[i] {
                    keep[i] = t
                } else if let t = free.popLast() ?? newSnapshotTexture() {
                    fill(t, field: field, snapshot: i)
                    keep[i] = t
                }
            }
            snapshots = keep
            spareSnapshots = free
            if let a = keep[s.first], let b = keep[s.second] { textures = (a, b) }
        }
        var p = CloudWeatherParams()
        if let s = params.snapshots, textures != nil {
            p.snapshots = SIMD4(Float(s.weight), 1, Float(params.fieldWeight), s.first != s.second ? 1 : 0)
        }
        p.counts = SIMD4(Float(min(params.overrides.count, 2)), 0, 0, 0)
        for (i, o) in params.overrides.prefix(2).enumerated() {
            let place = SIMD4<Float>(Float(o.latitude), Float(o.longitude), Float(o.radius), Float(o.timeWeight))
            let sky = SIMD4<Float>(Float(o.observation.low), Float(o.observation.mid), Float(o.observation.high),
                                   o.observation.convective ? 1 : 0)
            if i == 0 { p.overridePlace.0 = place; p.overrideSky.0 = sky } else { p.overridePlace.1 = place; p.overrideSky.1 = sky }
        }
        p.layerModel = SIMD4(Float(CloudLayerModel.defaultLowBase), Float(CloudLayerModel.midBase),
                             Float(CloudLayerModel.lowDepth), Float(CloudLayerModel.cumulonimbusTop))
        let climate = params.climatology.map { SIMD4<Float>(Float($0.low), Float($0.mid), Float($0.high), 0) }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(textures?.0 ?? placeholder, index: 0)
        enc.setTexture(textures?.1 ?? placeholder, index: 1)
        enc.setTexture(map.a, index: 2)
        enc.setTexture(map.b, index: 3)
        // 721 rows, 11.5 KB: through the frame's arena (setBytes takes 4 KB at
        // most; Metal's API validation stops on more).
        guard let rows = f.arena.push(climate) else { return }
        enc.setBuffer(rows.buffer, offset: rows.offset, index: 0)
        enc.setBytes(&p, length: MemoryLayout<CloudWeatherParams>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: map.a.width, height: map.a.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    /// A texture for one snapshot's planes.
    private func newSnapshotTexture() -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: CloudWeatherMap.columns,
                                                         height: CloudWeatherMap.rows, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        return placeholder?.device.makeTexture(descriptor: d)
    }

    /// Snapshot `i`'s planes into `t`.
    private func fill(_ t: MTLTexture, field: CloudField, snapshot i: Int) {
        let bytes = CloudWeatherMap.interleaved(field, snapshot: i)
        bytes.withUnsafeBytes { b in
            t.replace(region: MTLRegionMake2D(0, 0, CloudWeatherMap.columns, CloudWeatherMap.rows), mipmapLevel: 0,
                      withBytes: b.baseAddress!, bytesPerRow: 4 * CloudWeatherMap.columns)
        }
        t.label = "Cloud snapshot \(i)"
    }

    private func bindField(_ enc: MTLComputeCommandEncoder, noise: CloudNoiseVolumes, tables: CloudTables,
                           air: CloudAir.Tables, map: (a: MTLTexture, b: MTLTexture),
                           samplers: (wrap: MTLSamplerState, weather: MTLSamplerState)) {
        enc.setTexture(noise.shape, index: 2)
        enc.setTexture(noise.detail, index: 3)
        enc.setTexture(noise.curl, index: 4)
        enc.setTexture(map.a, index: 5)
        enc.setTexture(map.b, index: 6)
        enc.setTexture(tables.slab, index: 7)
        enc.setTexture(air.transmittance, index: 8)
        enc.setTexture(air.irradiance, index: 9)
        enc.setSamplerState(samplers.wrap, index: 0)
        enc.setSamplerState(samplers.weather, index: 1)
    }

    private func encodeShadow(_ enc: MTLComputeCommandEncoder, _ f: FrameContext, frame: CloudFrame,
                              u: inout CloudUniforms, texels: Int, pipeline: MTLComputePipelineState,
                              noise: CloudNoiseVolumes, map: (a: MTLTexture, b: MTLTexture),
                              samplers: (wrap: MTLSamplerState, weather: MTLSamplerState)) -> Bool {
        if shadowTexture?.width != texels {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: texels, height: texels,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            shadowTexture = f.device.makeTexture(descriptor: d)
            shadowTexture?.label = "Cloud shadow"
        }
        guard let shadowTexture, frame.sunBody.dot(frame.cameraBody.normalized) > -0.2 else { return false }
        let shadowMap = frame.shadowMap(texels: texels)
        let center = shadowMap.center - frame.cameraBody
        u.shadow = SIMD4(Float(shadowMap.extent), Float(texels), 1, 32)
        u.shadowCenter = SIMD4(center, 0)
        u.shadowU = SIMD4(shadowMap.u, 0)
        u.shadowV = SIMD4(shadowMap.v, 0)
        enc.setComputePipelineState(pipeline)
        enc.setTexture(shadowTexture, index: 0)
        enc.setTexture(noise.shape, index: 2)
        enc.setTexture(noise.detail, index: 3)
        enc.setTexture(noise.curl, index: 4)
        enc.setBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        enc.setSamplerState(samplers.wrap, index: 0)
        enc.setSamplerState(samplers.weather, index: 1)
        enc.setTexture(map.a, index: 5)
        enc.setTexture(map.b, index: 6)
        enc.dispatchThreads(MTLSize(width: texels, height: texels, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        // Camera-relative world to (u, v, height, 1), for the receivers.
        let b = frame.icrfToBody
        let uw = b.transposed * shadowMap.u, vw = b.transposed * shadowMap.v
        let up = b.transposed * Ellipsoid.wgs84.normal(latitude: frame.latitude, longitude: frame.longitude)
        let e = shadowMap.extent
        let row0 = SIMD4<Float>(Float(uw.x / e), Float(uw.y / e), Float(uw.z / e), Float(0.5 - center.dot(shadowMap.u) / e))
        let row1 = SIMD4<Float>(Float(vw.x / e), Float(vw.y / e), Float(vw.z / e), Float(0.5 - center.dot(shadowMap.v) / e))
        let row2 = SIMD4<Float>(Float(up.x), Float(up.y), Float(up.z), Float(frame.altitude))
        f.atmosphere.cloudShadowMatrix = simd_float4x4(rows: [row0, row1, row2, SIMD4(0, 0, 0, 1)])
        f.atmosphere.cloudLayer = SIMD4(Float(CloudLayerModel.defaultLowBase), Float(Self.shellTop), 0, 1)
        return true
    }

    // MARK: Uniforms

    private func uniforms(_ f: FrameContext, frame: CloudFrame, settings s: CloudSettings, sample: CloudSample,
                          regimes: (near: Double, orbit: Double, far: Double), size: RenderSize, scale: Int,
                          hasField: Bool, airTop: Double) -> CloudUniforms {
        var u = CloudUniforms()
        let b = frame.icrfToBody
        u.worldToBody = simd_float4x4(rotation: b)
        u.bodyToWorld = simd_float4x4(rotation: b.transposed)
        u.cameraFigure = SIMD4(frame.cameraFigure, Float(frame.stretch))
        u.radii = SIMD4(Float(frame.radius), Float(frame.altitude), Float(Self.shellTop), Float(airTop))
        u.shell = SIMD4(Float(frame.shellConstant(height: 0)), Float(frame.shellConstant(height: Self.shellTop)),
                        Float(frame.shellConstant(height: Self.cirrusHeight)),
                        Float(frame.shellConstant(height: Self.lowReference)))
        u.shellMid = SIMD4(Float(frame.shellConstant(height: Self.midReference)), Float(Self.cirrusHeight),
                           Float(Self.lowReference), Float(Self.midReference))
        u.sun = SIMD4(frame.sunBody, 0)
        let exposure = f.frame.exposure.x
        let sun = f.frame.sunIlluminance
        u.sunLight = SIMD4(sun.x * exposure, sun.y * exposure, sun.z * exposure, exposure)
        let tile = FrameContext.noiseTile
        func origin(_ i: Int) -> Vec3 { CloudFrame.wrap(frame.cameraBody + advection.offsets[i], tile: tile) }
        u.noiseLow = SIMD4(origin(0), Float(Self.shapePeriod))
        u.noiseMid = SIMD4(origin(1), Float(Self.midPeriod))
        u.noiseHigh = SIMD4(origin(2), Float(Self.detailPeriod))
        // The cirrus's streak frames (CirrusFrame): axes, and the camera's
        // noise coordinate in each; w the previous frame's weight.
        func set(_ c: CirrusFrame?, _ a: inout SIMD4<Float>, _ b: inout SIMD4<Float>, _ n: inout SIMD4<Float>,
                 _ o: inout SIMD4<Float>, weight: Double) {
            guard let c else { return }
            a = SIMD4(c.along, Float(weight))
            b = SIMD4(c.across, 0)
            n = SIMD4(c.up, 0)
            o = SIMD4(c.origin(camera: frame.cameraBody, period: Self.shapePeriod), 0)
        }
        set(cirrus.current, &u.cirrusAlong, &u.cirrusAcross, &u.cirrusUp, &u.cirrusOrigin, weight: cirrus.fade)
        set(cirrus.previous, &u.cirrusAlong2, &u.cirrusAcross2, &u.cirrusUp2, &u.cirrusOrigin2, weight: 0)
        u.windHigh = SIMD4(u.cirrusAlong.x, u.cirrusAlong.y, u.cirrusAlong.z, Float(Self.curlPeriod))
        let layers = CloudLayerModel.layers(CloudSample(low: 1, mid: 1, high: 1))
        u.extinction = SIMD4(Float(layers[0].extinction), Float(layers[1].extinction), Float(layers[2].extinction),
                             Float(s.densityScale))
        u.layers = SIMD4(Float(CloudLayerModel.midBase), Float(CloudLayerModel.midTop), Float(CloudLayerModel.highBase),
                         Float(CloudLayerModel.highBase + Self.cirrusThickness))
        u.march = SIMD4(Float(max(s.steps, 8)), 0, Float(s.lightDistance), Float(s.nearReach))
        let lighting = CloudLighting(), mie = lighting.mie
        u.mie = SIMD4(Float(mie.gHG), Float(mie.gDraine), Float(mie.alpha), Float(mie.weightDraine))
        u.lighting = SIMD4(Float(lighting.backscatter), Float(lighting.minimumSunCosine), Float(s.detail),
                           Float(CloudLayerModel.iceAsymmetry))
        let forcedFar = s.regime == "far" ? 1.0 : 0.0
        u.regime = SIMD4(Float(regimes.near), Float(regimes.orbit), Float(max(regimes.far, forcedFar)), Float(s.farDensity))
        let cam = f.scene.camera
        let pixelAngle = Self.handOverPixelAngle(fovY: cam.fovY, viewportHeight: cam.viewport.height)
        u.footprint = SIMD4(Float(pixelAngle), Float(s.farFootprint.first ?? 1_500),
                            Float(s.farFootprint.count > 1 ? s.farFootprint[1] : 6_000), Float(s.coverageModulation))
        if let l = s.lookDev {
            u.lookDev = SIMD4(1, Float(l.cover), Float(l.opticalDepth), s.regime == "far" ? 1 : (s.regime == "march" ? 2 : 0))
            u.lookDevSlab = SIMD4(Float(l.base), Float(l.base + l.thickness), 0, 0)
        } else {
            u.lookDev = SIMD4(0, 0, 0, s.regime == "far" ? 1 : (s.regime == "march" ? 2 : 0))
        }
        u.target = SIMD4(Float(size.width), Float(size.height), Float(scale), Float(scale))
        u.lut = SIMD4(Float(CloudSlabLUT.depths), Float(CloudSlabLUT.cosines), Float(CloudSlabLUT.minDepth),
                      Float(log(CloudSlabLUT.maxDepth / CloudSlabLUT.minDepth)))
        // The low layer's base and top where the camera is: under it, or over
        // it looking down, far clouds may be the surface layer.
        let low = CloudLayerModel.layers(sample)[0]
        let lowBase = s.lookDev?.base ?? low.base
        let lowTop = s.lookDev.map { $0.base + $0.thickness } ?? low.top
        u.lut2 = SIMD4(Float(CloudSlabLUT.minCosine), hasField ? 1 : 0, Float(lowBase), Float(lowTop))
        u.shadowLevels = SIMD4(Self.shadowLevels[0], Self.shadowLevels[1], Self.shadowLevels[2], Self.shadowLevels[3])
        let st = CloudCoverage.standardStatistics
        u.coverage = Self.table(CloudCoverage.standard)
        u.densityLow = Self.table(st.densityScale[0])
        u.densityMid = Self.table(st.densityScale[1])
        u.cirrusTheta = Self.table(st.cirrusThreshold)
        u.cirrusScale = Self.table(st.cirrusScale)
        return u
    }

    /// The cirrus's streak at the camera: along the high wind, east when calm.
    static func streak(_ frame: CloudFrame, wind: LayerWind?) -> Vec3 {
        let axes = frame.eastNorth
        guard let w = wind, (w.east * w.east + w.north * w.north) > 1 else { return axes.east }
        return (axes.east * w.east + axes.north * w.north).normalized
    }

    /// A 33-entry table over the cover, four entries to a float4 (CloudShaders' cloud_table).
    static func table(_ t: [Double]) -> CloudTable9 {
        func entry(_ i: Int) -> SIMD4<Float> { SIMD4((0..<4).map { k in Float(t[min(4 * i + k, t.count - 1)]) }) }
        return (entry(0), entry(1), entry(2), entry(3), entry(4), entry(5), entry(6), entry(7), entry(8))
    }

    /// This frame's camera-relative world to last frame's clip space for
    /// body-fixed points (CloudFrame.reprojection), in Double until the
    /// product with last frame's view-projection.
    private func reprojectionMatrix(_ f: FrameContext, frame: CloudFrame) -> simd_float4x4 {
        guard let previous, !f.scene.clock.temporalReset else { return f.viewProjection }
        let (r, t) = frame.reprojection(from: previous)
        return f.frame.previousViewProjection * simd_float4x4(rotation: r, translation: t)
    }

    /// How far (pixels of the frame) the clouds at the centre of the view
    /// moved since last frame: the point 20 km along the view, or on the
    /// low layer where the view meets it, reprojected.
    private func motionPixels(_ f: FrameContext, frame: CloudFrame, reprojection: simd_float4x4) -> Double {
        guard previous != nil else { return .infinity }
        let cam = f.scene.camera
        let forward = Vec3(-cam.worldToView.r2.x, -cam.worldToView.r2.y, -cam.worldToView.r2.z)
        let distance = min(max(frame.altitude * 1.5, 20_000), 2_000_000)
        let p = forward * distance
        let now = f.viewProjection * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
        let then = reprojection * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
        guard now.w > 0, then.w > 0 else { return .infinity }
        let a = SIMD2<Float>(now.x, now.y) / now.w, b = SIMD2<Float>(then.x, then.y) / then.w
        let d = (a - b) * SIMD2<Float>(Float(cam.viewport.width), Float(cam.viewport.height)) * 0.5
        return Double(simd_length(d))
    }
}

/// What the weather map was last assembled from.
struct WeatherKey {
    var mission: String?
    var snapshots: (Int, Int)?
    var weights: [Double]

    init(mission: String?, params: CloudWeatherMap.Parameters) {
        self.mission = mission
        snapshots = params.snapshots.map { ($0.first, $0.second) }
        weights = [params.snapshots?.weight ?? 0, params.fieldWeight] + params.overrides.map(\.timeWeight)
            + [params.climatology.first?.low ?? 0, params.climatology.last?.high ?? 0]
    }

    /// The same map within 1/500 of every weight.
    func close(to k: WeatherKey) -> Bool {
        mission == k.mission && snapshots?.0 == k.snapshots?.0 && snapshots?.1 == k.snapshots?.1
            && weights.count == k.weights.count
            && zip(weights, k.weights).allSatisfy { abs($0 - $1) < 0.002 }
    }
}

/// Swift mirror of CloudShaders' CloudUniforms.
struct CloudUniforms {
    var worldToBody = matrix_identity_float4x4
    var bodyToWorld = matrix_identity_float4x4
    var reprojection = matrix_identity_float4x4
    var cameraFigure = SIMD4<Float>.zero
    var radii = SIMD4<Float>.zero
    var shell = SIMD4<Float>.zero
    var shellMid = SIMD4<Float>.zero
    var sun = SIMD4<Float>.zero
    var sunLight = SIMD4<Float>.zero
    var noiseLow = SIMD4<Float>.zero
    var noiseMid = SIMD4<Float>.zero
    var noiseHigh = SIMD4<Float>.zero
    var windHigh = SIMD4<Float>.zero
    var cirrusAlong = SIMD4<Float>.zero
    var cirrusAcross = SIMD4<Float>.zero
    var cirrusUp = SIMD4<Float>.zero
    var cirrusOrigin = SIMD4<Float>.zero
    var cirrusAlong2 = SIMD4<Float>.zero
    var cirrusAcross2 = SIMD4<Float>.zero
    var cirrusUp2 = SIMD4<Float>.zero
    var cirrusOrigin2 = SIMD4<Float>.zero
    var extinction = SIMD4<Float>.zero
    var layers = SIMD4<Float>.zero
    var march = SIMD4<Float>.zero
    var mie = SIMD4<Float>.zero
    var lighting = SIMD4<Float>.zero
    var regime = SIMD4<Float>.zero
    var footprint = SIMD4<Float>.zero
    var checker = SIMD4<Float>.zero
    var lookDev = SIMD4<Float>.zero
    var lookDevSlab = SIMD4<Float>.zero
    var target = SIMD4<Float>.zero
    var lut = SIMD4<Float>.zero
    var lut2 = SIMD4<Float>.zero
    var shadow = SIMD4<Float>.zero
    var shadowCenter = SIMD4<Float>.zero
    var shadowU = SIMD4<Float>.zero
    var shadowV = SIMD4<Float>.zero
    var shadowLevels = SIMD4<Float>.zero
    var coverage = CloudUniforms.emptyTable
    var densityLow = CloudUniforms.emptyTable
    var densityMid = CloudUniforms.emptyTable
    var cirrusTheta = CloudUniforms.emptyTable
    var cirrusScale = CloudUniforms.emptyTable

    static let emptyTable: CloudTable9 = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}

/// A 33-entry table over the cover in nine float4s.
typealias CloudTable9 = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                         SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

/// Swift mirror of CloudShaders' CloudWeatherParams.
struct CloudWeatherParams {
    var snapshots = SIMD4<Float>.zero
    var counts = SIMD4<Float>.zero
    var overridePlace = (SIMD4<Float>.zero, SIMD4<Float>.zero)
    var overrideSky = (SIMD4<Float>.zero, SIMD4<Float>.zero)
    var layerModel = SIMD4<Float>.zero
    var structure = SIMD4<Float>.zero
}

/// Swift mirror of CloudShaders' CloudResolveUniforms.
struct CloudResolveUniforms {
    var reprojection = matrix_identity_float4x4
    var target = SIMD4<Float>.zero
    var checker = SIMD4<Float>.zero
}

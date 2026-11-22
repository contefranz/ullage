import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// Volumetric clouds (track C2), in P0 on the command buffer:
/// 1. the noise volumes, once;
/// 2. the weather map: C1's weather assembled at ERA5's grid points
///    (`cloud_weather`, CloudWeatherMap's mirror), the weather elsewhere the
///    procedural weather's nodes (`cloud_procedural`, ProceduralWeather's
///    mirror) calibrated row by row to the climatology (`cloud_calibrate`);
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
                            curl: MTLComputePipelineState, procedural: MTLComputePipelineState,
                            calibrate: MTLComputePipelineState)?
    /// The procedural weather's nodes (latent covers and base; top and how
    /// cumuliform), the rows' offsets, and the geography it reads.
    private(set) var procedural: (latent: MTLTexture, layer: MTLTexture, offsets: MTLBuffer,
                                  geography: (a: MTLTexture, b: MTLTexture))?
    /// The procedural weather's state the map was last made with, for the
    /// camera's sample in between.
    private(set) var proceduralState: ProceduralWeather.State?
    /// The procedural weather's time step: its nodes are made again when the
    /// time has moved this far (s; a front at 15 m/s moves 450 m), band by
    /// band over `sweepBands` frames with one state (0.6 ms for all its
    /// nodes, 0.12 ms for the rows' calibration, M3 Pro; 0.7-0.9 ms a frame
    /// of a sweep with the band's map rows, `testWeatherAssemblyCost`), and
    /// at once after a jump of an hour or more, a new seed or a new start.
    public nonisolated static let proceduralStep = 30.0
    public nonisolated static let sweepBands = 4
    /// The nodes' sweep under way: its inputs and the next band.
    private var sweep: (frame: CloudWeatherMap.ProceduralFrame, band: Int)?
    /// The seed and time the nodes were last made (or are being made) for.
    private var nodesKey: (seed: Int, epoch: Epoch)?

    /// A band of the procedural nodes' rows.
    static func nodeRows(band b: Int) -> Range<Int> {
        let n = ProceduralWeather.rows
        return (n * b / sweepBands)..<(n * (b + 1) / sweepBands)
    }

    /// The map's rows made again with a band of nodes' rows: those over the
    /// band (every other one is a node's), and the 12 before it whose
    /// inputs reach into it (a row reads the nodes' rows on either side and
    /// their offsets smoothed over ±4 rows). The bands go in order, so after a
    /// sweep every row has its new inputs: the map a fresh one would make.
    static func mapRows(nodes r: Range<Int>) -> Range<Int> {
        max(2 * r.lowerBound - 12, 0)..<min(2 * r.upperBound, CloudWeatherMap.rows)
    }
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
    /// The low layer's detail curl's own frame (CirrusFrame, its wind the
    /// low layer's).
    private(set) var detailFrames = CirrusFrames()
    /// The shadow map's lattice anchor and the extent it was set for.
    private(set) var shadowAnchor: (point: Vec3, extent: Double)?
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
        probeLibrary = library
        probePipelines = [:]
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
                     try compute("cloud_noise_curl"), try compute("cloud_procedural"), try compute("cloud_calibrate"))
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
        procedural = Self.makeProcedural(s.device)
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: 1, height: 1, mipmapped: false)
        pd.usage = .shaderRead
        placeholder = s.device.makeTexture(descriptor: pd)
        mergeBreak = s.device.makeBuffer(length: 16, options: .storageModePrivate)
        mergeBreak?.label = "Cloud encoder break"
        guard noise != nil, tables != nil, weatherMap != nil, placeholder != nil, procedural != nil else {
            throw ShaderLibrary.Failure.missingFunction("cloud textures")
        }
    }

    /// The procedural weather's textures and buffer, and its geography
    /// uploaded once (WeatherGeography: two rgba8 planes).
    static func makeProcedural(_ device: MTLDevice) -> (latent: MTLTexture, layer: MTLTexture, offsets: MTLBuffer,
                                                        geography: (a: MTLTexture, b: MTLTexture))? {
        func texture(_ format: MTLPixelFormat, _ label: String, gpuOnly: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: ProceduralWeather.columns,
                                                             height: ProceduralWeather.rows, mipmapped: false)
            d.usage = gpuOnly ? [.shaderRead, .shaderWrite] : .shaderRead
            d.storageMode = gpuOnly ? .private : .shared
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        guard let latent = texture(.rgba32Float, "Procedural weather latent", gpuOnly: true),
              let layer = texture(.rgba32Float, "Procedural weather layer", gpuOnly: true),
              let a = texture(.rgba8Unorm, "Weather geography A", gpuOnly: false),
              let b = texture(.rgba8Unorm, "Weather geography B", gpuOnly: false),
              let offsets = device.makeBuffer(length: 16 * ProceduralWeather.rows, options: .storageModePrivate)
        else { return nil }
        offsets.label = "Procedural weather offsets"
        let g = WeatherGeography.earth
        let region = MTLRegionMake2D(0, 0, ProceduralWeather.columns, ProceduralWeather.rows)
        g.a.withUnsafeBytes { a.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!,
                                         bytesPerRow: 4 * ProceduralWeather.columns) }
        g.b.withUnsafeBytes { b.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!,
                                         bytesPerRow: 4 * ProceduralWeather.columns) }
        return (latent, layer, offsets, (a, b))
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

    /// The Earth, when R3's probe draws the clouds this frame: enabled, with
    /// weather, the probe on and asking for them; on screen or not, so the
    /// vessels' light does not change as the camera turns.
    func probeEarth(_ f: FrameContext) -> RenderScene.Body? {
        let c = f.settings.cloud, probe = f.settings.probe
        guard probe.enabled, probe.clouds, probe.environment == .scene, c.enabled, c.weather != "clear",
              c.lookDev == nil, pipelines != nil, !f.settings.transparency.testBackdrop else { return nil }
        return CloudFrame.earth(in: f.scene)
    }

    /// When the clouds draw (`earth`), or when only R3's probe needs this
    /// frame's state (`probeEarth`): then the weather and the uniforms are
    /// prepared, and the shadow map, the march and the slot are not.
    public func isActive(in f: FrameContext) -> Bool { earth(f) != nil || probeEarth(f) != nil }

    /// Asked before P0 has run (R6 plans its frame first): the same test
    /// as `isActive`, not this frame's results.
    public func halfResLayers(in f: FrameContext) -> HalfResLayers {
        slotPipeline != nil && earth(f) != nil ? .clouds : []
    }

    /// A new sequence (`SceneRenderer.startOver`): the next frame starts as
    /// in a fresh pass. The wind's drift, the cirrus and detail frames and
    /// the shadow map's anchor start over as for a new scene (a frame with
    /// no last epoch is a jump), and the weather map is made anew rather
    /// than kept while its weights stay within 1/500 of the last shot's.
    public func startOver() {
        lastEpoch = nil
        previous = nil
        lastWeather = nil
        proceduralState = nil
        sweep = nil
        nodesKey = nil
    }

    // MARK: P0

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        resolved = nil
        lastFrame = Report()
        frameAir = nil
        probeState = nil
        let onScreen = earth(f)
        guard case .commandBuffer(let cb) = e, let earth = onScreen ?? probeEarth(f), let p = pipelines, let noise,
              let tables, let samplers, let weatherMap, let airTables = air?.tables(f) else { return }
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
            detailFrames = CirrusFrames()
            shadowAnchor = nil
        }
        lastEpoch = clock.simTime

        // The weather.
        let (weather, mission) = weatherFor(settings, epoch: f.scene.clock.simTime)
        let params = CloudWeatherMap.parameters(weather, at: f.scene.clock.simTime)
        // Two encoders: the weather map and the shadow map, which P1 reads
        // (slot 24, bound on every render encoder); then the march and the
        // resolve, which only P3 reads (`breakComputeMerge`).
        guard let enc = f.makeComputeEncoder() else { return }
        // P0: the frame uniforms alone (the shared ones are uploaded after it).
        f.bindFrameUniforms(enc)
        enc.setSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
        // The procedural weather's nodes, when it shows: all at once after a
        // jump, a new seed or a new start, else a band a frame once the time
        // has moved by `proceduralStep`. Then the weather map: whole when
        // another mission, seed or snapshots or a weight moved by 1/500, else
        // the rows of the nodes made this frame.
        var mapRows: Range<Int>?
        if !settings.skip.contains("weather") {
            let epoch = f.scene.clock.simTime
            if let w = params.procedural {
                if nodesKey.map({ $0.seed != w.seed || abs(epoch - $0.epoch) > 3_600 }) ?? true {
                    let frame = CloudWeatherMap.proceduralFrame(w, at: epoch)
                    encodeNodes(enc, f, frame, rows: 0..<ProceduralWeather.rows, pipelines: p)
                    nodesKey = (w.seed, epoch)
                    proceduralState = frame.state
                    sweep = nil
                    mapRows = 0..<CloudWeatherMap.rows
                } else if let s = sweep {
                    let rows = Self.nodeRows(band: s.band)
                    encodeNodes(enc, f, s.frame, rows: rows, pipelines: p)
                    mapRows = Self.mapRows(nodes: rows)
                    sweep = s.band + 1 < Self.sweepBands ? (s.frame, s.band + 1) : nil
                } else if let k = nodesKey, abs(epoch - k.epoch) >= Self.proceduralStep {
                    let frame = CloudWeatherMap.proceduralFrame(w, at: epoch)
                    let rows = Self.nodeRows(band: 0)
                    encodeNodes(enc, f, frame, rows: rows, pipelines: p)
                    nodesKey = (w.seed, epoch)
                    proceduralState = frame.state
                    mapRows = Self.mapRows(nodes: rows)
                    sweep = (frame, 1)
                }
            } else {
                nodesKey = nil
                sweep = nil
                proceduralState = nil
            }
            let key = WeatherKey(mission: mission, params: params)
            if lastWeather.map({ !$0.close(to: key) }) ?? true {
                lastWeather = key
                mapRows = 0..<CloudWeatherMap.rows
            }
            if let mapRows {
                encodeWeather(enc, f, weather: weather, mission: mission, params: params, map: weatherMap, rows: mapRows,
                              pipelines: p)
            }
        }
        // The weather where the camera is: the winds and the low layer's
        // heights (the procedural weather's as the map was last made).
        let sample = weather.sample(latitude: frame.latitude, longitude: frame.longitude, at: f.scene.clock.simTime,
                                    state: proceduralState, calibrated: false)
        let dt = f.scene.clock.paused ? 0 : f.scene.clock.simDt
        advection.advance(frame, winds: [sample.lowWind ?? sample.surfaceWind, sample.midWind, sample.highWind], dt: dt)
        cirrus.update(frame, streak: Self.streak(frame, wind: sample.highWind), wind: sample.highWind, dt: dt,
                      realDt: f.scene.clock.realDt, period: Self.shapePeriod)
        let lowWind = sample.lowWind ?? sample.surfaceWind
        detailFrames.update(frame, streak: Self.streak(frame, wind: lowWind), wind: lowWind, dt: dt,
                            realDt: f.scene.clock.realDt, period: Self.shapePeriod)

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

        // Off screen, only R3's probe reads this frame's state: no shadow
        // map, march or slot.
        guard onScreen != nil else {
            enc.endEncoding()
            probeState = ProbeState(frame: f, uniforms: u, air: airTables)
            return
        }

        // The shadow map.
        let shadowN = settings.shadowTexels
        if shadowN > 0, !settings.skip.contains("shadow"), frame.altitude < 2_000_000,
           encodeShadow(enc, f, frame: frame, u: &u, texels: shadowN, pipeline: p.shadow, noise: noise, map: weatherMap,
                        samplers: samplers) {
            f.slotTextures[Binding.cloudShadow] = shadowTexture
            if let t = shadowTexture { f.textures[.cloudShadow] = t }
        }
        enc.endEncoding()

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
        breakComputeMerge(f)
        guard let enc = f.makeComputeEncoder() else { return }
        f.bindFrameUniforms(enc)
        enc.setSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
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
        breakComputeMerge(f)

        resolved = (hc.current, hd.current)
        uniformsForSlot = u
        probeState = ProbeState(frame: f, uniforms: u, air: airTables)
        f.textures[.cloudLayer] = hc.current
        f.textures[.cloudDepth] = hd.current
        previous = frame
        lastFrame = Report(drawn: true, reprojected: reprojects, motionPixels: motion, mission: mission,
                           regimes: regimes, frame: frame, epoch: f.scene.clock.simTime, sunLight: u.sunLight,
                           scale: scale, footprintAngle: Double(u.footprint.x))
    }

    /// A one-command blit on each side of the march's encoder. Apple's driver
    /// merges consecutive compute encoders into one GPU pass, and an encoder
    /// that depends on any part of that pass waits for all of it. Merged with
    /// A2's LUTs, which P1's planet pass reads, the march (about 2 ms) sat on
    /// P1's critical path: LEO's frame took 1.2 ms more with A2 on than off.
    /// In a pass of its own it overlaps P1 (docs/look/clouds.md, Cost). The
    /// break after it keeps P0's later compute passes (shadows, probes,
    /// particles) out of the march's pass for the same reason.
    private func breakComputeMerge(_ f: FrameContext) {
        guard let mergeBreak, let blit = f.makeBlitEncoder() else { return }
        blit.fill(buffer: mergeBreak, range: 0..<16, value: 0)
        blit.endEncoding()
    }

    private var mergeBreak: MTLBuffer?

    // MARK: The slot

    public func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder) {
        guard let resolved, let slotPipeline, let noise, let tables, let frameAir, let weatherMap, let samplers
        else { return }
        // A2's haze over the ground from space, for the clouds with the
        // camera above the air (y: 1 when bound).
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

    // MARK: R3's probe entry point

    private var probePipelines: [String: MTLRenderPipelineState] = [:]
    private var probeLibrary: MTLLibrary?
    /// This frame's uniforms and air tables for R3's probe, keyed to the
    /// frame that prepared them (held weakly, so a later frame never sees
    /// them): a frame the pass did not run has none.
    private struct ProbeState {
        weak var frame: FrameContext?
        let uniforms: CloudUniforms
        let air: CloudAir.Tables
    }
    private var probeState: ProbeState?

    /// R3's probe entry point: this frame's far cloud layers (low and mid,
    /// `cloud_probe_fragment`) drawn premultiplied over one 90° face of a
    /// radiance cube on `encoder` (attachments of `formats`, `faceSize`²), in
    /// cd/m², along the face's rays from `center` (camera-relative, m: the
    /// probe's centre), with the air between marched in front when A2 is on.
    /// `viewToWorld`: the face's view basis. The state
    /// is this frame's, prepared by `encode` whether the clouds are on screen
    /// or not (`probeEarth`); a frame the pass did not run draws nothing. The
    /// encoder must have the atmosphere's uniforms (buffer 28) and its slots
    /// (25, 28) bound. What `encode` and `encodeHalfRes` draw does not depend
    /// on it.
    @discardableResult
    public func encodeProbe(_ f: FrameContext, on encoder: MTLRenderCommandEncoder, formats: SceneFormats,
                            viewToWorld: simd_float4x4, faceSize: Int, hazeSteps: Int = 6, center: Vec3 = .zero) -> Bool {
        guard let state = probeState, state.frame === f, let noise, let tables, let weatherMap, let samplers,
              let probeLibrary else { return false }
        let frameAir = state.air
        // Without A2 (its profile absent) the air in front is not marched.
        let profile = f.textures[.atmosphereProfile]
        let key = "\(formats.color.rawValue) \(formats.depth.rawValue) \(formats.sampleCount)"
        if probePipelines[key] == nil {
            let d = MTLRenderPipelineDescriptor()
            guard let vf = probeLibrary.makeFunction(name: "cloud_slot_vertex"),
                  let ff = probeLibrary.makeFunction(name: "cloud_probe_fragment") else { return false }
            d.label = "Clouds (probe)"
            d.vertexFunction = vf
            d.fragmentFunction = ff
            d.rasterSampleCount = formats.sampleCount
            d.depthAttachmentPixelFormat = formats.depth
            let c = d.colorAttachments[0]!
            c.pixelFormat = formats.color
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .zero
            c.destinationAlphaBlendFactor = .one
            guard let p = try? f.device.makeRenderPipelineState(descriptor: d) else { return false }
            probePipelines[key] = p
        }
        guard let pipeline = probePipelines[key] else { return false }
        var u = state.uniforms
        // From the probe's centre: the far layers depend on the ray's origin
        // and its shells' constants alone (the weather and the structure are
        // read at absolute figure points), recomputed for the centre in double.
        if center != .zero, var earth = CloudFrame.earth(in: f.scene) {
            earth.position = earth.position - center
            let at = CloudFrame(earth: earth)
            u.cameraFigure = SIMD4(at.cameraFigure, Float(at.stretch))
            u.radii.y = Float(at.altitude)
            u.shell = SIMD4(Float(at.shellConstant(height: 0)), Float(at.shellConstant(height: Self.shellTop)),
                            Float(at.shellConstant(height: Self.cirrusHeight)),
                            Float(at.shellConstant(height: Self.lowReference)))
            u.shellMid.x = Float(at.shellConstant(height: Self.midReference))
        }
        let sun = f.scene.sun
        var view = CloudProbeView(viewToWorld: viewToWorld,
                                  params: SIMD4(1 / max(f.frame.exposure.x, 1e-30), Float(hazeSteps), Float(faceSize),
                                                profile == nil ? 0 : 1),
                                  sunWorld: SIMD4(sun.direction, Float(sun.angularRadius)),
                                  solar: SIMD4(f.frame.sunIlluminance.x, f.frame.sunIlluminance.y,
                                               f.frame.sunIlluminance.z, 0))
        encoder.setRenderPipelineState(pipeline)
        if formats.depth != .invalid { encoder.setDepthStencilState(f.states.noDepth) }
        encoder.setFragmentBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&view, length: MemoryLayout<CloudProbeView>.stride, index: 1)
        encoder.setFragmentTexture(noise.shape, index: 2)
        encoder.setFragmentTexture(noise.detail, index: 3)
        encoder.setFragmentTexture(noise.curl, index: 4)
        encoder.setFragmentTexture(weatherMap.a, index: 5)
        encoder.setFragmentTexture(weatherMap.b, index: 6)
        encoder.setFragmentTexture(tables.slab, index: 7)
        encoder.setFragmentTexture(frameAir.transmittance, index: 8)
        encoder.setFragmentTexture(frameAir.irradiance, index: 9)
        encoder.setFragmentTexture(profile ?? frameAir.irradiance, index: 10)
        encoder.setFragmentSamplerState(samplers.wrap, index: 0)
        encoder.setFragmentSamplerState(samplers.weather, index: 1)
        encoder.setFragmentSamplerState(f.states.linearClamp, index: Binding.linearClampSampler)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }

    // MARK: Parts

    /// The weather for the settings and the epoch, and the mission it is.
    /// The settings' weather (CloudSettings.weather): "auto" or "historic"
    /// the mission's field and pad sky with the procedural weather
    /// elsewhere, "random" the procedural weather alone, "climatology" the
    /// zonal climatology alone; the procedural weather of the settings' seed.
    private func weatherFor(_ s: CloudSettings, epoch: Epoch) -> (CloudWeather, String?) {
        if let weatherOverride { return (weatherOverride, weatherOverrideName) }
        let procedural = ProceduralWeather(seed: s.seed)
        let name: String?
        switch s.weather {
        case "auto", "historic": name = CloudWeatherMap.mission(at: epoch)
        case "random": return (CloudWeather(procedural: procedural), "random")
        case "climatology", "clear": return (CloudWeather(), nil)
        default: name = s.weather
        }
        guard let name else { return (CloudWeather(procedural: procedural), nil) }
        var w = weathers[name] ?? CloudWeather.mission(name)
        weathers[name] = w
        w.procedural = procedural
        return (w, name)
    }

    private func encodeWeather(_ enc: MTLComputeCommandEncoder, _ f: FrameContext, weather: CloudWeather, mission: String?,
                               params: CloudWeatherMap.Parameters, map: (a: MTLTexture, b: MTLTexture), rows: Range<Int>,
                               pipelines pl: (march: MTLComputePipelineState, resolve: MTLComputePipelineState,
                                              weather: MTLComputePipelineState, shadow: MTLComputePipelineState,
                                              shape: MTLComputePipelineState, detail: MTLComputePipelineState,
                                              curl: MTLComputePipelineState, procedural: MTLComputePipelineState,
                                              calibrate: MTLComputePipelineState)) {
        guard let proc = procedural else { return }
        let procOn = params.procedural != nil && nodesKey != nil
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
        p.structure = SIMD4(procOn ? 1 : 0, Float(rows.lowerBound), 0, 0)
        let climate = params.climatology.map { SIMD4<Float>(Float($0.low), Float($0.mid), Float($0.high), 0) }
        enc.setComputePipelineState(pl.weather)
        enc.setTexture(textures?.0 ?? placeholder, index: 0)
        enc.setTexture(textures?.1 ?? placeholder, index: 1)
        enc.setTexture(map.a, index: 2)
        enc.setTexture(map.b, index: 3)
        enc.setTexture(proc.latent, index: 5)
        enc.setTexture(proc.layer, index: 6)
        enc.setBuffer(proc.offsets, offset: 0, index: 2)
        // 721 rows, 11.5 KB: through the frame's arena (setBytes takes 4 KB at
        // most; Metal's API validation stops on more).
        guard let climateRows = f.arena.push(climate) else { return }
        enc.setBuffer(climateRows.buffer, offset: climateRows.offset, index: 0)
        enc.setBytes(&p, length: MemoryLayout<CloudWeatherParams>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: map.a.width, height: rows.count, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    /// The procedural weather's nodes (`cloud_procedural`) and the rows'
    /// offsets (`cloud_calibrate`) for a band of rows, from `frame`'s inputs.
    private func encodeNodes(_ enc: MTLComputeCommandEncoder, _ f: FrameContext, _ frame: CloudWeatherMap.ProceduralFrame,
                             rows: Range<Int>,
                             pipelines pl: (march: MTLComputePipelineState, resolve: MTLComputePipelineState,
                                            weather: MTLComputePipelineState, shadow: MTLComputePipelineState,
                                            shape: MTLComputePipelineState, detail: MTLComputePipelineState,
                                            curl: MTLComputePipelineState, procedural: MTLComputePipelineState,
                                            calibrate: MTLComputePipelineState)) {
        guard let proc = procedural, !rows.isEmpty else { return }
        var u = ProceduralUniforms(frame.state)
        u.rows = SIMD4(Float(rows.lowerBound), Float(rows.count), 0, 0)
        let bands = zip(frame.bands, frame.climatology).map { b, c in
            ProceduralBand(a: SIMD4(Float(b.steer), Float(b.subtropics), Float(b.stratocumulus), Float(b.desert)),
                           b: SIMD4(Float(b.midDesert), Float(b.trades), Float(b.polar), Float(b.ice)),
                           c: SIMD4(Float(c.low), Float(c.mid), Float(c.high), 0))
        }
        var systems = frame.state.systems.map(ProceduralSystemGPU.init)
        if systems.isEmpty { systems = [ProceduralSystemGPU()] }
        guard let b = f.arena.push(bands), let s = f.arena.push(systems) else { return }
        enc.setComputePipelineState(pl.procedural)
        enc.setTexture(proc.latent, index: 0)
        enc.setTexture(proc.layer, index: 1)
        enc.setTexture(proc.geography.a, index: 2)
        enc.setTexture(proc.geography.b, index: 3)
        enc.setBytes(&u, length: MemoryLayout<ProceduralUniforms>.stride, index: 0)
        enc.setBuffer(b.buffer, offset: b.offset, index: 1)
        enc.setBuffer(s.buffer, offset: s.offset, index: 2)
        enc.dispatchThreads(MTLSize(width: ProceduralWeather.columns, height: rows.count, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        enc.setComputePipelineState(pl.calibrate)
        enc.setTexture(proc.latent, index: 0)
        enc.setBytes(&u, length: MemoryLayout<ProceduralUniforms>.stride, index: 0)
        enc.setBuffer(b.buffer, offset: b.offset, index: 1)
        enc.setBuffer(proc.offsets, offset: 0, index: 3)
        enc.dispatchThreadgroups(MTLSize(width: rows.count, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
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
        // The lattice runs through an anchor near the camera, moved by whole
        // texels (CloudFrame.shadowAnchor), so it holds still as the camera
        // and the Sun move.
        let anchor = frame.shadowAnchor(previous: shadowAnchor?.point, previousExtent: shadowAnchor?.extent,
                                        texels: texels)
        let shadowMap = frame.shadowMap(texels: texels, anchor: anchor)
        shadowAnchor = (anchor, shadowMap.extent)
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
        var detailUp = SIMD4<Float>.zero
        set(detailFrames.current, &u.detailAlong, &u.detailAcross, &detailUp, &u.detailOrigin, weight: detailFrames.fade)
        set(detailFrames.previous, &u.detailAlong2, &u.detailAcross2, &detailUp, &u.detailOrigin2, weight: 0)
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

/// What the weather map was last assembled from, the procedural weather's
/// time apart (its nodes are made again by their own sweep).
struct WeatherKey {
    var mission: String?
    var snapshots: (Int, Int)?
    var weights: [Double]
    /// The procedural weather's seed, when it shows.
    var seed: Int?

    init(mission: String?, params: CloudWeatherMap.Parameters) {
        self.mission = mission
        snapshots = params.snapshots.map { ($0.first, $0.second) }
        weights = [params.snapshots?.weight ?? 0, params.fieldWeight] + params.overrides.map(\.timeWeight)
            + [params.climatology.first?.low ?? 0, params.climatology.last?.high ?? 0]
        seed = params.procedural?.seed
    }

    /// The same map within 1/500 of every weight.
    func close(to k: WeatherKey) -> Bool {
        mission == k.mission && snapshots?.0 == k.snapshots?.0 && snapshots?.1 == k.snapshots?.1 && seed == k.seed
            && weights.count == k.weights.count
            && zip(weights, k.weights).allSatisfy { abs($0 - $1) < 0.002 }
    }
}

/// Swift mirror of CloudShaders' ProceduralUniforms.
struct ProceduralUniforms {
    var phase0 = SIMD4<Float>.zero
    var phase1 = SIMD4<Float>.zero
    var ages = SIMD4<Float>.zero
    var sky = SIMD4<Float>.zero
    var rows = SIMD4<Float>.zero

    init(_ s: ProceduralWeather.State) {
        let p = s.phases
        func phase(_ k: Int) -> SIMD4<Float> {
            SIMD4(Float(p[k].offset.x), Float(p[k].offset.y), Float(p[k].offset.z), Float(p[k].weight))
        }
        phase0 = phase(0)
        phase1 = phase(1)
        let w2 = p.reduce(0) { $0 + $1.weight * $1.weight }
        ages = SIMD4(Float(p[0].age), Float(p[1].age), Float(1 / max(w2, 1e-6).squareRoot()), Float(s.systems.count))
        sky = SIMD4(Float(s.sky.subsolarLongitude), Float(s.sky.declination), Float(s.sky.itczSea), Float(s.sky.itczLand))
    }
}

/// Swift mirror of CloudShaders' ProceduralBand.
struct ProceduralBand {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
}

/// Swift mirror of CloudShaders' ProceduralSystem.
struct ProceduralSystemGPU {
    var centre = SIMD4<Float>.zero
    var east = SIMD4<Float>.zero
    var poleward = SIMD4<Float>.zero
    var params = SIMD4<Float>.zero
    var turn = SIMD4<Float>(2, 1, 0, 0)

    init() {}

    init(_ s: ProceduralWeather.System) {
        centre = SIMD4(Float(s.centre.x), Float(s.centre.y), Float(s.centre.z), Float(s.kind.rawValue))
        east = SIMD4(Float(s.east.x), Float(s.east.y), Float(s.east.z), Float(s.reach))
        poleward = SIMD4(Float(s.poleward.x), Float(s.poleward.y), Float(s.poleward.z), Float(s.size))
        params = SIMD4(Float(s.intensity), Float(s.stage), Float(s.top), Float(s.tilt))
        // The cone a little wider than the reach, so Float's cosine never
        // cuts a node the reach keeps.
        turn = SIMD4(Float(cos(min(s.reach * 1.01 + 1e-4, .pi))), Float(cos(s.tilt)), Float(sin(s.tilt)), 0)
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
    var detailAlong = SIMD4<Float>.zero
    var detailAcross = SIMD4<Float>.zero
    var detailOrigin = SIMD4<Float>.zero
    var detailAlong2 = SIMD4<Float>.zero
    var detailAcross2 = SIMD4<Float>.zero
    var detailOrigin2 = SIMD4<Float>.zero
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

/// Swift mirror of CloudShaders' `CloudProbeView` (R3's probe faces).
struct CloudProbeView {
    var viewToWorld: simd_float4x4
    var params: SIMD4<Float>
    var sunWorld: SIMD4<Float>
    var solar: SIMD4<Float>
}

import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// Post (P4), track R1: from the resolved scene (`hdrColor`, pre-exposed
/// linear light), the bloom pyramid from half resolution down, the
/// luminance histogram the auto exposure reads back (from the pyramid's
/// eighth-resolution level, a meter of zones where stars do not count), the
/// Sun's visibility against `sceneDepth`, then the tone map with the bloom,
/// the Sun's veiling glare and the dither into the output.
@MainActor
public final class PostPass: RenderPass {
    public let name = "Post"
    public let stage = PassStage.post
    public let order = 0
    public var reads: Set<ResourceID> { [.hdrColor, .sceneDepth] }

    /// The camera's exposure, which the exposure pass sets each frame from
    /// the histograms this pass reads back.
    public let control = ExposureControl()
    let textures = PostTextures()
    /// The passes that go with this one: the exposure (P0) and the
    /// resolve's encoding (end of P3).
    public private(set) lazy var exposurePass = ExposurePass(control: control, textures: textures)
    public private(set) lazy var resolvePass = HDRResolvePass()

    /// Bloom levels, the first at half resolution.
    public static let bloomLevels = 6
    /// Half float: rg11b10Float's 5- and 6-bit mantissas would round away
    /// a few per cent of the light down and up the pyramid.
    static let bloomFormat = MTLPixelFormat.rgba16Float
    /// The level the histogram meters, at an eighth of the resolution.
    static let meteredLevel = 2
    /// The glare fades out as the Sun leaves the frame, over this angle (rad).
    static let glareFade = 10 * Double.pi / 180
    /// Drawn depth nearer than this hides the Sun from the visibility probe
    /// (vessels, the pad), m; farther depth is a planet's, which the probe
    /// tests by its disc, or the legacy sky's, which does not hide the Sun.
    static let occluderRange = 1.0e6
    /// Each level of the bloom keeps this share of the level below it, so
    /// level i holds (1 - r) rⁱ of the light (the last level the rest).
    public static let bloomSpread = 0.6
    /// The veiling glare around the Sun, cd/m² per lux at 1 rad from it: a
    /// tenth of the eye's (Stiles-Holladay, L = 10 E / θ² in degrees).
    public static let glareConstant = 3.0e-4

    private var device: MTLDevice?
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var tonePipeline: MTLRenderPipelineState?
    private var outputIsSRGB = true

    /// When set, the next frame's resolved light is also written to a
    /// shared texture (`capturedLight()`): a snapshot's PFM, the tests.
    public var capturesLight = false
    private var capture: MTLTexture?
    /// The same for the bloom's top level (as the tone map makes it, at
    /// full resolution), for the tests.
    var capturesBloom = false
    private var bloomCapture: MTLTexture?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.post)
        device = s.device
        for name in ["post_clear_histogram", "post_downsample_first", "post_histogram", "post_downsample",
                     "post_upsample", "post_bloom_capture", "post_sun_visibility", "post_decode_scene",
                     "post_tone_probe"] {
            guard let fn = library.makeFunction(name: name) else { throw ShaderLibrary.Failure.missingFunction(name) }
            pipelines[name] = try s.device.makeComputePipelineState(function: fn)
        }
        tonePipeline = try PipelineBuilder.make(library, vertex: "post_fullscreen_vertex", fragment: "post_tonemap_fragment",
                                                blend: .opaque, color: s.formats.output, depth: .invalid, sampleCount: 1,
                                                device: s.device)
        outputIsSRGB = s.formats.output.isSRGB
        try textures.setUp(device: s.device)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard let hdr = f.textures[.hdrColor], let depth = f.textures[.sceneDepth],
              let readback = control.readback(for: f.commandBuffer, device: f.device) else { return }
        let settings = f.settings.post
        let size = f.size
        // The bloom pyramid, the first level at half resolution.
        var levels: [(down: MTLTexture, up: MTLTexture)] = []
        var w = max(1, size.width / 2), h = max(1, size.height / 2)
        for level in 0..<Self.bloomLevels {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.bloomFormat, width: w, height: h,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            // The top level has no upsampled texture: the tone map makes it.
            guard let down = f.pool.texture(d), let up = level == 0 ? down : f.pool.texture(d) else { return }
            levels.append((down, up))
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
        let sunView = Self.sunView(f)
        let share = settings.sunGlare ? glareShare(f) : 0

        guard let c = f.makeComputeEncoder() else { return }
        f.bindShared(c)
        c.setBuffer(readback, offset: 0, index: 0)
        dispatch(c, "post_clear_histogram", threads: MTLSize(width: ExposureControl.readbackCount, height: 1, depth: 1))
        // The first level.
        var u = PostUniforms(size: SIMD4(Float(levels[0].down.width), Float(levels[0].down.height), Float(size.width),
                                         Float(size.height)),
                             params: SIMD4(0, 0, Float(LuminanceHistogram.minEV100), Float(LuminanceHistogram.maxEV100)),
                             glare: SIMD4(Float(Self.glareConstant * f.scene.sun.illuminance), Float(share),
                                          Float(2 * f.scene.sun.angularRadius), 0),
                             sunView: SIMD4(sunView, 0))
        c.setTexture(hdr, index: 0)
        c.setTexture(levels[0].down, index: 1)
        c.setBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 1)
        if let p = pipelines["post_downsample_first"] {
            // Whole 16×16 threadgroups: they share a tile of decoded texels.
            c.setComputePipelineState(p)
            c.dispatchThreadgroups(MTLSize(width: (levels[0].down.width + 15) / 16,
                                           height: (levels[0].down.height + 15) / 16, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        // The Sun's visibility, 64 samples in one threadgroup.
        if let p = pipelines["post_sun_visibility"] {
            var probe = Self.sunProbe(f.scene)
            c.setComputePipelineState(p)
            c.setTexture(depth, index: 0)
            c.setBytes(&probe, length: MemoryLayout<SunProbeUniforms>.stride, index: 1)
            c.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        // Down to the metered level, or to the last for the bloom.
        for i in 1..<(settings.bloom > 0 ? levels.count : Self.meteredLevel + 1) {
            u.size = SIMD4(Float(levels[i].down.width), Float(levels[i].down.height), Float(levels[i - 1].down.width),
                           Float(levels[i - 1].down.height))
            c.setTexture(levels[i - 1].down, index: 0)
            c.setTexture(levels[i].down, index: 1)
            c.setBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 1)
            dispatch(c, "post_downsample", texture: levels[i].down)
            if i == Self.meteredLevel {
                c.setTexture(levels[i].down, index: 0)
                dispatch(c, "post_histogram", texture: levels[i].down)
            }
        }
        if settings.bloom > 0 {
            // Up from the smallest (up[last] is down[last]) to the second
            // level; the tone map makes the top as it reads it.
            for i in stride(from: levels.count - 2, through: 1, by: -1) {
                let below = i == levels.count - 2 ? levels[i + 1].down : levels[i + 1].up
                u.size = SIMD4(Float(levels[i].up.width), Float(levels[i].up.height), 0, 0)
                u.params.x = Float(Self.bloomSpread)
                c.setTexture(below, index: 0)
                c.setTexture(levels[i].down, index: 1)
                c.setTexture(levels[i].up, index: 2)
                c.setBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 1)
                dispatch(c, "post_upsample", texture: levels[i].up)
            }
        }
        // The resolved light for a debug view or a capture.
        if f.wanted.contains(.sceneColor), let t = decodedScene(f, storage: .private) {
            decode(c, hdr, into: t)
            f.textures[.sceneColor] = t
        }
        capture = nil
        if capturesLight, let t = decodedScene(f, storage: .shared, format: .rgba32Float) {
            decode(c, hdr, into: t)
            capture = t
            capturesLight = false
        }
        bloomCapture = nil
        if capturesBloom, settings.bloom > 0, let t = decodedScene(f, storage: .shared, format: .rgba32Float) {
            u.params.x = Float(Self.bloomSpread)
            c.setTexture(levels[0].down, index: 0)
            c.setTexture(levels[1].up, index: 1)
            c.setTexture(t, index: 2)
            c.setBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 1)
            dispatch(c, "post_bloom_capture", texture: t)
            bloomCapture = t
            capturesBloom = false
        }
        c.endEncoding()
        f.slotTextures[Binding.sceneDepth] = depth

        // The tone map into the output.
        guard let tonePipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = f.output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let r = f.makeRenderEncoder(pass) else { return }
        var t = toneUniforms(f, sunView: sunView, share: share)
        r.setRenderPipelineState(tonePipeline)
        r.setFragmentTexture(hdr, index: 0)
        r.setFragmentTexture(levels[0].down, index: 1)
        r.setFragmentTexture(levels[1].up, index: 2)
        r.setFragmentBuffer(readback, offset: 0, index: 0)
        r.setFragmentBytes(&t, length: MemoryLayout<ToneUniforms>.stride, index: 1)
        r.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        r.endEncoding()
    }

    private func dispatch(_ c: MTLComputeCommandEncoder, _ name: String, texture: MTLTexture) {
        dispatch(c, name, threads: MTLSize(width: texture.width, height: texture.height, depth: 1))
    }

    private func dispatch(_ c: MTLComputeCommandEncoder, _ name: String, threads: MTLSize) {
        guard let p = pipelines[name] else { return }
        c.setComputePipelineState(p)
        let tg = threads.height > 1 ? MTLSize(width: 16, height: 16, depth: 1)
                                    : MTLSize(width: min(256, p.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        c.dispatchThreads(threads, threadsPerThreadgroup: tg)
    }

    private func decodedScene(_ f: FrameContext, storage: MTLStorageMode,
                              format: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: f.size.width, height: f.size.height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = storage
        return storage == .private ? f.pool.texture(d) : f.device.makeTexture(descriptor: d)
    }

    private func decode(_ c: MTLComputeCommandEncoder, _ hdr: MTLTexture, into t: MTLTexture) {
        c.setTexture(hdr, index: 0)
        c.setTexture(t, index: 1)
        dispatch(c, "post_decode_scene", texture: t)
    }

    /// The light of the frame captured last (`capturesLight`), pre-exposed
    /// linear Rec. 709, RGBA rows top first; call once the GPU is done.
    public func capturedLight() -> (pixels: [Float], width: Int, height: Int)? {
        capture.map(Self.read)
    }

    /// The bloom's top captured last (`capturesBloom`), as `capturedLight`.
    func capturedBloom() -> (pixels: [Float], width: Int, height: Int)? {
        bloomCapture.map(Self.read)
    }

    private static func read(_ t: MTLTexture) -> (pixels: [Float], width: Int, height: Int) {
        var out = [Float](repeating: 0, count: 4 * t.width * t.height)
        out.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!, bytesPerRow: 16 * t.width, from: MTLRegionMake2D(0, 0, t.width, t.height),
                       mipmapLevel: 0)
        }
        return (out, t.width, t.height)
    }

    // MARK: The Sun

    /// The unit vector to the Sun in view axes.
    static func sunView(_ f: FrameContext) -> SIMD3<Float> {
        let v = f.scene.camera.worldToView * f.scene.sun.direction
        return SIMD3(Float(v.x), Float(v.y), Float(v.z))
    }

    /// The visibility probe's Sun, the axes across its disc, and the discs of
    /// the bodies that may hide it, largest first: a body's equatorial radius
    /// as a sphere, as `Eclipse` has it (half the sky from inside it).
    static func sunProbe(_ scene: RenderScene) -> SunProbeUniforms {
        let d = scene.sun.direction
        let u = VisualShape.defaultReference(for: d).cross(d).normalized, v = d.cross(u)
        var discs: [(direction: Vec3, angle: Double)] = []
        for b in scene.bodies where !b.isSun && b.distance - b.figure.equatorialRadius < scene.sun.distance {
            let r = b.figure.equatorialRadius
            discs.append((b.position.normalized, b.distance > r ? asin(r / b.distance) : Double.pi / 2))
        }
        discs.sort { $0.angle > $1.angle }
        var p = SunProbeUniforms(sun: SIMD4(d, Float(scene.sun.angularRadius)), axisU: SIMD4(u, 0), axisV: SIMD4(v, 0),
                                 params: SIMD4(Float(min(discs.count, SunProbeUniforms.maxOcculters)),
                                               Float(occluderRange), 1, 0))
        withUnsafeMutableBytes(of: &p.bodies) { raw in
            let slots = raw.bindMemory(to: SIMD4<Float>.self)
            for (i, disc) in discs.prefix(SunProbeUniforms.maxOcculters).enumerated() {
                slots[i] = SIMD4(disc.direction, Float(cos(disc.angle)))
            }
        }
        return p
    }

    /// The glare's share: 1 while the Sun is within the frame, fading to 0
    /// `glareFade` outside it (a lens hood; nothing from behind).
    func glareShare(_ f: FrameContext) -> Double {
        let cam = f.scene.camera
        let v = cam.worldToView * f.scene.sun.direction
        let tanY = tan(cam.fovY / 2), tanX = tanY * cam.aspect
        // How far outside the frame the Sun is, rad (negative inside).
        let ax = atan2(abs(v.x), -v.z) - atan(tanX), ay = atan2(abs(v.y), -v.z) - atan(tanY)
        let outside = v.z < 0 ? max(ax, ay) : Double.pi
        return max(0, min(1, 1 - outside / Self.glareFade))
    }

    private func toneUniforms(_ f: FrameContext, sunView: SIMD3<Float>, share: Double) -> ToneUniforms {
        let p = f.settings.post
        let e = Photometry.sunColor.scaled(by: f.scene.sun.illuminance)
        return ToneUniforms(
            params: SIMD4(Float(max(0, min(1, p.bloom))), 1, p.toneCurve == .neutral ? 1 : 0, p.dither ? 1 : 0),
            glare: SIMD4(Float(Self.glareConstant), Float(share), Float(f.scene.sun.angularRadius), 0),
            sunView: SIMD4(sunView, 0),
            sunColor: SIMD4(Float(e.r), Float(e.g), Float(e.b), 0),
            output: SIMD4(outputIsSRGB ? 1 : 0, 0, 0, 0),
            lut: SIMD4(Float(ToneLUT.size), Float(ToneLUT.minLog2), Float(ToneLUT.maxLog2), 0),
            bloom: SIMD4(Float(Self.bloomSpread), 0, 0, 0))
    }

    // MARK: Tests

    /// The tone curve the post shader applies, on `colors` (exposed linear
    /// light), from the GPU: the tests compare it with ToneCurves.
    func toneProbe(_ colors: [SIMD4<Float>], curve: ToneCurve, queue: MTLCommandQueue) -> [SIMD4<Float>]? {
        guard let device, let p = pipelines["post_tone_probe"], let lut = textures.lut(curve),
              let input = device.makeBuffer(bytes: colors, length: 16 * colors.count, options: .storageModeShared),
              let output = device.makeBuffer(length: 16 * colors.count, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let c = cb.makeComputeCommandEncoder() else { return nil }
        var u = ToneUniforms(params: SIMD4(0, 1, curve == .neutral ? 1 : 0, 0), glare: .zero, sunView: .zero,
                             sunColor: .zero, output: SIMD4(1, 0, 0, 0),
                             lut: SIMD4(Float(ToneLUT.size), Float(ToneLUT.minLog2), Float(ToneLUT.maxLog2), 0),
                             bloom: .zero)
        c.setComputePipelineState(p)
        c.setBuffer(input, offset: 0, index: 0)
        c.setBytes(&u, length: MemoryLayout<ToneUniforms>.stride, index: 1)
        c.setBuffer(output, offset: 0, index: 2)
        c.setTexture(lut, index: Binding.toneLUT)
        c.dispatchThreads(MTLSize(width: colors.count, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: min(64, colors.count), height: 1, depth: 1))
        c.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let p4 = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: colors.count)
        return Array(UnsafeBufferPointer(start: p4, count: colors.count))
    }
}

/// The scene's last draw (P3, after every other): weights each sample's
/// light for the resolve (Karis), in tile memory, so the passes before it
/// blend in linear light and only the resolve is weighted. Track R1.
///
/// The rule for every pass that draws into the scene: write linear Rec. 709
/// luminance (cd/m²) times this frame's pre-exposure
/// (`FrameUniforms.exposure.x`), below 6e4, and never `orbit_encodeHDR`,
/// which would weight the light twice; draw with an order below
/// `sceneOrder` in P3. HDRRuleTests checks both.
@MainActor
public final class HDRResolvePass: RenderPass {
    public let name = "HDR resolve"
    public let stage = PassStage.transparent
    public let order = HDRResolvePass.sceneOrder
    /// Its order in P3: every pass that draws into the scene comes before it.
    public static let sceneOrder = 1_000_000

    private var pipeline: MTLRenderPipelineState?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        guard s.formats.color == HDRTargetPlan.colorFormat else { throw Failure.needsHDRTargets }
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.post), vertex: "post_fullscreen_vertex",
                                             fragment: "post_resolve_encode", blend: .opaque, setup: s)
    }

    public enum Failure: Error { case needsHDRTargets }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.noDepth)
        enc.setCullMode(.none)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

// Swift mirrors of PostShaders' structs.

struct PostUniforms {
    var size: SIMD4<Float>
    var params: SIMD4<Float>
    /// x: k E⊙ (cd/m² at 1 rad), y: the glare's share, z: its smallest angle (rad).
    var glare: SIMD4<Float>
    /// xyz: unit vector to the Sun, view axes.
    var sunView: SIMD4<Float>
}

struct SunProbeUniforms {
    static let maxOcculters = 8
    var sun: SIMD4<Float>
    var axisU: SIMD4<Float>
    var axisV: SIMD4<Float>
    /// x: bodies in use, y: drawn depth nearer than this (m) occludes, z: 1 to probe.
    var params: SIMD4<Float>
    var bodies = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero,
                  SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)
}

struct ToneUniforms {
    var params: SIMD4<Float>
    var glare: SIMD4<Float>
    var sunView: SIMD4<Float>
    var sunColor: SIMD4<Float>
    var output: SIMD4<Float>
    var lut: SIMD4<Float>
    var bloom: SIMD4<Float>
}

extension MTLPixelFormat {
    /// Whether the GPU encodes to sRGB when it stores this format.
    var isSRGB: Bool {
        switch self {
        case .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgr10_xr_srgb, .bgra10_xr_srgb: true
        default: false
        }
    }
}

import Foundation
import Metal
import simd
import OrbitScene

/// The camera's exposure, shared by track R1's passes: the post pass's
/// histograms come back here (from the frames the GPU has finished), the
/// auto exposure follows them on the CPU (`AutoExposure`), and each frame is
/// rendered pre-exposed at the EV this sets, so pre-exposure and exposure
/// are the same number and the post shader needs no correction.
@MainActor
public final class ExposureControl {
    /// The EV100 and pre-exposure of the frame encoded last.
    public private(set) var ev100 = ExposureControl.initialEV100
    public private(set) var preExposure = Exposure.exposure(ev100: ExposureControl.initialEV100)
    /// The latest histogram read back, and the share of the Sun's disc in view then.
    public private(set) var histogram: LuminanceHistogram?
    public private(set) var sunVisibility = 1.0
    public private(set) var auto = AutoExposure()

    /// The EV100 before any histogram has come back.
    public nonisolated static let initialEV100 = 15.0
    /// Histograms that snap the camera after a reset, rather than adapting.
    nonisolated static let snapCount = 2

    private var target: Double?
    private var snaps = ExposureControl.snapCount
    private var previousPreExposure: Double?

    /// Per frame in flight: the buffer the post pass counts into (the
    /// histogram's bins, the dark weight, the Sun's visible samples), the
    /// frame's command buffer and whether it was read.
    struct Readback {
        let buffer: MTLBuffer
        var commandBuffer: MTLCommandBuffer?
        var serial = 0
        var read = true
    }
    private var readbacks: [Readback] = []
    private var serial = 0
    public nonisolated static let readbackCount = LuminanceHistogram.binCount + 2

    init() {}

    /// Starts over (a new scenario, a snapshot): the next histograms set the
    /// camera at once instead of adapting.
    public func reset() {
        auto.reset()
        target = nil
        snaps = Self.snapCount
        previousPreExposure = nil
        for i in readbacks.indices { readbacks[i].read = true }
    }

    /// The buffer this frame's post pass counts into.
    func readback(for cb: MTLCommandBuffer, device: MTLDevice) -> MTLBuffer? {
        if readbacks.isEmpty {
            for _ in 0..<SceneRenderer.framesInFlight {
                guard let b = device.makeBuffer(length: Self.readbackCount * 4, options: .storageModeShared) else {
                    return nil
                }
                readbacks.append(Readback(buffer: b))
            }
        }
        serial += 1
        let i = serial % readbacks.count
        readbacks[i].commandBuffer = cb
        readbacks[i].serial = serial
        readbacks[i].read = false
        return readbacks[i].buffer
    }

    /// The newest histogram whose frame the GPU has finished, once.
    private func takeHistogram() -> (LuminanceHistogram, Double)? {
        var newest: Int?
        for (i, r) in readbacks.enumerated() where !r.read && r.commandBuffer?.status == .completed {
            if newest.map({ readbacks[$0].serial < r.serial }) ?? true { newest = i }
        }
        guard let i = newest else { return nil }
        // Older ones are stale now.
        for j in readbacks.indices where readbacks[j].serial <= readbacks[i].serial { readbacks[j].read = true }
        let words = readbacks[i].buffer.contents().bindMemory(to: UInt32.self, capacity: Self.readbackCount)
        let n = LuminanceHistogram.binCount
        let h = LuminanceHistogram(bins: (0..<n).map { Double(words[$0]) }, dark: Double(words[n]))
        return (h, Double(words[n + 1]) / 64)
    }

    /// The frame's EV100 and pre-exposure: fixed by the settings, or the
    /// auto exposure moved by the wall-clock time since the last frame
    /// towards the latest histogram's target.
    func beginFrame(_ settings: ExposureSettings, realDt: Double) {
        var fresh = false
        if let (h, sun) = takeHistogram() {
            histogram = h
            sunVisibility = sun
            if let t = auto.target(h, compensation: settings.compensation) { target = t }
            fresh = true
        }
        if let fixed = settings.fixedEV100 {
            ev100 = fixed
        } else if let target {
            let snap = fresh && snaps > 0
            auto.update(target: target, dt: min(max(realDt, 0), 0.25), snap: snap)
            if snap { snaps -= 1 }
            ev100 = auto.ev100 ?? Self.initialEV100
        } else {
            ev100 = auto.ev100 ?? Self.initialEV100
        }
        previousPreExposure = preExposure
        preExposure = Exposure.exposure(ev100: ev100)
    }

    /// This frame's pre-exposure over the last frame's.
    var preExposureRatio: Double { previousPreExposure.map { preExposure / $0 } ?? 1 }
}

/// P0, first: sets the frame's exposure (`FrameUniforms.exposure`), the
/// Sun's coloured illuminance, the blue-noise offset, and binds the blue
/// noise and the tone LUT in their reserved slots. Track R1.
@MainActor
public final class ExposurePass: RenderPass {
    public let name = "Exposure"
    public let stage = PassStage.prepare
    public let order = -100
    /// It sets up a frame for the HDR targets, so it runs only on a plan that has them.
    public var reads: Set<ResourceID> { [.hdrColor] }

    let control: ExposureControl
    private let textures: PostTextures
    private var lastFrameIndex = 0

    init(control: ExposureControl, textures: PostTextures) {
        self.control = control
        self.textures = textures
    }

    public func setUp(_ s: PassSetup) throws {
        try textures.setUp(device: s.device)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        let scene = f.scene
        // A new scenario (the extractor started over) sets the camera at once.
        if scene.clock.frameIndex < lastFrameIndex { control.reset() }
        lastFrameIndex = scene.clock.frameIndex
        control.beginFrame(f.settings.post.exposure, realDt: scene.clock.realDt)
        f.frame.exposure = SIMD4(Float(control.preExposure), Float(control.ev100), Float(control.preExposureRatio),
                                 Float(f.settings.post.exposure.compensation))
        let lux = scene.sun.illuminance, c = Photometry.sunColor.scaled(by: lux)
        f.frame.sunIlluminance = SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(lux))
        // The dither's noise moves each frame (a 2D golden-ratio sequence).
        let k = Double(scene.clock.frameIndex % 4_096)
        let n = Double(BlueNoise.shared.size)
        f.frame.jitter.z = Float(((k * 0.754_877_666).truncatingRemainder(dividingBy: 1) * n).rounded(.down))
        f.frame.jitter.w = Float(((k * 0.569_840_291).truncatingRemainder(dividingBy: 1) * n).rounded(.down))
        if let t = textures.blueNoise { f.slotTextures[Binding.blueNoise] = t }
        if let t = textures.lut(f.settings.post.toneCurve) { f.slotTextures[Binding.toneLUT] = t }
    }
}

/// The textures R1 generates at start-up: the blue noise and the tone LUT
/// (`BlueNoise`, `ToneLUT`), built once per process and uploaded per device.
@MainActor
final class PostTextures {
    private(set) var blueNoise: MTLTexture?
    private var agx: MTLTexture?
    private var device: MTLDevice?

    /// Baked once per process: AgX's LUT (AgX is the default curve).
    private nonisolated static let agxLUT = ToneLUT(.agx)

    func setUp(device: MTLDevice) throws {
        guard self.device !== device else { return }
        self.device = device
        let noise = BlueNoise.shared
        let nd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: noise.size, height: noise.size,
                                                          mipmapped: false)
        nd.usage = .shaderRead
        nd.storageMode = .shared
        guard let n = device.makeTexture(descriptor: nd) else { throw SceneRenderer.Failure.noResources }
        noise.values.withUnsafeBytes {
            n.replace(region: MTLRegionMake2D(0, 0, noise.size, noise.size), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: 4 * noise.size)
        }
        blueNoise = n
        agx = try Self.upload(Self.agxLUT, device: device)
    }

    /// The LUT for `curve`; Neutral is computed in the shader and has none
    /// (the slot keeps AgX's, which it does not read).
    func lut(_ curve: ToneCurve) -> MTLTexture? { agx }

    static func upload(_ lut: ToneLUT, device: MTLDevice) throws -> MTLTexture {
        let n = ToneLUT.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = n
        d.height = n
        d.depth = n
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw SceneRenderer.Failure.noResources }
        let half = lut.texels.map { Float16($0) }
        half.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                      bytesPerRow: 8 * n, bytesPerImage: 8 * n * n)
        }
        return t
    }
}

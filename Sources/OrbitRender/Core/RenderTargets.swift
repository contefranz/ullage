import Foundation
import Metal

// MARK: - Target plans

/// How the frame's render stages map onto attachments: which stage opens a
/// render encoder on what, and the formats its pipelines must match. The
/// plan is swappable, so a new target structure (R1's HDR targets, R6's
/// half-resolution ones) is a file of its own rather than an edit of the
/// frame graph.
@MainActor
public protocol SceneTargetPlan: AnyObject {
    /// The formats the render pipelines of `stage` must match.
    func formats(for stage: PassStage) -> SceneFormats
    /// The resources the plan's attachments provide (`ResourceID.sceneColor`, ...).
    var provides: Set<ResourceID> { get }
    /// Whether P4 can run: the scene draws into a target post reads, and P5
    /// draws on the output after it.
    var hasPostStage: Bool { get }
    /// (Re)allocates the plan's own targets.
    func resize(_ size: RenderSize, device: MTLDevice)
    /// The render pass `stage` opens an encoder on, or nil to go on drawing
    /// in the encoder the previous render stage opened.
    func renderPass(for stage: PassStage, _ f: FrameContext) -> MTLRenderPassDescriptor?
}

/// The M1.5 structure, kept until R1's HDR targets: one 4× MSAA LDR pass
/// (sRGB colour, reversed-Z depth, both memoryless) resolving straight into
/// the output, which P1, P2, P3 and P5 all draw in, in that order.
@MainActor
public final class DirectTargetPlan: SceneTargetPlan {
    public let colorFormat: MTLPixelFormat
    public let depthFormat = MTLPixelFormat.depth32Float
    public let sampleCount: Int
    private var color: MTLTexture?
    private var depth: MTLTexture?

    public init(colorFormat: MTLPixelFormat, sampleCount: Int) {
        self.colorFormat = colorFormat
        self.sampleCount = sampleCount
    }

    public func formats(for stage: PassStage) -> SceneFormats {
        SceneFormats(color: colorFormat, depth: depthFormat, sampleCount: sampleCount, output: colorFormat)
    }

    public var provides: Set<ResourceID> { [.sceneColor, .sceneDepth, .output] }

    /// The scene resolves straight into the output: nothing for a post pass to read.
    public var hasPostStage: Bool { false }

    public func resize(_ size: RenderSize, device: MTLDevice) {
        func target(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width, height: size.height,
                                                             mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .memoryless
            if sampleCount > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = sampleCount
            }
            return device.makeTexture(descriptor: d)
        }
        color = sampleCount > 1 ? target(colorFormat) : nil
        depth = target(depthFormat)
    }

    public func renderPass(for stage: PassStage, _ f: FrameContext) -> MTLRenderPassDescriptor? {
        guard stage == .opaque else { return nil }
        let pass = MTLRenderPassDescriptor()
        let c = pass.colorAttachments[0]!
        c.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        c.loadAction = .clear
        if let color {
            c.texture = color
            c.resolveTexture = f.output
            c.storeAction = .multisampleResolve
        } else {
            c.texture = f.output
            c.storeAction = .store
        }
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 0
        return pass
    }
}

// MARK: - Transient and history textures

/// Transient textures for one frame, reused from frame to frame by
/// descriptor (the queue orders the GPU's use of them). Dropped on a resize.
@MainActor
public final class TexturePool {
    private struct Key: Hashable {
        let format: UInt, type: UInt, width: Int, height: Int, depth: Int, arrayLength: Int, mipmaps: Int
        let samples: Int, usage: UInt, storage: UInt

        init(_ d: MTLTextureDescriptor) {
            format = d.pixelFormat.rawValue
            type = d.textureType.rawValue
            width = d.width
            height = d.height
            depth = d.depth
            arrayLength = d.arrayLength
            mipmaps = d.mipmapLevelCount
            samples = d.sampleCount
            usage = d.usage.rawValue
            storage = d.storageMode.rawValue
        }
    }

    private let device: MTLDevice
    private var free: [Key: [MTLTexture]] = [:]
    private var used: [Key: [MTLTexture]] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// A texture matching `descriptor` that no other pass holds this frame.
    public func texture(_ descriptor: MTLTextureDescriptor) -> MTLTexture? {
        let key = Key(descriptor)
        let t = free[key]?.popLast() ?? device.makeTexture(descriptor: descriptor)
        if let t { used[key, default: []].append(t) }
        return t
    }

    func beginFrame() {
        for (key, list) in used { free[key, default: []] += list }
        used = [:]
    }

    func purge() {
        free = [:]
        used = [:]
    }
}

/// Textures kept from one frame to the next for temporal passes (cloud
/// reprojection): each id has this frame's texture and last frame's.
@MainActor
public final class HistoryTargets {
    private struct Pair {
        var current: MTLTexture
        var previous: MTLTexture
        var width: Int, height: Int, format: MTLPixelFormat
        var valid: Bool
        var touched: Bool
    }

    private let device: MTLDevice
    private var pairs: [ResourceID: Pair] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// This frame's texture for `id` and last frame's; `valid` is false when
    /// last frame's holds nothing usable (first use, a resize, a temporal reset).
    public func pair(_ id: ResourceID, descriptor: MTLTextureDescriptor)
        -> (current: MTLTexture, previous: MTLTexture, valid: Bool)? {
        if let p = pairs[id], p.width == descriptor.width, p.height == descriptor.height,
           p.format == descriptor.pixelFormat {
            pairs[id]!.touched = true
            return (p.current, p.previous, p.valid)
        }
        guard let a = device.makeTexture(descriptor: descriptor), let b = device.makeTexture(descriptor: descriptor)
        else { return nil }
        pairs[id] = Pair(current: a, previous: b, width: descriptor.width, height: descriptor.height,
                         format: descriptor.pixelFormat, valid: false, touched: true)
        return (a, b, false)
    }

    /// Every history is stale (a temporal reset).
    func invalidate() {
        for id in pairs.keys { pairs[id]!.valid = false }
    }

    func purge() { pairs = [:] }

    /// The frame's textures become last frame's.
    func endFrame() {
        for (id, p) in pairs where p.touched {
            pairs[id] = Pair(current: p.previous, previous: p.current, width: p.width, height: p.height,
                             format: p.format, valid: true, touched: false)
        }
    }
}

// MARK: - Fallbacks for the reserved texture slots

/// One zero texel of the right type for each reserved texture slot nobody
/// has filled, so that a shader may sample any of them.
@MainActor
final class FallbackTextures {
    private(set) var bySlot: [Int: MTLTexture] = [:]
    private let depthTextures: [MTLTexture]

    init?(device: MTLDevice) {
        func color(_ type: MTLTextureType) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = type
            d.pixelFormat = .rgba16Float
            d.width = 1
            d.height = 1
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            let zero = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
            defer { zero.deallocate() }
            zero.initializeMemory(as: UInt8.self, repeating: 0, count: 8)
            t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0, withBytes: zero,
                      bytesPerRow: 8, bytesPerImage: 8)
            if type == .typeCube {
                for slice in 1..<6 {
                    t.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: slice, withBytes: zero,
                              bytesPerRow: 8, bytesPerImage: 8)
                }
            }
            return t
        }
        func depth(_ type: MTLTextureType) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = type
            d.pixelFormat = .depth32Float
            d.width = 1
            d.height = 1
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let flat = color(.type2D), let cube = color(.typeCube), let volume = color(.type3D),
              let shadow = depth(.type2DArray), let sceneDepth = depth(.type2D) else { return nil }
        depthTextures = [shadow, sceneDepth]
        bySlot = [Binding.sceneDepth: sceneDepth, Binding.environmentSpecular: cube, Binding.environmentIrradiance: cube,
                  Binding.dfgLUT: flat, Binding.shadowAtlas: shadow, Binding.cloudShadow: flat,
                  Binding.transmittanceLUT: flat, Binding.blueNoise: flat, Binding.toneLUT: volume,
                  Binding.multipleScatteringLUT: flat, Binding.skyViewLUT: flat, Binding.aerialPerspective: volume]
    }

    /// Clears the depth fallbacks (private, so undefined until written) to
    /// 0, reversed-Z's far.
    func clear(on queue: MTLCommandQueue) {
        guard let cb = queue.makeCommandBuffer() else { return }
        for t in depthTextures {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = t
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .store
            pass.renderTargetWidth = 1
            pass.renderTargetHeight = 1
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        cb.commit()
    }
}

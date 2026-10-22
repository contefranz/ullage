import Foundation
import Metal

/// Track R1's targets: the scene (P1-P3) in one 4× MSAA pass on memoryless
/// rgba16Float colour and depth32Float, resolved at its end into `hdrColor`
/// (rgba16Float, with each sample weighted by `HDRResolvePass`) and
/// `sceneDepth` (the nearest sample, `.max` in reversed-Z); P4's post reads
/// them and writes the output; P5's overlays draw on the output, depth-tested
/// against `sceneDepth`. The light in the scene's colour is linear Rec. 709
/// luminance times the frame's pre-exposure (`FrameUniforms.exposure.x`).
///
/// When the encoders are split for timing, the samples are stored between
/// them in private textures, so the image is the same.
@MainActor
public final class HDRTargetPlan: SceneTargetPlan {
    public static let colorFormat = MTLPixelFormat.rgba16Float
    public let outputFormat: MTLPixelFormat
    public let depthFormat = MTLPixelFormat.depth32Float
    public let sampleCount: Int
    private var size = RenderSize(width: 0, height: 0)
    private var device: MTLDevice?
    private var memoryless: (color: MTLTexture?, depth: MTLTexture?)
    private(set) var stored: (color: MTLTexture?, depth: MTLTexture?)
    /// Frames since the last split one: the stored targets go once timing
    /// has been off for a while.
    private var unsplitFrames = 0
    /// The render pass last opened (the scene's or the overlay's), for the continuations.
    private var current: MTLRenderPassDescriptor?

    public init(outputFormat: MTLPixelFormat, sampleCount: Int) {
        self.outputFormat = outputFormat
        self.sampleCount = sampleCount
    }

    public func formats(for stage: PassStage) -> SceneFormats {
        stage == .overlay
            ? SceneFormats(color: outputFormat, depth: depthFormat, sampleCount: 1, output: outputFormat)
            : SceneFormats(color: Self.colorFormat, depth: depthFormat, sampleCount: sampleCount, output: outputFormat)
    }

    public var provides: Set<ResourceID> { [.sceneColor, .sceneDepth, .output, .hdrColor] }

    public func resize(_ size: RenderSize, device: MTLDevice) {
        self.size = size
        self.device = device
        memoryless = (target(Self.colorFormat, .memoryless), target(depthFormat, .memoryless))
        stored = (nil, nil)
    }

    private func target(_ format: MTLPixelFormat, _ storage: MTLStorageMode) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width, height: size.height,
                                                         mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = storage
        if sampleCount > 1 {
            d.textureType = .type2DMultisample
            d.sampleCount = sampleCount
        }
        return device?.makeTexture(descriptor: d)
    }

    /// A single-sample frame texture the scene resolves into.
    private func resolveTarget(_ format: MTLPixelFormat, _ f: FrameContext) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width, height: size.height,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return f.pool.texture(d)
    }

    public func renderPass(for stage: PassStage, _ f: FrameContext) -> MTLRenderPassDescriptor? {
        switch stage {
        case .opaque: return scenePass(f)
        case .overlay: return overlayPass(f)
        default: return nil
        }
    }

    private func scenePass(_ f: FrameContext) -> MTLRenderPassDescriptor? {
        let split = f.splitsEncoders
        if split {
            unsplitFrames = 0
            if stored.depth == nil { stored = (target(Self.colorFormat, .private), target(depthFormat, .private)) }
        } else {
            unsplitFrames += 1
            if unsplitFrames > 30, stored.depth != nil { stored = (nil, nil) }
        }
        let multisampled = sampleCount > 1
        guard let hdr = resolveTarget(Self.colorFormat, f), let depth = resolveTarget(depthFormat, f) else { return nil }
        let pass = MTLRenderPassDescriptor()
        let c = pass.colorAttachments[0]!
        c.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        c.loadAction = .clear
        let z = pass.depthAttachment!
        z.loadAction = .clear
        z.clearDepth = 0
        if multisampled {
            c.texture = split ? stored.color : memoryless.color
            c.resolveTexture = hdr
            c.storeAction = split ? .storeAndMultisampleResolve : .multisampleResolve
            z.texture = split ? stored.depth : memoryless.depth
            z.resolveTexture = depth
            z.depthResolveFilter = .max
            z.storeAction = split ? .storeAndMultisampleResolve : .multisampleResolve
        } else {
            c.texture = hdr
            c.storeAction = .store
            z.texture = depth
            z.storeAction = .store
        }
        f.textures[.hdrColor] = hdr
        f.textures[.sceneColor] = hdr
        f.textures[.sceneDepth] = depth
        current = pass
        return pass
    }

    /// The overlays on the tone-mapped output, tested against the scene's
    /// resolved depth; none under a debug view, which replaces the image.
    private func overlayPass(_ f: FrameContext) -> MTLRenderPassDescriptor? {
        guard f.settings.debug.view == .none, let depth = f.textures[.sceneDepth] else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = f.output
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .dontCare
        // The depth is this pass's attachment: not a texture it may sample too.
        f.slotTextures[Binding.sceneDepth] = nil
        current = pass
        return pass
    }

    public func continuation(_ f: FrameContext) -> MTLRenderPassDescriptor? {
        guard let pass = current?.copy() as? MTLRenderPassDescriptor else { return nil }
        pass.colorAttachments[0].loadAction = .load
        pass.depthAttachment.loadAction = .load
        return pass
    }
}

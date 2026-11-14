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
/// A render-stage pass on the command buffer (`FrameContext.breaksScene`,
/// R6's effect slots) ends the scene's encoder, and the scene resumes after
/// it. A break in P2 or P3 resolves the scene there, with the same
/// weighting, and the resumed scene is re-expanded in tile memory: its first
/// draw puts each pixel's resolved light and nearest depth in every sample
/// (`post_expand_scene`). No sample is stored or loaded; what the break
/// costs is a 1× resolve and a 1× read. The passes after the break keep
/// their 4× pipelines and antialias their own edges, but they see the scene
/// before them resolved: where one draws behind an opaque silhouette, the
/// edge pixel's nearest depth hides it in the whole pixel. A break in P1,
/// with opaque passes after it, stores the samples and loads them again.
/// The pass that breaks the scene finds `sceneDepth` resolved as far as the
/// scene has gone; `hdrColor` and `sceneDepth` are final only in P4 (the
/// resumed scene resolves into textures of its own).
///
/// When the encoders are split for timing, the samples are stored between
/// encoders in private textures, and the image is that of a frame that
/// keeps its samples at every break. The resume after a break in P2 or P3,
/// which the profile charges to the pass that broke the scene, then does
/// the plain frame's work on scratch targets (the re-expansion, the
/// weighting, the 1× resolve), so the timing is the plain frame's.
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
    /// Frames since the last one that stored samples: the stored targets go
    /// once none has for a while.
    private var unsplitFrames = 0

    /// Breaks in P2 and P3 resolve the scene and re-expand it (above); off,
    /// they keep the samples, as a break in P1 does. For the tests and the
    /// timings that compare the two.
    var resolvesAtBreaks = true
    /// The weighting and the re-expansion the plan draws itself.
    private var draws: (weight: MTLRenderPipelineState, expand: MTLRenderPipelineState,
                        depthAlways: MTLDepthStencilState)?

    // The frame's state.
    /// The stage the graph is in (its last `renderPass(for:)`).
    private var stage = PassStage.prepare
    /// The render pass the continuations copy: the scene's last, or the overlay's.
    private var current: MTLRenderPassDescriptor?
    /// The scene's render passes this frame (kept, so identity holds).
    private var scenePasses: [MTLRenderPassDescriptor] = []
    /// The render passes handed out and not yet ended, in order: the graph
    /// opens and ends them in that order (`endScene`).
    private var handedOut: [MTLRenderPassDescriptor] = []
    /// The graph begins the plan's encoders (`beginScene`), as seen on the
    /// scene's first this frame: the re-expansion needs it.
    private var begins = false
    /// How the scene's last encoder ended before a break, until it resumes.
    private enum Break {
        /// Its samples stored, in the stage it broke in.
        case kept(PassStage)
        /// Resolved into these.
        case resolved(color: MTLTexture, depth: MTLTexture)
    }
    private var broken: Break?
    /// The render pass that begins with the re-expansion, and what from.
    private var expansion: (pass: MTLRenderPassDescriptor, color: MTLTexture, depth: MTLTexture)?
    /// The timed stand-in for a break's re-expansion (split frames).
    private var measurement: MTLRenderPassDescriptor?
    /// Re-expansions drawn, and of those the timed stand-ins, for the tests.
    private(set) var expansions = (drawn: 0, timed: 0)
    /// The store action set where a break ended a scene encoder, in order,
    /// for the tests: `.multisampleResolve` stores no sample.
    private(set) var breakStores: [MTLStoreAction] = []

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

    public func setUp(_ s: PassSetup) throws {
        draws = nil
        guard sampleCount > 1 else { return }
        let library = try s.shaders.library(.post)
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            try PipelineBuilder.make(library, vertex: "post_fullscreen_vertex", fragment: fragment, blend: .opaque,
                                     color: Self.colorFormat, depth: depthFormat, sampleCount: sampleCount,
                                     device: s.device)
        }
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .always
        d.isDepthWriteEnabled = true
        guard let always = s.device.makeDepthStencilState(descriptor: d) else { throw Failure.noDepthState }
        draws = (try pipeline("post_resolve_encode"), try pipeline("post_expand_scene"), always)
    }

    public enum Failure: Error { case noDepthState }

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
        self.stage = stage
        switch stage {
        case .opaque: return scenePass(f)
        case .overlay: return overlayPass(f)
        default: return nil
        }
    }

    private func scenePass(_ f: FrameContext) -> MTLRenderPassDescriptor? {
        scenePasses = []
        handedOut = []
        begins = false
        broken = nil
        expansion = nil
        measurement = nil
        // The samples may be stored: a frame split for timing, or one that
        // breaks the scene (in P1, or with the re-expansion off).
        let split = f.splitsEncoders || f.breaksScene
        if split {
            unsplitFrames = 0
            if stored.depth == nil { stored = (target(Self.colorFormat, .private), target(depthFormat, .private)) }
        } else {
            unsplitFrames += 1
            if unsplitFrames > 30, stored.depth != nil { stored = (nil, nil) }
        }
        let multisampled = sampleCount > 1
        // Its store actions are set as each encoder ends (`endScene`).
        let deferred = split && multisampled
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
            c.storeAction = deferred ? .unknown : .multisampleResolve
            z.texture = split ? stored.depth : memoryless.depth
            z.resolveTexture = depth
            z.depthResolveFilter = .max
            z.storeAction = deferred ? .unknown : .multisampleResolve
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
        scenePasses.append(pass)
        handedOut.append(pass)
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
        handedOut.append(pass)
        return pass
    }

    private func isScene(_ pass: MTLRenderPassDescriptor) -> Bool { scenePasses.contains { $0 === pass } }

    public func continuation(_ f: FrameContext) -> MTLRenderPassDescriptor? {
        guard let last = current else { return nil }
        // The scene resumes after a break when none of its encoders is open
        // (a split's continuation comes while the last one is).
        let resuming = handedOut.isEmpty && isScene(last) ? broken : nil
        broken = nil
        switch resuming {
        case .resolved(let color, let depth)?:
            guard let pass = expandedPass(f, publish: true) else { return nil }
            expansion = (pass, color, depth)
            current = pass
            handedOut.append(pass)
            return pass
        case .kept(let brokeIn)? where f.splitsEncoders && brokeIn != .opaque && reExpands:
            // Timing: the plain frame would have resolved and re-expanded
            // here. That work, on scratch targets; the scene goes on in the
            // stored samples (`current`) after it.
            guard let pass = expandedPass(f, publish: false), let color = f.textures[.hdrColor],
                  let depth = f.textures[.sceneDepth] else { break }
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.storeAction = .multisampleResolve
            expansion = (pass, color, depth)
            measurement = pass
            handedOut.append(pass)
            return pass
        default:
            break
        }
        guard let pass = last.copy() as? MTLRenderPassDescriptor else { return nil }
        pass.colorAttachments[0].loadAction = .load
        pass.depthAttachment.loadAction = .load
        if isScene(last) {
            current = pass
            scenePasses.append(pass)
        }
        handedOut.append(pass)
        return pass
    }

    /// Breaks after P1 may resolve the scene and re-expand it.
    private var reExpands: Bool { resolvesAtBreaks && draws != nil && begins }

    /// A render pass on the memoryless samples that loads nothing (the
    /// re-expansion fills them) and resolves into new frame textures,
    /// published as the scene's when `publish`; its store actions are left
    /// to `endScene`.
    private func expandedPass(_ f: FrameContext, publish: Bool) -> MTLRenderPassDescriptor? {
        guard let hdr = resolveTarget(Self.colorFormat, f), let depth = resolveTarget(depthFormat, f) else { return nil }
        let pass = MTLRenderPassDescriptor()
        let c = pass.colorAttachments[0]!
        c.texture = memoryless.color
        c.loadAction = .dontCare
        c.resolveTexture = hdr
        c.storeAction = .unknown
        let z = pass.depthAttachment!
        z.texture = memoryless.depth
        z.loadAction = .dontCare
        z.resolveTexture = depth
        z.depthResolveFilter = .max
        z.storeAction = .unknown
        if publish {
            f.textures[.hdrColor] = hdr
            f.textures[.sceneColor] = hdr
            f.textures[.sceneDepth] = depth
        }
        scenePasses.append(pass)
        return pass
    }

    public func beginScene(_ encoder: MTLRenderCommandEncoder, on pass: MTLRenderPassDescriptor, _ f: FrameContext) {
        guard isScene(pass) else { return }
        begins = true
        guard let x = expansion, x.pass === pass, let draws else { return }
        expansion = nil
        expansions.drawn += 1
        if pass === measurement { expansions.timed += 1 }
        encoder.pushDebugGroup("HDR scene re-expanded")
        encoder.setRenderPipelineState(draws.expand)
        encoder.setDepthStencilState(draws.depthAlways)
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(x.color, index: 0)
        encoder.setFragmentTexture(x.depth, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setFragmentTexture(nil, index: 0)
        encoder.setFragmentTexture(nil, index: 1)
        encoder.popDebugGroup()
    }

    /// HDRResolvePass's weighting, drawn where a break resolves the scene.
    private func weight(_ encoder: MTLRenderCommandEncoder, _ f: FrameContext) {
        guard let draws else { return }
        encoder.pushDebugGroup("HDR resolve at the break")
        encoder.setRenderPipelineState(draws.weight)
        encoder.setDepthStencilState(f.states.noDepth)
        encoder.setCullMode(.none)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.popDebugGroup()
    }

    public func endScene(_ encoder: MTLRenderCommandEncoder, resumes: Bool, _ f: FrameContext) {
        guard !handedOut.isEmpty else { return }
        let pass = handedOut.removeFirst()
        if pass === measurement {
            // Its store actions were set up front.
            weight(encoder, f)
            measurement = nil
            return
        }
        // The overlay's, and the scene's on a frame that neither breaks nor
        // is timed, set their store actions up front.
        guard pass.colorAttachments[0].storeAction == .unknown else { return }
        // The re-expanded scene's samples cannot be stored.
        let onTile = pass.colorAttachments[0].texture === memoryless.color
        let store: MTLStoreAction
        if !resumes {
            store = .multisampleResolve
        } else if onTile || !f.splitsEncoders && stage != .opaque && reExpands,
                  let c = pass.colorAttachments[0].resolveTexture, let z = pass.depthAttachment.resolveTexture {
            // A break in P2 or P3: weighted and resolved here, re-expanded
            // where the scene resumes.
            weight(encoder, f)
            store = .multisampleResolve
            broken = .resolved(color: c, depth: z)
            breakStores.append(store)
        } else {
            // A break in P1, or a split while timing: the samples stay.
            store = .storeAndMultisampleResolve
            broken = .kept(stage)
            breakStores.append(store)
        }
        encoder.setColorStoreAction(store, index: 0)
        encoder.setDepthStoreAction(store)
    }
}

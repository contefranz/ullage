import Foundation
import Metal
import OrbitScene

/// The effect slots' composite (P3, after the volumes and before the
/// full-resolution additive passes). It upsamples the half-resolution
/// layers to the frame by depth (`EffectSlots.upsampleWeights`), orders
/// clouds, volumes and OIT pixel by pixel by their fronts
/// (`EffectSlots.composite`), and blends them, premultiplied, over the
/// scene in the scene's own encoder.
///
/// The frame's order: opaque → clouds → plumes and smoke (half resolution)
/// → this composite → additive sparks at full resolution (order above 35:
/// P3's particles at 40, the entry plasma at 50) → overlays → tone mapping.
@MainActor
public final class TransparentCompositePass: RenderPass {
    public let name = "Transparent composite"
    public let stage = PassStage.transparent
    public let order = 35
    public var reads: Set<ResourceID> { [.sceneDepth, .halfResDepth, .halfResFronts] }

    let slots: HalfResTransparentPass
    private var pipeline: MTLRenderPipelineState?

    public init(slots: HalfResTransparentPass) {
        self.slots = slots
    }

    public func isActive(in f: FrameContext) -> Bool { slots.isActive(in: f) }

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.transparentComposite),
                                             vertex: "effect_composite_vertex", fragment: "effect_composite_fragment",
                                             blend: .premultiplied, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, let u = slots.uniformsBuffer,
              let depths = f.textures[.halfResDepth], let fronts = f.textures[.halfResFronts] else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.noDepth)
        enc.setFragmentBuffer(u.buffer, offset: u.offset, index: HalfResTransparentPass.uniformsIndex)
        enc.setFragmentTexture(depths, index: HalfResTransparentPass.sceneDepthIndex)
        Self.bindLayers(enc, f, fronts: fronts, standIn: depths)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The layers at textures 0-4; a layer not drawn this frame gets a
    /// stand-in the shader does not read (`EffectSlotUniforms.scale.w`).
    static func bindLayers(_ enc: MTLRenderCommandEncoder, _ f: FrameContext, fronts: MTLTexture, standIn: MTLTexture) {
        let ids: [ResourceID] = [.halfResClouds, .halfResTransparent, .oitAccumulation, .oitRevealage]
        for (i, id) in ids.enumerated() { enc.setFragmentTexture(f.textures[id] ?? standIn, index: i) }
        enc.setFragmentTexture(fronts, index: 4)
    }
}

/// F9's views of the effect slots (P4, over the output, as the render
/// foundation's debug views): the half-resolution test depth, each layer's
/// coverage, the nearest front. Black on a frame no effect draws in.
@MainActor
public final class EffectDebugViewPass: RenderPass {
    public let name = "Effect slots debug view"
    public let stage = PassStage.post
    public let order = 1_001
    public var reads: Set<ResourceID> { [.halfResDepth] }

    /// The views this pass draws, and their index in the shader.
    static let views: [DebugView: Float] = [.effectDepth: 1, .effectLayers: 2, .effectFront: 3]

    let slots: HalfResTransparentPass
    private var pipeline: MTLRenderPipelineState?

    public init(slots: HalfResTransparentPass) {
        self.slots = slots
    }

    public func isActive(in f: FrameContext) -> Bool { Self.views[f.settings.debug.view] != nil }

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.make(try s.shaders.library(.transparentComposite),
                                            vertex: "effect_composite_vertex", fragment: "effect_debug_fragment",
                                            blend: .opaque, color: s.formats.output, depth: .invalid, sampleCount: 1,
                                            device: s.device)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard let pipeline, let view = Self.views[f.settings.debug.view] else { return }
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = f.output
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        d.colorAttachments[0].loadAction = .clear
        d.colorAttachments[0].storeAction = .store
        guard let enc = f.makeRenderEncoder(d) else { return }
        defer { enc.endEncoding() }
        guard let u = slots.uniformsBuffer, let depths = f.textures[.halfResDepth],
              let fronts = f.textures[.halfResFronts] else { return }
        enc.setRenderPipelineState(pipeline)
        var params = SIMD4<Float>(view, 0, 0, 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setFragmentBuffer(u.buffer, offset: u.offset, index: HalfResTransparentPass.uniformsIndex)
        enc.setFragmentTexture(depths, index: HalfResTransparentPass.sceneDepthIndex)
        TransparentCompositePass.bindLayers(enc, f, fronts: fronts, standIn: depths)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

import Foundation
import Metal
import simd
import OrbitScene

/// The debug view the settings choose (F9), drawn over the output from the
/// resolved scene in place of the image (P4, so the markers are left out).
@MainActor
public final class DebugViewPass: RenderPass {
    public let name = "Debug view"
    public let stage = PassStage.post
    public let order = 1_000
    public var reads: Set<ResourceID> { [.sceneColor, .sceneDepth] }

    private var pipeline: MTLRenderPipelineState?

    public init() {}

    public func isActive(in f: FrameContext) -> Bool { f.settings.debug.view != .none }

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.make(try s.shaders.library(.debug), vertex: "debug_vertex",
                                            fragment: "debug_fragment", blend: .opaque, color: s.formats.output,
                                            depth: .invalid, sampleCount: 1, device: s.device)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard let pipeline, let color = f.textures[.sceneColor], let depth = f.textures[.sceneDepth],
              let index = DebugView.allCases.firstIndex(of: f.settings.debug.view) else { return }
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = f.output
        d.colorAttachments[0].loadAction = .dontCare
        d.colorAttachments[0].storeAction = .store
        guard let enc = f.makeRenderEncoder(d) else { return }
        enc.setRenderPipelineState(pipeline)
        var params = SIMD4<Float>(Float(index), 0, 0, 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setFragmentTexture(color, index: 0)
        enc.setFragmentTexture(depth, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

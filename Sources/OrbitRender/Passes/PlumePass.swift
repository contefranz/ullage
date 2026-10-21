import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The emitters' plumes as additive impostors, tested against the opaque
/// depth (P3). Track P2 owns this pass, Plumes.swift and the plume module.
@MainActor
public final class PlumePass: RenderPass {
    public let name = "Plumes"
    public let stage = PassStage.transparent
    public let order = 10

    private var pipeline: MTLRenderPipelineState?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.plume), vertex: "plume_vertex",
                                             fragment: "plume_fragment", blend: .additive, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        var plumes: [PlumeVertex] = []
        for p in f.scene.emitters where f.drawsMesh(p.vesselID) {
            Plumes.append(exit: p.exit, axis: p.axis, radius: p.exitRadius, style: p.style, fraction: p.thrustFraction,
                          pressureRatio: p.pressureRatio, jet: p.isJet, to: &plumes)
        }
        guard let b = f.arena.push(plumes) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        var u = PointUniforms(viewProjection: f.viewProjection, params: f.pointParams)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plumes.count)
    }
}

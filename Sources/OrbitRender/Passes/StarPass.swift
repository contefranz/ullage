import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The stars, directions at infinity (P1, first). Track R1 owns this file
/// and the star module, and makes the stars photometric.
@MainActor
public final class StarPass: RenderPass {
    public let name = "Stars"
    public let stage = PassStage.opaque
    public let order = 0

    private var pipeline: MTLRenderPipelineState?
    private var device: MTLDevice?
    private var stars: [Star] = []
    private var buffer: MTLBuffer?
    private var count = 0

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.star), vertex: "point_vertex",
                                             fragment: "point_fragment", blend: .alpha, setup: s)
        device = s.device
        upload()
    }

    /// The catalogue to draw (`StarCatalog`), set once.
    public func setStars(_ stars: [Star]) {
        self.stars = stars
        upload()
    }

    private func upload() {
        guard let device else { return }
        var pts: [PointVertex] = []
        pts.reserveCapacity(stars.count)
        for s in stars {
            let brightness = Float(pow(10, -0.4 * (s.magnitude - 1.0)))
            let size = Float(max(1.5, min(5.0, 4.5 - 0.5 * s.magnitude)))
            let c = Self.starColor(bv: s.colorIndex)
            pts.append(PointVertex(position: SIMD4(s.direction, 0),
                                   color: SIMD4(c.x, c.y, c.z, min(1, 0.25 + brightness)),
                                   size: SIMD4(size, 0, 0, 0)))
        }
        count = pts.count
        buffer = pts.isEmpty ? nil : device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<PointVertex>.stride,
                                                      options: .storageModeShared)
    }

    static func starColor(bv: Double) -> SIMD3<Float> {
        // Rough B-V -> linear RGB.
        let t = Float(max(-0.4, min(2.0, bv)))
        let r: Float = t < 0.4 ? 0.75 + 0.6 * t : 1.0
        let g: Float = t < 0.0 ? 0.82 + 0.3 * t : 0.98 - 0.25 * t
        let b: Float = t < 0.4 ? 1.0 : max(0.35, 1.0 - 0.6 * (t - 0.4))
        return SIMD3(r, g, b)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, let buffer else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.noDepth)
        var u = PointUniforms(viewProjection: f.viewProjection, params: f.pointParams)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
    }
}

/// Bodies and vessels too small to draw, as points: the Sun's glare, a
/// vessel tinted by its plume while a main engine or a solid fires, dimmed
/// in the shadow otherwise (P3, after the plumes). Track R1 owns this pass.
@MainActor
public final class FarPointPass: RenderPass {
    public let name = "Far points"
    public let stage = PassStage.transparent
    public let order = 20

    private var pipeline: MTLRenderPipelineState?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.star), vertex: "point_vertex",
                                             fragment: "point_fragment", blend: .alpha, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        var points: [PointVertex] = []
        for body in f.scene.bodies where f.drawsPoint(body) {
            let style = PlanetPass.style(for: body.id)
            points.append(PointVertex(position: SIMD4(body.position.normalized, 0),
                                      color: SIMD4(style.color.x, style.color.y, style.color.z, 1),
                                      size: SIMD4(body.isSun ? 24 : 4, 0, 0, 0)))
        }
        for v in f.scene.vessels where f.drawsPoint(v.id) {
            points.append(Self.point(of: v))
        }
        guard let b = f.arena.push(points) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        var u = PointUniforms(viewProjection: f.viewProjection, params: f.pointParams)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: points.count)
    }

    static func point(of v: RenderScene.Vessel) -> PointVertex {
        if let style = v.farPointStyle {
            let c = Plumes.pointColor(style)
            return PointVertex(position: SIMD4(v.position, 1), color: SIMD4(c.x, c.y, c.z, 1), size: SIMD4(5, 0, 0, 0))
        }
        let b = 0.9 * max(Float(v.light.sunlit), 0.2)
        return PointVertex(position: SIMD4(v.position, 1), color: SIMD4(1, 1, 1, b), size: SIMD4(3, 0, 0, 0))
    }
}

/// A point's vertex (StarShaders).
struct PointVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    var size: SIMD4<Float>
}

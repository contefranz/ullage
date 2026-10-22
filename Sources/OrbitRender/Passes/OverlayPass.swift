import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The focus vessel's orbit line, then the parachutes' risers, as lines
/// tested against the scene's depth, drawn after tone mapping in display
/// colours (P5, before the markers). R2 makes the risers quads in the scene.
@MainActor
public final class OrbitLinePass: RenderPass {
    public let name = "Orbit line"
    public let stage = PassStage.overlay
    public let order = -10

    private var pipeline: MTLRenderPipelineState?
    static let orbitColor = SIMD4<Float>(0.3, 1.0, 0.45, 0.8)
    static let riserColor = SIMD4<Float>(0.82, 0.8, 0.74, 0.85)

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.overlay), vertex: "line_vertex",
                                             fragment: "line_fragment", blend: .alpha, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        var lines: [LineVertex] = []
        var strips: [Int] = []
        for strip in f.scene.orbit?.strips ?? [] {
            strips.append(strip.count)
            lines += strip.map { LineVertex(position: SIMD4($0, 1), color: Self.orbitColor) }
        }
        for c in f.scene.canopies where f.drawsMesh(c.vesselID) {
            for (a, b) in c.risers {
                lines.append(LineVertex(position: SIMD4(a, 1), color: Self.riserColor))
                lines.append(LineVertex(position: SIMD4(b, 1), color: Self.riserColor))
            }
        }
        guard let b = f.arena.push(lines) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        var u = PointUniforms(viewProjection: f.viewProjection, params: f.pointParams)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
        var start = 0
        for count in strips {
            enc.drawPrimitives(type: .lineStrip, vertexStart: start, vertexCount: count)
            start += count
        }
        if lines.count > start {
            enc.drawPrimitives(type: .line, vertexStart: start, vertexCount: lines.count - start)
        }
    }
}

/// The orbit's markers (Ap, Pe, AN, DN, EI) and their readouts, a fixed
/// size on screen, over everything (P5). Anchors a body hides were left out
/// by the scene.
@MainActor
public final class MarkerPass: RenderPass {
    public let name = "Markers"
    public let stage = PassStage.overlay
    public let order = 0

    private var pipeline: MTLRenderPipelineState?
    private var atlas: SpriteAtlas?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.overlay), vertex: "sprite_vertex",
                                             fragment: "sprite_fragment", blend: .premultiplied, setup: s)
        atlas = SpriteAtlas(device: s.device)
        if atlas == nil { NSLog("OrbitSim: the sprite atlas could not be drawn; no orbit markers") }
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, let atlas else { return }
        let pointScale = f.pointParams.x
        var sprites: [SpriteVertex] = []
        for marker in f.scene.orbit?.markers ?? [] {
            let p = marker.position
            let width = atlas.append(.orbit(marker.kind), at: p, pointScale: pointScale, to: &sprites)
            if let text = marker.text, let cell = atlas.cell(.orbit(marker.kind)) {
                atlas.appendText(text, at: p, offset: SIMD2(width - cell.anchor.x + 1, -4), pointScale: pointScale,
                                 tint: SIMD4(0.9, 0.95, 1, 1), to: &sprites)
            }
        }
        guard let b = f.arena.push(sprites) else { return }
        let viewport = f.scene.camera.viewport
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.noDepth)
        var u = SpriteUniforms(viewProjection: f.viewProjection,
                               params: SIMD4(2 / Float(max(viewport.width, 1)), 2 / Float(max(viewport.height, 1)), 0, 0))
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(f.states.linearClamp, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: sprites.count)
    }
}

// Swift mirrors of OverlayShaders' structs.

struct LineVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

struct SpriteUniforms {
    var viewProjection: simd_float4x4
    /// xy: 2 / drawable size in pixels (pixels to NDC).
    var params: SIMD4<Float>
}

import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

// R6's test emitters (`TransparencySettings.testEmitters`, none by
// default). They draw through the effect slots exactly as C2, P2 and P3
// will draw theirs, so they prove the contract and show it in look-dev
// shots and F9:
// - a slab, through the clouds layer (C2);
// - a cone, through the volumes layer (P2);
// - sprites, through OIT (P3's smoke);
// - sparks, additive at full resolution after the composite (P3);
// - a column, and the look-dev backdrop, in P1.

/// The test emitters' uniforms (EffectTestShaders' EffectTestUniforms).
struct EffectTestUniforms {
    var slabCenter = SIMD4<Float>.zero
    var slabEast = SIMD4<Float>.zero
    var slabNorth = SIMD4<Float>.zero
    var slabUp = SIMD4<Float>.zero
    var coneApex = SIMD4<Float>.zero
    var coneAxis = SIMD4<Float>.zero
    var light = SIMD4<Float>.zero
    var params = SIMD4<Float>.zero

    /// The frame's light and scales, with neither shape.
    @MainActor
    init(_ f: FrameContext, hdrOpaque: Bool = false) {
        light = SIMD4(f.scene.sun.direction, Float(f.scene.sun.illuminance / Photometry.solarIlluminanceAt1AU))
        params = SIMD4(f.frame.exposure.x * EffectTestEmitters.radianceScale, Float(EffectTestScene.slabAlbedo),
                       f.frame.frame.x, hdrOpaque ? 1 : 0)
    }
}

/// The half-resolution test emitters: the slab, the cone and the sprites.
@MainActor
public final class EffectTestEmitters: HalfResEffect {
    public let name = "Effect test emitters"

    /// Today's display-relative scale (1: a white surface facing the Sun).
    /// R1's units change it, here only.
    static let radianceScale: Float = 1
    /// Sides of the cone's proxy and of the column.
    static let segments = 32

    private var slab: MTLRenderPipelineState?
    private var cone: MTLRenderPipelineState?
    private var sprites: MTLRenderPipelineState?
    /// Tests: draws the sprites last to first (OIT must not mind).
    var reversesSprites = false

    public init() {}

    public func setUpHalfRes(_ s: HalfResSetup) throws {
        let library = try s.shaders.library(.effectTest)
        slab = try s.pipeline(library, vertex: "effect_test_fullscreen_vertex", fragment: "effect_test_slab_fragment",
                              layer: .clouds)
        cone = try s.pipeline(library, vertex: "effect_test_cone_vertex", fragment: "effect_test_cone_fragment",
                              layer: .volumes)
        sprites = try s.pipeline(library, vertex: "effect_test_sprite_vertex", fragment: "effect_test_sprite_fragment",
                                 layer: .oit)
    }

    public func halfResLayers(in f: FrameContext) -> HalfResLayers {
        var l = HalfResLayers()
        for e in f.settings.transparency.testEmitters {
            switch e.kind {
            case .slab: l.insert(.clouds)
            case .cone: l.insert(.volumes)
            case .sprites where e.count > 0: l.insert(.oit)
            default: break
            }
        }
        return l
    }

    public func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder) {
        let frame = EffectTargetFrame(scene: f.scene)
        for e in f.settings.transparency.testEmitters {
            var u = EffectTestUniforms(f)
            switch e.kind {
            case .slab:
                guard let slab else { continue }
                let s = EffectTestScene.slab(e, in: frame)
                u.slabCenter = SIMD4(s.center, Float(s.extinction))
                u.slabEast = SIMD4(s.axes.east, Float(s.halfExtents.x))
                u.slabNorth = SIMD4(s.axes.north, Float(s.halfExtents.y))
                u.slabUp = SIMD4(s.axes.up, Float(s.halfExtents.z))
                enc.setRenderPipelineState(slab)
                enc.setDepthStencilState(slots.noDepth)
                enc.setCullMode(.none)
                enc.setFragmentBytes(&u, length: MemoryLayout<EffectTestUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            case .cone:
                let c = EffectTestScene.cone(e, in: frame)
                guard let cone, let mesh = f.arena.push(Self.coneProxy(c)) else { continue }
                u.coneApex = SIMD4(c.apex, Float(c.length))
                u.coneAxis = SIMD4(c.axis, Float(c.radius))
                enc.setRenderPipelineState(cone)
                enc.setDepthStencilState(slots.noDepth)
                // Back faces only: each texel once, the camera inside too.
                enc.setFrontFacing(.counterClockwise)
                enc.setCullMode(.front)
                enc.setVertexBuffer(mesh.buffer, offset: mesh.offset, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<EffectTestUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.segments * 6)
                enc.setCullMode(.none)
            case .sprites:
                var list = EffectTestScene.sprites(e, in: frame).map {
                    Sprite(centerRadius: SIMD4($0.center, Float($0.radius)), colorAlpha: SIMD4($0.color, Float($0.alpha)))
                }
                if reversesSprites { list.reverse() }
                guard let sprites, let b = f.arena.push(list) else { continue }
                enc.setRenderPipelineState(sprites)
                enc.setDepthStencilState(slots.depthTest)
                enc.setCullMode(.none)
                enc.setVertexBuffer(b.buffer, offset: b.offset, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<EffectTestUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: list.count)
            case .sparks, .column:
                break
            }
        }
    }

    /// EffectTestShaders' EffectTestSprite.
    struct Sprite {
        var centerRadius: SIMD4<Float>
        var colorAlpha: SIMD4<Float>
    }

    /// The cone's proxy: its sides and base, circumscribed about the cone,
    /// counter-clockwise seen from outside, camera-relative.
    static func coneProxy(_ c: EffectTestScene.Cone) -> [SIMD4<Float>] {
        let (u, v) = basis(c.axis)
        let r = c.radius / cos(Double.pi / Double(segments)), base = c.apex + c.axis * c.length
        func ring(_ i: Int) -> Vec3 {
            let a = 2 * Double.pi * Double(i) / Double(segments)
            return base + u * (r * cos(a)) + v * (r * sin(a))
        }
        var out: [SIMD4<Float>] = []
        for i in 0..<segments {
            let p0 = ring(i), p1 = ring(i + 1)
            out += [c.apex, p1, p0].map { SIMD4($0, 1) }
            out += [base, p0, p1].map { SIMD4($0, 1) }
        }
        return out
    }

    /// Two unit vectors across `axis`, (u, v, axis) right-handed.
    static func basis(_ axis: Vec3) -> (Vec3, Vec3) {
        let helper = abs(axis.z) < 0.9 ? Vec3.unitZ : Vec3.unitX
        let u = helper.cross(axis).normalized
        return (u, axis.cross(u))
    }
}

/// The test column and the look-dev backdrop, opaque (P1, after the scene's
/// own opaque passes).
@MainActor
public final class EffectTestOpaquePass: RenderPass {
    public let name = "Effect test opaque"
    public let stage = PassStage.opaque
    public let order = 1_000

    private var column: MTLRenderPipelineState?
    private var backdrop: MTLRenderPipelineState?
    private var depthAlways: MTLDepthStencilState?
    private var hdr = false

    public init() {}

    public func isActive(in f: FrameContext) -> Bool {
        f.settings.transparency.testBackdrop || f.settings.transparency.testEmitters.contains { $0.kind == .column }
    }

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.effectTest)
        column = try PipelineBuilder.scene(library, vertex: "effect_test_column_vertex",
                                           fragment: "effect_test_column_fragment", blend: .opaque, setup: s)
        backdrop = try PipelineBuilder.scene(library, vertex: "effect_test_fullscreen_vertex",
                                             fragment: "effect_test_backdrop_fragment", blend: .opaque, setup: s)
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .always
        d.isDepthWriteEnabled = true
        depthAlways = s.device.makeDepthStencilState(descriptor: d)
        // R1's targets take Karis-encoded colour in P1.
        hdr = [.rgba16Float, .rgba32Float, .rg11b10Float].contains(s.formats.color)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let column, let backdrop, let depthAlways else { return }
        var u = EffectTestUniforms(f, hdrOpaque: hdr)
        enc.setCullMode(.none)
        if f.settings.transparency.testBackdrop {
            enc.setRenderPipelineState(backdrop)
            enc.setDepthStencilState(depthAlways)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        let frame = EffectTargetFrame(scene: f.scene)
        let vertices = f.settings.transparency.testEmitters.filter { $0.kind == .column }
            .flatMap { Self.columnMesh(EffectTestScene.column($0, in: frame)) }
        guard let b = f.arena.push(vertices) else { return }
        enc.setRenderPipelineState(column)
        enc.setDepthStencilState(f.states.depthWrite)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<EffectTestUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 2)
    }

    /// The column's sides and top, as (position, normal) pairs, camera-relative.
    static func columnMesh(_ c: EffectTestScene.Column) -> [SIMD4<Float>] {
        let (u, v) = EffectTestEmitters.basis(c.axis)
        let n = EffectTestEmitters.segments, top = c.base + c.axis * c.height
        func around(_ i: Int) -> Vec3 {
            let a = 2 * Double.pi * Double(i) / Double(n)
            return u * cos(a) + v * sin(a)
        }
        var out: [SIMD4<Float>] = []
        func vertex(_ p: Vec3, _ normal: Vec3) { out += [SIMD4(p, 1), SIMD4(normal, 0)] }
        for i in 0..<n {
            let d0 = around(i), d1 = around(i + 1)
            let b0 = c.base + d0 * c.radius, b1 = c.base + d1 * c.radius
            let t0 = top + d0 * c.radius, t1 = top + d1 * c.radius
            for (p, d) in [(b0, d0), (b1, d1), (t1, d1), (b0, d0), (t1, d1), (t0, d0)] { vertex(p, d) }
            for p in [top, t0, t1] { vertex(p, c.axis) }
        }
        return out
    }
}

/// The test sparks: additive streaks at full resolution, after the
/// composite (P3), against the scene's depth.
@MainActor
public final class EffectTestSparksPass: RenderPass {
    public let name = "Effect test sparks"
    public let stage = PassStage.transparent
    public let order = 36

    private var pipeline: MTLRenderPipelineState?

    public init() {}

    public func isActive(in f: FrameContext) -> Bool {
        f.settings.transparency.testEmitters.contains { $0.kind == .sparks && $0.count > 0 }
    }

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.effectTest), vertex: "effect_test_spark_vertex",
                                             fragment: "effect_test_spark_fragment", blend: .additive, setup: s)
    }

    /// EffectTestShaders' EffectTestSpark.
    struct Spark {
        var start: SIMD4<Float>
        var end: SIMD4<Float>
        var color: SIMD4<Float>
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        let frame = EffectTargetFrame(scene: f.scene)
        let sparks = f.settings.transparency.testEmitters.filter { $0.kind == .sparks }
            .flatMap { EffectTestScene.sparks($0, in: frame) }
            .map { Spark(start: SIMD4($0.start, Float($0.width)), end: SIMD4($0.end, 0), color: SIMD4($0.color, 0)) }
        guard let b = f.arena.push(sparks) else { return }
        var u = EffectTestUniforms(f)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        enc.setCullMode(.none)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<EffectTestUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sparks.count)
    }
}

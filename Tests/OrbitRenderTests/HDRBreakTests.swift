import Foundation
import Metal
import XCTest
import simd
@testable import OrbitCore
import OrbitScene
@testable import OrbitRender

/// Light at a depth, in any render stage: opaque (depth written) or
/// additive (depth tested, not written), each shape of one luminance
/// (cd/m², times the frame's pre-exposure).
@MainActor
final class DepthLightTestPass: RenderPass {
    struct Shape {
        var ndc: [SIMD2<Float>]
        /// Reversed-Z: 1 near, 0 far.
        var depth: Float
        var value: Float
    }

    let name: String
    let stage: PassStage
    let order: Int
    let additive: Bool
    var shapes: [Shape] = []
    private var pipeline: MTLRenderPipelineState?

    init(_ name: String, _ stage: PassStage, order: Int, additive: Bool) {
        self.name = name
        self.stage = stage
        self.order = order
        self.additive = additive
    }

    static let module = ShaderModule(name: "TestDepthLight", source: #"""
    struct TestDepthLightVertex { float4 position; float4 value; };
    struct TestDepthLightOut { float4 position [[position]]; float4 value [[flat]]; };
    vertex TestDepthLightOut test_depth_light_vertex(uint vid [[vertex_id]],
                                                     const device TestDepthLightVertex *v [[buffer(0)]]) {
        TestDepthLightOut o;
        o.position = float4(v[vid].position.xyz, 1.0);
        o.value = v[vid].value;
        return o;
    }
    fragment float4 test_depth_light_fragment(TestDepthLightOut in [[stage_in]],
                                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
        return float4(float3(in.value.x * frame.exposure.x), 1.0);
    }
    """#)

    func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(Self.module), vertex: "test_depth_light_vertex",
                                             fragment: "test_depth_light_fragment",
                                             blend: additive ? .additive : .opaque, setup: s)
    }

    func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        var vertices: [SIMD4<Float>] = []
        for s in shapes {
            for p in s.ndc { vertices += [SIMD4(p.x, p.y, s.depth, 1), SIMD4(s.value, 0, 0, 0)] }
        }
        guard !vertices.isEmpty, let b = f.arena.push(vertices) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(additive ? f.states.depthReadOnly : f.states.depthWrite)
        enc.setCullMode(.none)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 2)
    }

    static func ndc(_ x: Double, _ y: Double, w: Int, h: Int) -> SIMD2<Float> {
        SIMD2(Float(x / Double(w) * 2 - 1), Float(1 - y / Double(h) * 2))
    }

    /// A triangle through three points in pixels.
    static func triangle(_ p: [(Double, Double)], w: Int, h: Int, depth: Float, value: Float) -> Shape {
        Shape(ndc: p.map { ndc($0.0, $0.1, w: w, h: h) }, depth: depth, value: value)
    }

    /// The pixels x0..<x1, y0..<y1, whole.
    static func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, w: Int, h: Int, depth: Float, value: Float) -> Shape {
        let a = ndc(Double(x0), Double(y0), w: w, h: h), b = ndc(Double(x1), Double(y0), w: w, h: h)
        let c = ndc(Double(x1), Double(y1), w: w, h: h), d = ndc(Double(x0), Double(y1), w: w, h: h)
        return Shape(ndc: [a, b, c, a, c, d], depth: depth, value: value)
    }
}

/// A render-stage pass on the command buffer: it breaks the scene.
@MainActor
final class BreakTestPass: RenderPass {
    let name: String
    let stage: PassStage
    let order: Int
    var encodesOnCommandBuffer: Bool { true }
    var encoded = 0
    var active = true
    func isActive(in f: FrameContext) -> Bool { active }
    init(_ name: String = "Break", _ stage: PassStage = .transparent, order: Int = -10) {
        self.name = name
        self.stage = stage
        self.order = order
    }
    func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .commandBuffer = e else { return XCTFail("a pass on the command buffer") }
        encoded += 1
    }
}

/// Copies the resolved scene depth in P4.
@MainActor
final class SceneDepthCapture: RenderPass {
    let name = "Scene depth capture"
    let stage = PassStage.post
    let order = 2_000
    var reads: Set<ResourceID> { [.sceneDepth] }
    var buffer: MTLBuffer?
    func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard let t = f.textures[.sceneDepth], let blit = f.makeBlitEncoder(),
              let b = f.device.makeBuffer(length: 4 * t.width * t.height, options: .storageModeShared) else { return }
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: b, destinationOffset: 0,
                  destinationBytesPerRow: 4 * t.width, destinationBytesPerImage: 4 * t.width * t.height)
        blit.endEncoding()
        buffer = b
    }
    var depths: [Float] {
        guard let b = buffer else { return [] }
        return Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: Float.self, capacity: b.length / 4),
                                         count: b.length / 4))
    }
}

/// The HDR plan where a pass breaks the scene (R6's effect slots): a break
/// in P2 or P3 resolves the scene with its weighting and re-expands it in
/// tile memory, rather than store and reload 4× samples.
extension HDRLookTests {
    @MainActor
    struct BreakScene {
        static let w = 96, h = 64
        static let sky: Float = 0.5, vehicle: Float = 8, glow: Float = 3
        /// The vehicle's silhouette, slanted so its edges are antialiased.
        static let corners = [(10.0, 8.0), (80.0, 20.0), (30.0, 58.0)]
        /// A glow in front of the vehicle across its top edge, and one
        /// behind it across its left edge.
        static let front = (40, 4, 56, 26), behind = (12, 30, 32, 46)

        let opaque = DepthLightTestPass("Test opaque", .opaque, order: 5, additive: false)
        let glows = DepthLightTestPass("Test glows", .transparent, order: 10, additive: true)
        let breaker = BreakTestPass()
        let depth = SceneDepthCapture()

        init(glows on: Bool = true) {
            let w = Self.w, h = Self.h
            opaque.shapes = [DepthLightTestPass.rect(0, 0, w, h, w: w, h: h, depth: 0.05, value: Self.sky),
                             DepthLightTestPass.triangle(Self.corners, w: w, h: h, depth: 0.5, value: Self.vehicle)]
            if on {
                let f = Self.front, b = Self.behind
                glows.shapes = [DepthLightTestPass.rect(f.0, f.1, f.2, f.3, w: w, h: h, depth: 0.9, value: Self.glow),
                                DepthLightTestPass.rect(b.0, b.1, b.2, b.3, w: w, h: h, depth: 0.3, value: Self.glow)]
            }
        }

        static func inside(_ r: (Int, Int, Int, Int), _ x: Int, _ y: Int) -> Bool {
            x >= r.0 && x < r.2 && y >= r.1 && y < r.3
        }

        func passes(breaking: Bool) -> [RenderPass] { breaking ? [opaque, breaker, glows, depth] : [opaque, glows, depth] }
    }

    /// Renders and returns the light (cd/m², RGBA), the output and the depth.
    func renderBreak(_ s: BreakScene, resolves: Bool, timing: Bool = false, breaking: Bool = true,
                     extra: [RenderPass] = [])
        throws -> (light: [Float], output: [UInt8], depth: [Float], plan: HDRTargetPlan) {
        let (r, post) = try renderer(s.passes(breaking: breaking) + extra)
        if timing, !r.profiler.isSupported { throw XCTSkip("no timestamp counters on this GPU") }
        let plan = try XCTUnwrap(r.graph.plan as? HDRTargetPlan)
        plan.resolvesAtBreaks = resolves
        r.settings = settings(ev100: 0)
        r.profiling = timing
        r.profileInterval = 1
        let (light, output, _) = try render(r, post, scene(width: BreakScene.w, height: BreakScene.h))
        return (light, output, s.depth.depths, plan)
    }

    static func close(_ a: Float, _ b: Float, _ tolerance: Float = 2e-3) -> Bool {
        abs(a - b) <= tolerance * max(abs(a), abs(b)) + 1e-5
    }

    /// The scene's light is the same where nothing draws over an opaque
    /// edge after the break: the sky, the vehicle, its edges, the glows'
    /// insides, each to half float's rounding; the units hold (the sky, the
    /// vehicle and a glow over the sky read their luminance). Over an edge,
    /// a glow in front adds its light to the resolved edge; one behind is
    /// hidden in the whole pixel, the edge's nearest depth being the
    /// vehicle's (the cost of not keeping the samples). The resolved depth
    /// is the same to the bit.
    func testBreakResolvesAndReExpandsTheScene() throws {
        let w = BreakScene.w, h = BreakScene.h
        let bare = BreakScene(glows: false)
        let edgesOnly = try renderBreak(bare, resolves: false).light
        let kept = try renderBreak(BreakScene(), resolves: false)
        let s = BreakScene()
        let new = try renderBreak(s, resolves: true)
        XCTAssertEqual(s.breaker.encoded, 1)
        XCTAssertEqual(new.plan.breakStores, [.multisampleResolve], "no sample stored")
        XCTAssertEqual(new.plan.expansions.drawn, 1)
        XCTAssertEqual(kept.plan.breakStores, [.storeAndMultisampleResolve])

        var edges = 0, edgesInFront = 0, edgesBehind = 0, interior = 0
        var hidden: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let a = new.light[4 * i], k = kept.light[4 * i], e = edgesOnly[4 * i]
                let isEdge = !Self.close(e, BreakScene.sky, 1e-3) && !Self.close(e, BreakScene.vehicle, 1e-3)
                let front = BreakScene.inside(BreakScene.front, x, y)
                let behind = BreakScene.inside(BreakScene.behind, x, y)
                switch (isEdge, front, behind) {
                case (true, true, _):
                    edgesInFront += 1
                    XCTAssertTrue(Self.close(a, e + BreakScene.glow), "(\(x), \(y)): \(a) is the edge \(e) and the glow")
                case (true, _, true):
                    edgesBehind += 1
                    XCTAssertTrue(Self.close(a, e), "(\(x), \(y)): \(a), the edge \(e) with the glow behind it hidden")
                    XCTAssertLessThanOrEqual(a, k * 1.002, "(\(x), \(y))")
                    hidden = max(hidden, (k - a) / BreakScene.glow)
                default:
                    if isEdge { edges += 1 } else { interior += 1 }
                    XCTAssertTrue(Self.close(a, k), "(\(x), \(y)): \(a) against \(k) with the samples kept")
                }
            }
        }
        XCTAssertGreaterThan(edges, 100)
        XCTAssertGreaterThan(edgesInFront, 10)
        XCTAssertGreaterThan(edgesBehind, 10)
        // About a glow's light at most: the weighting of the kept samples
        // is not linear in it.
        XCTAssertGreaterThan(hidden, 0.1, "the glow behind an edge loses part of a pixel's light")
        XCTAssertLessThan(hidden, 1.25)
        // The units: the sky, the vehicle, a glow over the sky, over the vehicle and behind it.
        func light(_ x: Int, _ y: Int) -> Float { new.light[4 * (y * w + x)] }
        XCTAssertEqual(light(90, 60), BreakScene.sky, accuracy: BreakScene.sky * 1e-3)
        XCTAssertEqual(light(40, 30), BreakScene.vehicle, accuracy: BreakScene.vehicle * 1e-3)
        XCTAssertEqual(light(50, 6), BreakScene.sky + BreakScene.glow, accuracy: 4e-3)
        XCTAssertEqual(light(50, 24), BreakScene.vehicle + BreakScene.glow, accuracy: 0.012)
        XCTAssertEqual(light(28, 40), BreakScene.vehicle, accuracy: BreakScene.vehicle * 1e-3)
        XCTAssertEqual(light(13, 40), BreakScene.sky + BreakScene.glow, accuracy: 4e-3)
        XCTAssertEqual(new.depth, kept.depth, "the resolved depth")
        XCTAssertFalse(new.depth.isEmpty)
    }
}

extension HDRLookTests {
    /// A frame that breaks nothing sets its stores up front, as before this
    /// change: nothing is stored, decided at a break or re-expanded, and
    /// the re-expansion's switch changes nothing (it is never read there).
    /// That such a frame matches main's to the bit is the look-dev goldens'.
    func testFramesWithoutABreakAreUntouched() throws {
        let on = try renderBreak(BreakScene(), resolves: true, breaking: false)
        let off = try renderBreak(BreakScene(), resolves: false, breaking: false)
        XCTAssertEqual(on.output, off.output)
        XCTAssertEqual(on.light, off.light)
        XCTAssertEqual(on.depth, off.depth)
        XCTAssertNil(on.plan.stored.color)
        XCTAssertEqual(on.plan.expansions.drawn, 0)
        XCTAssertEqual(on.plan.breakStores, [])
    }

    /// The plan's record of the frame's break stores is the frame's: a frame
    /// that breaks nothing, after one that broke the scene, records none.
    func testBreakStoresAreTheFramesOwn() throws {
        let s = BreakScene()
        let (r, post) = try renderer(s.passes(breaking: true))
        let plan = try XCTUnwrap(r.graph.plan as? HDRTargetPlan)
        r.settings = settings(ev100: 0)
        _ = try render(r, post, scene(width: BreakScene.w, height: BreakScene.h))
        XCTAssertEqual(plan.breakStores, [.multisampleResolve])
        s.breaker.active = false
        _ = try render(r, post, scene(width: BreakScene.w, height: BreakScene.h))
        XCTAssertEqual(plan.breakStores, [])
        s.breaker.active = true
        _ = try render(r, post, scene(width: BreakScene.w, height: BreakScene.h))
        XCTAssertEqual(plan.breakStores, [.multisampleResolve])
    }

    /// Two breaks in P3: the scene is resolved and re-expanded twice, and
    /// the light is that of one break, to half float's rounding.
    func testTwoBreaks() throws {
        let one = try renderBreak(BreakScene(), resolves: true)
        let second = BreakTestPass("Second break", .transparent, order: 20)
        let two = try renderBreak(BreakScene(), resolves: true, extra: [second])
        XCTAssertEqual(second.encoded, 1)
        XCTAssertEqual(two.plan.expansions.drawn, 2)
        for i in 0..<(BreakScene.w * BreakScene.h) {
            XCTAssertTrue(Self.close(two.light[4 * i], one.light[4 * i]), "\(i): \(two.light[4 * i]), \(one.light[4 * i])")
        }
        XCTAssertEqual(two.depth, one.depth)
    }

    /// While timing, the samples are kept, so the image is that of a frame
    /// that keeps them, to the bit; the resume after the break, which the
    /// profile charges to the pass that broke the scene, re-expands into
    /// scratch targets, the plain frame's work.
    func testTimingKeepsTheSamplesAndTimesTheReExpansion() throws {
        let kept = try renderBreak(BreakScene(), resolves: false)
        let timed = try renderBreak(BreakScene(), resolves: true, timing: true)
        XCTAssertEqual(timed.output, kept.output)
        XCTAssertEqual(timed.light, kept.light)
        XCTAssertEqual(timed.depth, kept.depth)
        XCTAssertEqual(timed.plan.expansions.drawn, 1)
        XCTAssertEqual(timed.plan.expansions.timed, 1)
        let off = try renderBreak(BreakScene(), resolves: false, timing: true)
        XCTAssertEqual(off.output, kept.output)
        XCTAssertEqual(off.plan.expansions.drawn, 0)
    }

    /// R6's test emitters (a column, the slab, sprites, sparks) on the
    /// default passes: the re-expanded scene's light is the kept samples'
    /// to half float's rounding except next to an opaque silhouette.
    func testEffectSlotsOnTheReExpandedScene() throws {
        let sparks = EffectTestEmitter(.sparks, position: [-30, 20, 20], size: 30, axis: [0, 0, 1], count: 30)
        var shot = EffectSlotsRenderTests.shot([EffectSlotsRenderTests.column, EffectSlotsRenderTests.slab,
                                                EffectSlotsRenderTests.sprites, sparks], width: 320, height: 200)
        shot.settings.post.exposure.mode = .manual
        shot.settings.post.exposure.ev100 = 15
        shot.settings.post.dither = false
        let snapper = try SnapshotRenderer(device: try device())
        let prepared = try shot.prepare(system: snapper.system)
        let scene = shot.scene(prepared)
        func frame(resolves: Bool) throws -> (light: [Float], output: [UInt8], depth: [Float], drawn: Int) {
            let depth = SceneDepthCapture()
            let r = try SceneRenderer(device: snapper.device, outputFormat: .bgra8Unorm_srgb,
                                      passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [depth],
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            XCTAssertEqual(r.failures, [:])
            r.setStars(snapper.stars)
            r.settings = shot.settings
            let plan = try XCTUnwrap(r.graph.plan as? HDRTargetPlan)
            plan.resolvesAtBreaks = resolves
            let post = try XCTUnwrap(r.graph.passes.compactMap { $0 as? PostPass }.first)
            let (light, output, _) = try render(r, post, scene)
            return (light, output, depth.depths, plan.expansions.drawn)
        }
        let kept = try frame(resolves: false), new = try frame(resolves: true)
        XCTAssertEqual(kept.drawn, 0)
        XCTAssertEqual(new.drawn, 1)
        XCTAssertEqual(new.depth, kept.depth)
        let w = shot.width, h = shot.height
        // An opaque silhouette: depths a factor of 2 apart within a pixel.
        func silhouette(_ x: Int, _ y: Int) -> Bool {
            let d = kept.depth[y * w + x]
            for j in max(0, y - 1)...min(h - 1, y + 1) {
                for i in max(0, x - 1)...min(w - 1, x + 1) {
                    let e = kept.depth[j * w + i]
                    if max(d, e) > 2 * min(d, e) { return true }
                }
            }
            return false
        }
        var off = 0, offAtEdges = 0, lit = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let a = Self.luminance(new.light, i), b = Self.luminance(kept.light, i)
                if b > 1 { lit += 1 }
                guard abs(a - b) > 2e-3 * max(a, b) + 1e-3 else { continue }
                if silhouette(x, y) { offAtEdges += 1 } else { off += 1 }
            }
        }
        let steps = zip(new.output, kept.output).map { abs(Int($0) - Int($1)) }
        print("R1 on R6's emitters: \(offAtEdges) pixels apart at silhouettes, \(off) elsewhere, of \(w * h) "
              + "(\(lit) lit); output: \(steps.filter { $0 > 0 }.count) bytes apart, at most \(steps.max() ?? 0)")
        XCTAssertGreaterThan(lit, w * h / 10, "the emitters show")
        XCTAssertEqual(off, 0, "light apart away from silhouettes")
        XCTAssertLessThan(offAtEdges, w * h / 200)
        XCTAssertLessThanOrEqual(steps.max() ?? 3, 2, "steps of 8-bit sRGB")
    }
}

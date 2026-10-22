import Foundation
import Metal
import XCTest
import simd
@testable import OrbitCore
import OrbitScene
@testable import OrbitRender

/// Light drawn by a test: triangles in NDC, each of one luminance (cd/m²,
/// times the frame's pre-exposure), or of a raw value (NaN, infinity).
@MainActor
final class LightTestPass: RenderPass {
    struct Shape {
        var ndc: [SIMD2<Float>]
        /// cd/m², or a raw value written as it is when `raw`.
        var value: Float
        var raw = false
    }

    let name = "Test light"
    let stage = PassStage.opaque
    let order = 5
    var shapes: [Shape] = []
    private var pipeline: MTLRenderPipelineState?

    static let module = ShaderModule(name: "TestLight", source: #"""
    struct TestLightVertex { float4 position; float4 value; };
    struct TestLightOut { float4 position [[position]]; float4 value [[flat]]; };
    vertex TestLightOut test_light_vertex(uint vid [[vertex_id]], const device TestLightVertex *v [[buffer(0)]]) {
        TestLightOut o;
        o.position = float4(v[vid].position.xy, 0.5, 1.0);
        o.value = v[vid].value;
        return o;
    }
    fragment float4 test_light_fragment(TestLightOut in [[stage_in]],
                                        constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
        return in.value.y > 0.5 ? float4(in.value.x) : float4(float3(in.value.x * frame.exposure.x), 1.0);
    }
    """#)

    func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(Self.module), vertex: "test_light_vertex",
                                             fragment: "test_light_fragment", blend: .opaque, setup: s)
    }

    func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        var vertices: [SIMD4<Float>] = []
        for s in shapes {
            for p in s.ndc { vertices += [SIMD4(p.x, p.y, 0, 1), SIMD4(s.value, s.raw ? 1 : 0, 0, 0)] }
        }
        guard !vertices.isEmpty, let b = f.arena.push(vertices) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthWrite)
        enc.setCullMode(.none)
        enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 2)
    }

    /// The whole screen.
    static func screen(_ luminance: Float) -> Shape {
        Shape(ndc: [SIMD2(-1, -1), SIMD2(3, -1), SIMD2(-1, 3)], value: luminance)
    }

    /// A square of `size` pixels with its corner at pixel (x, y) of a w × h target.
    static func pixels(x: Int, y: Int, size: Int = 1, w: Int, h: Int, value: Float, raw: Bool = true) -> Shape {
        func ndc(_ px: Int, _ py: Int) -> SIMD2<Float> {
            SIMD2(Float(px) / Float(w) * 2 - 1, 1 - Float(py) / Float(h) * 2)
        }
        let a = ndc(x, y), b = ndc(x + size, y), c = ndc(x + size, y + size), d = ndc(x, y + size)
        return Shape(ndc: [a, b, c, a, c, d], value: value, raw: raw)
    }
}

/// Track R1's look metrics on the GPU: the tone curve, the stars' and the
/// Sun's light, the bloom's energy, NaN containment, the weighted resolve
/// and the auto exposure (docs/m16/plan.md, Verification, Mac).
@MainActor
final class HDRLookTests: XCTestCase {
    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// A renderer with R1's passes only, plus `extra`.
    func renderer(_ extra: [RenderPass] = [], stars: Bool = false) throws -> (SceneRenderer, PostPass) {
        let post = PostPass()
        var passes: [RenderPass] = [post.exposurePass, post.resolvePass, post] + extra
        if stars { passes.append(StarPass()) }
        let r = try SceneRenderer(device: try device(), outputFormat: .bgra8Unorm_srgb, passes: passes,
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        XCTAssertEqual(r.failures, [:])
        return (r, post)
    }

    func settings(ev100: Double?, bloom: Double = 0) -> RenderSettings {
        var s = RenderSettings()
        if let ev100 {
            s.post.exposure.mode = .manual
            s.post.exposure.ev100 = ev100
        }
        s.post.bloom = bloom
        s.post.sunGlare = false
        s.post.dither = false
        return s
    }

    /// A scene looking down -z (world = view axes) with a vertical field of
    /// `fovY`, the Sun at 1 AU in `sun`'s direction.
    func scene(width: Int, height: Int, fovY: Double = 1, sun: Vec3 = .unitX, realDt: Double = 0) -> RenderScene {
        let au = Photometry.astronomicalUnit
        return RenderScene(
            clock: RenderScene.Clock(simTime: Epoch(tdbSecondsPastJ2000: 0), realDt: realDt, frameIndex: 2,
                                     temporalReset: false),
            camera: RenderScene.Camera(position: .zero, worldToView: .identity, fovY: fovY,
                                       viewport: RenderScene.Viewport(width: Double(width), height: Double(height)),
                                       target: .body(399)),
            sun: RenderScene.Sun(position: sun * au, direction: sun, distance: au,
                                 illuminance: Photometry.solarIlluminance(distance: au),
                                 angularRadius: Photometry.solarAngularRadius(distance: au)))
    }

    /// Renders and returns the light (cd/m², RGBA) and the output (BGRA).
    func render(_ r: SceneRenderer, _ post: PostPass, _ scene: RenderScene,
                bloom: Bool = false) throws -> (light: [Float], output: [UInt8], bloom: [Float]?) {
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: w, height: h))
        post.capturesLight = true
        post.capturesBloom = bloom
        let cb = try XCTUnwrap(r.renderAndWait(scene, into: target))
        XCTAssertNil(cb.error)
        let light = try XCTUnwrap(post.capturedLight())
        let k = Float(1 / post.control.preExposure)
        return (light.pixels.map { $0 * k }, target.bytes(), post.capturedBloom()?.pixels.map { $0 * k })
    }

    static func luminance(_ p: [Float], _ i: Int) -> Double {
        0.2126 * Double(p[4 * i]) + 0.7152 * Double(p[4 * i + 1]) + 0.0722 * Double(p[4 * i + 2])
    }

    /// The solid angle of pixel (x, y) of a pinhole camera, sr.
    static func pixelSolidAngle(x: Int, y: Int, w: Int, h: Int, fovY: Double) -> Double {
        let t = tan(fovY / 2), aspect = Double(w) / Double(h)
        let nx = (Double(x) + 0.5) / Double(w) * 2 - 1, ny = 1 - (Double(y) + 0.5) / Double(h) * 2
        let r = (nx * t * aspect, ny * t)
        let c = 1 / (1 + r.0 * r.0 + r.1 * r.1).squareRoot()
        let omega0 = (2 * t / Double(h)) * (2 * t / Double(h))
        return omega0 * c * c * c
    }

    // MARK: Tone curve

    /// The post shader's curves against ToneCurves: AgX through the LUT
    /// within a step of 8-bit sRGB of the Swift LUT (half-float texels,
    /// the GPU's filtering), and within 2 steps of AgX itself for 99 %;
    /// Neutral, evaluated in the shader, to float precision.
    func testToneCurveOnTheGPU() throws {
        let (r, post) = try renderer()
        var g = SystemRandomNumberGenerator()
        let colors: [SIMD4<Float>] = (0..<512).map { _ in
            let l = pow(2, Double.random(in: -10...4, using: &g))
            return SIMD4(Float(l * Double.random(in: 0...1, using: &g)), Float(l * Double.random(in: 0...1, using: &g)),
                         Float(l * Double.random(in: 0...1, using: &g)), 1)
        }
        func srgb(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            return 255 * (c <= 0.003_130_8 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
        let agx = try XCTUnwrap(post.toneProbe(colors, curve: .agx, queue: r.queue))
        let lut = ToneLUT(.agx)
        var errors: [Double] = []
        for (c, o) in zip(colors, agx) {
            let rgb = Photometry.RGB(Double(c.x), Double(c.y), Double(c.z))
            let s = lut.sample(rgb), exact = ToneCurves.agx(rgb)
            for (a, b) in [(Double(o.x), s.r), (Double(o.y), s.g), (Double(o.z), s.b)] {
                XCTAssertEqual(srgb(a), srgb(b), accuracy: 1, "AgX LUT on the GPU at \(c)")
            }
            errors.append(max(abs(srgb(Double(o.x)) - srgb(exact.r)), abs(srgb(Double(o.y)) - srgb(exact.g)),
                              abs(srgb(Double(o.z)) - srgb(exact.b))))
        }
        errors.sort()
        XCTAssertLessThan(errors[errors.count * 99 / 100], 2)
        let neutral = try XCTUnwrap(post.toneProbe(colors, curve: .neutral, queue: r.queue))
        for (c, o) in zip(colors, neutral) {
            let e = ToneCurves.neutral(Photometry.RGB(Double(c.x), Double(c.y), Double(c.z)))
            XCTAssertEqual(Double(o.x), min(max(e.r, 0), 1), accuracy: 2e-5)
            XCTAssertEqual(Double(o.y), min(max(e.g, 0), 1), accuracy: 2e-5)
            XCTAssertEqual(Double(o.z), min(max(e.b, 0), 1), accuracy: 2e-5)
        }
    }

    // MARK: Stars and the Sun

    /// A magnitude-1 and a magnitude-6 star: their light in the image, summed
    /// over the pixels' solid angles, is their illuminance (within 3 %), and
    /// 100 × apart (±3 %), wherever they fall in a pixel.
    func testStarEnergy() throws {
        let (r, post) = try renderer(stars: true)
        let w = 512, h = 256, fovY = 1.0
        let directions = [Vec3(-0.2, 0.05, -1).normalized, Vec3(0.23, -0.07, -1).normalized]
        let stars = [Star(direction: directions[0], magnitude: 1, colorIndex: 0.6),
                     Star(direction: directions[1], magnitude: 6, colorIndex: 0.6)]
        r.setStars(stars)
        r.settings = settings(ev100: -4)
        let (light, _, _) = try render(r, post, scene(width: w, height: h, fovY: fovY))
        let t = tan(fovY / 2), aspect = Double(w) / Double(h)
        var energies: [Double] = []
        for d in directions {
            let cx = (d.x / -d.z / (t * aspect) + 1) / 2 * Double(w), cy = (1 - d.y / -d.z / t) / 2 * Double(h)
            var e = 0.0
            for y in (Int(cy) - 5)...(Int(cy) + 5) {
                for x in (Int(cx) - 5)...(Int(cx) + 5) {
                    e += Self.luminance(light, y * w + x) * Self.pixelSolidAngle(x: x, y: y, w: w, h: h, fovY: fovY)
                }
            }
            energies.append(e)
        }
        XCTAssertEqual(energies[0] / Photometry.illuminance(visualMagnitude: 1), 1, accuracy: 0.03)
        XCTAssertEqual(energies[0] / energies[1], 100, accuracy: 3)
    }

    /// The Sun's disc carries E⊙ (within 2 %), limb-darkened: the centre is
    /// brighter than the mean of the disc.
    func testSunDiscEnergy() throws {
        let (r, post) = try renderer(stars: true)
        let w = 256, h = 256, fovY = 0.05
        r.settings = settings(ev100: 16)
        let (light, _, _) = try render(r, post, scene(width: w, height: h, fovY: fovY, sun: Vec3(0, 0, -1)))
        var e = 0.0
        for y in 0..<h {
            for x in 0..<w { e += Self.luminance(light, y * w + x) * Self.pixelSolidAngle(x: x, y: y, w: w, h: h, fovY: fovY) }
        }
        XCTAssertEqual(e / Photometry.solarIlluminanceAt1AU, 1, accuracy: 0.02)
        let centre = Self.luminance(light, (h / 2) * w + w / 2)
        XCTAssertEqual(centre / Photometry.solarLuminance, Photometry.solarCentreOverMean, accuracy: 0.03)
    }

    // MARK: Bloom, NaN, resolve

    /// The bloom pyramid conserves the image's light within 1 %: its top,
    /// as the tone map reads it, carries what the image does, here the
    /// Sun's disc.
    func testBloomConservesEnergy() throws {
        let (r, post) = try renderer(stars: true)
        let w = 512, h = 512
        r.settings = settings(ev100: 16, bloom: 0.03)
        let (light, _, bloom) = try render(r, post, scene(width: w, height: h, fovY: 0.1, sun: Vec3(0, 0, -1)),
                                           bloom: true)
        let b = try XCTUnwrap(bloom)
        let image = (0..<(w * h)).reduce(0.0) { $0 + Self.luminance(light, $1) }
        let pyramid = (0..<(w * h)).reduce(0.0) { $0 + Self.luminance(b, $1) }
        XCTAssertGreaterThan(image, 0)
        XCTAssertEqual(pyramid / image, 1, accuracy: 0.01)
    }

    /// A NaN and an infinity drawn into one pixel each stop at the resolve:
    /// the light stays finite, nothing beyond those pixels changes in it,
    /// and the output, with the bloom on, by a step at most (the bloom sees
    /// the two pixels gone dark).
    func testNaNIsContained() throws {
        let w = 64, h = 64
        let pass = LightTestPass()
        let (r, post) = try renderer([pass])
        r.settings = settings(ev100: 10, bloom: 0.03)
        pass.shapes = [LightTestPass.screen(500)]
        let clean = try render(r, post, scene(width: w, height: h))
        pass.shapes += [LightTestPass.pixels(x: 20, y: 30, w: w, h: h, value: .nan),
                        LightTestPass.pixels(x: 44, y: 10, w: w, h: h, value: .infinity)]
        let dirty = try render(r, post, scene(width: w, height: h))
        XCTAssertFalse(dirty.light.contains { !$0.isFinite }, "finite light")
        for y in 0..<h {
            for x in 0..<w where max(abs(x - 20), abs(y - 30)) > 1 && max(abs(x - 44), abs(y - 10)) > 1 {
                let i = y * w + x
                XCTAssertEqual(dirty.light[4 * i], clean.light[4 * i], accuracy: 1e-3 * clean.light[4 * i], "(\(x), \(y))")
                for k in 0..<3 {
                    XCTAssertLessThanOrEqual(abs(Int(dirty.output[4 * i + k]) - Int(clean.output[4 * i + k])), 1, "(\(x), \(y))")
                }
            }
        }
    }

    /// A highlight of 1e4 times saturation on a slanted edge over black:
    /// the weighted resolve keeps every pixel between the two sides, falling
    /// monotonically across the edge, and a pixel the edge crosses no
    /// brighter than 3× saturation (a box resolve would give thousands).
    func testResolveHasNoRinging() throws {
        let w = 64, h = 64
        let pass = LightTestPass()
        let (r, post) = try renderer([pass])
        r.settings = settings(ev100: 0)
        let p = Exposure.exposure(ev100: 0)
        let value = Float(1e4 / p)       // cd/m²: 1e4 after pre-exposure
        pass.shapes = [LightTestPass.Shape(ndc: [SIMD2(-1, -1), SIMD2(0.37, -1), SIMD2(-0.21, 1),
                                                 SIMD2(-1, -1), SIMD2(-0.21, 1), SIMD2(-1, 1)], value: value)]
        let (light, output, _) = try render(r, post, scene(width: w, height: h))
        for y in 0..<h {
            var previous = Double.infinity, previousOut = 256
            for x in 0..<w {
                let l = Self.luminance(light, y * w + x) * p
                XCTAssertGreaterThanOrEqual(l, 0)
                XCTAssertLessThanOrEqual(l, 1e4 * 1.001)
                XCTAssertLessThanOrEqual(l, previous * 1.001 + 1e-6, "monotonic across the edge, row \(y)")
                if l > 1e-3, l < 1e4 * 0.999 { XCTAssertLessThan(l, 3.01, "an edge pixel, row \(y)") }
                let o = Int(output[4 * (y * w + x) + 1])
                XCTAssertLessThanOrEqual(o, previousOut, "the output too, row \(y)")
                previous = l
                previousOut = o
            }
        }
    }

    // MARK: Exposure

    /// The auto exposure on a uniform image settles at its EV100 less the
    /// compensation, within 0.1 EV, in under 5 s of 60 Hz frames, brighter
    /// or darker.
    func testAutoExposureConverges() throws {
        let w = 64, h = 64
        let pass = LightTestPass()
        let (r, post) = try renderer([pass])
        r.settings = settings(ev100: nil)
        let comp = r.settings.post.exposure.compensation
        func expected(_ l: Float) -> Double { Exposure.ev100(averageLuminance: Double(l)) - comp }
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: w, height: h))
        post.control.reset()
        pass.shapes = [LightTestPass.screen(10)]
        for _ in 0..<4 { r.renderAndWait(scene(width: w, height: h, realDt: 1.0 / 60), into: target) }
        XCTAssertEqual(post.control.ev100, expected(10), accuracy: 0.1, "the first histograms set it at once")
        for l: Float in [2_000, 200] {
            pass.shapes = [LightTestPass.screen(l)]
            var frames = 0
            while abs(post.control.ev100 - expected(l)) > 0.1, frames < 300 {
                r.renderAndWait(scene(width: w, height: h, realDt: 1.0 / 60), into: target)
                frames += 1
            }
            XCTAssertLessThan(frames, 300, "\(l) cd/m² within 5 s: EV \(post.control.ev100) for \(expected(l))")
        }
    }
}

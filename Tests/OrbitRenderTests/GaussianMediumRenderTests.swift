import Foundation
import Metal
import simd
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// LR5's header on the GPU (GaussianMediumCommon, through its check
/// module): every function against OrbitScene's GaussianMedium and
/// SmokeScattering, which are tested against quadrature and C2.
@MainActor
final class GaussianMediumRenderTests: XCTestCase {
    /// The check kernel's case, as `GaussianMediumCheckCase` lays it out.
    struct Case {
        var medium: GaussianMediumGPU
        var origin: SIMD4<Float>
        var direction: SIMD4<Float>
        var column: SIMD4<Float>
        var view: SIMD4<Float>
        var extra: SIMD4<Float>
        var sun: SIMD4<Float>
        var ambient: SIMD4<Float>
        var ambientUp: SIMD4<Float>
        var ambientDown: SIMD4<Float>
    }

    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    func run(_ name: String, buffers: [MTLBuffer], threads: Int, lighting: LightingUniforms? = nil) throws {
        let device = try device()
        let library = try ShaderLibrary(device: device).library(.gaussianMediumCheck)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: name)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        for (i, b) in buffers.enumerated() { enc.setBuffer(b, offset: 0, index: i) }
        if var l = lighting { enc.setBytes(&l, length: MemoryLayout<LightingUniforms>.stride, index: 29) }
        enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
    }

    /// The header's struct and the check's case have the Swift mirrors' sizes.
    func testLayoutsMatchMSL() throws {
        let out = try XCTUnwrap(try device().makeBuffer(length: 8, options: .storageModeShared))
        try run("gaussianMedium_sizes", buffers: [out], threads: 1)
        let v = out.contents().bindMemory(to: UInt32.self, capacity: 2)
        XCTAssertEqual(Int(v[0]), MemoryLayout<GaussianMediumGPU>.stride)
        XCTAssertEqual(Int(v[0]), 80, "five float4s")
        XCTAssertEqual(Int(v[1]), MemoryLayout<Case>.stride)
    }

    /// Every function of the header, on the GPU, within Float's reach of
    /// the Swift mirror's Double.
    func testHeaderMatchesTheSwiftMirror() throws {
        let u = Vec3(1, 2, -0.5).normalized, v = u.cross(Vec3(0.3, -0.2, 1)).normalized
        struct Input {
            var medium: GaussianMedium
            var origin: Vec3, direction: Vec3, t0: Double, t1: Double
            var column: (t: Double, tau: Double, w: Double, g: Double)
            var light: SmokeScattering.Light
            var erf: Double, invert: Double
        }
        var cases: [Input] = []
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for i in 0..<96 {
            let sigma = Vec3(5 + 40 * next(), 3 + 20 * next(), 2 + 10 * next())
            let m = GaussianMedium(centre: Vec3(60 * next() - 30, 60 * next() - 30, 60 * next() - 30), axisU: u, axisV: v,
                                   sigma: sigma, peakExtinction: 0.001 + 0.2 * next(),
                                   albedo: Spectrum3(next(), next(), next()), asymmetry: 0.9 * next())
            // From near the primitive, as a pass sets its origin.
            let d = Vec3(next() - 0.5, next() - 0.5, next() - 0.5).normalized
            let o = m.centre - d * (3.5 * sigma.x) + Vec3(next() - 0.5, next() - 0.5, next() - 0.5) * (2 * sigma.z)
            let r = m.ray(origin: o, direction: d)
            let t0 = r.centre - (0.5 + 3 * next()) * r.width, t1 = r.centre + (-0.4 + 3 * next()) * r.width
            let tau = i % 8 == 0 ? 0 : 40 * next() * next()
            // Albedos on both sides of the streams' resonance (ω 0.49 at g
            // 0.35), and at 0 and 1.
            let w = i % 7 == 0 ? 1 : (i % 11 == 0 ? 0 : (i % 5 == 0 ? 1 - 1e-5 * next() : (i % 3 == 0 ? 0.48 + 0.02 * next() : next())))
            let sunChord = 20 * next(), ambientChord = 10 * next()
            let light = SmokeScattering.Light(sun: Spectrum3(1e5, 1.05e5, 1.1e5), ambient: Spectrum3(2e3, 3e3, 5e3),
                                              ambientUp: Spectrum3(3e3, 4e3, 6e3), ambientDown: Spectrum3(5e2, 6e2, 7e2),
                                              cosView: 2 * next() - 1, cosAxis: 2 * next() - 1, sunDepth: sunChord * next(),
                                              sunChord: sunChord, ambientDepth: ambientChord * next(), ambientChord: ambientChord)
            cases.append(Input(medium: m, origin: o, direction: d, t0: t0, t1: max(t1, t0),
                               column: (tau * next(), tau, w, i % 3 == 0 ? 0.35 : 0.9 * next()), light: light,
                               erf: 6 * next() - 3, invert: r.total * next()))
        }
        func f4(_ x: Spectrum3) -> SIMD4<Float> { SIMD4<Float>(Float(x.r), Float(x.g), Float(x.b), 0) }
        let gpu = cases.map { c in
            Case(medium: GaussianMediumGPU(c.medium, camera: .zero),
                 origin: SIMD4<Float>(c.origin, Float(c.t0)), direction: SIMD4<Float>(c.direction, Float(c.t1)),
                 column: SIMD4<Float>(Float(c.column.t), Float(c.column.tau), Float(c.column.w), Float(c.column.g)),
                 view: SIMD4<Float>(Float(c.light.cosView), Float(c.light.sunDepth), Float(c.light.sunChord),
                                    Float(c.light.ambientDepth)),
                 extra: SIMD4<Float>(Float(c.light.ambientChord), Float(c.erf), Float(c.light.cosAxis), Float(c.invert)),
                 sun: f4(c.light.sun), ambient: f4(c.light.ambient), ambientUp: f4(c.light.ambientUp),
                 ambientDown: f4(c.light.ambientDown))
        }
        let device = try device()
        let input = try XCTUnwrap(gpu.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        let out = try XCTUnwrap(device.makeBuffer(length: 7 * 16 * cases.count, options: .storageModeShared))
        try run("gaussianMedium_check", buffers: [input, out], threads: cases.count, lighting: LightingUniforms())
        let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 7 * cases.count)

        func near(_ a: Float, _ b: Double, _ scale: Double, _ what: String, _ i: Int, rel: Double = 2e-4) {
            XCTAssertEqual(Double(a), b, accuracy: rel * max(abs(b), scale), "case \(i): \(what)")
        }
        for (i, c) in cases.enumerated() {
            let m = c.medium, r = m.ray(origin: c.origin, direction: c.direction)
            let depth = r.depth(from: c.t0, to: c.t1)
            let row = (0..<7).map { p[7 * i + $0] }
            near(row[0].x, r.centre, r.width, "nearest approach", i)
            near(row[0].y, r.width, 0, "width", i)
            near(row[0].z, r.peak, m.peakExtinction, "peak", i)
            near(row[0].w, depth, r.total, "depth", i, rel: 1e-3)
            near(row[5].w, r.total, 0, "total", i)
            if let b = m.box(origin: c.origin, direction: c.direction) {
                near(row[1].x, b.lowerBound, r.width, "box entry", i)
                near(row[1].y, b.upperBound, r.width, "box exit", i)
            } else {
                XCTAssertGreaterThanOrEqual(row[1].x, row[1].y, "case \(i): the box is missed")
            }
            near(row[1].z, m.depth(origin: c.origin, direction: c.direction, from: c.t0, to: c.t1), r.total, "boxed depth", i, rel: 1e-3)
            near(row[1].w, r.shadingTime(from: c.t0, to: c.t1), r.width, "shading time", i, rel: 3e-3)
            let s = SmokeScattering.streams(depth: c.column.t, column: c.column.tau, albedo: c.column.w, asymmetry: c.column.g)
            near(row[2].x, s.down, 1e-3, "down", i, rel: 1e-3)
            near(row[2].y, s.up, 1e-3, "up", i, rel: 1e-3)
            near(row[2].z, SmokeScattering.ambientDiffuse(depth: c.column.t, column: c.column.tau, cosAxis: c.light.cosAxis,
                                                          albedo: c.column.w, asymmetry: c.column.g, up: c.light.ambientUp.r,
                                                          down: c.light.ambientDown.r, inScatter: c.light.ambient.r),
                 c.light.ambientUp.r, "ambient diffuse", i, rel: 1e-3)
            near(row[2].w, SmokeScattering.sunDiffuse(sunDepth: c.column.t, sunChord: c.column.tau, cosView: c.light.cosView,
                                                      albedo: c.column.w, asymmetry: c.column.g), 1e-3, "Sun diffuse", i, rel: 1e-3)
            let j = SmokeScattering.source(albedo: m.albedo, asymmetry: m.asymmetry, light: c.light)
            let scale = 1e-3 * (c.light.sun.max + c.light.ambientUp.max)
            near(row[3].x, j.r, scale, "J red", i, rel: 1e-3)
            near(row[3].y, j.g, scale, "J green", i, rel: 1e-3)
            near(row[3].z, j.b, scale, "J blue", i, rel: 1e-3)
            near(row[3].w, GaussianMedium.erf(c.erf), 1e-6, "erf", i)
            let lit = GaussianMedium.light(source: j, depth: depth)
            near(row[4].x, lit.radiance.r, scale, "light", i, rel: 2e-3)
            near(row[4].w, lit.alpha, 1e-3, "alpha", i, rel: 1e-3)
            // No probe drawn (probe.w 0): the stand-in, every way.
            near(row[5].x, c.light.ambient.r, 0, "ambient stand-in", i)
            near(row[5].y, c.light.ambient.r, 0, "ambient up", i)
            near(row[5].z, c.light.ambient.r, 0, "ambient down", i)
            near(row[6].x, r.time(atDepth: c.invert, from: c.t0), r.width, "time at depth", i, rel: 3e-3)
            near(row[6].y, GaussianMedium.erfInverse(min(max(c.erf / 3.5, -0.99), 0.99)), 1e-3, "erf inverse", i, rel: 1e-3)
            XCTAssertEqual(Int(row[6].z), GaussianMedium.segments(depth: depth), "case \(i): segments")
            XCTAssertEqual(row[6].w, 1, "case \(i): the stand-in's axis")
        }
    }

    /// With the probe drawn, the ambient is R3's SH9 scattered by the
    /// smoke's phase (`SH9.inScatter`).
    func testAmbientIsSH9WhenTheProbeIsDrawn() throws {
        let sh = SH9.project(size: 16) { d in
            Spectrum3(repeating: 1_000) + Spectrum3(800, 900, 1_400) * max(d.z, 0) + Spectrum3(300, 250, 200) * max(-d.x, 0)
        }
        var lighting = LightingUniforms()
        let c = sh.irradianceOverPi.map { SIMD4<Float>(Float($0.r), Float($0.g), Float($0.b), 0) }
        lighting.sh9 = (c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8])
        lighting.probe = SIMD4<Float>(0, 0, 0, 1)
        let dirs = [Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(-0.3, 0.5, -0.8).normalized, Vec3(0.2, -0.9, 0.1).normalized]
        let g = 0.55
        let m = GaussianMedium(centre: .zero, axisU: .unitX, axisV: .unitY, sigma: Vec3(1, 1, 1), peakExtinction: 0.01,
                               albedo: .one, asymmetry: g)
        let gpu = dirs.map { d in
            Case(medium: GaussianMediumGPU(m, camera: .zero), origin: SIMD4<Float>(0, 0, 0, 0), direction: SIMD4<Float>(d, 1),
                 column: .zero, view: .zero, extra: .zero, sun: .zero, ambient: SIMD4<Float>(-1, -1, -1, 0),
                 ambientUp: .zero, ambientDown: .zero)
        }
        let device = try device()
        let input = try XCTUnwrap(gpu.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        let out = try XCTUnwrap(device.makeBuffer(length: 7 * 16 * dirs.count, options: .storageModeShared))
        try run("gaussianMedium_check", buffers: [input, out], threads: dirs.count, lighting: lighting)
        let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 7 * dirs.count)
        for (i, d) in dirs.enumerated() {
            let want = SmokeScattering.ambient(SH9(irradianceOverPi: sh.irradianceOverPi), view: d, asymmetry: g, standIn: .zero)
            XCTAssertEqual(Double(p[7 * i + 5].x), want.inScatter.r, accuracy: 1e-4 * want.inScatter.r, "\(d)")
            XCTAssertEqual(Double(p[7 * i + 5].y), want.up.r, accuracy: 1e-4 * want.up.r, "\(d): up")
            XCTAssertEqual(Double(p[7 * i + 5].z), want.down.r, accuracy: 1e-3 * want.up.r, "\(d): down")
            XCTAssertEqual(Double(p[7 * i + 6].w), want.axis.z, accuracy: 1e-4, "\(d): axis")
        }
    }
}

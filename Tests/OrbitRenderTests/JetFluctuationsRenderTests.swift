import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// The plumes' fluctuations on the GPU (`JetFluctuations` in
/// PlumeShaders' `plume_member`): the shader's field against
/// `PlumeMember.sample(at:noise:)` at the same noise, still in the potential
/// core and a ballooned plume's interior; and on screen, the same region's
/// light the same from 1× to 32× zoom, as the eddies come into the footprint.
@MainActor
final class JetFluctuationsRenderTests: XCTestCase {
    static let probe = """
        kernel void plume_fluctuation_probe(const device PlumeMember *members [[buffer(0)]],
                                            constant PlumeFrame &pf [[buffer(1)]],
                                            const device float4 *cases [[buffer(2)]],
                                            device float4 *out [[buffer(3)]],
                                            texture3d<float> noise [[texture(0)]], sampler ns [[sampler(0)]],
                                            uint id [[thread_position_in_grid]]) {
            // Each case: the point (camera-relative) and the noise there, its
            // shutter's depth 1; the member's field as the march samples it.
            float4 c = cases[id];
            PlumeSample s = {0.0, 0.0, float3(0.0), 0.0, float3(0.0)};
            PlumeNoiseAt na = {members, 0, 1, 0.0, true, float2(c.w, 1.0)};
            float sunDepth = 0.0;
            plume_member(s, members[0], 0, c.xyz, pf, na, noise, ns, sunDepth, float3(0.0, 0.0, 1.0));
            out[id] = float4(s.absorption, s.scattering, dot(s.emission, float3(0.2126, 0.7152, 0.0722)), 0.0);
        }
        """

    /// The frame's uniforms as `PlumeSystem` sets them, with no footprint
    /// (every eddy drawn).
    static func frameUniforms() -> PlumeFrameGPU {
        let w = PlumeLook.wien
        var u = PlumeFrameGPU()
        u.wienK = SIMD4(Float(w[0].0), Float(w[1].0), Float(w[2].0), 32)
        u.wienA = SIMD4(Float(w[0].1), Float(w[1].1), Float(w[2].1), 0)
        u.wienC = SIMD4(Float(w[0].2), Float(w[1].2), Float(w[2].2), 0)
        u.flowRates2.y = Float(PlumeLook.Ice.ramp)
        Plumes.setTurbulence(&u)
        u.setLayers(Plumes.layers(time: 0))
        return u
    }

    /// An F-1 at `altitude`, its exit at `exit` firing along `axis`.
    static func f1(altitude: Double, exit: Vec3 = Vec3(3, 30, -8), axis: Vec3 = Vec3(0.2, -0.9, 0.3).normalized)
        -> PlumeMember {
        let air = USStandardAtmosphere1976().state(altitude: altitude)
        let s = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: air)
        var m = PlumeLook.member(ApolloExhaust.f1.spec, state: s, exit: exit, axis: axis,
                                 exitRadius: ApolloExhaust.f1.spec.exitRadius, ambient: air)
        m.noiseSeed = 7
        return m
    }

    /// The probe's field at `points` (each with its noise value), per point
    /// absorption, scattering and the emission's luminance.
    func gpuField(_ m: PlumeMember, _ cases: [(Vec3, Double)]) throws -> [SIMD4<Float>] {
        let device = try XCTUnwrap(RenderDevice.shared)
        let m0 = ShaderModule.plume
        let lib = try ShaderLibrary(device: device).library(ShaderModule(name: "FluctuationProbe", headers: m0.headers,
                                                                         source: plumeShaderSource + Self.probe))
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: "plume_fluctuation_probe")))
        let noise = try VolumeNoise(device: device, library: try ShaderLibrary(device: device).library(.particle))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var member = [Plumes.gpu(m, seed: 7)]
        var pf = Self.frameUniforms()
        let c4 = cases.map { SIMD4(Float($0.0.x), Float($0.0.y), Float($0.0.z), Float($0.1)) }
        let caseBuffer = try XCTUnwrap(device.makeBuffer(bytes: c4, length: 16 * c4.count))
        let out = try XCTUnwrap(device.makeBuffer(length: 16 * c4.count, options: .storageModeShared))
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        noise.encodeIfNeeded(enc)
        enc.setComputePipelineState(pipeline)
        enc.setBytes(&member, length: MemoryLayout<PlumeMemberGPU>.stride, index: 0)
        enc.setBytes(&pf, length: MemoryLayout<PlumeFrameGPU>.stride, index: 1)
        enc.setBuffer(caseBuffer, offset: 0, index: 2)
        enc.setBuffer(out, offset: 0, index: 3)
        enc.setTexture(noise.texture, index: 0)
        enc.setSamplerState(noise.sampler, index: 0)
        enc.dispatchThreads(MTLSize(width: c4.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: c4.count)
        return (0..<c4.count).map { p[$0] }
    }

    /// The shader's fluctuating field is the reference's at the same noise:
    /// an F-1 at the pad through its core, shear layer, flame, far field and
    /// edge, and at 65 km (ballooned, its boundary billowing), five noise
    /// values each; within 0.5 % in extinction and 3 % in emitted light. And
    /// the core and the ballooned interior hold still on the GPU too (the
    /// plan's core r.m.s. under 1e-3).
    func testFluctuationsMatchTheReferenceAndTheCoreIsStill() throws {
        let values = [-2.5, -1.0, 0.0, 0.7, 2.0]
        var worstExtinction = 0.0, worstLight = 0.0
        for altitude in [0.0, 65_000] {
            let m = Self.f1(altitude: altitude)
            let u = PlumeLook.perpendicular(m.axis), v = m.axis.cross(u).normalized
            var state: UInt32 = 21
            var points: [Vec3] = []
            for _ in 0..<64 {
                let x = 1 + (altitude > 0 ? 300 : 180) * pow(ParticleRandom.uniform(&state), 1.5)
                let r = 1.5 * m.radius(atX: x) * ParticleRandom.uniform(&state)
                let a = 2 * Double.pi * ParticleRandom.uniform(&state)
                points.append(m.centre(atX: x) + u * (r * cos(a)) + v * (r * sin(a)))
            }
            let cases = points.flatMap { p in values.map { (p, $0) } }
            let gpu = try gpuField(m, cases)
            for (i, (p, n)) in cases.enumerated() {
                let s = m.sample(at: p, noise: JetFluctuations.Noise(value: n))
                let e = Double(gpu[i].x + gpu[i].y), l = Double(gpu[i].z)
                if s.extinction > 1e-4 {
                    worstExtinction = max(worstExtinction, abs(e / s.extinction - 1))
                }
                if s.emission.luminance > 1e-3 * max(m.sample(at: p).emission.luminance, 1) {
                    worstLight = max(worstLight, abs(l / s.emission.luminance - 1))
                }
            }
        }
        print(String(format: "JetFluctuationsRenderTests: GPU against the reference, extinction within %.4f, light "
                     + "within %.4f", worstExtinction, worstLight))
        XCTAssertLessThan(worstExtinction, 0.005)
        XCTAssertLessThan(worstLight, 0.03)

        // Still: the F-1's potential core at the pad, and its free expansion
        // within the boundary at 65 km.
        var squares = 0.0, count = 0, moving = 0.0
        for (altitude, inside) in [(0.0, true), (65_000, false)] {
            let m = Self.f1(altitude: altitude)
            let u = PlumeLook.perpendicular(m.axis)
            let points = (0..<16).map { i -> Vec3 in
                if inside {
                    let x = 0.9 * m.coreLength * Double(i) / 15, rc = m.exitRadius * (1 - x / m.coreLength)
                    return m.centre(atX: x) + u * (0.9 * rc * Double(i % 4) / 3)
                }
                let x = 20 + 20 * Double(i)
                return m.centre(atX: x) + u * (0.9 * m.radius(atX: x) * Double(i % 4) / 3)
            }
            let gpu = try gpuField(m, points.flatMap { p in values.map { (p, $0) } })
            for k in 0..<points.count {
                let base = gpu[k * values.count]
                for j in 1..<values.count {
                    let g = gpu[k * values.count + j]
                    for (a, b) in [(g.x + g.y, base.x + base.y), (g.z, base.z)] where b > 0 {
                        squares += pow(Double(a / b) - 1, 2)
                        count += 1
                    }
                }
            }
            // The shear layer about the core does move.
            if inside {
                let edge = (1..<8).map { m.centre(atX: Double($0) * 4) + u * m.radius(atX: Double($0) * 4) }
                let e = try gpuField(m, edge.flatMap { p in [(p, -2.0), (p, 2.0)] })
                moving = (0..<edge.count).map { k -> Double in
                    let a = Double(e[2 * k].x), b = Double(e[2 * k + 1].x)
                    return abs(a - b) / max(a, b, 1e-9)
                }.max() ?? 0
            }
        }
        let rms = (squares / Double(max(count, 1))).squareRoot()
        print(String(format: "JetFluctuationsRenderTests: the core and the ballooned interior r.m.s. %.1e "
                     + "(%d comparisons); the shear layer moves by up to %.2f", rms, count, moving))
        XCTAssertGreaterThan(count, 100)
        XCTAssertLessThan(rms, 1e-3)
        XCTAssertGreaterThan(moving, 0.1)
    }

    /// The linear light of `shot` averaged over frames at turbulence times
    /// `times` (s), rendered running so that the clock moves.
    func meanLight(_ shot: SnapshotSpec.Shot, times: [Double]) throws -> [Float] {
        let snapper = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let scene0 = shot.scene(try shot.prepare(system: snapper.system))
        let r = try snapper.renderer(userTextures: false)
        guard let target = OffscreenTarget(device: r.device, width: shot.width, height: shot.height) else {
            throw SceneRenderer.Failure.noResources
        }
        r.startOver()
        r.settings = shot.settings
        let post = try XCTUnwrap(r.post)
        post.control.reset()
        var scene = scene0
        scene.clock.paused = false
        scene.clock.warp = 1
        scene.clock.frameIndex = 1
        scene.clock.realDt = 0
        r.renderAndWait(scene, into: target)
        var sum = [Float](), clock = 0.0
        for t in times {
            scene.clock.frameIndex += 1 << 24
            scene.clock.realDt = t - clock
            clock = t
            post.capturesLight = true
            r.renderAndWait(scene, into: target)
            let c = try XCTUnwrap(post.capturedLight(), "the light at \(t) s")
            let k = Float(1 / post.control.preExposure)
            if sum.isEmpty { sum = [Float](repeating: 0, count: c.pixels.count) }
            for i in 0..<c.pixels.count { sum[i] += c.pixels[i] * k }
        }
        return sum.map { $0 / Float(times.count) }
    }

    /// The luminance of a frame's central angular window: the window the
    /// whole frame spans at a vertical field of view `window` (rad), seen at
    /// `fov` (rad) with square pixels, its edge pixels weighted by how much
    /// of them it covers.
    static func windowLuminance(_ light: [Float], width: Int, height: Int, fov: Double, window: Double) -> Double {
        let scale = tan(window / 2) / tan(fov / 2)
        let hx = 0.5 * Double(width) * scale, hy = 0.5 * Double(height) * scale
        let cx = 0.5 * Double(width), cy = 0.5 * Double(height)
        func cover(_ i: Int, _ c: Double, _ h: Double) -> Double {
            max(0, min(Double(i + 1), c + h) - max(Double(i), c - h))
        }
        var sum = 0.0, weight = 0.0
        for y in max(Int((cy - hy).rounded(.down)), 0)..<min(Int((cy + hy).rounded(.up)), height) {
            let wy = cover(y, cy, hy)
            for x in max(Int((cx - hx).rounded(.down)), 0)..<min(Int((cx + hx).rounded(.up)), width) {
                let w = wy * cover(x, cx, hx), i = 4 * (y * width + x)
                sum += w * (0.2126 * Double(light[i]) + 0.7152 * Double(light[i + 1]) + 0.0722 * Double(light[i + 2]))
                weight += w
            }
        }
        return sum / max(weight, 1e-12)
    }

    /// Plan's test: the same region of the F-1s' far field at the pad (the
    /// window the 32× frame spans: 2 km off, 49.1 m down the plume about
    /// 100 m from the exits and 78.5 m across, the plume's 43 or so and the
    /// black backdrop beside it) is as bright from 1× to 32× zoom, within
    /// 3 %. Marched at every zoom (at 1× it would be an impostor, under 48
    /// pixels), its eddies are under the footprint's cut-off at 1× and drawn
    /// in full from 4× on, and the fluctuations keep the mean as they come
    /// in. Each zoom's light in that window with the turbulence over without,
    /// averaged over eight moments, and against 32×'s (at 1× the window is
    /// 19.5 by 12.2 pixels, its edges weighted; R6's half resolution blurs
    /// them).
    func testLuminanceHeldOverAZoom() throws {
        let engine = PlumeTestEngine(engine: "F-1", position: [0, 0, 100], altitude: 0, ring: 4, ringRadius: 4.9)
        let times = (0..<8).map { 0.25 + 1.37 * Double($0) }
        var ratios: [(Double, Double, Double, Double)] = []
        var moving = 0.0
        for zoom in [1.0, 2, 4, 8, 16, 32] {
            func shot(_ turbulent: Bool) -> SnapshotSpec.Shot {
                var s = PlumeRenderTests.lookDev([engine], distance: 2_000, ev: 15) {
                    $0.turbulence = turbulent
                    $0.marchPixels = 1
                }
                s.width = 640
                s.height = 400
                s.camera.fov = 45 / zoom
                return s
            }
            let on = try meanLight(shot(true), times: times), off = try meanLight(shot(false), times: [0.25])
            let fov = 45 / zoom * Double.pi / 180, window = 45.0 / 32 * Double.pi / 180
            let lOn = Self.windowLuminance(on, width: 640, height: 400, fov: fov, window: window)
            let lOff = Self.windowLuminance(off, width: 640, height: 400, fov: fov, window: window)
            ratios.append((zoom, lOn / lOff, lOff, lOn))
            if zoom == 32 {
                // One moment's frame does move about the mean.
                let one = try meanLight(shot(true), times: [0.25])
                var squares = 0.0, n = 0
                for i in stride(from: 0, to: one.count, by: 4) where off[i + 1] > 100 {
                    squares += pow(Double(one[i + 1] / off[i + 1]) - 1, 2)
                    n += 1
                }
                moving = (squares / Double(max(n, 1))).squareRoot()
            }
        }
        let full = ratios.last!.3
        print("JetFluctuationsRenderTests: the region's light with the turbulence over without, by zoom:",
              ratios.map { String(format: "%.0f×: %.4f (%.0f cd/m², %+.1f %% of 32×'s)", $0.0, $0.1, $0.2,
                                  100 * ($0.3 / full - 1)) }.joined(separator: ", "),
              String(format: "; one moment at 32× moves %.1f %% r.m.s.", 100 * moving))
        for (zoom, ratio, light, on) in ratios {
            XCTAssertGreaterThan(light, 1, "the plume is in the region at \(zoom)×")
            XCTAssertEqual(ratio, 1, accuracy: 0.03, "\(zoom)×")
            XCTAssertEqual(on / full, 1, accuracy: 0.03, "\(zoom)× against 32×")
        }
        XCTAssertGreaterThan(moving, 0.02, "the fluctuations are drawn at 32×")
    }
}

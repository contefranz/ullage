import Foundation
import Metal
import XCTest
import OrbitCore
@testable import OrbitScene
@testable import OrbitRender

/// R3's environment probe on the GPU against OrbitScene's references: the
/// cube's convention (its texels and Metal's sampler), the GGX prefilter
/// against brute force, the irradiance cube against brute force and SH9,
/// SH9 reaching this frame's LightingUniforms, the white furnace through
/// the vessel pass, and earthshine on a plate against Howell's factor.
@MainActor
final class EnvironmentProbePassTests: XCTestCase {
    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// Copies LightingUniforms' sh9, probe and ambient (buffer 29, as P1
    /// sees it) into a buffer, in P4.
    final class LightingCapture: RenderPass {
        let name = "Lighting capture"
        let stage = PassStage.post
        let order = 0
        private var pipeline: MTLComputePipelineState?
        private(set) var buffer: MTLBuffer?

        func setUp(_ s: PassSetup) throws {
            let module = ShaderModule(name: "LightingCaptureTest", source: """
                kernel void lighting_capture(constant LightingUniforms &l [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                             device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
                    if (i < 9u) { out[i] = l.sh9[i]; } else if (i == 9u) { out[i] = l.probe; } else { out[i] = l.ambient; }
                }
                """)
            let library = try s.shaders.library(module)
            pipeline = try s.device.makeComputePipelineState(function: library.makeFunction(name: "lighting_capture")!)
            buffer = s.device.makeBuffer(length: 11 * 16, options: .storageModeShared)
        }

        func encode(_ f: FrameContext, _ e: PassEncoding) {
            guard let pipeline, let buffer, let enc = f.makeComputeEncoder() else { return }
            f.bindShared(enc)
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.dispatchThreads(MTLSize(width: 11, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 11, height: 1, depth: 1))
            enc.endEncoding()
        }

        var values: [SIMD4<Float>] {
            guard let buffer else { return [] }
            return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 11),
                                             count: 11))
        }
    }

    /// The probe alone in a renderer, on the look-dev scene's Sun, and what
    /// the lighting uniforms held after P0.
    func renderProbe(_ settings: ProbeSettings) throws -> (EnvironmentProbePass, LightingCapture, SceneRenderer) {
        let device = try device()
        let probe = EnvironmentProbePass(), capture = LightingCapture()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: [probe, capture],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 1))
        XCTAssertEqual(r.failures, [:])
        var s = RenderSettings()
        s.probe = settings
        r.settings = s
        let scene = LookDevScenes.materialSpheres(width: 8, height: 8)
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 8, height: 8))
        r.renderAndWait(scene, into: target)
        XCTAssertTrue(probe.lastFrame.drawn)
        return (probe, capture, r)
    }

    /// Level `level` of a cube texture, read back.
    func read(_ t: MTLTexture, level: Int, device: MTLDevice) throws -> EnvironmentProbe.CubeMap {
        let n = max(t.width >> level, 1)
        let face = n * n * 8
        let buffer = try XCTUnwrap(device.makeBuffer(length: 6 * face, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        for f in 0..<6 {
            blit.copy(from: t, sourceSlice: f, sourceLevel: level, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: n, height: n, depth: 1),
                      to: buffer, destinationOffset: f * face, destinationBytesPerRow: n * 8, destinationBytesPerImage: face)
        }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let halves = UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float16.self, capacity: 24 * n * n),
                                         count: 24 * n * n)
        let values = (0..<(6 * n * n)).map {
            Spectrum3(Double(halves[4 * $0]), Double(halves[4 * $0 + 1]), Double(halves[4 * $0 + 2]))
        }
        return EnvironmentProbe.CubeMap(size: n, values: values)
    }

    static var earthBelow: ProbeSettings {
        var s = ProbeSettings()
        s.environment = .earthBelow
        return s
    }

    /// The analytic look-dev Earth the probe draws, in Swift.
    static var earthBelowReference: EnvironmentProbe.LookDevEnvironment {
        .earthBelow(toSun: LookDevScenes.toSun, sunLux: Photometry.solarIlluminanceAt1AU)
    }

    // MARK: The cube

    /// Each texel holds the radiance toward EnvironmentProbe's direction for
    /// it, and Metal's sampler, given that direction, returns that texel:
    /// the GPU's cube, the Swift convention and the hardware agree.
    func testCubeFollowsTheSwiftConventionAndTheSampler() throws {
        let device = try device()
        let (probe, _, _) = try renderProbe(Self.earthBelow)
        let maps = try XCTUnwrap(probe.maps)
        let cube = try read(maps.radiance, level: 0, device: device)
        let env = Self.earthBelowReference
        var off = 0, peak = 0.0
        for t in EnvironmentProbe.texels(size: cube.size) {
            let want = env.radiance(t.direction).g, got = cube.value(t.face, t.x, t.y).g
            peak = max(peak, want)
            // The disc's edge and the terminator may fall either side of a
            // texel centre in float.
            if abs(got - want) > 2e-3 * max(want, 1) + 1 { off += 1 }
        }
        XCTAssertGreaterThan(peak, 5_000)
        XCTAssertLessThan(off, cube.size * 6, "texels off the reference")

        // The sampler, nearest, at each texel's direction.
        let module = ShaderModule(name: "CubeSampleTest", source: """
            kernel void cube_sample(texturecube<float> c [[texture(0)]], const device float4 *d [[buffer(0)]],
                                    device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
                constexpr sampler s(filter::nearest);
                out[i] = c.sample(s, d[i].xyz, level(0.0));
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "cube_sample")))
        let texels = EnvironmentProbe.texels(size: cube.size).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
        let dirs = texels.map { SIMD4<Float>(Float($0.direction.x), Float($0.direction.y), Float($0.direction.z), 0) }
        let dBuffer = try XCTUnwrap(device.makeBuffer(bytes: dirs, length: 16 * dirs.count, options: .storageModeShared))
        let oBuffer = try XCTUnwrap(device.makeBuffer(length: 16 * dirs.count, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setTexture(maps.radiance, index: 0)
        enc.setBuffer(dBuffer, offset: 0, index: 0)
        enc.setBuffer(oBuffer, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: dirs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let out = UnsafeBufferPointer(start: oBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: dirs.count),
                                      count: dirs.count)
        for (k, t) in texels.enumerated() {
            XCTAssertEqual(Double(out[k].y), cube.value(t.face, t.x, t.y).g, accuracy: 1e-6,
                           "face \(t.face) texel \(t.x), \(t.y)")
        }
    }

    // MARK: Derived maps

    /// Each prefiltered mip against EnvironmentProbe.prefilterReference over
    /// the GPU's own radiance, R2's look-dev Earth with its disc's edge and
    /// terminator (filtered importance sampling, 32 samples at mip 1 doubling
    /// to 256, lod bias ½): the mean error within 4 % of the mean radiance,
    /// the largest within 5 % of the largest. (Křivánek and Colbert's bias
    /// of 1 with 32 samples throughout read 2² and 1² faces at roughness 1,
    /// 27 % off.)
    func testPrefilteredMipsMatchTheReference() throws {
        let device = try device()
        let (probe, _, _) = try renderProbe(Self.earthBelow)
        let maps = try XCTUnwrap(probe.maps)
        XCTAssertEqual(maps.mips, 6)
        let full = try read(maps.radiance, level: 0, device: device)
        let half = full.downsampled(), quarter = half.downsampled()
        for mip in 1..<maps.mips {
            let gpu = try read(maps.specular, level: mip, device: device)
            let source = mip == 1 ? full : mip == 2 ? half : quarter
            let roughness = EnvironmentProbe.roughness(mip: mip, count: maps.mips)
            var sumError = 0.0, sumSigned = 0.0, sumRef = 0.0, maxError = 0.0, maxRef = 0.0
            let texels = EnvironmentProbe.texels(size: gpu.size)
            let step = max(1, texels.count / 160)
            for t in stride(from: 0, to: texels.count, by: step).map({ texels[$0] }) {
                let ref = EnvironmentProbe.prefilterReference(source, n: t.direction, roughness: roughness).g
                let got = gpu.value(t.face, t.x, t.y).g
                sumError += abs(got - ref)
                sumSigned += got - ref
                sumRef += ref
                maxError = max(maxError, abs(got - ref))
                maxRef = max(maxRef, ref)
            }
            print(String(format: "probe prefilter mip %d (r %.2f): mean error %.2f%% of the mean (bias %+.2f%%), largest %.2f%% of the largest",
                         mip, roughness, 100 * sumError / sumRef, 100 * sumSigned / sumRef, 100 * maxError / maxRef))
            XCTAssertLessThan(sumError / sumRef, 0.04, "mip \(mip)")
            XCTAssertLessThan(maxError / maxRef, 0.05, "mip \(mip)")
        }
    }

    /// The irradiance cube against brute force over the same 32² downsample
    /// (half float's precision), and over the full cube (1 %); SH9 in this
    /// frame's LightingUniforms against SH9.project of the downsample; the
    /// irradiance cube against SH9's evaluation (its ringing at the
    /// terminator, within 4 % of the peak).
    func testIrradianceAndSH9() throws {
        let device = try device()
        let (probe, capture, _) = try renderProbe(Self.earthBelow)
        let maps = try XCTUnwrap(probe.maps)
        let full = try read(maps.radiance, level: 0, device: device)
        let source = try read(maps.radiance, level: 2, device: device)
        XCTAssertEqual(source.size, EnvironmentProbePass.sourceSize)
        let irradiance = try read(maps.irradiance, level: 0, device: device)
        XCTAssertEqual(irradiance.size, EnvironmentProbePass.irradianceSize)
        let captured = capture.values
        XCTAssertEqual(captured.count, 11)
        let sh = SH9(irradianceOverPi: (0..<9).map { Spectrum3(Double(captured[$0].x), Double(captured[$0].y),
                                                                Double(captured[$0].z)) })
        let cpu = SH9.project(source.samples)
        let peak = EnvironmentProbe.irradianceReference(full, n: -.unitZ).g
        XCTAssertGreaterThan(peak, 100)
        for i in 0..<9 {
            XCTAssertEqual(sh.irradianceOverPi[i].g, cpu.irradianceOverPi[i].g, accuracy: 1e-3 * peak, "sh9[\(i)]")
        }
        var worstSH = 0.0
        for t in EnvironmentProbe.texels(size: irradiance.size) {
            let got = irradiance.value(t.face, t.x, t.y).g
            XCTAssertEqual(got, EnvironmentProbe.irradianceReference(source, n: t.direction).g, accuracy: 2e-3 * peak)
            if t.x % 5 == 2, t.y % 5 == 2 {
                XCTAssertEqual(got, EnvironmentProbe.irradianceReference(full, n: t.direction).g, accuracy: 0.01 * peak)
            }
            worstSH = max(worstSH, abs(sh.irradianceOverPi(t.direction).g - got))
        }
        print(String(format: "probe SH9 against the irradiance cube: largest difference %.2f%% of the peak", 100 * worstSH / peak))
        XCTAssertLessThan(worstSH, 0.04 * peak)
        // The probe's centre (the camera target, 20 m ahead), its mips, the
        // night floor at pre-exposure 1, the scale.
        XCTAssertEqual(captured[9], SIMD4<Float>(0, 20, 0, 6))
        XCTAssertEqual(captured[10], SIMD4<Float>(0.02, 0.02, 0.02, 1))
    }

    /// A furnace without the probe's light leaves SH9 at zero, and the probe
    /// turned off publishes nothing: the vessels keep R2's stand-in.
    func testFurnaceSH9AndProbeOff() throws {
        var furnace = ProbeSettings()
        furnace.environment = .furnace
        furnace.furnaceRadiance = 250
        let (_, capture, _) = try renderProbe(furnace)
        let c = capture.values
        XCTAssertEqual(Double(c[0].y), 250 / 0.282_094_791_773_878_1, accuracy: 0.5)
        for i in 1..<9 { XCTAssertEqual(c[i].y, 0, accuracy: 0.05, "sh9[\(i)]") }
        var off = ProbeSettings()
        off.enabled = false
        let device = try device()
        let probe = EnvironmentProbePass(), capture2 = LightingCapture()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: [probe, capture2],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 1))
        var s = RenderSettings()
        s.probe = off
        r.settings = s
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 8, height: 8))
        r.renderAndWait(LookDevScenes.materialSpheres(width: 8, height: 8), into: target)
        XCTAssertFalse(probe.lastFrame.drawn)
        XCTAssertEqual(capture2.values, [SIMD4<Float>](repeating: .zero, count: 11))
    }

    /// The faces two a frame in turn while frames follow each other at 1×;
    /// all six on the first frame, a temporal reset, a skipped frame, a warp
    /// above 10×, a Sun that turned or new settings.
    func testFacesRoundRobin() throws {
        let device = try device()
        let probe = EnvironmentProbePass()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: [probe],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 1))
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 8, height: 8))
        var scene = LookDevScenes.materialSpheres(width: 8, height: 8)
        func faces(_ index: Int, reset: Bool = false, warp: Double = 1) -> Int {
            scene.clock.frameIndex = index
            scene.clock.temporalReset = reset
            scene.clock.warp = warp
            r.renderAndWait(scene, into: target)
            return probe.lastFrame.facesDrawn
        }
        XCTAssertEqual([faces(1), faces(2), faces(3), faces(4)], [6, 2, 2, 2])
        XCTAssertEqual(faces(5, reset: true), 6)
        XCTAssertEqual([faces(6), faces(8)], [2, 6], "a skipped frame")
        XCTAssertEqual([faces(9, warp: 100), faces(10, warp: 10)], [6, 2])
        let sun = scene.sun.direction
        scene.sun.direction = (sun + Vec3(0, 0, 0.01)).normalized
        XCTAssertEqual(faces(11), 6, "the Sun turned 0.4°")
        var s = r.settings
        s.probe.nightFloor = 0.03
        r.settings = s
        XCTAssertEqual([faces(12), faces(13)], [6, 2], "new settings")
    }

    // MARK: Through the vessel pass

    /// The app's renderer at EV 15 with the probe's environment `env`, the
    /// Sun put out, no night floor and no AO: only the probe lights.
    func probeLitRenderer(_ env: ProbeEnvironment, furnace: Double = 1_000) throws -> SceneRenderer {
        let r = try SceneRenderer(device: try device(), loadsUserTextures: false)
        var s = RenderSettings()
        s.post.exposure.mode = .manual
        s.post.exposure.ev100 = 15
        s.probe.environment = env
        s.probe.furnaceRadiance = furnace
        s.probe.nightFloor = 0
        s.ambientOcclusion.enabled = false
        r.settings = s
        return r
    }

    /// cd/m² before the tone map, rgba per pixel (R1's capture).
    func light(_ scene: RenderScene, _ r: SceneRenderer) throws -> [Float] {
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: w, height: h))
        let post = try XCTUnwrap(r.post, "R1's post pass")
        post.capturesLight = true
        r.renderAndWait(scene, into: target)
        XCTAssertEqual(r.failures, [:])
        let c = try XCTUnwrap(post.capturedLight())
        let k = Float(1 / post.control.preExposure)
        return c.pixels.enumerated().map { $0.offset % 4 == 3 ? $0.element : $0.element * k }
    }

    /// A white dielectric (albedo 1) and a metal of F0 1 at five roughnesses
    /// in a uniform environment render its radiance, within 2 % and 3 %
    /// (the design's furnace): the split sum with multiple scattering
    /// conserves energy through the probe's cubes.
    func testWhiteFurnace() throws {
        let r = try probeLitRenderer(.furnace, furnace: 1_000)
        let roughness = [0.05, 0.25, 0.45, 0.65, 0.85]
        var shapes: [VisualShape] = []
        for (i, rough) in roughness.enumerated() {
            for (row, model) in [(0, MaterialDefaults.Model.metal), (1, .dielectric)] {
                let centre = Vec3(Double(i - 2) * 2.5, 0, Double(row == 0 ? 1.25 : -1.25))
                let profile = (0...48).map { k -> VisualShape.ProfilePoint in
                    let t = Double.pi * Double(k) / 48
                    return VisualShape.ProfilePoint(-cos(t), sin(t))
                }
                var s = VisualShape.revolution(profile, from: centre, axis: .unitZ, segments: 96, color: (1, 1, 1))
                s.material = MaterialDefaults.lookDev(model, roughness: rough)
                shapes.append(s)
            }
        }
        let part = VesselPart(name: "Furnace spheres", dryMass: 1, length: 2, radius: 1, shapes: shapes)
        let vessel = Vessel(name: "Furnace spheres", parts: [part], reference: VesselPassTests.system.earth)
        let (w, h) = (320, 160)
        var scene = LookDevScenes.scene(vessel, at: Vec3(0, 20, 0), attitude: .identity, fovY: 20, width: w, height: h)
        scene.vessels[0].light.sunlit = 0
        let pixels = try light(scene, r)
        let metresPerPixel = 2 * 20 * tan(10 * Double.pi / 180) / Double(h)
        for (i, rough) in roughness.enumerated() {
            for (row, tolerance) in [(0, 0.03), (1, 0.02)] {
                let x = w / 2 + Int((Double(i - 2) * 2.5 / metresPerPixel).rounded())
                let y = h / 2 - Int(((row == 0 ? 1.25 : -1.25) / metresPerPixel).rounded())
                let g = Double(pixels[4 * (y * w + x) + 1])
                XCTAssertEqual(g, 1_000, accuracy: 1_000 * tolerance, "\(row == 0 ? "metal" : "white") r \(rough)")
            }
        }
    }

    /// A white plate tilted 45° from the nadir under the evenly lit look-dev
    /// Earth from 185 km: its luminance through the probe's cubes and the
    /// vessel pass against the split sum on the CPU, Howell's (horizon-
    /// clipped) sphere factor for the irradiance and the prefilter reference
    /// for the specular, within 5 % (the design's earthshine test).
    func testEarthshineOnAPlate() throws {
        let r = try probeLitRenderer(.earthUniform)
        let normal = Vec3(0, -1, -1).normalized
        var plate = VisualShape.box(from: Vec3(0, 0, 0), length: 0.1, width: 6, height: 6, axis: normal,
                                    color: (0.8, 0.8, 0.8))
        plate.material = MaterialDefaults.lookDev(.dielectric, roughness: 0.85)
        let part = VesselPart(name: "Plate", dryMass: 1, length: 1, radius: 5, shapes: [plate])
        let vessel = Vessel(name: "Plate", parts: [part], reference: VesselPassTests.system.earth)
        let (w, h) = (64, 64)
        var scene = LookDevScenes.scene(vessel, at: Vec3(0, 20, 0), attitude: .identity, fovY: 6, width: w, height: h)
        scene.vessels[0].light.sunlit = 0
        let pixels = try light(scene, r)
        let got = Double(pixels[4 * ((h / 2) * w + w / 2) + 1])

        let env = EnvironmentProbe.LookDevEnvironment.earthUniform(sunLux: scene.sun.illuminance)
        let s2 = LookDevScenes.earthSinSigma2
        let radiance = env.radiance(-.unitZ).g
        let irradianceOverPi = radiance * BRDF.sphereIrradiance(cosTheta: normal.dot(-.unitZ), sinSigma2: s2) / Double.pi
        let view = Vec3(0, -1, 0)
        let nv = normal.dot(view)
        let reflection = normal * (2 * nv) - view
        let cube = EnvironmentProbe.CubeMap(size: 48) { env.radiance($0) }
        let prefiltered = EnvironmentProbe.prefilterReference(cube, n: reflection.normalized, roughness: 0.85).g
        let dfg = BRDF.dfgTable.lookup(nv: nv, roughness: 0.85)
        let weights = BRDF.environmentWeights(f0: 0.04, albedo: 0.8, a: dfg.a, b: dfg.b)
        let want = weights.specular * prefiltered + (weights.multiple + weights.diffuse) * irradianceOverPi
        print(String(format: "earthshine on a plate: %.1f cd/m², split sum %.1f (E/π %.1f)", got, want, irradianceOverPi))
        XCTAssertEqual(got, want, accuracy: 0.05 * want)
    }
}

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

    /// The faces two a frame in turn while frames follow each other at 1×:
    /// three frames draw all six exactly once. All six on the first frame, a
    /// skipped frame or new settings; three on a reset for the body's turn
    /// alone, or while the centre moves or the Sun turns more than half a
    /// texel a frame (in the world: a camera orbiting its target moves
    /// nothing); none while paused once all six are current, and then no
    /// derived maps either. ProbeCadenceTests has the bodies' cases.
    func testFacesRoundRobin() throws {
        let device = try device()
        let probe = EnvironmentProbePass()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: [probe],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 1))
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 8, height: 8))
        var scene = LookDevScenes.materialSpheres(width: 8, height: 8)
        func faces(_ index: Int, reset: Bool = false, paused: Bool = false) -> [Int] {
            scene.clock.frameIndex = index
            scene.clock.temporalReset = reset
            scene.clock.paused = paused
            r.renderAndWait(scene, into: target)
            return probe.lastFrame.faces
        }
        XCTAssertEqual(faces(1), Array(0..<6))
        let cycle = [faces(2), faces(3), faces(4)]
        XCTAssertEqual(cycle.map(\.count), [2, 2, 2])
        XCTAssertEqual(cycle.flatMap { $0 }.sorted(), Array(0..<6), "three frames, each face once")
        XCTAssertEqual(faces(5, reset: true).count, 3, "a reset with the same target and warp: the body's turn")
        XCTAssertEqual([faces(6).count, faces(8).count], [2, 6], "a skipped frame")
        // The camera orbits its target 1.5 km out: the probe does not move.
        scene.camera.position = scene.camera.position + Vec3(1_500, 0, 0)
        scene.vessels[0].position = scene.vessels[0].position - Vec3(1_500, 0, 0)
        XCTAssertEqual(faces(9).count, 2, "a camera orbit")
        // The target flies 5 m in a frame, then 50 m (1 km is the scale without
        // a body: half a 128² texel is 7.8 m).
        scene.vessels[0].position = scene.vessels[0].position + Vec3(0, 5, 0)
        XCTAssertEqual(faces(10).count, 2, "5 m a frame")
        scene.vessels[0].position = scene.vessels[0].position + Vec3(0, 50, 0)
        let moving = [faces(11)]
        XCTAssertEqual(moving[0].count, 3, "50 m a frame")
        let sun = scene.sun.direction
        scene.sun.direction = (sun + Vec3(0, 0, 0.03)).normalized
        XCTAssertEqual(faces(12).count, 3, "the Sun turned 1.3°")
        XCTAssertEqual(faces(13).count, 2, "still again")
        var s = r.settings
        s.probe.nightFloor = 0.03
        r.settings = s
        XCTAssertEqual([faces(14).count, faces(15).count], [6, 2], "new settings")
        // Paused: the faces left to draw, then nothing, and no derived maps.
        let paused = [faces(16, paused: true), faces(17, paused: true), faces(18, paused: true)]
        XCTAssertEqual(paused.flatMap { $0 }.count, 6)
        XCTAssertEqual(faces(19, paused: true), [])
        XCTAssertFalse(probe.lastFrame.derived)
        XCTAssertTrue(probe.lastFrame.drawn, "still published")
        XCTAssertEqual(faces(20).count, 2, "running again")
        // 6 a frame on request (the cost test's full path).
        s.probe.facesPerFrame = 6
        r.settings = s
        XCTAssertEqual([faces(21).count, faces(22).count], [6, 6])
    }

    /// The probe on the pad holds the ground below it (the WGS-84 ground is
    /// 4.9 km inside the equatorial sphere there, which the planets' probe
    /// entry once took for the planet's inside): sunlit sea toward the nadir,
    /// with the pad left out of the probe.
    func testPadProbeHoldsTheGround() throws {
        let device = try device()
        let snapper = try SnapshotRenderer(device: device)
        var shot = SnapshotSpec.Shot(name: "pad", scenario: "as506-pad",
                                     camera: SnapshotSpec.CameraSpec(yaw: -60, pitch: 4, distance: 210, fov: 38))
        shot.width = 64
        shot.height = 40
        let scene = shot.scene(try shot.prepare(system: snapper.system))
        let r = try SceneRenderer(device: device, loadsUserTextures: false)
        var s = r.settings
        s.probe.sites = false
        s.particle.quality = .off
        r.settings = s
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 64, height: 40))
        r.renderAndWait(scene, into: target)
        let probe = try XCTUnwrap(r.graph.passes.compactMap { $0 as? EnvironmentProbePass }.first)
        let cube = try read(try XCTUnwrap(probe.maps).radiance, level: 0, device: device)
        let earth = try XCTUnwrap(scene.bodies.first { $0.id == 399 })
        let up = (probe.lastFrame.center - earth.position).normalized
        let down = cube.nearest(-up).g
        // Up: the sky, for scale.
        let sky = cube.nearest(up).g
        print(String(format: "pad probe: nadir %.0f cd/m², zenith %.0f cd/m²", down, sky))
        XCTAssertGreaterThan(down, 200, "the ground below the pad")
        XCTAssertGreaterThan(sky, 200, "the sky above")
    }

    /// C2's far clouds are in the probe whether or not they are on screen,
    /// and only while they are on: with the camera looking away from the
    /// Earth in LEO, the probe's nadir irradiance is higher with clouds than
    /// without, and turning the clouds off leaves none behind.
    func testProbeCloudsFollowTheSettingsNotTheView() throws {
        let device = try device()
        let snapper = try SnapshotRenderer(device: device)
        var shot = SnapshotSpec.Shot(name: "away", scenario: "as506-parking-orbit", advance: ["stage", "wait:60"],
                                     camera: SnapshotSpec.CameraSpec(target: "vessel:Apollo 11 – S-IVB", frame: "vessel",
                                                                     yaw: 0, pitch: -60, distance: 40, fov: 50))
        shot.width = 64
        shot.height = 40
        let scene = shot.scene(try shot.prepare(system: snapper.system))
        func nadirIrradiance(_ r: SceneRenderer, clouds: Bool) throws -> Double {
            var s = r.settings
            s.cloud.enabled = clouds
            r.settings = s
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: 64, height: 40))
            r.renderAndWait(scene, into: target)
            let cloudPass = try XCTUnwrap(r.graph.passes.compactMap { $0 as? CloudPass }.first)
            XCTAssertFalse(cloudPass.lastFrame.drawn, "the clouds are off screen")
            let probe = try XCTUnwrap(r.graph.passes.compactMap { $0 as? EnvironmentProbePass }.first)
            let irradiance = try read(try XCTUnwrap(probe.maps).irradiance, level: 0, device: device)
            let earth = try XCTUnwrap(scene.bodies.first { $0.id == 399 })
            return irradiance.nearest((earth.position - probe.lastFrame.center).normalized).g
        }
        let a = try SceneRenderer(device: device, loadsUserTextures: false)
        let cloudy = try nadirIrradiance(a, clouds: true)
        let cleared = try nadirIrradiance(a, clouds: false)
        let fresh = try nadirIrradiance(try SceneRenderer(device: device, loadsUserTextures: false), clouds: false)
        print(String(format: "probe nadir E/π in LEO: with clouds %.0f, turned off %.0f, never on %.0f", cloudy, cleared, fresh))
        XCTAssertGreaterThan(cloudy, 1.2 * fresh, "the clouds brighten the Earth below")
        XCTAssertEqual(cleared, fresh, accuracy: 0.002 * fresh, "no clouds left behind")
    }

    /// R1's rule in the probe's clean (+inf saturates at 6e4, NaN and −inf
    /// are no light), and the pass that cleans the faces in place before
    /// their mips: a face texel stored as +inf by a blend.
    func testCleanFollowsR1sRule() throws {
        let device = try device()
        let module = ShaderModule(name: "ProbeCleanTest", headers: [.sphericalHarmonics], source: probeShaderSource + """

            kernel void clean_test(const device float4 *input [[buffer(0)]], device float4 *out [[buffer(1)]],
                                   uint i [[thread_position_in_grid]]) {
                out[i] = probe_clean(input[i].xyz);
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "clean_test")))
        let nan = Float(bitPattern: 0x7fc0_0000)
        let input: [SIMD4<Float>] = [SIMD4(.infinity, -.infinity, nan, 0), SIMD4(7e4, -1, 123.5, 0)]
        let inBuffer = try XCTUnwrap(device.makeBuffer(bytes: input, length: 32, options: .storageModeShared))
        let outBuffer = try XCTUnwrap(device.makeBuffer(length: 32, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(inBuffer, offset: 0, index: 0)
        enc.setBuffer(outBuffer, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let out = outBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
        XCTAssertEqual(SIMD3(out[0].x, out[0].y, out[0].z), SIMD3(60_000, 0, 0))
        XCTAssertEqual(SIMD3(out[1].x, out[1].y, out[1].z), SIMD3(60_000, 0, 123.5))

        // The faces: one texel at +inf in a 32² cube, cleaned in place.
        let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: 32, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let cube = try XCTUnwrap(device.makeTexture(descriptor: d))
        var texels = [Float16](repeating: 1, count: 4 * 32 * 32)
        texels[4 * (5 * 32 + 7)] = .infinity
        for face in 0..<6 {
            cube.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0, slice: face, withBytes: texels,
                         bytesPerRow: 32 * 8, bytesPerImage: 32 * 32 * 8)
        }
        let faces = try XCTUnwrap(cube.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2DArray,
                                                       levels: 0..<1, slices: 0..<6))
        let clean = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "probe_cleanFaces")))
        cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc2 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc2.setComputePipelineState(clean)
        enc2.setTexture(faces, index: 0)
        enc2.dispatchThreads(MTLSize(width: 32, height: 32, depth: 6), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc2.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let back = try read(cube, level: 0, device: device)
        for f in EnvironmentProbe.Face.allCases {
            XCTAssertEqual(back.value(f, 7, 5).r, 60_000, accuracy: 32, "face \(f)")
            XCTAssertEqual(back.value(f, 8, 5).r, 1)
        }
    }

    /// The smallest face the probe draws, 32² (16 resolves to it: the
    /// irradiance and SH9 read a 32² source): its irradiance against brute
    /// force over its own radiance.
    func testSmallestFaceIrradiance() throws {
        let device = try device()
        var settings = Self.earthBelow
        settings.faceSize = 16
        let (probe, capture, _) = try renderProbe(settings)
        let maps = try XCTUnwrap(probe.maps)
        XCTAssertEqual(maps.size, 32)
        XCTAssertEqual(maps.mips, 4)
        let full = try read(maps.radiance, level: 0, device: device)
        let irradiance = try read(maps.irradiance, level: 0, device: device)
        let peak = EnvironmentProbe.irradianceReference(full, n: -.unitZ).g
        for t in EnvironmentProbe.texels(size: irradiance.size) where t.x % 3 == 1 && t.y % 3 == 1 {
            XCTAssertEqual(irradiance.value(t.face, t.x, t.y).g, EnvironmentProbe.irradianceReference(full, n: t.direction).g,
                           accuracy: 2e-3 * peak)
        }
        let sh = SH9(irradianceOverPi: (0..<9).map {
            Spectrum3(Double(capture.values[$0].x), Double(capture.values[$0].y), Double(capture.values[$0].z)) })
        XCTAssertEqual(sh.irradianceOverPi(-.unitZ).g, peak, accuracy: 0.04 * peak)
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

import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// The plumes' turbulence on the GPU (`plume_noise` on the cluster's flow)
/// against its reference (`PlumeTurbulence.value` on the texture's own
/// texels): the same flow noise at points through the F-1s' cluster and its
/// merged far field, at the clock's start and minutes on; on screen, never
/// looping; and the uniforms' Swift mirrors at MSL's sizes.
@MainActor
final class PlumeTurbulenceRenderTests: XCTestCase {
    static let probe = """
        kernel void plume_noise_probe(const device PlumeMember *members [[buffer(0)]],
                                      constant PlumeFrame &pf [[buffer(1)]],
                                      const device float4 *points [[buffer(2)]],
                                      device float *out [[buffer(3)]],
                                      constant float4 *cluster [[buffer(4)]],
                                      texture3d<float> noise [[texture(0)]], sampler ns [[sampler(0)]],
                                      uint id [[thread_position_in_grid]]) {
            // The cluster: x its members (the merged one after them), y
            // mergeX; its origin; its axis. The march's sample, as it finds
            // the flow and the noise.
            float3 p = points[id].xyz;
            float mergeX = cluster[0].y;
            float wm = mergeX > 0.0 ? plume_smoothstep(mergeX, 1.15 * mergeX, dot(p - cluster[1].xyz, cluster[2].xyz))
                                    : 0.0;
            PlumeNoiseAt na = {members, 0, int(cluster[0].x), wm, false, 0.0};
            out[id] = plume_noiseAt(na, PlumeAsking{-1, 0.0, 0.0, 0.0}, p, pf, noise, ns);
        }

        kernel void plume_shadow_probe(const device float4 *rays [[buffer(0)]], constant float4 *capsule [[buffer(1)]],
                                       device float2 *out [[buffer(2)]], uint id [[thread_position_in_grid]]) {
            out[id] = plume_shadowInterval(rays[id].xyz, capsule[2].xyz, capsule[0].xyz, capsule[1].xyz, capsule[0].w);
        }

        kernel void plume_sizes(device uint *out [[buffer(0)]]) {
            out[0] = sizeof(PlumeFrame);
            out[1] = sizeof(PlumeMember);
            out[2] = sizeof(PlumeCluster);
        }
        """

    func library(_ device: MTLDevice) throws -> MTLLibrary {
        let m = ShaderModule.plume
        return try ShaderLibrary(device: device).library(ShaderModule(name: "PlumeProbe", headers: m.headers,
                                                                      source: plumeShaderSource + Self.probe))
    }

    /// The F-1s at the pad's air, a ring of four and the centre, their
    /// axis tilted off the world's and their exits away from the camera.
    func cluster() -> [PlumeMember] {
        var settings = PlumeSettings()
        settings.turbulence = true
        let air = USStandardAtmosphere1976().state(altitude: 0)
        let s = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: air)
        let axis = Vec3(0.3, -0.9, 0.2).normalized
        let u = PlumeLook.perpendicular(axis), v = axis.cross(u).normalized
        let centre = Vec3(12, 40, -7)
        let exits = [centre] + (0..<4).map { i -> Vec3 in
            let a = Double.pi / 2 * (Double(i) + 0.5)
            return centre + u * (4.9 * cos(a)) + v * (4.9 * sin(a))
        }
        return exits.enumerated().map { i, e in
            var m = PlumeLook.member(ApolloExhaust.f1.spec, state: s, exit: e, axis: axis,
                                     exitRadius: ApolloExhaust.f1.spec.exitRadius, ambient: air)
            m.name = "S-IC engine \(i + 1)"
            m.noiseSeed = PlumeTurbulence.seed("S-IC|" + m.name)
            return m
        }
    }

    func testNoiseMatchesTheReference() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let lib = try library(device)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: "plume_noise_probe")))
        let noise = try VolumeNoise(device: device, library: try ShaderLibrary(device: device).library(.particle))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        do {
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
            noise.encodeIfNeeded(enc)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        let members = cluster()
        let merge = PlumeClusters.cluster(members)
        let merged = try XCTUnwrap(merge.merged)
        let seed: UInt32 = 0x1234_5678
        let gpuMembers = (members + [merged]).map { Plumes.gpu($0, seed: seed) }
        let m0 = members[0]
        let u = PlumeLook.perpendicular(m0.axis), v = m0.axis.cross(u).normalized
        var state: UInt32 = 11
        let points = (0..<96).map { _ -> Vec3 in
            let x = 0.5 + 160 * pow(ParticleRandom.uniform(&state), 2)
            let r = 1.2 * m0.radius(atX: x) * ParticleRandom.uniform(&state) + (x < 20 ? 5 : 0)
            let a = 2 * Double.pi * ParticleRandom.uniform(&state)
            return m0.exit + m0.axis * x + u * (r * cos(a)) + v * (r * sin(a))
        }
        var worst = 0.0, sum = 0.0, spread = 0.0
        for t in [0.0, 13.7, 1_234.567] {
            var pf = PlumeFrameGPU()
            Plumes.setTurbulence(&pf)
            pf.setLayers(Plumes.layers(time: t))
            let memberBuffer = try XCTUnwrap(device.makeBuffer(bytes: gpuMembers,
                                                               length: MemoryLayout<PlumeMemberGPU>.stride * gpuMembers.count))
            let p4 = points.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 0) }
            let pointBuffer = try XCTUnwrap(device.makeBuffer(bytes: p4, length: 16 * p4.count))
            let out = try XCTUnwrap(device.makeBuffer(length: 4 * points.count, options: .storageModeShared))
            var c = [SIMD4<Float>(Float(members.count), Float(merge.mergeX), 0, 0),
                     Plumes.f4(merge.origin, 0), Plumes.f4(merge.axis, 0)]
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(memberBuffer, offset: 0, index: 0)
            enc.setBytes(&pf, length: MemoryLayout<PlumeFrameGPU>.stride, index: 1)
            enc.setBuffer(pointBuffer, offset: 0, index: 2)
            enc.setBuffer(out, offset: 0, index: 3)
            enc.setBytes(&c, length: 16 * c.count, index: 4)
            enc.setTexture(noise.texture, index: 0)
            enc.setSamplerState(noise.sampler, index: 0)
            enc.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            let gpu = out.contents().bindMemory(to: Float.self, capacity: points.count)
            let bands = PlumeTurbulence.bands(time: t)
            for (i, p) in points.enumerated() {
                let reference = PlumeTurbulence.value(members, merged: merged, mergeX: merge.mergeX,
                                                      origin: merge.origin, axis: merge.axis, at: p, bands: bands,
                                                      seed: seed, noise: PlumeTurbulence.texel)
                let d = abs(Double(gpu[i]) - reference)
                worst = max(worst, d)
                sum += d
                spread += reference * reference
            }
        }
        let n = Double(3 * points.count)
        print(String(format: "PlumeTurbulenceRenderTests: GPU against the reference, mean %.4f, worst %.4f (spread %.3f)",
                     sum / n, worst, (spread / n).squareRoot()))
        XCTAssertGreaterThan((spread / n).squareRoot(), 0.02, "the field is not flat")
        XCTAssertLessThan(sum / n, 0.004)
        XCTAssertLessThan(worst, 0.03)
    }

    /// The F-1s at the pad's air (P2's look-dev shot) through the renderer
    /// on the turbulence clock at `times` (s), ascending, the frames'
    /// pixels; the clock wrapped at `loop` (s) when given, as a loop would
    /// draw it. ORBITSIM_PLUME_FRAMES=<dir> writes them there for a look.
    func frames(at times: [Double], name: String, loop: Double? = nil) throws -> [[UInt8]] {
        let snapper = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let engine = PlumeTestEngine(engine: "F-1", position: [0, 0, 40], altitude: 0, ring: 4, ringRadius: 4.9)
        var shot = PlumeRenderTests.lookDev([engine], distance: 150, ev: 17)
        shot.settings.atmosphere.enabled = false
        let scene0 = shot.scene(try shot.prepare(system: snapper.system))
        let r = try snapper.renderer(userTextures: false)
        guard let target = OffscreenTarget(device: r.device, width: shot.width, height: shot.height) else {
            throw SceneRenderer.Failure.noResources
        }
        r.startOver()
        r.settings = shot.settings
        let system = try XCTUnwrap(r.graph.passes.compactMap { ($0 as? PlumePreparePass)?.system }.first)
        system.testLoop = loop
        let dir = ProcessInfo.processInfo.environment["ORBITSIM_PLUME_FRAMES"].map { URL(fileURLWithPath: $0) }
        // The shot opens paused: running, at real time. A first frame starts
        // the clock at 0; each frame on steps it to its time, 1,024 frames on
        // (every per-frame pattern's period: the jitter, the dither), so that only the turbulence differs.
        var scene = scene0
        scene.clock.paused = false
        scene.clock.warp = 1
        scene.clock.frameIndex = 1
        scene.clock.realDt = 0
        r.renderAndWait(scene, into: target)
        XCTAssertEqual(system.turbulenceClock, 0)
        var out: [[UInt8]] = [], clock = 0.0
        for (i, t) in times.enumerated() {
            scene.clock.frameIndex += 1 << 24
            scene.clock.realDt = t - clock
            clock = t
            r.renderAndWait(scene, into: target)
            XCTAssertEqual(system.turbulenceClock, t, accuracy: 1e-9, "the clock frame \(i) was drawn at")
            let pixels = target.bytes()
            out.append(pixels)
            if let dir {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try ImageFiles.writePNG(pixels, width: shot.width, height: shot.height, order: .bgra,
                                        to: dir.appendingPathComponent(String(format: "%@-%03d-%.4fs.png", name, i, t)))
            }
        }
        return out
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var d = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            d += abs(Double(a[i]) - Double(b[i])) + abs(Double(a[i + 1]) - Double(b[i + 1]))
                + abs(Double(a[i + 2]) - Double(b[i + 2]))
        }
        return d / Double(a.count / 4)
    }

    /// The plume on screen never loops: frames whole numbers of M1.6's
    /// first noise's loop apart (its tile over its eddy speed, 1.28 s for
    /// the F-1) differ as much as frames ten seconds apart, while a frame a
    /// millisecond on has moved on from its predecessor much less (a 60th
    /// of a second carries the F-1's far field half an eddy on, and its
    /// near field's eddies live a few milliseconds). The same
    /// frames drawn on a clock that loops at that period match, so the
    /// comparison sees a loop.
    func testOnScreenItNeverLoops() throws {
        let re = ApolloExhaust.f1.spec.exitRadius
        let loop = 16 * 0.8 * re / min(max(10 * re, 2), 40)
        let t0 = 3.0
        let times = [t0, t0 + 0.001, t0 + loop, t0 + 2 * loop, t0 + 3 * loop, t0 + 10, t0 + 20]
        let f = try frames(at: times, name: "f1")
        let unrelated = Self.difference(f[0], f[5])
        let next = Self.difference(f[0], f[1])
        let loops = [2, 3, 4].map { Self.difference(f[0], f[$0]) }
        let looped = try frames(at: [t0, t0 + loop, t0 + 2 * loop], name: "f1-looped", loop: loop)
        let seen = [1, 2].map { Self.difference(looped[0], looped[$0]) }
        print(String(format: "PlumeTurbulenceRenderTests: a millisecond on %.2f, a loop on %@, ten seconds on %.2f, "
                     + "twenty %.2f; on a looping clock a loop on %@ (mean |Δ| per pixel, 0-765)", next,
                     loops.map { String(format: "%.2f", $0) }.joined(separator: ", "), unrelated,
                     Self.difference(f[0], f[6]), seen.map { String(format: "%.3f", $0) }.joined(separator: ", ")))
        XCTAssertGreaterThan(unrelated, 0.3, "the plume moves")
        for d in seen { XCTAssertLessThan(d, 0.05 * unrelated, "a loop is seen") }
        for d in loops { XCTAssertGreaterThan(d, 0.7 * unrelated) }
        XCTAssertLessThan(next, 0.5 * unrelated)
    }

    /// The march's shadow interval (`plume_shadowInterval`): where a ray is
    /// in a capsule's shadow, swept away from the Sun, against a brute-force
    /// walk along each ray (the capsule seen along the Sun within its
    /// radius, and no nearer the Sun than its sunward side), within 5 cm.
    func testShadowIntervalIsTheCapsulesShadow() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let lib = try library(device)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: "plume_shadow_probe")))
        // A Saturn-V-like capsule 110 m long, 6 m in radius, 80 m off, the
        // Sun low across it.
        let a = Vec3(-20, 80, -30), b = Vec3(-20, 80 + 110, -30), radius = 6.0
        let sun = Vec3(0.8, 0.3, 0.52).normalized
        var state: UInt32 = 5
        let rays = (0..<256).map { _ -> Vec3 in
            let target = a + (b - a) * ParticleRandom.uniform(&state) - sun * (400 * ParticleRandom.uniform(&state))
                + Vec3(ParticleRandom.uniform(&state) - 0.5, 0, ParticleRandom.uniform(&state) - 0.5) * 30
            return target.normalized
        }
        var capsule = [Plumes.f4(a, radius), Plumes.f4(b, 0), Plumes.f4(sun, 0)]
        let rayBuffer = try XCTUnwrap(device.makeBuffer(bytes: rays.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 0) },
                                                        length: 16 * rays.count))
        let out = try XCTUnwrap(device.makeBuffer(length: 8 * rays.count, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(rayBuffer, offset: 0, index: 0)
        enc.setBytes(&capsule, length: 16 * capsule.count, index: 1)
        enc.setBuffer(out, offset: 0, index: 2)
        enc.dispatchThreads(MTLSize(width: rays.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let gpu = out.contents().bindMemory(to: SIMD2<Float>.self, capacity: rays.count)
        func shadowed(_ p: Vec3) -> Bool {
            func flat(_ v: Vec3) -> Vec3 { v - sun * v.dot(sun) }
            let q = flat(p), pa = flat(a), pb = flat(b), ab = pb - pa
            let t = min(max((q - pa).dot(ab) / ab.dot(ab), 0), 1)
            let front = max(a.dot(sun), b.dot(sun)) + radius
            return (q - (pa + ab * t)).length <= radius && p.dot(sun) <= front
        }
        var crossing = 0, worst = 0.0
        for (i, d) in rays.enumerated() {
            var lo = Double.infinity, hi = -Double.infinity
            for k in 0..<20_000 {
                let s = 0.05 * Double(k)
                if shadowed(d * s) {
                    lo = min(lo, s)
                    hi = max(hi, s)
                }
            }
            let g = gpu[i]
            if lo <= hi {
                crossing += 1
                worst = max(worst, abs(Double(g.x) - lo), abs(Double(g.y) - hi))
            } else {
                XCTAssertTrue(g.x >= g.y || Double(g.y) < 0, "ray \(i): no shadow, the interval \(g)")
            }
        }
        print(String(format: "PlumeTurbulenceRenderTests: %d of %d rays cross the capsule's shadow; its ends within %.3f m",
                     crossing, rays.count, worst))
        XCTAssertGreaterThan(crossing, 50)
        XCTAssertLessThan(worst, 0.1)
    }

    /// The capsule a vessel's shadow is cast by (`Plumes.capsule`): the
    /// Saturn V on the pad, 363 ft (110.6 m) tall, 33 ft (10.1 m) across
    /// its stages, 63.3 ft (19.3 m) across its fins' tips; and its axis the
    /// stack's.
    func testVesselCapsule() throws {
        let snapper = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let shot = SnapshotSpec.Shot(name: "capsule", scenario: "as506-pad", camera: SnapshotSpec.CameraSpec())
        let scene = shot.scene(try shot.prepare(system: snapper.system))
        let v = try XCTUnwrap(scene.vessels.first { $0.isFocus })
        let c = try XCTUnwrap(Plumes.capsule(v))
        let length = (c.b - c.a).length
        print(String(format: "PlumeTurbulenceRenderTests: the Saturn V's capsule %.1f m long, %.2f m in radius", length,
                     c.radius))
        XCTAssertEqual(length, 110.6, accuracy: 4)
        XCTAssertGreaterThan(c.radius, 5.0)
        XCTAssertLessThan(c.radius, 10.5)
        XCTAssertGreaterThan(abs((c.b - c.a).normalized.dot(v.attitude.rotate(.unitX))), 0.999)
    }

    /// The uniforms' Swift mirrors have MSL's sizes.
    func testStructLayoutsMatchMSL() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let lib = try library(device)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: "plume_sizes")))
        let out = try XCTUnwrap(device.makeBuffer(length: 3 * 4, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let v = out.contents().bindMemory(to: UInt32.self, capacity: 3)
        XCTAssertEqual(Int(v[0]), MemoryLayout<PlumeFrameGPU>.stride)
        XCTAssertEqual(Int(v[1]), MemoryLayout<PlumeMemberGPU>.stride)
        XCTAssertEqual(Int(v[2]), MemoryLayout<PlumeClusterGPU>.stride)
    }
}

/// The J-2s' chambers glowing through their throats (`ChamberGlow`) in the
/// real ascent, seen from behind: each of the five S-II engines mid-burn,
/// the fixed centre one among them (drawn from its part's static draws),
/// shows its chamber's light at its throat, orange and as bright as the
/// gas's emission over the chamber's length, where the same frame without
/// the nozzles' glow is dark; after the centre engine's cutoff its throat
/// is dark and the four others still glow. Seen from the side, the S-IVB's
/// J-2 shows none of it (its chamber is hidden behind the engine's wall).
@MainActor
final class ChamberGlowRenderTests: XCTestCase {
    struct Frame {
        var chambers: [(exit: Vec3, axis: Vec3, chamber: ApolloExhaust.Chamber, light: Photometry.RGB)]
        var light: [Float]
        var camera: RenderScene.Camera
        var width: Int, height: Int
    }

    func render(_ advance: [String], glow: Bool = true,
                camera: SnapshotSpec.CameraSpec = .init(frame: "vessel", yaw: 180, pitch: 8, distance: 40, fov: 40))
        throws -> Frame {
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        var shot = SnapshotSpec.Shot(name: "chambers", scenario: "as506-pad", advance: advance, camera: camera)
        shot.showOrbit = false
        shot.settings.cloud.enabled = false
        shot.settings.plume.nozzleGlow = glow
        let out = try s.render(shot)
        let r = try s.renderer(userTextures: false)
        let system = try XCTUnwrap(r.graph.passes.compactMap { ($0 as? PlumePreparePass)?.system }.first)
        return Frame(chambers: system.frame.chambers.map { ($0.exit, $0.axis, $0.chamber, $0.light) },
                     light: try XCTUnwrap(out.light), camera: try XCTUnwrap(system.frame.camera), width: shot.width,
                     height: shot.height)
    }

    /// Where camera-relative `p` projects (pixel column and row).
    func pixel(_ f: Frame, _ p: Vec3) -> (col: Double, row: Double) {
        let v = f.camera.worldToView * p, t = tan(f.camera.fovY / 2)
        let aspect = Double(f.width) / Double(f.height)
        return ((v.x / (-v.z) / (t * aspect) + 1) / 2 * Double(f.width), (1 - v.y / (-v.z) / t) / 2 * Double(f.height))
    }

    /// The brightest light (cd/m², linear Rec. 709) within 2 px of where
    /// camera-relative `p` projects.
    func light(_ f: Frame, at p: Vec3) -> (r: Double, g: Double, b: Double) {
        let (col, row) = pixel(f, p)
        var best = (r: 0.0, g: 0.0, b: 0.0)
        for dy in -2...2 {
            for dx in -2...2 {
                let x = Int(col) + dx, y = Int(row) + dy
                guard x >= 0, y >= 0, x < f.width, y < f.height else { continue }
                let i = 4 * (y * f.width + x)
                let c = (r: Double(f.light[i]), g: Double(f.light[i + 1]), b: Double(f.light[i + 2]))
                if c.r + c.g + c.b > best.r + best.g + best.b { best = c }
            }
        }
        return best
    }

    /// Where a chamber's injector face shows through its throat.
    func face(_ c: (exit: Vec3, axis: Vec3, chamber: ApolloExhaust.Chamber, light: Photometry.RGB)) -> Vec3 {
        c.exit - c.axis * c.chamber.injectorDepth
    }

    func testChambersGlowThroughTheThroats() throws {
        let mid = try render(["met:350"]), dark = try render(["met:350"], glow: false)
        XCTAssertEqual(mid.chambers.count, 5)
        XCTAssertTrue(dark.chambers.isEmpty)
        for (i, c) in mid.chambers.enumerated() {
            let on = light(mid, at: face(c)), off = light(dark, at: face(c))
            let cosine = abs(c.axis.dot(face(c).normalized))
            let expected = ChamberGlow.luminance(c.light, chamber: c.chamber, depth: c.chamber.injectorDepth,
                                                 cosine: cosine).luminance
            let glow = 0.2126 * (on.r - off.r) + 0.7152 * (on.g - off.g) + 0.0722 * (on.b - off.b)
            print(String(format: "ChamberGlowRenderTests: chamber %d: %.0f cd/m² (without the glow %.0f; expected %.0f), "
                         + "rgb %.0f %.0f %.0f", i, glow, 0.2126 * off.r + 0.7152 * off.g + 0.0722 * off.b,
                         expected, on.r, on.g, on.b))
            XCTAssertGreaterThan(glow, 0.3 * expected, "chamber \(i) glows")
            XCTAssertLessThan(glow, 1.5 * expected, "chamber \(i)")
            XCTAssertGreaterThan(on.r - off.r, on.g - off.g, "orange")
            XCTAssertGreaterThan(on.g - off.g, on.b - off.b, "orange")
        }
        let advance = ["ev:S-II centre engine cutoff", "wait:3"]
        let ceco = try render(advance), cecoDark = try render(advance, glow: false)
        XCTAssertEqual(ceco.chambers.count, 4)
        // The glow's own light: with it less without it (the sunlit ice in
        // front lights both alike).
        func glow(at p: Vec3) -> Double {
            let on = light(ceco, at: p), off = light(cecoDark, at: p)
            return 0.2126 * (on.r - off.r) + 0.7152 * (on.g - off.g) + 0.0722 * (on.b - off.b)
        }
        // The centre engine on the stage's axis, among the four.
        let centre = ceco.chambers.reduce(Vec3.zero) { $0 + face($1) } / 4
        let outboard = ceco.chambers.map { glow(at: face($0)) }
        print(String(format: "ChamberGlowRenderTests: after CECO the centre throat's glow %.0f cd/m², the outboard's %@ "
                     + "(an engine gimballed off the line of sight hides its throat)", glow(at: centre),
                     outboard.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        let shown = outboard.filter { $0 > 1_000 }
        XCTAssertGreaterThanOrEqual(shown.count, 2, "the outboard engines glow on")
        XCTAssertLessThan(abs(glow(at: centre)), 0.02 * (shown.max() ?? 0), "the centre engine is off")
    }

    /// From the side the S-IVB's J-2, hanging below its aft skirt, shows no
    /// chamber glow on its outside (the throat cannot be seen through the
    /// exit beyond about 26° off the axis): p2-flight-s-ivb-burn's chase
    /// camera, some 68° off the engine's axis, 100 m out, where the glow
    /// pass's slope-scaled depth bias let the gas-side wall, 19 mm behind the
    /// outer one, through (496 cd/m² at the throat's pixel). Every pixel is
    /// the same with the glow and without it, within 1 % (or 5 cd/m²).
    func testNoGlowOnTheEnginesOutside() throws {
        let advance = ["ev:S-IVB ignition", "wait:30"]
        let side = SnapshotSpec.CameraSpec(yaw: 150, pitch: -12, distance: 100, fov: 50)
        let on = try render(advance, camera: side), off = try render(advance, glow: false, camera: side)
        let c = try XCTUnwrap(on.chambers.first)
        XCTAssertEqual(on.chambers.count, 1)
        let (col, row) = pixel(on, c.exit - c.axis * c.chamber.throatDepth)
        XCTAssertTrue(col > 0 && row > 0 && col < Double(on.width) && row < Double(on.height), "the J-2 is in the frame")
        var worst = (excess: -Double.infinity, d: 0.0, x: 0, y: 0)
        for i in stride(from: 0, to: on.light.count, by: 4) {
            func y(_ l: [Float]) -> Double {
                0.2126 * Double(l[i]) + 0.7152 * Double(l[i + 1]) + 0.0722 * Double(l[i + 2])
            }
            let d = abs(y(on.light) - y(off.light)), excess = d - max(0.01 * y(off.light), 5)
            if excess > worst.excess { worst = (excess, d, (i / 4) % on.width, (i / 4) / on.width) }
        }
        print(String(format: "ChamberGlowRenderTests: from the side the glow changes a pixel by at most %.1f cd/m² "
                     + "(at %d, %d; the throat projects to %.0f, %.0f)", worst.d, worst.x, worst.y, col, row))
        XCTAssertLessThanOrEqual(worst.excess, 0, "no glow on the engine's outside")
    }
}

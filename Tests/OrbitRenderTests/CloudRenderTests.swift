import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// Track C2's clouds on the GPU, against OrbitScene's maths: the noise
/// volumes against CloudNoise, the weather map against CloudWeatherMap's
/// mirror, the march on a homogeneous slab against the far LUT
/// (continuity of the regimes), the slot copy's depth cut, the shadow map,
/// the reprojection rules, and the uniforms' layout.
@MainActor
final class CloudRenderTests: XCTestCase {
    static var snapper: SnapshotRenderer?

    func snapper() throws -> SnapshotRenderer {
        if let s = Self.snapper { return s }
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        Self.snapper = s
        return s
    }

    /// Reads textures back after the scene (P4).
    final class Capture: RenderPass {
        let name = "Cloud capture"
        let stage = PassStage.post
        let order = 2_000
        var ids: [ResourceID] = [.cloudLayer, .cloudDepth, .cloudShadow, .halfResClouds, .halfResFronts]
        var images: [ResourceID: (width: Int, height: Int, format: MTLPixelFormat, buffer: MTLBuffer)] = [:]

        func encode(_ f: FrameContext, _ e: PassEncoding) {
            images = [:]
            guard let blit = f.makeBlitEncoder() else { return }
            for id in ids {
                guard let t = f.textures[id] else { continue }
                let bpp: Int
                switch t.pixelFormat {
                case .rgba32Float: bpp = 16
                case .rg32Float, .rgba16Float: bpp = 8
                case .rg16Float: bpp = 4
                case .r16Float: bpp = 2
                default: bpp = 4
                }
                guard let b = f.device.makeBuffer(length: t.width * t.height * bpp, options: .storageModeShared) else {
                    continue
                }
                blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: b, destinationOffset: 0,
                          destinationBytesPerRow: t.width * bpp, destinationBytesPerImage: t.width * t.height * bpp)
                images[id] = (t.width, t.height, t.pixelFormat, b)
            }
            blit.endEncoding()
        }

        /// The image's channels as Double, texel by texel (row-major).
        func values(_ id: ResourceID) -> (width: Int, height: Int, texels: [[Double]])? {
            guard let i = images[id] else { return nil }
            let n = i.width * i.height
            switch i.format {
            case .rgba32Float:
                let p = i.buffer.contents().bindMemory(to: Float.self, capacity: 4 * n)
                return (i.width, i.height, (0..<n).map { t in (0..<4).map { Double(p[4 * t + $0]) } })
            case .rgba16Float:
                let p = i.buffer.contents().bindMemory(to: UInt16.self, capacity: 4 * n)
                return (i.width, i.height, (0..<n).map { t in
                    (0..<4).map { Double(Float(Float16(bitPattern: p[4 * t + $0]))) }
                })
            case .rg16Float:
                let p = i.buffer.contents().bindMemory(to: UInt16.self, capacity: 2 * n)
                return (i.width, i.height, (0..<n).map { t in
                    (0..<2).map { Double(Float(Float16(bitPattern: p[2 * t + $0]))) }
                })
            default:
                return nil
            }
        }
    }

    struct Frame {
        let pixels: [UInt8]
        let capture: Capture
        let scene: RenderScene
        let renderer: SceneRenderer
        @MainActor var clouds: CloudPass? { renderer.graph.pass(named: "Clouds") as? CloudPass }
    }

    /// Renders `shot` with the default passes and a capture after them;
    /// `frames` frames, the scene's clock advanced by `step` real seconds
    /// each (the history's reprojection).
    func render(_ shot: SnapshotSpec.Shot, frames: Int = 1) throws -> Frame {
        let s = try snapper()
        let prepared = try shot.prepare(system: s.system)
        let capture = Capture()
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [capture],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.setStars(s.stars)
        r.settings = shot.settings
        XCTAssertEqual(r.failures.filter { $0.key.contains("Cloud") }, [:])
        XCTAssertEqual(r.graph.passes.compactMap { $0 as? HalfResTransparentPass }.first?.effectFailures, [:])
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
        var scene = shot.scene(prepared)
        for k in 0..<frames {
            scene.clock.frameIndex = k + 1
            scene.clock.temporalReset = k == 0
            let cb = try XCTUnwrap(r.renderAndWait(scene, into: target))
            XCTAssertNil(cb.error)
        }
        return Frame(pixels: target.bytes(), capture: capture, scene: scene, renderer: r)
    }

    static func slabShot(regime: String, width: Int = 160, height: Int = 100) -> SnapshotSpec.Shot {
        var shot = SnapshotSpec.Shot(name: "c2-slab", scenario: "as506-parking-orbit",
                                     camera: SnapshotSpec.CameraSpec(yaw: -34.4, pitch: 30, distance: 70, fov: 60))
        shot.width = width
        shot.height = height
        shot.showOrbit = false
        shot.settings.cloud.lookDev = CloudSettings.LookDevSlab(cover: 1, opticalDepth: 20)
        shot.settings.cloud.regime = regime
        shot.settings.post.exposure.mode = .manual
        shot.settings.post.exposure.ev100 = 14
        return shot
    }

    /// The far layer and the march at single texels of the slab against
    /// CloudSlab.march on the CPU with A1's air: the far surface layer is
    /// the LUT of that march, the march the march itself.
    func testSlabTexelsAgainstTheSwiftMarch() throws {
        for regime in ["far", "march"] {
            let f = try render(Self.slabShot(regime: regime))
            let report = try XCTUnwrap(f.clouds?.lastFrame)
            let frame = try XCTUnwrap(report.frame)
            let c = try XCTUnwrap(f.capture.values(.cloudLayer))
            let cam = f.scene.camera
            let slab = CloudSlab(thickness: 1_500)
            let air = CloudTables.air
            var ratios: [Double] = []
            for (x, y) in [(c.width / 2, c.height / 2), (c.width / 4, 3 * c.height / 4), (3 * c.width / 4, c.height / 2)] {
                let t = c.texels[y * c.width + x]
                guard t[3] > 0.99 else { continue }
                // The texel's ray, body axes.
                let px = (Double(x) + 0.5) * Double(report.scale), py = (Double(y) + 0.5) * Double(report.scale)
                let tanY = tan(cam.fovY / 2)
                let vr = Vec3((2 * px / cam.viewport.width - 1) * tanY * cam.aspect, (1 - 2 * py / cam.viewport.height) * tanY, -1)
                let w = (cam.worldToView.transposed * vr).normalized
                let d = frame.icrfToBody * w
                // The slab's top, 2,500 m, on the figure's sphere.
                let o = frame.cameraFigure, df = Vec3(d.x, d.y, d.z * frame.stretch)
                let r = frame.radius + 2_500
                let b = o.dot(df), a = df.dot(df), cc = o.lengthSquared - r * r
                let hit = (-b - (b * b - a * cc).squareRoot()) / a
                let pf = o + df * hit
                let up = Vec3(pf.x, pf.y, pf.z * frame.stretch).normalized
                let mu = -d.dot(up), mu0 = frame.sunBody.dot(up), cosTheta = d.dot(frame.sunBody)
                let m = slab.march(opticalDepth: 20, mu0: mu0, mu: mu)
                let sun = air.transmittanceToSun(radius: air.bottomRadius + 2_500, cosSun: mu0)
                let sky = air.skyIrradiance(radius: air.bottomRadius + 2_500, cosSun: mu0)
                let g = Double(report.sunLight.y)
                let expected = g * (sun.g * (m.single * slab.lighting.mie.phase(cosTheta) + m.sunDiffuse) + sky.g * m.sky)
                ratios.append(t[1] / expected)
                print("\(regime) texel (\(x), \(y)): μ \(mu) μ0 \(mu0) cosθ \(cosTheta): GPU \(t[1]) Swift \(expected)")
            }
            XCTAssertFalse(ratios.isEmpty)
            for q in ratios { XCTAssertEqual(q, 1, accuracy: regime == "far" ? 0.02 : 0.04, regime) }
        }
    }

    /// The regimes agree on a homogeneous slab: the march's and the far
    /// LUT's radiance over the same view, texel by texel where both cover.
    func testMarchMatchesTheFarLUTOnASlab() throws {
        let march = try render(Self.slabShot(regime: "march"))
        let far = try render(Self.slabShot(regime: "far"))
        let a = try XCTUnwrap(march.capture.values(.cloudLayer)), b = try XCTUnwrap(far.capture.values(.cloudLayer))
        var sa = [0.0, 0.0, 0.0], sb = [0.0, 0.0, 0.0], n = 0, worst = 0.0
        for (x, y) in zip(a.texels, b.texels) where x[3] > 0.99 && y[3] > 0.99 {
            for k in 0..<3 {
                sa[k] += x[k]
                sb[k] += y[k]
            }
            worst = max(worst, abs(x[1] - y[1]) / max(y[1], 1e-6))
            n += 1
        }
        XCTAssertGreaterThan(n, a.texels.count / 3)
        print("slab march/far:", (0..<3).map { sa[$0] / sb[$0] }, "worst texel", worst, "texels", n)
        for k in 0..<3 { XCTAssertEqual(sa[k] / sb[k], 1, accuracy: 0.03, "channel \(k)") }
        XCTAssertLessThan(worst, 0.08, "the worst texel")
    }
}

/// Track C2's GPU cost (ORBITSIM_CLOUD_COST=1, holding the GPU lock): the
/// cloud pass alone against empty frames at 3024×1964, back to back and
/// interleaved, three in flight, the difference of the medians of
/// gpuEndTime − gpuStartTime; in the steady state (reprojecting) and fresh
/// (every texel marched, as at 10× warp).
@MainActor
final class CloudCostTests: XCTestCase {
    func testCostReport() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST"] != nil else {
            throw XCTSkip("set ORBITSIM_CLOUD_COST=1 to measure")
        }
        let lock = GPULock { print("waiting for the GPU lock") }
        defer { _ = lock }
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let shots: [(String, String, SnapshotSpec.CameraSpec, [String])] = [
            ("pad", "as506-pad", SnapshotSpec.CameraSpec(yaw: -60, pitch: 12, distance: 300, fov: 60), []),
            ("ascent-60s", "as506-pad", SnapshotSpec.CameraSpec(yaw: 149, pitch: -25, distance: 400, fov: 60), ["met:60"]),
            ("leo", "as506-parking-orbit", SnapshotSpec.CameraSpec(yaw: -34.4, pitch: 30, distance: 70, fov: 60), []),
            ("earth", "as506-parking-orbit",
             SnapshotSpec.CameraSpec(target: "body:399", frame: "inertial", yaw: 223.5, pitch: 22.9, distance: 22_000_000), []),
        ]
        let filter = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST_SHOTS"].map { $0.split(separator: ",").map(String.init) }
        for (name, scenario, camera, advance) in shots where filter?.contains(name) ?? true {
            var shot = SnapshotSpec.Shot(name: name, scenario: scenario, advance: advance, camera: camera)
            shot.width = 3024
            shot.height = 1964
            shot.showOrbit = false
            let prepared = try shot.prepare(system: s.system)
            let base = shot.scene(prepared)
            for warp in [1.0, 10.0] {
                // One renderer, one queue: the clouds on and off on alternate
                // frames (separate queues' command buffers overlap on the GPU).
                let clouds = CloudPass()
                let a = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: [clouds],
                                          plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
                var on = a.settings, off = a.settings
                off.cloud.enabled = false
                if let json = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_SETTINGS"] {
                    on.cloud = try JSONDecoder().decode(CloudSettings.self, from: Data(json.utf8))
                }
                if let skip = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_SKIP"] {
                    on.cloud.skip = skip.split(separator: ",").map(String.init)
                }
                let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
                final class Times: @unchecked Sendable {
                    let lock = NSLock()
                    var a: [Double] = [], b: [Double] = []
                }
                let times = Times()
                var last: MTLCommandBuffer?
                var reprojected = false
                for k in 0..<240 {
                    var scene = base
                    scene.clock.frameIndex = k / 2 + 1
                    scene.clock.temporalReset = k == 0
                    scene.clock.warp = warp
                    let measure = k >= 40, isOn = k % 2 == 0
                    a.settings = isOn ? on : off
                    last = a.render(scene, to: target.texture) { cb in
                        guard measure else { return }
                        times.lock.withLock {
                            if isOn { times.a.append(cb.gpuEndTime - cb.gpuStartTime) } else { times.b.append(cb.gpuEndTime - cb.gpuStartTime) }
                        }
                    }
                    if isOn { reprojected = clouds.lastFrame.reprojected }
                }
                last?.waitUntilCompleted()
                Thread.sleep(forTimeInterval: 0.2)
                func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
                let cost = (median(times.a) - median(times.b)) * 1_000
                print(String(format: "clouds %@ %@: %.2f ms (frame %.2f, empty %.2f; reprojected %@)", name,
                             warp >= 10 ? "fresh" : "steady", cost, median(times.a) * 1_000, median(times.b) * 1_000,
                             "\(reprojected)"))
            }
        }
    }
}

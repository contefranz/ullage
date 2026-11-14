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

    /// The clouds reach the frame on its first render (R6 plans its slots
    /// before P0 runs), in either regime, over R6's look-dev backdrop.
    func testCloudsDrawnOnTheFirstFrame() throws {
        for regime in ["march", "far"] {
            var shot = Self.slabShot(regime: regime, width: 160, height: 100)
            shot.settings.transparency.testBackdrop = true
            let f = try render(shot)
            let lit = stride(from: 0, to: f.pixels.count, by: 4).filter { f.pixels[$0] > 40 }.count
            XCTAssertGreaterThan(lit, f.pixels.count / 4 / 3, regime)
        }
    }

    func testDebugSeam() throws {
        guard ProcessInfo.processInfo.environment["C2_SEAM"] != nil else { throw XCTSkip("debug") }
        var shot = SnapshotSpec.Shot(name: "seam", scenario: "as506-parking-orbit", advance: ["wait:900"],
                                     camera: SnapshotSpec.CameraSpec(yaw: 180, pitch: 12, distance: 70, fov: 70))
        shot.showOrbit = false
        let f = try render(shot)
        let frame = try XCTUnwrap(f.clouds?.lastFrame.frame)
        let cam = f.scene.camera
        let weather = CloudWeather.mission("apollo11")
        let c = try XCTUnwrap(f.capture.values(.halfResClouds))
        for x in stride(from: 290, through: 330, by: 4) {
            let px = Double(x) + 0.5, py = 300.5
            let tanY = tan(cam.fovY / 2)
            let vr = Vec3((2 * px / cam.viewport.width - 1) * tanY * cam.aspect, (1 - 2 * py / cam.viewport.height) * tanY, -1)
            let d = frame.icrfToBody * (cam.worldToView.transposed * vr).normalized
            let o = frame.cameraBody
            let r = frame.radius + 2_000
            let b = o.dot(d), cc = o.lengthSquared - r * r
            let disc = b * b - cc
            guard disc > 0 else { continue }
            let p = o + d * (-b - disc.squareRoot())
            let g = Ellipsoid.wgs84.geodetic(p)
            let w = weather.sample(latitude: g.latitude, longitude: g.longitude, at: f.scene.clock.simTime)
            let t = c.texels[(Int(py) / 2) * c.width + x / 2]
            print(String(format: "SEAM x %d lat %.3f lon %.3f low %.2f mid %.2f high %.2f | alpha %.3f", x,
                         g.latitude * 180 / .pi, g.longitude * 180 / .pi, w.low, w.mid, w.high, t[3]))
        }
    }

    /// The far layer and the march at single texels of the slab against
    /// CloudSlab.march on the CPU with A1's air: the far surface layer is
    /// the LUT of that march, the march the march itself.
    func testSlabTexelsAgainstTheSwiftMarch() throws {
        for regime in ["far", "march"] {
            let f = try render(Self.slabShot(regime: regime))
            let report = try XCTUnwrap(f.clouds?.lastFrame)
            let frame = try XCTUnwrap(report.frame)
            let c = try XCTUnwrap(f.capture.values(.halfResClouds))
            let cam = f.scene.camera
            let slab = CloudSlab(thickness: 1_500)
            let air = CloudTables.air
            var ratios: [Double] = []
            for (x, y) in [(c.width / 2, c.height / 2), (c.width / 4, 3 * c.height / 4), (3 * c.width / 4, c.height / 2)] {
                let t = c.texels[y * c.width + x]
                guard t[3] > 0.99 else { continue }
                // The texel's ray, body axes.
                let px = (Double(x) + 0.5) * 2, py = (Double(y) + 0.5) * 2
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
        // R6's clouds layer: what the slot copy draws, the far layer and the
        // cirrus at R6's resolution over the march.
        let a = try XCTUnwrap(march.capture.values(.halfResClouds)), b = try XCTUnwrap(far.capture.values(.halfResClouds))
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
                // ORBITSIM_CLOUD_COST_FULL: every default pass, so the
                // difference holds the slot copy and R6's slots too.
                let full = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST_FULL"] != nil
                let passes = full ? SceneRenderer.defaultPasses(loadsUserTextures: false) : [CloudPass()]
                let clouds = try XCTUnwrap(passes.compactMap { $0 as? CloudPass }.first)
                let a = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                          plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
                a.setStars(s.stars)
                var on = a.settings, off = a.settings
                off.cloud.enabled = false
                if let json = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_SETTINGS"] {
                    on.cloud = try JSONDecoder().decode(CloudSettings.self, from: Data(json.utf8))
                }
                // ORBITSIM_CLOUD_COST_R6: R6's slots alone (a small test slab, no clouds), for their share.
                if ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST_R6"] != nil {
                    on.cloud.enabled = false
                    on.transparency.testEmitters = [EffectTestEmitter(.slab, position: [0, 0, 30], size: 2)]
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

/// Track C2's GPU volumes and maps against their Swift mirrors.
@MainActor
final class CloudMapTests: XCTestCase {
    /// Copies `texture` (any storage) into a shared buffer: slice 0, mip 0,
    /// every depth plane.
    static func readBack(_ texture: MTLTexture, bytesPerTexel: Int, device: MTLDevice) throws -> MTLBuffer {
        let rowBytes = texture.width * bytesPerTexel, image = rowBytes * texture.height
        let buffer = try XCTUnwrap(device.makeBuffer(length: image * texture.depth, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: texture.depth), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: image)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return buffer
    }

    /// Renders the LEO slab shot (or `shot`) with a fresh CloudPass and returns it.
    func render(_ shot: SnapshotSpec.Shot, configure: ((CloudPass) -> Void)? = nil) throws -> (CloudPass, SnapshotRenderer) {
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let prepared = try shot.prepare(system: s.system)
        let clouds = CloudPass()
        configure?(clouds)
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: [clouds],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.settings = shot.settings
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
        _ = r.renderAndWait(shot.scene(prepared), into: target)
        return (clouds, s)
    }

    /// The GPU's noise volumes are CloudNoise's texels, within a step of
    /// 8 bits and a half (Float against fast math).
    func testNoiseVolumesAreCloudNoise() throws {
        let (clouds, s) = try render(CloudRenderTests.slabShot(regime: "far"))
        let noise = try XCTUnwrap(clouds.noise)
        let shape = try Self.readBack(noise.shape, bytesPerTexel: 4, device: s.device)
        let detail = try Self.readBack(noise.detail, bytesPerTexel: 4, device: s.device)
        let curl = try Self.readBack(noise.curl, bytesPerTexel: 2, device: s.device)
        let n = CloudNoise.shapeSize, m = CloudNoise.detailSize, c = CloudNoise.curlSize
        let sp = shape.contents().bindMemory(to: UInt8.self, capacity: 4 * n * n * n)
        let dp = detail.contents().bindMemory(to: UInt8.self, capacity: 4 * m * m * m)
        let cp = curl.contents().bindMemory(to: Int8.self, capacity: 2 * c * c)
        var worst = 0
        for (x, y, z) in [(0, 0, 0), (127, 3, 64), (17, 99, 5), (64, 64, 127), (101, 12, 88)] {
            let t = CloudNoise.shapeTexel(x, y, z), at = 4 * ((z * n + y) * n + x)
            for (k, v) in [t.0, t.1, t.2, t.3].enumerated() {
                worst = max(worst, abs(Int(sp[at + k]) - Int(CloudNoise.unorm8(v))))
            }
        }
        for (x, y, z) in [(0, 0, 0), (31, 7, 16), (5, 30, 22)] {
            let t = CloudNoise.detailTexel(x, y, z), at = 4 * ((z * m + y) * m + x)
            for (k, v) in [t.0, t.1, t.2].enumerated() {
                worst = max(worst, abs(Int(dp[at + k]) - Int(CloudNoise.unorm8(v))))
            }
        }
        for (x, y) in [(0, 0), (127, 64), (33, 90)] {
            let t = CloudNoise.curlTexel(x, y), at = 2 * (y * c + x)
            worst = max(worst, abs(Int(cp[at]) - Int(CloudNoise.snorm8(t.0))), abs(Int(cp[at + 1]) - Int(CloudNoise.snorm8(t.1))))
        }
        XCTAssertLessThanOrEqual(worst, 1, "8-bit steps")
    }

    /// The GPU's weather map is CloudWeatherMap's mirror at the grid points,
    /// with the pad's override (the large-scale structure off).
    func testWeatherMapIsTheMirror() throws {
        // A field of three snapshots around the parking orbit's epoch,
        // pseudo-random, the cloud base missing in places, and an observed
        // sky at 0° N 0° E then.
        let epoch = VesselLibrary.apollo11Insertion
        let t0 = Int64(((epoch.julianDateUTC - 2_440_587.5) * 86_400).rounded()) - 1_800
        let planes = ["lcc", "mcc", "hcc", "cbh"].map { name in
            CloudField.Plane(name: name, columns: CloudWeatherMap.columns, rows: CloudWeatherMap.rows, offset: 0,
                             scale: name == "cbh" ? 60 : 1 / 254)
        }
        var state: UInt32 = 777
        func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state >> 8
        }
        let times = [t0, t0 + 3_600, t0 + 7_200]
        let snapshots = times.map { _ in
            planes.map { p in
                (0..<p.count).map { _ -> UInt8 in
                    let r = next()
                    return p.name == "cbh" ? (r % 5 == 0 ? 255 : UInt8(r % 120)) : UInt8(r % 255)
                }
            }
        }
        let field = try CloudField(data: CloudField.encode(planes: planes, utcSeconds: times, note: "test",
                                                           snapshots: snapshots))
        let override = CloudOverride(latitude: 0, longitude: 0, time: epoch,
                                     observation: CloudObservation(low: 0.3, mid: 0, high: 0.8, convective: true))
        let weather = CloudWeather(field: field, overrides: [override])
        var shot = CloudRenderTests.slabShot(regime: "far")
        shot.settings.cloud.lookDev = nil
        shot.settings.cloud.coverageModulation = 0
        let (clouds, s) = try render(shot) { $0.weatherOverride = weather }
        let report = clouds.lastFrame
        XCTAssertTrue(report.drawn)
        let map = try XCTUnwrap(clouds.weatherMap)
        let a = try Self.readBack(map.a, bytesPerTexel: 8, device: s.device)
        let b = try Self.readBack(map.b, bytesPerTexel: 4, device: s.device)
        let ap = a.contents().bindMemory(to: UInt16.self, capacity: 4 * CloudWeatherMap.columns * CloudWeatherMap.rows)
        let bp = b.contents().bindMemory(to: UInt16.self, capacity: 2 * CloudWeatherMap.columns * CloudWeatherMap.rows)
        let p = CloudWeatherMap.parameters(weather, at: try XCTUnwrap(report.epoch))
        XCTAssertNotNil(p.snapshots)
        let first = p.snapshots.map { CloudWeatherMap.interleaved(field, snapshot: $0.first) }
        let second = p.snapshots.map { CloudWeatherMap.interleaved(field, snapshot: $0.second) }
        func half(_ v: UInt16) -> Double { Double(Float(Float16(bitPattern: v))) }
        for r in [0, 100, 359, 360, 361, 600, 720] {
            for c in [0, 1, 321, 1000, 1439] {
                let e = CloudWeatherMap.texel(column: c, row: r, first: first, second: second, parameters: p)
                let at = r * CloudWeatherMap.columns + c
                XCTAssertEqual(half(ap[4 * at]), e.low, accuracy: 2e-3)
                XCTAssertEqual(half(ap[4 * at + 1]), e.mid, accuracy: 2e-3)
                XCTAssertEqual(half(ap[4 * at + 2]), e.high, accuracy: 2e-3)
                XCTAssertEqual(half(ap[4 * at + 3]), e.lowBase, accuracy: 2.5, "half floats: 2 m steps to 4 km")
                XCTAssertEqual(half(bp[2 * at]), e.lowTop, accuracy: 8)
            }
        }
    }

    /// A pseudo-random field of three hourly snapshots around the parking
    /// orbit's epoch.
    static func syntheticField(seed: UInt32) throws -> CloudField {
        let epoch = VesselLibrary.apollo11Insertion
        let t0 = Int64(((epoch.julianDateUTC - 2_440_587.5) * 86_400).rounded()) - 1_800
        let planes = ["lcc", "mcc", "hcc", "cbh"].map { name in
            CloudField.Plane(name: name, columns: CloudWeatherMap.columns, rows: CloudWeatherMap.rows, offset: 0,
                             scale: name == "cbh" ? 60 : 1 / 254)
        }
        var state = seed
        func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state >> 8
        }
        let times = [t0, t0 + 3_600, t0 + 7_200]
        let snapshots = times.map { _ in
            planes.map { p in (0..<p.count).map { _ in UInt8(next() % (p.name == "cbh" ? 120 : 255)) } }
        }
        return try CloudField(data: CloudField.encode(planes: planes, utcSeconds: times, note: "test",
                                                      snapshots: snapshots))
    }

    /// A pass that drew one mission's field and then another's, whose
    /// snapshots have the same indices, assembles the second's weather map
    /// as a fresh pass does (it once kept the first's snapshot textures).
    func testWeatherMapAfterAnotherMission() throws {
        let a = CloudWeather(field: try Self.syntheticField(seed: 777))
        let b = CloudWeather(field: try Self.syntheticField(seed: 4_242))
        var shot = CloudRenderTests.slabShot(regime: "far", width: 64, height: 40)
        shot.settings.cloud.lookDev = nil
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let prepared = try shot.prepare(system: s.system)
        func map(_ steps: [(String, CloudWeather)]) throws -> [UInt16] {
            let clouds = CloudPass()
            let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: [clouds],
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            r.settings = shot.settings
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
            for (name, weather) in steps {
                clouds.weatherOverride = weather
                clouds.weatherOverrideName = name
                _ = r.renderAndWait(shot.scene(prepared), into: target)
            }
            let m = try XCTUnwrap(clouds.weatherMap)
            let buffer = try Self.readBack(m.a, bytesPerTexel: 8, device: s.device)
            let n = 4 * CloudWeatherMap.columns * CloudWeatherMap.rows
            return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt16.self, capacity: n), count: n))
        }
        let fresh = try map([("b", b)])
        XCTAssertNotEqual(try map([("a", a)]), fresh, "the two fields differ")
        XCTAssertEqual(try map([("a", a), ("b", b)]), fresh)
    }

    /// The shadow map under the homogeneous slab: above the ground the
    /// slab's whole optical depth along the Sun, above 2 km a third of it,
    /// above 6 km none.
    func testShadowMapUnderTheSlab() throws {
        var shot = CloudRenderTests.slabShot(regime: "march")
        shot.scenario = "as506-pad"
        shot.camera = SnapshotSpec.CameraSpec(yaw: -60, pitch: 12, distance: 300, fov: 60)
        let (clouds, s) = try render(shot)
        let frame = try XCTUnwrap(clouds.lastFrame.frame)
        let map = try XCTUnwrap(clouds.shadowTexture)
        let buffer = try Self.readBack(map, bytesPerTexel: 8, device: s.device)
        let p = buffer.contents().bindMemory(to: UInt16.self, capacity: 4 * map.width * map.height)
        let at = 4 * ((map.height / 2) * map.width + map.width / 2)
        func half(_ v: UInt16) -> Double { Double(Float(Float16(bitPattern: v))) }
        let up = frame.cameraBody.normalized
        let mu0 = frame.sunBody.dot(up)
        let full = 20 / mu0
        XCTAssertEqual(half(p[at]), full, accuracy: 0.05 * full, "above the ground")
        XCTAssertEqual(half(p[at + 1]), full / 3, accuracy: 0.1 * full / 3, "above 2 km")
        XCTAssertEqual(half(p[at + 2]), 0, accuracy: 1e-3, "above 6 km")
    }

    /// The cloud-shadow header compiles in another module and gives 1 with
    /// no clouds (AtmosphereUniforms' cloud layer off).
    func testCloudShadowHeader() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "CloudShadowUse", headers: [.cloudShadow], source: """
            kernel void cloud_shadow_use(device float *out [[buffer(0)]],
                                         constant AtmosphereUniforms &a [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                         texture2d<float> map [[texture(ORBIT_TEXTURE_CLOUD_SHADOW)]],
                                         sampler s [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
                out[0] = orbit_cloudSunTransmittance(float3(0.0, 0.0, -100.0), a, map, s);
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        XCTAssertNotNil(library.makeFunction(name: "cloud_shadow_use"))
    }

    /// The cloud uniforms' Swift mirrors have MSL's sizes.
    func testStructLayoutsMatchMSL() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "CloudSizes", headers: [.effectSlots], source: cloudShaderSource + """
            kernel void cloud_sizes(device uint *out [[buffer(0)]]) {
                out[0] = sizeof(CloudUniforms);
                out[1] = sizeof(CloudWeatherParams);
                out[2] = sizeof(CloudResolveUniforms);
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "cloud_sizes")))
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
        XCTAssertEqual(Int(v[0]), MemoryLayout<CloudUniforms>.stride)
        XCTAssertEqual(Int(v[1]), MemoryLayout<CloudWeatherParams>.stride)
        XCTAssertEqual(Int(v[2]), MemoryLayout<CloudResolveUniforms>.stride)
    }
}

/// Apollo 8's orbit by day (ORBITSIM_CLOUD_SHOTS=<dir>): the pad and the
/// ascent are orbitsnap's (`apollo8-pad`, c2-scenes.json), but a parking
/// orbit on Apollo 8's day is M2's, so this puts a capsule in a 185 km orbit
/// in daylight an hour after AS-503's launch (the terminator is Apollo
/// 11's, c2-scenes.json),
/// and renders them as orbitsnap does (auto exposure, settled), with
/// Apollo 8's ERA5 field when it is fetched.
@MainActor
final class CloudApollo8Shots: XCTestCase {
    struct Shot {
        var name: String
        var build: (SolarSystem) throws -> Simulation
        var advance: [String] = []
        var missionClockZero: Epoch?
        var camera: SnapshotSpec.CameraSpec
        var warp = 1.0
    }

    static let launch = Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51)

    /// A capsule in a 185 km orbit at 32.5° an hour after launch, its
    /// ascending node towards the Sun (RA about 270° at the December
    /// solstice), `latitudeArgument` degrees along from it.
    static func orbit(latitudeArgument: Double) -> (SolarSystem) -> Simulation {
        { system in
            let sim = Simulation(system: system, time: Epoch(utcYear: 1968, month: 12, day: 21, hour: 13, minute: 51))
            let capsule = VesselLibrary.capsule()
            sim.add(capsule)
            sim.placeInCircularOrbit(capsule, around: system.earth, altitude: 185_000, inclination: 32.5,
                                     ascendingNode: 270, argumentOfLatitude: latitudeArgument)
            sim.paused = true
            return sim
        }
    }

    func testApollo8Shots() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_SHOTS"] else {
            throw XCTSkip("set ORBITSIM_CLOUD_SHOTS=<dir> to render Apollo 8's skies")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let shots: [Shot] = [
            Shot(name: "a8-leo-day", build: Self.orbit(latitudeArgument: 10), camera: .init(yaw: -34, pitch: 25, distance: 60, fov: 60)),
        ]
        let width = 1280, height = 800
        let viewport = RenderScene.Viewport(width: Double(width), height: Double(height), pointScale: 2)
        var written: [String] = []
        for shot in shots {
            let sim = try shot.build(s.system)
            try ScenarioScript(shot.advance).run(on: sim, missionClockZero: shot.missionClockZero)
            sim.paused = true
            var camera = OrbitCamera()
            try shot.camera.apply(to: &camera, sim: sim)
            let extractor = SceneExtractor()
            let scene = extractor.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0,
                                          options: SceneExtractor.Options(showOrbit: false))
            let r = try s.renderer(userTextures: false)
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: width, height: height))
            // As orbitsnap: snap the exposure, then let it settle.
            r.post?.control.reset()
            var adapting = scene
            adapting.clock.realDt = 0.5
            for i in 0..<24 { _ = r.renderAndWait(i <= 2 ? scene : adapting, into: target) }
            _ = r.renderAndWait(scene, into: target)
            let url = out.appendingPathComponent(shot.name + ".png")
            try ImageFiles.writePNG(target.bytes(), width: width, height: height, order: .bgra, to: url)
            let clouds = r.graph.passes.compactMap { $0 as? CloudPass }.first
            print("APOLLO8 \(shot.name): \(sim.time) mission \(clouds?.lastFrame.mission ?? "none") drawn \(clouds?.lastFrame.drawn ?? false)")
            written.append(url.path)
        }
        XCTAssertEqual(written.count, shots.count)
    }
}

/// The clouds over a flight at 1×, 10× and 1000× warp (ORBITSIM_CLOUD_SHOTS
/// =<dir>): the parking orbit stepped as the app steps it, 1/60 s of wall
/// clock a frame, each frame extracted and rendered by one renderer, so the
/// history, the reprojection rule and the drift with the wind run as in
/// the app. Writes the last frame of each, and checks the rule.
@MainActor
final class CloudWarpFlights: XCTestCase {
    func testWarpFlights() throws {
        guard let dir = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_SHOTS"] else {
            throw XCTSkip("set ORBITSIM_CLOUD_SHOTS=<dir> to fly")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let width = 1280, height = 800
        let viewport = RenderScene.Viewport(width: Double(width), height: Double(height), pointScale: 2)
        for warp in [1.0, 10.0, 1000.0] {
            let scenario = try XCTUnwrap(Scenario.named("as506-parking-orbit"))
            let sim = scenario.build(s.system)
            sim.paused = false
            sim.warp = warp
            var camera = OrbitCamera()
            try SnapshotSpec.CameraSpec(yaw: -34.4, pitch: 30, distance: 70, fov: 60).apply(to: &camera, sim: sim)
            let extractor = SceneExtractor()
            let r = try s.renderer(userTextures: false)
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: width, height: height))
            let clouds = try XCTUnwrap(r.graph.passes.compactMap { $0 as? CloudPass }.first)
            var reprojected = 0
            let frames = 90
            for k in 0..<frames {
                if k > 0 { sim.advance(by: 1.0 / 60) }
                camera.update(sim: sim)
                let scene = extractor.extract(sim: sim, camera: camera, viewport: viewport, realTime: Double(k) / 60,
                                              options: SceneExtractor.Options(showOrbit: false))
                XCTAssertEqual(scene.clock.warp, warp)
                _ = r.renderAndWait(scene, into: target)
                if clouds.lastFrame.reprojected { reprojected += 1 }
            }
            try ImageFiles.writePNG(target.bytes(), width: width, height: height, order: .bgra,
                                    to: out.appendingPathComponent("warp-\(Int(warp))x.png"))
            print(String(format: "WARP %4.0fx: %d of %d frames reprojected, motion %.2f px", warp, reprojected, frames,
                         clouds.lastFrame.motionPixels))
            if warp >= CloudReprojection.maximumWarp {
                XCTAssertEqual(reprojected, 0, "no reprojection at \(warp)×")
            } else {
                XCTAssertGreaterThan(reprojected, frames / 2, "reprojecting at \(warp)×")
            }
        }
    }
}

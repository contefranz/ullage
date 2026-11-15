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
    func render(_ shot: SnapshotSpec.Shot, frames: Int = 1, weather: CloudWeather? = nil) throws -> Frame {
        let s = try snapper()
        let prepared = try shot.prepare(system: s.system)
        let capture = Capture()
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [capture],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.setStars(s.stars)
        r.settings = shot.settings
        if let weather { (r.graph.pass(named: "Clouds") as? CloudPass)?.weatherOverride = weather }
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
        // The slab alone: no air between it and the camera (A2's aerial
        // perspective is the same for the march and the far layer).
        shot.settings.atmosphere.enabled = false
        return shot
    }

    /// A field of one uniform sky around the parking orbit's epoch: the low,
    /// mid and high covers, the cloud base 1,000 m up.
    static func uniformWeather(low: Double, mid: Double = 0, high: Double = 0, eastWind: Double = 0,
                               northWind: Double = 0, epoch: Epoch = VesselLibrary.apollo11Insertion,
                               overrides: [CloudOverride] = []) throws -> CloudWeather {
        let t0 = Int64(((epoch.julianDateUTC - 2_440_587.5) * 86_400).rounded())
        let names = ["lcc", "mcc", "hcc", "cbh", "u850", "v850", "u500", "v500", "u250", "v250"]
        let planes = names.map { name in
            CloudField.Plane(name: name, columns: CloudWeatherMap.columns, rows: CloudWeatherMap.rows,
                             offset: name.hasPrefix("u") || name.hasPrefix("v") ? -50 : 0,
                             scale: name == "cbh" ? 60 : (name.hasPrefix("u") || name.hasPrefix("v") ? 0.5 : 1 / 254))
        }
        let east = UInt8(((eastWind + 50) / 0.5).rounded()), north = UInt8(((northWind + 50) / 0.5).rounded())
        let values: [UInt8] = [UInt8((low * 254).rounded()), UInt8((mid * 254).rounded()),
                               UInt8((high * 254).rounded()), 17, east, north, east, north, east, north]
        let snapshot = zip(planes, values).map { p, v in [UInt8](repeating: v, count: p.count) }
        let field = try CloudField(data: CloudField.encode(planes: planes, utcSeconds: [t0 - 86_400, t0 + 86_400],
                                                           note: "uniform", snapshots: [snapshot, snapshot]))
        return CloudWeather(field: field, overrides: overrides)
    }

    /// LEO, the camera on the stack looking down across a broken deck.
    static func deckShot(regime: String = "auto", width: Int = 160, height: Int = 100) -> SnapshotSpec.Shot {
        var shot = slabShot(regime: regime, width: width, height: height)
        shot.settings.cloud.lookDev = nil
        shot.settings.cloud.coverageModulation = 0
        return shot
    }

    /// The march and the far layer draw a broken deck alike: the march's
    /// in-cloud extinction is C1's and the far layer's optical depth is the
    /// one that reflects as the march's columns do (CloudCoverage). Before,
    /// the march's clouds were 5-10 times thinner than C1's and the far
    /// layer 1.5-5 times brighter at the hand-over.
    func testMarchAndFarAgreeOnABrokenDeck() throws {
        for cover in [0.3, 0.7] {
            let weather = try Self.uniformWeather(low: cover)
            let march = try XCTUnwrap(render(Self.deckShot(regime: "march"), weather: weather).capture.values(.halfResClouds))
            let far = try XCTUnwrap(render(Self.deckShot(regime: "far"), weather: weather).capture.values(.halfResClouds))
            var sums = (march: 0.0, far: 0.0, alphaMarch: 0.0, alphaFar: 0.0), n = 0
            for (m, f) in zip(march.texels, far.texels) where f[3] > 0.01 {
                sums.march += m[1]
                sums.far += f[1]
                sums.alphaMarch += m[3]
                sums.alphaFar += f[3]
                n += 1
            }
            XCTAssertGreaterThan(n, march.texels.count / 4, "the deck fills the view's lower part")
            XCTAssertEqual(sums.far / sums.march, 1, accuracy: 0.25, "the deck's radiance at cover \(cover)")
            // An oblique view through a broken deck sees more cloud than its
            // cover, which the far layer (cover times the slab) does not.
            XCTAssertEqual(sums.alphaFar / sums.alphaMarch, 1, accuracy: 0.3, "its opacity at cover \(cover)")
        }
    }

    /// The cirrus draws its cover: 4/10 cirrus seen from orbit has 4/10 of
    /// the deck's opacity. Cut with the shape's thresholds it drew none.
    func testCirrusDrawsItsCover() throws {
        let weather = try Self.uniformWeather(low: 0, high: 0.4)
        var shot = Self.deckShot()
        shot.camera = SnapshotSpec.CameraSpec(target: "body:399", frame: "inertial", yaw: 223.5, pitch: 22.9,
                                              distance: 6_700_000, fov: 6)
        let c = try XCTUnwrap(render(shot, weather: weather).capture.values(.halfResClouds))
        // At this footprint (650 m) the fibres have averaged out: everywhere
        // 4/10 of the deck at its in-cloud optical depth, C1's through 1.8 km.
        let tau = CloudLayerModel.layers(CloudSample(low: 0, mid: 0, high: 1))[2].extinction * CloudPass.cirrusThickness
        let mean = c.texels.map { $0[3] }.reduce(0, +) / Double(c.texels.count)
        XCTAssertEqual(mean, 0.4 * (1 - exp(-tau)), accuracy: 0.2 * 0.4 * (1 - exp(-tau)))
    }

    /// The cirrus's opacity over a view is the same whatever the footprint:
    /// fibres at 0.2 km, their blend with the deck's mean at 0.3 km (the
    /// middle of the hand-over), the mean at 0.9-6 km. Sampled at coarser mips the fibres vanished at 0.5-2.5 km
    /// footprints (their thresholds are mip 0's), and blending depth and
    /// cover apart overshot the deck's opacity 3-6 times at low cover.
    func testCirrusOpacityHoldsAcrossFootprints() throws {
        // 1104 x 690 at fov 20: 320-360 m, the middle of the hand-over (128-512 m).
        for (cover, sizes) in [(0.5, [(1_600, 1_000), (1_104, 690), (400, 250), (160, 100), (64, 40)]),
                               (0.1, [(1_104, 690), (400, 250), (160, 100), (64, 40)])] {
            let weather = try Self.uniformWeather(low: 0, high: cover)
            var means: [Double] = []
            for (w, h) in sizes {
                var shot = Self.deckShot(width: w, height: h)
                shot.camera = SnapshotSpec.CameraSpec(target: "body:399", frame: "inertial", yaw: 223.5, pitch: 22.9,
                                                      distance: 6_700_000, fov: 20)
                let c = try XCTUnwrap(render(shot, weather: weather).capture.values(.halfResClouds))
                means.append(c.texels.map { $0[3] }.reduce(0, +) / Double(c.texels.count))
            }
            let far = try XCTUnwrap(means.last)
            XCTAssertGreaterThan(far, 0.01, "cover \(cover)")
            for (m, (w, _)) in zip(means, sizes) {
                XCTAssertEqual(m / far, 1, accuracy: cover < 0.2 ? 0.35 : 0.25, "cover \(cover), \(w) px wide")
            }
        }
    }

    /// Through a cirrus re-anchor's fade (the high wind turned 90°) the
    /// cirrus keeps its opacity: the two frames' depths mix. Mixing their
    /// fibre values before the threshold thinned partial cirrus to
    /// 0.17-0.58 of its depth mid-fade.
    func testCirrusKeepsItsOpacityThroughAReAnchor() throws {
        // 3/10 cirrus, its fibres alone (130 m footprints).
        let east = try Self.uniformWeather(low: 0, high: 0.3, eastWind: 30)
        let north = try Self.uniformWeather(low: 0, high: 0.3, northWind: 30)
        var shot = Self.deckShot(width: 1_600, height: 1_000)
        shot.camera = SnapshotSpec.CameraSpec(target: "body:399", frame: "inertial", yaw: 223.5, pitch: 22.9,
                                              distance: 6_700_000, fov: 12)
        let s = try snapper()
        let prepared = try shot.prepare(system: s.system)
        let capture = Capture()
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [capture],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.settings = shot.settings
        let clouds = try XCTUnwrap(r.graph.pass(named: "Clouds") as? CloudPass)
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
        var scene = shot.scene(prepared)
        func mean(_ k: Int, _ w: CloudWeather, _ name: String, realDt: Double) throws -> Double {
            clouds.weatherOverride = w
            clouds.weatherOverrideName = name
            scene.clock.frameIndex = k
            scene.clock.realDt = realDt
            scene.clock.temporalReset = k == 1
            _ = r.renderAndWait(scene, into: target)
            let c = try XCTUnwrap(capture.values(.halfResClouds))
            return c.texels.map { $0[3] }.reduce(0, +) / Double(c.texels.count)
        }
        let a = try mean(1, east, "east", realDt: 0)
        let old = try mean(2, north, "north", realDt: 1)      // re-anchored: the old frame at full weight
        XCTAssertEqual(clouds.cirrus.fade, 1)
        let mid = try mean(3, north, "north", realDt: 1)      // halfway
        XCTAssertEqual(clouds.cirrus.fade, 0.5, accuracy: 1e-9)
        let new = try mean(4, north, "north", realDt: 2)      // the new frame alone
        XCTAssertEqual(clouds.cirrus.fade, 0)
        XCTAssertGreaterThan(a, 0.02)
        XCTAssertEqual(old / a, 1, accuracy: 0.1, "the old frame drawn as before")
        print("cirrus through a re-anchor: \(a), \(old), \(mid), \(new)")
        XCTAssertEqual(mid / (0.5 * (old + new)), 1, accuracy: 0.1, "halfway through the fade")
    }

    /// In the hand-over band the far layer's share shows where the march
    /// found no cloud: its depth is the far layer's there. Taking the
    /// march's (none) below a weight of 0.5 cut the far layer away in every
    /// gap, an edge across LEO views of broken cloud.
    func testHandOverKeepsTheFarLayerInTheGaps() throws {
        let weather = try Self.uniformWeather(low: 0.5)
        let march = try XCTUnwrap(render(Self.deckShot(regime: "march"), weather: weather).capture.values(.halfResClouds))
        let far = try XCTUnwrap(render(Self.deckShot(regime: "far"), weather: weather).capture.values(.halfResClouds))
        // A footprint band so wide the far layer's weight is about 0.16
        // everywhere (smoothstep at a quarter of the way).
        var shot = Self.deckShot()
        shot.settings.cloud.farFootprint = [-1e9, 3e9]
        let both = try XCTUnwrap(render(shot, weather: weather).capture.values(.halfResClouds))
        var gaps = 0, shown = 0
        for i in 0..<both.texels.count where march.texels[i][3] < 1e-3 && far.texels[i][3] > 0.05 {
            gaps += 1
            if both.texels[i][3] > 0.5 * 0.156 * far.texels[i][3] { shown += 1 }
        }
        XCTAssertGreaterThan(gaps, 50, "the deck is broken")
        // (The depth cut's extent, from the march's neighbours' entry, trims
        // a few; with the march's mean taken there none showed.)
        XCTAssertGreaterThan(Double(shown), 0.75 * Double(gaps), "the far layer's share in the march's gaps")
    }

    /// The shadow map takes the weather where each texel's Sun ray crosses
    /// the clouds. At Apollo 8's dawn (the Sun 7° up), under a full deck
    /// everywhere but a clear 25 km about the pad, every ray that crosses the
    /// deck more than 60 km from the pad is shaded. Read at the map's plane,
    /// near the pad for a low Sun, a strip of them was clear.
    func testShadowMapReadsTheWeatherAlongTheSun() throws {
        let pad = try XCTUnwrap(CloudOverride.launches["apollo8"])
        let clear = CloudOverride(latitude: pad.latitude, longitude: pad.longitude, time: pad.time,
                                  observation: CloudObservation(low: 0, mid: 0, high: 0))
        let weather = try Self.uniformWeather(low: 1, epoch: pad.time, overrides: [clear])
        var shot = SnapshotSpec.Shot(name: "a8-shadow", scenario: "apollo8-pad",
                                     camera: SnapshotSpec.CameraSpec(yaw: -100, pitch: 8, distance: 300, fov: 60))
        shot.width = 64
        shot.height = 40
        shot.showOrbit = false
        shot.settings.cloud.coverageModulation = 0
        let f = try render(shot, weather: weather)
        let frame = try XCTUnwrap(f.clouds?.lastFrame.frame)
        let c = try XCTUnwrap(f.capture.values(.cloudShadow))
        let map = frame.shadowMap(texels: c.width)
        XCTAssertLessThan(map.sun.dot(frame.cameraBody.normalized), 0.15, "the Sun is low")
        let ground = frame.cameraBody.normalized * frame.radius
        var far = 0, shaded = 0
        for y in 0..<c.height {
            for x in 0..<c.width {
                // Where the texel's line along the Sun is 1,750 m up.
                let mu = (Double(x) + 0.5) / Double(c.width), mv = (Double(y) + 0.5) / Double(c.height)
                let p0: Vec3 = map.point(u: mu, v: mv, along: 0)
                var lo = -2e6, hi = 2e6
                for _ in 0..<60 {
                    let m = 0.5 * (lo + hi)
                    if (p0 + map.sun * m).length - frame.radius > 1_750 { hi = m } else { lo = m }
                }
                let crossing = p0 + map.sun * lo
                guard (crossing - ground).length > 60_000, (crossing - ground).length < 400_000 else { continue }
                far += 1
                if c.texels[y * c.width + x][0] > 1 { shaded += 1 }
            }
        }
        XCTAssertGreaterThan(far, c.width * c.height / 8)
        XCTAssertGreaterThan(Double(shaded), 0.95 * Double(far))
    }

    /// The march's history is rescaled to this frame's pre-exposure: after
    /// the exposure jumps by 2 EV the reprojected clouds are what they are
    /// with the exposure there all along. Mixed unscaled, the marched texels
    /// came out at 5/8.
    func testResolveFollowsTheExposure() throws {
        let weather = try Self.uniformWeather(low: 0.6)
        var shot = Self.deckShot(regime: "march")
        shot.settings.post.exposure.ev100 = 14
        let s = try snapper()
        let prepared = try shot.prepare(system: s.system)
        func run(_ evs: [Double]) throws -> [[Double]] {
            let capture = Capture()
            let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                      passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [capture],
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            (r.graph.pass(named: "Clouds") as? CloudPass)?.weatherOverride = weather
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
            var scene = shot.scene(prepared)
            for (k, ev) in evs.enumerated() {
                var settings = shot.settings
                settings.post.exposure.ev100 = ev
                r.settings = settings
                scene.clock.frameIndex = k + 1
                scene.clock.temporalReset = k == 0
                _ = r.renderAndWait(scene, into: target)
            }
            XCTAssertEqual((r.graph.pass(named: "Clouds") as? CloudPass)?.lastFrame.reprojected, true)
            return try XCTUnwrap(capture.values(.cloudLayer)).texels
        }
        let jumped = try run([14, 14, 14, 14, 12]), steady = try run([12, 12, 12, 12, 12])
        let a = jumped.map { $0[1] }.reduce(0, +), b = steady.map { $0[1] }.reduce(0, +)
        XCTAssertGreaterThan(b, 0)
        XCTAssertEqual(a / b, 1, accuracy: 0.02)
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
            let air = try XCTUnwrap(AtmosphereTables.shared.tables(wait: true))
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
                // ORBITSIM_CLOUD_COST_NO_AIR: A2's atmosphere off in both frames.
                if ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST_NO_AIR"] != nil {
                    on.atmosphere.enabled = false
                    off.atmosphere.enabled = false
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

    /// The wind's drift goes on through a warp change (a temporal reset):
    /// it starts over only with a scene. Reset, every cloud jumped back by
    /// its whole drift when the warp key was pressed.
    func testAdvectionGoesOnThroughAWarpChange() throws {
        let weather = try CloudRenderTests.uniformWeather(low: 0.5, eastWind: 10)
        let shot = CloudRenderTests.deckShot()
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let prepared = try shot.prepare(system: s.system)
        let clouds = CloudPass()
        clouds.weatherOverride = weather
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: [clouds],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.settings = shot.settings
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
        var scene = shot.scene(prepared)
        scene.clock.paused = false
        func frame(_ k: Int, dt: Double, warp: Double, reset: Bool) {
            scene.clock.frameIndex = k
            scene.clock.simTime = scene.clock.simTime + dt
            scene.clock.simDt = dt
            scene.clock.warp = warp
            scene.clock.temporalReset = reset
            _ = r.renderAndWait(scene, into: target)
        }
        frame(1, dt: 0, warp: 60, reset: true)
        for k in 2...6 { frame(k, dt: 60, warp: 60, reset: false) }   // 300 s of a 10 m/s wind
        let before = clouds.advection.offsets[0]
        frame(7, dt: 600, warp: 600, reset: true)                     // the warp key
        let after = clouds.advection.offsets[0]
        let tile = FrameContext.noiseTile
        func centred(_ v: Vec3) -> Vec3 {
            func c(_ x: Double) -> Double { x - (x / tile).rounded() * tile }
            return Vec3(c(v.x), c(v.y), c(v.z))
        }
        let drift = centred(before), step = centred(after - before)
        XCTAssertEqual(drift.length, 3_000, accuracy: 1)
        XCTAssertEqual((step - drift * 2).length, 0, accuracy: 1, "600 s more of the same wind")
        // A new scene (the extractor's first frame) starts it over.
        frame(1, dt: 0, warp: 1, reset: true)
        XCTAssertEqual(clouds.advection.offsets[0].length, 0, accuracy: 1e-9)
    }

    /// The hand-over to the far layer is judged by R6's half-resolution
    /// texel whatever the march's scale, which no longer drops back at
    /// 3,000 km: neither moves the hand-over as the camera climbs (it went
    /// far, then march, then far again).
    func testHandOverIgnoresTheMarchScale() throws {
        XCTAssertEqual(CloudPass.marchScale(altitude: 2_999_000), CloudPass.marchScale(altitude: 3_001_000))
        var angles: [Double] = []
        for distance in [6_700_000.0, 9_300_000, 9_500_000] {   // 322, 2,920 and 3,120 km up
            var shot = CloudRenderTests.deckShot()
            shot.camera = SnapshotSpec.CameraSpec(target: "body:399", frame: "inertial", yaw: 223.5, pitch: 22.9,
                                                  distance: distance, fov: 60)
            let (clouds, _) = try render(shot)
            XCTAssertTrue(clouds.lastFrame.drawn)
            angles.append(clouds.lastFrame.footprintAngle)
        }
        XCTAssertEqual(angles[0], CloudPass.handOverPixelAngle(fovY: .pi / 3, viewportHeight: 100), accuracy: 1e-9)
        XCTAssertEqual(angles[1], angles[0], accuracy: 1e-9)
        XCTAssertEqual(angles[2], angles[0], accuracy: 1e-9)
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
        let module = ShaderModule(name: "CloudSizes", headers: [.effectSlots, .atmosphereCommon], source: cloudShaderSource + """
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

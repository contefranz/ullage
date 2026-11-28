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
        var ids: [ResourceID] = [.cloudLayer, .cloudDepth, .cloudShadow, .cloudSky, .halfResClouds, .halfResFronts]
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
    func render(_ shot: SnapshotSpec.Shot, frames: Int = 1, weather: CloudWeather? = nil,
                edit: ((inout RenderScene) -> Void)? = nil) throws -> Frame {
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
        edit?(&scene)
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
    /// mid and high covers, the cloud base `base` m up (ERA5's 60 m steps).
    static func uniformWeather(low: Double, mid: Double = 0, high: Double = 0, eastWind: Double = 0,
                               northWind: Double = 0, base: Double = 1_020, epoch: Epoch = VesselLibrary.apollo11Insertion,
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
                               UInt8((high * 254).rounded()), UInt8((base / 60).rounded()), east, north, east, north, east, north]
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

    /// The elevation (rad) above the camera's horizontal of the ray through
    /// each texel of a `width` × `height` target over the frame (row-major),
    /// and its angle from the nadir; the Earth a sphere about its centre.
    static func rayAngles(_ frame: Frame, width: Int, height: Int) throws -> [(elevation: Double, offNadir: Double)] {
        let cam = frame.scene.camera
        let earth = try XCTUnwrap(frame.scene.bodies.first { $0.id == AtmosphereFrame.planetID })
        let nadir = earth.position.normalized
        let viewToWorld = cam.worldToView.transposed
        let t = tan(cam.fovY / 2), aspect = Double(cam.viewport.width) / Double(cam.viewport.height)
        return (0..<width * height).map { k in
            let x = 2 * (Double(k % width) + 0.5) / Double(width) - 1, y = 1 - 2 * (Double(k / width) + 0.5) / Double(height)
            let d = (viewToWorld * Vec3(x * t * aspect, y * t, -1)).normalized
            return (-asin(max(-1, min(1, d.dot(nadir)))), acos(max(-1, min(1, d.dot(nadir)))))
        }
    }

    /// The pad, looking along the horizon past the stack (320 × 200, fov 30).
    static func padHorizonShot(regime: String, advance: [String] = []) -> SnapshotSpec.Shot {
        var shot = deckShot(regime: regime, width: 320, height: 200)
        shot.name = "c2-pad-horizon"
        shot.scenario = "as506-first-motion"
        shot.advance = advance
        shot.camera = SnapshotSpec.CameraSpec(yaw: -60, pitch: -3, distance: 300, fov: 30)
        return shot
    }

    /// The far layer holds the pad's horizon as C2's own field does. A slant
    /// ray crosses the deck over 50-150 km of cells there, so a broken deck
    /// is mostly opaque: the far layer's cover along the ray. C2's field
    /// integrated to convergence along these rays (the #73 review's port of
    /// cloud_density) is 0.73-0.85 opaque at 1/10 and 0.98-1.00 at 3/10; the
    /// march, its clear-air steps 4 km long out there, finds less. Before,
    /// the far layer drew the cover overhead (0.1 at 1/10).
    func testFarLayerHoldsThePadsHorizon() throws {
        for (cover, field) in [(0.1, 0.79), (0.3, 0.99)] {
            let weather = try Self.uniformWeather(low: cover)
            var alpha: [String: Double] = [:]
            for regime in ["march", "far"] {
                let frame = try render(Self.padHorizonShot(regime: regime), weather: weather)
                let c = try XCTUnwrap(frame.capture.values(.halfResClouds))
                let angles = try Self.rayAngles(frame, width: c.width, height: c.height)
                // 0.3-1.5° up, clear of the stack and the tower (the middle third).
                var sum = 0.0, n = 0
                for (k, texel) in c.texels.enumerated() {
                    let e = angles[k].elevation * 180 / .pi, x = k % c.width
                    guard e > 0.3, e < 1.5, x < c.width / 3 || x > 2 * c.width / 3 else { continue }
                    sum += texel[3]
                    n += 1
                }
                XCTAssertGreaterThan(n, 100, "the band is in view")
                alpha[regime] = sum / Double(max(n, 1))
            }
            let march = try XCTUnwrap(alpha["march"]), far = try XCTUnwrap(alpha["far"])
            print("pad horizon at cover \(cover): march \(march), far \(far)")
            XCTAssertGreaterThan(march, 2 * cover, "the march sees more than the cover along the horizon")
            XCTAssertGreaterThanOrEqual(far, march, "no thinner than the march")
            XCTAssertEqual(far, field, accuracy: 0.08, "the field's opacity at cover \(cover)")
        }
    }

    /// The far layers lie in front of the ground or not at all. From 2.9 km
    /// up the ascent, rays that meet the ground 85-150 km out drew the 4.5 km
    /// shell's far side beyond the Earth, seen from below; its mean pulled
    /// the depth cut past the ground and thinned the low layer in front.
    func testFarLayerStopsAtTheGround() throws {
        var alpha: [Double: Double] = [:]
        for mid in [0.0, 0.5] {
            let frame = try render(Self.padHorizonShot(regime: "far", advance: ["met:44"]),
                                   weather: try Self.uniformWeather(low: 0.3, mid: mid))
            let c = try XCTUnwrap(frame.capture.values(.halfResClouds))
            let angles = try Self.rayAngles(frame, width: c.width, height: c.height)
            var sum = 0.0
            for (k, texel) in c.texels.enumerated() where angles[k].elevation < -1.9 * .pi / 180 { sum += texel[3] }
            alpha[mid] = sum
        }
        let alone = try XCTUnwrap(alpha[0]), withMid = try XCTUnwrap(alpha[0.5])
        print("low layer under the horizon from 2.9 km: alone \(alone), with the mid layer \(withMid)")
        XCTAssertGreaterThan(alone, 1, "the low layer draws below the horizon")
        XCTAssertEqual(withMid / alone, 1, accuracy: 0.03, "the mid layer beyond the ground leaves it as it is")
    }

    /// The cirrus lies in front of the ground or not at all. From 2.9 km up
    /// the ascent, rays to the ground met the 10 km shell only beyond the
    /// Earth, and with the ground under the low clouds never cut (C2's slot)
    /// that cirrus showed behind them; on a day launch it is the night's, a
    /// dark veil over the clouds below the horizon.
    func testCirrusStopsAtTheGround() throws {
        var alpha: [Double: Double] = [:]
        for high in [0.0, 0.6] {
            let frame = try render(Self.padHorizonShot(regime: "far", advance: ["met:44"]),
                                   weather: try Self.uniformWeather(low: 0.3, high: high))
            let c = try XCTUnwrap(frame.capture.values(.halfResClouds))
            let angles = try Self.rayAngles(frame, width: c.width, height: c.height)
            var sum = 0.0
            for (k, texel) in c.texels.enumerated() where angles[k].elevation < -1.9 * .pi / 180 { sum += texel[3] }
            alpha[high] = sum
        }
        let alone = try XCTUnwrap(alpha[0]), withCirrus = try XCTUnwrap(alpha[0.6])
        print("low layer under the horizon from 2.9 km: alone \(alone), with cirrus \(withCirrus)")
        XCTAssertGreaterThan(alone, 1, "the low layer draws below the horizon")
        XCTAssertEqual(withCirrus / alone, 1, accuracy: 0.03, "the cirrus beyond the ground leaves it as it is")
    }

    /// The cirrus goes behind cloud tops above its 10 km shell. From orbit
    /// over a cumulonimbus deck (tops at 12 km, overcast), a cirrostratus at
    /// 10 km lies inside the towers, hidden: the towers' light is what it was
    /// without it. Ordered by the camera's height alone, it was laid over
    /// the tops, dimming them by about its opacity.
    func testCirrusGoesBehindTopsAboveIt() throws {
        let epoch = VesselLibrary.apollo11Insertion
        func towers(high: Double) throws -> Double {
            var storm = CloudOverride(latitude: 0, longitude: 0, time: epoch,
                                      observation: CloudObservation(low: 1, mid: 0, high: high, convective: true))
            storm.radius = 4e7
            let weather = try Self.uniformWeather(low: 1, high: high, overrides: [storm])
            let c = try XCTUnwrap(render(Self.deckShot(regime: "march"), weather: weather).capture.values(.halfResClouds))
            var sum = 0.0, n = 0
            for texel in c.texels where texel[3] > 0.9 {
                sum += 0.2126 * texel[0] + 0.7152 * texel[1] + 0.0722 * texel[2]
                n += 1
            }
            XCTAssertGreaterThan(n, c.texels.count / 2, "the towers fill the view")
            return sum / Double(max(n, 1))
        }
        let bare = try towers(high: 0), under = try towers(high: 1)
        print("cumulonimbus tops from orbit, with cirrostratus at 10 km / without: \(under / bare)")
        XCTAssertEqual(under / bare, 1, accuracy: 0.03)
    }

    /// The cirrus keeps its order through the far hand-over. Over the same
    /// cumulonimbus deck from orbit, the far layers draw the towers as their
    /// 2 km shell with the cirrus over it (regime "far", wf 1); just inside
    /// the hand-over (wf 0.998 everywhere: a far footprint ramp from −10⁹ to
    /// 2.66 × 10⁷ m) the towers under the cirrus are as bright. With one
    /// order for the blend, from the nearer entry, the march's tops above
    /// 10 km put the cirrus behind a colour 99.8 % the far deck's: a step at
    /// wf 1 of the cirrus's whole dimming (about half the light). (The bare
    /// deck's light differs by 3 % between the two renders by itself, so
    /// the test compares the light with the cirrus, not the ratio.)
    func testCirrusOrderHoldsThroughTheHandOver() throws {
        let epoch = VesselLibrary.apollo11Insertion
        func dimming(regime: String, farFootprint: [Double]? = nil) throws -> (with: Double, ratio: Double) {
            func towers(high: Double) throws -> Double {
                var storm = CloudOverride(latitude: 0, longitude: 0, time: epoch,
                                          observation: CloudObservation(low: 1, mid: 0, high: high, convective: true))
                storm.radius = 4e7
                var shot = Self.deckShot(regime: regime)
                if let farFootprint { shot.settings.cloud.farFootprint = farFootprint }
                let weather = try Self.uniformWeather(low: 1, high: high, overrides: [storm])
                let c = try XCTUnwrap(render(shot, weather: weather).capture.values(.halfResClouds))
                var sum = 0.0, n = 0
                for texel in c.texels where texel[3] > 0.9 {
                    sum += 0.2126 * texel[0] + 0.7152 * texel[1] + 0.0722 * texel[2]
                    n += 1
                }
                XCTAssertGreaterThan(n, c.texels.count / 2, "the towers fill the view")
                return sum / Double(max(n, 1))
            }
            let a = try towers(high: 1)
            return (a, a / (try towers(high: 0)))
        }
        let far = try dimming(regime: "far"), inside = try dimming(regime: "auto", farFootprint: [-1e9, 2.66e7])
        print("towers under cirrus (and / without), at wf 1: \(far), at wf 0.998: \(inside)")
        XCTAssertLessThan(far.ratio, 0.8, "the far deck under its cirrus")
        XCTAssertEqual(inside.with / far.with, 1, accuracy: 0.03)
    }

    /// C2's sky map holds the cover over each map line's two ground points.
    /// At Apollo 8's dawn launch (the Sun 8° up) with a clear sky 150 km
    /// round the pad (fading out to 300 km) in an overcast: lines that rise through the ground
    /// within 100 km of the pad have a clear sky there (x 1), and fall
    /// through it about 1,800 km west, in the night's overcast (y the
    /// overcast's slab transmittance for the sky's diffuse light,
    /// cloud_skyColumn's, here in Swift); lines that rise more than 380 km
    /// off have the overcast's in x. (The weather map's 27 km cells cannot
    /// hold a clear patch smaller than the clouds' offset along a low Sun,
    /// 10 km here, so this checks where the map reads the cover; that it is
    /// the cover overhead and not the Sun's line is the form of
    /// cloud_skyColumn, and testCloudShadowTakesTheSkysLightToo's twilight.)
    func testSkyMapHoldsTheCoverOverhead() throws {
        let pad = try XCTUnwrap(CloudOverride.launches["apollo8"])
        var clear = CloudOverride(latitude: pad.latitude, longitude: pad.longitude, time: pad.time,
                                  observation: CloudObservation(low: 0, mid: 0, high: 0))
        clear.radius = 300_000
        let weather = try Self.uniformWeather(low: 1, epoch: pad.time, overrides: [clear])
        var shot = SnapshotSpec.Shot(name: "a8-sky", scenario: "apollo8-first-motion",
                                     camera: SnapshotSpec.CameraSpec(yaw: -100, pitch: 8, distance: 300, fov: 60))
        shot.width = 64
        shot.height = 40
        shot.showOrbit = false
        shot.settings.cloud.coverageModulation = 0
        let f = try render(shot, weather: weather)
        let frame = try XCTUnwrap(f.clouds?.lastFrame.frame)
        let sky = try XCTUnwrap(f.capture.values(.cloudSky))
        let map = frame.shadowMap(texels: sky.width)
        let ground = frame.cameraBody.normalized * frame.radius
        let overcast = Self.skyTransmittance(low: 1)
        var near: [[Double]] = [], far: [Double] = []
        for y in 0..<sky.height {
            for x in 0..<sky.width {
                // Where the texel's line along the Sun rises through the ground.
                let mu = (Double(x) + 0.5) / Double(sky.width), mv = (Double(y) + 0.5) / Double(sky.height)
                let p0: Vec3 = map.point(u: mu, v: mv, along: 0)
                var lo = -2e6, hi = 2e6
                for _ in 0..<60 {
                    let m = 0.5 * (lo + hi)
                    if (p0 + map.sun * m).length - frame.radius > 0 { hi = m } else { lo = m }
                }
                // (Lines that pass over the ground hold their lowest point's
                // cover, not a ground point's; lines that graze it at under
                // 3° are left out: this test's sphere of the local radius and
                // the kernel's figure ellipsoid differ by kilometres in
                // radius, which moves a grazing line's ground point by tens
                // of km, or makes it miss.)
                let root = p0 + map.sun * lo
                guard abs(root.length - frame.radius) < 100, root.normalized.dot(map.sun) > 0.05 else { continue }
                let d = (p0 + map.sun * lo - ground).length, k = y * sky.width + x
                if d < 100_000 { near.append(sky.texels[k]) }
                if d > 380_000 { far.append(sky.texels[k][0]) }
            }
        }
        print("sky map: the overcast's \(overcast); within 100 km of the pad x \(near.map { $0[0] }.min() ?? -1)-"
              + "\(near.map { $0[0] }.max() ?? -1), y \(near.map { $0[1] }.min() ?? -1)-\(near.map { $0[1] }.max() ?? -1); "
              + "beyond 380 km x \(far.min() ?? -1)-\(far.max() ?? -1) (\(near.count), \(far.count) texels)")
        XCTAssertLessThan(overcast, 0.3)
        XCTAssertGreaterThan(near.count, sky.width * sky.height / 20)
        XCTAssertGreaterThan(far.count, 20)
        for t in near {
            XCTAssertGreaterThan(t[0], 0.98, "clear over the pad")
            XCTAssertEqual(t[1], overcast, accuracy: 0.02, "the overcast where the line falls")
        }
        for v in far { XCTAssertEqual(v, overcast, accuracy: 0.02) }
    }

    /// The sky map holds the cover through the terminator: with the Sun put
    /// 0.3° over the pad's horizon under a uniform overcast, every line of
    /// the map holds the overcast's in both channels, those that pass over
    /// the ground too (their lowest point's). A clear 1 there bled into the
    /// band of ground near tangency through the bilinear filter.
    func testSkyMapHoldsThroughTheTerminator() throws {
        let pad = try XCTUnwrap(CloudOverride.launches["apollo8"])
        let weather = try Self.uniformWeather(low: 1, epoch: pad.time)
        var shot = SnapshotSpec.Shot(name: "a8-tangent", scenario: "apollo8-pad",
                                     camera: SnapshotSpec.CameraSpec(yaw: -100, pitch: 8, distance: 300, fov: 60))
        shot.width = 64
        shot.height = 40
        shot.showOrbit = false
        shot.settings.cloud.coverageModulation = 0
        let f = try render(shot, weather: weather) { scene in
            guard let earth = scene.bodies.first(where: { $0.id == AtmosphereFrame.planetID }) else { return }
            let up = (-earth.position).normalized, east = Vec3(0, 0, 1).cross(up).normalized
            let e = 0.3 * Double.pi / 180, toSun = (east * cos(e) + up * sin(e)).normalized
            scene.sun.direction = toSun
            scene.sun.position = toSun * scene.sun.distance
            for i in scene.bodies.indices { scene.bodies[i].toSun = toSun }
        }
        let frame = try XCTUnwrap(f.clouds?.lastFrame.frame)
        XCTAssertEqual(frame.sunBody.dot(frame.cameraBody.normalized), sin(0.3 * Double.pi / 180), accuracy: 0.003)
        let sky = try XCTUnwrap(f.capture.values(.cloudSky))
        let overcast = Self.skyTransmittance(low: 1)
        let x = sky.texels.map { $0[0] }, y = sky.texels.map { $0[1] }
        print("sky map with the Sun 0.3° up: the overcast's \(overcast); x \(x.min() ?? -1)-\(x.max() ?? -1), "
              + "y \(y.min() ?? -1)-\(y.max() ?? -1)")
        for v in x + y { XCTAssertEqual(v, overcast, accuracy: 0.02) }
    }

    /// Stacked decks pass the sky's light as two-stream adding has it, the
    /// light reflected back and forth between them included: under 9/10 low,
    /// 9/10 mid and 5/10 cirrus the sky map holds the random overlap's
    /// expectation over the eight cases (here in Swift), not the product of
    /// the layers' own factors, which is darker.
    func testSkyMapAddsTheDecks() throws {
        let pad = try XCTUnwrap(CloudOverride.launches["apollo8"])
        let weather = try Self.uniformWeather(low: 0.9, mid: 0.9, high: 0.5, epoch: pad.time)
        var shot = SnapshotSpec.Shot(name: "a8-decks", scenario: "apollo8-pad",
                                     camera: SnapshotSpec.CameraSpec(yaw: -100, pitch: 8, distance: 300, fov: 60))
        shot.width = 64
        shot.height = 40
        shot.showOrbit = false
        shot.settings.cloud.coverageModulation = 0
        let sky = try XCTUnwrap(render(shot, weather: weather).capture.values(.cloudSky))
        let expected = Self.skyTransmittance(low: 0.9, mid: 0.9, high: 0.5)
        let product = Self.skyTransmittance(low: 0.9) * Self.skyTransmittance(low: 0, mid: 0.9)
            * Self.skyTransmittance(low: 0, high: 0.5)
        let x = sky.texels.map { $0[0] }
        print("sky map under three decks: \(x.min() ?? -1)-\(x.max() ?? -1); adding \(expected), the product \(product)")
        XCTAssertGreaterThan(expected - product, 0.02, "adding passes more than the product")
        for v in x { XCTAssertEqual(v, expected, accuracy: 0.01) }
    }

    /// From orbit the shadow map is 800 km across, and its plane lies
    /// hundreds of km off the ground at its edges: its lines must cross the
    /// low layer at the layer's own heights. Under a uniform overcast (the
    /// parking orbit 1,250 s on, the Sun 31° up below), every line that runs through
    /// the ground, its lowest point 5 km or more under it, crosses the deck
    /// on its way up to the Sun: shaded, beyond 200 km of the map's centre
    /// line too. (The parabola h(t) = hBase + μ0 t + t²/2R marched the low
    /// layer kilometres under its heights there: 44 % of the lines shaded.)
    func testShadowMapHoldsTheLowLayerFromOrbit() throws {
        let weather = try Self.uniformWeather(low: 1)
        var shot = Self.deckShot(width: 64, height: 40)
        shot.advance = ["wait:1250"]
        let f = try render(shot, weather: weather)
        let frame = try XCTUnwrap(f.clouds?.lastFrame.frame)
        let c = try XCTUnwrap(f.capture.values(.cloudShadow))
        let map = frame.shadowMap(texels: c.width)
        let elevation = asin(map.sun.dot(frame.cameraBody.normalized)) * 180 / .pi
        var through = 0, shaded = 0, farThrough = 0, farShaded = 0
        for yy in 0..<c.height {
            for xx in 0..<c.width {
                let mv = (Double(yy) + 0.5) / Double(c.height)
                let p0 = map.point(u: (Double(xx) + 0.5) / Double(c.width), v: mv, along: 0)
                let lowest = (p0 - map.sun * p0.dot(map.sun)).length - frame.radius
                guard lowest < -5_000 else { continue }
                let isShaded = c.texels[yy * c.width + xx][0] > 1
                through += 1
                if isShaded { shaded += 1 }
                if abs(mv - 0.5) * map.extent > 200_000 {
                    farThrough += 1
                    if isShaded { farShaded += 1 }
                }
            }
        }
        print(String(format: "orbit shadow map (%.0f km, the Sun %.1f° up at nadir): %d of %d lines through the ground "
                     + "shaded, %d of %d beyond 200 km", map.extent / 1000, elevation, shaded, through, farShaded, farThrough))
        XCTAssertGreaterThan(map.extent, 500_000)
        XCTAssertGreaterThan(farThrough, c.width * c.height / 10)
        XCTAssertGreaterThanOrEqual(Double(shaded), 0.98 * Double(through))
        XCTAssertGreaterThanOrEqual(Double(farShaded), 0.98 * Double(farThrough))
    }

    /// cloud_skyColumn in Swift: each layer's gaps and its cloudy columns
    /// of their mean optical depth (C1's extinction × the layer's depth ×
    /// CloudCoverage.columnDepth) at random overlap; over the eight cases the
    /// cloudy layers stacked as conservative slabs by two-stream adding,
    /// 1/T = 1 + Σ (1 − g) τ / 2, g 0.85 for water and 0.75 for ice.
    static func skyTransmittance(low: Double, mid: Double = 0, high: Double = 0,
                                 lowDepth: Double = CloudLayerModel.lowDepth, densityScale: Double = 1) -> Double {
        let layers = CloudLayerModel.layers(CloudSample(low: 1, mid: 1, high: 1))
        let st = CloudCoverage.standardStatistics
        func table(_ t: [Double], _ c: Double) -> Double {
            let x = min(max(c, 0), 1) * 32, i = min(Int(x), 31)
            return t[i] + (x - Double(i)) * (t[i + 1] - t[i])
        }
        let tauLow = layers[0].extinction * densityScale * lowDepth * table(st.columnDepth[0], low)
        let tauMid = layers[1].extinction * densityScale * (CloudLayerModel.midTop - CloudLayerModel.midBase)
            * table(st.columnDepth[1], mid)
        let tauHigh = layers[2].extinction * densityScale * CloudPass.cirrusThickness
        let c = [low, mid, high], k = [0.075 * tauLow, 0.075 * tauMid, 0.125 * tauHigh]
        var sum = 0.0
        for m in 0..<8 {
            var p = 1.0, d = 1.0
            for i in 0..<3 {
                let on = (m >> i) & 1 == 1
                p *= on ? c[i] : 1 - c[i]
                if on { d += k[i] }
            }
            sum += p / d
        }
        return sum
    }

    /// Under a cloud base above the low layer's 2 km reference shell, the far
    /// layer is not drawn below the camera: the clouds are above it. Before,
    /// at 2.2 km under a 2.8 km base, rays 0.3-1° down drew the 2 km shell's
    /// deck from above.
    func testFarLayerKeepsToItsSideOfTheShell() throws {
        let frame = try render(Self.padHorizonShot(regime: "auto", advance: ["met:40"]),
                               weather: try Self.uniformWeather(low: 0.5, base: 2_820))
        let c = try XCTUnwrap(frame.capture.values(.halfResClouds))
        let angles = try Self.rayAngles(frame, width: c.width, height: c.height)
        var sum = 0.0, n = 0
        for (k, texel) in c.texels.enumerated() {
            let e = angles[k].elevation * 180 / .pi, x = k % c.width
            guard e > -1, e < -0.3, x < c.width / 3 || x > 2 * c.width / 3 else { continue }
            sum += texel[3]
            n += 1
        }
        XCTAssertGreaterThan(n, 100)
        print("below the horizon under a 2.8 km base: mean opacity \(sum / Double(max(n, 1)))")
        XCTAssertLessThan(sum / Double(max(n, 1)), 0.02)
    }

    /// From above the air the clouds take A2's haze from space, as the
    /// ground around them does. At 1,500 km the disc's outer part lies
    /// beyond the froxels' 2,000 km along the ray, and at 2,000 km A2 stops
    /// them. Before, the clouds there took the froxels' empty last slice (no
    /// haze), and their haze switched at 2,000 km in one frame.
    func testCloudsTakeTheHazeFromSpace() throws {
        let weather = try Self.uniformWeather(low: 0.5)
        func hazed(altitude: Double, air: Bool) throws -> (mean: SIMD3<Double>, n: Int) {
            var shot = Self.deckShot(width: 320, height: 320)
            shot.camera = SnapshotSpec.CameraSpec(target: "body:399", frame: "inertial", yaw: 223.5, pitch: 22.9,
                                                  distance: 6_378_137 + altitude, fov: 115)
            shot.settings.atmosphere.enabled = air
            let frame = try render(shot, weather: weather)
            let c = try XCTUnwrap(frame.capture.values(.halfResClouds))
            let angles = try Self.rayAngles(frame, width: c.width, height: c.height)
            // The disc's outer part: 0.75-0.9 of its angular radius.
            let disc = asin(6_371_000 / (6_371_000 + altitude))
            var s = SIMD3<Double>(0, 0, 0), n = 0
            for (k, texel) in c.texels.enumerated() {
                let a = angles[k].offNadir / disc
                guard a > 0.75, a < 0.9, texel[3] > 0.05 else { continue }
                s += SIMD3(texel[0], texel[1], texel[2])
                n += 1
            }
            return (s / Double(max(n, 1)), n)
        }
        let bare = try hazed(altitude: 1_500_000, air: false)
        let at1500 = try hazed(altitude: 1_500_000, air: true)
        let below = try hazed(altitude: 1_990_000, air: true), above = try hazed(altitude: 2_010_000, air: true)
        XCTAssertGreaterThan(bare.n, 500)
        let r = at1500.mean / bare.mean
        print("haze at 1,500 km over the disc's outer part (hazed / bare):", r,
              "across 2,000 km (above / below):", above.mean / below.mean)
        // The air's transmittance takes a quarter or more of the clouds' blue.
        XCTAssertGreaterThan(abs(r.z - 1), 0.1, "hazed at 1,500 km")
        for k in 0..<3 { XCTAssertEqual((above.mean / below.mean)[k], 1, accuracy: 0.05, "across 2,000 km, channel \(k)") }
    }

    /// The cirrus draws its cover: 4/10 cirrus seen from orbit at 650 m
    /// footprints, where the deck's mean is drawn, has 4/10 of the deck's
    /// opacity. The fibres' thresholds (the shape's drew none) are
    /// testCirrusOpacityHoldsAcrossFootprints' samples at 0.2-0.4 km.
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
    /// cirrus keeps its opacity: each frame's depth is lit on its own and
    /// the two cross-fade in light and opacity. Mixing their fibre values
    /// before the threshold thinned partial cirrus to 0.17-0.58 of its depth
    /// mid-fade, and mixing their depths thickened it by 10 %.
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
        var shot = SnapshotSpec.Shot(name: "a8-shadow", scenario: "apollo8-first-motion",
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

    /// The mid layer holds the pad's horizon as C2's field does: its lens
    /// altocumulus fill a band about 250 m deep, so a slant ray crosses far
    /// fewer of them than the 3 km layer's span would. The field, integrated
    /// to convergence 0.6-1.5° up (the #73 fix check's port), is 0.19-0.21
    /// opaque at 1/10 and 0.49-0.53 at 3/10; with the whole layer's span the
    /// far layer drew 0.61-0.67 and 0.96-0.98.
    func testFarMidLayerHoldsThePadsHorizon() throws {
        for (cover, field) in [(0.1, 0.20), (0.3, 0.51)] {
            let frame = try render(Self.padHorizonShot(regime: "far"), weather: try Self.uniformWeather(low: 0, mid: cover))
            let c = try XCTUnwrap(frame.capture.values(.halfResClouds))
            let angles = try Self.rayAngles(frame, width: c.width, height: c.height)
            var sum = 0.0, n = 0
            for (k, texel) in c.texels.enumerated() {
                let e = angles[k].elevation * 180 / .pi, x = k % c.width
                guard e > 0.6, e < 1.5, x < c.width / 3 || x > 2 * c.width / 3 else { continue }
                sum += texel[3]
                n += 1
            }
            XCTAssertGreaterThan(n, 50, "the band is in view")
            print("pad horizon, mid layer at cover \(cover): far \(sum / Double(max(n, 1)))")
            XCTAssertEqual(sum / Double(max(n, 1)), field, accuracy: 0.06, "the field's opacity at cover \(cover)")
        }
    }

    /// The camera's height above the Earth (geodetic, m) in `frame`.
    static func cameraAltitude(_ frame: Frame) throws -> Double {
        let earth = try XCTUnwrap(frame.scene.bodies.first { $0.id == AtmosphereFrame.planetID })
        return earth.figure.geodetic(earth.orientation.icrfToBody * (-earth.position)).height
    }

    /// AS-506's ascent at `met` s, looking down across the deck.
    static func climbShot(met: Double) -> SnapshotSpec.Shot {
        var shot = deckShot(width: 160, height: 160)
        shot.scenario = "as506-first-motion"
        shot.advance = [String(format: "met:%.2f", met)]
        shot.settings.atmosphere.enabled = true
        return shot
    }

    /// Through the air's top the clouds' haze goes on smoothly: inside it
    /// A2's froxels, above it A2's haze from space, the two blended over the
    /// 40 km above the top. AS-506's ascent passes it at about 217 s. Before,
    /// a 2 km cloud's light stepped by about (1.01, 0.94, 0.85) at nadir as
    /// the camera crossed it.
    func testCloudsHazeGoesOnThroughTheAirsTop() throws {
        let lut = try XCTUnwrap(AtmosphereTables.shared.tables(wait: true))
        let top = lut.topRadius - lut.bottomRadius
        let weather = try Self.uniformWeather(low: 0.5)
        // The times the ascent is 1 km under and over the top.
        let t0 = 210.0, t1 = 225.0
        let h0 = try Self.cameraAltitude(render(Self.climbShot(met: t0), weather: weather))
        let h1 = try Self.cameraAltitude(render(Self.climbShot(met: t1), weather: weather))
        func mean(_ altitude: Double) throws -> SIMD3<Double> {
            let frame = try render(Self.climbShot(met: t0 + (altitude - h0) / (h1 - h0) * (t1 - t0)), weather: weather)
            XCTAssertEqual(try Self.cameraAltitude(frame), altitude, accuracy: 800)
            let c = try XCTUnwrap(frame.capture.values(.halfResClouds))
            var s = SIMD3<Double>(0, 0, 0), n = 0
            for texel in c.texels where texel[3] > 0.05 {
                s += SIMD3(texel[0], texel[1], texel[2])
                n += 1
            }
            XCTAssertGreaterThan(n, 1_000)
            return s / Double(max(n, 1))
        }
        let inside = try mean(top - 1_000), above = try mean(top + 1_000)
        print("haze across the air's top at \(top) m (above / inside):", above / inside)
        for k in 0..<3 { XCTAssertEqual((above / inside)[k], 1, accuracy: 0.03, "channel \(k)") }
    }

    /// The march has a GPU pass of its own: the weather and shadow maps'
    /// compute encoder, a blit, the march and resolve's, a blit. Apple's
    /// driver merges consecutive compute encoders, and merged with A2's LUTs,
    /// which P1 reads, the march held P1 back (LEO 1.2 ms over with A2 on;
    /// CloudCostTests times it). Counted from the timed frame's encoders,
    /// which the profiler labels by pass.
    func testMarchHasAGPUPassOfItsOwn() throws {
        let s = try snapper()
        var shot = Self.slabShot(regime: "march")
        shot.settings.atmosphere.enabled = true
        let prepared = try shot.prepare(system: s.system)
        let log = RecordingPass.Log()
        let spy = RecordingPass("spy", .opaque, log: log)
        var profile: FrameProfile?
        spy.onEncode = { f in profile = f.profile }
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [spy],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        guard r.profiler.isSupported else { throw XCTSkip("no timestamp counters on this GPU") }
        r.settings = shot.settings
        r.profiling = true
        r.profileInterval = 1
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
        var scene = shot.scene(prepared)
        for k in 0..<2 {
            scene.clock.frameIndex = k + 1
            scene.clock.temporalReset = k == 0
            XCTAssertNil(try XCTUnwrap(r.renderAndWait(scene, into: target)).error)
        }
        let p = try XCTUnwrap(profile, "a timed frame")
        XCTAssertTrue(try XCTUnwrap(r.graph.pass(named: "Clouds") as? CloudPass).lastFrame.drawn)
        // P0's run of the clouds' encoders, after A2's LUTs (E1's tile
        // uploads may come between; the slot's copy in P3 carries the
        // pass's name too).
        let first = try XCTUnwrap(p.labels.firstIndex(of: "Clouds"), "\(p.labels)")
        XCTAssertLessThan(try XCTUnwrap(p.labels.firstIndex(of: "Atmosphere LUTs"), "\(p.labels)"), first)
        let run = p.labels[first...].prefix { $0 == "Clouds" }.count
        XCTAssertEqual(run, 4, "\(p.labels)")
    }

    // MARK: A frame drawn again

    /// The pad's sky (C2's clouds reprojecting) on one renderer, its particles
    /// (P3 is not byte-deterministic), plumes and probe off, the frames at `steps`
    /// (frame index and seconds after the shot's epoch), the clock running
    /// (not paused) and no temporal reset after the first: each frame's
    /// pixels, the renderer's profile and the clouds' report after it.
    func drawPad(_ steps: [(index: Int, seconds: Double)], profiled: Bool = false) throws
        -> [(pixels: [UInt8], labels: [String], report: CloudPass.Report)] {
        let s = try snapper()
        var shot = SnapshotSpec.Shot(name: "c2-redraw", scenario: "as506-first-motion",
                                     camera: SnapshotSpec.CameraSpec(yaw: -60, pitch: 12, distance: 300, fov: 60))
        shot.width = 320
        shot.height = 200
        shot.showOrbit = false
        shot.settings.particle.quality = .off
        shot.settings.plume.quality = .off
        shot.settings.post.exposure.mode = .manual
        shot.settings.post.exposure.ev100 = 14
        // R3's probe updates its faces in turn, a redraw included (two
        // bytes of the frame move): it is not what these tests check.
        shot.settings.probe.enabled = false
        let prepared = try shot.prepare(system: s.system)
        let log = RecordingPass.Log()
        let spy = RecordingPass("spy", .opaque, log: log)
        var profile: FrameProfile?
        spy.onEncode = { f in profile = f.profile }
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [spy],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.settings = shot.settings
        r.setStars(s.stars)
        if profiled {
            guard r.profiler.isSupported else { throw XCTSkip("no timestamp counters on this GPU") }
            r.profiling = true
            r.profileInterval = 1
        }
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
        let base = shot.scene(prepared)
        let clouds = try XCTUnwrap(r.graph.pass(named: "Clouds") as? CloudPass)
        var out: [(pixels: [UInt8], labels: [String], report: CloudPass.Report)] = []
        // Each frame's clock; a frame drawn again keeps the one it repeats.
        var clock: (index: Int, seconds: Double, simDt: Double, reset: Bool)?
        for step in steps {
            if clock?.index != step.index {
                clock = (step.index, step.seconds, clock.map { step.seconds - $0.seconds } ?? 0, clock == nil)
            }
            guard let c = clock else { continue }
            var scene = base
            scene.clock.frameIndex = c.index
            scene.clock.simTime = base.clock.simTime + c.seconds
            scene.clock.simDt = c.simDt
            scene.clock.realDt = 1.0 / 60
            scene.clock.paused = false
            scene.clock.temporalReset = c.reset
            if !c.reset { scene.transitions = [] }
            profile = nil
            XCTAssertNil(try XCTUnwrap(r.renderAndWait(scene, into: target)).error)
            out.append((target.bytes(), profile?.labels ?? [], clouds.lastFrame))
        }
        return out
    }

    /// A frame drawn again (the same index and clock: a snapshot's views,
    /// its exposure and timed frames, F12's) does the frame's work again:
    /// its clouds' encoders run as the frame's did, march included, and its
    /// pixels are the frame's, though the clouds reproject (their history
    /// is read as the frame read it, not blended into once more).
    func testARedrawDoesTheFramesWorkAgain() throws {
        let frames = try drawPad([(1, 0), (2, 1.0 / 60), (3, 2.0 / 60), (3, 2.0 / 60)], profiled: true)
        XCTAssertTrue(frames[2].report.reprojected, "the frame reprojects")
        XCTAssertEqual(frames[3].pixels, frames[2].pixels, "the redraw is the frame")
        func run(_ labels: [String]) -> Int {
            guard let first = labels.firstIndex(of: "Clouds") else { return 0 }
            return labels[first...].prefix { $0 == "Clouds" }.count
        }
        XCTAssertEqual(run(frames[3].labels), run(frames[2].labels), "\(frames[3].labels)")
        XCTAssertEqual(run(frames[3].labels), 4, "the weather and shadow maps, the march and resolve, between blits")
    }

    /// In a running simulation (F12 in the app) a frame drawn again moves
    /// nothing on: the clouds' drift, cirrus and detail frames and weather
    /// bands advance once per frame, so the frame after a redraw is the frame
    /// it would have been without it.
    func testARedrawInARunningSimMovesNothing() throws {
        let dt = 30.0
        let plain = try drawPad([(1, 0), (2, dt), (3, 2 * dt)])
        let redrawn = try drawPad([(1, 0), (2, dt), (2, dt), (2, dt), (3, 2 * dt)])
        XCTAssertEqual(redrawn[2].pixels, redrawn[1].pixels, "a redraw is its frame")
        XCTAssertEqual(redrawn[3].pixels, redrawn[1].pixels)
        XCTAssertEqual(redrawn[4].pixels, plain[2].pixels, "the next frame as without the redraws")
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
            ("pad", "as506-first-motion", SnapshotSpec.CameraSpec(yaw: -60, pitch: 12, distance: 300, fov: 60), []),
            ("ascent-60s", "as506-first-motion", SnapshotSpec.CameraSpec(yaw: 149, pitch: -25, distance: 400, fov: 60), ["met:60"]),
            ("leo", "as506-parking-orbit", SnapshotSpec.CameraSpec(yaw: -34.4, pitch: 30, distance: 70, fov: 60), []),
            // The clouds off screen (the camera above the stack looking up):
            // R3's probe's state alone, with the shadow and sky maps.
            ("leo-up", "as506-parking-orbit", SnapshotSpec.CameraSpec(yaw: -34.4, pitch: -60, distance: 70, fov: 40), []),
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
                // P4's pad smoke off on both sides: it would keep R6's slots
                // running in the off frames too.
                on.particle.quality = .off
                off.particle.quality = .off
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

extension CloudCostTests {
    /// The procedural weather's kernels alone (ORBITSIM_CLOUD_COST=1): 20
    /// dispatches of each back to back in one command buffer (the GPU's
    /// clock stays up), gpuEndTime − gpuStartTime over 20, the median of 9.
    func testProceduralKernelCost() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST"] != nil else {
            throw XCTSkip("set ORBITSIM_CLOUD_COST=1 to measure")
        }
        let lock = GPULock { print("waiting for the GPU lock") }
        defer { _ = lock }
        let device = try XCTUnwrap(RenderDevice.shared)
        let library = try ShaderLibrary(device: device).library(.cloud)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: name)))
        }
        let nodes = try pipeline("cloud_procedural"), calibrate = try pipeline("cloud_calibrate")
        let proc = try XCTUnwrap(CloudPass.makeProcedural(device))
        let frame = CloudWeatherMap.proceduralFrame(ProceduralWeather(seed: 1), at: VesselLibrary.apollo11Insertion)
        var u = ProceduralUniforms(frame.state)
        let bands = zip(frame.bands, frame.climatology).map { b, c in
            ProceduralBand(a: SIMD4(Float(b.steer), Float(b.subtropics), Float(b.stratocumulus), Float(b.desert)),
                           b: SIMD4(Float(b.midDesert), Float(b.trades), Float(b.polar), Float(b.ice)),
                           c: SIMD4(Float(c.low), Float(c.mid), Float(c.high), 0))
        }
        let systems = frame.state.systems.map(ProceduralSystemGPU.init)
        let bandBuffer = try XCTUnwrap(device.makeBuffer(bytes: bands, length: MemoryLayout<ProceduralBand>.stride * bands.count))
        let systemBuffer = try XCTUnwrap(device.makeBuffer(bytes: systems,
                                                           length: MemoryLayout<ProceduralSystemGPU>.stride * systems.count))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for (name, kernel) in [("nodes", 0), ("calibration", 1)] {
            var times: [Double] = []
            for _ in 0..<9 {
                let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
                for _ in 0..<20 {
                    if kernel == 0 {
                        enc.setComputePipelineState(nodes)
                        enc.setTexture(proc.latent, index: 0)
                        enc.setTexture(proc.layer, index: 1)
                        enc.setTexture(proc.geography.a, index: 2)
                        enc.setTexture(proc.geography.b, index: 3)
                        enc.setBytes(&u, length: MemoryLayout<ProceduralUniforms>.stride, index: 0)
                        enc.setBuffer(bandBuffer, offset: 0, index: 1)
                        enc.setBuffer(systemBuffer, offset: 0, index: 2)
                        enc.dispatchThreads(MTLSize(width: ProceduralWeather.columns, height: ProceduralWeather.rows, depth: 1),
                                            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
                    } else {
                        enc.setComputePipelineState(calibrate)
                        enc.setTexture(proc.latent, index: 0)
                        enc.setBytes(&u, length: MemoryLayout<ProceduralUniforms>.stride, index: 0)
                        enc.setBuffer(bandBuffer, offset: 0, index: 1)
                        enc.setBuffer(proc.offsets, offset: 0, index: 3)
                        enc.dispatchThreadgroups(MTLSize(width: ProceduralWeather.rows, height: 1, depth: 1),
                                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                    }
                }
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
                times.append((cb.gpuEndTime - cb.gpuStartTime) / 20)
            }
            print(String(format: "procedural %@: %.3f ms a dispatch (%d systems)", name, times.sorted()[4] * 1_000, systems.count))
        }
    }

    /// The weather map's assembly (ORBITSIM_CLOUD_COST=1): the frames of a
    /// sweep (the time 60 s on, past `CloudPass.proceduralStep`, every eighth
    /// frame: the next `CloudPass.sweepBands` frames each make a band of the
    /// nodes, the rows' calibration and the band's map rows) against the
    /// frames after it that keep the map, one renderer, every default pass at
    /// 3024 × 1964; with the procedural weather and with the climatology (the
    /// map alone, made once: its frames are the same).
    func testWeatherAssemblyCost() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_COST"] != nil else {
            throw XCTSkip("set ORBITSIM_CLOUD_COST=1 to measure")
        }
        let lock = GPULock { print("waiting for the GPU lock") }
        defer { _ = lock }
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        var shot = SnapshotSpec.Shot(name: "leo", scenario: "as506-parking-orbit",
                                     camera: SnapshotSpec.CameraSpec(yaw: -34.4, pitch: 30, distance: 70, fov: 60))
        // The full frame, every default pass: the GPU's clock stays up.
        shot.width = 3024
        shot.height = 1964
        shot.showOrbit = false
        let prepared = try shot.prepare(system: s.system)
        let base = shot.scene(prepared)
        for weather in ["random", "climatology"] {
            let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                      passes: SceneRenderer.defaultPasses(loadsUserTextures: false),
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            r.setStars(s.stars)
            r.settings.particle.quality = .off
            r.settings.cloud.weather = weather
            r.settings.cloud.reprojection = false
            if let skip = ProcessInfo.processInfo.environment["ORBITSIM_CLOUD_SKIP"] {
                r.settings.cloud.skip = skip.split(separator: ",").map(String.init)
            }
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
            final class Times: @unchecked Sendable {
                let lock = NSLock()
                var a: [Double] = [], b: [Double] = []
            }
            let times = Times()
            var last: MTLCommandBuffer?
            var time = base.clock.simTime
            let cycle = 2 * CloudPass.sweepBands
            for k in 0..<(40 + 25 * cycle) {
                var scene = base
                let assemble = k % cycle < CloudPass.sweepBands
                if k % cycle == 0 { time = time + 60 }
                scene.clock.simTime = time
                scene.clock.frameIndex = k + 1
                scene.clock.temporalReset = k == 0
                let measure = k >= 40
                last = r.render(scene, to: target.texture) { cb in
                    guard measure else { return }
                    times.lock.withLock {
                        if assemble { times.a.append(cb.gpuEndTime - cb.gpuStartTime) } else { times.b.append(cb.gpuEndTime - cb.gpuStartTime) }
                    }
                }
            }
            last?.waitUntilCompleted()
            Thread.sleep(forTimeInterval: 0.2)
            func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
            let band = median(times.a) - median(times.b)
            print(String(format: "weather map %@: %.2f ms a frame of a sweep, %.2f ms the sweep (frame %.2f, kept %.2f)",
                         weather, band * 1_000, band * Double(CloudPass.sweepBands) * 1_000, median(times.a) * 1_000,
                         median(times.b) * 1_000))
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

    /// The procedural weather on the GPU is ProceduralWeather's mirror: its
    /// nodes (`cloud_procedural` against `ProceduralWeather.node`, Float and
    /// fast math against Double), each row's calibration (`cloud_calibrate`
    /// against `ProceduralWeather.offset` over the GPU's own nodes) and the
    /// map assembled from them (`cloud_weather` against
    /// `CloudWeatherMap.texel`).
    func testProceduralWeatherIsTheMirror() throws {
        let w = ProceduralWeather(seed: 7)
        let weather = CloudWeather(procedural: w)
        var shot = CloudRenderTests.slabShot(regime: "far")
        shot.settings.cloud.lookDev = nil
        shot.settings.cloud.coverageModulation = 0
        let (clouds, s) = try render(shot) { $0.weatherOverride = weather }
        let report = clouds.lastFrame
        XCTAssertTrue(report.drawn)
        let epoch = try XCTUnwrap(report.epoch)
        let proc = try XCTUnwrap(clouds.procedural)
        let columns = ProceduralWeather.columns, rows = ProceduralWeather.rows
        let latent = try Self.readBack(proc.latent, bytesPerTexel: 16, device: s.device)
            .contents().bindMemory(to: Float.self, capacity: 4 * columns * rows)
        let layer = try Self.readBack(proc.layer, bytesPerTexel: 16, device: s.device)
            .contents().bindMemory(to: Float.self, capacity: 4 * columns * rows)
        let offsetsBuffer = try Self.readBack(proc.offsets, device: s.device)
            .contents().bindMemory(to: Float.self, capacity: 4 * rows)
        func gpuNode(_ j: Int, _ c: Int) -> ProceduralWeather.Node {
            let k = 4 * (j * columns + c)
            var n = ProceduralWeather.Node()
            n.low = Double(latent[k])
            n.mid = Double(latent[k + 1])
            n.high = Double(latent[k + 2])
            n.base = Double(latent[k + 3])
            n.top = Double(layer[k])
            n.cumuliform = Double(layer[k + 1])
            return n
        }
        // The nodes.
        let state = w.state(at: epoch)
        XCTAssertEqual(state, clouds.proceduralState)
        let g = WeatherGeography.earth
        var worst = 0.0
        for j in [0, 41, 100, 150, 180, 211, 250, 300, 360] {
            let lat = ProceduralWeather.latitude(row: j)
            let band = ProceduralWeather.band(latitude: lat, sky: state.sky)
            for c in stride(from: 0, to: columns, by: 7) {
                let e = ProceduralWeather.node(latitude: lat, longitude: ProceduralWeather.longitude(column: c),
                                               geography: g.texel(row: j, column: c), band: band, state: state)
                let n = gpuNode(j, c)
                worst = max(worst, abs(n.low - e.low), abs(n.mid - e.mid), abs(n.high - e.high))
                XCTAssertEqual(n.base, e.base, accuracy: 2, "base at \(j), \(c)")
                XCTAssertEqual(n.top, e.top, accuracy: 8, "top at \(j), \(c)")
                XCTAssertEqual(n.cumuliform, e.cumuliform, accuracy: 2e-3, "cumuliform at \(j), \(c)")
            }
        }
        XCTAssertLessThan(worst, 0.01, "the latent covers")
        // The rows' calibration over the GPU's own nodes.
        let frame = CloudWeatherMap.proceduralFrame(w, at: epoch)
        let gains = ProceduralWeather.gains
        var offsets: [(low: Double, mid: Double, high: Double)] = []
        for j in 0..<rows {
            offsets.append((Double(offsetsBuffer[4 * j]), Double(offsetsBuffer[4 * j + 1]), Double(offsetsBuffer[4 * j + 2])))
            guard j % 30 == 0 || j == rows - 1 else { continue }
            let nodes = (0..<columns).map { gpuNode(j, $0) }
            let c = frame.climatology[j]
            XCTAssertEqual(offsets[j].low, ProceduralWeather.offset(nodes.map(\.low), target: c.low, gain: gains.low),
                           accuracy: 2e-3, "row \(j)")
            XCTAssertEqual(offsets[j].mid, ProceduralWeather.offset(nodes.map(\.mid), target: c.mid, gain: gains.mid),
                           accuracy: 2e-3, "row \(j)")
            XCTAssertEqual(offsets[j].high, ProceduralWeather.offset(nodes.map(\.high), target: c.high, gain: gains.high),
                           accuracy: 2e-3, "row \(j)")
        }
        // The map.
        let map = try XCTUnwrap(clouds.weatherMap)
        let a = try Self.readBack(map.a, bytesPerTexel: 8, device: s.device)
        let b = try Self.readBack(map.b, bytesPerTexel: 4, device: s.device)
        let ap = a.contents().bindMemory(to: UInt16.self, capacity: 4 * CloudWeatherMap.columns * CloudWeatherMap.rows)
        let bp = b.contents().bindMemory(to: UInt16.self, capacity: 2 * CloudWeatherMap.columns * CloudWeatherMap.rows)
        let p = CloudWeatherMap.parameters(weather, at: epoch)
        XCTAssertNotNil(p.procedural)
        let nodes = CloudWeatherMap.ProceduralNodes(node: gpuNode, offsets: offsets)
        func half(_ v: UInt16) -> Double { Double(Float(Float16(bitPattern: v))) }
        for r in [0, 1, 99, 360, 361, 500, 719, 720] {
            for c in [0, 1, 321, 1000, 1439] {
                let e = CloudWeatherMap.texel(column: c, row: r, first: nil, second: nil, parameters: p, procedural: nodes)
                let at = r * CloudWeatherMap.columns + c
                XCTAssertEqual(half(ap[4 * at]), e.low, accuracy: 2e-3, "\(r), \(c)")
                XCTAssertEqual(half(ap[4 * at + 1]), e.mid, accuracy: 2e-3, "\(r), \(c)")
                XCTAssertEqual(half(ap[4 * at + 2]), e.high, accuracy: 2e-3, "\(r), \(c)")
                XCTAssertEqual(half(ap[4 * at + 3]), e.lowBase, accuracy: 2.5, "half floats: 2 m steps to 4 km")
                XCTAssertEqual(half(bp[2 * at]), e.lowTop, accuracy: 8)
                XCTAssertEqual(half(bp[2 * at + 1]), e.cumuliform, accuracy: 2e-3)
            }
        }
    }

    /// A sweep (the procedural nodes made again a band a frame once the
    /// time has moved 30 s) ends with the map a fresh pass makes at its time,
    /// texel for texel.
    func testProceduralSweepEndsWithAFreshMap() throws {
        let weather = CloudWeather(procedural: ProceduralWeather(seed: 9))
        var shot = CloudRenderTests.slabShot(regime: "far", width: 64, height: 40)
        shot.settings.cloud.lookDev = nil
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let prepared = try shot.prepare(system: s.system)
        let start = shot.scene(prepared).clock.simTime
        func map(_ times: [Double]) throws -> [UInt16] {
            let clouds = CloudPass()
            clouds.weatherOverride = weather
            let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: [clouds],
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            r.settings = shot.settings
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
            for (k, t) in times.enumerated() {
                var scene = shot.scene(prepared)
                scene.clock.simTime = start + t
                scene.clock.frameIndex = k + 1
                _ = r.renderAndWait(scene, into: target)
            }
            let m = try XCTUnwrap(clouds.weatherMap)
            let n = 4 * CloudWeatherMap.columns * CloudWeatherMap.rows
            let buffer = try Self.readBack(m.a, bytesPerTexel: 8, device: s.device)
            return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt16.self, capacity: n), count: n))
        }
        let fresh = try map([3_600])
        // 40 s on: a sweep, four frames.
        let sweep = try map([3_560, 3_600, 3_600, 3_600, 3_600])
        XCTAssertEqual(sweep, fresh)
        // Mid-sweep it is not yet.
        XCTAssertNotEqual(try map([3_560, 3_600, 3_600]), fresh)
    }

    /// A private buffer's bytes, through a shared copy.
    static func readBack(_ buffer: MTLBuffer, device: MTLDevice) throws -> MTLBuffer {
        let out = try XCTUnwrap(device.makeBuffer(length: buffer.length, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: buffer, sourceOffset: 0, to: out, destinationOffset: 0, size: buffer.length)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return out
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
        shot.scenario = "as506-first-motion"
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

    /// cloud_cirrusFirst: the cirrus in front of a part by the height of its
    /// entry from the camera's side of the shell, and in front of what a
    /// ray from above enters above the shell on its way up again (beyond its
    /// lowest point, past the shell's far crossing).
    func testCirrusOrderByHeight() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "CloudCirrusFirst", headers: [.effectSlots, .atmosphereCommon],
                                  source: cloudShaderSource + """
            kernel void cloud_test_cirrusFirst(constant CloudUniforms &u [[buffer(0)]],
                                               constant float4 *rays [[buffer(1)]],
                                               device uint *out [[buffer(2)]],
                                               uint i [[thread_position_in_grid]]) {
                out[i] = cloud_cirrusFirst(rays[2 * i].w, rays[2 * i].xyz, rays[2 * i + 1].xyz, u) ? 1u : 0u;
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(
            function: try XCTUnwrap(library.makeFunction(name: "cloud_test_cirrusFirst")))
        let a = 6_378_137.0, shell = 10_000.0
        // A camera at height h, the ray's direction at `dip` below its
        // horizontal, and the distance along it where it is at height `at`,
        // on its way down or up again.
        func ray(height h: Double, dip: Double, at: Double, climbing: Bool) -> (of: Vec3, df: Vec3, entry: Double) {
            let of = Vec3(a + h, 0, 0), df = Vec3(-sin(dip), cos(dip), 0)
            let b = of.dot(df), c = of.dot(of) - (a + at) * (a + at), disc = b * b - c
            let t = climbing ? -b + disc.squareRoot() : -b - disc.squareRoot()
            return (of, df, t)
        }
        var cases: [(String, (of: Vec3, df: Vec3, entry: Double), Bool, Bool)] = [
            ("from orbit, a deck at 2 km", ray(height: 190_000, dip: 1.2, at: 2_000, climbing: false), true, true),
            ("from orbit, a top at 12 km", ray(height: 190_000, dip: 1.2, at: 12_000, climbing: false), true, false),
        ]
        // A ray from 15 km whose lowest point is 8 km up: a top at 11 km on
        // its way down (before the cirrus) and on its way up (beyond it).
        let dip = acos((a + 8_000) / (a + 15_000))
        cases.append(("grazing, a top at 11 km before the dip", ray(height: 15_000, dip: dip, at: 11_000, climbing: false), true, false))
        cases.append(("grazing, a top at 11 km beyond the dip", ray(height: 15_000, dip: dip, at: 11_000, climbing: true), true, true))
        // From 5 km looking up: the cirrus where the ray leaves the shell.
        cases.append(("from below, a cloud at 7 km", ray(height: 5_000, dip: -0.3, at: 7_000, climbing: true), false, false))
        cases.append(("from below, an anvil at 12 km", ray(height: 5_000, dip: -0.3, at: 12_000, climbing: true), false, true))
        cases.append(("no cloud", (Vec3(a + 190_000, 0, 0), Vec3(-1, 0, 0), 1e30), true, true))
        var rays: [SIMD4<Float>] = []
        for c in cases {
            // Figure coordinates from the Earth's centre, as the slot's
            // ray.of (the camera's figure point, u.cameraFigure).
            rays.append(SIMD4(Float(c.1.of.x), Float(c.1.of.y), Float(c.1.of.z), Float(c.1.entry)))
            rays.append(SIMD4(Float(c.1.df.x), Float(c.1.df.y), Float(c.1.df.z), 0))
        }
        var results: [Bool] = []
        for (k, c) in cases.enumerated() {
            var u = CloudUniforms()
            u.radii = SIMD4(Float(a), Float(c.1.of.length - a), 0, 0)
            let r = Float(a + shell), o = Float(c.1.of.length)
            u.shell = SIMD4(0, 0, (o - r) * (o + r), 0)
            u.shellMid = SIMD4(0, Float(shell), 0, 0)
            let input = try XCTUnwrap(device.makeBuffer(bytes: [rays[2 * k], rays[2 * k + 1]], length: 32,
                                                        options: .storageModeShared))
            let out = try XCTUnwrap(device.makeBuffer(length: 4, options: .storageModeShared))
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
            enc.setComputePipelineState(pipeline)
            enc.setBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 0)
            enc.setBuffer(input, offset: 0, index: 1)
            enc.setBuffer(out, offset: 0, index: 2)
            enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            results.append(out.contents().load(as: UInt32.self) == 1)
            XCTAssertEqual(c.2, u.shell.z > 0, "\(c.0): the camera's side")
        }
        for (c, first) in zip(cases, results) { XCTAssertEqual(first, c.3, c.0) }
    }

    /// cloud_lineAt, the shadow map's lines along the Sun: in figure space
    /// (z stretched by a/b, heights |pf| − a), its roots lie at the heights
    /// asked for, checked in Double off the equator (28.5°, 32.5°, 57°) from
    /// map planes 150 km under the ground to 300 km over it, the Sun 15° and
    /// 45° up; where the line never comes down to the height, its lowest
    /// point. The sphere's own quadratic, which dropped the stretch, put
    /// these roots up to 740 m off their heights (the review found 2 km at a
    /// 20° Sun).
    func testShadowLinesMeetTheirHeightsOffTheEquator() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "CloudLineAt", headers: [.effectSlots, .atmosphereCommon],
                                  source: cloudShaderSource + """
            kernel void cloud_test_lineAt(constant CloudUniforms &u [[buffer(0)]],
                                          constant float4 *lines [[buffer(1)]],
                                          device float2 *out [[buffer(2)]],
                                          uint i [[thread_position_in_grid]]) {
                out[i] = cloud_lineAt(lines[2 * i].xyz, lines[2 * i + 1].xyz, lines[2 * i].w, lines[2 * i + 1].w, u);
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(
            function: try XCTUnwrap(library.makeFunction(name: "cloud_test_lineAt")))
        let e = Ellipsoid.wgs84, a = e.equatorialRadius, w = a / e.polarRadius
        func figure(_ p: Vec3) -> Vec3 { Vec3(p.x, p.y, p.z * w) }
        struct Line { var pf0: Vec3; var sF: Vec3; var hBase: Double; var h: Double; var oldT: Double }
        var lines: [Line] = []
        for lat in [28.5, 32.5, 57.0] {
            let φ = lat * .pi / 180, λ = -0.9
            let up = e.normal(latitude: φ, longitude: λ)
            let east = Vec3(-sin(λ), cos(λ), 0), north = up.cross(east)
            for elevation in [15.0, 45.0] {
                let el = elevation * .pi / 180
                for azimuth in [0.0, 2.0] {
                    let horizontal = east * cos(azimuth) + north * sin(azimuth)
                    let sun = (horizontal * cos(el) + up * sin(el)).normalized
                    // The map's plane through a point beside the ground point,
                    // across the Sun, 150 km under to 300 km over the ground.
                    for (offset, height) in [(0.0, 0.0), (-250_000.0, -150_000.0), (250_000.0, 300_000.0)] {
                        let p = e.bodyFixed(latitude: φ, longitude: λ, height: height) + horizontal.cross(up) * offset
                        let pf0 = figure(p), sF = figure(sun), hBase = pf0.length - a
                        for h in [0.0, 720.0, 1_500.0, 2_820.0, 10_000.0] {
                            // The sphere's own root, as the kernel had it.
                            let mu0 = sun.dot(e.normal(at: p)), b0 = (a + hBase) * mu0
                            let oldT = -b0 + max(b0 * b0 + (h - hBase) * (2 * a + h + hBase), 0).squareRoot()
                            lines.append(Line(pf0: pf0, sF: sF, hBase: hBase, h: h, oldT: oldT))
                        }
                    }
                }
            }
        }
        var input: [SIMD4<Float>] = []
        for l in lines {
            input.append(SIMD4(Float(l.pf0.x), Float(l.pf0.y), Float(l.pf0.z), Float(l.hBase)))
            input.append(SIMD4(Float(l.sF.x), Float(l.sF.y), Float(l.sF.z), Float(l.h)))
        }
        var u = CloudUniforms()
        u.radii = SIMD4(Float(a), 0, 0, 0)
        let inBuffer = try XCTUnwrap(device.makeBuffer(bytes: input, length: 16 * input.count, options: .storageModeShared))
        let out = try XCTUnwrap(device.makeBuffer(length: 8 * lines.count, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBytes(&u, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        enc.setBuffer(inBuffer, offset: 0, index: 1)
        enc.setBuffer(out, offset: 0, index: 2)
        enc.dispatchThreads(MTLSize(width: lines.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let t = out.contents().bindMemory(to: SIMD2<Float>.self, capacity: lines.count)
        func height(_ l: Line, _ t: Double) -> Double { (l.pf0 + l.sF * t).length - a }
        var worst = 0.0, worstOld = 0.0, reached = 0
        for (k, l) in lines.enumerated() {
            let lowestT = -l.pf0.dot(l.sF) / l.sF.dot(l.sF)
            let rising = Double(t[k].x), falling = Double(t[k].y)
            if height(l, lowestT) < l.h {
                reached += 1
                worst = max(worst, abs(height(l, rising) - l.h), abs(height(l, falling) - l.h))
                XCTAssertGreaterThan(rising, falling, "x rises")
                worstOld = max(worstOld, abs(height(l, l.oldT) - l.h))
            } else {
                XCTAssertEqual(rising, lowestT, accuracy: 10, "the lowest point")
                XCTAssertEqual(falling, lowestT, accuracy: 10)
            }
        }
        print(String(format: "shadow lines: %d of %d reach their heights, worst %.1f m off (the sphere's own root %.0f m)",
                     reached, lines.count, worst, worstOld))
        XCTAssertGreaterThan(reached, lines.count / 2)
        XCTAssertLessThan(worst, 10)
        XCTAssertGreaterThan(worstOld, 300, "the sphere's own root was off")
    }

    /// The cloud uniforms' Swift mirrors have MSL's sizes.
    func testStructLayoutsMatchMSL() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "CloudSizes", headers: [.effectSlots, .atmosphereCommon], source: cloudShaderSource + """
            kernel void cloud_sizes(device uint *out [[buffer(0)]]) {
                out[0] = sizeof(CloudUniforms);
                out[1] = sizeof(CloudWeatherParams);
                out[2] = sizeof(CloudResolveUniforms);
                out[3] = sizeof(ProceduralUniforms);
                out[4] = sizeof(ProceduralBand);
                out[5] = sizeof(ProceduralSystem);
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "cloud_sizes")))
        let out = try XCTUnwrap(device.makeBuffer(length: 6 * 4, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let v = out.contents().bindMemory(to: UInt32.self, capacity: 6)
        XCTAssertEqual(Int(v[0]), MemoryLayout<CloudUniforms>.stride)
        XCTAssertEqual(Int(v[1]), MemoryLayout<CloudWeatherParams>.stride)
        XCTAssertEqual(Int(v[2]), MemoryLayout<CloudResolveUniforms>.stride)
        XCTAssertEqual(Int(v[3]), MemoryLayout<ProceduralUniforms>.stride)
        XCTAssertEqual(Int(v[4]), MemoryLayout<ProceduralBand>.stride)
        XCTAssertEqual(Int(v[5]), MemoryLayout<ProceduralSystemGPU>.stride)
    }
}

/// Apollo 8's orbit by day (ORBITSIM_CLOUD_SHOTS=<dir>): the pad and the
/// ascent are orbitsnap's (`apollo8-first-motion`, c2-scenes.json), but a
/// parking orbit on Apollo 8's day is M2's, so this puts a capsule in a 185
/// km orbit in daylight an hour after AS-503's launch (the terminator is
/// Apollo 11's, c2-scenes.json), and renders them as orbitsnap does (auto
/// exposure, settled), with Apollo 8's ERA5 field when it is fetched.
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

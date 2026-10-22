import Foundation
import Metal
import simd
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// Track R4's shadow maps on the GPU: ShadowCommon's `orbit_sunShadow`
/// probed at chosen points after ShadowPass has drawn a scene. The plan's
/// look metrics: the shadow edge within a texel of the geometric one and
/// the penumbra within 20% of the Sun's disc's (0.0093·Δd); shadow on the
/// ground far behind a caster; nothing moving as the camera moves; the
/// receiver API's corner cases.
@MainActor
final class ShadowPassTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    // MARK: The probe

    /// `orbit_sunShadowAndMap` at each point and normal (camera-relative
    /// world): the Sun's visible share and the map that gave it.
    nonisolated static let probeSource = #"""
    kernel void shadow_probe(const device float4 *points [[buffer(0)]],
                             const device float4 *normals [[buffer(1)]],
                             device float2 *out [[buffer(2)]],
                             constant LightingUniforms &lighting [[buffer(3)]],
                             depth2d_array<float> atlas [[texture(0)]],
                             sampler compare [[sampler(0)]],
                             uint i [[thread_position_in_grid]]) {
        out[i] = orbit_sunShadowAndMap(points[i].xyz, normals[i].xyz, lighting, atlas, compare);
    }
    """#

    @MainActor
    struct Probe {
        let device: MTLDevice
        let pipeline: MTLComputePipelineState
        let sampler: MTLSamplerState
        let queue: MTLCommandQueue

        init(device: MTLDevice) throws {
            self.device = device
            let module = ShaderModule(name: "ShadowProbe", headers: [.shadowCommon], source: ShadowPassTests.probeSource)
            let library = try device.makeLibrary(source: module.fullSource, options: nil)
            pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "shadow_probe")))
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear
            sd.magFilter = .linear
            sd.sAddressMode = .clampToEdge
            sd.tAddressMode = .clampToEdge
            sd.compareFunction = .greaterEqual
            sampler = try XCTUnwrap(device.makeSamplerState(descriptor: sd))
            queue = try XCTUnwrap(device.makeCommandQueue())
        }

        /// (visibility, map) at each point, with each normal.
        func run(_ points: [Vec3], normals: [Vec3], pass: ShadowPass,
                 lighting: LightingUniforms? = nil) throws -> [(Double, Int)] {
            let atlas = try XCTUnwrap(pass.lastAtlas, "no maps drawn")
            let p = points.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 1) }
            let n = normals.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 0) }
            let out = try XCTUnwrap(device.makeBuffer(length: 8 * points.count, options: .storageModeShared))
            var lighting = lighting ?? pass.lastLighting
            let pb = try XCTUnwrap(device.makeBuffer(bytes: p, length: 16 * p.count, options: .storageModeShared))
            let nb = try XCTUnwrap(device.makeBuffer(bytes: n, length: 16 * n.count, options: .storageModeShared))
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(pb, offset: 0, index: 0)
            enc.setBuffer(nb, offset: 0, index: 1)
            enc.setBuffer(out, offset: 0, index: 2)
            enc.setBytes(&lighting, length: MemoryLayout<LightingUniforms>.stride, index: 3)
            enc.setTexture(atlas, index: 0)
            enc.setSamplerState(sampler, index: 0)
            enc.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            let r = out.contents().bindMemory(to: SIMD2<Float>.self, capacity: points.count)
            return (0..<points.count).map { (Double(r[$0].x), Int(r[$0].y.rounded())) }
        }
    }

    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// A renderer with the shadow pass alone, and the pass.
    func shadowRenderer() throws -> (SceneRenderer, ShadowPass) {
        let pass = ShadowPass(), device = try device()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: [pass],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 1))
        XCTAssertEqual(r.failures, [:])
        return (r, pass)
    }

    func draw(_ scene: RenderScene, _ r: SceneRenderer, settings: ShadowSettings = ShadowSettings()) throws {
        r.settings.shadow = settings
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: 64, height: 64))
        r.renderAndWait(scene, into: target)
    }

    // MARK: Scenes

    /// A vessel of `shapes` (one part, its construction frame at its centre
    /// of mass), camera-relative at `position` with `attitude`.
    static func vessel(_ shapes: [VisualShape], position: Vec3, attitude: Quat = .identity,
                       name: String = "Caster") -> RenderScene.Vessel {
        let part = VesselPart(name: name, dryMass: 1_000, length: 1, radius: 1, shapes: shapes)
        let core = Vessel(name: name, parts: [part], reference: system.earth)
        let light = LegacyLight(toSun: .unitX, sunlit: 1, sky: 0, earthDirection: -.unitZ, earthLit: 0,
                                earthStrength: 0, earthColor: RenderScene.RGB(0, 0, 0))
        return RenderScene.Vessel(id: core.id, name: name, isFocus: true, status: .flying, isLanded: false,
                                  referenceBodyID: 399, position: position, attitude: attitude,
                                  structureOrigin: core.structureOrigin, boundingRadius: core.boundingRadius,
                                  geometry: VesselGeometry(of: core), thrusters: [:], light: light,
                                  glow: RenderScene.RGB(0, 0, 0), flowDirection: .zero, farPointStyle: nil,
                                  heatFlux: 0, heatLoad: 0)
    }

    /// A scene of `vessels`, the camera at the origin looking at the first,
    /// the Sun along `toSun`.
    static func scene(_ vessels: [RenderScene.Vessel], toSun: Vec3, cameraOffset: Vec3 = .zero) -> RenderScene {
        let sun = toSun.normalized * 1.496e11 - cameraOffset
        var moved = vessels
        for i in moved.indices { moved[i].position = moved[i].position - cameraOffset }
        return RenderScene(clock: RenderScene.Clock(simTime: Epoch(tdbSecondsPastJ2000: 0)),
                           camera: RenderScene.Camera(position: cameraOffset, worldToView: .identity,
                                                      fovY: 50 * Double.pi / 180,
                                                      viewport: RenderScene.Viewport(width: 640, height: 400),
                                                      target: .vessel(vessels[0].id)),
                           sun: RenderScene.Sun(position: sun, direction: sun.normalized, distance: sun.length,
                                                illuminance: 1.3e5, angularRadius: ShadowFitting.sunAngularRadius),
                           vessels: moved, sites: [])
    }

    nonisolated static let white = (1.0, 1.0, 1.0)

    // MARK: Look metrics

    /// A square plate, `side` across and 5 cm thick, facing the Sun, 30 m
    /// from the camera; with the unit vectors along one of its edges' normal
    /// (`u`) and along that edge (`w`), and the edge's offset from its
    /// centre along u, measured on its mesh.
    @MainActor
    struct Plate {
        let vessel: RenderScene.Vessel
        let centre: Vec3, toSun: Vec3, u: Vec3, w: Vec3
        let edge: Double

        init(side: Double = 4, toSun: Vec3 = Vec3(0.3, 0.5, 0.8).normalized) {
            let u = toSun.cross(.unitZ).normalized, w = toSun.cross(u)
            let shape = VisualShape.box(from: -toSun * 0.025, length: 0.05, width: side, height: side, axis: toSun,
                                        reference: u, color: ShadowPassTests.white)
            vessel = ShadowPassTests.vessel([shape], position: Vec3(2, -1, -30))
            let points = shape.mesh().vertices.map(\.position)
            edge = points.map { $0.dot(u) }.max()!
            centre = vessel.position + vessel.attitude.rotate(vessel.structureOrigin)
            (self.toSun, self.u, self.w) = (toSun, u, w)
        }

        /// A receiver facing the Sun, `depth` behind the plate's plane, `s`
        /// past the shadow's geometric edge (outwards) and `along` it.
        func receiver(depth: Double, s: Double, along: Double) -> Vec3 {
            centre - toSun * depth + u * (edge + s) + w * along
        }
    }

    /// The share 10% and 90% of the way across a straight edge's penumbra
    /// in the Sun's disc profile, in half widths (±0.687).
    static let tenToNinety: Double = {
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if ShadowFitting.edgeVisibility(mid) < 0.9 { lo = mid } else { hi = mid }
        }
        return lo
    }()

    /// The mean visibility across the edge at offsets `s` (m), each averaged
    /// along 256 receivers spread along the edge, so the filter's per-texel
    /// turns average out.
    func profile(_ plate: Plate, depth: Double, offsets: [Double], pass: ShadowPass,
                 probe: Probe) throws -> [Double] {
        var points: [Vec3] = []
        let n = 256
        for s in offsets {
            for k in 0..<n { points.append(plate.receiver(depth: depth, s: s, along: Double(k) * 1.5 / Double(n) - 0.75)) }
        }
        let v = try probe.run(points, normals: Array(repeating: plate.toSun, count: points.count), pass: pass)
        XCTAssert(v.allSatisfy { $0.1 == 0 }, "every receiver in the plate's map")
        return offsets.indices.map { i in v[(i * n)..<(i * n + n)].map(\.0).reduce(0, +) / Double(n) }
    }

    /// Where `values` (increasing with `offsets`) cross `level`, by linear
    /// interpolation.
    func crossing(_ offsets: [Double], _ values: [Double], _ level: Double) -> Double? {
        for i in 1..<offsets.count where values[i - 1] < level && values[i] >= level {
            let t = (level - values[i - 1]) / (values[i] - values[i - 1])
            return offsets[i - 1] + t * (offsets[i] - offsets[i - 1])
        }
        return nil
    }

    /// The plan's look metrics, for a plate's straight edge at Δd from 1 m
    /// to 30 m in front of a receiver, at 4096² and 1024², with 16 and 32
    /// taps: the shadow's 50% line within a texel of the geometric edge, and
    /// the penumbra's width (10-90%, scaled to the full width by the disc's
    /// profile) within 20% of 0.0093·Δd. Under a texel, the penumbra is the
    /// hardware filter's, about a texel.
    func testEdgeAndPenumbraAgainstTheSunsDisc() throws {
        let plate = Plate()
        let probe = try Probe(device: try device())
        for (size, taps) in [(4096, 16), (4096, 32), (1024, 16)] {
            var settings = ShadowSettings()
            settings.mapSize = size
            settings.filterSamples = taps
            let (r, pass) = try shadowRenderer()
            try draw(Self.scene([plate.vessel], toSun: plate.toSun), r, settings: settings)
            let map = try XCTUnwrap(pass.maps.first)
            XCTAssertEqual(pass.maps.count, 1)
            for depth in [1.0, 3.0, 10.0, 30.0] {
                let width = ShadowFitting.penumbraWidth(separation: depth)
                let span = max(width, 4 * map.texel)
                let offsets = stride(from: -1.5 * span, through: 1.5 * span, by: span / 40).map { $0 }
                let v = try profile(plate, depth: depth, offsets: offsets, pass: pass, probe: probe)
                XCTAssertLessThan(v.first!, 0.02, "umbra inside")
                XCTAssertGreaterThan(v.last!, 0.98, "lit outside")
                let s10 = try XCTUnwrap(crossing(offsets, v, 0.1)), s50 = try XCTUnwrap(crossing(offsets, v, 0.5))
                let s90 = try XCTUnwrap(crossing(offsets, v, 0.9))
                let measured = (s90 - s10) / Self.tenToNinety
                let label = String(format: "%d², %d taps, Δd %.0f m: edge %+.2f texels, penumbra %.1f mm (disc %.1f mm, "
                                   + "texel %.1f mm)", size, taps, depth, s50 / map.texel, measured * 1e3, width * 1e3,
                                   map.texel * 1e3)
                print(label)
                XCTAssertLessThanOrEqual(abs(s50), map.texel, label)
                if width > 3 * map.texel {
                    XCTAssertEqual(measured / width, 1, accuracy: 0.2, label)
                } else {
                    XCTAssertLessThan(measured, width + 3 * map.texel, label)
                }
            }
        }
    }

    /// No shimmer from the camera on the GPU: the same receivers, fixed to
    /// the plate, see the same shadow from a camera 6 m away (the maps ride
    /// on the caster, and only float rounding differs).
    func testCameraMotionLeavesTheShadowsInPlace() throws {
        let plate = Plate()
        let probe = try Probe(device: try device())
        var points: [Vec3] = []
        for depth in [0.5, 3.0, 12.0] {
            for s in stride(from: -0.2, through: 0.2, by: 0.005) { points.append(plate.receiver(depth: depth, s: s, along: 0.3)) }
        }
        func visibility(cameraOffset: Vec3) throws -> [Double] {
            let (r, pass) = try shadowRenderer()
            try draw(Self.scene([plate.vessel], toSun: plate.toSun, cameraOffset: cameraOffset), r)
            return try probe.run(points.map { $0 - cameraOffset }, normals: Array(repeating: plate.toSun, count: points.count),
                                 pass: pass).map(\.0)
        }
        let a = try visibility(cameraOffset: .zero), b = try visibility(cameraOffset: Vec3(3.1, -2.7, 4.3))
        XCTAssertGreaterThan(Set(a.map { ($0 * 100).rounded() }).count, 10, "the probe crosses penumbrae")
        let worst = zip(a, b).map { abs($0 - $1) }.max()!, mean = zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
        XCTAssertLessThan(worst, 0.02)
        XCTAssertLessThan(mean, 0.002)
    }

    /// A small vessel's shadow far behind it, where the Sun's disc is much
    /// wider than the vessel seen from there (the plate seen from the ground
    /// under a vessel in orbit): next to nothing, not a black spot.
    func testShadowFadesFarBehindASmallCaster() throws {
        let plate = Plate(side: 4)
        let (r, pass) = try shadowRenderer()
        try draw(Self.scene([plate.vessel], toSun: plate.toSun), r)
        let probe = try Probe(device: r.device)
        let centre = plate.edge                         // the plate's half width
        let points = (0..<64).map { k in plate.receiver(depth: 10_000, s: -centre + Double(k % 8) * 0.3, along: Double(k / 8) * 0.3 - 1) }
        let v = try probe.run(points, normals: Array(repeating: plate.toSun, count: points.count), pass: pass)
        // The plate covers (4 m / (2·10 km·tan α))² ≈ 0.2% of the Sun's disc there.
        XCTAssertGreaterThan(v.map(\.0).reduce(0, +) / Double(v.count), 0.97)
    }

    /// With shadows off, or nothing to cast, no map is drawn and every
    /// receiver is lit.
    func testNoMapsMeansLit() throws {
        let plate = Plate()
        let (r, pass) = try shadowRenderer()
        var off = ShadowSettings()
        off.enabled = false
        try draw(Self.scene([plate.vessel], toSun: plate.toSun), r, settings: off)
        XCTAssertTrue(pass.maps.isEmpty)
        XCTAssertNil(pass.lastAtlas)
        XCTAssertEqual(pass.lastLighting.shadowParams.x, 0)
        try draw(Self.scene([plate.vessel], toSun: plate.toSun), r)
        XCTAssertEqual(pass.maps.count, 1)
        // The probe with the frame's uniforms but no maps in use: lit, no map.
        var lighting = pass.lastLighting
        lighting.shadowParams.x = 0
        let probe = try Probe(device: r.device)
        let v = try probe.run([plate.receiver(depth: 2, s: -0.5, along: 0)], normals: [plate.toSun], pass: pass,
                              lighting: lighting)
        XCTAssertEqual(v[0].0, 1)
        XCTAssertEqual(v[0].1, -1)
    }

    // MARK: Cost

    /// The shadow pass's own GPU time, s: frames that draw nothing but
    /// four copies of it (each its own maps) and empty frames, interleaved
    /// back to back so both see the GPU at one clock; the difference of
    /// their medians over four.
    func shadowCost(_ scene: RenderScene, settings: ShadowSettings = ShadowSettings(), frames: Int = 300,
                    copies: Int = 4) throws -> Double {
        let device = try device()
        final class Times: @unchecked Sendable {
            let lock = NSLock()
            var values: [[Double]] = [[], []]
            func add(_ t: Double, _ k: Int) { lock.withLock { values[k].append(t) } }
        }
        let renderers = try [(0..<copies).map { _ in ShadowPass() } as [RenderPass], []].map { passes in
            let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                      plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 1))
            r.settings.shadow = settings
            return r
        }
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 16, height: 16))
        let times = Times()
        for i in 0..<frames {
            for (k, r) in renderers.enumerated() {
                r.render(scene, to: target.texture) { cb in if i >= 30 { times.add(cb.gpuEndTime - cb.gpuStartTime, k) } }
            }
        }
        for r in renderers { r.renderAndWait(scene, into: target) }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        return (median(times.values[0]) - median(times.values[1])) / Double(copies)
    }

    /// The sun-shadow view's own GPU time at the scene's viewport, s: whole
    /// frames (the default passes) with it against the same frames with
    /// F0's normals view, interleaved, medians. An upper bound on the
    /// receivers' cost: every pixel evaluates `orbit_sunShadow`, after
    /// reconstructing its normal from depth.
    func receiverCost(_ scene: RenderScene, frames: Int = 120) throws -> Double {
        let device = try device()
        final class Times: @unchecked Sendable {
            let lock = NSLock()
            var values: [[Double]] = [[], []]
            func add(_ t: Double, _ k: Int) { lock.withLock { values[k].append(t) } }
        }
        let renderers = try [DebugView.sunShadow, .normals].map { view in
            let r = try SceneRenderer(device: device, loadsUserTextures: false)
            r.settings.debug.view = view
            return r
        }
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
        let times = Times()
        for i in 0..<frames {
            for (k, r) in renderers.enumerated() {
                r.render(scene, to: target.texture) { cb in if i >= 20 { times.add(cb.gpuEndTime - cb.gpuStartTime, k) } }
            }
        }
        for r in renderers { r.renderAndWait(scene, into: target) }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        return median(times.values[0]) - median(times.values[1])
    }

    func padScene(distance: Double = 170, yaw: Double? = nil, pitch: Double? = nil,
                  scenario name: String = "as506-pad", advance: [String] = []) throws -> RenderScene {
        let scenario = try XCTUnwrap(Scenario.named(name))
        let sim = scenario.build(Self.system)
        try ScenarioScript(advance).run(on: sim, missionClockZero: scenario.missionClockZero) { _ in }
        var camera = OrbitCamera()
        let v = try XCTUnwrap(sim.focus)
        camera.target = .vessel(v.id)
        camera.distance = distance
        if let yaw { camera.yaw = yaw * Double.pi / 180 }
        if let pitch { camera.pitch = pitch * Double.pi / 180 }
        camera.update(sim: sim)
        return SceneExtractor().extract(sim: sim, camera: camera, viewport: RenderScene.Viewport(width: 3024, height: 1964),
                                        realTime: 0)
    }

    func testCostReport() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_SHADOW_COST"] == "1" else { throw XCTSkip("cost report") }
        let lock = GPULock()
        defer { withExtendedLifetime(lock) {} }
        let scenes = [("pad 170 m", try padScene()), ("pad 40 m", try padScene(distance: 40)),
                      ("pad 15 m", try padScene(distance: 15)),
                      ("liftoff 8 s", try padScene(distance: 160, advance: ["met:8"])),
                      ("LEO 70 m", try padScene(distance: 70, scenario: "as506-parking-orbit")),
                      ("LEO 12 m", try padScene(distance: 12, scenario: "as506-parking-orbit"))]
        for (name, scene) in scenes {
            var s = ShadowSettings()
            let (r, pass) = try shadowRenderer()
            try draw(scene, r)
            let maps = pass.maps.map { $0.level == .detail ? "detail" : String(format: "%.0f m", 2 * $0.halfWidth) }
            print(String(format: "COST %@ %@: %.3f ms (1 copy %.3f, 2 copies %.3f)", name, "\(maps)",
                         try shadowCost(scene, settings: s) * 1e3, try shadowCost(scene, settings: s, copies: 1) * 1e3,
                         try shadowCost(scene, settings: s, copies: 2) * 1e3))
            s.maxMaps = 2
            print(String(format: "COST %@ Medium (2 maps): %.3f ms", name, try shadowCost(scene, settings: s) * 1e3))
            print(String(format: "COST %@ receivers (sun-shadow view, full frame): %.3f ms", name,
                         try receiverCost(scene) * 1e3))
        }
    }

    // MARK: Pad (diagnostic)

    // MARK: The pad

    /// AS-506 on LC-39A at Apollo 11's launch (the Sun 36° up in the east),
    /// seen as R2 and E2 will sample it:
    /// - the stack's Sun side lit, its back turned from the Sun;
    /// - the hardstand in the stack's shadow behind it, from the ML's edge
    ///   out past 100 m, and lit on the Sun's side;
    /// - the pad on itself: the ML deck in the LUT's shadow west of it, and
    ///   lit east of it.
    func testThePadsShadows() throws {
        let scene = try padScene()
        let (r, pass) = try shadowRenderer()
        try draw(scene, r)
        XCTAssertEqual(pass.maps.map(\.level), [.cluster, .cluster], "the vehicle's map and the site's")
        let probe = try Probe(device: r.device)
        let site = try XCTUnwrap(scene.sites.first), vessel = try XCTUnwrap(scene.vessels.first)
        let up = site.orientation * Vec3.unitZ, toSun = scene.sun.direction
        XCTAssertEqual(asin(up.dot(toSun)) * 180 / Double.pi, 36.5, accuracy: 0.5, "the Sun's elevation")
        func at(_ p: Vec3) -> Vec3 { site.origin + site.orientation * p }   // site frame to camera-relative
        let axis = vessel.attitude.rotate(.unitX)
        let across = (toSun - axis * axis.dot(toSun)).normalized
        let level = toSun - up * up.dot(toSun), away = -level.normalized   // along the shadows, on the ground

        // The stack's skin on the S-II, 25 m above its centre of mass.
        let skin = try probe.run([vessel.position + axis * 25 + across * 5.6, vessel.position + axis * 25 - across * 5.6],
                                 normals: [across, -across], pass: pass)
        XCTAssertGreaterThan(skin[0].0, 0.95, "the stack's Sun side")
        XCTAssertEqual(skin[1].1, -2, "its back is turned from the Sun")

        // The hardstand along the stack's shadow, and towards the Sun.
        let base = at(Vec3(0, 0, LC39A.hardstandHeight + 0.02))
        let behind = [30.0, 45, 70, 100, 130].map { base + away * $0 }
        let shade = try probe.run(behind, normals: Array(repeating: up, count: behind.count), pass: pass)
        for (d, v) in zip([30.0, 45, 70, 100, 130], shade) {
            XCTAssertLessThan(v.0, 0.1, "the hardstand \(d) m behind the stack")
        }
        let sunward = try probe.run([base - away * 40], normals: [up], pass: pass)
        XCTAssertGreaterThan(sunward[0].0, 0.95, "the hardstand on the Sun's side")

        // The ML deck beside the LUT: in its shadow to the west, lit to the east.
        let deck = try probe.run([at(Vec3(LC39A.towerFaceX + 6, 15, 0.02)), at(Vec3(LC39A.towerFaceX + 6, -15, 0.02))],
                                 normals: [up, up], pass: pass)
        XCTAssertLessThan(deck[0].0, 0.1, "the deck west of the LUT")
        XCTAssertGreaterThan(deck[1].0, 0.95, "the deck east of it")

        // The vehicle's welded caster mesh (ready a moment later) draws the
        // same shadows as its plain positions did.
        let points = (0..<400).map { k in vessel.position + axis * (Double(k % 20) * 4 - 40) + across * 5.6
            + up.cross(axis).normalized * (Double(k / 20) * 0.6 - 6) }
        let normals = Array(repeating: across, count: points.count)
        let weldedAlready = pass.isWelded
        let plain = try probe.run(points, normals: normals, pass: pass)
        let deadline = Date().addingTimeInterval(5)
        while !pass.isWelded, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(pass.isWelded)
        try draw(scene, r)
        let welded = try probe.run(points, normals: normals, pass: pass)
        XCTAssertEqual(plain.map(\.0), welded.map(\.0))
        if weldedAlready { print("note: the weld finished before the first frame; plain and welded not compared") }
    }

}

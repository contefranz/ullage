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

    /// The grain stays on the casters: when the detail map's window steps
    /// (the centre of mass, which the camera orbits, drifting on the
    /// vessel), every receiver on the vessel keeps its filtered value, the
    /// penumbrae's noise included. Before the fix the filter's rotation was
    /// keyed to the window's texel index and re-rolled at every step.
    func testDetailWindowStepKeepsTheGrain() throws {
        let (r, pass) = try shadowRenderer()
        let probe = try Probe(device: r.device)
        // The shadow cubes close up: a detail map on the plate.
        func scene(comShift: Vec3) -> RenderScene {
            var s = ShadowLookDevTests.scene(distance: 6)
            s.vessels[0].position = s.vessels[0].position + comShift
            s.vessels[0].structureOrigin = s.vessels[0].structureOrigin - comShift
            return s
        }
        let base = scene(comShift: .zero)
        try draw(base, r)
        XCTAssertEqual(pass.maps.map(\.level), [.detail, .cluster])
        let detail = pass.maps[0]
        // The plate's top (its construction origin) under the sheet's and the
        // floating cube's shadows, where the penumbrae are.
        let top = base.vessels[0].position + base.vessels[0].structureOrigin
        var points: [Vec3] = []
        for i in 0..<60 {
            for j in 0..<40 {
                points.append(top + Vec3(-1.5 + Double(i) * 0.1, -2 + Double(j) * 0.1, 0.001))
            }
        }
        let normals = Array(repeating: Vec3.unitZ, count: points.count)
        let before = try probe.run(points, normals: normals, pass: pass)
        XCTAssertEqual(Set(before.map(\.1)), [0], "all in the detail map")
        let partial = before.filter { $0.0 > 0.05 && $0.0 < 0.95 }.count
        XCTAssertGreaterThan(partial, 40, "receivers in penumbrae, where the noise shows")

        // One block of the window's grid along the map's right.
        let block = detail.texel * Double(ShadowFitting.noisePeriod)
        try draw(scene(comShift: detail.basis.r0 * block), r)
        let moved = pass.maps[0]
        XCTAssertEqual(moved.level, .detail)
        XCTAssertEqual(moved.basis.r0.dot(moved.centre - detail.centre) / detail.texel,
                       Double(ShadowFitting.noisePeriod), accuracy: 1e-3, "the window stepped one block")
        let after = try probe.run(points, normals: normals, pass: pass)
        let worst = zip(before, after).map { abs($0.0 - $1.0) }.max()!
        XCTAssertLessThan(worst, 1e-3, "a receiver's filtered value is the same after the step")
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

    /// The median GPU time of each renderer's frames of `scene` into
    /// `target`, s: blocks of frames from one renderer at a time, back to
    /// back so the GPU's clock stays up, alternating between them so both
    /// see the same conditions. One renderer at a time, because each has a
    /// command queue of its own and two queues' frames would overlap on the
    /// GPU and share each other's time. The first round warms up.
    func medianFrameTimes(_ renderers: [SceneRenderer], _ scene: RenderScene, into target: OffscreenTarget,
                          rounds: Int = 7, block: Int = 24) -> [Double] {
        final class Times: @unchecked Sendable {
            let lock = NSLock()
            var values: [Double] = []
            func add(_ t: Double) { lock.withLock { values.append(t) } }
        }
        let times = renderers.map { _ in Times() }
        for round in 0..<rounds {
            for (k, r) in renderers.enumerated() {
                for _ in 0..<block {
                    r.render(scene, to: target.texture) { cb in
                        if round > 0 { times[k].add(cb.gpuEndTime - cb.gpuStartTime) }
                    }
                }
                r.renderAndWait(scene, into: target)
            }
        }
        return times.map { t in
            let v = t.values.sorted()
            return v[v.count / 2]
        }
    }

    /// The shadow pass's own GPU time, s: frames that draw nothing but
    /// `copies` of it (each with its own maps) against empty frames, the
    /// difference of their medians over the copies.
    func shadowCost(_ scene: RenderScene, settings: ShadowSettings = ShadowSettings(), copies: Int = 4) throws -> Double {
        let device = try device()
        let renderers = try [(0..<copies).map { _ in ShadowPass() } as [RenderPass], []].map { passes in
            let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                      plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 1))
            r.settings.shadow = settings
            return r
        }
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 16, height: 16))
        let t = medianFrameTimes(renderers, scene, into: target)
        return (t[0] - t[1]) / Double(copies)
    }

    /// A scenario's focus vessel seen from `distance` (m; OrbitCamera keeps
    /// the camera 1.2 bounding radii out, 66 m for the Saturn V) with a
    /// vertical field of view `fovY` (rad, the external camera's 50° by
    /// default), at 3024×1964 unless `viewport` says otherwise.
    static func padScene(distance: Double = 170, yaw: Double? = nil, pitch: Double? = nil, fovY: Double? = nil,
                  scenario name: String = "as506-pad", advance: [String] = [],
                  viewport: RenderScene.Viewport = RenderScene.Viewport(width: 3024, height: 1964)) throws -> RenderScene {
        let scenario = try XCTUnwrap(Scenario.named(name))
        let sim = scenario.build(Self.system)
        try ScenarioScript(advance).run(on: sim, missionClockZero: scenario.missionClockZero) { _ in }
        var camera = OrbitCamera()
        let v = try XCTUnwrap(sim.focus)
        camera.target = .vessel(v.id)
        camera.distance = distance
        if let yaw { camera.yaw = yaw * Double.pi / 180 }
        if let pitch { camera.pitch = pitch * Double.pi / 180 }
        if let fovY { camera.fovY = fovY }
        camera.update(sim: sim)
        return SceneExtractor().extract(sim: sim, camera: camera, viewport: viewport, realTime: 0)
    }

    /// The shadow pass's GPU time per scene, with the GPU lock
    /// (ORBITSIM_SHADOW_COST=1; `scripts/test.sh fast --no-parallel --filter
    /// ShadowPassTests/testCostReport`), at High (up to 4 maps) and Medium (2),
    /// and without the detail map where there is one. The pass's time does
    /// not depend on the filter's taps; the receivers' does
    /// (`testReceiverProbeCost`). The detail map shows only with a long lens
    /// or a small vessel, since OrbitCamera keeps the camera 1.2 bounding
    /// radii out: the 250 mm cases (12.6°) have one.
    func testCostReport() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_SHADOW_COST"] == "1" else { throw XCTSkip("cost report") }
        let lock = GPULock()
        defer { withExtendedLifetime(lock) {} }
        let lens = OrbitCamera.hasselblad250mm
        let scenes = [("pad 170 m", try Self.padScene()),
                      ("pad 70 m, 250 mm", try Self.padScene(distance: 70, pitch: 40, fovY: lens)),
                      ("liftoff 8 s", try Self.padScene(distance: 160, advance: ["met:8"])),
                      ("LEO 70 m", try Self.padScene(distance: 70, scenario: "as506-parking-orbit")),
                      ("LEO 25 m, 250 mm", try Self.padScene(distance: 25, fovY: lens, scenario: "as506-parking-orbit"))]
        for (name, scene) in scenes {
            let (r, pass) = try shadowRenderer()
            try draw(scene, r)
            let maps = pass.maps.map { $0.level == .detail ? String(format: "detail %.0f m", 2 * $0.halfWidth)
                                                           : String(format: "%.0f m", 2 * $0.halfWidth) }
            var medium = ShadowSettings(), noDetail = ShadowSettings()
            medium.maxMaps = 2
            noDetail.detailMap = false
            let detail = pass.maps.first?.level == .detail
                ? String(format: ", %.3f ms without its detail map", try shadowCost(scene, settings: noDetail, copies: 1) * 1e3)
                : ""
            print(String(format: "COST %@ %@: pass High %.3f ms, Medium %.3f ms%@ (4 copies a frame: %.3f ms each)", name,
                         maps.joined(separator: " + "), try shadowCost(scene, copies: 1) * 1e3,
                         try shadowCost(scene, settings: medium, copies: 1) * 1e3, detail, try shadowCost(scene) * 1e3))
        }
    }

    /// The receivers' cost alone: `orbit_sunShadow` at 6 million points on
    /// the pad's ground (3000 × 2000 over 600 m × 400 m about the site,
    /// facing up, nearly all inside a map), one compute dispatch, the median
    /// of 9 back to back, at 16 and 32 filter taps, less the same dispatch
    /// with no maps (with the GPU lock; ORBITSIM_SHADOW_COST=1).
    func testReceiverProbeCost() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_SHADOW_COST"] == "1" else { throw XCTSkip("cost report") }
        let lock = GPULock()
        defer { withExtendedLifetime(lock) {} }
        let scene = try Self.padScene()
        let (r, pass) = try shadowRenderer()
        try draw(scene, r)
        let site = try XCTUnwrap(scene.sites.first)
        let (nx, ny) = (3000, 2000)
        var points = [SIMD4<Float>](), normals = [SIMD4<Float>]()
        points.reserveCapacity(nx * ny)
        let up = site.orientation * Vec3.unitZ
        let n = SIMD4<Float>(Float(up.x), Float(up.y), Float(up.z), 0)
        for j in 0..<ny {
            for i in 0..<nx {
                let p = site.origin + site.orientation * Vec3(Double(i) * 0.2 - 300, Double(j) * 0.2 - 200,
                                                              LC39A.hardstandHeight + 0.02)
                points.append(SIMD4(Float(p.x), Float(p.y), Float(p.z), 1))
            }
        }
        normals = Array(repeating: n, count: points.count)
        let probe = try Probe(device: r.device)
        let device = r.device
        let pb = try XCTUnwrap(device.makeBuffer(bytes: points, length: 16 * points.count, options: .storageModeShared))
        let nb = try XCTUnwrap(device.makeBuffer(bytes: normals, length: 16 * normals.count, options: .storageModeShared))
        let out = try XCTUnwrap(device.makeBuffer(length: 8 * points.count, options: .storageModePrivate))
        let atlas = try XCTUnwrap(pass.lastAtlas)
        func time(_ lighting: LightingUniforms) throws -> Double {
        var lighting = lighting
        var times: [Double] = []
        for _ in 0..<9 {
            let cb = try XCTUnwrap(probe.queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
            enc.setComputePipelineState(probe.pipeline)
            enc.setBuffer(pb, offset: 0, index: 0)
            enc.setBuffer(nb, offset: 0, index: 1)
            enc.setBuffer(out, offset: 0, index: 2)
            enc.setBytes(&lighting, length: MemoryLayout<LightingUniforms>.stride, index: 3)
            enc.setTexture(atlas, index: 0)
            enc.setSamplerState(probe.sampler, index: 0)
            enc.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            times.append(cb.gpuEndTime - cb.gpuStartTime)
        }
        return times.sorted()[4]
        }
        // No maps: the probe's own reading and writing, which a fragment
        // function does not pay.
        var none = pass.lastLighting, taps16 = pass.lastLighting, taps32 = pass.lastLighting
        none.shadowParams.x = 0
        taps16.shadowParams.y = 16
        taps32.shadowParams.y = 32
        let base = try time(none)
        let t16 = try time(taps16) - base, t32 = try time(taps32) - base
        print(String(format: "PROBE %d receivers on the pad's ground, net of the probe's %.3f ms: 16 taps %.3f ms, "
                     + "32 taps %.3f ms (%.2f and %.2f ns each; a full 3024×1964 screen of receivers %.2f and %.2f ms)",
                     points.count, base * 1e3, t16 * 1e3, t32 * 1e3, t16 / Double(points.count) * 1e9,
                     t32 / Double(points.count) * 1e9, t16 / Double(points.count) * 3024 * 1964 * 1e3,
                     t32 / Double(points.count) * 3024 * 1964 * 1e3))
    }

    // MARK: Dark casters

    /// Casters the Sun does not light cast nothing, as the vessel pass lights
    /// them: on the pad, the stack in the Earth's shadow (its Sun share 0)
    /// leaves only the site's map; with the Sun also 2° below the site's
    /// horizon there are no maps: the pass draws nothing and leaves
    /// `shadowParams.x` at 0, so every receiver returns 1 at once (LEO's
    /// night, a night on the pad).
    func testDarkCastersDrawNoMaps() throws {
        var scene = try Self.padScene()
        let (r, pass) = try shadowRenderer()
        try draw(scene, r)
        XCTAssertEqual(pass.maps.map(\.level), [.cluster, .cluster], "the vehicle's map and the site's")

        for i in scene.vessels.indices { scene.vessels[i].light.sunlit = 0 }
        try draw(scene, r)
        XCTAssertEqual(pass.maps.count, 1, "the site's map alone")
        XCTAssertEqual(pass.maps.first?.casters.count, 1, "the site alone casts")

        let site = try XCTUnwrap(scene.sites.first)
        let up = site.orientation * Vec3.unitZ, toSun = scene.sun.direction
        let level = (toSun - up * up.dot(toSun)).normalized, dip = -2 * Double.pi / 180
        scene.sun.direction = level * cos(dip) + up * sin(dip)
        scene.sun.position = scene.sun.direction * scene.sun.distance
        XCTAssertFalse(ShadowPass.isLit(site, sun: scene.sun))
        try draw(scene, r)
        XCTAssertTrue(pass.maps.isEmpty)
        XCTAssertNil(pass.lastAtlas, "no atlas drawn: the frame's shadowParams.x stays 0")
    }

    // MARK: Caster caches

    /// The casters follow the vessels, as R2's mesh cache does: a fresh
    /// vessel in place of the last (new parts, as a scenario loaded again)
    /// leaves only its own vessel and part casters, however often it
    /// happens, so no freed geometry stays alive.
    func testCasterCachesFollowTheVessels() throws {
        let (r, pass) = try shadowRenderer()
        for k in 0..<6 {
            let shapes = [VisualShape.box(from: .zero, length: 2, width: 2, height: 2, axis: .unitZ, color: Self.white),
                          VisualShape.box(from: Vec3(0, 0, 4 + Double(k)), length: 0.2, width: 3, height: 3,
                                          axis: .unitZ, color: Self.white)]
            let v = Self.vessel(shapes, position: Vec3(0, 0, -20))
            try draw(Self.scene([v], toSun: Vec3(0.3, 0.2, 1)), r)
            XCTAssertNotNil(pass.casterTriangles(of: v.id))
            XCTAssertEqual(pass.cachedCasters.vessels, 1, "vessel casters after load \(k)")
            XCTAssertEqual(pass.cachedCasters.parts, 1, "part casters after load \(k)")
        }
    }

    /// A part's caster goes once its part entry is freed, even frames after
    /// the vessels changed: here the old vessel's parts are held past the
    /// swap (as a bake or a wire draw may hold them) and then let go.
    func testOrphanPartCastersGo() throws {
        let (r, pass) = try shadowRenderer()
        func vessel(_ k: Int) -> RenderScene.Vessel {
            Self.vessel([VisualShape.box(from: .zero, length: 2 + Double(k), width: 2, height: 2, axis: .unitZ,
                                         color: Self.white)], position: Vec3(0, 0, -20))
        }
        let a = vessel(0), b = vessel(1)
        try draw(Self.scene([a], toSun: Vec3(0.3, 0.2, 1)), r)
        var held: [PartEntry]? = try XCTUnwrap(r.meshes.mesh(a.id)).parts
        try draw(Self.scene([b], toSun: Vec3(0.3, 0.2, 1)), r)
        XCTAssertEqual(pass.cachedCasters.parts, 2, "the old part still lives")
        XCTAssertEqual(held?.count, 1)
        held = nil
        try draw(Self.scene([b], toSun: Vec3(0.3, 0.2, 1)), r)
        XCTAssertEqual(pass.cachedCasters.vessels, 1)
        XCTAssertEqual(pass.cachedCasters.parts, 1, "its caster goes with it")
    }

    // MARK: The pad

    /// AS-506 on LC-39A at Apollo 11's launch (the Sun 36° up in the east),
    /// seen as R2 and E2 will sample it:
    /// - the stack's Sun side lit, its back turned from the Sun;
    /// - the hardstand in the stack's shadow behind it, from the ML's edge
    ///   out past 100 m, and lit on the Sun's side;
    /// - the pad on itself: the ML deck in the LUT's shadow west of it, and
    ///   lit east of it.
    func testThePadsShadows() throws {
        let scene = try Self.padScene()
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

        // The maps draw each part's own mesh (the shadow-only renderer's
        // parts are never subdivided), not R5's 898k triangles.
        let parts = try XCTUnwrap(r.meshes.mesh(vessel.id)).parts
        XCTAssertTrue(parts.allSatisfy { $0.mesh.subdividedEdge == nil })
        let triangles = parts.map { $0.mesh.indexCount / 3 }.reduce(0, +)
        XCTAssertEqual(pass.casterTriangles(of: vessel.id), triangles)
        XCTAssertLessThan(triangles, 200_000)
    }

}

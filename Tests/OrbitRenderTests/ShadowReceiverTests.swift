import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// R4's maps in R2's shading: the vessel pass's Sun term times
/// `orbit_sunShadow`, before `orbit_exposed`'s one exit, on the opaque
/// draws (P1), the wires (P2, after A2's composite) and LC-39A's elements.
/// Each scene is drawn by the default renderer with the maps and without,
/// and R1's captured light compared where ShadowCommon's probe says a
/// receiver is in umbra or fully lit: only the Sun's share of the light
/// goes, the rest (sky, earthshine, the night floor) stays.
@MainActor
final class ShadowReceiverTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    static let degree = Double.pi / 180

    /// The default renderer at a fixed exposure (EV 15), so the two frames
    /// compare pixel for pixel; the clouds off, so their shadow (C2's, on the
    /// same Sun term: CloudShadowReceiverTests) leaves the maps' share alone.
    func renderer() throws -> SceneRenderer {
        let r = try SceneRenderer(device: try XCTUnwrap(RenderDevice.shared), loadsUserTextures: false)
        XCTAssertEqual(r.failures, [:])
        r.settings = VesselPassTests.manual(RenderSettings())
        r.settings.cloud.enabled = false
        return r
    }

    /// The scene's linear light (R1's capture over its pre-exposure), the
    /// luminance of each pixel, with the maps or without.
    func luminance(_ scene: RenderScene, shadows: Bool, renderer r: SceneRenderer) throws -> [Double] {
        r.settings.shadow.enabled = shadows
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: w, height: h))
        let post = try XCTUnwrap(r.post, "R1's post pass")
        post.capturesLight = true
        r.renderAndWait(scene, into: target)
        let c = try XCTUnwrap(post.capturedLight())
        XCTAssertEqual([c.width, c.height], [w, h])
        let k = 1 / post.control.preExposure
        return (0..<w * h).map { i in
            (0.2126 * Double(c.pixels[4 * i]) + 0.7152 * Double(c.pixels[4 * i + 1])
                + 0.0722 * Double(c.pixels[4 * i + 2])) * k
        }
    }

    /// The pixel `p` (camera-relative world) falls in, nil off the screen.
    static func pixel(_ p: Vec3, camera: RenderScene.Camera) -> (x: Int, y: Int)? {
        let v = camera.worldToView * p
        guard v.z < 0 else { return nil }
        let t = tan(camera.fovY / 2), w = camera.viewport.width, h = camera.viewport.height
        let x = (v.x / -v.z / (t * w / h) + 1) / 2 * w, y = (1 - v.y / -v.z / t) / 2 * h
        guard x >= 0, y >= 0, x < w, y < h else { return nil }
        return (Int(x), Int(y))
    }

    /// The probe's reading at `points` (normal `normal`) with every point
    /// within `margin` (m) of each, across the surface, reading the same: a
    /// pixel's footprint all in umbra (true), all lit (false), or neither (nil).
    func classify(_ points: [Vec3], normal: Vec3, margin: Double, pass: ShadowPass,
                  device: MTLDevice) throws -> [Bool?] {
        let a = (abs(normal.x) < 0.9 ? Vec3.unitX : .unitY).cross(normal).normalized, b = normal.cross(a)
        let offsets = [Vec3.zero, a * margin, -a * margin, b * margin, -b * margin]
        let all = points.flatMap { p in offsets.map { p + $0 } }
        let v = try ShadowPassTests.Probe(device: device).run(all, normals: Array(repeating: normal, count: all.count),
                                                              pass: pass)
        return points.indices.map { i in
            let s = v[5 * i..<5 * i + 5].map(\.0)
            if s.allSatisfy({ $0 < 0.01 }) { return true }
            if s.allSatisfy({ $0 > 0.99 }) { return false }
            return nil
        }
    }

    /// The light with the maps over the light without, at each classified
    /// point's pixel: (umbra ratios, lit ratios), each with its point
    /// (camera-relative).
    func ratios(_ scene: RenderScene, points: [Vec3], normal: Vec3, margin: Double)
        throws -> (umbra: [Reading], lit: [Reading]) {
        let r = try renderer()
        let with = try luminance(scene, shadows: true, renderer: r)
        let pass = try XCTUnwrap(r.graph.pass(named: "Shadows") as? ShadowPass)
        let kinds = try classify(points, normal: normal, margin: margin, pass: pass, device: r.device)
        let without = try luminance(scene, shadows: false, renderer: r)
        var umbra: [Reading] = [], lit: [Reading] = []
        let w = Int(scene.camera.viewport.width)
        for (p, kind) in zip(points, kinds) {
            guard let kind, let px = Self.pixel(p, camera: scene.camera) else { continue }
            let i = px.y * w + px.x
            XCTAssertGreaterThan(without[i], 0, "a receiver at \(p) shows")
            let reading = Reading(point: p, ratio: with[i] / max(without[i], 1e-30))
            if kind { umbra.append(reading) } else { lit.append(reading) }
        }
        return (umbra, lit)
    }

    /// A point's light with the maps over its light without.
    struct Reading: CustomStringConvertible {
        let point: Vec3
        let ratio: Double
        var description: String { String(format: "%.3f at (%.2f, %.2f, %.2f)", ratio, point.x, point.y, point.z) }
    }

    /// Checks the umbra's readings under `umbraAtMost` and the lit ones at 1
    /// (to 0.1%), each failure with its point in `frame`.
    func check(_ r: (umbra: [Reading], lit: [Reading]), umbraAtMost: Double, minimum: (Int, Int),
               frame: (Vec3) -> Vec3 = { $0 }) {
        XCTAssertGreaterThanOrEqual(r.umbra.count, minimum.0, "receivers in umbra")
        XCTAssertGreaterThanOrEqual(r.lit.count, minimum.1, "receivers fully lit")
        func at(_ x: Reading) -> String { Reading(point: frame(x.point), ratio: x.ratio).description }
        for x in r.umbra where !(x.ratio < umbraAtMost) { XCTFail("in umbra, \(at(x))") }
        for x in r.lit where !(abs(x.ratio - 1) < 1e-3) { XCTFail("lit, \(at(x))") }
    }

    /// `v` with its stand-in light's Sun (the vessel pass's object
    /// lighting) along the scene's.
    static func lit(_ v: RenderScene.Vessel, by sun: RenderScene.Sun) -> RenderScene.Vessel {
        var v = v
        v.light.toSun = sun.direction
        return v
    }

    // MARK: Opaque draws

    /// The look-dev cubes (ShadowLookDevTests) at 34 m: the plate about the
    /// floating cube's shadow, 5 m from its foot towards azimuth 40°, in
    /// sight of the camera. In umbra the plate keeps only its sky and
    /// earthshine stand-in (under a fifth of its sunlit light); lit, its
    /// light is the same to 0.1%.
    func testOpaqueDrawsReceiveTheShadows() throws {
        var scene = ShadowLookDevTests.scene(distance: 34)
        scene.vessels[0] = Self.lit(scene.vessels[0], by: scene.sun)
        let v = scene.vessels[0]
        func at(_ p: Vec3) -> Vec3 { v.position + v.attitude.rotate(v.structureOrigin + p) }
        var points: [Vec3] = []
        for i in -8...8 { for j in -8...8 { points.append(at(Vec3(6.8 + 0.2 * Double(i), -0.8 + 0.2 * Double(j), 0))) } }
        let readings = try ratios(scene, points: points, normal: v.attitude.rotate(.unitZ), margin: 0.12)
        check(readings, umbraAtMost: 0.2, minimum: (15, 60)) { v.attitude.inverseRotate($0 - v.position) - v.structureOrigin }
    }

    // MARK: Wires

    /// A wire (a tube 4 cm in radius, which the vessel pass draws through
    /// its P2 wire pipeline) 10 m in front of the camera against empty
    /// space, half of it under a plate 4 m above it (out of the view): its
    /// light where the plate shades it is its stand-in's alone; where the
    /// Sun reaches it, the same with the maps and without.
    func testWiresReceiveTheShadows() throws {
        let grey = (0.8, 0.8, 0.8)
        let wire = VisualShape.frustum(from: Vec3(-3, 0, 0), length: 6, baseRadius: 0.04, topRadius: 0.04,
                                       axis: .unitX, color: grey)
        XCTAssertTrue(PartMesh.isWire(wire))
        let plate = VisualShape.box(from: Vec3(2, 0, 4), length: 0.2, width: 4, height: 4, axis: .unitZ,
                                    reference: .unitX, color: grey)
        let toSun = Vec3(0, -0.2, 1).normalized, sun = toSun * 1.496e11
        var v = ShadowPassTests.vessel([wire, plate], position: .zero, name: "Wire")
        v.position = Vec3(0, 10, 0) - v.attitude.rotate(v.structureOrigin)
        v.light.toSun = toSun
        let scene = RenderScene(clock: RenderScene.Clock(simTime: Epoch(tdbSecondsPastJ2000: 0)),
                                camera: RenderScene.Camera(position: .zero, worldToView: Mat3(rows: .unitX, .unitZ, -.unitY),
                                                           fovY: 20 * Self.degree,
                                                           viewport: RenderScene.Viewport(width: 640, height: 400),
                                                           target: .vessel(v.id)),
                                sun: RenderScene.Sun(position: sun, direction: toSun, distance: sun.length,
                                                     illuminance: 1.3e5, angularRadius: ShadowFitting.sunAngularRadius),
                                vessels: [v], sites: [])
        XCTAssertNil(Self.pixel(Vec3(0, 8, 4), camera: scene.camera), "the plate is out of the view")
        // The tube's upper side, turned to the Sun and the camera.
        let normal = Vec3(0, -0.5, 1).normalized
        let points = stride(from: -2.6, through: 2.6, by: 0.1).map { Vec3($0, 10, 0) + normal * 0.04 }
        let readings = try ratios(scene, points: points, normal: normal, margin: 0.03)
        check(readings, umbraAtMost: 0.2, minimum: (15, 15))
    }

    // MARK: The pad

    /// AS-506 on LC-39A at Apollo 11's launch (the Sun 36.5° up in the
    /// east), seen from the south and above (yaw 180°, pitch 65°, 230 m
    /// out): LC-39A's elements, which the vessel pass draws, in the stack's
    /// shadow to the west of it (the ML deck from 13 m out, clear of the
    /// vehicle's base and the tail service masts in the camera's view, and the
    /// hardstand beyond the ML's own shadow), lit to the east and south.
    func testThePadReceivesTheShadows() throws {
        let scene = try ShadowPassTests.padScene(distance: 230, yaw: 180, pitch: 65,
                                                 viewport: RenderScene.Viewport(width: 640, height: 416))
        let site = try XCTUnwrap(scene.sites.first)
        func at(_ x: Double, _ y: Double, _ z: Double) -> Vec3 { site.origin + site.orientation * Vec3(x, y, z) }
        let deck = 0.02, hardstand = LC39A.hardstandHeight + 0.02
        var points: [Vec3] = []
        for x in stride(from: -3.0, through: 3, by: 1.5) {
            for y in stride(from: 13.4, through: 19, by: 1.4) { points.append(at(x, y, deck)) }    // the deck, west
            for y in stride(from: 41.0, through: 47, by: 2) { points.append(at(x, y, hardstand)) } // the hardstand, west
        }
        for x in stride(from: -12.0, through: -2, by: 2) {
            for y in stride(from: -19.0, through: -9, by: 2) { points.append(at(x, y, deck)) }    // the deck, east
        }
        for x in stride(from: -55.0, through: -25, by: 5) {
            for y in stride(from: 12.0, through: 45, by: 6.6) { points.append(at(x, y, hardstand)) } // the hardstand, south
        }
        let readings = try ratios(scene, points: points, normal: site.orientation * Vec3.unitZ, margin: 1)
        check(readings, umbraAtMost: 0.25, minimum: (20, 30)) { site.orientation.transposed * ($0 - site.origin) }
    }

    // MARK: Cost

    /// What the receivers cost in R2's vessel pass, on the plan's display
    /// (3024 × 1964, 4× MSAA) with R5's subdivided stack (898k triangles):
    /// the pass's split-profile time and the unsplit frame's GPU time, with
    /// the maps and without (`ShadowSettings.enabled`), in alternating
    /// blocks of 5 frames, medians of 25 each; R2's cameras
    /// (`VesselPassTests.testPassTimeReport`), and the stack in the Earth's
    /// shadow. A report (ORBITSIM_SHADOW_COST=1;
    /// it holds the GPU lock).
    func testReceiverCostReport() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_SHADOW_COST"] == "1" else { throw XCTSkip("cost report") }
        let lock = GPULock()
        defer { withExtendedLifetime(lock) {} }
        let (w, h) = (3024, 1964)
        // The last case is the stack in the Earth's shadow: the same view
        // with its Sun share 0 (`LegacyLight.sunlit`).
        let cases: [(String, String, (Double, Double, Double, Double), Bool)] = [
            ("pad, stack and LC-39A", "as506-first-motion", (-1.2, 0.12, 190, 50), false),
            ("pad, the base close", "as506-first-motion", (-0.6, -0.03, 62, 62), false),
            ("LEO, the stack", "as506-parking-orbit", (-0.6, 0.35, 70, 50), false),
            ("LEO, the stack in eclipse", "as506-parking-orbit", (-0.6, 0.35, 70, 50), true),
        ]
        let r = try SceneRenderer(device: try XCTUnwrap(RenderDevice.shared), loadsUserTextures: false)
        r.setStars(try StarCatalog.bundled())
        r.settings.shading.waitForAmbientOcclusion = true
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: w, height: h))
        for (label, id, view, eclipse) in cases {
            let scenario = try XCTUnwrap(Scenario.named(id))
            let sim = scenario.build(Self.system)
            var camera = OrbitCamera()
            camera.target = .vessel(try XCTUnwrap(sim.focus).id)
            (camera.yaw, camera.pitch, camera.distance) = (view.0, view.1, view.2)
            camera.fovY = view.3 * Double.pi / 180
            camera.update(sim: sim)
            var scene = SceneExtractor().extract(sim: sim, camera: camera,
                                                 viewport: RenderScene.Viewport(width: Double(w), height: Double(h)),
                                                 realTime: 0)
            if eclipse { for i in scene.vessels.indices { scene.vessels[i].light.sunlit = 0 } }
            for _ in 0..<3 { r.renderAndWait(scene, into: target) }
            var vessels: [Bool: [Double]] = [:], shadows: [Bool: [Double]] = [:], frames: [Bool: [Double]] = [:]
            for block in 0..<10 {
                let on = block % 2 == 0
                r.settings.shadow.enabled = on
                r.renderAndWait(scene, into: target)
                r.profiling = true
                r.profileInterval = 1
                for _ in 0..<5 {
                    r.renderAndWait(scene, into: target)
                    let passes = r.lastReport?.passes ?? []
                    if let t = passes.first(where: { $0.pass == "Vessels" }) { vessels[on, default: []].append(t.seconds) }
                    if let t = passes.first(where: { $0.pass == "Shadows" }) { shadows[on, default: []].append(t.seconds) }
                }
                r.profiling = false
                for _ in 0..<5 {
                    r.renderAndWait(scene, into: target)
                    if let g = r.lastReport?.gpu { frames[on, default: []].append(g) }
                }
            }
            r.settings.shadow.enabled = true
            func median(_ xs: [Double]?) -> Double { (xs ?? []).isEmpty ? .nan : xs!.sorted()[xs!.count / 2] * 1_000 }
            print(String(format: "RECEIVERS %@: vessel pass %.2f ms with the maps, %.2f ms without (+%.2f); "
                         + "shadow pass (split) %.2f ms; frame %.2f ms with, %.2f ms without (+%.2f)", label,
                         median(vessels[true]), median(vessels[false]), median(vessels[true]) - median(vessels[false]),
                         median(shadows[true]), median(frames[true]), median(frames[false]),
                         median(frames[true]) - median(frames[false])))
        }
    }

    // MARK: Casters

    /// The maps keep drawing a part's own mesh once R5's subdivided one has
    /// swapped in for the vessel pass (the same surface, its edges bisected):
    /// the same triangles, the same shadows. The first frame's shadow pass
    /// (P0) sees the part's own mesh, and the vessel pass (P1) then bakes and
    /// swaps in R5's; the second frame's shadow pass sees R5's.
    func testCastersKeepThePartsOwnMesh() throws {
        let r = try renderer()
        r.settings.shading.waitForAmbientOcclusion = true
        r.settings.ambientOcclusion.maxEdge = 0.5
        let scene = ShadowLookDevTests.scene(distance: 34, width: 64, height: 40)
        let v = scene.vessels[0]
        _ = try luminance(scene, shadows: true, renderer: r)
        _ = try luminance(scene, shadows: true, renderer: r)
        let entry = try XCTUnwrap(r.meshes.mesh(v.id)?.parts.first)
        XCTAssertEqual(entry.mesh.subdividedEdge, 0.5, "R5's mesh drawn by the vessel pass")
        let own = entry.part.shapes.map { $0.mesh().triangleCount }.reduce(0, +)
        XCTAssertGreaterThan(entry.mesh.indexCount / 3, 2 * own)
        let pass = try XCTUnwrap(r.graph.pass(named: "Shadows") as? ShadowPass)
        XCTAssertEqual(pass.casterTriangles(of: v.id), own)
    }

    /// The same for a vessel the maps first meet after R5's bake: one in
    /// the Earth's shadow on its first frame (Apollo 7's entry scenarios open
    /// in the umbra), whose casters are made all the same, and one first
    /// drawn with the shadows off, whose casters come from its shapes again.
    func testCastersKeepThePartsOwnMeshAfterTheDark() throws {
        for darkFirst in [true, false] {
            let r = try renderer()
            r.settings.shading.waitForAmbientOcclusion = true
            r.settings.ambientOcclusion.maxEdge = 0.5
            // Wide enough for a map (64 px across).
            var scene = ShadowLookDevTests.scene(distance: 34, width: 320, height: 200)
            let v = scene.vessels[0]
            if darkFirst { scene.vessels[0].light.sunlit = 0 }
            _ = try luminance(scene, shadows: darkFirst, renderer: r)
            let entry = try XCTUnwrap(r.meshes.mesh(v.id)?.parts.first)
            XCTAssertEqual(entry.mesh.subdividedEdge, 0.5, "R5's mesh after the first frame")
            scene.vessels[0].light.sunlit = 1
            _ = try luminance(scene, shadows: true, renderer: r)
            let pass = try XCTUnwrap(r.graph.pass(named: "Shadows") as? ShadowPass)
            XCTAssertFalse(pass.maps.isEmpty, "lit, it casts")
            let own = entry.part.shapes.map { $0.mesh().triangleCount }.reduce(0, +)
            XCTAssertEqual(pass.casterTriangles(of: v.id), own, darkFirst ? "dark first" : "shadows off first")
        }
    }
}

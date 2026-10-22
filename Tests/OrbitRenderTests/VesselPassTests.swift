import Foundation
import Metal
import XCTest
import OrbitCore
@testable import OrbitScene
@testable import OrbitRender

/// The vessel pass on the GPU: the DFG table it binds, its radiance against
/// the Swift reference, R5's AO decoded per vertex, the part meshes a
/// separation reuses, wires that stay visible, the pad, and the plumes'
/// light.
@MainActor
final class VesselPassTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// A renderer drawing into one-sample rgba16Float, as an HDR plan would.
    func floatRenderer() throws -> SceneRenderer {
        try SceneRenderer(device: try device(), outputFormat: .rgba16Float,
                          passes: SceneRenderer.defaultPasses(loadsUserTextures: false),
                          plan: DirectTargetPlan(colorFormat: .rgba16Float, sampleCount: 1))
    }

    /// Renders `scene` into a float target and returns its decoded linear
    /// values (the vessel shader's Karis encoding undone), rgba per pixel.
    func renderFloat(_ scene: RenderScene, renderer r: SceneRenderer) throws -> [Float] {
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let t = try XCTUnwrap(r.device.makeTexture(descriptor: d))
        r.render(scene, to: t)?.waitUntilCompleted()
        var raw = [Float16](repeating: 0, count: 4 * w * h)
        raw.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!, bytesPerRow: 8 * w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var out = [Float](repeating: 0, count: raw.count)
        for i in stride(from: 0, to: raw.count, by: 4) {
            let c = (Float(raw[i]), Float(raw[i + 1]), Float(raw[i + 2]))
            let k = 1 / max(1 - max(c.0, max(c.1, c.2)), 1e-4)
            out[i] = c.0 * k
            out[i + 1] = c.1 * k
            out[i + 2] = c.2 * k
            out[i + 3] = Float(raw[i + 3])
        }
        return out
    }

    /// A plate 10 m square facing the camera 10 m away, in `material`.
    func plateScene(material: MaterialKey = .apolloWhitePaint, colour: (Double, Double, Double) = (0.8, 0.8, 0.8),
                    shapes extra: [VisualShape] = [], size: (Int, Int) = (64, 64)) -> RenderScene {
        var plate = VisualShape.box(from: .zero, length: 0.1, width: 10, height: 10, axis: -.unitY, color: colour)
        plate.material = material
        let part = VesselPart(name: "Plate", dryMass: 1, length: 1, radius: 5, shapes: [plate] + extra)
        let vessel = Vessel(name: "Plate", parts: [part], reference: Self.system.earth)
        return LookDevScenes.scene(vessel, at: Vec3(0, 10, 0), attitude: .identity, fovY: 20, width: size.0,
                                   height: size.1)
    }

    /// The DFG texture holds the Swift bake, texel for texel.
    func testDFGTextureIsTheSwiftBake() throws {
        let t = try XCTUnwrap(VesselPass.dfgTexture(device: try device()))
        let n = BRDF.dfgTable.size
        XCTAssertEqual([t.width, t.height], [n, n])
        var values = [Float](repeating: 0, count: 2 * n * n)
        values.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!, bytesPerRow: 8 * n, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
        }
        XCTAssertEqual(values, BRDF.dfgTable.values)
    }

    /// The radiance of white paint facing the camera, lit by the Sun from
    /// behind the camera, the stand-in Earth below and the night floor:
    /// the GPU's (over the pre-exposure) is the Swift reference's within
    /// 1 %. Also through the DFG table (rough metal) and with the Sun to
    /// one side.
    func testRadianceMatchesTheSwiftReference() throws {
        let r = try floatRenderer()
        XCTAssertEqual(r.failures.filter { $0.key == "Vessels" }, [:])
        for (material, colour, toSun) in [
            (MaterialKey.apolloWhitePaint, (0.8, 0.8, 0.8), Vec3(0, -1, 0)),
            (.apolloWhitePaint, (0.8, 0.8, 0.8), Vec3(-0.6, -0.6, 0.53).normalized),
            (MaterialDefaults.lookDev(.metal, roughness: 0.6), (0.913, 0.913, 0.913), Vec3(0.3, -0.9, 0.3).normalized),
        ] {
            var scene = plateScene(material: material, colour: colour)
            scene.sun.direction = toSun
            scene.vessels[0].light.toSun = toSun
            let pixels = try renderFloat(scene, renderer: r)
            let centre = 4 * (32 * 64 + 32)
            let gpu = Double(pixels[centre]) / StandInLighting.preExposure
            // The reference at the pixel's centre.
            let e = MaterialDefaults.entry(for: material)
            let p = Vec3(0, 10, 0) + Vec3(0.5, 0, -0.5) * (2 * 10 * tan(10 * Double.pi / 180) / 64)
            let n = Vec3(0, -1, 0), v = (-p).normalized
            let point = ShadingReference.point(albedo: colour.0, metalness: e.metalness, roughness: e.roughness,
                                               reflectance: e.reflectance, n: n, v: v)
            let light = StandInLighting.vessel(scene.vessels[0], in: scene)
            let expected = ShadingReference.sun(point, toSun: toSun, rho: scene.sun.angularRadius,
                                                e: scene.sun.illuminance)
                + ShadingReference.environment(point, bodyDirection: light.earthDirection,
                                               bodySinSigma2: light.earthSinSigma2,
                                               bodyRadiance: Double(light.earthRadiance.r),
                                               uniform: light.sky + light.floor)
            XCTAssertEqual(gpu, expected, accuracy: 0.01 * expected, "\(material), Sun \(toSun)")
        }
    }

    /// R5's contract: each vertex's packed AO decodes in the vertex
    /// function, and the rasteriser interpolates the levels. A triangle
    /// whose vertices pack fronts 0.2, 1, 1 with backs 0, 1, 0.5 shows
    /// about 0.73 of the open light at its centroid; decoding the
    /// interpolated code would give 0.40.
    func testAmbientOcclusionDecodesEachVertexItsOwn() throws {
        let r = try floatRenderer()
        var scene = plateScene(material: MaterialDefaults.lookDev(.dielectric, roughness: 0.9))
        // Only the uniform floor lights it: no Sun, no Earth.
        scene.vessels[0].light.sunlit = 0
        scene.vessels[0].light.earthStrength = 0
        let open = try renderFloat(scene, renderer: r)
        let centre = 4 * (32 * 64 + 32)
        // Replace the plate's mesh by one big triangle around the centre,
        // as if subdivided, with an AO stream.
        let entry = try XCTUnwrap(r.meshes.mesh(scene.vessels[0].id)?.parts.first)
        var mesh = VisualShape.Mesh()
        let template = try XCTUnwrap(entry.part.shapes.first?.mesh().vertices.first)
        func vertex(_ x: Double, _ z: Double) -> VisualShape.Vertex {
            var v = template
            v.position = Vec3(x, -0.1, z)
            v.normal = Vec3(0, -1, 0)
            v.tangent = .unitX
            return v
        }
        // Centroid at the view's centre: (-3,-2), (3,-2), (0,4).
        mesh.vertices = [vertex(-3, -2), vertex(0, 4), vertex(3, -2)]
        mesh.indices = [0, 2, 1]
        let device = try device()
        let tri = try XCTUnwrap(PartMesh.build(meshes: [mesh], info: [entry.info[0]], paint: [[]], subdivided: true,
                                               device: device))
        entry.mesh = tri
        let codes = [AmbientOcclusion.pack(front: 0.2, back: 0), AmbientOcclusion.pack(front: 1, back: 0.5),
                     AmbientOcclusion.pack(front: 1, back: 1)]
        entry.aoNow = device.makeBuffer(bytes: codes, length: 12, options: .storageModeShared)
        entry.aoBake = AOBakeID(signature: scene.vessels[0].geometry.signature, settings: AmbientOcclusionSettings())
        entry.aoArrived = -Double.infinity
        var settings = RenderSettings()
        settings.ambientOcclusion.enabled = true
        r.settings = settings
        let occluded = try renderFloat(scene, renderer: r)
        let ratio = Double(occluded[centre] / open[centre])
        // The pixel's centre is a little off the centroid; the levels vary
        // by about 0.8 over the triangle's 6 m, a pixel is 5.5 cm.
        XCTAssertEqual(ratio, (0.2 + 1 + 1) / 3, accuracy: 0.03, "per-vertex decode")
        XCTAssertGreaterThan(abs(ratio - 0.40), 0.2, "not the decode of an interpolated code")
    }

    /// A separation rebuilds draw lists, not geometry: after the CSM
    /// separates (SLA panels and all), no part mesh is built again, and the
    /// S-IVB draws the very meshes it drew in the stack.
    func testSeparationReusesThePartMeshes() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-parking-orbit"))
        let sim = scenario.build(Self.system)
        var camera = OrbitCamera()
        let focus = try XCTUnwrap(sim.focus)
        camera.target = .vessel(focus.id)
        camera.distance = 60
        camera.update(sim: sim)
        let x = SceneExtractor()
        let viewport = RenderScene.Viewport(width: 160, height: 100)
        let r = try SceneRenderer(device: try device(), loadsUserTextures: false)
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: 160, height: 100))
        r.renderAndWait(x.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0), into: target)
        let built = r.meshes.partsBuilt
        let before = try XCTUnwrap(r.meshes.mesh(focus.id))
        XCTAssertGreaterThan(built, 5)
        try ScenarioScript(["stage", "wait:2"]).run(on: sim, missionClockZero: scenario.missionClockZero) { _ in }
        camera.update(sim: sim)
        let scene = x.extract(sim: sim, camera: camera, viewport: viewport, realTime: 1)
        XCTAssertGreaterThan(scene.vessels.count, 2, "the CSM, the S-IVB and the panels")
        r.renderAndWait(scene, into: target)
        XCTAssertEqual(r.meshes.partsBuilt, built, "no part mesh built at the separation")
        let sivb = try XCTUnwrap(scene.vessels.first { $0.name.hasSuffix("S-IVB") })
        let after = try XCTUnwrap(r.meshes.mesh(sivb.id))
        for p in after.parts {
            XCTAssertTrue(before.parts.contains { $0 === p }, "\(p.part.name) is the stack's own entry")
        }
    }

    /// Persson's phone-wire AA: a 1 cm tube 100 m away (a ninth of a pixel
    /// across), tilted 3° across the rows, draws in every column it
    /// crosses, faintly; without it, it breaks into dashes where it falls
    /// between the samples.
    func testThinTubesStayCovered() throws {
        let r = try SceneRenderer(device: try device(), loadsUserTextures: false)
        let axis = Vec3(cos(0.0524), 0, sin(0.0524))
        var tube = VisualShape.frustum(from: axis * -25, length: 50, baseRadius: 0.01, topRadius: 0.01, axis: axis,
                                       color: (0.9, 0.9, 0.9))
        tube.material = .apolloLESTower
        XCTAssertTrue(PartMesh.isWire(tube))
        let part = VesselPart(name: "Tube", dryMass: 1, length: 50, radius: 0.01, shapes: [tube])
        let vessel = Vessel(name: "Tube", parts: [part], reference: Self.system.earth)
        let scene = LookDevScenes.scene(vessel, at: Vec3(0, 100, 0), attitude: .identity, fovY: 20, width: 320,
                                        height: 200)
        func columns(_ wire: Double) throws -> (covered: Int, ink: Double) {
            var s = RenderSettings()
            s.shading.wireMinimumRadius = wire
            r.settings = s
            let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: 320, height: 200))
            r.renderAndWait(scene, into: target)
            let px = target.bytes()
            var covered = 0, ink = 0.0
            for x in 40..<280 {
                var column = 0.0
                for y in 70..<130 { column += Double(px[4 * (y * 320 + x) + 1]) / 255 }
                if column > 0.05 { covered += 1 }
                ink += column
            }
            return (covered, ink / 240)
        }
        let aa = try columns(0.7), plain = try columns(0)
        XCTAssertEqual(aa.covered, 240, "every column shows the tube")
        XCTAssertLessThan(plain.covered, 200, "without it the tube breaks up")
        XCTAssertLessThan(aa.ink, 1.5, "a faint line, not a widened bright one")
    }

    /// LC-39A drawn by the vessel pass: with the site placed, the tower and
    /// the deck show beside the vehicle; nothing fails.
    func testDrawsThePad() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-pad"))
        let sim = scenario.build(Self.system)
        var camera = OrbitCamera()
        let v = try XCTUnwrap(sim.focus)
        camera.target = .vessel(v.id)
        camera.distance = 260
        camera.yaw = -1.2
        camera.pitch = 0.15
        camera.update(sim: sim)
        let viewport = RenderScene.Viewport(width: 320, height: 200)
        let r = try SceneRenderer(device: try device(), loadsUserTextures: false)
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: 320, height: 200))
        let bare = SceneExtractor()
        r.renderAndWait(bare.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0), into: target)
        let without = target.bytes()
        let x = SceneExtractor()
        x.sites = [LC39A.placement()]
        let scene = x.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0)
        XCTAssertEqual(scene.sites.count, 1)
        r.renderAndWait(scene, into: target)
        let with = target.bytes()
        XCTAssertEqual(r.failures, [:])
        var changed = 0
        for i in stride(from: 0, to: with.count, by: 4) {
            let db = abs(Int(with[i]) - Int(without[i])), dg = abs(Int(with[i + 1]) - Int(without[i + 1]))
            if db + dg > 30 { changed += 1 }
        }
        XCTAssertGreaterThan(changed, 320 * 200 / 50, "the tower, deck and pad cover a good part of the view")
        XCTAssertEqual(VesselPass.countdown(at: sim.time).name, LC39A.Countdown.apollo11.name)
    }

    /// The F-1s light the vehicle's base at liftoff: with plume lights the
    /// lower stack is brighter than without, and the upper stack is not.
    func testPlumesLightTheBase() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-pad"))
        let sim = scenario.build(Self.system)
        sim.paused = false
        sim.stepBudget = nil
        sim.advance(by: 2)
        var camera = OrbitCamera()
        let v = try XCTUnwrap(sim.focus)
        camera.target = .vessel(v.id)
        camera.distance = 90
        camera.yaw = 2.6
        camera.pitch = -0.05
        camera.fovY = 70 * Double.pi / 180
        camera.update(sim: sim)
        let r = try floatRenderer()
        let scene = SceneExtractor().extract(sim: sim, camera: camera,
                                             viewport: RenderScene.Viewport(width: 96, height: 160), realTime: 0)
        XCTAssertEqual(scene.emitters.count, 5)
        var none = RenderSettings()
        none.shading.plumeLights = 0
        r.settings = none
        let dark = try renderFloat(scene, renderer: r)
        r.settings = RenderSettings()
        let lit = try renderFloat(scene, renderer: r)
        var gain = 0.0
        for i in stride(from: 0, to: lit.count, by: 4) where lit[i + 1] > dark[i + 1] {
            gain += Double(lit[i + 1]) - Double(dark[i + 1])
        }
        XCTAssertGreaterThan(gain, 0, "the plumes add light")
    }
}

import Foundation
import Metal
import XCTest
import simd
@testable import OrbitCore
@testable import OrbitScene
@testable import OrbitRender

/// A uniform light behind everything (depth 0, as the stars are), so a test
/// can see what the air in front of it lets through.
@MainActor
final class BackgroundTestPass: RenderPass {
    let name = "Test background"
    let stage = PassStage.opaque
    let order = 1
    var luminance: Float = 0
    private var pipeline: MTLRenderPipelineState?

    static let module = ShaderModule(name: "TestBackground", source: #"""
    struct TestBackgroundOut { float4 position [[position]]; };
    vertex TestBackgroundOut test_background_vertex(uint vid [[vertex_id]]) {
        float2 q = float2(float((vid << 1) & 2), float(vid & 2));
        TestBackgroundOut o;
        o.position = float4(q * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }
    fragment float4 test_background_fragment(TestBackgroundOut in [[stage_in]], constant float &l [[buffer(0)]],
                                             constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
        return float4(float3(l * frame.exposure.x), 1.0);
    }
    """#)

    func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(Self.module), vertex: "test_background_vertex",
                                             fragment: "test_background_fragment", blend: .additive, setup: s)
    }

    func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, luminance > 0 else { return }
        var l = luminance
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.noDepth)
        enc.setFragmentBytes(&l, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

/// What P0 left for the passes after it: the atmosphere's uniforms, and a
/// readable copy of the froxels.
@MainActor
final class AtmosphereProbeTestPass: RenderPass {
    let name = "Test atmosphere readback"
    let stage = PassStage.prepare
    let order = 1
    var uniforms: AtmosphereUniforms?
    var froxels: MTLTexture?
    var sunIlluminance = SIMD4<Float>.zero

    func encode(_ f: FrameContext, _ e: PassEncoding) {
        uniforms = f.atmosphere
        sunIlluminance = f.frame.sunIlluminance
        guard let v = f.textures[.aerialPerspective], let b = f.makeBlitEncoder() else { return }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = v.pixelFormat
        d.width = v.width
        d.height = v.height
        d.depth = v.depth
        d.storageMode = .shared
        guard let copy = f.device.makeTexture(descriptor: d) else { return }
        b.copy(from: v, to: copy)
        b.endEncoding()
        froxels = copy
    }

    /// RGBA of froxel (x, y, z).
    func froxel(_ x: Int, _ y: Int, _ z: Int) -> SIMD4<Float>? {
        guard let t = froxels else { return nil }
        let v = read(t, MTLRegionMake3D(x, y, z, 1, 1, 1))
        return SIMD4(v[0], v[1], v[2], v[3])
    }

    /// Every froxel's RGBA, x fastest, then y, then z.
    func allFroxels() -> [Float]? {
        guard let t = froxels else { return nil }
        return read(t, MTLRegionMake3D(0, 0, 0, t.width, t.height, t.depth))
    }

    private func read(_ t: MTLTexture, _ region: MTLRegion) -> [Float] {
        let n = 4 * region.size.width * region.size.height * region.size.depth
        switch t.pixelFormat {
        case .rgba32Float:
            var f = [Float](repeating: 0, count: n)
            f.withUnsafeMutableBytes {
                t.getBytes($0.baseAddress!, bytesPerRow: 16 * region.size.width,
                           bytesPerImage: 16 * region.size.width * region.size.height, from: region, mipmapLevel: 0,
                           slice: 0)
            }
            return f
        default:
            var h = [UInt16](repeating: 0, count: n)
            h.withUnsafeMutableBytes {
                t.getBytes($0.baseAddress!, bytesPerRow: 8 * region.size.width,
                           bytesPerImage: 8 * region.size.width * region.size.height, from: region, mipmapLevel: 0,
                           slice: 0)
            }
            return h.map { Float(Float16(bitPattern: $0)) }
        }
    }
}

/// R3's probe entry point, drawn by a test after the post pass into a
/// square face with the camera's own view.
@MainActor
final class ProbeFaceTestPass: RenderPass {
    let name = "Test probe face"
    let stage = PassStage.post
    let order = 10
    let composite: AtmosphereCompositePass
    var face: MTLTexture?
    var drew = false

    init(composite: AtmosphereCompositePass) { self.composite = composite }

    func encode(_ f: FrameContext, _ e: PassEncoding) {
        let size = f.size.width
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: size, height: size,
                                                         mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .shared
        guard let t = f.device.makeTexture(descriptor: d) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = f.makeRenderEncoder(pass) else { return }
        drew = composite.encodeProbe(f, on: enc, formats: SceneFormats(color: .rgba32Float, depth: .invalid,
                                                                      sampleCount: 1, output: .rgba32Float),
                                     viewToWorld: f.frame.viewToWorld, tanHalfFov: f.frame.camera.y, faceSize: size)
        enc.endEncoding()
        face = t
    }

    func pixels() -> [Float]? {
        guard let t = face else { return nil }
        var out = [Float](repeating: 0, count: 4 * t.width * t.height)
        out.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!, bytesPerRow: 16 * t.width, from: MTLRegionMake2D(0, 0, t.width, t.height),
                       mipmapLevel: 0)
        }
        return out
    }
}

/// Track A2 on the GPU: the sky, the limb and the ground against the Swift
/// march they mirror (OrbitScene's `AtmosphereMarch`, itself tested against
/// A1's sky), the transmitted Sun and stars, the uniforms R2 and C2 read,
/// R3's probe entry point and the froxels.
@MainActor
final class AtmospherePassTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    var lut: AtmosphereLUT {
        AtmosphereTables.shared.tables(wait: true)!
    }

    func settings(ev100: Double = 15) -> RenderSettings {
        var s = RenderSettings()
        s.post.exposure.mode = .manual
        s.post.exposure.ev100 = ev100
        s.post.bloom = 0
        s.post.sunGlare = false
        s.post.dither = false
        return s
    }

    func renderer(_ extra: [RenderPass] = [], ev100: Double = 15) throws -> SceneRenderer {
        let r = try SceneRenderer(device: try device(), outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + extra,
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.settings = settings(ev100: ev100)
        XCTAssertEqual(r.failures, [:])
        return r
    }

    /// The scene's light, cd/m² (RGBA, rows top first).
    func light(_ r: SceneRenderer, _ scene: RenderScene) throws -> [Float] {
        let post = try XCTUnwrap(r.post)
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: w, height: h))
        post.capturesLight = true
        let cb = try XCTUnwrap(r.renderAndWait(scene, into: target))
        XCTAssertNil(cb.error)
        let light = try XCTUnwrap(post.capturedLight())
        let k = Float(1 / post.control.preExposure)
        return light.pixels.map { $0 * k }
    }

    /// A scenario's frame, the camera at the orbit camera's place (`distance`
    /// from the focus) looking along `look` (world), `fovY` degrees.
    func scene(_ scenario: Scenario, at sim: Simulation? = nil, distance: Double = 400, width: Int = 96,
               height: Int = 64, fovY: Double = 40, look: ((RenderScene) -> Vec3)?) -> RenderScene {
        let sim = sim ?? scenario.build(Self.system)
        var cam = OrbitCamera()
        if let focus = sim.focus { cam.target = .vessel(focus.id) }
        cam.distance = distance
        cam.fovY = fovY * Double.pi / 180
        cam.update(sim: sim)
        var scene = SceneExtractor().extract(sim: sim, camera: cam,
                                             viewport: RenderScene.Viewport(width: Double(width), height: Double(height)),
                                             realTime: 0)
        scene.sites = []
        if let look {
            let forward = look(scene).normalized, back = -forward
            let earth = scene.bodies.first { $0.id == 399 }!
            let up0 = (-earth.position).normalized
            let right = (abs(up0.dot(back)) > 0.99 ? Vec3.unitX : up0).cross(back).normalized
            scene.camera.worldToView = Mat3(rows: right, back.cross(right), back)
        }
        return scene
    }

    /// The world direction through pixel (x, y)'s centre.
    func direction(_ scene: RenderScene, x: Int, y: Int) -> Vec3 {
        let c = scene.camera, w = c.viewport.width, h = c.viewport.height
        let t = tan(c.fovY / 2), aspect = w / h
        let ndc = (2 * (Double(x) + 0.5) / w - 1, 1 - 2 * (Double(y) + 0.5) / h)
        let v = Vec3(ndc.0 * t * aspect, ndc.1 * t, -1)
        return (c.worldToView.transposed * v).normalized
    }

    /// The sky through the air along `d` (world), cd/m² per channel, by the
    /// Swift march with `steps`; nil when the ray meets the ground.
    func sky(_ frame: AtmosphereFrame, _ scene: RenderScene, _ d: Vec3, steps: Int,
             allowGround: Bool = false) -> (radiance: Spectrum3, transmittance: Spectrum3)? {
        let dF = frame.figureDirection(d)
        guard let seg = AtmosphereMarch.airSegment(origin: frame.camera, direction: dF, bottomRadius: frame.bottomRadius,
                                                   topRadius: frame.topRadius) else { return (.zero, .one) }
        if seg.ground && !allowGround { return nil }
        let m = AtmosphereMarch.march(lut, origin: frame.camera, direction: dF, from: seg.t0, to: seg.t1, steps: steps,
                                      sun: frame.sun, cosView: d.dot(scene.sun.direction))
        let s = frame.solarScale
        return (Spectrum3(m.radiance.r * s.r, m.radiance.g * s.g, m.radiance.b * s.b), m.transmittance)
    }

    func assertClose(_ got: (Float, Float, Float), _ want: Spectrum3, _ tolerance: Double, floor: Double = 1e-3,
                     _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for (g, w) in [(Double(got.0), want.r), (Double(got.1), want.g), (Double(got.2), want.b)] {
            XCTAssertEqual(g, w, accuracy: tolerance * w + floor, message, file: file, line: line)
        }
    }

    func rgb(_ p: [Float], _ i: Int) -> (Float, Float, Float) { (p[4 * i], p[4 * i + 1], p[4 * i + 2]) }

    // MARK: From the pad

    /// The sky over the pad at Apollo 8's dawn, every few pixels in four
    /// directions (away from the vehicle and the Sun), is the march's within
    /// 4 %: the sky-view LUT's parameterisation and interpolation.
    func testSkyFromThePadMatchesTheMarch() throws {
        let r = try renderer()
        var checked = 0
        for (azimuth, elevation) in [(0.0, 30.0), (180, 30), (90, 15), (270, 50)] {
            let scene = self.scene(.apollo8DawnPad) { s in
                let earth = s.bodies.first { $0.id == 399 }!
                let up = (-earth.position).normalized
                let toSun = (s.sun.direction - up * s.sun.direction.dot(up)).normalized
                let side = up.cross(toSun)
                let a = azimuth * Double.pi / 180, e = elevation * Double.pi / 180
                return (toSun * cos(a) + side * sin(a)) * cos(e) + up * sin(e)
            }
            let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
            let light = try self.light(r, scene)
            let vessel = scene.vessels[0].position.normalized
            for y in stride(from: 2, to: 64, by: 7) {
                for x in stride(from: 3, to: 96, by: 9) {
                    let d = direction(scene, x: x, y: y)
                    if d.dot(scene.sun.direction) > cos(3 * Double.pi / 180) || d.dot(vessel) > cos(0.5) { continue }
                    let dF = frame.figureDirection(d)
                    // Clear of the horizon by half a degree.
                    guard dF.dot(frame.up) > -sin(acos(frame.bottomRadius / frame.cameraRadius)) + 0.009,
                          let want = sky(frame, scene, d, steps: 64) else { continue }
                    assertClose(rgb(light, y * 96 + x), want.radiance, 0.04, "az \(azimuth) el \(elevation) px \(x),\(y)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    /// The Sun and the stars are seen through the air: a uniform light
    /// behind it comes through times the transmittance along each pixel's
    /// ray, per channel. Looking at the 7° Sun from the pad, that is A1's
    /// (0.37, 0.18, 0.052) about it: the disc is reddened seven times. (The
    /// light behind is bright, 1e6 cd/m², so that the aureole's in front of
    /// it does not drown its difference in half float's precision.)
    func testWhatIsBehindTheAirIsTransmitted() throws {
        let background = BackgroundTestPass()
        let r = try renderer([background])
        let scene = self.scene(.apollo8DawnPad, width: 64, height: 64, fovY: 8) { $0.sun.direction }
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        let without = try light(r, scene)
        let l: Float = 1e6
        background.luminance = l
        let with = try light(r, scene)
        var checked = 0
        for y in stride(from: 1, to: 64, by: 5) {
            for x in stride(from: 1, to: 64, by: 5) {
                let d = direction(scene, x: x, y: y)
                if d.dot(scene.sun.direction) > cos(1.5 * Double.pi / 180) { continue }
                let dF = frame.figureDirection(d)
                if AtmosphereMarch.airSegment(origin: frame.camera, direction: dF, bottomRadius: frame.bottomRadius,
                                              topRadius: frame.topRadius)?.ground ?? false { continue }
                let mu = dF.dot(frame.up)
                let t = lut.transmittanceToTop(radius: frame.cameraRadius, cosZenith: mu)
                let i = 4 * (y * 64 + x)
                let got = ((with[i] - without[i]) / l, (with[i + 1] - without[i + 1]) / l,
                           (with[i + 2] - without[i + 2]) / l)
                assertClose(got, t, 0.02, floor: 2e-3, "px \(x),\(y)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 50)
        let t = frame.sunTransmittance
        XCTAssertEqual(t.r / t.b, 0.37 / 0.052, accuracy: 2.5, "the Sun's disc is reddened")
    }

    /// The ground seen from inside the air is lit through it as from space,
    /// and hazed by the sky-view LUT's rows below the horizon (the light
    /// scattered toward the eye on the way to the ground) and the
    /// transmittance from A1's table along the reversed ray: the march to
    /// the ground within 4 %, from 2 m above it to the horizon's haze 15 km
    /// away (a camera on the dawn pad's service structure height, 120 m).
    func testGroundFromThePadMatchesTheMarch() throws {
        let r = try renderer()
        let scene = self.scene(.apollo8DawnPad, distance: 300, width: 96, height: 64, fovY: 30) { s in
            let earth = s.bodies.first { $0.id == 399 }!
            let up = (-earth.position).normalized
            let toSun = (s.sun.direction - up * s.sun.direction.dot(up)).normalized
            return (toSun.cross(up) - up * 0.15).normalized
        }
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        let light = try self.light(r, scene)
        let exposure = Exposure.exposure(ev100: 15)
        let vessel = scene.vessels[0].position.normalized
        var checked = 0
        for y in stride(from: 1, to: 64, by: 4) {
            for x in stride(from: 2, to: 96, by: 6) {
                let d = direction(scene, x: x, y: y)
                if d.dot(vessel) > cos(0.3) { continue }
                let dF = frame.figureDirection(d)
                guard let seg = AtmosphereMarch.airSegment(origin: frame.camera, direction: dF,
                                                           bottomRadius: frame.bottomRadius,
                                                           topRadius: frame.topRadius), seg.ground,
                      seg.t1 < 15_000 else { continue }
                let p = frame.camera + dF * seg.t1
                let nb = Vec3(p.x, p.y, p.z * frame.stretch).normalized
                let lat = asin(nb.z) * 180 / .pi, lon = atan2(nb.y, nb.x) * 180 / .pi
                func offGrid(_ a: Double) -> Bool { abs(a / 15 - (a / 15).rounded()) * 15 > 0.2 }
                guard offGrid(lat), offGrid(lon) else { continue }
                let n = frame.planet.orientation.toInertial(nb)
                let muS = p.normalized.dot(frame.sun)
                let sunlight = lut.transmittanceToSun(radius: frame.bottomRadius, cosSun: muS)
                    * max(n.dot(scene.sun.direction), 0) + lut.skyIrradiance(radius: frame.bottomRadius, cosSun: muS)
                let m = AtmosphereMarch.march(lut, origin: frame.camera, direction: dF, from: seg.t0, to: seg.t1,
                                              steps: 64, sun: frame.sun, cosView: d.dot(scene.sun.direction))
                let albedo = Spectrum3(0.04, 0.06, 0.08), s = frame.solarScale
                let solar = Spectrum3(s.r, s.g, s.b)
                let lit = albedo * sunlight * solar * (1 / Double.pi) + albedo * (0.015 / exposure)
                let want = lit * m.transmittance + m.radiance * solar
                assertClose(rgb(light, y * 96 + x), want, 0.04, floor: 0.5, "ground px \(x),\(y) at \(Int(seg.t1)) m")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    /// The Sun's disc itself, seen through a solar filter (EV 27): R1's
    /// disc luminance at its centre times the transmittance along that ray,
    /// per channel, about A1's (0.37, 0.18, 0.052) at 7°.
    func testTheSunsDiscIsTransmitted() throws {
        let r = try renderer(ev100: 27)
        let scene = self.scene(.apollo8DawnPad, width: 64, height: 64, fovY: 1.2) { $0.sun.direction }
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        let light = try self.light(r, scene)
        let d = direction(scene, x: 32, y: 32)
        XCTAssertGreaterThan(d.dot(scene.sun.direction), cos(0.05 * Double.pi / 180), "pixel 32,32 is the disc's centre")
        let t = lut.transmittanceToTop(radius: frame.cameraRadius, cosZenith: frame.figureDirection(d).dot(frame.up))
        let centre = Photometry.sunColor.scaled(by: Photometry.solarLuminance * Photometry.solarCentreOverMean)
        let sky = try XCTUnwrap(sky(frame, scene, d, steps: 64)).radiance
        let want = Spectrum3(centre.r * t.r, centre.g * t.g, centre.b * t.b) + sky
        assertClose(rgb(light, 32 * 64 + 32), want, 0.03, "the disc's centre")
        XCTAssertEqual(t.g, frame.sunTransmittance.g, accuracy: 0.1 * t.g)
    }

    // MARK: From orbit

    /// A day in low orbit: the simulation advanced until the capsule is
    /// under a Sun at least `elevation` degrees up.
    func orbitSim(sunElevation: Double) throws -> Simulation {
        let sim = Scenario.lowEarthOrbit.build(Self.system)
        for _ in 0..<40 {
            let s = scene(.lowEarthOrbit, at: sim, look: nil)
            if let f = AtmosphereFrame(scene: s, tables: lut), asin(f.cosSunZenith) > sunElevation * Double.pi / 180 {
                return sim
            }
            sim.advance(by: 200)
        }
        throw XCTSkip("no daylight found")
    }

    /// From orbit the limb is marched per pixel: rays past the ground are
    /// the Swift march's with the same steps within 1.5 %; the ground below
    /// is lit through the air (A1's transmittance to it and its sky's
    /// light, R1's sunlight) and hazed by the march to it, done in P0 at a
    /// quarter of the resolution, within 3 %.
    func testLimbAndGroundFromOrbitMatchTheMarch() throws {
        let sim = try orbitSim(sunElevation: 25)
        let r = try renderer()
        let settings = AtmosphereSettings()
        let scene = self.scene(.lowEarthOrbit, at: sim, distance: 30, fovY: 30) { s in
            let earth = s.bodies.first { $0.id == 399 }!
            let up = (-earth.position).normalized
            let dip = acos(earth.figure.equatorialRadius / earth.position.length)
            let toSun = (s.sun.direction - up * s.sun.direction.dot(up)).normalized
            return toSun * cos(dip) - up * sin(dip)
        }
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        XCTAssertFalse(frame.isInside)
        let light = try self.light(r, scene)
        let exposure = Exposure.exposure(ev100: 15)
        let earth = frame.planet
        var limb = 0, ground = 0
        for y in stride(from: 0, to: 64, by: 3) {
            for x in stride(from: 2, to: 96, by: 6) {
                let d = direction(scene, x: x, y: y)
                let dF = frame.figureDirection(d)
                guard let seg = AtmosphereMarch.airSegment(origin: frame.camera, direction: dF,
                                                           bottomRadius: frame.bottomRadius,
                                                           topRadius: frame.topRadius) else { continue }
                let got = rgb(light, y * 96 + x)
                if !seg.ground {
                    // Clear of the silhouette's pixel.
                    if AtmosphereMarch.sphere(origin: frame.camera, direction: dF,
                                              radius: frame.bottomRadius + 3_000) != nil { continue }
                    guard let want = sky(frame, scene, d, steps: settings.limbSteps) else { continue }
                    // Half float's subnormals (2^-24) at EV 15 are 0.0024 cd/m².
                    assertClose(got, want.radiance, 0.015, floor: 0.004, "limb px \(x),\(y)")
                    limb += 1
                    continue
                }
                // The ground, away from the grid lines and the silhouette.
                let p = frame.camera + dF * seg.t1
                let nb = Vec3(p.x, p.y, p.z * frame.stretch).normalized
                let lat = asin(nb.z) * 180 / .pi, lon = atan2(nb.y, nb.x) * 180 / .pi
                func offGrid(_ a: Double) -> Bool { abs(a / 15 - (a / 15).rounded()) * 15 > 1 }
                // MSAA blends the limb into the pixels next to the silhouette.
                guard offGrid(lat), offGrid(lon), seg.t1 < 0.7 * (frame.camera.length * frame.camera.length
                    - frame.bottomRadius * frame.bottomRadius).squareRoot() else { continue }
                let n = earth.orientation.toInertial(nb)
                let muS = p.normalized.dot(frame.sun)
                let sunlight = lut.transmittanceToSun(radius: frame.bottomRadius, cosSun: muS)
                    * max(n.dot(scene.sun.direction), 0) + lut.skyIrradiance(radius: frame.bottomRadius, cosSun: muS)
                let m = AtmosphereMarch.spaceGround(lut, origin: frame.camera, direction: dF, steps: settings.groundSteps,
                                                    sun: frame.sun, cosView: d.dot(scene.sun.direction))
                let albedo = Spectrum3(0.04, 0.06, 0.08), s = frame.solarScale
                let solar = Spectrum3(s.r, s.g, s.b)
                let lit = albedo * sunlight * solar * (1 / Double.pi)
                let night = albedo * (0.015 / exposure)
                let want = (lit + night) * m.transmittance + m.radiance * solar
                assertClose(got, want, 0.03, "ground px \(x),\(y)")
                ground += 1
            }
        }
        XCTAssertGreaterThan(limb, 20)
        XCTAssertGreaterThan(ground, 50)
    }

    /// The view's direction through (u, v) of the frame (0...1, top first),
    /// as the atmosphere module's kernels compute it.
    func direction(_ scene: RenderScene, u: Double, v: Double) -> Vec3 {
        let c = scene.camera, t = tan(c.fovY / 2), aspect = c.viewport.width / c.viewport.height
        return (c.worldToView.transposed * Vec3((2 * u - 1) * t * aspect, (1 - 2 * v) * t, -1)).normalized
    }

    /// Low orbit with the Sun `range` degrees above the limb (its elevation
    /// over the horizontal plus the horizon's dip), the minute or so before
    /// an orbital sunset or after a sunrise.
    func orbitSim(sunAboveTheLimb range: ClosedRange<Double>) throws -> Simulation {
        let sim = Scenario.lowEarthOrbit.build(Self.system)
        for _ in 0..<400 {
            let s = scene(.lowEarthOrbit, at: sim, look: nil)
            if let f = AtmosphereFrame(scene: s, tables: lut) {
                let above = (asin(f.cosSunZenith) + acos(f.bottomRadius / f.cameraRadius)) * 180 / .pi
                if range.contains(above) { return sim }
            }
            sim.advance(by: 15)
        }
        throw XCTSkip("the Sun never stood \(range)° above the limb")
    }

    /// Toward a Sun 6-8° above the limb from low orbit, A1's aerosol
    /// scatters forward along the grazing rays at the silhouette: the haze
    /// over the ground there passes 65,504 cd/m² (half float's largest
    /// value) in red, and P0's quarter-resolution haze must hold it. The
    /// ground along the silhouette is the march's (bilinear between P0's
    /// texels, as the planet samples them) within 3 %: neither black (an
    /// overflow to +∞, which the planet shader zeroes) nor clipped.
    func testTheGroundUnderALowSunFromOrbitIsNeitherBlackNorClipped() throws {
        let sim = try orbitSim(sunAboveTheLimb: 6...8)
        let r = try renderer()
        let settings = AtmosphereSettings()
        let (width, height) = (96, 64)
        var scene = self.scene(.lowEarthOrbit, at: sim, distance: 30, width: width, height: height, fovY: 3) { s in
            let earth = s.bodies.first { $0.id == 399 }!
            let up = (-earth.position).normalized
            let dip = acos(earth.figure.equatorialRadius / earth.position.length)
            let toSun = (s.sun.direction - up * s.sun.direction.dot(up)).normalized
            return toSun * cos(dip) - up * sin(dip)
        }
        scene.vessels = []
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        XCTAssertFalse(frame.isInside)
        let light = try self.light(r, scene)
        let exposure = Exposure.exposure(ev100: 15)
        let s = frame.solarScale, solar = Spectrum3(s.r, s.g, s.b)
        // P0's haze, texel by texel, as atmosphere_spaceGround marches it.
        let k = settings.spaceGroundDivisor
        let (tw, th) = ((width + k - 1) / k, (height + k - 1) / k)
        var haze = [[AtmosphereMarch.Result]](repeating: [], count: th)
        var brightest = 0.0
        for j in 0..<th {
            for i in 0..<tw {
                let d = direction(scene, u: (Double(i) + 0.5) / Double(tw), v: (Double(j) + 0.5) / Double(th))
                let m = AtmosphereMarch.spaceGround(lut, origin: frame.camera, direction: frame.figureDirection(d),
                                                    steps: settings.groundSteps, sun: frame.sun,
                                                    cosView: d.dot(scene.sun.direction))
                brightest = max(brightest, m.radiance.r * s.r)
                haze[j].append(m)
            }
        }
        XCTAssertGreaterThan(brightest, 65_504, "the haze passes half float's range here")
        func bilinear(_ u: Double, _ v: Double, _ f: (AtmosphereMarch.Result) -> Spectrum3) -> Spectrum3 {
            let x = u * Double(tw) - 0.5, y = v * Double(th) - 0.5
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = x - Double(x0), fy = y - Double(y0)
            func at(_ i: Int, _ j: Int) -> Spectrum3 { f(haze[min(max(j, 0), th - 1)][min(max(i, 0), tw - 1)]) }
            return at(x0, y0) * ((1 - fx) * (1 - fy)) + at(x0 + 1, y0) * (fx * (1 - fy))
                + at(x0, y0 + 1) * ((1 - fx) * fy) + at(x0 + 1, y0 + 1) * (fx * fy)
        }
        func ground(_ x: Int, _ y: Int) -> (t: Double, d: Vec3)? {
            let d = direction(scene, x: x, y: y)
            guard let seg = AtmosphereMarch.airSegment(origin: frame.camera, direction: frame.figureDirection(d),
                                                       bottomRadius: frame.bottomRadius, topRadius: frame.topRadius),
                  seg.ground else { return nil }
            return (seg.t1, d)
        }
        var checked = 0, rows = Set<Int>()
        for y in 1..<(height - 1) {
            for x in stride(from: 1, to: width, by: 4) {
                // The ground, a pixel clear of the silhouette (MSAA blends
                // the limb into the pixels on it).
                guard let g = ground(x, y), ground(x, y - 1) != nil else { continue }
                let dF = frame.figureDirection(g.d)
                let p = frame.camera + dF * g.t
                let nb = Vec3(p.x, p.y, p.z * frame.stretch).normalized
                let n = frame.planet.orientation.toInertial(nb)
                let muS = p.normalized.dot(frame.sun)
                let sunlight = lut.transmittanceToSun(radius: frame.bottomRadius, cosSun: muS)
                    * max(n.dot(scene.sun.direction), 0) + lut.skyIrradiance(radius: frame.bottomRadius, cosSun: muS)
                let albedo = Spectrum3(0.04, 0.06, 0.08)
                let lit = albedo * sunlight * solar * (1 / Double.pi) + albedo * (0.015 / exposure)
                let u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
                let want = lit * bilinear(u, v) { $0.transmittance } + bilinear(u, v) { $0.radiance * solar }
                let got = rgb(light, y * width + x)
                XCTAssertTrue(got.0.isFinite && got.1.isFinite && got.2.isFinite, "px \(x),\(y)")
                assertClose(got, want, 0.03, floor: 0.5, "ground px \(x),\(y), \(Int(g.t / 1_000)) km away")
                checked += 1
                rows.insert(y)
            }
        }
        XCTAssertGreaterThan(rows.count, 20, "rows of ground below the silhouette")
        XCTAssertGreaterThan(checked, 200)
    }

    // MARK: What other passes read

    /// `AtmosphereUniforms` as R2's vessel pass, C2 and R3 read it, at the
    /// dawn pad: the transmitted Sun's colour times its lux is A1's
    /// transmittance times R1's sunlight, per channel; the sky's
    /// irradiance; the froxels' slices; the planet. In orbit, in sunlight,
    /// it is R1's sunlight itself.
    func testUniformsOtherPassesRead() throws {
        let readback = AtmosphereProbeTestPass()
        let r = try renderer([readback])
        let pad = scene(.apollo8DawnPad, look: { $0.sun.direction })
        _ = try light(r, pad)
        let a = try XCTUnwrap(readback.uniforms)
        let frame = try XCTUnwrap(AtmosphereFrame(scene: pad, tables: lut))
        XCTAssertEqual(a.radii.w, 1)
        XCTAssertEqual(Double(a.radii.x), 6_378_137)
        XCTAssertEqual(Double(a.radii.y), 6_478_137)
        XCTAssertEqual(Double(a.radii.z), frame.cameraAltitude, accuracy: 1)
        let t = frame.sunTransmittance
        let sun = readback.sunIlluminance
        for (k, (colour, lux, tr)) in [(a.sunTransmitted.x, sun.x, t.r), (a.sunTransmitted.y, sun.y, t.g),
                                       (a.sunTransmitted.z, sun.z, t.b)].enumerated() {
            XCTAssertEqual(Double(colour * a.sunTransmitted.w), Double(lux) * tr, accuracy: 1e-4 * Double(lux),
                           "channel \(k): colour × lux = R1's sunlight × A1's transmittance")
        }
        XCTAssertEqual(a.sunTransmitted.w, sun.w, "w: the Sun's lux above the air")
        let sky = frame.skyIrradiance
        XCTAssertEqual(Double(a.skyIrradiance.y), sky.g, accuracy: 1e-4 * sky.g)
        XCTAssertGreaterThan(a.skyIrradiance.z, a.skyIrradiance.x)
        XCTAssertEqual(a.aerialPerspective.x, 32)
        XCTAssertEqual(Double(a.aerialPerspective.y), frame.froxels.far, accuracy: 1)

        let sim = try orbitSim(sunElevation: 10)
        _ = try light(r, scene(.lowEarthOrbit, at: sim, look: nil))
        let o = try XCTUnwrap(readback.uniforms)
        let s = readback.sunIlluminance
        XCTAssertEqual(o.sunTransmitted.x * o.sunTransmitted.w, s.x, accuracy: 1e-4 * s.x)
        XCTAssertEqual(o.sunTransmitted.y * o.sunTransmitted.w, s.y, accuracy: 1e-4 * s.y)
        XCTAssertEqual(o.sunTransmitted.z * o.sunTransmitted.w, s.z, accuracy: 1e-4 * s.z)
        XCTAssertEqual(o.skyIrradiance, .zero)
    }

    /// The froxels hold the march to each slice's distance along their
    /// column's ray: in-scattered luminance and the transmittance's mean.
    func testFroxelsMatchTheMarch() throws {
        let readback = AtmosphereProbeTestPass()
        let r = try renderer([readback])
        let scene = self.scene(.apollo8DawnPad, width: 64, height: 64) { s in
            let earth = s.bodies.first { $0.id == 399 }!
            let up = (-earth.position).normalized
            let toSun = (s.sun.direction - up * s.sun.direction.dot(up)).normalized
            return (toSun.cross(up) + up * 0.05).normalized
        }
        _ = try light(r, scene)
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        let s = frame.solarScale
        for (x, y) in [(3, 5), (16, 16), (28, 20), (10, 30)] {
            // The column's ray: froxel (x, y) is pixel (x + 0.5)/32 across.
            let c = scene.camera, t = tan(c.fovY / 2)
            let u = (Double(x) + 0.5) / 32, v = (Double(y) + 0.5) / 32
            let d = (c.worldToView.transposed * Vec3((2 * u - 1) * t, (1 - 2 * v) * t, -1)).normalized
            for z in [0, 7, 20, 31] {
                let got = try XCTUnwrap(readback.froxel(x, y, z))
                let m = AtmosphereMarch.froxel(lut, origin: frame.camera, direction: frame.figureDirection(d),
                                               slices: frame.froxels, slice: z, steps: AtmosphereSettings().froxelSteps, sun: frame.sun,
                                               cosView: d.dot(scene.sun.direction))
                let want = Spectrum3(m.radiance.r * s.r, m.radiance.g * s.g, m.radiance.b * s.b)
                assertClose((got.x, got.y, got.z), want, 0.02, floor: 0.05, "froxel \(x),\(y),\(z)")
                let mean = (m.transmittance.r + m.transmittance.g + m.transmittance.b) / 3
                XCTAssertEqual(Double(got.w), mean, accuracy: 3e-3, "froxel \(x),\(y),\(z)")
            }
        }
    }

    /// Toward the Sun 7° up at the dawn pad, A1's aerosol scatters forward
    /// up to about 1.5e5 cd/m² in red beyond the aerosol's layer, past half
    /// float's 65,504: every froxel is finite, and the columns toward the
    /// Sun are the march's within 2 %.
    func testFroxelsTowardALowSunHoldTheirLight() throws {
        let readback = AtmosphereProbeTestPass()
        let r = try renderer([readback])
        let scene = self.scene(.apollo8DawnPad, width: 64, height: 64) { $0.sun.direction }
        _ = try light(r, scene)
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        let all = try XCTUnwrap(readback.allFroxels())
        XCTAssertEqual(all.count, 4 * 32 * 32 * 32)
        XCTAssertFalse(all.contains { !$0.isFinite }, "every froxel is finite")
        let s = frame.solarScale
        var brightest = 0.0
        for (x, y) in [(16, 16), (15, 15), (17, 15), (16, 19), (12, 16)] {
            let c = scene.camera, t = tan(c.fovY / 2)
            let u = (Double(x) + 0.5) / 32, v = (Double(y) + 0.5) / 32
            let d = (c.worldToView.transposed * Vec3((2 * u - 1) * t, (1 - 2 * v) * t, -1)).normalized
            for z in [0, 5, 12, 20, 31] {
                let got = try XCTUnwrap(readback.froxel(x, y, z))
                let m = AtmosphereMarch.froxel(lut, origin: frame.camera, direction: frame.figureDirection(d),
                                               slices: frame.froxels, slice: z, steps: AtmosphereSettings().froxelSteps,
                                               sun: frame.sun, cosView: d.dot(scene.sun.direction))
                let want = Spectrum3(m.radiance.r * s.r, m.radiance.g * s.g, m.radiance.b * s.b)
                brightest = max(brightest, want.r)
                assertClose((got.x, got.y, got.z), want, 0.02, floor: 0.05, "froxel \(x),\(y),\(z)")
                let mean = (m.transmittance.r + m.transmittance.g + m.transmittance.b) / 3
                XCTAssertEqual(Double(got.w), mean, accuracy: 3e-3, "froxel \(x),\(y),\(z)")
            }
        }
        XCTAssertGreaterThan(brightest, 65_504, "the froxels toward the Sun pass half float's range")
    }

    // MARK: R3's probe

    /// The probe entry point draws the sky the view sees: a face with the
    /// camera's own rotation and field matches the view's sky pixels, in
    /// cd/m² (pre-exposure 1), within 1 %.
    func testProbeEntryDrawsTheViewsSky() throws {
        let composite = AtmosphereCompositePass()
        var passes = SceneRenderer.defaultPasses(loadsUserTextures: false).filter { !($0 is AtmosphereCompositePass) }
        passes.append(composite)
        let probe = ProbeFaceTestPass(composite: composite)
        passes.append(probe)
        let r = try SceneRenderer(device: try device(), outputFormat: .bgra8Unorm_srgb, passes: passes,
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.settings = settings()
        XCTAssertEqual(r.failures, [:])
        let scene = self.scene(.apollo8DawnPad, width: 48, height: 48, fovY: 60) { s in
            let earth = s.bodies.first { $0.id == 399 }!
            let up = (-earth.position).normalized
            return (s.sun.direction.cross(up) + up).normalized
        }
        let view = try light(r, scene)
        XCTAssertTrue(probe.drew)
        let face = try XCTUnwrap(probe.pixels())
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene, tables: lut))
        var checked = 0
        for y in stride(from: 1, to: 48, by: 4) {
            for x in stride(from: 1, to: 48, by: 4) {
                let d = direction(scene, x: x, y: y)
                guard frame.figureDirection(d).dot(frame.up) > 0.05,
                      d.dot(scene.vessels[0].position.normalized) < cos(0.5) else { continue }
                let i = y * 48 + x
                let v = rgb(view, i)
                assertClose(rgb(face, i), Spectrum3(Double(v.0), Double(v.1), Double(v.2)), 0.01, "px \(x),\(y)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 30)
    }

    // MARK: Robustness

    /// No NaN or infinity reaches the image anywhere along the flight: the
    /// dawn pad, the ascent, orbit by day and by night, entry and the mains.
    func testNoNaNAlongTheFlight() throws {
        let r = try renderer()
        var scenes: [(String, RenderScene)] = [
            ("pad", scene(.apollo8DawnPad, look: nil)),
            ("leo", scene(.lowEarthOrbit, look: nil)),
            ("entry", scene(.apollo7EntryInterface, distance: 30, look: nil)),
        ]
        let night = Scenario.lowEarthOrbit.build(Self.system)
        night.advance(by: 2_700)
        scenes.append(("leo, later", scene(.lowEarthOrbit, at: night, look: nil)))
        scenes.append(("moon", scene(.lunarOrbit, look: { s in s.bodies.first { $0.id == 399 }!.position })))
        for (name, s) in scenes {
            let light = try self.light(r, s)
            XCTAssertFalse(light.contains { !$0.isFinite }, name)
            XCTAssertGreaterThan(light.max() ?? 0, 0, name)
        }
    }
}

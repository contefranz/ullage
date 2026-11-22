import Foundation
import Metal
import simd
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// C2's cloud shadow on its receivers: the vessels' Sun (the direct beam,
/// e^−τ, `orbit_cloudSunTransmittance`) and the Earth's ground (the Sun's
/// and the sky's light through a conservative slab, direct and diffuse,
/// `orbit_cloudGroundTransmittance`). A P0 pass puts a uniform optical
/// depth in slot 24 and AtmosphereUniforms' cloud members, as CloudPass
/// would, with the clouds themselves off. (After R4's patch in its notes,
/// 2026-11-15.)
@MainActor
final class CloudShadowReceiverTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    /// The scene's linear light, luminance per pixel (R1's capture over its
    /// pre-exposure).
    func luminance(_ scene: RenderScene, renderer r: SceneRenderer) throws -> [Double] {
        let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: w, height: h))
        let post = try XCTUnwrap(r.post, "R1's post pass")
        post.capturesLight = true
        r.renderAndWait(scene, into: target)
        let c = try XCTUnwrap(post.capturedLight())
        let k = 1 / post.control.preExposure
        return (0..<w * h).map { i in
            (0.2126 * Double(c.pixels[4 * i]) + 0.7152 * Double(c.pixels[4 * i + 1])
                + 0.0722 * Double(c.pixels[4 * i + 2])) * k
        }
    }

    /// With an optical depth of ln 2 over a plate, the Sun's part of the
    /// plate's light halves and the rest stays: (half − none)/(clear − none)
    /// = 0.5, the Sun's part read against the plate with no Sun (`sunlit` 0).
    func testCloudShadowDimsTheVesselsSun() throws {
        let toSun = Vec3(0, -1, 1).normalized, sun = toSun * 1.496e11
        let plate = VisualShape.box(from: .zero, length: 0.1, width: 10, height: 10, axis: -.unitY,
                                    color: (0.8, 0.8, 0.8))
        var v = ShadowPassTests.vessel([plate], position: .zero, name: "Plate")
        v.position = Vec3(0, 10, 0) - v.attitude.rotate(v.structureOrigin)
        v.light.toSun = toSun
        var scene = RenderScene(clock: RenderScene.Clock(simTime: Epoch(tdbSecondsPastJ2000: 0)),
                                camera: RenderScene.Camera(position: .zero, worldToView: Mat3(rows: .unitX, .unitZ, -.unitY),
                                                           fovY: 20 * Double.pi / 180,
                                                           viewport: RenderScene.Viewport(width: 64, height: 40),
                                                           target: .vessel(v.id)),
                                sun: RenderScene.Sun(position: sun, direction: toSun, distance: sun.length,
                                                     illuminance: 1.3e5, angularRadius: ShadowFitting.sunAngularRadius),
                                vessels: [v], sites: [])
        let device = try XCTUnwrap(RenderDevice.shared)
        let clouds = try CloudShadowInjection(device: device)
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [clouds],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        XCTAssertEqual(r.failures, [:])
        r.settings = VesselPassTests.manual(RenderSettings())
        func centre(opticalDepth: Float, sunlit: Double) throws -> Double {
            clouds.opticalDepth = opticalDepth
            scene.vessels[0].light.sunlit = sunlit
            return try luminance(scene, renderer: r)[20 * 64 + 32]
        }
        let clear = try centre(opticalDepth: 0, sunlit: 1), half = try centre(opticalDepth: log(2), sunlit: 1)
        let none = try centre(opticalDepth: 0, sunlit: 0)
        XCTAssertGreaterThan(clear, 2 * none, "the Sun lights the plate")
        XCTAssertEqual((half - none) / (clear - none), 0.5, accuracy: 0.005)
    }

    /// The ground from the parking orbit under a uniform deck: its light is
    /// the slab's flux transmittance 2 / (2 + 0.15 τ μ), not e^−τ (μ the
    /// Sun's ray's slope at the clouds). With L(τ) = A + B T(τ) and
    /// T(10⁶) ≈ 0, (L(τ) − L(10⁶)) / (L(0) − L(10⁶)) is T(τ); the μ that τ 10
    /// gives must give τ 40 its reading too (the form), and lie in (0, 1].
    /// Under τ 20 the ground keeps far more than e^−20 of the light.
    func testCloudShadowOnTheGround() throws {
        var shot = SnapshotSpec.Shot(name: "ground", scenario: "as506-parking-orbit",
                                     camera: SnapshotSpec.CameraSpec(yaw: -34.4, pitch: 70, distance: 70, fov: 40))
        shot.width = 160
        shot.height = 100
        shot.showOrbit = false
        shot.settings = VesselPassTests.manual(shot.settings)
        shot.settings.cloud.enabled = false
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let prepared = try shot.prepare(system: s.system)
        let scene = shot.scene(prepared)
        let device = s.device
        let clouds = try CloudShadowInjection(device: device)
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [clouds],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        XCTAssertEqual(r.failures, [:])
        r.settings = shot.settings
        func ground(_ tau: Float) throws -> Double {
            clouds.opticalDepth = tau
            // A corner of the view, the ground beside the stack.
            return try luminance(scene, renderer: r)[12 * 160 + 12]
        }
        let clear = try ground(0), dark = try ground(1e6)
        let t10 = (try ground(10) - dark) / (clear - dark), t40 = (try ground(40) - dark) / (clear - dark)
        let t20 = (try ground(20) - dark) / (clear - dark)
        XCTAssertGreaterThan(clear, 1.2 * dark, "the Sun lights the ground")
        let mu0 = (2 / t10 - 2) / (0.15 * 10)
        XCTAssertGreaterThan(mu0, 0.05)
        XCTAssertLessThanOrEqual(mu0, 1.01)
        XCTAssertEqual(t40, 2 / (2 + 0.15 * 40 * mu0), accuracy: 0.01)
        XCTAssertGreaterThan(t20, 0.2, "the slab passes the Sun's flux on diffusely")
    }
}

extension CloudShadowReceiverTests {
    /// The ground's sky light passes the cover overhead (C2's sky map), not
    /// the clouds on the Sun's line. Over the pad (the stack and the site
    /// taken away, 260 m of air to the ground):
    /// - with the Sun put 1.5° under the horizon the ground has the sky's
    ///   light alone: the sky map's zero takes it (18 % of the pixel; the rest
    ///   is the air's light in front of the ground and PlanetPass's night
    ///   floor, 1.5 % of the albedo), while an opaque deck on the Sun's line
    ///   (hundreds of km off at the terminator) leaves it as it was;
    /// - by day (Sun at 30°) the Sun's line takes the Sun's share and the
    ///   sky map the sky's: the two together more than 80 % of the pixel.
    func testCloudShadowTakesTheSkysLightToo() throws {
        var shot = SnapshotSpec.Shot(name: "pad-ground", scenario: "as506-pad",
                                     camera: SnapshotSpec.CameraSpec(yaw: -60, pitch: 60, distance: 300, fov: 40))
        shot.width = 160
        shot.height = 100
        shot.showOrbit = false
        shot.settings = VesselPassTests.manual(shot.settings)
        shot.settings.cloud.enabled = false
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let prepared = try shot.prepare(system: s.system)
        var scene = shot.scene(prepared)
        scene.vessels = []
        scene.sites = []
        let clouds = try CloudShadowInjection(device: s.device)
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [clouds],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        XCTAssertEqual(r.failures, [:])
        r.settings = shot.settings
        let earth = try XCTUnwrap(scene.bodies.first { $0.id == AtmosphereFrame.planetID })
        let up = (-earth.position).normalized, east = Vec3(0, 0, 1).cross(up).normalized
        // The ground's light under (the Sun's line's optical depth, the sky
        // map's transmittance) against the clear ground's: the share taken.
        func dimmed(sunElevation e: Double, _ deck: (tau: Float, sky: Float)) throws -> Double {
            let toSun = (east * cos(e) + up * sin(e)).normalized
            scene.sun.direction = toSun
            scene.sun.position = toSun * scene.sun.distance
            for i in scene.bodies.indices { scene.bodies[i].toSun = toSun }
            clouds.opticalDepth = 0
            clouds.skyTransmittance = 1
            let clear = try luminance(scene, renderer: r)[50 * 160 + 80]
            clouds.opticalDepth = deck.tau
            clouds.skyTransmittance = deck.sky
            let under = try luminance(scene, renderer: r)[50 * 160 + 80]
            XCTAssertGreaterThan(clear, 0)
            return 1 - under / clear
        }
        let twilight = -1.5 * Double.pi / 180, day = 30 * Double.pi / 180
        let twilightSky = try dimmed(sunElevation: twilight, (0, 0)), twilightLine = try dimmed(sunElevation: twilight, (1e6, 1))
        let daySun = try dimmed(sunElevation: day, (1e6, 1)), dayBoth = try dimmed(sunElevation: day, (1e6, 0))
        print("the pad's ground dimmed: in twilight by the sky map \(twilightSky), by the Sun's line \(twilightLine); "
              + "by day by the Sun's line \(daySun), by both \(dayBoth)")
        XCTAssertGreaterThan(twilightSky, 0.1, "the cover overhead takes the sky's light")
        XCTAssertEqual(twilightLine, 0, accuracy: 1e-3, "the clouds on the Sun's line do not")
        XCTAssertGreaterThan(dayBoth, 0.8)
        XCTAssertGreaterThan(dayBoth - daySun, 0.1, "the sky's share")
    }
}

/// R3's probe draws LC-39A relative to its centre: C2's cloud shadow map,
/// which takes camera-relative points, reads it where the screen does.
final class ProbeCloudShadowTests: XCTestCase {
    func testProbeReadsTheCloudShadowWhereTheScreenDoes() {
        var air = AtmosphereUniforms()
        air.cloudShadowMatrix = simd_float4x4(rows: [SIMD4(1e-5, 2e-6, 0, 0.5), SIMD4(-3e-6, 1e-5, 0, 0.5),
                                                     SIMD4(0.3, 0.2, 0.93, 1_200), SIMD4(0, 0, 0, 1)])
        let center = Vec3(1_500, -4_000, 2_500)
        let probe = VesselPass.probeAtmosphere(air, center: center)
        for p in [Vec3(0, 0, 0), Vec3(1_520, -3_990, 2_480), Vec3(-800, 300, 90)] {
            let screen = air.cloudShadowMatrix * SIMD4(Float(p.x), Float(p.y), Float(p.z), 1)
            let q = p - center
            let inProbe = probe.cloudShadowMatrix * SIMD4(Float(q.x), Float(q.y), Float(q.z), 1)
            XCTAssertEqual(simd_distance(screen, inProbe), 0, accuracy: 0.01, "\(p)")
        }
        XCTAssertEqual(probe.aerialPerspective, .zero)
    }
}

/// C2's cloud shadow as CloudPass leaves it at the end of P0, for a test:
/// the layer on, every point mapped to the map's centre at the ground, the
/// map's optical depth `opticalDepth` at every height, and the sky map's
/// transmittance `skyTransmittance`.
@MainActor
final class CloudShadowInjection: RenderPass {
    let name = "Test cloud shadow"
    let stage = PassStage.prepare
    let order = 1_000
    var opticalDepth: Float = 0
    /// The sky map's transmittance (both ground points).
    var skyTransmittance: Float = 1
    private let map: MTLTexture
    private let sky: MTLTexture

    init(device: MTLDevice) throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        map = try XCTUnwrap(device.makeTexture(descriptor: d))
        sky = try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    func encode(_ f: FrameContext, _ e: PassEncoding) {
        let texels = [SIMD4<Float>](repeating: SIMD4(repeating: opticalDepth), count: 16)
        texels.withUnsafeBytes {
            map.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64)
        }
        f.atmosphere.cloudLayer = SIMD4(0, 2_000, 1, 1)
        f.atmosphere.cloudShadowMatrix = simd_float4x4(columns: (.zero, .zero, .zero, SIMD4(0.5, 0.5, 0, 1)))
        f.slotTextures[Binding.cloudShadow] = map
        let skies = [SIMD4<Float>](repeating: SIMD4(skyTransmittance, skyTransmittance, 0, 0), count: 16)
        skies.withUnsafeBytes {
            sky.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64)
        }
        f.slotTextures[Binding.cloudSky] = sky
    }
}

import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// Track R4's look-dev goldens, hard tests: shadow test cubes in the
/// sun-shadow view (DebugView.sunShadow), at High, at Low (2048², 3×3 PCF)
/// and close up, where the detail map takes over (`Goldens/<gpu family>/
/// r4-lookdev-*.png`; mean linear error under 0.5%, p99.5 ΔE76 under 3).
/// A plate 24 m across, a 2 m cube standing on it (contact shadows), a 1 m
/// cube 3 m above it (a detached shadow, its penumbra 0.03 m), a pole 6 m
/// tall and 12 cm thick (a penumbra widening along its shadow) and a 4 m
/// sheet 8 m up (0.07 m soft), the Sun 35° up. `ORBITSIM_UPDATE_GOLDENS=1`
/// rewrites them; `ORBITSIM_R4_LOOKDEV_OUT=<dir>` also writes the renders there.
@MainActor
final class ShadowLookDevTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    static let degree = Double.pi / 180

    /// The cubes vessel, its construction frame along the world's axes
    /// (z up), its origin on the plate's top at the centre.
    static func cubes() -> RenderScene.Vessel {
        let grey = (0.8, 0.8, 0.8)
        func box(_ centre: Vec3, _ size: Vec3) -> VisualShape {
            .box(from: Vec3(centre.x, centre.y, centre.z - size.z / 2), length: size.z, width: size.x, height: size.y,
                 axis: .unitZ, reference: .unitX, color: grey)
        }
        let shapes = [box(Vec3(0, 0, -0.1), Vec3(24, 24, 0.2)),        // the plate
                      box(Vec3(-5, -3, 1), Vec3(2, 2, 2)),             // standing on it
                      box(Vec3(3, -4, 3.5), Vec3(1, 1, 1)),            // floating 3 m up
                      box(Vec3(-3, 4.5, 3), Vec3(0.12, 0.12, 6)),      // the pole
                      box(Vec3(-7, -6, 8), Vec3(4, 4, 0.05))]          // the sheet 8 m up
        return ShadowPassTests.vessel(shapes, position: .zero)
    }

    /// The cubes seen from `distance` (m) at 40° above the plate, the Sun
    /// 35° up; camera-relative, the camera at the origin.
    static func scene(distance: Double, width: Int = 640, height: Int = 400) -> RenderScene {
        var v = cubes()
        let up = Vec3.unitZ
        let look = Vec3(cos(40 * degree) * cos(300 * degree), cos(40 * degree) * sin(300 * degree), sin(40 * degree))
        let camera = look * distance                                     // from the plate's centre
        v.position = v.position - v.structureOrigin - camera             // the plate's top centre at the target
        let back = look, right = up.cross(back).normalized, viewUp = back.cross(right)
        let toSun = Vec3(cos(35 * degree) * cos(220 * degree), cos(35 * degree) * sin(220 * degree), sin(35 * degree))
        let sun = toSun * 1.496e11 - camera
        return RenderScene(clock: RenderScene.Clock(simTime: Epoch(tdbSecondsPastJ2000: 0)),
                           camera: RenderScene.Camera(position: camera, worldToView: Mat3(rows: right, viewUp, back),
                                                      fovY: 50 * degree,
                                                      viewport: RenderScene.Viewport(width: Double(width),
                                                                                     height: Double(height)),
                                                      target: .vessel(v.id)),
                           sun: RenderScene.Sun(position: sun, direction: sun.normalized, distance: sun.length,
                                                illuminance: 1.3e5, angularRadius: ShadowFitting.sunAngularRadius),
                           vessels: [v], sites: [])
    }

    struct Shot {
        let name: String
        let distance: Double
        let settings: ShadowSettings
    }

    static let shots: [Shot] = {
        var low = ShadowSettings()
        low.mapSize = 2048
        low.maxMaps = 2
        low.filterSamples = 9
        return [Shot(name: "r4-lookdev-cubes", distance: 34, settings: ShadowSettings()),
                Shot(name: "r4-lookdev-cubes-low", distance: 34, settings: low),
                Shot(name: "r4-lookdev-cubes-close", distance: 9, settings: ShadowSettings())]
    }()

    func testShadowCubeGoldens() throws {
        let device = try XCTUnwrap(RenderDevice.shared, "no Metal device")
        let env = ProcessInfo.processInfo.environment
        let update = env["ORBITSIM_UPDATE_GOLDENS"] == "1"
        let goldens = GoldenImageTests.here.appendingPathComponent("Goldens/\(GPUFamily.name(device))")
        if !update, !FileManager.default.fileExists(atPath: goldens.path) {
            throw XCTSkip("no goldens for \(GPUFamily.name(device))")
        }
        let out = env["ORBITSIM_R4_LOOKDEV_OUT"].map { URL(fileURLWithPath: $0) }
        let failures = FileManager.default.temporaryDirectory.appendingPathComponent("orbitsim-golden-failures")
        let r = try SceneRenderer(device: device, loadsUserTextures: false)
        let shadows = try XCTUnwrap(r.graph.pass(named: "Shadows") as? ShadowPass)
        for shot in Self.shots {
            let scene = Self.scene(distance: shot.distance)
            r.settings = RenderSettings()
            r.settings.shadow = shot.settings
            r.settings.debug.view = .sunShadow
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: 640, height: 400))
            r.renderAndWait(scene, into: target)
            let mine = ImageFiles.rgba(fromBGRA: target.bytes())
            let levels = shadows.maps.map(\.level)
            XCTAssertEqual(levels, shot.name.hasSuffix("close") ? [.detail, .cluster] : [.cluster], shot.name)
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try ImageFiles.writePNG(mine, width: 640, height: 400, order: .rgba,
                                        to: out.appendingPathComponent("\(shot.name).png"))
            }
            let file = goldens.appendingPathComponent("\(shot.name).png")
            if update {
                try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
                try ImageFiles.writePNG(mine, width: 640, height: 400, order: .rgba, to: file)
                continue
            }
            let golden = try ImageFiles.readPNG(file)
            XCTAssertEqual([golden.width, golden.height], [640, 400], shot.name)
            guard golden.pixels.count == mine.count else { continue }
            let c = ImageMetrics.compare(golden.pixels, mine)
            let summary = String(format: "%@ (lookdev golden): mean %.4f%%, p99.5 ΔE %.2f, max ΔE %.1f, %d px differ",
                                 shot.name, c.meanLinearError * 100, c.p995DeltaE, c.maxDeltaE, c.differingPixels)
            print(summary)
            if !c.withinGoldenTolerance {
                try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
                try ImageFiles.writePNG(mine, width: 640, height: 400, order: .rgba,
                                        to: failures.appendingPathComponent("\(shot.name).png"))
                try ImageFiles.writePNG(ImageMetrics.difference(golden.pixels, mine), width: 640, height: 400,
                                        order: .rgba, to: failures.appendingPathComponent("\(shot.name).diff.png"))
                XCTFail("out of tolerance: \(summary); render and diff in \(failures.path)")
            }
        }
    }
}

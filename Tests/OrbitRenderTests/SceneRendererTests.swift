import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

@MainActor
final class SceneRendererTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    /// Today's passes are set up and active, every track's stub is off.
    /// R6's effect slots are set up too; they run only on frames an effect
    /// draws in.
    func testDefaultPasses() throws {
        let r = try SceneRenderer(device: try XCTUnwrap(RenderDevice.shared), loadsUserTextures: false)
        XCTAssertEqual(r.failures, [:])
        XCTAssertEqual(r.graph.active.map(\.name), ["Stars", "Planets", "Vessels", "Effect test opaque",
                                                    "Half-resolution transparents", "Orbit line", "Plumes", "Far points",
                                                    "Transparent composite", "Effect test sparks", "Debug view",
                                                    "Effect slots debug view", "Markers"])
        XCTAssertEqual(Set(r.graph.passes.map(\.name)).count, r.graph.passes.count, "pass names are unique")
        for stage in PassStage.allCases {
            XCTAssertTrue(r.graph.passes.contains { $0.stage == stage }, "a pass in every slot, \(stage)")
        }
    }

    /// The Saturn V on the pad, offscreen without the user's textures: sky
    /// above the horizon, ground below, the white vehicle in the middle;
    /// and the same pixels from a second renderer.
    func testRendersThePadOffscreen() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-pad"))
        let sim = scenario.build(Self.system)
        var camera = OrbitCamera()
        let v = try XCTUnwrap(sim.focus)
        camera.target = .vessel(v.id)
        camera.distance = max(v.boundingRadius * 3, 30)
        camera.update(sim: sim)
        let scene = SceneExtractor().extract(sim: sim, camera: camera,
                                             viewport: RenderScene.Viewport(width: 320, height: 200), realTime: 0)

        func image() throws -> [UInt8] {
            let r = try SceneRenderer(device: try XCTUnwrap(RenderDevice.shared), loadsUserTextures: false)
            r.setStars(try StarCatalog.bundled())
            let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: 320, height: 200))
            r.renderAndWait(scene, into: target)
            return target.bytes()
        }
        let pixels = try image()
        func pixel(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
            let i = 4 * (y * 320 + x)
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let sky = pixel(20, 10), ground = pixel(20, 190), vehicle = pixel(160, 100)
        XCTAssertGreaterThan(sky.b, sky.r + 40, "blue sky at the top: \(sky)")
        XCTAssertLessThan(ground.b + ground.g + ground.r, sky.b + sky.g + sky.r, "darker ground below: \(ground)")
        XCTAssertGreaterThan(vehicle.r + vehicle.g + vehicle.b, 300, "the white stack in the middle: \(vehicle)")
        XCTAssertEqual(try image(), pixels, "deterministic")
    }
}

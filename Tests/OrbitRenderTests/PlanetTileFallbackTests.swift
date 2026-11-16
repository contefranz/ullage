import Foundation
import Metal
import XCTest
@testable import OrbitCore
@testable import OrbitRender
@testable import OrbitScene

/// Without tile files the tile store changes nothing: the default passes,
/// with the user's textures on and an empty tile directory, draw the same
/// bytes as the same passes without the tile store (no PlanetTilePass, a
/// PlanetPass without tiles), and every draw uses the planet module E2
/// owns, untouched. (Against main itself: the golden specs' 57 shots,
/// PNG and PFM, rendered byte-identical by main's orbitsnap and this
/// branch's; see docs/m16/planet-tile-cache.md.)
@MainActor
final class PlanetTileFallbackTests: XCTestCase {
    static let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/look/shots")

    func testWithoutTilesTheFrameIsTheOneWithoutTheStore() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-tiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        setenv("ORBITSIM_TILES_DIR", empty.path, 1)
        defer { unsetenv("ORBITSIM_TILES_DIR") }

        let format = MTLPixelFormat.bgra8Unorm_srgb
        let samples = device.supportsTextureSampleCount(SceneRenderer.defaultSampleCount) ? SceneRenderer.defaultSampleCount : 1
        func renderer(withStore: Bool) throws -> SceneRenderer {
            var passes = SceneRenderer.defaultPasses(loadsUserTextures: true)
            if !withStore {
                passes = passes.compactMap { p -> RenderPass? in
                    if p is PlanetTilePass { return nil }
                    if p is PlanetPass { return PlanetPass(loadsUserTextures: true) }
                    return p
                }
            }
            let r = try SceneRenderer(device: device, outputFormat: format, passes: passes,
                                      plan: HDRTargetPlan(outputFormat: format, sampleCount: samples))
            r.setStars(try StarCatalog.bundled())
            return r
        }
        let withStore = try renderer(withStore: true), without = try renderer(withStore: false)
        XCTAssertEqual(withStore.failures, [:])
        let tilePass = try XCTUnwrap(withStore.graph.passes.first { $0 is PlanetTilePass } as? PlanetTilePass)
        XCTAssertEqual(tilePass.directory.path, empty.path)

        let system = try SolarSystem.bundled()
        var compared = 0
        for (file, names) in [("a2.json", ["a2-earth-from-afar", "a2-pad-dawn-wide", "a2-orbit-limb"]), ("f0.json", ["pad"])] {
            let spec = try SnapshotSpec.load(Self.shots.appendingPathComponent(file))
            for var shot in spec.shots where names.contains(shot.name) {
                shot.userTextures = true
                shot.width = 320
                shot.height = 200
                // A fixed exposure: one frame is the whole image. No pad
                // smoke (P4): P3's OIT sums it in the GPU's atomic order,
                // which moves a few bytes between renderers.
                shot.settings.particle.quality = .off
                shot.settings.post.exposure = ExposureSettings(mode: .manual)
                shot.settings.post.exposure.ev100 = 13
                let scene = shot.scene(try shot.prepare(system: system))
                func image(_ r: SceneRenderer) throws -> [UInt8] {
                    r.settings = shot.settings
                    let target = try XCTUnwrap(OffscreenTarget(device: device, width: shot.width, height: shot.height))
                    // The store's first frame looks at the (empty) directory
                    // off the main thread; the next draws after it has.
                    _ = r.renderAndWait(scene, into: target)
                    let deadline = Date().addingTimeInterval(10)
                    while tilePass.status == "not started" && Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    _ = r.renderAndWait(scene, into: target)
                    return target.bytes()
                }
                let a = try image(withStore), b = try image(without)
                XCTAssertEqual(a.count, b.count)
                XCTAssertTrue(a == b, "\(shot.name): \(zip(a, b).filter { $0 != $1 }.count) bytes differ")
                XCTAssertGreaterThan(Set(a).count, 8, "\(shot.name) drew something")
                compared += 1
            }
        }
        XCTAssertEqual(compared, 4)
        XCTAssertTrue(tilePass.layers.isEmpty)
        XCTAssertTrue(tilePass.status.hasPrefix("no Earth tiles in"), tilePass.status)
    }

    /// With an albedo layer the Earth's colour comes from it: an all-magenta
    /// July layer turns the disc magenta, through the default passes; and
    /// with `planetTile.enabled` off the same renderer draws it as before.
    func testAnAlbedoLayerColoursTheEarthAndTheSettingTurnsItOff() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("magenta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 32, b = 4, m = n + 2 * b
        let layout = PlanetTileLayout(format: .jpeg, tileSize: n, border: b, channels: 3, maxLevel: 2, bodyID: 399, figure: .wgs84)
        let w = try PlanetTileWriter(url: dir.appendingPathComponent(EarthTileFiles.albedo(month: 7)), layout: layout)
        let magenta = try PlanetTileCacheTests.jpeg([UInt8](repeating: 0, count: m * m * 3).enumerated().map { $0.offset % 3 == 1 ? 0 : 255 },
                                                    side: m)
        for k in PlanetTileBuilder.keys(levels: 0 ... 2, figure: .wgs84) { try w.add(k, payload: magenta) }
        try w.finish()
        setenv("ORBITSIM_TILES_DIR", dir.path, 1)
        defer { unsetenv("ORBITSIM_TILES_DIR") }
        let r = try SceneRenderer(device: device, loadsUserTextures: true)
        r.setStars(try StarCatalog.bundled())
        let spec = try SnapshotSpec.load(Self.shots.appendingPathComponent("a2.json"))
        var shot = try XCTUnwrap(spec.shots.first { $0.name == "a2-earth-from-afar" })
        shot.width = 320
        shot.height = 200
        shot.settings.post.exposure = ExposureSettings(mode: .manual)
        shot.settings.post.exposure.ev100 = 13
        shot.settings.planetTile.synchronous = true
        let scene = shot.scene(try shot.prepare(system: try SolarSystem.bundled()))
        func magentaPixels(enabled: Bool) throws -> Int {
            var settings = shot.settings
            settings.planetTile.enabled = enabled
            r.settings = settings
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: shot.width, height: shot.height))
            _ = r.renderAndWait(scene, into: target)
            _ = r.renderAndWait(scene, into: target)
            let px = target.bytes()   // BGRA
            return stride(from: 0, to: px.count, by: 4).filter { k in
                let blue = Int(px[k]), green = Int(px[k + 1]), red = Int(px[k + 2])
                return red > green + 25 && blue > green + 25
            }.count
        }
        let tiled = try magentaPixels(enabled: true)
        let tilePass = try XCTUnwrap(r.graph.passes.first { $0 is PlanetTilePass } as? PlanetTilePass)
        XCTAssertNotNil(tilePass.layer(.albedo), tilePass.status)
        XCTAssertGreaterThan(tilePass.layer(.albedo)?.residency.residentCount ?? 0, 0)
        XCTAssertGreaterThan(tiled, 2_000, "the disc is magenta")
        XCTAssertLessThan(try magentaPixels(enabled: false), 50, "off, the Earth is not drawn from the tiles")
    }

    /// The plain planet module is E2's own, with nothing of the tile store;
    /// the tiled one found both of its anchors in it.
    func testThePlanetModuleIsUntouchedAndTheTiledOneComplete() throws {
        XCTAssertFalse(ShaderModule.planet.fullSource.contains("planet_tile"))
        XCTAssertFalse(ShaderModule.planet.fullSource.contains("PlanetTileLayer"))
        let tiled = ShaderModule.planetTiled.source
        XCTAssertFalse(tiled.contains("#error"), "the planet shader's anchors moved")
        XCTAssertTrue(tiled.contains("planet_tile_find(tileIndirection"))
        XCTAssertTrue(tiled.contains("[[texture(5)]]"))
        let device = try XCTUnwrap(RenderDevice.shared)
        XCTAssertNoThrow(try ShaderLibrary(device: device).library(.planetTiled))
    }
}

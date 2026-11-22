import Foundation
import Metal
import XCTest
@testable import OrbitCore
@testable import OrbitScene
@testable import OrbitRender

/// The renderer is deterministic: a frame renders to the same bytes in a
/// fresh renderer as in one that has drawn other scenarios first.
///
/// The orbit shots of r3-scenes differed now and then between orbitsnap
/// processes (a few in a hundred, more with the GPU loaded): the mesh cache
/// keyed parts by their address (`ObjectIdentifier`), which a part of the
/// next shot's simulation could take once the last shot's was freed. That
/// part was served the old part's entry, whose gimballed nozzles were posed
/// by the old thrusters' keys, which no pose answered: the CSM's SPS drew at
/// its null pose, its shadow and reflections with it. Whether an address
/// came back depended on the allocator's timing. Parts and thrusters are
/// keyed by `ObjectSerial` now, which no later object takes.
///
/// A shot also depended on the shots drawn before it in the same renderer:
/// C2 kept its wind drift, cirrus and shadow anchors and weather map, and
/// P2 its last exposure and looks, from one shot to the next (ascent-60s
/// by p99.5 ΔE 10-29 after liftoff). `SnapshotRenderer` starts the renderer
/// over before each shot (`SceneRenderer.startOver`).
@MainActor
final class RenderDeterminismTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    static let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/look/shots")

    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// Two flights of the same scenario, one after the other in one renderer,
    /// the first freed before the second is built: the second never draws an
    /// entry made for the first, and every gimballed draw's thruster is one of
    /// its own vessel's.
    func testANewFlightNeverDrawsTheLastOnesParts() throws {
        let r = try SceneRenderer(device: try device(), loadsUserTextures: false)
        let viewport = RenderScene.Viewport(width: 160, height: 100)
        let scenario = try XCTUnwrap(Scenario.named("as506-parking-orbit"))
        func flight() throws -> (sim: Simulation, scene: RenderScene) {
            let sim = scenario.build(Self.system)
            try ScenarioScript(["stage", "wait:1"]).run(on: sim, missionClockZero: scenario.missionClockZero)
            var camera = OrbitCamera()
            camera.target = .vessel(try XCTUnwrap(sim.focus).id)
            camera.distance = 60
            camera.update(sim: sim)
            return (sim, SceneExtractor().extract(sim: sim, camera: camera, viewport: viewport, realTime: 0))
        }
        var oldEntries: [PartEntry] = []
        var oldAddresses = Set<ObjectIdentifier>()
        weak var firstSim: Simulation?
        try autoreleasepool {
            let first = try flight()
            r.meshes.update(first.scene, device: r.device)
            for v in first.scene.vessels { oldEntries += r.meshes.mesh(v.id)?.parts ?? [] }
            firstSim = first.sim
            for v in first.sim.vessels {
                for p in v.parts {
                    oldAddresses.insert(ObjectIdentifier(p))
                    for t in p.thrusters { oldAddresses.insert(ObjectIdentifier(t)) }
                }
            }
        }
        XCTAssertGreaterThan(oldEntries.count, 10)
        XCTAssertNil(firstSim, "the first flight is freed, so its addresses can come back")

        let second = try flight()
        r.meshes.update(second.scene, device: r.device)
        var reused = 0, gimballed = 0
        for v in second.sim.vessels {
            for p in v.parts {
                if oldAddresses.contains(ObjectIdentifier(p)) { reused += 1 }
                for t in p.thrusters where oldAddresses.contains(ObjectIdentifier(t)) { reused += 1 }
            }
        }
        for v in second.scene.vessels {
            let mesh = try XCTUnwrap(r.meshes.mesh(v.id), v.name)
            for (entry, part) in zip(mesh.parts, v.geometry.parts) {
                XCTAssertFalse(oldEntries.contains { $0 === entry }, "\(v.name): \(part.name) drew the last flight's entry")
                XCTAssertEqual(entry.part.id, part.id, "\(v.name): \(part.name)")
                for d in entry.mesh.draws {
                    guard let key = d.thruster else { continue }
                    gimballed += 1
                    XCTAssertNotNil(v.thrusters[key], "\(v.name): \(part.name) turns with a thruster it does not have")
                }
            }
        }
        XCTAssertGreaterThan(gimballed, 0, "no gimballed nozzle drawn")
        // How many of the second flight's parts and thrusters took the
        // first's addresses: each one could have drawn the first's entry.
        print("RenderDeterminismTests: \(reused) parts and thrusters of the second flight took the first's addresses")
    }

    /// The cache's key covers what an entry is made of: the same part (its
    /// serial) seen with other thrusters is another entry, whose draws turn
    /// with the thrusters it has now.
    func testAPartSeenWithOtherThrustersIsAnotherEntry() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-parking-orbit"))
        let sim = scenario.build(Self.system)
        let geometry = VesselGeometry(of: try XCTUnwrap(sim.focus))
        let part = try XCTUnwrap(geometry.parts.first { $0.thrusters.contains(where: \.isGimballed) })
        let other = VesselGeometry.Part(id: part.id, name: part.name, appearance: part.appearance, offset: part.offset,
                                        shapes: part.shapes, thrusters: part.thrusters.map {
                                            VesselGeometry.ThrusterMount(key: ObjectSerial.next(), name: $0.name,
                                                                         position: $0.position, direction: $0.direction,
                                                                         isGimballed: $0.isGimballed)
                                        })
        XCTAssertTrue(PartKey(part) != PartKey(other), "other thrusters, the same key")
        let moved = VesselGeometry.Part(id: part.id, name: part.name, appearance: part.appearance, offset: part.offset,
                                        shapes: part.shapes, thrusters: part.thrusters.map {
                                            VesselGeometry.ThrusterMount(key: $0.key, name: $0.name,
                                                                         position: $0.position + Vec3(0.1, 0, 0),
                                                                         direction: $0.direction,
                                                                         isGimballed: $0.isGimballed)
                                        })
        XCTAssertTrue(PartKey(part) != PartKey(moved), "a gimbal moved, the same key")
        let again = try XCTUnwrap(VesselGeometry(of: try XCTUnwrap(sim.focus)).parts.first { $0.id == part.id })
        XCTAssertTrue(PartKey(part) == PartKey(again), "the same part, another key")
    }

    /// r3-scenes' orbit shots after a pad shot in one renderer, the first of
    /// them again at the end, and alone in a fresh renderer: the same bytes
    /// each time. (The shots draw no particles, whose blending follows the
    /// GPU's atomics, P3's known exception.)
    func testOrbitShotsRenderTheSameBytesWhateverCameBefore() throws {
        let spec = try SnapshotSpec.load(Self.shots.appendingPathComponent("r3-scenes.json"))
        func shot(_ name: String) throws -> SnapshotSpec.Shot {
            var s = try XCTUnwrap(spec.shots.first { $0.name == name }, name)
            s.aovs = []
            return s
        }
        let pad = try shot("r3-pad-base"), below = try shot("r3-csm-earth-below"), shine = try shot("r3-sivb-earthshine")
        XCTAssertEqual(below.settings.particle.quality, .off)

        let used = try SnapshotRenderer(device: try device())
        _ = try used.render(pad)
        let first = try used.render(below)
        let between = try used.render(shine)
        let again = try used.render(below)
        let fresh = try SnapshotRenderer(device: try device())
        let alone = try fresh.render(below)
        let shineAlone = try fresh.render(shine)

        for (name, a, b) in [("again", first.pixels, again.pixels), ("alone", first.pixels, alone.pixels),
                             ("earthshine alone", between.pixels, shineAlone.pixels)] {
            let differing = zip(a, b).filter { $0 != $1 }.count
            XCTAssertEqual(differing, 0, "\(name): \(differing) bytes differ")
        }
        XCTAssertEqual(first.record.ev100, alone.record.ev100)
    }

    /// f0's ascent at T+60 s under its cloud deck after liftoff, and P2's
    /// SPS burn in daylight after the night one, each against the same shot
    /// in a fresh renderer: the same bytes (particles off, as above).
    func testCloudsAndPlumesStartOverWithEachShot() throws {
        func shots(_ spec: String, _ names: [String]) throws -> [SnapshotSpec.Shot] {
            let all = try SnapshotSpec.load(Self.shots.appendingPathComponent("\(spec).json")).shots
            return try names.map { name in
                var s = try XCTUnwrap(all.first { $0.name == name }, name)
                s.aovs = []
                s.settings.particle.quality = .off
                return s
            }
        }
        for (spec, names) in [("f0", ["liftoff", "ascent-60s"]), ("p2-scenes", ["p2-sps-burn-night", "p2-sps-burn-day"])] {
            let sequence = try shots(spec, names)
            let used = try SnapshotRenderer(device: try device())
            var last: SnapshotRenderer.Output?
            for s in sequence { last = try used.render(s) }
            let after = try XCTUnwrap(last)
            let alone = try SnapshotRenderer(device: try device()).render(try XCTUnwrap(sequence.last))
            let differing = zip(after.pixels, alone.pixels).filter { $0 != $1 }.count
            XCTAssertEqual(differing, 0, "\(names.last!) after \(names.dropLast().joined()): \(differing) bytes differ")
            XCTAssertEqual(after.record.ev100, alone.record.ev100, names.last!)
        }
    }

    /// P2 keeps its visible extents under a coarser key than its trims: the
    /// S-IC's retros and the S-II's ullage motors at staging (clusters of
    /// one or two, whose proxies their members' extents set; a merged far
    /// field's are its own) at two exposures 0.14 stop apart (the least
    /// light drawn e^3.952 and e^4.048 cd/m², 10 %) share the extents'
    /// bucket (0.1 in its log) but not the trims' (0.01), and the extents
    /// found at the two differ. The second after the first in one renderer renders the
    /// bytes it does alone: `PlumeSystem.startOver` clears the extents with
    /// the rest (particles off, as above).
    func testPlumeExtentsStartOverWithEachShot() throws {
        let all = try SnapshotSpec.load(Self.shots.appendingPathComponent("p2-cost.json")).shots
        func shot(logFaintest: Double) throws -> SnapshotSpec.Shot {
            var s = try XCTUnwrap(all.first { $0.name == "p2-cost-staging" })
            s.aovs = []
            s.settings.particle.quality = .off
            s.settings.post.exposure.mode = .manual
            s.settings.post.exposure.ev100 = (logFaintest - log(PlumeSystem.faintest * 1.2)) / log(2)
            return s
        }
        func caches(_ s: SnapshotRenderer) throws -> (extents: [String: [Double]], trims: Set<String>) {
            let r = try s.renderer(userTextures: false)
            let system = try XCTUnwrap(r.graph.passes.compactMap { ($0 as? PlumePreparePass)?.system }.first)
            return (system.extents.mapValues(\.radii), Set(system.trims.keys))
        }
        let a = try shot(logFaintest: 3.952), b = try shot(logFaintest: 4.048)
        let used = try SnapshotRenderer(device: try device())
        _ = try used.render(a)
        let first = try caches(used)
        let after = try used.render(b)
        let fresh = try SnapshotRenderer(device: try device())
        let alone = try fresh.render(b)
        let second = try caches(fresh)
        XCTAssertFalse(first.extents.isEmpty, "the plume's extents are kept")
        XCTAssertEqual(Set(first.extents.keys), Set(second.extents.keys), "the same extents' bucket")
        XCTAssertTrue(first.trims.isDisjoint(with: second.trims), "not the same trims' bucket")
        XCTAssertTrue(first.extents.contains { second.extents[$0.key] != $0.value }, "extents that differ")
        let differing = zip(after.pixels, alone.pixels).filter { $0 != $1 }.count
        XCTAssertEqual(differing, 0, "p2-cost-staging at e^4.048 after e^3.952: \(differing) bytes differ")
        XCTAssertEqual(after.record.ev100, alone.record.ev100)
    }

    // MARK: R3's face schedule and E1's tiles

    /// R3: a frame whose index follows the last one's, with the same body,
    /// target and settings, redraws only some faces of the probe and keeps
    /// the last frame's in the others. After `startOver` it redraws them all,
    /// and renders the bytes a fresh renderer does.
    func testProbeRedrawsEveryFaceAfterStartingOver() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-first-motion"))
        let sim = scenario.build(Self.system)
        var camera = OrbitCamera()
        camera.target = .vessel(try XCTUnwrap(sim.focus).id)
        camera.distance = 120
        camera.update(sim: sim)
        let viewport = RenderScene.Viewport(width: 160, height: 100)
        let a = SceneExtractor().extract(sim: sim, camera: camera, viewport: viewport, realTime: 0)
        var b = a
        b.clock.frameIndex += 1
        func renderer() throws -> (SceneRenderer, OffscreenTarget, EnvironmentProbePass) {
            let r = try SceneRenderer(device: try device(), loadsUserTextures: false)
            var s = RenderSettings()
            s.post.exposure.mode = .manual
            s.post.exposure.ev100 = 15
            s.particle.quality = .off
            r.settings = s
            let probe = try XCTUnwrap(r.graph.passes.first { $0 is EnvironmentProbePass } as? EnvironmentProbePass)
            return (r, try XCTUnwrap(OffscreenTarget(device: r.device, width: 160, height: 100)), probe)
        }
        let (kept, keptTarget, keptProbe) = try renderer()
        kept.renderAndWait(a, into: keptTarget)
        kept.renderAndWait(b, into: keptTarget)
        XCTAssertLessThan(keptProbe.lastFrame.faces.count, 6, "without starting over, b keeps some of a's faces")
        let (over, overTarget, overProbe) = try renderer()
        over.renderAndWait(a, into: overTarget)
        over.startOver()
        over.renderAndWait(b, into: overTarget)
        XCTAssertEqual(overProbe.lastFrame.faces, Array(0 ..< 6))
        let (fresh, freshTarget, _) = try renderer()
        fresh.renderAndWait(b, into: freshTarget)
        XCTAssertTrue(overTarget.bytes() == freshTarget.bytes(), "b after a and starting over, against b alone")
    }

    /// A raw RGBA8 layer to `maxLevel`, every tile one colour of its own.
    func tileLayer(maxLevel: Int) throws -> URL {
        let layout = PlanetTileLayout(format: .uint8, tileSize: 8, border: 2, channels: 4, maxLevel: maxLevel, bodyID: 399,
                                      figure: .wgs84)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("determinism-\(UUID().uuidString).ostiles")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let w = try PlanetTileWriter(url: url, layout: layout)
        for k in PlanetTileBuilder.keys(levels: 0 ... maxLevel, figure: .wgs84).sorted() {
            let texel = [40 * k.level + k.face.rawValue, k.x % 251, k.y % 251, 255]
            try w.add(k, rawSamples: (0 ..< 12 * 12).flatMap { _ in texel })
        }
        try w.finish()
        return url
    }

    func tileCache(_ url: URL) throws -> PlanetTileCache {
        let catalog = try PlanetTileCatalog(files: [(url.lastPathComponent, try PlanetTileFile(contentsOf: url))])
        return try PlanetTileCache(device: try device(), name: "determinism", catalog: catalog, color: false, slots: 64,
                                   maxTextureLevel: 3, pinnedLevel: 1, fileURLs: [url])
    }

    /// Each resident tile's slot.
    func slots(_ c: PlanetTileCache) -> [TileKey: Int] {
        Dictionary(uniqueKeysWithValues: c.residency.residentKeys.map { ($0, c.residency.slot(of: $0)!) })
    }

    /// Every level and face of the cache's indirection texture, as the GPU has it.
    func indirectionBytes(_ c: PlanetTileCache) throws -> [UInt8] {
        let t = c.indirection, queue = try XCTUnwrap(c.device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        var copies: [(MTLBuffer, Int)] = []
        for level in 0 ..< t.mipmapLevelCount {
            let side = max(1, t.width >> level)
            for face in 0 ..< t.arrayLength {
                let b = try XCTUnwrap(c.device.makeBuffer(length: side * side * 4, options: .storageModeShared))
                blit.copy(from: t, sourceSlice: face, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: side, height: side, depth: 1), to: b, destinationOffset: 0,
                          destinationBytesPerRow: side * 4, destinationBytesPerImage: side * side * 4)
                copies.append((b, side * side * 4))
            }
        }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return copies.flatMap { Array(UnsafeRawBufferPointer(start: $0.0.contents(), count: $0.1)) }
    }

    /// E1's cache started over loads and maps as a new cache: the same tiles
    /// in the same slots, the same indirection and deep table on the GPU,
    /// none of the last shot's tiles kept (pinned levels' included). Frame a
    /// reaches level 4, which the deep table holds; frame b wants level 3 at
    /// most, so nothing it loads rewrites the deep table, and only starting
    /// over clears a's level-4 entries from it.
    func testTileCacheStartsOverAsANewCache() throws {
        let url = try tileLayer(maxLevel: 4)
        let used = try tileCache(url), fresh = try tileCache(url)
        XCTAssertEqual(used.residency.indirection.textureMaxLevel, 3, "level 4 lives in the deep table")
        let queue = try XCTUnwrap(used.device.makeCommandQueue())
        func frame(_ c: PlanetTileCache, around d: Vec3, level: Int) throws {
            let centre = TileKey.containing(d, level: level)
            var keys = [centre] + TileKey.Edge.allCases.map { centre.neighbor($0) }
            for k in 0 ..< 4 { if let g = centre.diagonalNeighbor(corner: k) { keys.append(g.key) } }
            let tiles = keys.map { PlanetQuadtree.Tile(key: $0, distance: ($0.centre - d).length, morphStart: 0, morphEnd: 1,
                                                       seams: 0) }
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            c.update(current: PlanetTileWants.ordered(tiles, finestAvailable: c.catalog.finestAvailable), commandBuffer: cb,
                     blit: blit, synchronous: true)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        let a = Vec3(1, 0.2, 0.1).normalized, b = Vec3(-0.3, 1, 0.4).normalized
        try frame(used, around: a, level: 4)
        XCTAssertGreaterThan(used.residency.residentCount, 30)
        XCTAssertEqual(used.residency.residentKeys.filter { $0.level == 4 }.count, 9)
        used.startOver()
        XCTAssertEqual(used.residency.residentCount, 0)
        try frame(used, around: b, level: 3)
        try frame(fresh, around: b, level: 3)
        XCTAssertNil(used.residency.validate())
        XCTAssertGreaterThan(fresh.residency.residentKeys.filter { $0.level == 3 }.count, 0)
        XCTAssertTrue(fresh.residency.residentKeys.allSatisfy { $0.level <= 3 })
        XCTAssertEqual(slots(used), slots(fresh))
        XCTAssertTrue(try indirectionBytes(used) == indirectionBytes(fresh), "the indirection on the GPU")
        XCTAssertEqual(used.deepTable.length, fresh.deepTable.length)
        XCTAssertTrue(Array(UnsafeRawBufferPointer(start: used.deepTable.contents(), count: used.deepTable.length))
                      == Array(UnsafeRawBufferPointer(start: fresh.deepTable.contents(), count: fresh.deepTable.length)),
                      "the deep table")
    }

    /// E1's pass started over selects and loads as a fresh pass's first
    /// frame: no level-of-detail hysteresis, prediction or tiles of the
    /// frames before.
    func testTilePassStartsOverAsANewPass() throws {
        let url = try tileLayer(maxLevel: 4)
        let used = PlanetTilePass(loadsUserTiles: false), fresh = PlanetTilePass(loadsUserTiles: false)
        used.install([.albedo: try tileCache(url)])
        fresh.install([.albedo: try tileCache(url)])
        var settings = PlanetTileSettings()
        settings.synchronous = true
        let queue = try XCTUnwrap(try device().makeCommandQueue())
        func frame(_ pass: PlanetTilePass, _ v: PlanetTilePass.PlanetTileView) throws {
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            pass.frame(v, settings: settings, commandBuffer: cb, blit: blit)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        // From 400 km, looking 30° below the horizon along an orbit; the
        // third view half an orbit on.
        func view(_ u: Double, reset: Bool) -> PlanetTilePass.PlanetTileView {
            let r = 6_778_137.0, p = Vec3(cos(u), sin(u), 0.2).normalized * r
            let along = Vec3(-sin(u), cos(u), 0).normalized, down = -p.normalized
            let forward = (along * cos(Double.pi / 6) + down * sin(Double.pi / 6)).normalized
            let up = (p.normalized - forward * p.normalized.dot(forward)).normalized
            return .init(camera: p, worldToView: Mat3(rows: forward.cross(up), up, -forward), fovY: Double.pi / 4, width: 640,
                         height: 400, orientation: BodyOrientation(icrfToBody: .identity, angularVelocity: .zero),
                         figure: .wgs84, simTime: u * 900, warp: 1, realDt: 1.0 / 60, reset: reset)
        }
        try frame(used, view(0, reset: true))
        try frame(used, view(0.01, reset: false))
        used.startOver()
        XCTAssertTrue(used.lastSelections.isEmpty)
        XCTAssertEqual(used.layer(.albedo)?.residency.residentCount, 0)
        try frame(used, view(3, reset: false))
        try frame(fresh, view(3, reset: false))
        let u = try XCTUnwrap(used.lastSelections[.albedo]), f = try XCTUnwrap(fresh.lastSelections[.albedo])
        XCTAssertTrue(u == f, "the selection")
        XCTAssertGreaterThan(f.tiles.count, 6)
        XCTAssertEqual(slots(try XCTUnwrap(used.layer(.albedo))), slots(try XCTUnwrap(fresh.layer(.albedo))))
    }
}

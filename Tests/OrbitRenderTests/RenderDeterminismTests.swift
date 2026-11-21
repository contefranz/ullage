import Foundation
import Metal
import XCTest
import OrbitCore
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
}

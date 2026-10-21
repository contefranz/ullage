import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

final class SceneExtractorTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    static let viewport = RenderScene.Viewport(width: 640, height: 400)

    /// A scenario's simulation and the app's opening camera on its focus vessel.
    func open(_ id: String) throws -> (Simulation, OrbitCamera) {
        let scenario = try XCTUnwrap(Scenario.named(id))
        let sim = scenario.build(Self.system)
        var camera = OrbitCamera()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
        return (sim, camera)
    }

    func advance(_ sim: Simulation, _ seconds: Double) {
        sim.paused = false
        sim.stepBudget = nil
        var left = seconds
        while left > 1e-9 {
            sim.advance(by: min(5, left))
            left -= min(5, left)
        }
    }

    /// AS-506 just after first motion: one emitter per F-1, kerosene, at
    /// full thrust, each at its nozzle's exit (radius 1.79 m, the F-1's),
    /// the five exits in one plane across the axis below the vehicle's base.
    func testSaturnVAtFirstMotionHasFiveF1Emitters() throws {
        let (sim, camera) = try open("as506-pad")
        let paused = SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        XCTAssertTrue(paused.emitters.isEmpty, "the scenario opens paused, before the first step")
        advance(sim, 0.5)
        let scene = SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        let v = try XCTUnwrap(scene.vessels.first)
        let f1 = scene.emitters.filter { $0.name.hasPrefix("S-IC engine") }
        XCTAssertEqual(f1.count, 5)
        XCTAssertEqual(scene.emitters.count, 5, "only the F-1s fire at first motion")
        let axis = v.attitude.rotate(.unitX)         // the nose
        let base = f1.map { ($0.exit - v.position).dot(axis) }
        for e in f1 {
            XCTAssertEqual(e.style, .kerosene)
            XCTAssertEqual(e.exitRadius, 1.79, accuracy: 0.1)
            XCTAssertGreaterThan(e.thrustFraction, 0.85)
            XCTAssertFalse(e.isJet)
            XCTAssertEqual(e.axis.dot(axis), -1, accuracy: 1e-3, "the exhaust points aft")
            XCTAssertEqual((e.exit - v.position).dot(axis), base[0], accuracy: 0.05)
        }
        XCTAssertLessThan(base[0], -25, "the exits are well below the centre of mass")
        XCTAssertNil(paused.orbit, "no orbit line while the vehicle stands on the pad")
        // The journal's liftoff record comes through once. (The F-1s fire
        // from before the scenario opens, so they have no ignition record.)
        let x = SceneExtractor()
        let records = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0).transitions
            .compactMap { t -> EffectEvent? in
                if case let .event(e) = t { return e }
                return nil
            }
        XCTAssertEqual(records.map(\.kind), [.liftoff])
        XCTAssertEqual(records.first?.vessel, v.id)
        XCTAssertTrue(x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0).transitions.isEmpty)
        XCTAssertEqual(v.farPointStyle, .kerosene)
    }

    /// The plumes start at the exhaust specs' exits: every nozzle the scene
    /// finds on the Apollo vehicles (the F-1s, J-2s, the SPS and the SM RCS
    /// jets, each from the last shape linked to its thruster) has its
    /// spec's exit radius, however many shapes the dresser links to it.
    func testNozzleExitsAreTheExhaustSpecs() throws {
        var checked = Set<String>()
        for v in [VesselLibrary.saturnV(), VesselLibrary.apolloCSM(.apollo7), VesselLibrary.commandModule(.apollo7)] {
            let geometry = VesselGeometry(of: v)
            for p in v.parts {
                for t in p.thrusters {
                    guard let nozzle = geometry.nozzles[ObjectIdentifier(t)] else { continue }
                    let spec = try XCTUnwrap(ExhaustLibrary.spec(for: t, in: p), t.name)
                    XCTAssertEqual(nozzle.radius, spec.exitRadius, accuracy: 1e-9, t.name)
                    checked.insert(String(t.name.prefix(6)))
                }
            }
        }
        XCTAssertEqual(checked, ["S-IC e", "S-II e", "S-IVB ", "SPS", "SM RCS"])
    }

    /// The scene's clock: a reset on the first scene and on a change of
    /// warp, none while time runs on.
    func testClockAndTemporalReset() throws {
        let (sim, camera) = try open("leo")
        let x = SceneExtractor()
        let first = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 10)
        XCTAssertTrue(first.clock.temporalReset)
        XCTAssertEqual(first.clock.frameIndex, 1)
        XCTAssertEqual(first.clock.simDt, 0)
        advance(sim, 2)
        let second = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 10.5)
        XCTAssertFalse(second.clock.temporalReset)
        XCTAssertEqual(second.clock.frameIndex, 2)
        XCTAssertEqual(second.clock.simDt, 2, accuracy: 1e-9)
        XCTAssertEqual(second.clock.realDt, 0.5, accuracy: 1e-12)
        XCTAssertEqual(second.clock.simTimeOfScene, 2, accuracy: 1e-9)
        sim.warp = 10
        XCTAssertTrue(x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 11).clock.temporalReset)
        // A new simulation starts the sequence again.
        let (other, _) = try open("leo")
        XCTAssertEqual(x.extract(sim: other, camera: camera, viewport: Self.viewport, realTime: 12).clock.frameIndex, 1)
    }

    /// Separating the CSM in the parking orbit: the new vessels appear as
    /// transitions on the next scene, each with the stack as its parent.
    func testSeparationAppearsAsTransitions() throws {
        let (sim, camera) = try open("as506-parking-orbit")
        let x = SceneExtractor()
        let stack = try XCTUnwrap(sim.focus)
        _ = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        XCTAssertNotNil(sim.stage(stack))
        let after = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0.1)
        let appeared = after.transitions.compactMap { t -> (UUID, UUID?)? in
            if case let .vesselAppeared(id, _, _, parent, _, _) = t { return (id, parent) }
            return nil
        }
        XCTAssertEqual(appeared.count, sim.vessels.count - 1)
        for (_, parent) in appeared { XCTAssertEqual(parent, stack.id) }
        // The journal's separation records, one per vessel that left the stack.
        let separations = after.transitions.compactMap { t -> UUID? in
            if case let .event(e) = t, case let .separation(_, _, parent) = e.kind { return parent }
            return nil
        }
        XCTAssertFalse(separations.isEmpty)
        XCTAssertTrue(separations.allSatisfy { $0 == stack.id })
        XCTAssertTrue(x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0.2).transitions.isEmpty)
    }

    /// The legacy light passes the core's eclipse through: the capsule in
    /// lunar orbit at 17:00 UTC on 20 July 1969 is in the Moon's shadow.
    func testSunlitFractionPassesThrough() throws {
        let (sim, camera) = try open("llo")
        let scene = SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        let v = try XCTUnwrap(sim.focus)
        let expected = Eclipse.sunlitFraction(at: v.position, relativeTo: v.reference, in: sim.system,
                                              snapshot: sim.snapshot)
        XCTAssertEqual(scene.vessels[0].light.sunlit, expected)
        XCTAssertEqual(expected, 0, "in the Moon's shadow")
    }

    /// Bodies farthest first; the parking orbit's line and its markers.
    func testBodiesAndOrbitOverlay() throws {
        let (sim, camera) = try open("as506-parking-orbit")
        let scene = SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        let distances = scene.bodies.map(\.distance)
        XCTAssertEqual(distances, distances.sorted(by: >))
        XCTAssertEqual(scene.bodies.last?.id, 399)
        XCTAssertTrue(scene.bodies.contains { $0.isSun && $0.id == 10 })
        let orbit = try XCTUnwrap(scene.orbit)
        XCTAssertEqual(orbit.strips.count, 1)
        XCTAssertGreaterThanOrEqual(orbit.strips[0].count, 512)
        XCTAssertNil(SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0,
                                              options: .init(showOrbit: false)).orbit)
        // The Sun's illuminance: about 1.31e5 lx at 1 AU, a little more in July (aphelion: less).
        XCTAssertEqual(scene.sun.illuminance, Photometry.solarIlluminanceAt1AU / pow(scene.sun.distance / Photometry.astronomicalUnit, 2),
                       accuracy: 1e-6)
        XCTAssertEqual(scene.sun.angularRadius * 180 / .pi, 0.2625, accuracy: 0.002, "the Sun near aphelion")
    }

    /// The drogues out on Apollo 7's CM: two canopies with eight risers
    /// each, hanging behind it along the air flow.
    func testCanopiesHangDownstream() throws {
        let (sim, camera) = try open("apollo7-cm-ei")
        let cm = try XCTUnwrap(sim.focus)
        let entry = try XCTUnwrap(ApolloMission.entryProgram(of: cm))
        advance(sim, 1)
        XCTAssertTrue(entry.advanceELS(cm, in: sim))   // apex cover and drogues, the crew's backup
        advance(sim, 3)
        let scene = SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        XCTAssertEqual(scene.canopies.count, 2)
        let flow = scene.vessels[0].flowDirection
        for c in scene.canopies {
            XCTAssertFalse(c.isMain)
            XCTAssertEqual(c.risers.count, 8)
            XCTAssertLessThan(c.axis.dot(flow), -0.9, "behind the CM, against its velocity through the air")
            XCTAssertEqual((c.skirt - scene.vessels[0].position).length, 0, accuracy: 60)
        }
    }

    /// A site placed on LC-39A stands where the Saturn V does, its up axis
    /// along the vehicle's.
    func testSitePlacement() throws {
        let (sim, camera) = try open("as506-pad")
        let x = SceneExtractor()
        let pad = Scenario.lc39A, deg = Double.pi / 180
        x.sites = [SitePlacement(name: "LC-39A", bodyID: 399, latitude: pad.latitude * deg,
                                 longitude: pad.longitude * deg, height: pad.elevation, azimuth: 90 * deg)]
        let scene = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        let site = try XCTUnwrap(scene.sites.first)
        let v = scene.vessels[0]
        let up = site.orientation * Vec3.unitZ, nose = v.attitude.rotate(.unitX)
        XCTAssertEqual(up.dot(nose), 1, accuracy: 1e-6)
        let offset = v.position - site.origin
        XCTAssertLessThan((offset - up * offset.dot(up)).length, 1, "on the pad's axis")
        XCTAssertEqual(offset.dot(up), v.structureOrigin.length, accuracy: 60)
        // Forward points east at azimuth 90°: perpendicular to the pole.
        let forward = site.orientation * Vec3.unitX
        XCTAssertEqual(forward.dot(sim.snapshot.orientation(sim.system.earth).pole), 0, accuracy: 1e-9)
    }
}

final class SceneValuesTests: XCTestCase {
    /// The Hasselblad's lenses on its 55 mm frame: 37.9° for the 80 mm and
    /// 12.6° for the 250 mm (design-earth-moon §2).
    func testHasselbladFieldsOfView() {
        let deg = 180 / Double.pi
        XCTAssertEqual(OrbitCamera.hasselblad80mm * deg, 37.9, accuracy: 0.05)
        XCTAssertEqual(OrbitCamera.hasselblad250mm * deg, 12.6, accuracy: 0.05)
        XCTAssertEqual(OrbitCamera().fovY * deg, 50, accuracy: 1e-12)
        var camera = OrbitCamera()
        camera.fovY = OrbitCamera.hasselblad250mm
        XCTAssertEqual(camera.fovY, OrbitCamera.hasselblad250mm)
    }

    func testSurfaceIDsRoundTrip() {
        let ids = SurfaceIDs(material: 255, paint: 17, decal: 200)
        XCTAssertEqual(SurfaceIDs(packed: ids.packed), ids)
        XCTAssertEqual(ids.packed, Float(255 + 17 * 256 + 200 * 65_536))
        XCTAssertEqual(SurfaceIDs(packed: 0), SurfaceIDs())
    }

    /// A spec gives only the settings it changes.
    func testRenderSettingsDecodePartially() throws {
        let s = try JSONDecoder().decode(RenderSettings.self, from: Data(#"{"debug": {"view": "depth"}}"#.utf8))
        var expected = RenderSettings()
        expected.debug.view = .depth
        XCTAssertEqual(s, expected)
        XCTAssertEqual(try JSONDecoder().decode(RenderSettings.self, from: Data("{}".utf8)), RenderSettings())
        let round = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(expected))
        XCTAssertEqual(round, expected)
    }

    func testScenarioLookup() {
        XCTAssertEqual(Scenario.named("as506-pad")?.name, "Saturn V (AS-506) on LC-39A")
        XCTAssertNil(Scenario.named("no-such-scenario"))
        XCTAssertEqual(Set(Scenario.all.map(\.id)).count, Scenario.all.count, "ids are unique")
    }
}

import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

final class ScenarioScriptTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    func testParsing() throws {
        typealias S = ScenarioScript
        XCTAssertEqual(try S.parse("met:162.3"), .met(162.3))
        XCTAssertEqual(try S.parse(" wait : 5 "), .wait(5))
        XCTAssertEqual(try S.parse("ev:S-IC OECO"), .event("S-IC OECO"))
        XCTAssertEqual(try S.parse("ev:time: 12"), .event("time: 12"), "only the first colon separates")
        XCTAssertEqual(try S.parse("liftoff"), .liftoff)
        XCTAssertEqual(try S.parse("T3"), .timeBase(3))
        XCTAssertEqual(try S.parse("stage"), .stage)
        XCTAssertEqual(try S.parse("throttle:0.5"), .throttle(0.5))
        XCTAssertEqual(try S.parse("warp:100"), .warp(100))
        XCTAssertEqual(try S.parse("autopilot:retrograde"), .autopilot(.retrograde))
        XCTAssertEqual(try S.parse("autopilot:Hold Att"), .autopilot(.attitudeHold))
        XCTAssertEqual(try S.parse("autopilot:off"), .autopilot(nil))
        XCTAssertEqual(try S.parse("fail:S-IC engine 1"), .fail("S-IC engine 1"))
        XCTAssertEqual(try S.parse("focus:CSM"), .focus("CSM"))
        for bad in ["met:soon", "throttle:2", "warp:0", "autopilot:sideways", "t9", "jump", "ev:", "", "   ", ":5"] {
            XCTAssertThrowsError(try S.parse(bad), bad)
        }
    }

    /// Liftoff, then the mission clock: AS-506's first motion is range 0.30 s.
    func testRunsTheSaturnToLiftoffAndAClockTime() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-pad"))
        let sim = scenario.build(Self.system)
        var observed = 0
        try ScenarioScript(["liftoff", "t1", "met:5"]).run(on: sim, missionClockZero: scenario.missionClockZero) { _ in
            observed += 1
        }
        XCTAssertNil(sim.focus?.landed)
        XCTAssertEqual(sim.time - scenario.missionClockZero!, 5, accuracy: 1e-4, "within the epoch's rounding")
        XCTAssertGreaterThan(observed, 4)
        XCTAssertFalse(sim.paused)
    }

    /// A high warp in powered flight still stops where `met:` says: every
    /// stretch runs whole (0.02 s steps, 25,000 of them in one stretch at
    /// 1000×), and only the time the simulation covered counts.
    func testWarpInPoweredFlightReachesTheClockTime() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-pad"))
        let sim = scenario.build(Self.system)
        try ScenarioScript(["warp:1000", "met:500"]).run(on: sim, missionClockZero: scenario.missionClockZero)
        XCTAssertEqual(sim.time - scenario.missionClockZero!, 500, accuracy: 1e-3)
        XCTAssertEqual(sim.warp, 1000)
    }

    /// `ev:` matches only what an IU logs after the command starts, whichever
    /// vessel carries the IU: after CSM separation the S-IVB has it and the
    /// CSM is the focus, and the old "T5: resumed" must not count.
    func testEventIgnoresWhatTheIUHadLogged() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-parking-orbit"))
        let sim = scenario.build(Self.system)
        XCTAssertTrue(ScenarioScript.ius(in: sim).contains { $0.log.contains { $0.event == "T5: resumed" } })
        var script = try ScenarioScript(["stage", "ev:T5: resumed"])
        script.limit = 20
        XCTAssertThrowsError(try script.run(on: sim, missionClockZero: scenario.missionClockZero)) { error in
            guard case .notReached = error as? ScenarioScript.Failure else { return XCTFail("\(error)") }
        }
    }

    /// Space in the parking orbit separates the CSM; `focus` picks a vessel.
    func testStageAndFocus() throws {
        let scenario = try XCTUnwrap(Scenario.named("as506-parking-orbit"))
        let sim = scenario.build(Self.system)
        let before = sim.vessels.count
        try ScenarioScript(["stage", "wait:1"]).run(on: sim, missionClockZero: scenario.missionClockZero)
        XCTAssertGreaterThan(sim.vessels.count, before)
        let name = try XCTUnwrap(sim.vessels.last?.name)
        try ScenarioScript(["focus:\(name)"]).run(on: sim, missionClockZero: nil)
        XCTAssertEqual(sim.focus?.name, name)
        XCTAssertThrowsError(try ScenarioScript(["focus:no such vessel"]).run(on: sim, missionClockZero: nil))
    }

    /// A wait that never ends stops at the limit.
    func testEventNotReached() throws {
        let scenario = try XCTUnwrap(Scenario.named("leo"))
        let sim = scenario.build(Self.system)
        var script = try ScenarioScript(["ev:this never happens"])
        script.limit = 30
        XCTAssertThrowsError(try script.run(on: sim, missionClockZero: nil)) { error in
            guard case .notReached = error as? ScenarioScript.Failure else { return XCTFail("\(error)") }
        }
    }
}

final class SnapshotSpecTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    func testDecodingFillsDefaults() throws {
        let json = #"""
        {"shots": [
          {"name": "a", "scenario": "leo"},
          {"name": "b", "scenario": "as506-pad", "advance": ["met:60"], "width": 320, "height": 200,
           "camera": {"target": "body:399", "frame": "inertial", "yaw": 45, "lens": "hasselblad250"},
           "settings": {"debug": {"view": "depth"}}, "aovs": ["depth", "normals"], "reference": "AS08-14-2383"}
        ]}
        """#
        let spec = try JSONDecoder().decode(SnapshotSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.shots.count, 2)
        let a = spec.shots[0]
        XCTAssertEqual(a, SnapshotSpec.Shot(name: "a", scenario: "leo"))
        XCTAssertEqual([a.width, a.height], [640, 400])
        XCTAssertEqual(a.camera.target, "focus")
        XCTAssertEqual(a.camera.yaw, -2.4 * 180 / .pi, accuracy: 1e-12)
        XCTAssertFalse(a.userTextures)
        let b = spec.shots[1]
        XCTAssertEqual(b.advance, ["met:60"])
        XCTAssertEqual(b.camera.frame, "inertial")
        XCTAssertEqual(b.camera.lens, "hasselblad250")
        XCTAssertEqual(b.settings.debug.view, .depth)
        XCTAssertEqual(b.aovs, [.depth, .normals])
        XCTAssertEqual(b.reference, "AS08-14-2383")
        XCTAssertThrowsError(try JSONDecoder().decode(SnapshotSpec.self, from: Data(#"{"shots": [{"name": "x"}]}"#.utf8)))
    }

    /// A prepared shot: the scenario as the app opens it, then the camera
    /// the spec gives.
    func testPrepare() throws {
        var shot = SnapshotSpec.Shot(name: "earth", scenario: "leo", advance: ["wait:10"])
        shot.camera = SnapshotSpec.CameraSpec(target: "body:399", frame: "inertial", yaw: 30, pitch: 10,
                                              lens: "hasselblad80")
        let p = try shot.prepare(system: Self.system)
        XCTAssertEqual(p.camera.target, .body(399))
        XCTAssertEqual(p.camera.frame, .inertial)
        XCTAssertEqual(p.camera.fovY, OrbitCamera.hasselblad80mm)
        XCTAssertEqual(p.camera.distance, 3 * p.sim.system.earth.radius, accuracy: 1)
        XCTAssertTrue(p.sim.paused)
        XCTAssertEqual(p.sim.time - Scenario.named("leo")!.build(Self.system).time, 10, accuracy: 1e-4)
        let scene = shot.scene(p)
        XCTAssertEqual(scene.camera.viewport, RenderScene.Viewport(width: 640, height: 400))
        XCTAssertGreaterThan(scene.clock.frameIndex, 1, "the extractor followed the flight")

        // The frame carries what happened while the script ran, though the
        // extractor followed the flight: the CSM's separation records.
        let orbit = SnapshotSpec.Shot(name: "sep", scenario: "as506-parking-orbit", advance: ["stage", "wait:3"])
        let prepared = try orbit.prepare(system: Self.system)
        let events = orbit.scene(prepared).transitions.compactMap { t -> EffectEvent? in
            if case let .event(e) = t { return e }
            return nil
        }
        XCTAssertTrue(events.contains { if case .separation = $0.kind { return true } else { return false } })
        XCTAssertEqual(events.map(\.sequence), events.map(\.sequence).sorted(), "oldest first")
        XCTAssertEqual(prepared.advanceTransitions.count, prepared.advanceTransitions.filter {
            if case .event = $0 { return true } else { return false }
        }.count, "only the journal's records come from the script, not positions from earlier cameras")
        XCTAssertFalse(prepared.advanceTransitions.isEmpty)

        shot.camera.target = "vessel:nothing"
        XCTAssertThrowsError(try shot.prepare(system: Self.system))
        XCTAssertThrowsError(try SnapshotSpec.Shot(name: "x", scenario: "nowhere").prepare(system: Self.system))
    }
}

final class ImageMetricsTests: XCTestCase {
    func image(_ n: Int, _ pixel: [UInt8]) -> [UInt8] { Array([[UInt8]](repeating: pixel, count: n).joined()) }

    /// sRGB red against green, ΔE*ab 170.6 (Lindbloom's calculator: red
    /// L*a*b* 53.24, 80.09, 67.20; green 87.73, -86.18, 83.18).
    func testDeltaEOfPrimaries() {
        let red = ImageMetrics.lab(r: 255, g: 0, b: 0)
        XCTAssertEqual(red.l, 53.24, accuracy: 0.01)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.01)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.01)
        let white = ImageMetrics.lab(r: 255, g: 255, b: 255)
        XCTAssertEqual(white.l, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(ImageMetrics.deltaE76((255, 0, 0), (0, 255, 0)), 170.57, accuracy: 0.05)
    }

    func testIdenticalImages() {
        let a = image(100, [10, 200, 30, 255])
        let c = ImageMetrics.compare(a, a)
        XCTAssertEqual(c, ImageMetrics.Comparison(meanLinearError: 0, p995DeltaE: 0, maxDeltaE: 0, differingPixels: 0,
                                                  pixels: 100))
        XCTAssertTrue(c.withinGoldenTolerance)
    }

    /// One pixel in a thousand differing stays under the 99.5th percentile;
    /// one in a hundred does not.
    func testPercentileAndMean() {
        let grey: [UInt8] = [128, 128, 128, 255], black: [UInt8] = [0, 0, 0, 255]
        let a = image(1_000, grey)
        var b = a
        b.replaceSubrange(0..<4, with: black)
        let one = ImageMetrics.compare(a, b)
        XCTAssertEqual(one.differingPixels, 1)
        XCTAssertEqual(one.p995DeltaE, 0)
        XCTAssertGreaterThan(one.maxDeltaE, 50)
        XCTAssertEqual(one.meanLinearError, ImageMetrics.linear[128] / 1_000, accuracy: 1e-12)
        for p in 0..<10 { b.replaceSubrange(4 * p..<4 * p + 4, with: black) }
        let ten = ImageMetrics.compare(a, b)
        XCTAssertEqual(ten.p995DeltaE, ten.maxDeltaE)
        XCTAssertFalse(ten.withinGoldenTolerance)
        // Channel order matters only for which byte is which.
        XCTAssertEqual(ImageMetrics.compare(a, b, order: .bgra).p995DeltaE, ten.p995DeltaE, accuracy: 1e-12)
        XCTAssertEqual(ImageMetrics.difference(a, a), image(1_000, [0, 0, 0, 255]))
    }
}

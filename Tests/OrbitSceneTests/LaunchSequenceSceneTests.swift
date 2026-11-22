import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The live launch sequence in the scene: the pad scenarios open in the
/// terminal count's hold, running; LC-39A's moving elements and P4's effects
/// follow the count (`TerminalCount`), at any time of launch.
final class LaunchSequenceSceneTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    let viewport = RenderScene.Viewport(width: 320, height: 200)

    func open(_ id: String = "as506-pad") throws -> (Simulation, OrbitCamera) {
        let sim = try XCTUnwrap(Scenario.named(id)).build(Self.system)
        sim.stepBudget = nil
        var camera = OrbitCamera()
        camera.target = .vessel(try XCTUnwrap(sim.focus).id)
        camera.distance = 300
        camera.update(sim: sim)
        return (sim, camera)
    }

    func advance(_ sim: Simulation, to range: Double) {
        let count = sim.terminalCount!
        while count.rangeTime(at: sim.time) < range - 1e-6 {
            sim.advance(by: min(0.5, range - count.rangeTime(at: sim.time)))
        }
    }

    func angle(_ name: String, _ site: RenderScene.Site, at epoch: Epoch) -> Double {
        let c = site.countdown(at: epoch)
        return LC39A.elements.first { $0.name == name }!.angle(at: c.rangeTime(at: epoch), c) * 180 / .pi
    }

    // Every Saturn V pad scenario opens running, holding at T−35 s with the
    // F-1s off, and no scenario opens paused; Apollo 7's deorbit neither.
    func testPadScenariosOpenInTheHold() throws {
        for s in Scenario.all {
            let sim = s.build(Self.system)
            XCTAssertFalse(sim.paused, s.id)
            guard let count = sim.terminalCount else { continue }
            XCTAssertTrue(count.isHolding, s.id)
            XCTAssertEqual(count.rangeTime(at: sim.time), Scenario.padHold, s.id)
            XCTAssertTrue(sim.focus!.thrusters.allSatisfy { !$0.isDelivering }, s.id)
            if let zero = s.missionClockZero { XCTAssertEqual(count.plannedRangeZero, zero, s.id) }
        }
        XCTAssertEqual(Set(Scenario.all.compactMap { s in s.build(Self.system).terminalCount.map { _ in s.id } }),
                       ["as506-pad", "apollo8-pad", "as506-earth-orbit-return", "as506-apollo13", "as506-sic-engine1-out"])
    }

    // LC-39A stands in the count: while it holds, range time stands at
    // T−35 s however long it holds, the arms in place; resumed 100 s late,
    // the arms move on the count's own T−0: arm 1 from its command at T−30 s
    // (withdrawn 5.06 s, at its safe angle 9.9 s on), arm 2 from T−16.2 s, the
    // hold-down links at the release, the in-flight arms and tail service
    // masts at the liftoff switches the count found.
    func testSiteFollowsTheCount() throws {
        let (sim, camera) = try open()
        let extractor = SceneExtractor()
        let count = try XCTUnwrap(sim.terminalCount)
        func site() -> RenderScene.Site {
            extractor.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0).sites.first { $0.name == "LC-39A" }!
        }
        sim.advance(by: 100)
        XCTAssertEqual(site().countdown(at: sim.time).rangeTime(at: sim.time), -35, accuracy: 1e-6)
        XCTAssertEqual(angle("Swing arm 1", site(), at: sim.time), 0)
        sim.stage(sim.focus!)
        XCTAssertEqual(count.rangeZero! - VesselLibrary.apollo11RangeZero, 100, accuracy: 1e-6, "100 s late")
        advance(sim, to: -27)
        XCTAssertEqual(angle("Swing arm 1", site(), at: sim.time), 0, "withdrawing")
        advance(sim, to: -22)
        let midway = angle("Swing arm 1", site(), at: sim.time)
        XCTAssert((10...80).contains(midway), "arm 1 swinging: \(midway)°")
        advance(sim, to: -19)
        XCTAssertEqual(angle("Swing arm 1", site(), at: sim.time), 90, accuracy: 1e-9)
        XCTAssertEqual(angle("Swing arm 2", site(), at: sim.time), 0)
        advance(sim, to: -8)
        XCTAssertEqual(angle("Swing arm 2", site(), at: sim.time), 90, accuracy: 1e-9)
        XCTAssertEqual(angle("Hold-down arm 1 link", site(), at: sim.time), 0)
        XCTAssertEqual(angle("Swing arm 4", site(), at: sim.time), 0)
        advance(sim, to: 1)
        let release = try XCTUnwrap(count.released), switches = try XCTUnwrap(count.liftoffSwitch)
        XCTAssertEqual(release - count.rangeZero!, 0.30, accuracy: 1e-6)
        XCTAssertEqual(angle("Hold-down arm 1 link", site(), at: sim.time), 90, accuracy: 1e-9)
        let c = site().countdown(at: sim.time)
        XCTAssertEqual(c.liftoffSwitch, switches - count.rangeZero!, accuracy: 1e-9)
        XCTAssertEqual(c.liftoffSwitch, 0.5, accuracy: 0.03, "0.2 s after the release, the controlled release")
        let arm4 = angle("Swing arm 4", site(), at: sim.time)
        XCTAssert(arm4 > 0 && arm4 < 90, "arm 4 retracting: \(arm4)°")
        advance(sim, to: 12)
        XCTAssertEqual(angle("Swing arm 8", site(), at: sim.time), 90, accuracy: 1e-9)
    }

    // P4's effects run on the count: the LOX tank's fog while it holds; the
    // gas generators' smoke from engine 5's start command at T−6.4 s; the
    // TEA-TEB flash once at each engine's ignition, 1-2-2; the trench's jets
    // from the first ignition at T−3.05 s, as many as the engines' thrust in
    // the core gives (none while the count holds).
    func testEffectsFollowTheCount() throws {
        let (sim, camera) = try open()
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        for _ in 0..<20 { sim.advance(by: 0.1); run.realTime += 0.1; run.frame() }
        XCTAssertGreaterThan(run.count("p4 cold vapour"), 20, "the fog while it holds")
        XCTAssertEqual(run.count("p4 pad exhaust") + run.count("p4 start smoke"), 0)
        sim.stage(sim.focus!)
        let zero = try XCTUnwrap(sim.terminalCount?.rangeZero)
        var flashes: [Double] = [], smokeFrom: Double?, jetsFrom: Double?
        while sim.time - zero < 1 {
            sim.advance(by: 1.0 / 30)
            run.realTime += 1.0 / 30
            let out = run.frame()
            let t = sim.time - zero
            for r in run.requests("p4 ignition flash", in: out) { flashes.append(t - r.ages.lowerBound) }
            if smokeFrom == nil, run.count("p4 start smoke") > 0 { smokeFrom = t }
            if jetsFrom == nil, run.count("p4 pad exhaust") > 0 { jetsFrom = t }
        }
        XCTAssertEqual(flashes.count, 5, "one flash per engine")
        let ignitions = [-3.05, -2.75, -2.75, -2.65, -2.55]
        for (f, i) in zip(flashes.sorted(), ignitions) { XCTAssertEqual(f, i, accuracy: 1e-3) }
        // The first whole particle: the smoke's at its rate, the jets' as the
        // thrust rises from nothing.
        XCTAssertEqual(try XCTUnwrap(smokeFrom), -6.4, accuracy: 0.25)
        XCTAssertEqual(try XCTUnwrap(jetsFrom), -3.05, accuracy: 0.35)
        XCTAssertGreaterThan(try XCTUnwrap(jetsFrom), -3.05)
        XCTAssertGreaterThan(run.count("p4 ground cloud"), 10)
    }

    // No emission repeats itself: over the count, the start and the first
    // 20 s of flight every request of P4's has its own seed, and the jets'
    // and clouds' counts carry their fractions, so neither the particles nor
    // their noise fall into a period.
    func testEmissionNeverRepeats() throws {
        let (sim, camera) = try open()
        sim.stage(sim.focus!)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        while sim.terminalCount!.rangeTime(at: sim.time) < 20 {
            sim.advance(by: 1.0 / 20)
            run.realTime += 1.0 / 20
            run.frame()
        }
        let requests = run.outputs.flatMap(\.requests)
        XCTAssertGreaterThan(requests.count, 1_000)
        XCTAssertEqual(Set(requests.map(\.seed)).count, requests.count, "one seed per request")
        print(String(format: "optical depths: jets %.0f, clouds %.0f, start smoke %.0f; cloud albedo %.2f",
                     LaunchMaterials.jetOpticalDepth, LaunchMaterials.cloudOpticalDepth,
                     LaunchMaterials.startSmokeOpticalDepth, LaunchMaterials.cloudAlbedo))
    }

    // The scenario script's `met:` resumes a count holding short of it, so
    // shots and their goldens take a pad scenario's T−0 at the historic
    // range zero; `count` resumes it alone.
    func testScriptResumesTheCount() throws {
        let (sim, _) = try open()
        try ScenarioScript(["met:-10"]).run(on: sim, missionClockZero: nil)
        XCTAssertEqual(sim.terminalCount?.rangeZero, VesselLibrary.apollo11RangeZero)
        XCTAssertEqual(sim.time - VesselLibrary.apollo11RangeZero, -10, accuracy: 1e-6)
        let (other, _) = try open()
        try ScenarioScript(["count", "wait:5"]).run(on: other, missionClockZero: nil)
        XCTAssertEqual(other.terminalCount!.rangeTime(at: other.time), -30, accuracy: 1e-6)
    }
}

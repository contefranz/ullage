import XCTest
import OrbitCore
@testable import OrbitScene

/// The SPS extension's glow (P2): the wall's temperature along the bell,
/// its lag in simulation time (exact whatever the step), its history from
/// the engine's burn time on a first frame, and the tracker on Apollo 7's
/// deorbit burn.
final class NozzleGlowTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    func testWallTemperatureAlongTheBell() {
        let top = 0.387
        XCTAssertEqual(NozzleGlow.temperature(radius: top, top: top, heat: 1), 1_480, accuracy: 1e-9)
        // At the 62.5:1 exit, √(62.5/6) of the top's radius: ε^-0.225.
        let exit = top * (62.5 / 6).squareRoot()
        XCTAssertEqual(NozzleGlow.temperature(radius: exit, top: top, heat: 1), 1_480 * pow(62.5 / 6, -0.225),
                       accuracy: 1e-6)
        XCTAssertEqual(NozzleGlow.temperature(radius: top, top: top, heat: 0), NozzleGlow.ambient, accuracy: 1e-9)
        // Half the heat: the radiating wall's T⁴ half way.
        let t = NozzleGlow.temperature(radius: top, top: top, heat: 0.5)
        XCTAssertEqual(pow(t, 4), 0.5 * (pow(1_480, 4) + pow(NozzleGlow.ambient, 4)), accuracy: 1e-6 * pow(t, 4))
    }

    func testLagIsExactWhateverTheStep() {
        let once = NozzleGlow.advance(0.1, flow: 1, dt: 7)
        var steps = 0.1
        for _ in 0..<700 { steps = NozzleGlow.advance(steps, flow: 1, dt: 0.01) }
        XCTAssertEqual(once, steps, accuracy: 1e-12)
        XCTAssertEqual(NozzleGlow.heat(sinceIgnition: NozzleGlow.heating, sinceCutoff: nil), 1 - exp(-1), accuracy: 1e-12)
        // A 12 s burn 24 s ago (Apollo 7's SPS-8 is about that long).
        let h = NozzleGlow.heat(sinceIgnition: 36, sinceCutoff: 24)
        XCTAssertEqual(h, (1 - exp(-12 / NozzleGlow.heating)) * exp(-24 / NozzleGlow.cooling), accuracy: 1e-12)
        XCTAssertEqual(NozzleGlow.heat(sinceIgnition: nil, sinceCutoff: nil), 0)
    }

    /// Apollo 7's deorbit burn: the scene's tracker heats the SPS's
    /// extension as the engine's burn time says on its first frame, then
    /// frame by frame in simulation time; paused, it holds.
    func testTrackerOnApollo7sBurn() throws {
        let scenario = try XCTUnwrap(Scenario.named("apollo7-deorbit"))
        let sim = scenario.build(Self.system)
        try ScenarioScript(["throttle:1", "wait:3"]).run(on: sim, missionClockZero: scenario.missionClockZero) { _ in }
        var camera = OrbitCamera()
        let v = try XCTUnwrap(sim.focus)
        camera.target = .vessel(v.id)
        camera.update(sim: sim)
        let x = SceneExtractor(), tracker = NozzleGlowTracker()
        let viewport = RenderScene.Viewport(width: 320, height: 200)
        let first = x.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0)
        let sps = try XCTUnwrap(first.emitters.first { $0.name == "SPS" })
        let h0 = try XCTUnwrap(tracker.update(first)[sps.thruster])
        XCTAssertEqual(h0, NozzleGlow.heat(sinceIgnition: sps.burnTime, sinceCutoff: nil) * min(sps.flowFraction, 1.2),
                       accuracy: 0.02)
        XCTAssertGreaterThan(h0, 0.3)
        sim.advance(by: 2)
        let second = x.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0.1)
        let h1 = try XCTUnwrap(tracker.update(second)[sps.thruster])
        XCTAssertGreaterThan(h1, h0, "heating")
        XCTAssertEqual(try XCTUnwrap(tracker.update(second)[sps.thruster]), h1, accuracy: 1e-12, "the same frame again")
    }
}

import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The Apollo 8 look-development stand-in: AS-506's stack, physics
/// unchanged, dressed as AS-503 on Apollo 8's day.
final class Apollo8PadScenarioTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    func testStandInOnApollo8sDay() throws {
        let scenario = try XCTUnwrap(Scenario.named("apollo8-pad"))
        XCTAssertTrue(scenario.name.contains("stand-in"))
        XCTAssertTrue(scenario.summary.contains("stand-in"))
        XCTAssertEqual(scenario.missionClockZero, Scenario.apollo8RangeZero)
        let sim = scenario.build(Self.system)
        XCTAssertTrue(sim.paused)
        // First motion 0.30 s after Apollo 8's range zero, 12:51:00 UTC.
        XCTAssertEqual(sim.time - Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51), 0.30, accuracy: 1e-6)
        let v = try XCTUnwrap(sim.focus)
        XCTAssertTrue(v.parts.allSatisfy { $0.appearance == .apollo8 }, "dressed as AS-503, CSM-103, LTA-B")
        // The physics is AS-506's: the same parts, masses and engines.
        let reference = try XCTUnwrap(Scenario.named("as506-pad")).build(Self.system)
        let a = try XCTUnwrap(reference.focus)
        XCTAssertEqual(v.parts.map(\.name), a.parts.map(\.name))
        XCTAssertEqual(v.mass, a.mass, accuracy: 1e-9)
        XCTAssertEqual(v.parts.flatMap(\.thrusters).count, a.parts.flatMap(\.thrusters).count)
        // The look differs: LTA-B rides in the SLA, not LM-5.
        let lm = try XCTUnwrap(v.parts.first { $0.name == "LM" }), lm5 = try XCTUnwrap(a.parts.first { $0.name == "LM" })
        XCTAssertNotEqual(lm.shapes.count, 0)
        XCTAssertNotEqual("\(lm.shapes)", "\(lm5.shapes)")
    }

    func testScenarioListHasIt() {
        XCTAssertEqual(Scenario.all.firstIndex { $0.id == "apollo8-pad" }, 2, "after the AS-506 pad")
        XCTAssertEqual(Set(Scenario.all.map(\.id)).count, Scenario.all.count)
    }
}

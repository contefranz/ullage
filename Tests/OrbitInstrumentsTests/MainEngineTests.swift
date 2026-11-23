import XCTest
import OrbitCore
@testable import OrbitInstruments

/// DEORBIT's engine model (`MFDContext.mainEngine`) leaves out an engine
/// that cannot light again (its starts spent), as it leaves out a failed
/// one.
final class MainEngineTests: XCTestCase {
    func testASpentEngineIsNoMainEngine() throws {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 44))
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 32.5)
        let engine = try XCTUnwrap(v.thrusters.first { $0.name == "SM engine" })
        engine.ignitionLimit = 1
        func context() -> MFDContext { MFDContext(sim: sim, vessel: v, snapshot: sim.snapshot) }
        XCTAssertNotNil(context().mainEngine)
        v.mainThrottle = 1
        for _ in 0..<10 { sim.advance(by: 0.02) }
        v.mainThrottle = 0
        for _ in 0..<10 { sim.advance(by: 0.02) }
        XCTAssertTrue(engine.ignitionsSpent)
        XCTAssertNil(context().mainEngine)
    }
}

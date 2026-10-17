import XCTest
@testable import OrbitCore

/// How `advance` bounds a frame at time warp: the real interval it makes up
/// for, the steps and the wall-clock time it may spend, and the flag that
/// tells the HUD the warp was not achieved.
final class TimeWarpTests: XCTestCase {
    /// The toy rocket firing in free space, so every step is a 0.02 s powered
    /// one (62 s of burn).
    func firingRocket() throws -> (Simulation, Vessel) {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        return (sim, v)
    }

    /// A wall clock on which each powered step costs `perStep` seconds (the
    /// Saturn V's is about 0.5 ms in Debug).
    func stepClock(_ sim: Simulation, perStep: Double) -> () -> Double {
        let start = sim.time
        return { [unowned sim] in (sim.time - start) / 0.02 * perStep }
    }

    // The budget bounds a frame's stepping by wall-clock time. At 0.5 ms a
    // step, a 40.25 ms budget stops a 1,000x frame of 0.05 s (50 s, 2,500
    // steps) after 81 steps, 1.62 s: the step that crosses the budget
    // finishes. The rest is dropped, not carried over, so the next frame
    // covers the same.
    func testStepBudgetBoundsAFrame() throws {
        let (sim, _) = try firingRocket()
        sim.clock = stepClock(sim, perStep: 0.0005)
        sim.stepBudget = 0.04025
        sim.warp = 1000
        let start = sim.time
        for frame in 1...2 {
            sim.advance(by: 0.05)
            XCTAssertEqual(sim.time - start, 1.62 * Double(frame), accuracy: 1e-5)
            XCTAssertTrue(sim.warpLimited)
        }
    }

    // On the real clock: a 100,000x frame of 0.1 s would hold 10,000 s of
    // powered flight (20,000 steps under the step cap); with a 10 ms budget
    // it returns within a few times that, having flown part of it.
    func testStepBudgetOnTheWallClock() throws {
        let (sim, _) = try firingRocket()
        sim.stepBudget = 0.01
        sim.warp = 100_000
        let start = sim.time
        let wall0 = ProcessInfo.processInfo.systemUptime
        sim.advance(by: 0.1)
        let wall = ProcessInfo.processInfo.systemUptime - wall0
        XCTAssertLessThan(wall, 0.05)
        XCTAssertGreaterThan(sim.time - start, 0.02)
        XCTAssertLessThan(sim.time - start, 400)
        XCTAssertTrue(sim.warpLimited)
    }

    // The flag says whether a frame covered warp times its real interval;
    // each bound sets it: the real-interval cap (a 0.5 s hitch makes up for
    // 0.1 s), the step cap (10 steps of 0.02 s out of 1 s) and the budget
    // (above). A frame that needs exactly the steps allowed, and a paused
    // frame, are not limited.
    func testWarpLimitedFlag() throws {
        let (sim, _) = try firingRocket()
        sim.warp = 10
        var start = sim.time
        sim.advance(by: 0.1)
        XCTAssertFalse(sim.warpLimited)
        XCTAssertEqual(sim.time - start, 1, accuracy: 1e-6)

        sim.maxRealInterval = 0.1
        start = sim.time
        sim.advance(by: 0.5)
        XCTAssertTrue(sim.warpLimited)
        XCTAssertEqual(sim.time - start, 1, accuracy: 1e-6)

        sim.maxSubsteps = 10
        start = sim.time
        sim.advance(by: 0.1)
        XCTAssertTrue(sim.warpLimited)
        XCTAssertEqual(sim.time - start, 0.2, accuracy: 1e-6)

        sim.warp = 2
        start = sim.time
        sim.advance(by: 0.1)
        XCTAssertFalse(sim.warpLimited)
        XCTAssertEqual(sim.time - start, 0.2, accuracy: 1e-6)

        sim.warp = 10
        sim.advance(by: 0.1)
        XCTAssertTrue(sim.warpLimited)
        sim.paused = true
        start = sim.time
        sim.advance(by: 0.1)
        XCTAssertFalse(sim.warpLimited)
        XCTAssertEqual(sim.time, start)
    }

    // Cutting frames short changes when frames end, not the flight: 25.2 s
    // of burn flown at 1x in 0.02 s frames (a step each) and at 1,000x in
    // the app's 1/60 s frames under a 10.25 ms budget at 0.5 ms a step (60
    // frames of 21 steps) leave the same velocity and propellant.
    func testBudgetLeavesTheFlightUnchanged() throws {
        var results: [(speed: Double, mass: Double)] = []
        for budgeted in [false, true] {
            let (sim, v) = try firingRocket()
            if budgeted {
                sim.clock = stepClock(sim, perStep: 0.0005)
                sim.stepBudget = 0.01025
                sim.warp = 1000
            }
            let start = sim.time
            for _ in 0..<(budgeted ? 60 : 1_260) { sim.advance(by: budgeted ? 1.0 / 60 : 0.02) }
            XCTAssertEqual(sim.time - start, 25.2, accuracy: 1e-4)
            XCTAssertEqual(sim.warpLimited, budgeted)
            results.append((v.velocity.length, v.mass))
        }
        XCTAssertGreaterThan(results[0].speed, 1000)
        XCTAssertEqual(results[1].speed, results[0].speed, accuracy: results[0].speed * 1e-6)
        XCTAssertEqual(results[1].mass, results[0].mass, accuracy: results[0].mass * 1e-6)
    }
}

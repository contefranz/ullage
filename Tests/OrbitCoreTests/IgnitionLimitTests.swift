import XCTest
@testable import OrbitCore

/// Engines that can be started only so many times (`Thruster.ignitionLimit`):
/// the F-1's hypergol cartridge and the S-II J-2's start tank serve one start,
/// the S-IVB's J-2 two (MSFC-MAN-503). Before the limit, X then Z relit an
/// F-1 at once, on the hold-down rods or in flight.
final class IgnitionLimitTests: XCTestCase {
    func run(_ sim: Simulation, seconds: Double) {
        let end = sim.time + seconds
        while end - sim.time > 1e-9 {
            for v in sim.vessels { sim.prepareControls(v) }
            sim.step(min(0.02, sim.maxStep(), end - sim.time))
        }
    }

    // The toy rocket's two engines, one with a single start and one with
    // two, and the rule on a third without a limit (the SPS's): each start
    // from rest counts, a cutoff is final once the starts are spent, and an
    // engine still burning is never stopped by its count.
    func testStartsWithinTheLimit() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeInFreeSpace(v)
        let one = v.thrusters[0], two = v.thrusters[1]
        one.ignitionLimit = 1
        two.ignitionLimit = 2
        XCTAssertFalse(one.ignitionsSpent)
        v.mainThrottle = 1
        run(sim, seconds: 1)
        XCTAssertEqual(one.ignitions, 1)
        XCTAssertEqual(two.ignitions, 1)
        XCTAssertTrue(one.isCommanded)
        XCTAssertFalse(one.ignitionsSpent)
        v.mainThrottle = 0
        run(sim, seconds: 1)
        XCTAssertTrue(one.ignitionsSpent)
        XCTAssertFalse(two.ignitionsSpent)
        v.mainThrottle = 1
        run(sim, seconds: 1)
        XCTAssertFalse(one.isCommanded)
        XCTAssertFalse(one.isDelivering)
        XCTAssertEqual(one.ignitions, 1)
        XCTAssertTrue(two.isCommanded)
        XCTAssertEqual(two.ignitions, 2)
        v.mainThrottle = 0
        run(sim, seconds: 1)
        v.mainThrottle = 1
        run(sim, seconds: 1)
        XCTAssertFalse(two.isCommanded)
        XCTAssertEqual(two.ignitions, 2)
        two.ignitionLimit = nil
        run(sim, seconds: 0.1)
        XCTAssertTrue(two.isCommanded)
        XCTAssertEqual(two.ignitions, 3)
    }

    // The Saturn V's engines: the F-1s and the S-II's J-2s one start each,
    // the S-IVB's J-2 two; the CSM's SPS no limit.
    func testTheSaturnsLimits() {
        let v = VesselLibrary.saturnV()
        for e in v.thrusters where e.name.hasPrefix("S-IC engine") || e.name.hasPrefix("S-II engine") {
            XCTAssertEqual(e.ignitionLimit, 1, e.name)
        }
        XCTAssertEqual(v.thrusters.filter { $0.ignitionLimit == 1 }.count, 10)
        XCTAssertEqual(v.thrusters.first { $0.name == "S-IVB engine" }?.ignitionLimit, 2)
        XCTAssertNil(v.thrusters.first { $0.name == "SPS" }?.ignitionLimit)
    }

    // On the hold-down rods, at the release: X cuts the F-1s, which tail
    // off (the stack, freed, may hop off the pad on the tail-off), and Z
    // lights none of them again: their ground start was their one start.
    func testTheF1sDoNotRelightOnTheRods() throws {
        let sim = try Simulation.forTests(perturbations: true)
        sim.setTime(AS506.rangeZero + TerminalCountTests.hold)
        let count = VesselLibrary.apollo11InTerminalCount(in: sim, hold: TerminalCountTests.hold)
        let v = try XCTUnwrap(count.vehicle)
        count.resume(at: sim.time, in: sim)
        while count.released == nil { run(sim, seconds: 0.02) }
        // On the rods: freed, but not yet past their 6 in stroke.
        XCTAssertLessThan(count.rise(of: v, snapshot: sim.snapshot) ?? 0, 6 * 0.0254)
        let f1s = v.thrusters.filter { $0.name.hasPrefix("S-IC engine") }
        XCTAssertEqual(f1s.count, 5)
        for e in f1s { XCTAssertEqual(e.ignitions, 1, e.name) }
        v.mainThrottle = 0
        run(sim, seconds: 0.1)
        v.mainThrottle = 1   // Z while the S-IC is still the stack's
        run(sim, seconds: 0.02)
        // One step on (the IU's own T3 cutoff then closes the throttle again).
        XCTAssertTrue(v.parts.contains { $0.name == "S-IC" })
        for e in f1s {
            XCTAssertGreaterThan(e.level, 0, e.name)
            XCTAssertFalse(e.isCommanded, e.name)
            XCTAssertEqual(e.ignitions, 1, e.name)
        }
        run(sim, seconds: 1.6)
        for e in f1s {
            XCTAssertFalse(e.isCommanded, e.name)
            XCTAssertFalse(e.isDelivering, e.name)
        }
        // With every F-1 out, the IU senses T3 and stages, as it would for
        // a burnout.
        XCTAssertNotNil((v.flightProgram as? SaturnIU)?.timeBases[.t3])
    }

    /// Apollo 11 from first motion, its IU flying, to range time `t`.
    func fly(to t: Double) throws -> (Simulation, Vessel) {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        v.mainThrottle = 1
        run(sim, seconds: AS506.rangeZero + t - sim.time)
        return (sim, v)
    }

    // In flight, 20 s after first motion: X cuts the F-1s, and Z, pressed
    // while the S-IC is still aboard (the IU senses T3 and separates it
    // 0.7 s later), lights none.
    func testTheF1sDoNotRelightInFlight() throws {
        let (sim, v) = try fly(to: 20)
        XCTAssertNil(v.landed)
        let f1s = v.thrusters.filter { $0.name.hasPrefix("S-IC engine") }
        for e in f1s { XCTAssertTrue(e.isCommanded, e.name) }
        v.mainThrottle = 0
        run(sim, seconds: 0.1)
        v.mainThrottle = 1
        run(sim, seconds: 0.3)
        XCTAssertTrue(v.parts.contains { $0.name == "S-IC" })
        for e in f1s {
            XCTAssertGreaterThan(e.level, 0, e.name)
            XCTAssertFalse(e.isCommanded, e.name)
            XCTAssertEqual(e.ignitions, 1, e.name)
        }
    }

    // X during the S-IC's burn, at T+60 s: the F-1s are out for good, so the
    // IU senses T3 as for a burnout (a spent engine is out, as a failed one
    // is), stages, and lights the S-II; the stack is not left unable to
    // stage.
    func testAnSICCutoffByThePilotStillStages() throws {
        let (sim, v) = try fly(to: 60)
        let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
        XCTAssertNil(iu.timeBases[.t3])
        v.mainThrottle = 0
        run(sim, seconds: 1)
        XCTAssertNotNil(iu.timeBases[.t3])
        run(sim, seconds: 9)
        XCTAssertFalse(v.thrusters.contains { $0.name.hasPrefix("S-IC engine") })
        let j2s = v.thrusters.filter { $0.name.hasPrefix("S-II engine") }
        XCTAssertEqual(j2s.count, 5)
        XCTAssertTrue(j2s.allSatisfy { $0.ignitions == 1 && $0.isDelivering })
    }

    // In the parking orbit the S-IVB's J-2 has its two starts: once they are
    // spent, Z opens the throttle on an engine that cannot light, and the IU
    // does not count it as firing, so Space still separates the CSM.
    func testASpentSIVBDoesNotBlockSeparation() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
        let j2 = try XCTUnwrap(v.thrusters.first { $0.name == "S-IVB engine" })
        for start in 1...2 {
            v.mainThrottle = 1
            run(sim, seconds: 4)
            XCTAssertEqual(j2.ignitions, start)
            v.mainThrottle = 0
            run(sim, seconds: 2)
        }
        v.mainThrottle = 1
        run(sim, seconds: 2)
        XCTAssertTrue(j2.ignitionsSpent)
        XCTAssertFalse(j2.isDelivering)
        XCTAssertTrue(iu.allowsManualStaging(of: v))
        XCTAssertEqual(v.mainDeltaV, 0)
    }

    // On the S-II, 40 s into its burn: X cuts the J-2s, and Z, pressed while
    // the S-II is still aboard, lights none.
    func testTheSIIJ2sDoNotRelight() throws {
        let (sim, v) = try fly(to: 205)
        let j2s = v.thrusters.filter { $0.name.hasPrefix("S-II engine") }
        XCTAssertEqual(j2s.count, 5)
        XCTAssertFalse(v.thrusters.contains { $0.name.hasPrefix("S-IC engine") })
        for e in j2s { XCTAssertTrue(e.isDelivering, e.name) }
        v.mainThrottle = 0
        run(sim, seconds: 0.1)
        v.mainThrottle = 1
        run(sim, seconds: 0.3)
        XCTAssertTrue(v.parts.contains { $0.name == "S-II" })
        for e in j2s {
            XCTAssertGreaterThan(e.level, 0, e.name)
            XCTAssertFalse(e.isCommanded, e.name)
            XCTAssertEqual(e.ignitions, 1, e.name)
        }
    }

    // A landed vessel whose engines' starts are spent, its throttle open,
    // takes the long steps of one at rest: nothing on it can fire.
    func testASpentEngineOnTheGroundIsAtRest() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: 28.6, longitude: -80.6)
        for e in v.thrusters { e.ignitionLimit = 1 }
        for e in v.thrusters { e.groundStart = 0.01 }   // a ground start, too weak to lift
        run(sim, seconds: 0.1)
        for e in v.thrusters { e.groundStart = nil }
        run(sim, seconds: 1)
        XCTAssertNotNil(v.landed)
        v.mainThrottle = 1
        XCTAssertTrue(v.thrusters.allSatisfy { $0.ignitionsSpent })
        for w in sim.vessels { sim.prepareControls(w) }
        XCTAssertEqual(sim.maxStep(for: v), 10)
    }
}

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
        run(sim, seconds: 1)
        for e in f1s { XCTAssertFalse(e.isDelivering, e.name) }
        v.mainThrottle = 1
        run(sim, seconds: 2)
        for e in f1s {
            XCTAssertFalse(e.isCommanded, e.name)
            XCTAssertFalse(e.isDelivering, e.name)
            XCTAssertEqual(e.ignitions, 1, e.name)
        }
        XCTAssertEqual(v.thrustAcceleration, 0)
    }

    /// Apollo 11 from first motion, its IU flying, to range time `t`.
    func fly(to t: Double) throws -> (Simulation, Vessel) {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        v.mainThrottle = 1
        run(sim, seconds: AS506.rangeZero + t - sim.time)
        return (sim, v)
    }

    // In flight, 20 s after first motion: X cuts the F-1s and Z lights none.
    func testTheF1sDoNotRelightInFlight() throws {
        let (sim, v) = try fly(to: 20)
        XCTAssertNil(v.landed)
        let f1s = v.thrusters.filter { $0.name.hasPrefix("S-IC engine") }
        for e in f1s { XCTAssertTrue(e.isCommanded, e.name) }
        v.mainThrottle = 0
        run(sim, seconds: 1)
        v.mainThrottle = 1
        run(sim, seconds: 1)
        for e in f1s {
            XCTAssertFalse(e.isCommanded, e.name)
            XCTAssertFalse(e.isDelivering, e.name)
            XCTAssertEqual(e.ignitions, 1, e.name)
        }
    }

    // On the S-II, 40 s into its burn: X cuts the J-2s and Z lights none.
    func testTheSIIJ2sDoNotRelight() throws {
        let (sim, v) = try fly(to: 205)
        let j2s = v.thrusters.filter { $0.name.hasPrefix("S-II engine") }
        XCTAssertEqual(j2s.count, 5)
        XCTAssertFalse(v.thrusters.contains { $0.name.hasPrefix("S-IC engine") })
        for e in j2s { XCTAssertTrue(e.isDelivering, e.name) }
        v.mainThrottle = 0
        run(sim, seconds: 2)
        v.mainThrottle = 1
        run(sim, seconds: 3)
        for e in j2s {
            XCTAssertFalse(e.isCommanded, e.name)
            XCTAssertFalse(e.isDelivering, e.name)
            XCTAssertEqual(e.ignitions, 1, e.name)
        }
    }
}

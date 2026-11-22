import XCTest
@testable import OrbitCore

/// The warp governor in `Simulation.advance` (`WarpEvent`): the focus
/// vessel's program asks for stops and caps; no step crosses one that would
/// lower the warp, the warp comes down there and is never raised, and with
/// no events a frame is stepped exactly as before the governor.
final class WarpGovernorTests: XCTestCase {
    /// A program that only asks for warp events.
    final class WarpProgram: FlightProgram {
        var events: [WarpEvent]
        init(_ events: [WarpEvent]) { self.events = events }
        func update(_ vessel: Vessel, in sim: Simulation) {}
        func timeToNextEvent(at now: Epoch) -> Double? { nil }
        var status: String { "" }
        func warpEvents(after now: Epoch) -> [WarpEvent] { events.filter { $0.matters(at: now) } }
    }

    let frame = 1.0 / 60

    /// The toy rocket coasting in free space (60 s steps), flown by a
    /// program asking for `events`.
    func coasting(_ events: [WarpEvent]) throws -> (Simulation, Vessel) {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.flightProgram = WarpProgram(events)
        return (sim, v)
    }

    func count(_ sim: Simulation, _ message: String) -> Int { sim.events.filter { $0.message == message }.count }

    // A 1x stop two hours ahead, met at 100,000x (1,667 s a frame): no frame
    // passes it, and the frame that reaches it ends on it, at 1x, logged
    // once. The frames approach it over about 5 s of real time, the warp
    // set staying 100,000x until then. Past it, the pilot may raise the
    // warp again.
    func testStopAtHighWarpIsNotOverrun() throws {
        let start = try Simulation.forTests(perturbations: false).time
        let stop = start + 7_200
        let (sim, _) = try coasting([.stop(at: stop, reason: "TIG-2 min")])
        sim.warp = 100_000
        var frames = 0
        while stop - sim.time > WarpEvent.reachedWithin && frames < 100_000 {
            sim.advance(by: frame)
            frames += 1
            XCTAssertLessThanOrEqual(sim.time - stop, WarpEvent.reachedWithin)
            if stop - sim.time > WarpEvent.reachedWithin {
                XCTAssertEqual(sim.warp, 100_000)
                XCTAssertTrue(sim.warpLimited)
            }
        }
        XCTAssertEqual(sim.time - stop, 0, accuracy: WarpEvent.reachedWithin)
        XCTAssertEqual(sim.warp, 1)
        XCTAssertEqual(count(sim, "Warp 1×: TIG-2 min"), 1)
        print(String(format: "stop met at 100,000x: %d frames, %.1f s of real time", frames, Double(frames) * frame))
        XCTAssertGreaterThan(Double(frames) * frame, 3)
        XCTAssertLessThan(Double(frames) * frame, 7)

        sim.advance(by: frame)
        XCTAssertEqual(sim.time - stop, frame, accuracy: 1e-6)
        sim.warp = 1_000
        sim.advance(by: 0.1)
        XCTAssertEqual(sim.warp, 1_000)
        XCTAssertEqual(sim.time - stop, frame + 100, accuracy: 1e-6)
        XCTAssertEqual(count(sim, "Warp 1×: TIG-2 min"), 1)
    }

    // A 10x cap from 600 s to 1,200 s ahead, met at 1,000x: the frames end
    // on its start, the warp is 10x through it and stays there after it
    // (the governor never raises the warp). A cap already in force lowers
    // the warp at the next frame.
    func testCapWindow() throws {
        let start = try Simulation.forTests(perturbations: false).time
        let (sim, _) = try coasting([.cap(from: start + 600, until: start + 1_200, maxWarp: 10, reason: "TIG-10 min")])
        sim.warp = 1_000
        while sim.time - start < 600 - WarpEvent.reachedWithin {
            sim.advance(by: frame)
            XCTAssertLessThanOrEqual(sim.time - start, 600 + WarpEvent.reachedWithin)
        }
        XCTAssertEqual(sim.warp, 10)
        XCTAssertEqual(count(sim, "Warp at most 10×: TIG-10 min"), 1)
        while sim.time - start < 1_300 {
            sim.advance(by: 0.1)
            XCTAssertLessThanOrEqual(sim.warp, 10)
        }
        XCTAssertEqual(sim.warp, 10)

        let (late, _) = try coasting([.cap(from: start + -60, until: start + 60, maxWarp: 1, reason: "TIG")])
        late.warp = 100
        late.advance(by: 0.1)
        XCTAssertEqual(late.warp, 1)
        XCTAssertEqual(late.time - start, 0.1, accuracy: 1e-6)
        XCTAssertEqual(count(late, "Warp at most 1×: TIG"), 1)
    }

    // The warp is only ever lowered: a 100x stop met at 10x does nothing,
    // and logs nothing. Soft stops are not honoured on their own, nor are
    // the events of a vessel without the focus.
    func testOnlyLoweredAndOnlyHardAndOnlyTheFocus() throws {
        let start = try Simulation.forTests(perturbations: false).time
        let (sim, _) = try coasting([.stop(at: start + 5, maxWarp: 100, reason: "high"),
                                     .stop(at: start + 7, hard: false, reason: "AOS")])
        sim.warp = 10
        sim.advance(by: 1)
        XCTAssertEqual(sim.time - start, 10, accuracy: 1e-6)
        XCTAssertEqual(sim.warp, 10)
        XCTAssertFalse(sim.warpLimited)
        XCTAssertTrue(sim.events.isEmpty)

        let other = Toy.rocket()
        sim.add(other)
        sim.placeInFreeSpace(other)
        other.position += Vec3(1_000, 0, 0)
        other.flightProgram = WarpProgram([.stop(at: start + 20, reason: "other")])
        sim.warp = 1_000
        sim.advance(by: 0.1)
        XCTAssertEqual(sim.time - start, 110, accuracy: 1e-6)
        XCTAssertEqual(sim.warp, 1_000)
        // Given the focus, its stop ahead governs.
        (other.flightProgram as? WarpProgram)?.events = [.stop(at: start + 300, reason: "other")]
        sim.focus = other
        sim.advance(by: 0.1)
        XCTAssertLessThan(sim.time - start, 200)
        XCTAssertTrue(sim.warpLimited)
    }

    /// `advance` as it was before the governor: the frame's simulated time
    /// in steps of `maxStep`, with no budget or caps set.
    func ungoverned(_ sim: Simulation, by real: Double) {
        var remaining = real * sim.warp
        while remaining > 1e-9 {
            for v in sim.vessels { sim.prepareControls(v) }
            let h = min(remaining, sim.maxStep())
            sim.step(h)
            remaining -= h
        }
    }

    // With no warp events a frame is stepped as before the governor, to the
    // bit: Apollo 7's deorbit scenario, its SPS lit as the scenario's crew
    // lights it, flown 60 s at 10x in 0.1 s frames, holds the same state
    // either way. (The §17 ascent and the Apollo 7 pins step the simulation
    // themselves and do not go through `advance`.)
    func testEmptyEventListLeavesSteppingUnchanged() throws {
        var states: [(Vec3, Vec3, Quat, Double)] = []
        for governed in [true, false] {
            let sim = try Simulation.forTests(perturbations: true)
            let v = VesselLibrary.apollo7BeforeDeorbit(in: sim)
            XCTAssertTrue(v.flightProgram?.warpEvents(after: sim.time).isEmpty ?? false)
            sim.warp = 10
            for i in 0..<60 {
                if i == 40 { v.mainThrottle = 1 }
                if governed { sim.advance(by: 0.1) } else { ungoverned(sim, by: 0.1) }
                if governed { XCTAssertFalse(sim.warpLimited) }
            }
            states.append((v.position, v.velocity, v.attitude, v.mass))
        }
        XCTAssertEqual(states[0].0, states[1].0)
        XCTAssertEqual(states[0].1, states[1].1)
        XCTAssertEqual(states[0].2, states[1].2)
        XCTAssertEqual(states[0].3, states[1].3)
    }
}

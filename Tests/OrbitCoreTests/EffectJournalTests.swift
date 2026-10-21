import XCTest
@testable import OrbitCore

/// `EffectJournal` and its hooks: each record's epoch is the event's own,
/// the same at any time warp, with the vessel's state then; the ring stays
/// bounded and tells a reader what it missed.
final class EffectJournalTests: XCTestCase {
    /// A flight program that runs `actions` at their times (s after
    /// `start`), ending steps on them and on `chutes`' reefing changes; to
    /// a microsecond, the epoch's resolution being 0.12 µs in 1969.
    final class Script: FlightProgram {
        let start: Epoch
        var actions: [(at: Double, run: (Vessel, Simulation) -> Void)]
        var chutes: [Parachute] = []
        var done = 0

        init(start: Epoch, actions: [(at: Double, run: (Vessel, Simulation) -> Void)]) {
            self.start = start
            self.actions = actions
        }

        func update(_ vessel: Vessel, in sim: Simulation) {
            while done < actions.count, sim.time - start >= actions[done].at - 1e-6 {
                actions[done].run(vessel, sim)
                done += 1
            }
        }

        func timeToNextEvent(at now: Epoch) -> Double? {
            var times = actions[done...].map { start + $0.at - now }
            for c in chutes { times += c.scheduleCorners(after: now).map { $0 - now } }
            return times.filter { $0 > 1e-6 }.min()
        }

        var status: String { "" }
    }

    /// `Toy.stack` in free space with solid retros on its booster (lit by
    /// their own separation, 0.6 s burns), a solid ullage motor on the
    /// interstage (lit by the booster's separation, 1.5 s), start and
    /// shutdown ramps on the core's engines, and a reefed parachute on the
    /// payload, flown by a script: booster on at 1.007 s, staged at 3.313 s
    /// (the core lights), interstage off at 5.011 s, the parachute out at
    /// 6.223 s (reefed a second later, open two), the core cut off at 7.709
    /// s, the tower off at 9.013 s. The times keep a millisecond clear of
    /// the 60 Hz frames' ends: an event less than that after a step's end
    /// comes on the next step, the step being at least 1 ms long
    /// (`Simulation.maxStep(for:)`).
    func flight(warp: Double) throws -> Simulation {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.stack()
        let booster = v.parts.first { $0.name == "Booster" }!
        let rating = EngineRating(name: "Toy retro", thrustVacuum: 50_000, ispVacuum: 250)
        for (i, y) in [1.0, -1.0].enumerated() {
            let load: Double = 50_000 * 0.6 / (250 * standardGravity)
            let grain = PropellantTank(name: "Booster retro grain", capacity: load)
            booster.tanks.append(grain)
            let retro = Thruster(name: "Booster retro motor \(i + 1)", position: Vec3(8, y * 2.1, 0),
                                 direction: -Vec3.unitX, rating: rating, feed: .single(grain), groups: [])
            retro.isSolid = true
            retro.trigger = .ownSeparation
            booster.thrusters.append(retro)
        }
        let interstage = v.parts.first { $0.name == "Interstage" }!
        let load: Double = 20_000 * 1.5 / (250 * standardGravity)
        let grain = PropellantTank(name: "Ullage grain", capacity: load)
        interstage.tanks.append(grain)
        let ullage = Thruster(name: "Ullage motor", position: Vec3(0, 0, 2.1), direction: .unitX,
                              rating: EngineRating(name: "Toy ullage", thrustVacuum: 20_000, ispVacuum: 250),
                              feed: .single(grain), groups: [])
        ullage.isSolid = true
        ullage.trigger = .event(1)
        interstage.thrusters.append(ullage)
        for t in v.parts.first(where: { $0.name == "Core" })!.thrusters {
            t.transients = EngineTransients(startDelay: 0.5, startRise: 1, shutdown: 0.3)
        }
        let chute = Parachute(name: "Toy chute", count: 1, diameter: 10, dragArea: 50, attachPoint: Vec3(2, 0, 0))
        chute.reefing = [.init(dragArea: 10, duration: 2)]
        v.parts.first { $0.name == "Payload" }!.parachutes = [chute]

        sim.add(v)
        sim.placeInFreeSpace(v)
        let script = Script(start: sim.time, actions: [
            (1.007, { v, _ in v.mainThrottle = 1 }),
            (3.313, { v, sim in sim.stage(v, event: 1) }),
            (5.011, { v, sim in sim.stage(v, event: 2) }),
            (6.223, { _, sim in chute.deploy(at: sim.time) }),
            (7.709, { v, _ in v.mainThrottle = 0 }),
            (9.013, { v, sim in sim.stage(v, event: 3) }),
        ])
        script.chutes = [chute]
        v.flightProgram = script
        sim.warp = warp
        let frame = 1.0 / 60
        for _ in 0..<Int((10 / (frame * warp)).rounded()) { sim.advance(by: frame) }
        sim.recordEffectEdges()
        return sim
    }

    /// A record as a line, without the run's vessel identities.
    func label(_ e: EffectEvent) -> String {
        switch e.kind {
        case let .separation(event, parts, _):
            return "\(e.vesselName): separation \(event ?? -1) \(parts.joined(separator: ","))"
        case let .ignition(thruster, part): return "\(e.vesselName): ignition \(part) \(thruster)"
        case let .cutoff(thruster, part): return "\(e.vesselName): cutoff \(part) \(thruster)"
        case let .parachute(name, state): return "\(e.vesselName): parachute \(name) \(state)"
        default: return "\(e.vesselName): \(e.kind)"
        }
    }

    // The same records at 1× (steps of a 60 Hz frame) and at 100× (0.02 s
    // steps, 1.7 s a frame), at the same epochs to the epoch's rounding:
    // commands at the script's times, the solids' burnouts and the reefing
    // stages where the steps end on them.
    func testSameEpochsAt1xAnd100x() throws {
        let slow = try flight(warp: 1), fast = try flight(warp: 100)
        let start = AS506.rangeZero + AS506.firstMotion
        let a = slow.journal.events.map { (label($0), $0.epoch - start) }
        let b = fast.journal.events.map { (label($0), $0.epoch - start) }
        XCTAssertEqual(a.map(\.0), b.map(\.0))
        for (x, y) in zip(a, b) { XCTAssertEqual(x.1, y.1, accuracy: 1e-6, x.0) }

        // What happened, and when.
        let expected: [(String, Double)] = [
            ("Toy stack: ignition Booster Booster engine 1", 1.007),
            ("Toy stack: ignition Booster Booster engine 2", 1.007),
            ("Toy stack – Booster: separation 1 Booster", 3.313),
            ("Toy stack: ignition Interstage Ullage motor", 3.313),
            ("Toy stack: ignition Core Core engine 1", 3.313),
            ("Toy stack: ignition Core Core engine 2", 3.313),
            ("Toy stack – Booster: cutoff Booster Booster engine 1", 3.313),
            ("Toy stack – Booster: cutoff Booster Booster engine 2", 3.313),
            ("Toy stack – Booster: ignition Booster Booster retro motor 1", 3.313),
            ("Toy stack – Booster: ignition Booster Booster retro motor 2", 3.313),
            ("Toy stack – Booster: cutoff Booster Booster retro motor 1", 3.913),
            ("Toy stack – Booster: cutoff Booster Booster retro motor 2", 3.913),
            ("Toy stack: cutoff Interstage Ullage motor", 4.813),
            ("Toy stack – Interstage: separation 2 Interstage", 5.011),
            ("Toy stack: parachute Toy chute deploying", 6.223),
            ("Toy stack: parachute Toy chute reefed(1)", 7.223),
            ("Toy stack: cutoff Core Core engine 1", 7.709),
            ("Toy stack: cutoff Core Core engine 2", 7.709),
            ("Toy stack: parachute Toy chute open", 8.223),
            ("Toy stack – Tower: separation 3 Tower", 9.013),
        ]
        XCTAssertEqual(a.count, expected.count)
        XCTAssertEqual(Set(a.map(\.0)), Set(expected.map(\.0)))
        // The burnouts to the rounding of the grains' draw over the steps.
        for (name, epoch) in expected {
            XCTAssertEqual(a.first { $0.0 == name }?.1 ?? .nan, epoch, accuracy: 1e-5, name)
        }
        // In the order they happened.
        XCTAssertEqual(a.map(\.1), a.map(\.1).sorted())

        // The separation records name the parts that left, from whom, and
        // carry the leaving vessel's state; a thruster's its place and exhaust.
        let main = try XCTUnwrap(slow.vessels.first { $0.name == "Toy stack" })
        let booster = try XCTUnwrap(slow.journal.events.first {
            if case .separation = $0.kind { return $0.vesselName == "Toy stack – Booster" } else { return false }
        })
        XCTAssertEqual(booster.kind, .separation(event: 1, parts: ["Booster"], parent: main.id))
        let boosterVessel = try XCTUnwrap(slow.vessels.first { $0.id == booster.vessel })
        XCTAssertNotEqual(booster.velocity, .zero)
        let retro = try XCTUnwrap(slow.journal.events.first { $0.kind == .ignition(thruster: "Booster retro motor 1",
                                                                                   part: "Booster") })
        XCTAssertEqual(retro.vessel, boosterVessel.id)
        XCTAssertEqual(retro.direction, Vec3.unitX)
        XCTAssertEqual(retro.epoch, booster.epoch)
    }

    // The ring keeps the last `capacity` records; a reader asking from a
    // sequence the ring has dropped learns how many it missed.
    func testRingIsBounded() throws {
        let journal = EffectJournal(capacity: 4)
        let v = Toy.rocket()
        let t = Epoch(tdbSecondsPastJ2000: 0)
        for i in 0..<10 { journal.record(.splashdown(speed: Double(i)), vessel: v, at: t + Double(i)) }
        XCTAssertEqual(journal.count, 4)
        XCTAssertEqual(journal.nextSequence, 10)
        XCTAssertEqual(journal.events.map(\.sequence), [6, 7, 8, 9])
        let (events, missed) = journal.events(from: 3)
        XCTAssertEqual(events.map(\.sequence), [6, 7, 8, 9])
        XCTAssertEqual(missed, 3)
        XCTAssertEqual(journal.events(from: 8).events.map(\.sequence), [8, 9])
        XCTAssertEqual(journal.events(from: 8).missed, 0)
        XCTAssertTrue(journal.events(from: 10).events.isEmpty)
        journal.removeAll()
        journal.record(.breakup, vessel: v, at: t)
        XCTAssertEqual(journal.events.map(\.sequence), [10])
        // The simulation's journal is bounded too.
        XCTAssertEqual(Simulation(system: try SolarSystem.bundled(), time: t).journal.capacity, 4096)
    }

    // Liftoff: the toy rocket on the pad lifts off on its first step at full
    // throttle, its engines lit at the same epoch.
    func testLiftoff() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: 0.5, longitude: 0.3, azimuth: 0)
        sim.run(seconds: 0.2)
        XCTAssertTrue(sim.journal.events.isEmpty)
        let t0 = sim.time
        v.mainThrottle = 1
        sim.tick()
        let kinds = sim.journal.events.map(\.kind)
        XCTAssertEqual(kinds, [.ignition(thruster: "Stage engine 1", part: "Stage"),
                               .ignition(thruster: "Stage engine 2", part: "Stage"), .liftoff])
        XCTAssertTrue(sim.journal.events.allSatisfy { $0.epoch == t0 })
    }

    // A vessel that arrives burning has not just lit its engines: Apollo 11
    // in its parking orbit has had its APS ullage on since T5, which its IU
    // commands again on the first step (a liquid engine's level is only set
    // by the control pass). Its first frame records no ignition; the ullage
    // cutoff at T5 + 87 s is recorded when it comes, and so are the APS
    // attitude jets' pulses of the turn to the local horizontal.
    func testArrivingBurningRecordsNoIgnition() throws {
        let sim = Simulation(system: try SolarSystem.bundled(), time: AS506.rangeZero)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        let ullage = v.thrusters.filter { $0.name.hasPrefix("APS") && $0.name.hasSuffix("ullage") }
        XCTAssertEqual(ullage.count, 2)
        func ignitions() -> [EffectEvent] {
            sim.journal.events.filter { if case .ignition = $0.kind { return true } else { return false } }
        }
        sim.advance(by: 1.0 / 60)
        XCTAssertTrue(ullage.allSatisfy(\.isCommanded))
        XCTAssertEqual(ignitions().map(\.kind), [])

        sim.warp = 100
        sim.advance(by: 0.8)
        XCTAssertFalse(ignitions().isEmpty)
        for e in ignitions() {
            guard case let .ignition(thruster, _) = e.kind else { continue }
            XCTAssertFalse(ullage.contains { $0.name == thruster }, thruster)
        }
        let off = AS506.rangeZero + AS506.timeBase5 + AS506.tb5UllageOff
        let cutoffs = sim.journal.events.filter { e in
            if case let .cutoff(thruster, _) = e.kind { return ullage.contains { $0.name == thruster } }
            return false
        }
        XCTAssertEqual(cutoffs.count, 2)
        for c in cutoffs { XCTAssertEqual(c.epoch - off, 0, accuracy: 0.02) }
    }

    // Contact: splashdown, touchdown and impacts are recorded with the
    // speed the log gives.
    func testContacts() throws {
        for (latitude, longitude, speed, surface) in [(27.54, -64.07, 9.0, SurfaceKind.water),
                                                      (23.0, 13.0, 3.0, .land),
                                                      (27.54, -64.07, 60.0, .water)] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = VesselLibrary.commandModule(.apollo7)
            sim.add(v)
            let clearance = min(v.baseHeight, v.boundingRadius)
            sim.place(v, geodeticLatitude: latitude, longitude: longitude, height: clearance * 0.9 + 0.05,
                      inertialSpeed: 100, flightPathAngle: -90, azimuth: 0)
            let o = sim.snapshot.orientation(v.reference)
            let up = v.reference.vertical(at: v.position, orientation: o)
            v.velocity = o.angularVelocity.cross(v.position) - up * speed
            sim.updateTelemetry(v, snapshot: sim.snapshot)
            sim.step(0.02)
            let record = try XCTUnwrap(sim.journal.events.last)
            let logged = try XCTUnwrap(sim.events.last?.message)
            let words = logged.split(separator: " "), at = try XCTUnwrap(words.firstIndex(of: "at"))
            let loggedSpeed = try XCTUnwrap(Double(words[at + 1]))
            switch record.kind {
            case let .splashdown(s):
                XCTAssertEqual(surface, .water)
                XCTAssertLessThan(speed, v.impactLimits.water)
                XCTAssertEqual(s, loggedSpeed, accuracy: 0.05)
            case let .touchdown(s):
                XCTAssertEqual(surface, .land)
                XCTAssertEqual(s, loggedSpeed, accuracy: 0.05)
            case let .impact(kind, s):
                XCTAssertEqual(kind, surface)
                XCTAssertGreaterThan(speed, v.impactLimits.water)
                XCTAssertEqual(s, loggedSpeed, accuracy: 0.5)
            default:
                XCTFail("\(record.kind)")
            }
            XCTAssertEqual(record.epoch, sim.time)
            XCTAssertEqual(record.position, v.position)
            XCTAssertEqual(record.reference.id, sim.system.earth.id)
        }
    }
}

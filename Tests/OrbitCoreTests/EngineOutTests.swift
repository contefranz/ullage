import XCTest
@testable import OrbitCore

/// Engine out on the AS-506 model (datasheet §16): the latched failure, the
/// IU's failure schedule and engine-out discrete, GE504's S-IC chi freeze and
/// the IGM's S-II engine-out presettings. References: GE504 (Boeing
/// D5-15706-4: Table 4-II, Figures 3-4 and 4-4 to 4-6), MSFC-MAN-506 (§3,
/// Figure 3-7), the AS-508 FER (MPR-SAT-FE-70-1: Apollo 13's S-II centre
/// engine out, Table 2-2 and §6.1) and the AS-502 FER (Apollo 6's two S-II
/// engines out, §11).
final class EngineOutTests: XCTestCase {
    let deg = Double.pi / 180

    // A failure stops the engine as a cutoff does, from the next step, along
    // the same shutdown ramp; unlike a cutoff, it is latched: neither the
    // controls nor `isEnabled` restart it, and a failed solid is a dud.
    func testFailureIsLatchedAndDistinctFromACutoff() {
        func engine() -> Thruster {
            let e = Thruster(name: "e", position: .zero, direction: .unitX, maxThrustVacuum: 1_000, ispVacuum: 300,
                             tank: PropellantTank(name: "t", capacity: 1_000), groups: [.main])
            e.transients = EngineTransients(shutdown: 0.5)
            e.level = 1
            e.advanceTransients(dt: 0.1)
            return e
        }
        let failed = engine(), cut = engine()
        failed.fail()
        cut.isEnabled = false
        XCTAssertTrue(failed.isFailed && failed.isEnabled)
        XCTAssertFalse(failed.isAvailable || failed.isCommanded)
        XCTAssertFalse(cut.isFailed || cut.isAvailable || cut.isCommanded)
        // The same ramp from the step's start: 1 - (0.1 / 2) / 0.5 of full thrust.
        XCTAssertEqual(failed.thrust(ambientPressure: 0, seaLevelPressure: 0), 900, accuracy: 1e-9)
        XCTAssertEqual(failed.thrust(ambientPressure: 0, seaLevelPressure: 0),
                       cut.thrust(ambientPressure: 0, seaLevelPressure: 0))
        for _ in 0..<6 {
            failed.advanceTransients(dt: 0.1)
            cut.advanceTransients(dt: 0.1)
        }
        XCTAssertFalse(failed.isDelivering || cut.isDelivering)
        // Commanded again, the cut engine restarts; the failed one stays out.
        failed.isEnabled = true
        cut.isEnabled = true
        failed.level = 1
        cut.level = 1
        XCTAssertTrue(cut.isCommanded)
        XCTAssertFalse(failed.isCommanded || failed.isDelivering)
        let solid = Thruster(name: "s", position: .zero, direction: .unitX, maxThrustVacuum: 1_000, ispVacuum: 250,
                             tank: PropellantTank(name: "g", capacity: 10), groups: [])
        solid.isSolid = true
        solid.fail()
        XCTAssertFalse(solid.ignite())
    }

    // GE504 Figure 3-4 ("SA-504 reduced-loads chi-freeze schedule") and Table
    // 4-II: for an S-IC engine out at t_FAIL the freeze lasts 36 s from 25 s
    // for t_FAIL up to 25 s, 40.9 - 0.62 t_FAIL s to 45 s and 29.25 - 0.3611
    // t_FAIL s to 81 s from the shutdown, and 0 after; the figure's lines join
    // at 45 s (13.0 s) and reach 0 at 81 s, and step down at 25 s (36 to 25.4
    // s; Table 4-II, which the LVDC flew, puts 25 s itself in the first row,
    // the figure in the second). The tilt arrest moves out to t_AR + (t_AR -
    // t_FAIL)/4. After the freeze the polynomial runs Δt_f behind.
    func testChiFreezeScheduleIsGE504Figure34() {
        let eo = SaturnIU.EngineOut.as506
        XCTAssertTrue(AS506.engineOutFreezeTimes == (25, 36, 45, 81))
        XCTAssertTrue(AS506.engineOutFreezeLines == (-0.62, 40.9, -0.3611, 29.25))
        for t in [6.0, 13, 24.9, 25] {
            XCTAssertTrue(eo.freeze(failure: t) == (25, 36), "\(t)")
        }
        for (t, duration) in [(25.001, 25.4), (30, 22.3), (45, 13.0), (45.001, 13.0), (60, 7.584), (81, 0.0)] {
            XCTAssertEqual(eo.freeze(failure: t).start, t)
            XCTAssertEqual(eo.freeze(failure: t).duration, duration, accuracy: 0.001, "\(t)")
        }
        XCTAssertTrue(eo.freeze(failure: 90) == (90, 0))
        let tAR = AS506.tiltArrest
        XCTAssertEqual(eo.arrest(tAR, failure: 30), tAR + (tAR - 30) / 4, accuracy: 1e-12)
        XCTAssertEqual(eo.arrest(tAR, failure: tAR + 1), tAR)   // the LVDC already holds the command
        let tilt = AS506.tiltProgram
        for t in stride(from: 0.0, through: 200, by: 3.7) {
            XCTAssertEqual(tilt.pitch(at: t, bias: 0, arrest: tilt.arrest), tilt.pitch(at: t))   // bit for bit
        }
        XCTAssertEqual(tilt.pitch(at: 100, bias: 20, arrest: tilt.arrest), tilt.pitch(at: 80))
        XCTAssertEqual(tilt.pitch(at: 190, bias: 20, arrest: 170), tilt.pitch(at: 150))
    }

    // A failure lands on its time at any warp: stepped as the app steps at
    // 10× (frames of 10/60 s), a step starts on each scheduled failure, in
    // range time or on a time base, and the IU logs it there. The IU senses
    // an F-1 out within a step of its shutdown ramp (0.66 s) falling past the
    // 90 % thrust OK level, 0.066 s on; a second S-IC engine out
    // before 2 min sets off the EDS automatic abort, which is logged only.
    func testFailureLandsOnItsTimeAtTenTimesWarp() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        v.mainThrottle = 1
        let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
        iu.scheduleFailure(of: "S-IC engine 2", at: .range(30))
        iu.scheduleFailure(of: "S-IC engine 4", at: .timeBase(.t1, 30.5))
        let start = sim.time
        func range(_ e: Epoch) -> Double { e - start + AS506.firstMotion }
        var steps: [Epoch] = []
        while range(sim.time) < 31.5 {
            var remaining = 10.0 / 60
            while remaining > 1e-9 {
                for w in sim.vessels { sim.prepareControls(w) }
                steps.append(sim.time)
                let h = min(remaining, sim.maxStep())
                sim.step(h)
                remaining -= h
            }
        }
        let t1 = try XCTUnwrap(iu.timeBases[.t1])
        for (engine, at) in [("S-IC engine 2", start + (30 - AS506.firstMotion)), ("S-IC engine 4", t1 + 30.5)] {
            XCTAssertTrue(steps.contains { abs($0 - at) < 1e-6 }, engine)
            let failed = try XCTUnwrap(iu.log.first { $0.event == "\(engine) failed" })
            XCTAssertEqual(failed.time - at, 0, accuracy: 1e-6)
            let sensed = try XCTUnwrap(iu.log.first { $0.event == "engine out sensed: \(engine)" })
            XCTAssertEqual(sensed.time - at, 0.066, accuracy: 0.021, engine)
            XCTAssertTrue(try XCTUnwrap(v.thrusters.first { $0.name == engine }).isFailed)
        }
        XCTAssertEqual(iu.enginesOut.map(\.engine), ["S-IC engine 2", "S-IC engine 4"])
        XCTAssertNotNil(iu.log.first { $0.event.hasPrefix("EDS automatic abort: two S-IC engines out") })
        XCTAssertTrue(iu.status.hasSuffix("engines out: S-IC engine 2, S-IC engine 4"), iu.status)
    }

    // An S-IC outboard engine out at 30 s: the IU senses it within a step of
    // the F-1's ramp passing 90 %, freezes the pitch program for 40.9 - 0.62 t
    // s from there (GE504), then runs it on that far behind from the value it
    // held, without a step and below the 1°/s command limit; the tilt arrest
    // moves out by a quarter of the time to it. The command follows the
    // program exactly, except where the 1°/s limit takes two steps to cross
    // the polynomial's own joins (up to 0.04°, datasheet §8.4), as it does in
    // the nominal flight.
    func testChiFreezeHoldsAndResumesWithoutAStep() throws {
        let f = EngineOutFlight.sICOutboard30, iu = f.iu
        let t1 = try XCTUnwrap(iu.timeBases[.t1])
        let sensed = try XCTUnwrap(iu.enginesOut.first)
        XCTAssertEqual(sensed.engine, "S-IC engine 1")
        let t = sensed.time - t1
        XCTAssertEqual(t, 30 + 0.066, accuracy: 0.021)
        let freeze = try XCTUnwrap(iu.chiFreeze)
        XCTAssertEqual(freeze.start, t, accuracy: 1e-9)
        XCTAssertEqual(freeze.duration, 40.9 - 0.62 * t, accuracy: 1e-9)
        XCTAssertEqual(iu.tiltArrest, AS506.tiltArrest + (AS506.tiltArrest - t) / 4, accuracy: 1e-9)
        let tilt = iu.plan.tilt, end = freeze.start + freeze.duration
        var last: (t: Double, chi: Double)?, held = 0, after = 0
        for p in f.pitch where p.t >= 20 && p.t < iu.tiltArrest {
            // The polynomial's argument, and the program's command.
            let arg = p.t < freeze.start ? p.t : p.t < end ? freeze.start : p.t - freeze.duration
            let expected = p.t < freeze.start ? tilt.pitch(at: p.t)
                : p.t < end ? tilt.pitch(at: freeze.start)
                : tilt.pitch(at: p.t, bias: freeze.duration, arrest: iu.tiltArrest)
            defer { last = p }
            guard !tilt.boundaries.contains(where: { arg >= $0 && arg < $0 + 0.1 }) else { continue }
            XCTAssertEqual(p.chi, expected, accuracy: 1e-9, "\(p.t)")
            if p.t >= freeze.start && p.t < end { held += 1 }
            if p.t >= end { after += 1 }
            if let l = last, p.t > l.t { XCTAssertLessThan(abs(p.chi - l.chi) / (p.t - l.t), 0.99 * deg, "\(p.t)") }
        }
        XCTAssertGreaterThan(held, 1_000)
        XCTAssertGreaterThan(after, 1_000)
        // Across the resumption: no more than the program's own rate.
        let across = f.pitch.filter { $0.t > end - 0.05 && $0.t < end + 0.05 }
        XCTAssertGreaterThanOrEqual(across.count, 4)
        for (a, b) in zip(across, across.dropFirst()) { XCTAssertLessThan(abs(b.chi - a.chi), 0.75 * deg * (b.t - a.t)) }
        XCTAssertNotNil(iu.log.first { $0.event == "tilt arrest" })
    }

    // T2 starts on the IU's own centre engine cutoff, not on a failure of that
    // engine: with S-IC engine 5 out at 60 s, T1's gain switches at 105 and
    // 130 s and its timed cutoff at 134.56 s stand, and T2 starts the step
    // after that cutoff, as in the nominal flight (the simulation's 1 ms
    // minimum step can put a step's start, and so the cutoff, up to 1 ms
    // after an event). The freeze is GE504's 29.25 - 0.3611 t (7.6 s).
    func testEarlyCentreEngineFailureKeepsT1Events() throws {
        let f = EngineOutFlight.sICCentre60, iu = f.iu
        let t1 = try XCTUnwrap(iu.timeBases[.t1])
        XCTAssertEqual(iu.enginesOut.first?.engine, "S-IC engine 5")
        let gains = iu.log.filter { $0.event == "S-IC flight control gains" }.map { $0.time - t1 }
        XCTAssertEqual(gains.count, 3)
        for (g, at) in zip(gains, [0.0, 105, 130]) { XCTAssertEqual(g, at, accuracy: 1e-6) }
        let ceco = try XCTUnwrap(iu.log.first { $0.event.hasPrefix("S-IC centre engine cutoff") })
        XCTAssertEqual(ceco.event, "S-IC centre engine cutoff (engine already out)")
        XCTAssertEqual(ceco.time - t1, AS506.sICCenterCutoffTime, accuracy: 1e-6)
        let t2 = try XCTUnwrap(iu.timeBases[.t2])
        XCTAssertGreaterThan(t2 - ceco.time, 0)
        XCTAssertLessThanOrEqual(t2 - ceco.time, 0.021 + 1e-6)
        let freeze = try XCTUnwrap(iu.chiFreeze)
        XCTAssertEqual(freeze.duration, 29.25 - 0.3611 * freeze.start, accuracy: 1e-9)
        XCTAssertEqual(freeze.start, 60.066, accuracy: 0.021)
    }

    // With an S-IC engine out at 30 s or 90 s (outboard) or 60 s (centre) the
    // IU keeps its timed centre engine cutoff, the S-IC burns longer, and
    // iterative guidance still takes the S-II and S-IVB to the parking orbit:
    // the velocity cutoff on V_T - ΔV_B (0.01 m/s), on the nominal flight's
    // radius, flight-path angle and plane to its insertion tolerances
    // (`testIGMFliesApollo11ToItsParkingOrbit`: 50 m, 0.005°, 0.003°, 0.006°).
    // The speed after the J-2's decay is checked to 0.6 m/s: ΔV_B is the
    // nominal decay's gain, and a longer burn leaves a lighter S-IVB that the
    // same decay takes further (the failure at 30 s: 134 s more S-IVB burn,
    // about 29 t lighter at cutoff, 0.40 m/s fast). The S-IVB keeps 34.9 t of
    // LOX and 7.0 t of LH2 or more (checked to 25 and 5 t).
    func testSICEngineOutReachesOrbit() throws {
        let nominal = try Insertion.nominal()
        for (name, f) in [("30 s", EngineOutFlight.sICOutboard30), ("90 s", EngineOutFlight.sICOutboard90),
                          ("centre 60 s", EngineOutFlight.sICCentre60)] {
            let i = try XCTUnwrap(f.insertion, name)
            let left = try XCTUnwrap(f.stack.parts.first { $0.name == "S-IVB" }).tanks.prefix(2).map(\.usableMass)
            let igm = AS506.igmPresettings(gm: f.stack.reference.gm)
            XCTAssertEqual(try XCTUnwrap(f.cutoffSpeed, name),
                           (igm.mu / igm.terminalRadius).squareRoot() - igm.cutoffVelocityBias, accuracy: 0.01, name)
            XCTAssertEqual(i.r, nominal.r, accuracy: 50, name)
            XCTAssertEqual(i.v, nominal.v, accuracy: 0.6, name)
            XCTAssertEqual(i.gamma, nominal.gamma, accuracy: 0.005, name)
            XCTAssertEqual(i.inclination, nominal.inclination, accuracy: 0.003, name)
            XCTAssertEqual(i.node, nominal.node, accuracy: 0.006, name)
            XCTAssertGreaterThan(left[0], 25_000, name)
            XCTAssertGreaterThan(left[1], 5_000, name)
        }
        XCTAssertNotNil(EngineOutFlight.sICOutboard30.iu.log
            .first { $0.event == "S-IC centre engine cutoff (with S-IC engine 1 out)" })
        let late = try XCTUnwrap(EngineOutFlight.sICOutboard90.iu.chiFreeze)
        XCTAssertEqual(late.duration, 0)
    }

    // Apollo 13's S-II centre engine out (AS-508, at T3 + 167.0 s, 132.36 s
    // before its planned cutoff; FER Table 2-2), on the AS-506 model against
    // its own nominal flight. AS-508's FER gives the EMR shift command 32.2 s
    // later than predicted, S-II OECO 34.53 s and the S-IVB velocity cutoff
    // 44.06 s, "mainly" from the early cutoff but also from the S-II's 0.25 %
    // low flow and the upper stages' heavier loads (§6.1): 0.25 % of the
    // 429 s burn alone is 1.1 s. So the shift is checked to a guidance cycle
    // (1.7 s: it falls on the cycle) and the cutoffs to 2 s. The presettings
    // already leave the centre engine out, so the IGM's factor stays 1. The
    // parking orbit was nominal (FER Table 4-5: 0.2 km and -0.5 m/s, the
    // navigation's errors included): with perfect navigation the model's
    // insertion must be the nominal flight's, to the cutoff's own 50 m and
    // 0.25 m/s, 0.005° in flight-path angle and the plane's 0.003°/0.006°.
    func testApollo13AnalogueMatchesAS508() throws {
        let f = EngineOutFlight.apollo13, iu = f.iu, n = NominalFlight.shared
        XCTAssertEqual(iu.enginesOut.first?.engine, "S-II engine 5")
        XCTAssertEqual(iu.stage2EngineFactor, 1)
        XCTAssertNotNil(iu.log.first { $0.event == "S-II centre engine cutoff (engine already out)" })
        let shift = "EMR shift command (IGM phase 2)", cutoff = "S-IVB velocity cutoff (IGM)"
        let dShift = try XCTUnwrap(f.time(of: shift)) - XCTUnwrap(n.time(of: shift))
        let dOECO = f.range(try XCTUnwrap(iu.timeBases[.t4])) - n.range(try XCTUnwrap(n.iu.timeBases[.t4]))
        let dCutoff = try XCTUnwrap(f.time(of: cutoff)) - XCTUnwrap(n.time(of: cutoff))
        XCTAssertEqual(dShift, 32.2, accuracy: AS506.igmCycle)
        XCTAssertEqual(dOECO, 34.53, accuracy: 2)
        XCTAssertEqual(dCutoff, 44.06, accuracy: 2)
        let igm = AS506.igmPresettings(gm: f.stack.reference.gm)
        XCTAssertEqual(try XCTUnwrap(f.cutoffSpeed),
                       (igm.mu / igm.terminalRadius).squareRoot() - igm.cutoffVelocityBias, accuracy: 0.01)
        let i = try XCTUnwrap(f.insertion), nominal = try Insertion.nominal()
        XCTAssertEqual(i.r, nominal.r, accuracy: 50)
        XCTAssertEqual(i.v, nominal.v, accuracy: 0.25)
        XCTAssertEqual(i.gamma, nominal.gamma, accuracy: 0.005)
        XCTAssertEqual(i.inclination, nominal.inclination, accuracy: 0.003)
        XCTAssertEqual(i.node, nominal.node, accuracy: 0.006)
    }

    // An outboard S-II engine out (here engine 2 at T3 + 10 s, before IGM
    // start) leaves three of the four engines the stage 2 presettings assume:
    // the IU sets the factor 4/3, and the IGM starts with T2 and τ2 at 4/3 of
    // their presettings (GE504 Fig 4-6, generalised). The flight control
    // computer's re-mix holds the attitude well inside Apollo 6's
    // two-engine-out transient (AS-502 FER §11: 13.4° pitch error, 2.8°/s),
    // a sanity bound only.
    func testSIIOutboardEngineOutStretchesStage2() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        v.mainThrottle = 1
        let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
        iu.scheduleFailure(of: "S-II engine 2", at: .timeBase(.t3, 10))
        let start = sim.time
        func range() -> Double { sim.time - start + AS506.firstMotion }
        var worstError = 0.0, worstRate = 0.0
        while range() < AS506.timeBase3 + AS506.igmStartTime + 3 {
            for w in sim.vessels { sim.prepareControls(w) }
            sim.step(min(0.02, sim.maxStep()))
            if let t3 = iu.timeBases[.t3], sim.time - t3 > 10, let c = v.attitudeCommand {
                worstError = max(worstError, rotationVector(c.attitude.conjugate * v.attitude).length / deg)
                worstRate = max(worstRate, Vec3(0, v.angularVelocity.y, v.angularVelocity.z).length / deg)
            }
        }
        XCTAssertEqual(iu.enginesOut.map(\.engine), ["S-II engine 2"])
        XCTAssertEqual(iu.stage2EngineFactor, 4.0 / 3, accuracy: 1e-15)
        let igm = try XCTUnwrap(iu.guidance), p = AS506.igmPresettings(gm: 0)
        XCTAssertEqual(igm.stage, .first)
        XCTAssertEqual(igm.t2, p.stage2Time * 4 / 3, accuracy: 1e-9)
        XCTAssertEqual(igm.tau2, p.tau2 * 4 / 3, accuracy: 1e-9)
        XCTAssertLessThan(worstError, 13.4)
        XCTAssertLessThan(worstRate, 2.8)
    }

    // A stage that loses every engine has cut off: with all five J-2s failed at
    // T3 + 20 s the IU starts T4 at that step (the stage gone out before any
    // single engine is sensed), and the S-IVB's sequence follows.
    func testLosingEveryEngineOfAStageStartsTheNextTimeBase() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        v.mainThrottle = 1
        let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
        for n in 1...5 { iu.scheduleFailure(of: "S-II engine \(n)", at: .timeBase(.t3, 20)) }
        let start = sim.time
        while sim.time - start + AS506.firstMotion < AS506.timeBase3 + 25 {
            for w in sim.vessels { sim.prepareControls(w) }
            sim.step(min(0.02, sim.maxStep()))
        }
        let t3 = try XCTUnwrap(iu.timeBases[.t3]), t4 = try XCTUnwrap(iu.timeBases[.t4])
        XCTAssertEqual(t4 - t3, 20, accuracy: 1e-6)
        XCTAssertTrue(iu.enginesOut.isEmpty)
        XCTAssertNotNil(iu.log.first { $0.event == "S-II/S-IVB separation" })
        XCTAssertFalse(v.parts.contains { $0.name == "S-II" })
    }
}

/// The parking orbit 10 s after the velocity cutoff, in the IU's space-fixed
/// frame, as `testIGMFliesApollo11ToItsParkingOrbit` measures it: radius (m),
/// speed (m/s), flight-path angle, inclination and descending node from the
/// launch meridian at guidance reference release (deg).
struct Insertion {
    let r: Double, v: Double, gamma: Double, inclination: Double, node: Double

    init(position: Vec3, velocity: Vec3, iu: SaturnIU, sim: Simulation) {
        let frame = iu.spaceFixed!
        let pole = frame.conjugate.rotate(sim.snapshot.orientation(sim.system.earth).pole)
        let r = frame.conjugate.rotate(position), w = frame.conjugate.rotate(velocity)
        let h = r.cross(w).normalized, meridian = (Vec3.unitX - pole * pole.x).normalized
        let node = -pole.cross(h).normalized
        var n = atan2(node.dot(pole.cross(meridian)), node.dot(meridian)) * 180 / .pi
        if n < 0 { n += 360 }
        self.r = r.length
        v = w.length
        gamma = asin(r.normalized.dot(w.normalized)) * 180 / .pi
        inclination = acos(h.dot(pole)) * 180 / .pi
        self.node = n
    }

    /// The nominal flight's (`NominalFlight`, its sample 10 s after the cutoff:
    /// within 0.5 s, on a circular orbit).
    static func nominal() throws -> Insertion {
        let n = NominalFlight.shared
        let cutoff = try XCTUnwrap(n.time(of: "S-IVB velocity cutoff (IGM)"))
        let s = try XCTUnwrap(n.sample(at: cutoff + 10).vessels["Apollo 11"])
        return Insertion(position: s.position, velocity: s.velocity, iu: n.iu, sim: n.sim)
    }
}

/// AS-506 flown with an engine failure scheduled on its IU, stepped as
/// `NominalFlight` steps (0.02 s at most, ending on IU events, so the failure
/// lands on its time), to 10 s after the IGM's velocity cutoff: one flight
/// per case, shared by the tests that read it.
final class EngineOutFlight {
    static let apollo13 = EngineOutFlight("S-II engine 5", at: .timeBase(.t3, 167.0))
    static let sICOutboard30 = EngineOutFlight("S-IC engine 1", at: .timeBase(.t1, 30))
    static let sICOutboard90 = EngineOutFlight("S-IC engine 3", at: .timeBase(.t1, 90))
    static let sICCentre60 = EngineOutFlight("S-IC engine 5", at: .timeBase(.t1, 60))

    let sim: Simulation
    let stack: Vessel
    let iu: SaturnIU
    let start: Epoch
    /// The IU's commanded pitch chi_Y (rad) at the start of each step, by
    /// time from T1 (s), to T3 + 45 s.
    private(set) var pitch: [(t: Double, chi: Double)] = []
    /// Range time of the velocity cutoff, the speed there (m/s; the step's
    /// start, where the IU cuts off), and the state 10 s after it.
    private(set) var cutoff: Double?
    private(set) var cutoffSpeed: Double?
    private(set) var insertion: Insertion?

    private init(_ engine: String, at when: SaturnIU.EngineFailure.Time) {
        sim = try! Simulation.forTests(perturbations: true)
        stack = VesselLibrary.apollo11OnPad(in: sim)
        stack.mainThrottle = 1
        iu = stack.flightProgram as! SaturnIU
        iu.scheduleFailure(of: engine, at: when)
        start = sim.time
        while range() < (cutoff.map { $0 + 10 } ?? 900) - 1e-9 {
            for v in sim.vessels { sim.prepareControls(v) }
            if let t1 = iu.timeBases[.t1], iu.timeBases[.t3].map({ sim.time - $0 < 45 }) ?? true {
                pitch.append((sim.time - t1, iu.chi.y))
            }
            if cutoff == nil, let c = time(of: "S-IVB velocity cutoff (IGM)") {
                cutoff = c
                cutoffSpeed = stack.velocity.length
            }
            sim.step(min(0.02, sim.maxStep(), cutoff.map { $0 + 10 - range() } ?? .infinity))
        }
        if cutoff != nil { insertion = Insertion(position: stack.position, velocity: stack.velocity, iu: iu, sim: sim) }
    }

    /// Range time now, s, and of an epoch.
    func range() -> Double { sim.time - start + AS506.firstMotion }
    func range(_ e: Epoch) -> Double { e - start + AS506.firstMotion }
    /// Range time of the IU log entry `event`, if it was logged.
    func time(of event: String) -> Double? { iu.log.first { $0.event == event }.map { range($0.time) } }
}

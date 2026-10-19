import XCTest
@testable import OrbitCore

/// The parachutes and the earth landing system against TN D-7437 (West,
/// Apollo Experience Report: Earth Landing System, 1973; transcribed by two
/// readers in tools/data/tnd7437_els.csv) and MSC IN 68-FM-184 §5.4.4
/// (Apollo 7's operational trajectory: about 53 s on the drogues, 4 min 45 s
/// on the mains; tools/data/68fm184_sec5_events.csv).
final class ParachuteTests: XCTestCase {
    let ft = 0.3048, lb = 0.45359237

    /// What a descent did: when each ELS step happened, the static pressure
    /// and altitude the CM read at the end of the 0.1 s it happened in, the
    /// splashdown log line, and the CM's tilt from the vertical every 0.1 s
    /// on the open mains.
    struct Descent {
        var start: Epoch
        var upper, cover, drogues, mains: (time: Epoch, pressure: Double, altitude: Double)?
        var splash: (time: Epoch, message: String)?
        var drogueStates: [(Double, Parachute.State)] = [], mainStates: [(Double, Parachute.State)] = []
        var hang: [(time: Double, angle: Double)] = []
        var vessel: Vessel
        var sim: Simulation
    }

    /// The CM falling from 30,000 ft at its terminal speed, heat shield down,
    /// over 68-FM-184's planned landing point (29.8° N, 67.0° W), with the
    /// ELS armed as its program. Its CM structure is lightened by the
    /// ablator and propellant the entry burnt (the model burns neither), so
    /// that once the apex cover has gone it weighs `weightUnderDrogues` (lb;
    /// Apollo 7's drogue-deploy row by default), and under the mains that
    /// less the 74.8 lb drogue pack. `mains` canopies open.
    func descend(weightUnderDrogues: Double = 11_936, mains: Int = 3, lowerBaroswitch: Double? = nil,
                 until limit: Double = 700) throws -> Descent {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.commandModule(.apollo7)
        let cm = try XCTUnwrap(v.parts.first { $0.name == "CM" })
        let cover = try XCTUnwrap(v.parts.first { $0.name == "Apex cover" })
        cm.dryMass -= v.mass - cover.mass - weightUnderDrogues * lb
        v.recenter()
        let chutes = v.parachutes
        let mainCluster = try XCTUnwrap(chutes.first { $0.name == "Main parachutes" })
        mainCluster.count = mains
        sim.add(v)
        let height = 30_000 * ft
        sim.place(v, geodeticLatitude: 29.8, longitude: -67, height: height, inertialSpeed: 100,
                  flightPathAngle: -90, azimuth: 0)
        let o = sim.snapshot.orientation(v.reference)
        let up = v.position.normalized, east = o.pole.cross(up).normalized, north = up.cross(east)
        v.attitude = Quat(matrix: Mat3(columns: up, east, north))
        let rho = try XCTUnwrap(sim.atmosphere(of: v.reference)).state(altitude: height).density
        v.velocity = o.angularVelocity.cross(v.position) - up * (2 * v.mass * 9.79 / (rho * v.dragArea)).squareRoot()
        let els = EarthLandingSystem(armed: true)
        if let p = lowerBaroswitch { els.lowerBaroswitch = p }
        v.flightProgram = els
        sim.updateTelemetry(v, snapshot: sim.snapshot)

        var d = Descent(start: sim.time, vessel: v, sim: sim)
        func reading() -> (Epoch, Double, Double) { (sim.time, v.atmosphere.pressure, v.altitude) }
        while v.status == .flying && sim.time - d.start < limit {
            sim.advance(by: 0.1)
            let t = sim.time - d.start
            if d.upper == nil, els.upperBaroswitchClosed != nil { d.upper = reading() }
            if d.cover == nil, els.apexCoverJettisoned != nil { d.cover = reading() }
            if d.drogues == nil, els.droguesDeployed != nil { d.drogues = reading() }
            if d.mains == nil, els.mainsDeployed != nil { d.mains = reading() }
            for c in chutes where c.isDeployed {
                if c.name == "Drogue parachutes" { d.drogueStates.append((t, c.state)) }
                if c.name == "Main parachutes" { d.mainStates.append((t, c.state)) }
            }
            if let m = els.mainsDeployed, sim.time - m > 30, v.status == .flying {
                let vertical = v.reference.vertical(at: v.position, orientation: sim.snapshot.orientation(v.reference))
                d.hang.append((t, acos(min(1, v.attitude.rotate(.unitX).dot(vertical)))))
            }
        }
        // The ELS releases the mains on the step after splashdown.
        sim.advance(by: 0.1)
        d.splash = sim.events.last {
            $0.message.hasPrefix("\(v.name): ") && ($0.message.contains("splashdown") || $0.message.contains("impact"))
        }.map { ($0.time, $0.message) }
        return d
    }

    /// The speed in a "... at x m/s" log line.
    func speed(in message: String) -> Double? {
        let words = message.split(separator: " ")
        guard let i = words.firstIndex(of: "at"), i + 1 < words.count else { return nil }
        return Double(words[i + 1])
    }

    // Apollo 7's descent, step by step: the 24,000 ft baroswitch at 39.3 kPa
    // starts the sequence; the apex cover goes 0.4 s later and the drogues
    // 1.6 s after it (TN D-7437 Fig. 2), reefed for 10 s; at 69.7 kPa
    // (10,000 ft) the drogues go and the mains come out, reefed for 6 s and
    // then 4 s; after splashdown the mains are released. 53 ± 5 s on the
    // drogues and 285 ± 20 s on the mains (68-FM-184 §5.4.4; Apollo 7 flew
    // 50 s and 290 s, Mission Report Table 2-I); the log reads "splashdown
    // at x m/s" and the CM floats.
    func testApollo7DescentByPressure() throws {
        let d = try descend()
        let upper = try XCTUnwrap(d.upper), cover = try XCTUnwrap(d.cover)
        let drogues = try XCTUnwrap(d.drogues), mains = try XCTUnwrap(d.mains)
        // Each baroswitch acts on the step after the pressure crosses it: the
        // reading at the end of that 0.1 s is at most 0.1 s of descent beyond.
        XCTAssertGreaterThanOrEqual(upper.pressure, 39_300)
        XCTAssertLessThan(upper.pressure, 39_300 + 100)
        XCTAssertEqual(upper.altitude, 24_000 * ft, accuracy: 20)
        XCTAssertGreaterThanOrEqual(mains.pressure, 69_700)
        XCTAssertLessThan(mains.pressure, 69_700 + 100)
        XCTAssertEqual(mains.altitude, 10_000 * ft, accuracy: 20)
        let els = try XCTUnwrap(d.vessel.flightProgram as? EarthLandingSystem)
        let start = try XCTUnwrap(els.upperBaroswitchClosed)
        XCTAssertEqual(try XCTUnwrap(els.apexCoverJettisoned) - start, 0.4, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(els.droguesDeployed) - start, 2.0, accuracy: 1e-4)
        XCTAssertLessThan(cover.time - upper.time, 0.5 + 1e-6)
        XCTAssertLessThan(drogues.time - cover.time, 1.7 + 1e-6)

        let onDrogues = try XCTUnwrap(els.mainsDeployed) - XCTUnwrap(els.droguesDeployed)
        let splash = try XCTUnwrap(d.splash)
        let onMains = try splash.time - XCTUnwrap(els.mainsDeployed)
        XCTAssertEqual(onDrogues, 53, accuracy: 5)
        XCTAssertEqual(onMains, 285, accuracy: 20)

        // Reefing: the drogues reefed to 10 s, the mains in two stages to 6
        // and 10 s (within the 0.1 s sampling).
        for (t, state) in d.drogueStates {
            let s = t - (try XCTUnwrap(els.droguesDeployed) - d.start)
            if s > 1.05 && s < 9.95 { XCTAssertEqual(state, .reefed(1)) }
            if s > 10.05 && s < 30 { XCTAssertEqual(state, .open) }
        }
        for (t, state) in d.mainStates {
            let s = t - (try XCTUnwrap(els.mainsDeployed) - d.start)
            if s > 2.05 && s < 5.95 { XCTAssertEqual(state, .reefed(1)) }
            if s > 6.05 && s < 9.95 { XCTAssertEqual(state, .reefed(2)) }
            if s > 10.05 && s < 200 { XCTAssertEqual(state, .open) }
        }

        // Splashdown on water, logged, afloat in Stable I, the mains cut away.
        XCTAssertTrue(splash.message.hasPrefix("Apollo 7: splashdown at "), splash.message)
        let v = d.vessel
        XCTAssertEqual(v.status, .landed)
        XCTAssertEqual(v.landed?.surface, .water)
        XCTAssertEqual(v.parts.map(\.name), ["CM"])
        XCTAssertEqual(els.status, "ELS mains released")
        XCTAssertTrue(v.thrusters.allSatisfy { !$0.isEnabled })
        let names = Set(d.sim.vessels.map(\.name))
        XCTAssertEqual(names, ["Apollo 7", "Apollo 7 – Apex cover", "Apollo 7 – Drogue parachutes",
                               "Apollo 7 – Main parachutes"])
    }

    // TN D-7437 Fig. 2's splashdowns for the 13,000 lb recovery weight: 32
    // ft/s on three mains, to which the cluster's interference is calibrated,
    // and 36 ft/s on two, which the model predicts with each of the two
    // canopies delivering its full area. Under the mains the CM hangs at
    // 27.5° (the riser attachment's offset), and its swing settles there
    // (the drag at the attach point, with ω x r, damps it).
    func testSplashdownRatesOnTheMains() throws {
        for (mains, rate, tolerance) in [(3, 32.0, 0.5), (2, 36.0, 1.0)] {
            let d = try descend(weightUnderDrogues: 13_000 + 74.8, mains: mains)
            let splash = try XCTUnwrap(d.splash)
            XCTAssertTrue(splash.message.contains("splashdown"), splash.message)
            let v = try XCTUnwrap(speed(in: splash.message))
            XCTAssertEqual(v / ft, rate, accuracy: tolerance, "\(mains) mains")
            XCTAssertLessThan(v, ApolloCM.impactLimits.water)
            // The hang angle over the last 100 s before splashdown.
            let late = d.hang.filter { $0.time > d.hang.last!.time - 100 }.map(\.angle)
            let mean = late.reduce(0, +) / Double(late.count)
            XCTAssertEqual(mean, ApolloCM.mainHangAngle, accuracy: 1.5 * Double.pi / 180, "\(mains) mains")
            XCTAssertLessThan(late.map { abs($0 - mean) }.max()!, 1 * Double.pi / 180, "\(mains) mains")
        }
    }

    // On the drogues alone the CM hits the water far above its limit: the
    // mains are what make a splashdown survivable.
    func testDrogueOnlyImpactCrashes() throws {
        let d = try descend(lowerBaroswitch: 200_000)
        let splash = try XCTUnwrap(d.splash)
        XCTAssertTrue(splash.message.hasPrefix("Apollo 7: water impact at "), splash.message)
        XCTAssertGreaterThan(try XCTUnwrap(speed(in: splash.message)), 40)
        XCTAssertEqual(d.vessel.status, .crashed)
    }

    // The ELS's API, as the CM's entry program drives it: nothing happens
    // until it is armed, nor on the ground at sea-level pressure; the crew's
    // backup (`advance`) steps through the sequence; the pilot's Space key
    // is refused while the sequence owns the staging; `nextEvent` and
    // `status` say what comes next.
    func testELSStepsAndGuards() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.commandModule(.apollo7)
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: 29.8, longitude: -67)
        let els = EarthLandingSystem()
        v.flightProgram = els
        XCTAssertEqual(els.status, "ELS safe")
        sim.advance(by: 1)
        els.arm()
        XCTAssertEqual(els.status, "ELS armed")
        sim.advance(by: 1)
        XCTAssertNil(els.upperBaroswitchClosed)
        XCTAssertTrue(els.allowsManualStaging(of: v) == false)
        XCTAssertNil(sim.stage(v))
        XCTAssertEqual(sim.events.last?.message, "Apollo 7: staging inhibited by the flight program")

        let t0 = sim.time
        XCTAssertTrue(els.advance(v, in: sim))
        XCTAssertEqual(els.status, "ELS apex cover off")
        XCTAssertFalse(v.parts.contains { $0.name == "Apex cover" })
        let next = try XCTUnwrap(els.nextEvent(at: sim.time))
        XCTAssertEqual(next.name, "Drogues")
        XCTAssertEqual(next.at - t0, 1.6, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(els.timeToNextEvent(at: sim.time)), 1.6, accuracy: 1e-4)
        XCTAssertTrue(els.advance(v, in: sim))
        XCTAssertEqual(els.status, "ELS drogues deploying")
        XCTAssertEqual(try XCTUnwrap(els.nextEvent(at: sim.time)).name, "Drogue parachutes disreef")
        XCTAssertTrue(els.advance(v, in: sim))
        XCTAssertEqual(els.status, "ELS mains deploying")
        XCTAssertFalse(v.parts.contains { $0.name == "Drogue parachutes" })
        XCTAssertTrue(v.thrusters.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(els.advance(v, in: sim))
        XCTAssertEqual(els.status, "ELS mains released")
        XCTAssertEqual(v.parts.map(\.name), ["CM"])
        XCTAssertFalse(els.advance(v, in: sim))
        XCTAssertTrue(els.allowsManualStaging(of: v))
    }

    // The reefing schedule: per canopy 285 ft^2 to 6 s, 1,080 ft^2 to 10 s,
    // then 4,200 ft^2 (TN D-7437 Fig. A-15), each change ramped over 2 s,
    // the three-canopy cluster at its calibrated efficiency; the drogues at
    // 65 ft^2 to 10 s, then 114 ft^2 (Fig. A-16).
    func testReefingSchedule() {
        let ft2 = ft * ft
        let mains = ApolloCM.mainParachutes()
        let t0 = Epoch(tdbSecondsPastJ2000: 0)
        XCTAssertEqual(mains.effectiveDragArea(at: t0 + 1), 0)
        mains.deploy(at: t0)
        let k = 3 * ApolloCM.mainClusterEfficiency
        for (s, area) in [(0.0, 0.0), (1, 142.5), (2, 285), (5.9, 285), (7, (285 + 1_080) / 2.0), (8, 1_080),
                          (9.9, 1_080), (11, (1_080 + 4_200) / 2.0), (12, 4_200), (300, 4_200)] {
            XCTAssertEqual(mains.effectiveDragArea(at: t0 + s), k * area * ft2, accuracy: 1e-9, "\(s) s")
        }
        for (s, state) in [(1.0, Parachute.State.deploying), (3, .reefed(1)), (7, .reefed(2)), (10.5, .open)] {
            mains.update(at: t0 + s)
            XCTAssertEqual(mains.state, state, "\(s) s")
        }
        XCTAssertEqual(mains.scheduleCorners(after: t0 + 5).map { $0 - t0 }, [6, 8, 10, 12])
        mains.count = 2
        XCTAssertEqual(mains.effectiveDragArea(at: t0 + 20), 2 * 4_200 * ft2, accuracy: 1e-9)
        mains.release()
        XCTAssertEqual(mains.state, .released)
        XCTAssertEqual(mains.effectiveDragArea(at: t0 + 20), 0)

        let drogues = ApolloCM.drogueParachutes()
        drogues.deploy(at: t0)
        XCTAssertEqual(drogues.effectiveDragArea(at: t0 + 5), 2 * 65 * ft2, accuracy: 1e-9)
        XCTAssertEqual(drogues.effectiveDragArea(at: t0 + 15), 2 * 114 * ft2, accuracy: 1e-9)
    }

    // The load acts at the attach point with the air velocity there: drag
    // -½ ρ C_D S |u| u, its torque r x F, and a vessel turning under its
    // canopy feels a torque against its rotation (ω x r).
    func testLoadsAtTheAttachPoint() {
        let r = Vec3(2, 0.5, 0), air = Vec3(-10, 0, 0)
        let still = Parachute.loads(area: 100, at: r, air: air, omega: .zero, density: 1.2)
        XCTAssertEqual(still.force.x, 0.5 * 1.2 * 100 * 100, accuracy: 1e-9)
        XCTAssertEqual(still.force.y, 0, accuracy: 1e-12)
        XCTAssertEqual((still.torque - r.cross(still.force)).length, 0, accuracy: 1e-9)
        let turning = Parachute.loads(area: 100, at: Vec3(2, 0, 0), air: air, omega: Vec3(0, 0, 0.1), density: 1.2)
        XCTAssertLessThan(turning.torque.z, 0)
        XCTAssertEqual(turning.torque.x, 0, accuracy: 1e-9)
    }
}

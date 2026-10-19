import XCTest
@testable import OrbitCore

/// Apollo 7's deorbit, SPS-8, to entry interface, against its Mission
/// Report (MSC-PA-R-68-15): Table 3-III's ignition and cutoff states, Table
/// 2-I's event times, §5.16's entry state and Table A.5-I's mass. The
/// ignition state is put in place on the WGS-84 Earth (Table 3-III's
/// altitudes are over MSC's Fischer 1960 ellipsoid, about 30 m higher at
/// these latitudes); the burn's direction is the one the two states imply
/// (`ApolloCSM.apollo7SPS8DeltaV`), so the cutoff checks the burn's size
/// and where it puts the CSM, and entry interface the coast from there.
final class Apollo7DeorbitTests: XCTestCase {
    let ft = 0.3048, lb = 0.45359237, deg = Double.pi / 180

    struct Flight {
        let sim: Simulation
        let v: Vessel
        let scs: ApolloSCS
        /// GET of the simulation now, s.
        var get: Double { sim.time - ApolloCSM.apollo7RangeZero }
        /// Steps of 0.02 s at most, ending on the program's events, to GET `t`.
        func fly(to t: Double, each: () -> Void = {}) {
            while get < t - 1e-6 {
                for w in sim.vessels { sim.prepareControls(w) }
                sim.step(min(0.02, sim.maxStep(), t - get))
                each()
            }
        }
        /// Speed, geocentric flight-path angle and geodetic altitude now.
        func state() -> (speed: Double, gamma: Double, altitude: Double) {
            let r = v.position.normalized
            return (v.velocity.length, asin(v.velocity.normalized.dot(r)), v.altitude)
        }
    }

    /// CSM-101 at SPS-8 ignition, GET 259:39:16.3: Table 3-III's state,
    /// Table A.5-I row 17's 24,262 lb, in the burn's attitude, held, heads
    /// down; its counter loaded as the scenario loads it.
    func ignition() throws -> Flight {
        let sim = try Simulation.forTests(perturbations: true)
        let s = ApolloCSM.apollo7SPS8Ignition
        sim.setTime(ApolloCSM.apollo7RangeZero + s.groundElapsedTime)
        let v = VesselLibrary.apolloCSM(.apollo7)
        let loads = ApolloCSM.apollo7Loads(row: 17)
        ApolloCSM.setLoads(v, spsOxidizer: loads.spsOxidizer, spsFuel: loads.spsFuel, rcs: loads.rcs)
        sim.add(v)
        sim.place(v, geodeticLatitude: s.latitude, longitude: s.longitude, height: s.altitude * ft,
                  inertialSpeed: s.speed * ft, flightPathAngle: s.flightPathAngle, azimuth: s.heading)
        v.attitude = ApolloCSM.burnAttitude(v, along: ApolloCSM.apollo7SPS8DeltaV(system: sim.system))
        v.autopilot = .attitudeHold
        v.attitudeCommand = AttitudeCommand(attitude: v.attitude)
        let scs = try XCTUnwrap(v.flightProgram as? ApolloSCS)
        return Flight(sim: sim, v: v, scs: scs)
    }

    // The burn, 11.9 s from Z at 259:39:16.3 to X at 259:39:28.2 (Table
    // 2-I): at the cutoff signal, Table 3-III's 24,966.5 ft/s, -1.643° and
    // 1,137,041 ft. The model comes within 3.2 ft/s (its burn about 1 m/s,
    // 1 %, short of the flight's by then, on 68-FM-184's preflight rating),
    // 0.009° and 60 ft. With its tail-off it uses 821 lb, against the 809 lb
    // the weight dropped from row 17 to row 18 (with the SM RCS's to the
    // separation).
    func testSPS8Cutoff() throws {
        let f = try ignition()
        XCTAssertEqual(f.v.mass / lb, 24_262, accuracy: 1e-6)
        let dv = ApolloCSM.apollo7SPS8DeltaV(system: f.sim.system)
        let m0 = f.v.mass
        f.v.mainThrottle = 1
        f.fly(to: ApolloCSM.apollo7SPS8Cutoff.groundElapsedTime)
        f.v.mainThrottle = 0
        let s = f.state()
        let c = ApolloCSM.apollo7SPS8Cutoff
        print(String(format: "SPS-8 cutoff: %.1f ft/s (%.1f), %.3f° (%.3f), %.0f ft (%.0f); fitted Δv %.2f m/s",
                     s.speed / ft, c.speed, s.gamma / deg, c.flightPathAngle, s.altitude / ft, c.altitude, dv.length))
        f.fly(to: c.groundElapsedTime + 3)
        let used = (m0 - f.v.mass) / lb
        print(String(format: "SPS-8 used %.1f lb", used))
        XCTAssertEqual(s.speed / ft, c.speed, accuracy: 4)
        XCTAssertEqual(s.gamma / deg, c.flightPathAngle, accuracy: 0.03)
        XCTAssertEqual(s.altitude / ft, c.altitude, accuracy: 2_000)
        XCTAssertEqual(used, 809, accuracy: 20)
    }

    // On to entry interface, the EMS counter cutting the SPS off (loaded as
    // the scenario loads it, within 0.05 s of the flight's 11.9 s): CM/SM
    // separation at 259:43:33.8 (Table 2-I), then the CM to 400,000 ft,
    // Table 2-I's 259:53:27 at the onboard computer's 25,846.4 ft/s and
    // -2.072° (§5.16). The model comes 4.4 s early, 3.4 ft/s slow and
    // 0.003° steep (it puts 1 m/s of Δv about 4 s of entry time).
    func testEntryInterface() throws {
        let f = try ignition()
        f.scs.loadDeltaV(ApolloCSM.apollo7SPS8CounterLoad)
        f.v.mainThrottle = 1
        var counterCutoff: Double?
        f.fly(to: ApolloCSM.apollo7SPS8Cutoff.groundElapsedTime + 2) {
            if counterCutoff == nil && f.v.mainThrottle == 0 { counterCutoff = f.get }
        }
        f.v.mainThrottle = 0
        f.fly(to: ApolloCSM.apollo7CMSMSeparation)
        let sm = try XCTUnwrap(f.sim.stage(f.v, event: 7))
        XCTAssertEqual(sm.name, "Apollo 7 – SM")
        var ei: (get: Double, speed: Double, gamma: Double)?
        var previous = (get: f.get, altitude: f.v.altitude, speed: f.v.velocity.length, gamma: f.state().gamma)
        let interface = ApolloCSM.apollo7EntryInterface.altitude * ft
        while ei == nil && f.get < ApolloCSM.apollo7EntryInterface.groundElapsedTime + 120 {
            f.fly(to: f.get + 0.5)
            let s = f.state()
            if f.v.altitude <= interface {
                let u = (previous.altitude - interface) / (previous.altitude - f.v.altitude)
                ei = (previous.get + u * (f.get - previous.get), previous.speed + u * (s.speed - previous.speed),
                      previous.gamma + u * (s.gamma - previous.gamma))
            }
            previous = (f.get, f.v.altitude, s.speed, s.gamma)
        }
        let e = try XCTUnwrap(ei)
        let ref = ApolloCSM.apollo7EntryInterface
        print(String(format: "Apollo 7 EI: GET %.1f s (%.1f), %.1f ft/s (%.1f), %.3f° (%.3f); counter cutoff at %.2f s",
                     e.get, ref.groundElapsedTime, e.speed / ft, ref.speed, e.gamma / deg, ref.flightPathAngle,
                     (counterCutoff ?? .nan) - ApolloCSM.apollo7SPS8Ignition.groundElapsedTime))
        XCTAssertEqual(try XCTUnwrap(counterCutoff) - ApolloCSM.apollo7SPS8Ignition.groundElapsedTime, 11.9, accuracy: 0.05)
        XCTAssertEqual(e.get, ref.groundElapsedTime, accuracy: 5)
        XCTAssertEqual(e.speed / ft, ref.speed, accuracy: 10)
        XCTAssertEqual(e.gamma / deg, ref.flightPathAngle, accuracy: 0.05)
    }

    // The scenario (`apollo7BeforeDeorbit`): at 259:38:00 it holds the
    // burn's attitude and coasts, and with U from 259:39:01.3 for 15 s
    // reaches Table 3-III's ignition state at 259:39:16.3 with row 17's
    // weight (the ullage's 21.7 lb burned, and 2 lb the hold's pulses
    // took). Its counter is loaded.
    func testScenarioCoastsToTheIgnitionState() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo7BeforeDeorbit(in: sim)
        XCTAssertEqual(sim.time - ApolloCSM.apollo7RangeZero, 259 * 3_600 + 38 * 60, accuracy: 1e-6)
        XCTAssertEqual(v.mass / lb, 24_262 + 399.2 / 276.0 * 15, accuracy: 1e-6)
        XCTAssertTrue(v.flightProgram is ApolloSCS)
        XCTAssertEqual((v.flightProgram as? ApolloSCS)?.deltaVRemaining, ApolloCSM.apollo7SPS8CounterLoad)
        let s = ApolloCSM.apollo7SPS8Ignition
        let f = Flight(sim: sim, v: v, scs: v.flightProgram as! ApolloSCS)
        f.fly(to: s.groundElapsedTime - 15)
        v.setPilotInput(rotation: RotationCommand(), translation: Vec3(1, 0, 0))
        f.fly(to: s.groundElapsedTime)
        v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        XCTAssertEqual(v.mass / lb, 24_262, accuracy: 3)   // and the hold's pulses
        let ign = ApolloCSM.inertialState(s, system: sim.system)
        print(String(format: "scenario at ignition: %.1f m, %.3f m/s from Table 3-III's state",
                     (v.position - ign.position).length, (v.velocity - ign.velocity).length))
        XCTAssertLessThan((v.position - ign.position).length, 50)
        XCTAssertLessThan((v.velocity - ign.velocity).length, 0.5)
    }
}

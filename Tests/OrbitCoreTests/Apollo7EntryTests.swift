import XCTest
@testable import OrbitCore

/// Apollo 7's entry to splashdown, against MSC Internal Note 68-FM-184 (the
/// operational trajectory) and the Mission Report (MSC-PA-R-68-15). The CM
/// is E2's (Mission Report row, CM RCS, ELS) on MSC's trim tables as
/// published (the operational calibration), flown by its entry program at
/// the 55° backup bank that 68-FM-184 §5.4.4 puts the target on.
final class Apollo7EntryTests: XCTestCase {
    static let deg = Double.pi / 180
    /// The planned landing point, 68-FM-184 Table IX(b) and §5.4.3: 29.8° N,
    /// 67.0° W (H).
    static let planned = (latitude: 29.8 * deg, longitude: -67.0 * deg)
    /// Where Apollo 7 came down, reconstructed from the accelerometers
    /// corrected for platform errors (Mission Report §5.16, H): 27.64° N,
    /// 64.15° W, 1.9 n mi beyond the target the computer flew to.
    static let flown = (latitude: 27.64 * deg, longitude: -64.15 * deg)

    struct Flight {
        var landing: (latitude: Double, longitude: Double)
        var miss: Double                     // n mi from the target
        var duration: Double                 // s, entry interface to splashdown
        var drogues: Double, mains: Double   // s under each
        var peakLoadFactor: Double
        var peakHeatFlux: Double, heatLoad: Double   // BTU/ft^2 s, BTU/ft^2
        var rcsPropellant: Double            // lb, from the program's waking
        var reversals: Int
        var log: [String]
    }

    /// Fly `v`, its entry program `program` holding ±55°, to splashdown; the
    /// crew rolls the lift across the ground track whenever the CM is more
    /// than 10 n mi off it (the great circle from where it sensed 0.05 g to
    /// `target`): a constant bank to one side would carry it about 95 n mi
    /// across. `interface` is when it passed 400,000 ft, if known.
    static func entry(_ sim: Simulation, _ v: Vessel, _ program: CMEntryProgram,
                      target: (latitude: Double, longitude: Double), interface: Epoch? = nil) -> Flight {
        var bank = -55 * deg   // Apollo 7's backup bank was a left roll (Mission Report §5.16)
        program.mode = .bankHold(bank)
        let figure = sim.system.earth.figure
        let aim = figure.bodyFixed(latitude: target.latitude, longitude: target.longitude, height: 0).normalized
        var ei = interface, normal: Vec3?, peakFlux = 0.0, reversals = 0
        let propellant = v.tanks.filter { $0.name.hasPrefix("CM RCS") }.reduce(0) { $0 + $1.mass }
        let start = sim.time
        while v.landed == nil && v.status != .crashed && sim.time - start < 3_000 {
            for x in sim.vessels { sim.prepareControls(x) }
            sim.step(min(1, sim.maxStep()))
            if ei == nil && v.altitude <= 121_920 { ei = sim.time }
            peakFlux = max(peakFlux, v.heatFlux)
            let here = sim.snapshot.orientation(v.reference).toBody(v.position).normalized
            guard program.phase == .entry else { continue }
            if normal == nil { normal = here.cross(aim).normalized }
            let across = asin(here.dot(normal!)) * 6_371_000 / 1_852
            if bank > 0 && across < -10 || bank < 0 && across > 10 {
                bank = -bank
                reversals += 1
                program.mode = .bankHold(bank)
            }
        }
        let ll = v.latitudeLongitude(snapshot: sim.snapshot)
        let miss = acos(min(1, sin(ll.lat) * sin(target.latitude)
                            + cos(ll.lat) * cos(target.latitude) * cos(ll.lon - target.longitude))) * 6_371_000 / 1_852
        let els = program.els, btu = 11_356.53   // W/m^2 per BTU/ft^2 s, and J/m^2 per BTU/ft^2
        let t0 = ei ?? start
        return Flight(landing: (ll.lat, ll.lon), miss: miss, duration: sim.time - t0,
                      drogues: (els.mainsDeployed ?? t0) - (els.droguesDeployed ?? t0),
                      mains: (v.landed != nil ? sim.time : t0) - (els.mainsDeployed ?? t0),
                      peakLoadFactor: program.peakLoadFactor, peakHeatFlux: peakFlux / btu, heatLoad: v.heatLoad / btu,
                      rcsPropellant: (propellant - v.tanks.filter { $0.name.hasPrefix("CM RCS") }.reduce(0) { $0 + $1.mass })
                          / 0.45359237,
                      reversals: reversals, log: sim.events.map(\.message))
    }

    func report(_ label: String, _ f: Flight, from target: String) {
        print(String(format: "Apollo 7 %@: landed %.3f, %.3f (%.1f n mi from %@) %.0f s after EI; "
                     + "%.1f s on the drogues, %.1f s on the mains; peak %.2f g; heating %.1f BTU/ft^2 s, %.0f BTU/ft^2; "
                     + "CM RCS %.1f lb; %d reversals", label, f.landing.latitude / Self.deg, f.landing.longitude / Self.deg,
                     f.miss, target, f.duration, f.drogues, f.mains, f.peakLoadFactor, f.peakHeatFlux, f.heatLoad,
                     f.rcsPropellant, f.reversals))
    }

    /// The checks both flights share: the ELS's steps and a splashdown on
    /// water under the CM's limit; 53 s on the drogues and 4 min 45 s on
    /// the mains (68-FM-184 §5.4.4; E2's bands, ±5 and ±20 s); the CM RCS
    /// within a factor of two of Apollo 7's 49.1 lb (Mission Report §5.21).
    func checkDescent(_ f: Flight) {
        XCTAssertEqual(f.drogues, 53, accuracy: 5)
        XCTAssertEqual(f.mains, 285, accuracy: 20)
        XCTAssertGreaterThan(f.rcsPropellant, 49.1 / 2)
        XCTAssertLessThan(f.rcsPropellant, 49.1 * 2)
        XCTAssertGreaterThan(f.reversals, 0)
        XCTAssertTrue(f.log.contains { $0.contains("splashdown at") }, "\(f.log.suffix(5))")
        for step in ["entry program active", "0.05 g", "ELS sequence started", "drogues deployed", "mains deployed"] {
            XCTAssertTrue(f.log.contains { $0.contains(step) }, step)
        }
    }

    /// From 68-FM-184 Table IX(b)'s entry interface (31.03° N, 98.83° W,
    /// 400,000 ft, 25,850.3 ft/s at -1.759° and 83.64°): a 3.3 g peak
    /// (±0.3 g); landing 963 s after entry interface (10:20:09:53 GET
    /// against the 10:19:40:04 cutoff and the 826 s coast; ±40 s); 59.8
    /// BTU/ft^2 s and 12,649 BTU/ft^2 of heating (±10 %, on the radius
    /// fitted to them); and the descent's checks.
    ///
    /// It lands 70-75 n mi beyond the planned point. The range moves about
    /// 700 n mi per degree of entry flight-path angle (a -1.85° entry lands 7
    /// n mi from it), so that is 0.09° of γ, the size of the conventions
    /// between 68-FM-184's trajectory program and this one, and 4° of bank
    /// dead band moves it about 10 n mi (datasheet §4.4). The band is 90 n mi.
    func testFromThePlannedEntryInterface() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.commandModule(.apollo7)
        v.aerodynamics = [.apolloCommandModule(calibration: .operational)]
        sim.add(v)
        let ei = EntryTests.apollo7EntryInterface
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height, inertialSpeed: ei.speed,
                  flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
        let program = CMEntryProgram(mode: .bankHold(-55 * Self.deg))
        v.flightProgram = program
        v.attitude = CMEntryProgram.trimAttitude(of: v, capsule: v.activeAerodynamics!.capsule!, bank: -55 * Self.deg,
                                                 in: sim)!
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        let f = Self.entry(sim, v, program, target: Self.planned, interface: sim.time)
        report("from 68-FM-184's EI", f, from: "29.8 N 67.0 W")
        XCTAssertEqual(f.peakLoadFactor, 3.3, accuracy: 0.3)
        XCTAssertLessThan(f.miss, 90)
        XCTAssertEqual(f.duration, 963, accuracy: 40)
        XCTAssertEqual(f.peakHeatFlux, 59.8, accuracy: 6)
        XCTAssertEqual(f.heatLoad, 12_649, accuracy: 1_265)
        checkDescent(f)
    }

    /// The mission as flown, from the deorbit burn: track C's CSM before
    /// SPS-8 (`apollo7BeforeDeorbit`), the crew's steps of Table 2-I (U for
    /// 15 s from 259:39:01.3, Z at 259:39:16.3, the EMS counter's cutoff,
    /// CM/SM separation at 259:43:33.8), then the CM's entry program, woken
    /// by the separation through the SCS (`ApolloMission`), at the 55°
    /// backup bank with reversals.
    ///
    /// Against the flight: entry interface 259:53:27 (Table 2-I; within 6 s);
    /// a 3.3 ± 0.3 g peak (68-FM-184's, and the flight's computer-flown entry
    /// peaked near it); splashdown 936 s after entry interface (260:09:03,
    /// ±40 s); the descent's checks. The flight's computer flew lift up to
    /// 0.2 g and then its own guidance to 27.64° N 64.15° W; at 55° this
    /// flight lands within 60 n mi of that. (The preflight 29.8° N 67.0° W
    /// is about 250 n mi away: the flight entered steeper than planned, and
    /// its target had moved.)
    func testFromTheDeorbitBurn() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo7BeforeDeorbit(in: sim)
        let scs = try XCTUnwrap(v.flightProgram as? ApolloSCS)
        let program = try XCTUnwrap(ApolloMission.entryProgram(of: v))
        XCTAssertTrue(scs.successor === program)
        let zero = ApolloCSM.apollo7RangeZero, ignition = ApolloCSM.apollo7SPS8Ignition.groundElapsedTime
        func fly(to get: Double) {
            while sim.time - zero < get - 1e-6 {
                for w in sim.vessels { sim.prepareControls(w) }
                sim.step(min(0.02, sim.maxStep(), get - (sim.time - zero)))
            }
        }
        fly(to: ignition - 15)
        v.setPilotInput(rotation: RotationCommand(), translation: Vec3(1, 0, 0))
        fly(to: ignition)
        v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        v.mainThrottle = 1
        fly(to: ignition + 15)
        XCTAssertEqual(v.mainThrottle, 0, "the counter cut the SPS off")
        fly(to: ApolloCSM.apollo7CMSMSeparation)
        XCTAssertEqual(program.phase, .dormant)
        XCTAssertNotNil(sim.stage(v, event: 7))
        sim.tick()
        XCTAssertEqual(program.phase, .preEntry)
        XCTAssertTrue(v.flightProgram as? ApolloSCS === scs)
        XCTAssertTrue(scs.status.hasPrefix("ENTRY hold"), scs.status)

        var interface: Epoch?
        while interface == nil {
            for w in sim.vessels { sim.prepareControls(w) }
            sim.step(min(1, sim.maxStep()))
            if v.altitude <= 121_920 { interface = sim.time }
        }
        let f = Self.entry(sim, v, program, target: Self.flown, interface: interface)
        report("from the deorbit burn", f, from: "27.64 N 64.15 W")
        let planned = acos(sin(f.landing.latitude) * sin(Self.planned.latitude) + cos(f.landing.latitude)
                           * cos(Self.planned.latitude) * cos(f.landing.longitude - Self.planned.longitude)) * 6_371_000 / 1_852
        print(String(format: "  entry interface at GET %.1f s (259:53:27 = 935607); %.1f n mi from 29.8 N 67.0 W",
                     interface! - zero, planned))
        XCTAssertEqual(interface! - zero, ApolloCSM.apollo7EntryInterface.groundElapsedTime, accuracy: 6)
        XCTAssertEqual(f.peakLoadFactor, 3.3, accuracy: 0.3)
        XCTAssertEqual(f.duration, 936, accuracy: 40)
        XCTAssertLessThan(f.miss, 60)
        checkDescent(f)
    }
}

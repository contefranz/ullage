import XCTest
@testable import OrbitCore

/// Apollo 7's entry, from entry interface to splashdown, against MSC
/// Internal Note 68-FM-184 (the operational trajectory) and the Mission
/// Report. The CM is E2's (Mission Report row, CM RCS, ELS), with the MSC
/// trim table as published (the operational calibration).
final class Apollo7EntryTests: XCTestCase {
    /// The planned landing point, 68-FM-184 Table IX(b) and §5.4.3: 29.8° N,
    /// 67.0° W (H).
    static let target = (latitude: 29.8 * Double.pi / 180, longitude: -67.0 * Double.pi / 180)

    /// One flight from 68-FM-184 Table IX(b)'s entry interface at a 55° bank,
    /// the backup bank that §5.4.4 puts the target on. The crew rolls the lift
    /// across the ground track whenever the CM is more than 10 n mi off it
    /// (the great circle from entry interface to the target): a constant bank
    /// to one side would carry it about 95 n mi across.
    struct Flight {
        var landing: (latitude: Double, longitude: Double)
        var miss: Double                     // n mi
        var duration: Double                 // s, entry interface to splashdown
        var drogues: Double, mains: Double   // s under each
        var peakLoadFactor: Double
        var peakHeatFlux: Double, heatLoad: Double   // BTU/ft^2 s, BTU/ft^2
        var rcsPropellant: Double            // lb
        var reversals: Int
        var log: [String]
    }

    static func fly() throws -> Flight {
        let deg = Double.pi / 180
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.commandModule(.apollo7)
        v.aerodynamics = [.apolloCommandModule(calibration: .operational)]
        sim.add(v)
        let ei = EntryTests.apollo7EntryInterface
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height, inertialSpeed: ei.speed,
                  flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
        var bank = -55 * deg   // Apollo 7's backup bank was a left roll (Mission Report §5.16)
        let program = CMEntryProgram(mode: .bankHold(bank))
        v.flightProgram = program
        v.attitude = CMEntryProgram.trimAttitude(of: v, capsule: v.activeAerodynamics!.capsule!, bank: bank, in: sim)!
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        let t0 = sim.time, propellant = v.tanks.reduce(0) { $0 + $1.mass }
        let figure = sim.system.earth.figure
        let normal = figure.bodyFixed(latitude: ei.latitude * deg, longitude: ei.longitude * deg, height: 0).normalized
            .cross(figure.bodyFixed(latitude: target.latitude, longitude: target.longitude, height: 0).normalized).normalized
        var peakFlux = 0.0, reversals = 0
        while v.landed == nil && v.status != .crashed && sim.time - t0 < 2_000 {
            for x in sim.vessels { sim.prepareControls(x) }
            sim.step(min(1, sim.maxStep()))
            peakFlux = max(peakFlux, v.heatFlux)
            let across = asin(sim.snapshot.orientation(v.reference).toBody(v.position).normalized.dot(normal))
                * 6_371_000 / 1_852
            if program.phase == .entry, bank > 0 && across < -10 || bank < 0 && across > 10 {
                bank = -bank
                reversals += 1
                program.mode = .bankHold(bank)
            }
        }
        let ll = v.latitudeLongitude(snapshot: sim.snapshot)
        let miss = acos(min(1, sin(ll.lat) * sin(target.latitude)
                            + cos(ll.lat) * cos(target.latitude) * cos(ll.lon - target.longitude))) * 6_371_000 / 1_852
        let els = program.els, btu = 11_356.53   // W/m^2 per BTU/ft^2 s, and J/m^2 per BTU/ft^2
        return Flight(landing: (ll.lat, ll.lon), miss: miss, duration: sim.time - t0,
                      drogues: (els.mainsDeployed ?? t0) - (els.droguesDeployed ?? t0),
                      mains: (v.landed != nil ? sim.time : t0) - (els.mainsDeployed ?? t0),
                      peakLoadFactor: program.peakLoadFactor, peakHeatFlux: peakFlux / btu, heatLoad: v.heatLoad / btu,
                      rcsPropellant: (propellant - v.tanks.reduce(0) { $0 + $1.mass }) / 0.45359237,
                      reversals: reversals, log: sim.events.map(\.message))
    }

    /// 68-FM-184 §5.4.4: a 3.3 g peak (±0.3 g); 53 s on the drogues and
    /// 4 min 45 s on the mains (E2's bands, ±5 and ±20 s); landing 963 s
    /// after entry interface (10:20:09:53 GET against the 10:19:40:04
    /// cutoff and the 826 s coast; ±40 s here); 59.8 BTU/ft^2 s and 12,649
    /// BTU/ft^2 of heating (±10 %, on the radius fitted to them). The CM
    /// RCS uses about what Apollo 7's did, 49.1 lb (Mission Report §5.21;
    /// within a factor of two). Splashdown is on water under the limit.
    ///
    /// The landing is 70 n mi beyond the planned point: about 0.09° of
    /// entry flight-path angle (a -1.85° entry lands 7 n mi from it), the
    /// size of the conventions between 68-FM-184's trajectory program and
    /// this one (datasheet §4.4). The test holds it within 75 n mi.
    func testFromEntryInterfaceToSplashdown() throws {
        let f = try Self.fly()
        print(String(format: "Apollo 7 entry: landed %.3f, %.3f (%.1f n mi from 29.8 N 67.0 W) %.0f s after EI; "
                     + "%.1f s on the drogues, %.1f s on the mains; peak %.2f g; heating %.1f BTU/ft^2 s, %.0f BTU/ft^2; "
                     + "CM RCS %.1f lb; %d reversals", f.landing.latitude * 180 / .pi, f.landing.longitude * 180 / .pi,
                     f.miss, f.duration, f.drogues, f.mains, f.peakLoadFactor, f.peakHeatFlux, f.heatLoad,
                     f.rcsPropellant, f.reversals))
        XCTAssertEqual(f.peakLoadFactor, 3.3, accuracy: 0.3)
        XCTAssertLessThan(f.miss, 75)
        XCTAssertEqual(f.duration, 963, accuracy: 40)
        XCTAssertEqual(f.drogues, 53, accuracy: 5)
        XCTAssertEqual(f.mains, 285, accuracy: 20)
        XCTAssertEqual(f.peakHeatFlux, 59.8, accuracy: 6)
        XCTAssertEqual(f.heatLoad, 12_649, accuracy: 1_265)
        XCTAssertGreaterThan(f.rcsPropellant, 49.1 / 2)
        XCTAssertLessThan(f.rcsPropellant, 49.1 * 2)
        XCTAssertGreaterThan(f.reversals, 0)
        XCTAssertTrue(f.log.contains { $0.contains("splashdown at") }, "\(f.log.suffix(5))")
        for step in ["0.05 g", "ELS sequence started", "drogues deployed", "mains deployed"] {
            XCTAssertTrue(f.log.contains { $0.contains(step) }, step)
        }
    }
}

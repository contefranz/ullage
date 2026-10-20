import XCTest
@testable import OrbitCore

/// The HUD's entry readouts (`EntryReadouts`): when they show, and that they
/// carry the entry telemetry, the entry program's 0.05 g latch and peak and
/// the ELS's state.
final class EntryReadoutsTests: XCTestCase {
    let deg = Double.pi / 180

    // Not on the pad, and not in orbit on a vessel without a capsule model:
    // the Saturn V stack carries the CM, but under the SM and the launch
    // vehicle's aerodynamics.
    func testHiddenOutsideEntry() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let stack = VesselLibrary.apollo11OnPad(in: sim)
        sim.updateTelemetry(stack, snapshot: sim.snapshot)
        XCTAssertNil(EntryReadouts(vessel: stack))
        let capsule = VesselLibrary.capsule()
        sim.add(capsule)
        sim.placeInCircularOrbit(capsule, around: sim.system.earth, altitude: 185_000, inclination: 32.5)
        sim.updateTelemetry(capsule, snapshot: sim.snapshot)
        XCTAssertNil(EntryReadouts(vessel: capsule))
    }

    // Any vessel coming down unpowered through the air at 0.05 g or more:
    // the M0 capsule at 60 km, 7.4 km/s, 5° down: the g meter and the light,
    // no bank (no capsule model), no heating, no ELS. Climbing, or burning
    // its engine, it is not entering.
    func testAnyVesselsEntry() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.place(v, geodeticLatitude: 28, longitude: -60, height: 60_000, inertialSpeed: 7_400, flightPathAngle: -5,
                  azimuth: 90)
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        XCTAssertGreaterThan(v.loadFactor, 0.05)
        let r = try XCTUnwrap(EntryReadouts(vessel: v))
        XCTAssertEqual(r.loadFactor, v.loadFactor)
        XCTAssertTrue(r.pointZeroFiveG)
        XCTAssertNil(r.bankAngle)
        XCTAssertNil(r.peakLoadFactor)
        XCTAssertNil(r.landingSystem)
        XCTAssertEqual(r.heatFlux, 0)

        sim.place(v, geodeticLatitude: 28, longitude: -60, height: 60_000, inertialSpeed: 7_400, flightPathAngle: 5,
                  azimuth: 90)
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        XCTAssertFalse(EntryReadouts.isEntering(v))
        XCTAssertNil(EntryReadouts(vessel: v))
    }

    // The Apollo 7 CM from 68-FM-184's entry interface on its entry program
    // at a 55° left bank: shown from the start (a capsule model flies), the
    // bank read from the telemetry, the light dark until the program senses
    // 0.05 g and lit from then on with the program's peak load factor, the
    // heating, and the ELS armed by the program.
    func testCommandModuleEntry() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.commandModule(.apollo7)
        v.aerodynamics = [.apolloCommandModule(calibration: .operational)]
        sim.add(v)
        let ei = EntryTests.apollo7EntryInterface
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height, inertialSpeed: ei.speed,
                  flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
        let program = CMEntryProgram(mode: .bankHold(-55 * deg))
        v.flightProgram = program
        v.attitude = try XCTUnwrap(CMEntryProgram.trimAttitude(of: v, capsule: try XCTUnwrap(v.activeAerodynamics?.capsule),
                                                               bank: -55 * deg, in: sim))
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        var r = try XCTUnwrap(EntryReadouts(vessel: v))
        XCTAssertEqual(try XCTUnwrap(r.bankAngle) / deg, -55, accuracy: 0.5)
        XCTAssertFalse(r.pointZeroFiveG)
        XCTAssertNil(r.peakLoadFactor, "the program has not woken")
        XCTAssertEqual(r.landingSystem, "ELS safe")

        func step() {
            for x in sim.vessels { sim.prepareControls(x) }
            sim.step(min(1, sim.maxStep()))
        }
        step()
        r = try XCTUnwrap(EntryReadouts(vessel: v))
        XCTAssertEqual(r.landingSystem, "ELS armed")
        XCTAssertFalse(r.pointZeroFiveG)
        // Apollo 7's 0.05 g came about 130 s after entry interface.
        let start = sim.time
        while program.pointZeroFiveG == nil && sim.time - start < 400 {
            step()
            XCTAssertEqual(EntryReadouts(vessel: v)?.pointZeroFiveG, program.pointZeroFiveG != nil)
        }
        XCTAssertNotNil(program.pointZeroFiveG)
        let lit = sim.time
        while sim.time - lit < 60 { step() }
        r = try XCTUnwrap(EntryReadouts(vessel: v))
        XCTAssertTrue(r.pointZeroFiveG)
        XCTAssertGreaterThan(r.loadFactor, 0.05)
        XCTAssertEqual(r.loadFactor, v.loadFactor)
        XCTAssertEqual(try XCTUnwrap(r.peakLoadFactor), max(program.peakLoadFactor, v.loadFactor))
        XCTAssertGreaterThan(program.peakLoadFactor, 0.05)
        XCTAssertEqual(r.heatFlux, v.heatFlux)
        XCTAssertEqual(r.heatLoad, v.heatLoad)
        XCTAssertGreaterThan(r.heatFlux, 1e5)
        XCTAssertGreaterThan(r.heatLoad, 1e6)
        XCTAssertEqual(try XCTUnwrap(r.bankAngle), try XCTUnwrap(v.bankAngle))
    }
}

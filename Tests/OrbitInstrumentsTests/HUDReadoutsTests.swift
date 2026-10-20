import XCTest
import OrbitCore
@testable import OrbitInstruments

/// The HUD's phase 2 readouts: the numbers as the cluster prints them, and
/// the manoeuvre DEORBIT's SET loads for the navball.
final class HUDReadoutsTests: XCTestCase {
    let deg = Double.pi / 180

    func testCountdownAndNextEvent() {
        XCTAssertEqual(HUDFormat.countdown(0.2), "0:01")
        XCTAssertEqual(HUDFormat.countdown(1), "0:01")
        XCTAssertEqual(HUDFormat.countdown(42.01), "0:43")
        XCTAssertEqual(HUDFormat.countdown(725), "12:05")
        XCTAssertEqual(HUDFormat.countdown(3_733), "1:02:13")
        XCTAssertEqual(HUDFormat.countdown(2 * 86_400 + 3_733), "2d 01:02:13")
        XCTAssertEqual(HUDFormat.countdown(0), "now")
        XCTAssertEqual(HUDFormat.countdown(-3), "now")
        XCTAssertEqual(HUDFormat.countdown(.infinity), "---")
        XCTAssertEqual(HUDFormat.nextEvent("S-IVB cutoff (IGM)", in: 132.4), "S-IVB cutoff (IGM) in 2:13")
        XCTAssertEqual(HUDFormat.nextEvent("Drogues", in: 0), "Drogues now")
    }

    func testRangeAndRangeRate() {
        XCTAssertEqual(HUDFormat.range(0.84), "0.8 m")
        XCTAssertEqual(HUDFormat.range(125.34), "125.3 m")
        XCTAssertEqual(HUDFormat.range(999.96), "1.00 km")
        XCTAssertEqual(HUDFormat.range(8_432), "8.43 km")
        XCTAssertEqual(HUDFormat.range(1_234_500), "1234.5 km")
        XCTAssertEqual(HUDFormat.range(384_400_000), "384400 km")
        XCTAssertEqual(HUDFormat.rangeRate(0.314), "+0.31 m/s")
        XCTAssertEqual(HUDFormat.rangeRate(-12.44), "-12.4 m/s")
        XCTAssertEqual(HUDFormat.rangeRate(7_312.4), "+7312 m/s")
        XCTAssertEqual(HUDFormat.rangeRate(-0.001), "0.00 m/s")
        XCTAssertEqual(HUDFormat.rangeRate(0.004), "0.00 m/s")
    }

    func testEntryReadouts() {
        XCTAssertEqual(HUDFormat.bank(-55 * deg), "55°L")
        XCTAssertEqual(HUDFormat.bank(120.4 * deg), "120°R")
        XCTAssertEqual(HUDFormat.bank(0.3 * deg), "0°")
        XCTAssertEqual(HUDFormat.bank(-0.4 * deg), "0°")
        XCTAssertEqual(HUDFormat.bank(.pi), "180°")
        XCTAssertEqual(HUDFormat.bank(-.pi), "180°")
        XCTAssertEqual(HUDFormat.bank(-179.6 * deg), "180°")
        XCTAssertEqual(HUDFormat.bank(370 * deg), "10°R")
        XCTAssertEqual(HUDFormat.bank(nil), "---")
        XCTAssertEqual(HUDFormat.heatFlux(0), "0 kW/m²")
        // Apollo 7's planned peak, 59.8 BTU/ft² s (68-FM-184), is 679 kW/m².
        XCTAssertEqual(HUDFormat.heatFlux(59.8 * 11_356.53), "679 kW/m²")
        XCTAssertEqual(HUDFormat.heatFlux(1_234_000), "1.23 MW/m²")
        XCTAssertEqual(HUDFormat.heatLoad(0), "0.00 MJ/m²")
        XCTAssertEqual(HUDFormat.heatLoad(4_561_000), "4.56 MJ/m²")
        XCTAssertEqual(HUDFormat.heatLoad(12_340_000), "12.3 MJ/m²")
        // And its 12,649 BTU/ft² heat load, 144 MJ/m².
        XCTAssertEqual(HUDFormat.heatLoad(12_649 * 11_356.53), "144 MJ/m²")
        XCTAssertEqual(HUDFormat.loadFactor(3.417), "3.42 g")
        XCTAssertEqual(HUDFormat.loadFactor(12.34), "12.3 g")
    }

    // DEORBIT's SET loads the counter and the burn for the navball's
    // manoeuvre marker: the plan's thrust direction and centred ignition.
    // The marker stands while the counter has Δv to go, goes once it has
    // counted the burn down, and CLR clears both.
    func testSetLoadsTheManeuver() throws {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 44))
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 32.5)
        let counter = TestCounter()
        v.flightProgram = counter
        let mfd = MFDController(left: .deorbit)
        _ = mfd.page(.left, sim: sim)
        XCTAssertNil(mfd.activeManeuver(for: v))
        let mode = mfd.mode(.deorbit, on: .left) as! DeorbitMFD
        XCTAssertTrue(mfd.handle(.s, side: .left, sim: sim))
        let plan = try XCTUnwrap(mode.plan)
        let m = try XCTUnwrap(mfd.activeManeuver(for: v))
        XCTAssertEqual(m.name, "DEORBIT")
        XCTAssertEqual(m.direction.dot(plan.burnDirection), 1, accuracy: 1e-12)
        XCTAssertEqual(m.deltaV.length, plan.deltaVMagnitude, accuracy: 1e-9)
        XCTAssertEqual(m.ignition, try XCTUnwrap(plan.centredIgnition))
        XCTAssertEqual(try XCTUnwrap(m.burnTime), try XCTUnwrap(plan.burnTime), accuracy: 1e-12)
        // Retrograde at TIG: against the velocity there, which is ahead.
        XCTAssertLessThan(m.direction.dot(plan.preBurn.velocity.normalized), -0.99)

        counter.loadDeltaV(0.01)     // the SPS cutoff's remainder
        XCTAssertNil(mfd.activeManeuver(for: v))
        counter.loadDeltaV(12)       // cut off early by hand: 12 m/s still to go
        XCTAssertNotNil(mfd.activeManeuver(for: v))
        XCTAssertTrue(mfd.handle(.c, side: .left, sim: sim))
        XCTAssertNil(mfd.data(for: v).maneuver)
        XCTAssertNil(mfd.activeManeuver(for: v))
    }
}

import XCTest
import OrbitCore
@testable import OrbitInstruments

/// The ENTRY page on track E1's entry program: its landing-point prediction
/// and its landing system, whether the program flies the CM itself or
/// through the CSM's SCS.
final class EntryProgramHooksTests: XCTestCase {
    func testEntryPageShowsTheProgramsPrediction() throws {
        let deg = Double.pi / 180
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: Epoch(utcYear: 1968, month: 10, day: 22, hour: 11, minute: 50))
        let v = VesselLibrary.commandModule(.apollo7)
        sim.add(v)
        sim.place(v, geodeticLatitude: 31.03, longitude: -98.83, height: 121_920, inertialSpeed: 7_879.2,
                  flightPathAngle: -1.759, azimuth: 83.64, attitude: Quat(w: 0, x: 0, y: 0, z: 1))
        let mfd = MFDController(left: .entry)
        mfd.update(sim: sim, realTime: 0)
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("LAND no predictor"))

        // Through the SCS: nothing until the SM has gone (here, at once) and
        // the program has predicted.
        let scs = ApolloMission.spacecraftControl(entryMode: .bankHold(-55 * deg))
        v.flightProgram = scs
        XCTAssertNil(scs.predictedLandingPoint)
        sim.advance(by: 0.02)
        let program = try XCTUnwrap(ApolloMission.entryProgram(of: v))
        let p = try XCTUnwrap(program.prediction)
        let point = try XCTUnwrap(scs.predictedLandingPoint)
        XCTAssertEqual(point.latitude, p.latitude)
        XCTAssertEqual(point.longitude, p.longitude)
        XCTAssertEqual(point.time, p.time)
        mfd.update(sim: sim, realTime: 0)
        let page = mfd.page(.left, sim: sim)
        XCTAssertTrue(page.shows("LAND " + MFDFormat.latitude(p.latitude)), page.lines.joined(separator: "\n"))
        XCTAssertTrue(page.shows("ELS armed"), page.lines.joined(separator: "\n"))

        // The program flying the CM itself.
        v.flightProgram = program
        XCTAssertEqual(program.predictedLandingPoint?.latitude, p.latitude)
        XCTAssertTrue(mfd.page(.left, sim: sim).shows("LAND " + MFDFormat.latitude(p.latitude)))
    }
}

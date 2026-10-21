import XCTest
@testable import OrbitCore

/// The isentropic and Prandtl-Meyer relations against NACA Report 1135's
/// tables (γ = 1.4), and their inverses against themselves.
final class NozzleFlowTests: XCTestCase {
    let deg = Double.pi / 180

    // NACA 1135 Table I (γ = 1.4) at M = 2 and 3, to the table's digits,
    // and ν_max = 130.45°.
    func testNACA1135Table() {
        typealias N = NozzleFlow
        XCTAssertEqual(N.areaRatio(mach: 2, gamma: 1.4), 1.6875, accuracy: 5e-5)
        XCTAssertEqual(N.pressureRatio(mach: 2, gamma: 1.4), 0.1278, accuracy: 5e-5)
        XCTAssertEqual(N.prandtlMeyer(mach: 2, gamma: 1.4) / deg, 26.38, accuracy: 5e-3)
        XCTAssertEqual(N.areaRatio(mach: 3, gamma: 1.4), 4.2346, accuracy: 5e-5)
        XCTAssertEqual(N.pressureRatio(mach: 3, gamma: 1.4), 0.02722, accuracy: 5e-6)
        XCTAssertEqual(N.prandtlMeyer(mach: 3, gamma: 1.4) / deg, 49.76, accuracy: 5e-3)
        XCTAssertEqual(N.maximumTurning(gamma: 1.4) / deg, 130.45, accuracy: 5e-3)
        XCTAssertEqual(N.temperatureRatio(mach: 2, gamma: 1.4), 0.5556, accuracy: 5e-5)
        XCTAssertEqual(N.densityRatio(mach: 3, gamma: 1.4), 0.07623, accuracy: 5e-6)
        XCTAssertEqual(N.machAngle(mach: 2) / deg, 30, accuracy: 1e-12)
    }

    // The inverses return the Mach number they came from, on both branches
    // of A/A*, at a rocket's γ as at air's, out to the SPS's 62.5:1 and
    // beyond; the exit pressure follows the area ratio.
    func testInversesRoundTrip() {
        typealias N = NozzleFlow
        for g in [1.13, 1.2, 1.25, 1.4, 5.0 / 3] {
            for m in [1.0001, 1.05, 1.5, 2, 3.7, 5, 8, 15] {
                let a = N.areaRatio(mach: m, gamma: g)
                XCTAssertEqual(N.supersonicMach(areaRatio: a, gamma: g), m, accuracy: 1e-10 * m, "γ \(g), M \(m)")
                let p = N.pressureRatio(mach: m, gamma: g)
                XCTAssertEqual(N.mach(pressureRatio: p, gamma: g), m, accuracy: 1e-9 * m)
                let nu = N.prandtlMeyer(mach: m, gamma: g)
                XCTAssertEqual(N.mach(prandtlMeyer: nu, gamma: g), m, accuracy: 1e-9 * m)
            }
            for m in [0.01, 0.1, 0.3, 0.6, 0.9, 0.9999] {
                let a = N.areaRatio(mach: m, gamma: g)
                XCTAssertEqual(N.subsonicMach(areaRatio: a, gamma: g), m, accuracy: 1e-10, "γ \(g), M \(m)")
            }
            XCTAssertEqual(N.supersonicMach(areaRatio: 1, gamma: g), 1)
            XCTAssertEqual(N.mach(prandtlMeyer: N.maximumTurning(gamma: g), gamma: g), .infinity)
        }
        // The exit pressure falls monotonically with the area ratio.
        var last = 1.0
        for e in [1.5, 4, 16, 27.5, 40, 62.5, 200] {
            let p = N.pressureRatio(mach: N.supersonicMach(areaRatio: e, gamma: 1.22), gamma: 1.22)
            XCTAssertLessThan(p, last)
            last = p
        }
    }

    // NACA 1135 Table I's A/A* at M = 2.5 for γ = 1.4, 2.6367, read back
    // to the table's Mach number.
    func testAreaRatioInverseAgainstTable() {
        XCTAssertEqual(NozzleFlow.areaRatio(mach: 2.5, gamma: 1.4), 2.6367, accuracy: 5e-5)
        XCTAssertEqual(NozzleFlow.supersonicMach(areaRatio: 2.6367, gamma: 1.4), 2.5, accuracy: 5e-5)
    }
}

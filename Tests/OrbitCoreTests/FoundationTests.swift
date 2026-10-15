import XCTest
@testable import OrbitCore

final class MathTests: XCTestCase {
    func testQuaternionMatchesMatrix() {
        let q = Quat(axis: Vec3(1, 2, 3), angle: 0.7)
        let v = Vec3(0.3, -1.2, 2.5)
        let a = q.rotate(v), b = q.matrix * v
        XCTAssertEqual((a - b).length, 0, accuracy: 1e-12)
        XCTAssertEqual(q.inverseRotate(a).x, v.x, accuracy: 1e-12)
        let q2 = Quat(matrix: q.matrix)
        XCTAssertEqual((q2.rotate(v) - a).length, 0, accuracy: 1e-12)
    }

    func testMatrixInverse() {
        let m = Mat3(rows: Vec3(4, 1, 0.5), Vec3(1, 3, 0.2), Vec3(0.5, 0.2, 2))
        let p = m * m.inverse
        for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(p[i, j], i == j ? 1 : 0, accuracy: 1e-12) } }
    }

    func testPassiveRotationConvention() {
        // Rotating the frame by +90 deg about z makes the old x axis appear at -y.
        let v = Mat3.frameZ(Double.pi / 2) * Vec3.unitX
        XCTAssertEqual(v.y, -1, accuracy: 1e-15)
    }
}

final class TimeTests: XCTestCase {
    func testJulianDay() {
        XCTAssertEqual(Epoch.julianDay(year: 2000, month: 1, day: 1), 2451544.5)
        XCTAssertEqual(Epoch.julianDay(year: 1957, month: 10, day: 4), 2436115.5)   // Meeus example 7.a (4.81 d)
        // Leap-second table entries fall on the right dates.
        XCTAssertEqual(Epoch.julianDay(year: 1972, month: 1, day: 1), 2441317.5)
        XCTAssertEqual(Epoch.julianDay(year: 2017, month: 1, day: 1), 2457754.5)
    }

    func testLeapSeconds() {
        XCTAssertEqual(Epoch.taiMinusUTC(julianDateUTC: 2451545.0), 32)
        XCTAssertEqual(Epoch.taiMinusUTC(julianDateUTC: 2458000.0), 37)
        // Apollo 11: TAI-UTC was ~7.9 s (rubber-second era).
        XCTAssertEqual(Epoch.taiMinusUTC(julianDateUTC: 2440419.06), 7.9, accuracy: 0.3)
    }

    func testUTCRoundTrip() {
        let e = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32, second: 0)
        XCTAssertEqual(e.julianDateUTC, 2440419.0638889, accuracy: 1e-7)
        let c = e.utc
        XCTAssertEqual(c.year, 1969); XCTAssertEqual(c.month, 7); XCTAssertEqual(c.day, 16)
        XCTAssertEqual(c.hour, 13); XCTAssertEqual(c.minute, 32)
        XCTAssertEqual(c.second, 0, accuracy: 0.002)
        // J2000.0 is 2000-01-01 11:58:55.816 UTC.
        let j2000 = Epoch(tdbSecondsPastJ2000: 0).utc
        XCTAssertEqual(j2000.hour, 11); XCTAssertEqual(j2000.minute, 58)
        XCTAssertEqual(j2000.second, 55.816, accuracy: 0.002)
    }
}

final class AtmosphereTests: XCTestCase {
    let atm = USStandardAtmosphere1976()

    func testLayerBasePressures() {
        // U.S. Standard Atmosphere 1976, Table 4 (geopotential layer bases).
        let r0 = 6_356_766.0
        func geometric(_ h: Double) -> Double { r0 * h / (r0 - h) }
        let expected: [(Double, Double, Double)] = [
            (0, 101_325, 288.15), (11_000, 22_632.06, 216.65), (20_000, 5_474.889, 216.65),
            (32_000, 868.0187, 228.65), (47_000, 110.9063, 270.65), (51_000, 66.93887, 270.65),
            (71_000, 3.956420, 214.65),
        ]
        for (h, p, t) in expected {
            let s = atm.state(altitude: geometric(h))
            XCTAssertEqual(s.pressure, p, accuracy: p * 2e-5, "pressure at \(h)")
            XCTAssertEqual(s.temperature, t, accuracy: 1e-6, "temperature at \(h)")
        }
        XCTAssertEqual(atm.state(altitude: 0).density, 1.225, accuracy: 1e-4)
        XCTAssertEqual(atm.state(altitude: 0).speedOfSound, 340.294, accuracy: 0.01)
    }

    func testUpperAtmosphereIsMonotonic() {
        var last = Double.infinity
        for km in stride(from: 0.0, through: 1000, by: 5) {
            let rho = atm.state(altitude: km * 1000).density
            XCTAssertLessThan(rho, last * 1.12, "density jump at \(km) km")   // allow the 86 km model seam
            last = rho
        }
        XCTAssertEqual(atm.state(altitude: 400_000).density, 3.725e-12, accuracy: 1e-14)
    }
}

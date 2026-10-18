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
        // SOFA/ERFA t_dat: 2003-06-01 32 s, 2008-01-17 33 s, 2017-09-01 37 s.
        XCTAssertEqual(Epoch.taiMinusUTC(julianDateUTC: Epoch.julianDay(year: 2003, month: 6, day: 1)), 32)
        XCTAssertEqual(Epoch.taiMinusUTC(julianDateUTC: Epoch.julianDay(year: 2008, month: 1, day: 17)), 33)
        XCTAssertEqual(Epoch.taiMinusUTC(julianDateUTC: Epoch.julianDay(year: 2017, month: 9, day: 1)), 37)
    }

    // Before 1972 UTC ran on "rubber seconds": TAI-UTC = offset + (MJD -
    // MJD0) × rate, stepped by 0.05-0.1 s (USNO tai-utc.dat, as SOFA/ERFA
    // dat). The values are that table's expressions at its own dates.
    func testRubberSecondsBefore1972() {
        func dat(_ y: Int, _ m: Int, _ d: Int, _ seconds: Double = 0) -> Double {
            Epoch.taiMinusUTC(julianDateUTC: Epoch.julianDay(year: y, month: m, day: d) + seconds / 86400)
        }
        // Apollo 11, 1969-07-16 13:32:00 UTC: 4.2131700 + (40418.5638889 - 39126) × 0.002592.
        let launch = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        XCTAssertEqual(Epoch.taiMinusUTC(julianDateUTC: launch.julianDateUTC), 7.5634956, accuracy: 1e-6)
        XCTAssertEqual(launch.tdb - (launch.julianDateUTC - Epoch.j2000JD) * 86400, 39.7474956, accuracy: 1e-4)
        XCTAssertEqual(dat(1961, 1, 1), 1.4228180, accuracy: 1e-9)
        XCTAssertEqual(dat(1961, 7, 31, 86399.9), 1.6975700, accuracy: 1e-5)   // -0.05 s step on 1961-08-01
        XCTAssertEqual(dat(1961, 8, 1), 1.6475700, accuracy: 1e-9)
        XCTAssertEqual(dat(1963, 10, 31, 86399.9), 2.5972788, accuracy: 1e-5)  // +0.1 s on 1963-11-01
        XCTAssertEqual(dat(1963, 11, 1), 2.6972788, accuracy: 1e-9)
        XCTAssertEqual(dat(1964, 1, 1), 2.7657940, accuracy: 1e-9)             // continuous on 1964-01-01
        XCTAssertEqual(dat(1968, 1, 31, 86399.9), 6.2856820, accuracy: 1e-5)   // -0.1 s on 1968-02-01
        XCTAssertEqual(dat(1968, 2, 1), 6.1856820, accuracy: 1e-9)
        XCTAssertEqual(dat(1971, 12, 31, 86399.9), 9.8922420, accuracy: 1e-5)
        XCTAssertEqual(dat(1972, 1, 1), 10)
        // Before 1960, when there was no UTC, the 1960-01-01 value is held.
        XCTAssertEqual(dat(1959, 6, 1), 0.9434820, accuracy: 1e-9)
    }

    // UTC -> TDB -> UTC across the rubber-second steps and a leap second.
    // Where the clock was set forward (1961-08-01 by 0.05 s, 1968-02-01 by
    // 0.1 s) the skipped labels never existed: 1968-01-31 23:59:59.95 is the
    // instant the clock showed as 1968-02-01 00:00:00.05. Where it was set
    // back, the repeated labels read as shown the second time: 0.05 s before
    // the TAI instant of 1972-01-01 00:00:00 UTC the clock showed 1971-12-31
    // 23:59:59.95 again (TAI-UTC 10 s, not 9.892).
    func testUTCRoundTripAcrossSteps() {
        for (y, m, d) in [(1961, 8, 1), (1963, 11, 1), (1968, 2, 1), (1972, 1, 1), (2017, 1, 1)] {
            for s in [-0.3, -0.12, 0, 0.05, 0.3] {
                let jd = Epoch.julianDay(year: y, month: m, day: d) + s / 86400
                XCTAssertEqual((Epoch(julianDateUTC: jd).julianDateUTC - jd) * 86400, 0, accuracy: 1e-4, "\(y)-\(m)-\(d) \(s) s")
            }
        }
        let skipped = Epoch(utcYear: 1968, month: 1, day: 31, hour: 23, minute: 59, second: 59.95).utc
        XCTAssertEqual([skipped.year, skipped.month, skipped.day, skipped.hour, skipped.minute], [1968, 2, 1, 0, 0])
        XCTAssertEqual(skipped.second, 0.05, accuracy: 1e-3)
        let repeated = Epoch(utcYear: 1972, month: 1, day: 1) + -0.05
        let c = repeated.utc
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [1971, 12, 31, 23, 59])
        XCTAssertEqual(c.second, 59.95, accuracy: 1e-3)
        let leap = (Epoch(utcYear: 2017, month: 1, day: 1) + -0.5).utc   // inside the leap second
        XCTAssertEqual([leap.year, leap.month, leap.day, leap.hour, leap.minute], [2016, 12, 31, 23, 59])
        XCTAssertEqual(leap.second, 59.5, accuracy: 1e-3)
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

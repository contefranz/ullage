import XCTest
@testable import OrbitCore

/// The atmosphere above 86 km against U.S. Standard Atmosphere 1976, Part 4
/// Table I (tools/data/us76_table1_86_1000km.csv, read by two readers, H).
final class UpperAtmosphereTests: XCTestCase {
    let atm = USStandardAtmosphere1976()

    /// The standard's values at the altitudes the entry design names: density
    /// within 0.5 % and temperature within 0.1 K (Table I, as printed).
    func testStandardValues() {
        let table: [(km: Double, t: Double, p: Double, rho: Double)] = [
            (86, 186.87, 0.37338, 6.958e-6), (90, 186.87, 0.18359, 3.416e-6), (100, 195.08, 3.2011e-2, 5.604e-7),
            (110, 240.00, 7.1042e-3, 9.708e-8), (120, 360.00, 2.5382e-3, 2.222e-8), (150, 634.39, 4.5422e-4, 2.076e-9),
            (200, 854.56, 8.4736e-5, 2.541e-10), (300, 976.01, 8.7704e-6, 1.916e-11),
            (500, 999.24, 3.0236e-7, 5.215e-13), (1000, 1000.00, 7.5138e-9, 3.561e-15),
        ]
        for row in table {
            let s = atm.state(altitude: row.km * 1000)
            XCTAssertEqual(s.density, row.rho, accuracy: row.rho * 0.005, "density at \(row.km) km")
            XCTAssertEqual(s.pressure, row.p, accuracy: row.p * 0.005, "pressure at \(row.km) km")
            XCTAssertEqual(s.temperature, row.t, accuracy: 0.1, "temperature at \(row.km) km")
        }
        // Entry interface, 400,000 ft: log-linear between the 121 and 122 km rows.
        let ei = atm.state(altitude: 121_920)
        XCTAssertEqual(ei.density, 1.977e-8 * pow(1.767 / 1.977, 0.92), accuracy: 1e-13)
        XCTAssertEqual(ei.temperature, 382.62, accuracy: 0.05)
    }

    /// Every transcribed row: the model's table holds the printed pressure and
    /// density, its temperature profile gives the printed kinetic temperature,
    /// and its speed of sound is the standard's sqrt(γ R* T_M / M0) with the
    /// printed molecular-scale temperature.
    func testEveryRowOfTheTranscription() throws {
        let rows = try toolsData("us76_table1_86_1000km.csv")
        XCTAssertEqual(rows.count, USStandardAtmosphere1976.upper.count)
        for (row, model) in zip(rows, USStandardAtmosphere1976.upper) {
            let z = row.number("z_m")!, p = row.number("p_mb")!, rho = row.number("rho_kgm3")!
            XCTAssertEqual(model.km * 1000, z)
            XCTAssertEqual(model.pressure, p, "pressure at \(z) m")
            XCTAssertEqual(model.density, rho, "density at \(z) m")
            // 86 km itself is the lower model's (testContinuityAt86km).
            let s = atm.state(altitude: z), exact = z > 86_000 ? 1e-12 : 5e-4
            XCTAssertEqual(s.pressure, 100 * p, accuracy: 100 * p * exact)
            XCTAssertEqual(s.density, rho, accuracy: rho * exact)
            XCTAssertEqual(s.temperature, row.number("t_k")!, accuracy: z > 86_000 ? 0.01 : 0.1, "temperature at \(z) m")
            let a = (1.4 * 8_314.32 * row.number("tm_k")! / 28.9644).squareRoot()
            XCTAssertEqual(s.speedOfSound, a, accuracy: a * 2e-4, "speed of sound at \(z) m")
        }
    }

    /// The two models meet at 86 km: pressure, density and the speed of sound
    /// within 0.05 %; the temperature steps by the 0.08 K between the
    /// molecular-scale temperature below and the kinetic one above.
    func testContinuityAt86km() {
        let below = atm.state(altitude: 85_999.999), above = atm.state(altitude: 86_000.001)
        XCTAssertEqual(above.pressure, below.pressure, accuracy: below.pressure * 5e-4)
        XCTAssertEqual(above.density, below.density, accuracy: below.density * 5e-4)
        XCTAssertEqual(above.speedOfSound, below.speedOfSound, accuracy: below.speedOfSound * 5e-4)
        XCTAssertEqual(below.temperature, 186.946, accuracy: 0.001)
        XCTAssertEqual(above.temperature, 186.8673, accuracy: 1e-4)
    }

    /// Pressure and density fall all the way up, and the temperature profile
    /// is continuous where its segments join (91, 110 and 120 km).
    func testSmoothAllTheWayUp() {
        var last = atm.state(altitude: 86_000)
        for z in stride(from: 86_100.0, through: 1_000_000, by: 100) {
            let s = atm.state(altitude: z)
            XCTAssertLessThan(s.density, last.density, "density at \(z) m")
            XCTAssertLessThan(s.pressure, last.pressure, "pressure at \(z) m")
            last = s
        }
        for km in [91.0, 110, 120] {
            let t0 = USStandardAtmosphere1976.upperTemperature(km: km - 1e-9)
            let t1 = USStandardAtmosphere1976.upperTemperature(km: km + 1e-9)
            XCTAssertEqual(t0, t1, accuracy: 1e-3, "temperature join at \(km) km")
        }
        XCTAssertEqual(atm.state(altitude: 1_000_001).density, 0)
    }
}

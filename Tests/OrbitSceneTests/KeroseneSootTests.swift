import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// Decision 4's soot model (`KeroseneSoot`): CSVEM's afterburning fit by
/// the pressure's US76 altitude, its floor dropped.
final class KeroseneSootTests: XCTestCase {
    static let air = USStandardAtmosphere1976()

    func share(atKm h: Double) -> Double {
        KeroseneSoot.survivingShare(pressure: Self.air.state(altitude: 1_000 * h).pressure)
    }

    /// Above 15 km it is CSVEM's fit as Barker et al.'s inventory computes
    /// it, max(0.04, min(1, 0.04 e^(0.12 (h − 15)))), to 1e-6; all of it
    /// from 41.8 km (ln 25 / 0.12 above 15 km) and in vacuum.
    func testAloftIsCSVEMsFit() {
        for h in stride(from: 15.0, through: 60, by: 2.5) {
            let csvem = max(0.04, min(1, 0.04 * exp(0.12 * (h - 15))))
            XCTAssertEqual(share(atKm: h), csvem, accuracy: 1e-6 * csvem, "\(h) km")
        }
        XCTAssertEqual(share(atKm: 15 + log(25.0) / 0.12), 1, accuracy: 1e-6)
        XCTAssertEqual(KeroseneSoot.survivingShare(pressure: 0), 1)
    }

    /// Below 15 km the fit's exponential carries on (CSVEM's 4 % floor
    /// dropped): 0.66 % at sea level, so 0.015 % of the exhaust survives
    /// near the pad (the global models' floor leaves 0.09 %); it falls
    /// steadily with the pressure, and the surviving soot is the exit's
    /// times it.
    func testDownToSeaLevel() {
        XCTAssertEqual(share(atKm: 0), 0.04 * exp(-1.8), accuracy: 1e-6)
        let pad = KeroseneSoot.surviving(pressure: 101_325)
        XCTAssertEqual(pad, KeroseneSoot.exit * 0.04 * exp(-1.8), accuracy: 1e-9)
        var last = 0.0
        for p in stride(from: 110_000.0, through: 100, by: -500) {
            let s = KeroseneSoot.survivingShare(pressure: p)
            XCTAssertGreaterThanOrEqual(s, last, "\(p) Pa")
            last = s
        }
        for h in [0.0, 0.5, 2, 6, 10.6, 15, 33, 42] {
            print(String(format: "KeroseneSootTests: %4.1f km: %.4f of the exit's soot, %.4f %% of the exhaust", h,
                         share(atKm: h), 100 * KeroseneSoot.exit * share(atKm: h)))
        }
    }

    /// The altitude is US76's for the pressure, to a millimetre.
    func testStandardAltitude() {
        for h in [-1_000.0, 0, 3_000, 11_000, 20_000, 47_000, 80_000] {
            XCTAssertEqual(KeroseneSoot.standardAltitude(pressure: Self.air.state(altitude: h).pressure), h, accuracy: 1e-3)
        }
    }
}

import XCTest
@testable import OrbitCore

/// The frost schedule against FER Table 20-1, and the ice's sublimation
/// against Murphy and Koop and IAPWS.
final class FrostSheddingTests: XCTestCase {
    typealias F = FrostShedding
    typealias I = IceSublimation

    // Each band holds its first-motion frost until first motion and the
    // table's CECO mass from CECO on; what it sheds in between, the burst
    // and the integrated rate, is the table's difference within 1 %
    // (295 kg from the S-IC, 204 from the S-II, 90 from the S-IVB), and the
    // remaining mass only falls.
    func testShedsFERTable20_1ByCECO() {
        XCTAssertEqual(F.cutoffTime, 134.9, accuracy: 1e-9)
        for band in F.Band.allCases {
            let m0 = F.initialMass(band), mc = F.massAtCutoff(band)
            XCTAssertEqual(F.remainingMass(band, at: -1), m0)
            XCTAssertEqual(F.remainingMass(band, at: F.cutoffTime), mc, accuracy: 1e-9)
            XCTAssertEqual(F.remainingMass(band, at: 600), mc)
            let burst = F.shedMass(band, from: -1e-9, to: 0)
            XCTAssertEqual(burst, F.burstShare * (m0 - mc), accuracy: 1e-9)
            let n = 20_000, h = F.cutoffTime / Double(n)
            var integral = 0.0
            for i in 0..<n { integral += F.shedRate(band, at: (Double(i) + 0.5) * h) * h }
            XCTAssertEqual((burst + integral) / (m0 - mc), 1, accuracy: 0.01, band.rawValue)
            var last = m0
            for t in stride(from: 0.0, through: 200, by: 0.5) {
                XCTAssertLessThanOrEqual(F.remainingMass(band, at: t), last)
                last = F.remainingMass(band, at: t)
            }
        }
        XCTAssertEqual(F.Band.allCases.reduce(0) { $0 + F.initialMass($1) - F.massAtCutoff($1) }, 589)
        XCTAssertEqual(F.remainingFraction(.sIC, at: 200), 340.0 / 635, accuracy: 1e-12)
        // Frame intervals at any warp add up to the whole.
        var shed = 0.0, t = -0.5
        while t < 140 { shed += F.shedMass(.sII, from: t, to: t + 1.7); t += 1.7 }
        XCTAssertEqual(shed, 204, accuracy: 1e-9)
    }

    // Murphy and Koop's vapour pressure over ice: 611.657 Pa at the triple
    // point, and IAPWS's sublimation curve (Wagner et al. 2011) within 0.5 %
    // from 110 K up (-20 °C: 103.2 Pa; -80 °C: 0.0548 Pa).
    func testMurphyKoopVapourPressure() {
        func iapws(_ t: Double) -> Double {
            let th = t / 273.16
            let a = [-0.212144006e2, 0.273203819e2, -0.610598130e1], b = [0.333333333e-2, 0.120666667e1, 0.170333333e1]
            let sum = zip(a, b).reduce(0) { $0 + $1.0 * pow(th, $1.1) }
            return 611.657 * exp(sum / th)
        }
        XCTAssertEqual(I.vaporPressure(temperature: 273.16), 611.657, accuracy: 0.01)
        XCTAssertEqual(I.vaporPressure(temperature: 253.15), 103.2, accuracy: 0.1)
        XCTAssertEqual(I.vaporPressure(temperature: 193.15), 0.0548, accuracy: 0.0001)
        for t in stride(from: 110.0, through: 273.16, by: 2.5) {
            XCTAssertEqual(I.vaporPressure(temperature: t) / iapws(t), 1, accuracy: 0.005, "\(t) K")
        }
    }

    // In vacuum the flux is Hertz and Knudsen's p_sat √(M / (2π R T)),
    // whatever the radius; air's diffusion slows it, the more the larger
    // the flake; supersaturated air deposits.
    func testHertzKnudsenFlux() {
        let t = 210.0
        let hk = I.vaporPressure(temperature: t) * (I.molarMass / (2 * Double.pi * 8.314462618 * t)).squareRoot()
        for r in [1e-4, 1e-3, 0.1] {
            XCTAssertEqual(I.massFlux(iceTemperature: t, airPressure: 0, airTemperature: t, radius: r) / hk, 1,
                           accuracy: 1e-9)
        }
        let small = I.massFlux(iceTemperature: 250, airPressure: 101_325, airTemperature: 250, radius: 5e-4)
        let large = I.massFlux(iceTemperature: 250, airPressure: 101_325, airTemperature: 250, radius: 5e-3)
        let free = I.massFlux(iceTemperature: 250, airPressure: 0, airTemperature: 250, radius: 5e-4)
        XCTAssertLessThan(small, free / 50)
        XCTAssertLessThan(large, small)
        XCTAssertLessThan(I.massFlux(iceTemperature: 250, airPressure: 50_000, airTemperature: 250,
                                     vaporPressure: 2 * I.vaporPressure(temperature: 250), radius: 1e-3), 0)
    }

    // Sunlit in vacuum, frost cools itself by sublimating: it settles near
    // 183 K, not the 208 K radiation alone would give, the energy balance
    // closing there, and a 1 mm flake lasts about 9 h, the "fireflies"; in
    // eclipse, warmed by Earth's infrared alone, about 2 days. In dry air
    // at 270 K a 1 mm flake lasts under an hour, diffusion-limited.
    func testIceLifetimes() {
        let sunlit = I.radiativeEquilibriumTemperature(sunlitFraction: 1)
        let radiative = pow(I.solarAbsorptance * I.solarConstant / (4 * I.emissivity * 5.670374419e-8), 0.25)
        XCTAssertEqual(radiative, 207.6, accuracy: 0.5)
        XCTAssertLessThan(sunlit, radiative - 10)
        XCTAssertGreaterThan(sunlit, 180)
        XCTAssertEqual(I.surplus(temperature: sunlit, sunlitFraction: 1), 0, accuracy: 1e-6)
        let eclipse = I.radiativeEquilibriumTemperature(sunlitFraction: 0, earthInfrared: 240)
        XCTAssertLessThan(eclipse, sunlit)
        let firefly = I.vacuumLifetime(radius: 5e-4, temperature: sunlit)
        XCTAssertGreaterThan(firefly, 3_600)
        XCTAssertLessThan(firefly, 10 * 86_400)
        XCTAssertGreaterThan(I.vacuumLifetime(radius: 5e-4, temperature: eclipse), 3 * firefly)
        let rate = I.radiusRate(iceTemperature: 270, airPressure: 101_325, airTemperature: 270, radius: 5e-4)
        XCTAssertGreaterThan(5e-4 / rate, 60)
        XCTAssertLessThan(5e-4 / rate, 3_600)
    }
}

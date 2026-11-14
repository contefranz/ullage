import Foundation
import XCTest
@testable import OrbitScene

/// The HDR renderer's units against external references (track R1).
final class PhotometryTests: XCTestCase {
    /// The 1948 candela: a full radiator at the freezing point of platinum
    /// (2041.4 K) has a luminance of 60 cd/cm², 6.0e5 cd/m², here within 3 %
    /// through the Wyman-Sloan-Shirley colour-matching fits.
    func testBlackbodyLuminanceAtThePlatinumPoint() {
        let l = Photometry.blackbody(2_041.4).luminance
        XCTAssertEqual(l, 6.0e5, accuracy: 6.0e5 * 0.03)
    }

    /// CIE illuminant A, a full radiator at 2856 K with c₂ = 1.435e-2 m K
    /// (CIE 15:2004), has chromaticity (0.44757, 0.40745).
    func testIlluminantAChromaticity() {
        let xyz = Photometry.blackbodyXYZ(2_856, c2: 1.435e-2)
        let sum = xyz.x + xyz.y + xyz.z
        XCTAssertEqual(xyz.x / sum, 0.44757, accuracy: 0.002)
        XCTAssertEqual(xyz.y / sum, 0.40745, accuracy: 0.002)
    }

    /// The Planckian locus against Kim et al.'s cubic-spline approximation
    /// (2002, US patent 7,024,034; also Kang et al., J. Korean Phys. Soc.
    /// 41(6)), within 0.003 from 2000 to 10,000 K.
    func testPlanckianLocus() {
        func kang(_ t: Double) -> (Double, Double) {
            let x = t <= 4_000
                ? -0.266_123_9e9 / (t * t * t) - 0.234_358_9e6 / (t * t) + 0.877_695_6e3 / t + 0.179_910
                : -3.025_846_9e9 / (t * t * t) + 2.107_037_9e6 / (t * t) + 0.222_634_7e3 / t + 0.240_390
            let y: Double
            if t <= 2_222 {
                y = -1.106_381_4 * x * x * x - 1.348_110_20 * x * x + 2.185_558_32 * x - 0.202_196_83
            } else if t <= 4_000 {
                y = -0.954_947_6 * x * x * x - 1.374_185_93 * x * x + 2.091_370_15 * x - 0.167_488_67
            } else {
                y = 3.081_758_0 * x * x * x - 5.873_386_70 * x * x + 3.751_129_97 * x - 0.370_014_83
            }
            return (x, y)
        }
        for t in [2_000.0, 2_856, 4_000, 5_000, 5_772, 6_500, 10_000] {
            let c = Photometry.blackbody(t).chromaticity, k = kang(t)
            XCTAssertEqual(c.x, k.0, accuracy: 0.003, "x at \(t) K")
            XCTAssertEqual(c.y, k.1, accuracy: 0.003, "y at \(t) K")
        }
    }

    /// The Sun's colour: a 5772 K blackbody (IAU 2015 B3) in linear Rec. 709
    /// with unit luminance, slightly warm (the D65 white is 6504 K), and a
    /// 6504 K blackbody close to neutral.
    func testSunColour() {
        let s = Photometry.sunColor
        XCTAssertEqual(s.luminance, 1, accuracy: 1e-9)
        XCTAssertEqual(s.r, 1.110, accuracy: 0.005)
        XCTAssertEqual(s.g, 0.976, accuracy: 0.005)
        XCTAssertEqual(s.b, 0.912, accuracy: 0.005)
        XCTAssertGreaterThan(s.r, s.g)
        XCTAssertGreaterThan(s.g, s.b)
        let d65 = Photometry.blackbody(6_504).color
        for c in [d65.r, d65.g, d65.b] { XCTAssertEqual(c, 1, accuracy: 0.05) }
    }

    /// E⊙ is Darula et al.'s 133.334 klx at 1 AU and falls as 1/r²; the
    /// disc is 0.2665° in radius, so its mean luminance is E⊙/Ω⊙ = 1.96e9
    /// cd/m², within 7 % of a 5772 K blackbody's (the photosphere is not a
    /// full radiator in the visible).
    func testSunIlluminanceAndLuminance() {
        let au = Photometry.astronomicalUnit
        XCTAssertEqual(Photometry.solarIlluminance(distance: au), 133_334, accuracy: 0.5)
        XCTAssertEqual(Photometry.solarIlluminance(distance: 2 * au), 133_334 / 4, accuracy: 0.5)
        XCTAssertEqual(Photometry.solarIlluminance(distance: 0.5 * au) / Photometry.solarIlluminance(distance: au), 4,
                       accuracy: 1e-12)
        XCTAssertEqual(Photometry.solarAngularRadius(distance: au) * 180 / .pi, 0.26645, accuracy: 0.0001)
        XCTAssertEqual(Photometry.solarLuminance, 1.962e9, accuracy: 0.005e9)
        let bb = Photometry.blackbody(Photometry.solarTemperature).luminance
        XCTAssertEqual(Photometry.solarLuminance / bb, 1, accuracy: 0.07)
        // The limb darkening keeps the disc's mean: the centre is brighter.
        XCTAssertEqual(Photometry.solarCentreOverMean, 1.25, accuracy: 1e-12)
    }

    /// V magnitude to illuminance (Allen: 2.54 µlx at V = 0), checked
    /// against the Sun: V⊙ = -26.76 (Willmer 2018, ApJS 236, 47) gives
    /// Darula's luminous solar constant within 5 %.
    func testVisualMagnitudeToIlluminance() {
        XCTAssertEqual(Photometry.illuminance(visualMagnitude: 0), 2.54e-6, accuracy: 1e-12)
        XCTAssertEqual(Photometry.illuminance(visualMagnitude: 1) / Photometry.illuminance(visualMagnitude: 6), 100,
                       accuracy: 1e-9)
        let sun = Photometry.illuminance(visualMagnitude: -26.76)
        XCTAssertEqual(sun / Photometry.solarIlluminanceAt1AU, 1, accuracy: 0.05)
    }

    /// B-V to temperature (Ballesteros 2012): the Sun's B-V of 0.65 is near
    /// 5800 K, Vega's 0.0 near 10,000 K, and redder stars are cooler.
    func testStarTemperatures() {
        XCTAssertEqual(Photometry.starTemperature(colorIndex: 0.65), 5_780, accuracy: 150)
        XCTAssertEqual(Photometry.starTemperature(colorIndex: 0.0), 10_000, accuracy: 500)
        XCTAssertGreaterThan(Photometry.starTemperature(colorIndex: 0.5), Photometry.starTemperature(colorIndex: 1.5))
    }

    /// The heat shield's glow: radiative equilibrium (σT⁴ε = q), a grey
    /// body of the ablator's emissivity; dark below the Draper point's
    /// neighbourhood, orange and bright at entry's fluxes.
    func testGlow() {
        let q = 0.85 * Photometry.stefanBoltzmann * pow(2_041.4, 4)
        let g = Photometry.glow(heatFlux: q, emissivity: 0.85)
        XCTAssertEqual(g.temperature, 2_041.4, accuracy: 0.01)
        XCTAssertEqual(g.luminance.luminance / (0.85 * Photometry.blackbody(2_041.4).luminance), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(g.luminance.r, g.luminance.g)
        XCTAssertGreaterThan(g.luminance.g, g.luminance.b)
        XCTAssertGreaterThanOrEqual(g.luminance.b, 0)
        XCTAssertEqual(Photometry.glow(heatFlux: 1_000, emissivity: 0.85).luminance.luminance, 0)
        let cool = LegacyLighting.glowLuminance(heatFlux: 0.85 * Photometry.stefanBoltzmann * pow(900.0, 4))
        let hot = LegacyLighting.glowLuminance(heatFlux: 0.85 * Photometry.stefanBoltzmann * pow(1_800.0, 4))
        XCTAssertGreaterThan(hot.r, cool.r * 1_000, "the glow brightens steeply with temperature")
    }
}

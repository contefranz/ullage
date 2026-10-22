import XCTest
import OrbitCore
@testable import OrbitScene

/// Frost from FER Table 20-1 and char from the entry's heat load.
final class FrostCharTests: XCTestCase {
    /// ∫ density dA over each stage's skin, by stations (1 in steps).
    static func integral(_ stage: Frost.Stage, time: Double) -> Double {
        var total = 0.0
        for zone in Frost.zones where zone.stage == stage {
            let step = 1.0, inch = 0.0254
            var s = zone.stations.lowerBound + step / 2
            while s < zone.stations.upperBound {
                total += Frost.arealDensity(station: s, time: time) * 2 * Double.pi * zone.radius * inch * step * inch
                s += step
            }
        }
        return total
    }

    /// The frost on the skin integrates to FER Table 20-1's masses within
    /// 1 %: 635, 204 and 90 kg on the pad and at first motion; 340, 0 and
    /// 0 kg at CECO; the S-IC's 295 kg, the S-II's 204 and the S-IVB's 90
    /// shed between.
    func testFrostIntegralsMatchTheFER() {
        let table: [(Frost.Stage, Double, Double)] = [(.sIC, 635, 340), (.sII, 204, 0), (.sIVB, 90, 0)]
        for (stage, release, cutoff) in table {
            for t in [-600.0, 0, Frost.firstMotion] {
                XCTAssertEqual(Self.integral(stage, time: t), release, accuracy: 0.01 * release, "\(stage) at \(t) s")
            }
            XCTAssertEqual(Self.integral(stage, time: Frost.centreCutoff), cutoff, accuracy: 0.01 * release, "\(stage)")
            XCTAssertEqual(Self.integral(stage, time: 160), cutoff, accuracy: 0.01 * release, "\(stage)")
            let shed = Self.integral(stage, time: 0) - Self.integral(stage, time: Frost.centreCutoff)
            XCTAssertEqual(shed, release - cutoff, accuracy: 0.01 * (release - cutoff), "\(stage) shed")
            // The shed rate integrates to the same.
            var rate = 0.0
            for k in 0..<1400 { rate += Frost.shedRate(stage, time: (Double(k) + 0.5) * 0.1) * 0.1 }
            XCTAssertEqual(rate, release - cutoff, accuracy: 0.01 * (release - cutoff), "\(stage) rate")
        }
        XCTAssertEqual(Frost.mass(.sIC, time: (Frost.firstMotion + Frost.centreCutoff) / 2), (635 + 340) / 2,
                       accuracy: 1e-9)
    }

    /// Frost lies on the cryogenic bands only (the S-IC LOX tank and
    /// intertank, the S-II's aft LOX band, the S-IVB's tank), fades only
    /// with time, and is full on the LOX tank on the pad.
    func testFrostCoverage() {
        XCTAssertEqual(Frost.coverage(station: 1150, time: 0), 1)
        XCTAssertEqual(Frost.coverage(station: 750, time: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Frost.coverage(station: 1150, time: Frost.centreCutoff), 340.0 / 635, accuracy: 1e-12)
        for station in [200.0, 600, 1480, 1600, 1740, 2000, 2100, 2300, 2450, 2700, 3150, 3240] {
            XCTAssertEqual(Frost.coverage(station: station, time: 0), 0, "\(station)")
            XCTAssertEqual(Frost.arealDensity(station: station, time: 0), 0, "\(station)")
        }
        for station in [1800.0, 1890, 1960] { XCTAssertGreaterThan(Frost.coverage(station: station, time: 0), 0.9) }
        for station in stride(from: 620.0, through: 3110, by: 10) {
            var last = Double.infinity
            for t in stride(from: -10.0, through: 200, by: 5) {
                let c = Frost.coverage(station: station, time: t)
                XCTAssertLessThanOrEqual(c, last + 1e-12, "\(station) at \(t)")
                XCTAssertTrue((0...1).contains(c))
                last = c
            }
            if station > 1500 { XCTAssertEqual(last, 0, "\(station): the upper stages' frost is gone by CECO") }
        }
        // The flags on the LOX tank are under the heaviest frost on the pad
        // (AS-506's launch-day photos: frost hides them).
        let flagStation = 1160.0
        XCTAssertGreaterThan(Frost.arealDensity(station: flagStation, time: 0), Frost.arealDensity(station: 2950, time: 0))
    }

    /// The overlay is one scale for every stage: its strength is the
    /// frost's areal density over the S-IC LOX tank's on the pad, so the
    /// S-IVB's 90 kg, spread over its tank, read as the design's light
    /// band (about 0.55), and the S-II's 204 kg on its aft band about as
    /// heavy as the LOX tank's.
    func testCoverageFollowsTheFrostsThickness() {
        let lox = Frost.arealDensity(station: 1150, time: 0)
        XCTAssertEqual(Frost.fullCoverageDensity, lox, accuracy: 1e-12)
        XCTAssertEqual(lox, 635 / Frost.weightedArea(.sIC), accuracy: 1e-12)
        XCTAssertEqual(lox, 1.21, accuracy: 0.01)
        let sIVB = Frost.coverage(station: 2950, time: 0)
        XCTAssertEqual(sIVB, Frost.arealDensity(station: 2950, time: 0) / lox, accuracy: 1e-12)
        XCTAssertEqual(sIVB, (90 / Frost.weightedArea(.sIVB)) / lox, accuracy: 1e-12)
        XCTAssertEqual(sIVB, 0.55, accuracy: 0.02)
        XCTAssertEqual(Frost.coverage(station: 1870, time: 0), 1)
        for station in stride(from: 600.0, through: 3200, by: 7) {
            for t in [-30.0, 0, 40, 100, 135.2, 170] {
                let expected = min(1, Frost.arealDensity(station: station, time: t) / lox)
                XCTAssertEqual(Frost.coverage(station: station, time: t), expected, accuracy: 1e-12, "\(station) at \(t)")
            }
        }
        // Half-way to CECO the S-IVB band has half its pad strength.
        let half = (Frost.firstMotion + Frost.centreCutoff) / 2
        XCTAssertEqual(Frost.coverage(station: 2950, time: half), sIVB / 2, accuracy: 1e-12)
    }

    /// The char factor grows with the heat load and is 1 at Apollo 7's
    /// 12,649 BTU/ft²; the heat shield is fully charred there; the tape burns
    /// more facing the flow.
    func testCharFactor() {
        XCTAssertEqual(Char.factor(heatLoad: 12_649 * 11_356.53), 1, accuracy: 1e-12)
        XCTAssertEqual(Char.factor(heatLoad: 0), 0)
        XCTAssertEqual(Char.factor(heatLoad: -5), 0)
        var last = -1.0, lastShield = -1.0, lastTape = -1.0
        for k in 0...300 {
            let q = Double(k) / 100 * Char.apollo7HeatLoad
            let f = Char.factor(heatLoad: q)
            XCTAssertGreaterThan(f, last)
            let shield = Char.heatShield(factor: f), tape = Char.afterbody(factor: f, exposure: 0.5)
            XCTAssertGreaterThanOrEqual(shield, lastShield)
            XCTAssertGreaterThanOrEqual(tape, lastTape)
            last = f
            lastShield = shield
            lastTape = tape
        }
        XCTAssertEqual(Char.heatShield(factor: 1), 1)
        XCTAssertEqual(Char.heatShield(factor: 2), 1)
        XCTAssertEqual(Char.afterbody(factor: 1, exposure: 1), 1)
        XCTAssertLessThan(Char.afterbody(factor: 1, exposure: 0), Char.afterbody(factor: 1, exposure: 1))
        XCTAssertEqual(Char.exposure(normal: Vec3(-1, 0, 0), flow: Vec3(1, 0, 0)), 1, accuracy: 1e-12)
        XCTAssertEqual(Char.exposure(normal: Vec3(1, 0, 0), flow: Vec3(1, 0, 0)), 0)
        XCTAssertEqual(Char.exposure(normal: Vec3(-1, 1, 0), flow: Vec3(2, 0, 0)), 0.5, accuracy: 1e-12)
        let silver = Char.tapeColour(burn: 0), burnt = Char.tapeColour(burn: 1)
        XCTAssertEqual(silver, PaintColour.kapton.linear)
        XCTAssertLessThan(burnt.r + burnt.g + burnt.b, silver.r + silver.g + silver.b)
    }

    /// A vessel's char factor is its own heat load's: none before entry.
    func testCharOfAVessel() {
        let cm = VesselLibrary.commandModule(.apollo7)
        XCTAssertEqual(Char.factor(cm), Char.factor(heatLoad: cm.heatLoad))
        XCTAssertEqual(Char.factor(cm), 0)
    }
}

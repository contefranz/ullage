import XCTest
@testable import OrbitScene

/// The octave spectrum shared by the plumes' and the launch cloud's
/// turbulence (`TurbulenceSpectrum`): the inertial range's amplitudes and
/// lifetimes, the footprint's cut-off, the variance the pixel resolves and
/// the structure function's 2/3 slope.
final class TurbulenceSpectrumTests: XCTestCase {
    let spectrum = TurbulenceSpectrum(largestCell: 8, largestLifetime: 0.5, maximumOctaves: 6)

    /// Each octave halves the cell, holds 2^(-1/3) of the amplitude above it
    /// and lives 2^(-2/3) as long.
    func testAmplitudesCellsAndLifetimes() {
        XCTAssertEqual(TurbulenceSpectrum.amplitude(octave: 0), 1)
        for k in 0..<8 {
            XCTAssertEqual(TurbulenceSpectrum.amplitude(octave: k + 1) / TurbulenceSpectrum.amplitude(octave: k),
                           pow(2, -1.0 / 3), accuracy: 1e-12)
            XCTAssertEqual(spectrum.cell(octave: k + 1) / spectrum.cell(octave: k), 0.5, accuracy: 1e-12)
            XCTAssertEqual(spectrum.lifetime(octave: k + 1) / spectrum.lifetime(octave: k), pow(2, -2.0 / 3),
                           accuracy: 1e-12)
        }
        XCTAssertEqual(TurbulenceSpectrum.amplitude(octave: 3), 0.5, accuracy: 1e-12, "an octave of three halvings")
        XCTAssertEqual(spectrum.lifetime(octave: 3), 0.5 / 4, accuracy: 1e-12)
        // Every octave's variance summed.
        let sum = (0..<200).reduce(0.0) { $0 + pow(TurbulenceSpectrum.amplitude(octave: $1), 2) }
        XCTAssertEqual(TurbulenceSpectrum.totalVariance, sum, accuracy: 1e-9)
        XCTAssertEqual(TurbulenceSpectrum.totalVariance, 2.702, accuracy: 1e-3)
    }

    /// An octave is drawn in full from four footprints across its cell,
    /// faded out at one and a half, smoothly; the count of octaves drawn
    /// follows, capped.
    func testFootprintCutOff() {
        XCTAssertEqual(TurbulenceSpectrum.footprintWeight(cell: 4, footprint: 1), 1)
        XCTAssertEqual(TurbulenceSpectrum.footprintWeight(cell: 1.5, footprint: 1), 0)
        XCTAssertEqual(TurbulenceSpectrum.footprintWeight(cell: 2.75, footprint: 1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(TurbulenceSpectrum.footprintWeight(cell: 1, footprint: 0), 1, "no footprint: everything")
        var last = 0.0
        for i in 0...100 {
            let w = TurbulenceSpectrum.footprintWeight(cell: 1 + 0.04 * Double(i), footprint: 1)
            XCTAssertGreaterThanOrEqual(w, last)
            last = w
        }
        // ℓ0 = 8 m: at a 1 m footprint the cells 8, 4 and 2 m (the last
        // faded) are drawn; at 6 m none; at a millimetre the cap.
        XCTAssertEqual(spectrum.octaves(footprint: 1), 3)
        XCTAssertEqual(spectrum.weight(octave: 2, footprint: 1), TurbulenceSpectrum.footprintWeight(cell: 2, footprint: 1))
        XCTAssertGreaterThan(spectrum.weight(octave: 2, footprint: 1), 0)
        XCTAssertEqual(spectrum.weight(octave: 3, footprint: 1), 0)
        XCTAssertEqual(spectrum.octaves(footprint: 6), 0)
        XCTAssertEqual(spectrum.octaves(footprint: 1e-3), 6)
        XCTAssertEqual(spectrum.weight(octave: 6, footprint: 1e-3), 0, "beyond the cap")
        for f in [0.01, 0.1, 0.3, 1, 2, 5, 6] {
            let n = spectrum.octaves(footprint: f)
            for k in 0..<8 where k >= n {
                XCTAssertEqual(spectrum.weight(octave: k, footprint: f), 0, "octave \(k) at \(f) m")
            }
        }
    }

    /// The variance drawn is the share the pixel resolves: all of the
    /// capped octaves' close up, less as the camera backs off, none once the
    /// largest eddies are under the cut-off; never more than every octave's.
    func testResolvedVarianceFallsWithTheFootprint() {
        let capped = (0..<6).reduce(0.0) { $0 + pow(TurbulenceSpectrum.amplitude(octave: $1), 2) }
            / TurbulenceSpectrum.totalVariance
        XCTAssertEqual(spectrum.resolvedVariance(footprint: 1e-4), capped, accuracy: 1e-12)
        XCTAssertEqual(spectrum.resolvedVariance(footprint: 10), 0)
        var last = 1.0
        for i in 0...60 {
            let f = 1e-3 * pow(1.2, Double(i))
            let v = spectrum.resolvedVariance(footprint: f)
            XCTAssertLessThanOrEqual(v, last + 1e-12, "at \(f) m")
            XCTAssertLessThanOrEqual(v, 1)
            last = v
        }
        // An uncapped spectrum resolves nearly all of it from far below its
        // finest drawn cell: what is left is below the cut-off.
        let deep = TurbulenceSpectrum(largestCell: 8, largestLifetime: 1, maximumOctaves: 40)
        XCTAssertEqual(deep.resolvedVariance(footprint: 1e-9), 1, accuracy: 1e-6)
    }

    /// The field's variance from unit-variance octaves (independent noise,
    /// sampled at random) is the resolved share.
    func testValueHoldsTheResolvedVariance() {
        var state: UInt32 = 3
        func gaussian() -> Double {
            let u1 = max(ParticleRandom.uniform(&state), 1e-12), u2 = ParticleRandom.uniform(&state)
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
        for footprint in [1e-3, 0.5, 1.0, 2.5] {
            var sum = 0.0, sum2 = 0.0
            let n = 40_000
            for _ in 0..<n {
                let v = spectrum.value(footprint: footprint) { _ in gaussian() }
                sum += v
                sum2 += v * v
            }
            let mean = sum / Double(n), variance = sum2 / Double(n) - mean * mean
            XCTAssertEqual(mean, 0, accuracy: 0.02)
            XCTAssertEqual(variance, spectrum.resolvedVariance(footprint: footprint),
                           accuracy: 0.03 * max(spectrum.resolvedVariance(footprint: footprint), 0.05),
                           "footprint \(footprint) m")
        }
        XCTAssertEqual(spectrum.value(footprint: 100) { _ in 1 }, 0, "nothing drawn")
    }

    /// With each octave's noise decorrelating over a fraction of its cell
    /// (an exponential correlation of integral length 0.39 cells, the
    /// volume noise's), the structure function rises as r^(2/3) between
    /// the finest and the largest octave: the k^(-5/3) spectrum's.
    func testStructureFunctionSlopeIsTwoThirds() {
        let deep = TurbulenceSpectrum(largestCell: 1_024, largestLifetime: 1, maximumOctaves: 20)
        let rho = { (s: Double) in exp(-s / 0.39) }
        // Over separations well inside the octaves' span (cells 1 mm to 1 km).
        let r0 = 0.05, r1 = 20.0
        let slope = log(deep.structureFunction(separation: r1, octaves: 20, correlation: rho)
                        / deep.structureFunction(separation: r0, octaves: 20, correlation: rho)) / log(r1 / r0)
        print(String(format: "TurbulenceSpectrumTests: structure-function slope %.3f", slope))
        XCTAssertEqual(slope, 2.0 / 3, accuracy: 0.05)
        // Beyond the largest cell it saturates at twice the variance.
        XCTAssertEqual(deep.structureFunction(separation: 1e7, octaves: 20, correlation: rho),
                       2 * (0..<20).reduce(0.0) { $0 + pow(TurbulenceSpectrum.amplitude(octave: $1), 2) }
                       / TurbulenceSpectrum.totalVariance, accuracy: 1e-6)
    }
}

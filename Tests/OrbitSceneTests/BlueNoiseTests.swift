import Foundation
import XCTest
@testable import OrbitScene

/// The dither's blue noise (track R1): every threshold once, and little
/// energy at low frequencies.
final class BlueNoiseTests: XCTestCase {
    func testEveryValueOnce() {
        let n = BlueNoise(size: 32)
        XCTAssertEqual(n.values.count, 1_024)
        let ranks = Set(n.values.map { Int(($0 * 1_024).rounded(.down)) })
        XCTAssertEqual(ranks, Set(0..<1_024))
        XCTAssertEqual(BlueNoise(size: 32).values, n.values, "seeded")
    }

    /// The mean of each 4×4 block stays near 0.5 (white noise spreads them
    /// more than twice as wide), and neighbours are anti-correlated.
    func testLowFrequenciesAreSuppressed() {
        let n = BlueNoise.shared
        XCTAssertEqual(n.size, 64)
        var deviations: [Double] = []
        for by in 0..<16 {
            for bx in 0..<16 {
                var s = 0.0
                for y in 0..<4 { for x in 0..<4 { s += Double(n[bx * 4 + x, by * 4 + y]) } }
                deviations.append(s / 16 - 0.5)
            }
        }
        let rms = (deviations.map { $0 * $0 }.reduce(0, +) / Double(deviations.count)).squareRoot()
        let white = (1.0 / 12 / 16).squareRoot()     // a 4×4 mean of uniform noise
        XCTAssertLessThan(rms, white / 2, "block means: \(rms) against white noise's \(white)")
        var c = 0.0
        for y in 0..<64 {
            for x in 0..<64 { c += Double(n[x, y] - 0.5) * Double(n[x + 1, y] - 0.5) }
        }
        XCTAssertLessThan(c / 4_096 / (1.0 / 12), -0.1, "neighbours anti-correlated")
    }
}

import Foundation
import XCTest
@testable import OrbitScene

/// The tone curves (track R1) at transcribed reference points, their shape,
/// and the LUT the GPU samples.
final class ToneCurveTests: XCTestCase {
    typealias RGB = Photometry.RGB

    func assertEqual(_ a: RGB, _ b: RGB, accuracy: Double, _ message: String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.r, b.r, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: accuracy, message, file: file, line: line)
    }

    /// AgX against three.js's `AgXToneMapping` (exposure 1) at commit
    /// 7b690028, evaluated outside the repo by a NumPy transliteration of
    /// the GLSL, its mat3s built column by column.
    func testAgXMatchesThreeJS() {
        let reference: [(RGB, RGB)] = [
            (RGB(0.18, 0.18, 0.18), RGB(0.214549, 0.214502, 0.214499)),
            (RGB(1, 1, 1), RGB(0.590229, 0.590136, 0.590102)),
            (RGB(0.5, 0.1, 0.02), RGB(0.464492, 0.146862, 0.057074)),
            (RGB(0.02, 0.3, 0.05), RGB(0.077756, 0.299818, 0.081917)),
            (RGB(0.05, 0.08, 0.9), RGB(0.098841, 0.200272, 0.655065)),
            (RGB(4, 2, 0.5), RGB(0.890336, 0.741185, 0.543421)),
            (RGB(10, 10, 10), RGB(0.955365, 0.955258, 0.955171)),
            (RGB(0.001, 0.002, 0.004), RGB(0.000063, 0.000362, 0.001089)),
            (RGB(1.5, 0.2, 1.2), RGB(0.731627, 0.367142, 0.648787)),
        ]
        for (input, output) in reference {
            assertEqual(ToneCurves.agx(input), output, accuracy: 1.5e-6, "AgX of \(input)")
        }
    }

    /// PBR Neutral against Khronos's own LUT (PBR_Neutral/pbrNeutral.cube,
    /// commit f5dc1011): 57³ points over log₂ input from -9 to 10, red
    /// fastest, linear output to 7 decimals.
    func testNeutralMatchesKhronosLUT() {
        func input(_ i: Int) -> Double { pow(2, Double(i) / 56 * 19 - 9) }
        let reference: [((Int, Int, Int), RGB)] = [
            ((25, 22, 18), RGB(0.6584084, 0.3049085, 0.0946366)),
            ((20, 12, 26), RGB(0.1858943, 0.0099781, 0.8293233)),
            ((14, 14, 14), RGB(0.0172633, 0.0172633, 0.0172633)),
            ((27, 27, 27), RGB(0.8967447, 0.8967447, 0.8967447)),
            ((30, 30, 30), RGB(0.9661878, 0.9661878, 0.9661878)),
            ((40, 25, 10), RGB(0.9975213, 0.778008, 0.7715599)),
            ((10, 35, 20), RGB(0.4829718, 0.9915271, 0.4965262)),
            ((47, 40, 30), RGB(0.9995308, 0.9578074, 0.9487918)),
            ((20, 20, 44), RGB(0.8992336, 0.8992336, 0.9990455)),
        ]
        for ((i, j, k), output) in reference {
            let c = ToneCurves.neutral(RGB(input(i), input(j), input(k)))
            assertEqual(c, output, accuracy: 1e-6, "Neutral at \((i, j, k))")
        }
        // The specification's promise: base colours from 0.08 to 0.8 come out 0.04 lower.
        assertEqual(ToneCurves.neutral(RGB(0.5, 0.3, 0.1)), RGB(0.46, 0.26, 0.06), accuracy: 1e-12)
    }

    /// Neutral round-trips through its analytic inverse.
    func testNeutralInverse() {
        var g = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let l = pow(2, Double.random(in: -8...6, using: &g))
            let c = RGB(l * Double.random(in: 0...1, using: &g), l * Double.random(in: 0...1, using: &g), l)
            let back = ToneCurves.neutralInverse(ToneCurves.neutral(c))
            assertEqual(back, c, accuracy: 1e-6 * max(1, l), "\(c)")
        }
    }

    /// Each curve is monotonic, keeps grey grey (AgX within
    /// its rounded Rec. 2020 matrices), stays in [0, 1], and takes black to
    /// black and very bright light to white.
    func testShape() {
        for curve in ToneCurve.allCases {
            var previous = curve.map(RGB(0, 0, 0))
            XCTAssertEqual(previous.luminance, 0, accuracy: 1e-4, "\(curve) black")
            for i in 1...200 {
                let v = pow(2, -14 + Double(i) * 0.1)
                let o = curve.map(RGB(v, v, v))
                XCTAssertGreaterThanOrEqual(o.g, previous.g - 1e-12, "\(curve) grey at \(v)")
                XCTAssertEqual(o.r, o.g, accuracy: 3e-4, "\(curve) stays grey at \(v)")
                XCTAssertEqual(o.b, o.g, accuracy: 3e-4, "\(curve) stays grey at \(v)")
                previous = o
            }
            XCTAssertGreaterThan(curve.map(RGB(1e4, 1e4, 1e4)).luminance, 0.99, "\(curve) white")
            // AgX: raising one channel never lowers its output. Neutral is a
            // min/max operator (raising the smallest channel lowers the
            // offset's share of the peak), so it is checked along brightness.
            var g = SystemRandomNumberGenerator()
            for _ in 0..<300 {
                let c = RGB(Double.random(in: 0...4, using: &g), Double.random(in: 0...4, using: &g),
                            Double.random(in: 0...4, using: &g))
                if curve == .agx {
                    let up = RGB(c.r * 1.05 + 1e-4, c.g, c.b)
                    XCTAssertGreaterThanOrEqual(curve.map(up).r, curve.map(c).r - 1e-9, "\(curve) \(c)")
                } else {
                    XCTAssertGreaterThanOrEqual(curve.map(c.scaled(by: 1.05)).luminance, curve.map(c).luminance - 1e-9,
                                                "\(curve) \(c)")
                }
                let o = curve.map(c)
                for x in [o.r, o.g, o.b] { XCTAssertTrue((0...1).contains(x), "\(curve) \(c) in range") }
            }
        }
    }

    /// The 33³ LUT over log₂ input follows AgX: under a step of 8-bit sRGB
    /// on average and under 2 steps for 99 % of colours (the worst are
    /// saturated colours far over white).
    func testAgXLUTAccuracy() {
        let lut = ToneLUT(.agx)
        XCTAssertEqual(lut.texels.count, 33 * 33 * 33 * 4)
        func srgb(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            return c <= 0.003_130_8 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        var errors: [Double] = []
        var g = SystemRandomNumberGenerator()
        for _ in 0..<3_000 {
            let l = pow(2, Double.random(in: -10...4, using: &g))
            let k = [Double.random(in: 0...1, using: &g), Double.random(in: 0...1, using: &g),
                     Double.random(in: 0...1, using: &g)].map { $0 * $0 }
            let m = max(k.max()!, 1e-6)
            let c = RGB(l * k[0] / m, l * k[1] / m, l * k[2] / m)
            let a = lut.sample(c), b = ToneCurves.agx(c)
            errors.append(255 * max(abs(srgb(a.r) - srgb(b.r)), abs(srgb(a.g) - srgb(b.g)), abs(srgb(a.b) - srgb(b.b))))
        }
        errors.sort()
        XCTAssertLessThan(errors.reduce(0, +) / Double(errors.count), 1)
        XCTAssertLessThan(errors[Int(Double(errors.count) * 0.99)], 2)
        // On the grid itself the LUT is the curve.
        let c = RGB(ToneLUT.input(7), ToneLUT.input(20), ToneLUT.input(13))
        assertEqual(lut.sample(c), ToneCurves.agx(c), accuracy: 1e-6)
    }
}

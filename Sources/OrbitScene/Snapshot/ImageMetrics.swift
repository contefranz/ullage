import Foundation

/// Comparisons of 8-bit sRGB images, as the golden tests make them: the
/// mean error in linear light and percentiles of CIE ΔE*ab (1976).
public enum ImageMetrics {
    /// Where red, green and blue sit in a 4-byte pixel.
    public enum Order {
        case rgba, bgra
        var indices: (r: Int, g: Int, b: Int) { self == .rgba ? (0, 1, 2) : (2, 1, 0) }
    }

    public struct Comparison: Equatable {
        /// Mean over pixels and channels of |a - b| in linear light (0...1).
        public var meanLinearError: Double
        /// ΔE*ab at the 99.5th percentile, and the largest.
        public var p995DeltaE: Double
        public var maxDeltaE: Double
        /// Pixels whose bytes differ at all.
        public var differingPixels: Int
        public var pixels: Int

        /// The golden criterion: mean linear error under 0.5 % and the 99.5th
        /// percentile of ΔE76 under 3.
        public var withinGoldenTolerance: Bool { meanLinearError < 0.005 && p995DeltaE < 3 }
    }

    /// sRGB code value to linear light (IEC 61966-2-1).
    public static let linear: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// CIELAB (D65 white) of an 8-bit sRGB colour.
    public static func lab(r: UInt8, g: UInt8, b: UInt8) -> (l: Double, a: Double, b: Double) {
        let R = linear[Int(r)], G = linear[Int(g)], B = linear[Int(b)]
        let x = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / 0.95047
        let y = 0.2126729 * R + 0.7151522 * G + 0.0721750 * B
        let z = (0.0193339 * R + 0.1191920 * G + 0.9503041 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24_389 ? cbrt(t) : (24_389.0 / 27 * t + 16) / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    public static func deltaE76(_ p: (UInt8, UInt8, UInt8), _ q: (UInt8, UInt8, UInt8)) -> Double {
        let a = lab(r: p.0, g: p.1, b: p.2), b = lab(r: q.0, g: q.1, b: q.2)
        return ((a.l - b.l) * (a.l - b.l) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    /// Compares two images of the same size, 4 bytes a pixel, alpha ignored.
    public static func compare(_ a: [UInt8], _ b: [UInt8], order: Order = .rgba) -> Comparison {
        precondition(a.count == b.count && a.count % 4 == 0, "images of different sizes")
        let (ri, gi, bi) = order.indices
        let pixels = a.count / 4
        var sum = 0.0, differing = 0
        var deltas: [Double] = []
        deltas.reserveCapacity(pixels / 16)
        var zero = 0
        for p in 0..<pixels {
            let i = 4 * p
            let pa = (a[i + ri], a[i + gi], a[i + bi]), pb = (b[i + ri], b[i + gi], b[i + bi])
            if pa == pb { zero += 1; continue }
            differing += 1
            sum += abs(linear[Int(pa.0)] - linear[Int(pb.0)]) + abs(linear[Int(pa.1)] - linear[Int(pb.1)])
                + abs(linear[Int(pa.2)] - linear[Int(pb.2)])
            deltas.append(deltaE76(pa, pb))
        }
        // The identical pixels are zeros of the distribution.
        deltas.sort()
        let rank = Int((0.995 * Double(pixels)).rounded(.up)) - 1     // 0-based index of the 99.5th percentile
        let p995 = rank < zero ? 0 : deltas[min(rank - zero, deltas.count - 1)]
        return Comparison(meanLinearError: sum / Double(3 * max(pixels, 1)), p995DeltaE: p995,
                          maxDeltaE: deltas.last ?? 0, differingPixels: differing, pixels: pixels)
    }

    /// A picture of the differences: black where the images agree, the
    /// absolute difference scaled by `gain` elsewhere, RGBA.
    public static func difference(_ a: [UInt8], _ b: [UInt8], order: Order = .rgba, gain: Double = 8) -> [UInt8] {
        precondition(a.count == b.count, "images of different sizes")
        let (ri, gi, bi) = order.indices
        var out = [UInt8](repeating: 255, count: a.count)
        for p in 0..<(a.count / 4) {
            let i = 4 * p
            for (k, c) in [ri, gi, bi].enumerated() {
                out[i + k] = UInt8(min(255, Double(abs(Int(a[i + c]) - Int(b[i + c]))) * gain))
            }
        }
        return out
    }
}

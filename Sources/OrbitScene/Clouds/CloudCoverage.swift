import Foundation

/// Track C2: how much of the sky the march's clouds cover. A layer is cloud
/// where Schneider's low-frequency shape (`CloudCoverage.shapeValue`, from
/// the shape volume) exceeds a threshold θ; the threshold for ERA5's cover
/// c is the shape value's (1 − c) quantile, so that a fraction c of the
/// layer is cloud and the drawn cover is ERA5's (Schneider's remap(…, 1 −
/// c, 1) draws a different fraction, since the shape is not uniform).
public enum CloudCoverage {
    /// Schneider and Vos 2015's base shape from a shape-volume texel: the
    /// Perlin-Worley (r) dilated by the Worley fBm (g, b, a), in [0, 1].
    public static func shapeValue(_ t: (Float, Float, Float, Float)) -> Float {
        let fbm = t.1 * 0.625 + t.2 * 0.25 + t.3 * 0.125
        let lo = fbm - 1
        return min(max((t.0 - lo) / max(1 - lo, 1e-6), 0), 1)
    }

    /// The thresholds θ(c) at c = 0, 1/32 ... 1: the shape values' quantiles
    /// over a `grid`³ lattice of the shape volume's texels (every
    /// `shapeSize / grid`-th).
    public static func thresholds(grid: Int = 24) -> [Double] {
        let step = max(CloudNoise.shapeSize / grid, 1)
        var values: [Float] = []
        values.reserveCapacity(grid * grid * grid)
        for z in stride(from: 0, to: CloudNoise.shapeSize, by: step) {
            for y in stride(from: 0, to: CloudNoise.shapeSize, by: step) {
                for x in stride(from: 0, to: CloudNoise.shapeSize, by: step) {
                    values.append(shapeValue(CloudNoise.shapeTexel(x, y, z)))
                }
            }
        }
        values.sort()
        return (0...32).map { k -> Double in
            let c = Double(k) / 32
            if c <= 0 { return 1 }
            if c >= 1 { return 0 }
            let at = (1 - c) * Double(values.count - 1)
            let i = Int(at), f = at - Double(i)
            let a = Double(values[i]), b = Double(values[min(i + 1, values.count - 1)])
            return a + f * (b - a)
        }
    }

    /// The renderer's thresholds, computed once.
    public static let standard: [Double] = thresholds()

    /// θ(c), linear between the table's entries, as the shader reads it.
    public static func threshold(_ cover: Double, table: [Double] = standard) -> Double {
        let x = min(max(cover, 0), 1) * 32
        let i = min(Int(x), 31)
        return table[i] + (x - Double(i)) * (table[i + 1] - table[i])
    }
}

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
        lookup(cover, table)
    }

    /// A 33-entry table over c = 0, 1/32 ... 1, linear between entries.
    public static func lookup(_ cover: Double, _ table: [Double]) -> Double {
        let x = min(max(cover, 0), 1) * 32
        let i = min(Int(x), 31)
        return table[i] + (x - Double(i)) * (table[i + 1] - table[i])
    }

    // MARK: Density and the far layer

    /// The cirrus's fibres from a shape-volume texel: the Worley fBm of 8 and
    /// 16 cells (b, a), stretched along the high wind by the shader.
    public static func cirrusValue(_ t: (Float, Float, Float, Float)) -> Float { 0.7 * t.2 + 0.3 * t.3 }

    /// The march's height profiles at a height fraction h of the layer
    /// (CloudShaders' cloud_profileLow and cloud_profileMid).
    public static func profile(layer: Int, _ h: Double) -> Double {
        func ramp(_ x: Double) -> Double { min(max(x, 0), 1) }
        return layer == 0 ? ramp(h / 0.08) * ramp((1 - h) / 0.6) : ramp(h / 0.2) * ramp((1 - h) / 0.45)
    }

    /// The march's density in [0, 1] at a texel of shape value v, height
    /// fraction h and threshold θ (cloud_baseDensity, before the detail).
    public static func density(_ v: Double, layer: Int, height h: Double, threshold theta: Double) -> Double {
        min(max((v * profile(layer: layer, h) - theta) / max(1 - theta, 1e-6), 0), 1)
    }

    /// The tables that tie the march, the far layer and the cirrus to C1's
    /// layer model, each over c = 0, 1/32 ... 1:
    /// - `densityScale[layer]`: 1 over the march's mean density where there
    ///   is cloud, so that its in-cloud extinction averages C1's β (the
    ///   thresholded shape alone averages 0.1-0.2 of it);
    /// - `cirrusThreshold` and `cirrusScale`: the cirrus's own coverage
    ///   thresholds (the quantiles of `cirrusValue`) and 1 over its mean
    ///   remapped value where there is cirrus, so its in-cloud optical depth
    ///   averages C1's.
    public struct Statistics: Equatable {
        public var densityScale: [[Double]]
        public var cirrusThreshold: [Double]
        public var cirrusScale: [Double]
    }

    /// The statistics over columns of the shape volume (what
    /// CloudCoverageTables.swift bakes): `levels` texels up
    /// (both layers span about 12 of the volume's 128: 1,500 m of the low
    /// noise's 16,384 m period, 3,000 m of the mid's 32,768 m), on a lattice
    /// every `step` texels across and `stepUp` up.
    public static func statistics(step: Int = 8, stepUp: Int = 32, levels: Int = 12,
                                  thresholds: [Double] = standard) -> Statistics {
        let n = CloudNoise.shapeSize
        var columns: [[(shape: Double, cirrus: Double)]] = []
        for x in stride(from: 0, to: n, by: step) {
            for y in stride(from: 0, to: n, by: step) {
                for z0 in stride(from: 0, to: n, by: stepUp) {
                    columns.append((0..<levels).map { k in
                        let t = CloudNoise.shapeTexel(x, y, (z0 + k) % n)
                        return (Double(shapeValue(t)), Double(cirrusValue(t)))
                    })
                }
            }
        }
        var densityScale: [[Double]] = [[], []]
        for layer in 0..<2 {
            for k in 0...32 {
                let theta = thresholds[k]
                var sum = 0.0, count = 0
                for column in columns {
                    for (j, v) in column.enumerated() {
                        let d = density(v.shape, layer: layer, height: Double(j) / Double(levels - 1), threshold: theta)
                        if d > 0 { sum += d; count += 1 }
                    }
                }
                densityScale[layer].append(count > 0 ? Double(count) / sum : .nan)
            }
        }
        // The cirrus.
        let cirrus = columns.flatMap { $0.map(\.cirrus) }.sorted()
        var cirrusThreshold: [Double] = [], cirrusScale: [Double] = []
        for k in 0...32 {
            let c = Double(k) / 32
            let theta: Double
            if c <= 0 { theta = 1 } else if c >= 1 { theta = 0 } else {
                let at = (1 - c) * Double(cirrus.count - 1)
                let i = Int(at), f = at - Double(i)
                theta = cirrus[i] + f * (cirrus[min(i + 1, cirrus.count - 1)] - cirrus[i])
            }
            let cloudy = cirrus.filter { $0 > theta }.map { ($0 - theta) / max(1 - theta, 1e-6) }
            cirrusThreshold.append(theta)
            cirrusScale.append(cloudy.isEmpty ? .nan : Double(cloudy.count) / cloudy.reduce(0, +))
        }
        // No cloud at c = 0: its entries are the first cloudy one's, so the
        // tables stay smooth where they are read.
        func fill(_ t: [Double]) -> [Double] {
            guard let first = t.first(where: { !$0.isNaN }) else { return t.map { _ in 1 } }
            return t.map { $0.isNaN ? first : $0 }
        }
        return Statistics(densityScale: densityScale.map(fill), cirrusThreshold: cirrusThreshold,
                          cirrusScale: fill(cirrusScale))
    }

    // The renderer's are baked: `standardStatistics`, CloudCoverageTables.swift.
}

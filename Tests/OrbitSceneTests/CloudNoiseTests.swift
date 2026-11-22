import XCTest
@testable import OrbitScene

/// Track C2's procedural noise: tiling, range, Worley against a brute-force
/// search, and the curl map free of divergence.
final class CloudNoiseTests: XCTestCase {
    /// A fixed sequence of points in [0, 1)³ (a splitmix64 stream).
    private func points(_ n: Int) -> [(Float, Float, Float)] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
        }
        return (0..<n).map { _ in (next(), next(), next()) }
    }

    func testPerlinTilesAndVanishesOnTheLattice() {
        for (x, y, z) in points(200) {
            let p = (x * 4, y * 4, z * 4)
            let a = CloudNoise.perlin(p.0, p.1, p.2, period: 4, seed: 9)
            XCTAssertEqual(a, CloudNoise.perlin(p.0 + 4, p.1, p.2, period: 4, seed: 9), accuracy: 1e-5)
            XCTAssertEqual(a, CloudNoise.perlin(p.0, p.1 - 4, p.2 + 8, period: 4, seed: 9), accuracy: 1e-5)
        }
        for i in 0..<4 {
            XCTAssertEqual(CloudNoise.perlin(Float(i), 2, Float(3 - i), period: 4, seed: 9), 0, accuracy: 1e-7)
        }
    }

    func testPerlinRangeAndMean() {
        var lo: Float = 1, hi: Float = -1, sum: Float = 0
        let samples = points(4000)
        for (x, y, z) in samples {
            let v = CloudNoise.perlin(x * 8, y * 8, z * 8, period: 8, seed: 3)
            lo = min(lo, v)
            hi = max(hi, v)
            sum += v
        }
        XCTAssertGreaterThan(lo, -1.05)
        XCTAssertLessThan(hi, 1.05)
        XCTAssertGreaterThan(hi - lo, 1.0, "the noise spans most of its range")
        XCTAssertEqual(sum / Float(samples.count), 0, accuracy: 0.03)
        let fbm = samples.map { CloudNoise.perlinFBM($0.0, $0.1, $0.2, basePeriod: 4, octaves: 5, seed: 3) }
        XCTAssertTrue(fbm.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(fbm.reduce(0, +) / Float(fbm.count), 0.5, accuracy: 0.03)
    }

    /// Worley's F1 against the nearest of every feature point of one
    /// period and its 26 periodic images.
    func testWorleyAgainstBruteForce() {
        let cells: Int32 = 4, seed: UInt32 = 21
        var features: [(Float, Float, Float)] = []
        for k in 0..<cells {
            for j in 0..<cells {
                for i in 0..<cells {
                    let h = CloudNoise.cellHash(i, j, k, period: cells, seed: seed)
                    features.append((Float(i) + CloudNoise.unit(h.0), Float(j) + CloudNoise.unit(h.1),
                                     Float(k) + CloudNoise.unit(h.2)))
                }
            }
        }
        let n = Float(cells)
        for (x, y, z) in points(300) {
            var best = Float.greatestFiniteMagnitude
            for f in features {
                for a in -1...1 {
                    for b in -1...1 {
                        for c in -1...1 {
                            let dx = f.0 + Float(a) * n - x * n, dy = f.1 + Float(b) * n - y * n
                            let dz = f.2 + Float(c) * n - z * n
                            best = min(best, dx * dx + dy * dy + dz * dz)
                        }
                    }
                }
            }
            let expected = min(max(1 - best.squareRoot(), 0), 1)
            XCTAssertEqual(CloudNoise.worley(x, y, z, cells: cells, seed: seed), expected, accuracy: 1e-5)
            XCTAssertEqual(CloudNoise.worley(x + 1, y - 1, z + 2, cells: cells, seed: seed), expected, accuracy: 1e-4,
                           "tiles every unit")
        }
    }

    func testPerlinWorleyBlend() {
        XCTAssertEqual(CloudNoise.perlinWorley(perlin: 0.3, worley: 0), 0.3, accuracy: 1e-7)
        XCTAssertEqual(CloudNoise.perlinWorley(perlin: 0.3, worley: 1), 0.65, accuracy: 1e-7)
        for (p, w, _) in points(200) {
            let v = CloudNoise.perlinWorley(perlin: p, worley: w)
            XCTAssertTrue(v >= p && v <= 1, "dilates Perlin")
        }
    }

    /// The volumes repeat across their edges: the texel past the last is
    /// the first.
    func testVolumesTile() {
        let n = CloudNoise.shapeSize
        let s = 1 / Float(n)
        for (y, z) in [(3, 77), (120, 5)] {
            let u = (Float(n) + 0.5) * s, v = (Float(y) + 0.5) * s, w = (Float(z) + 0.5) * s
            let past = CloudNoise.perlinFBM(u, v, w, basePeriod: CloudNoise.shapePerlinPeriod,
                                            octaves: CloudNoise.shapePerlinOctaves, seed: CloudNoise.shapeSeed)
            let first = CloudNoise.perlinFBM(0.5 * s, v, w, basePeriod: CloudNoise.shapePerlinPeriod,
                                             octaves: CloudNoise.shapePerlinOctaves, seed: CloudNoise.shapeSeed)
            XCTAssertEqual(past, first, accuracy: 1e-5)
            let texel = CloudNoise.shapeTexel(0, y, z)
            XCTAssertTrue([texel.0, texel.1, texel.2, texel.3].allSatisfy { $0 >= 0 && $0 <= 1 })
        }
        let d = CloudNoise.detailTexel(31, 0, 16)
        XCTAssertTrue([d.0, d.1, d.2].allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// The curl of a stream function has no divergence: at random points
    /// the map's divergence, by the same half-texel differences, vanishes
    /// beside its gradients (a swapped component or sign would make it as
    /// large as they are); and it seldom clips at ±1.
    func testCurlMapIsFreeOfDivergence() {
        let h = 0.5 / Float(CloudNoise.curlSize)
        func curl(_ u: Float, _ v: Float) -> (Float, Float) {
            let dv = (CloudNoise.streamFunction(u, v + h) - CloudNoise.streamFunction(u, v - h)) / (2 * h)
            let du = (CloudNoise.streamFunction(u + h, v) - CloudNoise.streamFunction(u - h, v)) / (2 * h)
            return (dv * CloudNoise.curlScale, -du * CloudNoise.curlScale)
        }
        var divergence: Float = 0, gradient: Float = 0
        for (u, v, _) in points(300) {
            let ex = (curl(u + h, v).0 - curl(u - h, v).0) / (2 * h)
            let ey = (curl(u, v + h).1 - curl(u, v - h).1) / (2 * h)
            divergence += abs(ex + ey)
            gradient += abs(ex) + abs(ey)
        }
        XCTAssertLessThan(divergence / gradient, 1e-3, "divergence against the gradients")
        var clipped = 0
        for y in stride(from: 0, to: CloudNoise.curlSize, by: 4) {
            for x in stride(from: 0, to: CloudNoise.curlSize, by: 4) {
                let c = curl((Float(x) + 0.5) / Float(CloudNoise.curlSize), (Float(y) + 0.5) / Float(CloudNoise.curlSize))
                if abs(c.0) > 1 || abs(c.1) > 1 { clipped += 1 }
                let t = CloudNoise.curlTexel(x, y)
                XCTAssertTrue(abs(t.0) <= 1 && abs(t.1) <= 1)
            }
        }
        XCTAssertLessThan(clipped, 1 + (CloudNoise.curlSize / 4) * (CloudNoise.curlSize / 4) / 100, "clipped at ±1")
    }

    func testTexelEncoding() {
        XCTAssertEqual(CloudNoise.unorm8(0), 0)
        XCTAssertEqual(CloudNoise.unorm8(1), 255)
        XCTAssertEqual(CloudNoise.unorm8(0.5), 128)
        XCTAssertEqual(CloudNoise.snorm8(-1), -127)
        XCTAssertEqual(CloudNoise.snorm8(1), 127)
    }
}

/// Track C2's coverage thresholds: the drawn fraction of a layer is ERA5's
/// cover.
final class CloudCoverageTests: XCTestCase {
    func testDrawnCoverIsTheCover() {
        let table = CloudCoverage.standard
        XCTAssertEqual(table.count, 33)
        XCTAssertEqual(table.first, 1)
        XCTAssertEqual(table.last, 0)
        XCTAssertTrue(zip(table, table.dropFirst()).allSatisfy { $0 >= $1 }, "falls as the cover grows")
        // Texels off the table's lattice.
        var values: [Double] = []
        for z in stride(from: 3, to: CloudNoise.shapeSize, by: 11) {
            for y in stride(from: 5, to: CloudNoise.shapeSize, by: 11) {
                for x in stride(from: 1, to: CloudNoise.shapeSize, by: 11) {
                    values.append(Double(CloudCoverage.shapeValue(CloudNoise.shapeTexel(x, y, z))))
                }
            }
        }
        for c in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let theta = CloudCoverage.threshold(c)
            let drawn = Double(values.filter { $0 > theta }.count) / Double(values.count)
            XCTAssertEqual(drawn, c, accuracy: 0.03, "cover \(c)")
        }
    }

    /// Columns of the shape volume off the baked statistics' lattice, 12
    /// texels up. Clouds are features some 30 texels across, so a sample's
    /// own noise is a few per cent at partial cover, more at 1/10.
    static let columns: [[(Float, Float, Float, Float)]] = {
        var columns: [[(Float, Float, Float, Float)]] = []
        for x in stride(from: 1, to: CloudNoise.shapeSize, by: 5) {
            for y in stride(from: 3, to: CloudNoise.shapeSize, by: 5) {
                for z0 in stride(from: 9, to: CloudNoise.shapeSize, by: 23) {
                    columns.append((0..<12).map { CloudNoise.shapeTexel(x, y, (z0 + $0) % CloudNoise.shapeSize) })
                }
            }
        }
        return columns
    }()

    /// The cirrus has its own thresholds: its drawn fraction is the cover
    /// (with the shape's, 4/10 cirrus drew 0.01 % of the sky).
    func testCirrusDrawnCoverIsTheCover() {
        let st = CloudCoverage.standardStatistics
        XCTAssertEqual(st.cirrusThreshold.count, 33)
        let values = Self.columns.flatMap { $0.map { Double(CloudCoverage.cirrusValue($0)) } }
        for c in [0.1, 0.4, 0.7, 0.9] {
            let theta = CloudCoverage.lookup(c, st.cirrusThreshold)
            let cloudy = values.filter { $0 > theta }
            XCTAssertEqual(Double(cloudy.count) / Double(values.count), c, accuracy: 0.04, "cover \(c)")
            // Its in-cloud optical depth averages C1's.
            let mean = cloudy.map { ($0 - theta) / (1 - theta) }.reduce(0, +) / Double(cloudy.count)
            XCTAssertEqual(mean * CloudCoverage.lookup(c, st.cirrusScale), 1, accuracy: c < 0.2 ? 0.15 : 0.08,
                           "cover \(c)")
        }
    }

    /// The march's cloudy columns hold a fraction of C1's optical depth (β ×
    /// the layer's depth), as CloudCoverageTables bakes it: the mid layer's
    /// lenses about a twelfth at low cover, more as they merge; the low layer
    /// a quarter to a third. The far mid layer takes it (an independent
    /// sample of columns).
    func testColumnDepthOfTheMarchsClouds() {
        let st = CloudCoverage.standardStatistics
        XCTAssertEqual(st.columnDepth.count, 2)
        for layer in 0..<2 {
            for c in [0.2, 0.5, 0.8] {
                let theta = CloudCoverage.threshold(c), scale = CloudCoverage.lookup(c, st.densityScale[layer])
                var depths: [Double] = []
                for column in Self.columns {
                    let d = column.enumerated().map { j, t in
                        CloudCoverage.density(Double(CloudCoverage.shapeValue(t)), layer: layer, height: Double(j) / 11,
                                              threshold: theta)
                    }
                    if d.contains(where: { $0 > 0 }) { depths.append(d.reduce(0, +) / 12 * scale) }
                }
                let sample = depths.reduce(0, +) / Double(depths.count)
                XCTAssertEqual(CloudCoverage.lookup(c, st.columnDepth[layer]), sample, accuracy: 0.25 * sample,
                               "layer \(layer), cover \(c)")
            }
        }
        XCTAssertLessThan(CloudCoverage.lookup(0.3, st.columnDepth[1]), 0.15, "the mid layer's lenses are thin")
        XCTAssertGreaterThan(CloudCoverage.lookup(0.3, st.columnDepth[0]), 0.2)
    }

    /// The march's density, scaled, averages C1's in-cloud extinction where
    /// there is cloud, at any cover (unscaled it averaged 0.1-0.2 of it).
    func testMarchDensityAveragesTheLayerModel() {
        let st = CloudCoverage.standardStatistics
        for layer in 0..<2 {
            for c in [0.1, 0.3, 0.5, 0.7, 0.9] {
                let theta = CloudCoverage.threshold(c), scale = CloudCoverage.lookup(c, st.densityScale[layer])
                var sum = 0.0, count = 0
                for column in Self.columns {
                    for (j, t) in column.enumerated() {
                        let d = CloudCoverage.density(Double(CloudCoverage.shapeValue(t)), layer: layer,
                                                      height: Double(j) / 11, threshold: theta)
                        if d > 0 { sum += d * scale; count += 1 }
                    }
                }
                XCTAssertEqual(sum / Double(count), 1, accuracy: c < 0.2 ? 0.15 : 0.08, "layer \(layer), cover \(c)")
                XCTAssertGreaterThan(scale, 3, "the thresholded shape alone is far thinner than C1's clouds")
            }
        }
    }
}

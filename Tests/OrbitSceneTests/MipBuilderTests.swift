import Foundation
import XCTest
@testable import OrbitScene

/// The mip chains: box means that keep a map's mean, and Toksvig's
/// roughness widening against the second moment of the normals it
/// replaces.
final class MipBuilderTests: XCTestCase {
    func testLevelCountsAndSizes() {
        XCTAssertEqual(MipBuilder.levelCount(width: 8, height: 8), 4)
        XCTAssertEqual(MipBuilder.levelCount(width: 5, height: 3), 3)
        XCTAssertEqual(MipBuilder.levelCount(width: 1, height: 1), 1)
        let image = MipBuilder.Image(width: 5, height: 3, channels: 1, pixels: (0..<15).map(Float.init))
        let levels = MipBuilder.mips(image)
        XCTAssertEqual(levels.map { [$0.width, $0.height] }, [[5, 3], [2, 1], [1, 1]])
    }

    /// Power-of-two box means keep the map's mean at every level.
    func testColourMipsKeepTheMean() {
        var rng = AmbientOcclusion.SplitMix64(state: 3)
        let w = 32, h = 16
        let pixels = (0..<(w * h * 3)).map { _ in Float(rng.unit()) }
        let levels = MipBuilder.mips(MipBuilder.Image(width: w, height: h, channels: 3, pixels: pixels))
        XCTAssertEqual(levels.count, 6)
        for c in 0..<3 {
            let mean = stride(from: c, to: pixels.count, by: 3).map { pixels[$0] }.reduce(0, +) / Float(w * h)
            for l in levels {
                let m = stride(from: c, to: l.pixels.count, by: 3).map { l.pixels[$0] }.reduce(0, +)
                    / Float(l.width * l.height)
                XCTAssertEqual(m, mean, accuracy: 1e-5)
            }
        }
    }

    /// A flat map keeps its normal and roughness all the way down.
    func testFlatNormalsKeepTheirRoughness() {
        let w = 16
        let levels = MipBuilder.normalRoughnessMips(width: w, height: w,
                                                    normals: [Float]((0..<(w * w)).flatMap { _ in [0, 0, 1] }),
                                                    roughness: [Float](repeating: 0.3, count: w * w))
        XCTAssertEqual(levels.count, 5)
        for l in levels {
            for r in l.roughness { XCTAssertEqual(r, 0.3, accuracy: 1e-6) }
            for i in 0..<(l.width * l.height) { XCTAssertEqual(l.normals[3 * i + 2], 1, accuracy: 1e-6) }
        }
    }

    /// Stripes of normals tilted ±θ have a slope variance of tan² θ, which
    /// a Beckmann-like lobe holds as α² (α²/2 per axis, summed over the
    /// two): the first mip, which averages them, must widen α² by about
    /// that, and keep the mean normal on the axis.
    func testToksvigWideningMatchesTheSlopeVariance() {
        for degrees in [2.0, 5.0, 10.0] {
            let t = Float(degrees * Double.pi / 180)
            let w = 8
            var normals: [Float] = []
            for _ in 0..<w {
                for x in 0..<w { normals += [x % 2 == 0 ? sin(t) : -sin(t), 0, cos(t)] }
            }
            let r0: Float = 0.2
            let levels = MipBuilder.normalRoughnessMips(width: w, height: w, normals: normals,
                                                        roughness: [Float](repeating: r0, count: w * w))
            let l1 = levels[1]
            XCTAssertEqual(l1.normals[2], 1, accuracy: 1e-6)
            let added = pow(l1.roughness[0], 4) - pow(r0, 4)
            let slopeVariance = tan(t) * tan(t)
            XCTAssertEqual(added, slopeVariance, accuracy: 0.05 * slopeVariance, "θ \(degrees)°")
            // Coarser levels see the same spread: no further widening.
            XCTAssertEqual(levels.last!.roughness[0], l1.roughness[0], accuracy: 1e-5)
        }
    }

    /// A bumpy map's mips grow rougher level by level, never smoother.
    func testBumpyMapGetsRougherDownTheChain() {
        var rng = AmbientOcclusion.SplitMix64(state: 11)
        let w = 64
        var normals: [Float] = []
        for _ in 0..<(w * w) {
            let x = Float((rng.unit() - 0.5) * 0.4), y = Float((rng.unit() - 0.5) * 0.4)
            let z = (1 - x * x - y * y).squareRoot()
            normals += [x, y, z]
        }
        let levels = MipBuilder.normalRoughnessMips(width: w, height: w, normals: normals,
                                                    roughness: [Float](repeating: 0.1, count: w * w))
        var previous: Float = 0.1
        for l in levels.dropFirst() {
            let mean = l.roughness.reduce(0, +) / Float(l.roughness.count)
            XCTAssertGreaterThanOrEqual(mean, previous - 1e-6)
            previous = mean
        }
        XCTAssertGreaterThan(previous, 0.3, "the 1×1 level carries the map's whole spread")
        XCTAssertEqual(MipBuilder.toksvigVariance(meanLength: 0), 1)
        XCTAssertEqual(MipBuilder.toksvigVariance(meanLength: 1), 0)
    }
}

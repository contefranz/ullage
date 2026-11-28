import Foundation
import XCTest
@testable import OrbitCore
@testable import OrbitScene

/// R6's effect-slot maths: the half-resolution depth, the depth-aware
/// upsample, front depths, weighted-blended OIT and the layer order.
final class EffectSlotsTests: XCTestCase {
    typealias P = EffectSlots.Premultiplied

    func testTargetSizeRoundsUp() {
        XCTAssertTrue(EffectSlots.targetSize(width: 3024, height: 1964, scale: 2) == (1512, 982))
        XCTAssertTrue(EffectSlots.targetSize(width: 641, height: 401, scale: 2) == (321, 201))
        XCTAssertTrue(EffectSlots.targetSize(width: 641, height: 401, scale: 1) == (641, 401))
        XCTAssertTrue(EffectSlots.targetSize(width: 0, height: 0, scale: 2) == (1, 1))
    }

    /// Nearest on even texels, farthest on odd ones, so every 2×2
    /// neighbourhood of texels holds both extremes.
    func testHalfResDepthIsACheckerboardOfMinAndMax() {
        let quad = [0.1, 0.5, 0, 0.3]
        XCTAssertTrue(EffectSlots.halfResDepth(quad, x: 0, y: 0) == (0.5, 0))
        XCTAssertTrue(EffectSlots.halfResDepth(quad, x: 1, y: 0) == (0, 0.5))
        XCTAssertTrue(EffectSlots.halfResDepth(quad, x: 1, y: 1) == (0.5, 0))
        XCTAssertTrue(EffectSlots.halfResDepth([0.2], x: 3, y: 0) == (0.2, 0.2), "a lone pixel at the edge")
        for x in 0..<4 {
            for y in 0..<4 {
                let tests = [(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)].map {
                    EffectSlots.halfResDepth(quad, x: $0.0, y: $0.1).test
                }
                XCTAssertEqual(Set(tests), [0.5, 0], "texels \(x), \(y)")
            }
        }
    }

    /// At half resolution a pixel's centre sits a quarter texel from four
    /// texel centres (9, 3, 3 and 1 sixteenths); at full resolution the
    /// footprint is the pixel's own texel.
    func testUpsampleFootprint() {
        let half = EffectSlots.upsampleFootprint(pixelX: 5, pixelY: 8, scale: 2, width: 10, height: 10)
        XCTAssertEqual(half.texels.map(\.x), [2, 3, 2, 3])
        XCTAssertEqual(half.texels.map(\.y), [3, 3, 4, 4])
        XCTAssertEqual(half.bilinear, [3.0 / 16, 1.0 / 16, 9.0 / 16, 3.0 / 16])
        let full = EffectSlots.upsampleFootprint(pixelX: 5, pixelY: 8, scale: 1, width: 10, height: 10)
        XCTAssertEqual(full.texels.first!.x, 5)
        XCTAssertEqual(full.texels.first!.y, 8)
        XCTAssertEqual(full.bilinear, [1, 0, 0, 0])
        let corner = EffectSlots.upsampleFootprint(pixelX: 0, pixelY: 0, scale: 2, width: 10, height: 10)
        XCTAssertEqual(corner.texels.map(\.x), [0, 0, 0, 0], "clamped at the edge")
        XCTAssertEqual(corner.bilinear.reduce(0, +), 1, accuracy: 1e-15)
    }

    func testUpsampleWeights() {
        let bilinear = [9.0 / 16, 3.0 / 16, 3.0 / 16, 1.0 / 16]
        // A continuous surface: bilinear.
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: [0.010, 0.0103, 0.0098, 0.0101],
                                                   depth: 0.01, tolerance: 0.1), bilinear)
        // An edge: the pixel on the vessel (near), two texels on the sky
        // behind: Kopf's weights, the bilinear ones renormalised over the
        // two on the vessel.
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: [0, 0.0102, 0, 0.0099],
                                                   depth: 0.01, tolerance: 0.1), [0, 0.75, 0, 0.25])
        // A sky pixel next to the vessel: over the two sky texels.
        let nearTexel3 = [1.0 / 16, 3.0 / 16, 3.0 / 16, 9.0 / 16]
        let sky = EffectSlots.upsampleWeights(bilinear: nearTexel3, depths: [0, 0.01, 0.01, 0], depth: 0, tolerance: 0.1)
        XCTAssertEqual(sky[0], 0.1, accuracy: 1e-15)
        XCTAssertEqual(sky[3], 0.9, accuracy: 1e-15)
        XCTAssertEqual(sky[1] + sky[2], 0)
        // None within the tolerance: the nearest in depth alone, ties going
        // to the larger bilinear weight, then to the lower index.
        let none = EffectSlots.reconstruction(bilinear: bilinear, depths: [0.04, 0.005, 0.04, 0.0025], depth: 0.01,
                                              tolerance: 0.1, ended: [false, false, false, false])
        XCTAssertEqual(none.weights, [0, 1, 0, 0])
        XCTAssertEqual(none.kind, .nearest)
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: [0.02, 0.005, 0.005, 0.04],
                                                   depth: 0.01, tolerance: 0.1), [1, 0, 0, 0], "the larger weight")
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: [0.25, 0.25, 0.25, 0.25], depths: [0.04, 0.005, 0.02, 0.04],
                                                   depth: 0.01, tolerance: 0.1), [0, 1, 0, 0], "the lower index")
        // The tolerance is relative, whatever the distance.
        let far = [1e-6, 1.05e-6, 0.97e-6, 1e-6]
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: far, depth: 1e-6, tolerance: 0.1),
                       bilinear)
        // Texels whose effects ended in front of both depths match whatever
        // their depth: bilinear across an edge they are wholly in front of.
        XCTAssertEqual(EffectSlots.reconstruction(bilinear: bilinear, depths: [0, 0.0102, 0, 0.0099], depth: 0.01,
                                                  tolerance: 0.1, ended: [true, false, true, false]).kind, .bilinear)
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: [0, 0.03, 0, 0.0099], depth: 0.01,
                                                   tolerance: 0.1, ended: [true, false, false, false]),
                       [0.9, 0, 0, 0.1])
    }

    /// LR0's test: in front of a ramp whose depth changes 30 % a row (the
    /// ocean toward the horizon), an effect that ended in front of it is
    /// reconstructed exactly bilinearly at every pixel, from the writers'
    /// codes, for each layer; without them (depth alone) most pixels are
    /// not. An effect the ramp cuts is not let through on its codes.
    func testExactlyBilinearInFrontOfARamp() {
        let n = 48, near = 0.25
        // Linear depth 100 m · 1.3^(n - 1 - row), farthest at the top; z reversed.
        func linear(_ y: Int) -> Double { 100 * pow(1.3, Double(n - 1 - y)) }
        func z(_ y: Int) -> Double { near / linear(y) }
        let (w, h) = EffectSlots.targetSize(width: n, height: n, scale: 2)
        var test = [[Double]](repeating: [Double](repeating: 0, count: h), count: w)
        for x in 0..<w {
            for y in 0..<h {
                let quad = [(0, 0), (1, 0), (0, 1), (1, 1)].map { z(min(2 * y + $0.1, n - 1)) }
                test[x][y] = EffectSlots.halfResDepth(quad, x: x, y: y).test
            }
        }
        func layers(endsAt: Double) -> (bilinear: Int, depthAlone: Int, cutLetThrough: Int) {
            var bilinear = 0, depthAlone = 0, cutLetThrough = 0
            for x in 0..<n {
                for y in 0..<n {
                    let fp = EffectSlots.upsampleFootprint(pixelX: x, pixelY: y, scale: 2, width: w, height: h)
                    let depths = fp.texels.map { test[$0.x][$0.y] }
                    // Each texel's codes as its writers write them.
                    let ended = fp.texels.map { t -> Bool in
                        let s = near / test[t.x][t.y]
                        let cut = s < endsAt
                        let back = EffectSlots.backCode(lastVisible: endsAt, cut: cut)
                        let clip = cut ? 0 : EffectSlots.clipCode(endsAt: endsAt, sceneDepth: s)
                        return EffectSlots.texelEnded(back: Self.half(back), clouds: clip, oit: clip, texel: s, pixel: linear(y),
                                                      drawn: [.clouds, .volumes, .oit], reconstructed: [.clouds, .volumes, .oit])
                    }
                    let r = EffectSlots.reconstruction(bilinear: fp.bilinear, depths: depths, depth: z(y), tolerance: 0.1,
                                                       ended: ended)
                    if r.kind == .bilinear { bilinear += 1 }
                    let alone = EffectSlots.reconstruction(bilinear: fp.bilinear, depths: depths, depth: z(y), tolerance: 0.1,
                                                           ended: [false, false, false, false])
                    if alone.kind == .bilinear { depthAlone += 1 }
                    if ended.contains(true) && linear(y) < endsAt { cutLetThrough += 1 }
                }
            }
            return (bilinear, depthAlone, cutLetThrough)
        }
        // Wholly in front: 60 m against 100 m and beyond.
        let front = layers(endsAt: 60)
        XCTAssertEqual(front.bilinear, n * n, "exactly bilinear everywhere")
        XCTAssertLessThan(front.depthAlone, n * n / 10, "depth alone: stairs")
        // Ending within the ramp: never let through where the ramp is nearer.
        let within = layers(endsAt: 1_000)
        XCTAssertEqual(within.cutLetThrough, 0)
        XCTAssertLessThan(within.bilinear, n * n)
    }

    /// The codes never claim more than they know: a clip code says a pixel
    /// sees the effect whole only if its scene lies at the effect's end or
    /// beyond, and does so within one step of it; a back code, rounded to
    /// half, stays behind the back.
    func testCodesAreConservative() {
        var rng = SystemRandomNumberGenerator()
        for k in 0..<5_000 {
            // Every fifth on the sky, the effect a few metres to megametres out.
            let s = k % 5 == 0 ? EffectSlots.skyDistance : exp2(Double.random(in: -1...30, using: &rng))
            let x = k % 5 == 0 ? exp2(Double.random(in: 1...20, using: &rng)) : s * exp2(-Double.random(in: 0...20, using: &rng))
            let code = EffectSlots.clipCode(endsAt: x, sceneDepth: s)
            XCTAssertTrue((1...254).contains(code))
            let step = code <= 192 ? 1.0 / 16 : 2.0
            for _ in 0..<4 {
                let d = x * exp2(Double.random(in: -3...3, using: &rng))
                let ended = EffectSlots.clipEnded(code: code, texel: s, pixel: d)
                if ended { XCTAssertGreaterThanOrEqual(d * (1 + 1e-12), x, "\(x) in front of \(s), pixel at \(d)") }
                if code < 254 && d >= x * exp2(step) * (1 + 1e-12) { XCTAssertTrue(ended, "within a step: \(x), \(s), \(d)") }
            }
            if x >= 1.0 / 16_384 {
                let back = Self.half(EffectSlots.backCode(lastVisible: x, cut: false))
                XCTAssertGreaterThanOrEqual(back, log2(x))
                XCTAssertLessThan(back, log2(x) + 2 * EffectSlots.backMargin)
            }
        }
        XCTAssertEqual(EffectSlots.clipCode(endsAt: 11, sceneDepth: 10), 0, "cut")
        XCTAssertEqual(EffectSlots.clipCode(endsAt: 10, sceneDepth: 10), 1, "ends at the scene")
        XCTAssertFalse(EffectSlots.clipEnded(code: 0, texel: 10, pixel: .infinity))
        XCTAssertTrue(EffectSlots.clipEnded(code: EffectSlots.clipEmpty, texel: 100, pixel: 0.1), "nothing drawn")
        XCTAssertEqual(EffectSlots.clipCode(endsAt: 20, sceneDepth: EffectSlots.skyDistance), 234, "20 m out on the sky: 50 m")
        XCTAssertTrue(EffectSlots.clipEnded(code: 234, texel: EffectSlots.skyDistance, pixel: 60))
        XCTAssertFalse(EffectSlots.clipEnded(code: 234, texel: EffectSlots.skyDistance, pixel: 40))
        XCTAssertEqual(EffectSlots.backCode(lastVisible: 30, cut: true), EffectSlots.noFront)
        XCTAssertEqual(EffectSlots.backCode(lastVisible: nil, cut: false), EffectSlots.noBack)
        XCTAssertEqual(Self.half(EffectSlots.noBack), EffectSlots.noBack, "the clear value is a half")
        // A cut volume never ends, even for a sky pixel.
        XCTAssertFalse(EffectSlots.texelEnded(back: EffectSlots.noFront, clouds: 0, oit: 0, texel: 25, pixel: .infinity,
                                              drawn: [.volumes], reconstructed: [.volumes]))
        XCTAssertTrue(EffectSlots.texelEnded(back: EffectSlots.noBack, clouds: 0, oit: 0, texel: 25, pixel: .infinity,
                                             drawn: [.volumes], reconstructed: [.volumes]))
        // A layer drawn but not reconstructed never ends.
        XCTAssertFalse(EffectSlots.texelEnded(back: EffectSlots.noBack, clouds: 255, oit: 255, texel: 25, pixel: 25,
                                              drawn: [.volumes, .oit], reconstructed: [.volumes]))
    }

    /// A texel's footprint is the pixels whose four texels include it, and
    /// the depth sprites test against is its farthest.
    func testFootprint() {
        let (n, m) = (11, 9)
        let (w, h) = EffectSlots.targetSize(width: n, height: m, scale: 2)
        var reads = [[Set<Int>]](repeating: [Set<Int>](repeating: [], count: h), count: w)
        for x in 0..<n {
            for y in 0..<m {
                let fp = EffectSlots.upsampleFootprint(pixelX: x, pixelY: y, scale: 2, width: w, height: h)
                for (t, b) in zip(fp.texels, fp.bilinear) where b > 0 { reads[t.x][t.y].insert(y * n + x) }
            }
        }
        for tx in 0..<w {
            for ty in 0..<h {
                let pixels = Set(EffectSlots.footprintPixels(x: tx, y: ty, scale: 2, width: n, height: m).map { $0.y * n + $0.x })
                XCTAssertTrue(reads[tx][ty].isSubset(of: pixels), "texel \(tx), \(ty)")
            }
        }
        XCTAssertEqual(EffectSlots.footprintPixels(x: 2, y: 2, scale: 2, width: 20, height: 20).count, 16)
        XCTAssertEqual(EffectSlots.footprintPixels(x: 0, y: 0, scale: 2, width: 20, height: 20).count, 9, "clipped at the edge")
        XCTAssertEqual(EffectSlots.footprintPixels(x: 3, y: 4, scale: 1, width: 20, height: 20).map(\.x), [3])
        XCTAssertEqual(EffectSlots.footprintFarthest([0.2, 0.05, 0.3]), 0.05)
    }

    /// The slots' jitter: R1's blue noise, rotated by the golden ratio each
    /// frame. A texel's 64 frames are stratified (the golden-ratio
    /// sequence's largest gap); one frame's pattern keeps the noise's even
    /// spread; the same frame gives the same numbers.
    func testJitterIsKeyedOnTheFrameIndex() {
        let values = (0..<64).map { EffectSlots.jitter(x: 5, y: 9, frameIndex: 1_000 + $0) }.sorted()
        let gaps = zip(values.dropFirst(), values).map { $0 - $1 } + [1 - values.last! + values.first!]
        XCTAssertLessThan(gaps.max()!, 2.7 / 64, "stratified over frames")
        XCTAssertEqual(EffectSlots.jitter(x: 5, y: 9, frameIndex: 7), EffectSlots.jitter(x: 5, y: 9, frameIndex: 7))
        XCTAssertNotEqual(EffectSlots.jitter(x: 5, y: 9, frameIndex: 7), EffectSlots.jitter(x: 5, y: 9, frameIndex: 8))
        XCTAssertNotEqual(EffectSlots.jitter(x: 5, y: 9, salt: 1, frameIndex: 7), EffectSlots.jitter(x: 5, y: 9, frameIndex: 7))
        // One frame over the tile: every value once, so its mean is a half
        // and each 8 × 8 block's is near it.
        let n = BlueNoise.shared.size
        let frame = (0..<(n * n)).map { EffectSlots.jitter(x: $0 % n, y: $0 / n, frameIndex: 12_345) }
        XCTAssertEqual(frame.reduce(0, +) / Double(n * n), 0.5, accuracy: 1e-3)
        for by in stride(from: 0, to: n, by: 8) {
            for bx in stride(from: 0, to: n, by: 8) {
                var sum = 0.0
                for y in by..<(by + 8) { for x in bx..<(bx + 8) { sum += frame[y * n + x] } }
                XCTAssertEqual(sum / 64, 0.5, accuracy: 0.12, "block \(bx), \(by)")
            }
        }
        XCTAssertEqual(EffectSlots.jitterRotation(frameIndex: 1 << 24), 0, "the uniforms' index wraps at 2^24")
    }

    /// A shot's settle mode decodes, never negative.
    func testSettleDecodes() throws {
        func shot(_ json: String) throws -> SnapshotSpec.Shot {
            try JSONDecoder().decode(SnapshotSpec.Shot.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try shot(#"{"name": "a", "scenario": "leo"}"#).settle, 0)
        XCTAssertEqual(try shot(#"{"name": "a", "scenario": "leo", "settle": 32}"#).settle, 32)
        XCTAssertEqual(try shot(#"{"name": "a", "scenario": "leo", "settle": -3}"#).settle, 0)
    }

    /// End to end on a synthetic frame: a near disc in front of a far wall,
    /// fog between them at half resolution, marched to each texel's test
    /// depth (so it is 1 where that depth is the wall, 0 on the disc).
    /// Upsampled, the fog must be on the wall and off the disc. The
    /// checkerboard and nearest-depth upsample miss far fewer pixels than
    /// the nearest depth and bilinear, and none away from the edge.
    func testUpsampleKeepsFogOffTheForeground() {
        let n = 64, near = 0.05, far = 0.0005
        func depth(_ x: Int, _ y: Int) -> Double {
            let dx = Double(x) + 0.5 - 30.3, dy = Double(y) + 0.5 - 33.7
            return dx * dx + dy * dy < 17.0 * 17.0 ? near : far
        }
        let (w, h) = EffectSlots.targetSize(width: n, height: n, scale: 2)
        func quad(_ x: Int, _ y: Int) -> [Double] {
            [(0, 0), (1, 0), (0, 1), (1, 1)].compactMap { o in
                let px = 2 * x + o.0, py = 2 * y + o.1
                return px < n && py < n ? depth(px, py) : nil
            }
        }
        func misses(checkerboard: Bool, depthAware: Bool) -> (total: Int, awayFromEdge: Int) {
            var test = [[Double]](repeating: [Double](repeating: 0, count: h), count: w)
            for x in 0..<w {
                for y in 0..<h {
                    test[x][y] = checkerboard ? EffectSlots.halfResDepth(quad(x, y), x: x, y: y).test : quad(x, y).max()!
                }
            }
            var total = 0, away = 0
            for x in 0..<n {
                for y in 0..<n {
                    let fp = EffectSlots.upsampleFootprint(pixelX: x, pixelY: y, scale: 2, width: w, height: h)
                    let depths = fp.texels.map { test[$0.x][$0.y] }
                    let weights = depthAware
                        ? EffectSlots.upsampleWeights(bilinear: fp.bilinear, depths: depths, depth: depth(x, y), tolerance: 0.1)
                        : fp.bilinear
                    let fog = zip(weights, depths).map { $0 * ($1 == far ? 1 : 0) }.reduce(0, +)
                    let wanted = depth(x, y) == far ? 1.0 : 0.0
                    if abs(fog - wanted) > 0.25 {
                        total += 1
                        let edge = (-3...3).contains { dx in
                            (-3...3).contains { dy in
                                let qx = min(max(x + dx, 0), n - 1), qy = min(max(y + dy, 0), n - 1)
                                return depth(qx, qy) != depth(x, y)
                            }
                        }
                        if !edge { away += 1 }
                    }
                }
            }
            return (total, away)
        }
        let naive = misses(checkerboard: false, depthAware: false)
        let r6 = misses(checkerboard: true, depthAware: true)
        print("Upsample misses on a 17 px disc at 64², naive \(naive.total), R6's \(r6.total)")
        XCTAssertEqual(r6.awayFromEdge, 0)
        XCTAssertGreaterThan(naive.total, 40)
        XCTAssertLessThanOrEqual(r6.total * 8, naive.total, "R6's \(r6.total) against the naive \(naive.total)")
    }

    /// Half precision: the code keeps 1.1 % at 1e9 m and 0.3 % at 30 m.
    func testFrontCodeRoundTrip() {
        for (z, tolerance) in [(30.0, 0.003), (1_500.0, 0.006), (1e9, 0.011), (0.3, 0.003)] {
            let back = EffectSlots.linearDepth(frontCode: Self.half(EffectSlots.frontCode(linearDepth: z)))
            XCTAssertEqual(back / z, 1, accuracy: tolerance, "\(z) m")
        }
        XCTAssertEqual(EffectSlots.linearDepth(frontCode: EffectSlots.noFront), .infinity)
        XCTAssertEqual(Self.half(EffectSlots.noFront), EffectSlots.noFront, "the clear value is a half")
        XCTAssertLessThan(EffectSlots.frontCode(linearDepth: 1e300), EffectSlots.noFront + 1)
    }

    /// A dark homogeneous medium reports its front where 2 % is absorbed; a
    /// bright one sooner, where its radiance is first visible.
    func testHomogeneousFront() throws {
        let t = try XCTUnwrap(EffectSlots.homogeneousFront(entry: 10, exit: 50, extinction: 0.1))
        XCTAssertEqual(t, 10 - log(0.98) / 0.1, accuracy: 1e-12)
        XCTAssertEqual(1 - exp(-0.1 * (t - 10)), EffectSlots.frontOpacity, accuracy: 1e-12)
        XCTAssertNil(EffectSlots.homogeneousFront(entry: 10, exit: 10.1, extinction: 0.1))
        XCTAssertNil(EffectSlots.homogeneousFront(entry: 10, exit: 50, extinction: 0))
        // A glow of source radiance 2: visible at a coverage of 1/512.
        let glow = try XCTUnwrap(EffectSlots.homogeneousFront(entry: 10, exit: 50, extinction: 0.1, source: 2))
        let coverage = 1 - exp(-0.1 * (glow - 10))
        XCTAssertEqual(2 * coverage, EffectSlots.frontRadiance, accuracy: 1e-12)
        XCTAssertTrue(EffectSlots.frontReached(coverage: coverage * 1.001, radiance: 2 * coverage * 1.001))
        XCTAssertFalse(EffectSlots.frontReached(coverage: coverage * 0.999, radiance: 2 * coverage * 0.999))
        XCTAssertLessThan(glow, t)
        // A glow too thin to reach 2 % still has its front.
        XCTAssertNotNil(EffectSlots.homogeneousFront(entry: 10, exit: 10.1, extinction: 0.1, source: 2))
        // A dim medium falls back on its coverage.
        XCTAssertEqual(EffectSlots.homogeneousFront(entry: 10, exit: 50, extinction: 0.1, source: 0.1), t)
    }

    /// A bright, optically thin plume in front of a dense deck reports a
    /// front by its radiance, so it goes over the deck: the deck dims it to
    /// a tenth when it sorts beneath for want of a front.
    func testABrightThinLayerGoesInFront() {
        let plume = P(0.3, 0.12, 0.03, 0.01)
        XCTAssertFalse(plume.a >= EffectSlots.frontOpacity, "too thin to report by coverage")
        XCTAssertTrue(EffectSlots.frontReached(coverage: plume.a, radiance: max(plume.r, plume.g, plume.b)))
        let deck = EffectSlots.LayerSample(P(0.45, 0.45, 0.5, 0.9), front: 600)
        let reported = EffectSlots.composite([deck, EffectSlots.LayerSample(plume, front: 200)])
        XCTAssertEqual(reported, plume.over(deck.color))
        let unreported = EffectSlots.composite([deck, EffectSlots.LayerSample(plume, front: .infinity)])
        XCTAssertEqual(unreported, deck.color.over(plume))
        XCTAssertGreaterThan(reported.r - unreported.r, 0.25, "the plume's glow, not a tenth of it")
        // Faint smoke: a fragment visible on its own by its radiance alone.
        let smoke = P(0.006, 0.006, 0.006, 0.012)
        XCTAssertTrue(EffectSlots.frontReached(coverage: smoke.a, radiance: smoke.r))
        XCTAssertFalse(EffectSlots.frontReached(coverage: 0.01, radiance: 0.002))
    }

    func testOITWeight() {
        let ref = 200.0
        XCTAssertEqual(EffectSlots.oitWeight(alpha: 1, linearDepth: ref, reference: ref), 1, accuracy: 1e-12)
        XCTAssertEqual(EffectSlots.oitWeight(alpha: 0.5, linearDepth: ref / 2, reference: ref), 0.5 * 8, accuracy: 1e-12)
        XCTAssertEqual(EffectSlots.oitWeight(alpha: 1, linearDepth: 0, reference: ref), 64, "held, finite at 0")
        XCTAssertEqual(EffectSlots.oitWeight(alpha: 1, linearDepth: 1e9, reference: ref), 1.0 / 64)
        var last = Double.infinity
        for z in stride(from: 1.0, through: 10_000, by: 7) {
            let w = EffectSlots.oitWeight(alpha: 0.7, linearDepth: z, reference: ref)
            XCTAssertLessThanOrEqual(w, last, "non-increasing with depth")
            last = w
        }
        // A bright, near fragment stays below half's largest, several together too.
        let bright = EffectSlots.oitAccumulation(P(1_000, 800, 500, 1), linearDepth: 1, reference: ref)
        XCTAssertEqual(bright.r, EffectSlots.oitMaxAccumulation)
        XCTAssertLessThan(3 * bright.r, 65_504)
    }

    /// One fragment resolves to itself; any order gives the same sums; and
    /// for two fragments far apart in depth the result is the sorted
    /// composite's, not the reversed one's.
    func testOITResolve() {
        let ref = 100.0
        let red = P(0.6, 0.1, 0.05, 0.6), blue = P(0.05, 0.1, 0.5, 0.5)
        let one = EffectSlots.oitAccumulate([(red, 80)], reference: ref)
        let alone = EffectSlots.oitResolve(accumulation: one.accumulation, revealage: one.revealage)
        for (a, b) in [(alone.r, red.r), (alone.g, red.g), (alone.b, red.b), (alone.a, red.a)] {
            XCTAssertEqual(a, b, accuracy: 1e-12)
        }

        let frags = [(red, 50.0), (blue, 400.0)]
        let forward = EffectSlots.oitAccumulate(frags, reference: ref)
        let backward = EffectSlots.oitAccumulate(frags.reversed(), reference: ref)
        XCTAssertEqual(forward.accumulation, backward.accumulation)
        XCTAssertEqual(forward.revealage, backward.revealage)
        let oit = EffectSlots.oitResolve(accumulation: forward.accumulation, revealage: forward.revealage)
        let sorted = red.over(blue), reversed = blue.over(red)
        func distance(_ x: P, _ y: P) -> Double { abs(x.r - y.r) + abs(x.g - y.g) + abs(x.b - y.b) + abs(x.a - y.a) }
        XCTAssertEqual(oit.a, sorted.a, accuracy: 1e-12, "coverage is exact")
        // OIT gives the whole coverage the weighted mean colour, nearly the
        // near fragment's here: 0.37 from the sorted result, 0.92 from the
        // reversed one.
        XCTAssertLessThan(distance(oit, sorted) * 2, distance(oit, reversed))
    }

    /// The layers go far to near by their fronts; ties keep clouds,
    /// volumes, smoke; an empty layer changes nothing.
    func testCompositeOrder() {
        XCTAssertEqual(EffectSlots.compositeOrder([1_000, 500, 800]), [0, 2, 1])
        XCTAssertEqual(EffectSlots.compositeOrder([500, 500, .infinity]), [2, 0, 1])
        let cloud = EffectSlots.LayerSample(P(0.5, 0.5, 0.5, 0.5), front: 3_000)
        let plume = EffectSlots.LayerSample(P(0.8, 0.4, 0.1, 0.8), front: 400)
        let none = EffectSlots.LayerSample(.clear, front: .infinity)
        XCTAssertEqual(EffectSlots.composite([cloud, plume, none]), plume.color.over(cloud.color),
                       "a plume in front of the deck")
        let behind = EffectSlots.LayerSample(plume.color, front: 5_000)
        XCTAssertEqual(EffectSlots.composite([cloud, behind, none]), cloud.color.over(plume.color),
                       "the deck in front of a plume above it")
        XCTAssertEqual(EffectSlots.composite([none, plume, none]), plume.color)
    }

    /// A layer that overflowed half floats (a sum of items each below 6e4)
    /// saturates rather than vanishing; NaN is no light.
    func testAnOverflowingLayerSaturates() {
        XCTAssertEqual(EffectSlots.layerChannel(.infinity), EffectSlots.maxRadiance)
        XCTAssertEqual(EffectSlots.layerChannel(7e4), EffectSlots.maxRadiance)
        XCTAssertEqual(EffectSlots.layerChannel(.nan), 0)
        XCTAssertEqual(EffectSlots.layerChannel(-.infinity), 0)
        XCTAssertEqual(EffectSlots.layerChannel(5), 5)
        let hot = EffectSlots.Texel(clouds: .clear, volumes: P(.infinity, .infinity, 3e4, 0.6), accumulation: .clear,
                                    revealage: 1, fronts: [EffectSlots.noFront, 5, EffectSlots.noFront])
        let c = EffectSlots.compositePixel([hot], weights: [1], drawn: [.volumes])
        XCTAssertEqual(c, P(EffectSlots.maxRadiance, EffectSlots.maxRadiance, 3e4, 0.6))
        let bad = EffectSlots.Texel(clouds: .clear, volumes: P(.nan, 1, 1, .nan), accumulation: .clear,
                                    revealage: .nan, fronts: [EffectSlots.noFront, 5, EffectSlots.noFront])
        XCTAssertEqual(EffectSlots.compositePixel([bad], weights: [1], drawn: [.volumes, .oit]), P(0, 1, 1, 0))
    }

    // MARK: Settings and test emitters

    func testSettingsDecodePartially() throws {
        let empty = try JSONDecoder().decode(TransparencySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, TransparencySettings())
        XCTAssertEqual(empty.resolution.scale, 2)
        let spec = #"{"transparency": {"testEmitters": [{"kind": "cone", "size": 80}], "testBackdrop": true}}"#
        let s = try JSONDecoder().decode(RenderSettings.self, from: Data(spec.utf8))
        XCTAssertEqual(s.transparency.testEmitters, [EffectTestEmitter(.cone, size: 80)])
        XCTAssertTrue(s.transparency.testBackdrop)
        XCTAssertEqual(s.transparency.resolution, .half)
        XCTAssertEqual(s.transparency.upsampleTolerance, 0.1)
    }

    func testTargetFrame() {
        let earth = RenderScene.Body(id: 399, name: "Earth", position: Vec3(0, 0, -6.4e6),
                                     orientation: BodyOrientation(icrfToBody: .identity, angularVelocity: .zero),
                                     figure: .sphere(6.4e6),
                                     radius: 6.4e6, isSun: false, toSun: .unitX)
        var scene = RenderScene(clock: RenderScene.Clock(simTime: Epoch(tdbSecondsPastJ2000: 0)),
                                camera: RenderScene.Camera(position: .zero, worldToView: .identity, fovY: 1,
                                                           viewport: RenderScene.Viewport(width: 64, height: 32),
                                                           target: .body(301)),
                                sun: RenderScene.Sun(position: Vec3(1.5e11, 0, 0), direction: .unitX,
                                                     distance: 1.5e11, illuminance: 1.3e5, angularRadius: 0.0046),
                                bodies: [earth])
        scene.camera.target = CameraTarget.body(999)   // missing: the origin at the camera
        let f = EffectTargetFrame(scene: scene)
        XCTAssertEqual(f.up.z, 1, accuracy: 1e-12, "away from the Earth below")
        XCTAssertEqual(f.east.cross(f.north).x, f.up.x, accuracy: 1e-12)
        XCTAssertEqual(f.east.cross(f.north).y, f.up.y, accuracy: 1e-12)
        XCTAssertEqual(f.east.cross(f.north).z, f.up.z, accuracy: 1e-12)
        XCTAssertEqual(f.east.length, 1, accuracy: 1e-12)
        XCTAssertEqual(f.point([3, 0, 2]), f.east * 3 + f.up * 2)
        XCTAssertEqual(f.direction([0, 0, 0]), -f.up, "down by default")

        scene.camera.target = CameraTarget.body(399)
        let onEarth = EffectTargetFrame(scene: scene)
        XCTAssertEqual(onEarth.origin, earth.position)
        XCTAssertEqual(onEarth.up.z, 1, accuracy: 1e-12, "from the body to the camera")
        XCTAssertEqual(onEarth.distance, 6.4e6)
    }

    /// The sprites and sparks are the same on every platform, in their ball
    /// and their cone.
    func testTestEmittersAreFixed() {
        XCTAssertEqual(EffectTestScene.unit(0, 0, seed: 1), 0.8833108082136426, "splitmix64, integer arithmetic")
        let frame = EffectTargetFrame(origin: Vec3(0, 0, -100), east: .unitX, north: .unitY, up: .unitZ)
        let sprites = EffectTestScene.sprites(EffectTestEmitter(.sprites, position: [0, 0, 10], size: 20, count: 9),
                                              in: frame)
        XCTAssertEqual(sprites.count, 9)
        for s in sprites {
            XCTAssertLessThanOrEqual((s.center - Vec3(0, 0, -90)).length, 20)
            XCTAssertTrue((6...9).contains(s.radius))
        }
        XCTAssertNotEqual(sprites[0].color, sprites[1].color, "alternating tints")
        let sparks = EffectTestScene.sparks(EffectTestEmitter(.sparks, size: 10, axis: [1, 0, 0], count: 20), in: frame)
        for s in sparks {
            let d = (s.end - s.start).normalized
            XCTAssertLessThanOrEqual(acos(d.x) * 180 / Double.pi, 25.0001)
        }
        let slab = EffectTestScene.slab(EffectTestEmitter(.slab, size: 50), in: frame)
        XCTAssertEqual(slab.extinction * 2 * slab.halfExtents.z, 1, accuracy: 1e-12)
        let thin = EffectTestScene.slab(EffectTestEmitter(.slab, size: 50, opticalDepth: 0.05), in: frame)
        XCTAssertEqual(thin.extinction * 2 * thin.halfExtents.z, 0.05, accuracy: 1e-12)
    }

    /// x rounded to the nearest half (binary16), for the front code's precision.
    static func half(_ x: Double) -> Double {
        guard x != 0, x.isFinite else { return x }
        let e = max(Int(floor(log2(abs(x)))), -14)
        let ulp = exp2(Double(e - 10))
        return min((x / ulp).rounded() * ulp, 65_504)
    }
}

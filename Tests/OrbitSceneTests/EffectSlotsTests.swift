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
        // behind: all the weight on the nearest in depth.
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: [0, 0.0102, 0, 0.0099],
                                                   depth: 0.01, tolerance: 0.1), [0, 0, 0, 1])
        // A sky pixel next to the vessel: the sky texel with the larger
        // bilinear weight wins the tie.
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: [0.01, 0, 0, 0.01],
                                                   depth: 0, tolerance: 0.1), [0, 1, 0, 0])
        // The tolerance is relative, whatever the distance.
        let far = [1e-6, 1.05e-6, 0.97e-6, 1e-6]
        XCTAssertEqual(EffectSlots.upsampleWeights(bilinear: bilinear, depths: far, depth: 1e-6, tolerance: 0.1),
                       bilinear)
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

    /// A homogeneous medium reports its front where 2 % is absorbed.
    func testHomogeneousFront() throws {
        let t = try XCTUnwrap(EffectSlots.homogeneousFront(entry: 10, exit: 50, extinction: 0.1))
        XCTAssertEqual(t, 10 - log(0.98) / 0.1, accuracy: 1e-12)
        XCTAssertEqual(1 - exp(-0.1 * (t - 10)), EffectSlots.frontOpacity, accuracy: 1e-12)
        XCTAssertNil(EffectSlots.homogeneousFront(entry: 10, exit: 10.1, extinction: 0.1))
        XCTAssertNil(EffectSlots.homogeneousFront(entry: 10, exit: 50, extinction: 0))
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
        XCTAssertEqual(slab.extinction * 2 * slab.halfExtents.z, EffectTestScene.slabOpticalDepth, accuracy: 1e-12)
    }

    /// x rounded to the nearest half (binary16), for the front code's precision.
    static func half(_ x: Double) -> Double {
        guard x != 0, x.isFinite else { return x }
        let e = max(Int(floor(log2(abs(x)))), -14)
        let ulp = exp2(Double(e - 10))
        return min((x / ulp).rounded() * ulp, 65_504)
    }
}

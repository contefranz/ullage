import XCTest
import OrbitCore
@testable import OrbitScene

/// Clusters, proxies and level of detail (P2): the S-IC's five F-1s and
/// the S-II's five J-2s each one cluster; a proxy concave, finite, within
/// the ring budget and holding every member's field; the hull and its
/// reduction; the detail by size on screen.
final class PlumeClustersTests: XCTestCase {
    let us76 = USStandardAtmosphere1976()

    /// The five engines of a stage in the S-IC's pattern (or a J-2 ring).
    func five(_ engine: ApolloExhaust.Engine, air: AtmosphereState, ringRadius: Double = 4.9,
              axis: Vec3 = Vec3(0, 0, -1), at origin: Vec3 = .zero) -> [PlumeMember] {
        let s = PlumeModel.state(engine.spec, flowFraction: 1, ambient: air)
        var exits = [origin]
        for i in 0..<4 {
            let a = 2 * Double.pi * (Double(i) + 0.5) / 4
            exits.append(origin + Vec3(ringRadius * cos(a), ringRadius * sin(a), 0))
        }
        return exits.map {
            PlumeLook.member(engine.spec, state: s, exit: $0, axis: axis, exitRadius: engine.spec.exitRadius,
                             ambient: air)
        }
    }

    /// Whether every sampled point of every member's field lies in the proxy.
    func assertHolds(_ c: PlumeCluster, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for m in c.members {
            let across = PlumeLook.perpendicular(m.axis), other = m.axis.cross(across)
            for i in 0...30 {
                let x = m.length * Double(i) / 30 * 0.98
                let e = m.extent(atX: x) * 0.97
                for k in 0..<8 {
                    let a = 2 * Double.pi * Double(k) / 8
                    let p = m.exit + m.axis * x + (across * cos(a) + other * sin(a)) * e
                    XCTAssertTrue(c.contains(p), "\(label): x \(x) of \(m.length), r \(e)", file: file, line: line)
                }
            }
        }
    }

    func assertWellFormed(_ c: PlumeCluster, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(c.rings.count, 2, label, file: file, line: line)
        XCTAssertLessThanOrEqual(c.rings.count, PlumeClusters.maximumRings, label, file: file, line: line)
        for r in c.rings {
            XCTAssertTrue(r.x.isFinite && r.r.isFinite && r.r > 0, "\(label): \(r)", file: file, line: line)
        }
        for k in 1..<c.rings.count {
            XCTAssertGreaterThan(c.rings[k].x, c.rings[k - 1].x - 1e-9, label, file: file, line: line)
        }
        // Concave: the slopes never rise.
        var slope = Double.infinity
        for k in 1..<c.rings.count where c.rings[k].x > c.rings[k - 1].x + 1e-9 {
            let s = (c.rings[k].r - c.rings[k - 1].r) / (c.rings[k].x - c.rings[k - 1].x)
            XCTAssertLessThanOrEqual(s, slope + 1e-6, "\(label): concave", file: file, line: line)
            slope = s
        }
    }

    func testFiveF1sAreOneClusterWhoseProxyHoldsThem() {
        for altitude in [0.0, 6_700, 13_000, 30_000, 45_000, 67_000] {
            let clusters = PlumeClusters.clusters(five(ApolloExhaust.f1, air: us76.state(altitude: altitude)))
            XCTAssertEqual(clusters.count, 1, "F-1 at \(altitude) m")
            let c = clusters[0]
            XCTAssertEqual(c.members.count, 5)
            XCTAssertEqual(c.axis.dot(Vec3(0, 0, -1)), 1, accuracy: 1e-12)
            assertWellFormed(c, "F-1 at \(altitude) m")
            assertHolds(c, "F-1 at \(altitude) m")
        }
    }

    func testOtherFamiliesProxies() {
        let cases: [(String, [PlumeMember])] = [
            ("J-2 vacuum", five(ApolloExhaust.j2, air: .vacuum, ringRadius: 2.7)),
            ("J-2 sea level", five(ApolloExhaust.j2, air: us76.state(altitude: 0), ringRadius: 2.7)),
            ("SPS", [PlumeLook.member(ApolloExhaust.sps.spec,
                                      state: PlumeModel.state(ApolloExhaust.sps.spec, flowFraction: 1, ambient: .vacuum),
                                      exit: Vec3(10, 0, 0), axis: Vec3(-1, 0, 0),
                                      exitRadius: ApolloExhaust.sps.spec.exitRadius, ambient: .vacuum)]),
            ("retro", [PlumeLook.member(ApolloExhaust.sICRetro.spec,
                                        state: PlumeModel.state(ApolloExhaust.sICRetro.spec, flowFraction: 1,
                                                                ambient: us76.state(altitude: 65_000)),
                                        exit: Vec3(0, 5, 0), axis: Vec3(0.13, 0, 0.99).normalized,
                                        exitRadius: ApolloExhaust.sICRetro.spec.exitRadius,
                                        ambient: us76.state(altitude: 65_000))]),
        ]
        for (label, members) in cases {
            for c in PlumeClusters.clusters(members) {

                assertWellFormed(c, label)
                assertHolds(c, label)
            }
        }
    }

    /// Engines far apart, of different families or vessels, or pointing
    /// different ways, stay apart; a cluster takes eight at most. The S-IC
    /// retros' pairs, side by side in their fairings, are one cluster each.
    func testClusteringRules() {
        let air = us76.state(altitude: 65_000)
        let retro = ApolloExhaust.sICRetro.spec
        let rs = PlumeModel.state(retro, flowFraction: 1, ambient: air)
        func r(_ exit: Vec3, _ axis: Vec3) -> PlumeMember {
            PlumeLook.member(retro, state: rs, exit: exit, axis: axis, exitRadius: retro.exitRadius, ambient: air)
        }
        // Retros around the interstage, 5 m out, and a pair side by side.
        let ring = (0..<8).map { i -> PlumeMember in
            let a = 2 * Double.pi * Double(i) / 8
            let out = Vec3(cos(a), sin(a), 0)
            return r(out * 5, (Vec3(0, 0, 1) + out * 0.13).normalized)
        }
        XCTAssertEqual(PlumeClusters.clusters(ring).count, 8)
        XCTAssertEqual(PlumeClusters.clusters([r(.zero, .unitZ), r(Vec3(0.5, 0, 0), .unitZ)]).count, 1)

        let f1 = ApolloExhaust.f1.spec
        let s = PlumeModel.state(f1, flowFraction: 1, ambient: us76.state(altitude: 0))
        func m(_ exit: Vec3, _ axis: Vec3, vessel: UUID? = nil) -> PlumeMember {
            var x = PlumeLook.member(f1, state: s, exit: exit, axis: axis, exitRadius: f1.exitRadius,
                                     ambient: us76.state(altitude: 0))
            x.vesselID = vessel
            return x
        }
        // Twelve close and aligned: eight and four.
        let tight = (0..<12).map { m(Vec3(Double($0) * 0.1, 0, 0), Vec3(0, 0, 1)) }
        XCTAssertEqual(PlumeClusters.clusters(tight).map(\.members.count).sorted(), [4, 8])
        // Two vessels.
        let a = UUID(), b = UUID()
        XCTAssertEqual(PlumeClusters.clusters([m(.zero, .unitZ, vessel: a), m(Vec3(0.1, 0, 0), .unitZ, vessel: b)]).count, 2)
        // Pointing apart.
        XCTAssertEqual(PlumeClusters.clusters([m(.zero, .unitZ), m(Vec3(0.1, 0, 0), Vec3(0, 0.5, 1).normalized)]).count, 2)
    }

    /// The upper concave hull lies on or above every point; the reduction
    /// keeps it within the budget and above the hull.
    func testHullAndReduction() {
        var points: [PlumeCluster.Ring] = []
        for i in 0..<200 {
            let x = Double(i) * 0.5
            points.append(.init(x: x, r: 2 + 8 * (1 - exp(-x / 12)) + 0.3 * sin(Double(i))))
        }
        let hull = PlumeClusters.upperConcaveHull(points)
        let reduced = PlumeClusters.reduce(hull, to: PlumeClusters.maximumRings)
        XCTAssertLessThanOrEqual(reduced.count, PlumeClusters.maximumRings)
        let c = PlumeCluster(members: [], origin: .zero, axis: .unitX, u: .unitY, v: .unitZ, rings: reduced,
                             family: .kerosene, isJet: false, vesselID: nil)
        for p in points {
            XCTAssertGreaterThanOrEqual(c.radius(atX: p.x), p.r - 1e-9, "\(p)")
        }
    }

    /// Big on screen marches, small is an impostor, tiny is nothing; a jet
    /// far off is an impostor however big; Low draws only impostors.
    func testDetailBySize() {
        let members = five(ApolloExhaust.f1, air: us76.state(altitude: 0), axis: Vec3(0, 0, -1),
                           at: Vec3(0, 0, -100))
        let c = PlumeClusters.cluster(members)
        let camera = RenderScene.Camera(position: .zero, worldToView: .identity, fovY: 0.8,
                                        viewport: RenderScene.Viewport(width: 1600, height: 1000),
                                        target: .body(399))
        let settings = PlumeSettings()
        XCTAssertEqual(PlumeClusters.detail(c, camera: camera, settings: settings), .march)
        var far = c
        far.origin = c.origin + Vec3(0, 0, -1e4)
        XCTAssertEqual(PlumeClusters.detail(far, camera: camera, settings: settings), .impostor)
        far.origin = c.origin + Vec3(0, 0, -1e5)
        XCTAssertEqual(PlumeClusters.detail(far, camera: camera, settings: settings), .none)
        var low = settings
        low.quality = .low
        XCTAssertEqual(PlumeClusters.detail(c, camera: camera, settings: low), .impostor)
        var jet = c
        jet.isJet = true
        XCTAssertEqual(PlumeClusters.detail(jet, camera: camera, settings: settings), .impostor)
        var off = settings
        off.quality = .off
        XCTAssertEqual(PlumeClusters.detail(c, camera: camera, settings: off), .none)
    }

    /// The analytic intersection the march starts from agrees with point
    /// containment along random rays, the camera outside and inside.
    func testRayIntervalsAgreeWithContainment() {
        var rng = SeededGenerator(seed: 0x9_1E5E)
        for altitude in [0.0, 13_000, 67_000] {
            let c = PlumeClusters.cluster(five(ApolloExhaust.f1, air: us76.state(altitude: altitude),
                                              at: Vec3(3, -2, 40)))
            let scale = max(c.end, c.rings.map(\.r).max() ?? 1)
            var hits = 0
            for _ in 0..<400 {
                let o = Vec3(Double.random(in: -2...2, using: &rng), Double.random(in: -2...2, using: &rng),
                             Double.random(in: -2...2, using: &rng)) * scale
                let target = c.origin + c.axis * Double.random(in: c.start...c.end, using: &rng)
                    + Vec3(Double.random(in: -1...1, using: &rng), Double.random(in: -1...1, using: &rng), 0)
                    * (0.5 * c.radius(atX: (target0(c))))
                let d = (target - o)
                let span = c.interval(origin: o, direction: d)
                for i in 0...200 {
                    let t = -1 + 3 * Double(i) / 200
                    let p = o + d * t
                    let inside = c.contains(p)
                    let between = span.map { t > $0.lowerBound + 1e-6 && t < $0.upperBound - 1e-6 } ?? false
                    let outside = span.map { t < $0.lowerBound - 1e-6 || t > $0.upperBound + 1e-6 } ?? true
                    if inside { hits += 1 }
                    if between { XCTAssertTrue(inside, "F-1 at \(altitude): t \(t) in \(String(describing: span))") }
                    if outside { XCTAssertFalse(inside, "F-1 at \(altitude): t \(t) out of \(String(describing: span))") }
                }
            }
            XCTAssertGreaterThan(hits, 1000, "F-1 at \(altitude)")
        }
    }

    func target0(_ c: PlumeCluster) -> Double { 0.5 * (c.start + c.end) }

    /// Beyond the merge, the merged member carries the members' soot: the
    /// extinction integrated over the cross-section, within 35 % of theirs
    /// summed (one wide jet for five overlapping ones).
    /// The extinction summed over a cross-section of `c` at x along its
    /// axis, of `members`.
    func mass(_ members: [PlumeMember], in c: PlumeCluster, atX x: Double) -> Double {
        let reach = (c.radius(atX: x) / PlumeClusters.margin) * 1.2
        var total = 0.0
        let n = 120
        for i in 0..<n {
            for j in 0..<n {
                let a = -reach + 2 * reach * (Double(i) + 0.5) / Double(n)
                let b = -reach + 2 * reach * (Double(j) + 0.5) / Double(n)
                let p = c.origin + c.axis * x + c.u * a + c.v * b
                total += members.reduce(0) { $0 + $1.sample(at: p).extinction }
            }
        }
        return total
    }

    func testMergedFarFieldKeepsTheMembersMass() throws {
        for altitude in [0.0, 13_000] {
            let c = PlumeClusters.cluster(five(ApolloExhaust.f1, air: us76.state(altitude: altitude)))
            let merged = try XCTUnwrap(c.merged, "F-1 at \(altitude) m")
            XCTAssertGreaterThan(c.mergeX, 0)
            XCTAssertLessThan(c.mergeX, 0.8 * c.end)
            XCTAssertEqual(merged.densityScale, 5)
            let x = min(1.5 * c.mergeX, 0.6 * c.end)
            let single = mass([merged], in: c, atX: x), members = mass(c.members, in: c, atX: x)
            XCTAssertEqual(single / members, 1, accuracy: 0.35, "F-1 at \(altitude) m at \(x) m")
        }
    }

    /// A centre engine shutting down (CECO's tail-off) neither carries nor
    /// empties the merged far field: with the centre at 0.3 of its flow
    /// the merged member is an outer engine's, as dense as the 4.3 engines'
    /// flow, within 20 % of the five at full there.
    func testMergedFarFieldFollowsTheFlow() throws {
        let spec = ApolloExhaust.f1.spec
        for altitude in [0.0, 13_000] {
            let air = us76.state(altitude: altitude)
            let full = PlumeClusters.cluster(five(ApolloExhaust.f1, air: air))
            var members = five(ApolloExhaust.f1, air: air)
            let low = PlumeModel.state(spec, flowFraction: 0.3, ambient: air)
            members[0] = PlumeLook.member(spec, state: low, exit: members[0].exit, axis: members[0].axis,
                                          exitRadius: spec.exitRadius, ambient: air)
            let c = PlumeClusters.cluster(members)
            let a = try XCTUnwrap(full.merged), b = try XCTUnwrap(c.merged, "F-1 at \(altitude) m")
            XCTAssertEqual(b.flowFraction, 1)
            XCTAssertEqual(b.densityScale, 4.3, accuracy: 1e-9)
            let x = min(1.5 * full.mergeX, 0.6 * full.end)
            let ratio = mass([b], in: full, atX: x) / mass([a], in: full, atX: x)
            XCTAssertEqual(ratio, 1, accuracy: 0.2, "F-1 at \(altitude) m at \(x) m")
        }
    }
}

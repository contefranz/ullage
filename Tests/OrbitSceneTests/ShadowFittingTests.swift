import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// Track R4's shadow fitting: the penumbra against the Sun's 0.53° disc,
/// footprints that hold the cluster for any attitude and Sun, maps that do
/// not move on their casters as the camera or the vessel moves, the detail
/// map's steps, clustering, the plan's order and the matrices.
final class ShadowFittingTests: XCTestCase {
    static let degree = Double.pi / 180

    /// A seeded generator, so a failure repeats.
    struct Random {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }

        mutating func unit() -> Vec3 {
            let z = 2 * next() - 1, a = 2 * Double.pi * next(), s = (1 - z * z).squareRoot()
            return Vec3(s * cos(a), s * sin(a), z)
        }

        mutating func attitude() -> Quat { Quat(axis: unit(), angle: 2 * Double.pi * next()) }
    }

    /// The Saturn V's mesh vertices in its construction frame, and their
    /// sphere: as ShadowPass finds them from the mesh.
    static let saturnV: (points: [Vec3], centre: Vec3, radius: Double) = {
        let geometry = VesselGeometry(of: VesselLibrary.saturnV())
        let points = geometry.parts.flatMap { part in
            part.shapes.flatMap { $0.mesh(offset: part.offset).vertices.map(\.position) }
        }
        let s = ShadowFitting.boundingSphere(points)!
        return (points, s.centre, s.radius)
    }()

    // MARK: Penumbra

    /// The Sun's disc is 0.533° (IAU 2015 nominal radius at 1 au), and a
    /// straight edge Δd in front of a receiver facing it throws a penumbra
    /// 0.0093·Δd wide: about 3 cm for the LES tower on the CM, 0.9 m for the
    /// stack on the ground (the design's figures).
    func testPenumbraOfTheSunsDisc() {
        XCTAssertEqual(2 * ShadowFitting.sunAngularRadius / Self.degree, 0.533, accuracy: 0.0005)
        XCTAssertEqual(ShadowFitting.penumbraWidth(separation: 1), 0.0093, accuracy: 0.00002)
        XCTAssertEqual(ShadowFitting.penumbraWidth(separation: 3.2), 0.03, accuracy: 0.001)
        XCTAssertEqual(ShadowFitting.penumbraWidth(separation: 100), 0.93, accuracy: 0.005)

        // Against the construction: a straight edge h above flat ground, the
        // Sun's centre at elevation e. The rays from its upper and lower
        // limbs (e ± α) through the edge bound the penumbra on the ground.
        // Across the light that is 2·Δd·tan α, Δd = h / sin e along it, and
        // on the ground 1/sin e wider, to second order in α/e: 0.3% at 5°.
        let alpha = ShadowFitting.sunAngularRadius
        for e in stride(from: 5.0, through: 90, by: 5).map({ $0 * Self.degree }) {
            for h in [1.0, 30, 110] {
                let ground = h / tan(e - alpha) - h / tan(e + alpha)
                let across = ShadowFitting.penumbraWidth(separation: h / sin(e)) / sin(e)
                XCTAssertEqual(across / ground, 1, accuracy: e < 9 * Self.degree ? 3e-3 : 7e-4,
                               "e \(e / Self.degree)°, h \(h) m")
            }
        }
    }

    /// The profile across the edge is a uniform disc's share on one side of
    /// a chord; numerically integrated, it matches `edgeVisibility`.
    func testEdgeProfileIsTheDiscs() {
        XCTAssertEqual(ShadowFitting.edgeVisibility(-1), 0, accuracy: 1e-12)
        XCTAssertEqual(ShadowFitting.edgeVisibility(0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ShadowFitting.edgeVisibility(1), 1, accuracy: 1e-12)
        XCTAssertEqual(ShadowFitting.edgeVisibility(-3), 0)
        XCTAssertEqual(ShadowFitting.edgeVisibility(3), 1)
        let n = 600
        for s in stride(from: -0.95, through: 0.95, by: 0.1) {
            var inside = 0, total = 0
            for i in 0..<n {
                for j in 0..<n {
                    let x = (Double(i) + 0.5) / Double(n) * 2 - 1, y = (Double(j) + 0.5) / Double(n) * 2 - 1
                    guard x * x + y * y <= 1 else { continue }
                    total += 1
                    if x < s { inside += 1 }
                }
            }
            XCTAssertEqual(ShadowFitting.edgeVisibility(s), Double(inside) / Double(total), accuracy: 3e-3)
        }
        var last = -1.0
        for s in stride(from: -1.0, through: 1, by: 0.01) {
            XCTAssertGreaterThan(ShadowFitting.edgeVisibility(s), last)
            last = ShadowFitting.edgeVisibility(s)
        }
    }

    /// ShadowCommon's filter: n Vogel taps on a disc the penumbra's half
    /// width across, each turned per texel. Across a straight edge, averaged
    /// over the turns, it gives the Sun's profile within 0.02 at 16 and 32
    /// taps, so PCSS's soft shadow has the real disc's width.
    func testVogelFilterGivesTheDiscsProfile() {
        for n in [16, 32] {
            for s in stride(from: -1.0, through: 1, by: 0.125) {
                var lit = 0.0
                let turns = 720
                for t in 0..<turns {
                    let rotation = 2 * Double.pi * Double(t) / Double(turns)
                    for k in 0..<n where ShadowFitting.vogel(k, of: n, rotation: rotation).x < s { lit += 1 }
                }
                XCTAssertEqual(lit / Double(turns * n), ShadowFitting.edgeVisibility(s), accuracy: 0.02, "n \(n), s \(s)")
            }
            // Equal-area rings.
            let radii = (0..<n).map { k -> Double in
                let p = ShadowFitting.vogel(k, of: n, rotation: 0)
                return (p.x * p.x + p.y * p.y).squareRoot()
            }
            XCTAssertEqual(radii.map { $0 * $0 }.reduce(0, +) / Double(n), 0.5, accuracy: 1e-12)
            XCTAssertLessThan(radii.max()!, 1)
        }
    }

    /// PCSS's estimate is the penumbra's half width in texels.
    func testFilterRadius() {
        let range = 120.0, texel = 0.03
        let r = ShadowFitting.filterRadius(blocker: 0.6, receiver: 0.4, depthRange: range, texel: texel)
        XCTAssertEqual(r, ShadowFitting.penumbraWidth(separation: 0.2 * range) / 2 / texel, accuracy: 1e-12)
        XCTAssertEqual(ShadowFitting.filterRadius(blocker: 0.3, receiver: 0.4, depthRange: range, texel: texel), 0)
    }

    // MARK: Steps and frames

    func testQuantizedUp() {
        XCTAssertEqual(ShadowFitting.quantizedUp(1), 1, accuracy: 1e-12)
        XCTAssertEqual(ShadowFitting.quantizedUp(2), 2, accuracy: 1e-12)
        XCTAssertEqual(ShadowFitting.quantizedUp(57.4), pow(2, 47.0 / 8), accuracy: 1e-9)
        for x in stride(from: 0.3, through: 500, by: 0.37) {
            let q = ShadowFitting.quantizedUp(x)
            XCTAssertGreaterThanOrEqual(q, x)
            XCTAssertLessThan(q, x * pow(2, 1.0 / 8) * (1 + 1e-9))
        }
    }

    /// The detail map: 2·d·tan(fovY/2), at least 2 m, in steps of √2 up
    /// from 2 m, and only while finer than the cluster map.
    func testDetailRadius() {
        let fov = 50 * Self.degree
        // The camera 5 m from the CM: 4.66 m, so 4√2 = 5.66 m.
        XCTAssertEqual(ShadowFitting.detailRadius(distance: 5, fovY: fov, clusterRadius: 58)!, 4 * 2.0.squareRoot(),
                       accuracy: 1e-9)
        XCTAssertEqual(ShadowFitting.detailRadius(distance: 0.5, fovY: fov, clusterRadius: 58)!, 2, accuracy: 1e-12)
        XCTAssertNil(ShadowFitting.detailRadius(distance: 200, fovY: fov, clusterRadius: 58))
        var last = 0.0
        for d in stride(from: 0.1, through: 60, by: 0.05) {
            guard let r = ShadowFitting.detailRadius(distance: d, fovY: fov, clusterRadius: 1e9) else {
                return XCTFail("no detail map at \(d) m")
            }
            XCTAssertGreaterThanOrEqual(r, max(2 * d * tan(fov / 2), 2) - 1e-9)
            let step = log2(r / 2) * 2
            XCTAssertEqual(step, step.rounded(), accuracy: 1e-9, "√2 steps from 2 m")
            XCTAssertGreaterThanOrEqual(r, last)
            last = r
        }
    }

    func testLightBasis() {
        var random = Random(state: 7)
        for _ in 0..<200 {
            let toSun = random.unit()
            let b = ShadowFitting.lightBasis(toSun: toSun * 1.5e11)
            for (u, v) in [(b.r0, b.r1), (b.r1, b.r2), (b.r0, b.r2)] { XCTAssertEqual(u.dot(v), 0, accuracy: 1e-12) }
            for r in [b.r0, b.r1, b.r2] { XCTAssertEqual(r.length, 1, accuracy: 1e-12) }
            XCTAssertEqual(b.determinant, 1, accuracy: 1e-12)
            XCTAssertEqual((b.r2 - toSun).length, 0, accuracy: 1e-12)
        }
    }

    func testClusters() {
        func vessel(_ x: Double, _ r: Double) -> ShadowCaster {
            ShadowCaster(kind: .vessel(UUID()), centre: Vec3(x, 0, 0), radius: r)
        }
        // Gaps between spheres: 250 m links, 350 m does not, a chain links.
        let casters = [vessel(0, 10), vessel(270, 10), vessel(630, 10), vessel(5_000, 10), vessel(5_310, 10)]
        XCTAssertEqual(ShadowFitting.clusters(casters, members: Array(casters.indices), link: 300),
                       [[0, 1], [2], [3, 4]])
        XCTAssertEqual(ShadowFitting.clusters(casters, members: Array(casters.indices), link: 400),
                       [[0, 1, 2], [3, 4]])
        XCTAssertEqual(ShadowFitting.clusters(casters, members: [3, 1], link: 300), [[1], [3]])
    }

    // MARK: Footprints

    /// The Saturn V's map: about 115 m across (2R), 2.8-2.9 cm texels at
    /// 4096², and for random attitudes and Sun directions every vertex of
    /// the vehicle lands inside the usable footprint and inside the depth.
    func testFootprintHoldsTheCluster() {
        let v = Self.saturnV
        XCTAssertEqual(v.radius, 57, accuracy: 2, "the Saturn V's sphere about its middle")
        var random = Random(state: 42)
        var settings = ShadowSettings()
        settings.detailMap = false
        for _ in 0..<12 {
            let attitude = random.attitude(), position = random.unit() * (60 + 400 * random.next())
            let origin = random.unit() * 30     // the structure origin from the centre of mass
            let anchor = position + attitude.rotate(origin + v.centre)
            let view = ShadowView(casters: [ShadowCaster(kind: .vessel(UUID()), centre: anchor, radius: v.radius)],
                                  sun: random.unit() * 1.5e11, target: nil, fovY: 50 * Self.degree,
                                  pixelsPerRadian: 1_000)
            let maps = ShadowFitting.plan(view, settings: settings)
            XCTAssertEqual(maps.count, 1)
            guard let map = maps.first else { continue }
            XCTAssertEqual(map.casters, [0])
            XCTAssertEqual(2 * map.halfWidth, 117, accuracy: 3)
            XCTAssertEqual(map.texel, 0.0286, accuracy: 0.001)
            let edge = ShadowFitting.usableEdge(resolution: map.resolution)
            for p in v.points {
                let c = map.clip(position + attitude.rotate(origin + p))
                XCTAssertLessThan(max(abs(c.x), abs(c.y)), edge)
                XCTAssert((0...1).contains(c.z))
            }
        }
    }

    /// A cluster of vessels, and a site beside them: each member's whole
    /// sphere lands in the cluster map; the site is drawn into it and has a
    /// map of its own holding it; a caster far off is in neither.
    func testClusterAndSiteMaps() {
        var random = Random(state: 3)
        for _ in 0..<50 {
            let a = ShadowCaster(kind: .vessel(UUID()), centre: random.unit() * 150, radius: 20)
            let b = ShadowCaster(kind: .vessel(UUID()), centre: a.centre + random.unit() * 200, radius: 8)
            let far = ShadowCaster(kind: .vessel(UUID()), centre: a.centre + random.unit() * 5_000, radius: 5)
            let site = ShadowCaster(kind: .site("LC-39A"), centre: a.centre + random.unit() * 60, radius: 130)
            let view = ShadowView(casters: [a, b, far, site], sun: random.unit() * 1.5e11,
                                  target: .init(caster: 0, point: a.centre), fovY: 50 * Self.degree,
                                  pixelsPerRadian: 1_000)
            var settings = ShadowSettings()
            settings.detailMap = false
            let maps = ShadowFitting.plan(view, settings: settings)
            XCTAssertEqual(maps.count, 2, "the cluster and the site; the far vessel is too small")
            guard maps.count == 2 else { continue }
            let (cluster, siteMap) = (maps[0], maps[1])
            XCTAssertEqual(cluster.centre, a.centre, "anchored on the target")
            XCTAssertEqual(siteMap.centre, site.centre)
            XCTAssert(cluster.casters.contains(0) && cluster.casters.contains(1) && !cluster.casters.contains(2))
            XCTAssert(siteMap.casters.contains(3) && !siteMap.casters.contains(2))
            let edge = ShadowFitting.usableEdge(resolution: cluster.resolution)
            for (map, members) in [(cluster, [a, b]), (siteMap, [site])] {
                for m in members {
                    for _ in 0..<64 {
                        let c = map.clip(m.centre + random.unit() * m.radius)
                        XCTAssertLessThan(max(abs(c.x), abs(c.y)), edge)
                        XCTAssert((0...1).contains(c.z))
                    }
                }
            }
            // Any caster drawn is inside the depth range.
            for map in maps {
                for j in map.casters {
                    let c = view.casters[j], z = map.basis.r2.dot(c.centre - map.centre)
                    XCTAssertLessThanOrEqual(z + c.radius, map.near + 1e-9)
                    XCTAssertLessThanOrEqual(c.radius - z, map.far + 1e-9)
                }
            }
        }
    }

    // MARK: Stability

    /// The Saturn V's anchor on the pad, the site's centre and the point
    /// the camera orbits, for a camera at the origin 7.3 m from it.
    static let anchor = Vec3(6, -4, -38.8), siteCentre = Vec3(30, 30, -90), com = Vec3(6, -4, 1.2)

    /// A vessel on the pad, its site, and the camera target: the casters the
    /// maps are fitted to, camera-relative for a camera at `camera`.
    func padView(camera: Vec3, vesselShift: Vec3 = .zero, comShift: Vec3 = .zero) -> ShadowView {
        let anchor = Self.anchor + vesselShift - camera
        let site = Self.siteCentre - camera
        let com = Self.com + vesselShift + comShift - camera
        return ShadowView(casters: [ShadowCaster(kind: .vessel(UUID()), centre: anchor, radius: 57.4),
                                    ShadowCaster(kind: .site("LC-39A"), centre: site, radius: 130)],
                          sun: Vec3(1.1e11, 0.9e11, 0.3e11) - camera, target: .init(caster: 0, point: com),
                          fovY: 50 * Self.degree, pixelsPerRadian: 1_000 / (2 * tan(25 * Self.degree)))
    }

    /// No shimmer from the camera: moving it changes no map (where a point
    /// fixed in the world lands on each), and the detail map's centre stays
    /// on its grid however the camera's distance rounds.
    func testCameraMotionLeavesTheMapsUnchanged() {
        let world = [Self.anchor, Self.com, Vec3(20, -5, 30), Self.siteCentre, Vec3(-60, 70, -40)]
        let base = ShadowFitting.plan(padView(camera: .zero), settings: ShadowSettings())
        XCTAssertEqual(base.map(\.level), [.detail, .cluster, .cluster])
        var random = Random(state: 11)
        for _ in 0..<100 {
            let camera = random.unit() * random.next()    // within a metre: the same detail step
            let maps = ShadowFitting.plan(padView(camera: camera), settings: ShadowSettings())
            XCTAssertEqual(maps.count, base.count)
            for (a, b) in zip(base, maps) {
                XCTAssertEqual(a.halfWidth, b.halfWidth)
                XCTAssertEqual(a.casters, b.casters)
                for p in world {
                    XCTAssertEqual((a.clip(p) - b.clip(p - camera)).length, 0, accuracy: 1e-9)
                }
            }
        }
    }

    /// Whole-texel moves leave the map unchanged. The cluster map rides on
    /// the vessel, whose casters keep their texels however it moves, and a
    /// site in it moves by whole texels when the vessel moves by whole
    /// texels. The detail map's window keeps its place under sub-texel moves
    /// of the camera's target point and steps by whole texels.
    func testWholeTexelMovesLeaveTheMapsUnchanged() {
        let base = ShadowFitting.plan(padView(camera: .zero), settings: ShadowSettings())
        let detail = base[0], cluster = base[1]
        let onVessel = [Vec3(0, 0, 0), Vec3(0.3, -0.2, 40), Vec3(-4, 2, -50)].map { $0 + Self.anchor }
        let onSite = [Self.siteCentre, Vec3(10, 60, -80)]
        func texels(_ map: ShadowMapFit, _ p: Vec3) -> (Double, Double) {
            let t = ShadowMapFit.texture(map.clip(p))
            return (t.x * Double(map.resolution), t.y * Double(map.resolution))
        }
        var random = Random(state: 5)
        for _ in 0..<50 {
            // The vessel moves by whole texels of its cluster map across the light.
            let k = (Double(Int(random.next() * 200) - 100), Double(Int(random.next() * 200) - 100))
            let shift = cluster.basis.r0 * (k.0 * cluster.texel) + cluster.basis.r1 * (k.1 * cluster.texel)
                + cluster.basis.r2 * (random.next() * 3)
            let maps = ShadowFitting.plan(padView(camera: .zero, vesselShift: shift), settings: ShadowSettings())
            let moved = maps[1]
            XCTAssertEqual(moved.texel, cluster.texel)
            for p in onVessel {
                let a = texels(cluster, p), b = texels(moved, p + shift)
                XCTAssertEqual(a.0, b.0, accuracy: 1e-6)
                XCTAssertEqual(a.1, b.1, accuracy: 1e-6)
            }
            for p in onSite {
                let a = texels(cluster, p), b = texels(moved, p)
                XCTAssertEqual(a.0 - b.0, k.0, accuracy: 1e-6)
                XCTAssertEqual(a.1 - b.1, -k.1, accuracy: 1e-6, "v runs down")
            }
            // The detail map rides with it (the camera following, so that
            // its step stays): its casters keep their texels.
            let followed = ShadowFitting.plan(padView(camera: shift, vesselShift: shift), settings: ShadowSettings())
            XCTAssertEqual(followed[0].halfWidth, detail.halfWidth)
            for p in onVessel {
                let a = texels(detail, p), b = texels(followed[0], p)
                XCTAssertEqual(a.0, b.0, accuracy: 1e-6)
                XCTAssertEqual(a.1, b.1, accuracy: 1e-6)
            }
        }
        // The centre of mass drifting on the vessel moves the detail map's
        // window by whole texels only, so its casters keep their texels'
        // phases; a drift that does not carry it over a rounding boundary
        // moves it not at all across the light.
        let offset = Self.com - Self.anchor
        let phase = (detail.basis.r0.dot(offset) / detail.texel, detail.basis.r1.dot(offset) / detail.texel)
        let room = min(0.5 - abs(phase.0 - phase.0.rounded()), 0.5 - abs(phase.1 - phase.1.rounded()))
        var still = 0
        for i in 0..<200 {
            let drift = random.unit() * (Double(i % 20) * 0.3 * detail.texel)
            let moved = ShadowFitting.plan(padView(camera: .zero, comShift: drift), settings: ShadowSettings())[0]
            XCTAssertEqual(moved.halfWidth, detail.halfWidth)
            let step = moved.centre - detail.centre
            for axis in [detail.basis.r0, detail.basis.r1] {
                let k = axis.dot(step) / detail.texel
                XCTAssertEqual(k, k.rounded(), accuracy: 1e-6)
            }
            for p in onVessel {
                let a = texels(detail, p), b = texels(moved, p)
                XCTAssertEqual(a.0 - b.0, (a.0 - b.0).rounded(), accuracy: 1e-6)
                XCTAssertEqual(a.1 - b.1, (a.1 - b.1).rounded(), accuracy: 1e-6)
            }
            let across = max(abs(detail.basis.r0.dot(drift)), abs(detail.basis.r1.dot(drift))) / detail.texel
            if across < room {
                still += 1
                XCTAssertEqual(detail.basis.r0.dot(step), 0, accuracy: 1e-9)
                XCTAssertEqual(detail.basis.r1.dot(step), 0, accuracy: 1e-9)
            }
        }
        XCTAssertGreaterThan(still, 0)
    }

    // MARK: Plan

    /// The detail map first, the target's cluster, then the rest by size on
    /// screen; nothing under the minimum size; no more than `maxMaps`.
    func testPlanOrderAndLimits() {
        let view = padView(camera: .zero)
        var s = ShadowSettings()
        XCTAssertEqual(ShadowFitting.plan(view, settings: s).map(\.level), [.detail, .cluster, .cluster])
        s.maxMaps = 2
        let two = ShadowFitting.plan(view, settings: s)
        XCTAssertEqual(two.map(\.level), [.detail, .cluster])
        XCTAssertEqual(two[1].centre, view.casters[0].centre, "the target's cluster")
        s.maxMaps = 1
        XCTAssertEqual(ShadowFitting.plan(view, settings: s).map(\.level), [.cluster], "no room for the detail map")
        s = ShadowSettings()
        s.detailMap = false
        XCTAssertEqual(ShadowFitting.plan(view, settings: s).map(\.level), [.cluster, .cluster])
        s.enabled = false
        XCTAssertEqual(ShadowFitting.plan(view, settings: s), [])

        // Far away, everything is under 64 px: no maps at all.
        var far = view
        far.casters = far.casters.map { ShadowCaster(kind: $0.kind, centre: $0.centre * 1_000, radius: $0.radius) }
        far.target = .init(caster: 0, point: view.target!.point * 1_000)
        XCTAssertEqual(ShadowFitting.plan(far, settings: ShadowSettings()), [])

        // The camera looking at a body: no detail map, clusters by size.
        var body = view
        body.target = nil
        let maps = ShadowFitting.plan(body, settings: ShadowSettings())
        XCTAssertEqual(maps.map(\.level), [.cluster, .cluster])
        XCTAssertEqual(Set(maps.map { [$0.centre.x, $0.centre.y, $0.centre.z] }),
                       Set(view.casters.map { [$0.centre.x, $0.centre.y, $0.centre.z] }))

        // A receiver takes the first map holding it: the target's point the
        // detail map; past it, the cluster's; past that, on the side away
        // from the vessel, the site's; nothing far off.
        let all = ShadowFitting.plan(view, settings: ShadowSettings())
        let (detail, cluster, site) = (all[0], all[1], all[2])
        XCTAssertEqual(ShadowFitting.mapIndex(for: view.target!.point, in: all), 0)
        XCTAssertEqual(ShadowFitting.mapIndex(for: cluster.centre + cluster.basis.r0 * (2 * detail.halfWidth + 1),
                                              in: all), 1)
        let away = site.basis.r0.dot(cluster.centre - site.centre) > 0 ? -1.0 : 1.0
        let edge = ShadowFitting.usableEdge(resolution: site.resolution)
        XCTAssertEqual(ShadowFitting.mapIndex(for: site.centre + site.basis.r0 * (away * 0.9 * edge * site.halfWidth),
                                              in: all), 2)
        XCTAssertNil(ShadowFitting.mapIndex(for: site.centre + site.basis.r0 * (1.1 * site.halfWidth), in: all))
    }

    /// The matrix is `clip`, and the composed mesh matrix is `clip` of the
    /// placed point.
    func testMatrices() {
        var random = Random(state: 9)
        let map = ShadowFitting.plan(padView(camera: .zero), settings: ShadowSettings())[1]
        func apply(_ m: [Double], _ p: Vec3) -> Vec3 {
            XCTAssertEqual(Array(m[12...]), [0, 0, 0, 1])
            return Vec3(m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3], m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
                        m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11])
        }
        for _ in 0..<100 {
            let p = random.unit() * 100, rotation = random.attitude().matrix, t = random.unit() * 300
            XCTAssertEqual((apply(map.matrix, p) - map.clip(p)).length, 0, accuracy: 1e-12)
            XCTAssertEqual((apply(map.matrix(rotation: rotation, translation: t), p) - map.clip(rotation * p + t)).length,
                           0, accuracy: 1e-12)
        }
        // Depth runs from 1 on the Sun's side to 0 on the far side.
        XCTAssertEqual(map.clip(map.centre + map.basis.r2 * map.near).z, 1, accuracy: 1e-12)
        XCTAssertEqual(map.clip(map.centre - map.basis.r2 * map.far).z, 0, accuracy: 1e-12)
        let t = ShadowMapFit.texture(Vec3(-1, 1, 0.3))
        XCTAssertEqual([t.x, t.y, t.z], [0, 0, 0.3], "u right, v down from the top left")
    }

    /// A spec may give only what it changes.
    func testSettingsDecodePartially() throws {
        let s = try JSONDecoder().decode(RenderSettings.self, from: Data(#"{"shadow": {"mapSize": 2048}}"#.utf8))
        var expected = ShadowSettings()
        expected.mapSize = 2048
        XCTAssertEqual(s.shadow, expected)
    }
}

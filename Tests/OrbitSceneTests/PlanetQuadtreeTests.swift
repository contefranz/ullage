import XCTest
@testable import OrbitCore
@testable import OrbitScene

/// CDLOD selection on the cube sphere (PlanetQuadtree.swift): every visible
/// point covered by exactly one tile, horizon culling against the analytic
/// horizon, with and without relief, the tile budget, determinism, crack-free
/// morph ranges between levels, and the motion bias under time warp.
final class PlanetQuadtreeTests: XCTestCase {
    let deg = Double.pi / 180
    let moonRadius = 1_737_400.0

    /// The Earth's imagery: WGS 84, 256-texel tiles.
    func earth(maxLevel: Int = 7, budget: Int = 100_000) -> PlanetQuadtree {
        PlanetQuadtree(.init(figure: .wgs84, maxLevel: maxLevel, tileBudget: budget))
    }

    /// The Moon's terrain: 32-quad grids at 4 px, on LOLA's relief.
    func moon(maxLevel: Int = 10, relief: ClosedRange<Double> = PlanetQuadtree.moonRelief,
              budget: Int = 100_000) -> PlanetQuadtree {
        PlanetQuadtree(.init(figure: .sphere(moonRadius), maxLevel: maxLevel, samplesPerTile: 32, pixelError: 4,
                             tileBudget: budget, heightRange: relief))
    }

    /// A camera `altitude` above geodetic (lat, lon) (deg), looking along
    /// `heading` (deg from north) `pitch` deg above the horizontal, with a
    /// 50° field on 3024 × 1964 px; nil frustum for `frustum: false`.
    func look(_ q: PlanetQuadtree, lat: Double, lon: Double, altitude: Double, heading: Double = 90,
              pitch: Double = 0, frustum: Bool = true) -> PlanetQuadtree.View {
        let f = q.parameters.figure
        let position = f.bodyFixed(latitude: lat * deg, longitude: lon * deg, height: altitude)
        let up = f.normal(latitude: lat * deg, longitude: lon * deg)
        let east = Vec3.unitZ.cross(up).normalized, north = up.cross(east)
        let h = north * cos(heading * deg) + east * sin(heading * deg)
        let forward = h * cos(pitch * deg) + up * sin(pitch * deg)
        let camUp = up * cos(pitch * deg) - h * sin(pitch * deg)
        let fov = 50 * deg
        let fr = PlanetQuadtree.Frustum(apex: position, forward: forward, up: camUp, fovY: fov, aspect: 3024.0 / 1964)
        return PlanetQuadtree.View(position: position, frustum: frustum ? fr : nil, pixelAngle: fov / 1964)
    }

    /// Directions within `radius` (rad) of `centre`, evenly spread.
    func cap(_ centre: Vec3, radius: Double, count: Int) -> [Vec3] {
        let c = centre.normalized
        let e1 = (abs(c.z) < 0.9 ? Vec3.unitZ : Vec3.unitX).cross(c).normalized, e2 = c.cross(e1)
        let floor = cos(radius)
        return (0 ..< count).map { i in
            let z = 1 - (1 - floor) * (Double(i) + 0.5) / Double(count)
            let r = max(0, 1 - z * z).squareRoot(), phi = Double(i) * 2.399963229728653
            return c * z + e1 * (r * cos(phi)) + e2 * (r * sin(phi))
        }
    }

    /// Which selected tiles hold a direction.
    struct Cover {
        let ids: Set<UInt64>
        let levels: [Int]
        init(_ s: PlanetQuadtree.Selection) {
            ids = Set(s.tiles.map(\.key.id))
            levels = Array(Set(s.tiles.map(\.key.level))).sorted()
        }
        func count(_ d: Vec3) -> Int {
            levels.filter { ids.contains(TileKey.containing(d, level: $0).id) }.count
        }
    }

    /// The scaled figure coordinates (x/a, y/a, z/b) of a body-fixed point.
    func scaled(_ p: Vec3, _ f: Ellipsoid) -> Vec3 {
        Vec3(p.x / f.equatorialRadius, p.y / f.equatorialRadius, p.z / f.polarRadius)
    }

    /// Whether the straight line from the camera to the surface point at
    /// figure direction `d` and `height` clears the occluder (the figure
    /// lowered by `lowest` m) with room to spare, by direct geometry in
    /// scaled figure coordinates, where the figure is the unit sphere.
    func clearlyVisible(_ d: Vec3, height: Double, from camera: Vec3, _ f: Ellipsoid, lowest: Double) -> Bool {
        let c = scaled(camera, f), p = d.normalized * (1 + height / f.equatorialRadius)
        let occluder = 1 + lowest / f.polarRadius
        let v = p - c
        if p.length <= occluder * (1 + 1e-9) {
            // On the occluder: seen only from above its tangent plane.
            return (c - p).dot(p.normalized) > 1e-6 * v.length
        }
        let t = min(1, max(0, -c.dot(v) / v.lengthSquared))
        return (c + v * t).length > occluder * (1 + 1e-9)
    }

    /// Whether a body-fixed point is inside the frustum by a margin.
    func clearlyInside(_ p: Vec3, _ f: PlanetQuadtree.Frustum?) -> Bool {
        guard let f else { return true }
        let v = p - f.apex, l = v.length
        return f.normals.allSatisfy { $0.dot(v) > 1e-6 * l }
    }

    /// Every clearly visible sample in the frustum lies in exactly one
    /// selected tile; returns how many samples were visible.
    @discardableResult
    func assertCoversVisible(_ s: PlanetQuadtree.Selection, _ view: PlanetQuadtree.View, _ q: PlanetQuadtree,
                             samples: [Vec3], height: Double = 0, file: StaticString = #filePath,
                             line: UInt = #line) -> Int {
        let cover = Cover(s), f = q.parameters.figure
        var visible = 0, misses = 0
        for d in samples {
            let p = f.surfacePoint(figureDirection: d) + d.normalized * height
            guard clearlyInside(p, view.frustum),
                  clearlyVisible(d, height: height, from: view.position, f, lowest: q.parameters.heightRange.lowerBound)
            else { continue }
            visible += 1
            if cover.count(d) != 1 { misses += 1 }
        }
        XCTAssertEqual(misses, 0, "visible samples not covered exactly once", file: file, line: line)
        XCTAssertGreaterThan(visible, 0, file: file, line: line)
        return visible
    }

    /// The selection's tiles are sorted, and none holds another.
    func assertAntichain(_ s: PlanetQuadtree.Selection, file: StaticString = #filePath, line: UInt = #line) {
        let ids = s.tiles.map(\.key.id)
        XCTAssertEqual(ids, ids.sorted(), file: file, line: line)
        XCTAssertEqual(Set(ids).count, ids.count, file: file, line: line)
        let set = Set(ids)
        for t in s.tiles {
            var k = t.key
            while let p = k.parent {
                XCTAssertFalse(set.contains(p.id), "\(t.key) inside \(p)", file: file, line: line)
                k = p
            }
        }
    }

    /// The least angle (rad) from `d` to a tile, from 256 steps along each
    /// edge, or 0 if it holds `d`: an estimate independent of the
    /// selection's, high by at most half a step (`sampledAngleError`).
    func sampledAngle(_ d: Vec3, to key: TileKey) -> Double {
        if TileKey.containing(d, level: key.level) == key { return 0 }
        var best = -1.0
        for k in 0 ... 256 {
            let t = Double(k) / 256
            for (u, v) in [(t, 0.0), (t, 1), (0, t), (1, t)] {
                best = max(best, d.dot(key.direction(localU: u, localV: v)))
            }
        }
        return acos(min(1, best))
    }

    func sampledAngleError(_ key: TileKey) -> Double {
        CubeSphere.tileAngle(level: key.level) * CubeSphere.maxLinearScale / 500 + 1e-9
    }

    // MARK: Coverage

    /// The visible surface is covered exactly once, from the pad (100 m,
    /// looking at the horizon), from the 100 n mi parking orbit (looking at
    /// the limb and straight down), from 30,000 km (the whole disc), and on
    /// the Moon at 110 km with its relief.
    func testCoversTheVisibleSurfaceExactlyOnce() {
        let pad = earth(maxLevel: 16)
        let padView = look(pad, lat: 28.6, lon: -80.6, altitude: 100, heading: 90, pitch: -2)
        let padSelection = pad.select(padView)
        let nadir = scaled(padView.position, pad.parameters.figure)
        let padHorizon = pad.horizonAngle(position: padView.position, height: 0)!
        assertCoversVisible(padSelection, padView, pad,
                            samples: cap(nadir, radius: padHorizon * 1.02, count: 20_000)
                                + cap(nadir, radius: 2e-4, count: 5_000))
        assertAntichain(padSelection)

        let leo = earth(maxLevel: 9)
        for pitch in [-15.0, -90] {
            let v = look(leo, lat: 28.6, lon: -80.6, altitude: 185_000, heading: 72, pitch: pitch)
            let s = leo.select(v)
            let c = scaled(v.position, leo.parameters.figure)
            assertCoversVisible(s, v, leo, samples: cap(c, radius: 14.5 * deg, count: 20_000))
            assertAntichain(s)
        }

        let far = earth(maxLevel: 6)
        let farView = look(far, lat: -10, lon: 30, altitude: 3e7, pitch: -90)
        let farSelection = far.select(farView)
        assertCoversVisible(farSelection, farView, far,
                            samples: cap(scaled(farView.position, far.parameters.figure), radius: 85 * deg,
                                         count: 20_000))

        let m = moon()
        let mv = look(m, lat: 0.7, lon: 23.4, altitude: 110_000, heading: 0, pitch: -20)
        let ms = m.select(mv)
        let mc = scaled(mv.position, m.parameters.figure)
        for h in [0.0, PlanetQuadtree.moonRelief.upperBound] {
            assertCoversVisible(ms, mv, m, samples: cap(mc, radius: 25 * deg, count: 20_000), height: h)
        }
        assertAntichain(ms)
    }

    // MARK: Horizon culling

    /// On a smooth sphere the selection reaches exactly to the analytic
    /// horizon: acos(R/(R + h)), at the tangent distance √((R + h)² - R²).
    /// Every tile reaches within it, and every point short of it is covered.
    func testHorizonCullingAgainstTheAnalyticHorizon() {
        let q = moon(maxLevel: 8, relief: 0 ... 0)
        for altitude in [15_000.0, 110_000, 1_000_000, 6e7] {
            let r = moonRadius + altitude
            let position = Vec3(0.3, -0.5, 0.81).normalized * r
            let v = PlanetQuadtree.View(position: position, pixelAngle: 50 * deg / 1964)
            let alpha = acos(moonRadius / r)
            XCTAssertEqual(q.horizonAngle(position: position, height: 0)!, alpha, accuracy: 1e-12)
            let tangent = (r * r - moonRadius * moonRadius).squareRoot()
            let atHorizon = (r * r + moonRadius * moonRadius - 2 * r * moonRadius * cos(alpha)).squareRoot()
            XCTAssertEqual(atHorizon, tangent, accuracy: tangent * 1e-9)

            let s = q.select(v)
            assertAntichain(s)
            let up = position.normalized
            for t in s.tiles {
                // Its nearest point is no farther than the horizon point.
                XCTAssertLessThanOrEqual(sampledAngle(up, to: t.key), alpha + sampledAngleError(t.key),
                                         "\(t.key) at \(altitude) m")
                XCTAssertLessThanOrEqual(t.distance, tangent * (1 + 1e-9))
            }
            // Points short of the horizon distance are covered once.
            let cover = Cover(s)
            for d in cap(up, radius: alpha * 1.05, count: 8_000) {
                let distance = (d * moonRadius - position).length
                if distance < tangent * (1 - 1e-6) { XCTAssertEqual(cover.count(d), 1, "\(altitude) m") }
            }
            // The selection's area is at least the visible cap's 2π(1 - cos α).
            let area = s.tiles.map(\.key.solidAngle).reduce(0, +)
            XCTAssertGreaterThanOrEqual(area, 2 * Double.pi * (1 - cos(alpha)))
        }
    }

    /// With relief the horizon test lowers the occluder to the lowest
    /// surface and raises each tile to its highest: peaks of +10.8 km show
    /// over a -9.1 km horizon out to acos(ρ/r) + acos(ρ/(R + 10.8 km)), past
    /// the smooth horizon. Per-tile heights cull flat tiles there and keep
    /// the mountains.
    func testHorizonCullingWithMaxRelief() {
        let relief = PlanetQuadtree.moonRelief
        let q = moon(maxLevel: 8, relief: relief)
        let position = Vec3(-0.2, 0.9, 0.1).normalized * (moonRadius + 110_000)
        let up = position.normalized
        let v = PlanetQuadtree.View(position: position, pixelAngle: 50 * deg / 1964)
        let rho = (moonRadius + relief.lowerBound) / moonRadius, rc = position.length / moonRadius
        let limit = acos(rho / rc) + acos(rho / ((moonRadius + relief.upperBound) / moonRadius))
        XCTAssertEqual(q.horizonAngle(position: position, height: relief.upperBound)!, limit, accuracy: 1e-12)
        let smooth = acos(moonRadius / position.length)
        XCTAssertGreaterThan(limit, smooth + 3 * deg)

        let s = q.select(v)
        let angles = s.tiles.map { sampledAngle(up, to: $0.key) }
        for (t, angle) in zip(s.tiles, angles) {
            XCTAssertLessThanOrEqual(angle, limit + sampledAngleError(t.key), "\(t.key)")
        }
        XCTAssertTrue(angles.contains { $0 > smooth + 1 * deg })
        // Every peak that could show is covered, checked by direct geometry.
        assertCoversVisible(s, v, q, samples: cap(up, radius: limit * 1.02, count: 20_000), height: relief.upperBound)

        // Per tile: mountains in one band of azimuths beyond the smooth
        // horizon, flat ground elsewhere.
        let east = Vec3.unitZ.cross(up).normalized
        func mountainous(_ key: TileKey) -> Bool { key.centre.dot(east) > 0.25 }
        var p = q.parameters
        p.heightRange = 0 ... relief.upperBound
        p.tileHeights = { key in mountainous(key) ? 0 ... relief.upperBound : 0 ... 0 }
        let tiled = PlanetQuadtree(p).select(v)
        var beyond = 0
        for t in tiled.tiles where !mountainous(t.key) || sampledAngle(up, to: t.key) > smooth + 0.5 * deg {
            let angle = sampledAngle(up, to: t.key)
            if mountainous(t.key) {
                beyond += 1
            } else {
                // Flat tiles stop at the smooth horizon.
                XCTAssertLessThanOrEqual(angle, smooth + sampledAngleError(t.key), "\(t.key)")
            }
        }
        XCTAssertGreaterThan(beyond, 0)
    }

    /// The frustum culls what the camera does not face: looking at the limb
    /// from orbit keeps far fewer tiles than the horizon alone, and no tile
    /// far outside the field of view.
    func testFrustumCulling() {
        let q = earth(maxLevel: 9)
        let v = look(q, lat: 28.6, lon: -80.6, altitude: 185_000, heading: 72, pitch: -15)
        var all = v
        all.frustum = nil
        let s = q.select(v), everything = q.select(all)
        XCTAssertLessThan(s.tiles.count, everything.tiles.count / 2)
        let fr = v.frustum!
        let forward = (fr.normals[0] + fr.normals[1]).normalized
        let halfDiagonal = atan(hypot(tan(25 * deg) * 3024 / 1964, tan(25 * deg)))
        for t in s.tiles {
            let centre = q.parameters.figure.surfacePoint(figureDirection: t.key.centre)
            let corner = q.parameters.figure.surfacePoint(figureDirection: t.key.corners[0])
            let toTile = centre - v.position
            let spread = asin(min(1, (corner - centre).length * CubeSphere.maxLinearScale / toTile.length))
            XCTAssertLessThanOrEqual(angleBetween(toTile, forward), halfDiagonal + 2 * spread + 1 * deg, "\(t.key)")
        }
    }

    // MARK: Budget and determinism

    /// The selection is a function of its inputs, and stays under the tile
    /// budget: as the budget shrinks, the LOD bias grows and then the level
    /// limit falls, and coverage holds throughout.
    func testDeterministicAndUnderBudget() {
        var previous: PlanetQuadtree.Selection?
        let probe = earth(maxLevel: 16)
        let v = look(probe, lat: 28.6, lon: -80.6, altitude: 100, heading: 90, pitch: -2)
        let unbounded = probe.select(v)
        XCTAssertGreaterThan(unbounded.tiles.count, 600)
        XCTAssertEqual(unbounded.lodBias, 0)
        let nadir = scaled(v.position, probe.parameters.figure)
        let samples = cap(nadir, radius: 0.33 * deg, count: 8_000) + cap(nadir, radius: 2e-4, count: 2_000)
        for budget in [100_000, 512, 256, 128, 64, 24, 6, 1] {
            let q = earth(maxLevel: 16, budget: budget)
            let s = q.select(v)
            XCTAssertLessThanOrEqual(s.tiles.count, max(budget, 6), "budget \(budget)")
            XCTAssertEqual(q.select(v), s)
            XCTAssertEqual(earth(maxLevel: 16, budget: budget).select(v), s)
            if let p = previous {
                XCTAssertGreaterThanOrEqual(s.lodBias, p.lodBias)
                XCTAssertLessThanOrEqual(s.levelLimit, p.levelLimit)
            }
            assertAntichain(s)
            assertCoversVisible(s, v, q, samples: samples)
            previous = s
        }
        XCTAssertEqual(previous?.lodBias, 8)
    }

    /// Given the last frame's selection, the search starts half an octave
    /// below its bias: for the same view it lands on the same tiles, more
    /// cheaply; after a coarser frame it brings detail back half an octave
    /// at a time; and it climbs back out of a level limit the budget forced.
    func testSelectionFromThePreviousFrame() {
        let q = earth(maxLevel: 16, budget: 128)
        let v = look(q, lat: 28.6, lon: -80.6, altitude: 100, heading: 90, pitch: -2)
        let cold = q.select(v)
        XCTAssertGreaterThan(cold.lodBias, 1)
        let warm = q.select(v, previous: cold)
        XCTAssertEqual(warm.tiles, cold.tiles)
        XCTAssertEqual(warm.lodBias, cold.lodBias)
        XCTAssertLessThan(warm.nodesVisited, cold.nodesVisited)

        let tight = earth(maxLevel: 16, budget: 24).select(v)
        XCTAssertGreaterThan(tight.lodBias, cold.lodBias + 0.5)
        let easing = q.select(v, previous: tight)
        XCTAssertEqual(easing.lodBias, tight.lodBias - 0.5)
        XCTAssertLessThanOrEqual(easing.tiles.count, 128)
        var s = easing
        for _ in 0 ..< 40 { s = q.select(v, previous: s) }
        XCTAssertEqual(s.tiles, cold.tiles)

        let starved = earth(maxLevel: 16, budget: 6).select(v)
        XCTAssertEqual(starved.lodBias, 8)
        XCTAssertLessThan(starved.levelLimit, 16)
        s = starved
        for _ in 0 ..< 60 { s = q.select(v, previous: s) }
        XCTAssertEqual(s.tiles, cold.tiles)
        XCTAssertEqual(s.levelLimit, 16)
    }

    /// Fine enough, under the bias: a leaf above the level limit lies beyond
    /// its biased detail distance, where its samples subtend at most
    /// `pixelError` · 2^bias pixels; detail distances halve per level; morph
    /// bands run from a level's own detail distance (plus the start ratio)
    /// to its parent's.
    func testDetailDistancesAndMorphBands() {
        let q = earth(maxLevel: 12, budget: 200)
        let v = look(q, lat: 28.6, lon: -80.6, altitude: 2_000, heading: 90, pitch: -10)
        let s = q.select(v)
        XCTAssertGreaterThan(s.lodBias, 0)
        let d7 = q.detailDistance(level: 7, pixelAngle: v.pixelAngle)
        XCTAssertEqual(d7, 6_378_137 * Double.pi / 2 / 128 / 256 / v.pixelAngle, accuracy: 1e-6)
        XCTAssertEqual(q.detailDistance(level: 8, pixelAngle: v.pixelAngle), d7 / 2, accuracy: 1e-9)
        let scale = pow(2, -s.lodBias)
        for t in s.tiles {
            let l = t.key.level
            let detail = q.detailDistance(level: l, pixelAngle: v.pixelAngle) * scale
            if l < s.levelLimit { XCTAssertGreaterThanOrEqual(t.distance, detail * (1 - 1e-12), "\(t.key)") }
            guard l > 0 else { continue }
            XCTAssertEqual(t.morphEnd, detail * 2, accuracy: detail * 1e-12)
            XCTAssertEqual(t.morphStart, detail * (1 + 2.0 / 3), accuracy: detail * 1e-12)
            XCTAssertEqual(t.morph(atDistance: t.morphStart), 0)
            XCTAssertEqual(t.morph(atDistance: t.morphEnd), 1)
            XCTAssertEqual(t.morph(atDistance: (t.morphStart + t.morphEnd) / 2), 0.5, accuracy: 1e-12)
        }
        let root = PlanetQuadtree.Tile(key: .root(.posX), distance: 0, morphStart: .infinity, morphEnd: .infinity)
        XCTAssertEqual(root.morph(atDistance: 1e12), 0)
    }

    // MARK: Cracks

    /// The vertex grid's morph rule: odd vertices go to the midpoint of
    /// their even neighbours along the edge, centres along the cell's
    /// (0, 0)-(1, 1) diagonal.
    func testMorphTargets() {
        XCTAssertNil(PlanetQuadtree.morphTargets(column: 4, row: 0))
        XCTAssertEqual(PlanetQuadtree.morphTargets(column: 3, row: 0).map { [$0.0, $0.1, $0.2, $0.3] }, [2, 0, 4, 0])
        XCTAssertEqual(PlanetQuadtree.morphTargets(column: 0, row: 5).map { [$0.0, $0.1, $0.2, $0.3] }, [0, 4, 0, 6])
        XCTAssertEqual(PlanetQuadtree.morphTargets(column: 1, row: 1).map { [$0.0, $0.1, $0.2, $0.3] }, [0, 0, 2, 2])
    }

    /// The grid points along `edge` of a tile's `n`-quad grid, as (column,
    /// row), counter-clockwise round the tile seen from outside.
    func edgeIndices(_ edge: TileKey.Edge, _ n: Int) -> [(Int, Int)] {
        (0 ... n).map { k -> (Int, Int) in
            switch edge {
            case .minV: return (k, 0)
            case .maxU: return (n, k)
            case .maxV: return (n - k, n)
            case .minU: return (0, n - k)
            }
        }
    }

    func gridDirection(_ key: TileKey, _ i: Int, _ j: Int, _ n: Int) -> Vec3 {
        key.direction(localU: Double(i) / Double(n), localV: Double(j) / Double(n))
    }

    /// Where MR2 draws vertex (i, j) of tile `t`'s `n`-quad grid
    /// (planet-tiles.md): its own point, placed with its level's heights,
    /// moved toward its morph target (`morphTargets`), placed with the
    /// parent level's, by the morph `Tile.morph(column:row:gridSize:
    /// distance:)` gives at its own point's distance. `place` puts a figure
    /// direction at a level's height.
    func drawn(_ t: PlanetQuadtree.Tile, _ i: Int, _ j: Int, _ n: Int, camera: Vec3,
               place: (Vec3, Int) -> Vec3) -> Vec3 {
        let level = t.key.level
        let own = place(gridDirection(t.key, i, j, n), level)
        let m = t.morph(column: i, row: j, gridSize: n, distance: (own - camera).length)
        guard m > 0 else { return own }
        let target: Vec3
        if let (i0, j0, i1, j1) = PlanetQuadtree.morphTargets(column: i, row: j) {
            let p0 = place(gridDirection(t.key, i0, j0, n), level - 1)
            let p1 = place(gridDirection(t.key, i1, j1, n), level - 1)
            target = (p0 + p1) / 2
        } else {
            target = place(gridDirection(t.key, i, j, n), level - 1)
        }
        return own + (target - own) * m
    }

    /// The distance from `p` to the segment from `a` to `b`.
    func distance(_ p: Vec3, toSegment a: Vec3, _ b: Vec3) -> Double {
        let ab = b - a
        let t = min(1, max(0, (p - a).dot(ab) / ab.lengthSquared))
        return (p - (a + ab * t)).length
    }

    /// The selected tile that covers same-level tile `k`: itself or an
    /// ancestor; nil if `k` is split (finer) or culled.
    func cover(_ k: TileKey, _ byID: [UInt64: PlanetQuadtree.Tile]) -> PlanetQuadtree.Tile? {
        var level = k.level
        while true {
            if let t = byID[k.ancestor(atLevel: level).id] { return t }
            if level == 0 { return nil }
            level -= 1
        }
    }

    /// What same-level tile `k`'s area holds in a selection, seen from a
    /// tile it touches: a selected tile of its level, part of a coarser one,
    /// or selected tiles among `quarters` (its children that touch).
    func expectedSeam(_ k: TileKey, quarters: [Int], _ byID: [UInt64: PlanetQuadtree.Tile]) -> PlanetQuadtree.Seam {
        if byID[k.id] != nil { return .level }
        if cover(k, byID) != nil { return .coarser }
        return quarters.contains { byID[k.children[$0].id] != nil } ? .finer : .level
    }

    /// The seams of tile `a` in a selection, from their definition
    /// (`Tile.seams`): each edge's neighbour, and the greatest of each
    /// corner's other tiles.
    func assertSeams(_ a: PlanetQuadtree.Tile, _ byID: [UInt64: PlanetQuadtree.Tile], _ name: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        // `TileKey.children` indices along each edge, and at each corner.
        let along: [TileKey.Edge: [Int]] = [.minU: [0, 2], .maxU: [1, 3], .minV: [0, 1], .maxV: [2, 3]]
        let atCorner = [0, 1, 3, 2]
        for edge in TileKey.Edge.allCases {
            let (k, back) = a.key.neighborAndEdge(edge)
            XCTAssertEqual(a.seam(edge), expectedSeam(k, quarters: along[back]!, byID), "\(name): \(a.key) \(edge)",
                           file: file, line: line)
        }
        for corner in 0 ..< 4 {
            var expected = PlanetQuadtree.Seam.level
            for (k, c) in a.key.tilesAround(corner: corner) where k != a.key {
                let m = expectedSeam(k, quarters: [atCorner[c]], byID)
                if m.rawValue > expected.rawValue { expected = m }
            }
            XCTAssertEqual(a.seam(corner: corner), expected, "\(name): \(a.key) corner \(corner)", file: file, line: line)
        }
    }

    /// No cracks between neighbouring tiles, on either side of a level
    /// change: tiles that touch, across an edge or at a corner, differ by
    /// at most one level, every tile's seams are what it meets, and along
    /// every edge two selected tiles share, the vertices MR2 draws (`drawn`)
    /// meet. Each level has its own heights (as a pyramid's levels do), so a
    /// vertex drawn with another level's heights, or a coarse vertex
    /// morphing where the finer side cannot follow, opens a gap:
    /// - same level: the shared vertices are drawn at the same points;
    /// - finer beside coarser: the finer tile's even vertices are drawn at
    ///   the coarse tile's consecutive drawn vertices, and its odd ones on
    ///   the coarse tile's drawn segments between them (T-junctions).
    ///
    /// Views: the pad, also under a tight budget, near a cube corner, the
    /// limb from orbit under a tight budget and at warp, a grid too coarse
    /// for its tiles, which the balancing pass splits, the Moon's terrain on
    /// its relief at 15 km over a face edge, and the Moon setup
    /// planet-tiles.md recommends, budget-biased. The fine side is fully
    /// morphed by distance everywhere. Under the heavier biases and beside
    /// balancing splits, coarse tiles' shared-edge vertices lie past their
    /// morph start, where only the seams keep them on their own grid; in the
    /// other views the distance morph alone already does.
    func testNoCracksBetweenNeighbouringLevels() {
        let n = 16
        let cornerDirection = Vec3(1, 1, 1).normalized
        let g = Ellipsoid.wgs84.geodeticCoordinates(figureDirection: cornerDirection)
        let fineEarth = earth(maxLevel: 16)
        var leoWarp = look(earth(maxLevel: 12), lat: 28.6, lon: -80.6, altitude: 185_000, heading: 72, pitch: -15)
        leoWarp.groundSpeed = 7_400; leoWarp.warp = 100
        let coarseGrid = PlanetQuadtree(.init(figure: .sphere(moonRadius), maxLevel: 14, samplesPerTile: 16,
                                              pixelError: 200))
        let edgeOfFace = Ellipsoid.sphere(moonRadius).geodeticCoordinates(figureDirection: Vec3(1, 0.999, 0.2))
        let moonView = look(moon(), lat: edgeOfFace.latitude / deg, lon: edgeOfFace.longitude / deg,
                            altitude: 15_000, heading: 80, pitch: -12)
        let relief: (Vec3) -> Double = { d in 8_000 * sin(5 * d.x) * cos(3 * d.y) + 800 * d.z }
        let flat: (Vec3) -> Double = { _ in 0 }
        // (name, quadtree, view, terrain, whether the distance morph alone
        // keeps the coarse side's shared-edge vertices on their own grid).
        let cases: [(String, PlanetQuadtree, PlanetQuadtree.View, (Vec3) -> Double, Bool)] = [
            ("pad", fineEarth, look(fineEarth, lat: 28.6, lon: -80.6, altitude: 100, heading: 90, pitch: -2), flat,
             true),
            // Bias 3.5.
            ("pad, budget", earth(maxLevel: 16, budget: 48),
             look(fineEarth, lat: 28.6, lon: -80.6, altitude: 100, heading: 90, pitch: -2), flat, false),
            ("cube corner", earth(maxLevel: 12),
             look(earth(maxLevel: 12), lat: g.latitude / deg + 1, lon: g.longitude / deg - 2, altitude: 1_000_000,
                  heading: 20, pitch: -70), flat, true),
            // Bias 1.5.
            ("limb, budget", earth(maxLevel: 12, budget: 96),
             look(earth(maxLevel: 12), lat: 28.6, lon: -80.6, altitude: 185_000, heading: 72, pitch: -15), flat,
             true),
            ("limb, warp", earth(maxLevel: 12), leoWarp, flat, true),
            // Detail distances shorter than the tiles (pixelError 200 on
            // 16-sample tiles) make the selection two or more levels
            // finer than a neighbour around the camera: the balancing pass
            // must split.
            ("coarse grid", coarseGrid, look(coarseGrid, lat: 3, lon: 40, altitude: 10, heading: 30, pitch: 0), flat,
             false),
            ("moon", moon(maxLevel: 12, budget: 3_000), moonView, relief, true),
            // Bias 2.5.
            ("moon, budget", moon(maxLevel: 16, budget: 384), moonView, relief, false),
        ]
        var acrossFaces = 0, balanced = 0
        for (name, q, view, height, distanceHolds) in cases {
            let s = q.select(view)
            let f = q.parameters.figure
            // Each level's heights differ from the next's by half a metre.
            func place(_ d: Vec3, _ level: Int) -> Vec3 {
                let h: Double = height(d) + 0.5 * Double(level)
                return f.surfacePoint(figureDirection: d) + d.normalized * h
            }
            func draw(_ t: PlanetQuadtree.Tile, _ ij: (Int, Int)) -> Vec3 {
                drawn(t, ij.0, ij.1, n, camera: view.position, place: place)
            }
            // The morph by distance alone, on the terrain without the levels' offsets.
            func byDistance(_ t: PlanetQuadtree.Tile, _ ij: (Int, Int)) -> Double {
                let d = gridDirection(t.key, ij.0, ij.1, n)
                let p = f.surfacePoint(figureDirection: d) + d.normalized * height(d)
                return t.morph(atDistance: (p - view.position).length)
            }
            var byID: [UInt64: PlanetQuadtree.Tile] = [:]
            for t in s.tiles { byID[t.key.id] = t }
            var finerCoarser = 0, pinned = 0
            for a in s.tiles {
                assertSeams(a, byID, name)
                // Tiles that touch a corner are within a level of each other.
                for corner in 0 ..< 4 {
                    for (k, _) in a.key.tilesAround(corner: corner) {
                        guard let b = cover(k, byID) else { continue }
                        XCTAssertLessThanOrEqual(a.key.level - b.key.level, 1, "\(name): \(a.key) touches \(b.key)")
                    }
                }
                for edge in TileKey.Edge.allCases {
                    let (k, back) = a.key.neighborAndEdge(edge)
                    guard let b = cover(k, byID) else { continue }      // finer, or culled
                    XCTAssertLessThanOrEqual(a.key.level - b.key.level, 1, "\(name): \(a.key) beside \(b.key)")
                    let mine = edgeIndices(edge, n)
                    if b.key.level == a.key.level {
                        let theirs = Array(edgeIndices(back, n).reversed())
                        for (p, q) in zip(mine, theirs) {
                            let dp = gridDirection(a.key, p.0, p.1, n), dq = gridDirection(b.key, q.0, q.1, n)
                            XCTAssertLessThan((dp - dq).length, 1e-15, "\(name): \(a.key) \(edge)")
                            let gap = (draw(a, p) - draw(b, q)).length
                            XCTAssertLessThan(gap, 1e-6, "\(name): \(a.key) \(edge) beside \(b.key)")
                        }
                        continue
                    }
                    guard b.key.level == a.key.level - 1 else { continue }
                    finerCoarser += 1
                    if a.key.face != b.key.face { acrossFaces += 1 }
                    // The finer tile's even vertices are consecutive grid
                    // points of the coarse edge, drawn at the same points.
                    let coarse = edgeIndices(back, n)
                    let coarseDirections = coarse.map { gridDirection(b.key, $0.0, $0.1, n) }
                    var indices: [Int] = []
                    for p in stride(from: 0, through: n, by: 2).map({ mine[$0] }) {
                        let d = gridDirection(a.key, p.0, p.1, n)
                        guard let j = coarseDirections.firstIndex(where: { ($0 - d).length < 1e-14 }) else { continue }
                        indices.append(j)
                        let gap = (draw(a, p) - draw(b, coarse[j])).length
                        XCTAssertLessThan(gap, 1e-6, "\(name): \(a.key) \(edge) beside \(b.key)")
                    }
                    XCTAssertEqual(indices.count, n / 2 + 1, "\(name): \(a.key) \(edge) beside \(b.key)")
                    guard indices.count == n / 2 + 1 else { continue }
                    for (i, j) in zip(indices, indices.dropFirst()) {
                        XCTAssertEqual(abs(i - j), 1, "\(name): \(a.key) \(edge) beside \(b.key)")
                    }
                    // Its odd vertices lie on the coarse edge as drawn.
                    for k in stride(from: 1, to: n, by: 2) {
                        let p = draw(a, mine[k])
                        let q0 = draw(b, coarse[indices[k / 2]]), q1 = draw(b, coarse[indices[k / 2 + 1]])
                        XCTAssertLessThan(distance(p, toSegment: q0, q1), 1e-6, "\(name): \(a.key) \(edge) beside \(b.key)")
                    }
                    // The fine side: fully morphed by distance too. The
                    // coarse side: count the vertices only the seams pin.
                    for p in mine {
                        XCTAssertEqual(byDistance(a, p), 1, accuracy: 1e-12, "\(name): \(a.key) \(edge)")
                    }
                    pinned += indices.filter { byDistance(b, coarse[$0]) > 0 }.count
                }
            }
            XCTAssertGreaterThan(finerCoarser, 0, name)
            if distanceHolds { XCTAssertEqual(pinned, 0, name) } else { XCTAssertGreaterThan(pinned, 0, name) }
            if name == "coarse grid" { balanced = s.balanceSplits }
        }
        XCTAssertGreaterThan(acrossFaces, 0)
        // The balancing pass did split tiles, and its splits held up.
        XCTAssertGreaterThan(balanced, 0)
    }

    /// The balancing pass and the seams on a tree built by hand on face +x:
    /// level-2 leaves, three of them split into level-3 leaves, and one of
    /// those, 3/4/4, into level 4. Its quarter 4/8/8 then touches the
    /// level-2 leaf 2/1/1 at a corner only: an edge-only pass would leave
    /// three levels meeting there; this one splits 2/1/1, and nothing else.
    /// The seams then name what each edge and corner meets.
    func testBalancingAndSeamsOnATreeBuiltByHand() {
        let q = moon(maxLevel: 8, relief: 0 ... 0)
        let view = PlanetQuadtree.View(position: Vec3(3 * moonRadius, 0, 0), pixelAngle: 1e-3)
        var pass = PlanetQuadtree.Pass(context: .init(view, q.parameters), levelLimit: 8, detail: 1)
        func key(_ l: Int, _ x: Int, _ y: Int) -> TileKey { TileKey(face: .posX, level: l, x: x, y: y) }
        let split = PlanetQuadtree.Pass.split
        func divide(_ k: TileKey) {
            pass.nodes[k.id] = split
            for c in k.children { pass.nodes[c.id] = 1e9 }
        }
        divide(.root(.posX))
        for c in TileKey.root(.posX).children { divide(c) }
        for (x, y) in [(1, 2), (2, 1), (2, 2)] { divide(key(2, x, y)) }
        divide(key(3, 4, 4))
        pass.leafCount = pass.nodes.sorted().filter { $0.value >= 0 }.count
        XCTAssertEqual(pass.leafCount, 13 + 11 + 4)
        XCTAssertTrue(pass.balance(budget: 1_000))
        XCTAssertEqual(pass.balanceSplits, 1)
        XCTAssertEqual(pass.nodes[key(2, 1, 1).id], split)
        XCTAssertEqual(pass.leafCount, 12 + 15 + 4)

        var tiles: [TileKey: PlanetQuadtree.Tile] = [:]
        for t in pass.tiles(morphStartRatio: 2.0 / 3) { tiles[t.key] = t }
        let fine = tiles[key(4, 8, 8)]!
        XCTAssertEqual(TileKey.Edge.allCases.map { fine.seam($0) }, [.coarser, .level, .coarser, .level])
        XCTAssertEqual((0 ..< 4).map { fine.seam(corner: $0) }, [.coarser, .coarser, .level, .coarser])
        // Its grid: pinned to the parent's along the coarse edges and
        // corners, by distance inside and along the level edges.
        XCTAssertEqual(fine.morph(column: 0, row: 7, gridSize: 16, distance: 0), 1)
        XCTAssertEqual(fine.morph(column: 7, row: 0, gridSize: 16, distance: 0), 1)
        XCTAssertEqual(fine.morph(column: 16, row: 16, gridSize: 16, distance: 0), 0)
        XCTAssertEqual(fine.morph(column: 16, row: 7, gridSize: 16, distance: 0), 0)
        XCTAssertEqual(fine.morph(column: 16, row: 7, gridSize: 16, distance: 1e12), 1)
        XCTAssertEqual(fine.morph(column: 5, row: 5, gridSize: 16, distance: 1e12), 1)
        // 3/3/4 meets the level-4 tiles across +u: pinned to its own grid there.
        let coarse = tiles[key(3, 3, 4)]!
        XCTAssertEqual(TileKey.Edge.allCases.map { coarse.seam($0) }, [.level, .finer, .level, .level])
        XCTAssertEqual((0 ..< 4).map { coarse.seam(corner: $0) }, [.level, .finer, .finer, .level])
        XCTAssertEqual(coarse.morph(column: 16, row: 9, gridSize: 16, distance: 1e12), 0)
        XCTAssertEqual(coarse.morph(column: 16, row: 16, gridSize: 16, distance: 1e12), 0)
        XCTAssertEqual(coarse.morph(column: 0, row: 9, gridSize: 16, distance: 1e12), 1)
        // A level-2 leaf beside the split 2/1/2, and that split's quarter beside it.
        XCTAssertEqual(tiles[key(2, 0, 2)]!.seam(.maxU), .finer)
        XCTAssertEqual(tiles[key(3, 2, 4)]!.seam(.minU), .coarser)
        XCTAssertEqual(tiles[key(3, 2, 4)]!.seam(corner: 0), .coarser)
        // The balancing split's quarter at the corner: level all round but
        // for 4/8/8, finer, at its corner 2.
        let quarter = tiles[key(3, 3, 3)]!
        XCTAssertEqual(TileKey.Edge.allCases.map { quarter.seam($0) }, [.level, .level, .level, .level])
        XCTAssertEqual((0 ..< 4).map { quarter.seam(corner: $0) }, [.level, .level, .finer, .level])
    }

    // MARK: Motion

    /// Under time warp no tile is finer than the ground covers in four
    /// frames: in the parking orbit at 7.4 km/s over the ground, 1× leaves
    /// the selection alone (tiles down to 493 m are allowed), 10× stops at
    /// level 10 (9.8 km tiles against 4 × 1.2 km), 1000× at level 4 (626 km
    /// against 4 × 123 km), and the count falls with warp. Zero frames per
    /// tile switches the bias off.
    func testMotionBiasCoarsensUnderWarp() {
        let q = earth(maxLevel: 12)
        var v = look(q, lat: 28.6, lon: -80.6, altitude: 185_000, heading: 72, pitch: -40)
        let still = q.select(v)
        v.groundSpeed = 7_400
        var previous = still
        for warp in [1.0, 10, 100, 1_000, 10_000] {
            v.warp = warp
            let s = q.select(v)
            let perFrame = 7_400 * warp / 60
            let face = 6_378_137 * Double.pi / 2
            if s.levelLimit < 12 {
                XCTAssertGreaterThanOrEqual(face / Double(1 << s.levelLimit), 4 * perFrame)
                XCTAssertLessThan(face / Double(1 << (s.levelLimit + 1)), 4 * perFrame)
            }
            XCTAssertTrue(s.tiles.allSatisfy { $0.key.level <= s.levelLimit })
            XCTAssertLessThanOrEqual(s.levelLimit, previous.levelLimit)
            XCTAssertLessThanOrEqual(s.tiles.count, previous.tiles.count)
            if warp == 1 { XCTAssertEqual(s, still) }
            if warp == 10 { XCTAssertEqual(s.levelLimit, 10) }
            if warp == 1_000 { XCTAssertEqual(s.levelLimit, 4) }
            assertCoversVisible(s, v, q, samples: cap(scaled(v.position, q.parameters.figure), radius: 14.5 * deg,
                                                      count: 4_000))
            previous = s
        }
        XCTAssertLessThan(previous.tiles.count, still.tiles.count)

        // No frames per tile switches the bias off, and a ground speed so
        // small that its distance per frame underflows to a subnormal sets
        // no limit: neither may trap on an infinite ratio.
        var p = q.parameters
        p.minimumFramesPerTile = 0
        v.warp = 1_000
        XCTAssertEqual(PlanetQuadtree(p).motionLevelLimit(v), 12)
        XCTAssertEqual(PlanetQuadtree(p).select(v), still)
        p.minimumFramesPerTile = -1
        XCTAssertEqual(PlanetQuadtree(p).motionLevelLimit(v), 12)
        v.groundSpeed = 1e-320; v.warp = 1
        XCTAssertEqual(q.motionLevelLimit(v), 12)
        XCTAssertEqual(q.select(v), still)
    }

    /// Ground speed is the camera's horizontal body-fixed velocity scaled
    /// to the surface; a camera fixed in ICRF above the equator sees the
    /// Earth turn under it at ωR (465 m/s), through the renderer's view.
    func testGroundSpeedAndTheRendererView() {
        let r = 6_378_137.0
        XCTAssertEqual(PlanetQuadtree.groundSpeed(position: Vec3(2 * r, 0, 0), velocity: Vec3(0, 1_000, 0), radius: r),
                       500, accuracy: 1e-9)
        XCTAssertEqual(PlanetQuadtree.groundSpeed(position: Vec3(2 * r, 0, 0), velocity: Vec3(300, 0, 0), radius: r), 0)
        XCTAssertEqual(PlanetQuadtree.groundSpeed(position: Vec3(r, 0, 0), velocity: Vec3(0, 3, 4), radius: r), 5,
                       accuracy: 1e-12)

        let omega = 7.292115e-5
        let o = BodyOrientation(icrfToBody: .identity, angularVelocity: Vec3(0, 0, omega))
        // Looking down at the Earth from 2R along +x: back = +x.
        let worldToView = Mat3(rows: Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 0, 0))
        let q = earth()
        let v = q.view(cameraPosition: Vec3(2 * r, 0, 0), worldToView: worldToView, fovY: 50 * deg,
                       viewportWidth: 3024, viewportHeight: 1964, orientation: o)
        XCTAssertEqual(v.position, Vec3(2 * r, 0, 0))
        XCTAssertEqual(v.groundSpeed, omega * r, accuracy: 1e-9)
        XCTAssertEqual(v.pixelAngle, 50 * deg / 1964, accuracy: 1e-15)
        XCTAssertTrue(v.frustum!.contains(Vec3(r, 0, 0)))
        XCTAssertFalse(v.frustum!.contains(Vec3(3 * r, 0, 0)))
        XCTAssertFalse(v.frustum!.contains(Vec3(r, 2 * r, 0)))
    }
}

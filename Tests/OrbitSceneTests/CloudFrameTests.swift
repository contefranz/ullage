import Foundation
import XCTest
@testable import OrbitCore
@testable import OrbitScene

/// Track C2's per-frame geometry: the shells' ray constants, the noise
/// origin, the reprojection of body-fixed points, the shadow map's frame,
/// the regimes and the advection.
final class CloudFrameTests: XCTestCase {
    /// An Earth whose body axes are turned `angle` about the ICRF z axis,
    /// centred at `center` from the camera.
    private func earth(center: Vec3, angle: Double, toSun: Vec3 = Vec3(1, 0.3, 0.2).normalized) -> RenderScene.Body {
        let o = BodyOrientation(icrfToBody: Mat3.rotZ(angle), angularVelocity: Vec3(0, 0, 7.292115e-5))
        return RenderScene.Body(id: 399, name: "Earth", position: center, orientation: o, figure: .wgs84,
                                radius: 6_371_000, isSun: false, toSun: toSun)
    }

    /// The camera `height` m above the ground at latitude 28.6°, longitude
    /// −80.6°, in a body frame turned by `angle`.
    private func frame(height: Double, angle: Double = 0.3) -> CloudFrame {
        let lat = 28.6 * Double.pi / 180, lon = -80.6 * Double.pi / 180
        let p = Ellipsoid.wgs84.bodyFixed(latitude: lat, longitude: lon, height: height)
        let center = Mat3.rotZ(angle).transposed * (p * -1)
        return CloudFrame(earth: earth(center: center, angle: angle))
    }

    func testGeodeticAndShellConstant() {
        let f = frame(height: 120)
        XCTAssertEqual(f.altitude, 120, accuracy: 1e-3)
        XCTAssertEqual(f.latitude * 180 / .pi, 28.6, accuracy: 1e-9)
        let o = f.cameraFigure, r = f.radius + 2_000
        XCTAssertEqual(f.shellConstant(height: 2_000), o.lengthSquared - r * r, accuracy: 1e-3 * abs(o.lengthSquared - r * r))
        // A shell below the camera: positive, about 2 r (|o| − r).
        XCTAssertGreaterThan(frame(height: 5_000).shellConstant(height: 2_000), 0)
        XCTAssertLessThan(f.shellConstant(height: 2_000), 0)
    }

    func testWrap() {
        let p = CloudFrame.wrap(Vec3(-1, 40_000, 6_378_137.25), tile: 32_768)
        XCTAssertEqual(p.x, 32_767, accuracy: 1e-9)
        XCTAssertEqual(p.y, 40_000 - 32_768, accuracy: 1e-9)
        XCTAssertEqual(p.z, 6_378_137.25 - 194 * 32_768, accuracy: 1e-6)
    }

    /// A body-fixed point seen this frame lands where last frame saw it,
    /// with the Earth turned and the camera moved between them.
    func testReprojectionOfBodyFixedPoints() {
        let now = earth(center: Vec3(-1e6, 6.3e6, 4e5), angle: 0.31)
        let before = earth(center: Vec3(-1.0075e6, 6.3002e6, 4.001e5), angle: 0.3)
        let (r, t) = CloudFrame(earth: now).reprojection(from: CloudFrame(earth: before))
        for x in [Vec3(6.37e6, 1e5, 2e4), Vec3(-2e6, 5e6, 3.1e6)] {
            let pNow = now.orientation.toInertial(x) + now.position
            let pBefore = before.orientation.toInertial(x) + before.position
            let q = r * pNow + t
            XCTAssertEqual((q - pBefore).length, 0, accuracy: 1e-6)
        }
    }

    /// A body-fixed point keeps its cirrus noise coordinate as the camera
    /// moves (but for whole periods, as the origin wraps), and the frame
    /// moves to the camera after 1,000 km or a 30° turn of the wind.
    func testCirrusFrameIsBodyFixed() {
        let period = 16_384.0
        let f = frame(height: 300)
        let east = f.eastNorth.east
        let c = CirrusFrame(f, streak: east)
        func noise(_ point: Vec3, camera: Vec3) -> Vec3 {
            let o = c.origin(camera: camera, period: period), q = point - camera
            return o + Vec3(q.dot(c.along) / CirrusFrame.stretch, q.dot(c.across), q.dot(c.up))
        }
        let point = f.cameraBody + east * 37_000 + f.eastNorth.north * 12_000
        let a = noise(point, camera: f.cameraBody)
        // Cameras 40 km to 400 km away, across many of the old body-axis wraps.
        for k in 1...10 {
            let camera = f.cameraBody + f.eastNorth.north * (40_000 * Double(k)) + east * (13_000 * Double(k))
            let b = noise(point, camera: camera)
            for (x, y) in [(a.x, b.x), (a.y, b.y), (a.z, b.z)] {
                let periods = (y - x) / period
                XCTAssertEqual(periods, periods.rounded(), accuracy: 1e-6, "camera \(k)")
            }
        }
        XCTAssertFalse(c.stale(f, streak: east))
        XCTAssertTrue(c.stale(f, streak: f.eastNorth.north), "the wind turned 90°")
        let distant = Ellipsoid.wgs84.bodyFixed(latitude: (28.6 + 11) * Double.pi / 180, longitude: -80.6 * Double.pi / 180,
                                                height: 300)   // 1,220 km north
        let far = CloudFrame(earth: earth(center: Mat3.rotZ(0.3).transposed * (distant * -1), angle: 0.3))
        XCTAssertTrue(c.stale(far, streak: far.eastNorth.east))
        // A new frame fades the old one out over two seconds.
        var frames = CirrusFrames()
        frames.update(f, streak: east, wind: nil, dt: 1, realDt: 1, period: period)
        XCTAssertNotNil(frames.current)
        XCTAssertNil(frames.previous)
        frames.update(f, streak: f.eastNorth.north, wind: nil, dt: 1, realDt: 1, period: period)
        XCTAssertNotNil(frames.previous)
        XCTAssertEqual(frames.fade, 1)
        frames.update(f, streak: f.eastNorth.north, wind: nil, dt: 1, realDt: 1, period: period)
        XCTAssertEqual(frames.fade, 0.5, accuracy: 1e-12)
        frames.update(f, streak: f.eastNorth.north, wind: nil, dt: 1, realDt: 1, period: period)
        XCTAssertNil(frames.previous)
        // A frame gone stale while the last one still fades waits: the fading
        // one fades on (replaced, it dropped out at once).
        frames.update(f, streak: east, wind: nil, dt: 1, realDt: 1, period: period)
        let fading = frames.previous
        XCTAssertEqual(frames.fade, 1)
        frames.update(f, streak: f.eastNorth.north, wind: nil, dt: 1, realDt: 0.5, period: period)
        XCTAssertEqual(frames.fade, 0.75, accuracy: 1e-12)
        XCTAssertEqual(frames.previous, fading)
        XCTAssertEqual(frames.current?.along.dot(east) ?? 0, 1, accuracy: 1e-9, "the stale one waits")
        frames.update(f, streak: f.eastNorth.north, wind: nil, dt: 1, realDt: 2, period: period)
        XCTAssertEqual(frames.current?.along.dot(f.eastNorth.north) ?? 0, 1, accuracy: 1e-5, "then it is replaced")
    }

    func testShadowMapFrame() {
        let f = frame(height: 300)
        let anchor0 = f.shadowAnchor(previous: nil, previousExtent: nil, texels: 256)
        let map = f.shadowMap(texels: 256, anchor: anchor0)
        XCTAssertEqual(map.extent, 100_000, accuracy: 1e-6)
        XCTAssertEqual(map.u.dot(map.v), 0, accuracy: 1e-12)
        XCTAssertEqual(map.u.dot(map.sun), 0, accuracy: 1e-12)
        XCTAssertEqual(map.u.cross(map.v).dot(map.sun), 1, accuracy: 1e-12)
        // The camera's ground point is within half a texel of the centre.
        let ground = f.cameraBody.normalized * f.radius
        let c = map.coordinates(ground)
        XCTAssertEqual(c.u, 0.5, accuracy: 0.5 / 256 + 1e-9)
        XCTAssertEqual(c.v, 0.5, accuracy: 0.5 / 256 + 1e-9)
        let back = map.point(u: c.u, v: c.v, along: c.along)
        XCTAssertEqual((back - ground).length, 0, accuracy: 1e-6)
        // Moves and climbs within an extent leave the lattice where it was:
        // the centre moves by whole texels, also when the anchor moves (past
        // a quarter of the map) and as the camera climbs (the extent once
        // grew every frame, sliding the lattice a texel or two).
        let lat = 28.6 * Double.pi / 180, lon = -80.6 * Double.pi / 180, texel = map.extent / 256
        func at(_ dLat: Double, _ dLon: Double, _ h: Double, angle: Double = 0.3) -> CloudFrame {
            let p = Ellipsoid.wgs84.bodyFixed(latitude: lat + dLat, longitude: lon + dLon, height: h)
            return CloudFrame(earth: earth(center: Mat3.rotZ(angle).transposed * (p * -1), angle: angle))
        }
        var anchor = anchor0, extent = map.extent
        for (dLat, dLon, h) in [(2e-6, -3e-6, 300.0), (1.8e-3, -2.1e-3, 300), (5.4e-3, -6.3e-3, 1_300),
                                (5.4e-3, -6.3e-3, 20_000)] {
            let g = at(dLat, dLon, h)
            anchor = g.shadowAnchor(previous: anchor, previousExtent: extent, texels: 256)
            let m = g.shadowMap(texels: 256, anchor: anchor)
            extent = m.extent
            XCTAssertEqual(m.extent, 100_000, accuracy: 1e-6)
            for axis in [map.u, map.v] {
                let k = (m.center - map.center).dot(axis) / texel
                XCTAssertEqual(k, k.rounded(), accuracy: 1e-6, "a move of \(dLat), \(dLon) rad to \(h) m")
            }
        }
        // The Sun's turning about the Earth (7.3e-5 rad/s) turns the lattice
        // about the anchor, here 20 km off: a quarter of the map's texels
        // times the turn at most, a quarter of a texel a minute. (Through
        // the Earth's centre it slid more than a texel a second.)
        let off = at(1.8e-3, -2.1e-3, 300)
        let anchorOff = off.shadowAnchor(previous: nil, previousExtent: nil, texels: 256)
        let still = f.shadowMap(texels: 256, anchor: f.shadowAnchor(previous: anchorOff, previousExtent: 100_000, texels: 256))
        for seconds in [1.0, 2, 5, 10, 60] {
            let turned = frame(height: 300, angle: 0.3 + 7.3e-5 * seconds)
            let a = turned.shadowAnchor(previous: anchorOff, previousExtent: 100_000, texels: 256)
            XCTAssertEqual((a - anchorOff).length, 0, "the anchor holds")
            let m = turned.shadowMap(texels: 256, anchor: a)
            for axis in [still.u, still.v] {
                let k = (m.center - still.center).dot(axis) / texel
                XCTAssertLessThan(abs(k - k.rounded()), 64 * 7.3e-5 * seconds + 0.01, "\(seconds) s")
            }
        }
        // A long walk along the ground (1,200 km west, the Sun partly along
        // it) keeps the anchor near the camera, along the Sun too, so the
        // lattice still turns at under a quarter of a texel a minute there
        // (kept off it along the Sun, the anchor drifted away and the lattice
        // turned at several texels a minute).
        var walker = anchor0, walkExtent = map.extent
        var last = f
        for k in 1...40 {
            last = at(0, -5.37e-3 * Double(k), 300)
            walker = last.shadowAnchor(previous: walker, previousExtent: walkExtent, texels: 256)
            walkExtent = last.shadowMap(texels: 256, anchor: walker).extent
        }
        XCTAssertLessThan((walker - last.groundPoint).length, 0.5 * map.extent, "the anchor follows")
        let lastMap = last.shadowMap(texels: 256, anchor: walker)
        let lastLat = 28.6 * Double.pi / 180, lastLon = -80.6 * Double.pi / 180 - 5.37e-3 * 40
        for seconds in [10.0, 60] {
            let p = Ellipsoid.wgs84.bodyFixed(latitude: lastLat, longitude: lastLon, height: 300)
            let angle = 0.3 + 7.3e-5 * seconds
            let turned = CloudFrame(earth: earth(center: Mat3.rotZ(angle).transposed * (p * -1), angle: angle))
            let a = turned.shadowAnchor(previous: walker, previousExtent: walkExtent, texels: 256)
            let m = turned.shadowMap(texels: 256, anchor: a)
            for axis in [lastMap.u, lastMap.v] {
                let k = (m.center - lastMap.center).dot(axis) / texel
                XCTAssertLessThan(abs(k - k.rounded()), 64 * 7.3e-5 * seconds + 0.02, "\(seconds) s after the walk")
            }
        }
        // The extent's ladder: the texel's size changes at four heights.
        for (h, e) in [(300.0, 100_000.0), (24_000, 100_000), (30_000, 200_000), (100_000, 400_000), (185_000, 800_000),
                       (300_000, 1_000_000), (1e8, 1_000_000)] {
            XCTAssertEqual(CloudFrame.shadowExtent(altitude: h), e, accuracy: 1e-6, "\(h) m")
        }
    }

    /// The regimes sum to one and cross smoothly as the camera climbs. The
    /// renderer reads the far weight (3,000-6,000 km); `near` and `orbit`
    /// are reported, and the march's own switch at 13 km is the shell's top.
    func testRegimesAreContinuous() {
        var last = CloudFrame.regimes(altitude: 0)
        XCTAssertEqual(last.near, 1)
        XCTAssertEqual(CloudFrame.regimes(altitude: 185_000).orbit, 1)
        XCTAssertEqual(CloudFrame.regimes(altitude: 3.8e8).far, 1)
        var h = 0.0
        while h < 1e7 {
            h += max(h * 0.01, 10)
            let w = CloudFrame.regimes(altitude: h)
            XCTAssertEqual(w.near + w.orbit + w.far, 1, accuracy: 1e-12)
            XCTAssertLessThan(abs(w.near - last.near) + abs(w.far - last.far), 0.03, "at \(h) m")
            XCTAssertLessThanOrEqual(w.near, last.near)
            XCTAssertGreaterThanOrEqual(w.far, last.far)
            last = w
        }
    }

    func testAdvectionFollowsTheWind() {
        let f = frame(height: 0)
        var a = CloudAdvection(tile: 32_768)
        a.advance(f, winds: [LayerWind(east: 10, north: 0), nil, LayerWind(east: 0, north: -20)], dt: 100)
        let axes = f.eastNorth
        func unwrapped(_ v: Vec3) -> Vec3 {
            func u(_ x: Double) -> Double { x > 16_384 ? x - 32_768 : x }
            return Vec3(u(v.x), u(v.y), u(v.z))
        }
        XCTAssertEqual((unwrapped(a.offsets[0]) - axes.east * -1_000).length, 0, accuracy: 1e-6)
        XCTAssertEqual(a.offsets[1], Vec3(0, 0, 0))
        XCTAssertEqual((unwrapped(a.offsets[2]) - axes.north * 2_000).length, 0, accuracy: 1e-6)
        XCTAssertEqual(axes.east.dot(axes.north), 0, accuracy: 1e-12)
        XCTAssertEqual(axes.north.dot(f.cameraBody.normalized), 0, accuracy: 0.004, "geodetic north is level")
    }

    func testReprojectionRule() {
        XCTAssertTrue(CloudReprojection.allowed(warp: 1, temporalReset: false, motionPixels: 0.4))
        XCTAssertTrue(CloudReprojection.allowed(warp: 9, temporalReset: false, motionPixels: 1.5))
        XCTAssertFalse(CloudReprojection.allowed(warp: 10, temporalReset: false, motionPixels: 0.1))
        XCTAssertFalse(CloudReprojection.allowed(warp: 1, temporalReset: true, motionPixels: 0.1))
        XCTAssertFalse(CloudReprojection.allowed(warp: 1, temporalReset: false, motionPixels: 1.6))
        XCTAssertFalse(CloudReprojection.allowed(warp: 1, temporalReset: false, motionPixels: .nan))
    }
}

/// Track C2's weather map: the assembly kernel's mirror gives C1's
/// `CloudWeather.sample` at the grid points.
final class CloudWeatherMapTests: XCTestCase {
    static let t0: Int64 = -32_000_400  // 1968-12-21 12:00 UTC
    static func epoch(_ posix: Int64) -> Epoch { Epoch(julianDateUTC: 2_440_587.5 + Double(posix) / 86_400) }

    /// A full 0.25° field of three snapshots, pseudo-random, with the cloud
    /// base missing in places.
    static let field: CloudField = {
        let planes = ["lcc", "mcc", "hcc", "cbh"].map { name in
            CloudField.Plane(name: name, columns: CloudWeatherMap.columns, rows: CloudWeatherMap.rows, offset: 0,
                             scale: name == "cbh" ? 60 : 1 / 254)
        }
        let times = [t0, t0 + 3600, t0 + 4 * 3600]
        var state: UInt32 = 12345
        func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state >> 8
        }
        let snapshots = times.map { _ in
            planes.map { p in
                (0..<p.count).map { _ -> UInt8 in
                    let r = next()
                    return p.name == "cbh" ? (r % 5 == 0 ? 255 : UInt8(r % 120)) : UInt8(r % 255)
                }
            }
        }
        return try! CloudField(data: CloudField.encode(planes: planes, utcSeconds: times, note: "test", snapshots: snapshots))
    }()

    /// The texels against the samples at grid points. With the procedural
    /// weather, its nodes (uncalibrated on both sides: the texel's offsets
    /// are smoothed over all 720 nodes, the sample's its estimate from 180)
    /// at grid points that are nodes (even rows and columns).
    private func check(_ weather: CloudWeather, at epoch: Epoch, rows: [Int], columns: [Int],
                       file: StaticString = #filePath, line: UInt = #line) {
        let p = CloudWeatherMap.parameters(weather, at: epoch)
        let first = p.snapshots.map { CloudWeatherMap.interleaved(Self.field, snapshot: $0.first) }
        let second = p.snapshots.map { CloudWeatherMap.interleaved(Self.field, snapshot: $0.second) }
        let state = weather.procedural.map { $0.state(at: epoch) }
        let nodes = state.map { st in
            CloudWeatherMap.ProceduralNodes(node: { j, c in
                let lat = ProceduralWeather.latitude(row: j)
                return ProceduralWeather.node(latitude: lat, longitude: ProceduralWeather.longitude(column: c),
                                              geography: WeatherGeography.earth.texel(row: j, column: c),
                                              band: ProceduralWeather.band(latitude: lat, sky: st.sky), state: st)
            }, offsets: Array(repeating: (0, 0, 0), count: ProceduralWeather.rows))
        }
        for r in rows {
            for c in columns {
                let t = CloudWeatherMap.texel(column: c, row: r, first: first, second: second, parameters: p,
                                              procedural: nodes)
                let s = weather.sample(latitude: CloudWeatherMap.latitude(row: r),
                                       longitude: CloudWeatherMap.longitude(column: c), at: epoch, state: state,
                                       calibrated: state == nil)
                XCTAssertEqual(t.low, s.low, accuracy: 1e-6, "low at \(r), \(c)", file: file, line: line)
                XCTAssertEqual(t.mid, s.mid, accuracy: 1e-6, "mid at \(r), \(c)", file: file, line: line)
                XCTAssertEqual(t.high, s.high, accuracy: 1e-6, "high at \(r), \(c)", file: file, line: line)
                // The cloud base where the grid point has it in both
                // snapshots (CloudField's bilinear borrows a neighbour's
                // where it has none).
                if let first, let second, let snap = p.snapshots {
                    let at = 4 * (r * CloudWeatherMap.columns + c) + 3
                    let known = first[at] != 255 && second[at] != 255 && snap.weight > 0 && snap.weight < 1
                    if known {
                        let layers = CloudLayerModel.layers(s)
                        XCTAssertEqual(t.lowBase, layers[0].base, accuracy: 1e-6, file: file, line: line)
                        XCTAssertEqual(t.lowTop, layers[0].top, accuracy: 1e-6, file: file, line: line)
                    }
                }
                // Fading into the procedural weather: the low layer's heights
                // and kind go linearly on both sides, from the field's at its
                // edge (where the grid point has a base there, or none in
                // both snapshots) to the procedural weather's.
                if state != nil, p.fieldWeight > 0, p.fieldWeight < 1, let first, let second {
                    let at = 4 * (r * CloudWeatherMap.columns + c) + 3
                    if (first[at] != 255) == (second[at] != 255) {
                        let layers = CloudLayerModel.layers(s)
                        XCTAssertEqual(t.lowBase, layers[0].base, accuracy: 1e-6, "base at \(r), \(c)", file: file, line: line)
                        XCTAssertEqual(t.lowTop, layers[0].top, accuracy: 1e-6, "top at \(r), \(c)", file: file, line: line)
                        XCTAssertEqual(t.cumuliform, s.cumuliform ?? 0.5, accuracy: 1e-6, file: file, line: line)
                    }
                }
            }
        }
    }

    func testMirrorGivesTheWeather() {
        let rows = [0, 1, 200, 360, 719, 720], columns = [0, 3, 700, 1439]
        let weather = CloudWeather(field: Self.field)
        check(weather, at: Self.epoch(Self.t0 + 1800), rows: rows, columns: columns)
        check(weather, at: Self.epoch(Self.t0 + 3600 + 5000), rows: rows, columns: columns)
        // Beyond the span: fading into the climatology, then the climatology.
        check(weather, at: Self.epoch(Self.t0 + 4 * 3600 + 4000), rows: rows, columns: columns)
        check(weather, at: Self.epoch(Self.t0 + 9 * 3600), rows: rows, columns: columns)
        // No field at all.
        check(CloudWeather(), at: Self.epoch(Self.t0), rows: rows, columns: columns)
    }

    /// Beyond the field's span with the procedural weather (the renderer's
    /// weather in "historic"): through the fade, at its start, a third, past
    /// halfway and its end, and before the field's first snapshot.
    func testMirrorFadesIntoTheProceduralWeather() {
        let rows = [0, 200, 360, 486, 720], columns = [0, 2, 700, 1438]
        let weather = CloudWeather(field: Self.field, procedural: ProceduralWeather(seed: 1))
        for away in [0.0, 600, 3600, 6000, 10_000, 12_000] {
            check(weather, at: Self.epoch(Self.t0 + 4 * 3600) + away, rows: rows, columns: columns)
        }
        check(weather, at: Self.epoch(Self.t0) + (-5000), rows: rows, columns: columns)
    }

    /// The pad's observed sky, blended in around LC-39A at Apollo 8's launch.
    func testMirrorTakesThePadOverride() throws {
        let o = try XCTUnwrap(CloudOverride.launches["apollo8"])
        let weather = CloudWeather(field: Self.field, overrides: [o])
        let r = Int((90 - o.latitude * 180 / .pi) * 4), c = Int(((o.longitude * 180 / .pi) + 360) * 4) % 1440
        check(weather, at: o.time, rows: Array(r - 2...r + 2), columns: Array(c - 2...c + 2))
        let p = CloudWeatherMap.parameters(weather, at: o.time)
        let t = CloudWeatherMap.texel(column: c, row: r, first: CloudWeatherMap.interleaved(Self.field, snapshot: 0),
                                      second: CloudWeatherMap.interleaved(Self.field, snapshot: 1), parameters: p)
        XCTAssertEqual(t.high, 0.4, accuracy: 0.01, "4/10 cirrus at the pad")
        XCTAssertEqual(t.low, 0, accuracy: 0.01)
    }

    func testMissionByEpoch() {
        XCTAssertEqual(CloudWeatherMap.mission(at: Epoch(utcYear: 1968, month: 12, day: 22, hour: 3, minute: 0)), "apollo8")
        XCTAssertEqual(CloudWeatherMap.mission(at: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)), "apollo11")
        XCTAssertEqual(CloudWeatherMap.mission(at: Epoch(utcYear: 1968, month: 10, day: 22, hour: 11, minute: 0)), "apollo7")
        XCTAssertNil(CloudWeatherMap.mission(at: Epoch(utcYear: 1970, month: 4, day: 11, hour: 19, minute: 13)))
    }

    func testInterleavedOrder() {
        let bytes = CloudWeatherMap.interleaved(Self.field, snapshot: 2)
        let j = 777 * 1440 / 2 + 31
        for (k, name) in CloudWeatherMap.snapshotPlanes.enumerated() {
            let plane = Self.field.bytes(plane: Self.field.plane(name)!, snapshot: 2)
            XCTAssertEqual(bytes[4 * j + k], plane[plane.startIndex + j])
        }
    }
}

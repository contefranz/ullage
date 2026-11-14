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

    func testShadowMapFrame() {
        let f = frame(height: 300)
        let map = f.shadowMap(texels: 512)
        XCTAssertEqual(map.extent, 101_200, accuracy: 1e-6)
        XCTAssertEqual(map.u.dot(map.v), 0, accuracy: 1e-12)
        XCTAssertEqual(map.u.dot(map.sun), 0, accuracy: 1e-12)
        XCTAssertEqual(map.u.cross(map.v).dot(map.sun), 1, accuracy: 1e-12)
        // The camera's ground point is within half a texel of the centre.
        let ground = f.cameraBody.normalized * f.radius
        let c = map.coordinates(ground)
        XCTAssertEqual(c.u, 0.5, accuracy: 0.5 / 512 + 1e-9)
        XCTAssertEqual(c.v, 0.5, accuracy: 0.5 / 512 + 1e-9)
        let back = map.point(u: c.u, v: c.v, along: c.along)
        XCTAssertEqual((back - ground).length, 0, accuracy: 1e-6)
        // A small move of the camera leaves the snapped centre where it was,
        // or moves it by whole texels.
        let lat = 28.6 * Double.pi / 180, lon = -80.6 * Double.pi / 180
        let p = Ellipsoid.wgs84.bodyFixed(latitude: lat + 2e-6, longitude: lon - 3e-6, height: 300)
        let moved = CloudFrame(earth: earth(center: Mat3.rotZ(0.3).transposed * (p * -1), angle: 0.3))
            .shadowMap(texels: 512)
        let shift = moved.center - map.center, texel = map.extent / 512
        for axis in [map.u, map.v] {
            let k = shift.dot(axis) / texel
            XCTAssertEqual(k, k.rounded(), accuracy: 1e-6)
        }
        // A frame of the Sun's turning about the Earth (7.3e-5 rad/s, 1/60 s)
        // moves the grid by a small fraction of a texel.
        let turned = frame(height: 300, angle: 0.3 + 7.3e-5 / 60).shadowMap(texels: 512)
        XCTAssertLessThan((turned.center - map.center).length, 0.05 * texel)
        XCTAssertEqual(CloudFrame.shadowExtent(altitude: 185_000), 840_000, accuracy: 1e-6)
        XCTAssertEqual(CloudFrame.shadowExtent(altitude: 1e8), 1_000_000, accuracy: 1e-6)
    }

    /// The regimes sum to one and cross smoothly as the camera climbs.
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

    private func check(_ weather: CloudWeather, at epoch: Epoch, rows: [Int], columns: [Int],
                       file: StaticString = #filePath, line: UInt = #line) {
        let p = CloudWeatherMap.parameters(weather, at: epoch)
        let first = p.snapshots.map { CloudWeatherMap.interleaved(Self.field, snapshot: $0.first) }
        let second = p.snapshots.map { CloudWeatherMap.interleaved(Self.field, snapshot: $0.second) }
        for r in rows {
            for c in columns {
                let t = CloudWeatherMap.texel(column: c, row: r, first: first, second: second, parameters: p)
                let s = weather.sample(latitude: CloudWeatherMap.latitude(row: r),
                                       longitude: CloudWeatherMap.longitude(column: c), at: epoch)
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

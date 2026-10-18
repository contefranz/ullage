import XCTest
@testable import OrbitCore

/// The Earth's figure (`Ellipsoid`) against published geodesy.
final class EllipsoidTests: XCTestCase {
    let deg = Double.pi / 180
    let wgs84 = Ellipsoid.wgs84

    /// Degrees from degrees, minutes and seconds.
    func dms(_ d: Double, _ m: Double, _ s: Double) -> Double { (d + m / 60 + s / 3600) * deg }

    // WGS 84's derived constants (NIMA TR8350.2, 3rd ed., Table 3.3):
    // b 6,356,752.3142 m and e² 6.69437999014e-3.
    func testWGS84DerivedConstants() {
        XCTAssertEqual(wgs84.polarRadius, 6_356_752.3142, accuracy: 1e-4)
        XCTAssertEqual(wgs84.eccentricitySquared, 6.69437999014e-3, accuracy: 1e-14)
        XCTAssertEqual(Ellipsoid.fischer1960.polarRadius, 6_378_166 * (1 - 1 / 298.3), accuracy: 1e-6)
        XCTAssertEqual(Ellipsoid.sphere(1_737_400).polarRadius, 1_737_400)
    }

    // IOGP Publication 373-7-2 (Geomatics Guidance Note 7, part 2), §4.1.1,
    // geographic/geocentric conversions (EPSG 9602), worked example on WGS
    // 84: 53°48'33.820"N, 2°07'46.380"E, h 73.000 m is X 3,771,793.968 m,
    // Y 140,253.342 m, Z 5,124,304.349 m. Both ways, to 1 mm.
    func testIOGPGeocentricExample() {
        let lat = dms(53, 48, 33.820), lon = dms(2, 7, 46.380)
        let p = wgs84.bodyFixed(latitude: lat, longitude: lon, height: 73)
        XCTAssertEqual(p.x, 3_771_793.968, accuracy: 1e-3)
        XCTAssertEqual(p.y, 140_253.342, accuracy: 1e-3)
        XCTAssertEqual(p.z, 5_124_304.349, accuracy: 1e-3)
        let g = wgs84.geodetic(Vec3(3_771_793.968, 140_253.342, 5_124_304.349))
        // 1 mm on the ground is 1.6e-10 rad.
        XCTAssertEqual(g.latitude, lat, accuracy: 1.6e-10)
        XCTAssertEqual(g.longitude, lon, accuracy: 1.6e-10)
        XCTAssertEqual(g.height, 73, accuracy: 1e-3)
    }

    // Round trips: from 6,000 km below the surface (inside the Earth, outside
    // the evolute) to the Moon's distance and 1e9 m, at every latitude,
    // the poles and the equator included, to 1e-9 relative in height and
    // 1e-12 rad in latitude (1e-14 relative near the surface).
    func testRoundTrips() {
        for latDeg in stride(from: -90.0, through: 90.0, by: 7.5) {
            for h in [-6_000_000.0, -100_000, -1, 0, 1e-3, 59, 185_000, 3.8e8, 1e9] {
                let lat = latDeg * deg, lon = (latDeg * 2.3).truncatingRemainder(dividingBy: 180) * deg
                let g = wgs84.geodetic(wgs84.bodyFixed(latitude: lat, longitude: lon, height: h))
                XCTAssertEqual(g.latitude, lat, accuracy: 1e-12, "\(latDeg)°, \(h) m")
                XCTAssertEqual(g.height, h, accuracy: max(abs(h) * 1e-9, 1e-7), "\(latDeg)°, \(h) m")
                if abs(latDeg) < 90 { XCTAssertEqual(g.longitude, lon, accuracy: 1e-12) }
            }
        }
    }

    // The edges: the centre, the poles, the axis inside and outside the
    // evolute, the equatorial plane inside it, a sphere (f = 0) and a
    // vanishing flattening. Nothing is NaN, and each is the nearest surface
    // point's latitude and height.
    func testEdgeCases() {
        let a = wgs84.equatorialRadius, b = wgs84.polarRadius, e2 = wgs84.eccentricitySquared
        func check(_ p: Vec3, _ lat: Double, _ h: Double, accuracy: Double = 1e-6,
                   _ e: Ellipsoid = .wgs84, line: UInt = #line) {
            let g = e.geodetic(p)
            XCTAssertEqual(g.latitude, lat, accuracy: 1e-12, "latitude", line: line)
            XCTAssertEqual(g.height, h, accuracy: accuracy, "height", line: line)
            XCTAssertFalse(g.longitude.isNaN, line: line)
        }
        // The centre: the poles are the nearest points.
        check(.zero, 90 * deg, -b)
        // The poles and the axis, outside and inside the evolute (|z| <
        // a e²/√(1 - e²), 42.8 km) and below the south pole.
        check(Vec3(0, 0, b), 90 * deg, 0)
        check(Vec3(0, 0, b + 1e9), 90 * deg, 1e9, accuracy: 1e-6)
        check(Vec3(0, 0, 30_000), 90 * deg, 30_000 - b)
        check(Vec3(0, 0, -30_000), -90 * deg, 30_000 - b)
        check(Vec3(0, 0, -b - 10), -90 * deg, 10)
        // The equator, on the surface and far out.
        check(Vec3(a, 0, 0), 0, 0)
        check(Vec3(0, -a - 1e9, 0), 0, 1e9, accuracy: 1e-6)
        // The equatorial plane inside the evolute (rho < a e², 42.7 km): the
        // normal that crosses the plane there, rho = N e² cos φ, h = -N(1 - e²).
        let rho = 20_000.0
        let g = wgs84.geodetic(Vec3(rho, 0, 0))
        let n = wgs84.primeVerticalRadius(latitude: g.latitude)
        XCTAssertEqual(n * e2 * cos(g.latitude), rho, accuracy: 1e-6)
        XCTAssertEqual(g.height, -n * (1 - e2), accuracy: 1e-6)
        // Just off the plane it is continuous with the closed form.
        let off = wgs84.geodetic(Vec3(rho, 0, 1e-3))
        XCTAssertEqual(off.latitude, g.latitude, accuracy: 1e-6)
        XCTAssertEqual(off.height, g.height, accuracy: 1e-3)
        // A sphere: geocentric latitude and r - R; its centre is a pole.
        let sphere = Ellipsoid.sphere(1_737_400)
        check(Vec3(1_000_000, 0, 1_000_000), 45 * deg, 2.0.squareRoot() * 1e6 - 1_737_400, sphere)
        check(.zero, 90 * deg, -1_737_400, sphere)
        // A vanishing flattening takes the closed form, and agrees with the sphere.
        let nearSphere = Ellipsoid(equatorialRadius: 1_737_400, flattening: 1e-15)
        for p in [Vec3(1_000_000, 0, 1_000_000), Vec3(3e8, -2e8, 1e8), Vec3(0, 0, 2e6), Vec3(0, 1_737_400, 0)] {
            let s = sphere.geodetic(p), t = nearSphere.geodetic(p)
            XCTAssertEqual(t.latitude, s.latitude, accuracy: 1e-12)
            XCTAssertEqual(t.height, s.height, accuracy: 1e-6 * max(1, p.length / 1e7))
        }
    }

    // The normal is the gradient of x²/a² + y²/a² + z²/b² at the surface
    // point, and `normal(at:)` is the normal along which a height was added.
    func testNormal() {
        let a = wgs84.equatorialRadius, b = wgs84.polarRadius
        for latDeg in [-80.0, -28.6, 0, 28.6084, 61, 89.99] {
            let lat = latDeg * deg, lon = -80.6 * deg
            let s = wgs84.bodyFixed(latitude: lat, longitude: lon, height: 0)
            let gradient = Vec3(s.x / (a * a), s.y / (a * a), s.z / (b * b)).normalized
            XCTAssertLessThan((wgs84.normal(latitude: lat, longitude: lon) - gradient).length, 1e-12)
            let p = wgs84.bodyFixed(latitude: lat, longitude: lon, height: 120_000)
            XCTAssertLessThan(((p - s).normalized - wgs84.normal(at: p)).length, 1e-12)
        }
    }

    // Normal gravity. Somigliana's closed form for WGS 84's level ellipsoid
    // (NIMA TR8350.2, eq. 4-1 and Table 3.4: γe 9.7803253359, γp
    // 9.8321849378 m/s²) against the model's field on the ellipsoid: GM and
    // J2 (`SolarSystem`, 1.08262668e-3; WGS 84's 1.08263e-3) plus the
    // centrifugal term of the sidereal rate. Within 1e-5 in magnitude to
    // 75° of latitude and 0.001° in direction everywhere: the model's field
    // leaves out J4 (-2.37e-6), which at the poles adds 5 J4 = 1.2e-5 to
    // the radial gravity, so there the bound is 1.3e-5.
    func testSomiglianaNormalGravity() throws {
        let earth = try SolarSystem.bundled().earth
        XCTAssertEqual(earth.figure, .wgs84)
        let a = wgs84.equatorialRadius, b = wgs84.polarRadius, e2 = wgs84.eccentricitySquared
        let gammaE = 9.7803253359, gammaP = 9.8321849378
        let k = (b * gammaP - a * gammaE) / (a * gammaE)
        XCTAssertEqual(k, 0.00193185265241, accuracy: 1e-11)   // TR8350.2 Table 3.4
        let w = Vec3(0, 0, EarthOrientation.rotationRate)
        for latDeg in stride(from: 0.0, through: 90.0, by: 2.5) {
            let lat = latDeg * deg
            let p = wgs84.bodyFixed(latitude: lat, longitude: 0, height: 0)
            let g = earth.gravity(at: p, pole: .unitZ) - w.cross(w.cross(p))
            let s = sin(lat), somigliana = gammaE * (1 + k * s * s) / (1 - e2 * s * s).squareRoot()
            XCTAssertEqual(g.length / somigliana - 1, 0, accuracy: latDeg <= 75 ? 1e-5 : 1.3e-5, "\(latDeg)°")
            XCTAssertLessThan(angleBetween(-g, wgs84.normal(latitude: lat, longitude: 0)), 0.001 * deg, "\(latDeg)°")
        }
    }
}

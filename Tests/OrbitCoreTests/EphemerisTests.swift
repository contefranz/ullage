import XCTest
@testable import OrbitCore

/// Reference values from JPL DE421 via jplephem, and SPICE matrices quoted in
/// skyfield's test-suite (generated with spiceypy pxform).
final class EphemerisTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    var system: SolarSystem { Self.system }

    func epoch(jd: Double) -> Epoch { Epoch(tdbSecondsPastJ2000: (jd - 2451545.0) * 86400) }

    func testEarthMoonAndSunVectors() {
        let cases: [(Double, Vec3, Vec3)] = [
            (2440423.5, Vec3(-382359.6639401161, -59408.20268694212, -37094.28960730451),
             Vec3(-72502190.75746004, 122569728.76505794, 53149760.267779246)),
            (2444700.25, Vec3(312535.6335367042, 170934.36105950957, 40283.34879737888),
             Vec3(143814074.74435788, 38156400.6976615, 16544980.387049926)),
        ]
        for (jd, moon, sun) in cases {
            let s = system.snapshot(at: epoch(jd: jd))
            let em = (s.position(system.moon) - s.position(system.earth)) / 1000
            let es = (s.position(system.sun) - s.position(system.earth)) / 1000
            XCTAssertEqual((em - moon).length, 0, accuracy: 1e-6, "Earth->Moon at \(jd)")
            XCTAssertEqual((es - sun).length, 0, accuracy: 1e-5, "Earth->Sun at \(jd)")
        }
    }

    func testMoonVelocity() {
        // d/dt of Moon w.r.t. Earth-Moon barycentre, km/s.
        let ref = Vec3(0.23387983902582063, -0.8517362495502805, -0.46002619018726565)
        let v = system.ephemeris.rawState(target: 301, center: 3, at: epoch(jd: 2440423.5))!.velocity / 1000
        XCTAssertEqual((v - ref).length, 0, accuracy: 1e-11)
    }

    func testSpanCoversApolloAndShuttle() {
        let span = system.validSpan
        XCTAssertLessThanOrEqual(span.lowerBound, Epoch(utcYear: 1961, month: 1, day: 1))
        XCTAssertGreaterThanOrEqual(span.upperBound, Epoch(utcYear: 2029, month: 12, day: 1))
    }

    func assertMatrix(_ m: Mat3, _ ref: [[Double]], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<3 { for j in 0..<3 {
            XCTAssertEqual(m[i, j], ref[i][j], accuracy: accuracy, "element \(i),\(j)", file: file, line: line)
        } }
    }

    func testLunarPrincipalAxes() {
        let pa1 = system.ephemeris.lunarPrincipalAxes(at: epoch(jd: 2451545.0 - 11150)).icrfToPA
        assertMatrix(pa1, [
            [0.9994150897380264, 0.032310270603926675, 0.011203785852719871],
            [-0.034157426811763446, 0.9272642685944782, 0.37284614304233643],
            [0.0016578894811167893, -0.3730107540024127, 0.9278255379116378],
        ], accuracy: 1e-13)

        let pa2 = system.ephemeris.lunarPrincipalAxes(at: epoch(jd: 2451545.0)).icrfToPA
        assertMatrix(pa2, [
            [0.7840447406961362, 0.5582359944893811, 0.2713787372716964],
            [-0.6203032939745002, 0.7203957219351799, 0.31024800934393754],
            [-0.02230847532023746, -0.41158544468183367, 0.9110981032001678],
        ], accuracy: 1e-12)
    }

    func testLunarMeanEarthFrame() {
        let o = system.moon.orientation(at: epoch(jd: 2451545.0 - 11150), ephemeris: system.ephemeris)
        assertMatrix(o.icrfToBody, [
            [0.9994268420493244, 0.03186286343877705, 0.011434392191818011],
            [-0.03382833397374688, 0.9272754001640859, 0.37284846261060917],
            [0.0012771890522186643, -0.37302156798771835, 0.927821792481783],
        ], accuracy: 1e-13)
    }

    func testLunarAngularVelocity() {
        // The SPICE rate matrix dR/dt = -[w]x R (body components); check magnitude
        // and that the derivative of the rotation matches numerically.
        let t = epoch(jd: 2451545.0 - 11150)
        let (r0, w) = system.ephemeris.lunarPrincipalAxes(at: t)
        let r1 = system.ephemeris.lunarPrincipalAxes(at: t + 1).icrfToPA
        let rm = system.ephemeris.lunarPrincipalAxes(at: t + -1).icrfToPA
        let dR = (r1 + rm * -1) * 0.5
        // For R = icrf->body, dR/dt = -R [w_icrf]x
        let predicted = (r0 * Mat3.cross(w)) * -1
        for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(dR[i, j], predicted[i, j], accuracy: 1e-12) } }
        XCTAssertEqual(w.length, 2.6617e-6, accuracy: 0.02e-6)
        // SPICE reference rate element (row 0, col 1) from skyfield's test.
        XCTAssertEqual(dR[0, 1], 2.4682369763316187e-06, accuracy: 1e-13)
    }
}

final class EarthOrientationTests: XCTestCase {
    func testGMSTAtJ2000() {
        let g = EarthOrientation.gmst(julianDateUT1: 2451545.0) * 180 / Double.pi
        XCTAssertEqual(g, 280.46061837, accuracy: 1e-7)
    }

    func testPrecessionIsIdentityAtJ2000AndGrows() {
        let p0 = EarthOrientation.precession(centuries: 0)
        XCTAssertEqual(p0[0, 0], 1, accuracy: 1e-15)
        // After one century the pole has moved by theta(T=1).
        let p1 = EarthOrientation.precession(centuries: 1)
        let pole = p1.transposed * Vec3.unitZ
        let angle = acos(pole.z) * 180 / Double.pi * 3600
        XCTAssertEqual(angle, 2004.3109 - 0.42665 - 0.041833, accuracy: 0.01)
    }

    func testEarthRotationRate() {
        let s = try! SolarSystem.bundled()
        let t = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        let o0 = s.earth.orientation(at: t, ephemeris: s.ephemeris)
        let o1 = s.earth.orientation(at: t + 86164.0905, ephemeris: s.ephemeris)
        // One sidereal day later the body frame is back where it was (to < 1 arcsec plus precession).
        let x0 = o0.toInertial(.unitX), x1 = o1.toInertial(.unitX)
        XCTAssertLessThan(angleBetween(x0, x1), 1e-5)
        XCTAssertEqual(o0.angularVelocity.length, 7.2921151e-5, accuracy: 1e-11)
    }
}

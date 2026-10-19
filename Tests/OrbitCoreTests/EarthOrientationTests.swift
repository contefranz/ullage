import XCTest
@testable import OrbitCore

/// The Earth's orientation (`EarthOrientation`, the `.earth` rotation model)
/// and UT1 (`Epoch`, `UT1Table`) against external references: ERFA's own test
/// values (t_erfa_c.c, liberfa/erfa at commit 1a8044c), the SOFA cookbook
/// *SOFA Tools for Earth Attitude* (its §5 example), JPL Horizons on Apollo
/// 11's launch, and the IERS EOP 20 C04 series.
final class EarthOrientationTests: XCTestCase {
    let mas = Double.pi / (180 * 3600 * 1000)

    func assertMatrix(_ m: Mat3, _ ref: [[Double]], accuracy: Double, _ what: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<3 { for j in 0..<3 {
            XCTAssertEqual(m[i, j], ref[i][j], accuracy: accuracy, "\(what) element \(i + 1)\(j + 1)",
                           file: file, line: line)
        } }
    }

    /// The largest element difference of two matrices.
    func maxDifference(_ m: Mat3, _ ref: [[Double]]) -> Double {
        var d = 0.0
        for i in 0..<3 { for j in 0..<3 { d = max(d, abs(m[i, j] - ref[i][j])) } }
        return d
    }

    // MARK: ERFA's test values (t_erfa_c.c), at ERFA's own tolerances

    // t_nut00b: IAU 2000B nutation on MJD 53736 TT.
    func testNutation2000B() {
        let n = EarthOrientation.nutation(tt: (2400000.5, 53736.0))
        XCTAssertEqual(n.dpsi, -0.9632552291148362783e-5, accuracy: 1e-13)
        XCTAssertEqual(n.deps, 0.4063197106621159367e-4, accuracy: 1e-13)
    }

    // t_pfw06, t_obl06, t_fw2m and t_pmat06: IAU 2006 bias and precession.
    func testPrecession2006() {
        let a = EarthOrientation.precessionAngles(tt: (2400000.5, 50123.9999))
        XCTAssertEqual(a.gamma, -0.2243387670997995690e-5, accuracy: 1e-16)
        XCTAssertEqual(a.phi, 0.4091014602391312808, accuracy: 1e-12)
        XCTAssertEqual(a.psi, -0.9501954178013031895e-3, accuracy: 1e-14)
        XCTAssertEqual(a.epsilon, 0.4091014316587367491, accuracy: 1e-12)
        XCTAssertEqual(EarthOrientation.meanObliquity(tt: (2400000.5, 54388.0)), 0.4090749229387258204,
                       accuracy: 1e-14)

        let fw = EarthOrientation.fukushimaWilliamsMatrix(gamma: -0.2243387670997992368e-5, phi: 0.4091014602391312982,
                                                          psi: -0.9501954178013015092e-3, epsilon: 0.4091014316587367472)
        assertMatrix(fw, [
            [0.9999995505176007047, 0.8695404617348192957e-3, 0.3779735201865582571e-3],
            [-0.8695404723772016038e-3, 0.9999996219496027161, -0.1361752496887100026e-6],
            [-0.3779734957034082790e-3, -0.1924880848087615651e-6, 0.9999999285679971958],
        ], accuracy: 1e-12, "fw2m")

        let p = EarthOrientation.biasPrecessionMatrix(tt: (2400000.5, 50123.9999))
        let pmat06 = [
            [0.9999995505176007047, 0.8695404617348208406e-3, 0.3779735201865589104e-3],
            [-0.8695404723772031414e-3, 0.9999996219496027161, -0.1361752497080270143e-6],
            [-0.3779734957034089490e-3, -0.1924880847894457113e-6, 0.9999999285679971958],
        ]
        assertMatrix(p, pmat06, accuracy: 1e-14, "pmat06")
    }

    // t_era00, t_gmst06 and t_eect00.
    func testRotationAngleAndMeanSiderealTime() {
        XCTAssertEqual(EarthOrientation.earthRotationAngle(ut1: (2400000.5, 54388.0)), 0.4022837240028158102,
                       accuracy: 1e-12)
        XCTAssertEqual(EarthOrientation.gmst(ut1: (2400000.5, 53736.0), tt: (2400000.5, 53736.0)),
                       1.754174971870091203, accuracy: 1e-12)
        XCTAssertEqual(EarthOrientation.equationOfEquinoxesComplementaryTerms(tt: (2400000.5, 53736.0)),
                       0.2046085004885125264e-8, accuracy: 1e-20)
        // The rotation rate is the Earth rotation angle's.
        XCTAssertEqual(EarthOrientation.rotationRate, 2 * Double.pi * 1.00273781191135448 / 86400, accuracy: 1e-19)
    }

    // t_pnm06a, t_gst06a and t_ee06a are IAU 2006/2000A: the 2000B nutation
    // is within 1 mas of 2000A from 1995 to 2050 (McCarthy & Luzum 2003),
    // and so are the matrix and the sidereal time built on it.
    func testWithinAMilliarcsecondOfIAU2006_2000A() {
        let pnm06a = [
            [0.9999995832794205484, 0.8372382772630962111e-3, 0.3639684771140623099e-3],
            [-0.8372533744743683605e-3, 0.9999996486492861646, 0.4132905944611019498e-4],
            [-0.3639337469629464969e-3, -0.4163377605910663999e-4, 0.9999999329094260057],
        ]
        let npb = EarthOrientation.biasPrecessionNutationMatrix(tt: (2400000.5, 50123.9999))
        assertMatrix(npb, pnm06a, accuracy: 1 * mas, "pnm06a")
        let gst = EarthOrientation.gast(ut1: (2400000.5, 53736.0), tt: (2400000.5, 53736.0))
        XCTAssertEqual(gst, 1.754166137675019159, accuracy: 1 * mas)
        let ee = EarthOrientation.equationOfEquinoxes(tt: (2400000.5, 53736.0))
        XCTAssertEqual(ee, -0.8834195072043790156e-5, accuracy: 1 * mas)
        print(String(format: "IAU 2000B vs 2006/2000A: pnm06a %.3f mas, gst06a %.3f mas, ee06a %.3f mas",
                     maxDifference(npb, pnm06a) / mas, abs(gst - 1.754166137675019159) / mas,
                     abs(ee + 0.8834195072043790156e-5) / mas))
    }

    // MARK: SOFA cookbook

    // SOFA Tools for Earth Attitude (sofa_pn_c.pdf, iausofa.org, 2023 May 31
    // edition, sha256 9a0691d1...), §5: 2007 April 05 12h UTC, TT 2454195.5 +
    // 0.500754444444444, UT1 2454195.5 + 0.499999165813831 (UT1-UTC
    // -0.072073685 s), xp 0.0349282", yp 0.4833163". Its IAU 2000A
    // equinox-based NPB matrix and GST (§5.4), and its IAU 2006/2000A
    // celestial-to-terrestrial matrices, without and with polar motion
    // (§5.5), to 1e-8: within the 2000B nutation's 1 mas and the cookbook's
    // celestial pole offsets (0.3 mas). Polar motion is applied here as the
    // cookbook does (pom00, s' = 3 µas left out); the model has none.
    func testSOFACookbookEarthAttitude() {
        let tt = (2454195.5, 0.500754444444444), ut1 = (2454195.5, 0.499999165813831)
        let npb = EarthOrientation.biasPrecessionNutationMatrix(tt: tt)
        let npbRef = [
            [+0.999998402755640, -0.001639289519579, -0.000712191013215],
            [+0.001639257491365, +0.999998655379006, -0.000045552787478],
            [+0.000712264729795, +0.000044385250265, +0.999999745354420],
        ]
        assertMatrix(npb, npbRef, accuracy: 1e-8, "NPB")
        let gst = EarthOrientation.gast(ut1: ut1, tt: tt) * 180 / Double.pi
        XCTAssertEqual(gst, 13.412417084674, accuracy: 1e-8 * 180 / Double.pi)

        let c2t = EarthOrientation.celestialToTerrestrial(ut1: ut1, tt: tt)
        let c2tiRef = [
            [+0.973104317573127, +0.230363826247709, -0.000703332818845],
            [-0.230363798804182, +0.973104570735574, +0.000120888549586],
            [+0.000712264729599, +0.000044385250426, +0.999999745354420],
        ]
        assertMatrix(c2t, c2tiRef, accuracy: 1e-8, "C2T without polar motion")
        let das2r = Double.pi / (180 * 3600)
        let pom = Mat3.frameX(-0.4833163 * das2r) * Mat3.frameY(-0.0349282 * das2r)
        let c2tRef = [
            [+0.973104317697535, +0.230363826239128, -0.000703163482198],
            [-0.230363800456037, +0.973104570632801, +0.000118545366625],
            [+0.000711560162668, +0.000046626403995, +0.999999745754024],
        ]
        assertMatrix(pom * c2t, c2tRef, accuracy: 1e-8, "C2T")
        print(String(format: "SOFA cookbook: NPB %.2e, GST %.3f mas, C2T %.2e, with polar motion %.2e",
                     maxDifference(npb, npbRef), abs(gst - 13.412417084674) * 3600e3, maxDifference(c2t, c2tiRef),
                     maxDifference(pom * c2t, c2tRef)))

        // The same instant from the UTC date: TT to the cookbook's 1e-9 day
        // (one Double's precision), and DUT1 from C04 within 0.1 ms of the
        // cookbook's illustrative value ("fairly close to those for the date").
        let e = Epoch(utcYear: 2007, month: 4, day: 5, hour: 12)
        XCTAssertEqual(e.tt.0 + e.tt.1, tt.0 + tt.1, accuracy: 1e-9)
        XCTAssertEqual(e.ut1MinusUTC, -0.072073685, accuracy: 1e-4)
    }

    // MARK: JPL Horizons, Apollo 11's launch

    // JPL Horizons (API 1.2, queried 2026-10-19: DE441, EOP file
    // eop.261016.p270112, ITRF93 with polar motion, WGS-84 radii):
    //   COMMAND='399' CENTER='coord@399' COORD_TYPE='GEODETIC'
    //   SITE_COORD='279.3959,28.6084,0.026' EPHEM_TYPE='VECTORS'
    //   TLIST='1969-07-16 13:32' TIME_TYPE='UT' REF_SYSTEM='ICRF'
    //   REF_PLANE='FRAME' VEC_TABLE='2' VEC_CORR='NONE' OUT_UNITS='KM-S'
    // gives the geocentre from LC-39A (the pad's geodetic coordinates and
    // elevation, AS506Data) at range zero, 13:32:00 UTC:
    //   X -3043.275111730532  Y -4699.665892391100  Z -3044.743914554680 km
    //   VX 0.3426963993205872 VY -0.2225742234313876 VZ 0.001019811038647383 km/s
    // and the site's distance from the axis and the equator, Dxy 5603.77286
    // and Dz 3035.88177 km. The pad is within 10 m of it (8.35 m): polar
    // motion, which Horizons applies and the model does not, is 8.5 m that
    // day. With C04's (xp 0.1413", yp 0.2351") applied here, 2.25 m are left,
    // which are Horizons' 1969 frame rather than the model: the same query
    // for TLIST='2007-04-05 12:00' (X -2165.988189791428, Y 5169.008997128868,
    // Z -3034.582271134753 km) closes to 0.09 m with C04's polar motion that
    // day (xp 0.0345", yp 0.4837"). IAU 1976 precession, GMST 1982 and UT1 =
    // UTC, the model before this one, put the pad 244 m away in 1969.
    func testLaunchPadAgainstHorizons() throws {
        let s = try SolarSystem.bundled()
        let deg = Double.pi / 180, das2r = Double.pi / (180 * 3600)
        let fixed = Ellipsoid.wgs84.bodyFixed(latitude: 28.6084 * deg, longitude: 279.3959 * deg, height: 26)
        XCTAssertEqual((fixed.x * fixed.x + fixed.y * fixed.y).squareRoot(), 5_603_772.86, accuracy: 0.01)
        XCTAssertEqual(fixed.z, 3_035_881.77, accuracy: 0.01)
        func polarMotion(xp: Double, yp: Double) -> Mat3 { Mat3.frameX(-yp * das2r) * Mat3.frameY(-xp * das2r) }

        let t = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        let o = s.earth.orientation(at: t, ephemeris: s.ephemeris)
        let r = o.toInertial(fixed), v = o.angularVelocity.cross(r)
        let horizonsR = Vec3(3_043_275.111730532, 4_699_665.892391100, 3_044_743.914554680)
        let horizonsV = Vec3(-342.6963993205872, 222.5742234313876, -1.019811038647383)
        XCTAssertLessThan((r - horizonsR).length, 10)
        XCTAssertLessThan((v - horizonsV).length, 1e-3)
        // C04 at 0h on 16 and 17 July: xp 0.141254" and 0.141354", yp 0.236254" and 0.234154".
        let f = (13 + 32 / 60.0) / 24
        let w = polarMotion(xp: 0.141254 + (0.141354 - 0.141254) * f, yp: 0.236254 + (0.234154 - 0.236254) * f)
        let rPolar = o.toInertial(w.transposed * fixed)
        XCTAssertLessThan((rPolar - horizonsR).length, 3)

        // 2007: C04 at 0h on 5 and 6 April, xp 0.033219" and 0.035734", yp 0.483159" and 0.484204".
        let t2 = Epoch(utcYear: 2007, month: 4, day: 5, hour: 12)
        let o2 = s.earth.orientation(at: t2, ephemeris: s.ephemeris)
        let w2 = polarMotion(xp: (0.033219 + 0.035734) / 2, yp: (0.483159 + 0.484204) / 2)
        let horizons2007 = Vec3(2_165_988.189791428, -5_169_008.997128868, 3_034_582.271134753)
        XCTAssertLessThan((o2.toInertial(w2.transposed * fixed) - horizons2007).length, 0.2)
        print(String(format: "LC-39A vs Horizons: %.2f m, %.3f mm/s; with C04's polar motion %.2f m, in 2007 %.2f m",
                     (r - horizonsR).length, (v - horizonsV).length * 1000, (rPolar - horizonsR).length,
                     (o2.toInertial(w2.transposed * fixed) - horizons2007).length))
    }

    // Horizons' observer table, QUANTITIES='7' (local apparent sidereal time),
    // EXTRA_PREC='YES', same time, at SITE_COORD='0,0,0', where polar motion
    // does not move the meridian: 09h 08m 50.8393s. The model's GAST, on UT1
    // from C04 (DUT1 +0.0119 s, more than the tolerance), within 5 ms
    // (-1.7 ms). Horizons' sidereal time is IAU 1982's, with its equinox: in
    // 2007 it gives 00h 53m 38.9764s, the SOFA cookbook's IAU 1976/1980/1982/
    // 1994 GST (38.9766s) rather than its IAU 2000 one (38.9801s).
    func testApparentSiderealTimeAgainstHorizons() {
        let t = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        let gast = EarthOrientation.gast(ut1: t.ut1, tt: t.tt) / (2 * Double.pi) * 86400
        XCTAssertEqual(gast, 9 * 3600 + 8 * 60 + 50.8393, accuracy: 0.005)
        print(String(format: "GAST vs Horizons: %.4f s", gast - (9 * 3600 + 8 * 60 + 50.8393)))
    }

    // MARK: UT1

    // C04 on launch day: UT1-UTC 0.0115221 s at 0h on 16 July 1969 and
    // 0.0121533 s at 0h on the 17th, so +0.0118780 s at range zero.
    func testDUT1OnLaunchDay() {
        let t = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        XCTAssertEqual(t.ut1MinusUTC, 0.0115221 + (0.0121533 - 0.0115221) * (13 + 32 / 60.0) / 24, accuracy: 1e-9)
        XCTAssertEqual((t.julianDateUT1 - t.julianDateUTC) * 86400, t.ut1MinusUTC, accuracy: 1e-4)
        XCTAssertEqual(Epoch(utcYear: 1969, month: 7, day: 16).ut1MinusUTC, 0.0115221, accuracy: 1e-9)
    }

    // The table spans C04 from 1962-01-01, and C04's UT1-UTC less Epoch's
    // TAI-UTC (USNO tai-utc.dat) changes smoothly, by under 5 ms a day,
    // through every pre-1972 step and leap second: the two tables agree on
    // when UTC stepped and by how much. UT1 runs on through a leap second.
    func testUT1TableIsC04AndContinuous() {
        let table = UT1Table.bundled
        XCTAssertEqual(table.firstMJD, 37665)                              // 1962-01-01
        XCTAssertGreaterThanOrEqual(table.firstMJD + Double(table.ut1MinusTAI.count - 1), 61301)  // 2026-09-18
        let steps = zip(table.ut1MinusTAI, table.ut1MinusTAI.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThan(steps.max()!, 0.005)

        // 1972 June 30 23:59:60 was a leap second: 3 s of UTC labels are 4 s
        // of TAI, and of UT1 to the day's drift; DUT1 steps by the second,
        // from C04's -0.6378 s to +0.3622 s.
        let before = Epoch(utcYear: 1972, month: 6, day: 30, hour: 23, minute: 59, second: 58)
        let after = Epoch(utcYear: 1972, month: 7, day: 1, hour: 0, minute: 0, second: 1)
        // (To 0.1 ms: a UTC label is a one-Double Julian date, 40 µs.)
        XCTAssertEqual(after - before, 4, accuracy: 1e-4)
        XCTAssertEqual((after.ut1.1 - before.ut1.1) * 86400, after - before, accuracy: 1e-6)
        XCTAssertEqual(before.ut1MinusUTC, -0.6378, accuracy: 1e-4)
        XCTAssertEqual(after.ut1MinusUTC, 0.3622, accuracy: 1e-4)
    }

    // MARK: The rotation model

    // The simulation's orientation interpolates precession-nutation between
    // evaluations 10 minutes apart: within 1 µas of the series, also across
    // a node.
    func testInterpolatedPrecessionNutationMatchesTheSeries() throws {
        let s = try SolarSystem.bundled()
        let t0 = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        let node = (t0.tdb / 600).rounded(.down) * 600
        for dt in [-1e-3, 0, 1e-3, 37.3, 299.99, 300, 599.999, 600, 4321.5] {
            let t = Epoch(tdbSecondsPastJ2000: node + dt)
            let exact = EarthOrientation.celestialToTerrestrial(ut1: t.ut1, tt: t.tt)
            let m = s.earth.orientation(at: t, ephemeris: s.ephemeris).icrfToBody
            var d = 0.0
            for i in 0..<3 { for j in 0..<3 { d = max(d, abs(m[i, j] - exact[i, j])) } }
            XCTAssertLessThan(d, 1e-3 * mas, "\(dt) s after a node")
        }
    }

    // The angular velocity is the Earth rotation angle's rate about the CIP,
    // the body frame's +z; the frame's own turning (its finite difference
    // over 2 s) agrees to within the precession and nutation rates, 2e-11
    // rad/s. One sidereal day on, the frame is back to under 1 arcsec plus
    // the day's precession.
    func testEarthRotation() throws {
        let s = try SolarSystem.bundled()
        let t = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)
        let o = s.earth.orientation(at: t, ephemeris: s.ephemeris)
        XCTAssertEqual(angleBetween(o.angularVelocity, o.pole), 0, accuracy: 1e-15)
        XCTAssertEqual(o.angularVelocity.length, EarthOrientation.rotationRate, accuracy: 1e-20)
        let m1 = s.earth.orientation(at: t + 1, ephemeris: s.ephemeris).icrfToBody
        let m0 = s.earth.orientation(at: t + -1, ephemeris: s.ephemeris).icrfToBody
        // R(t+1) = R(t-1) - 2 R [w]x: the skew part of R(t-1)^T R(t+1) is -2[w]x.
        let k = m0.transposed * m1
        let w = Vec3(k[1, 2] - k[2, 1], k[2, 0] - k[0, 2], k[0, 1] - k[1, 0]) * 0.25
        XCTAssertLessThan((w - o.angularVelocity).length, 2e-11)

        let later = s.earth.orientation(at: t + 86164.0905, ephemeris: s.ephemeris)
        XCTAssertLessThan(angleBetween(o.toInertial(.unitX), later.toInertial(.unitX)), 1e-5)
    }
}

import XCTest
@testable import OrbitCore

/// `Eclipse`, the conical shadow model (Montenbruck & Gill §3.4.2).
final class EclipseTests: XCTestCase {
    let au = 149_597_870_700.0
    let earthRadius = 6_378_137.0, moonRadius = 1_737_400.0, mu = 3.986004418e14

    // No occulter, the Sun straight ahead or straight behind the Earth, an
    // occulter beyond the Sun, a point inside the Earth.
    func testLimitingCases() {
        let sun = Vec3(au, 0, 0), earth = [(center: Vec3.zero, radius: earthRadius)]
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(7e6, 0, 0), sun: sun, occulters: []), 1)
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(7e6, 0, 0), sun: sun, occulters: earth), 1)
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(-7e6, 0, 0), sun: sun, occulters: earth), 0)
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(0, 7e6, 0), sun: sun, occulters: earth), 1)
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(-7e6, 0, 0), sun: sun,
                                              occulters: [(center: Vec3(-2 * au, 0, 0), radius: earthRadius)]), 1)
        // On the surface (inside the sphere) the Earth is the horizon: noon
        // lit, midnight dark, the Sun's centre on the horizon half lit.
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(6.37e6, 0, 0), sun: sun, occulters: earth), 1)
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(-6.37e6, 0, 0), sun: sun, occulters: earth), 0)
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(0, 6.37e6, 0), sun: Vec3(au, 6.37e6, 0), occulters: earth),
                       0.5, accuracy: 1e-3)
    }

    // The overlap of two discs against the symmetric lens formula, the
    // nested and separate cases, and a grid count of an asymmetric case.
    func testOverlapArea() {
        XCTAssertEqual(Eclipse.overlapArea(1, 1, separation: 1), 2 * Double.pi / 3 - 3.0.squareRoot() / 2,
                       accuracy: 1e-12)
        XCTAssertEqual(Eclipse.overlapArea(1, 0.5, separation: 0.3), Double.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(Eclipse.overlapArea(0.5, 1, separation: 0.3), Double.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(Eclipse.overlapArea(1, 0.5, separation: 1.6), 0)

        let a = 1.0, b = 0.6, c = 1.1, n = 2000, h = 2.0 / Double(n)
        var inside = 0
        for i in 0..<n {
            for j in 0..<n {
                let x = -1 + (Double(i) + 0.5) * h, y = -1 + (Double(j) + 0.5) * h
                if x * x + y * y <= a * a && (x - c) * (x - c) + y * y <= b * b { inside += 1 }
            }
        }
        XCTAssertEqual(Eclipse.overlapArea(a, b, separation: c), Double(inside) * h * h, accuracy: 2e-4)
    }

    /// Times (s) a circular orbit of altitude `height` whose plane is `beta`
    /// (deg) off the Sun's direction spends with the sunlit fraction below
    /// 0.5, and from 1 to 0 entering the shadow; and its period.
    func shadow(height: Double, beta: Double) -> (umbraAndHalf: Double, penumbra: Double, period: Double) {
        let r = earthRadius + height, n = (mu / (r * r * r)).squareRoot(), period = 2 * Double.pi / n
        let b = beta * Double.pi / 180
        let e1 = Vec3(cos(b), 0, -sin(b)), e2 = Vec3(0, 1, 0), sun = Vec3(au, 0, 0)
        func lit(_ t: Double) -> Double {
            let p = (e1 * cos(n * t) + e2 * sin(n * t)) * r
            return Eclipse.sunlitFraction(at: p, sun: sun, occulters: [(center: .zero, radius: earthRadius)])
        }
        /// Time in `t0...t1` where `lit` crosses `level`, by bisection.
        func crossing(_ level: Double, _ t0: Double, _ t1: Double) -> Double {
            var lo = t0, hi = t1
            let rising = lit(t1) > lit(t0)
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if (lit(mid) > level) == rising { hi = mid } else { lo = mid }
            }
            return (lo + hi) / 2
        }
        // From the subsolar point, so the shadow lies wholly inside one turn.
        var entry: (Double, Double)?, exit: (Double, Double)?
        let step = 1.0
        var t = 0.0
        while t < period {
            let a = lit(t), z = lit(t + step)
            if a > 0.5, z <= 0.5 { entry = (t, t + step) }
            if a <= 0.5, z > 0.5 { exit = (t, t + step) }
            t += step
        }
        guard let i = entry, let o = exit else { return (0, 0, period) }
        let start = crossing(1 - 1e-12, i.0 - 30, i.1), end = crossing(1e-12, i.0, i.1 + 30)
        return (crossing(0.5, o.0, o.1) - crossing(0.5, i.0, i.1), end - start, period)
    }

    /// The cylindrical model's shadow time: cos(φ/2) = cos ρ / cos β with
    /// sin ρ = R/(R+h) (Wertz & Larson, SMAD §5.1; Vallado).
    func textbookShadow(height: Double, beta: Double, period: Double) -> Double {
        let rho = asin(earthRadius / (earthRadius + height)), c = cos(rho) / cos(beta * Double.pi / 180)
        return c >= 1 ? 0 : 2 * acos(c) / (2 * Double.pi) * period
    }

    // A 185 km circular orbit at β = 0: about 42.4 % of its 88.2 min in
    // shadow, as the cylindrical model has it, and a penumbra of 2a/n, the
    // Sun's 0.53° disc crossing the limb, about 8 s.
    func testLowOrbitShadowAtBetaZero() {
        let s = shadow(height: 185_000, beta: 0)
        XCTAssertEqual(s.period / 60, 88.2, accuracy: 0.05)
        XCTAssertEqual(s.umbraAndHalf / s.period, 0.424, accuracy: 0.0005)
        XCTAssertEqual(s.umbraAndHalf, textbookShadow(height: 185_000, beta: 0, period: s.period), accuracy: 1)
        XCTAssertGreaterThanOrEqual(s.penumbra, 6)
        XCTAssertLessThanOrEqual(s.penumbra, 15)
        let a = asin(Eclipse.solarRadius / au)
        XCTAssertEqual(s.penumbra, 2 * a / (2 * Double.pi) * s.period, accuracy: 0.1)
    }

    // At β = 50° the shadow shortens as cos(φ/2) = cos ρ / cos β says and the
    // penumbra lengthens; past β = ρ (76.3°) there is none.
    func testLowOrbitShadowAtBeta() {
        let s = shadow(height: 185_000, beta: 50)
        XCTAssertEqual(s.umbraAndHalf, textbookShadow(height: 185_000, beta: 50, period: s.period), accuracy: 1)
        XCTAssertGreaterThan(s.penumbra, shadow(height: 185_000, beta: 0).penumbra)
        XCTAssertEqual(shadow(height: 185_000, beta: 80).umbraAndHalf, 0)
    }

    // Behind the Moon on the Sun's line: inside the umbra where the Moon
    // looks larger than the Sun, annular (1 - b²/a²) where it looks smaller.
    func testMoonShadow() {
        let sun = Vec3(au, 0, 0), moon = [(center: Vec3.zero, radius: moonRadius)]
        XCTAssertEqual(Eclipse.sunlitFraction(at: Vec3(-1e8, 0, 0), sun: sun, occulters: moon), 0)
        let p = Vec3(-6e8, 0, 0)
        let a = asin(Eclipse.solarRadius / (au + 6e8)), b = asin(moonRadius / 6e8)
        XCTAssertEqual(Eclipse.sunlitFraction(at: p, sun: sun, occulters: moon), 1 - b * b / (a * a), accuracy: 1e-12)
    }

    // At the pad with the bundled ephemeris: lit at Apollo 11's launch (about
    // 08:10 local mean solar time), dark at local midnight.
    func testPadDayAndNight() throws {
        let system = try SolarSystem.bundled(), earth = system.earth
        func lit(_ t: Epoch) -> Double {
            let s = system.snapshot(at: t)
            let pad = earth.figure.bodyFixed(latitude: AS506.padLatitude * Double.pi / 180,
                                             longitude: AS506.padLongitude * Double.pi / 180, height: 0)
            return Eclipse.sunlitFraction(at: s.orientation(earth).toInertial(pad), relativeTo: earth, in: system,
                                          snapshot: s)
        }
        XCTAssertEqual(lit(Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)), 1)
        XCTAssertEqual(lit(Epoch(utcYear: 1969, month: 7, day: 17, hour: 5, minute: 22)), 0)
    }
}

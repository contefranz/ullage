import XCTest
@testable import OrbitCore

/// `SurfaceGeometry`: the Sun's elevation and azimuth on DE421, the WGS-84
/// Earth and the IAU 2006/2000B orientation, against two references, and
/// the subsolar, sub-observer and specular points against their definitions.
///
/// - skyfield 1.55 (Rhodes 2019, ASCL 1907.024) on the same DE421
///   (skyfielders/python-skyfield, `ci/de421.bsp`), with IAU 2000A
///   nutation, WGS-84 and no polar motion: an independent implementation.
///   It is given the model's TT, since its UTC before 1972 holds TAI-UTC at
///   10 s where the rubber seconds had 7.03 s on 21 December 1968 (taken
///   from its UTC, the Sun stood 0.009° higher), and its ΔT is TT - UT1 of
///   the model's C04 UT1. Its geometric direction (the Sun's and the site's
///   positions at one instant, as the model takes them) is pinned; its
///   apparent one, with light time and aberration, differs by under 0.006°.
/// - The Astronomical Almanac's low-precision formulas for the Sun (section
///   C; 0.01° in right ascension and declination from 1950 to 2050), with
///   USNO's approximate apparent sidereal time ("Computing Greenwich
///   Apparent Sidereal Time", aa.usno.navy.mil/faq/GAST): independent of
///   DE421 and of the IAU models. Its Sun is apparent; it agrees within its
///   0.01° and the 20.5" of aberration.
final class SurfaceGeometryTests: XCTestCase {
    let deg = Double.pi / 180

    /// The Sun's apparent elevation and azimuth (deg) by the Astronomical
    /// Almanac's low-precision formulas, at a TT Julian date and a UT1 one,
    /// and a geodetic latitude and longitude (deg). Airless, geocentric.
    func almanacSun(jdTT: Double, jdUT1: Double, latitude: Double,
                    longitude: Double) -> (elevation: Double, azimuth: Double) {
        let n = jdTT - 2_451_545.0
        let meanLongitude = 280.460 + 0.9856474 * n
        let g = (357.528 + 0.9856003 * n) * deg
        let lambda = (meanLongitude + 1.915 * sin(g) + 0.020 * sin(2 * g)) * deg
        let epsilon = (23.439 - 0.0000004 * n) * deg
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let dec = asin(sin(epsilon) * sin(lambda))
        // GAST, hours: GMST plus the equation of the equinoxes.
        let d = jdUT1 - 2_451_545.0
        let gmst: Double = 18.697375 + 24.065709824279 * d
        let node = (125.04 - 0.052954 * d) * deg, sunLongitude = (280.47 + 0.98565 * d) * deg
        let dpsi = -0.000319 * sin(node) - 0.000024 * sin(2 * sunLongitude)
        let gast = gmst + dpsi * cos(epsilon)
        let hourAngle = (gast * 15 + longitude) * deg - ra
        let phi = latitude * deg
        let sinEl = sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(hourAngle)
        let y = -cos(dec) * sin(hourAngle)
        let x = sin(dec) * cos(phi) - cos(dec) * cos(hourAngle) * sin(phi)
        let az = atan2(y, x) / deg
        return (asin(sinEl) / deg, az < 0 ? az + 360 : az)
    }

    /// The Sun at a site, deg, with the almanac's at the same instant.
    func sun(at t: Epoch, latitude: Double, longitude: Double, height: Double,
             system: SolarSystem) -> (model: (Double, Double), almanac: (Double, Double)) {
        let s = system.snapshot(at: t)
        let m = SurfaceGeometry.sunElevationAzimuth(latitude: latitude * deg, longitude: longitude * deg,
                                                    height: height, on: system.earth, in: system, snapshot: s)
        let a = almanacSun(jdTT: t.julianDateTDB, jdUT1: t.julianDateUT1, latitude: latitude, longitude: longitude)
        print(String(format: "Sun at %@, %.4f° %.4f°: elevation %.6f° azimuth %.6f°; almanac %.4f° %.4f°",
                     t.description, latitude, longitude, m.elevation / deg, m.azimuth / deg,
                     a.elevation, a.azimuth))
        return ((m.elevation / deg, m.azimuth / deg), a)
    }

    // MARK: The Sun at LC-39A and at Apollo 8's splashdown

    // Apollo 8's range zero, 1968-12-21 12:51:00 UTC, on LC-39A: the Sun
    // 6.8° up in the east-southeast, 40 minutes after sunrise (skyfield).
    // skyfield: geometric 6.81594236° az 121.44304558°, apparent 6.82066661°
    // az 121.44636194°. Almanac: 6.8245° az 121.4445°.
    func testSunAtApollo8Launch() throws {
        let system = try SolarSystem.bundled(), pad = VesselLibrary.lc39A
        let t = Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51)
        let sun = sun(at: t, latitude: pad.latitude, longitude: pad.longitude, height: pad.elevation, system: system)
        XCTAssertEqual(sun.model.0, 6.81594236, accuracy: 2e-5)
        XCTAssertEqual(sun.model.1, 121.44304558, accuracy: 2e-5)
        XCTAssertEqual(sun.model.0, sun.almanac.0, accuracy: 0.02)
        XCTAssertEqual(sun.model.1, sun.almanac.1, accuracy: 0.02)
    }

    // Apollo 11's range zero, 1969-07-16 13:32:00 UTC, on LC-39A.
    // skyfield: geometric 36.45374168° az 83.54002925°, apparent 36.45920248°
    // az 83.54131859°. Almanac: 36.4583° az 83.5432°.
    func testSunAtApollo11Launch() throws {
        let system = try SolarSystem.bundled(), pad = VesselLibrary.lc39A
        let sun = sun(at: VesselLibrary.apollo11RangeZero, latitude: pad.latitude, longitude: pad.longitude,
                      height: pad.elevation, system: system)
        XCTAssertEqual(sun.model.0, 36.45374168, accuracy: 2e-5)
        XCTAssertEqual(sun.model.1, 83.54002925, accuracy: 2e-5)
        XCTAssertEqual(sun.model.0, sun.almanac.0, accuracy: 0.02)
        XCTAssertEqual(sun.model.1, sun.almanac.1, accuracy: 0.02)
    }

    // Apollo 8's splashdown, 1968-12-27 15:51:42 UTC, about 8.1° N 165.0° W:
    // before dawn, the Sun 19° below the horizon, past even astronomical
    // twilight's 18°, 80 minutes before sunrise (skyfield).
    // skyfield: geometric -19.13280718° az 111.94357408°, apparent
    // -19.12700279° az 111.94389538°. Almanac: -19.1231° az 111.9417°.
    func testSunBelowTheHorizonAtApollo8Splashdown() throws {
        let system = try SolarSystem.bundled()
        let t = Epoch(utcYear: 1968, month: 12, day: 27, hour: 15, minute: 51, second: 42)
        let sun = sun(at: t, latitude: 8.1, longitude: -165.0, height: 0, system: system)
        XCTAssertLessThan(sun.model.0, -18)
        XCTAssertEqual(sun.model.0, -19.13280718, accuracy: 2e-5)
        XCTAssertEqual(sun.model.1, 111.94357408, accuracy: 2e-5)
        XCTAssertEqual(sun.model.0, sun.almanac.0, accuracy: 0.02)
        XCTAssertEqual(sun.model.1, sun.almanac.1, accuracy: 0.02)
    }

    // MARK: Subsolar and sub-observer points

    // The subsolar point is the foot of the normal through the Sun, found by
    // the closed-form geodetic conversion 1.5e11 m out: its normal points
    // at the Sun to 1e-12 rad, the Sun reads 90° there, and its latitude is
    // the Sun's declination: -23.4456° at Apollo 8's launch, 6.1 h before
    // the solstice (skyfield). The almanac's Sun stands at its zenith too,
    // within its 0.01° and the 8.8" of parallax.
    func testSubsolarPoint() throws {
        let system = try SolarSystem.bundled(), earth = system.earth
        for t in [Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51), VesselLibrary.apollo11RangeZero,
                  Epoch(utcYear: 1969, month: 3, day: 20, hour: 6)] {
            let s = system.snapshot(at: t), o = s.orientation(earth)
            let p = SurfaceGeometry.subsolarPoint(on: earth, in: system, snapshot: s)
            let sun = o.toBody(s.position(system.sun) - s.position(earth))
            XCTAssertLessThan(angleBetween(p.normal, sun - p.position), 1e-12, "\(t)")
            XCTAssertEqual(p.position,
                           Ellipsoid.wgs84.bodyFixed(latitude: p.latitude, longitude: p.longitude, height: 0))
            let e = SurfaceGeometry.sunElevationAzimuth(latitude: p.latitude, longitude: p.longitude, on: earth,
                                                        in: system, snapshot: s)
            XCTAssertEqual(e.elevation, Double.pi / 2, accuracy: 1e-9, "\(t)")
            // The Sun's declination of date: the almanac's at its zenith.
            let a = almanacSun(jdTT: t.julianDateTDB, jdUT1: t.julianDateUT1, latitude: p.latitude / deg,
                               longitude: p.longitude / deg)
            XCTAssertEqual(a.elevation, 90, accuracy: 0.02, "\(t)")
        }
        let launch = system.snapshot(at: Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51))
        XCTAssertEqual(SurfaceGeometry.subsolarPoint(on: earth, in: system, snapshot: launch).latitude / deg,
                       -23.4456, accuracy: 1e-3)
    }

    // The sub-observer point of a point at a geodetic latitude, longitude and
    // height is that latitude and longitude, from 1 m up to the Moon's
    // distance, the observer on its normal (to 1e-12 rad, or 1 nm across).
    func testSubObserverPoint() throws {
        let system = try SolarSystem.bundled(), earth = system.earth
        let o = system.snapshot(at: VesselLibrary.apollo11RangeZero).orientation(earth)
        for (lat, lon, h) in [(28.6084, -80.6041, 185e3), (-89.9, 10.0, 7_000e3), (61.3, 179.99, 384_400e3),
                              (0.0, -165.0, 1.0)] {
            let r = o.toInertial(Ellipsoid.wgs84.bodyFixed(latitude: lat * deg, longitude: lon * deg, height: h))
            let p = SurfaceGeometry.subObserverPoint(r, on: earth, orientation: o)
            XCTAssertEqual(p.latitude / deg, lat, accuracy: 1e-10)
            XCTAssertEqual(p.longitude / deg, lon, accuracy: 1e-10)
            XCTAssertEqual((o.toBody(r) - p.position).length, h, accuracy: 1e-6 * max(1, h / 1e6))
            XCTAssertLessThan(angleBetween(p.normal, o.toBody(r) - p.position), 1e-12 + 1e-9 / h)
        }
    }

    // MARK: The specular point

    /// The path length O -> P -> S less |S| over the figure's point at
    /// geodetic `lat` and `lon` (rad), exact to about 1e-9 m with S at 1 au.
    func pathLength(_ lat: Double, _ lon: Double, observer: Vec3, source: Vec3, figure: Ellipsoid) -> Double {
        let p = figure.bodyFixed(latitude: lat, longitude: lon, height: 0)
        return (observer - p).length + (p.dot(p) - 2 * source.dot(p)) / ((source - p).length + source.length)
    }

    /// Fermat's principle by brute force: the figure's point of least path
    /// length, from a 1° grid over the whole globe narrowed by a factor of 4
    /// each round to 1e-11 rad. Independent of `specularPoint`'s bisection
    /// and Newton steps.
    func searchSpecularPoint(observer: Vec3, source: Vec3, figure: Ellipsoid) -> Vec3 {
        var best = (lat: 0.0, lon: 0.0, length: Double.infinity)
        for i in 0..<180 {
            for j in 0..<360 {
                let lat = (Double(i) - 89.5) * deg, lon = (Double(j) - 180) * deg
                let l = pathLength(lat, lon, observer: observer, source: source, figure: figure)
                if l < best.length { best = (lat, lon, l) }
            }
        }
        var step = deg
        while step > 1e-11 {
            step /= 4
            let center = best
            for i in -8...8 {
                for j in -8...8 {
                    let lat = max(-Double.pi / 2, min(Double.pi / 2, center.lat + Double(i) * step))
                    let lon = center.lon + Double(j) * step
                    let l = pathLength(lat, lon, observer: observer, source: source, figure: figure)
                    if l < best.length { best = (lat, lon, l) }
                }
            }
        }
        return figure.bodyFixed(latitude: best.lat, longitude: best.lon, height: 0)
    }

    /// The angle (rad) between the normal at `p` and the bisector of the
    /// directions from it to the observer and the source: 0 by the law of
    /// reflection (the two directions at equal angles to the normal, in one
    /// plane with it, on either side).
    func reflectionError(_ p: SurfaceGeometry.SurfacePoint, observer: Vec3, source: Vec3) -> Double {
        let o = (observer - p.position).normalized, s = (source - p.position).normalized
        return angleBetween(p.normal, o + s)
    }

    // The specular point obeys the law of reflection to 1e-10 rad, and lies
    // within 2 m of the point of least path length that a brute-force
    // search finds (0.3 m at most), for observers from 185 km, the Sun 6.8°
    // up below one (the glint 650 km off towards it, at 77° incidence), to
    // the Moon's distance. The figure's flattening moves the glint 0.3 to
    // 5 km out of the plane of the centre, the observer and the Sun, most
    // from far off and at 70° N.
    func testSpecularPointAgainstASearch() {
        let figure = Ellipsoid.wgs84, au = 149_597_870_700.0
        func at(_ lat: Double, _ lon: Double, _ h: Double) -> Vec3 {
            figure.bodyFixed(latitude: lat * deg, longitude: lon * deg, height: h)
        }
        func sun(_ lat: Double, _ lon: Double) -> Vec3 {
            figure.normal(latitude: lat * deg, longitude: lon * deg) * au
        }
        let cases: [(String, Vec3, Vec3)] = [
            ("185 km, Sun 35° from the zenith", at(28.6, -80.6, 185e3), sun(-5, -70)),
            ("185 km, Sun 6.8° up at LC-39A", at(28.6084, -80.6041, 185e3), sun(-23.44, -13.18)),
            ("7,000 km over 70° N", at(70, 20, 7_000e3), sun(10, 60)),
            ("60,000 km", at(-10, 120, 60_000e3), sun(23, 50)),
            ("384,400 km", at(5, -150, 384_400e3), sun(-20, -100)),
            ("the source 20,000 km off", at(30, 0, 2_000e3), at(-30, 40, 20_000e3)),
        ]
        for (name, observer, source) in cases {
            guard let p = SurfaceGeometry.specularPoint(observer: observer, source: source, on: figure) else {
                XCTFail("\(name): no specular point"); continue
            }
            let search = searchSpecularPoint(observer: observer, source: source, figure: figure)
            let error = reflectionError(p, observer: observer, source: source)
            let incidence = angleBetween(p.normal, source - p.position) / deg
            let offPlane = abs(p.position.dot(observer.cross(source).normalized))
            print(String(format: "%@: glint %.4f° %.4f°, incidence %.2f°, %.0f m off the plane; "
                         + "reflection %.1e rad, %.3f m from the search", name, p.latitude / deg, p.longitude / deg,
                         incidence, offPlane, error, (p.position - search).length))
            XCTAssertLessThan(error, 1e-10, name)
            XCTAssertLessThan((p.position - search).length, 2, name)
            XCTAssertGreaterThan(p.normal.dot(observer - p.position), 0, name)
            XCTAssertGreaterThan(p.normal.dot(source - p.position), 0, name)
        }
    }

    // Straight below an observer on the Sun's line the glint is the subsolar
    // point; with no point both see, in the Earth's shadow or with the
    // observer under the surface, there is none.
    func testSpecularPointLimitingCases() {
        let figure = Ellipsoid.wgs84, au = 149_597_870_700.0
        let lat = 40 * deg, lon = 75 * deg, normal = figure.normal(latitude: lat, longitude: lon)
        let foot = figure.bodyFixed(latitude: lat, longitude: lon, height: 0)
        let below = SurfaceGeometry.specularPoint(observer: foot + normal * 400e3, source: foot + normal * au,
                                                  on: figure)
        XCTAssertEqual(below?.latitude ?? .nan, lat, accuracy: 1e-12)
        XCTAssertEqual(below?.longitude ?? .nan, lon, accuracy: 1e-12)

        let sun = Vec3(au, 0, 0)
        XCTAssertNil(SurfaceGeometry.specularPoint(observer: Vec3(-7_378_137, 0, 0), source: sun, on: figure))
        XCTAssertNil(SurfaceGeometry.specularPoint(observer: Vec3(-6_500_000, 1_000_000, 2_000_000), source: sun,
                                                   on: figure))
        XCTAssertNil(SurfaceGeometry.specularPoint(observer: Vec3(6_000_000, 0, 0), source: sun, on: figure))
        // Just outside the shadow, low over the terminator, the glint is at
        // grazing incidence but still found.
        let dusk = Vec3(0, 6_378_137 + 300e3, 0)
        let grazing = SurfaceGeometry.specularPoint(observer: dusk, source: sun, on: figure)
        XCTAssertNotNil(grazing)
        if let g = grazing { XCTAssertLessThan(reflectionError(g, observer: dusk, source: sun), 1e-9) }
    }

    // On the Earth at an instant: the glint seen from 1,000 km at Apollo 8's
    // launch obeys the law of reflection in ICRF with DE421's Sun, and is
    // nil from the night side.
    func testSpecularPointOnTheEarth() throws {
        let system = try SolarSystem.bundled(), earth = system.earth
        let s = system.snapshot(at: Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51))
        let o = s.orientation(earth), sub = SurfaceGeometry.subsolarPoint(on: earth, in: system, snapshot: s)
        let sun = s.position(system.sun) - s.position(earth)
        let day = o.toInertial(Ellipsoid.wgs84.bodyFixed(latitude: sub.latitude + 0.3, longitude: sub.longitude - 0.5,
                                                          height: 1_000e3))
        let p = try XCTUnwrap(SurfaceGeometry.specularPoint(observer: day, on: earth, in: system, snapshot: s))
        let toObserver = (day - o.toInertial(p.position)).normalized
        let toSun = (sun - o.toInertial(p.position)).normalized
        XCTAssertLessThan(angleBetween(o.toInertial(p.normal), toObserver + toSun), 1e-10)
        let night = o.toInertial(Ellipsoid.wgs84.bodyFixed(latitude: -sub.latitude,
                                                            longitude: sub.longitude + Double.pi, height: 1_000e3))
        XCTAssertNil(SurfaceGeometry.specularPoint(observer: night, on: earth, in: system, snapshot: s))
    }
}

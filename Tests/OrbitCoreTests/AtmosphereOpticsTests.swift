import XCTest
@testable import OrbitCore

/// The atmosphere's optics (track A1) against Bodhaine et al. (1999),
/// Kasten & Young (1989), the ozone column and a direct numerical
/// integration of the optical depth.
final class AtmosphereOpticsTests: XCTestCase {
    static let optics = OpticalAtmosphere()
    static let rayleighOnly = OpticalAtmosphere(aerosol: .none, ozone: .none)
    var optics: OpticalAtmosphere { Self.optics }

    /// The optical depth along a ray by the trapezoid rule on `steps`
    /// uniform steps: the reference the quadrature is checked against.
    static func directOpticalDepth(_ o: OpticalAtmosphere, radius r: Double, cosZenith mu: Double,
                                   from s0: Double, to s1: Double, steps: Int = 200_000) -> Spectrum3 {
        let ds = (s1 - s0) / Double(steps)
        var sum = Spectrum3.zero
        for i in 0...steps {
            let w = i == 0 || i == steps ? 0.5 : 1.0
            let h = o.altitude(radius: r, cosZenith: mu, distance: s0 + Double(i) * ds)
            sum += o.extinction(altitude: h) * w
        }
        return sum * ds
    }

    /// Bodhaine eq. 29 gives their quoted σ(550 nm) = 4.5105e-27 cm², and its
    /// ratios at 440 and 680 nm are those of their Table 3's optical depths
    /// (0.24261, 0.097069, 0.040963 at sea level, 45° N), which share one column.
    func testBodhaineCrossSections() {
        let s = optics.rayleighCrossSection
        XCTAssertEqual(s.g, 4.5105e-31, accuracy: 4.5105e-31 * 1e-4)
        XCTAssertEqual(s.b / s.g, 0.24261 / 0.097069, accuracy: 2.5 * 2e-4)
        XCTAssertEqual(s.r / s.g, 0.040963 / 0.097069, accuracy: 0.42 * 2e-4)
    }

    /// Rayleigh optical depth from the US-1976 number density with
    /// Bodhaine's cross sections: 0.0971, 0.243 and 0.0410 at 550, 440 and
    /// 680 nm within 1.5 % (Bodhaine 1999 Table 3).
    func testRayleighOpticalDepthAgainstBodhaine() {
        let tau = Self.rayleighOnly.opticalDepth(altitude: 0, cosZenith: 1)
        XCTAssertEqual(tau.g, 0.097069, accuracy: 0.097069 * 0.015)
        XCTAssertEqual(tau.b, 0.24261, accuracy: 0.24261 * 0.015)
        XCTAssertEqual(tau.r, 0.040963, accuracy: 0.040963 * 0.015)
        // The column's effective height, N / n(0): about 8.43 km.
        let column = Self.rayleighOnly.airColumn(altitude: 0, cosZenith: 1)
        XCTAssertEqual(column / Self.rayleighOnly.airNumberDensity(altitude: 0), 8_430, accuracy: 100)
    }

    /// The launch day's sounding (AS-506, 16 July 1969) changes the
    /// Rayleigh optical depth by under 1 %.
    func testLaunchDaySoundingChangesTauByUnderOnePercent() {
        let day = OpticalAtmosphere(atmosphere: AS506.launchDayAtmosphere(), aerosol: .none, ozone: .none)
        let standard = Self.rayleighOnly.opticalDepth(altitude: 0, cosZenith: 1).g
        let launch = day.opticalDepth(altitude: 0, cosZenith: 1).g
        XCTAssertNotEqual(launch, standard)
        XCTAssertEqual(launch, standard, accuracy: standard * 0.01)
    }

    /// The ozone tent holds 300 DU, and its vertical optical depth is that
    /// column times the cross section, through the tent's corners.
    func testOzoneColumn() {
        let ozone = optics.ozone
        var column = 0.0
        let dh = 10.0
        for i in 0...10_000 {
            column += ozone.density(altitude: Double(i) * dh) * (i == 0 || i == 10_000 ? 0.5 : 1) * dh
        }
        XCTAssertEqual(column / OpticalAtmosphere.dobsonUnit, 300, accuracy: 1e-6)
        let all = optics.opticalDepth(altitude: 0, cosZenith: 1)
        let noOzone = OpticalAtmosphere(ozone: .none).opticalDepth(altitude: 0, cosZenith: 1)
        let expected = ozone.crossSection * (300 * OpticalAtmosphere.dobsonUnit)
        XCTAssertEqual(all.g - noOzone.g, expected.g, accuracy: expected.g * 2e-3)
        XCTAssertEqual(all.r - noOzone.r, expected.r, accuracy: expected.r * 2e-3)
        // About 0.027 at 550 nm, the Chappuis band's shoulder.
        XCTAssertEqual(expected.g, 0.0266, accuracy: 0.0005)
    }

    /// The aerosol's vertical optical depth is its AOD at 550 nm, with the
    /// Ångström exponent's slope across the three wavelengths.
    func testAerosolOpticalDepth() {
        let all = optics.opticalDepth(altitude: 0, cosZenith: 1)
        let clean = OpticalAtmosphere(aerosol: .none).opticalDepth(altitude: 0, cosZenith: 1)
        let aerosol = all - clean
        XCTAssertEqual(aerosol.g, 0.1, accuracy: 1e-4)
        XCTAssertEqual(aerosol.b / aerosol.r, pow(440.0 / 680, -1.3), accuracy: 1e-6)
    }

    /// The relative optical air mass at a zenith angle of 80° is 5.59
    /// (Kasten & Young 1989, refraction included) within 3 %: the 1976
    /// air's slant column over its vertical one, without refraction.
    func testKastenYoungAirMass() {
        let m80 = optics.relativeAirMass(altitude: 0, cosZenith: cos(80 * Double.pi / 180))
        XCTAssertEqual(m80, 5.59, accuracy: 5.59 * 0.03)
        XCTAssertEqual(optics.relativeAirMass(altitude: 0, cosZenith: 1), 1, accuracy: 1e-12)
        // Kasten-Young's formula at 60°: 1.995.
        XCTAssertEqual(optics.relativeAirMass(altitude: 0, cosZenith: 0.5), 1.995, accuracy: 0.01)
    }

    /// The quadrature against a direct trapezoid integration on 200,000
    /// steps: at the zenith, at 60°, along the horizon from the ground and
    /// from 10 km, and from orbit across the limb, within 1e-4 of τ.
    func testOpticalDepthAgainstDirectIntegration() {
        let rb = optics.bottomRadius
        let cases: [(h: Double, mu: Double)] = [
            (0, 1), (0, 0.5), (0, 0), (10_000, -0.05), (300_000, -0.29), (2_000, 0.02),
        ]
        for c in cases {
            let r = rb + c.h
            guard let seg = optics.atmosphereSegment(radius: r, cosZenith: c.mu) else {
                XCTFail("no atmosphere along \(c)"); continue
            }
            XCTAssertFalse(optics.rayMeetsGround(radius: r, cosZenith: c.mu))
            let quad = optics.opticalDepth(radius: r, cosZenith: c.mu, from: seg.enter, to: seg.exit)
            let direct = Self.directOpticalDepth(optics, radius: r, cosZenith: c.mu, from: seg.enter, to: seg.exit)
            XCTAssertEqual(quad.r, direct.r, accuracy: direct.r * 1e-4, "\(c)")
            XCTAssertEqual(quad.g, direct.g, accuracy: direct.g * 1e-4, "\(c)")
            XCTAssertEqual(quad.b, direct.b, accuracy: direct.b * 1e-4, "\(c)")
        }
    }

    /// Transmittance falls as the Sun sinks, and the light reddens:
    /// T(680)/T(440) rises with the air mass.
    func testTransmittanceMonotonicAndRedderAtTheHorizon() {
        var last = Spectrum3.one, lastRatio = 0.0
        for i in 0...90 {
            let mu = cos(Double(i) * Double.pi / 180)
            let t = optics.transmittance(altitude: 0, cosZenith: mu)
            XCTAssertLessThan(t.r, last.r)
            XCTAssertLessThan(t.g, last.g)
            XCTAssertLessThan(t.b, last.b)
            XCTAssertGreaterThan(t.r / t.b, lastRatio)
            XCTAssertGreaterThan(t.r, t.g)
            XCTAssertGreaterThan(t.g, t.b)
            last = t
            lastRatio = t.r / t.b
        }
        // At the zenith: about 0.84 in the green.
        let zenith = optics.transmittance(altitude: 0, cosZenith: 1)
        XCTAssertEqual(zenith.g, exp(-(0.0971 + 0.1 + 0.0266)), accuracy: 0.003)
    }

    /// From 10 km the Sun's centre is still above the horizon at −3.0°
    /// elevation and below it at −3.5° (the dip, acos(R/(R+h)), is 3.2°), at
    /// the equator and at the Cape, looking east and north.
    func testSunVisibleFrom10kmAtMinus3Degrees() {
        let deg = Double.pi / 180
        for lat in [0.0, 28.6, 60] {
            let lon = -80.6 * deg
            let p = optics.figure.bodyFixed(latitude: lat * deg, longitude: lon, height: 10_000)
            let up = optics.figure.normal(latitude: lat * deg, longitude: lon)
            let east = Vec3.unitZ.cross(up).normalized
            let north = up.cross(east)
            for horizontal in [east, north] {
                func sun(_ elevation: Double) -> Vec3 { up * sin(elevation * deg) + horizontal * cos(elevation * deg) }
                let visible = optics.sunTransmittance(position: p, sunDir: sun(-3.0))
                let hidden = optics.sunTransmittance(position: p, sunDir: sun(-3.5))
                XCTAssertGreaterThan(visible.r, 1e-6, "latitude \(lat)")
                XCTAssertLessThan(visible.r, 0.05, "latitude \(lat)")
                XCTAssertEqual(hidden, .zero, "latitude \(lat)")
            }
        }
    }

    /// The Sun's transmittance at a point: the same as along the local
    /// zenith cosine from the point's altitude; 1 above the air; through the
    /// limb from orbit, equal to the direct integration and reddening as the
    /// tangent point drops. The pole may be any axis.
    func testSunTransmittanceAtVessels() {
        let deg = Double.pi / 180
        // On the equator, the figure's stretch leaves the geometry spherical.
        let pad = Vec3(optics.bottomRadius + 100, 0, 0)
        for elevation in [90.0, 30, 7, 1] {
            let dir = Vec3(sin(elevation * deg), cos(elevation * deg), 0)
            let t = optics.sunTransmittance(position: pad, sunDir: dir)
            let expected = optics.transmittance(altitude: 100, cosZenith: sin(elevation * deg))
            XCTAssertEqual(t.g, expected.g, accuracy: expected.g * 1e-9)
        }
        let orbit = Vec3(optics.bottomRadius + 185_000, 0, 0)
        XCTAssertEqual(optics.sunTransmittance(position: orbit, sunDir: Vec3(0.6, 0.8, 0)), .one)
        // Across the limb with the tangent point at 40, 20, 10 and 5 km.
        let r = orbit.length
        var lastRatio = 0.0
        for tangent in [40_000.0, 20_000, 10_000, 5_000] {
            let sinZ = (optics.bottomRadius + tangent) / r
            let mu = -(1 - sinZ * sinZ).squareRoot()
            let t = optics.sunTransmittance(position: orbit, sunDir: Vec3(mu, sinZ, 0))
            let seg = optics.atmosphereSegment(radius: r, cosZenith: mu)!
            let direct = Self.directOpticalDepth(optics, radius: r, cosZenith: mu,
                                                 from: seg.enter, to: seg.exit).attenuation
            XCTAssertEqual(t.g, direct.g, accuracy: Swift.max(direct.g * 1e-3, 1e-12), "tangent \(tangent)")
            XCTAssertGreaterThan(t.r / t.b, lastRatio)
            lastRatio = t.r / t.b
            // Rotated so the pole is no longer +z: the same answer.
            let q = Quat(axis: Vec3(1, 2, 3).normalized, angle: 0.7)
            let turned = optics.sunTransmittance(position: q.rotate(orbit), sunDir: q.rotate(Vec3(mu, sinZ, 0)),
                                                 pole: q.rotate(.unitZ))
            XCTAssertEqual(turned.g, t.g, accuracy: t.g * 1e-9 + 1e-300)
        }
    }

    /// The pad at the Cape (28.6° N) is on the ground, not 4.8 km under the
    /// equatorial sphere: a Sun 7° up is transmitted as from the ground, and
    /// reddened (the Apollo 8 launch's light).
    func testSunTransmittanceOnThePad() {
        let deg = Double.pi / 180
        let lat = 28.608 * deg, lon = -80.604 * deg
        let p = optics.figure.bodyFixed(latitude: lat, longitude: lon, height: 50)
        let up = optics.figure.normal(latitude: lat, longitude: lon)
        let east = Vec3.unitZ.cross(up).normalized
        let t = optics.sunTransmittance(position: p, sunDir: up * sin(7 * deg) + east * cos(7 * deg))
        let expected = optics.transmittance(altitude: 50, cosZenith: sin(7 * deg))
        XCTAssertEqual(t.g, expected.g, accuracy: expected.g * 0.02)
        XCTAssertGreaterThan(t.r / t.b, 2)
        // Just under the ground is lifted onto it, not blacked out.
        let under = optics.figure.bodyFixed(latitude: lat, longitude: lon, height: -30)
        XCTAssertGreaterThan(optics.sunTransmittance(position: under, sunDir: up).g, 0.75)
    }

    /// The noon Sun's luminance at sea level (plan.md decision 8): above
    /// the air E⊙/Ω⊙ = 131 klx over the disc's 6.8e-5 sr, 1.9e9 cd/m²; times
    /// the zenith transmittance at 550 nm, the ground value 1.6e9 within 5 %.
    func testNoonSunLuminanceAtSeaLevel() {
        let alpha = Eclipse.solarRadius / 149_597_870_700
        let above = 131_000 / (Double.pi * alpha * alpha)
        XCTAssertEqual(above, 1.9e9, accuracy: 0.05e9)
        let ground = above * optics.transmittance(altitude: 0, cosZenith: 1).g
        XCTAssertEqual(ground, 1.6e9, accuracy: 0.08e9)
    }

    /// Both phase functions integrate to 1 over the sphere.
    func testPhaseFunctionsAreNormalised() {
        let n = 20_000
        var rayleigh = 0.0, aerosol = 0.0
        for i in 0..<n {
            let mu = -1 + (Double(i) + 0.5) * 2 / Double(n)
            rayleigh += OpticalAtmosphere.rayleighPhase(cosTheta: mu)
            aerosol += optics.aerosolPhase(cosTheta: mu)
        }
        let dOmega = 2 * Double.pi * 2 / Double(n)
        XCTAssertEqual(rayleigh * dOmega, 1, accuracy: 1e-8)
        XCTAssertEqual(aerosol * dOmega, 1, accuracy: 1e-4)
        // Forward scattering toward the Sun dominates the aerosol's.
        XCTAssertGreaterThan(optics.aerosolPhase(cosTheta: 1), 50 * optics.aerosolPhase(cosTheta: -1))
    }
}

import XCTest
@testable import OrbitCore

/// The atmosphere's lookup tables (track A1, for A2): the parameterisation,
/// the transmittance against a direct integration, the multiple-scattering
/// table's energy balance and the irradiance against a brute-force one.
final class AtmosphereLUTTests: XCTestCase {
    /// The standard tables, built once for the suite, and how long that took.
    static let built: (lut: AtmosphereLUT, seconds: Double) = {
        let start = Date()
        let lut = AtmosphereLUT()
        return (lut, Date().timeIntervalSince(start))
    }()
    var lut: AtmosphereLUT { Self.built.lut }

    /// Smaller tables for the tests that build their own, without the
    /// irradiance table they do not read.
    static let reduced: AtmosphereLUT.Resolution = {
        var r = AtmosphereLUT.Resolution.standard
        r.transmittanceWidth = 128
        r.transmittanceHeight = 32
        r.multipleScatteringSize = 16
        r.irradianceWidth = 2
        r.irradianceHeight = 2
        return r
    }()

    /// The transmittance table's (u, v) ↔ (r, μ) round trip, and its edges:
    /// the first column is the zenith, the last the horizon, the first row
    /// the ground and the last the top.
    func testTransmittanceParameterisationRoundTrip() {
        let rb = lut.bottomRadius, rt = lut.topRadius
        for h in [0.0, 50, 1_000, 10_000, 45_000, 99_999] {
            let r = rb + h
            let horizon = -(1 - (rb / r) * (rb / r)).squareRoot()
            for f in [0.0, 0.01, 0.3, 0.7, 0.99, 1] {
                let mu = horizon + (1 - horizon) * f
                let uv = lut.transmittanceUV(radius: r, cosZenith: mu)
                let back = lut.transmittanceRadiusAndCosine(u: uv.u, v: uv.v)
                XCTAssertEqual(back.radius, r, accuracy: 1e-6, "h \(h) mu \(mu)")
                XCTAssertEqual(back.cosZenith, mu, accuracy: 1e-9, "h \(h) mu \(mu)")
            }
        }
        let w = Double(lut.transmittance.width), hgt = Double(lut.transmittance.height)
        let zenithGround = lut.transmittanceRadiusAndCosine(u: 0.5 / w, v: 0.5 / hgt)
        XCTAssertEqual(zenithGround.radius, rb, accuracy: 1e-6)
        XCTAssertEqual(zenithGround.cosZenith, 1, accuracy: 1e-12)
        let horizonTop = lut.transmittanceRadiusAndCosine(u: 1 - 0.5 / w, v: 1 - 0.5 / hgt)
        XCTAssertEqual(horizonTop.radius, rt, accuracy: 1e-6)
        XCTAssertEqual(horizonTop.cosZenith, -(1 - (rb / rt) * (rb / rt)).squareRoot(), accuracy: 1e-9)
    }

    /// The (μs, r) tables' round trip and edges; half their rows lie below
    /// 25 km.
    func testSunTableParameterisationRoundTrip() {
        for (w, h) in [(32, 32), (64, 16)] {
            for alt in [0.0, 7_000, 100_000] {
                for muS in [-1.0, -0.2, 0, 0.35, 1] {
                    let uv = lut.sunTableUV(radius: lut.bottomRadius + alt, cosSun: muS, width: w, height: h)
                    let back = lut.sunTableRadiusAndCosine(u: uv.u, v: uv.v, width: w, height: h)
                    XCTAssertEqual(back.radius, lut.bottomRadius + alt, accuracy: 1e-6)
                    XCTAssertEqual(back.cosSun, muS, accuracy: 1e-12)
                }
            }
            let first = lut.sunTableRadiusAndCosine(u: 0.5 / Double(w), v: 0.5 / Double(h), width: w, height: h)
            XCTAssertEqual(first.cosSun, -1, accuracy: 1e-12)
            XCTAssertEqual(first.radius, lut.bottomRadius, accuracy: 1e-6)
            let middle = lut.sunTableRadiusAndCosine(u: 0.5, v: 0.5, width: w, height: h)
            XCTAssertEqual(middle.radius - lut.bottomRadius, 25_000, accuracy: 1e-6)
        }
    }

    /// The transmittance table at its texel centres is the optics' optical
    /// depth there, to Float precision.
    func testTransmittanceTableAtTexelCentres() {
        let t = lut.transmittance
        for (i, j) in [(0, 0), (255, 0), (17, 9), (128, 31), (250, 50), (255, 63), (0, 63)] {
            let p = lut.transmittanceRadiusAndCosine(u: (Double(i) + 0.5) / Double(t.width),
                                                     v: (Double(j) + 0.5) / Double(t.height))
            let d = lut.optics.distanceToTop(radius: p.radius, cosZenith: p.cosZenith)!
            let exact = lut.optics.opticalDepth(radius: p.radius, cosZenith: p.cosZenith, from: 0, to: d).attenuation
            let texel = t[i, j]
            XCTAssertEqual(texel.g, exact.g, accuracy: exact.g * 1e-6 + 1e-30, "texel \(i), \(j)")
            XCTAssertEqual(texel.b, exact.b, accuracy: exact.b * 1e-6 + 1e-30, "texel \(i), \(j)")
            // The lookup lands on the texel.
            let looked = lut.transmittanceToTop(radius: p.radius, cosZenith: p.cosZenith)
            XCTAssertEqual(looked.g, texel.g, accuracy: texel.g * 1e-4 + 1e-30, "texel \(i), \(j)")
        }
    }

    /// The transmittance table against the direct trapezoid integration, at
    /// the zenith and at grazing angles, from the ground, 3.3 km (midway
    /// between two rows), 10 km and the top: τ within 1 % between texels.
    /// The worst are 0.44 % half a degree above the horizon at 3.3 km and
    /// 0.53 % (blue) from the top, where the columns are steepest.
    func testTransmittanceTableAgainstDirectIntegration() {
        let optics = lut.optics, rb = lut.bottomRadius
        for h in [0.0, 3_333, 10_000, 100_000] {
            let r = rb + h
            let horizon = -(1 - (rb / r) * (rb / r)).squareRoot()
            for mu in [1.0, 0.5, 0.1, horizon + 0.035, horizon + 0.0087, horizon] {
                let d = optics.distanceToTop(radius: r, cosZenith: mu)!
                let direct = AtmosphereOpticsTests.directOpticalDepth(optics, radius: r, cosZenith: mu,
                                                                      from: 0, to: d, steps: 50_000)
                let table = lut.transmittanceToTop(radius: r, cosZenith: mu)
                if direct.g == 0 {
                    XCTAssertEqual(table, .one, "h \(h) mu \(mu)")
                    continue
                }
                let tau = Spectrum3(-log(table.r), -log(table.g), -log(table.b))
                XCTAssertEqual(tau.r, direct.r, accuracy: direct.r * 0.01, "h \(h) mu \(mu)")
                XCTAssertEqual(tau.g, direct.g, accuracy: direct.g * 0.01, "h \(h) mu \(mu)")
                XCTAssertEqual(tau.b, direct.b, accuracy: direct.b * 0.01, "h \(h) mu \(mu)")
            }
        }
    }

    /// The Sun's transmittance from the tables fades to 0 as its disc sets
    /// behind the planet, and equals the table's above the horizon.
    func testTransmittanceToSunAtTheHorizon() {
        let r = lut.bottomRadius + 10_000
        let horizon = -(1 - (lut.bottomRadius / r) * (lut.bottomRadius / r)).squareRoot()
        let alpha = lut.sunAngularRadius
        XCTAssertEqual(lut.transmittanceToSun(radius: r, cosSun: horizon - alpha), .zero)
        let half = lut.transmittanceToSun(radius: r, cosSun: horizon).g
        XCTAssertEqual(half, 0.5 * lut.transmittanceToTop(radius: r, cosZenith: horizon).g, accuracy: 1e-12)
        XCTAssertEqual(lut.transmittanceToSun(radius: r, cosSun: 0.5), lut.transmittanceToTop(radius: r, cosZenith: 0.5))
    }

    /// Every multiple-scattering transfer factor f_ms lies in (0, 1), so the
    /// series of orders converges, and Ψ_ms is positive and finite. f_ms
    /// does not depend on the Sun.
    func testMultipleScatteringFactorsInUnitInterval() {
        for h in [0.0, 5_000, 30_000, 100_000] {
            let atNoon = lut.multipleScatteringIntegrals(radius: lut.bottomRadius + h, cosSun: 1).transfer
            for muS in [-0.3, 0, 0.5, 1] {
                let f = lut.multipleScatteringIntegrals(radius: lut.bottomRadius + h, cosSun: muS).transfer
                for c in [f.r, f.g, f.b] {
                    XCTAssertGreaterThan(c, 0)
                    XCTAssertLessThan(c, 1)
                }
                XCTAssertEqual(f.b, atNoon.b, accuracy: 1e-12)
            }
            // Bluer light is rescattered more: about a quarter at 440 nm on the ground.
            XCTAssertGreaterThan(atNoon.b, atNoon.g)
            XCTAssertGreaterThan(atNoon.g, atNoon.r)
        }
        let t = lut.multipleScattering
        for j in 0..<t.height {
            for i in 0..<t.width {
                let v = t[i, j]
                XCTAssertTrue(v.min >= 0 && v.max.isFinite, "texel \(i), \(j)")
            }
        }
    }

    /// The tables' quadrature is converged: texels of the multiple-scattering
    /// and irradiance tables against the same integrals on 32 nodes, 16 or
    /// more azimuths and 60 or more steps, within 2 % and 1.5 %.
    func testTablesAgainstFinerQuadrature() {
        let ms = lut.multipleScattering
        for (i, j) in [(31, 0), (24, 5), (20, 12), (31, 31), (16, 3)] {
            let p = lut.sunTableRadiusAndCosine(u: (Double(i) + 0.5) / Double(ms.width),
                                                v: (Double(j) + 0.5) / Double(ms.height),
                                                width: ms.width, height: ms.height)
            let (l2, f) = lut.multipleScatteringIntegrals(radius: p.radius, cosSun: p.cosSun,
                                                          zenithNodes: 32, azimuths: 16, steps: 60)
            let fine = l2 / (Spectrum3.one - f)
            XCTAssertEqual(ms[i, j].g, fine.g, accuracy: fine.g * 0.02, "Ψ texel \(i), \(j)")
            XCTAssertEqual(ms[i, j].b, fine.b, accuracy: fine.b * 0.02, "Ψ texel \(i), \(j)")
        }
        let e = lut.irradiance
        for (i, j) in [(63, 0), (41, 0), (33, 0), (47, 3)] {
            let p = lut.sunTableRadiusAndCosine(u: (Double(i) + 0.5) / Double(e.width),
                                                v: (Double(j) + 0.5) / Double(e.height),
                                                width: e.width, height: e.height)
            let fine = lut.skyIrradianceIntegral(radius: p.radius, cosSun: p.cosSun, zenithNodes: 32,
                                                 azimuths: 32, steps: 80)
            XCTAssertEqual(e[i, j].g, fine.g, accuracy: fine.g * 0.015, "E texel \(i), \(j)")
            XCTAssertEqual(e[i, j].b, fine.b, accuracy: fine.b * 0.015, "E texel \(i), \(j)")
        }
    }

    /// Energy conservation: in an atmosphere that only scatters (no ozone,
    /// conservative aerosol) over a black ground, with the Sun at the zenith,
    /// the direct beam at the ground plus the sky's light down at the ground
    /// and up through the top add up to the Sun's within 0.5 % (0.35 % at
    /// worst). Single scattering alone loses 6-9 % of the blue: the
    /// multiple-scattering table returns it.
    func testEnergyConservation() {
        for aerosol in [OpticalAtmosphere.Aerosol.none, OpticalAtmosphere.Aerosol(singleScatteringAlbedo: 1)] {
            let optics = OpticalAtmosphere(aerosol: aerosol, ozone: .none)
            let lut = AtmosphereLUT(optics: optics, groundAlbedo: .zero, resolution: Self.reduced)
            func flux(_ r: Double, _ nodes: [(t: Double, w: Double)], down: Bool, multiple: Bool) -> Spectrum3 {
                var sum = Spectrum3.zero
                for (t, w) in nodes {
                    let mu = down ? t : -t
                    let l = lut.march(radius: r, cosZenith: mu, cosSun: 1, cosView: mu, steps: 40, isotropic: false,
                                      withMultipleScattering: multiple, groundAlbedo: .zero,
                                      sun: lut.transmittanceToSun).radiance
                    sum += l * (t * w * 2 * Double.pi)
                }
                return sum
            }
            let nodes = GaussLegendre.rule(48)
            let direct = lut.sunIrradiance(radius: lut.bottomRadius, cosSun: 1)
            let total = direct + flux(lut.bottomRadius, nodes, down: true, multiple: true)
                + flux(lut.topRadius, nodes, down: false, multiple: true)
            let single = direct + flux(lut.bottomRadius, nodes, down: true, multiple: false)
                + flux(lut.topRadius, nodes, down: false, multiple: false)
            print("AtmosphereLUT energy, AOD \(aerosol.opticalDepth550): total \(total), single scattering \(single)")
            for c in [total.r, total.g, total.b] {
                XCTAssertEqual(c, 1, accuracy: 0.005, "aerosol \(aerosol.opticalDepth550)")
            }
            XCTAssertLessThan(single.b, 0.97, "aerosol \(aerosol.opticalDepth550)")
        }
    }

    /// The irradiance with the Sun at the zenith: the table's sky light plus
    /// the direct beam within 2 % of the transmittance times cos θ plus a
    /// brute-force integration of the sky, with the optics' exact
    /// transmittance and 400 steps. The sky light alone is within 2 % on the
    /// ground, 3 % at 5 km.
    func testIrradianceAtZenithSunAgainstBruteForce() {
        let optics = lut.optics, rb = lut.bottomRadius
        let exactSun: (Double, Double) -> Spectrum3 = { rs, muS in
            optics.transmittance(altitude: rs - rb, cosZenith: muS)
        }
        for (h, skyTolerance) in [(0.0, 0.02), (5_000, 0.03), (20_000, 0.1)] {
            let r = rb + h
            var brute = Spectrum3.zero
            for (mu, w) in GaussLegendre.rule(32) {
                let l = lut.march(radius: r, cosZenith: mu, cosSun: 1, cosView: mu, steps: 400, isotropic: false,
                                  withMultipleScattering: true, groundAlbedo: lut.groundAlbedo, sun: exactSun).radiance
                brute += l * (mu * w * 2 * Double.pi)
            }
            brute += optics.transmittance(altitude: h, cosZenith: 1)
            let sky = lut.skyIrradiance(radius: r, cosSun: 1)
            let table = lut.sunIrradiance(radius: r, cosSun: 1) + sky
            XCTAssertEqual(table.r, brute.r, accuracy: brute.r * 0.02, "h \(h)")
            XCTAssertEqual(table.g, brute.g, accuracy: brute.g * 0.02, "h \(h)")
            XCTAssertEqual(table.b, brute.b, accuracy: brute.b * 0.02, "h \(h)")
            let bruteSky = brute - optics.transmittance(altitude: h, cosZenith: 1)
            print("AtmosphereLUT zenith-Sun irradiance at \(h) m: total \(table) vs \(brute), sky \(sky) vs \(bruteSky)")
            XCTAssertEqual(sky.g, bruteSky.g, accuracy: bruteSky.g * skyTolerance, "sky at h \(h)")
            XCTAssertEqual(sky.b, bruteSky.b, accuracy: bruteSky.b * skyTolerance, "sky at h \(h)")
        }
        // On the ground the sky gives about an eighth of the noon light at 550 nm.
        XCTAssertEqual(lut.skyIrradiance(radius: rb, cosSun: 1).g, 0.12, accuracy: 0.01)
    }

    /// The profile table times the coefficients is the optics' medium.
    func testProfileTimesCoefficientsIsTheMedium() {
        let c = lut.coefficients, p = lut.profile
        for h in stride(from: 0.0, through: 100_000, by: 1_237) {
            let s = p.sample(u: AtmosphereLUT.textureCoordinate(unit: h / OpticalAtmosphere.top, size: p.width), v: 0.5)
            let m = lut.optics.medium(altitude: h)
            let rayleigh = c.rayleighScatteringAtGround * s.r
            let aerosol = c.aerosolExtinctionAtGround * s.g
            let ozone = c.ozoneAbsorptionAtPeak * s.b
            XCTAssertEqual(rayleigh.b, m.rayleighScattering.b, accuracy: m.rayleighScattering.b * 1e-3, "h \(h)")
            XCTAssertEqual(aerosol.g, m.aerosolExtinction.g, accuracy: m.aerosolExtinction.g * 1e-3, "h \(h)")
            XCTAssertEqual(ozone.g, m.ozoneAbsorption.g, accuracy: c.ozoneAbsorptionAtPeak.g * 1e-3, "h \(h)")
        }
        XCTAssertEqual(c.rayleighScaleHeight, 8_430, accuracy: 100)
        XCTAssertEqual(c.aerosolScatteringAtGround.g, 0.9 * 0.1 / 1_200, accuracy: 1e-12)
    }

    /// The sky's colour: blue overhead at noon, and the aerosol's aureole
    /// brighter toward the Sun than away from it.
    func testSkyColour() {
        let rb = lut.bottomRadius
        let zenith = lut.skyRadiance(radius: rb, cosZenith: 1, cosSun: 0.7, cosView: 0.7)
        XCTAssertGreaterThan(zenith.b, 2 * zenith.r)
        XCTAssertGreaterThan(zenith.b, zenith.g)
        let toward = lut.skyRadiance(radius: rb, cosZenith: 0.5, cosSun: 0.5, cosView: cos(0.1))
        let away = lut.skyRadiance(radius: rb, cosZenith: 0.5, cosSun: 0.5, cosView: -0.5)
        XCTAssertGreaterThan(toward.g, 3 * away.g)
    }

    /// The standard tables' build time (0.7 s in -O on four cloud cores),
    /// and the parallel build gives the same tables every time.
    func testBuildTimeAndDeterminism() {
        print(String(format: "AtmosphereLUT standard build: %.3f s", Self.built.seconds))
        XCTAssertGreaterThan(lut.transmittance.texels.count, 0)
        let a = AtmosphereLUT(resolution: Self.reduced), b = AtmosphereLUT(resolution: Self.reduced)
        XCTAssertEqual(a.transmittance, b.transmittance)
        XCTAssertEqual(a.multipleScattering, b.multipleScattering)
        XCTAssertEqual(a.irradiance, b.irradiance)
    }
}

import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The shading model (`BRDF`) against published identities and data: the
/// normalisation of the GGX distribution, Heitz's projected-area identity
/// for Smith's Λ, Schlick's mirror limit of the DFG table, an independent
/// quadrature of the table, the white furnace with multiple scattering,
/// Rakić's aluminium, Tokuyoshi and Kaplanyan's filter, Karis' Sun disc and
/// Howell's sphere view factor.
final class BRDFTests: XCTestCase {
    static let alphas = [0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 1.0]

    /// ∫ D(m) (n·m) dm = 1 over the hemisphere (Walter et al. 2007, eq. 4).
    func testGGXProjectedAreaIsOne() {
        for alpha in Self.alphas {
            // Midpoint rule in θ, dense enough for the narrowest peak.
            let n = 400_000
            let dTheta = 0.5 * Double.pi / Double(n)
            var sum = 0.0
            for i in 0..<n {
                let theta = (Double(i) + 0.5) * dTheta
                sum += BRDF.ggx(nh: cos(theta), alpha: alpha) * cos(theta) * sin(theta)
            }
            XCTAssertEqual(2 * Double.pi * sum * dTheta, 1, accuracy: 2e-4, "α \(alpha)")
        }
    }

    /// Heitz (2014, eq. 2 with eq. 43): ∫ ⟨o, m⟩⁺ D(m) dm = cos θo (1 + Λ(o)),
    /// the projected area of the microsurface seen from o equals the
    /// macrosurface's, which pins Λ to D.
    func testSmithLambdaSatisfiesTheProjectedAreaIdentity() {
        for alpha in [0.1, 0.3, 0.6, 1.0] {
            for thetaO in [0.0, 0.4, 0.9, 1.3, 1.5] {
                let o = Vec3(sin(thetaO), 0, cos(thetaO))
                let nt = 1_500, np = 360
                var sum = 0.0
                let dT = 0.5 * Double.pi / Double(nt), dP = 2 * Double.pi / Double(np)
                for i in 0..<nt {
                    let t = (Double(i) + 0.5) * dT
                    let d = BRDF.ggx(nh: cos(t), alpha: alpha) * sin(t)
                    for j in 0..<np {
                        let p = (Double(j) + 0.5) * dP
                        let m = Vec3(sin(t) * cos(p), sin(t) * sin(p), cos(t))
                        sum += max(o.dot(m), 0) * d
                    }
                }
                let projected = sum * dT * dP
                let expected = cos(thetaO) * (1 + BRDF.smithLambda(cosine: cos(thetaO), alpha: alpha))
                XCTAssertEqual(projected, expected, accuracy: 4e-3 * max(expected, 0.1), "α \(alpha), θo \(thetaO)")
            }
        }
    }

    /// Height correlation never shadows more than the separable product
    /// allows, nor less than the worse side; V is G2 / (4 n·v n·l); the
    /// BRDF is reciprocal.
    func testHeightCorrelatedVisibility() {
        for alpha in Self.alphas {
            for nv in [0.05, 0.3, 0.7, 1.0] {
                for nl in [0.05, 0.5, 1.0] {
                    let g2 = BRDF.smithG2(nv: nv, nl: nl, alpha: alpha)
                    let g1v = BRDF.smithG1(cosine: nv, alpha: alpha), g1l = BRDF.smithG1(cosine: nl, alpha: alpha)
                    XCTAssertGreaterThanOrEqual(g2 + 1e-12, g1v * g1l)
                    XCTAssertLessThanOrEqual(g2, min(g1v, g1l) + 1e-12)
                    XCTAssertEqual(BRDF.visibility(nv: nv, nl: nl, alpha: alpha), g2 / (4 * nv * nl),
                                   accuracy: 1e-9 * max(1, g2 / (4 * nv * nl)))
                }
            }
        }
        let n = Vec3(0, 0, 1), v = Vec3(0.3, 0.2, 0.9).normalized, l = Vec3(-0.5, 0.1, 0.6).normalized
        XCTAssertEqual(BRDF.specular(n: n, v: v, l: l, alpha: 0.3, f0: 0.04),
                       BRDF.specular(n: n, v: l, l: v, alpha: 0.3, f0: 0.04), accuracy: 1e-12)
    }

    /// For a mirror the split sum is Schlick's own: A = 1 - (1 - n·v)⁵,
    /// B = (1 - n·v)⁵ (Schlick 1994), which the table's first row (α ≈
    /// 6e-5) must give.
    func testDFGMirrorLimitIsSchlick() {
        let table = BRDF.dfgTable
        for i in stride(from: 0, to: table.size, by: 7) {
            let nv = (Double(i) + 0.5) / Double(table.size)
            let schlick = pow(1 - nv, 5)
            let t = table.texel(i, 0)
            XCTAssertEqual(t.a, 1 - schlick, accuracy: 2e-3, "n·v \(nv)")
            XCTAssertEqual(t.b, schlick, accuracy: 2e-3, "n·v \(nv)")
        }
    }

    /// The table against an independent integral: a plain midpoint rule
    /// over the hemisphere of light directions of D G2 F / (4 n·v n·l) cos,
    /// no importance sampling.
    func testDFGMatchesDirectQuadrature() {
        for (nv, r) in [(0.9, 0.3), (0.5, 0.5), (0.2, 0.7), (0.7, 0.9), (0.1, 1.0), (0.95, 0.15)] {
            let alpha = r * r
            let v = Vec3((1 - nv * nv).squareRoot(), 0, nv)
            let nt = 1_200, np = 720
            let dT = 0.5 * Double.pi / Double(nt), dP = 2 * Double.pi / Double(np)
            var a = 0.0, b = 0.0
            for i in 0..<nt {
                let t = (Double(i) + 0.5) * dT
                for j in 0..<np {
                    let p = (Double(j) + 0.5) * dP
                    let l = Vec3(sin(t) * cos(p), sin(t) * sin(p), cos(t))
                    let h = (v + l).normalized
                    let base = BRDF.ggx(nh: h.z, alpha: alpha) * BRDF.visibility(nv: nv, nl: l.z, alpha: alpha)
                        * l.z * sin(t)
                    let fc = pow(1 - v.dot(h), 5)
                    a += base * (1 - fc)
                    b += base * fc
                }
            }
            a *= dT * dP
            b *= dT * dP
            let sampled = BRDF.dfg(nv: nv, alpha: alpha)
            XCTAssertEqual(sampled.a, a, accuracy: 4e-3, "A at n·v \(nv), r \(r)")
            XCTAssertEqual(sampled.b, b, accuracy: 2e-3, "B at n·v \(nv), r \(r)")
            let looked = BRDF.dfgTable.lookup(nv: nv, roughness: r)
            XCTAssertEqual(looked.a + looked.b, a + b, accuracy: 1e-2, "the table at n·v \(nv), r \(r)")
        }
    }

    /// The white furnace (design-renderer-core §5): a conductor of F0 = 1
    /// under a uniform environment reflects at least 98 % of it at every
    /// roughness and angle, with multiple scattering restored through the
    /// table as the GPU reads it, both ways the renderer uses it: a light's
    /// compensated BRDF integrated over the hemisphere, and Fdez-Agüera's
    /// environment weights. Without compensation rough metal loses far more.
    func testWhiteFurnaceWithMultipleScattering() {
        var worstSingle = 1.0
        for r in stride(from: 0.05, through: 1.0, by: 0.05) {
            for nv in [0.05, 0.2, 0.5, 0.8, 1.0] {
                let t = BRDF.dfgTable.lookup(nv: nv, roughness: r)
                let single = t.a + t.b
                worstSingle = min(worstSingle, single)
                let light = single * BRDF.energyCompensation(f0: 1, a: t.a, b: t.b)
                XCTAssertGreaterThanOrEqual(light, 0.98, "light, r \(r), n·v \(nv)")
                XCTAssertLessThanOrEqual(light, 1.02, "light, r \(r), n·v \(nv)")
                let w = BRDF.environmentWeights(f0: 1, albedo: 0, a: t.a, b: t.b)
                XCTAssertEqual(w.specular + w.multiple, 1, accuracy: 0.02, "environment, r \(r), n·v \(nv)")
                // A white dielectric: specular plus diffuse is the whole.
                let d = BRDF.environmentWeights(f0: 0.04, albedo: 1, a: t.a, b: t.b)
                XCTAssertEqual(d.specular + d.multiple + d.diffuse, 1, accuracy: 1e-9)
            }
        }
        XCTAssertLessThan(worstSingle, 0.7, "single scattering alone loses energy at high roughness")
    }

    /// Aluminium at 550 nm from Rakić et al. (1998, Brendel-Bormann fit;
    /// refractiveindex.info, CC0): n, k interpolated between 541.47 nm
    /// (0.93525, 6.3099) and 564.52 nm (1.0162, 6.5519) give F0 0.91-0.92
    /// (design-renderer-core §5).
    func testAluminiumReflectanceFromRakic() {
        let t = (0.550 - 0.54147) / (0.56452 - 0.54147)
        let n = 0.93525 + (1.0162 - 0.93525) * t, k = 6.3099 + (6.5519 - 6.3099) * t
        let f0 = BRDF.normalIncidenceReflectance(n: n, k: k)
        XCTAssertGreaterThanOrEqual(f0, 0.91)
        XCTAssertLessThanOrEqual(f0, 0.92)
        // A dielectric of n = 1.5 (glass, paint binder): 0.04.
        XCTAssertEqual(BRDF.normalIncidenceReflectance(n: 1.5, k: 0), 0.04, accuracy: 1e-12)
    }

    /// Tokuyoshi and Kaplanyan (2021, listing 5): a flat surface keeps its
    /// α², a curved one widens by 2σ²|∂n|² with σ² = 1/(2π), the kernel
    /// clamped at κ = 0.18, the result at 1.
    func testSpecularAntiAliasingFilter() {
        XCTAssertEqual(BRDF.filteredAlpha2(0.01, normalDerivatives: 0), 0.01)
        XCTAssertEqual(BRDF.filteredAlpha2(0.01, normalDerivatives: 0.05), 0.01 + 0.05 / Double.pi, accuracy: 1e-12)
        XCTAssertEqual(BRDF.filteredAlpha2(0.01, normalDerivatives: 10), 0.19, accuracy: 1e-12)
        XCTAssertEqual(BRDF.filteredAlpha2(0.95, normalDerivatives: 10), 1)
    }

    /// Karis (2013): inside the disc the reflection is its own
    /// representative direction; outside, the direction is on the disc's
    /// edge towards it, ρ off its centre. The normalisation is 1 for rough surfaces and falls
    /// for a mirror to (α / (α + sin ρ / 3))².
    func testSunDiscAreaLight() {
        let rho = 0.2666 * Double.pi / 180
        let sun = Vec3(0, 0, 1)
        let inside = Vec3(sin(rho / 2), 0, cos(rho / 2))
        XCTAssertEqual(BRDF.sunDiscDirection(sun: sun, reflection: inside, cosAngularRadius: cos(rho), sinAngularRadius: sin(rho)).dot(inside),
                       1, accuracy: 1e-12)
        let outside = Vec3(sin(0.1), 0, cos(0.1))
        let d = BRDF.sunDiscDirection(sun: sun, reflection: outside, cosAngularRadius: cos(rho), sinAngularRadius: sin(rho))
        XCTAssertEqual(acos(d.dot(sun)), rho, accuracy: 1e-9)
        XCTAssertGreaterThan(d.x, 0)
        XCTAssertEqual(BRDF.sunDiscNormalization(alpha: 1, sinAngularRadius: sin(rho)), 1)
        let a = BRDF.alpha(roughness: 0.045)
        XCTAssertEqual(BRDF.sunDiscNormalization(alpha: a, sinAngularRadius: sin(rho)),
                       pow(a / (a + sin(rho) / 3), 2), accuracy: 1e-12)
        XCTAssertLessThan(BRDF.sunDiscNormalization(alpha: a, sinAngularRadius: sin(rho)), 0.5)
    }

    /// Howell's catalogue: an element facing a sphere's centre at distance
    /// d from it sees F = (R/d)², tilted by θ (whole sphere above its
    /// horizon) F = (R/d)² cos θ; past the horizon, against a direct
    /// integration over the sphere's visible cap; nothing beyond 90° + σ.
    /// At 185 km over the Earth, as the earthshine stand-in uses it.
    func testSphereIrradianceAgainstHowell() {
        let R = 6_371_000.0, d = R + 185_000
        let s2 = (R / d) * (R / d), sigma = asin(R / d)
        XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: 1, sinSigma2: s2) / Double.pi, s2, accuracy: 1e-12)
        XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: cos(0.1), sinSigma2: s2) / Double.pi, s2 * cos(0.1),
                       accuracy: 1e-12)
        XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: cos(Double.pi / 2 + sigma + 0.01), sinSigma2: s2), 0)
        // Direct integration: ∫ cos⁺ over the sphere's cap seen from the
        // element, for tilts that cut it with the horizon.
        for theta in [Double.pi / 2 - sigma + 0.05, Double.pi / 2, Double.pi / 2 + 0.3, Double.pi / 2 + sigma - 0.05] {
            let n = Vec3(sin(theta), 0, cos(theta))
            let nt = 2_000, np = 720
            let dT = sigma / Double(nt), dP = 2 * Double.pi / Double(np)
            var sum = 0.0
            for i in 0..<nt {
                let t = (Double(i) + 0.5) * dT
                for j in 0..<np {
                    let p = (Double(j) + 0.5) * dP
                    let w = Vec3(sin(t) * cos(p), sin(t) * sin(p), cos(t))
                    sum += max(n.dot(w), 0) * sin(t)
                }
            }
            let direct = sum * dT * dP
            XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: cos(theta), sinSigma2: s2), direct,
                           accuracy: 0.01 * Double.pi * s2, "θ \(theta)")
        }
    }
    /// The whole shading path (`ShadingReference`, LightingCommon's in
    /// Swift): in a white furnace (a uniform environment, no body) a white
    /// dielectric returns the environment's radiance and a white metal at
    /// least 98 % of it at every roughness; the Sun plate, a Lambertian
    /// albedo-0.8 surface (no specular) facing the Sun, renders 0.8 E/π
    /// (design-renderer-core's look metric, ±1 %).
    func testShadingPathFurnaceAndSunPlate() {
        let n = Vec3(0, 0, 1), e = 131_000.0
        for r in stride(from: 0.05, through: 1.0, by: 0.15) {
            for nv in [0.1, 0.5, 1.0] {
                let v = Vec3((1 - nv * nv).squareRoot(), 0, nv)
                let white = ShadingReference.point(albedo: 1, metalness: 0, roughness: r, reflectance: 0.04, n: n, v: v)
                XCTAssertEqual(ShadingReference.environment(white, uniform: e), e / Double.pi,
                               accuracy: 1e-9 * e, "white paint, r \(r), n·v \(nv)")
                let metal = ShadingReference.point(albedo: 1, metalness: 1, roughness: r, reflectance: 0.04, n: n, v: v)
                let m = ShadingReference.environment(metal, uniform: e) / (e / Double.pi)
                XCTAssertGreaterThanOrEqual(m, 0.98, "white metal, r \(r), n·v \(nv)")
                XCTAssertLessThanOrEqual(m, 1.02, "white metal, r \(r), n·v \(nv)")
            }
        }
        let plate = ShadingReference.point(albedo: 0.8, metalness: 0, roughness: 0.6, reflectance: 0, n: n, v: n)
        let sun = ShadingReference.sun(plate, toSun: n, rho: 0.2666 * Double.pi / 180, e: e)
        XCTAssertEqual(sun, 0.8 * e / Double.pi, accuracy: 0.01 * 0.8 * e / Double.pi)
    }
}

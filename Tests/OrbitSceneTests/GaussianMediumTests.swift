import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// LR5's header in Swift: the Gaussian primitive's closed-form optical depth
/// against quadrature, its mass normalisation and box, and the smoke
/// scattering's two-stream against C2's, its own equations and the energy
/// it keeps.
final class GaussianMediumTests: XCTestCase {
    /// An anisotropic primitive at a slant, of 2 kg of smoke at 3 m²/g.
    func medium() -> GaussianMedium {
        let u = Vec3(1, 2, -0.5).normalized
        let v = u.cross(Vec3(0.3, -0.2, 1)).normalized
        let sigma = Vec3(30, 12, 7)
        return GaussianMedium(centre: Vec3(40, -25, 10), axisU: u, axisV: v, sigma: sigma,
                              peakExtinction: GaussianMedium.peakExtinction(mass: 2, massExtinction: 3, sigma: sigma),
                              albedo: Spectrum3(0.9, 0.85, 0.8), asymmetry: 0.6)
    }

    /// Rays through and past it, from near and from farther off.
    func rays() -> [(origin: Vec3, direction: Vec3)] {
        [(Vec3(0, 0, 0), Vec3(1, -0.6, 0.25).normalized),
         (Vec3(-200, 30, 5), Vec3(1, -0.2, 0.02).normalized),
         (Vec3(40, -25, -300), Vec3(0, 0, 1)),
         (Vec3(40, -5, -300), Vec3(0.01, 0.02, 1).normalized),
         (Vec3(100, 100, 100), Vec3(-1, -1.1, -0.8).normalized)]
    }

    /// Simpson's rule, n even.
    func simpson(_ f: (Double) -> Double, _ a: Double, _ b: Double, n: Int = 20_000) -> Double {
        let h = (b - a) / Double(n)
        var s = f(a) + f(b)
        for i in 1..<n { s += f(a + Double(i) * h) * (i % 2 == 1 ? 4 : 2) }
        return s * h / 3
    }

    /// Abramowitz and Stegun 7.1.26 keeps its stated bound, 1.5e-7, and is odd.
    func testErfApproximation() {
        var worst = 0.0
        for i in -6_000...6_000 {
            let x = Double(i) / 1_000
            worst = max(worst, abs(GaussianMedium.erf(x) - erf(x)))
            XCTAssertEqual(GaussianMedium.erf(-x), -GaussianMedium.erf(x), accuracy: 3e-9)
        }
        XCTAssertLessThan(worst, 1.5e-7)
        XCTAssertEqual(GaussianMedium.erf(1e6), 1, accuracy: 1e-7)
    }

    /// The closed-form depth over any interval of the ray, the whole line's
    /// and the box's, against Simpson's rule on the extinction itself.
    func testOpticalDepthAgainstQuadrature() {
        let g = medium()
        for (o, d) in rays() {
            let r = g.ray(origin: o, direction: d)
            let total = simpson({ g.extinction(at: o + d * $0) }, -2_000, 2_000, n: 200_000)
            XCTAssertEqual(r.total, total, accuracy: 1e-9 + 1e-7 * total, "the line through \(o)")
            for (t0, t1) in [(r.centre - 3 * r.width, r.centre), (r.centre - r.width, r.centre + 2 * r.width),
                             (0, 40), (r.centre + r.width, r.centre + 5 * r.width)] {
                let q = simpson({ g.extinction(at: o + d * $0) }, t0, t1)
                XCTAssertEqual(r.depth(from: t0, to: t1), q, accuracy: 3e-7 * max(r.total, 1e-12), "\(o) \(t0)...\(t1)")
            }
            // In the box only: the extinction cut off outside it.
            if let b = g.box(origin: o, direction: d) {
                let q = simpson({ t in
                    let l = g.local(o + d * t)
                    return max(abs(l.x), abs(l.y), abs(l.z)) <= GaussianMedium.extent ? g.extinction(at: o + d * t) : 0
                }, b.lowerBound - 1, b.upperBound + 1, n: 400_000)
                XCTAssertEqual(g.depth(origin: o, direction: d, from: -1e6, to: 1e6), q, accuracy: 1e-5 * max(q, 1e-9), "\(o) boxed")
            }
        }
    }

    /// The optical-depth-weighted mean t, against quadrature.
    func testCentroid() {
        let g = medium()
        for (o, d) in rays() {
            let r = g.ray(origin: o, direction: d)
            for (t0, t1) in [(r.centre - 2 * r.width, r.centre + 0.5 * r.width), (r.centre - 4 * r.width, r.centre + 4 * r.width)] {
                let m0 = simpson({ g.extinction(at: o + d * $0) }, t0, t1)
                guard m0 > 1e-9 else { continue }
                let m1 = simpson({ $0 * g.extinction(at: o + d * $0) }, t0, t1)
                XCTAssertEqual(r.centroid(from: t0, to: t1, depth: r.depth(from: t0, to: t1)), m1 / m0,
                               accuracy: 1e-4 * r.width, "\(o) \(t0)...\(t1)")
            }
        }
    }

    /// Extinction from mass: the extinction integrated over space is κ M,
    /// here as the whole line's depth summed over a plane of rays.
    func testMassNormalisation() {
        let g = medium()
        XCTAssertEqual(g.extinctionCrossSection, 6, accuracy: 1e-12)
        let d = Vec3(0.2, -0.3, 1).normalized
        let e1 = d.cross(Vec3(1, 0, 0)).normalized, e2 = d.cross(e1)
        var sum = 0.0
        let step = 1.0, n = 200
        for i in -n...n {
            for j in -n...n {
                let o = g.centre + e1 * (Double(i) * step) + e2 * (Double(j) * step) - d * 500
                sum += g.ray(origin: o, direction: d).total * step * step
            }
        }
        XCTAssertEqual(sum, 6, accuracy: 6e-6)
    }

    /// The box is the ray's chord through ±3σ along each axis.
    func testBox() throws {
        let g = medium()
        var hits = 0
        for (o, d) in rays() {
            guard let b = g.box(origin: o, direction: d) else {
                // A miss: no point of the ray is inside.
                for k in 0...20_000 {
                    let l = g.local(o + d * Double(k) * 0.05)
                    XCTAssertGreaterThan(max(abs(l.x), abs(l.y), abs(l.z)), GaussianMedium.extent, "\(o)")
                }
                continue
            }
            hits += 1
            for t in [b.lowerBound, b.upperBound] {
                let l = g.local(o + d * t)
                XCTAssertEqual(max(abs(l.x), abs(l.y), abs(l.z)), GaussianMedium.extent, accuracy: 1e-9)
            }
            let mid = g.local(o + d * (0.5 * (b.lowerBound + b.upperBound)))
            XCTAssertLessThan(max(abs(mid.x), abs(mid.y), abs(mid.z)), GaussianMedium.extent)
        }
        XCTAssertGreaterThanOrEqual(hits, 4)
        XCTAssertNil(g.box(origin: Vec3(0, 0, 500), direction: Vec3(1, 0, 0)), "a ray far above misses")
        // Along an axis exactly (a zero component of d in the other two).
        let axisRay = try XCTUnwrap(g.box(origin: g.centre - g.axisU * 1_000, direction: g.axisU))
        XCTAssertEqual(axisRay.upperBound - axisRay.lowerBound, 6 * g.sigma.x, accuracy: 1e-6)
        XCTAssertEqual(GaussianMedium.light(source: Spectrum3(2, 2, 2), depth: 0.5).alpha, 1 - exp(-0.5), accuracy: 1e-15)
    }

    // MARK: The two-stream

    /// At albedo 1 the streams are C2's (`CloudLighting.streams`), and the
    /// Sun's diffuse light is C2's with the Sun overhead.
    func testConservativeStreamsAreC2s() {
        for g in [0.0, 0.5, 0.85] {
            var c2 = CloudLighting()
            c2.asymmetry = g
            for tau in [0.0, 0.3, 3, 30, 300] {
                for f in [0.0, 0.1, 0.5, 0.9, 1] {
                    let t = f * tau
                    let a = SmokeScattering.streams(depth: t, column: tau, albedo: 1, asymmetry: g), b = c2.streams(depth: t, column: tau)
                    XCTAssertEqual(a.down, b.down, accuracy: 1e-12, "τ \(tau) t \(t) g \(g)")
                    XCTAssertEqual(a.up, b.up, accuracy: 1e-12, "τ \(tau) t \(t) g \(g)")
                    for mu in [-1.0, -0.3, 0.4, 1] {
                        XCTAssertEqual(SmokeScattering.sunDiffuse(sunDepth: t, sunChord: tau, cosView: -mu, albedo: 1, asymmetry: g),
                                       c2.sunDiffuse(depth: t, column: tau, sunCosine: 1, muUp: mu), accuracy: 1e-12)
                    }
                    XCTAssertEqual(SmokeScattering.ambientShare(depth: t, column: tau, albedo: 1, asymmetry: g), 1, accuracy: 1e-12)
                }
            }
        }
    }

    /// The streams solve the two-stream equations, dF↓/dt = γ2 F↑ − γ1 F↓ and
    /// dF↑/dt = γ1 F↑ − γ2 F↓, with F↓(0) = 1 and F↑(τ) = 0, on either side of
    /// the series' switch.
    func testStreamsSolveTheTwoStreamEquations() {
        for w in [0.0, 0.25, 0.7, 0.93, 0.999, 0.999_99] {
            for g in [0.0, 0.6] {
                for tau in [0.01, 1, 8, 60] {
                    let b = (1 - g) / 2, g1 = 1 - w * (1 - b), g2 = w * b
                    func s(_ t: Double) -> (down: Double, up: Double) {
                        SmokeScattering.streams(depth: t, column: tau, albedo: w, asymmetry: g)
                    }
                    XCTAssertEqual(s(0).down, 1, accuracy: 1e-12)
                    XCTAssertEqual(s(tau).up, 0, accuracy: 1e-12)
                    for f in [0.1, 0.5, 0.9] {
                        let t = f * tau, h = 1e-5 * tau
                        let dDown = (s(t + h).down - s(t - h).down) / (2 * h), dUp = (s(t + h).up - s(t - h).up) / (2 * h)
                        let here = s(t)
                        XCTAssertEqual(dDown, g2 * here.up - g1 * here.down, accuracy: 1e-6, "ω \(w) g \(g) τ \(tau) t \(t)")
                        XCTAssertEqual(dUp, g1 * here.up - g2 * here.down, accuracy: 1e-6, "ω \(w) g \(g) τ \(tau) t \(t)")
                    }
                }
            }
        }
    }

    /// What is not reflected or transmitted is absorbed: R + T +
    /// ∫ (1 − ω)(F↓ + F↑) dt = 1; a deep column reflects the semi-infinite
    /// medium's γ2/(γ1 + k); a black one passes the direct beam alone.
    func testStreamsKeepEnergy() {
        for w in [0.1, 0.5, 0.93, 0.99] {
            let g = 0.4, tau = 12.0
            let s = { (t: Double) in SmokeScattering.streams(depth: t, column: tau, albedo: w, asymmetry: g) }
            let absorbed = simpson({ (1 - w) * (s($0).down + s($0).up) }, 0, tau, n: 4_000)
            XCTAssertEqual(s(0).up + s(tau).down + absorbed, 1, accuracy: 1e-9, "ω \(w)")
            let b = (1 - g) / 2, g1 = 1 - w * (1 - b), g2 = w * b, k = (g1 * g1 - g2 * g2).squareRoot()
            XCTAssertEqual(SmokeScattering.streams(depth: 0, column: 1e4, albedo: w, asymmetry: g).up, g2 / (g1 + k), accuracy: 1e-12)
        }
        for t in [0.0, 0.5, 3] {
            let s = SmokeScattering.streams(depth: t, column: 3, albedo: 0, asymmetry: 0.5)
            XCTAssertEqual(s.down, exp(-t), accuracy: 1e-15)
            XCTAssertEqual(s.up, 0)
            XCTAssertEqual(SmokeScattering.sunDiffuse(sunDepth: t, sunChord: 3, cosView: 0.3, albedo: 0, asymmetry: 0.5), 0,
                           accuracy: 1e-15)
        }
        XCTAssertEqual(SmokeScattering.ambientShare(depth: 0, column: 2, albedo: 0, asymmetry: 0), 0.5 * (1 + exp(-2)),
                       accuracy: 1e-15)
    }

    /// The streams move smoothly through the series' switch (2kτ = 0.01 at
    /// 1 − ω = 2.5e-5 here): no step in their second differences.
    func testSeriesSwitchIsContinuous() {
        // k² = (1 − ω)(1 − ω + ω(1 − g)) = 1 − ω with g = 0.
        var s: [(down: Double, up: Double)] = []
        for i in 0...400 {
            s.append(SmokeScattering.streams(depth: 0.3, column: 1, albedo: 1 - 1e-7 * Double(i), asymmetry: 0))
        }
        for i in 2..<s.count {
            XCTAssertEqual(s[i].down - 2 * s[i - 1].down + s[i - 2].down, 0, accuracy: 1e-10, "step \(i)")
            XCTAssertEqual(s[i].up - 2 * s[i - 1].up + s[i - 2].up, 0, accuracy: 1e-10, "step \(i)")
        }
    }

    // MARK: The source

    /// In a thin smoke the source is single scattering: ω (E⊙ p + L_amb);
    /// the ambient share falls inside an absorbing column and the Sun's
    /// direct beam dims through it.
    func testSourceLimits() {
        let sun = Spectrum3(1e5, 1.1e5, 1.2e5), ambient = Spectrum3(3e3, 4e3, 6e3), albedo = Spectrum3(0.9, 0.6, 0.3)
        let thin = SmokeScattering.Light(sun: sun, ambient: ambient, cosView: 0.5, sunDepth: 0, sunChord: 0,
                                         ambientDepth: 0, ambientChord: 0)
        let j = SmokeScattering.source(albedo: albedo, asymmetry: 0.6, light: thin)
        let p = CloudPhase.henyeyGreenstein(0.5, g: 0.6)
        for (a, (s, l, w)) in zip([j.r, j.g, j.b], [(sun.r, ambient.r, albedo.r), (sun.g, ambient.g, albedo.g), (sun.b, ambient.b, albedo.b)]) {
            XCTAssertEqual(a, w * (s * p + l), accuracy: 1e-9 * a)
        }
        var deep = thin
        deep.sunDepth = 4
        deep.sunChord = 8
        deep.ambientDepth = 4
        deep.ambientChord = 8
        let k = SmokeScattering.source(albedo: albedo, asymmetry: 0.6, light: deep)
        XCTAssertLessThan(k.b, j.b * 0.2, "a sooty column's heart is dark")
        let share = SmokeScattering.ambientShare(depth: 4, column: 8, albedo: 0.3, asymmetry: 0.6)
        XCTAssertLessThan(share, 0.1, "a tenth of the ambient reaches the middle of a sooty column of depth 8")
        XCTAssertEqual(SmokeScattering.ambientShare(depth: 1, column: 8, albedo: 0.7, asymmetry: 0.6),
                       SmokeScattering.ambientShare(depth: 7, column: 8, albedo: 0.7, asymmetry: 0.6), accuracy: 1e-12,
                       "the column is fed from both sides alike")
    }
}

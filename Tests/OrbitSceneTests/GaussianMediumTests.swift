import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// LR5's header in Swift: the Gaussian primitive's closed-form optical depth
/// against quadrature, its mass normalisation and box, and the smoke
/// scattering's two-stream against C2's, its own equations and the energy
/// it keeps.
final class GaussianMediumTests: XCTestCase {
    /// Soot's mass extinction at 550 nm, m²/kg: its mass absorption
    /// cross-section, 7.5 m²/g (Bond and Bergstrom 2006), as the launch
    /// effects take it.
    static let sootMassExtinction = 7_500.0

    /// An anisotropic primitive at a slant, of 2 g of soot.
    func medium() -> GaussianMedium {
        let u = Vec3(1, 2, -0.5).normalized
        let v = u.cross(Vec3(0.3, -0.2, 1)).normalized
        let sigma = Vec3(30, 12, 7)
        let peak = GaussianMedium.peakExtinction(mass: 0.002, massExtinction: Self.sootMassExtinction, sigma: sigma)
        return GaussianMedium(centre: Vec3(40, -25, 10), axisU: u, axisV: v, sigma: sigma, peakExtinction: peak,
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

    /// The inverse of the closed-form depth: the t where the depth from t0
    /// reaches τ, to 1e-6 of the width, over the line's whole depth.
    func testTimeAtDepth() {
        let g = medium()
        for (o, d) in rays() {
            let r = g.ray(origin: o, direction: d)
            guard r.total > 1e-3 else { continue }
            let t0 = r.centre - 2.5 * r.width
            for f in [0.001, 0.1, 0.4, 0.8, 0.98] {
                let tau = f * r.depth(from: t0, to: r.centre + 6 * r.width)
                let t = r.time(atDepth: tau, from: t0)
                XCTAssertEqual(r.depth(from: t0, to: t), tau, accuracy: 1e-6 * max(tau, 1e-3), "\(o) at \(f)")
            }
            XCTAssertEqual(GaussianMedium.erfInverse(GaussianMedium.erf(0.7)), 0.7, accuracy: 1e-9)
        }
    }

    /// Extinction from mass: the extinction integrated over space is κ M,
    /// here as the whole line's depth summed over a plane of rays.
    func testMassNormalisation() {
        let g = medium()
        XCTAssertEqual(g.extinctionCrossSection, 15, accuracy: 1e-12, "κ M: 7,500 m²/kg × 2 g")
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
        XCTAssertEqual(sum, 15, accuracy: 1.5e-5)
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
                }
            }
        }
    }

    /// The streams solve the two-stream of a beam entering face-on (Meador
    /// and Weaver 1980, γ1 = D(1 − ω) + ω b, γ2 = ω b, γ3 = b):
    /// dF↑/dt = γ1 F↑ − γ2 F↓d − ω b e^(−t), dF↓d/dt = γ2 F↑ − γ1 F↓d + ω (1 − b) e^(−t),
    /// F↓d the diffuse share of F↓, with F↓(0) = 1 and F↑(τ) = 0; on either
    /// side of the series' switch and of the resonance at k = 1.
    func testStreamsSolveTheTwoStreamEquations() {
        let dd = SmokeScattering.diffusivity
        for w in [0.0, 0.25, 0.4876, 0.7, 0.93, 0.999, 0.999_99] {
            for g in [0.0, 0.35, 0.6] {
                for tau in [0.01, 1, 8, 60] {
                    let b = (1 - g) / 2, g1 = dd * (1 - w) + w * b, g2 = w * b
                    func s(_ t: Double) -> (down: Double, up: Double) {
                        let x = SmokeScattering.streams(depth: t, column: tau, albedo: w, asymmetry: g)
                        return (x.down - exp(-t), x.up)
                    }
                    XCTAssertEqual(SmokeScattering.streams(depth: 0, column: tau, albedo: w, asymmetry: g).down, 1, accuracy: 1e-12)
                    XCTAssertEqual(s(tau).up, 0, accuracy: 1e-12)
                    for f in [0.1, 0.5, 0.9] {
                        let t = f * tau, h = 1e-5 * tau
                        let dDown = (s(t + h).down - s(t - h).down) / (2 * h), dUp = (s(t + h).up - s(t - h).up) / (2 * h)
                        let x = s(t), e = exp(-t)
                        XCTAssertEqual(dDown, g2 * x.up - g1 * x.down + w * (1 - b) * e, accuracy: 1e-6, "ω \(w) g \(g) τ \(tau) t \(t)")
                        XCTAssertEqual(dUp, g1 * x.up - g2 * x.down - w * b * e, accuracy: 1e-6, "ω \(w) g \(g) τ \(tau) t \(t)")
                    }
                }
            }
        }
    }

    /// What is not reflected or transmitted is absorbed: R + T + A = 1, A the
    /// beam's (1 − ω) e^(−t) and the diffuse light's D (1 − ω)(F↓d + F↑)
    /// over the column; a deep column reflects ρ (1 + c/(k + 1)), ρ =
    /// γ2/(γ1 + k), c = (D − 1)(1 − ω); a black one passes the beam alone.
    func testStreamsKeepEnergy() {
        let dd = SmokeScattering.diffusivity
        for w in [0.1, 0.5, 0.4876, 0.93, 0.99] {
            let g = 0.4, tau = 12.0
            let s = { (t: Double) in SmokeScattering.streams(depth: t, column: tau, albedo: w, asymmetry: g) }
            let absorbed = simpson({ t in
                let x = s(t)
                return (1 - w) * exp(-t) + dd * (1 - w) * (x.down - exp(-t) + x.up)
            }, 0, tau, n: 4_000)
            XCTAssertEqual(s(0).up + s(tau).down + absorbed, 1, accuracy: 1e-9, "ω \(w)")
            let b = (1 - g) / 2, a = dd * (1 - w), g1 = a + w * b, g2 = w * b, k = (g1 * g1 - g2 * g2).squareRoot()
            let deep = g2 / (g1 + k) * (1 + (dd - 1) * (1 - w) / (k + 1))
            XCTAssertEqual(SmokeScattering.streams(depth: 0, column: 1e4, albedo: w, asymmetry: g).up, deep, accuracy: 1e-12)
        }
        for t in [0.0, 0.5, 3] {
            let s = SmokeScattering.streams(depth: t, column: 3, albedo: 0, asymmetry: 0.5)
            XCTAssertEqual(s.down, exp(-t), accuracy: 1e-15)
            XCTAssertEqual(s.up, 0)
            XCTAssertEqual(SmokeScattering.sunDiffuse(sunDepth: t, sunChord: 3, cosView: 0.3, albedo: 0, asymmetry: 0.5), 0,
                           accuracy: 1e-15)
        }
    }

    /// The streams move smoothly through the series' switch (2kτ = 0.01,
    /// near ω = 1) and through the resonance at k = 1 (near ω 0.49 for
    /// g 0.35): no step in their second differences.
    func testStreamsAreSmooth() {
        for (centre, step, range) in [(1.0, 1e-7, -400...0), (0.4876, 1e-6, -200...200)] {
            var s: [(down: Double, up: Double)] = []
            for i in range {
                let w = centre + step * Double(i)
                s.append(SmokeScattering.streams(depth: 0.3, column: 1, albedo: w, asymmetry: 0.35))
            }
            for i in 2..<s.count {
                XCTAssertEqual(s[i].down - 2 * s[i - 1].down + s[i - 2].down, 0, accuracy: 1e-10, "ω near \(centre), \(i)")
                XCTAssertEqual(s[i].up - 2 * s[i - 1].up + s[i - 2].up, 0, accuracy: 1e-10, "ω near \(centre), \(i)")
            }
        }
    }

    /// A slab lit face-on, Monte Carlo (Henyey-Greenstein, absorption by
    /// weight, 60,000 photons) against the streams: their diffuse
    /// transmission T − e^(−τ) within 8 % for P2's kerosene smoke (ω 0.58,
    /// g 0.35) and 27 % for a condensed column (ω 0.93) at τ 1, 2 and 5; the
    /// reflectance over the Monte Carlo's (C2's backscatter b = (1 − g)/2 is
    /// too large for a beam entering face-on), by under 2×.
    func testStreamsAgainstMonteCarlo() {
        var rng = SplitMix(seed: 0x5107)
        for (w, g, bound) in [(0.58, 0.35, 0.08), (0.93, 0.35, 0.27)] {
            for tau in [1.0, 2, 5] {
                let mc = monteCarloSlab(depth: tau, albedo: w, asymmetry: g, photons: 60_000, rng: &rng)
                let s = SmokeScattering.streams(depth: tau, column: tau, albedo: w, asymmetry: g)
                let r = SmokeScattering.streams(depth: 0, column: tau, albedo: w, asymmetry: g).up
                let diffuse = s.down - exp(-tau)
                print(String(format: "GaussianMediumTests: ω %.2f g %.2f τ %.0f: diffuse T %.4f (Monte Carlo %.4f), R %.4f (%.4f)",
                             w, g, tau, diffuse, mc.transmitted, r, mc.reflected))
                XCTAssertEqual(diffuse, mc.transmitted, accuracy: bound * mc.transmitted, "ω \(w) τ \(tau)")
                XCTAssertGreaterThan(r, mc.reflected)
                XCTAssertLessThan(r, 2 * mc.reflected)
            }
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    /// Photons entering a slab of depth `depth` straight down: the flux
    /// reflected, and transmitted after scattering at least once.
    func monteCarloSlab(depth tau: Double, albedo w: Double, asymmetry g: Double, photons n: Int,
                        rng: inout SplitMix) -> (reflected: Double, transmitted: Double) {
        var r = 0.0, t = 0.0
        for _ in 0..<n {
            var z = 0.0, mu = 1.0, weight = 1.0, scattered = false
            while weight > 1e-4 {
                z += mu * -log(max(rng.next(), 1e-300))
                if z >= tau { if scattered { t += weight }; break }
                if z <= 0 { r += weight; break }
                weight *= w
                scattered = true
                let s = (1 - g * g) / (1 - g + 2 * g * rng.next()), c = (1 + g * g - s * s) / (2 * g)
                let phi = 2 * Double.pi * rng.next()
                mu = mu * c + (max(0, 1 - mu * mu) * max(0, 1 - c * c)).squareRoot() * cos(phi)
            }
        }
        return (r / Double(n), t / Double(n))
    }

    // MARK: The ambient

    /// An ambient the same in every direction gives J = ω L at ω = 1, at
    /// any depth and seen from anywhere; a thin smoke scatters it with its
    /// phase (the in-scatter alone).
    func testIsotropicAndThinAmbient() {
        for tau in [0.0, 0.5, 3, 30] {
            for f in [0.0, 0.3, 1] {
                for c in [-1.0, -0.2, 0.7, 1] {
                    let a = SmokeScattering.ambientDiffuse(depth: f * tau, column: tau, cosAxis: c, albedo: 1, asymmetry: 0.85,
                                                           up: 2, down: 2, inScatter: 2)
                    XCTAssertEqual(a, 2, accuracy: 1e-12, "τ \(tau) at \(f), cos \(c)")
                }
            }
        }
        for c in [-1.0, 0, 1] {
            XCTAssertEqual(SmokeScattering.ambientDiffuse(depth: 0, column: 0, cosAxis: c, albedo: 0.6, asymmetry: 0.85,
                                                          up: 3, down: 0.5, inScatter: 7), 7, accuracy: 1e-12)
        }
    }

    /// A thick column at ω = 1 lit by a sky above (E/π of 1) and a black
    /// ground: its base and top are C2's `skyDiffuse` (π times it, per unit
    /// E/π) seen at any angle, cosAxis 1, 0.5, 0, −0.5 and −1, where the
    /// in-scatter is C2's own blend, ½ (1 + c) of the sky's (to 1e-12); with
    /// a forward-scattering in-scatter (2.4) seen straight up or down, within
    /// e^(−τ) of it; dark below, bright above, as a cloud deck.
    func testThickAmbientIsC2s() {
        var c2 = CloudLighting()
        c2.asymmetry = 0.85
        for tau in [3.0, 10, 30, 100] {
            for c in [1.0, 0.5, 0, -0.5, -1] {
                let base = SmokeScattering.ambientDiffuse(depth: tau, column: tau, cosAxis: c, albedo: 1, asymmetry: 0.85,
                                                          up: 1, down: 0, inScatter: 0.5 * (1 + c))
                let top = SmokeScattering.ambientDiffuse(depth: 0, column: tau, cosAxis: c, albedo: 1, asymmetry: 0.85,
                                                         up: 1, down: 0, inScatter: 0.5 * (1 + c))
                XCTAssertEqual(base, Double.pi * c2.skyDiffuse(column: tau, heightFraction: 0, muUp: -c), accuracy: 1e-12,
                               "τ \(tau), cos \(c): base")
                XCTAssertEqual(top, Double.pi * c2.skyDiffuse(column: tau, heightFraction: 1, muUp: -c), accuracy: 1e-12,
                               "τ \(tau), cos \(c): top")
            }
            let base = SmokeScattering.ambientDiffuse(depth: tau, column: tau, cosAxis: 1, albedo: 1, asymmetry: 0.85,
                                                      up: 1, down: 0, inScatter: 2.4)
            let top = SmokeScattering.ambientDiffuse(depth: 0, column: tau, cosAxis: -1, albedo: 1, asymmetry: 0.85,
                                                     up: 1, down: 0, inScatter: 2.4)
            let wantBase = Double.pi * c2.skyDiffuse(column: tau, heightFraction: 0, muUp: -1)
            let wantTop = Double.pi * c2.skyDiffuse(column: tau, heightFraction: 1, muUp: 1)
            XCTAssertEqual(base, wantBase, accuracy: 3 * exp(-tau) + 1e-12, "τ \(tau): base")
            XCTAssertEqual(top, wantTop, accuracy: 3 * exp(-tau) + 1e-12, "τ \(tau): top")
            let side = SmokeScattering.ambientDiffuse(depth: tau, column: tau, cosAxis: 0, albedo: 1, asymmetry: 0.85,
                                                      up: 1, down: 0, inScatter: 0.9)
            print(String(format: "GaussianMediumTests: a sky-lit column of τ %.0f: base %.3f (C2 %.3f), top %.3f (C2 %.3f), base side-on %.3f",
                         tau, base, wantBase, top, wantTop, side))
            if tau >= 30 { XCTAssertLessThan(base, top, "dark below, bright above") }
            XCTAssertLessThan(side, Double.pi * c2.skyDiffuse(column: tau, heightFraction: 0, muUp: 0) + 0.9 * exp(-tau) + 1e-12,
                              "side-on, the base no brighter than C2's but for its in-scatter through e^(−τ)")
        }
    }

    /// A body elongated along the ambient's axis (a climbing trail) takes
    /// its skylight through its sides: `ambientColumn` caps the chord along
    /// the axis by the chord across it, so a condensed node's side seen
    /// side-on is lit as the column across it would light it (along its
    /// 10:1 length it would be dark).
    func testElongatedBodyTakesSkylightThroughItsSides() {
        let m = GaussianMedium(centre: .zero, axisU: .unitZ, axisV: .unitX, sigma: Vec3(100, 10, 10), peakExtinction: 0.12)
        let column = m.ambientColumn(at: .zero, axis: .unitZ)
        let across = m.ray(origin: .zero, direction: .unitX).total, along = m.ray(origin: .zero, direction: .unitZ).total
        XCTAssertEqual(column.chord, across, accuracy: 1e-9 * across)
        XCTAssertEqual(column.depth, 0.5 * across, accuracy: 1e-6 * across)
        XCTAssertEqual(along / across, 10, accuracy: 1e-9)
        func j(_ depth: Double, _ chord: Double) -> Double {
            SmokeScattering.ambientDiffuse(depth: depth, column: chord, cosAxis: 0, albedo: 0.93, asymmetry: 0.85, up: 1,
                                           down: 0.2, inScatter: 0.6)
        }
        let capped = j(column.depth, column.chord), lengthwise = j(0.5 * along, along)
        print(String(format: "GaussianMediumTests: an elongated node's side: J %.3f through its sides, %.3f through its length",
                     capped, lengthwise))
        XCTAssertGreaterThan(capped, 3 * lengthwise)
        // A round body keeps its own chord.
        let round = GaussianMedium(centre: .zero, axisU: .unitZ, axisV: .unitX, sigma: Vec3(10, 10, 10), peakExtinction: 0.12)
        XCTAssertEqual(round.ambientColumn(at: .zero, axis: .unitZ).chord, round.ray(origin: .zero, direction: .unitZ).total,
                       accuracy: 1e-12)
    }

    /// The ambient from R3's SH9 of a sky (brighter overhead): its axis is
    /// up, E/π along it more than against it; without a probe, the stand-in.
    func testAmbientFromSH9() {
        let sh = SH9.project(size: 16) { d in Spectrum3(repeating: 200) + Spectrum3(800, 900, 1_300) * max(d.z, 0) }
        let a = SmokeScattering.ambient(sh, view: Vec3(1, 0, 0), asymmetry: 0.6, standIn: .zero)
        XCTAssertGreaterThan(a.axis.z, 0.999)
        XCTAssertGreaterThan(a.up.g, 2 * a.down.g)
        XCTAssertEqual(a.inScatter, sh.inScatter(view: Vec3(1, 0, 0), asymmetry: 0.6))
        let none = SmokeScattering.ambient(nil, view: .unitX, asymmetry: 0.6, standIn: Spectrum3(1, 2, 3))
        XCTAssertEqual(none.up, Spectrum3(1, 2, 3))
        XCTAssertEqual(none.down, Spectrum3(1, 2, 3))
    }

    // MARK: The source

    /// A primitive's chord shaded in `segments` (0.25 deep from the entry,
    /// the last taking the rest past 16), each at its `shadingTime`, against
    /// the radiance's quadrature ∫ J σ e^(−τ) dt, condensed and sooty, for
    /// line depths 2 to 100:
    /// - lit from the front (the Sun behind the camera): within 0.5 %;
    /// - lit from the side (cosView 0; the Sun's chord the line across the
    ///   primitive through the point, the point halfway into it): within 2 %;
    /// - lit from the back: within 1.5 % (condensed, at any depth; sooty, to
    ///   depth 5). Thicker sooty smoke lit from behind sends only T e^(−T) of
    ///   its source's light (under 5e-4 past depth 10), every depth alike,
    ///   which the last segment's one source cannot hold: there the error is
    ///   under 1e-3 of its brightest source's.
    /// (One source at the σ-weighted mean was off by 35 % to 2.4× at depth 5.)
    func testSegmentsAgainstQuadrature() {
        let sun = Spectrum3(repeating: 1e5)
        for (albedo, g) in [(0.93, 0.85), (0.3, 0.6)] {
            for depth in [2.0, 5, 10, 30, 100] {
                let w = 10.0, r = GaussianMedium.Ray(centre: 0, width: w, peak: depth / (w * (2 * Double.pi).squareRoot()))
                let t0 = -5 * w, t1 = 5 * w, total = r.depth(from: t0, to: t1)
                for lighting in ["front", "back", "side"] {
                    var brightest = 0.0
                    func j(_ t: Double) -> Double {
                        // A round primitive: across it through the point the
                        // line's depth is σ(t) w √(2π).
                        let sigma = r.peak * exp(-0.5 * t * t / (w * w)), acrossDepth = sigma * w * (2 * Double.pi).squareRoot()
                        let sunDepth: Double, chord: Double, cosView: Double
                        switch lighting {
                        case "front": (sunDepth, chord, cosView) = (r.depth(from: t0, to: t), total, -1)
                        case "back": (sunDepth, chord, cosView) = (r.depth(from: t, to: t1), total, 1)
                        default: (sunDepth, chord, cosView) = (0.5 * acrossDepth, acrossDepth, 0)
                        }
                        let l = SmokeScattering.Light(sun: sun, ambient: .zero, ambientUp: .zero, ambientDown: .zero,
                                                      cosView: cosView, cosAxis: 0, sunDepth: sunDepth, sunChord: chord,
                                                      ambientDepth: 0, ambientChord: 0)
                        let v = SmokeScattering.source(albedo: Spectrum3(repeating: albedo), asymmetry: g, light: l).g
                        brightest = max(brightest, v)
                        return v
                    }
                    let exact = simpson({ t in j(t) * r.peak * exp(-0.5 * t * t / (w * w)) * exp(-r.depth(from: t0, to: t)) },
                                        t0, t1, n: 80_000)
                    let n = GaussianMedium.segments(depth: total)
                    var radiance = 0.0, transmittance = 1.0, a = t0
                    for k in 1...n {
                        let b = k == n ? t1 : r.time(atDepth: GaussianMedium.segmentBoundary(k, of: n, depth: total), from: t0)
                        let d = r.depth(from: a, to: b)
                        radiance += transmittance * j(r.shadingTime(from: a, to: b)) * (1 - exp(-d))
                        transmittance *= exp(-d)
                        a = b
                    }
                    print(String(format: "GaussianMediumTests: ω %.2f depth %3.0f %@-lit, %2d segments: %.4f of the quadrature (%.1e of its brightest source)",
                                 albedo, depth, lighting, n, radiance / exact, abs(radiance - exact) / brightest))
                    switch lighting {
                    case "front": XCTAssertEqual(radiance, exact, accuracy: 0.005 * exact, "ω \(albedo), depth \(depth), front-lit")
                    case "side": XCTAssertEqual(radiance, exact, accuracy: 0.02 * exact, "ω \(albedo), depth \(depth), side-lit")
                    default:
                        if albedo > 0.5 || depth <= 5 {
                            XCTAssertEqual(radiance, exact, accuracy: 0.015 * exact, "ω \(albedo), depth \(depth), back-lit")
                        } else {
                            XCTAssertLessThan(abs(radiance - exact), 1e-3 * brightest, "ω \(albedo), depth \(depth), back-lit")
                        }
                    }
                }
            }
        }
    }

    /// The shading depth's series below depth 0.05 meets the logarithms'
    /// mean there to O(T⁶).
    func testShadingSeriesMeetsTheLogarithms() {
        let d = 0.05
        let logs = 0.5 * (-log(0.5 * (1 + exp(-d))) + log(d / (1 - exp(-d))))
        XCTAssertEqual(d * (0.5 - d * (1.0 / 12.0 - d * d / 360.0)), logs, accuracy: 1e-10)
        let r = GaussianMedium.Ray(centre: 0, width: 10, peak: 1e-3)
        let t = r.shadingTime(from: -1, to: 1), dd = r.depth(from: -1, to: 1)
        XCTAssertEqual(r.depth(from: -1, to: t), dd * (0.5 - dd * (1.0 / 12.0 - dd * dd / 360.0)), accuracy: 1e-6 * dd)
    }

    /// In a thin smoke the source is single scattering: ω (E⊙ p + L_amb);
    /// a sooty column's heart is dark.
    func testSourceLimits() {
        let sun = Spectrum3(1e5, 1.1e5, 1.2e5), ambient = Spectrum3(3e3, 4e3, 6e3), albedo = Spectrum3(0.9, 0.6, 0.3)
        let thin = SmokeScattering.Light(sun: sun, ambient: ambient, ambientUp: ambient * 0.8, ambientDown: ambient * 0.3,
                                         cosView: 0.5, cosAxis: 0.2, sunDepth: 0, sunChord: 0, ambientDepth: 0, ambientChord: 0)
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
        XCTAssertLessThan(k.b, j.b * 0.1, "a sooty column's heart is dark")
    }
}

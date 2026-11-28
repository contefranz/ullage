import Foundation
import OrbitCore

// Look round 2, track LR5's header: the smoke the trail (LR5), the launch
// cloud (LR4) and the plumes' far field (LR3) share. Two parts:
// - `GaussianMedium`: a smoke primitive whose extinction is a 3-D Gaussian,
//   and its optical depth along a ray in closed form (Condor et al. 2025,
//   "Don't Splat your Gaussians"), truncated to its 3σ box;
// - `SmokeScattering`: the one way smoke scatters light, the Sun's and the
//   ambient's: Henyey-Greenstein single scattering, C2's two-stream with
//   absorption for the light scattered many times, and R3's SH9 for the
//   ambient.
//
// The shader header GaussianMediumCommon (OrbitRender) mirrors every
// function here line for line, in Float; OrbitRenderTests checks the GPU's
// results against these.

/// A smoke primitive: extinction σ(p) = σ0 exp(−½ (p − c)ᵀ Σ⁻¹ (p − c)),
/// a Gaussian of standard deviations `sigma` along the orthonormal axes u,
/// v and u × v, cut off at `extent` σ along each (its box). One albedo and
/// one asymmetry for the whole primitive.
public struct GaussianMedium: Equatable {
    /// Its centre, m (in whatever frame the caller works in; the shader's is
    /// camera-relative).
    public var centre: Vec3
    /// Two of its principal axes, unit and orthogonal; the third is u × v.
    public var axisU: Vec3
    public var axisV: Vec3
    /// Its standard deviations along u, v and u × v, m.
    public var sigma: Vec3
    /// σ0, the extinction at the centre, 1/m.
    public var peakExtinction: Double
    /// The single-scattering albedo per channel.
    public var albedo: Spectrum3
    /// The mean cosine of its scattering (`SmokeScattering`'s g).
    public var asymmetry: Double

    public init(centre: Vec3, axisU: Vec3, axisV: Vec3, sigma: Vec3, peakExtinction: Double,
                albedo: Spectrum3 = .one, asymmetry: Double = 0) {
        self.centre = centre
        self.axisU = axisU
        self.axisV = axisV
        self.sigma = sigma
        self.peakExtinction = peakExtinction
        self.albedo = albedo
        self.asymmetry = asymmetry
    }

    /// The truncation: the primitive ends at 3σ along each axis, its box
    /// holding erf(3/√2)³ = 99.19 % of its optical mass.
    public static let extent = 3.0

    /// The third axis, u × v.
    public var axisW: Vec3 { axisU.cross(axisV) }

    /// σ0 of a primitive holding `mass` (kg) of a smoke whose mass
    /// extinction coefficient is `massExtinction` (m²/kg): the integral of
    /// σ over space is κ M, so σ0 = κ M / ((2π)^(3/2) σu σv σw).
    public static func peakExtinction(mass: Double, massExtinction: Double, sigma s: Vec3) -> Double {
        massExtinction * mass / (pow(2 * Double.pi, 1.5) * s.x * s.y * s.z)
    }

    /// The integral of σ over space, m² (κ M): σ0 (2π)^(3/2) σu σv σw.
    public var extinctionCrossSection: Double { peakExtinction * pow(2 * Double.pi, 1.5) * sigma.x * sigma.y * sigma.z }

    /// The point in the primitive's axes (in σ), from `p`.
    func local(_ p: Vec3) -> Vec3 {
        let x = p - centre
        return Vec3(x.dot(axisU) / sigma.x, x.dot(axisV) / sigma.y, x.dot(axisW) / sigma.z)
    }

    /// σ at `p`, 1/m, untruncated.
    public func extinction(at p: Vec3) -> Double {
        peakExtinction * exp(-0.5 * local(p).lengthSquared)
    }

    /// Along a ray o + t d (d unit, t in m) σ is itself a Gaussian in t:
    /// σ(t) = peak · exp(−(t − centre)² / (2 width²)).
    public struct Ray: Equatable {
        /// The t of the ray's nearest approach in the primitive's metric, m.
        public var centre: Double
        /// The 1-D standard deviation along the ray, m.
        public var width: Double
        /// The extinction there, 1/m.
        public var peak: Double

        /// The optical depth from t0 to t1 (t0 ≤ t1):
        /// peak · width · √(π/2) · (erf((t1 − c)/(√2 w)) − erf((t0 − c)/(√2 w))),
        /// with `GaussianMedium.erf`, the shader's approximation.
        public func depth(from t0: Double, to t1: Double) -> Double {
            let k = 1 / (2.0.squareRoot() * width)
            let a = GaussianMedium.erf((t0 - centre) * k), b = GaussianMedium.erf((t1 - centre) * k)
            return max(peak * width * (0.5 * Double.pi).squareRoot() * (b - a), 0)
        }

        /// The optical depth along the whole line: peak · width · √(2π).
        public var total: Double { peak * width * (2 * Double.pi).squareRoot() }

        /// The t past t0 where the depth from t0 reaches `tau` (inverting
        /// `depth`): c + erf⁻¹(erf((t0 − c)k) + τ / P) / k, k = 1/(√2 w),
        /// P = peak w √(π/2); erf⁻¹ by Giles (2010, single precision) and
        /// two Newton steps on `GaussianMedium.erf`, as the shader has it.
        /// Past the line's whole depth, far along it.
        public func time(atDepth tau: Double, from t0: Double) -> Double {
            let k = 1 / (2.0.squareRoot() * width), p = peak * width * (0.5 * Double.pi).squareRoot()
            guard p > 0 else { return t0 }
            let e = min(max(GaussianMedium.erf((t0 - centre) * k) + max(tau, 0) / p, -1 + 1e-6), 1 - 1e-6)
            return centre + GaussianMedium.erfInverse(e) / k
        }

        /// Where a segment t0...t1 is shaded with one source: at the depth
        /// from t0 midway between the one exact for light falling as e^(−τ)
        /// from its entry (a front-lit primitive), −ln((1 + e^(−T))/2), and
        /// the one exact for light rising as e^(τ) (back-lit), ln(T/(1 −
        /// e^(−T))) (T its depth): within 0.3 % for either on segments of
        /// depth 0.25 (`segments`). Below depth 0.05 their mean's series,
        /// T/2 − T²/12 + T⁴/360 (the logarithms cancel in Float there).
        public func shadingTime(from t0: Double, to t1: Double) -> Double {
            let d = depth(from: t0, to: t1)
            guard d > 1e-9 else { return min(max(centre, t0), t1) }
            return min(max(time(atDepth: Ray.shadingDepth(d), from: t0), t0), t1)
        }

        /// The depth into a segment of depth `d` its one source sits at
        /// (`shadingTime`'s): for a caller that walks the segments by their
        /// depths and so knows each one's.
        public static func shadingDepth(_ d: Double) -> Double {
            guard d > 1e-9 else { return 0 }
            return d < 0.05 ? d * (0.5 - d * (1.0 / 12.0 - d * d / 360.0))
                : 0.5 * (-log(0.5 * (1 + exp(-d))) + log(d / (1 - exp(-d))))
        }
    }

    /// A primitive's chord is shaded in `segments(depth:)` segments, each
    /// with one source at its `shadingTime`: `segmentDepth` deep from the
    /// entry (`segmentBoundary`), at most `maxSegments`. Past depth 3.75 the
    /// first `maxSegments − evenSegments` stay 0.25 deep and the last
    /// `evenSegments` split the rest evenly: lit from behind, light leaves
    /// every depth about alike, so one thick last segment would carry most
    /// of it on one source.
    public static let segmentDepth = 0.25
    public static let maxSegments = 16
    public static let evenSegments = 4
    public static func segments(depth: Double) -> Int {
        min(max(Int((max(depth, 0) / segmentDepth).rounded(.up)), 1), maxSegments)
    }

    /// The depth from the chord's entry of segment boundary `k` of `n`
    /// (0 the entry, n the exit): k × `segmentDepth`, the exit's for the
    /// last; with `maxSegments`, past the first `maxSegments − evenSegments`
    /// the rest in equal parts.
    public static func segmentBoundary(_ k: Int, of n: Int, depth: Double) -> Double {
        if k >= n { return depth }
        let fixed = n >= maxSegments ? n - evenSegments : n
        if k <= fixed { return min(Double(k) * segmentDepth, depth) }
        let start = min(Double(fixed) * segmentDepth, depth)
        return start + (depth - start) * Double(k - fixed) / Double(n - fixed)
    }

    /// The column the ambient lights a point `p` through, along its axis
    /// (unit `axis`, towards its up side): the depth from `p` to the up
    /// side and the whole chord along the axis through `p`, both scaled by
    /// the body's own aspect along the axis, min(σ) over the line's width
    /// (its σ along the axis), where that is under 1. So an elongated body
    /// along the axis (the trail climbing) takes its skylight through its
    /// sides, not its length (on its centre line, the chord across it), and
    /// the scale depends on the body's shape alone: not on `p`, nor on which
    /// of equal axes is labelled first.
    public func ambientColumn(at p: Vec3, axis: Vec3) -> (depth: Double, chord: Double) {
        let r = ray(origin: p, direction: axis), chord = r.total
        guard chord > 1e-12 else { return (0, 0) }
        let up = r.depth(from: 0, to: r.centre + 10 * r.width + abs(r.centre))
        let scale = min(1, min(sigma.x, sigma.y, sigma.z) / r.width)
        return (up * scale, chord * scale)
    }

    /// The Gaussian along the ray from `origin` in the unit `direction`:
    /// with x = o − c in σ (`local`) and d' likewise, a = |d'|², b = x·d',
    /// the nearest approach is at −b/a, the width 1/√a and the peak
    /// σ0 exp(−½ |x − (b/a) d'|²). For the shader's precision `origin`
    /// should be near the primitive (its box's entry, say).
    public func ray(origin o: Vec3, direction d: Vec3) -> Ray {
        let x = local(o)
        let dl = Vec3(d.dot(axisU) / sigma.x, d.dot(axisV) / sigma.y, d.dot(axisW) / sigma.z)
        let a = max(dl.lengthSquared, 1e-30), b = x.dot(dl)
        let miss = x - dl * (b / a)
        return Ray(centre: -b / a, width: 1 / a.squareRoot(), peak: peakExtinction * exp(-0.5 * miss.lengthSquared))
    }

    /// Where the ray from `origin` in the unit `direction` is inside the
    /// box (±`extent` σ along each axis), as t0...t1 (m along the ray), or
    /// nil where it misses (t may be negative: behind the origin).
    public func box(origin o: Vec3, direction d: Vec3) -> ClosedRange<Double>? {
        let x = o - centre, axes = [axisU, axisV, axisW], s = [sigma.x, sigma.y, sigma.z]
        var t0 = -Double.greatestFiniteMagnitude, t1 = Double.greatestFiniteMagnitude
        for i in 0..<3 {
            let xi = x.dot(axes[i]), di = d.dot(axes[i]), h = Self.extent * s[i]
            let dd = abs(di) < 1e-12 ? (di < 0 ? -1e-12 : 1e-12) : di
            let a = (-h - xi) / dd, b = (h - xi) / dd
            t0 = max(t0, min(a, b))
            t1 = min(t1, max(a, b))
        }
        return t0 < t1 ? t0...t1 : nil
    }

    /// The optical depth along the ray from `origin` in the unit
    /// `direction` between t0 and t1, within the box only.
    public func depth(origin o: Vec3, direction d: Vec3, from t0: Double, to t1: Double) -> Double {
        guard let b = box(origin: o, direction: d) else { return 0 }
        let lo = max(t0, b.lowerBound), hi = min(t1, b.upperBound)
        return hi > lo ? ray(origin: o, direction: d).depth(from: lo, to: hi) : 0
    }

    /// A primitive's light over a segment of optical depth `depth` whose
    /// source is `source` (one J per primitive): premultiplied,
    /// (J (1 − e^(−τ)), 1 − e^(−τ)), composited over what lies behind it.
    public static func light(source: Spectrum3, depth: Double) -> (radiance: Spectrum3, alpha: Double) {
        let a = 1 - exp(-depth)
        return (source * a, a)
    }

    /// The inverse error function as the shader has it: Giles's single-
    /// precision approximation ("Approximating the erfinv function", GPU
    /// Computing Gems Jade, 2011), then two Newton steps on `erf`.
    public static func erfInverse(_ x: Double) -> Double {
        let x = min(max(x, -1 + 1e-7), 1 - 1e-7)
        var w = -log((1 - x) * (1 + x)), p: Double
        if w < 5 {
            w -= 2.5
            p = 2.81022636e-08
            for c in [3.43273939e-07, -3.5233877e-06, -4.39150654e-06, 0.00021858087, -0.00125372503, -0.00417768164,
                      0.246640727, 1.50140941] { p = c + p * w }
        } else {
            w = w.squareRoot() - 3
            p = -0.000200214257
            for c in [0.000100950558, 0.00134934322, -0.00367342844, 0.00573950773, -0.0076224613, 0.00943887047,
                      1.00167406, 2.83297682] { p = c + p * w }
        }
        var y = p * x
        for _ in 0..<2 { y -= (erf(y) - x) / (1.128_379_167 * exp(-y * y)) }
        return y
    }

    /// The error function as the shader has it (MSL has none): Abramowitz
    /// and Stegun 7.1.26, |error| ≤ 1.5e-7, odd.
    public static func erf(_ x: Double) -> Double {
        let z = min(abs(x), 9), t = 1 / (1 + 0.327_591_1 * z)
        let poly = t * (0.254_829_592 + t * (-0.284_496_736 + t * (1.421_413_741 + t * (-1.453_152_027 + t * 1.061_405_429))))
        let y = 1 - poly * exp(-z * z)
        return x < 0 ? -y : y
    }
}

/// How smoke scatters light: the source function J (cd/m², per unit
/// extinction, so dL/ds = σ (J − L)) at a point of a smoke of
/// single-scattering albedo ω and asymmetry g. One g for every part, and
/// C2's two-stream (`CloudLighting.streams`: Bohren 1987's, backscattered
/// fraction b = (1 − g)/2), here with absorption (`streams`), for all the
/// light scattered many times:
/// - **the Sun:** its beam enters the chord towards it face-on; the
///   streams there, seen in the eye's direction as C2 sees its own (each
///   F/π over its hemisphere, blended by the direction), with the direct
///   beam's share swapped for its single scattering, E⊙ p(cos θ) e^(−τ⊙)
///   (Henyey and Greenstein);
/// - **the ambient:** R3's SH9 as two fluxes along its dominant axis, E(n)/π
///   facing each way, each entering the chord along the axis from its own
///   side as a beam does (a sky lights a column from above, the ground from
///   below, as C2's `skyDiffuse` lights its decks), seen the same way, with each side's
///   unscattered share swapped for SH9's in-scatter by the same phase
///   (`SH9.inScatter`, Funk and Hecke) carried through to the point.
///
/// So at ω = 1 an isotropic ambient gives J = L at any depth, a thick
/// column's skylit base and top are C2's, and a thin smoke scatters the
/// Sun and the sky with its phase, as P2's smoke does today.
///
/// The streams' absorption has Elsasser's diffusivity 5/3 (the mean slant
/// of a diffuse field's path), their scattering C2's unit one, so at ω = 1
/// they are C2's. Against a Monte Carlo slab lit face-on, they hold the
/// diffuse transmission of P2's kerosene smoke (ω 0.58, g 0.35) within 5 %
/// at τ 1 to 5 (unit diffusivity: 18 % to 150 % over), and of a condensed
/// column (ω 0.93) within 26 %; the reflectance up to 41 % high where the
/// smoke is absorbing, C2's backscatter b = (1 − g)/2 being too large for
/// a beam entering face-on (`GaussianMediumTests.testStreamsAgainstMonteCarlo`).
public enum SmokeScattering {
    /// The two-stream backscattered fraction, (1 − g)/2, as C2's.
    public static func backscatter(asymmetry g: Double) -> Double { (1 - g) / 2 }

    /// The diffusivity of the streams' absorption: Elsasser's (1942) 5/3,
    /// the mean slant of a diffuse field's path. On absorption only, so that
    /// at ω = 1 the streams stay C2's (Bohren's unit diffusivity, which C1's
    /// slab calibrates).
    public static let diffusivity = 5.0 / 3.0

    /// The two-stream of a beam entering the top of a column of optical
    /// depth τ face-on, per unit flux, and nothing its bottom: the downward
    /// flux (the direct beam e^(−t) and the diffuse) and the upward flux at
    /// optical depth t, for albedo ω and asymmetry g. Meador and Weaver
    /// (1980) with γ1 = D(1 − ω) + ω b, γ2 = ω b, γ3 = b (b = (1 − g)/2, D
    /// the `diffusivity`), k = √(γ1² − γ2²):
    ///   dF↑/dt = γ1 F↑ − γ2 F↓d − ω b e^(−t),  dF↓d/dt = γ2 F↑ − γ1 F↓d + ω (1 − b) e^(−t).
    /// Its total F↓ = F↓d + e^(−t) obeys the diffuse-incidence two-stream
    /// with the source c e^(−t), c = (D − 1)(1 − ω): so the solution is
    /// that one's, with u = τ − t and E(x) = (1 − e^(−2kx))/k,
    ///   H↓ = e^(−kt) (1 + e^(−2ku) + γ1 E(u)) / (1 + e^(−2kτ) + γ1 E(τ)),
    ///   H↑ = e^(−kt) γ2 E(u) / (1 + e^(−2kτ) + γ1 E(τ)),
    /// plus the source's, written so that its resonance at k = 1 (near
    /// ω 0.49 for kerosene smoke, g 0.35) cancels: with ρ = γ2/(γ1 + k), e1(x) =
    /// (e^(−x) − e^(−kx))/(k − 1), q = c (γ2 e1(τ) + ρ e^(−kτ))/(k + 1),
    /// a = ρ e^(−kτ) q / (1 − ρ² e^(−2kτ)) and β = −q − a ρ e^(−kτ),
    ///   F↓ += c (γ1 + 1) e1(t)/(k + 1) + a e^(−kt) + β ρ e^(−k(τ − t)),
    ///   F↑ += c (γ2 e1(t) + ρ e^(−kt))/(k + 1) + a ρ e^(−kt) + β e^(−k(τ − t)).
    /// At ω = 1 (c = 0, k = 0, E(x) = 2x) these are C2's 1 − bt/(1 + bτ) and
    /// b(τ − t)/(1 + bτ); at ω = 0 the direct beam e^(−t) and nothing up.
    public static func streams(depth t: Double, column tau: Double, albedo w: Double, asymmetry g: Double)
        -> (down: Double, up: Double) {
        let tau = max(tau, 0), t = min(max(t, 0), tau), u = tau - t
        let b = backscatter(asymmetry: g), w = min(max(w, 0), 1), a = diffusivity * (1 - w)
        let g1 = a + w * b, g2 = w * b
        let k = (a * (a + 2 * w * b)).squareRoot()
        // (1 − e^(−y))/y, its series where |y| < 1e-2.
        func phi(_ y: Double) -> Double {
            abs(y) < 1e-2 ? 1 - y * (0.5 - y * (1.0 / 6.0 - y * (1.0 / 24.0 - y / 120.0))) : (1 - exp(-y)) / y
        }
        // E(x) = (1 − e^(−2kx))/k = 2x φ(2kx).
        func e(_ x: Double) -> Double { 2 * x * phi(2 * k * x) }
        let den = 1 + exp(-2 * k * tau) + g1 * e(tau), down0 = exp(-k * t)
        var down = down0 * (1 + exp(-2 * k * u) + g1 * e(u)) / den, up = down0 * g2 * e(u) / den
        // The beam's share past unit diffusivity.
        let c = (diffusivity - 1) * (1 - w)
        guard c > 0 else { return (down, up) }
        // e1(x) = e^(−x) x φ((k − 1) x).
        func e1(_ x: Double) -> Double {
            abs((k - 1) * x) < 1e-2 ? exp(-x) * x * phi((k - 1) * x) : (exp(-x) - exp(-k * x)) / (k - 1)
        }
        let rho = g2 / (g1 + k), ek = exp(-k * tau)
        // 1 − ρ² e^(−2kτ) = (1 − ρ e^(−kτ))(1 + ρ e^(−kτ)), 1 − ρ = (a + k)/(γ1 + k).
        let near = (a + k) / (g1 + k) + rho * k * tau * phi(k * tau)
        let q = c * (g2 * e1(tau) + rho * ek) / (k + 1)
        let aa = rho * ek * q / (near * (1 + rho * ek)), beta = -q - aa * rho * ek
        let ekt = exp(-k * t), eku = exp(-k * u)
        down += c * (g1 + 1) * e1(t) / (k + 1) + aa * ekt + beta * rho * eku
        up += c * (g2 * e1(t) + rho * ekt) / (k + 1) + aa * rho * ekt + beta * eku
        return (down, max(up, 0))
    }

    /// The radiance of the two streams going in a direction whose cosine
    /// with the column's top normal is `muUp` (the light's travel, towards
    /// an eye above the top positive), per unit flux: each stream F/π over
    /// its hemisphere, blended by the direction (`CloudLighting.streamRadiance`).
    public static func streamRadiance(down: Double, up: Double, muUp: Double) -> Double {
        let w = 0.5 * (1 + min(max(muUp, -1), 1))
        return (w * up + (1 - w) * down) / .pi
    }

    /// The Sun's light scattered many times at the point, per unit solar
    /// irradiance (1/sr): the two-stream of its chord towards the Sun, lit
    /// face-on at its sunward end, the point `sunDepth` into it, less the
    /// direct beam (`single`'s), seen with `cosView` the cosine between the
    /// view ray (camera to point) and the direction to the Sun.
    public static func sunDiffuse(sunDepth t: Double, sunChord tau: Double, cosView: Double, albedo w: Double,
                                  asymmetry g: Double) -> Double {
        let s = streams(depth: t, column: max(tau, t), albedo: w, asymmetry: g)
        return streamRadiance(down: max(s.down - exp(-t), 0), up: s.up, muUp: -cosView)
    }

    /// The ambient's light scattered towards the eye per unit albedo, cd/m²,
    /// per channel: the two fluxes along the axis, E/π `up` (from the
    /// side the axis points to) and `down`, through the chord along the
    /// axis (the point `depth` from the up side, `column` in all), seen at
    /// `cosAxis` (the view ray, camera to point, on the axis); the
    /// unscattered light the streams show, up ½ (1 + c) e^(−t) + down ½ (1 − c)
    /// e^(−(τ − t)), swapped for `inScatter` shared between the sides in the
    /// same proportion, each carried through from its own side (the plain
    /// mean of the two where neither side has light).
    public static func ambientDiffuse(depth t: Double, column tau: Double, cosAxis c: Double, albedo w: Double,
                                      asymmetry g: Double, up: Double, down: Double, inScatter: Double) -> Double {
        let tau = max(tau, 0), t = min(max(t, 0), tau), c = min(max(c, -1), 1)
        let a = streams(depth: t, column: tau, albedo: w, asymmetry: g)
        let b = streams(depth: tau - t, column: tau, albedo: w, asymmetry: g)
        let fromUp = exp(-t), fromDown = exp(-(tau - t))
        // The up side's streams: its "up" runs along the axis, so light
        // reaching the eye runs at −cosAxis to it; the down side's at +.
        let sideUp = Double.pi * streamRadiance(down: a.down - fromUp, up: a.up, muUp: -c)
        let sideDown = Double.pi * streamRadiance(down: b.down - fromDown, up: b.up, muUp: c)
        let wu = up * 0.5 * (1 + c), wd = down * 0.5 * (1 - c)
        let unscattered = wu + wd > 1e-30 ? (wu * fromUp + wd * fromDown) / (wu + wd)
            : 0.5 * (1 + c) * fromUp + 0.5 * (1 - c) * fromDown
        return up * sideUp + down * sideDown + inScatter * unscattered
    }

    /// The ambient as the smoke takes it from R3's SH9 (`sh`, the probe's
    /// radiance): its in-scatter by the smoke's phase along the unit view
    /// ray `view` (camera to point), and its dominant axis (the first band's
    /// luminance, towards the light; +z where it has none) with E/π facing
    /// along it and against it. Without a probe, the stand-in in every
    /// direction (an isotropic ambient, any axis).
    public static func ambient(_ sh: SH9?, view: Vec3, asymmetry g: Double, standIn: Spectrum3)
        -> (inScatter: Spectrum3, up: Spectrum3, down: Spectrum3, axis: Vec3) {
        guard let sh else { return (standIn, standIn, standIn, .unitZ) }
        let c = sh.irradianceOverPi
        func lum(_ x: Spectrum3) -> Double { 0.2126 * x.r + 0.7152 * x.g + 0.0722 * x.b }
        let dipole = Vec3(lum(c[3]), lum(c[1]), lum(c[2]))
        let axis = dipole.length > 1e-6 * max(abs(lum(c[0])), 1e-30) ? dipole.normalized : .unitZ
        return (sh.inScatter(view: view, asymmetry: g), sh.irradianceOverPi(axis), sh.irradianceOverPi(-axis), axis)
    }

    /// What the caller knows of the light at the point.
    public struct Light: Equatable {
        /// The Sun's illuminance on the smoke from outside it, lux: after
        /// the air, the planet's and the vessel's shadows, the clouds.
        public var sun: Spectrum3
        /// The ambient (`ambient`): its in-scatter by the smoke's phase,
        /// cd/m², and E/π along its axis and against it.
        public var ambient: Spectrum3
        public var ambientUp: Spectrum3
        public var ambientDown: Spectrum3
        /// The cosines of the view ray (camera to point) with the direction
        /// to the Sun (1 is looking at the Sun through the smoke) and with
        /// the ambient's axis.
        public var cosView: Double
        public var cosAxis: Double
        /// The smoke's optical depth from the point to the Sun, and its
        /// whole optical depth along that line through the point.
        public var sunDepth: Double
        public var sunChord: Double
        /// The smoke's optical depth from the point along the ambient's axis
        /// (towards its up side), and its whole depth along that line, no
        /// more than the column across the body there
        /// (`GaussianMedium.ambientColumn`).
        public var ambientDepth: Double
        public var ambientChord: Double

        public init(sun: Spectrum3, ambient: Spectrum3, ambientUp: Spectrum3, ambientDown: Spectrum3, cosView: Double,
                    cosAxis: Double, sunDepth: Double, sunChord: Double, ambientDepth: Double, ambientChord: Double) {
            self.sun = sun
            self.ambient = ambient
            self.ambientUp = ambientUp
            self.ambientDown = ambientDown
            self.cosView = cosView
            self.cosAxis = cosAxis
            self.sunDepth = sunDepth
            self.sunChord = sunChord
            self.ambientDepth = ambientDepth
            self.ambientChord = ambientChord
        }
    }

    /// J, cd/m² per unit extinction, per channel:
    /// ω (E⊙ (p e^(−τ⊙) + D⊙) + `ambientDiffuse`).
    public static func source(albedo: Spectrum3, asymmetry g: Double, light l: Light) -> Spectrum3 {
        let phase = CloudPhase.henyeyGreenstein(l.cosView, g: g), direct = exp(-l.sunDepth)
        func channel(_ w: Double, _ sun: Double, _ inScatter: Double, _ up: Double, _ down: Double) -> Double {
            let diffuse = sunDiffuse(sunDepth: l.sunDepth, sunChord: l.sunChord, cosView: l.cosView, albedo: w, asymmetry: g)
            let ambient = ambientDiffuse(depth: l.ambientDepth, column: l.ambientChord, cosAxis: l.cosAxis, albedo: w,
                                         asymmetry: g, up: up, down: down, inScatter: inScatter)
            return w * (sun * (phase * direct + diffuse) + ambient)
        }
        return Spectrum3(channel(albedo.r, l.sun.r, l.ambient.r, l.ambientUp.r, l.ambientDown.r),
                         channel(albedo.g, l.sun.g, l.ambient.g, l.ambientUp.g, l.ambientDown.g),
                         channel(albedo.b, l.sun.b, l.ambient.b, l.ambientUp.b, l.ambientDown.b))
    }
}

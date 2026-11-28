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

        /// The optical-depth-weighted mean t over t0...t1, whose depth is
        /// `depth`: c + w² (σ(t0) − σ(t1)) / depth, where a primitive's light
        /// is evaluated (Condor et al.'s constant source per primitive). The
        /// nearest approach, clamped into t0...t1, where the depth is nil.
        public func centroid(from t0: Double, to t1: Double, depth: Double) -> Double {
            guard depth > 1e-12 else { return min(max(centre, t0), t1) }
            let k = 1 / (2 * width * width)
            let e0 = exp(-(t0 - centre) * (t0 - centre) * k), e1 = exp(-(t1 - centre) * (t1 - centre) * k)
            return min(max(centre + width * width * peak * (e0 - e1) / depth, t0), t1)
        }
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
/// single-scattering albedo ω and asymmetry g. One g for all three parts:
/// - **the Sun's light scattered once:** ω E⊙ p(cos θ) e^(−τ⊙), with
///   Henyey and Greenstein's phase (`CloudPhase.henyeyGreenstein`) and τ⊙
///   the smoke's optical depth from the point towards the Sun;
/// - **the Sun's light scattered many times:** C2's two-stream
///   (`CloudLighting.streams`: Bohren 1987's, backscattered fraction
///   b = (1 − g)/2, unit diffusivity), here with absorption (`streams`), of
///   the Sun's chord through the point as a slab lit face-on: its diffuse
///   streams, less the direct beam, seen in the eye's direction as C2 sees
///   its own (each stream isotropic over its hemisphere, blended by the
///   direction);
/// - **the ambient:** R3's SH9 scattered by the same phase (`SH9.inScatter`,
///   Funk and Hecke), or the caller's stand-in where there is no probe,
///   reaching the point through the column around it diffusely from both
///   sides (`ambientShare`): all of it in a conservative smoke, the outer
///   hemisphere's half at the face of a black one.
///
/// At ω = 1 the streams are C2's exactly, and the ambient is unattenuated,
/// as P2's smoke has it today.
public enum SmokeScattering {
    /// The two-stream backscattered fraction, (1 − g)/2, as C2's.
    public static func backscatter(asymmetry g: Double) -> Double { (1 - g) / 2 }

    /// The two-stream's downward and upward diffuse fluxes at optical depth
    /// t from the top of a column of optical depth τ, per unit flux entering
    /// its top and none its bottom, for albedo ω and asymmetry g (Meador and
    /// Weaver 1980's γ1 = 1 − ω(1 − b), γ2 = ω b at C2's unit diffusivity):
    /// with k = √(γ1² − γ2²), u = τ − t and E(x) = (1 − e^(−2kx))/k,
    ///   F↓ = e^(−kt) (1 + e^(−2ku) + γ1 E(u)) / (1 + e^(−2kτ) + γ1 E(τ)),
    ///   F↑ = e^(−kt) γ2 E(u) / (1 + e^(−2kτ) + γ1 E(τ)).
    /// At ω = 1 (k = 0, E(x) = 2x) these are C2's 1 − bt/(1 + bτ) and
    /// b(τ − t)/(1 + bτ); at ω = 0 the direct beam e^(−t) and nothing up.
    public static func streams(depth t: Double, column tau: Double, albedo w: Double, asymmetry g: Double)
        -> (down: Double, up: Double) {
        let tau = max(tau, 0), t = min(max(t, 0), tau), u = tau - t
        let b = backscatter(asymmetry: g), w = min(max(w, 0), 1)
        let g1 = 1 - w * (1 - b), g2 = w * b
        let k = ((1 - w) * (1 - w + 2 * w * b)).squareRoot()
        // E(x) = (1 − e^(−2kx))/k, its series where 2kx < 1e-2:
        // 2x (1 − kx + ⅔ (kx)² − ⅓ (kx)³ + 2/15 (kx)⁴), 2x at k = 0.
        func e(_ x: Double) -> Double {
            let y = 2 * k * x, q = k * x
            return y < 1e-2 ? 2 * x * (1 - q * (1 - q * (2.0 / 3.0 - q * (1.0 / 3.0 - 2.0 / 15.0 * q)))) : (1 - exp(-y)) / k
        }
        let den = 1 + exp(-2 * k * tau) + g1 * e(tau), down0 = exp(-k * t)
        return (down0 * (1 + exp(-2 * k * u) + g1 * e(u)) / den, down0 * g2 * e(u) / den)
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

    /// The share of the ambient radiance that reaches a point `depth` into
    /// a column of optical depth `column`, fed diffusely from both sides:
    /// half the four streams there, ½ (F↓(t) + F↑(t) + F↓(τ − t) + F↑(τ − t)).
    /// 1 at ω = 1; ½ (1 + e^(−τ)) at the face of a black column.
    public static func ambientShare(depth t: Double, column tau: Double, albedo w: Double, asymmetry g: Double) -> Double {
        let tau = max(tau, 0), t = min(max(t, 0), tau)
        let a = streams(depth: t, column: tau, albedo: w, asymmetry: g)
        let b = streams(depth: tau - t, column: tau, albedo: w, asymmetry: g)
        return 0.5 * (a.down + a.up + b.down + b.up)
    }

    /// What the caller knows of the light at the point.
    public struct Light: Equatable {
        /// The Sun's illuminance on the smoke from outside it, lux: after
        /// the air, the planet's and the vessel's shadows, the clouds.
        public var sun: Spectrum3
        /// The ambient radiance scattered per unit albedo, cd/m²:
        /// `SH9.inScatter(view:asymmetry:)` with the smoke's g, or a stand-in.
        public var ambient: Spectrum3
        /// The cosine between the view ray (camera to point) and the
        /// direction to the Sun: 1 is looking at the Sun through the smoke.
        public var cosView: Double
        /// The smoke's optical depth from the point to the Sun, and its
        /// whole optical depth along that line through the point.
        public var sunDepth: Double
        public var sunChord: Double
        /// The point's optical depth into the column the ambient lights,
        /// and that column's whole optical depth (any chord through the
        /// point: the view ray's, say).
        public var ambientDepth: Double
        public var ambientChord: Double

        public init(sun: Spectrum3, ambient: Spectrum3, cosView: Double, sunDepth: Double, sunChord: Double,
                    ambientDepth: Double, ambientChord: Double) {
            self.sun = sun
            self.ambient = ambient
            self.cosView = cosView
            self.sunDepth = sunDepth
            self.sunChord = sunChord
            self.ambientDepth = ambientDepth
            self.ambientChord = ambientChord
        }
    }

    /// J, cd/m² per unit extinction, per channel: ω (E⊙ (p e^(−τ⊙) + D⊙) + L_amb A).
    public static func source(albedo: Spectrum3, asymmetry g: Double, light l: Light) -> Spectrum3 {
        let phase = CloudPhase.henyeyGreenstein(l.cosView, g: g), direct = exp(-l.sunDepth)
        func channel(_ w: Double, _ sun: Double, _ ambient: Double) -> Double {
            let diffuse = sunDiffuse(sunDepth: l.sunDepth, sunChord: l.sunChord, cosView: l.cosView, albedo: w, asymmetry: g)
            let share = ambientShare(depth: l.ambientDepth, column: l.ambientChord, albedo: w, asymmetry: g)
            return w * (sun * (phase * direct + diffuse) + ambient * share)
        }
        return Spectrum3(channel(albedo.r, l.sun.r, l.ambient.r), channel(albedo.g, l.sun.g, l.ambient.g),
                         channel(albedo.b, l.sun.b, l.ambient.b))
    }
}

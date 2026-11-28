import Foundation
import OrbitCore

/// The exhaust trail as a column of Gaussian smoke (look round 2, LR5 PR2),
/// closed form in each node's age, so that a frame, a rebuild and any warp
/// agree. This file holds the column's physics; `TrailChain` lays its nodes
/// and `TrailPass` draws them.
public enum TrailColumn {
    // MARK: Coflow growth

    /// A slice of the jet past P2's hand-over, still faster than the air it
    /// runs with: the top-hat jet of `JetPath` in a pure coflow of speed U,
    /// in closed form in the slice's age.
    ///
    /// With y = b² u (the volume flux over π: half-width b, the jet fluid's
    /// speed u = U + Δ) and m = b² u Δ (its excess momentum flux over π, kept
    /// in a coflow: the air taken in brings the stream's momentum), shear
    /// entrainment dy/ds = 2 α1 b Δ (`JetPath.shearEntrainment`) along the
    /// path, the slice's age t = ∫ ds / u, gives
    ///   dy/dt = 2 α1 m √(U y + m) / y,
    /// so with z = √(U y + m) and a = √m,
    ///   z³ − 3 a² z + 2 a³ = (z − a)²(z + 2a) = that at the start + 3 U² α1 m t.
    /// Writing z = a + U η keeps U out of the denominators:
    ///   η² (U η + 3a) = (y0 / (z0 + a))² (z0 + 2a) + 3 α1 m t,
    /// one cubic in η, then y = η (U η + 2a), z = a + U η, b = y / z,
    /// Δ = m / y; and the slice's drift through the air, ∫ Δ dt =
    /// (η − y0 / (z0 + a)) / α1. In still air (U = 0) b² = (y0² + 4 α1 m^(3/2) t)
    /// / m, the momentum jet's b ∝ √t; in a strong coflow b³ grows as t, the
    /// weak jet's b ∝ s^(1/3) (Tennekes and Lumley 1972), which `JetPath`
    /// is checked against.
    public struct Coflow: Equatable {
        /// The coflow's speed (the airspeed), m/s.
        public var stream: Double
        /// y0 and m at the start, m³/s and m⁴/s².
        public var flux: Double
        public var excessMomentum: Double

        /// The slice of half-width `halfWidth` (m) whose fluid runs `excess`
        /// m/s faster than a coflow of `stream` m/s.
        public init(halfWidth b: Double, excess: Double, stream: Double) {
            self.stream = max(stream, 0)
            let u = self.stream + max(excess, 0)
            flux = b * b * u
            excessMomentum = b * b * u * max(excess, 0)
        }

        /// The state at age `t` (s): half-width (m), excess speed (m/s) and
        /// the drift through the air since the start (m).
        public func state(age t: Double) -> (halfWidth: Double, excess: Double, drift: Double) {
            let m = excessMomentum, u = stream, y0 = flux
            guard m > 0, y0 > 0 else { return ((y0 / max(u, 1e-12)).squareRoot(), 0, 0) }
            let a = m.squareRoot(), z0 = (u * y0 + m).squareRoot(), eta0 = y0 / (z0 + a)
            let e = eta0 * eta0 * (z0 + 2 * a) + 3 * JetPath.shearEntrainment * m * max(t, 0)
            let eta = Self.root(u: u, a: a, e: e)
            let y = eta * (u * eta + 2 * a), z = a + u * eta
            return (y / z, m / y, (eta - eta0) / JetPath.shearEntrainment)
        }

        /// The root η ≥ 0 of η² (u η + 3a) = e: Newton from above (the cubic
        /// is increasing and convex there, so it converges from either
        /// over-estimate, √(e / 3a) or ∛(e / u), monotonically).
        static func root(u: Double, a: Double, e: Double) -> Double {
            guard e > 0 else { return 0 }
            var x = (e / (3 * a)).squareRoot()
            if u > 0 { x = min(x, cbrt(e / u)) }
            for _ in 0..<40 {
                let f = x * x * (u * x + 3 * a) - e, df = x * (3 * u * x + 6 * a)
                guard df > 0 else { break }
                let next = x - f / df
                if next >= x || x - next <= 1e-15 * x { return max(next, 0) }
                x = next
            }
            return x
        }
    }

    // MARK: The line thermal

    /// The trail's heat lifting it: a bent-over line thermal (the plume of a
    /// moving source seen in the air's frame, each slice a 2-D thermal) in
    /// air of buoyancy frequency N. Its buoyancy per metre B = g Q′ / (ρ c_p T)
    /// (Q′ the heat left in a metre, J/m) drives its momentum per metre,
    /// d(π r² w)/dt = B, and stratification takes it back, dB/dt = −N² π r² w;
    /// it entrains as r = β z. So π β² z³ / 3 = (B / N²)(1 − cos N t): in
    /// neutral air z = (3 B t² / (2 π β²))^(1/3), Briggs's bent-over rise
    /// 1.6 F^(1/3) x^(2/3) / U with F = B U / π (1.587 at β = 0.6); in stable
    /// air it peaks at N t = π, z = (6 B / (π β² N²))^(1/3), Briggs's
    /// 2.6 (F / (U s))^(1/3) (2.554), and holds there (Briggs 1975, "Plume
    /// rise predictions").
    public struct LineThermal: Equatable {
        /// β, the line thermal's entrainment (Briggs's 0.6 for bent-over
        /// plumes).
        public static let entrainment = 0.6
        /// B, m³/s², and N, 1/s.
        public var buoyancy: Double
        public var frequency: Double

        public init(buoyancy: Double, frequency: Double) {
            self.buoyancy = max(buoyancy, 0)
            self.frequency = max(frequency, 0)
        }

        /// The buoyancy per metre of `heat` J/m in air of `density`
        /// (kg/m³) and `temperature` (K), c_p 1,004.7 J/(kg K): g Q′ / (ρ c_p T).
        public static func buoyancy(heat: Double, density: Double, temperature: Double) -> Double {
            guard density > 0, temperature > 0 else { return 0 }
            return 9.806_65 * heat / (density * 1_004.7 * temperature)
        }

        /// The rise at age `t` (s), m: (3 B (1 − cos N t) / (π β² N²))^(1/3),
        /// held at its peak past N t = π; (3 B t² / (2 π β²))^(1/3) where N t
        /// is small (the same, to its series).
        public func rise(age t: Double) -> Double {
            let beta2 = Self.entrainment * Self.entrainment, t = max(t, 0)
            let nt = min(frequency * t, Double.pi)
            // (1 − cos x) / x² = 2 sin²(x/2) / x², ½ at x = 0.
            let half = nt < 1e-4 ? 0.5 - nt * nt / 24 : 2 * pow(sin(0.5 * nt), 2) / (nt * nt)
            let tEff = frequency > 0 ? min(t, Double.pi / frequency) : t
            return cbrt(3 * buoyancy * 2 * half * tEff * tEff / (2 * Double.pi * beta2))
        }

        /// The rise's speed at age `t`, m/s.
        public func speed(age t: Double) -> Double {
            let z = rise(age: t)
            guard z > 0, frequency * t < Double.pi else { return 0 }
            // π β² z² ż = (B / N) sin N t, or B t.
            let p = frequency > 0 ? buoyancy / frequency * sin(frequency * t) : buoyancy * t
            return p / (Double.pi * Self.entrainment * Self.entrainment * z * z)
        }
    }

    // MARK: Turbulent diffusion

    /// The cross-section of a smoke line in turbulent air, as a covariance
    /// in the plane across it (y horizontal, z up), in closed form in age.
    ///
    /// - **Below the mixed layer's top** z_i the convective layer's eddy
    ///   diffusivity K = κ w* z (1 − z/z_i)² (Troen and Mahrt 1986, the
    ///   profile's exponent 2; κ 0.4), the same across and up, at the line's
    ///   height: each variance grows by 2 K t.
    /// - **Above it** the free troposphere's and stratosphere's weak
    ///   turbulence in the wind's shear s = ∂u/∂z across the line, with
    ///   diffusivities D_h, D_v and D_s: dΣ/dt = A Σ + Σ Aᵀ + 2D, A = [[0, s],
    ///   [0, 0]], whose solution (Konopka 1995, as Schumann 2012's contrail
    ///   model has it) is
    ///   σzz = σzz0 + 2 D_v t,
    ///   σyz = σyz0 + s σzz0 t + 2 D_s t + s D_v t²,
    ///   σyy = σyy0 + 2 D_h t + 2 s σyz0 t + s² σzz0 t² + 2 s D_s t² + (2/3) s² D_v t³.
    public struct Spread: Equatable {
        public var yy: Double
        public var yz: Double
        public var zz: Double

        public init(yy: Double, yz: Double, zz: Double) {
            self.yy = yy
            self.yz = yz
            self.zz = zz
        }

        /// A round cross-section of standard deviation `sigma`.
        public init(sigma: Double) { self.init(yy: sigma * sigma, yz: 0, zz: sigma * sigma) }

        /// Konopka's covariance after `t` s in shear `shear` (1/s) with
        /// diffusivities `horizontal`, `vertical` and `cross` (m²/s).
        public func sheared(after t: Double, shear s: Double, horizontal dh: Double, vertical dv: Double,
                            cross ds: Double = 0) -> Spread {
            let t = max(t, 0)
            return Spread(yy: yy + 2 * dh * t + 2 * s * yz * t + s * s * zz * t * t + 2 * s * ds * t * t
                              + 2.0 / 3.0 * s * s * dv * t * t * t,
                          yz: yz + s * zz * t + 2 * ds * t + s * dv * t * t,
                          zz: zz + 2 * dv * t)
        }

        /// Above the mixed layer, Schumann's (2012, GMD 5, 543) contrail
        /// plume: Konopka's covariance with D_V = c_V w′² / N (his Eq. 35,
        /// c_V 0.2, w′ 0.1 m/s, N at least 0.001 1/s; sedimentation left out,
        /// the trail's droplets falling at under a cm/s), D_S = 0 and
        /// D_H = c_H D² S_T (Eq. 36, c_H 0.1) on the plume's depth D² = 8 σzz,
        /// which grows linearly, so that the whole stays closed form:
        /// σzz = σzz0 + 2 D_V t, σyz = σyz0 + S σzz0 t + S D_V t²,
        /// σyy = σyy0 + 16 c_H S_T (σzz0 t + D_V t²) + 2 S σyz0 t + S² σzz0 t² + (2/3) S² D_V t³,
        /// S the shear across the line, S_T the wind's whole shear.
        public func schumann(after t: Double, normalShear s: Double, totalShear st: Double, frequency n: Double,
                             turbulence w: Double = 0.1) -> Spread {
            let t = max(t, 0), dv = 0.2 * w * w / max(n, 0.001), ch = 0.1
            return Spread(yy: yy + 16 * ch * abs(st) * (zz * t + dv * t * t) + 2 * s * yz * t + s * s * zz * t * t
                              + 2.0 / 3.0 * s * s * dv * t * t * t,
                          yz: yz + s * zz * t + s * dv * t * t,
                          zz: zz + 2 * dv * t)
        }

        /// The covariance after `t` s at diffusivity `k` (m²/s) every way.
        public func diffused(after t: Double, diffusivity k: Double) -> Spread {
            Spread(yy: yy + 2 * k * max(t, 0), yz: yz, zz: zz + 2 * k * max(t, 0))
        }

        /// Its principal standard deviations (m) and the angle of the
        /// larger from y towards z (rad).
        public var principal: (major: Double, minor: Double, angle: Double) {
            let mean = 0.5 * (yy + zz), d = (0.25 * (yy - zz) * (yy - zz) + yz * yz).squareRoot()
            return ((mean + d).squareRoot(), max(mean - d, 0).squareRoot(), 0.5 * atan2(2 * yz, yy - zz))
        }
    }

    /// Troen and Mahrt's (1986) eddy diffusivity at height `z` (m) in a
    /// convective mixed layer of depth `top` (z_i) and velocity scale
    /// `convective` (w*): κ w* z (1 − z/z_i)², κ 0.4; none above it.
    public static func mixedLayerDiffusivity(height z: Double, top zi: Double, convective w: Double) -> Double {
        guard zi > 0, z > 0, z < zi else { return 0 }
        let f = 1 - z / zi
        return 0.4 * w * z * f * f
    }

    // MARK: The node

    /// The turbulence a node's height has: the convective mixed layer's
    /// (below z_i) or the stratified air's above it (Schumann's).
    public struct Air: Equatable {
        /// The node's height above the ground, m.
        public var height: Double
        /// The mixed layer's top z_i (m) and its velocity scale w* (m/s):
        /// the launch morning's at the Cape (L, plan §6).
        public var mixedLayerTop: Double
        public var convective: Double
        /// The buoyancy frequency N (1/s), the wind's shear across the line
        /// S and its whole shear S_T (1/s), the air's density (kg/m³) and
        /// temperature (K).
        public var frequency: Double
        public var normalShear: Double
        public var totalShear: Double
        public var density: Double
        public var temperature: Double

        public init(height: Double, mixedLayerTop: Double, convective: Double, frequency: Double, normalShear: Double,
                    totalShear: Double, density: Double, temperature: Double) {
            self.height = height
            self.mixedLayerTop = mixedLayerTop
            self.convective = convective
            self.frequency = frequency
            self.normalShear = normalShear
            self.totalShear = totalShear
            self.density = density
            self.temperature = temperature
        }
    }

    /// A node of the trail: `spacing` metres of exhaust left in the air at
    /// `laid`, where P2's plume handed it over, as one Gaussian whose every
    /// parameter is closed form in its age:
    /// - its cross-section: P2's column's Gaussian width σ0 = C/(τ √(2π)),
    ///   grown as the jet goes on spreading in the coflow (`Coflow`, from the
    ///   hand-over's top-hat jet: σ0 b(a)/b0) and as the line thermal
    ///   entrains (`LineThermal`, its radius β z, σ β z/2), and spread by
    ///   the turbulence below or above the mixed layer's top;
    /// - its place: where laid, carried on the wind, risen by the thermal,
    ///   and drifted back along the path by the jet's excess speed;
    /// - its extinction: the column's cross-section per metre times its
    ///   length, conserved as it spreads (κ λ for the smoke's mass), faded
    ///   in linearly over the hand-over's window by the distance it has
    ///   gone from the window's start, U a plus the jet's drift (P2's
    ///   plume fading out linearly over the same window, so the two sum to
    ///   one).
    public struct Node: Equatable {
        public var laid: Epoch
        /// Where laid, the anchor's axes (m); the path's direction there
        /// (unit, the vehicle's motion) and the local vertical.
        public var position: Vec3
        public var tangent: Vec3
        public var up: Vec3
        /// The wind at its height, the anchor's axes (m/s).
        public var wind: Vec3
        /// The metres of the jet at the joint it stands for: P2's column
        /// per metre times it is its extinction.
        public var spacing: Double
        /// P2's column at the hand-over, the jet there, its heat per metre
        /// (J/m) and the air.
        public var column: PlumeAirflow.Column
        public var coflow: Coflow
        public var heat: Double
        public var air: Air
        /// The hand-over's window, 2w (m), it fades in over.
        public var window: Double
        /// The airspeed's rate where it was laid (m/s², at least 0): the
        /// vehicle drawing away from it faster as it climbs.
        public var acceleration: Double

        public init(laid: Epoch, position: Vec3, tangent: Vec3, up: Vec3, wind: Vec3, spacing: Double,
                    column: PlumeAirflow.Column, coflow: Coflow, heat: Double, air: Air, window: Double,
                    acceleration: Double = 0) {
            self.laid = laid
            self.position = position
            self.tangent = tangent
            self.up = up
            self.wind = wind
            self.spacing = spacing
            self.column = column
            self.coflow = coflow
            self.heat = heat
            self.air = air
            self.window = window
            self.acceleration = acceleration
        }

        /// The Gaussian width of P2's column at the hand-over, m.
        public var startWidth: Double {
            column.depth > 0 ? column.crossSection / (column.depth * (2 * Double.pi).squareRoot()) : 0
        }

        /// Which way it rises: the vertical's part across the line (unit;
        /// along the vertical for a level line), and that part's length,
        /// cos θ for a line climbing at θ. Only the buoyancy across a line
        /// bends it; along it, it drives a flow along a uniform column that
        /// shows nowhere.
        public var rising: (direction: Vec3, share: Double) {
            let across = up - tangent * up.dot(tangent), share = across.length
            return share > 1e-9 ? (across * (1 / share), share) : (up, 0)
        }

        /// Its line thermal, across it: the buoyancy's part across the line,
        /// B cos θ, and the stratification's for a rise that climbs cos θ of
        /// it, N cos θ (level, Briggs's; standing upright, none).
        public var thermal: LineThermal {
            let c = rising.share
            return LineThermal(buoyancy: c * LineThermal.buoyancy(heat: heat, density: air.density,
                                                                  temperature: air.temperature),
                               frequency: c * air.frequency)
        }

        /// Its cross-section's covariance at age `a` (s), in the plane across
        /// the path (y horizontal, z up), m².
        public func spread(age a: Double) -> Spread {
            let s0 = startWidth, a = max(a, 0)
            let grown = s0 * coflow.state(age: a).halfWidth / max(coflow.state(age: 0).halfWidth, 1e-9)
            let entrained = 0.5 * LineThermal.entrainment * thermal.rise(age: a)
            let own = grown * grown + entrained * entrained
            let start = Spread(sigma: s0)
            let turbulent: Spread
            if air.height < air.mixedLayerTop {
                let k = mixedLayerDiffusivity(height: air.height, top: air.mixedLayerTop, convective: air.convective)
                turbulent = start.diffused(after: a, diffusivity: k)
            } else {
                turbulent = start.schumann(after: a, normalShear: air.normalShear, totalShear: air.totalShear,
                                           frequency: air.frequency)
            }
            return Spread(yy: turbulent.yy - s0 * s0 + own, yz: turbulent.yz, zz: turbulent.zz - s0 * s0 + own)
        }

        /// Where its centre is at age `a`, the anchor's axes.
        public func centre(age a: Double) -> Vec3 {
            let a = max(a, 0)
            return position + wind * a + rising.direction * thermal.rise(age: a) - tangent * coflow.state(age: a).drift
        }

        /// How far it is behind the window's start at age `a` (m), which
        /// draws away with the vehicle: the path the vehicle has flown
        /// through the air since, U a + ½ A a², and the jet's drift through
        /// the air.
        public func travelled(age a: Double) -> Double {
            let a = max(a, 0)
            return coflow.stream * a + 0.5 * acceleration * a * a + coflow.state(age: a).drift
        }

        /// Its fade-in at age `a`, 0...1: linear in how far it is behind
        /// the window's start, so that a line of them, laid as the vehicle
        /// climbs, ramps linearly over the window behind it (seen through
        /// its σ along the path, `TrailChain.jointAlong`: P2's fade is the
        /// complement of that, `PlumeAirflow.trailFade`).
        public func fade(age a: Double) -> Double { window > 0 ? min(max(travelled(age: a) / window, 0), 1) : 1 }

        /// The age at which it has crossed the window (its fade complete), s.
        public var fadeIn: Double {
            guard window > 0 else { return 0 }
            var lo = 0.0, hi = window / max(coflow.stream, 1e-3) + 1
            while travelled(age: hi) < window { hi *= 2 }
            for _ in 0..<60 {
                let mid = 0.5 * (lo + hi)
                if travelled(age: mid) < window { lo = mid } else { hi = mid }
            }
            return hi
        }

        /// The node at age `a` as a Gaussian medium, centred at the anchor's
        /// `origin` subtracted (camera-relative, say): along the path σ 0.6
        /// of its spacing at every age (a line of them is smooth to 0.2 %;
        /// a uniform column's spreading along itself shows nowhere, and at
        /// its head P2's fade is the complement of that σ,
        /// `PlumeAirflow.trailFade`); across, the covariance's principal
        /// axes; its peak from its extinction cross-section C × spacing.
        public func medium(age a: Double, origin: Vec3 = .zero, faded: Bool = true) -> GaussianMedium {
            let sp = spread(age: a), p = sp.principal
            let across = tangent.cross(up).normalized, vertical = across.cross(tangent).normalized
            let u = across * cos(p.angle) + vertical * sin(p.angle)
            let along = 0.6 * spacing
            let sigma = Vec3(along, max(p.major, 1e-3), max(p.minor, 1e-3))
            let cross = column.crossSection * spacing * (faded ? fade(age: a) : 1)
            return GaussianMedium(centre: centre(age: a) - origin, axisU: tangent, axisV: u, sigma: sigma,
                                  peakExtinction: cross / (pow(2 * Double.pi, 1.5) * sigma.x * sigma.y * sigma.z),
                                  albedo: Spectrum3(repeating: column.albedo), asymmetry: column.asymmetry)
        }
    }
}

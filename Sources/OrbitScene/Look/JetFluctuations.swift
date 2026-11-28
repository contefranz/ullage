import Foundation

/// How a plume's field fluctuates about its mean (look round 2, LR3): the
/// exhaust's share in the jet (its mixture fraction) and the heat it
/// carries, on the turbulence's noise (`PlumeTurbulence`). The shader's
/// `plume_member` applies the same lines; `PlumeMember.sample(x:r:noise:)`
/// is their reference.
///
/// - **No fluctuation in the unmixed core.** The potential core holds the
///   exhaust as it left the nozzle: no air has reached it, so its share is
///   exactly 1 and nothing fluctuates (`mixedness`): across the mixing
///   layer's inner half from the core's shrinking top hat, and on the axis
///   from the core's end to the self-similar far field. No noise is read
///   there. Nor in a ballooned plume's free expansion, a laminar flow:
///   only its boundary with the air billows.
/// - **The measured fluctuation.** In the mixed jet the exhaust's share
///   fluctuates as Dowling and Dimotakis (1990) measured a round jet's
///   concentration: 0.237 of the mean on the axis, rising off it, and much
///   more than the mean where it is thin at the jet's edge (`relativeRMS`,
///   by the share of the centreline's mean that the mean has fallen to).
/// - **An intermittent edge that keeps the mean.** The fluctuation is a
///   rectified Gaussian, (n − t)⁺ / E[(n − t)⁺] on the unit noise n, its
///   threshold t set so that its r.m.s. over its mean is the measured one
///   (`threshold(relativeRMS:)`): its mean is the mean field's, exactly for
///   a Gaussian n. On the axis t is about −4.2 and the factor is 1 + 0.24 n;
///   at the edge the threshold rises and the exhaust is present only part
///   of the time, Φ(−t): the turbulent front, ragged and bounded by pockets
///   of clear air, falling to half the time where Dowling and Dimotakis's
///   r.m.s. reaches 1.46 times the mean (η = r/(x − x0) ≈ 0.18), within half
///   a front width of the vortical front Corrsin and Kistler (1955)
///   measured (η 0.16, standard deviation 0.043; `JetFluctuationsTests`).
/// - **Billowing boundaries.** Where the air confines a ballooned plume's
///   free expansion (P1's structure visibility), the boundary's cut is the
///   share of the time the expansion's gas is there, drawn the same way; a
///   smoky plume's (`billows`).
/// - **The heat on its excess.** The temperature's excess over the air
///   follows the exhaust's share where it is mixed (inert dilution), not
///   where the afterburning flame burns (its own temperature; the flame
///   sheet comes later, decision 8); the light follows it to first order
///   in ln B, its mean kept over the rectified fluctuation (`heatLight`).
///
/// The march draws them only until the plume in front of a sample is 90 %
/// opaque, and a cluster that cannot fluctuate with the march's still
/// variant (PlumeShaders); behind, and there, the field is its mean.
public enum JetFluctuations {
    // MARK: Dowling and Dimotakis 1990

    /// η = r/(x − x0) at the stations of the profiles below.
    public static let similarity: [Double] = (0...19).map { Double($0) / 100 }
    /// The mean concentration over the centreline's: their figure 3's fitted
    /// curve (tools/data/dowling_dimotakis_1990_jet_concentration.csv).
    public static let meanProfile = [1.000, 0.994, 0.975, 0.945, 0.907, 0.861, 0.806, 0.749, 0.692, 0.628,
                                     0.566, 0.504, 0.444, 0.385, 0.325, 0.268, 0.214, 0.165, 0.122, 0.082]
    /// The r.m.s. fluctuation over the centreline's mean at Re0 16,000
    /// (figure 9; at 40,000 the same).
    public static let rmsProfile = [0.237, 0.2375, 0.242, 0.248, 0.255, 0.262, 0.268, 0.272, 0.275, 0.274,
                                    0.272, 0.266, 0.259, 0.2505, 0.240, 0.228, 0.216, 0.203, 0.191, 0.180]
    /// The centreline's r.m.s. over its mean (p. 120: 0.237 ± 0.005 at Re0
    /// 16,000), H.
    public static let centrelineUnmixedness = 0.237

    /// Corrsin and Kistler's (1955) round jet at x/d = 60: the turbulence
    /// front's mean position and its standard deviation in η, the
    /// intermittency 1/2 erfc((η − front)/(√2 width))
    /// (tools/data/corrsin_kistler_1955_round_jet_front.csv). The check on
    /// the edge, not an input.
    public static let frontPosition = 0.160, frontWidth = 0.0425

    /// The local r.m.s. over the local mean where the mean has fallen to
    /// `g` of the centreline's: theirs at the η where their mean does (linear
    /// between the stations), held beyond their last station (g 0.082).
    public static func relativeRMS(meanShare g: Double) -> Double {
        let n = meanProfile.count
        let g = min(max(g, meanProfile[n - 1]), 1)
        for i in 0..<(n - 1) where g >= meanProfile[i + 1] {
            let f = (meanProfile[i] - g) / (meanProfile[i] - meanProfile[i + 1])
            let r0 = rmsProfile[i] / meanProfile[i], r1 = rmsProfile[i + 1] / meanProfile[i + 1]
            return r0 + (r1 - r0) * f
        }
        return rmsProfile[n - 1] / meanProfile[n - 1]
    }

    // MARK: The rectified Gaussian

    /// The unit normal's density.
    public static func normalDensity(_ z: Double) -> Double { exp(-0.5 * z * z) / (2 * Double.pi).squareRoot() }

    /// The unit normal's distribution function Φ(z), from Abramowitz and
    /// Stegun's 7.1.26 (error under 1.5×10⁻⁷), as the shader evaluates it.
    public static func normalCDF(_ z: Double) -> Double {
        let x = abs(z) / 2.0.squareRoot(), t = 1 / (1 + 0.3275911 * x)
        let poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t
        let erf = 1 - poly * exp(-x * x)
        return z >= 0 ? 0.5 * (1 + erf) : 0.5 * (1 - erf)
    }

    /// E[(n − t)⁺] for a unit normal n: φ(t) − t Φ(−t).
    public static func positivePart(threshold t: Double) -> Double {
        max(normalDensity(t) - t * normalCDF(-t), 1e-12)
    }

    /// E[(n − t)⁺] over the jet's thresholds (t ≤ 0.7) without an
    /// exponential, as the shader takes it (`plume_positivePartJet`): −t
    /// below −2.6 (within 0.06 %), else a polynomial of degree 7 fitted on
    /// −2.6...0.7 (within 5×10⁻⁵).
    public static func positivePartApproximation(threshold t: Double) -> Double {
        if t < -2.6 { return -t }
        let x = (2 * min(t, 0.7) + 1.9) / 3.3
        var p = 0.009232227
        for c in [-0.005121836, -0.05182828, -0.010591066, 0.18120124, 0.346270441, -1.36783254, 1.041547268] {
            p = p * x + c
        }
        return p
    }

    /// The r.m.s. of (n − t)⁺ over its mean.
    public static func rectifiedRMS(threshold t: Double) -> Double {
        let m1 = positivePart(threshold: t), m2 = (1 + t * t) * normalCDF(-t) - t * normalDensity(t)
        return max(m2 / (m1 * m1) - 1, 0).squareRoot()
    }

    /// The threshold whose rectified Gaussian's r.m.s. over its mean is `r`
    /// (bisection; it rises with t).
    public static func threshold(relativeRMS r: Double) -> Double {
        var lo = -60.0, hi = 6.0
        for _ in 0..<80 {
            let mid = 0.5 * (lo + hi)
            if rectifiedRMS(threshold: mid) < r { lo = mid } else { hi = mid }
        }
        return 0.5 * (lo + hi)
    }

    /// The share of the time the jet's fluid is present at a threshold: Φ(−t).
    public static func presence(threshold t: Double) -> Double { normalCDF(-t) }

    /// The jet's thresholds where its mean has fallen to j/15 of the
    /// centreline's, j = 0...15: PlumeFrame's table.
    public static let thresholds: [Double] = (0...15).map {
        threshold(relativeRMS: relativeRMS(meanShare: Double($0) / 15))
    }

    /// The r.m.s. over the mean those thresholds give (the measured one):
    /// PlumeFrame's second table.
    public static let spreads: [Double] = thresholds.map { rectifiedRMS(threshold: $0) }

    /// The jet's threshold at a mean share `g` (0-1), linear in the table.
    public static func threshold(meanShare g: Double) -> Double { interpolate(thresholds, g) }

    /// The fluctuation's r.m.s. over the mean at a mean share `g` (0-1),
    /// linear in the table.
    public static func spread(meanShare g: Double) -> Double { interpolate(spreads, g) }

    static func interpolate(_ table: [Double], _ g: Double) -> Double {
        let s = min(max(g, 0), 1) * 15, i = min(Int(s), 14), f = s - Double(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    /// The threshold at which the fluid is present a share `presence` of
    /// the time, approximately: the logistic's probit, ln((1 − γ)/γ)/1.702.
    /// Where it lies only shapes the edge; the factor keeps the mean
    /// whatever it is.
    public static func threshold(presence gamma: Double) -> Double {
        let g = min(max(gamma, 1e-4), 1 - 1e-4)
        return log((1 - g) / g) / 1.702
    }

    /// The factor on the mean, weighted by `strength` (0-1: the shutter's
    /// and the footprint's averages, how mixed the jet is): 1 + a((n −
    /// t)⁺/E[(n − t)⁺] − 1), whose mean is 1.
    public static func factor(noise n: Double, threshold t: Double, strength a: Double) -> Double {
        guard a > 0 else { return 1 }
        return 1 + a * (max(n - t, 0) / positivePart(threshold: t) - 1)
    }

    /// How much of the jet's own fluctuation is drawn where the free
    /// expansion's field is `v` of the whole: all of it to v 0.85, none
    /// from 0.95, where the jet is under 5 % of the field and its
    /// fluctuation invisible (reading the noise for it would cost 0.2 ms
    /// behind the S-II, whose J-2s are at v 0.97 just after staging).
    public static func jetShare(_ v: Double) -> Double { 1 - PlumeMember.smoothstep(0.85, 0.95, v) }

    /// Whether a ballooned member's boundary billows: its smoke's, a
    /// kerosene or solid exhaust's, does; a clear exhaust's ice fan (the
    /// J-2's, the SPS's) keeps its mean boundary, faint against the dark
    /// sky, whose billows would read the noise across a fan hundreds of
    /// metres wide (1.6 ms more in a chase behind the S-II, where they
    /// cost nothing before).
    public static func billows(_ m: PlumeMember) -> Bool { m.condensationDensity <= 0 }

    // MARK: Where the jet is mixed

    /// How mixed the jet is at x, r (0-1, R its radius there): none in the
    /// potential core, whose top hat shrinks to nothing at the core's end;
    /// across the mixing layer's inner half from it (L), and on the axis
    /// from the core's end to the self-similar far field (four core
    /// lengths, `PlumeTurbulence.similarFrom`; linearly, L).
    public static func mixedness(_ m: PlumeMember, x: Double, r: Double, radius big: Double) -> Double {
        let core = max(m.coreLength, 1e-6), re = m.exitRadius
        let rc = re * max(0, 1 - x / core)
        let eta = max(r - rc, 0) / max(big - rc, 0.05 * re)
        let lateral = PlumeMember.smoothstep(0, 0.5, eta)
        let axial = min(max((x / core - 1) / (PlumeTurbulence.similarFrom - 1), 0), 1)
        return 1 - (1 - lateral) * (1 - axial)
    }

    /// The noise at a sample (`PlumeTurbulence.field`): its value, of unit
    /// variance; the shutter's depth (0-1); and the footprint's weight
    /// (0-1, `TurbulenceSpectrum.footprintWeight` on the eddies' cell).
    public struct Noise: Equatable {
        public var value: Double
        public var depth: Double
        public var footprint: Double

        public init(value: Double, depth: Double = 1, footprint: Double = 1) {
            self.value = value
            self.depth = depth
            self.footprint = footprint
        }

        /// The weight the noise is drawn at: the shutter's and the footprint's.
        public var weight: Double { depth * footprint }
    }

    // MARK: The light

    /// d ln B / dT per channel at `kelvin` (PlumeLook.blackbody's fit, ln B
    /// = c0 + c1/T + c2/T²).
    public static func logSlope(_ kelvin: Double) -> Photometry.RGB {
        let u = 1 / max(kelvin, 300), c = PlumeLook.wien
        func s(_ i: Int) -> Double { -(c[i].1 + 2 * c[i].2 * u) * u * u }
        return Photometry.RGB(s(0), s(1), s(2))
    }

    /// The light's log-contrast per unit of the noise (its standard
    /// deviation), in its bluest channel, is held to this (L): beyond it the
    /// noise's one eddy size draws the hot eddies as blobs many times the
    /// mean (P2's ×5-8), and the light's mean would rest on the noise's far
    /// tail, which the volume noise lacks (kurtosis 2.7): at the
    /// intermittent edge the light would vary as e^(2.5 n).
    public static let lightContrast = 1.0
    /// The heat is drawn fluctuating only where its light's log-contrast is
    /// more than this a standard deviation (the burning flame's heat, cold
    /// smoke are not): a cost, not a look.
    public static let lightThreshold = 0.02

    /// The light of a gas at mean temperature `t` whose excess `excess` (K)
    /// over the air follows the exhaust's share, the share's factor 1 + δ
    /// (δ = s ((n − τ)⁺/E[(n − τ)⁺] − 1), threshold τ, strength s, r.m.s.
    /// `spread`), the emitting density fluctuating with it. The excess is
    /// drawn D δ, D the excess or less where the light's log-contrast per
    /// unit of the noise would pass `lightContrast` (none where the light
    /// would move by under `lightThreshold` a σ of δ), no hotter than
    /// `hottest`; the light follows it to first order in ln B, B(t) e^(b δ),
    /// b = D d ln B/dT per channel, divided by the mean of (1 + δ) e^(b δ)
    /// over a Gaussian n, closed form for the rectified Gaussian:
    /// e^(−bs) [(1 − s)(Φ(τ) + E Φ(κ − τ)) + (s/μ) E ((κ − τ) Φ(κ − τ) +
    /// φ(κ − τ))], κ = b s/μ, μ = E[(n − τ)⁺], E = e^(−κτ + κ²/2). So the
    /// light's mean is kept at the intermittent edge too, where δ's tail is
    /// heavy. Returns the drawn temperature, D's share of the excess and the
    /// factor on B(t) per channel.
    public static func heatLight(temperature t: Double, excess: Double, hottest: Double, strength s: Double,
                                 threshold tau: Double, spread: Double, delta: Double)
        -> (kelvin: Double, drawn: Double, light: Photometry.RGB) {
        guard s > 0, spread > 0, excess > 0 else { return (t, 0, Photometry.RGB(1, 1, 1)) }
        let slope = logSlope(t)
        let green = slope.g * excess * spread
        guard green > lightThreshold else { return (t, 0, Photometry.RGB(1, 1, 1)) }
        let mu = positivePart(threshold: tau), below = normalCDF(tau)
        // The bluest channel's log-contrast per unit of the noise, b s/μ.
        let perNoise = slope.b * excess * s / mu
        let drawn = perNoise > lightContrast ? lightContrast / perNoise : 1
        let d = excess * drawn
        // No hotter than the hottest gas.
        let dt = min(delta, max(hottest - t, 0) / d)
        func k(_ slopeC: Double) -> Double {
            let b = slopeC * d, kappa = b * s / mu, z = kappa - tau
            let e = exp(-kappa * tau + 0.5 * kappa * kappa)
            let mean = (1 - s) * (below + e * normalCDF(z)) + s / mu * e * (z * normalCDF(z) + normalDensity(z))
            return exp(b * (dt + s)) / mean
        }
        return (t + d * dt, drawn, Photometry.RGB(k(slope.r), k(slope.g), k(slope.b)))
    }
}

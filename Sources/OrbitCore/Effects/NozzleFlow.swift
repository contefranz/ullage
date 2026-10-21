import Foundation

/// One-dimensional isentropic flow of a perfect gas of constant ratio of
/// specific heats γ, and the Prandtl-Meyer expansion: the relations of
/// NACA Report 1135 (Ames Research Staff, 1953), eqs. 43-45, 80 and 171.
/// Angles in radians. They draw plumes and feed no physics.
public enum NozzleFlow {
    /// 1 + (γ - 1) M² / 2: T0 / T.
    static func stagnation(_ m: Double, _ g: Double) -> Double { 1 + 0.5 * (g - 1) * m * m }

    /// T / T0 at Mach `m`.
    public static func temperatureRatio(mach m: Double, gamma g: Double) -> Double {
        1 / stagnation(m, g)
    }

    /// p / p0 at Mach `m`.
    public static func pressureRatio(mach m: Double, gamma g: Double) -> Double {
        pow(stagnation(m, g), -g / (g - 1))
    }

    /// ρ / ρ0 at Mach `m`.
    public static func densityRatio(mach m: Double, gamma g: Double) -> Double {
        pow(stagnation(m, g), -1 / (g - 1))
    }

    /// A / A*, the area over the sonic throat's, at Mach `m` (> 0).
    public static func areaRatio(mach m: Double, gamma g: Double) -> Double {
        let e = 0.5 * (g + 1) / (g - 1)
        let base = 2 * stagnation(m, g) / (g + 1)
        return pow(base, e) / m
    }

    /// The Mach number at p / p0 = `ratio` (0 < ratio ≤ 1): the explicit
    /// inverse of `pressureRatio`.
    public static func mach(pressureRatio ratio: Double, gamma g: Double) -> Double {
        let t0OverT = pow(ratio, -(g - 1) / g)
        return (2 * max(0, t0OverT - 1) / (g - 1)).squareRoot()
    }

    /// The supersonic Mach number whose area ratio is `areaRatio` (≥ 1).
    public static func supersonicMach(areaRatio a: Double, gamma g: Double) -> Double {
        guard a > 1 else { return 1 }
        // ln(A/A*) rises monotonically from 0 at M = 1; bracket it.
        var high = 2.0
        while areaRatio(mach: high, gamma: g) < a { high *= 2 }
        return solveAreaRatio(a, g, low: 1, high: high, guess: min(high, 1 + (a - 1).squareRoot()))
    }

    /// The subsonic Mach number whose area ratio is `areaRatio` (≥ 1).
    public static func subsonicMach(areaRatio a: Double, gamma g: Double) -> Double {
        guard a > 1 else { return 1 }
        // A/A* ≈ k / M at low M.
        let k = pow(2 / (g + 1), -0.5 * (g + 1) / (g - 1))
        return solveAreaRatio(a, g, low: 0, high: 1, guess: min(0.5, k / a))
    }

    /// Newton's method on ln(A/A*) - ln a in M, kept inside the bracket
    /// [low, high] that holds the root, bisecting when a step leaves it.
    static func solveAreaRatio(_ a: Double, _ g: Double, low: Double, high: Double, guess: Double) -> Double {
        let target = log(a)
        var lo = low, hi = high, m = guess
        // On the subsonic branch ln(A/A*) falls with M.
        let falling = high <= 1
        for _ in 0..<100 {
            let f = log(areaRatio(mach: m, gamma: g)) - target
            if abs(f) < 1e-15 { return m }
            if (f > 0) != falling { hi = m } else { lo = m }
            // d ln(A/A*) / dM = (M² - 1) / (M (1 + (γ - 1) M² / 2)).
            let slope = (m * m - 1) / (m * stagnation(m, g))
            var next = slope != 0 ? m - f / slope : 0.5 * (lo + hi)
            if !(next > lo && next < hi) { next = 0.5 * (lo + hi) }
            if abs(next - m) <= 1e-15 * m { return next }
            m = next
        }
        return m
    }

    /// The Prandtl-Meyer function ν(M), the angle through which a sonic
    /// stream turns expanding to Mach `m` (≥ 1).
    public static func prandtlMeyer(mach m: Double, gamma g: Double) -> Double {
        guard m > 1 else { return 0 }
        let k = ((g + 1) / (g - 1)).squareRoot(), b = (m * m - 1).squareRoot()
        return k * atan(b / k) - atan(b)
    }

    /// ν_max = (π / 2)(√((γ + 1) / (γ - 1)) - 1): the turn of an expansion
    /// to vacuum.
    public static func maximumTurning(gamma g: Double) -> Double {
        0.5 * Double.pi * (((g + 1) / (g - 1)).squareRoot() - 1)
    }

    /// The Mach number whose Prandtl-Meyer angle is `nu` (0 ≤ ν < ν_max);
    /// infinite at or beyond ν_max.
    public static func mach(prandtlMeyer nu: Double, gamma g: Double) -> Double {
        guard nu > 0 else { return 1 }
        guard nu < maximumTurning(gamma: g) else { return .infinity }
        var lo = 1.0, hi = 2.0
        while prandtlMeyer(mach: hi, gamma: g) < nu { lo = hi; hi *= 2 }
        var m = 0.5 * (lo + hi)
        for _ in 0..<200 {
            let f = prandtlMeyer(mach: m, gamma: g) - nu
            if abs(f) < 1e-15 { return m }
            if f > 0 { hi = m } else { lo = m }
            // dν/dM = √(M² - 1) / (M (1 + (γ - 1) M² / 2)).
            let slope = (m * m - 1).squareRoot() / (m * stagnation(m, g))
            var next = slope > 0 ? m - f / slope : 0.5 * (lo + hi)
            if !(next > lo && next < hi) { next = 0.5 * (lo + hi) }
            if abs(next - m) <= 1e-15 * m { return next }
            m = next
        }
        return m
    }

    /// The Mach angle μ = asin(1 / M) (π/2 at or below Mach 1).
    public static func machAngle(mach m: Double) -> Double {
        m > 1 ? asin(1 / m) : 0.5 * Double.pi
    }
}

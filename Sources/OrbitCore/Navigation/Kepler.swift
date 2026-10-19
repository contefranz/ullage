import Foundation

/// Two-body motion: universal-variable propagation and Kepler's equation.
///
/// `propagate` is Vallado's algorithm KEPLER (Fundamentals of Astrodynamics
/// and Applications, 4th ed., §2.3, algorithm 8): Newton's method on the
/// universal Kepler equation for the universal anomaly χ, then the f and g
/// functions. One formula serves ellipses, parabolas and hyperbolas. The time
/// of flight grows with χ (its derivative is r/√μ), so each iterate narrows a
/// bracket on the root, and a Newton step that leaves the bracket (or
/// overflows on a long hyperbolic arc) bisects instead.
public enum Kepler {
    /// Position and velocity relative to the central body (m, m/s), in any
    /// inertial axes.
    public struct State: Equatable {
        public var position: Vec3
        public var velocity: Vec3

        public init(position: Vec3, velocity: Vec3) {
            self.position = position
            self.velocity = velocity
        }
    }

    /// The Stumpff functions c2(ψ) = (1 - cos √ψ)/ψ and c3(ψ) = (√ψ - sin √ψ)/√ψ³,
    /// continued to ψ < 0 with cosh and sinh, and by their series near 0.
    public static func stumpff(_ psi: Double) -> (c2: Double, c3: Double) {
        if abs(psi) < 0.1 {
            // Σ (-ψ)^k/(2k+2)! and Σ (-ψ)^k/(2k+3)!, to within 1e-17 here.
            let c2 = 1.0 / 2 - psi * (1.0 / 24 - psi * (1.0 / 720 - psi * (1.0 / 40_320 - psi
                * (1.0 / 3_628_800 - psi / 479_001_600))))
            let c3 = 1.0 / 6 - psi * (1.0 / 120 - psi * (1.0 / 5_040 - psi * (1.0 / 362_880 - psi
                * (1.0 / 39_916_800 - psi / 6_227_020_800))))
            return (c2, c3)
        }
        if psi > 0 {
            let s = psi.squareRoot()
            return ((1 - cos(s)) / psi, (s - sin(s)) / (s * psi))
        }
        let s = (-psi).squareRoot()
        return ((cosh(s) - 1) / -psi, (sinh(s) - s) / (s * -psi))
    }

    /// The two-body state `dt` seconds later (or earlier, for dt < 0), about a
    /// body of gravitational parameter `mu` (m³/s²).
    public static func propagate(_ s: State, mu: Double, by dt: Double) -> State {
        let r0 = s.position, v0 = s.velocity
        let r0n = r0.length, sqmu = mu.squareRoot()
        let sigma = r0.dot(v0) / sqmu
        let alpha = 2 / r0n - v0.lengthSquared / mu      // 1/a
        var t = dt
        var lo = -Double.infinity, hi = Double.infinity
        var chi: Double
        if alpha * r0n > 1e-9 {
            // An ellipse repeats each period, and within one |χ| < 2π/√α.
            let period = 2 * Double.pi / (sqmu * alpha * alpha.squareRoot())
            t = dt.truncatingRemainder(dividingBy: period)
            let span = 2 * Double.pi / alpha.squareRoot()
            lo = -span
            hi = span
            chi = sqmu * t * alpha
        } else if alpha * r0n < -1e-9 {
            let a = 1 / alpha
            let sign: Double = t >= 0 ? 1 : -1
            let arg = -2 * mu * alpha * t / (r0.dot(v0) + sign * (-mu * a).squareRoot() * (1 - r0n * alpha))
            chi = arg > 0 && arg.isFinite ? sign * (-a).squareRoot() * log(arg) : sqmu * t / r0n
        } else {
            chi = sqmu * t / r0n
        }
        guard t != 0 else { return s }
        if t > 0 { lo = max(lo, 0) } else { hi = min(hi, 0) }
        chi = min(max(chi, lo), hi)

        for _ in 0..<200 {
            let psi = chi * chi * alpha
            let (c2, c3) = stumpff(psi)
            let chi2 = chi * chi
            let f = chi2 * chi * c3 + sigma * chi2 * c2 + r0n * chi * (1 - psi * c3) - sqmu * t
            let r = chi2 * c2 + sigma * chi * (1 - psi * c3) + r0n * (1 - psi * c2)
            var next: Double
            if f.isFinite && r.isFinite {
                if f < 0 { lo = chi } else { hi = chi }
                next = chi - f / r
            } else {
                // Overflow: too far out along a hyperbola.
                if chi > 0 { hi = chi } else { lo = chi }
                next = chi / 2
            }
            if !(next > lo && next < hi) {
                next = lo.isFinite && hi.isFinite ? (lo + hi) / 2 : chi / 2
            }
            let done = abs(next - chi) <= 1e-15 * max(abs(chi), 1)
            chi = next
            if done || !(hi - lo > 1e-15 * max(abs(chi), 1)) { break }
        }

        let psi = chi * chi * alpha
        let (c2, c3) = stumpff(psi)
        let chi2 = chi * chi
        let f = 1 - chi2 / r0n * c2
        let g = t - chi2 * chi / sqmu * c3
        let r = r0 * f + v0 * g
        let rn = r.length
        let fdot = sqmu / (rn * r0n) * chi * (psi * c3 - 1)
        let gdot = 1 - chi2 / rn * c2
        return State(position: r, velocity: r0 * fdot + v0 * gdot)
    }

    // MARK: Kepler's equation

    /// The mean anomaly at true anomaly `nu` (rad): M = E - e sin E on an
    /// ellipse, e sinh F - F on a hyperbola, and on a parabola Barker's
    /// D/2 + D³/6 with D = tan(ν/2), which is μ² t / h³. Measured from
    /// periapsis, negative before it; ν is taken in (-π, π]. Both forms are
    /// split so that near e = 1 and near periapsis they keep their digits.
    public static func meanAnomaly(trueAnomaly nu: Double, eccentricity e: Double) -> Double {
        let half = remainder(nu, 2 * Double.pi) / 2
        if abs(e - 1) < 1e-12 {
            let d = tan(half)
            return d / 2 + d * d * d / 6
        }
        if e < 1 {
            let ea = 2 * atan2((1 - e).squareRoot() * sin(half), (1 + e).squareRoot() * cos(half))
            return (1 - e) * sin(ea) + xMinusSin(ea)
        }
        let f = 2 * atanh(((e - 1) / (e + 1)).squareRoot() * tan(half))
        return (e - 1) * sinh(f) + sinhMinusX(f)
    }

    /// The true anomaly at mean anomaly `m` (rad), inverting `meanAnomaly`:
    /// Newton's method on Kepler's equation (elliptic or hyperbolic), Barker's
    /// cubic in closed form on a parabola. In (-π, π].
    public static func trueAnomaly(meanAnomaly m: Double, eccentricity e: Double) -> Double {
        if abs(e - 1) < 1e-12 {
            // D³ + 3D - 6M = 0.
            let w = cbrt(3 * m + (9 * m * m + 1).squareRoot())
            return 2 * atan(w - 1 / w)
        }
        if e < 1 {
            let mm = remainder(m, 2 * Double.pi)
            var ea = e < 0.8 ? mm + e * sin(mm) : (mm >= 0 ? Double.pi : -Double.pi)
            for _ in 0..<50 {
                let step = (ea - e * sin(ea) - mm) / (1 - e * cos(ea))
                ea -= step
                if abs(step) < 1e-15 { break }
            }
            return 2 * atan2((1 + e).squareRoot() * sin(ea / 2), (1 - e).squareRoot() * cos(ea / 2))
        }
        var f = m >= 0 ? log(2 * m / e + 1.8) : -log(-2 * m / e + 1.8)
        for _ in 0..<100 {
            let step = (e * sinh(f) - f - m) / (e * cosh(f) - 1)
            f -= step
            if abs(step) < 1e-15 * max(1, abs(f)) { break }
        }
        return 2 * atan(((e + 1) / (e - 1)).squareRoot() * tanh(f / 2))
    }

    /// x - sin x, by its series for small x.
    static func xMinusSin(_ x: Double) -> Double {
        guard abs(x) < 0.5 else { return x - sin(x) }
        let x2 = x * x
        return x * x2 * (1.0 / 6 - x2 * (1.0 / 120 - x2 * (1.0 / 5_040 - x2 * (1.0 / 362_880 - x2 / 39_916_800))))
    }

    /// sinh x - x, by its series for small x.
    static func sinhMinusX(_ x: Double) -> Double {
        guard abs(x) < 0.5 else { return sinh(x) - x }
        let x2 = x * x
        return x * x2 * (1.0 / 6 + x2 * (1.0 / 120 + x2 * (1.0 / 5_040 + x2 * (1.0 / 362_880 + x2 / 39_916_800))))
    }
}

// MARK: - Times along the conic

extension OrbitalElements {
    /// Time from periapsis to true anomaly `nu` along this conic (s),
    /// negative before periapsis; ν is taken in (-π, π].
    public func timeFromPeriapsis(toTrueAnomaly nu: Double) -> Double {
        let m = Kepler.meanAnomaly(trueAnomaly: nu, eccentricity: eccentricity)
        if abs(eccentricity - 1) < 1e-12 {
            let p = semiLatusRectum
            return m * (p * p * p / mu).squareRoot()
        }
        // n = √(μ |1 - e²|³ / p³), which stays finite as e → 1.
        let p = semiLatusRectum, q = abs((1 - eccentricity) * (1 + eccentricity))
        return m / (mu * q * q * q / (p * p * p)).squareRoot()
    }

    /// Time since periapsis (s): negative before it on an escape orbit; in
    /// [-T/2, T/2) on an ellipse.
    public var timeSincePeriapsis: Double { timeFromPeriapsis(toTrueAnomaly: trueAnomaly) }

    /// Time until the orbit next reaches true anomaly `nu` (s): in [0, T) on
    /// an ellipse; nil on an escape orbit that has passed it or never
    /// reaches it (beyond its asymptotes).
    public func timeTo(trueAnomaly nu: Double) -> Double? {
        if isBound {
            var dt = timeFromPeriapsis(toTrueAnomaly: nu) - timeSincePeriapsis
            dt = dt.truncatingRemainder(dividingBy: period)
            return dt < 0 ? dt + period : dt
        }
        guard 1 + eccentricity * cos(nu) > 0 else { return nil }
        let dt = timeFromPeriapsis(toTrueAnomaly: nu) - timeSincePeriapsis
        return dt >= 0 ? dt : nil
    }

    /// Time until the orbit next passes `radius` (s), going out, coming in,
    /// or either (nil); nil if it never does, or on a circular orbit.
    public func timeTo(radius: Double, outbound: Bool? = nil) -> Double? {
        guard let nus = trueAnomalies(atRadius: radius) else { return nil }
        var times: [Double] = []
        if outbound != false, let t = timeTo(trueAnomaly: nus.outbound) { times.append(t) }
        if outbound != true, let t = timeTo(trueAnomaly: nus.inbound) { times.append(t) }
        return times.min()
    }
}
